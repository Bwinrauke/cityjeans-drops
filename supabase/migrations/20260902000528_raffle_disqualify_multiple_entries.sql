-- One person, one entry. Extra entries are now accepted at the form rather
-- than refused — you get to see who tried — and every entry that person made
-- is passed over when the draw runs.
alter type public.entry_status add value if not exists 'disqualified';
