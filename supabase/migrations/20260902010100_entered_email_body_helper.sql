-- Reconstructed from the live schema (altered outside the migration system).
CREATE OR REPLACE FUNCTION public.entered_email_body(p_fname text, p_release text, p_size text, p_loc text, p_closes timestamp with time zone, p_code text)
 RETURNS text
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
$function$
;
