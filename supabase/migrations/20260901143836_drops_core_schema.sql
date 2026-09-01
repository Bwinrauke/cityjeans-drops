-- ============================================================
-- City Jeans / Ownership — Sneaker Release Reservations
-- Core schema
-- ============================================================

create extension if not exists pgcrypto;

-- ---------- Locations ----------
create table public.locations (
  id           uuid primary key default gen_random_uuid(),
  name         text not null,
  address      text,
  phone        text,
  sort_order   int  not null default 0,
  active       boolean not null default true,
  created_at   timestamptz not null default now()
);

-- ---------- Releases ----------
create type public.release_status as enum ('draft','open','closed','archived');
create type public.release_mode   as enum ('fcfs','raffle');

create table public.releases (
  id                 uuid primary key default gen_random_uuid(),
  slug               text not null unique,
  name               text not null,
  brand              text,
  style_code         text,
  colorway           text,
  description        text,
  photo_url          text,
  retail_price       numeric(10,2),
  status             public.release_status not null default 'draft',
  mode               public.release_mode   not null default 'fcfs',
  opens_at           timestamptz,
  closes_at          timestamptz,
  pickup_starts_at   timestamptz,
  pickup_ends_at     timestamptz,
  pickup_note        text,
  limit_per_customer int not null default 1,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);
create index releases_status_idx on public.releases(status);

-- ---------- Inventory: quantity per size per location ----------
create table public.release_inventory (
  id                uuid primary key default gen_random_uuid(),
  release_id        uuid not null references public.releases(id) on delete cascade,
  location_id       uuid not null references public.locations(id) on delete cascade,
  size              text not null,
  size_order        numeric(5,1) not null default 0,
  quantity_total    int not null default 0 check (quantity_total >= 0),
  quantity_reserved int not null default 0 check (quantity_reserved >= 0),
  constraint inventory_not_oversold check (quantity_reserved <= quantity_total),
  unique (release_id, location_id, size)
);
create index release_inventory_release_idx on public.release_inventory(release_id);

-- ---------- Reservations ----------
create type public.reservation_status as enum ('confirmed','picked_up','cancelled','no_show');

create table public.reservations (
  id            uuid primary key default gen_random_uuid(),
  code          text not null unique,
  release_id    uuid not null references public.releases(id) on delete cascade,
  location_id   uuid not null references public.locations(id),
  size          text not null,
  first_name    text not null,
  last_name     text not null,
  email         text not null,
  email_norm    text not null,
  phone         text not null,
  phone_norm    text not null,
  status        public.reservation_status not null default 'confirmed',
  source        text not null default 'web',
  created_at    timestamptz not null default now(),
  picked_up_at  timestamptz,
  picked_up_by  uuid,
  notes         text
);
create index reservations_release_idx on public.reservations(release_id);
create index reservations_location_idx on public.reservations(location_id);
create index reservations_email_idx on public.reservations(email_norm);
create index reservations_phone_idx on public.reservations(phone_norm);

-- one live reservation per email per release, and per phone per release
create unique index reservations_one_per_email
  on public.reservations(release_id, email_norm)
  where status in ('confirmed','picked_up');
create unique index reservations_one_per_phone
  on public.reservations(release_id, phone_norm)
  where status in ('confirmed','picked_up');

-- ---------- Raffle entries (schema ready, draw built later) ----------
create type public.entry_status as enum ('entered','won','lost','withdrawn');

create table public.raffle_entries (
  id           uuid primary key default gen_random_uuid(),
  release_id   uuid not null references public.releases(id) on delete cascade,
  location_id  uuid not null references public.locations(id),
  size         text not null,
  first_name   text not null,
  last_name    text not null,
  email        text not null,
  email_norm   text not null,
  phone        text not null,
  phone_norm   text not null,
  weight       numeric(6,2) not null default 1,
  status       public.entry_status not null default 'entered',
  reservation_id uuid references public.reservations(id),
  created_at   timestamptz not null default now(),
  drawn_at     timestamptz
);
create unique index raffle_one_per_email on public.raffle_entries(release_id, email_norm)
  where status in ('entered','won');
create index raffle_release_idx on public.raffle_entries(release_id);

-- ---------- Admin users ----------
create table public.admins (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  email      text,
  name       text,
  role       text not null default 'staff',   -- 'staff' | 'manager' | 'owner'
  created_at timestamptz not null default now()
);

-- ---------- Notification outbox (email/SMS wired later) ----------
create table public.notifications (
  id             uuid primary key default gen_random_uuid(),
  reservation_id uuid references public.reservations(id) on delete cascade,
  channel        text not null,          -- 'email' | 'sms'
  template       text not null,          -- 'confirmation' | 'reminder' | 'won' | 'lost'
  to_address     text not null,
  payload        jsonb,
  status         text not null default 'queued',  -- queued|sent|failed
  error          text,
  created_at     timestamptz not null default now(),
  sent_at        timestamptz
);
create index notifications_status_idx on public.notifications(status);
