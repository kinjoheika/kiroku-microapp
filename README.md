## Things To Do
1. Integrate four Google Sheets into one centralized Supabase database.
2. Implement event logging and activity tracking from G-sheet to Supabase.
3. Manage follow-up records efficiently.(everytime that it press can still press it)
4. Enable messaging and log note functionality.
5. Support file uploads and management.
6. All tracks is under the Job Order (All Due Gates)
7. Apply circular pagination
8. Identify the source of the avatar initials
9. Setting Menu
10. Improve the user interface and overall design

Kiroku Launch

Workflow – 8/10
Audit trail – 8/10

Date is hardcoded – DONE
security on row-level security

browser that accesses the app server.

Reverse proxy (TLS, rate limit, LAN)
API (fast API) – auth RBAC, audit log
Postgre 15 – row level security + audit tables
file store
UPS, nightly PG dump (2nd disk), week – external drive, encrypted off-site

Technical controls:
    • Full-disk encryption on the server (BitLocker or LUKS) and on laptops that hold exports. 
    • Per-user accounts, strong password policy, and lockout after failed logins. Add MFA if you can (TOTP app, no SMS). 
    • Row-level security in Postgres, so the database enforces who sees what, not just the UI. 
    • Audit log on every write, kept append-only where possible. 
    • TLS everywhere, even on the LAN, with an internal certificate authority installed on each PC. 
    • Firewall blocking inbound from outside. Bind services to the LAN interface only. 
    • Least privilege: the app connects to the database with a restricted role, never as superuser. 
    • OS and dependency patching on a schedule, applied from USB if there’s no internet. 
    • Offboarding: disable accounts the same day someone leaves. 
Operational supports:
    • UPS sized for graceful shutdown (30+ minutes). 
    • Mirrored disks (RAID 1), with a tested restore procedure. An untested backup doesn’t count. 
    • Nightly database dump plus weekly encrypted copies off-site, verified monthly by restoring to a spare machine. 
    • Health checks and a simple alert (a light, a buzzer, or an email if you ever add a mail relay). 
    • A written runbook for “server down,” “disk full,” and “restore from backup.” 
    • A named person who answers when it breaks, plus a spare PC you can swap in.

What it doesn’t remove
    • Insiders. Staff who are angry, careless, or bribed. Someone who leaves with a USB stick. This is usually the biggest real risk for a small office. 
    • Stolen or unlocked PCs. A laptop left logged in, or a browser that saved a session. 
    • Phishing. A staff member gives their password to a fake login page or a fake “IT” call. Local hosting does nothing about this. 
    • Malware on any PC on the LAN. One infected machine can talk to the server like any other client, and can sniff traffic if TLS is not properly enforced. 
    • Your own code. Bugs like the ones in the current build (unescaped HTML, hard-coded secrets, client-side permission checks) can be exploited from inside the office. 
    • Physical access. Someone walking into the server room, or taking the backup drive. 
    • Lost or unpatched software. Postgres, the OS, and the web framework all get security fixes that you must install. 
    • Supply chain. Libraries you install (npm, pip, CDN scripts) can contain malicious code. 
    • Legal and human errors. Sending a file to the wrong person, or an export left on a shared drive. 
What’s realistic
The goal is to make attacks expensive, limited in damage, and detectable, not impossible. Ranked by value for a 5–20 person office:
    1. Remove the public exposure entirely. No public domain, no internet-facing port, no Sheets or public repo holding real data. Verify with an external scan. 
    2. Enforce rules at the database, not the page. Row-level security so each user only reads and writes what their role allows. Assume the browser can be tampered with. 
    3. Individual accounts, MFA where possible, and short sessions. Automatic logout after inactivity. Immediate disable when someone leaves. 
    4. Least privilege everywhere. The app’s database user can’t drop tables or read other databases. Staff get only the access their job needs. 
    5. Full audit trail, append-only. Every change records who, what, when, from which PC. Review it weekly. This is what catches insiders. 
    6. Encryption at rest and in transit. Disk encryption on the server and laptops; TLS on the LAN with an internal certificate. 
    7. Patch on a schedule. OS, database, and dependencies. Pin versions so updates are deliberate. 
    8. Backups that you have tested restoring. Ransomware and accidental deletion are often bigger threats than hackers. 
    9. Staff training on phishing and password hygiene. Short, specific, and repeated. 
    10. A response plan. Who to call, how to isolate a PC, how to rotate passwords, and when to notify the Philippine National Privacy Commission (72-hour breach notification under the Data Privacy Act). 
    11. Periodic independent review. A penetration test by a third party once before go-live and yearly after. This is the closest you can get to evidence of security.


