-- Before a draw, the manager can upload a list of people to keep out (known
-- resellers, people banned in store) and screen matching entries out. A
-- screened-out entry stays 'entered' until the draw, so nothing is emailed at
-- the moment it is flagged and the flag can be taken back. The draw passes over
-- it, and it ends up 'lost' with everyone else not picked, so the person gets
-- the ordinary "not selected" email.

alter table public.raffle_entries add column if not exists excluded_at timestamptz;
alter table public.raffle_entries add column if not exists excluded_reason text;
alter table public.raffle_entries add column if not exists excluded_by uuid;

create or replace function public.raffle_exclude_entries(
  p_release_id uuid, p_ids uuid[], p_reason text default null)
returns jsonb
language plpgsql security definer set search_path = public, pg_temp
as $$
declare v_n int;
begin
  if not public.is_manager() then
    return jsonb_build_object('ok', false, 'error', 'forbidden',
      'message', 'Only a manager or owner can screen out entries.');
  end if;
  if exists (select 1 from public.raffle_draws where release_id = p_release_id) then
    return jsonb_build_object('ok', false, 'error', 'already_drawn',
      'message', 'This raffle has already been drawn.');
  end if;
  update public.raffle_entries
     set excluded_at = now(), excluded_by = auth.uid(),
         excluded_reason = nullif(left(btrim(coalesce(p_reason, '')), 200), '')
   where release_id = p_release_id and status = 'entered'
     and excluded_at is null and id = any(coalesce(p_ids, '{}'));
  get diagnostics v_n = row_count;
  return jsonb_build_object('ok', true, 'excluded', v_n,
    'message', v_n || ' entr' || case when v_n = 1 then 'y' else 'ies' end
            || ' screened out. They stay out of the draw and get the '
            || 'ordinary "not selected" email afterwards.');
end;
$$;

create or replace function public.raffle_unexclude_entries(p_release_id uuid, p_ids uuid[])
returns jsonb
language plpgsql security definer set search_path = public, pg_temp
as $$
declare v_n int;
begin
  if not public.is_manager() then
    return jsonb_build_object('ok', false, 'error', 'forbidden',
      'message', 'Only a manager or owner can change this.');
  end if;
  if exists (select 1 from public.raffle_draws where release_id = p_release_id) then
    return jsonb_build_object('ok', false, 'error', 'already_drawn',
      'message', 'This raffle has already been drawn.');
  end if;
  update public.raffle_entries
     set excluded_at = null, excluded_by = null, excluded_reason = null
   where release_id = p_release_id and status = 'entered'
     and excluded_at is not null and id = any(coalesce(p_ids, '{}'));
  get diagnostics v_n = row_count;
  return jsonb_build_object('ok', true, 'restored', v_n,
    'message', v_n || ' entr' || case when v_n = 1 then 'y is' else 'ies are' end
            || ' back in the draw.');
end;
$$;

revoke execute on function public.raffle_exclude_entries(uuid, uuid[], text) from public, anon;
revoke execute on function public.raffle_unexclude_entries(uuid, uuid[]) from public, anon;
grant execute on function public.raffle_exclude_entries(uuid, uuid[], text) to authenticated;
grant execute on function public.raffle_unexclude_entries(uuid, uuid[]) to authenticated;

