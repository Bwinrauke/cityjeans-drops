-- Winners show this email and their ID at the register.
do $m$
declare v_def text;
  v_old text := $t$         || 'Bring the code to the register within the window or the pair is '
         || 'released — and a won pair you don''t collect counts as a missed pickup.'$t$;
  v_new text := $t$         || 'Show this email and your ID at the register within the window, or the pair is '
         || 'released — and a won pair you don''t collect counts as a missed pickup.'$t$;
begin
  v_def := pg_get_functiondef('public.render_notification(uuid)'::regprocedure);
  if position(v_old in v_def) = 0 then
    raise exception 'raffle_won wording not found; render_notification changed';
  end if;
  execute replace(v_def, v_old, v_new);
end
$m$;
