/**
 * Kiroku edit log — Google Apps Script web app bound to the Kiroku Sheet.
 *
 * Setup:
 *  1. Open the Sheet > Extensions > Apps Script. Replace the contents with this file.
 *  2. Deploy > New deployment > type "Web app".
 *       Execute as: Me.   Who has access: Anyone.
 *  3. Copy the Web app URL into LOG_URL in index.html.
 *  4. Keep LOG_TOKEN in index.html equal to TOKEN below.
 *
 * Each UI change is appended as one row to the "EditLog" tab (created on first write).
 */
const TOKEN = 'kiroku-demo-token';
const LOG_TAB = 'EditLog';
const HEADERS = ['logged_at', 'user', 'entity', 'entity_id', 'field', 'old_value', 'new_value', 'source'];

// RETIRED (security audit 2026-11-09). Its token was public in index.html, so anyone could write rows into the
// sheet. Kiroku no longer uses it: activity_logs and event_logs in Supabase replace the EditLog tab.
// Also archive its deployment: Deploy > Manage deployments > Archive. The EditLog tab is kept as it is.
function doPost(e) {
  return json({ ok: false, error: 'This logger is retired.' });
}

function doPostRetired_(e) {
  try {
    const data = JSON.parse(e.postData.contents);
    if (data.token !== TOKEN) return json({ ok: false, error: 'bad token' });

    const changes = data.changes || [];
    const ss = SpreadsheetApp.getActiveSpreadsheet();
    let sh = ss.getSheetByName(LOG_TAB);
    if (!sh) {
      sh = ss.insertSheet(LOG_TAB);
      sh.appendRow(HEADERS);
      sh.setFrozenRows(1);
      sh.getRange(1, 1, 1, HEADERS.length).setFontWeight('bold');
    }
    const now = new Date();
    const rows = changes.map(c => [now, c.user || '', c.entity || '', c.entityId || '',
      c.field || '', String(c.oldValue ?? ''), String(c.newValue ?? ''), 'kiroku-ui']);
    if (rows.length) {
      sh.getRange(sh.getLastRow() + 1, 1, rows.length, HEADERS.length).setValues(rows);
    }
    return json({ ok: true, written: rows.length });
  } catch (err) {
    return json({ ok: false, error: String(err) });
  }
}

function json(obj) {
  return ContentService.createTextOutput(JSON.stringify(obj)).setMimeType(ContentService.MimeType.JSON);
}
