-- Pin search_path on the helper functions (advisor 0011).
alter function public.norm_email(text)     set search_path = public, pg_temp;
alter function public.norm_phone(text)     set search_path = public, pg_temp;
alter function public.gen_code()           set search_path = public, pg_temp;
alter function public.touch_updated_at()   set search_path = public, pg_temp;

-- is_admin() only ever runs for a signed-in admin; anon has no use for it.
revoke execute on function public.is_admin() from anon;

-- reserve_spot / lookup_reservation are intentionally public (that IS the
-- customer API); redeem_reservation stays authenticated-only and checks
-- is_admin() internally.
revoke execute on function public.redeem_reservation(text) from anon;
