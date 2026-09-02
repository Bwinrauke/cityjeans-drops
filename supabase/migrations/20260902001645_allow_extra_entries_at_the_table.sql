-- These were how one-entry-per-person used to be enforced: the second entry
-- simply bounced. The rule has moved to the draw, where every entry that
-- person made is disqualified, so the table has to be able to hold the
-- evidence. Ordinary indexes keep the same lookups fast.
drop index if exists public.raffle_one_per_email;
drop index if exists public.raffle_one_per_phone;

create index if not exists raffle_entries_email_idx
  on public.raffle_entries(release_id, email_norm);
create index if not exists raffle_entries_phone_idx
  on public.raffle_entries(release_id, phone_norm);