What to tell your clients
Don’t promise “unhackable” or “100% secure.” Promise a documented set of controls, regular testing, 

1. Remove public exposure entirely
How to do it
    • Don’t assign a public domain or open any inbound port on the router or firewall. 
    • Bind the database and app to the LAN address only, not 0.0.0.0 on a public interface. 
    • Move real data out of the public GitHub repo. Make the repo private, and delete any sample files that contain real names. 
    • Remove the Google Sheets sync and the Apps Script web app from the production path. 
How to check it yourself
    • From a phone on mobile data (not the office Wi-Fi), try to reach the server’s public IP on ports 80, 443, 5432 (Postgres), and 8000. Every one should time out or be refused. 
    • Run an external scan with nmap from outside your network, or use an online port checker against your public IP. Expect “filtered” or “closed” everywhere. 
    • On the server, run ss -tlnp (Linux) or netstat -ano (Windows) and confirm each service listens on a LAN address, not 0.0.0.0. 
    • Open the GitHub repo in a private browser window while logged out. It should show “Page not found.” 
Passing: no port answers from outside; the repo is private; no real data in any file.

2. Enforce rules at the database, not the page
How to do it
    • Turn on row-level security (RLS) for every table holding job orders, tasks, workers, and logs. 
    • Write policies such as: an officer can update only tasks where editor_id equals their own user ID; the CEO can read but not write; only Admin reads the event logs. 
    • Revoke direct table access from the anon role. Let the app call only specific functions that check the caller’s identity. 
    • Move all permission checks out of JavaScript and into these policies or server-side functions. 
How to check it yourself
    • Sign in as Doc Officer 1 in the browser, open the developer console, and run a direct update against a task that belongs to Doc Officer 2. The database should refuse it, not the page. 
    • In Supabase (or Postgres), run SELECT tablename, rowsecurity FROM pg_tables WHERE schemaname='public';. Every sensitive table should show true. 
    • Check the policy list: SELECT * FROM pg_policies;. Each sensitive table needs an explicit policy. No USING (true) on sensitive tables. 
    • Check for security definer functions: SELECT proname FROM pg_proc WHERE prosecdef;. Each one should validate its caller. 
Passing: cross-user edits fail even when called directly against the API.

3. Individual accounts, MFA, short sessions
How to do it
    • One account per person; no shared logins. Remove the mock shared password entirely. 
    • Enable MFA (TOTP app such as Google Authenticator or Authy). Most auth systems, including self-hosted Supabase GoTrue, support it. 
    • Set session expiry: access tokens short (e.g., 1 hour), with auto logout after 15 to 30 minutes of inactivity in the page. 
    • On offboarding, disable the account the same day and revoke active sessions. 
How to check it yourself
    • Try signing in with a deliberately wrong password 5 times; you should be locked out or rate-limited. 
    • Sign in on one PC, then check whether an old session token still works after you disable the account. It shouldn’t. 
    • Leave a logged-in tab idle for longer than the limit; it should log out. 
    • Review the user list: every name maps to one person, and no account is still active for someone who left. 
Passing: no shared accounts, lockout works, idle timeout works, disabled accounts stop working immediately.

4. Least privilege everywhere
How to do it
    • Create a dedicated database role for the app with only SELECT, INSERT, UPDATE on the tables it needs. No DROP, ALTER, or SUPERUSER. 
    • Run the server OS services under non-admin accounts. 
    • Give staff the minimum role: Doc Officer, CEO (read only), Admin. Don’t make everyone Admin. 
How to check it yourself
    • Run \du in psql. The app role should not show Superuser, Create role, or Create DB. 
    • Connect as the app role and try DROP TABLE job_orders;. It should fail with “permission denied.” 
    • Check the Windows or Linux service account for the app; it should not be in the Administrators or root group. 
    • Review the Users tab against actual job duties once a quarter. 
