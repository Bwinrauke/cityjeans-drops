-- Lets the test suite assert the shape render_notification hands the sender,
-- without granting it the sending functions. Returns one rendered sample per
-- template that currently exists in the outbox.
create or replace function public.render_contract_probe()
returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp
as $$
declare v jsonb;
begin
  if not public.is_manager() then
    return jsonb_build_object('ok', false, 'error', 'forbidden');
  end if;
  select coalesce(jsonb_agg(m), '[]'::jsonb) into v
    from (
      select distinct on (n.template) n.id
        from public.notifications n
       order by n.template, n.created_at desc
    ) pick,
    lateral public.render_notification(pick.id) m
   where m is not null;
  return v;
end;
$$;

revoke execute on function public.render_contract_probe() from public, anon;
grant execute on function public.render_contract_probe() to authenticated;
