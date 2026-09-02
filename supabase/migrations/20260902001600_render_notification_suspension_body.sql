-- render_notification as applied: the suspended template uses suspension_notice_body().
-- Reconstructed from the live schema, not the statement that was applied.
CREATE OR REPLACE FUNCTION public.render_notification(p_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  n public.notifications%rowtype; r public.reservations%rowtype;
  e public.raffle_entries%rowtype; rel public.releases%rowtype;
  s public.suspensions%rowtype;
  loc text; win text; scale text; subj text; body text; fname text; code text;
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

  scale := case rel.size_scale when 'womens' then 'Women''s ' when 'gs' then 'GS '
             when 'ps' then 'PS ' when 'td' then 'TD ' else 'US ' end;

  win := case when rel.pickup_starts_at is null then 'the pickup window'
    else to_char(rel.pickup_starts_at at time zone 'America/New_York', 'Dy Mon DD')
         || ', ' || trim(to_char(rel.pickup_starts_at at time zone 'America/New_York', 'HH12:MI AM'))
         || case when rel.pickup_ends_at is not null
              then ' – ' || trim(to_char(rel.pickup_ends_at at time zone 'America/New_York', 'HH12:MI AM'))
              else '' end end;

  if n.template = 'confirmation' then
    subj := 'You''re confirmed — ' || rel.name || ' (' || code || ')';
    body := 'Hi ' || fname || E',\n\n' || 'Your pair is reserved.' || E'\n\n'
         || rel.name || E'\n' || 'Size ' || scale || r.size || E'\n'
         || 'Pick up at ' || loc || E'\n' || 'Pickup window: ' || win || E'\n\n'
         || 'YOUR CODE: ' || code || E'\n\n'
         || 'Show this code at the register. ' || coalesce(rel.pickup_note, '') || E'\n\n'
         || 'Unclaimed pairs go back on the floor at the end of the window. '
         || 'Miss two in a row and you''re out for 90 days — if you can''t make '
         || 'it, reply to this email and we''ll cancel it, no penalty.';
  elsif n.template = 'entered' then
    subj := 'You''re entered — ' || rel.name;
    body := 'Hi ' || fname || E',\n\n' || 'Your raffle entry is in.' || E'\n\n'
         || rel.name || E'\n' || 'Size ' || scale || e.size || E'\n'
         || 'Pick up at ' || loc || ' if you win' || E'\n'
         || case when rel.closes_at is not null then 'Entries close '
              || to_char(rel.closes_at at time zone 'America/New_York', 'Dy Mon DD, HH12:MI AM')
              || E'\n' else '' end
         || E'\n' || 'YOUR CODE: ' || code || E'\n\n'
         || 'One entry per person. If you enter more than once — another email, '
         || 'the same phone — every one of your entries is disqualified.' || E'\n\n'
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
         || 'After that the pair goes back on the floor, and a second missed '
         || 'pickup in a row suspends you for 90 days.';
  elsif n.template = 'raffle_won' then
    subj := 'You won — ' || rel.name;
    body := 'Hi ' || fname || E',\n\n' || 'You were drawn for ' || rel.name || '.' || E'\n\n'
         || 'Size ' || scale || r.size || E'\n' || 'Pick up at ' || loc || E'\n'
         || 'Window: ' || win || E'\n\n' || 'YOUR CODE: ' || code || E'\n\n'
         || 'Bring the code to the register within the window or the pair is '
         || 'released — and a won pair you don''t collect counts as a missed pickup.';
  elsif n.template = 'raffle_lost' then
    subj := 'Not selected — ' || rel.name;
    body := 'Hi ' || fname || E',\n\n'
         || 'You weren''t drawn for ' || rel.name || ' this time.' || E'\n\n'
         || 'There were more entries than pairs. Every entry had the same chance — '
         || 'the draw is random and we keep a record of it.' || E'\n\n'
         || 'Thanks for entering. We''ll post the next drop soon.';
  elsif n.template = 'raffle_disqualified' then
    subj := 'Your entries were disqualified — ' || rel.name;
    body := 'Hi ' || fname || E',\n\n'
         || 'You weren''t included in the draw for ' || rel.name || '.' || E'\n\n'
         || 'More than one entry was made under your name, email or phone. '
         || 'The rule is one entry per person, and when someone enters twice '
         || 'every one of their entries comes out — otherwise entering twice '
         || 'would be worth doing.' || E'\n\n'
         || 'This is not a ban. Enter the next drop once and you''re in the '
         || 'draw like everyone else. If you think this is a mistake, reply to '
         || 'this email.';
  elsif n.template = 'suspended' then
    select * into s from public.suspensions
     where trigger_reservation_id = r.id order by created_at desc limit 1;
    subj := 'You''re paused for 90 days — City Jeans drops';
    body := public.suspension_notice_body(fname, coalesce(s.until, now() + interval '90 days'));
  else
    return null;
  end if;

  return jsonb_build_object('id', n.id, 'channel', n.channel, 'template', n.template,
    'to', case when n.channel = 'sms' then coalesce(r.phone_norm, e.phone_norm)
               else coalesce(r.email, e.email) end,
    'subject', subj, 'body', body);
end;
$function$
;
