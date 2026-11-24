-- Suspensions are staff-only. A customer is never told they are suspended:
--  * no suspension email is queued when someone is suspended
--  * a raffle entry from a suspended person goes in like any other (they get
--    the normal entry email) but is screened out with reason 'suspended', so
--    the draw skips it and they get the ordinary "not selected" email
--  * a first-come reservation from a suspended person is refused with the
--    same "sold out" answer anyone gets when a size runs out
-- render_notification() is untouched (its 'suspended' template just stops
-- being queued), so its 'code' and 'name' keys stay as they are.

create or replace function public.apply_no_show_suspensions(p_days integer default 90)
returns integer
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  p        record;
  v_last   record;
  v_prev   record;
  v_made   int := 0;
begin
  for p in
    select distinct r.email_norm, r.phone_norm
      from public.reservations r
     where r.status = 'no_show'
       and r.archived_at is null
       and r.created_at > now() - interval '1 year'
  loop
    select * into v_last from (
      select r2.id, r2.status, r2.first_name, r2.last_name,
             coalesce(rel.pickup_ends_at, r2.created_at) as at
        from public.reservations r2
        join public.releases rel on rel.id = r2.release_id
       where (r2.email_norm = p.email_norm or r2.phone_norm = p.phone_norm)
         and r2.status in ('picked_up','no_show')
         and r2.archived_at is null
       order by at desc, r2.created_at desc
       limit 1) x;

    select * into v_prev from (
      select r2.id, r2.status,
             coalesce(rel.pickup_ends_at, r2.created_at) as at
        from public.reservations r2
        join public.releases rel on rel.id = r2.release_id
       where (r2.email_norm = p.email_norm or r2.phone_norm = p.phone_norm)
         and r2.status in ('picked_up','no_show')
         and r2.archived_at is null
       order by at desc, r2.created_at desc
       limit 1 offset 1) y;

    if v_last.status::text <> 'no_show' or v_prev.status::text is distinct from 'no_show' then
      continue;
    end if;

    if exists (select 1 from public.suspensions s
                where s.trigger_reservation_id = v_last.id) then
      continue;
    end if;
    if (public.active_suspension(p.email_norm, p.phone_norm)).id is not null then
      continue;
    end if;

    insert into public.suspensions
      (email_norm, phone_norm, first_name, last_name, reason, strikes,
       trigger_reservation_id, until)
    values (p.email_norm, p.phone_norm, v_last.first_name, v_last.last_name,
            'two_no_shows', 2, v_last.id, now() + make_interval(days => p_days));

    -- no notice to the customer: suspensions are for staff eyes only

    v_made := v_made + 1;
  end loop;

  return v_made;
end;
$function$;

revoke execute on function public.apply_no_show_suspensions(int) from public, anon, authenticated;

-- anything still waiting to go out is dropped rather than sent
update public.notifications
   set status = 'skipped'
 where template = 'suspended' and status = 'pending';

create or replace function public.reserve_spot(p_release_slug text, p_location_id uuid, p_size text, p_first_name text, p_last_name text, p_email text, p_phone text)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_rel public.releases%rowtype;
  v_email text := public.norm_email(p_email);
  v_phone text := public.norm_phone(p_phone);
  v_inv_id uuid; v_code text; v_res public.reservations%rowtype;
  v_loc_name text; v_try int := 0; v_susp public.suspensions%rowtype;
