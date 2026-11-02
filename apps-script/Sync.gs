/**
 * Kiroku V4 sync — copies the Google Sheets tabs into Supabase.
 * Bound to a Google Sheet (or standalone): Extensions > Apps Script > paste this file.
 *
 * Setup: see supabase/SETUP.md (V4 section).
 *
 * Secrets and sheet IDs go in Project Settings > Script Properties, never in this file:
 *   SUPABASE_URL          https://<project-ref>.supabase.co
 *   SUPABASE_SERVICE_KEY  the service_role key (server-side only; bypasses row security)
 *   SHEET_ID_1 .. SHEET_ID_4   the Doc Officer 1..4 sheet IDs (from the sheet URL)
 *
 * One owner per row, so no sheet can undo another sheet's edit:
 *   - the masterlist sends the shared tabs (Users, Kumiai, Companies, JobOrders)
 *   - each Doc Officer sheet sends only its owner's Tasks (editor_id)
 * Every Doc Officer sheet still shows every task. After the sync, the other officers'
 * task rows are refreshed from Supabase and shaded grey; edits to them are ignored.
 * Activity: Supabase activity_logs is the one list. New rows typed into a sheet's Activity tab
 * are added to it, then every Activity tab is rewritten from it (see syncActivityTabs).
 * Run syncAll() manually once, then installTrigger() to run scheduledSync() every 5 minutes.
 */

const SHARED_TABS = { Users: 'users', Kumiai: 'kumiai', Companies: 'companies', JobOrders: 'job_orders' };
const OWN_TABS = { Tasks: 'tasks' };

const MASTERLIST_ID = '1OcjPALavuFbnMdhoTTRtqppKyK94CIDCWord2Gqi6OA';

// The masterlist goes first: tasks point at job orders, which must already exist.
// owner = the editor_id whose tasks (and their activity) this sheet may send.
const SOURCES = [
  { key: 'masterlist',    sheetId: MASTERLIST_ID,          tabs: SHARED_TABS },
  { key: 'doc-officer-1', idProp: 'SHEET_ID_1', owner: 'u1', tabs: OWN_TABS },
  { key: 'doc-officer-2', idProp: 'SHEET_ID_2', owner: 'u2', tabs: OWN_TABS },
  { key: 'doc-officer-3', idProp: 'SHEET_ID_3', owner: 'u3', tabs: OWN_TABS },
  { key: 'doc-officer-4', idProp: 'SHEET_ID_4', owner: 'u4', tabs: OWN_TABS },
];

// Sheet header -> table column, where they differ.
const RENAME = {
  tasks: { order: 'sort_order' },
};

const TZ = 'Asia/Manila';

function syncAll() {
  const props = PropertiesService.getScriptProperties();
  const url = props.getProperty('SUPABASE_URL');
  const key = props.getProperty('SUPABASE_SERVICE_KEY');
  if (!url || !key) throw new Error('Set SUPABASE_URL and SUPABASE_SERVICE_KEY in Script Properties.');

  SOURCES.forEach(src => {
    const sheetId = src.sheetId || props.getProperty(src.idProp);
    if (!sheetId || Object.keys(src.tabs).length === 0) {
      Logger.log('skip ' + src.key + ' (no ID or no tabs configured)');
      return;
    }
    const payload = {};
    try {
      Object.entries(src.tabs).forEach(([tab, table]) => {
        payload[table] = readTab(sheetId, tab, table);
      });
      if (src.owner) keepOwnRows(payload, src.owner, src.key);
      else applyMasterlistFixes(payload);
    } catch (err) {
      logSyncFailure(url, key, src.key, err);
      throw err;
    }

    const res = UrlFetchApp.fetch(url + '/rest/v1/rpc/sync_import', {
      method: 'post',
      contentType: 'application/json',
      headers: { apikey: key, Authorization: 'Bearer ' + key },
      payload: JSON.stringify({ p_source: src.key, p_payload: payload }),
      muteHttpExceptions: true,
    });
    if (res.getResponseCode() >= 300) {
      logSyncFailure(url, key, src.key, res.getContentText());
      throw new Error(src.key + ' failed: ' + res.getContentText());
    }
    Logger.log(src.key + ': ' + res.getContentText());
    writeEventLogTab(url, key, src.key, sheetId);
  });

  refreshOtherOfficersRows(url, key, props);
  syncActivityTabs(url, key, props);
}

