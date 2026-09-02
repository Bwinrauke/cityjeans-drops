-- The rules live in the database, not in the page, for two reasons: changing
-- them is a decision, not a deploy — and an entry records which version the
-- person actually agreed to, which is the only version that can be quoted back
-- at them if they argue.
create table if not exists public.raffle_rules (
  version     int primary key,
  body        text not null,
  created_at  timestamptz not null default now(),
  created_by  uuid references auth.users(id)
);

alter table public.raffle_rules enable row level security;

drop policy if exists raffle_rules_read on public.raffle_rules;
create policy raffle_rules_read on public.raffle_rules
  for select to anon, authenticated using (true);

insert into public.raffle_rules (version, body)
select 1, $rules$1. By submitting this form you agree to receive messaging from us including, but not limited to, raffle notifications and promotions.
2. Follow the official City Jeans Instagram account @cityjeanspremium
3. Pick-up time for winners is from 10AM to 2PM ONLY, unless otherwise stated
4. We DO NOT change sizes!
5. We DO NOT call our customers — please watch out for frauds!
6. We DO NOT hold sneakers after the official pick-up time is over.
7. We DO NOT request payment information at any time other than during pick-up.
8. ONLY 1 ENTRY PER PERSON!! Multiple entries will result in an AUTOMATIC DISQUALIFICATION.$rules$
where not exists (select 1 from public.raffle_rules);

-- The current rules, and the version number an entry will be stamped with.
create or replace function public.current_raffle_rules()
returns jsonb
language sql stable security definer set search_path = public, pg_temp
as $$
  select jsonb_build_object('version', r.version, 'body', r.body,
                            'updated_at', r.created_at)
    from public.raffle_rules r order by r.version desc limit 1;
$$;

grant execute on function public.current_raffle_rules() to anon, authenticated;

-- Editing publishes a new version rather than overwriting the old one, so an
-- entry from last month still points at the text that was on screen then.
create or replace function public.save_raffle_rules(p_body text)
returns jsonb
language plpgsql security definer set search_path = public, pg_temp
as $$
declare v_next int; v_cur text;
begin
  if not public.is_manager() then
    return jsonb_build_object('ok', false, 'error', 'forbidden',
      'message', 'Only a manager or owner can change the raffle rules.');
  end if;
  if btrim(coalesce(p_body, '')) = '' then
    return jsonb_build_object('ok', false, 'error', 'empty',
      'message', 'The rules cannot be empty.');
  end if;

  select body into v_cur from public.raffle_rules order by version desc limit 1;
  if btrim(v_cur) = btrim(p_body) then
    return jsonb_build_object('ok', true, 'unchanged', true,
      'message', 'No change — the rules are already this.');
  end if;

  select coalesce(max(version), 0) + 1 into v_next from public.raffle_rules;
  insert into public.raffle_rules (version, body, created_by)
  values (v_next, btrim(p_body), auth.uid());

  return jsonb_build_object('ok', true, 'version', v_next,
    'message', 'Saved as version ' || v_next
      || '. Entries from now on record that they agreed to this one.');
end;
$$;

revoke execute on function public.save_raffle_rules(text) from anon;
grant execute on function public.save_raffle_rules(text) to authenticated;

-- what each entrant agreed to
alter table public.raffle_entries
  add column if not exists rules_version int,
  add column if not exists rules_accepted_at timestamptz;
