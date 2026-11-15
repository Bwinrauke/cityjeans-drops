-- Winner email: the pickup window reads as a plain from/until sentence, and the
-- "pair is released" warning is gone.
do $m$
declare v_def text;
  v_old1 text := $t$         || 'Window: ' || win || E'\n\n' || 'YOUR CODE: ' || code || E'\n\n'
         || 'Show this email and your ID at the register within the window, or the pair is '
         || 'released — and a won pair you don''t collect counts as a missed pickup.'$t$;
  v_new1 text := $t$         || 'Pickup window: ' || coalesce(
              'from ' || trim(to_char(rel.pickup_starts_at at time zone 'America/New_York', 'FMDay, Mon FMDD'))
              || ' at ' || trim(to_char(rel.pickup_starts_at at time zone 'America/New_York', 'FMHH12:MI AM'))
              || coalesce(' until ' || trim(to_char(rel.pickup_ends_at at time zone 'America/New_York', 'FMDay, Mon FMDD'))
                 || ' at ' || trim(to_char(rel.pickup_ends_at at time zone 'America/New_York', 'FMHH12:MI AM')), ''),
              win) || E'\n\n' || 'YOUR CODE: ' || code || E'\n\n'
         || 'Show this email and your ID at the register when you pick up.'$t$;
begin
  v_def := pg_get_functiondef('public.render_notification(uuid)'::regprocedure);
  if position(v_old1 in v_def) = 0 then
    raise exception 'raffle_won wording not found; render_notification changed';
  end if;
  execute replace(v_def, v_old1, v_new1);
end
$m$;
