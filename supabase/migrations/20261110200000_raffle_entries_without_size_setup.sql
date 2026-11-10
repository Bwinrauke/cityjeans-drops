-- A raffle takes entries before any sizes are set up: the customer picks from
-- the standard size run for the release's scale, and sizes and pairs are only
-- loaded once entries close. Size setup up front is for first-come drops.

-- Kept in step with SIZE_RUNS in docs/admin.html and docs/index.html.
create or replace function public.size_run(p_scale text)
returns text[] language sql immutable set search_path = public, pg_temp as $$
  select case p_scale
    when 'womens' then array['5','5.5','6','6.5','7','7.5','8','8.5','9','9.5','10','10.5','11','12']
    when 'gs'     then array['3.5Y','4Y','4.5Y','5Y','5.5Y','6Y','6.5Y','7Y']
    when 'ps'     then array['10.5C','11C','11.5C','12C','12.5C','13C','13.5C','1Y','2Y','3Y']
    when 'td'     then array['2C','3C','4C','5C','6C','7C','8C','9C','10C']
    when 'unisex' then array['4','5','6','7','8','9','10','11','12','13']
    else array['7','7.5','8','8.5','9','9.5','10','10.5','11','11.5','12','12.5','13','14','15']
  end
$$;
revoke execute on function public.size_run(text) from public, anon, authenticated;

-- enter_raffle: a size is valid if it is in the release's standard run or was
-- added to the release by hand. Only that check changes.
do $m$
declare v_def text;
begin
  v_def := pg_get_functiondef('public.enter_raffle(text,text,text,text,text,text,text,boolean,uuid)'::regprocedure);
  if position('if not exists (select 1 from public.release_inventory i
                  where i.release_id = v_rel.id and i.size = p_size) then' in v_def) = 0 then
    raise exception 'enter_raffle size check not found; it has changed since this migration was written';
  end if;
  v_def := replace(v_def,
    'if not exists (select 1 from public.release_inventory i
                  where i.release_id = v_rel.id and i.size = p_size) then',
    'if not (p_size = any(public.size_run(v_rel.size_scale))
          or exists (select 1 from public.release_inventory i
                      where i.release_id = v_rel.id and i.size = p_size)) then');
  execute v_def;
end
$m$;

-- demand lists every size someone entered, whether or not pairs are loaded
-- for it yet, plus any size that has pairs but no entries
create or replace function public.raffle_stats(p_release_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp
as $$
declare v_res jsonb; v_dupes uuid[]; v_run text[];
begin
  if not public.is_admin() then
    return jsonb_build_object('ok', false, 'error', 'forbidden');
  end if;
  select coalesce(array_agg(id), '{}') into v_dupes
    from public.raffle_duplicate_entries(p_release_id);
  select public.size_run(size_scale) into v_run from public.releases where id = p_release_id;

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
               'size', z.size, 'entries', coalesce(x.entries, 0),
               'pairs', coalesce(s.pairs, 0), 'stores', coalesce(s.stores, '[]'::jsonb))
             order by coalesce(array_position(v_run, z.size), 1000 + coalesce(s.size_order, 0)), z.size)
      from (select size from public.raffle_entries where release_id = p_release_id
            union
            select size from public.release_inventory
             where release_id = p_release_id and quantity_total > 0) z
      left join (select i.size, min(i.size_order) as size_order,
                        sum(i.quantity_total)::int as pairs,
                        coalesce(jsonb_agg(jsonb_build_object('location', l.name,
                                   'pairs', i.quantity_total) order by l.sort_order)
                                 filter (where i.quantity_total > 0), '[]'::jsonb) as stores
                   from public.release_inventory i
                   join public.locations l on l.id = i.location_id
                  where i.release_id = p_release_id
                  group by i.size) s on s.size = z.size
      left join (select size, count(*) as entries
                   from public.raffle_entries
                  where release_id = p_release_id and status = 'entered'
                    and not (id = any(v_dupes))
                  group by size) x on x.size = z.size
    ), '[]'::jsonb))
  into v_res;
  return v_res;
end;
$$;
