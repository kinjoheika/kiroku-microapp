-- Kiroku: undo 18_require_mfa.sql (a password alone is enough again). Use only if MFA must be switched off,
-- for example while a problem is fixed; then run 18_require_mfa.sql again.
-- Puts back the checks exactly as 13 and 15 made them. All or nothing. Safe to run twice.
-- Afterwards run 14_security_tests.sql: every row must say PASS.

begin;

create or replace function public.is_kiroku_user() returns boolean
language sql stable security definer set search_path = public
as $$ select exists (select 1 from public.users where auth_user_id = auth.uid()) $$;

create or replace function public.is_kiroku_admin() returns boolean
language sql stable security definer set search_path = public
as $$ select exists (select 1 from public.users where auth_user_id = auth.uid() and role = 'Admin') $$;

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

create or replace function public.link_my_account() returns public.users
language sql stable security definer set search_path = public
as $$ select * from public.users where auth_user_id = auth.uid() $$;

create or replace function public.kiroku_actor(p_user_id text default null) returns public.users
language plpgsql stable security definer set search_path = public
as $$
declare v_user public.users;
begin
  select * into v_user from public.users where auth_user_id = auth.uid();
  if v_user.user_id is null then
    raise exception 'Sign in first.' using errcode = '42501';
  end if;
  return v_user;
end $$;

-- The original log_task_activity and update_task_fields come back under their own names.
do $$
begin
  if to_regprocedure('public.log_task_activity_inner(jsonb)') is not null then
    drop function public.log_task_activity(jsonb);
    alter function public.log_task_activity_inner(jsonb) rename to log_task_activity;
  end if;
  if to_regprocedure('public.update_task_fields_inner(text,text,jsonb,timestamptz)') is not null then
    drop function public.update_task_fields(text, text, jsonb, timestamptz);
    alter function public.update_task_fields_inner(text, text, jsonb, timestamptz) rename to update_task_fields;
  end if;
end $$;
revoke execute on function public.log_task_activity(jsonb) from public, anon;
revoke execute on function public.update_task_fields(text, text, jsonb, timestamptz) from public, anon;
grant  execute on function public.log_task_activity(jsonb) to authenticated;
grant  execute on function public.update_task_fields(text, text, jsonb, timestamptz) to authenticated;

drop function if exists public.kiroku_require_mfa();
drop function if exists public.kiroku_uid();

commit;
