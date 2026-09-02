-- Revoking took the person out of admins and invited_emails but left their
-- login sitting in auth.users. Harmless in the sense that the panel locks them
-- out, but a former employee keeping a working credential is not a state worth
-- defending — and it silently piled up 106 dead accounts from test runs.
-- Removing the login is what "no longer works here" should mean.
create or replace function public.revoke_user(p_email text)
returns jsonb
language plpgsql security definer set search_path = 'public', 'auth', 'pg_temp'
as $function$
declare v_email text := public.norm_email(p_email); v_id uuid;
begin
  if not public.is_owner() then
    return jsonb_build_object('ok', false, 'error', 'forbidden',
      'message', 'Only an owner can remove someone.');
  end if;
  if v_email = public.norm_email((select email from auth.users where id = auth.uid())) then
    return jsonb_build_object('ok', false, 'error', 'self',
      'message', 'You cannot revoke your own access.');
  end if;
  if (select count(*) from public.admins where role = 'owner') <= 1
     and exists (select 1 from public.admins a join auth.users u on u.id = a.user_id
                  where lower(u.email) = v_email and a.role = 'owner') then
    return jsonb_build_object('ok', false, 'error', 'last_owner',
      'message', 'That is the last owner. Make someone else an owner first.');
  end if;

  select u.id into v_id from auth.users u where lower(u.email) = v_email;

  delete from public.admins a using auth.users u
   where a.user_id = u.id and lower(u.email) = v_email;
  delete from public.invited_emails where email = v_email;
  if v_id is not null then
    delete from auth.users where id = v_id;
  end if;

  return jsonb_build_object('ok', true,
    'message', v_email || ' has been removed — their login no longer exists.');
end; $function$;

revoke execute on function public.revoke_user(text) from anon;
grant execute on function public.revoke_user(text) to authenticated;
