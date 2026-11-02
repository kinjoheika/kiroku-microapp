/**
 * Kiroku V4 — Job Order changes made in the app, written to the Google Sheets and Supabase.
 * Add this file to the same Apps Script project as Sync.gs (it uses SOURCES, MASTERLIST_ID and syncAll()).
 *
 * The sheets stay the source of truth: each change is made in the sheets first, the way a
 * hand edit would be, and syncAll() then carries it to Supabase and the other officers' sheets.
 *   create      JO row -> masterlist JobOrders, each task -> its owner's Tasks tab
 *   edit        JO row updated; when the deploy date moves, the owners' task due dates too
 *   archive     active = FALSE      reactivate   active = TRUE
 *   delete      rows removed from every sheet, then from Supabase (the sync never deletes)
 *
 * Setup: see supabase/SETUP.md ("Job Orders from the app").
 */

function doPost(e) {
  try {
    const data = JSON.parse(e.postData.contents);
    const token = PropertiesService.getScriptProperties().getProperty('APP_TOKEN');
    if (!token || data.token !== token) return jsonOut({ ok: false, error: 'bad token' });
    const handler = JO_ACTIONS[data.action];
    if (!handler) return jsonOut({ ok: false, error: 'unknown action' });

    // One writer at a time: the scheduled sync (scheduledSync) waits on the same lock.
    const lock = LockService.getScriptLock();
    lock.waitLock(60000);
    try {
      const res = handler(data);
      if (!res.ok) return jsonOut(res);
      SpreadsheetApp.flush();
      // The sheets are already changed. If the sync fails, the 5-minute trigger retries it.
      try { syncAll(); res.synced = true; }
      catch (err) { res.synced = false; res.sync_error = String(err); }
      return jsonOut(res);
    } finally {
      lock.releaseLock();
    }
  } catch (err) {
    return jsonOut({ ok: false, error: String(err) });
  }
}

const JO_ACTIONS = {
  create_jo: createJobOrder,
  edit_jo: editJobOrder,
  archive_jo: data => setJobOrderActive(data, false),
  reactivate_jo: data => setJobOrderActive(data, true),
  delete_jo: deleteJobOrder,
};

function createJobOrder(data) {
  const jo = data.jo || {};
  const tasks = data.tasks || [];
  if (!jo.jo_number || !jo.company_id || !jo.target_deployment_date) {
    return { ok: false, error: 'JO number, company and target deploy date are required.' };
  }
  if (!tasks.length) return { ok: false, error: 'No tasks to create.' };

  const m = masterlistJobOrders();
  const number = String(jo.jo_number).trim();
  if (m.rows.some(r => cellText(r[m.col.jo_number]) === number)) {
    return { ok: false, error: 'JO# ' + number + ' already exists.' };
  }

  // Next free jN. j9 is skipped: applyMasterlistFixes() drops it from every sync.
  let n = m.rows.reduce((max, r) => {
    const x = /^j(\d+)$/.exec(cellText(r[m.col.jo_id]));
    return x ? Math.max(max, Number(x[1])) : max;
  }, 0) + 1;
  if (n === 9) n = 10;
  const joId = 'j' + n;

  const joRow = {
    jo_id: joId, jo_number: number, company_id: jo.company_id,
    // worker_name is required in Supabase; the app's form does not ask for it yet.
    worker_name: jo.worker_name || 'TBA',
    target_deployment_date: jo.target_deployment_date,
    work_category: jo.work_category || '', program_type: jo.program_type || '', active: true,
  };
  m.sheet.appendRow(m.head.map(h => (h in joRow ? joRow[h] : '')));

  // Tasks go to their owner's sheet; the sync copies them into the other officers' sheets.
  const byOwner = {};
  tasks.forEach(t => {
    (byOwner[t.editor_id] = byOwner[t.editor_id] || []).push({
      task_id: joId + '-' + t.track + '-' + t.index, jo_id: joId, track: t.track, task_name: t.task_name,
      order: t.order, offset_days: t.offset_days, editor_id: t.editor_id, due_date: t.due_date,
      done: false, done_at: '',
    });
  });
  Object.keys(byOwner).forEach(owner => {
    const sh = officerTab(owner, 'Tasks');
    const head = headerOf(sh);
    const rows = byOwner[owner].map(r => head.map(h => (h in r ? r[h] : '')));
    sh.getRange(sh.getLastRow() + 1, 1, rows.length, head.length).setValues(rows);
  });
  return { ok: true, jo_id: joId };
}

