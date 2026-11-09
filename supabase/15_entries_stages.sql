-- Kiroku: My Entries, stage setup and the Agency / Client masterlist.
-- Run after 13_security_hardening.sql: Supabase dashboard > SQL Editor > New query > paste > Run.
-- Adds tables and functions. Safe to run twice. Nothing existing is removed.
--
-- Security (same rules as 13_security_hardening.sql):
--   * who is acting is ALWAYS the signed-in user (auth.uid()). The p_user_id the page sends is ignored;
--     it stays in the function signatures only so the page does not need to change.
--   * nobody who is not signed in can read the stages or call any of these functions
--   * masterlist and stages: Admin only. Create a job order: Admin or a Doc Officer.
--     Edit a job order: Admin, or a Doc Officer who has a task on that job order. CEO: read only.
--   * every change is written to event_logs (who, what, when), which cannot be changed or deleted.
-- Afterwards run 14_security_tests.sql again: every row must say PASS.

-- ---------------------------------------------------------------- tracks and stages (Configuration page)
create table if not exists public.track_config (
  track      text primary key check (track in ('TIO','OTIT','COE')),
  name       text not null,
  sort_order int  not null
);
insert into public.track_config (track, name, sort_order) values
  ('TIO','TIO',1), ('OTIT','OTIT',2), ('COE','COE',3)
on conflict (track) do nothing;

-- One row per stage: its track, its place in the track, its name, days from Target Deploy
-- (negative = before, e.g. -60 = 60 days before) and the Doc Officer who owns it by default.
create table if not exists public.stage_config (
  stage_id    serial primary key,
  track       text not null references public.track_config(track),
  sort_order  int  not null,
  stage_name  text not null,
  offset_days int  not null,
  editor_id   text references public.users(user_id),
  unique (track, sort_order)
);
insert into public.stage_config (track, sort_order, stage_name, offset_days, editor_id) values
  ('TIO', 1, 'Fill Up', -60, 'u2'),
  ('TIO', 2, 'Signing', -55, 'u2'),
  ('TIO', 3, 'DHL Sent', -50, 'u2'),
  ('TIO', 4, 'DHL Received', -45, 'u3'),
  ('TIO', 5, 'TIO waiting', -35, 'u3'),
  ('TIO', 6, 'TIO Received with Changes', -25, 'u3'),
  ('TIO', 7, 'TIO Received', -20, 'u3'),
  ('OTIT', 1, 'Fill Up', -60, 'u1'),
  ('OTIT', 2, 'Signing', -55, 'u1'),
  ('OTIT', 3, 'DHL Sent', -50, 'u1'),
  ('OTIT', 4, 'DHL Received', -45, 'u3'),
  ('OTIT', 5, 'COE Waiting', -35, 'u3'),
  ('OTIT', 6, 'COE Received with Changes', -25, 'u3'),
  ('OTIT', 7, 'COE Received', -20, 'u3'),
  ('COE', 1, 'PDOS done', -15, 'u4'),
  ('COE', 2, 'Visa done', -12, 'u4'),
  ('COE', 3, 'OWWA done', -10, 'u4'),
  ('COE', 4, 'Ticket done', -7, 'u4')
on conflict (track, sort_order) do nothing;

-- Read: signed-in Kiroku users only (not the public, not a stray login). Writes: only through the functions below.
alter table public.track_config enable row level security;
alter table public.stage_config enable row level security;
drop policy if exists "read track_config" on public.track_config;
drop policy if exists "read stage_config" on public.stage_config;
create policy "read track_config" on public.track_config for select to authenticated using (public.is_kiroku_user());
create policy "read stage_config" on public.stage_config for select to authenticated using (public.is_kiroku_user());
revoke all on public.track_config, public.stage_config from anon, authenticated;
revoke all on sequence public.stage_config_stage_id_seq from anon, authenticated;
grant  select on public.track_config, public.stage_config to authenticated;

-- ---------------------------------------------------------------- who is acting
-- Always the signed-in user. p_user_id is ignored (there is no "open mode" any more).
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

-- One event_logs row per change made from these screens.
create or replace function public.kiroku_log_change(p_user public.users, p_event text, p_action text,
  p_module text, p_record text, p_description text) returns void
language sql security definer set search_path = public
as $$
  insert into public.event_logs (event_type, source, user_id, user_name, action, module, record_id, description)
  values (p_event, 'Kiroku', p_user.user_id, p_user.name, p_action, p_module, p_record, left(p_description, 500))
$$;

