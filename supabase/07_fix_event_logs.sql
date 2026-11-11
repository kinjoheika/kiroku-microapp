-- OUTDATED (2026-11-11): a one-time repair from the Google Sheets days, already applied. Kept as a record. Do not run it.
-- Kiroku V4 — repair: make event_logs the full event log again.
--
-- When to run: the event_logs table has the OLD columns (event_id, occurred_at, actor,
-- entity ...) instead of event_type, module, description ... This happens when the old
-- event_log table was renamed to event_logs and sync_logs was deleted. In that state
-- every sync fails, because 03_sync.sql writes the new columns.
--
-- What it does (all or nothing):
--   1. Keeps the old table as event_log_old (nothing is deleted).
--   2. Creates event_logs with the full columns (same as 04_event_logs.sql).
--   3. Copies every 'created' / 'updated' row from the old table into it, in the new format.
--      The old 'sync_completed' rows (one every run, even with no changes) are not copied.
--
-- Order: run this file, then re-run 03_sync.sql. Then run syncAll once in Apps Script.
-- New installs do not need this file.

begin;

alter table public.event_logs rename to event_log_old;

create table public.event_logs (
  id            bigint generated always as identity primary key,
  event_at      timestamptz not null default now(),
  event_type    text not null check (event_type in
                  ('Record Created','Record Updated','Record Deleted','Sync Completed','Sync Failed','Activity')),
  source        text not null check (source in ('Google Sheets','Supabase','Kiroku')),
  user_id       text references public.users(user_id),
  user_name     text,
  action        text not null,
  module        text not null,
  record_id     text,
  field_changed text,
  old_value     text,
  new_value     text,
  description   text not null,
  sync_status   text not null default 'Success' check (sync_status in ('Success','Failed','Pending')),
  source_sheet  text,
  created_at    timestamptz not null default now()
);

create index event_logs_event_at_idx on public.event_logs (event_at desc);
create index event_logs_record_idx   on public.event_logs (module, record_id);
create index event_logs_user_idx     on public.event_logs (user_id);
create index event_logs_source_idx   on public.event_logs (source, event_type);

alter table public.event_logs enable row level security;
create policy "read event_logs" on public.event_logs for select to anon, authenticated using (true);
revoke insert, update, delete on public.event_logs from anon, authenticated;

insert into public.event_logs
  (event_at, event_type, source, action, module, record_id, field_changed,
   old_value, new_value, description, source_sheet, created_at)
select occurred_at,
       case action when 'created' then 'Record Created' else 'Record Updated' end,
       'Google Sheets',
       case action when 'created' then 'Create' else 'Update' end,
       initcap(replace(entity, '_', ' ')),
       record_id,
       initcap(replace(field, '_', ' ')),
       old_value, new_value,
       case action when 'created' then initcap(replace(entity, '_', ' ')) || ' record added'
                   else initcap(replace(field, '_', ' ')) || ' updated' end,
       source_sheet, occurred_at
  from public.event_log_old
 where action in ('created', 'updated')
 order by event_id;

commit;
