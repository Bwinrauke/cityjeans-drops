-- Two live entries belong to the same person when either the email or the
-- phone matches. Both sides of the pair are returned: entering twice
-- disqualifies both entries, not just the later one, so there is nothing to
-- gain by doing it.
create or replace function public.raffle_duplicate_entries(p_release_id uuid)
returns table (id uuid)
language sql stable security definer set search_path = public, pg_temp
as $$
  select e.id
    from public.raffle_entries e
   where e.release_id = p_release_id
     and e.status = 'entered'
     and exists (
       select 1 from public.raffle_entries o
        where o.release_id = e.release_id
          and o.id <> e.id
          and o.status = 'entered'
          and (o.email_norm = e.email_norm or o.phone_norm = e.phone_norm));
$$;

revoke execute on function public.raffle_duplicate_entries(uuid) from anon;
grant execute on function public.raffle_duplicate_entries(uuid) to authenticated;

-- How many entries this person already has for this release.
create or replace function public.raffle_entry_count(
  p_release_id uuid, p_email_norm text, p_phone_norm text)
returns int
language sql stable security definer set search_path = public, pg_temp
as $$
  select count(*)::int from public.raffle_entries
   where release_id = p_release_id
     and status in ('entered','won')
     and (email_norm = p_email_norm or phone_norm = p_phone_norm);
$$;

revoke execute on function public.raffle_entry_count(uuid, text, text) from anon, authenticated;
