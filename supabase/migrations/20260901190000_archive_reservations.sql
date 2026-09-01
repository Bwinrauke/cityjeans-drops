-- Past drops and reservations made while testing clutter the list. Archiving
-- hides a row without destroying it: the record, the code and the pickup history
-- survive, and an archived row can be restored.
--
-- Archiving on its own never touches stock. A test booking is still holding a
-- pair, so archive_reservations() takes p_release_stock: when true, anything
-- still 'confirmed' is cancelled first, which frees the pair AND releases the
-- one-per-person hold so that customer can book again.
alter table public.reservations
  add column if not exists archived_at timestamptz;
create index if not exists reservations_archived_idx
  on public.reservations(archived_at) where archived_at is not null;
-- See public.archive_reservations(uuid[], uuid, timestamptz, boolean, boolean)
-- as applied to the project — manager/owner only.
