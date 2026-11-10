-- Raffle entries now carry an Instagram handle, so staff can screen out
-- resellers before the draw, and no longer carry a store. Customers enter with
-- their details and a size; the manager decides afterwards how many pairs each
-- store gets, and the draw sends each winner to one of those stores. The
-- customer first sees their store in the winner email.

alter table public.raffle_entries add column if not exists instagram text;
alter table public.raffle_entries alter column location_id drop not null;
create index if not exists raffle_entries_ig_idx
  on public.raffle_entries (release_id, instagram);

-- "@Name", "name", "instagram.com/name/" all become "name"
create or replace function public.norm_instagram(p text)
returns text language sql immutable set search_path = public, pg_temp as $$
  select lower(regexp_replace(regexp_replace(btrim(coalesce(p, '')),
           '^(https?://)?(www\.)?instagram\.com/', '', 'i'), '^@+|[/?].*$', '', 'g'))
$$;
revoke execute on function public.norm_instagram(text) from public, anon, authenticated;

-- one person, one entry: the same Instagram handle counts as the same person,
-- just as the same email or phone does
create or replace function public.raffle_duplicate_entries(p_release_id uuid)
returns table(id uuid)
language sql stable security definer set search_path = public, pg_temp
as $$
  select e.id
    from public.raffle_entries e
   where e.release_id = p_release_id
     and e.status = 'entered'
     and exists (
       select 1 from public.raffle_entries o
        where o.release_id = e.release_id
          and o.id <> e.id
          and o.status = 'entered'
          and (o.email_norm = e.email_norm or o.phone_norm = e.phone_norm
               or (o.instagram is not null and o.instagram = e.instagram)));
$$;

drop function if exists public.raffle_entry_count(uuid, text, text);
create function public.raffle_entry_count(p_release_id uuid, p_email_norm text,
                                          p_phone_norm text, p_instagram text default null)
returns integer
language sql stable security definer set search_path = public, pg_temp
as $$
  select count(*)::int from public.raffle_entries
   where release_id = p_release_id
     and status in ('entered','won')
     and (email_norm = p_email_norm or phone_norm = p_phone_norm
          or (p_instagram is not null and instagram = p_instagram));
$$;
revoke execute on function public.raffle_entry_count(uuid, text, text, text)
  from public, anon, authenticated;

-- the store is no longer known when someone enters
create or replace function public.entered_email_body(p_fname text, p_release text,
  p_size text, p_loc text, p_closes timestamptz, p_code text)
returns text
language sql stable set search_path = public, pg_temp
as $$
  select 'Hi ' || p_fname || E',\n\n'
      || 'Your raffle entry is in.' || E'\n\n'
      || p_release || E'\n' || 'Size ' || p_size || E'\n'
      || case when p_loc is not null then 'Pick up at ' || p_loc || ' if you win'
              else 'If you win, we''ll email you the store and your pickup code' end || E'\n'
      || case when p_closes is not null then 'Entries close '
           || to_char(p_closes at time zone 'America/New_York', 'Dy Mon DD, HH12:MI AM')
           || E'\n' else '' end
      || E'\n' || 'YOUR CODE: ' || p_code || E'\n\n'
      || 'RESULTS COME BY EMAIL, NOT TEXT.' || E'\n'
      || 'This is a new system. We email everyone after the draw, win or lose, '
      || 'at this address. Add us to your contacts so it does not land in spam. '
      || 'We will not text you about the raffle, and we will not call you.' || E'\n\n'
      || 'One entry per person. If you enter more than once — another email, '
      || 'the same phone, the same Instagram — every one of your entries is disqualified.' || E'\n\n'
      || 'You don''t need to check back.';
$$;

drop function if exists public.enter_raffle(text, uuid, text, text, text, text, text, boolean);
create function public.enter_raffle(
  p_release_slug text, p_size text, p_first_name text, p_last_name text,
  p_email text, p_phone text, p_instagram text default null,
  p_agree boolean default false, p_location_id uuid default null)
