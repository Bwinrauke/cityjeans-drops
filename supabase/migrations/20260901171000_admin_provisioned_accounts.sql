-- Email confirmation is on for this project and Supabase's built-in SMTP is
-- rate-limited to a handful of messages an hour, so self-serve signup fails for
-- invited staff with "email rate limit exceeded". Accounts are therefore created
-- directly by an owner/manager with a temporary password, which the new user
-- changes on the Account tab. No email is ever sent.
--
-- NOTE: pgcrypto lives in the "extensions" schema on Supabase, so these
-- functions must include it in search_path for crypt()/gen_salt().

alter table public.invited_emails add column if not exists role text not null default 'staff';

create or replace function public.my_role()
returns text language sql stable security definer
set search_path = public, auth, pg_temp
as $$ select role from public.admins where user_id = auth.uid() $$;

-- Creating an account provisions it into public.admins with the invited role.
create or replace function public.provision_invited_admin()
returns trigger language plpgsql security definer
set search_path = public, auth, pg_temp as $$
declare v_role text;
begin
  select role into v_role from public.invited_emails where email = lower(btrim(new.email));
  if v_role is null then return new; end if;
  insert into public.admins (user_id, email, name, role)
  values (new.id, new.email, split_part(new.email, '@', 1), v_role)
  on conflict (user_id) do nothing;
  return new;
end; $$;

create trigger provision_invited_admin_after_signup
  after insert on auth.users
  for each row execute function public.provision_invited_admin();

create or replace function public.create_staff_account(
  p_email text, p_password text, p_role text default 'staff', p_name text default null)
returns jsonb language plpgsql security definer
set search_path = public, auth, extensions, pg_temp as $$
declare
  v_email text := public.norm_email(p_email);
  v_me    text := public.my_role();
  v_id    uuid := gen_random_uuid();
begin
  if v_me is null then
    return jsonb_build_object('ok', false, 'error', 'forbidden', 'message', 'Not authorized.');
  end if;
  if p_role not in ('staff','manager','owner') then
    return jsonb_build_object('ok', false, 'error', 'bad_role',
      'message', 'Role must be staff, manager or owner.');
  end if;
  if p_role in ('manager','owner') and v_me <> 'owner' then
    return jsonb_build_object('ok', false, 'error', 'forbidden',
      'message', 'Only an owner can create managers or owners.');
  end if;
  if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    return jsonb_build_object('ok', false, 'error', 'bad_email',
      'message', 'That does not look like an email address.');
  end if;
  if length(coalesce(p_password,'')) < 10 then
    return jsonb_build_object('ok', false, 'error', 'weak',
      'message', 'The temporary password needs at least 10 characters.');
  end if;
  if exists (select 1 from auth.users where lower(email) = v_email) then
    return jsonb_build_object('ok', false, 'error', 'exists',
      'message', v_email || ' already has an account. Use "Reset password" instead.');
  end if;

  insert into public.invited_emails (email, note, role, invited_by, used_at)
  values (v_email, p_name, p_role, auth.uid(), now())
  on conflict (email) do update set role = excluded.role, used_at = now();

  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, created_at, updated_at,
    raw_app_meta_data, raw_user_meta_data,
    confirmation_token, recovery_token, email_change_token_new, email_change
  ) values (
    '00000000-0000-0000-0000-000000000000', v_id, 'authenticated', 'authenticated',
    v_email, crypt(p_password, gen_salt('bf')), now(), now(), now(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    jsonb_build_object('name', coalesce(p_name, split_part(v_email, '@', 1))), '', '', '', ''
  );
  insert into auth.identities
    (provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
  values (v_id::text, v_id,
    jsonb_build_object('sub', v_id::text, 'email', v_email,
                       'email_verified', true, 'phone_verified', false),
    'email', now(), now(), now());

  update public.admins set name = coalesce(p_name, name), role = p_role where user_id = v_id;

  return jsonb_build_object('ok', true, 'email', v_email, 'role', p_role,
    'message', v_email || ' can sign in now with the temporary password.');
end; $$;

create or replace function public.reset_staff_password(p_email text, p_password text)
returns jsonb language plpgsql security definer
set search_path = public, auth, extensions, pg_temp as $$
declare v_email text := public.norm_email(p_email); v_me text := public.my_role();
begin
  if v_me <> 'owner' then
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
  return jsonb_build_object('ok', true,
    'message', 'Password reset. Give them the new one and have them change it.');
end; $$;

create or replace function public.list_staff()
returns jsonb language plpgsql stable security definer
set search_path = public, auth, pg_temp as $$
begin
  if not public.is_admin() then
    return jsonb_build_object('ok', false, 'error', 'forbidden');
  end if;
  return jsonb_build_object('ok', true, 'staff', coalesce((
    select jsonb_agg(jsonb_build_object(
      'email', i.email, 'role', i.role, 'note', i.note, 'invited_at', i.created_at,
      'has_account', exists (select 1 from auth.users u where lower(u.email) = i.email))
      order by i.created_at)
    from public.invited_emails i), '[]'::jsonb));
end; $$;

create or replace function public.revoke_user(p_email text)
returns jsonb language plpgsql security definer
set search_path = public, auth, pg_temp as $$
declare v_email text := public.norm_email(p_email);
begin
  if not public.is_admin() then
    return jsonb_build_object('ok', false, 'error', 'forbidden');
  end if;
  if v_email = public.norm_email((select email from auth.users where id = auth.uid())) then
    return jsonb_build_object('ok', false, 'error', 'self',
      'message', 'You cannot revoke your own access.');
  end if;
  delete from public.admins a using auth.users u
   where a.user_id = u.id and lower(u.email) = v_email;
  delete from public.invited_emails where email = v_email;
  return jsonb_build_object('ok', true,
    'message', v_email || ' can no longer sign in. Their login still exists but has no access.');
end; $$;

revoke execute on function public.create_staff_account(text,text,text,text) from anon, public;
revoke execute on function public.reset_staff_password(text,text) from anon, public;
revoke execute on function public.my_role() from anon;
revoke execute on function public.list_staff() from anon;
revoke execute on function public.revoke_user(text) from anon;
grant execute on function public.create_staff_account(text,text,text,text) to authenticated;
grant execute on function public.reset_staff_password(text,text) to authenticated;
grant execute on function public.my_role() to authenticated;
grant execute on function public.list_staff() to authenticated;
grant execute on function public.revoke_user(text) to authenticated;