// Drops the rows this sheet does not own: other officers' tasks.
function keepOwnRows(payload, owner, sourceKey) {
  const allTasks = payload.tasks || [];
  payload.tasks = allTasks.filter(r => String(r.editor_id) === owner);
  Logger.log(sourceKey + ': sending ' + payload.tasks.length + ' of ' + allTasks.length + ' tasks (owner ' + owner + ')');
}

// ---------------------------------------------------------------- Activity tabs
// Every Doc Officer sheet's Activity tab is a copy of Supabase activity_logs, newest first.
//   1. Rows typed into the tab (activity_id blank) are added to activity_logs as the sheet's
//      owner, through import_sheet_activity() (supabase/09_merge_activity.sql).
//   2. The tab is rewritten from activity_logs, so it shows every action from the app and all sheets.
// A typed row Supabase refuses (unknown task_id, action_type, date) is kept at the bottom in red.
// Edits to rows that have an activity_id are overwritten: activity_logs rows are permanent.
// Never throws, like writeEventLogTab: a failed copy must not stop the sync.
const ACTIVITY_TAB = 'Activity';
const ACTIVITY_COLUMNS = ['task_id', 'action_type', 'date', 'time', 'details', 'user_name',
  'jo_id', 'previous_status', 'updated_status', 'source', 'activity_id'];
// The kinds that can be added from a sheet (Mark Done and the rest need the app).
const SHEET_ACTIVITY_TYPES = ['Follow Up', 'Send Message', 'Log Note', 'Upload'];
const ACTIVITY_NOTE = 'Copied from Supabase activity_logs after every sync (every 5 minutes).\n' +
  'To add an activity: type a new row at the bottom (task_id, action_type, date, time, details) ' +
  'and leave activity_id blank. It is recorded as this sheet\'s Doc Officer.\n' +
  'Rows with an activity_id cannot be changed: edits to them are put back.';

function syncActivityTabs(url, key, props) {
  const sheets = SOURCES.filter(src => src.owner && props.getProperty(src.idProp))
    .map(src => ({ src: src, sheetId: props.getProperty(src.idProp), keep: [] }));

  sheets.forEach(s => {
    try { s.keep = importTypedActivity(url, key, s.src, s.sheetId); }
    catch (e) { Logger.log(s.src.key + ': could not import typed activity: ' + e); s.failed = true; }
  });

  let logs;
  try { logs = readAllActivityLogs(url, key); }
  catch (e) { Logger.log('could not read activity_logs to write the Activity tabs: ' + e); return; }

  // A sheet whose typed rows could not be sent is left as it is, so those rows are not lost.
  sheets.filter(s => !s.failed).forEach(s => {
    try { writeActivityTab(s.sheetId, logs, s.keep); }
    catch (e) { Logger.log(s.src.key + ': could not write the Activity tab: ' + e); }
  });
}

// Sends the tab's rows with a blank activity_id. Returns the refused rows (as sheet values) with the reason.
function importTypedActivity(url, key, src, sheetId) {
  const sh = SpreadsheetApp.openById(sheetId).getSheetByName(ACTIVITY_TAB);
  if (!sh || sh.getLastRow() < 2) return [];
  const values = sh.getDataRange().getValues();
  const head = values[0].map(h => String(h).trim());
  const typed = [];
  values.slice(1).forEach((row, i) => {
    const obj = {};
    head.forEach((h, j) => { if (h) obj[h] = cell(row[j], h); });
    if (obj.activity_id || !obj.task_id) return;
    typed.push({
      row: i + 2, task_id: String(obj.task_id),
      // the old tab used type / body; the new one action_type / details
      action_type: obj.action_type || obj.type || '',
      date: obj.date || '', time: obj.time || '', details: obj.details || obj.body || '',
    });
  });
  if (!typed.length) return [];

  const res = UrlFetchApp.fetch(url + '/rest/v1/rpc/import_sheet_activity', {
    method: 'post',
    contentType: 'application/json',
    headers: { apikey: key, Authorization: 'Bearer ' + key },
    payload: JSON.stringify({ p_source: src.key, p_user: src.owner, p_rows: typed }),
    muteHttpExceptions: true,
  });
  if (res.getResponseCode() >= 300) throw new Error(res.getContentText());
  const out = JSON.parse(res.getContentText());
  Logger.log(src.key + ': typed activity added ' + out.added + ', already there ' + out.existing +
             ', refused ' + out.skipped.length);

  const byRow = {};
  typed.forEach(t => { byRow[t.row] = t; });
  return out.skipped.map(s => {
    const t = byRow[s.row];
    return { values: [t.task_id, t.action_type, t.date, t.time, t.details], reason: s.reason };
  });
}

