# Kiroku backups

Supabase's Free plan makes **no** backups, and Supabase is the only copy of Kiroku's data. This folder makes one
every week on this PC: a full copy of the Kiroku database (every table and row, plus its security rules,
functions and triggers) in `C:\Kiruko\backups\kiroku-<date>.dump`. The newest 12 are kept (about 3 months).

The backups are **outside** this GitHub folder on purpose: they hold everyone's data and must never be published.

## Not in the backup
* **Logins** (Supabase → Authentication). Restoring into the same project keeps them. In a new project, people are
  added again and linked (see `supabase/SETUP.md`, "People and logins").
* **Uploaded task files** (Supabase → Storage → task-files). Their records are in the backup, the files are not.
  Download the bucket from Storage now and then if they matter.

## Set it up (once, 5 minutes)
You need the **database password**: Supabase → **Project Settings → Database**. If nobody knows it, click
**Reset database password** there. That does not affect the Kiroku website, which never uses it.

1. Open **PowerShell** on this PC (Start → type PowerShell).
2. Run:
   ```
   powershell -ExecutionPolicy Bypass -File C:\Kiruko\kiroku-v4-microapp\backup\setup-backup.ps1
   ```
3. It asks for three things. Find the first two in Supabase → **Connect** (top of the dashboard) →
   **Connection String** → Method **Session pooler**:
   `postgresql://`**`postgres.abcdefgh`**`:[YOUR-PASSWORD]@`**`aws-0-ap-southeast-1.pooler.supabase.com`**`:5432/postgres`
   * **Host**: the part after `@` and before `:5432`
   * **User**: the part after `postgresql://` and before the `:`
   * **Password**: the database password. It is not shown while you type, and it is never sent anywhere: it is saved
     in `%APPDATA%\postgresql\pgpass.conf`, which only your Windows account can open.
4. It makes the weekly job (**Task Scheduler → "Kiroku weekly backup"**, Mondays 10:00; if the PC is off then, it runs
   at the next start) and runs the first backup. It ends with **Done**.

Never paste the database password into a chat, an email or a file in this folder.

## Check it now and then
* `C:\Kiruko\backups\backup.log`: one line per run. **OK** with a size, or **FAILED** with the reason.
* Run a backup by hand: Task Scheduler → **Kiroku weekly backup** → **Run**.
* If the database password is changed, run the setup again.

## Restore
Ask Claude to help with a restore: it replaces live data, so do it calmly and with a fresh backup first.

**Look inside a backup** (changes nothing):
```
"C:\Program Files\PostgreSQL\17\bin\pg_restore.exe" --list C:\Kiruko\backups\kiroku-2026-11-17_1000.dump
```

**Get back one table's rows as a file** (changes nothing live), to copy back what is needed:
```
"C:\Program Files\PostgreSQL\17\bin\pg_restore.exe" --data-only --table=job_orders --file=job_orders.sql C:\Kiruko\backups\<file>.dump
```
This writes the rows as SQL to `job_orders.sql` to read or to run.

**Restore everything** (the whole Kiroku database back to the backup's moment, same Supabase project):
1. Take a backup of the current state first (Task Scheduler → Run).
2. Supabase → SQL Editor: `drop schema public cascade; create schema public;`
   This deletes all Kiroku data and rules until step 3 finishes.
3. In PowerShell:
   ```
   & "C:\Program Files\PostgreSQL\17\bin\pg_restore.exe" --host=<Host> --port=5432 --username=<User> --dbname=postgres --no-owner C:\Kiruko\backups\<file>.dump
   ```
   One message is expected and harmless: `schema "public" already exists`.
4. Supabase → SQL Editor: run `backup/after-restore.sql` (task-file rules, live activity updates, auto-RLS).
5. Run `supabase/14_security_tests.sql`: every row must say **PASS**. Then sign in to Kiroku and check.

Tested on a copy of the database (2026-11-11): every row came back, and the security tests passed on the restored copy.
