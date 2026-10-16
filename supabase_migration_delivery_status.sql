-- HOPA PIZZA: migration from the previous orders setup.
-- Run once in Supabase SQL Editor after the original setup has already been applied.

begin;

create table if not exists public.delivery_areas (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(trim(name)) between 2 and 100),
  fee numeric(10,2) not null check (fee >= 0),
  is_active boolean not null default true,
  display_order integer not null default 100,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index if not exists delivery_areas_name_lower_uidx on public.delivery_areas (lower(name));

alter table public.orders add column if not exists delivery_area_id uuid references public.delivery_areas(id) on delete set null;
alter table public.orders add column if not exists delivery_area_name text not null default '';
create index if not exists delivery_areas_active_order_idx on public.delivery_areas (is_active, display_order);

create or replace function public.record_order_status_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.status is distinct from old.status then
    -- Delivered and cancelled are terminal. Cancellation is only possible before dispatch.
    if old.status in ('delivered', 'cancelled') then
      raise exception 'هذه الحالة نهائية ولا يمكن تغييرها.';
    end if;

    if new.status = 'cancelled' then
      if old.status not in ('confirmed', 'preparing') then
        raise exception 'لا يمكن إلغاء الطلب بعد خروجه للتوصيل.';
      end if;
    elsif not (
      (old.status = 'confirmed' and new.status = 'preparing') or
      (old.status = 'preparing' and new.status = 'out_for_delivery') or
      (old.status = 'out_for_delivery' and new.status = 'delivered')
    ) then
      raise exception 'لا يمكن الرجوع لحالة سابقة أو تخطي مرحلة من مراحل الطلب.';
    end if;

    insert into public.order_status_history (order_id, status, note, changed_by)
    values (
      new.id,
      new.status,
      case new.status
        when 'confirmed' then 'الطلب اتأكد'
        when 'preparing' then 'الطلب بيتجهز'
        when 'out_for_delivery' then 'الطلب خرج للتوصيل'
        when 'delivered' then 'الطلب اتسلم'
        when 'cancelled' then 'الطلب اتلغى'
        else 'تم تحديث حالة الطلب'
      end,
      auth.uid()
    );
    new.updated_at := now();
  end if;
  return new;
end;
$$;

drop trigger if exists orders_status_history_trigger on public.orders;
create trigger orders_status_history_trigger
before update of status on public.orders
for each row execute function public.record_order_status_change();