// All activity_logs rows, newest first (PostgREST returns at most 1000 per request).
function readAllActivityLogs(url, key) {
  const all = [];
  for (let offset = 0; ; offset += 1000) {
    const res = UrlFetchApp.fetch(url + '/rest/v1/activity_logs?select=*' +
      '&order=created_at.desc,activity_id.desc&limit=1000&offset=' + offset, {
      headers: { apikey: key, Authorization: 'Bearer ' + key },
      muteHttpExceptions: true,
    });
    if (res.getResponseCode() >= 300) throw new Error(res.getContentText());
    const page = JSON.parse(res.getContentText());
    all.push.apply(all, page);
    if (page.length < 1000) return all;
  }
}

function writeActivityTab(sheetId, logs, keep) {
  const width = ACTIVITY_COLUMNS.length;
  const rows = logs.map(r => {
    const at = Utilities.formatDate(new Date(r.created_at), TZ, 'yyyy-MM-dd HH:mm');
    const v = Object.assign({}, r, { date: at.slice(0, 10), time: at.slice(11), details: r.action_details });
    return ACTIVITY_COLUMNS.map(c => (v[c] === null || v[c] === undefined) ? '' : String(v[c]));
  });
  const kept = keep.map(k => k.values.map(String).concat(Array(width - k.values.length).fill('')));

  const values = [ACTIVITY_COLUMNS].concat(rows, kept);

  const ss = SpreadsheetApp.openById(sheetId);
  const sh = ss.getSheetByName(ACTIVITY_TAB) || ss.insertSheet(ACTIVITY_TAB);
  // Nothing new: leave the tab alone, so it does not flicker every 5 minutes.
  if (!keep.length && sh.getLastRow() === values.length && sh.getLastColumn() === width &&
      JSON.stringify(sh.getDataRange().getDisplayValues()) === JSON.stringify(values)) return;

  sh.clear();
  sh.clearNotes();
  sh.getRange(1, 1, sh.getMaxRows(), sh.getMaxColumns()).clearDataValidations();
  if (sh.getMaxColumns() < width) sh.insertColumnsAfter(sh.getMaxColumns(), width - sh.getMaxColumns());
  if (sh.getMaxRows() < values.length + 50) sh.insertRowsAfter(sh.getMaxRows(), values.length + 50 - sh.getMaxRows());
  // Plain text, so a note like "=SUM(...)" is shown, not run as a formula.
  sh.getRange(1, 1, values.length, width).setNumberFormat('@').setValues(values);

  sh.getRange(1, 1, 1, width).setFontWeight('bold');
  sh.getRange(1, 1).setNote(ACTIVITY_NOTE);
  sh.setFrozenRows(1);
  if (rows.length) sh.getRange(2, 1, rows.length, width).setFontColor('#555555');
  keep.forEach((k, i) => {
    const r = 2 + rows.length + i;
    sh.getRange(r, 1, 1, width).setBackground('#fde2e1');
    sh.getRange(r, 1).setNote('Not added to Supabase: ' + k.reason + '. Fix this row; it is sent again on the next sync.');
  });
  // A dropdown for the action type of new rows (the empty rows below the data).
  const first = values.length + 1;
  sh.getRange(first, 2, sh.getMaxRows() - first + 1, 1).setDataValidation(
    SpreadsheetApp.newDataValidation().requireValueInList(SHEET_ACTIVITY_TYPES, true).setAllowInvalid(false).build());
}

