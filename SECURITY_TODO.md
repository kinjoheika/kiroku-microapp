# Kiroku — what is left to fix

Updated 2026-11-11. Work top to bottom. The first three are **urgent**: each one alone is a way into Kiroku.

**Kiroku no longer uses Google Sheets.** Supabase holds every record; the website (GitHub Pages) is the only way in.
Admin manages users, job orders and stages in Kiroku, and gets a spreadsheet with **Configuration → Download Excel**.

**Already done and verified on live:**
* database locked (security tests: every row PASS)
* sign-up off
* demo login removed
* automatic sign-out
* browser cleanup
* XSS fixes
* Change password button
* Users, archive/delete job orders and Download Excel in Kiroku (`16_no_sheets.sql`, pages live 2026-11-11)

---

## 🔴 1. Delete the secret key, the Apps Script and the sheets (urgent, 10 min) — *you*
**Why:** the secret key bypasses every security rule, most of it was visible in a screenshot, and it is stored in
the Apps Script. Nothing in Kiroku needs it any more. Do the steps **in this order**:

- [ ] Supabase → **Project Settings → API Keys → Secret keys**: delete **every** secret key.
- [ ] If **Legacy API keys** (`anon` / `service_role`, starting with `eyJ`) are shown: **Disable legacy API keys**.
- [ ] Reload Kiroku and sign in: it must work as before (it uses only the publishable key).
- [ ] Supabase → SQL Editor: run `supabase/17_remove_sheet_sync.sql`, then `supabase/14_security_tests.sql` (every row PASS).
- [ ] Optional: in each Kiroku Google Sheet, **File → Download → Microsoft Excel** to keep a copy.
- [ ] Google Drive: delete every Kiroku Google Sheet and the Apps Script project (script.google.com). Then **empty the
      Drive trash**, or the script and its copy of the key stay there for 30 days.
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
- [ ] Kiroku → **Configuration → Users**: put the same email in each person's **Email** field.
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

## 🟠 4. Supabase sign-in settings (3 min) — *you*
- [ ] **Authentication → Sign In / Providers → Passwords:** minimum length **12**; turn on **leaked password protection** if shown.
- [ ] **Authentication → Sessions:** JWT expiry **3600 seconds** or less.
- [ ] Confirm **"Allow new users to sign up"** is still **OFF**.

## 🟠 5. Who can change Kiroku itself (2 min) — *you*
**Why:** anyone who can push to the GitHub repository or sign in to the Supabase dashboard can change Kiroku.
- [ ] GitHub → repository **Settings → Collaborators**: only people who must change the code.
- [ ] Supabase → **Organization → Team**: only you and Admin.

## 🟡 6. MFA — authenticator app codes — *Claude builds it, you decide*
- [ ] **Decide:** required for **everyone** (recommended) or only Admin and CEO?
- [ ] Claude builds:
  * the QR set-up screen
  * the 6-digit code step at sign-in
  * a database rule so data is only given after the code is entered
- [ ] Each person installs Google or Microsoft Authenticator and scans their QR once.
- [ ] Admin keeps a backup (a second device) for their own authenticator.

## 🟡 7. Backups and recovery — *you and Claude*
Supabase is now the only copy of the data (the sheets are gone), so this matters more than before.
- [ ] Tell Claude your Supabase plan: **Free** (no automatic backups) or **Pro** (daily backups).
- [ ] Until then: Admin clicks **Configuration → Download Excel** once a week and keeps the file somewhere safe.
- [ ] Claude writes an export script (all tables to dated files) and a restore guide.
- [ ] Do one test restore into a spare project, and note the date here.

---

## Phase 2 — reliability (after security)
- [ ] **Overdue dates:** the page now uses today's Philippine date. Claude reviews every overdue calculation.
- [ ] **Gate order — decide:** must earlier gates be **Completed** before a later one can be marked done? Can Admin override? Claude then enforces it in the database.
- [ ] **Audit logs:** after a normal day of use, check the activity and change logs show who did what. Claude can write the check query.
- [ ] **Backup restore test:** see 7.

## Rules from now on
* Never screenshot or paste a **password** or **key**. Cover the value first.
* When someone leaves: delete their login (Supabase → Authentication → Users) on the same day.
* After any database change, run `supabase/14_security_tests.sql`. Every row must say **PASS**.
