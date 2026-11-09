-- Kiroku — 13_rollback.sql: undo 13_security_hardening.sql.
-- Puts every grant, policy, function and trigger back EXACTLY as 00_security_check.sql found them on 2026-11-09.
-- WARNING: that state is the INSECURE one (anon reads users and activity_logs, anyone can upload files,
-- anyone who signs up reads everything). Use it only to get Kiroku working again while a problem is fixed,
-- then run 13_security_hardening.sql again.
-- Touches no rows. All or nothing.

begin;

-- ---------------------------------------------------------------- objects 13 added
drop policy  if exists "task-files read"   on storage.objects;
drop policy  if exists "task-files upload" on storage.objects;
drop trigger if exists users_protect          on public.users;
drop trigger if exists event_logs_no_truncate on public.event_logs;
drop function if exists public.protect_users();
drop function if exists public.event_logs_no_truncate();
drop function if exists public.can_edit_task(text);
alter table public.users drop constraint if exists users_role_check;
alter table public.users      drop constraint if exists users_id_format;
alter table public.kumiai     drop constraint if exists kumiai_id_format;
alter table public.companies  drop constraint if exists companies_id_format;
alter table public.job_orders drop constraint if exists job_orders_id_format;
alter table public.tasks      drop constraint if exists tasks_id_format;

-- ---------------------------------------------------------------- functions: old bodies
create or replace function public.kiroku_open_mode() returns boolean
language sql stable as $$ select true $$;
alter function public.kiroku_open_mode() reset search_path;
alter function public.touch_updated_at() reset search_path;
alter function public.activity_logs_append_only() reset search_path;

-- link_my_account as in 10_admin_masterlist.sql
create or replace function public.link_my_account() returns public.users
language plpgsql security definer set search_path = public
as $$
declare
  v_user  public.users;
  v_email text;
begin
  if auth.uid() is null then return null; end if;
  select * into v_user from public.users where auth_user_id = auth.uid();
  if v_user.user_id is not null then return v_user; end if;

  select lower(email) into v_email from auth.users where id = auth.uid() and email_confirmed_at is not null;
  if v_email is null then return null; end if;
  update public.users set auth_user_id = auth.uid()
   where lower(email) = v_email and auth_user_id is null
  returning * into v_user;
  return v_user;
end $$;

-- log_task_activity as in 06_activity_logs.sql (the version that was live)
create or replace function public.log_task_activity(p_entries jsonb)
returns setof public.activity_logs
language plpgsql security definer set search_path = public
as $$
declare
  e      jsonb;
  v_user public.users;
  v_jo   text;
  v_ref  uuid;
  v_row  public.activity_logs;
begin
  if jsonb_typeof(p_entries) is distinct from 'array'
     or jsonb_array_length(p_entries) not between 1 and 50 then
    raise exception 'log_task_activity: send 1 to 50 entries';
  end if;

  for e in select value from jsonb_array_elements(p_entries) loop
    v_user := null;
    v_jo   := null;
    v_row  := null;
    v_ref  := nullif(e->>'client_ref', '')::uuid;

    if auth.uid() is not null then
      select * into v_user from public.users where auth_user_id = auth.uid();
    end if;
    if v_user.user_id is null then
      select * into v_user from public.users where user_id = e->>'user_id';
    end if;
    if v_user.user_id is null then
      raise exception 'log_task_activity: unknown user %', coalesce(e->>'user_id', '(none)');
    end if;

    if nullif(e->>'task_id', '') is not null then
      select jo_id into v_jo from public.tasks where task_id = e->>'task_id';
      if v_jo is null then
        raise exception 'log_task_activity: unknown task %', e->>'task_id';
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

-- sync_entity as in 03_sync.sql
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
  n_ins    int := 0;
  n_upd    int := 0;
  n_same   int := 0;
begin
  for r in select value from jsonb_array_elements(p_rows) loop
    k := r->>p_key;
    if k is null then
      raise exception 'sync %: row is missing key column %', p_entity, p_key;
    end if;

    execute format('select to_jsonb(t) from public.%I t where t.%I = $1', p_entity, p_key)
      into old_row using k;

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

  return jsonb_build_object('inserted', n_ins, 'updated', n_upd, 'unchanged', n_same);
end $$;

-- ---------------------------------------------------------------- function rights as found
revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on function public.activity_action_type(text)                    to public;
grant execute on function public.activity_import_key(text, text, date, time)   to public;
grant execute on function public.activity_logs_append_only()                   to public;
grant execute on function public.apply_task_status_from_log()                  to public;
grant execute on function public.is_kiroku_admin()                             to public;
grant execute on function public.is_kiroku_user()                              to public;
grant execute on function public.keep_task_status_in_step()                    to public;
grant execute on function public.kiroku_open_mode()                            to public;
grant execute on function public.protect_event_logs()                          to public;
grant execute on function public.touch_updated_at()                            to public;
grant execute on function public.link_my_account()                             to authenticated;
-- import_sheet_activity, log_task_activity, sync_entity, sync_import, update_task_fields: service_role only (as found)
grant execute on all functions in schema public to service_role;

-- ---------------------------------------------------------------- table rights as found
revoke all on all tables in schema public from anon, authenticated;
grant references, select, trigger                                on public.activity_logs    to anon, authenticated;
grant delete, insert, references, select, trigger, truncate, update on public.companies     to anon, authenticated;
grant references, trigger, truncate                              on public.event_logs       to anon, authenticated;
grant delete, insert, references, trigger, truncate, update      on public.job_orders       to anon;
grant delete, insert, references, select, trigger, truncate, update on public.job_orders    to authenticated;
grant delete, insert, references, select, trigger, truncate, update on public.kumiai        to anon, authenticated;
grant delete, insert, references, select, trigger, truncate, update on public.sheet_sync_state to anon, authenticated;
grant delete, insert, references, select, trigger, truncate, update on public.sync_runs     to anon, authenticated;
grant delete, insert, references, trigger, truncate, update      on public.tasks            to anon;
grant delete, insert, references, select, trigger, truncate, update on public.tasks         to authenticated;
grant delete, insert, references, select, trigger, truncate, update on public.users         to anon, authenticated;
grant usage, select, update on all sequences in schema public to anon, authenticated;

alter default privileges for role postgres in schema public grant all on tables    to anon, authenticated;
alter default privileges for role postgres in schema public grant all on sequences to anon, authenticated;
alter default privileges for role postgres in schema public grant execute on functions to anon, authenticated;

-- ---------------------------------------------------------------- policies as found
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
  end loop;
  foreach t in array array['activity_logs','companies','event_logs','job_orders','kumiai','sync_runs','users'] loop
    execute format('create policy "read %1$s" on public.%1$I for select to anon, authenticated using (true)', t);
  end loop;
end $$;
create policy "authenticated_read_tasks" on public.tasks for select to authenticated using (true);

create policy "task-files upload" on storage.objects for insert to anon, authenticated
  with check (bucket_id = 'task-files' and (storage.foldername(name))[1] in (select task_id from public.tasks));
create policy "task-files read" on storage.objects for select to anon, authenticated
  using (bucket_id = 'task-files');

commit;
