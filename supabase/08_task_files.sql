-- Kiroku V4 — task file uploads (Supabase Storage bucket task-files).
-- Run once in: Supabase dashboard > SQL Editor > New query > paste > Run.
-- Run after 06_activity_logs.sql. Does not change any existing table.
--
-- The Upload button stores the file first, then writes an Upload row to activity_logs
-- through log_task_activity(). The file lives at  task-files/<task_id>/<client_ref>,
-- where client_ref is that activity row's client_ref, and the row's action_details holds
-- the original file name. So every file belongs to exactly one logged upload.
--
-- Files are permanent, like activity_logs: there is no update or delete policy, so the page
-- can neither overwrite nor remove a file.

-- ---------------------------------------------------------------- bucket
-- Private: files are read through the Storage API with the page's key, not through public links.
-- 10 MB per file.
insert into storage.buckets (id, name, public, file_size_limit)
values ('task-files', 'task-files', false, 10485760)
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit;

-- ---------------------------------------------------------------- access
-- Upload: only into the folder of a task that exists.
create policy "task-files upload" on storage.objects for insert to anon, authenticated
  with check (
    bucket_id = 'task-files'
    and (storage.foldername(name))[1] in (select task_id from public.tasks)
  );

-- Read: anyone with the publishable key, the same as the other tables.
-- Restrict this to signed-in users when Supabase Auth is added.
create policy "task-files read" on storage.objects for select to anon, authenticated
  using (bucket_id = 'task-files');
