# Kiroku → Supabase setup

## Files in this folder

| File | What it does |
|---|---|
| `01_schema.sql` | Creates the tables: `users`, `kumiai`, `companies`, `job_orders`, `tasks`, `activity`, `edit_log`. Also turns on security rules. |
| `02_seed.sql` | Loads the sample data from the repo's `data/*.csv` (5 users, 2 kumiai, 4 companies, 8 job orders, 144 tasks, 16 activities). |
| `make_seed.py` | Rebuilds `02_seed.sql` from CSVs: `python make_seed.py <repo>/data` |

Both SQL files have been tested together on a blank Postgres database.

## Step 1: Create the project (you do this)

1. Go to https://supabase.com/dashboard and sign in (GitHub sign-in is fine).
2. Click **New project**.
   - Organization: your company's org (create one if asked).
   - Name: `kiroku`
   - Database password: click **Generate**, then save it in your password manager (KeePassXC).
   - Region: **Southeast Asia (Singapore)**, the closest region to PH and JP.
   - Plan: Free is enough for now.
3. Wait about 2 minutes for it to finish setting up.

## Step 2: Create the tables

1. In the left menu, open **SQL Editor** and click **New query**.
2. Paste the whole of `01_schema.sql` and click **Run**. You should see "Success. No rows returned".

## Step 3: Load the sample data

1. Open a **New query** again.
2. Paste the whole of `02_seed.sql` and click **Run**.

## Step 4: Check it

Open **Table Editor**. The row counts should be: users 5, kumiai 2, companies 4,
job_orders 8, tasks 144, activity 16, edit_log 0.

## Step 5: Get the connection details

Open **Project Settings > API** (it may also be called **API Keys / Data API**) and copy:

- **Project URL**, for example `https://abcd1234.supabase.co`
- **anon / publishable key**

You can safely put these two in the web page. Never paste the **service_role / secret** key into the page, the repo or the chat.
That key skips every security rule.

## Security (what the rules allow right now)

- **Anyone with the page** can *read* the data, the same as today's "anyone with the link" Sheet.
- **Nobody** can *write* yet. Writes are open only to logged-in users, and logins come in a later step.
- Times from the sheet (`done_at`) are stored as Philippine time (+08:00).

## Next steps (after Step 5)

1. Make `index.html` read from Supabase instead of the Sheet. The Sheet and CSV stay as a fallback.
2. Add logins (Supabase Auth, email magic link) and link each login to a `users` row through `auth_user_id`.
3. Save "mark done", follow-ups, notes and messages to the database, and write each change to `edit_log`.
   Then the Apps Script logger and its token, which anyone can read in the page, are no longer needed.
4. Uploads: add a private Storage bucket and save each file's path in `activity.file_path`.
5. Bring in the real data from the four live Google Sheets. Export each tab as CSV and run `make_seed.py`.

---

## V4: friendly sheets, task status and editing in Kiroku

Files: `12_task_status.sql`, `apps-script/Sync.gs`, `apps-script/JobOrders.gs`, `index.html`.
Order: run `10_admin_masterlist.sql` and `12_task_status.sql`; paste the scripts; run `setupFriendlySheets`, then
`previewTaskSync` and read its log, then `syncAll` and `installTrigger`; then publish `index.html`. Sign-in stays off
(`LOGIN_REQUIRED` in `index.html`) until the accounts exist; run `11_lock_down.sql` after turning it on, not before.

The Tasks tab shows Job Order, Track, Task Description, Due Date, Status, Assigned Officer and Remarks. The technical
columns stay in the tab, hidden and locked, and the sync finds every column by name (`COLUMN_FIELD` in `Sync.gs`), so
do not rename headers. Each Doc Officer sheet holds only that officer's tasks; the Admin Masterlist holds all of them.

| Change | Result |
|---|---|
| Status set anywhere | `tasks.status`; a trigger keeps `done` and `done_at` in step. Code that only knows `done` cannot turn In Progress into Pending |
| New row in a sheet | Gets a permanent `task_id`, `order` and `offset_days`, written back at once, so a retry cannot add it twice |
| Wrong or missing value in a row | Noted on the row's first cell; the row or value is not sent until it is fixed |
| Doc Officer edits Job Order, Track, Assigned Officer or a hidden column | Ignored and put back. Only Task Description, Due Date, Status and Remarks count |
| Admin changes Assigned Officer | The task moves from one officer's sheet to the other's |
| Same field changed in two places | Admin sheet beats Kiroku beats the officer's sheet. The lost value goes to `event_logs` and a note on the cell |
| Edit in Kiroku from an out-of-date screen | Refused by `update_task_fields`; the user sees a message and the latest value |

