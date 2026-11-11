# Kiroku

Kiroku tracks job orders and the tasks (gates) each one must pass, for the Doc Officers, the CEO and Admin.

* **Website:** https://kinjoheika.github.io/kiroku-microapp/ (GitHub Pages, from the `kiroku-v4-microapp` branch)
* **Data:** Supabase. It holds every record and enforces who may see and change what.

There is no Google Sheet and no Apps Script any more. Admin manages users, agencies, clients, stages and job
orders in Kiroku, and can download everything as an Excel file (**Configuration → Download Excel**).

## Files

| File | What it is |
|---|---|
| `index.html` | Kiroku. One page: sign-in, My Tasks, Due Gates, My Entries, Discuss, Configuration. |
| `index-centered.html` | The same app laid out in the middle of the screen. Every change goes into both files. |
| `supabase/` | The database: tables, security rules and functions, in the order they were applied. See `supabase/SETUP.md`. |
| `SECURITY_TODO.md` | What is left to do for security, in order. |
| `SECURITY_AUDIT.md` | The security audit of 2026-11-09 (a record). |

## Run it locally

```bash
python -m http.server 8765
```

Then open http://localhost:8765/ and sign in with a Kiroku login. It reads the live Supabase project.

## Security in one paragraph

The page contains only Supabase's **publishable** key, which is safe to publish: on its own it can read nothing.
Every read and change is checked by the database itself (row security and the functions in `supabase/`), against
the signed-in person's role. No secret key is used anywhere. After any database change, run
`supabase/14_security_tests.sql` in the Supabase SQL Editor: every row must say **PASS**.
