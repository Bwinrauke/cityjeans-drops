-- ============================================================
-- Raffle engine
--
-- Shape of a raffle, and why:
--
--   1. ENTRY.  Entrants pick a size and a pickup store, exactly as they would
--      for a first-come drop, but nothing is held — at this point nobody knows
--      how many pairs each store gets. One entry per person per release,
--      enforced by unique indexes on email and phone, not by trust.
--
--   2. CLOSE.  Entries stop at closes_at. Only now does the buyer see demand
--      per size per store, which is the whole point of running a raffle
--      before allocating: you allocate against real demand.
--
--   3. ALLOCATE. Quantities are loaded per size per store in the existing
--      editor.
--
--   4. DRAW.  Each (store, size) bucket is drawn independently, up to the
--      quantity loaded for it. Winners become ordinary reservations with the
--      same codes and the same register flow. Everyone else is marked lost.
--
-- Fairness is verifiable rather than asserted. The draw generates a random
-- seed, orders every entry by sha256(entry id || seed), and stores the seed
-- with the result. Anyone holding the seed and the entry list can recompute
-- the exact winners; nobody can predict them beforehand.
-- ============================================================

alter table public.raffle_entries
  add column if not exists code       text,
  add column if not exists draw_id    uuid,
  add column if not exists notified_at timestamptz;

create unique index if not exists raffle_entries_code on public.raffle_entries(code)
  where code is not null;

-- one entry per phone as well as per email
create unique index if not exists raffle_one_per_phone
  on public.raffle_entries(release_id, phone_norm)
  where status in ('entered','won');

create index if not exists raffle_bucket_idx
  on public.raffle_entries(release_id, location_id, size, status);

-- ------------------------------------------------------------
-- Audit record: one row per draw, holding the seed that proves it.
-- ------------------------------------------------------------
create table if not exists public.raffle_draws (
  id          uuid primary key default gen_random_uuid(),
  release_id  uuid not null references public.releases(id) on delete cascade,
  ran_at      timestamptz not null default now(),
  ran_by      uuid,
  seed        text not null,
  entries     int  not null default 0,
  winners     int  not null default 0,
  losers      int  not null default 0,
  buckets     jsonb
);
alter table public.raffle_draws enable row level security;
create policy raffle_draws_admin_read on public.raffle_draws
  for select to authenticated using (public.is_admin());

-- a release can only be drawn once
create unique index if not exists raffle_draws_one_per_release
  on public.raffle_draws(release_id);

-- ------------------------------------------------------------
-- Entry status on a release, for the customer page.
-- ------------------------------------------------------------
create or replace function public.raffle_state(p_slug text)
returns jsonb
language sql stable security definer set search_path = public, pg_temp
as $$
  select jsonb_build_object(
    'mode', r.mode,
    'status', r.status,
    'opens_at', r.opens_at,
    'closes_at', r.closes_at,
    'entries_open', r.mode = 'raffle' and r.status = 'open'
                    and (r.opens_at is null or now() >= r.opens_at)
                    and (r.closes_at is null or now() <= r.closes_at),
    'drawn', exists (select 1 from public.raffle_draws d where d.release_id = r.id))
  from public.releases r where r.slug = p_slug;
$$;
grant execute on function public.raffle_state(text) to anon, authenticated;
