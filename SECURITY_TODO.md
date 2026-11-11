# Kiroku — what is left to fix

Updated 2026-11-09. Work top to bottom. The first three are **urgent**: each one alone is a way into Kiroku.

**Plan change 2026-11-11: no Google Sheets.** Follow `supabase/SETUP.md`, "No Google Sheets: Kiroku only". It
**deletes** the secret key instead of replacing it (item 1), and makes items 4 and 6 (Apps Script) unnecessary.

**Already done and verified on live:**
* database locked (160/160 tests passed)
* sign-up off
* demo login removed
* automatic sign-out
* browser cleanup
* XSS fixes
* Change password button

---

## 🔴 1. Replace the Supabase master key (urgent, 5 min) — *you*
**Why:** most of the key was visible in a screenshot. It bypasses every security rule.
Do the steps **in this order**, so the sync never stops:

- [ ] Supabase → **Project Settings → API Keys → Secret keys → Add new secret key** (name: `apps-script-2026-11`). Copy it. **Do not screenshot it.**
- [ ] Apps Script → **Project Settings → Script Properties → Edit** → replace `SUPABASE_SERVICE_KEY` with the new key → **Save**.
- [ ] Apps Script editor → choose **`previewTaskSync`** → **Run**. The log should show task counts and no error.
- [ ] Supabase → **API Keys** → on the **old** secret key: **⋮ → Delete / Revoke**.
- [ ] If **Legacy API Keys** (`anon` / `service_role`, starting with `eyJ`) are shown, click **Disable legacy API keys**. Kiroku doesn't use them.
- [ ] Tell Claude, who checks from outside that the site still works.

## 🔴 2. Move the 6 logins off `@kiroku.com` (urgent, 10 min) — *you*
**Why:** `kiroku.com` belongs to someone else and receives email. "Forgot password?" sends reset links to **their** mail server, so they could take over any account, Admin included.

- [ ] Collect a **real** email for each person: company email, or personal Gmail if there is none.
  | Person | Kiroku ID | New login email |
  |---|---|---|
  | Admin | u6 | |
  | CEO | u5 | |
  | Doc Officer 1 | u1 | |
  | Doc Officer 2 | u2 | |
  | Doc Officer 3 | u3 | |
  | Doc Officer 4 | u4 | |
- [ ] Supabase → **Authentication → Users** → click each user → change **Email** → save. Passwords and the link to Kiroku stay the same.
- [ ] Admin Masterlist → **Users** tab → put the same emails in the **Email** column. That's what Kiroku's Configuration page shows.
- [ ] Each person signs in once with the new email to confirm it works.

## 🔴 3. Everyone changes their password (urgent, 2 min each) — *each person*
**Why:** the current passwords were shared in a screenshot and follow a guessable pattern.

Send this to the team:
> Please change your Kiroku password today.
> 1. Open https://kinjoheika.github.io/kiroku-microapp/ and sign in.
> 2. Click **Change password** (top right, next to Sign out).
> 3. Enter your current password, then a new one of **at least 12 characters**, twice.
> 4. Don't reuse a password from another site.

- [ ] Admin  - [ ] CEO  - [ ] Doc Officer 1  - [ ] Doc Officer 2 (has **never signed in**)  - [ ] Doc Officer 3  - [ ] Doc Officer 4

## 🟠 4. Check who can open the Apps Script (2 min) — *you*
**Why:** everyone who can **edit** the project can read the master key.

- [ ] Admin Masterlist → **Share**. Only you and Admin should be **Editor**. Viewers and Commenters are fine. General access: **Restricted**.
- [ ] **Extensions → Apps Script**: is `Sync.gs` here? If not, find the project at script.google.com and check its **Share** list instead.
- [ ] Each Doc Officer sheet → **Extensions → Apps Script**: it should contain **no** `Sync.gs` and no key.
- [ ] If anyone besides Admin was an Editor: remove them (step 1 already replaced the key).

## 🟠 5. Supabase sign-in settings (3 min) — *you*
- [ ] **Authentication → Sign In / Providers → Passwords:** minimum length **12**; turn on **leaked password protection** if shown.
- [ ] **Authentication → Sessions:** JWT expiry **3600 seconds** or less.
- [ ] Confirm **"Allow new users to sign up"** is still **OFF**.

## 🟡 6. Update the Apps Script sync code (10 min) — *you, or Claude once you're signed in to Google in the app's browser*
**Why:** stops formula injection into the sheets, checks roles and emails on the Users tab, and checks Job Order input.

- [ ] Back up the current `Sync.gs` and `JobOrders.gs` (copy each into a Notepad file).
- [ ] Paste `C:\Kiruko\kiroku-v4-microapp\apps-script\Sync.gs` and `…\JobOrders.gs` over them → **Save**.
- [ ] Run **`previewTaskSync`** and read the log.
- [ ] Run **`syncAll`**. No red errors.
- [ ] **Executions** page: the next 2–3 `scheduledSync` runs say **Completed**.
- [ ] Old logger project (`Code.gs`, EditLog): paste the retired version, then **Deploy → Manage deployments → Archive**. Skip if it doesn't exist.

## 🟡 7. MFA — authenticator app codes — *Claude builds it, you decide*
- [ ] **Decide:** required for **everyone** (recommended) or only Admin and CEO?
- [ ] Claude builds:
  * the QR set-up screen
  * the 6-digit code step at sign-in
  * a database rule so data is only given after the code is entered
- [ ] Each person installs Google or Microsoft Authenticator and scans their QR once.
- [ ] Admin keeps a backup (a second device) for their own authenticator.

## 🟡 8. Backups and recovery — *you and Claude*
- [ ] Tell Claude your Supabase plan: **Free** (no automatic backups) or **Pro** (daily backups).
- [ ] Claude writes an export script (all tables to dated files) and a restore guide.
- [ ] Do one test restore into a spare project, and note the date here.

---

## Phase 2 — reliability (after security)
- [ ] **Overdue dates:** the page now uses today's Philippine date. Claude reviews every overdue calculation.
- [ ] **Gate order — decide:** must earlier gates be **Completed** before a later one can be marked done? Can Admin override? Claude then enforces it in the database.
- [ ] **Audit logs:** after a normal day of use, check the activity and event logs show who did what. Claude can write the check query.
- [ ] **Backup restore test:** see 8.

## Rules from now on
* Never screenshot or paste a **password** or **key**. Cover the value first.
* When someone leaves: remove their login (Authentication → Users), their row's access, and their sheet sharing on the same day.
* After any database change, run `supabase/14_security_tests.sql`. Every row must say **PASS**.
