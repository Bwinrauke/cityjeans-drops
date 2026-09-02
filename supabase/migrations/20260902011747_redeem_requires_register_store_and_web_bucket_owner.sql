-- F7: with p_at_location omitted, the whole wrong-store branch was skipped and
-- a code held anywhere could be redeemed. The register always knows its store,
-- so require it — a redeem with no store is refused rather than waved through.
create or replace function public.redeem_reservation(
  p_code text, p_at_location uuid default null, p_override boolean default false, p_reason text default null)
returns jsonb
language plpgsql security definer set search_path to 'public','pg_temp'
as $function$
declare
  v_res public.reservations%rowtype;
  v_loc text; v_rel text; v_here text;
begin
  if not public.is_admin() then
    return jsonb_build_object('ok', false, 'error', 'forbidden', 'message', 'Not authorized.');
  end if;
  if p_at_location is null then
    return jsonb_build_object('ok', false, 'error', 'no_register_store',
      'message', 'Choose which store this register is at before scanning.');
  end if;
  if not exists (select 1 from public.locations where id = p_at_location) then
    return jsonb_build_object('ok', false, 'error', 'bad_store',
      'message', 'That is not a known store.');
  end if;

  select * into v_res from public.reservations
   where upper(btrim(code)) = upper(btrim(p_code));
  if not found then
    return jsonb_build_object('ok', false, 'error', 'not_found',
      'message', 'No reservation with that code.');
  end if;

  select name into v_loc from public.locations where id = v_res.location_id;
  select name into v_rel from public.releases  where id = v_res.release_id;

  if v_res.status = 'picked_up' then
    return jsonb_build_object('ok', false, 'error', 'already_redeemed',
      'message', 'Already picked up on ' ||
        to_char(v_res.picked_up_at at time zone 'America/New_York',
                'Mon DD, YYYY at HH12:MI AM') || '.',
      'reservation', to_jsonb(v_res) || jsonb_build_object('location', v_loc, 'release', v_rel));
  end if;
  if v_res.status <> 'confirmed' then
    return jsonb_build_object('ok', false, 'error', 'not_active',
      'message', 'This reservation is ' || v_res.status || '.');
  end if;

  -- wrong store — always evaluated now, because p_at_location can't be null
  if p_at_location <> v_res.location_id then
    select name into v_here from public.locations where id = p_at_location;
    if not p_override then
      return jsonb_build_object('ok', false, 'error', 'wrong_store',
        'message', 'This pair is held at ' || v_loc || ', not ' ||
                   coalesce(v_here, 'this store') || '.',
        'held_at', v_loc, 'scanned_at', v_here,
        'can_override', public.is_manager(),
        'reservation', to_jsonb(v_res) || jsonb_build_object('location', v_loc, 'release', v_rel));
    end if;
    if not public.is_manager() then
      return jsonb_build_object('ok', false, 'error', 'override_forbidden',
        'message', 'Only a manager or owner can release a pair held at another store.',
        'held_at', v_loc);
    end if;
  end if;

  update public.reservations
     set status = 'picked_up',
         picked_up_at = now(),
         picked_up_by = auth.uid(),
         picked_up_at_location = p_at_location,
         override_by = case when p_at_location <> location_id then auth.uid() end,
         override_reason = case when p_at_location <> location_id
                            then coalesce(p_reason, 'released at another store') end
   where id = v_res.id
  returning * into v_res;

  select name into v_here from public.locations where id = v_res.picked_up_at_location;

  return jsonb_build_object('ok', true,
    'moved', v_res.picked_up_at_location <> v_res.location_id,
    'held_at', v_loc, 'collected_at', v_here,
    'reservation', to_jsonb(v_res) || jsonb_build_object('location', v_loc, 'release', v_rel));
end;
$function$;

grant execute on function public.redeem_reservation(text, uuid, boolean, text) to authenticated;

-- F8: the `web` bucket is served publicly and its write policies gated on
-- is_admin(), so a cashier could upload JS into a public origin. The site is
-- hosted on GitHub Pages now, so nobody needs to write this bucket from a
-- browser at all — restrict it to owners.
drop policy if exists web_admin_write on storage.objects;
drop policy if exists web_admin_update on storage.objects;
drop policy if exists web_admin_delete on storage.objects;
create policy web_owner_write on storage.objects
  for insert to authenticated with check (bucket_id = 'web' and public.is_owner());
create policy web_owner_update on storage.objects
  for update to authenticated using (bucket_id = 'web' and public.is_owner());
create policy web_owner_delete on storage.objects
  for delete to authenticated using (bucket_id = 'web' and public.is_owner());
