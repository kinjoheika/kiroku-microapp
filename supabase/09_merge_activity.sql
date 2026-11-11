-- OUTDATED (2026-11-11): the one-time merge is done, and 17_remove_sheet_sync.sql removed the sheet-import functions
-- this file created (import_sheet_activity and its helpers). Kept as a record. Do not run it.
-- Kiroku V4 — merge the old activity table into activity_logs.
-- Run once in: Supabase dashboard > SQL Editor > New query > paste > Run.
-- Run after 06_activity_logs.sql. Then re-run 03_sync.sql (the sync no longer sends activity)
-- and paste the new apps-script/Sync.gs.
--
-- After this script:
--   * activity_logs is the only activity table. The app writes to it (log_task_activity),
--     and rows typed into a Google Sheet's Activity tab are added by import_sheet_activity().
--   * Each sheet's Activity tab is a copy of activity_logs, rewritten by Sync.gs after every sync.
--   * The old activity table is deleted, after its rows are copied. The copy and the delete run
--     together: if the copy fails, nothing is deleted.
-- Safe to run twice: the second run finds no activity table and only re-creates the functions.

-- ---------------------------------------------------------------- new columns
-- source:     where the row was recorded (the app, or typed into a Google Sheet)
-- import_key: task_id|type|date|time for rows from the sheets (the old activity_key),
--             so the same sheet row is never added twice
alter table public.activity_logs
  add column if not exists source text not null default 'Kiroku'
    check (source in ('Kiroku','Google Sheets')),
  add column if not exists import_key text unique;

-- ---------------------------------------------------------------- sheet type -> action_type
create or replace function public.activity_action_type(p_type text) returns text
language sql immutable as $$
  select case lower(replace(trim(coalesce(p_type, '')), ' ', ''))
    when 'followup'     then 'Follow Up'
    when 'message'      then 'Send Message'
    when 'sendmessage'  then 'Send Message'
    when 'note'         then 'Log Note'
    when 'lognote'      then 'Log Note'
    when 'upload'       then 'Upload'
    when 'markdone'     then 'Mark Done'
    when 'statuschange' then 'Status Change'
    when 'taskupdate'   then 'Task Update'
    when 'save'         then 'Save'
  end
$$;

-- The import key uses the old short type names, so a row matches its old activity_key.
create or replace function public.activity_import_key(p_task text, p_action text, p_date date, p_time time)
returns text language sql immutable as $$
  select concat_ws('|', p_task,
    case p_action when 'Follow Up' then 'followup' when 'Send Message' then 'message'
                  when 'Log Note' then 'note' when 'Upload' then 'upload' else p_action end,
    to_char(p_date, 'YYYY-MM-DD'), to_char(p_time, 'HH24:MI'))
$$;

-- ---------------------------------------------------------------- copy the old rows
-- Who: the row's user, or else the task's editor (the officer whose sheet sent it).
do $$
declare
  n_missing int;
  n_copied  int;
begin
  -- an earlier version of this script kept the old table as a backup
  drop table if exists public.activity_old;

  if to_regclass('public.activity') is null then
    raise notice 'public.activity is already gone; nothing to copy';
    return;
  end if;

  select count(*) into n_missing
    from public.activity a join public.tasks t using (task_id)
    left join public.users u on u.user_id = coalesce(a.user_id, t.editor_id)
   where u.user_id is null;
  if n_missing > 0 then
    raise exception '% activity rows have no user and their task has no editor_id; fix them first', n_missing;
  end if;

  insert into public.activity_logs
    (task_id, jo_id, user_id, user_name, action_type, action_details, created_at, source, import_key)
  select a.task_id, t.jo_id, u.user_id, u.name,
         public.activity_action_type(a.type),
         left(coalesce(a.body, a.file_path), 2000),
         (a.activity_date + a.activity_time) at time zone 'Asia/Manila',
         'Google Sheets',
         coalesce(a.activity_key,
                  public.activity_import_key(a.task_id, public.activity_action_type(a.type), a.activity_date, a.activity_time))
    from public.activity a
    join public.tasks t using (task_id)
    join public.users u on u.user_id = coalesce(a.user_id, t.editor_id)
   order by a.activity_date, a.activity_time, a.activity_id
  on conflict (import_key) do nothing;
  get diagnostics n_copied = row_count;

  drop table public.activity;
  raise notice 'copied % rows into activity_logs; the activity table is deleted', n_copied;
