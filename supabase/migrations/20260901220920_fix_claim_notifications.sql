-- RETURNING ... INTO only accepts a single row; collect the batch with a CTE.
create or replace function public.claim_notifications(p_limit int default 25)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare v_ids uuid[];
begin
  with picked as (
    select id from public.notifications
     where status = 'queued'
       and send_after <= now()
       and attempts < 5
       and (locked_at is null or locked_at < now() - interval '5 minutes')
     order by send_after
     limit p_limit
     for update skip locked
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
