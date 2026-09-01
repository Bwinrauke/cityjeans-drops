-- Public bucket that holds the two app pages. Supabase rewrites text/html to
-- text/plain on its own domain, so the pages are served through the `app` edge
-- function rather than straight from storage.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('web', 'web', true, 5242880,
        array['text/html','application/javascript','text/css','image/png','image/svg+xml','image/x-icon'])
on conflict (id) do update set public = true,
  allowed_mime_types = excluded.allowed_mime_types,
  file_size_limit = excluded.file_size_limit;

create policy web_public_read on storage.objects
  for select to anon, authenticated using (bucket_id = 'web');
create policy web_admin_write on storage.objects
  for insert to authenticated with check (bucket_id = 'web' and public.is_admin());
create policy web_admin_update on storage.objects
  for update to authenticated using (bucket_id = 'web' and public.is_admin());
create policy web_admin_delete on storage.objects
  for delete to authenticated using (bucket_id = 'web' and public.is_admin());
