-- Raffle results used to go out by text. Somebody who has entered City Jeans
-- raffles before will wait for a text that never arrives and assume they lost,
-- so the entry confirmation says plainly where to look — and says it in the
-- one message we know reaches them, since it is itself the email.
create or replace function public.entered_email_body(
  p_fname text, p_release text, p_size text, p_loc text, p_closes timestamptz, p_code text)
returns text
language sql stable set search_path = public, pg_temp
as $$
  select 'Hi ' || p_fname || E',\n\n'
      || 'Your raffle entry is in.' || E'\n\n'
      || p_release || E'\n' || 'Size ' || p_size || E'\n'
      || 'Pick up at ' || p_loc || ' if you win' || E'\n'
      || case when p_closes is not null then 'Entries close '
           || to_char(p_closes at time zone 'America/New_York', 'Dy Mon DD, HH12:MI AM')
           || E'\n' else '' end
      || E'\n' || 'YOUR CODE: ' || p_code || E'\n\n'
      || 'RESULTS COME BY EMAIL, NOT TEXT.' || E'\n'
      || 'This is a new system. We email everyone after the draw, win or lose, '
      || 'at this address. Add us to your contacts so it does not land in spam. '
      || 'We will not text you about the raffle, and we will not call you.' || E'\n\n'
      || 'One entry per person. If you enter more than once — another email, '
      || 'the same phone — every one of your entries is disqualified.' || E'\n\n'
      || 'You don''t need to check back.';
$$;
