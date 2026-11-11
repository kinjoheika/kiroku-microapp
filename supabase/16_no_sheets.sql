-- Kiroku: everything the Admin did in the Google Sheet can now be done in Kiroku.
--   * Users: add a person, change a name, role or email      (Configuration > Users, Admin only)
--   * Job orders: archive, reactivate, delete                  (My Due Gates)
-- Run after 15_entries_stages.sql: Supabase dashboard > SQL Editor > New query > paste > Run.
-- Adds functions only. No table, row or rule is changed or removed. Safe to run twice.
--
-- Security (same rules as 13 and 15):
--   * who is acting is ALWAYS the signed-in user (auth.uid()); p_user_id from the page is ignored
--   * nobody who is not signed in can call these functions
--   * users: Admin only. A login is still linked to a person only in the Supabase dashboard
--     (users.auth_user_id; protect_users() refuses it from the API). Kiroku always keeps one Admin.
--   * archive / reactivate: Admin, or a Doc Officer who has a task on that job order (like editing it)
--   * delete: Admin only, and only a job order nothing was ever logged on (a mistake). Otherwise archive it:
--     activity_logs and event_logs are permanent.
--   * every change is written to event_logs (who, what, when)
-- Afterwards run 14_security_tests.sql: every row must say PASS.

-- ---------------------------------------------------------------- users
create or replace function public.admin_save_user(p_user_id text, p_target_id text, p_name text,
  p_role text, p_email text) returns text
language plpgsql security definer set search_path = public
as $$
declare
  v_user  public.users;
  v_id    text := nullif(trim(coalesce(p_target_id, '')), '');
  v_name  text := nullif(trim(coalesce(p_name, '')), '');
  v_role  text := nullif(trim(coalesce(p_role, '')), '');
  v_email text := lower(nullif(trim(coalesce(p_email, '')), ''));
  v_old   public.users;
  v_n     int;
begin
  v_user := public.kiroku_actor(p_user_id);
  if v_user.role <> 'Admin' then raise exception 'Only Admin can change users.' using errcode = '42501'; end if;
  if v_name is null then raise exception 'Name is required.'; end if;
  if length(v_name) > 80 then raise exception 'Name is too long (80 characters at most).'; end if;
  if v_role is null or v_role not in ('Doc Officer', 'CEO', 'Admin') then
    raise exception 'Role must be Doc Officer, CEO or Admin.';
  end if;
  if v_email is not null then
    if length(v_email) > 254 or v_email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then
      raise exception 'Email % is not an email address.', v_email;
    end if;
    if exists (select 1 from public.users where lower(email) = v_email and user_id is distinct from v_id) then
      raise exception 'Another user already has the email %.', v_email;
    end if;
  end if;

  if v_id is null then
    -- next free u<number>
    select coalesce(max(substring(user_id from '^u([0-9]+)$')::int), 0) + 1 into v_n from public.users;
    v_id := 'u' || v_n;
    insert into public.users (user_id, name, role, email) values (v_id, v_name, v_role, v_email);
    perform public.kiroku_log_change(v_user, 'Record Created', 'Create', 'Users', v_id,
      'User added: ' || v_name || ' (' || v_role || ')');
    return v_id;
  end if;

  select * into v_old from public.users where user_id = v_id for update;
  if v_old.user_id is null then raise exception 'This user no longer exists.'; end if;
  if v_old.role = 'Doc Officer' and v_role <> 'Doc Officer' then
    if exists (select 1 from public.tasks where editor_id = v_id and status <> 'Completed') then
      raise exception '% still has open tasks. Give them to another Doc Officer first.', v_old.name;
    end if;
    if exists (select 1 from public.stage_config where editor_id = v_id) then
      raise exception '% is the default officer of a stage. Change that in Stages first.', v_old.name;
    end if;
  end if;
  -- protect_users() (13_security_hardening.sql) refuses to remove the last Admin.
  update public.users set name = v_name, role = v_role, email = v_email where user_id = v_id;
  if v_old.name is distinct from v_name or v_old.role is distinct from v_role or v_old.email is distinct from v_email then
    perform public.kiroku_log_change(v_user, 'Record Updated', 'Update', 'Users', v_id,
      'User ' || v_name || ' updated: ' || concat_ws('; ',
        case when v_old.name is distinct from v_name then 'name ' || v_old.name || ' -> ' || v_name end,
        case when v_old.role is distinct from v_role then 'role ' || v_old.role || ' -> ' || v_role end,
        case when v_old.email is distinct from v_email then 'email changed' end));
  end if;
  return v_id;