end $$;

-- ---------------------------------------------------------------- rows typed into a sheet
-- Called by Sync.gs with the service_role key, once per Doc Officer sheet.
-- p_user: the sheet's owner (u1..u4), who is recorded as the person who did it.
-- p_rows: [{row, task_id, action_type, date, time, details}, ...]  (date/time are Philippine time)
-- Returns {added, existing, skipped: [{row, reason}]}. A bad row is skipped, never fails the sync,
-- so Sync.gs can keep it in the tab for the officer to fix.
create or replace function public.import_sheet_activity(p_source text, p_user text, p_rows jsonb)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  r        jsonb;
  v_user   public.users;
  v_jo     text;
  v_action text;
  v_date   date;
  v_time   time;
  v_key    text;
  v_id     bigint;
  n_add    int := 0;
  n_same   int := 0;
  skipped  jsonb := '[]'::jsonb;
begin
  select * into v_user from public.users where user_id = p_user;
  if v_user.user_id is null then
    raise exception 'import_sheet_activity: unknown user %', p_user;
  end if;

  for r in select value from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) loop
    begin
      select jo_id into v_jo from public.tasks where task_id = trim(r->>'task_id');
      if v_jo is null then
        skipped := skipped || jsonb_build_object('row', r->'row', 'reason', 'unknown task_id');
        continue;
      end if;
      -- Mark Done and the other app actions change the task too, so only the app records them.
      v_action := public.activity_action_type(r->>'action_type');
      if v_action is null or v_action not in ('Follow Up','Send Message','Log Note','Upload') then
        skipped := skipped || jsonb_build_object('row', r->'row',
          'reason', 'action_type must be Follow Up, Send Message, Log Note or Upload');
        continue;
      end if;
      v_date := coalesce(nullif(trim(r->>'date'), '')::date, (now() at time zone 'Asia/Manila')::date);
      v_time := coalesce(nullif(trim(r->>'time'), '')::time, (now() at time zone 'Asia/Manila')::time);
    exception when others then
      skipped := skipped || jsonb_build_object('row', r->'row', 'reason', 'bad date or time');
      continue;
    end;

    v_key := public.activity_import_key(trim(r->>'task_id'), v_action, v_date, v_time);
    v_id  := null;
    insert into public.activity_logs
      (task_id, jo_id, user_id, user_name, action_type, action_details, created_at, source, import_key)
    values
      (trim(r->>'task_id'), v_jo, v_user.user_id, v_user.name, v_action,
       left(nullif(trim(r->>'details'), ''), 2000),
       (v_date + v_time) at time zone 'Asia/Manila', 'Google Sheets', v_key)
    on conflict (import_key) do nothing
    returning activity_id into v_id;

    if v_id is null then
      n_same := n_same + 1;
    else
      insert into public.event_logs
        (event_type, source, action, module, record_id, user_id, user_name, description, source_sheet)
      values ('Record Created', 'Google Sheets', 'Create', 'Activity', v_id::text, v_user.user_id, v_user.name,
              v_action || ' on ' || trim(r->>'task_id') || ' added from the sheet', p_source);
      n_add := n_add + 1;
    end if;
  end loop;

  return jsonb_build_object('added', n_add, 'existing', n_same, 'skipped', skipped);
end $$;

revoke execute on function public.import_sheet_activity(text, text, jsonb) from public, anon, authenticated;
grant  execute on function public.import_sheet_activity(text, text, jsonb) to service_role;
