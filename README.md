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

- **Register** — the cashier picks which store the register is at (remembered on
  that device), then types or scans a code; one tap marks it picked up. A second
  scan reports "already picked up" with the timestamp. A code held at another
  store is refused by name, with a manager override for the cases that deserve
  one.
- **Reservations** — filter by drop, store and status; search by name, email,
  phone or code; export CSV.
- **Releases** — every drop and how much of it is spoken for.
- **New / Edit release** — photo upload, details, timing, and a store × size
  grid for quantities.
- **Stores** — add or hide pickup locations.
- **Raffle** — demand per store and size, the draw, and the rules text.
- **Suspended** — who is paused, for how long, and the manager's early lift.
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

- Customers use a **publishable key only**. It can read active stores and
  published releases, and reach exactly seven RPCs (`get_availability`,
  `list_open_releases`, `current_raffle_rules`, `lookup_reservation`,
  `lookup_entry`, `reserve_spot`, `enter_raffle`). Nothing else — every other
  function had its EXECUTE grant revoked from `anon` and `authenticated`, so the
  publishable key cannot reach a single internal.
- `reservations` is invisible to anonymous callers. Reserving goes through
  `reserve_spot`; retrieval through `lookup_reservation`, which needs the code
  **and** the matching email, and returns byte-identical errors for a wrong code
  and a wrong email, so it is not a user-enumeration oracle.
- **Roles are enforced in Postgres, not the page.** `staff` / `manager` / `owner`
  are checked by `is_admin()` / `is_manager()` / `is_owner()` inside every RPC
  and every RLS policy. A cashier who re-shows a hidden tab in devtools, or calls
  an endpoint directly, is refused by the database. Reservation edits and the
  notification outbox are manager-only; only an owner can create or reset an
  account or write the site bucket.
- **Accounts are invite-only.** A trigger on `auth.users` rejects any signup
  whose email is not in `public.invited_emails`, so the public signup endpoint
  is closed regardless of the dashboard setting. An invite carries a role, and
  creating the account provisions it into `public.admins` automatically.
- The forced first-login password change is enforced by a trigger that clears
  the flag only when the password hash actually changes — it cannot be cleared
  by calling an RPC. Revoking an account deletes its login, not just its role,
  so no dormant credential is left behind.
- A cashier redeems only at the store the register is set to; a code held
  elsewhere is refused (manager override recorded). The redeem RPC refuses a
  call with no store rather than skipping the check.
- The CDN scripts (jsQR, qrcodejs) carry Subresource Integrity hashes, so a
  compromised CDN cannot inject code into the admin origin.
- Verified against the live API with nothing but the publishable key: anonymous
  attempts to read reservations, entries, suspensions, the admin list or the
  outbox; to call any privileged internal (`claim_notifications`,
  `mark_missed_pickups`, `apply_no_show_suspensions`, `active_suspension`,
  `complete_notification`, `is_admin`); to read draft releases or raw stock; or
  to redeem a code — all fail. These checks live in the test suite
  (`ANONYMOUS ATTACK SURFACE`) so they cannot silently regress.

---

## Layout

```
docs/                      the two pages + config
supabase/migrations/       schema, RLS, RPCs, seed data (in apply order)
supabase/functions/app/    edge function that serves the pages off Supabase
scripts/deploy_web.sh      push docs/ to the Supabase storage bucket
test/e2e_test.js           63-check browser test against the live backend
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
DROPS_TEST_EMAIL=<an owner account> DROPS_TEST_PASSWORD=<its password> \
  node test/e2e_test.js
```

The admin half signs in as whatever owner account you pass — there is no
standing test login sitting in the project. The customer half runs without
credentials.

Exercises both apps end to end against the real backend: reservation, duplicate
rejection, lookup, admin login, inventory grid, double-redemption, the staff
invite/revoke cycle, the fact that an uninvited email cannot sign up, the full
raffle cycle (enter, close, allocate, draw, emails, no second draw), the rules
consent gate, the multi-entry disqualification, the wrong-store refusal, and the
whole suspension cycle — two misses suspend, a suspended person is refused under
a fresh email, a manager lifts it, and the same misses can't suspend again.