Passing: the app cannot change its own schema, and no staff member has more access than their job needs.

5. Full audit trail, append-only
How to do it
    • Keep the activity_logs table, but make it insert-only: revoke UPDATE and DELETE from every role, including the app. 
    • Record who (user ID), what (action), when (server timestamp, not the browser’s clock), and from where (client IP or PC name if you can capture it). 
    • Store a copy of the log outside the database, e.g., a nightly export to the backup drive. 
How to check it yourself
    • Try to edit or delete a row in activity_logs as the app role. It should fail. 
    • Make a change in the app, then find the matching log row. Check that the timestamp matches the server time, not the PC clock. 
    • Once a week, skim the log for unusual patterns: late-night edits, bulk changes, a user changing many records in seconds. 
    • Confirm the nightly export file exists and grows over time. 
Passing: logs can’t be altered by the app, and every change has a matching record.

6. Encryption at rest and in transit
How to do it
    • Disk encryption: BitLocker (Windows Pro) or LUKS (Linux) on the server and on any laptop that holds exports. 
    • TLS on the LAN: create an internal certificate authority (e.g., with step-ca or Caddy’s built-in CA), install its root certificate on each PC, and serve the app over HTTPS only. 
    • Turn on ssl = on in Postgres if the app connects over the network, even on the LAN. 
How to check it yourself
    • Windows: manage-bde -status shows encryption on the drive. Linux: lsblk -f shows crypto_LUKS. 
    • Open the app with http:// instead of https://. It should redirect or refuse. 
    • In the browser, click the padlock; the certificate should show your internal CA, not “not secure.” 
    • Run SHOW ssl; in psql. It should return on. 
Passing: disks report encrypted, HTTP is refused, and certificates are valid.

7. Patch on a schedule
How to do it
    • Subscribe to security notices for the OS, Postgres, the web framework, and any library you use. 
    • Pin dependency versions in a lock file. Update deliberately, not automatically. 
    • Apply OS patches monthly, with a test on a copy first if possible. 
    • Keep a simple log: date, what was updated, who did it, and whether anything broke. 
How to check it yourself
    • Windows: Settings > Windows Update shows the last check date. Linux: apt list --upgradable or dnf check-update shows pending updates. 
    • Postgres: SELECT version(); and compare with the current supported minor version on postgresql.org. 
    • For Node or Python dependencies: npm audit or pip-audit lists known vulnerabilities in your installed libraries. 
    • Check your patch log: no gaps longer than your agreed schedule. 
Passing: no known high-severity vulnerabilities in the audit output, and the log shows regular updates.

8. Backups you have tested restoring
How to do it
    • Nightly pg_dump of the database, plus file store copies, saved to a second disk. 
    • Weekly copy to an external drive, encrypted, kept off-site or in a different room. 
    • Write a restore runbook: the exact commands and the order of steps. 
How to check it yourself
    • Monthly: restore the latest backup onto a spare machine or a separate database name, then open the app against it and check a few known records. 
    • Check backup file sizes: a sudden drop to near zero means the backup failed. 
    • Check that the off-site copy is actually readable (decrypt one file). 
    • Time the restore. Note the result in your runbook; that’s your real recovery time. 
Passing: a restore completes, the data matches, and you know how long it takes.

9. Staff training on phishing and password hygiene
How to do it
    • Short session (30 minutes) with real examples: fake “password expired” emails, fake calls claiming to be IT. 
    • Rules to teach: never share passwords, use a password manager, verify any request for credentials by phoning a known number, report anything odd. 
    • Repeat every 6 months and after any incident. 
How to check it yourself
    • Send a simulated phishing email (free tools such as GoPhish, or a controlled test from a known address). Track who clicks or enters credentials. 
    • Ask each staff member to explain, in their own words, what they’d do if asked for their password. Note the answers. 
    • Check whether passwords are reused: ask staff to confirm they use a unique password for the app. 
    • Review reports: did anyone report the test email? 
Passing: staff report suspicious messages, and click rates fall between tests.

10. Response plan
How to do it
    • Write a one-page plan: who to call first, how to isolate a PC (disconnect from LAN), how to disable accounts, and how to rotate the database password. 
    • List the authority to notify: the National Privacy Commission, with the 72-hour breach window under the Data Privacy Act. 
    • Keep a breach log template for even minor incidents. 
    • Store the plan printed and on the server, not only on the system that might be compromised. 
