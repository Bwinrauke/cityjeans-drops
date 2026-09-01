-- Invite-only accounts. Nobody gets an auth account unless their email was
-- added to public.invited_emails first, so the public /auth/v1/signup endpoint
-- is closed regardless of the dashboard's "allow new users to sign up" setting.
create table public.invited_emails (
  email       text primary key,
  note        text,
  invited_by  uuid references auth.users(id),
  created_at  timestamptz not null default now(),
  used_at     timestamptz
);
alter table public.invited_emails enable row level security;
create policy invited_admin_all on public.invited_emails
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

insert into public.invited_emails (email, note, used_at)
select lower(email), 'existing account at the time invite-only was turned on', now()
from auth.users on conflict (email) do nothing;

create or replace function public.enforce_invite_only()
returns trigger language plpgsql security definer
set search_path = public, auth, pg_temp as $$
declare v_email text := lower(btrim(coalesce(new.email, '')));
begin
  if v_email = '' then
    raise exception 'An email address is required to create an account.' using errcode = '42501';
  end if;
  if not exists (select 1 from public.invited_emails i where i.email = v_email) then
    raise exception 'Sign-ups are disabled. % has not been invited.', v_email using errcode = '42501';
  end if;
  update public.invited_emails set used_at = coalesce(used_at, now()) where email = v_email;
  return new;
end; $$;

create trigger enforce_invite_only_on_signup
  before insert on auth.users
  for each row execute function public.enforce_invite_only();
