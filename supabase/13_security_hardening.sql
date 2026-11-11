-- NOTE (2026-11-11): applied on live. Do not run it again after 17_remove_sheet_sync.sql: it names the sync tables
-- and functions that 17 removed, so it would stop with an error (and change nothing).
-- Kiroku — 13_security_hardening.sql
-- Locks Supabase down so that every rule is enforced by the database, not by the page.
--
-- WHEN: on the same day as the new index.html (real sign-in only). Order:
--   1. Turn OFF "Allow new users to sign up" (Authentication > Sign In / Providers).
--   2. Publish the new index.html / index-centered.html.
--   3. Run this file (SQL Editor > New query > paste > Run). All or nothing: on any error nothing changes.
--   4. Run 14_security_tests.sql and check that every line says PASS.
--   5. Paste the new apps-script/Sync.gs and JobOrders.gs, then run syncAll once.
-- WAY BACK: 13_rollback.sql puts every grant, policy and function back exactly as found on 2026-11-09.
--
-- Touches no rows. Deletes no table, row, trigger or login. Resets no password.
-- Safe to run twice.
--
-- After this script:
--   not signed in (anon)       nothing at all: no table, no function, no file
--   signed in, not in Kiroku   nothing (a login with no row in public.users)
--   any Kiroku user            reads users, kumiai, companies, job_orders, tasks, activity_logs, task files
--   Admin                      also reads event_logs and sync_runs; edits/reassigns any task; uploads to any task
--   CEO                        reads only; every write function refuses
--   Doc Officer                edits, logs actions and uploads files on tasks assigned to them only
--   direct INSERT/UPDATE/DELETE from the website: impossible for everyone (all writes go through checked functions)
--   the sync (service_role)    unchanged, except it can no longer set auth_user_id or unknown columns

begin;

-- ======================================================================== 1. who is signed in
-- The signed-in person's Kiroku user, or null. Used by every check below.
create or replace function public.is_kiroku_user() returns boolean
language sql stable security definer set search_path = public
as $$ select exists (select 1 from public.users where auth_user_id = auth.uid()) $$;

create or replace function public.is_kiroku_admin() returns boolean
language sql stable security definer set search_path = public
as $$ select exists (select 1 from public.users where auth_user_id = auth.uid() and role = 'Admin') $$;

-- May the signed-in person change this task (edit, log an action, upload a file)?
-- Admin: any task. Doc Officer: only tasks assigned to them. CEO and anyone else: none.
create or replace function public.can_edit_task(p_task_id text) returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (
    select 1 from public.users u
     where u.auth_user_id = auth.uid()
       and (u.role = 'Admin'
            or (u.role = 'Doc Officer'
                and exists (select 1 from public.tasks t where t.task_id = p_task_id and t.editor_id = u.user_id))))
$$;

-- FIX (open sign-up / identity takeover): never link a login by email any more. All six people are
-- already linked through users.auth_user_id. A new person is linked by Admin in the dashboard
-- (see "Adding a new person" in SECURITY_AUDIT.md). This only returns the caller's own profile.
create or replace function public.link_my_account() returns public.users
language sql stable security definer set search_path = public
as $$ select * from public.users where auth_user_id = auth.uid() $$;

-- ======================================================================== 2. table rights
-- FIX (anon SELECT and ALL grants): nobody who is not signed in gets anything. Signed-in users get
-- SELECT only; INSERT/UPDATE/DELETE/TRUNCATE are removed so a later mistake in a policy cannot open writes.
revoke all on all tables    in schema public from anon;
revoke all on all sequences in schema public from anon;
revoke insert, update, delete, truncate, references, trigger on all tables in schema public from authenticated;
revoke all on all sequences in schema public from authenticated;
revoke all on public.sheet_sync_state from authenticated;          -- sync bookkeeping: service_role only
grant  select on public.users, public.kumiai, public.companies, public.job_orders,
                 public.tasks, public.activity_logs, public.event_logs, public.sync_runs to authenticated;

