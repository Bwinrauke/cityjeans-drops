# send-notifications

Drains `public.notifications`. Deployed with `verify_jwt = false` because the
caller is Postgres (pg_cron → pg_net), not a signed-in user; access is gated by
the `CRON_KEY` secret, which must match the `x-cron-key` header.

## Secrets (Supabase → Edge Functions → Secrets)

| Secret | Value |
|---|---|
| `RESEND_API_KEY` | `re_…` from resend.com |
| `MAIL_FROM` | `City Jeans Drops <drops@cityjeans.com>` |
| `CRON_KEY` | any long random string; the cron job sends the same value |
| `TWILIO_SID` / `TWILIO_TOKEN` / `TWILIO_FROM` | optional, once A2P 10DLC clears |

Without `RESEND_API_KEY` the function still runs and records
`RESEND_API_KEY is not set` against each row — nothing is lost, and the
messages send as soon as the key exists.

## Schedule

```sql
create extension if not exists pg_cron;
create extension if not exists pg_net;

select cron.schedule('drops-notify', '*/5 * * * *', $$
  select net.http_post(
    url     := 'https://nrncccfqgwxcugqdouvs.supabase.co/functions/v1/send-notifications',
    headers := jsonb_build_object('Content-Type','application/json',
                                  'x-cron-key','THE_SAME_CRON_KEY'),
    body    := '{}'::jsonb);
$$);
```