function editJobOrder(data) {
  const jo = data.jo || {};
  if (!jo.jo_id || !jo.jo_number || !jo.company_id || !jo.target_deployment_date) {
    return { ok: false, error: 'JO number, company and target deploy date are required.' };
  }
  const m = masterlistJobOrders();
  const i = m.rows.findIndex(r => cellText(r[m.col.jo_id]) === jo.jo_id);
  if (i < 0) return { ok: false, error: 'Job Order ' + jo.jo_id + ' is not in the masterlist.' };
  const number = String(jo.jo_number).trim();
  if (m.rows.some((r, j) => j !== i && cellText(r[m.col.jo_number]) === number)) {
    return { ok: false, error: 'JO# ' + number + ' already exists.' };
  }
  setCells(m.sheet, m.head, i + 2, {
    jo_number: number, company_id: jo.company_id, target_deployment_date: jo.target_deployment_date,
    work_category: jo.work_category || '', program_type: jo.program_type || '',
  });

  // New due dates, written in each task owner's sheet (the others are refreshed by the sync).
  const due = {};
  (data.due_changes || []).forEach(d => { due[d.task_id] = d.due_date; });
  if (Object.keys(due).length) {
    ownerSources().forEach(src => {
      const sh = officerTab(src.owner, 'Tasks');
      const head = headerOf(sh);
      const idCol = head.indexOf('task_id'), edCol = head.indexOf('editor_id'), dueCol = head.indexOf('due_date');
      sh.getDataRange().getValues().forEach((r, k) => {
        const id = cellText(r[idCol]);
        if (k > 0 && id in due && cellText(r[edCol]) === src.owner) sh.getRange(k + 1, dueCol + 1).setValue(due[id]);
      });
    });
  }
  return { ok: true, jo_id: jo.jo_id };
}

function setJobOrderActive(data, active) {
  const m = masterlistJobOrders();
  const i = m.rows.findIndex(r => cellText(r[m.col.jo_id]) === data.jo_id);
  if (i < 0) return { ok: false, error: 'Job Order ' + data.jo_id + ' is not in the masterlist.' };
  setCells(m.sheet, m.head, i + 2, { active: active });
  return { ok: true, jo_id: data.jo_id };
}