-- Public checkout RPC: product prices and delivery fee are read from the database.
drop function if exists public.create_public_order(text, text, text, text, jsonb);
create or replace function public.create_public_order(
  p_customer_name text,
  p_phone text,
  p_address text,
  p_notes text,
  p_delivery_area_id uuid,
  p_items jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_name text := trim(coalesce(p_customer_name, ''));
  v_phone text := trim(coalesce(p_phone, ''));
  v_address text := trim(coalesce(p_address, ''));
  v_notes text := trim(coalesce(p_notes, ''));
  v_item jsonb;
  v_product public.products%rowtype;
  v_area public.delivery_areas%rowtype;
  v_qty integer;
  v_subtotal numeric(10,2) := 0;
  v_delivery_fee numeric(10,2);
  v_total numeric(10,2);
  v_order_id uuid;
  v_order_code text;
begin
  if length(v_name) < 2 or length(v_name) > 120 then
    raise exception 'اكتب الاسم بشكل صحيح';
  end if;
  if length(regexp_replace(v_phone, '[^0-9]', '', 'g')) < 10 or length(v_phone) > 30 then
    raise exception 'رقم الموبايل غير صحيح';
  end if;
  if length(v_address) < 5 or length(v_address) > 500 then
    raise exception 'اكتب عنوان توصيل واضح';
  end if;
  if length(v_notes) > 500 then
    raise exception 'الملاحظات طويلة أكثر من اللازم';
  end if;
  if p_delivery_area_id is null then
    raise exception 'اختار منطقة التوصيل';
  end if;
  select * into v_area
  from public.delivery_areas a
  where a.id = p_delivery_area_id and a.is_active = true;
  if not found then
    raise exception 'منطقة التوصيل المختارة غير متاحة. اختار منطقة أخرى.';
  end if;
  v_delivery_fee := v_area.fee;

  if jsonb_typeof(p_items) is distinct from 'array' then
    raise exception 'صيغة السلة غير صحيحة';
  end if;
  if jsonb_array_length(p_items) < 1 or jsonb_array_length(p_items) > 40 then
    raise exception 'السلة فارغة أو عدد عناصرها غير صحيح';
  end if;

  -- Validate products and calculate prices on the server.
  for v_item in select value from jsonb_array_elements(p_items) as t(value) loop
    if coalesce(v_item->>'quantity', '') !~ '^[0-9]+$' then
      raise exception 'كمية المنتج غير صحيحة';
    end if;
    v_qty := (v_item->>'quantity')::integer;
    if v_qty < 1 or v_qty > 20 then
      raise exception 'كمية المنتج يجب أن تكون من 1 إلى 20';
    end if;
    if coalesce(v_item->>'product_id', '') !~* '^[0-9a-f-]{36}$' then
      raise exception 'معرّف المنتج غير صحيح';
    end if;
    select * into v_product
    from public.products p
    where p.id = (v_item->>'product_id')::uuid and p.is_active = true;
    if not found then
      raise exception 'أحد المنتجات لم يعد متاحاً';
    end if;
    v_subtotal := v_subtotal + (v_product.price * v_qty);
  end loop;

  v_total := v_subtotal + v_delivery_fee;
  v_order_code := 'HP-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8));
  insert into public.orders (
    order_code, customer_name, phone, address, delivery_area_id, delivery_area_name,
    notes, subtotal, delivery_fee, total, status
  ) values (
    v_order_code, v_name, v_phone, v_address, v_area.id, v_area.name,
    v_notes, v_subtotal, v_delivery_fee, v_total, 'confirmed'
  ) returning id into v_order_id;

  for v_item in select value from jsonb_array_elements(p_items) as t(value) loop
    v_qty := (v_item->>'quantity')::integer;
    select * into v_product from public.products p where p.id = (v_item->>'product_id')::uuid and p.is_active = true;
    insert into public.order_items (order_id, product_id, product_name, unit_price, quantity, line_total)
    values (v_order_id, v_product.id, v_product.name, v_product.price, v_qty, v_product.price * v_qty);
  end loop;

  insert into public.order_status_history (order_id, status, note)
  values (v_order_id, 'confirmed', 'الطلب اتأكد');

  return jsonb_build_object(
    'id', v_order_id,
    'order_code', v_order_code,
    'status', 'confirmed',
    'delivery_area_name', v_area.name,
    'subtotal', v_subtotal,
    'delivery_fee', v_delivery_fee,
    'total', v_total
  );
end;
$$;

create or replace function public.track_public_order(p_order_code text, p_phone text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order public.orders%rowtype;
begin
  select o.* into v_order
  from public.orders o
  where upper(o.order_code) = upper(trim(coalesce(p_order_code, '')))
    and regexp_replace(o.phone, '[^0-9]', '', 'g') = regexp_replace(coalesce(p_phone, ''), '[^0-9]', '', 'g')
  limit 1;

  if not found then
    return null;
  end if;

  return jsonb_build_object(
    'order_code', v_order.order_code,
    'status', v_order.status,
    'delivery_area_name', v_order.delivery_area_name,
    'subtotal', v_order.subtotal,
    'delivery_fee', v_order.delivery_fee,
    'total', v_order.total,
    'created_at', v_order.created_at,
    'updated_at', v_order.updated_at,
    'items', coalesce((
      select jsonb_agg(jsonb_build_object(
        'product_name', oi.product_name,
        'unit_price', oi.unit_price,
        'quantity', oi.quantity,
        'line_total', oi.line_total
      ) order by oi.created_at)
      from public.order_items oi where oi.order_id = v_order.id
    ), '[]'::jsonb),
    'history', coalesce((
      select jsonb_agg(jsonb_build_object(
        'status', h.status,
        'note', h.note,
        'created_at', h.created_at
      ) order by h.created_at)
      from public.order_status_history h where h.order_id = v_order.id
    ), '[]'::jsonb)
  );
end;
$$;

revoke all on function public.create_public_order(text, text, text, text, uuid, jsonb) from public;
grant execute on function public.create_public_order(text, text, text, text, uuid, jsonb) to anon, authenticated;
revoke all on function public.track_public_order(text, text) from public;
grant execute on function public.track_public_order(text, text) to anon, authenticated;

alter table public.delivery_areas enable row level security;
revoke all on public.delivery_areas from anon, authenticated;
grant select on public.delivery_areas to anon, authenticated;
grant insert, update, delete on public.delivery_areas to authenticated;
drop policy if exists delivery_areas_public_read_active on public.delivery_areas;
create policy delivery_areas_public_read_active on public.delivery_areas
for select to anon, authenticated
using (is_active = true or public.is_admin());
drop policy if exists delivery_areas_admin_manage on public.delivery_areas;
create policy delivery_areas_admin_manage on public.delivery_areas
for all to authenticated
using (public.is_admin())
with check (public.is_admin());

commit;
