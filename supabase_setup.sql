-- HOPA PIZZA | Supabase database setup
-- Run this complete file once in Supabase Dashboard > SQL Editor.
-- Uses only the publishable key in browser code. Never put a service_role/secret key in HTML.

create table if not exists public.admin_users (
  user_id uuid primary key references auth.users(id) on delete cascade,
  email text,
  created_at timestamptz not null default now()
);

create table if not exists public.products (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(trim(name)) between 1 and 140),
  description text not null default '',
  price numeric(10,2) not null check (price >= 0),
  compare_price numeric(10,2),
  image_url text not null default '',
  category text not null default 'other',
  badge text not null default '',
  is_active boolean not null default true,
  display_order integer not null default 100,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.site_settings (
  id boolean primary key default true check (id = true),
  brand_name text not null default 'هوبا بيتزا',
  hotline text not null default '19XXX',
  delivery_fee numeric(10,2) not null default 25 check (delivery_fee >= 0),
  announcement text not null default 'في حتة تانية خالص!',
  updated_at timestamptz not null default now()
);

create table if not exists public.orders (
  id uuid primary key default gen_random_uuid(),
  order_code text not null unique,
  customer_name text not null,
  phone text not null,
  address text not null,
  notes text not null default '',
  subtotal numeric(10,2) not null check (subtotal >= 0),
  delivery_fee numeric(10,2) not null default 25 check (delivery_fee >= 0),
  total numeric(10,2) not null check (total >= 0),
  status text not null default 'confirmed' check (status in ('confirmed','preparing','out_for_delivery','delivered','cancelled')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.order_items (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete cascade,
  product_id uuid references public.products(id) on delete set null,
  product_name text not null,
  unit_price numeric(10,2) not null check (unit_price >= 0),
  quantity integer not null check (quantity between 1 and 20),
  line_total numeric(10,2) not null check (line_total >= 0),
  created_at timestamptz not null default now()
);

create table if not exists public.order_status_history (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete cascade,
  status text not null check (status in ('confirmed','preparing','out_for_delivery','delivered','cancelled')),
  note text not null default '',
  changed_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);

create index if not exists products_active_order_idx on public.products (is_active, display_order);
create index if not exists orders_created_at_idx on public.orders (created_at desc);
create index if not exists orders_status_idx on public.orders (status);
create index if not exists orders_code_phone_idx on public.orders (order_code, phone);
create index if not exists order_items_order_id_idx on public.order_items (order_id);
create index if not exists order_history_order_id_idx on public.order_status_history (order_id, created_at);

-- Seed only once (ON CONFLICT DO NOTHING preserves later dashboard edits).
insert into public.products (id, name, description, price, compare_price, image_url, category, badge, is_active, display_order)
values
 ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1', 'بيبروني بركان', 'دبل بيبروني إيطالي مع هلابينو سبايسي وجبنة موزاريلا سايحة بتمط.', 160, 200, 'https://freepngimg.com/thumb/pizza/34-pizza-png-image.png', 'meat', 'حراق 🔥', true, 1),
 ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2', 'هوبا سبيشيال', 'ميكس لحوم مع خلطة هوبا السرية، بصل مكرمل وصوص الباربكيو.', 185, null, 'https://freepngimg.com/thumb/pizza/2-pizza-png-image.png', 'meat', 'الوحش 👑', true, 2),
 ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa3', 'تشيكن رانش', 'قطع فراخ مشوية، مشروم فريش، غرقانة في صوص الرانش الغني.', 170, null, 'https://freepngimg.com/thumb/pizza/5-pizza-png-image.png', 'chicken', 'للمزاجنجية 🤤', true, 3)
on conflict (id) do nothing;

insert into public.site_settings (id, brand_name, hotline, delivery_fee, announcement)
values (true, 'هوبا بيتزا', '19XXX', 25, 'في حتة تانية خالص!')
on conflict (id) do nothing;

-- Helper used by row-level security. SECURITY DEFINER avoids admin_users RLS recursion.
create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.admin_users a where a.user_id = auth.uid()
  );
$$;

revoke all on function public.is_admin() from public;
grant execute on function public.is_admin() to anon, authenticated;

-- Keep a durable history record whenever an admin changes an order's status.
create or replace function public.record_order_status_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.status is distinct from old.status then
    insert into public.order_status_history (order_id, status, note, changed_by)
    values (
      new.id,
      new.status,
      case new.status
        when 'confirmed' then 'تم تأكيد الطلب'
        when 'preparing' then 'بدأ تجهيز الطلب'
        when 'out_for_delivery' then 'الطلب خرج للتوصيل'
        when 'delivered' then 'تم تسليم الطلب'
        when 'cancelled' then 'تم إلغاء الطلب'
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

-- Public checkout RPC: prices are loaded from the database, not trusted from browser values.
create or replace function public.create_public_order(
  p_customer_name text,
  p_phone text,
  p_address text,
  p_notes text,
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
  v_qty integer;
  v_subtotal numeric(10,2) := 0;
  v_delivery_fee numeric(10,2) := 25;
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
  if jsonb_typeof(p_items) is distinct from 'array' then
    raise exception 'صيغة السلة غير صحيحة';
  end if;
  if jsonb_array_length(p_items) < 1 or jsonb_array_length(p_items) > 40 then
    raise exception 'السلة فارغة أو عدد عناصرها غير صحيح';
  end if;

  select s.delivery_fee into v_delivery_fee
  from public.site_settings s where s.id = true;
  v_delivery_fee := coalesce(v_delivery_fee, 25);

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
  insert into public.orders (order_code, customer_name, phone, address, notes, subtotal, delivery_fee, total, status)
  values (v_order_code, v_name, v_phone, v_address, v_notes, v_subtotal, v_delivery_fee, v_total, 'confirmed')
  returning id into v_order_id;

  for v_item in select value from jsonb_array_elements(p_items) as t(value) loop
    v_qty := (v_item->>'quantity')::integer;
    select * into v_product from public.products p where p.id = (v_item->>'product_id')::uuid and p.is_active = true;
    insert into public.order_items (order_id, product_id, product_name, unit_price, quantity, line_total)
    values (v_order_id, v_product.id, v_product.name, v_product.price, v_qty, v_product.price * v_qty);
  end loop;

  insert into public.order_status_history (order_id, status, note)
  values (v_order_id, 'confirmed', 'تم استلام الطلب وتأكيده');

  return jsonb_build_object(
    'id', v_order_id,
    'order_code', v_order_code,
    'status', 'confirmed',
    'subtotal', v_subtotal,
    'delivery_fee', v_delivery_fee,
    'total', v_total
  );
end;
$$;

-- Public tracking only returns a single order after BOTH its code and phone are verified.
-- It deliberately does not return street address or the full phone number.
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

revoke all on function public.create_public_order(text, text, text, text, jsonb) from public;
grant execute on function public.create_public_order(text, text, text, text, jsonb) to anon, authenticated;
revoke all on function public.track_public_order(text, text) from public;
grant execute on function public.track_public_order(text, text) to anon, authenticated;

-- Enable RLS on every exposed application table.
alter table public.admin_users enable row level security;
alter table public.products enable row level security;
alter table public.site_settings enable row level security;
alter table public.orders enable row level security;
alter table public.order_items enable row level security;
alter table public.order_status_history enable row level security;

-- Remove broad defaults, then grant only the required table-level privileges.
revoke all on public.admin_users, public.products, public.site_settings, public.orders, public.order_items, public.order_status_history from anon, authenticated;
grant select on public.admin_users to authenticated;
grant select on public.products to anon, authenticated;
grant insert, update, delete on public.products to authenticated;
grant select on public.site_settings to anon, authenticated;
grant update on public.site_settings to authenticated;
grant select, update on public.orders to authenticated;
grant select on public.order_items to authenticated;
grant select on public.order_status_history to authenticated;

-- Policies are dropped/recreated so this file can be safely re-run.
drop policy if exists admin_users_read_self on public.admin_users;
create policy admin_users_read_self on public.admin_users
for select to authenticated
using (user_id = (select auth.uid()));

drop policy if exists products_public_read_active on public.products;
create policy products_public_read_active on public.products
for select to anon, authenticated
using (is_active = true or public.is_admin());

drop policy if exists products_admin_manage on public.products;
create policy products_admin_manage on public.products
for all to authenticated
using (public.is_admin())
with check (public.is_admin());

drop policy if exists settings_public_read on public.site_settings;
create policy settings_public_read on public.site_settings
for select to anon, authenticated
using (id = true);

drop policy if exists settings_admin_update on public.site_settings;
create policy settings_admin_update on public.site_settings
for update to authenticated
using (public.is_admin())
with check (public.is_admin());

drop policy if exists orders_admin_read on public.orders;
create policy orders_admin_read on public.orders
for select to authenticated
using (public.is_admin());

drop policy if exists orders_admin_update on public.orders;
create policy orders_admin_update on public.orders
for update to authenticated
using (public.is_admin())
with check (public.is_admin());

drop policy if exists order_items_admin_read on public.order_items;
create policy order_items_admin_read on public.order_items
for select to authenticated
using (public.is_admin());

drop policy if exists order_history_admin_read on public.order_status_history;
create policy order_history_admin_read on public.order_status_history
for select to authenticated
using (public.is_admin());

-- IMPORTANT: create an admin user before trying to sign in to admin.html:
-- 1) Supabase Dashboard > Authentication > Users > Add user (email + password).
-- 2) Replace the email below and run this statement in SQL Editor:
-- insert into public.admin_users (user_id, email)
-- select id, email from auth.users where lower(email) = lower('YOUR-ADMIN-EMAIL@example.com')
-- on conflict (user_id) do update set email = excluded.email;