-- Tables created later start closed (Supabase's default grants anon/authenticated ALL on new tables).
-- A future migration must GRANT what it needs. (Defaults owned by supabase_admin cannot be changed from here.)
alter default privileges for role postgres in schema public revoke all on tables    from anon, authenticated;
alter default privileges for role postgres in schema public revoke all on sequences from anon, authenticated;
alter default privileges for role postgres in schema public revoke execute on functions from anon, authenticated;

-- ======================================================================== 3. row security
-- FIX (read policies were "using (true)" for anon and authenticated: anyone who signed up could read all).
do $$
declare
  t   text;
  pol record;
begin
  foreach t in array array['users','kumiai','companies','job_orders','tasks','activity_logs',
                           'event_logs','sync_runs','sheet_sync_state'] loop
    for pol in select policyname from pg_policies where schemaname = 'public' and tablename = t loop
      execute format('drop policy %I on public.%I', pol.policyname, t);
    end loop;
    execute format('alter table public.%I enable row level security', t);
  end loop;

  -- Officers still see every task (the Due Gates and messages show other officers' work). To limit
  -- officers to their own tasks later, change only the tasks and activity_logs policies.
  foreach t in array array['users','kumiai','companies','job_orders','tasks','activity_logs'] loop
    execute format('create policy "kiroku users read %1$s" on public.%1$I for select to authenticated using (public.is_kiroku_user())', t);
  end loop;
  foreach t in array array['event_logs','sync_runs'] loop
    execute format('create policy "admin reads %1$s" on public.%1$I for select to authenticated using (public.is_kiroku_admin())', t);
  end loop;
  -- sheet_sync_state: no policy at all = only service_role.
end $$;

-- ======================================================================== 4. users: roles and logins
-- FIX (sync could write any role text): only the three roles exist.
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'users_role_check') then
    alter table public.users add constraint users_role_check check (role in ('Admin','CEO','Doc Officer'));
  end if;
end $$;

-- FIX (XSS): IDs are put inside the page's buttons (onclick="...('j1')"). An ID with a quote or bracket in it
-- would run as code in everyone's browser. Only letters, digits, _ and - from now on. NOT VALID = existing
-- rows are not re-checked (so this cannot fail the script); every new or changed row is.
do $$
declare
  c record;
begin
  for c in select * from (values
      ('users','user_id'), ('kumiai','kumiai_id'), ('companies','company_id'),
      ('job_orders','jo_id'), ('tasks','task_id')) as x(tbl, col) loop
    if not exists (select 1 from pg_constraint where conname = c.tbl || '_id_format') then
      execute format('alter table public.%I add constraint %I check (%I ~ ''^[A-Za-z0-9_-]{1,64}$'') not valid',
                     c.tbl, c.tbl || '_id_format', c.col);
    end if;
  end loop;
end $$;

-- FIX (sync / API could move a login to another person): auth_user_id can only be set or changed from the
-- Supabase dashboard (SQL Editor or Table Editor), never through the API, not even with the service_role key
-- the sync uses. Also: Kiroku always keeps at least one Admin.
create or replace function public.protect_users() returns trigger
language plpgsql set search_path = ''
as $$
declare
  v_api_role text := nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role';
begin
  if tg_op in ('UPDATE','INSERT') and v_api_role is not null then
    if (tg_op = 'INSERT' and new.auth_user_id is not null)
       or (tg_op = 'UPDATE' and new.auth_user_id is distinct from old.auth_user_id) then
      raise exception 'users.auth_user_id can only be changed by Admin in the Supabase dashboard'
        using errcode = '42501';
    end if;
  end if;
  if (tg_op = 'DELETE' and old.role = 'Admin')
     or (tg_op = 'UPDATE' and old.role = 'Admin' and new.role is distinct from 'Admin') then
    if not exists (select 1 from public.users where role = 'Admin' and user_id <> old.user_id) then
      raise exception 'Kiroku must keep at least one Admin';
    end if;
  end if;
  return case when tg_op = 'DELETE' then old else new end;
end $$;

drop trigger if exists users_protect on public.users;
create trigger users_protect before insert or update or delete on public.users
  for each row execute function public.protect_users();

-- ======================================================================== 5. the sync: only known columns
-- FIX (C4): sync_entity built its INSERT/UPDATE from whatever columns the sheet had. A column named
-- auth_user_id, created_at or done in a sheet would have been written. Now each table has an allow-list,
-- shared tabs are accepted only from the Admin Masterlist, and a Doc Officer sheet can only change
-- task_name, due_date, status and remarks of its own tasks (the same rule Sync.gs applies, now enforced here too).
create or replace function public.sync_entity(
  p_source text, p_run bigint, p_entity text, p_key text, p_rows jsonb
) returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  r        jsonb;
  k        text;
  old_row  jsonb;
  norm     jsonb;
  cols     text;
  f        text;
  changed  boolean;
  allowed  text[];
  v_owner  text;
  n_ins    int := 0;
  n_upd    int := 0;
  n_same   int := 0;
  n_refused int := 0;
begin
  allowed := case p_entity
    when 'users'      then array['user_id','name','role','email']
    when 'kumiai'     then array['kumiai_id','name']
    when 'companies'  then array['company_id','kumiai_id','name']
    when 'job_orders' then array['jo_id','jo_number','company_id','worker_name','target_deployment_date',
                                 'work_category','program_type','active']
    when 'tasks'      then array['task_id','jo_id','track','task_name','sort_order','offset_days',
                                 'editor_id','due_date','status','remarks']
  end;
  if allowed is null then
    raise exception 'sync: % is not a synced table', p_entity;
  end if;
  if p_entity <> 'tasks' and p_source <> 'admin' then
    raise exception 'sync: % can only come from the Admin Masterlist (got %)', p_entity, p_source;
  end if;
  if p_entity = 'tasks' and p_source ~ '^doc-officer-[0-9]+$' then
    v_owner := 'u' || substring(p_source from '[0-9]+$');
  elsif p_entity = 'tasks' and p_source <> 'admin' then
    raise exception 'sync: unknown task source %', p_source;
  end if;

  for r in select value from jsonb_array_elements(p_rows) loop
    -- keep only allowed columns
    select coalesce(jsonb_object_agg(e.key, e.value), '{}'::jsonb) into r
      from jsonb_each(r) e where e.key = any(allowed);

    k := r->>p_key;
    if k is null then
      raise exception 'sync %: row is missing key column %', p_entity, p_key;
    end if;

    execute format('select to_jsonb(t) from public.%I t where t.%I = $1', p_entity, p_key)
      into old_row using k;

    -- a Doc Officer sheet: own tasks only, four fields only
    if v_owner is not null then
      if old_row is null then
        if r->>'editor_id' is distinct from v_owner then
          n_refused := n_refused + 1;
          insert into public.event_logs (event_type, source, action, module, record_id, description, sync_status, source_sheet)
            values ('Sync Failed', 'Google Sheets', 'Refused', 'Tasks', k,
                    'New task from ' || p_source || ' is not assigned to that sheet''s officer; not added', 'Failed', p_source);
          continue;
        end if;
      else
        if old_row->>'editor_id' is distinct from v_owner then
          n_refused := n_refused + 1;
          insert into public.event_logs (event_type, source, action, module, record_id, description, sync_status, source_sheet)
            values ('Sync Failed', 'Google Sheets', 'Refused', 'Tasks', k,
                    p_source || ' tried to change a task assigned to someone else; ignored', 'Failed', p_source);
          continue;
        end if;
        select coalesce(jsonb_object_agg(e.key, e.value), '{}'::jsonb) into r
          from jsonb_each(r) e where e.key in ('task_id','task_name','due_date','status','remarks');
      end if;
    end if;

    execute format('select to_jsonb(x) from jsonb_populate_record(null::public.%I, $1) x', p_entity)
      into norm using r;

    select string_agg(format('%I', c.name), ', ') into cols
      from jsonb_object_keys(r) as c(name);

    if old_row is null then
      execute format(
        'insert into public.%1$I (%2$s) select %2$s from jsonb_populate_record(null::public.%1$I, $1)',
        p_entity, cols) using r;
      insert into public.event_logs (event_type, source, action, module, record_id, description, source_sheet)
        values ('Record Created', 'Google Sheets', 'Create', initcap(replace(p_entity, '_', ' ')), k,
                initcap(replace(p_entity, '_', ' ')) || ' record added', p_source);
      n_ins := n_ins + 1;
    else
      changed := false;
      for f in select c.name from jsonb_object_keys(r) as c(name) loop
        if old_row->>f is distinct from norm->>f then
          insert into public.event_logs
            (event_type, source, action, module, record_id, field_changed, old_value, new_value, description, source_sheet)
          values ('Record Updated', 'Google Sheets', 'Update', initcap(replace(p_entity, '_', ' ')), k,
                  initcap(replace(f, '_', ' ')), old_row->>f, norm->>f,
                  initcap(replace(f, '_', ' ')) || ' updated', p_source);
          changed := true;
        end if;
      end loop;

      if changed then
        execute format(
          'update public.%1$I t set (%2$s) = (select %2$s from jsonb_populate_record(null::public.%1$I, $1)) where t.%3$I = $2',
          p_entity, cols, p_key) using r, k;
        n_upd := n_upd + 1;
      else
        n_same := n_same + 1;
      end if;
    end if;
  end loop;

  return jsonb_build_object('inserted', n_ins, 'updated', n_upd, 'unchanged', n_same, 'refused', n_refused);
end $$;

-- ======================================================================== 6. writing from the app
-- FIX (C2): the 06 version trusted e->>'user_id' from the page. Now: always the signed-in user,
-- CEO refused, a Doc Officer only on their own tasks (also for job-order-level entries).
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
    raise exception 'log_task_activity: sign in first' using errcode = '42501';
  end if;
  if v_user.role not in ('Admin','Doc Officer') then
    raise exception 'log_task_activity: the CEO view is read only' using errcode = '42501';
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
        raise exception 'log_task_activity: this task is assigned to someone else' using errcode = '42501';
      end if;
    else
      select jo_id into v_jo from public.job_orders where jo_id = e->>'jo_id';
      if v_jo is null then
        raise exception 'log_task_activity: unknown job order %', coalesce(e->>'jo_id', '(none)');
      end if;
      if v_user.role <> 'Admin'
         and not exists (select 1 from public.tasks where jo_id = v_jo and editor_id = v_user.user_id) then
        raise exception 'log_task_activity: you have no task on this job order' using errcode = '42501';
      end if;
    end if;

    -- A client_ref belongs to whoever stored it first; nobody can read back someone else's row by reusing it.
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
      select * into v_row from public.activity_logs where client_ref = v_ref and user_id = v_user.user_id;
      if v_row.activity_id is null then
        raise exception 'log_task_activity: duplicate client_ref';
      end if;
    end if;
    return next v_row;
  end loop;
end $$;

-- FIX (C2): update_task_fields already prefers auth.uid(); open mode let anon name any user (p_user_id).
-- Open mode off = p_user_id is ignored and only the signed-in user counts.
create or replace function public.kiroku_open_mode() returns boolean
language sql stable set search_path = '' as $$ select false $$;

-- ======================================================================== 7. who may call which function
-- FIX: anon could call most functions. Trigger functions run without EXECUTE, so revoking is safe.
revoke execute on all functions in schema public from public, anon, authenticated;
grant  execute on function public.is_kiroku_user()          to authenticated;   -- used by row security
grant  execute on function public.is_kiroku_admin()         to authenticated;   -- used by row security
grant  execute on function public.can_edit_task(text)       to authenticated;   -- used by Storage rules
grant  execute on function public.link_my_account()         to authenticated;
grant  execute on function public.log_task_activity(jsonb)  to authenticated;
grant  execute on function public.update_task_fields(text, text, jsonb, timestamptz) to authenticated;
-- the sync key keeps what it had
grant  execute on all functions in schema public to service_role;

-- 15_entries_stages.sql (My Entries, stages, masterlist): keep it working when this file is run again after it.
-- Its functions check the signed-in user and role themselves; anon still gets nothing.
do $$
begin
  if to_regclass('public.stage_config') is not null then
    grant select on public.track_config, public.stage_config to authenticated;
  end if;
  if to_regprocedure('public.create_job_order(text, text, text, text, date)') is not null then
    grant execute on function public.admin_save_kumiai(text, text, text)                       to authenticated;
    grant execute on function public.admin_save_company(text, text, text, text)                to authenticated;
    grant execute on function public.admin_save_stage(text, int, text, int, text, int, text)  to authenticated;
    grant execute on function public.admin_delete_stage(text, int)                             to authenticated;
    grant execute on function public.create_job_order(text, text, text, text, date)          to authenticated;
    grant execute on function public.update_job_order(text, text, text, text, text, date)    to authenticated;
  end if;
end $$;

-- pinned search_path on the three that had none
alter function public.touch_updated_at()          set search_path = '';
alter function public.activity_logs_append_only() set search_path = '';

-- ======================================================================== 8. audit logs
-- activity_logs: unchanged (append-only, even for service_role).
-- event_logs: row UPDATE/DELETE was already blocked by protect_event_logs; TRUNCATE was not.
create or replace function public.event_logs_no_truncate() returns trigger
language plpgsql set search_path = ''
as $$ begin raise exception 'event_logs is append-only: it cannot be emptied'; end $$;
revoke execute on function public.event_logs_no_truncate() from public, anon, authenticated;

drop trigger if exists event_logs_no_truncate on public.event_logs;
create trigger event_logs_no_truncate before truncate on public.event_logs
  for each statement execute function public.event_logs_no_truncate();

-- ======================================================================== 9. task files (Storage)
-- FIX: anon could read every file and upload into any task's folder.
-- Now: Kiroku users read; only someone who may edit the task uploads into its folder. No update/delete.
drop policy if exists "task-files upload" on storage.objects;
drop policy if exists "task-files read"   on storage.objects;
create policy "task-files read" on storage.objects for select to authenticated
  using (bucket_id = 'task-files' and public.is_kiroku_user());
create policy "task-files upload" on storage.objects for insert to authenticated
  with check (bucket_id = 'task-files' and public.can_edit_task((storage.foldername(name))[1]));

commit;
