-- PARTLY OUTDATED (2026-11-11): the sheet-sync parts (sheet_sync_state) were removed by 17_remove_sheet_sync.sql.
-- The rest is still in use: users.email, the login checks and Mark Done updating the task. Do not run it again.
-- Kiroku V4 — Admin Masterlist, two-way task sync and logins: the parts that break nothing.
-- Run once in: Supabase dashboard > SQL Editor > New query > paste > Run.
-- Run after 09_merge_activity.sql, BEFORE the new index.html and Sync.gs go live.
-- Adds to the database and removes nothing. The old page keeps working after this script.
-- Safe to run twice. See supabase/SETUP.md ("Admin Masterlist and logins").

-- ---------------------------------------------------------------- users: who may sign in
-- email comes from the Users tab of the Admin Masterlist, like the other columns.
alter table public.users add column if not exists email text;
create unique index if not exists users_email_key on public.users (lower(email));

-- ---------------------------------------------------------------- two-way task sync
-- What each sheet held after the last sync (see syncTasks in apps-script/Sync.gs).
-- Row security with no policy: only the service_role key used by the sync can read or write it.
create table if not exists public.sheet_sync_state (
  source     text not null,                       -- admin, doc-officer-1 .. doc-officer-4
  task_id    text not null,
  fields     jsonb not null,
  updated_at timestamptz not null default now(),
  primary key (source, task_id)
);
alter table public.sheet_sync_state enable row level security;

-- ---------------------------------------------------------------- Mark Done reaches the task
-- A Mark Done or reopen in the app used to write only its activity_logs row, so the task went
-- back to open on the next page load. Now the task changes too, and the sync copies it to the sheets.
create or replace function public.apply_task_status_from_log() returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  if new.task_id is null then return new; end if;
  if new.action_type = 'Mark Done' then
    update public.tasks set done = true, done_at = new.created_at, updated_at = now() where task_id = new.task_id;
  elsif new.action_type = 'Status Change' and new.action_details = 'Task reopened' then
    update public.tasks set done = false, done_at = null, updated_at = now() where task_id = new.task_id;
  end if;
  return new;
end $$;

drop trigger if exists activity_logs_apply_status on public.activity_logs;
create trigger activity_logs_apply_status after insert on public.activity_logs
  for each row execute function public.apply_task_status_from_log();

-- ---------------------------------------------------------------- who is signed in
create or replace function public.is_kiroku_user() returns boolean
language sql stable security definer set search_path = public
as $$ select exists (select 1 from public.users where auth_user_id = auth.uid()) $$;

create or replace function public.is_kiroku_admin() returns boolean
language sql stable security definer set search_path = public
as $$ select exists (select 1 from public.users where auth_user_id = auth.uid() and role = 'Admin') $$;

-- Called by the page after sign-in. Returns the signed-in person's Kiroku user. The first time,
-- it links the login to the row in users with the same confirmed email.
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

revoke execute on function public.link_my_account() from public, anon;
grant  execute on function public.link_my_account() to authenticated;
grant  execute on function public.is_kiroku_user() to anon, authenticated;
grant  execute on function public.is_kiroku_admin() to anon, authenticated;