returns jsonb
language plpgsql security definer set search_path = public, pg_temp
as $$
declare
  v_rel public.releases%rowtype;
  v_email text := public.norm_email(p_email);
  v_phone text := public.norm_phone(p_phone);
  v_ig text := public.norm_instagram(p_instagram);
  v_e public.raffle_entries%rowtype; v_code text;
  v_try int := 0; v_held int; v_susp public.suspensions%rowtype;
  v_rules int;
begin
  -- p_location_id is accepted and ignored, so a page cached from before this
  -- change still gets an answer rather than "function not found"
  if btrim(coalesce(p_first_name,'')) = '' or btrim(coalesce(p_last_name,'')) = '' then
    return jsonb_build_object('ok', false, 'error', 'missing_name',
      'message', 'Please enter your first and last name.');
  end if;
  if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    return jsonb_build_object('ok', false, 'error', 'bad_email',
      'message', 'Please enter a valid email address.');
  end if;
  if length(v_phone) <> 10 then
    return jsonb_build_object('ok', false, 'error', 'bad_phone',
      'message', 'Please enter a valid 10-digit US phone number.');
  end if;
  if v_ig !~ '^[a-z0-9._]{1,30}$' then
    return jsonb_build_object('ok', false, 'error', 'bad_instagram',
      'message', 'Please enter your Instagram handle, like @cityjeans.');
  end if;
  if p_agree is not true then
    return jsonb_build_object('ok', false, 'error', 'rules_not_accepted',
      'message', 'Please read the raffle rules and tick the box to enter.');
  end if;

  v_susp := public.active_suspension(v_email, v_phone);
  if v_susp.id is not null then
    return jsonb_build_object('ok', false, 'error', 'suspended',
      'until', v_susp.until, 'eligible_again', public.eligible_again(v_susp.until),
      'message', public.suspension_message(v_susp.until, 'Entries'));
  end if;

  select * into v_rel from public.releases where slug = p_release_slug;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'not_found',
      'message', 'This release could not be found.');
  end if;
  if v_rel.mode <> 'raffle' then
    return jsonb_build_object('ok', false, 'error', 'not_a_raffle',
      'message', 'This release is first come, first served.');
  end if;
  if v_rel.status <> 'open' then
    return jsonb_build_object('ok', false, 'error', 'closed',
      'message', 'Entries for this raffle are closed.');
  end if;
  if v_rel.opens_at is not null and now() < v_rel.opens_at then
    return jsonb_build_object('ok', false, 'error', 'not_yet_open',
      'message', 'Entries have not opened yet.');
  end if;
  if v_rel.closes_at is not null and now() > v_rel.closes_at then
    return jsonb_build_object('ok', false, 'error', 'closed',
      'message', 'Entries for this raffle have closed.');
  end if;
  if exists (select 1 from public.raffle_draws d where d.release_id = v_rel.id) then
    return jsonb_build_object('ok', false, 'error', 'drawn',
      'message', 'This raffle has already been drawn.');
  end if;
  if not exists (select 1 from public.release_inventory i
                  where i.release_id = v_rel.id and i.size = p_size) then
    return jsonb_build_object('ok', false, 'error', 'bad_size',
      'message', 'That size is not part of this release.');
  end if;

  v_held := public.raffle_entry_count(v_rel.id, v_email, v_phone, v_ig);
  if v_held >= 10 then
    return jsonb_build_object('ok', false, 'error', 'too_many',
      'message', 'You already hold ' || v_held || ' entries for this release. '
              || 'Only one per person counts, and every one of these will be '
              || 'passed over at the draw. Email us to sort it out.');
  end if;

  select version into v_rules from public.raffle_rules order by version desc limit 1;

  loop
    v_try := v_try + 1;
    v_code := replace(public.gen_code(), 'CJ-', 'RF-');
    begin
      insert into public.raffle_entries
        (release_id, location_id, size, first_name, last_name,
         email, email_norm, phone, phone_norm, instagram, code,
         rules_version, rules_accepted_at)
      values (v_rel.id, null, p_size,
              btrim(p_first_name), btrim(p_last_name),
              btrim(p_email), v_email, btrim(p_phone), v_phone, v_ig, v_code,
              v_rules, now())
      returning * into v_e;
      exit;
    exception when unique_violation then
      if v_try < 8 then continue; end if;
      raise;
    end;
  end loop;

  return jsonb_build_object('ok', true, 'code', v_e.code,
    'entries_held', v_held + 1,
    'duplicate', v_held > 0,
    'rules_version', v_rules,
    'duplicate_message', case when v_held > 0 then
      'Heads up: this is entry number ' || (v_held + 1) || ' under your name, '
      || 'email, phone or Instagram. Rule 8 is one entry per person, and multiple '
      || 'entries are an automatic disqualification — all of them. Reply to your '
      || 'confirmation email before entries close and we''ll keep just one.'
      else null end,
    'entry', jsonb_build_object(
      'code', v_e.code, 'first_name', v_e.first_name, 'last_name', v_e.last_name,
      'email', v_e.email, 'phone', v_e.phone, 'instagram', v_e.instagram,
      'size', v_e.size, 'size_scale', v_rel.size_scale, 'location', null,
      'release', v_rel.name, 'photo_url', v_rel.photo_url,
      'retail_price', v_rel.retail_price, 'closes_at', v_rel.closes_at,
      'pickup_starts_at', v_rel.pickup_starts_at, 'pickup_ends_at', v_rel.pickup_ends_at,
      'status', 'entered', 'created_at', v_e.created_at));