Test rows use a `zz-` prefix and `@example.com` addresses. `claim_notifications`
retires both rather than sending: every one would bounce, and bounce rate is
what SES suspends an account over.

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

## Raffles

A release set to **Raffle** takes entries instead of reservations. An entry
picks a size and a pickup store and holds nothing — that is the point, because
you allocate against demand you can already see rather than guessing before it
exists. One entry per email and per phone per release; the entrant gets a
confirmation with an `RF-` code and the same lookup flow as a reservation.

The Raffle tab reads as four steps: entries open, entries close, load the pairs,
draw. Between the second and third you open the release and set the quantity for
each size at each store, now knowing exactly how many people want each. The tab
shows entries, pairs and the odds per bucket, and refuses to draw until pairs
exist.

The draw runs **per store and size**, so nobody wins a pair at a store they
didn't choose. Winners become ordinary reservations with `CJ-` pickup codes and
are emailed; everyone else is emailed too. `run_raffle_draw` is single-shot — a
unique index on `raffle_draws.release_id` makes a second run impossible even if
two managers press the button together.

**One entry per person, enforced at the draw.** Extra entries are accepted at
the form rather than bounced — you get to see who tried, and the entrant is told
on the spot that they now hold more than one. When the draw runs, every entry
belonging to anyone holding more than one comes out, matched on email *or*
phone, and all of them are emailed the reason. Taking out both entries rather
than just the second is what makes entering twice pointless. The Raffle tab
shows the count before you draw, and the odds it displays already exclude them.

**The rules are shown and agreed to.** `raffle_rules` holds the current text;
the entry form displays it and holds the button until it's ticked, and
`enter_raffle` refuses without consent, so the tick box can't be bypassed.
Editing the rules from the Raffle tab publishes a new version rather than
overwriting — each entry records the version its entrant agreed to, which is the
only version worth quoting back at someone.

**It is verifiable.** Winners are ordered by
`digest(entry_id || seed, 'sha256')` with a seed generated at draw time and
shown in the panel afterwards. With the seed and the entry list, anyone can
recompute the exact winners — which is what "provably fair" means for a raffle
and what an unhappy entrant will ask for.

---

## Wrong-store pickup

Every reservation is held at one store, so the register is bound to one too: the
cashier chooses it once and the browser remembers it. `redeem_reservation` takes
that store and refuses a code held elsewhere, naming the right store so the
cashier can say where to go. It's a refusal, not a lockout — a manager can
override with a reason, and the override is recorded on the reservation. The
check is in the RPC, not the page, so it holds no matter what a cashier types.

---

## Missed pickups

A reserved pair sits behind the counter instead of on the floor, so a no-show
costs someone else the shot at it. Marking that is not a job for a cashier on a
Saturday, so it happens on its own: a pg_cron job at 4:15am New York time marks
any uncollected pair a no-show once its pickup window has been shut for a day —
the grace covers the customer who turns up the next morning.

Two no-shows **in a row** pauses that person for 90 days. In a row is the point:
one collected pair anywhere in between wipes the slate, so a single bad week
doesn't follow anyone around. The pause follows the person, not an account —
there are no customer accounts here, only the email and phone on a booking — and
either one matching is enough, because coming back with a fresh email and the
same phone is what people actually try.

`reserve_spot` and `enter_raffle` both refuse a paused person, before the
inventory claim, naming the date they can book again. Existing bookings are
untouched: a pause stops new ones, it doesn't confiscate a pair someone is
already owed.

The **Suspended** tab lists who, why, and how long is left. Every admin can read
it — a cashier is the one who gets asked "why can't I book?" — but only a
manager or owner sees the Reactivate button, and lifting one records who did it
and why. A lifted suspension stays lifted: the same pair of misses can't
re-suspend them on the next night's sweep.

Warned before it applies, not after: the reservation form, the confirmation
email and the last-call email all say what two missed pickups costs, and offer
the way out — reply and we'll cancel it, no penalty.

---

## Not built yet

- **SMS.** The queue, templates and Twilio adapter are built. US carriers
  require A2P 10DLC registration before a single text sends — Twilio's docs put
  campaign review at 10–15 days — so texts stay queued until that clears and the
  Twilio secrets are set.
- **Shopify inventory.** Deliberately separate, so a reservation can't disturb
  live sell-through.
