-- ============================================================
-- Row Level Security
-- ============================================================
alter table public.locations         enable row level security;
alter table public.releases          enable row level security;
alter table public.release_inventory enable row level security;
alter table public.reservations      enable row level security;
alter table public.raffle_entries    enable row level security;
alter table public.admins            enable row level security;
alter table public.notifications     enable row level security;

-- Locations: anyone may read active stores; admins manage.
create policy locations_public_read on public.locations
  for select to anon, authenticated using (active = true);
create policy locations_admin_all on public.locations
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

-- Releases: anyone may read published (open/closed) releases; admins manage.
create policy releases_public_read on public.releases
  for select to anon, authenticated using (status in ('open','closed'));
create policy releases_admin_all on public.releases
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

-- Inventory: anyone may read counts for published releases; admins manage.
create policy inventory_public_read on public.release_inventory
  for select to anon, authenticated using (
    exists (select 1 from public.releases r
             where r.id = release_id and r.status in ('open','closed')));
create policy inventory_admin_all on public.release_inventory
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

-- Reservations: NO anonymous access at all. Customers reach their own
-- reservation only through reserve_spot / lookup_reservation.
create policy reservations_admin_all on public.reservations
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

create policy raffle_admin_all on public.raffle_entries
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

create policy notifications_admin_all on public.notifications
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

-- Admins table: an admin can see the admin list; nobody else can.
create policy admins_self_read on public.admins
  for select to authenticated using (public.is_admin());
create policy admins_owner_manage on public.admins
  for all to authenticated
  using (exists (select 1 from public.admins a
                  where a.user_id = auth.uid() and a.role = 'owner'))
  with check (exists (select 1 from public.admins a
                  where a.user_id = auth.uid() and a.role = 'owner'));

-- ============================================================
-- Storage: public bucket for shoe photos
-- ============================================================
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('shoe-photos', 'shoe-photos', true, 10485760,
        array['image/jpeg','image/png','image/webp','image/avif'])
on conflict (id) do nothing;

create policy shoe_photos_public_read on storage.objects
  for select to anon, authenticated using (bucket_id = 'shoe-photos');
create policy shoe_photos_admin_write on storage.objects
  for insert to authenticated with check (bucket_id = 'shoe-photos' and public.is_admin());
create policy shoe_photos_admin_update on storage.objects
  for update to authenticated using (bucket_id = 'shoe-photos' and public.is_admin());
create policy shoe_photos_admin_delete on storage.objects
  for delete to authenticated using (bucket_id = 'shoe-photos' and public.is_admin());
