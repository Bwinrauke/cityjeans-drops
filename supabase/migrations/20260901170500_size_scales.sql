-- Each release is its own product with its own size scale, so a men's drop,
-- a women's drop and a GS drop of the same shoe are separate releases with
-- separate inventory and separate reservations.
alter table public.releases
  add column if not exists size_scale text not null default 'mens';
alter table public.releases drop constraint if exists releases_size_scale_check;
alter table public.releases add constraint releases_size_scale_check
  check (size_scale in ('mens','womens','gs','ps','td','unisex'));
comment on column public.releases.size_scale is
  'Which size run this release uses: mens, womens, gs, ps, td, unisex. Drives the label the customer sees.';
