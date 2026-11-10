1. Replace Google Sheets with My Entries for each user.
2. Google Sheets should contain configuration lists, including Agencies and Job Orders (JO).
3. Combine the Agency and Client Lists into one tab.
4. Google Sheets should only be accessible to Admin accounts.

# links for the main pieces:
Kiroku Sync script (Apps Script): https://script.google.com/home/projects/1rn_tEbYq-Waq3Fs69Nui-zu6_3pNj41kWgmQIqwPqgI1j4JvZskRjDmt/edit

Doc Officer 1 sheet: https://docs.google.com/spreadsheets/d/14W4LtspvWhmp6dIwtkoWicLy98MO7nmaT5e_nRpXbgs/edit

Doc Officer 2 sheet: https://docs.google.com/spreadsheets/d/1mBsENuWFOYi45mILo7Za_5HIqFvwNzsR9eidq7gsAno/edit

Doc Officer 3 sheet: https://docs.google.com/spreadsheets/d/12k81jEyzBj1osoxxQ9XfSe2PZoDQr-b5qPU2sNeyX7M/edit

Doc Officer 4 sheet: https://docs.google.com/spreadsheets/d/1edyDABJKPno_hHU73POsNI6T5cjD4PBtCZ6xUkZonTE/edit

Admin Masterlist sheet: https://docs.google.com/spreadsheets/d/1wn6YERoX2xh9LPlU_jn5_5C2jeBl8OGD8yAZHx5j-1Q/edit

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

