-- Never send for a reservation that has been cancelled, marked no-show or
-- archived — those queue rows are history, not mail waiting to go out.
create or replace function public.claim_notifications(p_limit int default 25)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare v_ids uuid[];
begin
  -- retire anything whose reservation is no longer live
  update public.notifications n
     set status = 'skipped', locked_at = null
    from public.reservations r
   where n.reservation_id = r.id
     and n.status = 'queued'
     and (r.status in ('cancelled','no_show') or r.archived_at is not null);

  with picked as (
    select n.id from public.notifications n
     join public.reservations r on r.id = n.reservation_id
     where n.status = 'queued'
       and n.send_after <= now()
       and n.attempts < 5
       and (n.locked_at is null or n.locked_at < now() - interval '5 minutes')
       and r.status = 'confirmed'
       and r.archived_at is null
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

-- clear the backlog left by testing: nothing live is waiting
update public.notifications n
   set status = 'skipped', attempts = 0, locked_at = null, error = null
  from public.reservations r
 where n.reservation_id = r.id
   and n.status = 'queued'
   and (r.status <> 'confirmed' or r.archived_at is not null);

update public.notifications set attempts = 0, locked_at = null, error = null
 where status = 'queued';
