-- UGG Sunburst Dusted Cocoa raffle: pickup extended from Fri Nov 20 8 PM to
-- Sat Nov 21 8 PM ET, and every winner is emailed Fri Nov 20 at 6 PM ET (moved from 10 AM at Ben's request).
-- Adds the 'raffle_pickup_extended' template to render_notification (the
-- 'code' and 'name' keys are untouched). The nightly no-show sweep was paused
-- for all drops on 2026-11-19 (cron.alter_job active=false) at Ben's choice.
do $m$
declare v_def text;
  v_anchor text := $t$  elsif n.template = 'raffle_lost' then$t$;
  v_new text := $t$  elsif n.template = 'raffle_pickup_extended' then
    subj := 'Pickup extended to ' || coalesce(
              trim(to_char(rel.pickup_ends_at at time zone 'America/New_York', 'FMDay FMHH12 AM')) || ': ', '')
         || rel.name;
    body := 'Hi ' || fname || E',\n\n'
         || 'We heard your concerns, and we''re happy to extend the pickup window for your '
         || rel.name || '.' || E'\n\n'
         || 'You can now pick up your pair until '
         || coalesce(trim(to_char(rel.pickup_ends_at at time zone 'America/New_York', 'FMDay, Mon FMDD'))
              || ' at ' || trim(to_char(rel.pickup_ends_at at time zone 'America/New_York', 'FMHH12:MI AM')),
              'the end of the pickup window')
         || ' at ' || loc || '.' || E'\n\n'
         || 'Size ' || scale || r.size || E'\n'
         || coalesce('Directions: ' || public.store_maps_url(r.location_id) || E'\n', '')
         || E'\n' || 'YOUR CODE: ' || code || E'\n\n'
         || 'Show this email and your ID at the register. Any pairs not picked up by '
         || coalesce(trim(to_char(rel.pickup_ends_at at time zone 'America/New_York', 'FMDay')) || ' at '
              || trim(to_char(rel.pickup_ends_at at time zone 'America/New_York', 'FMHH12 AM')), 'then')
         || ' will be opened to the public on Sunday morning.'
         || E'\n\n' || 'Already got your pair? Don''t forget to post it and tag us @cityjeanspremium!';
$t$;
begin
  v_def := pg_get_functiondef('public.render_notification(uuid)'::regprocedure);
  if position('raffle_pickup_extended' in v_def) = 0 then
    if position(v_anchor in v_def) = 0 then
      raise exception 'raffle_lost branch not found; render_notification changed';
    end if;
    execute replace(v_def, v_anchor, v_new || v_anchor);
  end if;
end
$m$;

update public.releases
   set pickup_ends_at = timestamptz '2026-11-21 20:00:00 America/New_York'
 where slug = 'ugg-sunburst-dusted-cocoa-city-jeans-exclusive';

insert into public.notifications (reservation_id, channel, template, to_address, payload, send_after)
select x.id, 'email', 'raffle_pickup_extended', x.email,
       jsonb_build_object('code', x.code, 'release', rel.name),
       timestamptz '2026-11-20 18:00:00 America/New_York'
  from public.raffle_entries e
  join public.reservations x on x.id = e.reservation_id
  join public.releases rel on rel.id = e.release_id
 where rel.slug = 'ugg-sunburst-dusted-cocoa-city-jeans-exclusive'
   and e.status = 'won'
   and x.status = 'confirmed'
   and not exists (select 1 from public.notifications n
                    where n.reservation_id = x.id and n.template = 'raffle_pickup_extended');