How to check it yourself
    • Run a tabletop exercise: “A PC is infected and a staff password was phished.” Walk through the plan and time each step. 
    • Check the printed copy is current and the phone numbers work. 
    • Confirm the breach log template exists and that someone knows where it is. 
Passing: the exercise finishes, every step has a named owner, and the time to isolate and disable accounts is measured in minutes.

11. Independent review
How to do it
    • Before go-live, hire an independent security tester (local firms offer web and network penetration tests; expect a cost in the tens of thousands of pesos or more, depending on scope). Ask for a written report with severity ratings. 
    • Fix findings, then retest the critical and high ones. 
    • Repeat yearly, and after major changes. 
How to check it yourself (before the paid test)
    • Run OWASP ZAP (free) against a test copy of the app to find common web issues like missing headers, unescaped input, and weak cookies. 
    • Run Supabase/Postgres advisors if you use Supabase: the dashboard shows security warnings for missing RLS and exposed functions. 
    • Use pip-audit, npm audit, and the dependency checks from point 7. 
Passing: ZAP and the advisors report no high-severity findings, and the paid test (once done) has no open critical items.

A simple tracker
#	Control	Owner	Frequency	Last checked	Result
1	No public exposure		Monthly		
2	Database rules (RLS)		Monthly		
3	Accounts, MFA, timeouts		Monthly		
4	Least privilege		Quarterly		
5	Audit trail		Weekly		
6	Encryption		Yearly		
7	Patching		Monthly		
8	Backup restore test		Monthly		
9	Staff training		6-monthly		
10	Response plan drill		Yearly		
11	Independent review		Yearly		
Fill in the owner column with a named person for each row. A control without an owner tends to lapse.
Two honest limits. First, the checks above find many problems but not all of them; a clean result lowers risk, it doesn’t prove absence. Second, for points 2 and 11 in particular, the current Kiroku code has known gaps (client-side permissions and the mock password), so the first run of these checks will almost certainly fail until those are fixed.



Here are the four strengths I rated earlier (workflow fit, audit trail, coordination features, interface), each raised to 9.5/10. I’ll describe what the 9.5 version looks like on screen and why each change matters. These are design suggestions for the current build, not reviewed code changes.

1. Workflow fit: 8 → 9.5
What it looks like
    • Each job order opens to a single “Next action” banner at the top: “Fernando Jusay · COE · Ticket done — due in 3 days.” One button, one action. 
    • The three tracks (TIO, OTIT, COE) show as a horizontal progress path, with the current step highlighted and blocked steps greyed out with the reason (“waiting for DHL Received”). 
    • Each officer’s home screen shows only their tasks, sorted by deadline, with overdue items pinned to the top. 
    • Dependencies are visible: a step that needs a previous step shows a small chain icon, and the app explains the chain on hover or tap. 
    • A “hand off” action lets an officer send a job order to another officer with a note, and the receiver sees it in their queue immediately. 
Why
    • Staff work from a list of what to do next, not a grid of everything. That’s the core gap between this and a spreadsheet. 
    • Showing dependencies prevents the most common error in document processing: marking a later step done before an earlier one. 
    • Hand-offs replace the phone calls and chat messages that currently fill the gap between officers. 

2. Audit trail: 8 → 9.5
What it looks like
    • Every row in the task view has a small “History” link. Clicking it shows a timeline: who, what changed, old value → new value, time in Philippine time, and which PC. 
    • Event Logs gain a filter for “changed by” and “date range,” plus an export button that produces a dated, signed CSV. 
    • A “Verify” action on the Configuration screen recomputes a hash chain across the log and confirms no row was altered or removed. 
    • Logs show whether an entry came from the app, from an import, or from an admin correction, each labelled differently. 
    • A clear banner appears if the sync to Google Sheets or Supabase fails, with the time of the last successful sync. 
Why
    • An audit trail only helps if people can read it without a database expert. The timeline view makes it usable in a dispute. 
    • A hash chain makes tampering detectable, which is what an auditor or the Data Privacy Commission will ask about. 
    • Labelling the source of each change separates a staff edit from an import or a correction, which is the first question in any investigation. 