-- counts and odds leave screened-out entries out, the same way they leave out
-- duplicates
create or replace function public.raffle_stats(p_release_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp
as $$
declare v_res jsonb; v_dupes uuid[]; v_run text[];
begin
  if not public.is_admin() then
    return jsonb_build_object('ok', false, 'error', 'forbidden');
  end if;
  select coalesce(array_agg(id), '{}') into v_dupes
    from public.raffle_duplicate_entries(p_release_id);
  select public.size_run(size_scale) into v_run from public.releases where id = p_release_id;

  select jsonb_build_object(
    'ok', true,
    'total', (select count(*) from public.raffle_entries
               where release_id = p_release_id and status = 'entered'
                 and excluded_at is null and not (id = any(v_dupes))),
    'duplicates', cardinality(v_dupes),
    'duplicate_people', (select count(distinct email_norm) from public.raffle_entries
                          where id = any(v_dupes)),
    'excluded', (select count(*) from public.raffle_entries
                  where release_id = p_release_id and excluded_at is not null
                    and status = 'entered' and not (id = any(v_dupes))),
    'excluded_ever', (select count(*) from public.raffle_entries
                       where release_id = p_release_id and excluded_at is not null),
    'drawn', exists (select 1 from public.raffle_draws where release_id = p_release_id),
    'draw', (select to_jsonb(d) from public.raffle_draws d where d.release_id = p_release_id),
    'disqualified', (select count(*) from public.raffle_entries
                      where release_id = p_release_id and status = 'disqualified'),
    'buckets', coalesce((
      select jsonb_agg(jsonb_build_object(
               'size', z.size, 'entries', coalesce(x.entries, 0),
               'pairs', coalesce(s.pairs, 0), 'stores', coalesce(s.stores, '[]'::jsonb))
             order by coalesce(array_position(v_run, z.size), 1000 + coalesce(s.size_order, 0)), z.size)
      from (select size from public.raffle_entries where release_id = p_release_id
            union
            select size from public.release_inventory
             where release_id = p_release_id and quantity_total > 0) z
      left join (select i.size, min(i.size_order) as size_order,
                        sum(i.quantity_total)::int as pairs,
                        coalesce(jsonb_agg(jsonb_build_object('location', l.name,
                                   'pairs', i.quantity_total) order by l.sort_order)
                                 filter (where i.quantity_total > 0), '[]'::jsonb) as stores
                   from public.release_inventory i
                   join public.locations l on l.id = i.location_id
                  where i.release_id = p_release_id
                  group by i.size) s on s.size = z.size
      left join (select size, count(*) as entries
                   from public.raffle_entries
                  where release_id = p_release_id and status = 'entered'
                    and excluded_at is null and not (id = any(v_dupes))
                  group by size) x on x.size = z.size
    ), '[]'::jsonb))
  into v_res;
  return v_res;
end;
$$;

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
  v_excl    int := 0;
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

  -- entries the manager screened out before the draw are passed over
  select count(*) into v_excl from public.raffle_entries
   where release_id = p_release_id and status = 'entered' and excluded_at is not null;

  select count(*) into v_total from public.raffle_entries
   where release_id = p_release_id and status = 'entered' and excluded_at is null;
  if v_total = 0 then
    delete from public.raffle_draws where id = v_draw_id;
    update public.raffle_entries set status = 'entered', drawn_at = null, draw_id = null
     where release_id = p_release_id and status = 'disqualified' and draw_id = v_draw_id;
    return jsonb_build_object('ok', false, 'error', 'no_entries',
      'message', case when v_dq > 0 or v_excl > 0
        then 'Every entry is a duplicate or screened out — there is nobody left to draw.'
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
         and e.excluded_at is null
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

  -- everyone else, screened-out entries included: they get "not selected"
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
                                     and e.status <> 'disqualified'
                                     and e.excluded_at is null))
                    order by l.sort_order, i.size)
                    from public.release_inventory i
                    join public.locations l on l.id = i.location_id
                   where i.release_id = p_release_id and i.quantity_total > 0)
   where id = v_draw_id;

  update public.releases set status = 'closed' where id = p_release_id;

  return jsonb_build_object('ok', true, 'draw_id', v_draw_id, 'seed', v_seed,
    'entries', v_total, 'winners', v_win, 'losers', v_lost, 'disqualified', v_dq,
    'excluded', v_excl,
    'message', v_win || ' winner' || case when v_win = 1 then '' else 's' end ||
               ' drawn from ' || v_total || ' entries. ' ||
               v_lost || ' not selected' ||
               case when v_excl > 0
                 then ' (including ' || v_excl || ' screened out)' else '' end ||
               case when v_dq > 0
                 then ', and ' || v_dq || ' disqualified for multiple entries'
                 else '' end ||
               ' — all of them will be emailed.');
end;
$$;