// The same corrections the first setup made to the officer sheets, so the
// masterlist does not bring them back: job order 9 stays out, Workers Unite (c5) is under k2.
// Remove this once the masterlist sheet itself has the corrections.
function applyMasterlistFixes(payload) {
  if (payload.job_orders) payload.job_orders = payload.job_orders.filter(r => String(r.jo_id) !== 'j9');
  if (payload.companies) {
    const c5 = payload.companies.find(r => String(r.company_id) === 'c5');
    if (c5) c5.kumiai_id = 'k2';
    else payload.companies.push({ company_id: 'c5', kumiai_id: 'k2', name: 'Workers Unite' });
  }
}

// In each Doc Officer sheet, rewrites the other officers' task rows with the values in
// Supabase (and adds tasks the sheet is missing), so everyone sees the latest status.
// The owner's own rows are never touched. Never throws, like writeEventLogTab.
function refreshOtherOfficersRows(url, key, props) {
  let tasks;
  try {
    const res = UrlFetchApp.fetch(url + '/rest/v1/tasks?select=*&order=task_id&limit=10000', {
      headers: { apikey: key, Authorization: 'Bearer ' + key },
      muteHttpExceptions: true,
    });
    if (res.getResponseCode() >= 300) throw new Error(res.getContentText());
    tasks = JSON.parse(res.getContentText());
  } catch (e) {
    Logger.log('could not read tasks to refresh the sheets: ' + e);
    return;
  }

  SOURCES.filter(src => src.owner).forEach(src => {
    const sheetId = props.getProperty(src.idProp);
    if (!sheetId) return;
    try {
      const sh = SpreadsheetApp.openById(sheetId).getSheetByName('Tasks');
      const values = sh.getDataRange().getValues();
      const head = values[0].map(h => String(h).trim());
      const idCol = head.indexOf('task_id');
      const editorCol = head.indexOf('editor_id');
      if (idCol < 0 || editorCol < 0) throw new Error('Tasks tab needs task_id and editor_id headers');

      const rowOf = {};
      values.forEach((row, i) => { if (i > 0) rowOf[String(row[idCol]).trim()] = i; });

      let changed = 0;
      const added = [];
      tasks.filter(t => t.editor_id !== src.owner).forEach(t => {
        const i = rowOf[t.task_id];
        if (i === undefined) {
          added.push(head.map(h => sheetValue(t[RENAME_BACK[h] || h], h)));
          return;
        }
        head.forEach((h, j) => {
          const col = RENAME_BACK[h] || h;
          if (!h || !(col in t)) return;
          if (asText(values[i][j], h) !== asText(t[col], h)) {
            sh.getRange(i + 1, j + 1).setValue(sheetValue(t[col], h));
            changed++;
          }
        });
      });
      if (added.length) sh.getRange(values.length + 1, 1, added.length, head.length).setValues(added);

      shadeOtherOfficersRows(sh, idCol, editorCol, src.owner);
      Logger.log(src.key + ': refreshed ' + changed + ' cells, added ' + added.length + ' tasks of other officers');
    } catch (e) {
      Logger.log(src.key + ': could not refresh other officers\' rows: ' + e);
    }
  });
}

// Sheet header -> Supabase column for the refresh (the reverse of RENAME.tasks).
const RENAME_BACK = { order: 'sort_order' };

// One value as text, so a sheet cell and a Supabase value can be compared.
function asText(v, header) {
  if (v === '' || v === null || v === undefined) return '';
  if (v instanceof Date) {
    if (header === 'time') return Utilities.formatDate(v, TZ, 'HH:mm');
    const midnight = v.getHours() === 0 && v.getMinutes() === 0 && v.getSeconds() === 0;
    return Utilities.formatDate(v, TZ, midnight ? 'yyyy-MM-dd' : 'yyyy-MM-dd HH:mm');
  }
  const s = String(v).trim();
  if (/^(true|false)$/i.test(s)) return s.toUpperCase();
  // Supabase timestamps ("2026-06-11T01:00:00+00:00") -> Philippine time, like the sheet
  if (/_at$/.test(header) && /^\d{4}-\d{2}-\d{2}T/.test(s)) {
    return Utilities.formatDate(new Date(s), TZ, 'yyyy-MM-dd HH:mm');
  }
  return s;
}

