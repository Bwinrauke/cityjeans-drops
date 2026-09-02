-- SECURITY: nearly every function in public still carried the implicit PUBLIC
-- EXECUTE grant, so anon could call SECURITY DEFINER internals directly —
-- claim_notifications (dumps codes + emails), mark_missed_pickups /
-- apply_no_show_suspensions (mass-sabotage), active_suspension (PII oracle),
-- complete_notification (forge send status). The RPCs' own is_manager/is_owner
-- checks stopped the privileged ones, but the notification and sweep internals
-- had no check because they were only ever meant to run as the table owner
-- from cron or from a gated wrapper.
--
-- Fix once, globally: take EXECUTE away from everyone, then hand back only the
-- endpoints the two pages actually call. Definer functions still call their
-- helpers internally as the owner, so revoking the helpers breaks nothing.
revoke execute on all functions in schema public from public, anon, authenticated;

-- What the customer page (anon, and staff who are also authenticated) needs:
grant execute on function public.get_availability(text)                       to anon, authenticated;
grant execute on function public.list_open_releases()                         to anon, authenticated;
grant execute on function public.current_raffle_rules()                       to anon, authenticated;
grant execute on function public.lookup_reservation(text, text)               to anon, authenticated;
grant execute on function public.lookup_entry(text, text)                     to anon, authenticated;
grant execute on function public.reserve_spot(text,uuid,text,text,text,text,text)          to anon, authenticated;
grant execute on function public.enter_raffle(text,uuid,text,text,text,text,text,boolean)  to anon, authenticated;

-- What the admin panel needs — signed-in only. Each one still runs its own
-- is_admin / is_manager / is_owner check inside; this grant just lets an
-- authenticated session reach it at all.
grant execute on function public.me()                                         to authenticated;
grant execute on function public.redeem_reservation(text, uuid, boolean, text) to authenticated;
grant execute on function public.archive_reservations(uuid[], uuid, timestamptz, boolean, boolean) to authenticated;
grant execute on function public.raffle_stats(uuid)                           to authenticated;
grant execute on function public.run_raffle_draw(uuid)                        to authenticated;
grant execute on function public.save_raffle_rules(text)                      to authenticated;
grant execute on function public.list_suspensions(boolean)                    to authenticated;
grant execute on function public.lift_suspension(uuid, text)                  to authenticated;
grant execute on function public.sweep_no_shows_now()                         to authenticated;
grant execute on function public.list_staff()                                 to authenticated;
grant execute on function public.create_staff_account(text, text, text, text) to authenticated;
grant execute on function public.reset_staff_password(text, text)             to authenticated;
grant execute on function public.revoke_user(text)                            to authenticated;
grant execute on function public.clear_password_flag()                        to authenticated;
