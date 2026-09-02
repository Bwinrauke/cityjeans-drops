-- Disqualification happens as the first act of the draw, before the seed is
-- used for anything, so it cannot be aimed at a particular person: who is out
-- is settled by the entry list alone and is reproducible from it.
create or replace function public.queue_disqualified_email()
returns trigger language plpgsql security definer set search_path = public, pg_temp
as $$
begin
  if new.status = 'disqualified' and coalesce(old.status::text, '') <> 'disqualified' then
    insert into public.notifications (entry_id, channel, template, to_address)
    values (new.id, 'email', 'raffle_disqualified', new.email)
    on conflict (entry_id, channel, template) where entry_id is not null do nothing;
  end if;
  return new;
end;
$$;

drop trigger if exists raffle_disqualified_email on public.raffle_entries;
create trigger raffle_disqualified_email
  after update on public.raffle_entries
  for each row execute function public.queue_disqualified_email();

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

revoke execute on function public.run_raffle_draw(uuid) from anon;
grant execute on function public.run_raffle_draw(uuid) to authenticated;
