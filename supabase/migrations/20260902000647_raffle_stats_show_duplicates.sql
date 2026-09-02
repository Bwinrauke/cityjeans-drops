-- The odds shown have to be the odds that will actually apply, so duplicates
-- are taken out of the bucket counts here rather than only at the draw.
create or replace function public.raffle_stats(p_release_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp
as $$
declare v_res jsonb; v_dupes uuid[];
begin
  if not public.is_admin() then
    return jsonb_build_object('ok', false, 'error', 'forbidden');
  end if;

  select coalesce(array_agg(id), '{}') into v_dupes
    from public.raffle_duplicate_entries(p_release_id);

  select jsonb_build_object(
    'ok', true,
    'total', (select count(*) from public.raffle_entries
               where release_id = p_release_id and status = 'entered'
                 and not (id = any(v_dupes))),
    'duplicates', cardinality(v_dupes),
    'duplicate_people', (select count(distinct email_norm) from public.raffle_entries
                          where id = any(v_dupes)),
    'drawn', exists (select 1 from public.raffle_draws where release_id = p_release_id),
    'draw', (select to_jsonb(d) from public.raffle_draws d where d.release_id = p_release_id),
    'disqualified', (select count(*) from public.raffle_entries
                      where release_id = p_release_id and status = 'disqualified'),
    'buckets', coalesce((
      select jsonb_agg(jsonb_build_object(
               'location_id', x.location_id, 'location', l.name,
               'size', x.size, 'entries', x.entries,
               'pairs', coalesce(i.quantity_total, 0))
             order by l.sort_order, x.size)
      from (select location_id, size, count(*) as entries
              from public.raffle_entries
             where release_id = p_release_id and status = 'entered'
               and not (id = any(v_dupes))
             group by location_id, size) x
      join public.locations l on l.id = x.location_id
      left join public.release_inventory i
        on i.release_id = p_release_id and i.location_id = x.location_id and i.size = x.size
    ), '[]'::jsonb))
  into v_res;
  return v_res;
end;
$$;

revoke execute on function public.raffle_stats(uuid) from anon;
grant execute on function public.raffle_stats(uuid) to authenticated;
