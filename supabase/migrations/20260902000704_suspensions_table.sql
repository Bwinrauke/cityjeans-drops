-- A suspension follows the person, not an account — there are no customer
-- accounts here, only the email and phone on a booking. Either one matching is
-- enough, because coming back with a fresh email and the same phone is the
-- thing people actually try.
create table if not exists public.suspensions (
  id             uuid primary key default gen_random_uuid(),
  email_norm     text not null,
  phone_norm     text not null,
  first_name     text,
  last_name      text,
  reason         text not null default 'two_no_shows',
  strikes        int  not null default 2,
  -- the second missed pickup: what earned the suspension, and the guard against
  -- suspending the same person twice for the same pair of misses
  trigger_reservation_id uuid references public.reservations(id) on delete set null,
  started_at     timestamptz not null default now(),
  until          timestamptz not null,
  lifted_at      timestamptz,
  lifted_by      uuid references auth.users(id),
  lifted_reason  text,
  created_at     timestamptz not null default now()
);

create index if not exists suspensions_email_idx on public.suspensions(email_norm);
create index if not exists suspensions_phone_idx on public.suspensions(phone_norm);
create index if not exists suspensions_until_idx on public.suspensions(until);
create unique index if not exists suspensions_trigger_once
  on public.suspensions(trigger_reservation_id) where trigger_reservation_id is not null;

alter table public.suspensions enable row level security;

-- Anyone at a register may need to explain why a booking was refused, so every
-- admin can read the list. Only the RPCs below write to it.
drop policy if exists suspensions_admin_read on public.suspensions;
create policy suspensions_admin_read on public.suspensions
  for select to authenticated using (public.is_admin());

revoke all on public.suspensions from anon;

-- The one live suspension for a person, if there is one.
create or replace function public.active_suspension(p_email_norm text, p_phone_norm text)
returns public.suspensions
language sql stable security definer set search_path = public, pg_temp
as $$
  select s.* from public.suspensions s
   where (s.email_norm = p_email_norm or s.phone_norm = p_phone_norm)
     and s.lifted_at is null
     and s.until > now()
   order by s.until desc
   limit 1;
$$;

revoke execute on function public.active_suspension(text, text) from anon, authenticated;
