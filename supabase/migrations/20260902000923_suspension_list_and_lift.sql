-- Any cashier can be asked "why can't I book?", so reading the list is open to
-- every admin. Lifting is a manager decision and is recorded — who, when, and
-- why — because an unexplained reinstatement is how a rule stops meaning
-- anything.
create or replace function public.list_suspensions(p_include_past boolean default false)
returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp
as $$
declare v jsonb;
begin
  if not public.is_admin() then
    return jsonb_build_object('ok', false, 'error', 'forbidden');
  end if;

  select jsonb_build_object('ok', true, 'can_lift', public.is_manager(),
    'rows', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', s.id,
        'first_name', s.first_name, 'last_name', s.last_name,
        'email', s.email_norm, 'phone', s.phone_norm,
        'reason', s.reason, 'strikes', s.strikes,
        'started_at', s.started_at, 'until', s.until,
        'days_left', greatest(0, ceil(extract(epoch from (s.until - now())) / 86400)::int),
        'active', (s.lifted_at is null and s.until > now()),
        'lifted_at', s.lifted_at, 'lifted_reason', s.lifted_reason,
        'lifted_by', (select a.email from public.admins a where a.user_id = s.lifted_by),
        'misses', (select count(*) from public.reservations r
                    where (r.email_norm = s.email_norm or r.phone_norm = s.phone_norm)
                      and r.status = 'no_show' and r.archived_at is null))
      order by (s.lifted_at is null and s.until > now()) desc, s.until desc)
      from public.suspensions s
      where p_include_past
         or (s.lifted_at is null and s.until > now())
    ), '[]'::jsonb))
  into v;
  return v;
end;
$$;

create or replace function public.lift_suspension(p_id uuid, p_reason text default null)
returns jsonb
language plpgsql security definer set search_path = public, pg_temp
as $$
declare s public.suspensions%rowtype;
begin
  if not public.is_manager() then
    return jsonb_build_object('ok', false, 'error', 'forbidden',
      'message', 'Only a manager or owner can reactivate an account.');
  end if;

  select * into s from public.suspensions where id = p_id;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;
  if s.lifted_at is not null then
    return jsonb_build_object('ok', false, 'error', 'already_lifted',
      'message', 'That suspension was already lifted.');
  end if;

  update public.suspensions
     set lifted_at = now(), lifted_by = auth.uid(),
         lifted_reason = nullif(btrim(coalesce(p_reason, '')), '')
   where id = p_id;

  return jsonb_build_object('ok', true,
    'message', coalesce(s.first_name || ' ' || s.last_name, s.email_norm)
      || ' can book and enter again.');
end;
$$;

revoke execute on function public.list_suspensions(boolean) from anon;
revoke execute on function public.lift_suspension(uuid, text) from anon;
grant execute on function public.list_suspensions(boolean) to authenticated;
grant execute on function public.lift_suspension(uuid, text) to authenticated;