end;
$$;
revoke execute on function public.enter_raffle(text, text, text, text, text, text, text, boolean, uuid) from public;
grant execute on function public.enter_raffle(text, text, text, text, text, text, text, boolean, uuid)
  to anon, authenticated;

create or replace function public.lookup_entry(p_code text, p_email text)
returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp
as $$
declare
  v_e public.raffle_entries%rowtype; v_rel public.releases%rowtype; v_loc text;
begin
  select * into v_e from public.raffle_entries
   where upper(btrim(code)) = upper(btrim(p_code))
     and email_norm = public.norm_email(p_email);
  if not found then
    return jsonb_build_object('ok', false, 'error', 'not_found',
      'message', 'No entry found for that code and email.');
  end if;

  -- a winner's entry points at a real reservation; show that instead
  if v_e.status = 'won' and v_e.reservation_id is not null then
    return (select public.lookup_reservation(r.code, r.email)
            from public.reservations r where r.id = v_e.reservation_id);
  end if;

  select * into v_rel from public.releases where id = v_e.release_id;
  select name into v_loc from public.locations where id = v_e.location_id;
  return jsonb_build_object('ok', true, 'is_entry', true, 'entry', jsonb_build_object(
    'code', v_e.code, 'first_name', v_e.first_name, 'last_name', v_e.last_name,
    'email', v_e.email, 'phone', v_e.phone, 'instagram', v_e.instagram,
    'size', v_e.size, 'size_scale', v_rel.size_scale, 'location', v_loc,
    'release', v_rel.name, 'photo_url', v_rel.photo_url, 'retail_price', v_rel.retail_price,
    'closes_at', v_rel.closes_at, 'status', v_e.status,
    'pickup_starts_at', v_rel.pickup_starts_at, 'pickup_ends_at', v_rel.pickup_ends_at,
    'created_at', v_e.created_at));
end;
$$;

