-- A losing entry never becomes a reservation, so the outbox has to be able to
-- point at an entry as well. Telling losers is not optional — it is the
-- difference between a raffle and a silence.
alter table public.notifications
  alter column reservation_id drop not null,
  add column if not exists entry_id uuid references public.raffle_entries(id) on delete cascade;

drop index if exists notifications_once;
create unique index notifications_once_res
  on public.notifications(reservation_id, channel, template) where reservation_id is not null;
create unique index notifications_once_entry
  on public.notifications(entry_id, channel, template) where entry_id is not null;

create index if not exists notifications_entry_idx on public.notifications(entry_id);

-- ------------------------------------------------------------
create or replace function public.render_notification(p_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp
as $$
declare
  n public.notifications%rowtype;
  r public.reservations%rowtype;
  e public.raffle_entries%rowtype;
  rel public.releases%rowtype;
  loc text; win text; scale text; subj text; body text;
  fname text; code text;
begin
  select * into n from public.notifications where id = p_id;
  if not found then return null; end if;

  if n.entry_id is not null then
    select * into e from public.raffle_entries where id = n.entry_id;
    if not found then return null; end if;
    select * into rel from public.releases where id = e.release_id;
    select name into loc from public.locations where id = e.location_id;
    fname := e.first_name; code := e.code;
  else
    select * into r from public.reservations where id = n.reservation_id;
    if not found then return null; end if;
    select * into rel from public.releases where id = r.release_id;
    select name into loc from public.locations where id = r.location_id;
    fname := r.first_name; code := r.code;
  end if;

  scale := case rel.size_scale
             when 'womens' then 'Women''s ' when 'gs' then 'GS '
             when 'ps' then 'PS ' when 'td' then 'TD ' else 'US ' end;

  win := case
    when rel.pickup_starts_at is null then 'the pickup window'
    else to_char(rel.pickup_starts_at at time zone 'America/New_York', 'Dy Mon DD')
         || ', ' || trim(to_char(rel.pickup_starts_at at time zone 'America/New_York', 'HH12:MI AM'))
         || case when rel.pickup_ends_at is not null
              then ' – ' || trim(to_char(rel.pickup_ends_at at time zone 'America/New_York', 'HH12:MI AM'))
              else '' end
  end;

  if n.template = 'confirmation' then
    subj := 'You''re confirmed — ' || rel.name || ' (' || code || ')';
    body := 'Hi ' || fname || E',\n\n' || 'Your pair is reserved.' || E'\n\n'
         || rel.name || E'\n' || 'Size ' || scale || r.size || E'\n'
         || 'Pick up at ' || loc || E'\n' || 'Pickup window: ' || win || E'\n\n'
         || 'YOUR CODE: ' || code || E'\n\n'
         || 'Show this code at the register. ' || coalesce(rel.pickup_note, '') || E'\n\n'
         || 'Unclaimed pairs go back on the floor at the end of the window.';

  elsif n.template = 'entered' then
    subj := 'You''re entered — ' || rel.name;
    body := 'Hi ' || fname || E',\n\n'
         || 'Your raffle entry is in.' || E'\n\n'
         || rel.name || E'\n' || 'Size ' || scale || e.size || E'\n'
         || 'Pick up at ' || loc || ' if you win' || E'\n'
         || case when rel.closes_at is not null then 'Entries close '
              || to_char(rel.closes_at at time zone 'America/New_York', 'Dy Mon DD, HH12:MI AM')
              || E'\n' else '' end
         || E'\n' || 'YOUR CODE: ' || code || E'\n\n'
         || 'Everyone is emailed after the draw, whether or not they''re picked. '
         || 'You don''t need to check back.';

  elsif n.template = 'reminder' then
    subj := 'Today: pick up your ' || rel.name;
    body := 'Hi ' || fname || E',\n\n'
         || 'Your pair is waiting at ' || loc || ' today.' || E'\n\n'
         || rel.name || ' · Size ' || scale || r.size || E'\n'
         || 'Window: ' || win || E'\n\n' || 'YOUR CODE: ' || code;

  elsif n.template = 'expiring' then
    subj := 'Last call — your ' || rel.name || ' is still waiting';
    body := 'Hi ' || fname || E',\n\n'
         || 'Your reservation at ' || loc || ' has not been collected yet, '
         || 'and the pickup window closes soon.' || E'\n\n'
         || rel.name || ' · Size ' || scale || r.size || E'\n'
         || 'YOUR CODE: ' || code || E'\n\n'
         || 'After that the pair goes back on the floor.';

  elsif n.template = 'raffle_won' then
    subj := 'You won — ' || rel.name;
    body := 'Hi ' || fname || E',\n\n'
         || 'You were drawn for ' || rel.name || '.' || E'\n\n'
         || 'Size ' || scale || r.size || E'\n' || 'Pick up at ' || loc || E'\n'
         || 'Window: ' || win || E'\n\n' || 'YOUR CODE: ' || code || E'\n\n'
         || 'Bring the code to the register within the window or the pair is released.';

  elsif n.template = 'raffle_lost' then
    subj := 'Not selected — ' || rel.name;
    body := 'Hi ' || fname || E',\n\n'
         || 'You weren''t drawn for ' || rel.name || ' this time.' || E'\n\n'
         || 'There were more entries than pairs. Every entry had the same chance — '
         || 'the draw is random and we keep a record of it.' || E'\n\n'
         || 'Thanks for entering. We''ll post the next drop soon.';
  else
    return null;
  end if;

  return jsonb_build_object(
    'id', n.id, 'channel', n.channel, 'template', n.template,
    'to', case when n.channel = 'sms'
               then coalesce(r.phone_norm, e.phone_norm)
               else coalesce(r.email, e.email) end,
    'subject', subj, 'body', body, 'code', code,
    'name', coalesce(r.first_name || ' ' || r.last_name, e.first_name || ' ' || e.last_name));
end;
$$;

-- ------------------------------------------------------------
-- Claim now covers entry-backed rows as well as reservation-backed ones.
-- ------------------------------------------------------------
create or replace function public.claim_notifications(p_limit int default 25)
returns jsonb
language plpgsql security definer set search_path = public, pg_temp
as $$
declare v_ids uuid[];
begin
  update public.notifications n
     set status = 'skipped', locked_at = null
    from public.reservations r
   where n.reservation_id = r.id
     and n.status = 'queued'
     and (r.status in ('cancelled','no_show') or r.archived_at is not null);

  with picked as (
    select n.id from public.notifications n
     left join public.reservations r on r.id = n.reservation_id
     left join public.raffle_entries e on e.id = n.entry_id
     where n.status = 'queued'
       and n.send_after <= now()
       and n.attempts < 5
       and (n.locked_at is null or n.locked_at < now() - interval '5 minutes')
       and (
         (n.reservation_id is not null and r.status = 'confirmed' and r.archived_at is null)
         or (n.entry_id is not null and e.id is not null)
       )
     order by n.send_after
     limit p_limit
     for update of n skip locked
  ), claimed as (
    update public.notifications n
       set locked_at = now(), attempts = n.attempts + 1
      from picked p
     where n.id = p.id
    returning n.id
  )
  select array_agg(id) into v_ids from claimed;

  if v_ids is null then return '[]'::jsonb; end if;
  return coalesce(
    (select jsonb_agg(m) from unnest(v_ids) i,
       lateral public.render_notification(i) m where m is not null),
    '[]'::jsonb);
end;
$$;

revoke execute on function public.claim_notifications(int) from anon, authenticated;