Limits: a Google Sheet is protected by its sharing and by the locks `setupFriendlySheets` adds, which hold for accounts that
do not own the sheet. Supabase only enforces who is who once sign-in is on: until then the page names its user.
Conflict order is by source, not by time, because Google Sheets gives the sync no edit times.

---

## V4: Admin Masterlist and logins (do this first; it replaces the old masterlist)

Five Google Sheets in total: 1 Admin Masterlist and 4 Doc Officer sheets. Everyone signs in.
Files: `10_admin_masterlist.sql`, `11_lock_down.sql`, `apps-script/Sync.gs`, `apps-script/JobOrders.gs`.
Do the steps in this order. The site keeps working until step 5.

1. **Database:** run `10_admin_masterlist.sql` in the SQL Editor. It only adds things.
2. **Scripts:** in the Apps Script project, add Script Property `ADMIN_SHEET_ID` = the Admin sheet's ID,
   then paste the new `Sync.gs` and `JobOrders.gs`. The Admin sheet needs its data first: upload a prepared
   copy, or run `setupAdminSheet` once if the script's account can read the old masterlist. It stops rather than
   overwrite a tab that already has rows. Check the Admin sheet, then run `syncAll` and `installTrigger`.
   Only one project may run the sync: remove the trigger from any older project before `installTrigger`. Run `removeUnusedTabs`
   to delete the officers' Event Log tabs. The Admin sheet keeps a read-only Event Log tab, copied from Supabase.
   If the project lives inside the old masterlist file, keep that file: deleting it deletes the scripts.
3. **People:** in the Admin sheet's Users tab, fill in `email` for all 6 users. Wait for the next sync. In Supabase:
   - Authentication > Providers > Email: turn off "Allow new users to sign up"
   - Authentication > URL Configuration: Site URL = the Kiroku website address
   - Authentication > Users > Add user: one per person, same email, "Auto Confirm User" on
4. **Website:** in `index.html`, set `SHEET_ID` to the Admin sheet's ID, then push. Everyone signs in. Check that
   each person sees the right pages. Doc Officers and the CEO have no Configuration tab.
5. **Lock:** run `11_lock_down.sql`. From now on Supabase itself refuses anyone who is not signed in, and
   only Admin can read `event_logs` and `sync_runs`.
   The way back, if something is wrong: re-run the `grant`, `create policy` and `log_task_activity` parts of
   `01_schema.sql`, `04_event_logs.sql`, `06_activity_logs.sql` and `08_task_files.sql`, after dropping the policies that
   `11_lock_down.sql` created. No data changes either way.

How the sheets stay in step (`syncTasks` in `Sync.gs`), every 5 minutes:

| Change | Result |
|---|---|
| Doc Officer edits their own task | Supabase, Kiroku, the Admin Masterlist and the other officer sheets |
| Admin edits a task | Supabase, Kiroku, the owner's sheet and the other officer sheets |
| Both change the same field | Admin's value stays; the officer's is kept in `event_logs` (action Conflict) |
| Doc Officer edits another officer's row | Put back, as before |
| A row is removed from a sheet | Put back. Delete Job Orders in the app |
| Mark Done in Kiroku | The task changes in Supabase, then in every sheet |

Assigned Officer: `editor_id` on each task decides the owner, and only Admin can change it. The Admin sheet's
`assigned_officer` (Tasks) and `assigned_officers` (JobOrders) columns show names. The sync fills them in and never reads them.

Limits: Job Orders, Users, Kumiai and Companies are edited in the Admin sheet only. The Google Sheets themselves
are protected by Google sharing, not by Kiroku: share each sheet only with its owner and Admin, and turn off
"Anyone with the link" if you do not need the Sheet backup. Users in Configuration is a list; people
are added in the Users tab and in Supabase Authentication, because creating logins needs a secret key the page must not hold.

---

## V4: sync the Google Sheets into Supabase

