-- Drain the notification queue every minute.
--
-- Every minute rather than every few, because a drop puts hundreds of
-- confirmations in the queue within minutes and a confirmation that lands an
-- hour later is worthless. One run claims up to SEND_BATCH and sends them
-- concurrently, paced under the SES per-second rate.
--
-- The x-cron-key value below must match the CRON_KEY edge-function secret.
create extension if not exists pg_cron;
create extension if not exists pg_net;

select cron.unschedule(jobid) from cron.job where jobname = 'drops-notify';

select cron.schedule('drops-notify', '* * * * *', $job$
  select net.http_post(
    url     := 'https://nrncccfqgwxcugqdouvs.supabase.co/functions/v1/send-notifications',
    headers := jsonb_build_object(
                 'Content-Type','application/json',
                 'x-cron-key', current_setting('app.cron_key', true)),
    body    := '{}'::jsonb,
    timeout_milliseconds := 55000);
$job$);
