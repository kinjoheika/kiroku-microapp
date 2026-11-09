-- Kiroku — security check. READ ONLY: it changes nothing and can be run any time.
-- Supabase dashboard > SQL Editor > New query > paste > Run.
-- It returns ONE value (a JSON document). Click the cell, copy it, and send it back for review.
-- It shows no passwords, keys or tokens. It does show user names and roles.

select jsonb_pretty(jsonb_build_object(

  -- 1. Which version of the sign-in rules is live (12_task_status.sql vs 11_lock_down.sql)
  'open_mode_function', (select prosrc from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                          where n.nspname = 'public' and p.proname = 'kiroku_open_mode'),
  'log_task_activity_is_locked_version', (select bool_or(position('sign in first' in prosrc) > 0)
                          from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                          where n.nspname = 'public' and p.proname = 'log_task_activity'),

  -- 2. Every table and view in public: is row security on?
  'tables', (select jsonb_agg(jsonb_build_object(
                'table', c.relname, 'kind', c.relkind,
                'rls', c.relrowsecurity, 'rls_forced', c.relforcerowsecurity,
                'approx_rows', c.reltuples::bigint) order by c.relname)
             from pg_class c join pg_namespace n on n.oid = c.relnamespace
             where n.nspname = 'public' and c.relkind in ('r','p','v','m')),

  -- 3. What anon (not signed in) and authenticated (signed in) may do on each table
  'table_grants', (select jsonb_agg(jsonb_build_object(
                'table', table_name, 'role', grantee, 'privileges', privs) order by table_name, grantee)
             from (select table_name, grantee, string_agg(privilege_type, ',' order by privilege_type) privs
                     from information_schema.role_table_grants
                    where table_schema = 'public' and grantee in ('anon','authenticated','public')
                    group by table_name, grantee) g),

  -- 4. Every row-security policy (public tables and Storage)
  'policies', (select jsonb_agg(jsonb_build_object(
                'schema', schemaname, 'table', tablename, 'policy', policyname,
                'roles', roles, 'cmd', cmd, 'using', qual, 'check', with_check) order by schemaname, tablename, policyname)
             from pg_policies where schemaname in ('public','storage')),

  -- 5. Every function in public: SECURITY DEFINER? search_path pinned? who can call it?
  'functions', (select jsonb_agg(jsonb_build_object(
                'function', p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')',
                'security_definer', p.prosecdef, 'config', p.proconfig,
                'owner', pg_get_userbyid(p.proowner),
                'anon_can_call', has_function_privilege('anon', p.oid, 'execute'),
                'authenticated_can_call', has_function_privilege('authenticated', p.oid, 'execute')) order by p.proname)
             from pg_proc p join pg_namespace n on n.oid = p.pronamespace
             where n.nspname = 'public' and p.prokind = 'f'),

  -- 6. Every trigger on public tables
  'triggers', (select jsonb_agg(jsonb_build_object(
                'table', c.relname, 'trigger', t.tgname, 'enabled', t.tgenabled,
                'definition', pg_get_triggerdef(t.oid)) order by c.relname, t.tgname)
             from pg_trigger t join pg_class c on c.oid = t.tgrelid
             join pg_namespace n on n.oid = c.relnamespace
             where n.nspname = 'public' and not t.tgisinternal),

  -- 7. The six people: linked to a login? email confirmed and matching? signed in recently?
  'users', (select jsonb_agg(jsonb_build_object(
                'user_id', u.user_id, 'name', u.name, 'role', u.role,
                'linked', u.auth_user_id is not null,
                'login_exists', au.id is not null,
                'email_confirmed', au.email_confirmed_at is not null,
                'email_matches_profile', lower(au.email) = lower(u.email),
                'last_sign_in', au.last_sign_in_at) order by u.user_id)
             from public.users u left join auth.users au on au.id = u.auth_user_id),

  -- 8. Logins that belong to no Kiroku user (for example from an open sign-up page)
  'logins_without_profile', (select count(*) from auth.users au
             where not exists (select 1 from public.users u where u.auth_user_id = au.id)),

  -- 9. Rights given automatically to tables created in the future
  'default_privileges', (select jsonb_agg(jsonb_build_object(
                'owner', pg_get_userbyid(defaclrole), 'schema', defaclnamespace::regnamespace::text,
                'type', defaclobjtype, 'acl', defaclacl::text[]))
             from pg_default_acl where defaclnamespace = 'public'::regnamespace),

  -- 10. Storage buckets
  'buckets', (select jsonb_agg(jsonb_build_object(
                'id', id, 'public', public, 'size_limit', file_size_limit, 'mime_types', allowed_mime_types))
             from storage.buckets),

  -- 11. Tables sent to open pages live (Realtime)
  'realtime_tables', (select jsonb_agg(schemaname || '.' || tablename)
             from pg_publication_tables where pubname = 'supabase_realtime'),

  -- 12. Baseline counts, to prove later that no history was lost
  'counts', jsonb_build_object(
                'activity_logs', (select count(*) from public.activity_logs),
                'event_logs',    (select count(*) from public.event_logs),
                'tasks',         (select count(*) from public.tasks),
                'job_orders',    (select count(*) from public.job_orders),
                'users',         (select count(*) from public.users))
)) as kiroku_security_check;
