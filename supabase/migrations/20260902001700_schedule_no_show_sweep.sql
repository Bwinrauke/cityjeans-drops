-- pg_cron is enabled from the dashboard on this project; the guard keeps a
-- rebuild from scratch working. cron.schedule updates a job of the same name
-- in place, so replaying this file never leaves two sweeps registered.
create extension if not exists pg_cron;

-- The nightly sweep: 08:15 UTC is a little after 4am in New York, when no
-- store is open and nobody is mid-checkout.
select cron.schedule('drops-no-show-sweep', '15 8 * * *',
  $$select public.run_no_show_sweep();$$);