3. Coordination features: 7 → 9.5
What it looks like
    • Notes and messages live on the task, but a thread view groups them by job order so the whole conversation is visible in one place. 
    • @mentions notify the named officer and appear in their bell list with a direct link. 
    • Attachments show a preview thumbnail for PDFs and images, with the file name and uploader underneath. 
    • A “Waiting on” field on each task names who must act next. A small badge appears on that person’s home screen. 
    • Presence hints show which officers are currently viewing the same job order, so two people don’t edit the same record at once. 
Why
    • Coordination breaks down when the conversation about a worker is scattered across messages, notes, and files. One thread per job order keeps context together. 
    • “Waiting on” turns an implicit expectation into a visible task for a named person, which reduces the chase-up messages. 
    • Presence prevents overwrites and gives a live sense of who is working on what, which the current build can only approximate with its version check. 

4. Interface: 7 → 9.5
What it looks like
    • Font size is user-adjustable, with 16 px as the default and a “large” mode at 20 px. Contrast meets WCAG AA at minimum, with the status colours also shown as text and icon, not colour alone. 
    • Every control has a visible label. No icon-only buttons without a tooltip and a text alternative. 
    • Forms use dropdowns and date pickers wherever a value is fixed, with plain-language labels (“Target deployment date”, not “tgt_dep_dt”). 
    • A consistent layout across screens: the same top bar, the same position for search, the same colour meaning everywhere. 
    • Keyboard navigation works end to end: Tab through rows, Enter to open, Esc to close. Every clickable item is a real button or link, not a styled div. 
    • A first-run tour with three examples, dismissible and re-openable from the help menu. 
    • Clear empty states and error messages that say what to do next, in plain words. 
Why
    • Older staff and staff using a second language need larger text, clear labels, and fewer hidden controls. This is the same concern raised in the earlier voice and typed-entry discussion. 
    • Real buttons and keyboard support are the basis for both accessibility and reliability: they work with screen readers, and they behave predictably. 
    • Consistency reduces the number of things a new user must learn, which is the main cost of any new tool. 

What gets you from current to 9.5
The current build already has most of the features behind these changes. The gap is mostly presentation and two data-model additions:
    • A “next action” and “waiting on” field on each task. 
    • A per-job-order thread and a hash field on the log. 
The biggest single risk to hitting 9.5 is the security and date issues from the earlier review. A clean-looking interface that shows wrong overdue dates would drop the audit and workflow scores back down, so fix those first.
The fresh review is back. It read the whole repo cold, with no sight of my conclusions. It confirmed my main findings and found several things I missed.
Where it agreed with me
Independently reached the same two critical conclusions: the database is in the pre-lockdown state (USING (true) on four tables, two RPCs granted to anon that trust client-supplied identity), and the frozen TODAY breaks all deadline logic. Same read on the service key being correctly absent, the committed CSVs being fictional, and 11_lock_down.sql being a competent fix that simply hasn’t been switched on.
It also sharpened one point. I said login isn’t enforced. The precise version is worse:
js
localStorage.setItem('kiroku_mock_user','u6')  // reload → you are Admin
That’s the whole escalation. No server involvement, Configuration tab included.
What I missed
Gate order is never enforced — anywhere. TASKS_CONFIG defines order (index.html:899-924) and the UI highlights a “current” gate, but no JavaScript and no SQL prevents completing gate 7 with gates 1-6 still open. A job order can read “complete” with mandatory documents never processed. For a product named Completeness Gate, that’s a compliance-integrity failure, not a cosmetic one. This is arguably the most important business finding in the review and I had no inkling of it.
escHTML doesn’t escape quotes (index.html:1657 — it handles &, <, > only). So the seven unescaped title="${...}" sinks aren’t just content injection, they’re attribute breakout. A company named " onmouseover="... injects an event handler. My XSS finding was right but understated.
Worker data persists in every browser forever. saveDB() writes the entire database to localStorage, and signOut() clears only the mock user key. On a shared agency workstation, every machine keeps a full copy of worker names and deployment dates after sign-out.
activity_logs stays readable by every user even after lockdown (11_lock_down.sql:31-33, deliberate — the Notes/Messages tabs are built from it). Any Doc Officer can read every colleague’s notes and messages on every worker via a direct API call. The UI filters this; the database doesn’t.
Mark Done has no concurrency check at all. update_task_fields checks the version only when the client sends one, and the client can send null. The Mark Done path skips the check entirely, so it always clobbers.
“All Due Gates is read-only” is cosmetic. The same task is writable from the My Due Gates screen; the server has no concept of a page.
Uploaded documents can never be deleted, by design. Good for audit, but passports and visas held permanently with no erasure path conflicts with the Data Privacy Act’s storage-limitation and erasure requirements.
supabase-js is loaded from a CDN with no integrity hash (index.html:861). Version is pinned, which is good, but a CDN compromise would execute in a page handling personal data.
Keyboard navigation is worse than I said. The nav tabs are <span onclick> with no tabindex or role. You cannot change screens with a keyboard at all.
Its ratings
	Score
