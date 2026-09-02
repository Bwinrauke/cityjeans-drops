-- ------------------------------------------------------------
-- Public: enter the raffle.
--
-- Deliberately does NOT touch inventory. At entry time the allocation does not
-- exist yet, and pretending otherwise is how raffles end up quietly
-- first-come-first-served.
-- ------------------------------------------------------------
create or replace function public.enter_raffle(
  p_release_slug text,
  p_location_id  uuid,
  p_size         text,
  p_first_name   text,
  p_last_name    text,
  p_email        text,
  p_phone        text
)
returns jsonb
language plpgsql security definer set search_path = public, pg_temp
as $$
declare
  v_rel   public.releases%rowtype;
  v_email text := public.norm_email(p_email);
  v_phone text := public.norm_phone(p_phone);
  v_loc   text;
  v_e     public.raffle_entries%rowtype;
  v_code  text;
  v_try   int := 0;
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
  if not exists (select 1 from public.locations l where l.id = p_location_id and l.active) then
    return jsonb_build_object('ok', false, 'error', 'bad_location',
      'message', 'Please choose a pickup store.');
  end if;
  if not exists (select 1 from public.release_inventory i
                  where i.release_id = v_rel.id and i.size = p_size) then
    return jsonb_build_object('ok', false, 'error', 'bad_size',
      'message', 'That size is not part of this release.');
  end if;

  select * into v_e from public.raffle_entries
   where release_id = v_rel.id and status in ('entered','won')
     and (email_norm = v_email or phone_norm = v_phone) limit 1;
  if found then
    select name into v_loc from public.locations where id = v_e.location_id;
    return jsonb_build_object('ok', false, 'error', 'duplicate',
      'message', 'You are already entered for this release.',
      'entry', jsonb_build_object('code', v_e.code, 'size', v_e.size, 'location', v_loc));
  end if;

  loop
    v_try := v_try + 1;
    v_code := replace(public.gen_code(), 'CJ-', 'RF-');
    begin
      insert into public.raffle_entries
        (release_id, location_id, size, first_name, last_name,
         email, email_norm, phone, phone_norm, code)
      values (v_rel.id, p_location_id, p_size,
              btrim(p_first_name), btrim(p_last_name),
              btrim(p_email), v_email, btrim(p_phone), v_phone, v_code)
      returning * into v_e;
      exit;
    exception
      when unique_violation then
        if sqlerrm like '%raffle_entries_code%' and v_try < 8 then continue; end if;
        return jsonb_build_object('ok', false, 'error', 'duplicate',
          'message', 'You are already entered for this release.');
    end;
  end loop;

  select name into v_loc from public.locations where id = v_e.location_id;

  return jsonb_build_object('ok', true, 'code', v_e.code,
    'entry', jsonb_build_object(
      'code', v_e.code, 'first_name', v_e.first_name, 'last_name', v_e.last_name,
      'email', v_e.email, 'phone', v_e.phone, 'size', v_e.size,
      'size_scale', v_rel.size_scale, 'location', v_loc, 'release', v_rel.name,
      'photo_url', v_rel.photo_url, 'retail_price', v_rel.retail_price,
      'closes_at', v_rel.closes_at,
      'pickup_starts_at', v_rel.pickup_starts_at, 'pickup_ends_at', v_rel.pickup_ends_at,
      'status', 'entered', 'created_at', v_e.created_at));
end;
$$;

-- ------------------------------------------------------------
-- Public: check an entry, or the reservation it turned into.
-- ------------------------------------------------------------
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
    'email', v_e.email, 'phone', v_e.phone, 'size', v_e.size,
    'size_scale', v_rel.size_scale, 'location', v_loc, 'release', v_rel.name,
    'photo_url', v_rel.photo_url, 'retail_price', v_rel.retail_price,
    'closes_at', v_rel.closes_at, 'status', v_e.status,
    'pickup_starts_at', v_rel.pickup_starts_at, 'pickup_ends_at', v_rel.pickup_ends_at,
    'created_at', v_e.created_at));
end;
$$;

grant execute on function public.enter_raffle(text,uuid,text,text,text,text,text) to anon, authenticated;
grant execute on function public.lookup_entry(text,text) to anon, authenticated;
