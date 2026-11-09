# Kiroku security audit — stage 1: findings

Date: 2026-11-09. Scope: `index.html`, `config.html`, `apps-script/*.gs`, `supabase/01–12*.sql`.
**Nothing has been changed yet.** The only new files are this one and `supabase/00_security_check.sql`, which is read-only.

I could not connect to the live database. The SQL files show what *should* be there, and the page code shows
that the live site still runs in **demo-login mode**. Run `00_security_check.sql` to confirm what is actually live
before stage 2.

---

## Live check — 2026-11-09 (00_security_check.sql + tests from outside with the public key only)

Verdict: **not secure yet.** Someone has already applied some fixes by hand (below), but the main holes are still open.

| Area | Live state | Status |
|---|---|---|
| Anon reads `users` (incl. emails), `kumiai`, `companies`, `activity_logs` (56 rows of notes/messages), `sync_runs` (20k rows) | Confirmed by request | **Open** |
| Anon reads `tasks`, `job_orders`, `event_logs` | 401 refused | Fixed |
| **Public sign-up is ON** (`disable_signup: false`). Any stranger who registers and confirms an email reads `users`, `tasks`, `job_orders`, `activity_logs`, `companies`, `kumiai`, `sync_runs`: every read policy is `using (true)`, not `is_kiroku_user()` | Confirmed | **Open (critical)** |
| Anon / authenticated hold INSERT, UPDATE, DELETE, TRUNCATE on 7 tables | RLS blocks the row writes (no write policies). TRUNCATE is not covered by RLS. PostgREST cannot send TRUNCATE, but the grants are still wrong | **Open (defence in depth)** |
| `event_logs` | Append-only trigger `protect_event_logs` exists; TRUNCATE is still not blocked | Mostly fixed |
| Storage `task-files` | **Anon can upload into any task folder and read every file** | **Open** |
| `update_task_fields`, `log_task_activity` | Callable by nobody but `service_role`. Impersonation (C2) is closed, but **Mark Done, notes, messages, uploads and task edits from the app fail for every signed-in user too**. Old open-mode bodies still installed | Closed but broken |
| Default privileges | New tables and functions automatically grant ALL to anon | **Open** |
| Google Sheets | All 5 return 401 to the public | Fixed (C3) |
| Accounts | 6/6 linked and confirmed; no stray logins. `users.email` (`*@kiroku.sample`) differs from every login email; Doc Officer 2 has never signed in | OK; tidy the emails |
| Realtime | `activity_logs` is not published | Live updates are off |
| Page | `MOCK_LOGIN = true` and the hard-coded password are still in `index.html` | **Open** |

---

## Summary

The database design is mostly sound. Writes go through checked functions, `activity_logs` cannot be changed,
and the sync key stays in Script Properties. But the protections in `11_lock_down.sql` are **not in force today**,
because the live page still uses demo logins. As a result:

* anyone on the internet can read Kiroku's data (through the Google Sheets, and probably through Supabase too)
* anyone can edit tasks *as Admin*

Five problems are critical.

| # | Severity | Problem | Who can use it |
|---|---|---|---|
| C1 | Critical | Demo login is the live mode: one shared password and a no-password "pick a user" button | Anyone who opens the site |
| C2 | Critical | `update_task_fields` and `log_task_activity` trust the user ID the page sends (open mode) | Anyone holding the publishable key, which is in the page |
| C3 | Critical | All five Google Sheets are "Anyone with the link: Viewer", and their IDs are in the public page | Anyone who opens the site |
| C4 | Critical | The sync writes **every** column in the Admin Masterlist, including `auth_user_id` | Anyone who can edit the Admin Masterlist |
| C5 | High | Stored XSS: sheet text is put into the page without full escaping, and the session sits in localStorage | Any Doc Officer, against Admin |
| H1–H9, M1–M6 | High / Medium | See below | |

---

## Critical