Workflow fit	8
Audit trail	7
Coordination	7
Interface	7
Security	2
Maintainability	4
Accessibility	4
Demo use: 7.5/10. Production with real worker data: 2/10, do not deploy as committed.
It gave security 2 rather than 0 specifically because the remediation is already written and the service key was handled correctly. Its summary line is worth quoting back to you: the security model exists in the repo but is switched off, and nothing in the system detects that. For 20-30 client installs, that’s the structural problem — every client who doesn’t complete step 5 of SETUP.md ships wide open.
One thing relevant to your LAN plan
Moving to a local server removes the exposure behind the anon reads and the public Sheets. It does nothing about the localStorage identity, the frozen date, the XSS, the gate-order gap, or the browser data retention. Those are in-app flaws that a private network doesn’t touch.
The adversarial review is still running. That one is tasked with attacking my earlier conclusions specifically, so it may push back on some of what’s above.
The adversarial review is back, and it did its job. Here’s where it cut me down, followed by what it found that nobody else did.
Where it says I was wrong
My worst error: “the key lets anyone read/write everything.” The write half is flatly wrong. Direct table writes are comprehensively locked — 01_schema.sql:111-130 creates only for select policies, and 04:43, 06:126, 03:127-129, 09:166 explicitly revoke DML from anon. sheet_sync_state has RLS on with no policy at all, which is deny-all. Its verdict: I simultaneously overstated a risk I couldn’t check and missed the one that was actually there, so an owner acting on my original review would have hardened tables that were already locked and left the open RPC untouched. That’s fair.
My XSS citations were partly wrong in a way that matters. joNametagHTML does escape task names (index.html:1135), and buildJOProfile escapes them in both places. There are 69 escHTML call sites. Doc Officer free text is handled. The actual gap is reference-data names — kumiai, company, user — plus JO numbers, which arrive from the Admin Masterlist. Telling you “task names are unescaped” would have sent you to harden the wrong input.
Three findings were padding. The kiroku-demo-token is dead (LOG_URL='') and Code.gs is scheduled for deletion. The shared password is irrelevant when LOGIN_REQUIRED=false means there’s no auth at all — the real finding was the first clause, not the password. And I counted the CEO page twice, as a problem and as dead code, when it’s only the latter.
My maintainability score was generous, not harsh. I said ~1,500 lines of JS. It’s ~2,525, plus 800 of CSS. It dropped me from 4/10 to 3/10.
The finding nobody else got
sync_entity writes whatever columns appear in your sheet headers — including auth_user_id.
03_sync.sql:46-47 builds the column list from jsonb_object_keys of the payload, and Sync.gs:1199-1200 copies every non-empty sheet header into that payload with no allowlist. So anyone who can add a column named auth_user_id to the Users tab controls the only link between a Supabase login and a Kiroku identity (01_schema.sql:14) — the exact column is_kiroku_admin() tests.
This survives 11_lock_down.sql completely. That migration says so itself at line 12: the sync uses the service_role key, which is not affected. It’s the one privilege-escalation path the final hardening step doesn’t close. syncTasks already does this correctly via a TASK_FIELDS allowlist (Sync.gs:138); the shared-tab path just lacks the equivalent.
Other new findings
A second forgery path. apply_task_status_from_log (10:27-42) is a security-definer trigger that turns any activity_logs insert with action_type='Mark Done' into a tasks write. Since log_task_activity is granted to anon and takes action_type straight from the client, you don’t need update_task_fields at all to forge a completed gate.
02_seed.sql has no Admin user. data/Users.csv defines six users including u6,Admin, but the generated seed contains only five — u6 is absent. A fresh install from the committed seed has no Admin account, which breaks canManageJOs() and ADMIN_USER_ID in Sync.gs:32.
SETUP.md documents a table that doesn’t exist (edit_log, line 7), tells you to verify it in the Table Editor (line 37), and migration 05 is missing from the sequence with no note.
Stale Apps Script deployments may still be live. SETUP.md:217 warns that an old deployment keeps serving its old code. Any deployment from the Code.gs era still accepts writes with the published token. Thirty-second fix: Deploy → Manage deployments → archive everything but the current one.
kiroku_open_mode() has no search_path — the one function that decides whether identity is trusted from the client. Nine of eleven functions pin it; this isn’t one.
It also challenged my LAN advice
Two things I told you earlier need correcting:
“Drop the Google Sheets sync” is a rewrite, not a deletion. The sheets aren’t a peripheral convenience — they’re the primary data-entry surface, and the source of truth for Users, Kumiai, Companies and Job Orders. index.html has no UI at all for the first three. My framing was right on security and misleading on scope.
LAN does not fix the update_task_fields hole. Any device on the LAN can still call the RPC with a spoofed p_user_id. And it makes the localStorage leak worse, because shared terminals are the norm. A private network is not a substitute for items 1-3 below.
Commercially: index.html:874-882 hardcodes this client’s sheet IDs and Supabase project. There’s no tenancy boundary, so each sale is a fork. That’s a scaling constraint on your 20-30-client plan.
Corrected ratings
	Mine (original)	Adversarial
