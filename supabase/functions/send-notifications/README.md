# send-notifications

Drains `public.notifications`. Deployed with `verify_jwt = false` because the
caller is Postgres (pg_cron → pg_net), not a signed-in user; access is gated by
the `CRON_KEY` secret, which must match the `x-cron-key` header.

Email goes through **Amazon SES** — $0.10 per 1,000 with no monthly fee and no
daily cap. A free Resend tier allows 100 emails/day, which would trickle one
drop's confirmations out over three days. Resend is kept as a fallback so the
provider can be changed by swapping secrets alone.

## Secrets (Supabase → Edge Functions → Secrets)

| Secret | Value |
|---|---|
| `SES_ACCESS_KEY_ID` | IAM access key with `ses:SendEmail` |
| `SES_SECRET_ACCESS_KEY` | its secret |
| `SES_REGION` | e.g. `us-east-1` — must match the region the domain is verified in |
| `MAIL_FROM` | `City Jeans Drops <drops@cityjeans.com>` |
| `CRON_KEY` | any long random string; the cron job sends the same value |
| `RESEND_API_KEY` | optional fallback if SES keys are absent |
| `TWILIO_SID` / `TWILIO_TOKEN` / `TWILIO_FROM` | optional, once A2P 10DLC clears |

Without credentials the function still runs and records the exact reason against
each row — nothing is lost, and messages send as soon as the secrets exist.

## Test send

```
curl -X POST "https://nrncccfqgwxcugqdouvs.supabase.co/functions/v1/send-notifications?to=you@cityjeans.com" \
  -H "x-cron-key: THE_CRON_KEY"
```

Sends one real message without needing a reservation, and returns the provider's
own error if it fails.

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
