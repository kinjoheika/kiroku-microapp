-- Kiroku — 14_security_tests.sql: proves who can and cannot do what. CHANGES NOTHING.
-- SQL Editor > New query > paste > Run. Run it before 13 (to see today's holes) and after 13 (all PASS).
--
-- For each test it becomes that person exactly the way a signed-in browser is seen by Supabase
-- (role "authenticated" + their login id in the token), runs one statement, and records "allowed" or
-- "refused". Every test ends by throwing an error on purpose, so anything it wrote is undone at once.
-- No passwords are used. Results: one table, one row per test. Look for FAIL.

create temp table if not exists kiroku_test_results (
  n int, who text, test text, expected text, got text, result text);
truncate kiroku_test_results;

do $$
declare
  p        record;
  t        record;
  v_n      int := 0;
  v_got    text;
  v_cnt    bigint;
  v_own    text;
  v_other  text;
  v_any    text;
  v_jo     text;
  v_claims text;
  v_role   text;
begin
  select task_id into v_any from public.tasks order by task_id limit 1;
  select jo_id   into v_jo  from public.tasks where task_id = v_any;

  for p in
    select 'anon (not signed in)' as who, 'anon' as db_role, null::uuid as uid, null::text as user_id, 'anon' as role
    union all
    select u.name || ' (' || u.role || ')', 'authenticated', u.auth_user_id, u.user_id, u.role
      from public.users u where u.auth_user_id is not null
    union all
    select 'stranger (signed up, not in Kiroku)', 'authenticated', '5bd0f5c1-0000-4000-8000-0000deadbeef'::uuid, null, 'stranger'
  loop
    v_own   := (select task_id from public.tasks where editor_id = p.user_id order by task_id limit 1);
    v_other := (select task_id from public.tasks where editor_id is not null and editor_id is distinct from p.user_id
                 order by task_id limit 1);
    v_claims := json_build_object('role', p.db_role, 'sub', p.uid)::text;

    for t in
      -- label, sql, expected: 'rows>0' | 'rows=0' | 'allowed' | 'refused'
      select * from (values
        ('read users',            'select count(*) from public.users',
           case when p.role in ('Admin','CEO','Doc Officer') then 'rows>0' else 'refused|rows=0' end),
        ('read tasks',            'select count(*) from public.tasks',
           case when p.role in ('Admin','CEO','Doc Officer') then 'rows>0' else 'refused|rows=0' end),
        ('read activity_logs',    'select count(*) from public.activity_logs',
           case when p.role in ('Admin','CEO','Doc Officer') then 'rows>0' else 'refused|rows=0' end),
        ('read companies',        'select count(*) from public.companies',
           case when p.role in ('Admin','CEO','Doc Officer') then 'rows>0' else 'refused|rows=0' end),
        ('read event_logs',       'select count(*) from public.event_logs',
           case when p.role = 'Admin' then 'rows>0' else 'refused|rows=0' end),
        ('read sync_runs',        'select count(*) from public.sync_runs',
           case when p.role = 'Admin' then 'rows>0' else 'refused|rows=0' end),
        ('read sheet_sync_state', 'select count(*) from public.sheet_sync_state', 'refused|rows=0'),
        ('make myself Admin (direct update)',
           format('update public.users set role = %L where user_id = %L', 'Admin', coalesce(p.user_id, 'u1')), 'refused|rows=0'),
        ('take over Admin login (direct update)',
           format('update public.users set auth_user_id = %L where user_id = %L', coalesce(p.uid::text, gen_random_uuid()::text), 'u6'), 'refused|rows=0'),
        ('edit a task directly (bypass functions)',
           format('update public.tasks set status = %L where task_id = %L', 'Completed', v_any), 'refused|rows=0'),
        ('insert activity_logs directly',
           format('insert into public.activity_logs (jo_id, user_id, user_name, action_type) values (%L, %L, %L, %L)',
                  v_jo, 'u6', 'Admin', 'Log Note'), 'refused'),
        ('delete event_logs',     'delete from public.event_logs where id = (select min(id) from public.event_logs)', 'refused|rows=0'),
        ('delete activity_logs',  'delete from public.activity_logs where activity_id = (select min(activity_id) from public.activity_logs)', 'refused|rows=0'),
        ('edit OWN task (function)',
           case when v_own is null then null
                else format('select public.update_task_fields(%L, null, jsonb_build_object(%L, %L), null)', v_own, 'status', 'In Progress') end,
           case when p.role in ('Admin','Doc Officer') then 'allowed' else 'refused' end),
        ('edit ANOTHER officer''s task (function)',
           format('select public.update_task_fields(%L, null, jsonb_build_object(%L, %L), null)', v_other, 'status', 'In Progress'),
           case when p.role = 'Admin' then 'allowed' else 'refused' end),
        ('impersonate Admin via p_user_id = u6',
           format('select public.update_task_fields(%L, %L, jsonb_build_object(%L, %L), null)', v_other, 'u6', 'status', 'In Progress'),
           case when p.role = 'Admin' then 'allowed' else 'refused' end),
        ('reassign a task to someone else',
           format('select public.update_task_fields(%L, null, jsonb_build_object(%L, %L), null)', coalesce(v_own, v_other), 'editor_id',
                  (select user_id from public.users where role = 'Doc Officer' and user_id is distinct from p.user_id order by user_id limit 1)),
           case when p.role = 'Admin' then 'allowed' else 'refused' end),
        ('log a note on OWN task',
           case when v_own is null then null
                else format('select * from public.log_task_activity(%L::jsonb)',
                            json_build_array(json_build_object('task_id', v_own, 'action_type', 'Log Note', 'details', 'security test'))) end,
           case when p.role in ('Admin','Doc Officer') then 'allowed' else 'refused' end),
        ('log a note on ANOTHER officer''s task, as u6',
           format('select * from public.log_task_activity(%L::jsonb)',
                  json_build_array(json_build_object('task_id', v_other, 'user_id', 'u6', 'action_type', 'Mark Done'))),
           case when p.role = 'Admin' then 'allowed' else 'refused' end),
        ('upload a file to ANOTHER officer''s task',
           format('insert into storage.objects (bucket_id, name) values (%L, %L)', 'task-files', v_other || '/security-test'),
           case when p.role = 'Admin' then 'allowed' else 'refused' end),
        ('read task files',       'select count(*) from storage.objects where bucket_id = ''task-files''',
           case when p.role in ('Admin','CEO','Doc Officer') then 'allowed|rows=0|rows>0' else 'refused|rows=0' end)
      ) as x(label, sql, expected)
    loop
      continue when t.sql is null;
      v_n := v_n + 1;
      begin
        perform set_config('request.jwt.claims', v_claims, true);
        perform set_config('request.jwt.claim.sub', coalesce(p.uid::text, ''), true);
        execute format('set local role %I', p.db_role);
        if t.sql ~* '^\s*select count' then
          execute t.sql into v_cnt;
          v_got := case when v_cnt > 0 then 'rows>0' else 'rows=0' end;
        elsif t.sql ~* '^\s*(update|delete)' then
          execute t.sql;
          get diagnostics v_cnt = row_count;
          v_got := case when v_cnt > 0 then 'allowed' else 'rows=0' end;
        else
          execute t.sql;
          v_got := 'allowed';
        end if;
        raise exception 'KIROKU_TEST_UNDO';           -- undo whatever the test did
      exception when others then
        if sqlerrm <> 'KIROKU_TEST_UNDO' then
          v_got := 'refused';
          v_role := left(sqlerrm, 90);
        else
          v_role := null;
        end if;
      end;
      -- back to the SQL Editor's own role here (the error above undid "set local role")
      insert into kiroku_test_results values (v_n, p.who, t.label, t.expected,
        v_got || coalesce(' — ' || v_role, ''),
        case when v_got = any(string_to_array(t.expected, '|')) then 'PASS' else 'FAIL' end);
    end loop;
  end loop;
end $$;

select result, who, test, expected, got
  from kiroku_test_results
 order by (result = 'PASS'), n;