// A Supabase value as it should be written into the sheet.
function sheetValue(v, header) {
  if (typeof v === 'boolean') return v;
  return asText(v, header);
}

// Grey rows that belong to other officers, so it is clear they are view-only.
// One conditional-format rule per sheet; it follows the rows when they are sorted.
function shadeOtherOfficersRows(sh, idCol, editorCol, owner) {
  const letter = c => sh.getRange(1, c + 1).getA1Notation().replace(/\d+/g, '');
  const formula = '=AND($' + letter(idCol) + '2<>"", $' + letter(editorCol) + '2<>"' + owner + '")';
  const ours = /^=AND\(\$[A-Z]+2<>"", \$[A-Z]+2<>"u\d+"\)$/;
  const rules = sh.getConditionalFormatRules();
  const current = rules.filter(r => {
    const c = r.getBooleanCondition();
    return c && ours.test(String(c.getCriteriaValues()[0]));
  });
  if (current.length === 1 && current[0].getBooleanCondition().getCriteriaValues()[0] === formula) return;

  const rule = SpreadsheetApp.newConditionalFormatRule()
    .whenFormulaSatisfied(formula)
    .setBackground('#eeeeee').setFontColor('#888888')
    .setRanges([sh.getRange(2, 1, sh.getMaxRows() - 1, sh.getMaxColumns())])
    .build();
  sh.setConditionalFormatRules(rules.filter(r => current.indexOf(r) < 0).concat(rule));
}

// Read-only copy of this sheet's latest event_logs rows, in the "Event Log" tab.
// Supabase stays the real log: the tab is rewritten after every sync and never synced back.
const EVENT_LOG_TAB = 'Event Log';
const EVENT_LOG_LIMIT = 500;
const EVENT_LOG_COLUMNS = [
  ['event_at', 'Date & Time (PH)'], ['event_type', 'Event'], ['module', 'Module'],
  ['record_id', 'Record ID'], ['field_changed', 'Field'], ['old_value', 'Old Value'],
  ['new_value', 'New Value'], ['description', 'Description'], ['sync_status', 'Status'],
];

// Never throws: a failed copy must not stop the other sheets from syncing.
function writeEventLogTab(url, key, sourceKey, sheetId) {
  try {
    const query = '?select=' + EVENT_LOG_COLUMNS.map(c => c[0]).join(',') +
      '&source_sheet=eq.' + encodeURIComponent(sourceKey) +
      '&order=event_at.desc&limit=' + EVENT_LOG_LIMIT;
    const res = UrlFetchApp.fetch(url + '/rest/v1/event_logs' + query, {
      headers: { apikey: key, Authorization: 'Bearer ' + key },
      muteHttpExceptions: true,
    });
    if (res.getResponseCode() >= 300) throw new Error(res.getContentText());

    const rows = JSON.parse(res.getContentText()).map(e => EVENT_LOG_COLUMNS.map(([col]) => {
      if (e[col] === null || e[col] === undefined) return '';
      if (col === 'event_at') return Utilities.formatDate(new Date(e[col]), TZ, 'yyyy-MM-dd HH:mm');
      return String(e[col]);
    }));
    const values = [EVENT_LOG_COLUMNS.map(c => c[1])].concat(rows);

    const ss = SpreadsheetApp.openById(sheetId);
    const sh = ss.getSheetByName(EVENT_LOG_TAB) || ss.insertSheet(EVENT_LOG_TAB);
    if (sh.getProtections(SpreadsheetApp.ProtectionType.SHEET).length === 0) {
      sh.protect().setDescription('Copied from Supabase after each sync. Edits here are overwritten.')
        .setWarningOnly(true);
    }
    sh.clearContents();
    // Plain text, so a value like "=SUM(...)" from the log is shown, not run as a formula.
    const range = sh.getRange(1, 1, values.length, values[0].length);
    range.setNumberFormat('@').setValues(values);
    sh.getRange(1, 1, 1, values[0].length).setFontWeight('bold');
    sh.setFrozenRows(1);
  } catch (e) {
    Logger.log(sourceKey + ': could not write the Event Log tab: ' + e);
  }
}

