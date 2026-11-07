-- Kiroku V4 — three-state task status, remarks, and task editing from the app.
-- Run once in: Supabase dashboard > SQL Editor > New query > paste > Run.
-- Run after 10_admin_masterlist.sql. Adds to the database and removes nothing.
-- The old page and the old sync keep working after this script. Safe to run twice.
--
-- tasks.status is the progress of a task: Pending, In Progress or Completed.
-- tasks.done stays, because Kiroku and older code depend on it. A trigger keeps the two in step:
--   status = Completed           -> done = true, done_at is set (an existing time is kept)
--   status = Pending/In Progress -> done = false, done_at is cleared
--   done changed, status not     -> Completed when done; when not done, In Progress is left alone
-- So code that only knows done can never turn In Progress into Pending.
-- Overdue is not stored: it is an incomplete task whose due date has passed.

-- ---------------------------------------------------------------- columns
alter table public.tasks add column if not exists status text not null default 'Pending';
alter table public.tasks add column if not exists remarks text;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'tasks_status_check') then
    alter table public.tasks add constraint tasks_status_check
      check (status in ('Pending', 'In Progress', 'Completed'));
  end if;
end $$;

-- Existing completed tasks. Their done_at is not touched.
update public.tasks set status = 'Completed' where done and status <> 'Completed';

-- ---------------------------------------------------------------- status and done in step
create or replace function public.keep_task_status_in_step() returns trigger
language plpgsql set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    if new.status = 'Completed' or new.done then
      new.status  := 'Completed';
      new.done    := true;
      new.done_at := coalesce(new.done_at, now());
    else
      new.done    := false;
      new.done_at := null;
    end if;
    return new;
  end if;

  if new.status is distinct from old.status then
    new.done := new.status = 'Completed';
  elsif new.done is distinct from old.done then
    if new.done then
      new.status := 'Completed';
    elsif old.status = 'Completed' then
      new.status := 'Pending';
    end if;
  end if;

  if new.done then
    new.done_at := coalesce(new.done_at, old.done_at, now());
  else
    new.done_at := null;
  end if;

  if to_jsonb(new) - 'updated_at' is distinct from to_jsonb(old) - 'updated_at' then
    new.updated_at := now();
  end if;
  return new;
end $$;

drop trigger if exists tasks_keep_status_in_step on public.tasks;
create trigger tasks_keep_status_in_step before insert or update on public.tasks
  for each row execute function public.keep_task_status_in_step();

-- ---------------------------------------------------------------- who is allowed
-- True until 11_lock_down.sql: Kiroku has no sign-in yet, so the page names its user.
-- 11_lock_down.sql replaces this with false, and then only the signed-in user counts.
create or replace function public.kiroku_open_mode() returns boolean
language sql stable as $$ select true $$;

-- ---------------------------------------------------------------- editing a task from the app
-- p_fields may hold task_name, due_date, status, remarks, and (Admin only) editor_id.
-- p_expected_updated_at is when the page last read the task. If the task has changed since,
-- nothing is saved and the page says so: an old screen cannot overwrite a newer edit.
-- Admin may edit any task, a Doc Officer only their own, the CEO none.
-- Every change is added to activity_logs. The sync copies the task to the sheets.
create or replace function public.update_task_fields(
  p_task_id text, p_user_id text, p_fields jsonb, p_expected_updated_at timestamptz default null
) returns public.tasks
language plpgsql security definer set search_path = public
as $$
declare
  v_user public.users;
  v_task public.tasks;
  v_new  public.tasks;
  v_name text;
  v_due  date;
  v_stat text;
  v_rem  text;
  v_ed   text;
begin
  if auth.uid() is not null then
    select * into v_user from public.users where auth_user_id = auth.uid();
  elsif public.kiroku_open_mode() then
    select * into v_user from public.users where user_id = p_user_id;
  end if;
  if v_user.user_id is null then
    raise exception 'update_task_fields: sign in first';
  end if;
  if v_user.role = 'CEO' then
    raise exception 'The CEO view is read only.';
  end if;

  select * into v_task from public.tasks where task_id = p_task_id for update;
  if v_task.task_id is null then
    raise exception 'This task no longer exists.';
  end if;
  if v_user.role <> 'Admin' and v_task.editor_id is distinct from v_user.user_id then
    raise exception 'This task is assigned to someone else.';
  end if;
  if p_expected_updated_at is not null and v_task.updated_at > p_expected_updated_at then
    raise exception 'This task was changed by someone else. Reload to see the latest.'
      using errcode = 'P0409';
  end if;

  v_name := coalesce(nullif(trim(p_fields->>'task_name'), ''), v_task.task_name);
  v_due  := coalesce(nullif(trim(p_fields->>'due_date'), '')::date, v_task.due_date);
  v_stat := coalesce(nullif(trim(p_fields->>'status'), ''), v_task.status);
  v_rem  := case when p_fields ? 'remarks' then left(nullif(trim(p_fields->>'remarks'), ''), 2000) else v_task.remarks end;
  v_ed   := v_task.editor_id;
  if p_fields ? 'editor_id' and p_fields->>'editor_id' is distinct from v_task.editor_id then
    if v_user.role <> 'Admin' then
      raise exception 'Only Admin can reassign a task.';
    end if;
    if not exists (select 1 from public.users where user_id = p_fields->>'editor_id' and role = 'Doc Officer') then
      raise exception 'A task can only be assigned to a Doc Officer.';
    end if;
    v_ed := p_fields->>'editor_id';
  end if;

  update public.tasks
     set task_name = v_name, due_date = v_due, status = v_stat, remarks = v_rem, editor_id = v_ed
   where task_id = p_task_id
  returning * into v_new;

  if v_new.status is distinct from v_task.status then
    insert into public.activity_logs (task_id, jo_id, user_id, user_name, action_type, action_details, previous_status, updated_status)
    values (p_task_id, v_task.jo_id, v_user.user_id, v_user.name,
            case when v_new.status = 'Completed' then 'Mark Done' else 'Status Change' end,
            case when v_task.status = 'Completed' then 'Task reopened' else 'Status changed from the task page' end,
            v_task.status, v_new.status);
  end if;
  if v_new.task_name is distinct from v_task.task_name
     or v_new.due_date is distinct from v_task.due_date
     or v_new.remarks is distinct from v_task.remarks
     or v_new.editor_id is distinct from v_task.editor_id then
    insert into public.activity_logs (task_id, jo_id, user_id, user_name, action_type, action_details)
    values (p_task_id, v_task.jo_id, v_user.user_id, v_user.name, 'Task Update',
            left(concat_ws('; ',
              case when v_new.task_name is distinct from v_task.task_name then 'Description: ' || v_task.task_name || ' -> ' || v_new.task_name end,
              case when v_new.due_date is distinct from v_task.due_date then 'Due date: ' || v_task.due_date || ' -> ' || v_new.due_date end,
              case when v_new.remarks is distinct from v_task.remarks then 'Remarks updated' end,
              case when v_new.editor_id is distinct from v_task.editor_id then 'Assigned officer: ' || coalesce(v_task.editor_id, '-') || ' -> ' || v_new.editor_id end
            ), 2000));
  end if;
  return v_new;
end $$;

revoke execute on function public.update_task_fields(text, text, jsonb, timestamptz) from public;
grant  execute on function public.update_task_fields(text, text, jsonb, timestamptz) to anon, authenticated, service_role;
