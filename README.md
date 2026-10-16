# Hopa Pizza website package

Open `index.html` for the customer-facing shop. Open `admin.html` for the separate management dashboard.

## Supabase setup
1. In Supabase Dashboard → SQL Editor, run `supabase/schema.sql`.
2. Then run `supabase/seed.sql`.
3. Create an admin account from Authentication → Users.
4. Copy the user's UUID and run:

```sql
insert into public.admin_users (user_id)
values ('PASTE_AUTH_USER_UUID_HERE')
on conflict (user_id) do nothing;
```

5. The project URL and the supplied Publishable Key are set in both HTML files. A Publishable Key is intended for browser use; no Secret Key is embedded. If the public key is replaced, update both files.
6. Serve the folder over HTTP (not `file://`): `python -m http.server 8000`, then open `http://localhost:8000/index.html` and `http://localhost:8000/admin.html`.

## Security and launch checklist
- Rotate/revoke the Secret Key that was exposed in chat before production. Do not put the replacement into either HTML file.
- Keep customer orders protected by RLS; this schema only exposes orders to admin users and creates customer orders through `create_hopa_order`, which recalculates prices in the database.
- Verify phone/WhatsApp numbers, address, product photos/prices and delivery fee. Seed data reflects the original sample code and may need business-owner review.
- This build confirms orders via WhatsApp after saving to the database. It does not include online card payments.
- Before public launch, consider CAPTCHA/rate-limiting on order creation and configure backups/monitoring.
