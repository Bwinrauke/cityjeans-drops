-- A shared temporary password is convenient to hand out but means anyone who
-- knows it can sign in as anyone else. So an account created (or reset) by an
-- admin is flagged, and the app makes them set their own password before it
-- lets them do anything. See create_staff_account / reset_staff_password /
-- clear_password_flag / me() as applied to the project.
alter table public.admins
  add column if not exists must_change_password boolean not null default false;