-- ---------------------------------------------------------------- masterlist: Agencies (kumiai) and Clients (companies)
create or replace function public.admin_save_kumiai(p_user_id text, p_kumiai_id text, p_name text) returns text
language plpgsql security definer set search_path = public
as $$
declare
  v_user public.users;
  v_id   text := nullif(trim(coalesce(p_kumiai_id, '')), '');
  v_name text := nullif(trim(coalesce(p_name, '')), '');
  v_old  text;
begin
  v_user := public.kiroku_actor(p_user_id);
  if v_user.role <> 'Admin' then raise exception 'Only Admin can change the masterlist.' using errcode = '42501'; end if;
  if v_name is null then raise exception 'Agency name is required.'; end if;
  if length(v_name) > 120 then raise exception 'Agency name is too long (120 characters at most).'; end if;
  if v_id is null then
    v_id := 'k_' || substr(md5(random()::text || clock_timestamp()::text), 1, 10);
    insert into public.kumiai (kumiai_id, name) values (v_id, v_name);
    perform public.kiroku_log_change(v_user, 'Record Created', 'Create', 'Kumiai', v_id, 'Agency added: ' || v_name);
  else
    select name into v_old from public.kumiai where kumiai_id = v_id;
    if v_old is null then raise exception 'This agency no longer exists.'; end if;
    update public.kumiai set name = v_name where kumiai_id = v_id;
    if v_old is distinct from v_name then
      perform public.kiroku_log_change(v_user, 'Record Updated', 'Update', 'Kumiai', v_id, 'Agency renamed: ' || v_old || ' -> ' || v_name);
    end if;
  end if;
  return v_id;
end $$;

create or replace function public.admin_save_company(p_user_id text, p_company_id text, p_kumiai_id text, p_name text) returns text
language plpgsql security definer set search_path = public
as $$
declare
  v_user public.users;
  v_id   text := nullif(trim(coalesce(p_company_id, '')), '');
  v_name text := nullif(trim(coalesce(p_name, '')), '');
  v_old  public.companies;
begin
  v_user := public.kiroku_actor(p_user_id);
  if v_user.role <> 'Admin' then raise exception 'Only Admin can change the masterlist.' using errcode = '42501'; end if;
  if v_name is null then raise exception 'Client name is required.'; end if;
  if length(v_name) > 120 then raise exception 'Client name is too long (120 characters at most).'; end if;
  if not exists (select 1 from public.kumiai where kumiai_id = p_kumiai_id) then raise exception 'Choose an agency for this client.'; end if;
  if v_id is null then
    v_id := 'c_' || substr(md5(random()::text || clock_timestamp()::text), 1, 10);
    insert into public.companies (company_id, kumiai_id, name) values (v_id, p_kumiai_id, v_name);
    perform public.kiroku_log_change(v_user, 'Record Created', 'Create', 'Companies', v_id, 'Client added: ' || v_name);
  else
    select * into v_old from public.companies where company_id = v_id;
    if v_old.company_id is null then raise exception 'This client no longer exists.'; end if;
    update public.companies set name = v_name, kumiai_id = p_kumiai_id where company_id = v_id;
    if v_old.name is distinct from v_name or v_old.kumiai_id is distinct from p_kumiai_id then
      perform public.kiroku_log_change(v_user, 'Record Updated', 'Update', 'Companies', v_id,
        'Client updated: ' || v_old.name || ' -> ' || v_name ||
        case when v_old.kumiai_id is distinct from p_kumiai_id then ' (agency changed)' else '' end);
    end if;
  end if;
  return v_id;
end $$;

-- ---------------------------------------------------------------- stages (Configuration page)
create or replace function public.admin_save_stage(p_user_id text, p_stage_id int, p_track text, p_sort int,
  p_name text, p_offset int, p_editor text) returns int
language plpgsql security definer set search_path = public
as $$
declare
  v_user public.users;
  v_id   int := p_stage_id;
  v_name text := nullif(trim(coalesce(p_name, '')), '');
begin
  v_user := public.kiroku_actor(p_user_id);
  if v_user.role <> 'Admin' then raise exception 'Only Admin can change the stages.' using errcode = '42501'; end if;
  if v_name is null then raise exception 'Stage name is required.'; end if;
  if length(v_name) > 120 then raise exception 'Stage name is too long (120 characters at most).'; end if;
  if p_sort is null or p_sort < 1 or p_sort > 100 then raise exception 'Stage order must be between 1 and 100.'; end if;
  if p_offset is null or p_offset not between -730 and 730 then raise exception 'Days from Target Deploy must be between -730 and 730.'; end if;
  if p_editor is not null and not exists (select 1 from public.users where user_id = p_editor and role = 'Doc Officer') then
    raise exception 'A stage can only be owned by a Doc Officer.';
  end if;
  if v_id is null then
    insert into public.stage_config (track, sort_order, stage_name, offset_days, editor_id)
    values (p_track, p_sort, v_name, p_offset, p_editor) returning stage_id into v_id;
    perform public.kiroku_log_change(v_user, 'Record Created', 'Create', 'Stages', v_id::text,
      'Stage added: ' || p_track || ' #' || p_sort || ' ' || v_name);
  else
    update public.stage_config set track = p_track, sort_order = p_sort, stage_name = v_name,
           offset_days = p_offset, editor_id = p_editor where stage_id = v_id;
    if not found then raise exception 'This stage no longer exists.'; end if;
    perform public.kiroku_log_change(v_user, 'Record Updated', 'Update', 'Stages', v_id::text,
      'Stage updated: ' || p_track || ' #' || p_sort || ' ' || v_name || ', ' || p_offset || ' days, owner ' || coalesce(p_editor, '-'));
  end if;
  return v_id;
