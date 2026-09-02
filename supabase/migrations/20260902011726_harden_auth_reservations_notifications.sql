-- F4: my_role() returns NULL for an authenticated user with no admins row, and
-- `NULL <> 'owner'` is NULL, which PL/pgSQL treats as false — so the guard fell
-- through and let anyone reset any password. is_owner() is a real boolean and
-- is NULL-safe. Unreachable today (every login has an admins row) but one stray
-- DELETE away from critical, so close it now.
create or replace function public.reset_staff_password(p_email text, p_password text)
returns jsonb
language plpgsql security definer set search_path to 'public','auth','extensions','pg_temp'
as $function$
declare v_email text := public.norm_email(p_email);
begin
  if not public.is_owner() then
    return jsonb_build_object('ok', false, 'error', 'forbidden',
      'message', 'Only an owner can reset someone else''s password.');
  end if;
  if length(coalesce(p_password,'')) < 10 then
    return jsonb_build_object('ok', false, 'error', 'weak', 'message', 'Use at least 10 characters.');
  end if;
  if not exists (select 1 from auth.users where lower(email) = v_email) then
    return jsonb_build_object('ok', false, 'error', 'not_found', 'message', 'No account with that email.');
  end if;
  update auth.users set encrypted_password = crypt(p_password, gen_salt('bf')), updated_at = now()
   where lower(email) = v_email;
  update public.admins a set must_change_password = true
   from auth.users u where a.user_id = u.id and lower(u.email) = v_email;
  return jsonb_build_object('ok', true,
    'message', 'Password reset. They will be asked to set their own on next sign-in.');
end; $function$;

-- F5: the forced-password-change lock was clearable on its own — clear_password_flag
-- just set the flag false for whoever was logged in, no password change required.
-- Move the real enforcement to a trigger that flips the flag exactly when the
-- password hash actually changes, and make the RPC read-only so calling it
-- proves nothing.
create or replace function public.clear_flag_on_password_change()
returns trigger language plpgsql security definer set search_path to 'public','pg_temp'
as $$
begin
  if new.encrypted_password is distinct from old.encrypted_password then
    update public.admins set must_change_password = false where user_id = new.id;
  end if;
  return new;
end; $$;

drop trigger if exists clear_pw_flag on auth.users;
create trigger clear_pw_flag
  after update of encrypted_password on auth.users
  for each row execute function public.clear_flag_on_password_change();

create or replace function public.clear_password_flag()
returns jsonb language sql security definer set search_path to 'public','pg_temp'
as $$
  -- kept for the client, but it no longer clears anything: the trigger above is
  -- the only thing that lowers the flag, and only a real password change does.
  select jsonb_build_object('ok', true,
    'must_change_password',
    coalesce((select must_change_password from public.admins where user_id = auth.uid()), false));
$$;
revoke execute on function public.clear_password_flag() from public, anon;
grant execute on function public.clear_password_flag() to authenticated;

-- catch up anyone whose flag is stale from before the trigger existed
update public.admins a set must_change_password = false
  from auth.users u
 where a.user_id = u.id and a.must_change_password
   and u.updated_at < now() - interval '1 minute'
   and u.updated_at > u.created_at + interval '5 seconds';

-- F6: is_admin() is true for a plain cashier, so reservations_admin_update let
-- staff PATCH any reservation with any body — flipping status, backdating a
-- pickup, repointing release_id. Reservation edits are a manager action; a
-- cashier's only write is redeem_reservation, which is its own gated RPC.
drop policy if exists reservations_admin_update on public.reservations;
create policy reservations_manager_update on public.reservations
  for update to authenticated using (public.is_manager()) with check (public.is_manager());

-- F11: same for the outbox — staff could delete or forge queue rows. Nothing on
-- the client writes notifications (triggers and definer functions do, as owner,
-- bypassing RLS), so no ordinary role needs write.
drop policy if exists notifications_admin_all on public.notifications;
create policy notifications_manager_read on public.notifications
  for select to authenticated using (public.is_manager());

-- F12: pin pg_temp so a temp-table shadow can't hijack a bare relation name
-- inside these definer functions.
alter function public.is_admin() set search_path to 'public','auth','pg_temp';