// Writes one 'Sync Failed' row to event_logs. It never throws, so the original error still shows.
function logSyncFailure(url, key, sourceKey, message) {
  try {
    UrlFetchApp.fetch(url + '/rest/v1/event_logs', {
      method: 'post',
      contentType: 'application/json',
      headers: { apikey: key, Authorization: 'Bearer ' + key, Prefer: 'return=minimal' },
      payload: JSON.stringify({
        event_type: 'Sync Failed', source: 'Google Sheets', action: 'Sync', module: 'Sync',
        description: 'Sync from ' + sourceKey + ' failed',
        new_value: String(message).slice(0, 500),
        sync_status: 'Failed', source_sheet: sourceKey,
      }),
      muteHttpExceptions: true,
    });
  } catch (e) {
    Logger.log('could not write sync failure log: ' + e);
  }
}

function readTab(sheetId, tab, table) {
  const sh = SpreadsheetApp.openById(sheetId).getSheetByName(tab);
  if (!sh) throw new Error('Tab "' + tab + '" not found in sheet ' + sheetId);

  const values = sh.getDataRange().getValues();
  const head = values.shift().map(h => String(h).trim());
  const rename = RENAME[table] || {};

  return values
    .filter(row => row.some(c => c !== ''))
    .map(row => {
      const obj = {};
      head.forEach((h, i) => {
        if (h) obj[rename[h] || h] = cell(row[i], h);
      });
      if (table === 'activity') {
        obj.activity_key = [obj.task_id, obj.type, obj.date, obj.time].join('|');
        obj.activity_date = obj.date;
        obj.activity_time = obj.time;
        delete obj.date;
        delete obj.time;
      }
      return obj;
    });
}

// One sheet cell -> JSON value Supabase accepts.
function cell(v, header) {
  if (v === '' || v === null) return null;
  if (v instanceof Date) {
    if (header === 'time') return Utilities.formatDate(v, TZ, 'HH:mm');
    const midnight = v.getHours() === 0 && v.getMinutes() === 0 && v.getSeconds() === 0;
    return Utilities.formatDate(v, TZ, midnight ? 'yyyy-MM-dd' : "yyyy-MM-dd'T'HH:mm:ssXXX");
  }
  // text timestamps like "2026-06-11 09:00" (done_at) are Philippine time
  if (/_at$/.test(header) && /^\d{4}-\d{2}-\d{2} \d{2}:\d{2}/.test(String(v))) {
    return String(v).replace(' ', 'T') + '+08:00';
  }
  return v;
}

// The 5-minute trigger runs this, so it never overlaps a Job Order change from the app
// (JobOrders.gs holds the same lock while it edits the sheets and syncs).
function scheduledSync() {
  const lock = LockService.getScriptLock();
  if (!lock.tryLock(30000)) { Logger.log('skipped: an app change is syncing right now'); return; }
  try { syncAll(); } finally { lock.releaseLock(); }
}

// Run once: replaces any existing sync schedule with one that runs every 5 minutes.
// Google Apps Script allows only 1, 5, 10, 15 or 30 minutes.
function installTrigger() {
  ScriptApp.getProjectTriggers()
    .filter(t => ['syncAll', 'scheduledSync'].indexOf(t.getHandlerFunction()) >= 0)
    .forEach(t => ScriptApp.deleteTrigger(t));
  ScriptApp.newTrigger('scheduledSync').timeBased().everyMinutes(5).create();
}

// One-time cleanup: each Doc Officer sheet keeps only the tabs it uses
// (Tasks, Activity, Event Log). The shared tabs live in the masterlist.
// Run it once by hand. Deleted tabs can be restored from File > Version history.
const UNUSED_OFFICER_TABS = Object.keys(SHARED_TABS);

function removeUnusedTabs() {
  const props = PropertiesService.getScriptProperties();
  SOURCES.filter(src => src.owner).forEach(src => {
    const sheetId = props.getProperty(src.idProp);
    if (!sheetId) return;
    const ss = SpreadsheetApp.openById(sheetId);
    UNUSED_OFFICER_TABS.forEach(tab => {
      const sh = ss.getSheetByName(tab);
      if (sh) {
        ss.deleteSheet(sh);
        Logger.log(src.key + ': deleted tab ' + tab);
      }
    });
  });
}
