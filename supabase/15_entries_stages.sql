-- Kiroku: My Entries, stage setup and the Agency / Client masterlist.
-- Run after 13_security_hardening.sql (the colleague's security file): Supabase dashboard > SQL Editor > New query > paste > Run.
-- Adds tables and functions. Safe to run twice. Nothing existing is removed.

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

alter table public.track_config enable row level security;
alter table public.stage_config enable row level security;
drop policy if exists "read track_config" on public.track_config;
drop policy if exists "read stage_config" on public.stage_config;
create policy "read track_config" on public.track_config for select to anon, authenticated using (true);
create policy "read stage_config" on public.stage_config for select to anon, authenticated using (true);
grant select on public.track_config, public.stage_config to anon, authenticated;

-- ---------------------------------------------------------------- who is acting
-- Same rule as update_task_fields: a signed-in user, or (open mode) the user_id the page sends.
create or replace function public.kiroku_actor(p_user_id text) returns public.users
language plpgsql security definer set search_path = public
as $$
declare v_user public.users;
begin
  if auth.uid() is not null then
    select * into v_user from public.users where auth_user_id = auth.uid();
  elsif public.kiroku_open_mode() then
    select * into v_user from public.users where user_id = p_user_id;
  end if;
  if v_user.user_id is null then
    raise exception 'Sign in first.';
  end if;
  return v_user;
end $$;

-- ---------------------------------------------------------------- masterlist: Agencies (kumiai) and Clients (companies)
create or replace function public.admin_save_kumiai(p_user_id text, p_kumiai_id text, p_name text) returns text
language plpgsql security definer set search_path = public
as $$
declare v_user public.users; v_id text := nullif(trim(coalesce(p_kumiai_id, '')), '');
begin
  v_user := public.kiroku_actor(p_user_id);
  if v_user.role <> 'Admin' then raise exception 'Only Admin can change the masterlist.'; end if;
  if nullif(trim(coalesce(p_name, '')), '') is null then raise exception 'Agency name is required.'; end if;
  if v_id is null then
    v_id := 'k_' || substr(md5(random()::text || clock_timestamp()::text), 1, 10);
    insert into public.kumiai (kumiai_id, name) values (v_id, trim(p_name));
  else
    update public.kumiai set name = trim(p_name) where kumiai_id = v_id;
  end if;
  return v_id;
end $$;

create or replace function public.admin_save_company(p_user_id text, p_company_id text, p_kumiai_id text, p_name text) returns text
language plpgsql security definer set search_path = public
as $$
declare v_user public.users; v_id text := nullif(trim(coalesce(p_company_id, '')), '');
begin
  v_user := public.kiroku_actor(p_user_id);
  if v_user.role <> 'Admin' then raise exception 'Only Admin can change the masterlist.'; end if;
  if nullif(trim(coalesce(p_name, '')), '') is null then raise exception 'Client name is required.'; end if;
  if not exists (select 1 from public.kumiai where kumiai_id = p_kumiai_id) then raise exception 'Choose an agency for this client.'; end if;
  if v_id is null then
    v_id := 'c_' || substr(md5(random()::text || clock_timestamp()::text), 1, 10);
    insert into public.companies (company_id, kumiai_id, name) values (v_id, p_kumiai_id, trim(p_name));
  else
    update public.companies set name = trim(p_name), kumiai_id = p_kumiai_id where company_id = v_id;
  end if;
  return v_id;
end $$;

-- ---------------------------------------------------------------- stages (Configuration page)
create or replace function public.admin_save_stage(p_user_id text, p_stage_id int, p_track text, p_sort int,
  p_name text, p_offset int, p_editor text) returns int
language plpgsql security definer set search_path = public
as $$
declare v_user public.users; v_id int := p_stage_id;
begin
  v_user := public.kiroku_actor(p_user_id);
  if v_user.role <> 'Admin' then raise exception 'Only Admin can change the stages.'; end if;
  if nullif(trim(coalesce(p_name, '')), '') is null then raise exception 'Stage name is required.'; end if;
  if p_editor is not null and not exists (select 1 from public.users where user_id = p_editor and role = 'Doc Officer') then
    raise exception 'A stage can only be owned by a Doc Officer.';
  end if;
  if v_id is null then
    insert into public.stage_config (track, sort_order, stage_name, offset_days, editor_id)
    values (p_track, p_sort, trim(p_name), p_offset, p_editor) returning stage_id into v_id;
  else
    update public.stage_config set track = p_track, sort_order = p_sort, stage_name = trim(p_name),
           offset_days = p_offset, editor_id = p_editor where stage_id = v_id;
  end if;
  return v_id;
end $$;

-- Deleting a stage only removes it from new job orders. Existing job orders keep their tasks.
create or replace function public.admin_delete_stage(p_user_id text, p_stage_id int) returns void
language plpgsql security definer set search_path = public
as $$
declare v_user public.users;
begin
  v_user := public.kiroku_actor(p_user_id);
  if v_user.role <> 'Admin' then raise exception 'Only Admin can change the stages.'; end if;
  delete from public.stage_config where stage_id = p_stage_id;
end $$;

-- ---------------------------------------------------------------- My Entries: create a job order
-- Makes the job order, then its tasks: one per stage in stage_config (3 tracks, 18 stages today).
-- Each due date = target deploy + the stage's days. Later stage changes do not change existing job orders.
create or replace function public.create_job_order(p_user_id text, p_jo_number text, p_company_id text,
  p_worker_name text, p_target date) returns text
language plpgsql security definer set search_path = public
as $$
declare
  v_user public.users;
  v_num  text := nullif(trim(coalesce(p_jo_number, '')), '');
  v_jo   text := 'j_' || substr(md5(random()::text || clock_timestamp()::text), 1, 10);
  v_n    int;
begin
  v_user := public.kiroku_actor(p_user_id);
  if v_user.role not in ('Admin', 'Doc Officer') then raise exception 'Only a Doc Officer or Admin can create a job order.'; end if;
  if v_num is null then raise exception 'JO number is required.'; end if;
  if exists (select 1 from public.job_orders where jo_number = v_num) then raise exception 'JO # % already exists.', v_num; end if;
  if not exists (select 1 from public.companies where company_id = p_company_id) then raise exception 'Choose a client.'; end if;
  if nullif(trim(coalesce(p_worker_name, '')), '') is null then raise exception 'Worker name is required.'; end if;
  if p_target is null then raise exception 'Target deploy date is required.'; end if;
  select count(*) into v_n from public.stage_config;
  if v_n = 0 then raise exception 'Set up the stages in Configuration first.'; end if;

  insert into public.job_orders (jo_id, jo_number, company_id, worker_name, target_deployment_date, active)
  values (v_jo, v_num, p_company_id, trim(p_worker_name), p_target, true);

  insert into public.tasks (task_id, jo_id, track, task_name, sort_order, offset_days, editor_id, due_date, done, status)
  select v_jo || '-' || s.track || '-' || s.sort_order, v_jo, s.track, s.stage_name, s.sort_order,
         s.offset_days, s.editor_id, p_target + s.offset_days, false, 'Pending'
    from public.stage_config s
    join public.track_config t on t.track = s.track
   order by t.sort_order, s.sort_order;
  return v_jo;
end $$;

revoke execute on function public.kiroku_actor(text) from public;
revoke execute on function public.admin_save_kumiai(text, text, text) from public;
revoke execute on function public.admin_save_company(text, text, text, text) from public;
revoke execute on function public.admin_save_stage(text, int, text, int, text, int, text) from public;
revoke execute on function public.admin_delete_stage(text, int) from public;
revoke execute on function public.create_job_order(text, text, text, text, date) from public;
grant execute on function public.admin_save_kumiai(text, text, text) to anon, authenticated, service_role;
grant execute on function public.admin_save_company(text, text, text, text) to anon, authenticated, service_role;
grant execute on function public.admin_save_stage(text, int, text, int, text, int, text) to anon, authenticated, service_role;
grant execute on function public.admin_delete_stage(text, int) to anon, authenticated, service_role;
grant execute on function public.create_job_order(text, text, text, text, date) to anon, authenticated, service_role;


-- ---------------------------------------------------------------- My Entries: edit a job order
-- Changing the target deploy date moves every stage's due date by the same days (due = target + offset).
create or replace function public.update_job_order(p_user_id text, p_jo_id text, p_jo_number text, p_company_id text,
  p_worker_name text, p_target date) returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_user public.users;
  v_old  public.job_orders;
  v_num  text := nullif(trim(coalesce(p_jo_number, '')), '');
begin
  v_user := public.kiroku_actor(p_user_id);
  if v_user.role not in ('Admin', 'Doc Officer') then raise exception 'Only a Doc Officer or Admin can edit a job order.'; end if;
  select * into v_old from public.job_orders where jo_id = p_jo_id for update;
  if v_old.jo_id is null then raise exception 'This job order no longer exists.'; end if;
  if v_num is null then raise exception 'JO number is required.'; end if;
  if exists (select 1 from public.job_orders where jo_number = v_num and jo_id <> p_jo_id) then raise exception 'JO # % already exists.', v_num; end if;
  if not exists (select 1 from public.companies where company_id = p_company_id) then raise exception 'Choose a client.'; end if;
  if nullif(trim(coalesce(p_worker_name, '')), '') is null then raise exception 'Worker name is required.'; end if;
  if p_target is null then raise exception 'Target deploy date is required.'; end if;

  update public.job_orders set jo_number = v_num, company_id = p_company_id,
         worker_name = trim(p_worker_name), target_deployment_date = p_target
   where jo_id = p_jo_id;
  if p_target is distinct from v_old.target_deployment_date then
    update public.tasks set due_date = p_target + offset_days where jo_id = p_jo_id;
  end if;
end $$;

revoke execute on function public.update_job_order(text, text, text, text, text, date) from public;
grant execute on function public.update_job_order(text, text, text, text, text, date) to anon, authenticated, service_role;
