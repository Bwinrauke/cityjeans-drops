-- A suspension that expires at 7pm made the message say "you can book again
-- from Nov 30" when most of Nov 30 is still blocked. Quote the first day that
-- actually works instead — a date the customer tries and finds true.
create or replace function public.eligible_again(p_until timestamptz)
returns date
language sql immutable
as $$
  select ((p_until at time zone 'America/New_York')::date + 1);
$$;

grant execute on function public.eligible_again(timestamptz) to anon, authenticated;

create or replace function public.suspension_message(p_until timestamptz, p_verb text)
returns text
language sql stable set search_path = public, pg_temp
as $$
  select p_verb || ' are paused on this account until '
      || to_char(public.eligible_again(p_until), 'Mon FMDD, YYYY')
      || ' — two reserved pairs in a row weren''t picked up. '
      || 'Ask a manager in store if you think that''s wrong.';
$$;

grant execute on function public.suspension_message(timestamptz, text) to anon, authenticated;
