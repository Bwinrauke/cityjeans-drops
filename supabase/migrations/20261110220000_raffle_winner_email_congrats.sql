-- The winner email opens with congratulations and asks winners to share it on
-- their story and tag the store. Only the raffle_won wording changes; the
-- returned keys ('code', 'name', ...) are untouched.
--
-- Also: a pickup window that runs over several days printed only the end
-- time ("Mon Nov 16, 10:00 AM – 08:00 PM" for a window ending Fri), so it read
-- as one day. The end now carries its date when it falls on a later day.
do $m$
declare v_def text; v_old text; v_new text;
begin
  v_def := pg_get_functiondef('public.render_notification(uuid)'::regprocedure);

  v_old := $o$'You were drawn for ' || rel.name || '.' || E'\n\n'$o$;
  v_new := $n$'CONGRATS!!! You were drawn for ' || rel.name || '.' || E'\n\n'$n$;
  if position(v_old in v_def) = 0 then
    raise exception 'raffle_won opening not found; render_notification has changed';
  end if;
  v_def := replace(v_def, v_old, v_new);

  v_old := $o$'released — and a won pair you don''t collect counts as a missed pickup.';$o$;
  v_new := $n$'released — and a won pair you don''t collect counts as a missed pickup.'
         || E'\n\n' || 'Please share it on your story and tag us @cityjeanspremium!!';$n$;
  if position(v_old in v_def) = 0 then
    raise exception 'raffle_won closing not found; render_notification has changed';
  end if;
  v_def := replace(v_def, v_old, v_new);

  v_old := $o$subj := 'You won — ' || rel.name;$o$;
  v_new := $n$subj := 'Congrats, you won! ' || rel.name;$n$;
  if position(v_old in v_def) = 0 then
    raise exception 'raffle_won subject not found; render_notification has changed';
  end if;
  v_def := replace(v_def, v_old, v_new);

  v_old := $o$then ' – ' || trim(to_char(rel.pickup_ends_at at time zone 'America/New_York', 'HH12:MI AM'))$o$;
  v_new := $n$then ' – ' || case
                when (rel.pickup_ends_at at time zone 'America/New_York')::date
                   = (rel.pickup_starts_at at time zone 'America/New_York')::date
                then trim(to_char(rel.pickup_ends_at at time zone 'America/New_York', 'HH12:MI AM'))
                else to_char(rel.pickup_ends_at at time zone 'America/New_York', 'Dy Mon DD')
                     || ', ' || trim(to_char(rel.pickup_ends_at at time zone 'America/New_York', 'HH12:MI AM'))
              end$n$;
  if position(v_old in v_def) = 0 then
    raise exception 'pickup window format not found; render_notification has changed';
  end if;
  v_def := replace(v_def, v_old, v_new);

  execute v_def;
end
$m$;
