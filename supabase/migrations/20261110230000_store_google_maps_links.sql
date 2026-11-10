-- Every store gets a Google Maps directions link, taken from the store locator
-- on cityjeans.com, and the emails that name a pickup store (confirmation,
-- reminder, raffle winner) put it right under the store. Two addresses are
-- corrected to match the locator: Junction Blvd is 37-39 (a Queens address,
-- not 3739), and West 225th is in the Bronx.

alter table public.locations add column if not exists maps_url text;

update public.locations set maps_url = v.url
  from (values
    ('398eab63-6567-41db-b25b-a00f39e94c17'::uuid, 'https://www.google.com/maps/dir/?api=1&destination=3%20E%20170th%20St%2C%20Bronx%2C%20NY%2010452'),
    ('fd11edef-5bf2-4b1b-b105-4e75d1531708', 'https://www.google.com/maps/dir/?api=1&destination=Ownership%20by%20City%20Jeans%206%20E%20170th%20Street%20Bronx%20NY%2010452'),
    ('493e0798-1ff0-4ba9-a728-6584b9792726', 'https://www.google.com/maps/dir/?api=1&destination=Vault%20170%20by%20City%20Jeans%201%20E%20170th%20Street%20Bronx%20NY%2010452'),
    ('e8008178-408d-4b32-bd75-88231edcaf97', 'https://www.google.com/maps/dir/?api=1&destination=City%20Jeans%20306%20E%20Fordham%20Road%20Bronx%20NY%2010458'),
    ('a1342b74-2f5f-4b23-a2b8-0fa5ae3b7a93', 'https://www.google.com/maps/dir/?api=1&destination=City%20Jeans%20690%20E%20Tremont%20Avenue%20Bronx%20NY%2010457'),
    ('2f0934a9-15a6-4dd1-b91d-cd8d2276c622', 'https://www.google.com/maps/dir/?api=1&destination=City%20Jeans%202996%20Third%20Avenue%20Bronx%20NY%2010455'),
    ('9b5a0bbd-5ac6-4a42-8564-b0c56739cdf7', 'https://www.google.com/maps/dir/?api=1&destination=City%20Jeans%201935%20Turnbull%20Avenue%20Bronx%20NY%2010473'),
    ('24be52c0-3382-4adc-920d-ccf792bab749', 'https://www.google.com/maps/dir/?api=1&destination=City%20Jeans%2048%20W%20225th%20Street%20Bronx%20NY%2010463'),
    ('09b86657-acac-4f2f-9a2d-5c90fdc11086', 'https://www.google.com/maps/dir/?api=1&destination=City%20Jeans%2037-39%20Junction%20Boulevard%20Corona%20NY%2011368')
  ) v(id, url)
 where locations.id = v.id;

update public.locations set address = '37-39 Junction Boulevard, Corona, NY 11368'
 where id = '09b86657-acac-4f2f-9a2d-5c90fdc11086' and address = '3739 Junction Boulevard, Corona, NY 11368';
update public.locations set address = '48 West 225th Street, Bronx, NY 10463'
 where id = '24be52c0-3382-4adc-920d-ccf792bab749' and address = '48 West 225th Street, New York, NY 10463';

-- a store added later with no link still gets one, built from its address
create or replace function public.store_maps_url(p_location_id uuid)
returns text language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(l.maps_url,
           case when l.address is not null then
             'https://www.google.com/maps/dir/?api=1&destination='
             || replace(replace(replace(l.address, ' ', '%20'), ',', '%2C'), '&', '%26') end)
    from public.locations l where l.id = p_location_id
$$;
revoke execute on function public.store_maps_url(uuid) from public, anon, authenticated;

do $m$
declare v_def text; v_old text; v_new text; n int;
begin
  v_def := pg_get_functiondef('public.render_notification(uuid)'::regprocedure);

  -- confirmation and raffle winner: "Pick up at <store>" gets directions under it
  v_old := $o$'Pick up at ' || loc || E'\n'$o$;
  v_new := $n$'Pick up at ' || loc || E'\n'
         || coalesce('Directions: ' || public.store_maps_url(r.location_id) || E'\n', '')$n$;
  n := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if n <> 2 then
    raise exception 'expected 2 "Pick up at" lines in render_notification, found %', n;
  end if;
  v_def := replace(v_def, v_old, v_new);

  -- day-of reminder
  v_old := $o$'Your pair is waiting at ' || loc || ' today.' || E'\n\n'$o$;
  v_new := $n$'Your pair is waiting at ' || loc || ' today.' || E'\n'
         || coalesce('Directions: ' || public.store_maps_url(r.location_id) || E'\n', '') || E'\n'$n$;
  if position(v_old in v_def) = 0 then
    raise exception 'reminder line not found; render_notification has changed';
  end if;
  v_def := replace(v_def, v_old, v_new);

  execute v_def;
end
$m$;