Files: `03_sync.sql` (the sync function), `apps-script/Sync.gs` (reads the sheets and calls it).

1. **Run `03_sync.sql`** in the SQL Editor, after `01_schema.sql`.
   Do NOT run `02_seed.sql` if you will sync the real sheets (it would load the sample data first).
2. **Copy the keys** from Project Settings > API:
   the Project URL and the **service_role** key (secret).
3. **Apps Script:** open ONE Google Sheet (the masterlist) > Extensions > Apps Script, paste `apps-script/Sync.gs`.
   One copy syncs all five sheets; copies in other sheets would run the sync several times.
   Project Settings (gear icon) > Script Properties, add:
   - `SUPABASE_URL` = your Project URL
   - `SUPABASE_SERVICE_KEY` = the service_role key
   - `SHEET_ID_1` … `SHEET_ID_4` = the spreadsheet IDs (the part between `/d/` and `/edit` in the URL)
4. `SOURCES` at the top of `Sync.gs` lists each sheet, its owner and the tabs it sends.
5. Run `syncAll` once (Run button) and approve the permissions. Check the Execution log.
   Then run `installTrigger` once to sync every 5 minutes.

Re-running a sync never duplicates rows: each row is matched by its key
(`user_id`, `kumiai_id`, `company_id`, `jo_id`, `task_id`, or `activity_key` for activity).
Every new row and every changed field is recorded in `event_logs` (run `04_event_logs.sql` first), and each run in `sync_runs`.

If `event_logs` has the old columns (`event_id`, `occurred_at`, `actor`, `entity` …), every sync fails.
Repair: run `07_fix_event_logs.sql`, then re-run `03_sync.sql`, then run `syncAll` once.
The old rows are kept in `event_log_old`, and their created/updated history is copied into `event_logs`.

**Who sends what (one owner per row, so no sheet overwrites another):**

| Sheet | Sends to Supabase |
|---|---|
| Masterlist | Users, Kumiai, Companies, JobOrders (synced first) |
| Doc Officer 1..4 | Only Tasks where `editor_id` is that officer (u1..u4); new rows typed into its Activity tab (see "one activity list" below) |

Every Doc Officer sheet still shows every task. After the sync, the other officers' task rows are
rewritten from Supabase and shaded grey; edits there are ignored and put back. New companies and
job orders go in the masterlist.
Each Doc Officer sheet needs only Tasks and Activity: run `removeUnusedTabs` once to delete its other tabs. Run `Sync.gs` from **one** Apps Script project only, with one trigger: `syncAll` already loops over all five sheets.

Supabase is the real event log. Only the Admin sheet has an Event Log tab, a read-only copy of it.

Never put the service_role key in `index.html` or any file in the GitHub repo.

---

## V4: Job Orders from the app (saved to the Sheets and Supabase)

File: `apps-script/JobOrders.gs`. Without it, Job Order changes made in the app stay in that browser
and are gone on the next page load.

1. In the **same** Apps Script project as `Sync.gs`, add a file `JobOrders.gs` and paste `apps-script/JobOrders.gs`.
   Also paste the updated `Sync.gs`, then run `installTrigger` once more: the 5-minute trigger now runs
   `scheduledSync`, which waits while an app change is being saved.
2. The web app checks the signed-in user's Supabase token: only Admin and Doc Officer 1 can change Job Orders.
3. Deploy > New deployment > type **Web app**. Execute as: **Me**. Who has access: **Anyone**. Approve the permissions.
4. Copy the Web app URL into `JO_WRITE_URL` in `index.html`.
5. If the old `Code.gs` (EditLog) is in this project, remove it: a project can have only one `doPost`.

What each button does (Doc Officer 1), then `syncAll()` runs right away:

| In the app | Google Sheets | Supabase |
|---|---|---|
| Create Job Order | row added to masterlist **JobOrders** (next free `jo_id`, `worker_name` = `TBA`); each task added to its owner's **Tasks** tab | inserted by the sync; copied to the other officers' sheets |
| Save changes | JobOrders row updated; if the deploy date moved, the owners' task `due_date`s too | updated by the sync |
| Archive / Reactivate | `active` set to FALSE / TRUE | updated by the sync |
| Delete | JO row, its task rows (all four officer sheets) and their Activity rows removed | Job Order deleted (its tasks go with it); one Record Deleted row in `event_logs` |

