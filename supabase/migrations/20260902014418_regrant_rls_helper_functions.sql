-- The blanket revoke was too broad: is_admin/is_manager/is_owner are called
-- from inside RLS policies, and a policy predicate runs as the CURRENT role,
-- not as a definer — so `authenticated` must be able to execute them or every
-- gated table read returns "permission denied for function is_admin". These
-- three only read public.admins for the current uid, so exposing them leaks
-- nothing an authenticated user could not already infer about themselves.
grant execute on function public.is_admin()   to authenticated;
grant execute on function public.is_manager() to authenticated;
grant execute on function public.is_owner()   to authenticated;
