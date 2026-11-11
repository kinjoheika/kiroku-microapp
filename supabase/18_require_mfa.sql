-- Kiroku: two-step sign-in (MFA) for everyone. Data only after the 6-digit code from the authenticator app.
-- Run AFTER the new index.html is live (it asks for the code and sets it up the first time).
-- Supabase dashboard > SQL Editor > New query > paste > Run. All or nothing. Safe to run twice.
-- Afterwards run 14_security_tests.sql: every row must say PASS.
--
-- How: a password alone gives a session marked "aal1"; after the 6-digit code it is "aal2" (Supabase puts this in
-- the login token). Every check that asks "who is signed in?" now answers "nobody" for an aal1 session:
--   * the row-security helpers (is_kiroku_user, is_kiroku_admin, can_edit_task) -> no rows, no file access
--   * link_my_account -> no profile, so the page cannot start without the code
--   * kiroku_actor (every function in 15 and 16) -> refused
--   * log_task_activity, update_task_fields -> refused (a check is put in front of them)
-- Nothing else changes: same rules, same roles, same data.
--
-- Someone lost their phone: Supabase > Authentication > Users > the person > remove their MFA factor.
-- At their next sign-in Kiroku shows a new QR code to scan.
-- Way back (MFA off again): 18_rollback.sql.

begin;

-- The signed-in person's login id, but only after the 6-digit code (aal2). Otherwise null.
create or replace function public.kiroku_uid() returns uuid
language sql stable set search_path = ''
as $$ select case when coalesce(auth.jwt() ->> 'aal', '') = 'aal2' then auth.uid() end $$;

create or replace function public.kiroku_require_mfa() returns void
language plpgsql stable set search_path = ''
as $$
begin
  if public.kiroku_uid() is null then
    raise exception 'Enter the 6-digit code from your authenticator app first.' using errcode = '42501';
  end if;
end $$;

-- ---------------------------------------------------------------- the helpers (13_security_hardening.sql)
create or replace function public.is_kiroku_user() returns boolean
language sql stable security definer set search_path = public
as $$ select exists (select 1 from public.users where auth_user_id = public.kiroku_uid()) $$;

create or replace function public.is_kiroku_admin() returns boolean
language sql stable security definer set search_path = public
as $$ select exists (select 1 from public.users where auth_user_id = public.kiroku_uid() and role = 'Admin') $$;

create or replace function public.can_edit_task(p_task_id text) returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (
    select 1 from public.users u
     where u.auth_user_id = public.kiroku_uid()
       and (u.role = 'Admin'
            or (u.role = 'Doc Officer'
                and exists (select 1 from public.tasks t where t.task_id = p_task_id and t.editor_id = u.user_id))))
$$;

create or replace function public.link_my_account() returns public.users
language sql stable security definer set search_path = public
as $$ select * from public.users where auth_user_id = public.kiroku_uid() $$;

-- ---------------------------------------------------------------- who is acting (15_entries_stages.sql)
create or replace function public.kiroku_actor(p_user_id text default null) returns public.users
language plpgsql stable security definer set search_path = public
as $$
declare v_user public.users;
begin
  if auth.uid() is not null then perform public.kiroku_require_mfa(); end if;
  select * into v_user from public.users where auth_user_id = public.kiroku_uid();
  if v_user.user_id is null then
    raise exception 'Sign in first.' using errcode = '42501';
  end if;
  return v_user;
end $$;

-- ---------------------------------------------------------------- the two functions that look the user up themselves
-- The original function keeps working unchanged under a new name; the public name gets a check in front.
do $$
begin
  if to_regprocedure('public.log_task_activity_inner(jsonb)') is null then
    alter function public.log_task_activity(jsonb) rename to log_task_activity_inner;
  end if;
  if to_regprocedure('public.update_task_fields_inner(text,text,jsonb,timestamptz)') is null then
    alter function public.update_task_fields(text, text, jsonb, timestamptz) rename to update_task_fields_inner;
  end if;
end $$;

create or replace function public.log_task_activity(p_entries jsonb) returns setof public.activity_logs
language plpgsql security definer set search_path = public
as $$
begin
  perform public.kiroku_require_mfa();
  return query select * from public.log_task_activity_inner(p_entries);
end $$;

create or replace function public.update_task_fields(p_task_id text, p_user_id text, p_fields jsonb,
  p_expected_updated_at timestamptz default null) returns public.tasks
language plpgsql security definer set search_path = public
as $$
begin
  perform public.kiroku_require_mfa();
  return public.update_task_fields_inner(p_task_id, p_user_id, p_fields, p_expected_updated_at);
end $$;

-- ---------------------------------------------------------------- who may call what
revoke execute on function public.log_task_activity_inner(jsonb) from public, anon, authenticated;
revoke execute on function public.update_task_fields_inner(text, text, jsonb, timestamptz) from public, anon, authenticated;
revoke execute on function public.kiroku_uid(), public.kiroku_require_mfa() from public, anon;
grant  execute on function public.kiroku_uid(), public.kiroku_require_mfa() to authenticated;
revoke execute on function public.log_task_activity(jsonb) from public, anon;
revoke execute on function public.update_task_fields(text, text, jsonb, timestamptz) from public, anon;
grant  execute on function public.log_task_activity(jsonb) to authenticated;
grant  execute on function public.update_task_fields(text, text, jsonb, timestamptz) to authenticated;

commit;