Every change shows in Configuration > **Sync Logs** (Record Created / Updated / Deleted). Edits also add a
Task Update row to **Event Logs**.

Delete is refused for a Job Order that has rows in `activity_logs` (follow-ups, notes, edits ...): that
history is append-only and kept forever. Archive it instead.
If the sync step fails, the sheets are already changed and the 5-minute trigger brings Supabase up to date.

After changing `JobOrders.gs` or `Sync.gs`, use Deploy > Manage deployments > Edit > New version,
or the web app keeps running the old code.

---

## V4: file uploads (Upload button + Files tab)

File: `08_task_files.sql`. Run it once in the SQL Editor, after `06_activity_logs.sql`.

It creates the private Storage bucket `task-files` (10 MB per file) and its access rules.
The Upload button on a task:

1. stores the file at `task-files/<task_id>/<client_ref>`
2. then writes an Upload row to `activity_logs` (file name in `action_details`, same `client_ref`)

The file shows in the task's **Files** tab, where it can be opened in a new tab or downloaded.
Files cannot be overwritten or deleted from the page. Uploads imported from the sheets, or logged
before this step, have no stored file and show as "name only".

Until this script is run, the Upload button shows "file storage is not set up".
Anyone with the page can read the files, the same as the other data; limit this to signed-in users
when Supabase Auth is added.

---

## V4: activity log (Recent Actions + Configuration > Event Logs)

File: `06_activity_logs.sql`. Run it once in the SQL Editor, after `01_schema.sql`.

It creates `activity_logs`: one permanent row per action on a task (Follow Up, Send Message,
Log Note, Upload, Mark Done, Status Change, Task Update, Save). The page writes only through
`log_task_activity()`, which:

- stamps the server time (not the browser clock)
- reads the user's name from `users` (and, once logins exist, uses the signed-in user instead of the dropdown)
- takes the job order from the task, so a row always points at the right job order
- returns the existing row when the same click is sent twice

Rows cannot be updated, deleted or truncated, not even with the service_role key (a trigger blocks it).
The script also adds the table to Supabase Realtime so open pages show new actions without a refresh.

Until this script is run, the task page shows "Activity log not reachable" and actions are not recorded.

---

## V4: one activity list (activity + activity_logs merged, copied to every sheet)

File: `09_merge_activity.sql`. Before it, there were two lists: `activity` (rows from the sheets'
Activity tabs) and `activity_logs` (actions taken in the app). The app never wrote to the sheets,
so the Activity tabs and the `activity` table never grew.

After it, `activity_logs` is the only list. Each Doc Officer sheet's **Activity** tab is a copy of that
officer's own rows in it (`user_id` = u1..u4): everything they did, in the app or typed into the sheet, on any task.

Steps, in this order:

1. Run `09_merge_activity.sql` in the SQL Editor. It copies every `activity` row into `activity_logs`
   (source `Google Sheets`, user = the row's user or else the task's editor, time = the sheet's date and time),
   then deletes the `activity` table. Both happen together: if the copy fails, the table is not deleted.
2. Run `03_sync.sql` again (the sync no longer sends the Activity tab as a table).
3. Paste the new `apps-script/Sync.gs` and run `syncAll` once. Each Activity tab is rewritten with these
   columns: `task_id, action_type, date, time, details, user_name, jo_id, previous_status, updated_status, source, activity_id`.

How it works from then on (every sync, every 5 minutes):

| Where the action happens | What happens |
|---|---|
| In the app (Follow Up, Send Message, Log Note, Upload, Mark Done …) | saved to `activity_logs` at once; shows in that user's Activity tab after the next sync |
| Typed into a sheet's Activity tab (new row, `activity_id` blank) | added to `activity_logs` as that sheet's Doc Officer, then shows in the app |

Actions by users without a Doc Officer sheet (for example the CEO) are in `activity_logs` and the app, but in no Activity tab.

- From a sheet, only Follow Up, Send Message, Log Note and Upload can be added (Mark Done changes the task, so it needs the app).
- A typed row that cannot be added (unknown `task_id`, wrong type, bad date) stays at the bottom in red, with the reason as a note.
- Rows with an `activity_id` cannot be changed or deleted: edits to them are put back on the next sync.
- A Job Order with any activity (including the rows copied from the old table) can no longer be deleted, only archived.
