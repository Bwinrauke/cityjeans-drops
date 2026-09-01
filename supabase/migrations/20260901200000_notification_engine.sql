-- Notification queue: confirmation, reminder, expiring, raffle result.
--
-- Rows are written by reserve_spot and by enqueue_due_notifications(); the
-- send-notifications edge function drains them on a schedule. When and what
-- live here in SQL, so swapping provider only touches the edge function.
--
-- Applied to the project:
--   notifications gains send_after, attempts, locked_at, subject, body
--   unique (reservation_id, channel, template)  -- one of each kind, ever
--   render_notification(id)        builds subject + body from the reservation
--   enqueue_due_notifications()    queues reminders and last-call notices
--   claim_notifications(limit)     service-role only; skips cancelled/archived
--   complete_notification(id, ok)  marks sent, or retries up to 5 times
alter table public.notifications
  add column if not exists send_after  timestamptz not null default now(),
  add column if not exists attempts    int         not null default 0,
  add column if not exists locked_at   timestamptz,
  add column if not exists subject     text,
  add column if not exists body        text;
create unique index if not exists notifications_once
  on public.notifications(reservation_id, channel, template);
create index if not exists notifications_due_idx
  on public.notifications(status, send_after) where status = 'queued';
