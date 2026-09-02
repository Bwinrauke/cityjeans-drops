-- Test rows in this project are written with a "zz-" prefix by convention.
-- The earlier guard only caught RFC 2606 reserved domains, so a test address
-- on the real cityjeans.com domain still went out and bounced. Bounce rate is
-- what SES suspends an account over, so the prefix is retired too.
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

  update public.notifications
     set status = 'skipped', locked_at = null,
         error = 'test address — never sent'
   where status = 'queued'
     and channel = 'email'
     and (to_address ~* '@(example|test|invalid|localhost)\.(com|org|net|invalid)$'
          or to_address ~* '@example\.'
          or to_address ~* '^zz-');

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

revoke execute on function public.claim_notifications(int) from anon, authenticated;;