end $$;

-- Deleting a stage only removes it from new job orders. Existing job orders keep their tasks.
create or replace function public.admin_delete_stage(p_user_id text, p_stage_id int) returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_user public.users;
  v_old  public.stage_config;
begin
  v_user := public.kiroku_actor(p_user_id);
  if v_user.role <> 'Admin' then raise exception 'Only Admin can change the stages.' using errcode = '42501'; end if;
  delete from public.stage_config where stage_id = p_stage_id returning * into v_old;
  if v_old.stage_id is not null then
    perform public.kiroku_log_change(v_user, 'Record Deleted', 'Delete', 'Stages', v_old.stage_id::text,
      'Stage removed: ' || v_old.track || ' #' || v_old.sort_order || ' ' || v_old.stage_name);
  end if;
end $$;

-- ---------------------------------------------------------------- My Entries: create a job order
-- Makes the job order, then its tasks: one per stage in stage_config (3 tracks, 18 stages today).
-- Each due date = target deploy + the stage's days. Later stage changes do not change existing job orders.
create or replace function public.create_job_order(p_user_id text, p_jo_number text, p_company_id text,
  p_worker_name text, p_target date) returns text
language plpgsql security definer set search_path = public
as $$
declare
  v_user   public.users;
  v_num    text := nullif(trim(coalesce(p_jo_number, '')), '');
  v_worker text := nullif(trim(coalesce(p_worker_name, '')), '');
  v_jo     text := 'j_' || substr(md5(random()::text || clock_timestamp()::text), 1, 10);
  v_n      int;
begin
  v_user := public.kiroku_actor(p_user_id);
  if v_user.role not in ('Admin', 'Doc Officer') then
    raise exception 'Only a Doc Officer or Admin can create a job order.' using errcode = '42501';
  end if;
  if v_num is null then raise exception 'JO number is required.'; end if;
  if v_num !~ '^[A-Za-z0-9][A-Za-z0-9 _/-]{0,39}$' then raise exception 'JO number: letters, digits, - and / only (40 at most).'; end if;
  if exists (select 1 from public.job_orders where jo_number = v_num) then raise exception 'JO # % already exists.', v_num; end if;
  if not exists (select 1 from public.companies where company_id = p_company_id) then raise exception 'Choose a client.'; end if;
  if v_worker is null then raise exception 'Worker name is required.'; end if;
  if length(v_worker) > 120 then raise exception 'Worker name is too long (120 characters at most).'; end if;
  if p_target is null then raise exception 'Target deploy date is required.'; end if;
  if p_target not between current_date - 365 and current_date + 1095 then raise exception 'Target deploy date looks wrong.'; end if;
  select count(*) into v_n from public.stage_config;
  if v_n = 0 then raise exception 'Set up the stages in Configuration first.'; end if;

  insert into public.job_orders (jo_id, jo_number, company_id, worker_name, target_deployment_date, active)
  values (v_jo, v_num, p_company_id, v_worker, p_target, true);

  insert into public.tasks (task_id, jo_id, track, task_name, sort_order, offset_days, editor_id, due_date, done, status)
  select v_jo || '-' || s.track || '-' || s.sort_order, v_jo, s.track, s.stage_name, s.sort_order,
         s.offset_days, s.editor_id, p_target + s.offset_days, false, 'Pending'
    from public.stage_config s
    join public.track_config t on t.track = s.track
   order by t.sort_order, s.sort_order;
  get diagnostics v_n = row_count;

  perform public.kiroku_log_change(v_user, 'Record Created', 'Create', 'Job Orders', v_jo,
    'Job order JO# ' || v_num || ' created for ' || v_worker || ' (' || v_n || ' tasks)');
  return v_jo;
end $$;