-- demand is per size now; pairs are the sum across stores, with the split
-- alongside so the manager can see where winners will be sent
create or replace function public.raffle_stats(p_release_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp
as $$
declare v_res jsonb; v_dupes uuid[];
begin
  if not public.is_admin() then
    return jsonb_build_object('ok', false, 'error', 'forbidden');
  end if;

  select coalesce(array_agg(id), '{}') into v_dupes
    from public.raffle_duplicate_entries(p_release_id);

  select jsonb_build_object(
    'ok', true,
    'total', (select count(*) from public.raffle_entries
               where release_id = p_release_id and status = 'entered'
                 and not (id = any(v_dupes))),
    'duplicates', cardinality(v_dupes),
    'duplicate_people', (select count(distinct email_norm) from public.raffle_entries
                          where id = any(v_dupes)),
    'drawn', exists (select 1 from public.raffle_draws where release_id = p_release_id),
    'draw', (select to_jsonb(d) from public.raffle_draws d where d.release_id = p_release_id),
    'disqualified', (select count(*) from public.raffle_entries
                      where release_id = p_release_id and status = 'disqualified'),
    'buckets', coalesce((
      select jsonb_agg(jsonb_build_object(
               'size', s.size, 'entries', coalesce(x.entries, 0),
               'pairs', s.pairs, 'stores', s.stores)
             order by s.size_order, s.size)
      from (select i.size, min(i.size_order) as size_order,
                   sum(i.quantity_total)::int as pairs,
                   coalesce(jsonb_agg(jsonb_build_object('location', l.name,
                              'pairs', i.quantity_total) order by l.sort_order)
                            filter (where i.quantity_total > 0), '[]'::jsonb) as stores
              from public.release_inventory i
              join public.locations l on l.id = i.location_id
             where i.release_id = p_release_id
             group by i.size) s
      left join (select size, count(*) as entries
                   from public.raffle_entries
                  where release_id = p_release_id and status = 'entered'
                    and not (id = any(v_dupes))
                  group by size) x on x.size = s.size
    ), '[]'::jsonb))
  into v_res;
  return v_res;
end;
$$;

-- Winners are drawn per size, from everyone who entered that size, up to the
-- pairs loaded for it across all stores. The k-th winner of a size takes the
-- k-th pair of that size, with pairs laid out store by store, so each store
-- gets exactly the number loaded for it. Winner order is random, so which
-- winner lands at which store is random too.
create or replace function public.run_raffle_draw(p_release_id uuid)
returns jsonb
language plpgsql security definer set search_path = public, extensions, pg_temp
as $$
declare
  v_rel     public.releases%rowtype;
  v_seed    text;
  v_draw_id uuid;
  v_win     int := 0;
  v_lost    int := 0;
  v_dq      int := 0;
  v_total   int := 0;
  v_pairs   int := 0;
  v_code    text;
  w         record;
  v_res_id  uuid;
  v_try     int;
begin
  if not public.is_manager() then
    return jsonb_build_object('ok', false, 'error', 'forbidden',
      'message', 'Only a manager or owner can run a draw.');
  end if;

  select * into v_rel from public.releases where id = p_release_id for update;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;
  if v_rel.mode <> 'raffle' then
    return jsonb_build_object('ok', false, 'error', 'not_a_raffle',
      'message', 'This release is first come, first served.');
  end if;
  if exists (select 1 from public.raffle_draws where release_id = p_release_id) then
    return jsonb_build_object('ok', false, 'error', 'already_drawn',
      'message', 'This raffle has already been drawn.');
  end if;
  if v_rel.closes_at is not null and now() < v_rel.closes_at then
    return jsonb_build_object('ok', false, 'error', 'still_open',
      'message', 'Entries are still open. Close them before drawing.');
  end if;

  select coalesce(sum(quantity_total), 0) into v_pairs
    from public.release_inventory where release_id = p_release_id;
  if v_pairs = 0 then
    return jsonb_build_object('ok', false, 'error', 'no_pairs',
      'message', 'Load the quantity for each size and store before drawing.');
  end if;

  v_seed := encode(gen_random_bytes(32), 'hex');

  insert into public.raffle_draws (release_id, ran_by, seed, entries)
  values (p_release_id, auth.uid(), v_seed, 0)
  returning id into v_draw_id;

  -- one person, one entry: every entry of anyone holding more than one is out
  update public.raffle_entries e
     set status = 'disqualified', drawn_at = now(), draw_id = v_draw_id
   where e.id in (select id from public.raffle_duplicate_entries(p_release_id));
  get diagnostics v_dq = row_count;

  select count(*) into v_total from public.raffle_entries
   where release_id = p_release_id and status = 'entered';
  if v_total = 0 then
    delete from public.raffle_draws where id = v_draw_id;
    update public.raffle_entries set status = 'entered', drawn_at = null, draw_id = null
     where release_id = p_release_id and status = 'disqualified' and draw_id = v_draw_id;
    return jsonb_build_object('ok', false, 'error', 'no_entries',
      'message', case when v_dq > 0
        then 'Every entry is a duplicate — there is nobody left to draw.'
        else 'There are no entries to draw.' end);
  end if;
  update public.raffle_draws set entries = v_total where id = v_draw_id;

  for w in
    with slots as (
      select i.location_id, i.size,
             row_number() over (partition by i.size
                                order by l.sort_order, l.name, g.n) as k
        from public.release_inventory i
        join public.locations l on l.id = i.location_id
        cross join lateral generate_series(1, i.quantity_total) g(n)
       where i.release_id = p_release_id and i.quantity_total > 0
    ), ranked as (
      select e.id, e.size,
             row_number() over (partition by e.size
                                order by digest(e.id::text || v_seed, 'sha256')) as k
        from public.raffle_entries e
       where e.release_id = p_release_id and e.status = 'entered'
    )
    select r.id, s.location_id, r.size
      from ranked r join slots s on s.size = r.size and s.k = r.k
  loop
    -- a winner becomes an ordinary reservation, with the same code format and
    -- the same register flow as a first-come drop
    v_try := 0;
    loop
      v_try := v_try + 1;
      v_code := public.gen_code();
      begin
        insert into public.reservations
          (code, release_id, location_id, size, first_name, last_name,
           email, email_norm, phone, phone_norm, source)
        select v_code, e.release_id, w.location_id, e.size, e.first_name, e.last_name,
               e.email, e.email_norm, e.phone, e.phone_norm, 'raffle'
          from public.raffle_entries e where e.id = w.id
        returning id into v_res_id;
        exit;
      exception when unique_violation then
        if v_try < 8 then continue; end if;
        raise;
      end;
    end loop;

    update public.raffle_entries
       set status = 'won', reservation_id = v_res_id, location_id = w.location_id,
           drawn_at = now(), draw_id = v_draw_id
     where id = w.id;

    insert into public.notifications (reservation_id, channel, template, to_address)
    values (v_res_id, 'email', 'raffle_won',
            (select email from public.reservations where id = v_res_id))
    on conflict (reservation_id, channel, template) do nothing;

    v_win := v_win + 1;
  end loop;

  -- everyone else
  update public.raffle_entries
     set status = 'lost', drawn_at = now(), draw_id = v_draw_id
   where release_id = p_release_id and status = 'entered';
  get diagnostics v_lost = row_count;

  -- counters reflect the reservations the draw just created
  update public.release_inventory i
     set quantity_reserved = coalesce((
       select count(*) from public.reservations r
        where r.release_id = i.release_id and r.location_id = i.location_id
          and r.size = i.size and r.status in ('confirmed','picked_up')), 0)
   where i.release_id = p_release_id;

  update public.raffle_draws
     set winners = v_win, losers = v_lost,
         buckets = (select jsonb_agg(jsonb_build_object(
                      'location', l.name, 'size', i.size,
                      'pairs', i.quantity_total,
                      'winners', (select count(*) from public.raffle_entries e
                                   where e.release_id = p_release_id
                                     and e.location_id = i.location_id
                                     and e.size = i.size and e.status = 'won'),
                      'entries', (select count(*) from public.raffle_entries e
                                   where e.release_id = p_release_id
                                     and e.size = i.size
                                     and e.status <> 'disqualified'))
                    order by l.sort_order, i.size)
                    from public.release_inventory i
                    join public.locations l on l.id = i.location_id
                   where i.release_id = p_release_id and i.quantity_total > 0)
   where id = v_draw_id;

  update public.releases set status = 'closed' where id = p_release_id;

  return jsonb_build_object('ok', true, 'draw_id', v_draw_id, 'seed', v_seed,
    'entries', v_total, 'winners', v_win, 'losers', v_lost, 'disqualified', v_dq,
    'message', v_win || ' winner' || case when v_win = 1 then '' else 's' end ||
               ' drawn from ' || v_total || ' entries. ' ||
               v_lost || ' not selected' ||
               case when v_dq > 0
                 then ', and ' || v_dq || ' disqualified for multiple entries'
                 else '' end ||
               ' — all of them will be emailed.');
end;
$$;