begin
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

  select * into v_rel from public.releases where slug = p_release_slug;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'not_found',
      'message', 'This release could not be found.');
  end if;
  if v_rel.status <> 'open' then
    return jsonb_build_object('ok', false, 'error', 'closed',
      'message', 'Reservations for this release are closed.');
  end if;
  if v_rel.opens_at is not null and now() < v_rel.opens_at then
    return jsonb_build_object('ok', false, 'error', 'not_yet_open',
      'message', 'Reservations have not opened yet.');
  end if;
  if v_rel.closes_at is not null and now() > v_rel.closes_at then
    return jsonb_build_object('ok', false, 'error', 'closed',
      'message', 'Reservations for this release have closed.');
  end if;
  if v_rel.mode <> 'fcfs' then
    return jsonb_build_object('ok', false, 'error', 'raffle_mode',
      'message', 'This release is a raffle. Enter the raffle instead.');
  end if;

  select * into v_res from public.reservations
   where release_id = v_rel.id and status in ('confirmed','picked_up')
     and (email_norm = v_email or phone_norm = v_phone) limit 1;
  if found then
    select name into v_loc_name from public.locations where id = v_res.location_id;
    return jsonb_build_object('ok', false, 'error', 'duplicate',
      'message', 'You already have a reservation for this release.',
      'reservation', jsonb_build_object('code', v_res.code, 'size', v_res.size,
        'location', v_loc_name));
  end if;

  -- a suspended person gets exactly what a sold-out size returns, so nothing
  -- in the answer tells them they are suspended
  v_susp := public.active_suspension(v_email, v_phone);
  if v_susp.id is not null then
    return jsonb_build_object('ok', false, 'error', 'sold_out',
      'message', 'That size just sold out at this location. Try another size or store.');
  end if;

  update public.release_inventory set quantity_reserved = quantity_reserved + 1
   where release_id = v_rel.id and location_id = p_location_id and size = p_size
     and quantity_reserved < quantity_total
  returning id into v_inv_id;

  if v_inv_id is null then
    return jsonb_build_object('ok', false, 'error', 'sold_out',
      'message', 'That size just sold out at this location. Try another size or store.');
  end if;

  loop
    v_try := v_try + 1;
    v_code := public.gen_code();
    begin
      insert into public.reservations
        (code, release_id, location_id, size, first_name, last_name,
         email, email_norm, phone, phone_norm)
      values (v_code, v_rel.id, p_location_id, p_size,
         btrim(p_first_name), btrim(p_last_name),
         btrim(p_email), v_email, btrim(p_phone), v_phone)
      returning * into v_res;
      exit;
    exception when unique_violation then
      if sqlerrm like '%reservations_code_key%' and v_try < 8 then continue; end if;
      update public.release_inventory
         set quantity_reserved = quantity_reserved - 1 where id = v_inv_id;
      return jsonb_build_object('ok', false, 'error', 'duplicate',
        'message', 'You already have a reservation for this release.');
    end;
  end loop;

  -- email only for now; the SMS row goes back when 10DLC clears
  insert into public.notifications (reservation_id, channel, template, to_address, payload)
  values (v_res.id, 'email', 'confirmation', v_res.email,
            jsonb_build_object('code', v_res.code, 'release', v_rel.name));

  select name into v_loc_name from public.locations where id = v_res.location_id;

  return jsonb_build_object('ok', true, 'code', v_res.code,
    'reservation', jsonb_build_object(
      'code', v_res.code, 'first_name', v_res.first_name, 'last_name', v_res.last_name,
      'email', v_res.email, 'phone', v_res.phone, 'size', v_res.size,
      'size_scale', v_rel.size_scale, 'location', v_loc_name, 'release', v_rel.name,
      'photo_url', v_rel.photo_url, 'retail_price', v_rel.retail_price,
      'pickup_starts_at', v_rel.pickup_starts_at, 'pickup_ends_at', v_rel.pickup_ends_at,
      'pickup_note', v_rel.pickup_note, 'created_at', v_res.created_at));
end;
$function$;

create or replace function public.enter_raffle(p_release_slug text, p_size text, p_first_name text, p_last_name text, p_email text, p_phone text, p_instagram text default null::text, p_agree boolean default false, p_location_id uuid default null::uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
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

  -- looked up here, acted on silently at insert: the entry is screened out
  v_susp := public.active_suspension(v_email, v_phone);

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
  if not (p_size = any(public.size_run(v_rel.size_scale))
          or exists (select 1 from public.release_inventory i
                      where i.release_id = v_rel.id and i.size = p_size)) then
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
         rules_version, rules_accepted_at, excluded_at, excluded_reason)
      values (v_rel.id, null, p_size,
              btrim(p_first_name), btrim(p_last_name),
              btrim(p_email), v_email, btrim(p_phone), v_phone, v_ig, v_code,
              v_rules, now(),
              case when v_susp.id is not null then now() end,
              case when v_susp.id is not null then 'suspended' end)
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
$function$;

-- public execute on the two customer entry points is unchanged
grant execute on function public.reserve_spot(text, uuid, text, text, text, text, text) to anon, authenticated;
grant execute on function public.enter_raffle(text, text, text, text, text, text, text, boolean, uuid) to anon, authenticated;

-- Ben, Nov 24: no mention of pauses or suspensions anywhere customers look.
-- Two lines of render_notification() carried the rule; edit just those lines
-- in the live definition so nothing else in it (the 'code' and 'name' keys
-- included) can drift.
do $$
declare d text; d2 text;
begin
  d := pg_get_functiondef('public.render_notification(uuid)'::regprocedure);
  d2 := regexp_replace(d,
    $re$'Miss two in a row and you''re out for 90 days — if you can''t make '\s*\|\|\s*'it, reply to this email and we''ll cancel it, no penalty\.'$re$,
    $new$'If you can''t make it, reply to this email and we''ll cancel it.'$new$);
  d2 := regexp_replace(d2,
    $re$'After that the pair goes back on the floor, and a second missed '\s*\|\|\s*'pickup in a row suspends you for 90 days\.'$re$,
    $new$'After that the pair goes back on the floor.'$new$);
  if position('out for 90 days' in d2) > 0 or position('suspends you' in d2) > 0 then
    raise exception 'render_notification rule lines did not match; nothing changed';
  end if;
  if position($k$'code', code$k$ in d2) = 0 or position($k$'name', coalesce($k$ in d2) = 0 then
    raise exception 'render_notification lost its code/name keys';
  end if;
  execute d2;
end $$;
