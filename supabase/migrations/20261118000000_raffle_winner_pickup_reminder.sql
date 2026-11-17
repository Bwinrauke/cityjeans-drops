-- One-off pickup reminder for the UGG Sunburst Dusted Cocoa raffle winners,
-- sent Wed Nov 18 at 1:30 PM ET. Adds a 'raffle_pickup_reminder' template to
-- render_notification (the 'code' and 'name' keys are untouched) and queues
-- one email per winner. claim_notifications only sends while the reservation
-- is still 'confirmed', so anyone marked picked up by then is skipped.
do $m$
declare v_def text;
  v_anchor text := $t$  elsif n.template = 'raffle_lost' then$t$;
  v_new text := $t$  elsif n.template = 'raffle_pickup_reminder' then
    subj := 'Reminder: pick up your ' || rel.name || coalesce(' by ' ||
              trim(to_char(rel.pickup_ends_at at time zone 'America/New_York', 'FMDay FMHH12 AM')), '');
    body := 'Hi ' || fname || E',\n\n'
         || 'Just a reminder that your ' || rel.name || ' is waiting for you at ' || loc || '.' || E'\n\n'
         || 'Size ' || scale || r.size || E'\n'
         || coalesce('Directions: ' || public.store_maps_url(r.location_id) || E'\n', '')
         || coalesce('Pick up any time until '
              || trim(to_char(rel.pickup_ends_at at time zone 'America/New_York', 'FMDay, Mon FMDD'))
              || ' at ' || trim(to_char(rel.pickup_ends_at at time zone 'America/New_York', 'FMHH12:MI AM')) || '.',
              'Pickup window: ' || win)
         || E'\n\n' || 'YOUR CODE: ' || code || E'\n\n'
         || 'Show this email and your ID at the register when you pick up. This is a final '
         || 'sale item, and you can only buy it at your assigned store in the size you won.'
         || E'\n\n' || 'Already picked up? Thank you, you can ignore this email.';
$t$;
begin
  v_def := pg_get_functiondef('public.render_notification(uuid)'::regprocedure);
  if position('raffle_pickup_reminder' in v_def) = 0 then
    if position(v_anchor in v_def) = 0 then
      raise exception 'raffle_lost branch not found; render_notification changed';
    end if;
    execute replace(v_def, v_anchor, v_new || v_anchor);
  end if;
end
$m$;

insert into public.notifications (reservation_id, channel, template, to_address, payload, send_after)
select x.id, 'email', 'raffle_pickup_reminder', x.email,
       jsonb_build_object('code', x.code, 'release', rel.name),
       timestamptz '2026-11-18 13:30:00 America/New_York'
  from public.raffle_entries e
  join public.reservations x on x.id = e.reservation_id
  join public.releases rel on rel.id = e.release_id
 where rel.slug = 'ugg-sunburst-dusted-cocoa-city-jeans-exclusive'
   and e.status = 'won'
   and x.status = 'confirmed'
   and not exists (select 1 from public.notifications n
                    where n.reservation_id = x.id and n.template = 'raffle_pickup_reminder');
