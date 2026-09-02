-- ============================================================
-- Wrong-store pickup
--
-- The pair physically sits at the store the customer chose. Handing it over
-- anywhere else leaves that store an item short and the reserved store holding
-- an orphan nobody will collect — the register is the only place that mistake
-- can still be caught for free.
--
-- So the register is bound to a store, and a code for another store is refused
-- outright, naming the store it belongs to so staff can redirect the customer.
--
-- It is refused, not silently allowed, because the failure is invisible
-- otherwise: nobody notices until a stock count weeks later.
--
-- A manager or owner can override — sometimes the pair really was moved, or the
-- customer drove across the city and you would rather keep the sale. An
-- override records who allowed it and where it was actually collected, so the
-- two stores can be reconciled instead of quietly drifting.
-- ============================================================

alter table public.reservations
  add column if not exists picked_up_at_location uuid references public.locations(id),
  add column if not exists override_by           uuid,
  add column if not exists override_reason       text;

create or replace function public.redeem_reservation(
  p_code        text,
  p_at_location uuid    default null,
  p_override    boolean default false,
  p_reason      text    default null
)
returns jsonb
language plpgsql security definer set search_path = public, pg_temp
as $$
declare
  v_res public.reservations%rowtype;
  v_loc text; v_rel text; v_here text; v_mine text;
begin
  if not public.is_admin() then
    return jsonb_build_object('ok', false, 'error', 'forbidden', 'message', 'Not authorized.');
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

  -- wrong store
  if p_at_location is not null and p_at_location <> v_res.location_id then
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
         picked_up_at_location = coalesce(p_at_location, location_id),
         override_by = case when p_at_location is not null
                             and p_at_location <> location_id then auth.uid() end,
         override_reason = case when p_at_location is not null
                                 and p_at_location <> location_id
                            then coalesce(p_reason, 'released at another store') end
   where id = v_res.id
  returning * into v_res;

  select name into v_here from public.locations where id = v_res.picked_up_at_location;

  return jsonb_build_object('ok', true,
    'moved', v_res.picked_up_at_location <> v_res.location_id,
    'held_at', v_loc, 'collected_at', v_here,
    'reservation', to_jsonb(v_res) || jsonb_build_object('location', v_loc, 'release', v_rel));
end;
$$;

revoke execute on function public.redeem_reservation(text, uuid, boolean, text) from anon;
grant execute on function public.redeem_reservation(text, uuid, boolean, text) to authenticated;

-- the old single-argument form is gone; make sure nothing can still call it
drop function if exists public.redeem_reservation(text);