### C1. Demo login is the live mode — `index.html:3493-3503`, `:3654-3679`
```js
const LOGIN_REQUIRED = false;
const MOCK_LOGIN = true;
const MOCK_PASSWORD = '…';   // (value removed from this report)
const MOCK_ACCOUNTS = { 'admin@kiroku.sample':'u6', ... };
```
* One password for everyone, readable in the page source (and in git history on GitHub).
* The `siSwitch` picker signs in as **any user, Admin included, with no password**.
* In this mode every request goes out with the publishable key (`authBearer()` falls back to `SUPABASE_KEY`).
  Supabase cannot tell who anyone is, so no database rule can apply per user.
* `startWithoutLogin()` (the `userSwitch` dropdown) is a third way in, with no sign-in at all.

**Fix (stage 3):** delete `MOCK_*`, `startWithMockLogin`, `pickMockUser`, `enterMock`, `startWithoutLogin`,
the `userSwitch` dropdown and the `?login` switch. Sign-in becomes the only way in.

### C2. Anyone can act as Admin through the database functions — `12_task_status.sql`, `06_activity_logs.sql`
Until `11_lock_down.sql` runs, `kiroku_open_mode()` returns `true` and `update_task_fields` is granted to `anon`:
```sql
elsif public.kiroku_open_mode() then
  select * into v_user from public.users where user_id = p_user_id;   -- the caller picks who they are
```
With only the publishable key from the page source:
```
POST /rest/v1/rpc/update_task_fields
{"p_task_id":"<any>","p_user_id":"u6","p_fields":{"status":"Completed","editor_id":"u3"}}
```
This edits any task as Admin, reassigns it, and writes a forged `activity_logs` row in Admin's name.
The `06` version of `log_task_activity` (granted to `anon`) does the same with `e->>'user_id'`. Through the
`apply_task_status_from_log` trigger it can also mark any task done or reopened.

**Fix (stage 2):** the `11_lock_down.sql` versions are correct. They use only `auth.uid()`, block the CEO,
and allow officers their own tasks only. They have to go live, and stage 3 must ship first so the page keeps working.

### C3. The Google Sheets are public — `index.html:1025-1043`, `:2023`
The page's fallback reads every sheet through `gviz/tq?tqx=out:csv`. That only works because the sheets are shared
"Anyone with the link". Their IDs are in the page. So users' **emails**, roles, worker names, all tasks and all activity
can be downloaded by anyone, **whatever Supabase's rules say**. RLS cannot protect data that is also published elsewhere.

