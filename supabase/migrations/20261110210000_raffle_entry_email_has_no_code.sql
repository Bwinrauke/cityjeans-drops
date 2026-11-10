-- An entry gets no code: only a winner does, in the winner email. The entry
-- email leaves out the YOUR CODE line (which is also what draws the code box in
-- the HTML email) and says plainly that this is not a reservation and that the
-- winner email is the one that counts. render_notification still returns the
-- entry's code under 'code'; nothing shows it.
create or replace function public.entered_email_body(p_fname text, p_release text,
  p_size text, p_loc text, p_closes timestamptz, p_code text)
returns text
language sql stable set search_path = public, pg_temp
as $$
  select 'Hi ' || p_fname || E',\n\n'
      || 'You''re entered in the raffle for ' || p_release || ', size ' || p_size || '.' || E'\n\n'
      || 'THIS IS A RAFFLE ENTRY, NOT A RESERVATION.' || E'\n'
      || 'You don''t have a pair yet, and there is no code to bring to the store.' || E'\n\n'
      || 'IF YOU WIN, WE''LL EMAIL YOU.' || E'\n'
      || 'That email has your pickup code, your store and your pickup day. '
      || 'It''s the only thing you''ll need. If you''re not selected, we''ll email you that too.'
      || case when p_closes is not null then E'\n\n' || 'Entries close '
           || to_char(p_closes at time zone 'America/New_York', 'Dy Mon DD, HH12:MI AM')
           || '. The draw happens after that.' else '' end || E'\n\n'
      || 'Results come by email only — not text, not a call. Add us to your contacts '
      || 'so it doesn''t land in spam.' || E'\n\n'
      || 'One entry per person. If you enter more than once — another email, '
      || 'the same phone, the same Instagram — every one of your entries is disqualified.' || E'\n\n'
      || 'You don''t need to check back.';
$$;
