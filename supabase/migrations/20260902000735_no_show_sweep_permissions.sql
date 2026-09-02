-- The sweep runs from pg_cron, where there is no logged-in user to check, so
-- the function itself stays ungated and simply is not granted to anyone. A
-- manager who wants to run it early goes through the wrapper.
revoke execute on function public.run_no_show_sweep() from authenticated;

create or replace function public.sweep_no_shows_now()
returns jsonb
language plpgsql security definer set search_path = public, pg_temp
as $$
begin
  if not public.is_manager() then
    return jsonb_build_object('ok', false, 'error', 'forbidden',
      'message', 'Only a manager or owner can run the sweep.');
  end if;
  return public.run_no_show_sweep();
end;
$$;

revoke execute on function public.sweep_no_shows_now() from anon;
grant execute on function public.sweep_no_shows_now() to authenticated;