**Fix (stage 3 + a sharing change you make in Google Drive):** remove the Sheet/CSV fallback from the page. Share each
sheet only with the named Google accounts (the Apps Script owner, Admin, and that sheet's officer). Remove "Anyone with the link".
*Breaks:* the page no longer shows data when Supabase is down. It shows "cannot reach Kiroku" instead.

### C4. The sync can rewrite logins and roles — `Sync.gs:1181-1204` → `03_sync.sql: sync_entity`
`readTab` sends every non-empty header as a column. `sync_entity` builds its `INSERT`/`UPDATE` from whatever keys arrive,
with the service key, which bypasses every rule. Someone with edit access to the Admin Masterlist can add a column named
`auth_user_id` to the Users tab and:
* move Admin's login onto their own account, or
* blank it, change `email`, and let `link_my_account()` attach a different login on its next sign-in.

The **Role** column also goes straight into `users.role`, with no check that it is one of the three roles.

**Fix (stage 2):** an allow-list in `sync_entity` (users: `user_id, name, role, email` only, never `auth_user_id` or `created_at`),
a `check (role in ('Admin','CEO','Doc Officer'))` constraint, and a trigger so that `auth_user_id` and `role` changes are
written to `event_logs`. The same allow-list goes into `readTab`.

### C5. Stored XSS, which turns an officer into Admin — `index.html`
* `escHTML` (`:1850`) does not escape `"` or `'`, yet it is used inside attributes (`value="${escHTML(f.q)}"` `:3447`, `<option value=…>` `:3438`).
* Values that come from the sheets are inserted with no escaping at all, for example:
  * `:2175` company names in `<option>`
  * `:2965` the officer name
  * `:3404` `jo.jo`
  * `t.track` in many places
  * `onclick="msgAdd('${u.id}')"` and `pickMockUser('${u.id}')`
* supabase-js keeps the session in `localStorage`. A script injected through a company name or task description therefore
  runs in Admin's browser and can take Admin's session.
* The supabase-js `<script>` from jsdelivr (`:1022`) has no `integrity=` hash, and the site sends no Content-Security-Policy.

**Fix (stage 4):** make `escHTML` escape `& < > " '`; escape every inserted value; replace inline `onclick` string-building with
`data-` attributes and one event listener; add an SRI hash and a CSP `<meta>`.

---

## High

* **H1. Anon table grants** (your check: `activity_logs, companies, job_orders, kumiai, sheet_sync_state, sync_runs, users`).
  * Supabase grants anon **ALL** privileges on every new table by default.
  * `11_lock_down.sql` revokes anon on its 8 tables, but not on `sheet_sync_state`, `event_log_old` or Storage.
  * The fact that anon still has SELECT means 11 has not run, or the grants came back. The check script will show which.
  * **Fix:** `revoke all … from anon` on every public table, and `alter default privileges … revoke all on tables from anon`
    so future tables start closed.
* **H2. `event_logs` can be changed by the sync key.** `activity_logs` has an append-only trigger; `event_logs` does not.
  **Fix:** the same trigger. Old rows are kept as they are.
* **H3. Leftover tables.** `event_log_old` (from `07`) may still exist and may still be readable by anon.
  **Fix:** lock it the same way. It is not deleted.
* **H4. Open sign-up.** If "Allow new users to sign up" is on in Supabase Auth, anyone can create a login with the publishable key.
  `link_my_account()` auto-links by email. **Fix:**
  * turn sign-ups off (Dashboard > Authentication > Sign In / Providers)
  * since all six are already linked, make `link_my_account()` only *return* the linked profile, never link one
  * new staff are linked by Admin
* **H5. `JobOrders.gs`.**
  * u1 is hard-coded as a manager. This may be intended; please confirm.
  * `tasks[].editor_id`, `track` and dates arrive from the browser unchecked.
  * Only the Apps Script lock limits how often it can be called.
  * **Fix:** check `editor_id` is a Doc Officer, `track` is TIO/OTIT/COE, and dates are valid. Move the "who may manage Job Orders" list into the database.
* **H6. `Code.gs` (old EditLog web app).** Its token `kiroku-demo-token` is public. If it is still deployed, anyone can write rows
  into the sheet. **Fix:** archive that deployment (Deploy > Manage deployments).
* **H7. Storage.** If 11 has not run, the `08` rules let **anon read every uploaded file** and upload into any task's folder.
  The 11 rules still let any officer upload to any task. **Fix:** upload only to tasks the user may edit. No file types are restricted yet.
* **H8. CEO is read-only only inside the functions.** That is correct today, because there are no direct write grants. Stage 2 adds
  explicit "no insert/update/delete" for `authenticated` on every table, so a future grant cannot reopen writes by accident.
* **H9. Officers can read every task and every activity row.** The current rules let any Kiroku user read everything. Your requirement
  says officers *update* only their own tasks; it does not say they may not *see* others'. **Decision needed** (see the end).

## Medium

* **M1.** `saveDB()` stores the **whole dataset** in `localStorage` (`kiroku_sample_db_v2`) and nothing clears it on sign-out.
  On a shared PC the next person can read it.
* **M2.** No `SIGNED_OUT` / `TOKEN_REFRESHED`-failure handling. When a session expires or is revoked, the page keeps showing
  data until a reload. There is no idle timeout.
* **M3.** Sign-out does not clear `kiroku_signin_email`, `kiroku_notif_*` or the cached data.
* **M4.** Two functions have no fixed `search_path`: `touch_updated_at` and `activity_logs_append_only`.
  `is_kiroku_user` and `is_kiroku_admin` are callable by anon. Both are harmless, but tidy them.
* **M5.** Password rules are only checked in the page (8 characters). Set the minimum length and leaked-password protection in Auth settings.
* **M6.** `index-centered.html` is a full second copy of the app. Every fix must go into both files, or that copy must be removed from the published site.

## What is already good (keep it)
* The service key is only in Apps Script Script Properties, never in the page or the repo.
* The publishable key in the page is expected and fine, once RLS is in force.
* All `SECURITY DEFINER` functions pin `search_path = public`.
* `sync_import`, `sync_entity` and `import_sheet_activity` are service-role only.
* `activity_logs` is append-only, even for the service key.
* The `11` versions of `log_task_activity` and `update_task_fields` check the right things: signed-in user, CEO blocked, own tasks only, Admin-only reassign.
* `update_task_fields` has optimistic locking.

---

## Plan: highest risk first, each stage checked before the next

| Stage | What | Breaks if done alone | Way back |
|---|---|---|---|
| 0 | You run `00_security_check.sql` and send me the result. You check: Auth sign-ups on/off; JWT expiry; the sharing of the 5 sheets; whether the `Code.gs` deployment is live | nothing | — |
| 1 | You confirm each of the 6 accounts can sign in at `…/index.html?login` (that path already uses real Supabase Auth) | nothing | — |
| 3 | **Page:** remove demo login, the no-login mode and the Sheet fallback; clear browser data on sign-out and expiry; fix XSS. Published to GitHub Pages | Nothing, because RLS is still open, so the page works as before | Re-publish the previous commit |
| 2 | **Database:** `13_security_hardening.sql` = the `11` lock-down plus C4, H1–H4, H7, H8, M4. One transaction; no data touched | The old page (if anyone has it cached) can read nothing. That is the point | `13_rollback.sql`, written with it, restores the current grants, policies and function bodies exactly (taken from your stage 0 output) |
| 4 | **Apps Script:** `readTab` allow-list, `JobOrders.gs` validation, archive `Code.gs`; you change the sheet sharing | Sheet fallback (already removed in 3) | Paste the previous `.gs` files back and re-share |
| 5 | **Testing:** for each of the 6 accounts, signed in with a real session, run a script of allowed and refused calls (read, edit own task, edit another officer's task, change own role, reassign, CEO write, anon read of every table, forged `p_user_id`) and record pass/fail | — | — |

The page goes before the database on purpose. If the database is locked while the live page still uses the shared key,
Kiroku stops working for everyone. Stage 3 and stage 2 should be done back to back, on the same day.

Nothing in this plan deletes a table, a function, a trigger or a row, or resets a password.

## Decisions I need from you
1. **Officer visibility (H9):** may a Doc Officer *see* other officers' tasks and activity (today: yes), or only their own?
2. **u1 managing Job Orders (H5):** keep it?
3. **Sheet fallback (C3):** OK to remove it? This is the only way to stop the sheets being public.
4. Is the GitHub repository public? (GitHub Pages on a free plan needs a public repo, so the old demo password and the sheet IDs are in its history.)

---

# Stage 2 — fixes written and tested (2026-11-09)

Nothing below is live yet. Every file is in this folder, not committed, not published, not run on Supabase.

## What changed

| File | Fixes |
|---|---|
| `supabase/13_security_hardening.sql` | Anon gets nothing. Read rules need a linked Kiroku user (`is_kiroku_user()`), not just any login. Signed-in users get SELECT only. `event_logs`/`sync_runs` are Admin-only. Write functions use only `auth.uid()`: CEO is refused, officers may change only their own tasks, open mode is off. `link_my_account` no longer links by email. `users.auth_user_id` cannot be changed through the API, not even by the sync key. Role must be Admin/CEO/Doc Officer. At least one Admin is always kept. ID-format checks. The sync takes allow-listed columns only, shared tabs come only from the Admin Masterlist, and an officer sheet can change only its own tasks' 4 fields. `event_logs` cannot be emptied. Storage: Kiroku users read; uploads only to tasks you may edit. New tables and functions start closed. |
| `supabase/13_rollback.sql` | Puts back exactly the state found on 2026-11-09 (tested). |
| `supabase/14_security_tests.sql` | 160 checks: anon, a stranger with a login, and each of the 6 users; reads, direct writes, function writes, impersonation, reassigning, role change, login takeover, log deletion, file upload. All writes are undone. |
| `index.html`, `index-centered.html` | Demo login, shared password, user picker, "Logged in as" switch and no-login mode removed. Sheet/CSV/sample fallback removed. The session lives in sessionStorage (ends when the tab closes). Idle sign-out after 30 min. Expired or revoked sessions sign out. Sign-out and every page load clear Kiroku data from the browser. New passwords must be 12+ characters. `escHTML` escapes quotes, and every sheet value is escaped. The public EditLog token is removed. |
| `apps-script/Sync.gs` | Allow-listed columns per tab; role and email checked; text starting with `= + - @` is written to the sheets as text (stops formula injection). |
| `apps-script/JobOrders.gs` | Every value from the page is checked (IDs, dates, tracks, categories; officer must be a Doc Officer); formula-safe writes; u1 must also be a Doc Officer. |
| `apps-script/Code.gs` | Retired: refuses every request. |

## Tested on a local copy of the database
`01 → 12` plus the live extras were rebuilt in a throwaway Postgres with mock Supabase auth/storage:

* 14 before 13: **33 FAIL**, exactly the holes found live
* after 13: **160/160 PASS**
* each blocked action fails with the right message: bad role, removing the last Admin, users from an officer sheet, changing `auth_user_id` through the API, emptying `event_logs`
* row counts unchanged
* 13 runs twice safely
* the rollback restores the original 33 FAIL
* 13 after the rollback: 160/160 again

**Not yet tested:** real sign-in in the browser (needs each person's own password), the real Supabase Storage, and the real Apps Script run.

## Rollout, in this order, on one day
1. **Dashboard, Authentication.** These changes don't affect the six accounts:
   * Sign In / Providers: turn **off** "Allow new users to sign up"
   * Passwords: minimum length **12**; turn on leaked-password protection if your plan has it
   * Sessions: keep the JWT expiry at 3600 s or less
2. **Publish the page:** commit and push `index.html` and `index-centered.html`.
3. **SQL Editor:** run `13_security_hardening.sql`, then `14_security_tests.sql`. Every row must say PASS.
   * If anything is wrong, run `13_rollback.sql`, and if needed re-publish the old page.
4. **Apps Script:** paste `Sync.gs`, `JobOrders.gs` and `Code.gs`, then run `syncAll` once and read the log.
   * Deploy > Manage deployments: **archive** the old `Code.gs` web app.
   * After editing `JobOrders.gs`, make a new version of its deployment.
5. **Each of the 6 people signs in** (Doc Officer 2 never has) and checks:
   * the right screens show
   * Mark Done / Log Note works on their own task
   * the CEO can't change anything
6. **Each person changes their password.** The current ones were shared in a chat screenshot and follow a guessable pattern.

## Things only you can check
* **Who can open the Apps Script project.** If it is bound to a sheet (Extensions > Apps Script), everyone with **edit** access to that sheet can open the script and read `SUPABASE_SERVICE_KEY` in Script Properties. That key bypasses every rule. Keep the script bound only to a sheet that only Admin edits, or move it to a standalone script. If anyone else ever had edit access, **rotate the secret key** (Project Settings > API Keys) and update Script Properties.
* **The login email domain.** The logins use `@kiroku.com`. If your company does not own `kiroku.com`, whoever does could receive password-reset emails and take over any account. Use your company's own domain (change each email in Authentication > Users).
* **The Users tab emails** (`…@kiroku.sample`) don't match the logins. Correct them in the Admin Masterlist so the Configuration page shows the right addresses. Logins are linked by ID, so nothing breaks meanwhile.
* **Sheet sharing:** all five sheets are already private. Keep "General access: Restricted".

## Adding a new person later
1. Admin creates the login (Authentication > Users > Add user) and adds the row to the Users tab.
2. After the next sync, Admin runs in the SQL Editor:
   `update public.users set auth_user_id = (select id from auth.users where email = '<their login email>') where user_id = '<uN>';`
   This works only from the dashboard, never through the API.

## Live result — 2026-11-09
* Sign-up off (`disable_signup = true`).
* New page published (`kiroku-v4-microapp` @ 6583f51).
* `13_security_hardening.sql` applied.
* `14_security_tests.sql` on the live project: **160/160 PASS**. Covered: anon, a stranger with a login, Admin, CEO, and Doc Officers 1–4.
* Outside check with the public key: all 9 tables, the write functions, and file upload are refused.