// The sync only adds and updates, so a delete is done in the sheets and in Supabase here.
// A Job Order with recorded actions (activity_logs) is kept: that history is append-only.
function deleteJobOrder(data) {
  const joId = data.jo_id;
  const props = PropertiesService.getScriptProperties();
  const url = props.getProperty('SUPABASE_URL');
  const key = props.getProperty('SUPABASE_SERVICE_KEY');
  const headers = { apikey: key, Authorization: 'Bearer ' + key };

  const logs = supabaseJson(url + '/rest/v1/activity_logs?select=activity_id&limit=1&jo_id=eq.' + encodeURIComponent(joId), headers);
  if (logs.length) {
    return { ok: false, error: 'This Job Order has recorded actions, which are kept permanently. Archive it instead.' };
  }

  const m = masterlistJobOrders();
  const i = m.rows.findIndex(r => cellText(r[m.col.jo_id]) === joId);
  const number = i >= 0 ? cellText(m.rows[i][m.col.jo_number]) : joId;
  if (i >= 0) m.sheet.deleteRow(i + 2);

  // Every officer sheet shows every task, so the rows go from all of them.
  const prefix = joId + '-';
  let taskRows = 0;
  ownerSources().forEach(src => {
    taskRows += deleteRowsWhere(officerTab(src.owner, 'Tasks'), 'jo_id', v => v === joId);
    const act = SpreadsheetApp.openById(props.getProperty(src.idProp)).getSheetByName('Activity');
    if (act) deleteRowsWhere(act, 'task_id', v => v.indexOf(prefix) === 0);
  });

  // Its tasks go with it (on delete cascade). It has no activity_logs rows (checked above).
  const res = UrlFetchApp.fetch(url + '/rest/v1/job_orders?jo_id=eq.' + encodeURIComponent(joId), {
    method: 'delete', headers: headers, muteHttpExceptions: true,
  });
  if (res.getResponseCode() >= 300) throw new Error('Supabase delete failed: ' + res.getContentText());
  UrlFetchApp.fetch(url + '/rest/v1/event_logs', {
    method: 'post', contentType: 'application/json',
    headers: Object.assign({ Prefer: 'return=minimal' }, headers),
    payload: JSON.stringify({
      event_type: 'Record Deleted', source: 'Kiroku', action: 'Delete', module: 'Job Orders',
      record_id: joId, user_id: data.user_id || null, user_name: data.user_name || null,
      old_value: 'JO# ' + number, description: 'Job Order JO# ' + number + ' deleted with its tasks',
      source_sheet: 'masterlist',
    }),
    muteHttpExceptions: true,
  });
  return { ok: true, jo_id: joId, task_rows_removed: taskRows };
}

// ---------------------------------------------------------------- helpers
function masterlistJobOrders() {
  const sheet = SpreadsheetApp.openById(MASTERLIST_ID).getSheetByName('JobOrders');
  const values = sheet.getDataRange().getValues();
  const head = values[0].map(h => String(h).trim());
  const col = {};
  head.forEach((h, i) => { col[h] = i; });
  if (!('jo_id' in col) || !('jo_number' in col)) throw new Error('JobOrders tab needs jo_id and jo_number headers');
  return { sheet: sheet, head: head, col: col, rows: values.slice(1) };
}

function ownerSources() {
  return SOURCES.filter(s => s.owner);
}

function officerTab(owner, tab) {
  const src = SOURCES.find(s => s.owner === owner);
  const sheetId = src && PropertiesService.getScriptProperties().getProperty(src.idProp);
  if (!sheetId) throw new Error('No sheet for officer ' + owner);
  const sh = SpreadsheetApp.openById(sheetId).getSheetByName(tab);
  if (!sh) throw new Error('Tab "' + tab + '" not found for officer ' + owner);
  return sh;
}

function headerOf(sh) {
  return sh.getRange(1, 1, 1, sh.getLastColumn()).getValues()[0].map(h => String(h).trim());
}

function setCells(sh, head, rowNum, values) {
  Object.keys(values).forEach(h => {
    const c = head.indexOf(h);
    if (c >= 0) sh.getRange(rowNum, c + 1).setValue(values[h]);
  });
}

// Deletes from the bottom up, so row numbers stay valid. Returns how many rows went.
function deleteRowsWhere(sh, header, test) {
  const values = sh.getDataRange().getValues();
  const c = values[0].map(h => String(h).trim()).indexOf(header);
  if (c < 0) return 0;
  let n = 0;
  for (let k = values.length - 1; k >= 1; k--) {
    if (test(cellText(values[k][c]))) { sh.deleteRow(k + 1); n++; }
  }
  return n;
}

function cellText(v) {
  return String(v === null || v === undefined ? '' : v).trim();
}

function supabaseJson(url, headers) {
  const res = UrlFetchApp.fetch(url, { headers: headers, muteHttpExceptions: true });
  if (res.getResponseCode() >= 300) throw new Error(res.getContentText());
  return JSON.parse(res.getContentText());
}

function jsonOut(obj) {
  return ContentService.createTextOutput(JSON.stringify(obj)).setMimeType(ContentService.MimeType.JSON);
}
