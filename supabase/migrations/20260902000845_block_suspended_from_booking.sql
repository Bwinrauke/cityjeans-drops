-- The check goes before the inventory claim, so a suspended person never takes
-- a pair out of circulation even for the moment it takes to refuse them.
-- Existing bookings are untouched: a suspension stops new ones, it does not
-- confiscate a pair someone is already owed.
create or replace function public.reserve_spot(
  p_release_slug text, p_location_id uuid, p_size text,
  p_first_name text, p_last_name text, p_email text, p_phone text)
returns jsonb
language plpgsql security definer set search_path = 'public'
as $function$
declare
  v_rel      public.releases%rowtype;
  v_email    text := public.norm_email(p_email);
  v_phone    text := public.norm_phone(p_phone);
  v_inv_id   uuid;
  v_code     text;
  v_res      public.reservations%rowtype;
  v_loc_name text;
  v_try      int := 0;
  v_susp     public.suspensions%rowtype;
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

  v_susp := public.active_suspension(v_email, v_phone);
  if v_susp.id is not null then
    return jsonb_build_object('ok', false, 'error', 'suspended',
      'until', v_susp.until,
      'message', 'Reservations are paused on this account until '
        || to_char(v_susp.until at time zone 'America/New_York', 'Mon DD, YYYY')
        || ' — two reserved pairs in a row weren''t picked up. '
        || 'Ask a manager in store if you think that''s wrong.');
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
   where release_id = v_rel.id
     and status in ('confirmed','picked_up')
     and (email_norm = v_email or phone_norm = v_phone)
   limit 1;
  if found then
    select name into v_loc_name from public.locations where id = v_res.location_id;
    return jsonb_build_object('ok', false, 'error', 'duplicate',
      'message', 'You already have a reservation for this release.',
      'reservation', jsonb_build_object(
        'code', v_res.code, 'size', v_res.size, 'location', v_loc_name));
  end if;

  update public.release_inventory
     set quantity_reserved = quantity_reserved + 1
   where release_id = v_rel.id
     and location_id = p_location_id
     and size = p_size
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
      values
        (v_code, v_rel.id, p_location_id, p_size,
         btrim(p_first_name), btrim(p_last_name),
         btrim(p_email), v_email, btrim(p_phone), v_phone)
      returning * into v_res;
      exit;
    exception
      when unique_violation then
        if sqlerrm like '%reservations_code_key%' and v_try < 8 then
          continue;
        end if;
        update public.release_inventory
           set quantity_reserved = quantity_reserved - 1 where id = v_inv_id;
        return jsonb_build_object('ok', false, 'error', 'duplicate',
          'message', 'You already have a reservation for this release.');
    end;
  end loop;

  insert into public.notifications (reservation_id, channel, template, to_address, payload)
  values
    (v_res.id, 'email', 'confirmation', v_res.email,
       jsonb_build_object('code', v_res.code, 'release', v_rel.name)),
    (v_res.id, 'sms',   'confirmation', v_res.phone_norm,
       jsonb_build_object('code', v_res.code, 'release', v_rel.name));

  select name into v_loc_name from public.locations where id = v_res.location_id;

  return jsonb_build_object(
    'ok', true, 'code', v_res.code,
    'reservation', jsonb_build_object(
      'code', v_res.code, 'first_name', v_res.first_name, 'last_name', v_res.last_name,
      'email', v_res.email, 'phone', v_res.phone, 'size', v_res.size,
      'size_scale', v_rel.size_scale,
      'location', v_loc_name, 'release', v_rel.name, 'photo_url', v_rel.photo_url,
      'retail_price', v_rel.retail_price,
      'pickup_starts_at', v_rel.pickup_starts_at, 'pickup_ends_at', v_rel.pickup_ends_at,
      'pickup_note', v_rel.pickup_note, 'created_at', v_res.created_at));
end;
$function$;

grant execute on function public.reserve_spot(text,uuid,text,text,text,text,text) to anon, authenticated;
