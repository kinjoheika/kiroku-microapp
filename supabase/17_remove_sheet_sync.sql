-- Kiroku: remove the Google Sheets sync from the database. Kiroku and Supabase are the whole system now.
-- Run after 16_no_sheets.sql: Supabase dashboard > SQL Editor > New query > paste > Run.
-- Run it once the Apps Script is stopped (or deleted) and the secret key is deleted: see supabase/SETUP.md.
--
-- Removes:
--   * sync_import, sync_entity           the functions the Apps Script called to copy the sheets in  (03, 13)
--   * import_sheet_activity and helpers  rows typed into the sheets' Activity tab                     (09)
--   * sheet_sync_state                   what each sheet held after the last sync (bookkeeping only)  (10)
--   * sync_runs                          the history of past syncs (when each ran, whether it worked) (01)
-- Keeps every record: users, job orders, tasks, activity, files and the change log (event_logs, including its
-- old "Google Sheets" rows, which stay as history). activity_logs.source / import_key stay: they mark older rows
-- that came from the sheets.
-- All or nothing: on any error nothing changes. Safe to run twice.
-- Afterwards run 14_security_tests.sql: every row must say PASS.
-- Do NOT run 13_security_hardening.sql again after this file: it still names the removed tables.

begin;

drop function if exists public.sync_import;
drop function if exists public.sync_entity;
drop function if exists public.import_sheet_activity;
drop function if exists public.activity_import_key;
drop function if exists public.activity_action_type;

drop table if exists public.sheet_sync_state;
drop table if exists public.sync_runs;

commit;
