-- REGRESSION FIX. render_notification used to return 'code' and 'name'
-- alongside subject/body. Rewriting it to add the suspension and
-- disqualification templates dropped those two keys, and the sender does
--     html(m.body, m.code)  ->  esc(code)  ->  code.replace(...)
-- so every email since has died with "Cannot read properties of undefined
-- (reading 'replace')" and burned all five retries. No customer confirmation
-- has gone out since. Put the keys back rather than change the sender, because
-- the SMS path needs m.code too.
do $do$
declare v_def text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'render_notification';

  if position('''code'', code' in v_def) > 0 then
    raise notice 'already returns code; nothing to do';
    return;
  end if;

  v_def := replace(v_def,
    '''subject'', subj, ''body'', body);',
    '''subject'', subj, ''body'', body, ''code'', code,'
    || chr(10) ||
    '    ''name'', coalesce(r.first_name || '' '' || r.last_name, e.first_name || '' '' || e.last_name));');

  execute v_def;
end $do$;