Workflow fit	8	8
Audit trail	8	7
Coordination	7	7
Interface	7	6
Security	—	3 pre-lockdown, 7 post
Maintainability	4	3
Accessibility	4	3
Production verdict: 2/10, same as the fresh review, and for a reason both reached independently — the vulnerabilities are the documented install path, not accidents. SETUP.md:71 and 11_lock_down.sql:2-3 jointly guarantee a window where real worker data is live, world-readable, and anon-writable.
Worth saying, since both agents did: the author clearly thought hard about security. Append-only triggers that defeat even service_role, idempotency via client_ref, optimistic concurrency, server-side timestamps, format('%I') for identifiers, honest comments admitting where the demo is insecure. The problems are concentrated in the transition states between migrations, which is exactly where a frontend-only review can’t look.
Consolidated priority list
All three passes agree on the order:
    1. Revoke update_task_fields from anon today, and delete the p_user_id fallback rather than flag-gating it. A function that takes “who I am” as a parameter isn’t fixable by a feature flag. Do this even for the demo — the key and project URL are in a public repo right now. 
    2. Run 11_lock_down.sql before real data lands, with LOGIN_REQUIRED=true in the same change. Verify with the curl I gave you. 
    3. Allowlist columns in sync_entity, explicitly denying auth_user_id. This is the only item lockdown doesn’t fix. 
    4. Fix TODAY (index.html:863), and the nowStamp() hybrid that pairs a frozen date with the live clock. 
    5. escHTML every text sink, escAttr every attribute sink. Note escHTML doesn’t escape quotes, so attribute sinks need escAttr specifically. 
    6. Clear STORAGE_KEY on sign-out — one line, and the likeliest real-world leak on shared terminals. 
    7. Enforce gate order server-side (fresh review’s H3; the adversarial pass didn’t raise it, so treat it as one-of-two rather than confirmed). 
    8. Regenerate the seed with u6, archive stale Apps Script deployments, delete Code.gs. 
Items 1-3 are a few hours of SQL. None of this requires rearchitecting.
Both agents flagged the same unverifiable items: whether 11_lock_down.sql has been run, whether kiroku_open_mode() currently returns true, and whether the five Sheets are link-shared. Those three facts decide how urgent items 1-3 actually are, and only you can check them.


# links for the main pieces:
Kiroku V4 code (branch): https://github.com/kinjoheika/kiroku-v3-microapp/tree/kiroku-v4-microapp

