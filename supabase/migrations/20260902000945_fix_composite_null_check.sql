-- `row IS NOT NULL` is true only when every column is non-null, and lifted_at
-- is null on a live suspension by definition — so the guard never fired and a
-- person could be suspended a second time while already serving one. Test the
-- id instead.
create or replace function public.apply_no_show_suspensions(p_days int default 90)
returns int
language plpgsql security definer set search_path = public, pg_temp
as $$
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

    insert into public.notifications (reservation_id, channel, template, to_address)
    select v_last.id, 'email', 'suspended', r.email
      from public.reservations r where r.id = v_last.id
    on conflict (reservation_id, channel, template) do nothing;

    v_made := v_made + 1;
  end loop;

  return v_made;
end;
$$;

revoke execute on function public.apply_no_show_suspensions(int) from anon, authenticated;
