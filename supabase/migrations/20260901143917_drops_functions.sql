-- ============================================================
-- Helpers
-- ============================================================

create or replace function public.is_admin()
returns boolean
language sql stable security definer set search_path = public, auth
as $$
  select exists (select 1 from public.admins a where a.user_id = auth.uid());
$$;

create or replace function public.norm_email(p text)
returns text language sql immutable as $$ select lower(btrim(coalesce(p,''))) $$;

create or replace function public.norm_phone(p text)
returns text language sql immutable as $$
  select right(regexp_replace(coalesce(p,''), '[^0-9]', '', 'g'), 10)
$$;

-- Human-friendly, unambiguous confirmation code: CJ-XXXXXX
create or replace function public.gen_code()
returns text language plpgsql volatile as $$
declare
  alphabet text := '23456789ABCDEFGHJKLMNPQRSTUVWXYZ';
  out text := '';
  i int;
begin
  for i in 1..6 loop
    out := out || substr(alphabet, 1 + floor(random()*length(alphabet))::int, 1);
  end loop;
  return 'CJ-' || out;
end;
$$;

create or replace function public.touch_updated_at()
returns trigger language plpgsql as $$
begin new.updated_at := now(); return new; end;
$$;
create trigger releases_touch before update on public.releases
  for each row execute function public.touch_updated_at();

-- ============================================================
-- Public RPC: reserve a pair (atomic, no oversell)
-- ============================================================
create or replace function public.reserve_spot(
  p_release_slug text,
  p_location_id  uuid,
  p_size         text,
  p_first_name   text,
  p_last_name    text,
  p_email        text,
  p_phone        text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_rel      public.releases%rowtype;
  v_email    text := public.norm_email(p_email);
  v_phone    text := public.norm_phone(p_phone);
  v_inv_id   uuid;
  v_code     text;
  v_res      public.reservations%rowtype;
  v_loc_name text;
  v_try      int := 0;
begin
  -- basic validation
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

  -- already reserved?
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

  -- atomically claim one unit
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

  -- insert reservation, retrying on the (astronomically rare) code collision
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
          continue;                       -- code collision: try another code
        end if;
        -- lost a race on the one-per-person index: release the unit
        update public.release_inventory
           set quantity_reserved = quantity_reserved - 1 where id = v_inv_id;
        return jsonb_build_object('ok', false, 'error', 'duplicate',
          'message', 'You already have a reservation for this release.');
    end;
  end loop;

  -- queue notifications (sent once email/SMS provider is wired up)
  insert into public.notifications (reservation_id, channel, template, to_address, payload)
  values
    (v_res.id, 'email', 'confirmation', v_res.email,
       jsonb_build_object('code', v_res.code, 'release', v_rel.name)),
    (v_res.id, 'sms',   'confirmation', v_res.phone_norm,
       jsonb_build_object('code', v_res.code, 'release', v_rel.name));

  select name into v_loc_name from public.locations where id = v_res.location_id;

  return jsonb_build_object(
    'ok', true,
    'code', v_res.code,
    'reservation', jsonb_build_object(
      'code',        v_res.code,
      'first_name',  v_res.first_name,
      'last_name',   v_res.last_name,
      'email',       v_res.email,
      'phone',       v_res.phone,
      'size',        v_res.size,
      'location',    v_loc_name,
      'release',     v_rel.name,
      'photo_url',   v_rel.photo_url,
      'retail_price',v_rel.retail_price,
      'pickup_starts_at', v_rel.pickup_starts_at,
      'pickup_ends_at',   v_rel.pickup_ends_at,
      'pickup_note',      v_rel.pickup_note,
      'created_at',  v_res.created_at
    ));
end;
$$;

-- ============================================================
-- Public RPC: look up my reservation (code + email)
-- ============================================================
create or replace function public.lookup_reservation(p_code text, p_email text)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare v_res public.reservations%rowtype; v_rel public.releases%rowtype; v_loc text;
begin
  select * into v_res from public.reservations
   where upper(btrim(code)) = upper(btrim(p_code))
     and email_norm = public.norm_email(p_email);
  if not found then
    return jsonb_build_object('ok', false, 'error', 'not_found',
      'message', 'No reservation found for that code and email.');
  end if;
  select * into v_rel from public.releases where id = v_res.release_id;
  select name into v_loc from public.locations where id = v_res.location_id;
  return jsonb_build_object('ok', true, 'reservation', jsonb_build_object(
    'code', v_res.code, 'first_name', v_res.first_name, 'last_name', v_res.last_name,
    'email', v_res.email, 'phone', v_res.phone, 'size', v_res.size,
    'status', v_res.status, 'location', v_loc, 'release', v_rel.name,
    'photo_url', v_rel.photo_url, 'retail_price', v_rel.retail_price,
    'pickup_starts_at', v_rel.pickup_starts_at, 'pickup_ends_at', v_rel.pickup_ends_at,
    'pickup_note', v_rel.pickup_note, 'created_at', v_res.created_at));
end;
$$;

-- ============================================================
-- Admin RPC: redeem at the register
-- ============================================================
create or replace function public.redeem_reservation(p_code text)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare v_res public.reservations%rowtype; v_loc text; v_rel text;
begin
  if not public.is_admin() then
    return jsonb_build_object('ok', false, 'error', 'forbidden', 'message', 'Not authorized.');
  end if;
  select * into v_res from public.reservations where upper(btrim(code)) = upper(btrim(p_code));
  if not found then
    return jsonb_build_object('ok', false, 'error', 'not_found', 'message', 'No reservation with that code.');
  end if;
  select name into v_loc from public.locations where id = v_res.location_id;
  select name into v_rel from public.releases  where id = v_res.release_id;
  if v_res.status = 'picked_up' then
    return jsonb_build_object('ok', false, 'error', 'already_redeemed',
      'message', 'Already picked up on ' || to_char(v_res.picked_up_at, 'Mon DD, YYYY at HH12:MI AM') || '.',
      'reservation', to_jsonb(v_res) || jsonb_build_object('location', v_loc, 'release', v_rel));
  end if;
  if v_res.status <> 'confirmed' then
    return jsonb_build_object('ok', false, 'error', 'not_active',
      'message', 'This reservation is ' || v_res.status || '.');
  end if;
  update public.reservations
     set status = 'picked_up', picked_up_at = now(), picked_up_by = auth.uid()
   where id = v_res.id returning * into v_res;
  return jsonb_build_object('ok', true,
    'reservation', to_jsonb(v_res) || jsonb_build_object('location', v_loc, 'release', v_rel));
end;
$$;

-- ============================================================
-- Grants
-- ============================================================
revoke all on function public.reserve_spot(text,uuid,text,text,text,text,text) from public;
grant execute on function public.reserve_spot(text,uuid,text,text,text,text,text) to anon, authenticated;
grant execute on function public.lookup_reservation(text,text) to anon, authenticated;
grant execute on function public.redeem_reservation(text) to authenticated;
grant execute on function public.is_admin() to anon, authenticated;
