-- old.status is an enum; comparing it to '' tries to coerce '' into the enum
-- and fails. Compare as text.
create or replace function public.queue_lost_email()
returns trigger language plpgsql security definer set search_path = public, pg_temp
as $$
begin
  if new.status = 'lost' and coalesce(old.status::text, '') <> 'lost' then
    insert into public.notifications (entry_id, channel, template, to_address)
    values (new.id, 'email', 'raffle_lost', new.email)
    on conflict (entry_id, channel, template) where entry_id is not null do nothing;
  end if;
  return new;
end;
$$;
