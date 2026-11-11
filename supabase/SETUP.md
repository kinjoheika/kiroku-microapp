# Kiroku database (Supabase)

Kiroku is the website (`index.html`) and this Supabase database. Nothing else: no Google Sheets, no Apps Script.
Every rule about who may see and change what is enforced here, not only in the page.

## The files

Numbered in the order they were applied to the live database. They are the record of how it was built.
To change the database, add a new numbered file; do not edit or re-run old ones.

| File | What it does | Status |
|---|---|---|
| `00_security_check.sql` | Reports the current security settings. Changes nothing. | Run any time |
| `01_schema.sql` | Creates the tables: users, kumiai, companies, job_orders, tasks | Applied |
| `03_sync.sql` | Google Sheets sync | Applied, removed by 17. Do not run |
| `04_event_logs.sql` | The change log (event_logs): who changed what, when. Permanent | Applied |
| `06_activity_logs.sql` | Actions on tasks (Follow Up, Log Note, Upload, Mark Done). Permanent | Applied |
| `07_fix_event_logs.sql` | One-time repair | Applied. Do not run |
| `08_task_files.sql` | File uploads on tasks (storage bucket task-files) | Applied |
| `09_merge_activity.sql` | One-time merge of the old activity list; sheet import | Applied, sheet parts removed by 17. Do not run |
| `10_admin_masterlist.sql` | users.email, login checks, Mark Done updates the task | Applied. Do not run |
| `11_lock_down.sql` | First lock-down (sign-in required) | Applied, replaced by 13 |
| `12_task_status.sql` | Task status (Pending / In Progress / Completed), remarks, editing tasks | Applied |
| `13_security_hardening.sql` | **The main security rules** | Applied. Do not run again after 17 |
| `13_rollback.sql` | Undo 13 (insecure) | Obsolete. Never run |
| `14_security_tests.sql` | **The security exam.** Tries every action as every role. Changes nothing | Run after every change: all PASS |
| `15_entries_stages.sql` | My Entries, stages, agencies and clients | Applied |
| `16_no_sheets.sql` | Users, archive / reactivate / delete job orders | Applied 2026-11-11 |
| `17_remove_sheet_sync.sql` | Removes the Google Sheets sync (functions, sheet_sync_state, sync_runs) | **To run**: see below |

## Run 17 (finish removing Google Sheets)

Do these in order:

1. Supabase → **Project Settings → API Keys → Secret keys**: delete every secret key. If **Legacy API keys** are
   shown, **Disable legacy API keys**. Kiroku uses only the publishable key.
2. Reload Kiroku and sign in: it must work as before.
3. **SQL Editor → New query**: paste `17_remove_sheet_sync.sql` → **Run**. All or nothing; safe to run twice.
4. New query: paste `14_security_tests.sql` → **Run**. Every row must say **PASS**.
5. Google Drive: delete the Kiroku Google Sheets and the Apps Script project, then empty the Drive trash.
   (Optional first: **File → Download → Microsoft Excel** in each sheet, to keep a copy.)

Every record stays: users, job orders, tasks, activity, files and the change log. Older rows that came from the
sheets keep their "Google Sheets" source as history.

## Who may do what (enforced by the database)

| | Not signed in | Doc Officer | CEO | Admin |
|---|---|---|---|---|
| Read job orders, tasks, activity | – | ✓ | ✓ | ✓ |
| Edit a task, log an action | – | own tasks | – | all |
| Create a job order | – | ✓ | – | ✓ |
| Edit / archive a job order | – | if they have a task on it | – | ✓ |
| Delete a job order (only if nothing was ever logged on it) | – | – | – | ✓ |
| Users, agencies, clients, stages | – | – | – | ✓ |
| Read the change log | – | – | – | ✓ |

Who is acting is always taken from the login, never from what the page sends. The change log and the activity
log cannot be edited or deleted.

## People and logins

* **Add a person:** Kiroku → Configuration → Users → Add person (name, role, email).
* **Let them sign in:** Supabase → **Authentication → Users → Add user** with the same email. Then **Table Editor →
  users** → put that login's ID (from Authentication) in their `auth_user_id`. Only the dashboard can link a login,
  on purpose: nobody can link themselves to another person.
* **Someone leaves:** delete their login under Authentication on the same day. Their name stays on past records.

## Keeping a copy

Kiroku → **Configuration → Download Excel** gives every list in one `.xlsx` file (Job Orders, Tasks, Users,
Agencies, Clients, Activity, Change Log). It is a copy: editing it changes nothing in Kiroku.
Until proper backups are set up (see `SECURITY_TODO.md`), Admin downloads one each week.

## Connection details

The page needs the **Project URL** and the **publishable key** (Project Settings → API Keys). Both are safe to
publish. Never put a **secret** key in the page, the repository or a chat: it skips every rule.
