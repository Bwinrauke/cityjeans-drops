-- ON CONFLICT can only infer a partial index when the statement repeats its
-- predicate exactly, which is fragile and was already wrong in one caller.
-- Postgres treats NULLs as distinct in a unique index, so a plain index gives
-- the same guarantee (one message of each kind per reservation, and per entry)
-- while being inferrable from a bare column list.
drop index if exists notifications_once_res;
drop index if exists notifications_once_entry;

create unique index notifications_once_res
  on public.notifications(reservation_id, channel, template);
create unique index notifications_once_entry
  on public.notifications(entry_id, channel, template);

create or replace function public.queue_entry_email()
returns trigger language plpgsql security definer set search_path = public, pg_temp
as $$
begin
  insert into public.notifications (entry_id, channel, template, to_address)
  values (new.id, 'email', 'entered', new.email)
  on conflict (entry_id, channel, template) do nothing;
  return new;
end;
$$;

create or replace function public.queue_lost_email()
returns trigger language plpgsql security definer set search_path = public, pg_temp
as $$
begin
  if new.status = 'lost' and coalesce(old.status::text, '') <> 'lost' then
    insert into public.notifications (entry_id, channel, template, to_address)
    values (new.id, 'email', 'raffle_lost', new.email)
    on conflict (entry_id, channel, template) do nothing;
  end if;
  return new;
end;
$$;
