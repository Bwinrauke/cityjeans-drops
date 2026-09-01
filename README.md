# City Jeans — Drops

Mobile reservation app for in-store sneaker release pickups, with a back office
for loading drops and redeeming codes at the register.

---

## Live

| | |
|---|---|
| Customer app | https://drops.cityjeans.com |
| Admin panel | https://drops.cityjeans.com/admin.html |
| Repo | https://github.com/Bwinrauke/cityjeans-drops |
| Admin login | `ben@cityjeans.com` |
| Supabase project | `cityjeans-drops` (`nrncccfqgwxcugqdouvs`) |

---

## How it works

Two static HTML pages talk directly to Supabase with a publishable key. There is
no server to run and no build step — the security lives in Postgres row-level
security and three RPC functions, not in a backend the pages could bypass.

**`docs/index.html` — the customer app.** Opens on a list of every release that
is currently taking reservations — men's, women's and GS drops routinely overlap,
and each carries its own size scale, pickup window and stock. Tapping one goes
photo → size → pickup store → name/email/phone → a confirmation ticket with a
large code and a QR, designed to be screenshotted and shown at the register. A
link with `?release=<slug>` opens that drop directly and skips the list. A lookup
flow (code + email) recovers a lost screenshot.

Customers never see quantities: sizes read Available or Gone, and anonymous
access to `release_inventory` is withdrawn in favour of `get_availability()`,
which returns booleans.

**`docs/admin.html` — the back office.**

- **Register** — cashier types or scans a code; one tap marks it picked up. A
  second scan reports "already picked up" with the timestamp.
- **Reservations** — filter by drop, store and status; search by name, email,
  phone or code; export CSV.
- **Releases** — every drop and how much of it is spoken for.
- **New / Edit release** — photo upload, details, timing, and a store × size
  grid for quantities.
- **Stores** — add or hide pickup locations.
- **Account** — change your own password; invite, list and revoke staff.

---

## Preventing overselling

`reserve_spot` claims a unit with one conditional UPDATE
(`quantity_reserved + 1 WHERE quantity_reserved < quantity_total`) *before*
writing the reservation, so Postgres serializes the contention itself. A table
constraint (`quantity_reserved <= quantity_total`) is the backstop.

Verified with 40 simultaneous requests against 5 units: exactly 5 succeeded, 35
got "sold out", the counter landed on 5. If the reservation insert then fails
because that person already reserved, the claimed unit is handed straight back.

---

## Security model

- Customers use a **publishable key only**. It can read active stores, published
  releases and stock counts. Nothing else.
- `reservations` is invisible to anonymous callers. Reserving goes through
  `reserve_spot`; retrieval through `lookup_reservation`, which needs the code
  **and** the matching email.
- **Accounts are invite-only.** A trigger on `auth.users` rejects any signup
  whose email is not in `public.invited_emails`, so the public signup endpoint
  is closed regardless of the dashboard setting. An invite carries a role, and
  creating the account provisions it into `public.admins` automatically.
- Admin actions require an account listed in `public.admins`.
- Verified: anonymous attempts to read reservations, read the admin list, insert
  a reservation directly, raise inventory, read draft releases, or redeem a code
  all fail.

---

## Layout

```
docs/                      the two pages + config
supabase/migrations/       schema, RLS, RPCs, seed data (in apply order)
supabase/functions/app/    edge function that serves the pages off Supabase
scripts/deploy_web.sh      push docs/ to the Supabase storage bucket
test/e2e_test.js           44-check browser test against the live backend
```

---

## Deploying

**GitHub Pages** (primary): Pages is set to serve the `docs/` folder on `main`,
so every push to `main` republishes the site. Nothing to build, nothing to
configure.

**Supabase** (backup): `SUPABASE_ADMIN_PASSWORD='…' ./scripts/deploy_web.sh`
uploads the pages to the `web` bucket; the `app` edge function serves them.

**Database changes**: apply the SQL in `supabase/migrations/` in filename order,
or `supabase db push` with the CLI linked to the project.

---

## Running the tests

```bash
npm i playwright
node test/testserver.js &     # local harness that proxies Supabase
node test/e2e_test.js
```

Exercises both apps end to end against the real backend: reservation, duplicate
rejection, lookup, admin login, inventory grid, double-redemption, the staff
invite/revoke cycle, and the fact that an uninvited email cannot sign up.

---

## Notifications

`public.notifications` is an outbox. `reserve_spot` writes a confirmation row
per reservation; `enqueue_due_notifications()` adds a pickup reminder (4 hours
before the window opens) and a last-call notice (2 hours before it closes).
The `send-notifications` edge function claims a batch, renders subject and body
from the reservation with `render_notification()`, sends, and marks each row
sent or failed — retrying up to five times. Rows whose reservation has been
cancelled, marked no-show or archived are retired rather than sent.

**Live.** Email goes through Amazon SES in `us-east-2`, from
`drops@cityjeans.com`, drained by a pg_cron job every minute. The domain signs
with DKIM and uses a custom MAIL FROM on `shop.cityjeans.com`, so both
alignment paths pass the domain's `p=quarantine` DMARC policy — verified by a
test send landing in the inbox.

SES costs $0.10 per 1,000 with no monthly fee; the account allows 50,000/day at
14/second, so a drop costs a few cents. A free Resend tier caps at 100/day,
which would have trickled one drop's confirmations out over three days — Resend
remains as a fallback selected by which secrets are present.

A customer normally receives two emails: the confirmation, and a reminder four
hours before pickup opens. A third, the last call, only reaches someone who
still has an uncollected pair two hours before the window shuts. A unique index
on (reservation, channel, template) makes a duplicate impossible however often
the job runs. Timing and wording live in SQL, so changing either is a migration
rather than a deploy. See `supabase/functions/send-notifications/README.md`.

Neither Shopify nor Gorgias can do this job: Shopify has no Admin API for
arbitrary transactional email (its email is tied to its own order events, and
Shopify Email is bulk marketing), and sending through Gorgias would open a
support ticket per confirmation — wrecking response-time metrics and billing
per ticket.

---

## Not built yet

- **Raffle mode.** `raffle_entries`, the `entry_status` enum and the per-release
  `fcfs`/`raffle` toggle are in place. What remains is the entry form and the
  draw — pick winners at random up to the quantity loaded per size per store,
  convert winners into reservations, mark the rest lost.
- **SMS.** The queue, templates and Twilio adapter are built. US carriers
  require A2P 10DLC registration before a single text sends — Twilio's docs put
  campaign review at 10–15 days — so texts stay queued until that clears and the
  Twilio secrets are set.
- **Shopify inventory.** Deliberately separate, so a reservation can't disturb
  live sell-through.
