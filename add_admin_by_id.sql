-- HOPA PIZZA: Add an existing Supabase Auth user as an admin by their Auth user UUID.
-- Run this in Supabase Dashboard > SQL Editor after running supabase_setup.sql.

do $$
declare
  v_user_id uuid := '6daa51b7-e291-4336-a3a9-4141eb9b50a1'::uuid;
  v_email text;
begin
  select u.email
    into v_email
    from auth.users as u
   where u.id = v_user_id;

  if not found then
    raise exception 'No Supabase Auth user found with ID %; create the user first in Authentication > Users.', v_user_id;
  end if;

  insert into public.admin_users (user_id, email)
  values (v_user_id, v_email)
  on conflict (user_id)
  do update set email = excluded.email;
end
$$;

-- Optional verification: should return the admin user row.
select user_id, email, created_at
from public.admin_users
where user_id = '6daa51b7-e291-4336-a3a9-4141eb9b50a1'::uuid;