-- ---------------------------------------------------------------- My Entries: edit a job order
-- Changing the target deploy date moves every stage's due date by the same days (due = target + offset).
-- Admin may edit any job order; a Doc Officer only one they have a task on.
create or replace function public.update_job_order(p_user_id text, p_jo_id text, p_jo_number text, p_company_id text,
  p_worker_name text, p_target date) returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_user   public.users;
  v_old    public.job_orders;
  v_num    text := nullif(trim(coalesce(p_jo_number, '')), '');
  v_worker text := nullif(trim(coalesce(p_worker_name, '')), '');
begin
  v_user := public.kiroku_actor(p_user_id);
  if v_user.role not in ('Admin', 'Doc Officer') then
    raise exception 'Only a Doc Officer or Admin can edit a job order.' using errcode = '42501';
  end if;
  select * into v_old from public.job_orders where jo_id = p_jo_id for update;
  if v_old.jo_id is null then raise exception 'This job order no longer exists.'; end if;
  if v_user.role <> 'Admin'
     and not exists (select 1 from public.tasks where jo_id = p_jo_id and editor_id = v_user.user_id) then
    raise exception 'You have no task on this job order, so you cannot edit it.' using errcode = '42501';
  end if;
  if v_num is null then raise exception 'JO number is required.'; end if;
  if v_num !~ '^[A-Za-z0-9][A-Za-z0-9 _/-]{0,39}$' then raise exception 'JO number: letters, digits, - and / only (40 at most).'; end if;
  if exists (select 1 from public.job_orders where jo_number = v_num and jo_id <> p_jo_id) then raise exception 'JO # % already exists.', v_num; end if;
  if not exists (select 1 from public.companies where company_id = p_company_id) then raise exception 'Choose a client.'; end if;
  if v_worker is null then raise exception 'Worker name is required.'; end if;
  if length(v_worker) > 120 then raise exception 'Worker name is too long (120 characters at most).'; end if;
  if p_target is null then raise exception 'Target deploy date is required.'; end if;
  if p_target not between current_date - 365 and current_date + 1095 then raise exception 'Target deploy date looks wrong.'; end if;

  update public.job_orders set jo_number = v_num, company_id = p_company_id,
         worker_name = v_worker, target_deployment_date = p_target
   where jo_id = p_jo_id;
  if p_target is distinct from v_old.target_deployment_date then
    update public.tasks set due_date = p_target + offset_days where jo_id = p_jo_id;
  end if;

  if v_old.jo_number is distinct from v_num or v_old.company_id is distinct from p_company_id
     or v_old.worker_name is distinct from v_worker or v_old.target_deployment_date is distinct from p_target then
    perform public.kiroku_log_change(v_user, 'Record Updated', 'Update', 'Job Orders', p_jo_id,
      'Job order JO# ' || v_num || ' updated: ' || concat_ws('; ',
        case when v_old.jo_number is distinct from v_num then 'JO number ' || v_old.jo_number || ' -> ' || v_num end,
        case when v_old.company_id is distinct from p_company_id then 'client changed' end,
        case when v_old.worker_name is distinct from v_worker then 'worker ' || v_old.worker_name || ' -> ' || v_worker end,
        case when v_old.target_deployment_date is distinct from p_target
             then 'target deploy ' || v_old.target_deployment_date || ' -> ' || p_target || ' (all due dates moved)' end));
  end if;
end $$;

-- ---------------------------------------------------------------- who may call what
-- Signed-in users only. The functions themselves check the role. Never anon.
revoke execute on function public.kiroku_actor(text) from public, anon, authenticated;
revoke execute on function public.kiroku_log_change(public.users, text, text, text, text, text) from public, anon, authenticated;
revoke execute on function public.admin_save_kumiai(text, text, text) from public, anon;
revoke execute on function public.admin_save_company(text, text, text, text) from public, anon;
revoke execute on function public.admin_save_stage(text, int, text, int, text, int, text) from public, anon;
revoke execute on function public.admin_delete_stage(text, int) from public, anon;
revoke execute on function public.create_job_order(text, text, text, text, date) from public, anon;
revoke execute on function public.update_job_order(text, text, text, text, text, date) from public, anon;
grant  execute on function public.admin_save_kumiai(text, text, text) to authenticated, service_role;
grant  execute on function public.admin_save_company(text, text, text, text) to authenticated, service_role;
grant  execute on function public.admin_save_stage(text, int, text, int, text, int, text) to authenticated, service_role;
grant  execute on function public.admin_delete_stage(text, int) to authenticated, service_role;
grant  execute on function public.create_job_order(text, text, text, text, date) to authenticated, service_role;
grant  execute on function public.update_job_order(text, text, text, text, text, date) to authenticated, service_role;
grant  execute on function public.kiroku_actor(text), public.kiroku_log_change(public.users, text, text, text, text, text) to service_role;
