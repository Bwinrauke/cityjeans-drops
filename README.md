# City Jeans — Drops

Mobile reservation app for in-store sneaker release pickups, with a back office
for loading drops and redeeming codes at the register.

---

## Live

| | |
|---|---|
| Customer app | https://bwinrauke.github.io/cityjeans-drops/ |
| Admin panel | same URL + `/admin.html` |
| Backup host | `https://nrncccfqgwxcugqdouvs.supabase.co/functions/v1/app/` |
| Admin login | `ben@cityjeans.com` |
| Supabase project | `cityjeans-drops` (`nrncccfqgwxcugqdouvs`) |

---

## How it works

Two static HTML pages talk directly to Supabase with a publishable key. There is
no server to run and no build step — the security lives in Postgres row-level
security and three RPC functions, not in a backend the pages could bypass.

**`docs/index.html` — the customer app.** Photo → size → pickup store →
name/email/phone → a confirmation ticket with a large code and a QR, designed to
be screenshotted and shown at the register. Stock refreshes every 20 seconds
while they decide. A lookup flow (code + email) recovers a lost screenshot.

**`docs/admin.html` — the back office.**

- **Register** — cashier types or scans a code; one tap marks it picked up. A
  second scan reports "already picked up" with the timestamp.
- **Reservations** — filter by drop, store and status; search by name, email,
  phone or code; export CSV.
- **Releases** — every drop and how much of it is spoken for.
- **New / Edit release** — photo upload, details, timing, and a store × size
  grid for quantities.
- **Stores** — add or hide pickup locations.

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
- Admin actions require an account listed in `public.admins`. A stranger who
  signs up gets an account that can see nothing.
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
test/e2e_test.js           22-check browser test against the live backend
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
rejection, lookup, admin login, inventory grid, and double-redemption.

---

## Not built yet

- **Raffle mode.** `raffle_entries`, the `entry_status` enum and the per-release
  `fcfs`/`raffle` toggle are in place. What remains is the entry form and the
  draw — pick winners at random up to the quantity loaded per size per store,
  convert winners into reservations, mark the rest lost.
- **Email and SMS.** Every reservation already queues two rows in
  `notifications` with the code and release name. Wiring a provider means one
  scheduled function that drains that queue.
- **Shopify inventory.** Deliberately separate, so a reservation can't disturb
  live sell-through.
