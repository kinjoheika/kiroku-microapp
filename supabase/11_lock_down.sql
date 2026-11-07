-- Kiroku V4 — sign-in required, Admin-only logs. Enforced by Supabase, not just the page.
-- Run LAST, after the new index.html is live and every user can sign in.
-- From this moment the old page and anyone who is not signed in can read nothing.
-- Changes access only: no data is touched. Safe to run twice.
-- See supabase/SETUP.md ("Admin Masterlist and logins"), which also has the way back.
--
-- After this script:
--   anyone not signed in   nothing
--   any Kiroku user        reads users, kumiai, companies, job_orders, tasks, activity_logs, task files
--   Admin only             reads event_logs and sync_runs (the Sync Logs page)
--   writes                 only through log_task_activity(), for tasks the user may act on
--   the sync               uses the service_role key, which is not affected
-- activity_logs stays readable by every user because each task's Notes, Messages, Files and
-- Recent Actions are built from it. Configuration > Event Logs is hidden from everyone but Admin.

-- ---------------------------------------------------------------- tables
do $$
declare
  t   text;
  pol record;
begin
  foreach t in array array['users','kumiai','companies','job_orders','tasks','sync_runs','event_logs','activity_logs'] loop
    for pol in select policyname from pg_policies where schemaname = 'public' and tablename = t loop
      execute format('drop policy %I on public.%I', pol.policyname, t);
    end loop;
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon', t);
    execute format('grant select on public.%I to authenticated', t);
  end loop;

  foreach t in array array['users','kumiai','companies','job_orders','tasks','activity_logs'] loop
    execute format('create policy "kiroku users read %1$s" on public.%1$I for select to authenticated using (public.is_kiroku_user())', t);
  end loop;
  foreach t in array array['sync_runs','event_logs'] loop
    execute format('create policy "admin reads %1$s" on public.%1$I for select to authenticated using (public.is_kiroku_admin())', t);
  end loop;
end $$;

-- ---------------------------------------------------------------- task files
drop policy if exists "task-files upload" on storage.objects;
drop policy if exists "task-files read" on storage.objects;
create policy "task-files upload" on storage.objects for insert to authenticated
  with check (
    bucket_id = 'task-files'
    and public.is_kiroku_user()
    and (storage.foldername(name))[1] in (select task_id from public.tasks)
  );
create policy "task-files read" on storage.objects for select to authenticated
  using (bucket_id = 'task-files' and public.is_kiroku_user());

-- ---------------------------------------------------------------- writing actions
-- Same as 06_activity_logs.sql, except:
--   * who = always the signed-in user; what the page sends is ignored
--   * Admin may act on any task, a Doc Officer on their own, the CEO on none
create or replace function public.log_task_activity(p_entries jsonb)
returns setof public.activity_logs
language plpgsql security definer set search_path = public
as $$
declare
  e        jsonb;
  v_user   public.users;
  v_jo     text;
  v_editor text;
  v_ref    uuid;
  v_row    public.activity_logs;
begin
  if jsonb_typeof(p_entries) is distinct from 'array'
     or jsonb_array_length(p_entries) not between 1 and 50 then
    raise exception 'log_task_activity: send 1 to 50 entries';
  end if;

  select * into v_user from public.users where auth_user_id = auth.uid();
  if v_user.user_id is null then
    raise exception 'log_task_activity: sign in first';
  end if;
  if v_user.role = 'CEO' then
    raise exception 'log_task_activity: the CEO view is read only';
  end if;

  for e in select value from jsonb_array_elements(p_entries) loop
    v_jo     := null;
    v_editor := null;
    v_row    := null;
    v_ref    := nullif(e->>'client_ref', '')::uuid;

    if nullif(e->>'task_id', '') is not null then
      select jo_id, editor_id into v_jo, v_editor from public.tasks where task_id = e->>'task_id';
      if v_jo is null then
        raise exception 'log_task_activity: unknown task %', e->>'task_id';
      end if;
      if v_user.role <> 'Admin' and v_editor is distinct from v_user.user_id then
        raise exception 'log_task_activity: this task is assigned to someone else';
      end if;
    else
      select jo_id into v_jo from public.job_orders where jo_id = e->>'jo_id';
      if v_jo is null then
        raise exception 'log_task_activity: unknown job order %', coalesce(e->>'jo_id', '(none)');
      end if;
    end if;

    insert into public.activity_logs
      (client_ref, task_id, jo_id, user_id, user_name, action_type,
       action_details, previous_status, updated_status)
    values
      (v_ref, nullif(e->>'task_id', ''), v_jo, v_user.user_id, v_user.name, e->>'action_type',
       left(nullif(e->>'details', ''), 2000),
       left(nullif(e->>'previous_status', ''), 60),
       left(nullif(e->>'updated_status', ''), 60))
    on conflict (client_ref) do nothing
    returning * into v_row;

    if v_row.activity_id is null then
      select * into v_row from public.activity_logs where client_ref = v_ref;
    end if;
    return next v_row;
  end loop;
end $$;

revoke execute on function public.log_task_activity(jsonb) from public, anon;
grant  execute on function public.log_task_activity(jsonb) to authenticated, service_role;

-- Editing a task (12_task_status.sql): from now on only the signed-in user counts.
-- Run 12_task_status.sql before this script.
create or replace function public.kiroku_open_mode() returns boolean
language sql stable as $$ select false $$;
revoke execute on function public.update_task_fields(text, text, jsonb, timestamptz) from public, anon;
grant  execute on function public.update_task_fields(text, text, jsonb, timestamptz) to authenticated, service_role;