Kiroku Sync script (Apps Script): https://script.google.com/home/projects/1rn_tEbYq-Waq3Fs69Nui-zu6_3pNj41kWgmQIqwPqgI1j4JvZskRjDmt/edit

Doc Officer 1 sheet: https://docs.google.com/spreadsheets/d/14W4LtspvWhmp6dIwtkoWicLy98MO7nmaT5e_nRpXbgs/edit

Doc Officer 2 sheet: https://docs.google.com/spreadsheets/d/1mBsENuWFOYi45mILo7Za_5HIqFvwNzsR9eidq7gsAno/edit

Doc Officer 3 sheet: https://docs.google.com/spreadsheets/d/12k81jEyzBj1osoxxQ9XfSe2PZoDQr-b5qPU2sNeyX7M/edit

Doc Officer 4 sheet: https://docs.google.com/spreadsheets/d/1edyDABJKPno_hHU73POsNI6T5cjD4PBtCZ6xUkZonTE/edit

# Kiroku — Google Sheet connected demo

The Kiroku working-DB UI (`index.html`) loading its data from a Google Sheet
instead of the browser's built-in seed. Sample data is fictional.

Gsheet masterlist https://docs.google.com/spreadsheets/d/1OcjPALavuFbnMdhoTTRtqppKyK94CIDCWord2Gqi6OA/edit?gid=1926177793#gid=1926177793

## Files

- `index.html` — Kiroku UI. Data loader at the top of the script (`SHEET_ID`, `SHEET_TABS`).
- `Kiroku_Sample_Sheet.xlsx` — the sample sheet, six tabs: `Users`, `Kumiai`, `Companies`, `JobOrders`, `Tasks`, `Activity`.
- `data/*.csv` — the same six tabs as CSV. Used when no Sheet ID is set.

## Run it locally

The page fetches CSV files, so it must be served over HTTP (not opened as a file):

```bash
python -m http.server 8765
```

Then open http://localhost:8765/.

## Connect a Google Sheet

1. In Google Drive: File > Import > upload `Kiroku_Sample_Sheet.xlsx` > "Google Sheets".
2. Share > General access > "Anyone with the link" > Viewer.
3. Copy the ID from the URL: `docs.google.com/spreadsheets/d/<ID>/edit`.
4. Either paste it into `SHEET_ID` in `index.html`, or open
   http://localhost:8765/?sheet=<ID>.
5. The header shows `source: Google Sheet …` when it loads from the Sheet.

Sheet tab names must match exactly (case-sensitive).

## Limits

- Read-only sync. Changes made in the UI (mark done, activity) stay in the
  browser and are not written back to the Sheet. Write-back needs an Apps Script
  web app or Supabase (see the plan).
- Permissions still come from `TASKS_CONFIG` in the script, not the `editor_id`
  column. The column is informational for now.
- The Sheet fetch uses Google's public gviz CSV endpoint. Not yet tested against
  a live Sheet from this environment; if it fails, the page falls back to the
  built-in seed and shows the reason in the header.

## Log UI edits to the Sheet (EditLog tab)

Every change made in the UI (mark done, activity logged, JO created / edited /
archived / deleted, and so on) is appended as a row to an `EditLog` tab.

1. In the Sheet: Extensions > Apps Script. Replace the code with `apps-script/Code.gs`.
2. Deploy > New deployment > Web app. Execute as: **Me**. Who has access: **Anyone**. Deploy and authorize.
3. Copy the Web app URL into `LOG_URL` in `index.html`.
4. Keep `LOG_TOKEN` in `index.html` equal to `TOKEN` in `Code.gs`.
5. Reload the page. The header shows `logging off` until `LOG_URL` is set, then `✓ logged N to Sheet` after each change.

Columns: `logged_at, user, entity, entity_id, field, old_value, new_value, source`.

Security: the token sits in the page source, so this is demo-grade. Anyone who
can read the page can write to the log. Use a proper backend before real data goes in.

## Field masterlist (config page)

`config.html` is the masterlist of every field the worksheets must carry, grouped
by tab and owning department. Each tab has a **Copy header row** button (paste into
the worksheet) and **Export header CSV**. Lookups and reference values are on the
Reference page.

Open: http://localhost:8765/config.html

