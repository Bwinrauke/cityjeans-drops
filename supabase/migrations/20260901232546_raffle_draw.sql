-- ------------------------------------------------------------
-- Demand per size per store — what you allocate against.
-- ------------------------------------------------------------
create or replace function public.raffle_stats(p_release_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp
as $$
declare v_res jsonb;
begin
  if not public.is_admin() then
    return jsonb_build_object('ok', false, 'error', 'forbidden');
  end if;
  select jsonb_build_object(
    'ok', true,
    'total', (select count(*) from public.raffle_entries
               where release_id = p_release_id and status = 'entered'),
    'drawn', exists (select 1 from public.raffle_draws where release_id = p_release_id),
    'draw', (select to_jsonb(d) from public.raffle_draws d where d.release_id = p_release_id),
    'buckets', coalesce((
      select jsonb_agg(jsonb_build_object(
               'location_id', x.location_id, 'location', l.name,
               'size', x.size, 'entries', x.entries,
               'pairs', coalesce(i.quantity_total, 0))
             order by l.sort_order, x.size)
      from (select location_id, size, count(*) as entries
              from public.raffle_entries
             where release_id = p_release_id and status = 'entered'
             group by location_id, size) x
      join public.locations l on l.id = x.location_id
      left join public.release_inventory i
        on i.release_id = p_release_id and i.location_id = x.location_id and i.size = x.size
    ), '[]'::jsonb))
  into v_res;
  return v_res;
end;
$$;

-- ------------------------------------------------------------
-- The draw.
--
-- Each (store, size) bucket is drawn independently, up to the quantity loaded
-- for it. Order is sha256(entry id || seed) — unpredictable before the seed
-- exists, and exactly reproducible afterwards by anyone holding it.
--
-- Runs once: raffle_draws has a unique index on release_id, so a second call
-- is refused rather than drawing again.
-- ------------------------------------------------------------
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

  select count(*) into v_total from public.raffle_entries
   where release_id = p_release_id and status = 'entered';
  if v_total = 0 then
    return jsonb_build_object('ok', false, 'error', 'no_entries',
      'message', 'There are no entries to draw.');
  end if;

  select coalesce(sum(quantity_total), 0) into v_pairs
    from public.release_inventory where release_id = p_release_id;
  if v_pairs = 0 then
    return jsonb_build_object('ok', false, 'error', 'no_pairs',
      'message', 'Load the quantity for each size and store before drawing.');
  end if;

  v_seed := encode(gen_random_bytes(32), 'hex');

  insert into public.raffle_draws (release_id, ran_by, seed, entries)
  values (p_release_id, auth.uid(), v_seed, v_total)
  returning id into v_draw_id;

  -- winners, bucket by bucket
  for w in
    select e.id, e.location_id, e.size
      from public.release_inventory i
      join lateral (
        select e2.id, e2.location_id, e2.size
          from public.raffle_entries e2
         where e2.release_id = p_release_id
           and e2.status = 'entered'
           and e2.location_id = i.location_id
           and e2.size = i.size
         order by digest(e2.id::text || v_seed, 'sha256')
         limit i.quantity_total
      ) e on true
     where i.release_id = p_release_id
       and i.quantity_total > 0
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
        select v_code, e.release_id, e.location_id, e.size, e.first_name, e.last_name,
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
       set status = 'won', reservation_id = v_res_id, drawn_at = now(), draw_id = v_draw_id
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
                      'entries', (select count(*) from public.raffle_entries e
                                   where e.release_id = p_release_id
                                     and e.location_id = i.location_id
                                     and e.size = i.size))
                    order by l.sort_order, i.size)
                    from public.release_inventory i
                    join public.locations l on l.id = i.location_id
                   where i.release_id = p_release_id and i.quantity_total > 0)
   where id = v_draw_id;

  -- close the release to further entries
  update public.releases set status = 'closed' where id = p_release_id;

  return jsonb_build_object('ok', true, 'draw_id', v_draw_id, 'seed', v_seed,
    'entries', v_total, 'winners', v_win, 'losers', v_lost,
    'message', v_win || ' winner' || case when v_win = 1 then '' else 's' end ||
               ' drawn from ' || v_total || ' entries. ' ||
               v_lost || ' not selected — all of them will be emailed.');
end;
$$;

revoke execute on function public.run_raffle_draw(uuid) from anon;
revoke execute on function public.raffle_stats(uuid) from anon;
grant execute on function public.run_raffle_draw(uuid) to authenticated;
grant execute on function public.raffle_stats(uuid) to authenticated;
