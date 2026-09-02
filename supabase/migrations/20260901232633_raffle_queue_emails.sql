-- Queue the entry confirmation as part of entering.
create or replace function public.queue_entry_email()
returns trigger language plpgsql security definer set search_path = public, pg_temp
as $$
begin
  insert into public.notifications (entry_id, channel, template, to_address)
  values (new.id, 'email', 'entered', new.email)
  on conflict (entry_id, channel, template) where entry_id is not null do nothing;
  return new;
end;
$$;

drop trigger if exists raffle_entry_email on public.raffle_entries;
create trigger raffle_entry_email
  after insert on public.raffle_entries
  for each row execute function public.queue_entry_email();

-- Queue the "not selected" email the moment an entry is marked lost.
create or replace function public.queue_lost_email()
returns trigger language plpgsql security definer set search_path = public, pg_temp
as $$
begin
  if new.status = 'lost' and coalesce(old.status,'') <> 'lost' then
    insert into public.notifications (entry_id, channel, template, to_address)
    values (new.id, 'email', 'raffle_lost', new.email)
    on conflict (entry_id, channel, template) where entry_id is not null do nothing;
  end if;
  return new;
end;
$$;

drop trigger if exists raffle_lost_email on public.raffle_entries;
create trigger raffle_lost_email
  after update on public.raffle_entries
  for each row execute function public.queue_lost_email();

-- Entries are admin-readable; nobody else can list who entered.
drop policy if exists raffle_admin_all on public.raffle_entries;
create policy raffle_admin_read on public.raffle_entries
  for select to authenticated using (public.is_admin());
create policy raffle_manager_write on public.raffle_entries
  for all to authenticated using (public.is_manager()) with check (public.is_manager());