end $$;

-- ---------------------------------------------------------------- job orders: archive / reactivate
create or replace function public.set_job_order_active(p_user_id text, p_jo_id text, p_active boolean) returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_user public.users;
  v_old  public.job_orders;
begin
  v_user := public.kiroku_actor(p_user_id);
  if v_user.role not in ('Admin', 'Doc Officer') then
    raise exception 'Only a Doc Officer or Admin can archive a job order.' using errcode = '42501';
  end if;
  if p_active is null then raise exception 'Archive or reactivate?'; end if;
  select * into v_old from public.job_orders where jo_id = p_jo_id for update;
  if v_old.jo_id is null then raise exception 'This job order no longer exists.'; end if;
  if v_user.role <> 'Admin'
     and not exists (select 1 from public.tasks where jo_id = p_jo_id and editor_id = v_user.user_id) then
    raise exception 'You have no task on this job order, so you cannot archive it.' using errcode = '42501';
  end if;
  if v_old.active = p_active then return; end if;
  update public.job_orders set active = p_active where jo_id = p_jo_id;
  perform public.kiroku_log_change(v_user, 'Record Updated', 'Update', 'Job Orders', p_jo_id,
    'Job order JO# ' || v_old.jo_number || case when p_active then ' reactivated' else ' archived' end);
end $$;

-- ---------------------------------------------------------------- job orders: delete (mistakes only)
create or replace function public.admin_delete_job_order(p_user_id text, p_jo_id text) returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_user public.users;
  v_old  public.job_orders;
  v_n    int;
begin
  v_user := public.kiroku_actor(p_user_id);
  if v_user.role <> 'Admin' then raise exception 'Only Admin can delete a job order.' using errcode = '42501'; end if;
  select * into v_old from public.job_orders where jo_id = p_jo_id for update;
  if v_old.jo_id is null then raise exception 'This job order no longer exists.'; end if;
  if v_old.active then raise exception 'Archive the job order first, then delete it.'; end if;
  if exists (select 1 from public.activity_logs where jo_id = p_jo_id) then
    raise exception 'JO# % has recorded activity, which is kept permanently. Keep it archived instead.', v_old.jo_number;
  end if;
  select count(*) into v_n from public.tasks where jo_id = p_jo_id;
  delete from public.tasks where jo_id = p_jo_id;
  delete from public.job_orders where jo_id = p_jo_id;
  perform public.kiroku_log_change(v_user, 'Record Deleted', 'Delete', 'Job Orders', p_jo_id,
    'Job order JO# ' || v_old.jo_number || ' (' || coalesce(v_old.worker_name, '') || ') deleted with its ' || v_n || ' tasks');
end $$;

-- ---------------------------------------------------------------- who may call what
revoke execute on function public.admin_save_user(text, text, text, text, text) from public, anon;
revoke execute on function public.set_job_order_active(text, text, boolean) from public, anon;
revoke execute on function public.admin_delete_job_order(text, text) from public, anon;
grant  execute on function public.admin_save_user(text, text, text, text, text) to authenticated, service_role;
grant  execute on function public.set_job_order_active(text, text, boolean) to authenticated, service_role;
grant  execute on function public.admin_delete_job_order(text, text) to authenticated, service_role;
