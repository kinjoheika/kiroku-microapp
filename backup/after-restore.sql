-- Kiroku: run right after a FULL restore of a backup (backup/README.md, "Restore everything").
-- Supabase dashboard > SQL Editor > New query > paste > Run. Safe to run twice.
-- A backup holds everything in Kiroku's part of the database (schema public). Three things live outside it and
-- are lost when that part is replaced; this puts them back:
--   1. the rules for task files (Storage), which use Kiroku's checks
--   2. live updates of the activity list (Realtime)
--   3. "automatically enable RLS on new tables" (the ensure_rls event trigger)
-- Afterwards run supabase/14_security_tests.sql: every row must say PASS.

begin;

grant usage on schema public to anon, authenticated, service_role;

-- 1. task files: Kiroku users read; only someone who may edit the task uploads into its folder (as in 13)
drop policy if exists "task-files upload" on storage.objects;
drop policy if exists "task-files read"   on storage.objects;
create policy "task-files read" on storage.objects for select to authenticated
  using (bucket_id = 'task-files' and public.is_kiroku_user());
create policy "task-files upload" on storage.objects for insert to authenticated
  with check (bucket_id = 'task-files' and public.can_edit_task((storage.foldername(name))[1]));

-- 2. live updates of the activity list
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (select 1 from pg_publication_tables
                      where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'activity_logs') then
    alter publication supabase_realtime add table public.activity_logs;
  end if;
end $$;

-- 3. RLS on every new table
do $$
begin
  if to_regprocedure('public.rls_auto_enable()') is not null
     and not exists (select 1 from pg_event_trigger where evtname = 'ensure_rls') then
    create event trigger ensure_rls on ddl_command_end
      when tag in ('CREATE TABLE', 'CREATE TABLE AS', 'SELECT INTO')
      execute function public.rls_auto_enable();
  end if;
end $$;

commit;
