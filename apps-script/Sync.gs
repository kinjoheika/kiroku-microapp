/**
 * Kiroku V4 sync — five Google Sheets and Supabase, kept in step every 5 minutes.
 *   Admin Masterlist <-> Supabase <-> 4 Doc Officer sheets, and Supabase <-> the Kiroku website.
 * Paste this file into one Apps Script project (Extensions > Apps Script). Setup: supabase/SETUP.md.
 *
 * Secrets and sheet IDs go in Project Settings > Script Properties, never in this file:
 *   SUPABASE_URL          https://<project-ref>.supabase.co
 *   SUPABASE_SERVICE_KEY  the service_role key (server-side only; bypasses row security)
 *   ADMIN_SHEET_ID        the Admin Masterlist's sheet ID (from the sheet URL)
 *   SHEET_ID_1 .. SHEET_ID_4   the Doc Officer 1..4 sheet IDs
 *
 * Who edits what:
 *   - the Admin Masterlist has every tab: Users, Kumiai, Companies, JobOrders (it alone sends these)
 *     and all Tasks, editable
 *   - each Doc Officer sheet holds and edits only the Tasks it owns
 *   - both directions for Tasks go through syncTasks, which also decides conflicts
 * People see everyday columns (Job Order No., Worker Name, Track, Task Description, Due Date, Status, Remarks,
 * and Assigned Officer on the Admin sheet). Technical columns stay in the same tab, hidden and locked; see
 * COLUMN_FIELD and SHARED_COLUMNS. The CEO has no sheet.
 * Activity: Supabase activity_logs is the one list. New rows typed into a sheet's Activity tab
 * are added to it, then every Activity tab is rewritten from it (see syncActivityTabs).
 * Event logs: Supabase is the real log. The Admin Masterlist's Event Log tab is a read-only copy;
 * the Doc Officer sheets have none.
 * Run setupFriendlySheets() once, previewTaskSync() to see what a sync would change, then syncAll(),
 * then installTrigger() to run scheduledSync() every 5 minutes.
 */

const SHARED_TABS = { Users: 'users', Kumiai: 'kumiai', Companies: 'companies', JobOrders: 'job_orders' };

// The old masterlist. Read only by setupAdminSheet(), to copy its data once. Nothing else uses it.
const OLD_MASTERLIST_ID = '1OcjPALavuFbnMdhoTTRtqppKyK94CIDCWord2Gqi6OA';
const ADMIN_USER_ID = 'u6';

// The Admin Masterlist goes first: tasks point at job orders, which must already exist.
// owner = the editor_id whose tasks this sheet may change.
const SOURCES = [
  { key: 'admin',         idProp: 'ADMIN_SHEET_ID', tabs: SHARED_TABS, activityUser: ADMIN_USER_ID },
  { key: 'doc-officer-1', idProp: 'SHEET_ID_1', owner: 'u1' },
  { key: 'doc-officer-2', idProp: 'SHEET_ID_2', owner: 'u2' },
  { key: 'doc-officer-3', idProp: 'SHEET_ID_3', owner: 'u3' },
  { key: 'doc-officer-4', idProp: 'SHEET_ID_4', owner: 'u4' },
];

function masterlistId() {
  const id = PropertiesService.getScriptProperties().getProperty('ADMIN_SHEET_ID');
  if (!id) throw new Error('Set ADMIN_SHEET_ID in Script Properties.');
  return id;
}

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

  masterlistId();
  SOURCES.filter(src => src.tabs).forEach(src => {
    const sheetId = props.getProperty(src.idProp);
    const payload = {};
    try {
      Object.entries(src.tabs).forEach(([tab, table]) => {
        payload[table] = readTab(sheetId, tab, table);
      });
      resolveSharedRows(sheetId, payload);
      applyMasterlistFixes(payload);
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
  });

  syncTasks(url, key, props);
  syncActivityTabs(url, key, props);
  writeAdminEventLog(url, key, props);
}

// Writes nothing: logs what syncTasks would change right now, field by field.
function previewTaskSync() {
  const props = PropertiesService.getScriptProperties();
  const url = props.getProperty('SUPABASE_URL');
  const key = props.getProperty('SUPABASE_SERVICE_KEY');
  const ownerKeys = {};
  SOURCES.filter(src => src.owner).forEach(src => { ownerKeys[src.owner] = src.key; });
  const ctx = readTaskContext(url, key);
  const agreed = readAgreedTasks(url, key, ctx);
  const baselines = readBaselines(url, key);
  const rowsByKey = {};
  taskSources(props).forEach(src => {
    rowsByKey[src.key] = readTaskSheet(props.getProperty(src.idProp), ctx, src, true).rows;
  });
  const m = mergeTasks(agreed, baselines, rowsByKey, ownerKeys);
  const lines = [];
  Object.keys(m.changes).forEach(source => m.changes[source].forEach(id => {
    const before = agreed[id] || {};
    TASK_FIELDS.filter(f => before[f] !== m.final[id][f]).forEach(f => {
      lines.push(source + ' ' + id + ' ' + f + ': "' + (before[f] || '') + '" -> "' + m.final[id][f] + '"');
    });
  }));
  Logger.log('tasks in Supabase ' + Object.keys(agreed).length + ', after sync ' + Object.keys(m.final).length +
             ', fields that would change ' + lines.length + ', conflicts ' + m.conflicts.length + ', rejected ' + m.rejected.length);
  lines.slice(0, 60).forEach(l => Logger.log(l));
}

// ---------------------------------------------------------------- Tasks: two-way sync
// A task can be edited in two sheets (the Admin Masterlist and its owner's sheet) and in Kiroku.
// Supabase holds the agreed value. sheet_sync_state holds, per sheet, the values that sheet had
// after the last sync, so a cell that differs from them was edited there since then, and a Supabase
// value that differs from them was changed in Kiroku since then. That is what stops loops: a value
// the sync itself wrote is never mistaken for someone's edit. For one field:
//   Admin sheet edited     -> Admin's value goes everywhere
//   Kiroku changed it, and the owner's sheet changed it too -> Kiroku's stays
//   only the owner's sheet edited -> the owner's value goes everywhere
//   nobody edited          -> Supabase's value goes to every sheet
// A value that loses is kept in event_logs and noted on the cell, never dropped silently.
// A Doc Officer's sheet can change only their own tasks, and only OWNER_FIELDS on them. This check
// runs here, so unhiding a column or editing another officer's row changes nothing.
// A row removed from a sheet is put back: Job Orders are deleted from the app, not by removing rows.
const TASK_FIELDS = ['jo_id', 'track', 'task_name', 'sort_order', 'offset_days', 'editor_id', 'due_date', 'status', 'remarks'];
const REQUIRED_TASK_FIELDS = ['jo_id', 'track', 'task_name', 'sort_order', 'offset_days', 'due_date', 'status'];
const OWNER_FIELDS = ['task_name', 'due_date', 'status', 'remarks'];
const TASK_STATUSES = ['Pending', 'In Progress', 'Completed'];
const TASK_TRACKS = ['TIO', 'OTIT', 'COE'];
const ADMIN_KEY = 'admin';
// Filled in by the sync, for reading only: never sent to Supabase.
const DERIVED_COLUMNS = { job_orders: ['assigned_officers', 'Assigned Officers'] };

// What people see in the Tasks tab, and the technical columns kept hidden to the right of it.
// The sync finds columns by these names, so their order can change but the names cannot.
const VISIBLE_COLUMNS = ['Job Order No.', 'Worker Name', 'Track', 'Task Description', 'Due Date', 'Status', 'Assigned Officer', 'Remarks'];
const HIDDEN_COLUMNS = ['task_id', 'jo_id', 'editor_id', 'order', 'offset_days', 'done', 'done_at'];
const COLUMN_FIELD = {
  'Track': 'track', 'Task Description': 'task_name', 'Due Date': 'due_date', 'Status': 'status', 'Remarks': 'remarks',
  'jo_id': 'jo_id', 'editor_id': 'editor_id', 'order': 'sort_order', 'offset_days': 'offset_days',
};
const NOTE_PREFIX = 'Kiroku: ';

// The Admin Masterlist's other tabs, in everyday words. [what people see, the field behind it]
// company_name and kumiai_name are looked up to company_id and kumiai_id; '' is filled in by the sync.
const SHARED_COLUMNS = {
  Users: { table: 'users', idField: 'user_id', idPrefix: 'u', columns: [['Name', 'name'], ['Role', 'role'], ['Email', 'email']], hidden: ['user_id'] },
  Kumiai: { table: 'kumiai', idField: 'kumiai_id', idPrefix: 'k', columns: [['Kumiai', 'name']], hidden: ['kumiai_id'] },
  Companies: { table: 'companies', idField: 'company_id', idPrefix: 'c', columns: [['Company', 'name'], ['Kumiai', 'kumiai_name']], hidden: ['company_id', 'kumiai_id'] },
  JobOrders: { table: 'job_orders', idField: 'jo_id', idPrefix: 'j',
    columns: [['Job Order No.', 'jo_number'], ['Worker Name', 'worker_name'], ['Company', 'company_name'], ['Target Deployment Date', 'target_deployment_date'],
              ['Work Category', 'work_category'], ['Program Type', 'program_type'], ['Active', 'active'], ['Assigned Officers', '']],
    hidden: ['jo_id', 'company_id'] },
};
const ROLES = ['Doc Officer', 'CEO', 'Admin'];
const WORK_CATEGORIES = ['Construction', 'Caregiving', 'Manufacturing', 'Agriculture', 'Food Service'];
const PROGRAM_TYPES = ['SSW1', 'SSW2', 'TITP1', 'TITP2', 'TITP3'];

// Pure, so it can be tested without Google Sheets. Every value is text (see asText).
//   supabase  { task_id: row }                 baselines { sheetKey: { task_id: row } }
//   sheets    { sheetKey: { task_id: row } }   ownerKeys { editor_id: sheetKey }
// Returns final { task_id: row }, changes { sheetKey: [task_id] } (what to send to Supabase,
// by the sheet it came from), conflicts and rejected (new rows missing a required field).
function mergeTasks(supabase, baselines, sheets, ownerKeys) {
  const final = {}, changes = {}, conflicts = [], rejected = [];
  const admin = sheets[ADMIN_KEY] || {};
  const ids = {};
  Object.keys(supabase).forEach(id => { ids[id] = true; });
  Object.keys(admin).forEach(id => { ids[id] = true; });
  // An officer can add a new task only for themselves.
  Object.keys(ownerKeys).forEach(owner => {
    const rows = sheets[ownerKeys[owner]] || {};
    Object.keys(rows).forEach(id => { if (supabase[id] || rows[id].editor_id === owner) ids[id] = true; });
  });

  Object.keys(ids).forEach(id => {
    const agreed = supabase[id];
    const a = admin[id];
    const ownerKey = agreed ? ownerKeys[agreed.editor_id]
      : Object.keys(ownerKeys).map(o => ownerKeys[o]).find(k => sheets[k] && sheets[k][id] &&
          ownerKeys[sheets[k][id].editor_id] === k);
    const o = ownerKey && sheets[ownerKey] ? sheets[ownerKey][id] : undefined;

    if (!agreed) {
      const from = a || o;
      const row = {};
      TASK_FIELDS.forEach(f => { row[f] = from[f] === undefined ? '' : from[f]; });
      const key = a ? ADMIN_KEY : ownerKey;
      if (REQUIRED_TASK_FIELDS.some(f => row[f] === '')) { rejected.push({ task_id: id, source: key }); return; }
      final[id] = row;
      (changes[key] = changes[key] || []).push(id);
      return;
    }

    const before = (key, f) => {
      const b = baselines[key] && baselines[key][id];
      return b && f in b ? b[f] : agreed[f];
    };
    const row = {};
    let fromAdmin = false, fromOwner = false;
    TASK_FIELDS.forEach(f => {
      row[f] = agreed[f];
      const blankBad = v => v === '' && REQUIRED_TASK_FIELDS.indexOf(f) >= 0;
      const ownerEdit = o && OWNER_FIELDS.indexOf(f) >= 0 && f in o && o[f] !== before(ownerKey, f) && !blankBad(o[f]);
      const adminEdit = a && f in a && a[f] !== before(ADMIN_KEY, f) && !blankBad(a[f]);
      // Changed in Kiroku since this sheet was last in step, and the sheet was edited too.
      const kirokuEdit = ownerEdit && agreed[f] !== before(ownerKey, f);
      if (adminEdit) {
        if (ownerEdit && o[f] !== a[f]) {
          conflicts.push({ task_id: id, field: f, kept: a[f], lost: o[f], source: ownerKey, by: 'Admin' });
        }
        row[f] = a[f];
        if (row[f] !== agreed[f]) fromAdmin = true;
      } else if (kirokuEdit) {
        if (o[f] !== agreed[f]) {
          conflicts.push({ task_id: id, field: f, kept: agreed[f], lost: o[f], source: ownerKey, by: 'Kiroku' });
        }
      } else if (ownerEdit) {
        row[f] = o[f];
        if (row[f] !== agreed[f]) fromOwner = true;
      }
    });
    final[id] = row;
    if (fromAdmin || fromOwner) {
      const key = fromAdmin ? ADMIN_KEY : ownerKey;
      (changes[key] = changes[key] || []).push(id);
    }
  });
  return { final: final, changes: changes, conflicts: conflicts, rejected: rejected };
}

function supabaseHeaders(key) {
  return { apikey: key, Authorization: 'Bearer ' + key };
}

// Every row of a table (PostgREST returns at most 1000 per request).
function readAllRows(url, key, path) {
  const all = [];
  for (let offset = 0; ; offset += 1000) {
    const res = UrlFetchApp.fetch(url + '/rest/v1/' + path + (path.indexOf('?') < 0 ? '?' : '&') + 'limit=1000&offset=' + offset, {
      headers: supabaseHeaders(key), muteHttpExceptions: true,
    });
    if (res.getResponseCode() >= 300) throw new Error(res.getContentText());
    const page = JSON.parse(res.getContentText());
    all.push.apply(all, page);
    if (page.length < 1000) return all;
  }
}

function taskSources(props) {
  return SOURCES.filter(src => (src.owner || src.key === ADMIN_KEY) && props.getProperty(src.idProp));
}

// Names and numbers people see, and the IDs behind them.
function readTaskContext(url, key) {
  const ctx = { numberToJo: {}, joToNumber: {}, joToWorker: {}, deploy: {}, nameToId: {}, idToName: {}, officerNames: [], nextOrder: {} };
  readAllRows(url, key, 'job_orders?select=jo_id,jo_number,worker_name,target_deployment_date').forEach(j => {
    ctx.numberToJo[j.jo_number] = j.jo_id;
    ctx.joToNumber[j.jo_id] = j.jo_number;
    ctx.joToWorker[j.jo_id] = j.worker_name;
    ctx.deploy[j.jo_id] = j.target_deployment_date;
  });
  readAllRows(url, key, 'users?select=user_id,name,role').forEach(u => {
    ctx.idToName[u.user_id] = u.name;
    if (u.role === 'Doc Officer') {
      ctx.nameToId[u.name] = u.user_id;
      ctx.officerNames.push(u.name);
    }
  });
  ctx.officerNames.sort();
  return ctx;
}

function readAgreedTasks(url, key, ctx) {
  const agreed = {};
  readAllRows(url, key, 'tasks?select=*&order=task_id').forEach(t => {
    const r = {};
    TASK_FIELDS.forEach(f => { r[f] = asText(t[f], f); });
    agreed[t.task_id] = r;
    const slot = t.jo_id + '|' + t.track;
    ctx.nextOrder[slot] = Math.max(ctx.nextOrder[slot] || 1, Number(t.sort_order) + 1);
  });
  return agreed;
}

function readBaselines(url, key) {
  const baselines = {};
  readAllRows(url, key, 'sheet_sync_state?select=*').forEach(b => {
    (baselines[b.source] = baselines[b.source] || {})[b.task_id] = b.fields;
  });
  return baselines;
}

// One sheet's Tasks tab as text rows, using the IDs behind the friendly columns.
// A value that makes no sense (an unknown Job Order, a date that is not a date) is left out and
// noted on the row. A new row gets its permanent task_id here, written back at once, so it can
// never be added twice. The first row of a task_id counts; a repeat is ignored.
function readTaskSheet(sheetId, ctx, src, dryRun) {
  const ss = SpreadsheetApp.openById(sheetId);
  const sh = ss.getSheetByName('Tasks');
  if (!sh) throw new Error('Tab "Tasks" not found in sheet ' + sheetId);
  const tz = ss.getSpreadsheetTimeZone();
  const range = sh.getDataRange();
  const values = range.getValues();
  const notes = range.getNotes();
  const head = values[0].map(h => String(h).trim());
  const col = name => head.indexOf(name);
  if (col('Status') < 0 || col('task_id') < 0) throw new Error(src.key + ': run setupFriendlySheets first.');

  const rows = {}, rowNum = {};
  values.forEach((row, i) => {
    if (i === 0) return;
    if (!row.some(c => c !== '')) return;
    const problems = [];
    const r = {};
    const shown = name => cellText2(row[col(name)]);

    r.track = shown('Track').toUpperCase();
    if (TASK_TRACKS.indexOf(r.track) < 0) { problems.push('Track must be TIO, OTIT or COE'); delete r.track; }
    r.task_name = shown('Task Description');
    r.remarks = shown('Remarks');
    const status = TASK_STATUSES.find(s => s.toLowerCase() === shown('Status').toLowerCase());
    if (status) r.status = status; else if (shown('Status')) problems.push('Status must be Pending, In Progress or Completed');
    const due = asText(row[col('Due Date')], 'due_date', tz);
    if (/^\d{4}-\d{2}-\d{2}$/.test(due) && !isNaN(Date.parse(due))) r.due_date = due;
    else if (due) problems.push('Due Date is not a date');
    const jo = ctx.numberToJo[shown('Job Order No.')];
    if (jo) r.jo_id = jo; else if (shown('Job Order No.')) problems.push('Job Order No. ' + shown('Job Order No.') + ' is not in the Masterlist');
    if (src.owner) {
      r.editor_id = src.owner;
    } else {
      const ed = ctx.nameToId[shown('Assigned Officer')];
      if (ed) r.editor_id = ed; else problems.push('Assigned Officer must be a Doc Officer');
    }

    let id = shown('task_id');
    if (!id) {
      const missing = [];
      if (!r.jo_id) missing.push('Job Order No.');
      if (!r.track) missing.push('Track');
      if (!r.task_name) missing.push('Task Description');
      if (!r.due_date) missing.push('Due Date');
      if (!r.editor_id) missing.push('Assigned Officer');
      if (missing.length) {
        problems.push('Not added yet. Fill in: ' + missing.join(', '));
        noteRow(sh, i, notes[i][0], problems, dryRun);
        return;
      }
      id = r.jo_id + '-' + r.track + '-n' + Utilities.getUuid().slice(0, 8);
      if (!dryRun) sh.getRange(i + 1, col('task_id') + 1).setValue(id);
    }
    r.sort_order = shown('order');
    r.offset_days = shown('offset_days');
    // A new row, or one whose first sync failed: these are worked out once and kept in the row,
    // so a retry sends exactly the same task.
    if (!r.sort_order && r.jo_id && r.track) {
      const slot = r.jo_id + '|' + r.track;
      r.sort_order = String(ctx.nextOrder[slot] || 1);
      ctx.nextOrder[slot] = Number(r.sort_order) + 1;
      if (!dryRun) sh.getRange(i + 1, col('order') + 1).setValue(Number(r.sort_order));
    }
    if (!r.offset_days && r.jo_id && r.due_date) {
      r.offset_days = String(Math.round((Date.parse(r.due_date) - Date.parse(ctx.deploy[r.jo_id])) / 86400000));
      if (!dryRun) sh.getRange(i + 1, col('offset_days') + 1).setValue(Number(r.offset_days));
    }
    if (!r.status && !shown('Status')) r.status = 'Pending';
    noteRow(sh, i, notes[i][0], problems, dryRun);
    if (id in rows) return;
    rows[id] = r;
    rowNum[id] = i;
  });
  return { ss: ss, sh: sh, tz: tz, head: head, values: values, rows: rows, rowNum: rowNum };
}

// Text that starts with = + - or @ would run as a formula in Google Sheets (IMPORTDATA, for example, can send the
// sheet's data to another website). Such text is written with a leading apostrophe, which Sheets shows as plain text;
// reading the cell back gives the text without the apostrophe, so the sync sees no change.
function sheetSafe(v) {
  return typeof v === 'string' && /^[=+\-@]/.test(v) && !/^[-+]?\d+(\.\d+)?$/.test(v) && v !== '-' ? "'" + v : v;
}
function sheetSafeRows(rows) { return rows.map(r => r.map(sheetSafe)); }

function cellText2(v) {
  return String(v === null || v === undefined ? '' : v).trim();
}

// Shows what is wrong with a row on its first cell, and clears that once it is fixed.
function noteRow(sh, i, current, problems, dryRun) {
  if (dryRun) return;
  const text = problems.length ? NOTE_PREFIX + problems.join('. ') : '';
  if (text === current || (!text && current.indexOf(NOTE_PREFIX) !== 0)) return;
  const c = sh.getRange(i + 1, 1);
  c.setNote(text);
  c.setBackground(text ? '#FBECEB' : null);
}

function taskRowForSupabase(row, id) {
  const out = { task_id: id };
  TASK_FIELDS.forEach(f => { out[f] = cell(row[f], f); });
  return out;
}

function syncTasks(url, key, props) {
  const sources = taskSources(props);
  const ownerKeys = {};
  SOURCES.filter(src => src.owner).forEach(src => { ownerKeys[src.owner] = src.key; });

  const ctx = readTaskContext(url, key);
  const agreed = readAgreedTasks(url, key, ctx);
  const baselines = readBaselines(url, key);

  // Read every sheet before anything is written, so all of them are compared with the same state.
  const read = {}, rowsByKey = {};
  sources.forEach(src => {
    read[src.key] = readTaskSheet(props.getProperty(src.idProp), ctx, src, false);
    rowsByKey[src.key] = read[src.key].rows;
  });

  const merged = mergeTasks(agreed, baselines, rowsByKey, ownerKeys);
  merged.rejected.forEach(r => Logger.log(r.source + ': task ' + r.task_id + ' is missing a required field; not added'));

  // Supabase first: if this fails nothing else changes, and the next run tries again.
  Object.keys(merged.changes).forEach(source => {
    const res = UrlFetchApp.fetch(url + '/rest/v1/rpc/sync_import', {
      method: 'post', contentType: 'application/json', headers: supabaseHeaders(key),
      payload: JSON.stringify({ p_source: source, p_payload: { tasks: merged.changes[source].map(id => taskRowForSupabase(merged.final[id], id)) } }),
      muteHttpExceptions: true,
    });
    if (res.getResponseCode() >= 300) {
      logSyncFailure(url, key, source, res.getContentText());
      throw new Error(source + ' tasks failed: ' + res.getContentText());
    }
    Logger.log(source + ' tasks: ' + res.getContentText());
  });
  merged.conflicts.forEach(c => {
    logTaskConflict(url, key, c);
    noteConflict(read[c.source], c);
  });

  // done and done_at are set by Supabase, so they are read after the import.
  const doneState = {};
  readAllRows(url, key, 'tasks?select=task_id,done,done_at').forEach(t => { doneState[t.task_id] = t; });

  sources.forEach(src => {
    // A sheet that could not be written keeps its old baseline, so the next run writes it again.
    try {
      writeTaskSheet(read[src.key], merged.final, doneState, ctx, src);
      saveBaselines(url, key, src.key, src.owner ? ownRows(merged.final, src.owner) : merged.final, baselines[src.key] || {});
    } catch (e) {
      logSyncFailure(url, key, src.key, 'Could not write the Tasks tab: ' + e);
      Logger.log(src.key + ': could not write the Tasks tab: ' + e);
    }
  });
  writeAssignedOfficers(props, merged.final, ctx.idToName);
}

function ownRows(final, owner) {
  const out = {};
  Object.keys(final).forEach(id => { if (final[id].editor_id === owner) out[id] = final[id]; });
  return out;
}

// The value of one column for one task, as it should appear in the sheet.
function taskCellValue(h, id, row, doneState, ctx) {
  if (h === 'task_id') return id;
  if (h === 'Job Order No.') return ctx.joToNumber[row.jo_id] || '';
  if (h === 'Worker Name') return ctx.joToWorker[row.jo_id] || '';
  if (h === 'Assigned Officer') return ctx.idToName[row.editor_id] || row.editor_id;
  const st = doneState[id] || {};
  if (h === 'done') return row.status === 'Completed';
  if (h === 'done_at') return asText(st.done_at, 'done_at');
  const f = COLUMN_FIELD[h];
  return f ? row[f] : undefined;
}

// A Doc Officer's sheet holds their own tasks; the Admin Masterlist holds all of them.
// Writes only the cells that differ, adds the rows the sheet is missing, and removes rows
// that now belong to another officer (the task itself stays in Supabase and their sheet).
function writeTaskSheet(s, final, doneState, ctx, src) {
  const head = s.head;
  const wanted = src.owner ? ownRows(final, src.owner) : final;
  let changed = 0;
  const added = [], remove = [];
  Object.keys(s.rowNum).forEach(id => { if (!(id in wanted) && id in final) remove.push(s.rowNum[id] + 1); });
  Object.keys(wanted).sort().forEach(id => {
    const row = wanted[id];
    const i = s.rowNum[id];
    if (i === undefined) {
      added.push(head.map(h => {
        const v = taskCellValue(h, id, row, doneState, ctx);
        return v === undefined ? '' : v;
      }));
      return;
    }
    head.forEach((h, j) => {
      if (!h || h === 'task_id') return;
      const v = taskCellValue(h, id, row, doneState, ctx);
      if (v === undefined) return;
      const f = COLUMN_FIELD[h] || h;
      if (asText(s.values[i][j], f, s.tz) !== asText(v, f)) {
        s.sh.getRange(i + 1, j + 1).setValue(sheetSafe(v));
        changed++;
      }
    });
  });
  if (added.length) s.sh.getRange(s.values.length + 1, 1, added.length, head.length).setValues(sheetSafeRows(added));
  remove.sort((a, b) => b - a).forEach(r => s.sh.deleteRow(r));
  setJobOrderDropdown(s.sh, head, ctx);
  Logger.log(src.key + ': wrote ' + changed + ' cells, added ' + added.length + ', moved away ' + remove.length);
}

function setJobOrderDropdown(sh, head, ctx) {
  const numbers = Object.keys(ctx.numberToJo).sort();
  if (!numbers.length) return;
  sh.getRange(2, head.indexOf('Job Order No.') + 1, sh.getMaxRows() - 1, 1).setDataValidation(
    SpreadsheetApp.newDataValidation().requireValueInList(numbers, true).setAllowInvalid(false).build());
}

// Stores what this sheet now holds. Only rows that changed are sent.
function saveBaselines(url, key, source, final, current) {
  const rows = Object.keys(final)
    .filter(id => JSON.stringify(current[id]) !== JSON.stringify(final[id]))
    .map(id => ({ source: source, task_id: id, fields: final[id] }));
  if (!rows.length) return;
  const res = UrlFetchApp.fetch(url + '/rest/v1/sheet_sync_state?on_conflict=source,task_id', {
    method: 'post', contentType: 'application/json',
    headers: Object.assign({ Prefer: 'resolution=merge-duplicates,return=minimal' }, supabaseHeaders(key)),
    payload: JSON.stringify(rows), muteHttpExceptions: true,
  });
  if (res.getResponseCode() >= 300) throw new Error(res.getContentText());
}

// The replaced value stays in event_logs, so nothing is lost silently.
function logTaskConflict(url, key, c) {
  try {
    UrlFetchApp.fetch(url + '/rest/v1/event_logs', {
      method: 'post', contentType: 'application/json',
      headers: Object.assign({ Prefer: 'return=minimal' }, supabaseHeaders(key)),
      payload: JSON.stringify({
        event_type: 'Record Updated', source: 'Google Sheets', action: 'Conflict', module: 'Tasks',
        record_id: c.task_id, field_changed: c.field, old_value: c.lost, new_value: c.kept,
        description: c.by + ' and ' + c.source + ' both changed this field; ' + c.by + '\'s value was kept',
        source_sheet: c.source,
      }),
      muteHttpExceptions: true,
    });
  } catch (e) {
    Logger.log('could not log a task conflict: ' + e);
  }
}

// Tells the officer, on the cell, that their value was replaced and what it was.
function noteConflict(s, c) {
  if (!s) return;
  const i = s.rowNum[c.task_id];
  const name = Object.keys(COLUMN_FIELD).find(h => COLUMN_FIELD[h] === c.field && VISIBLE_COLUMNS.indexOf(h) >= 0);
  if (i === undefined || !name) return;
  s.sh.getRange(i + 1, s.head.indexOf(name) + 1).setNote(
    'Not saved: ' + c.by + ' changed this at the same time. Your value was: ' + c.lost);
}

// Admin Masterlist > JobOrders > assigned_officers: the officers with tasks on each Job Order.
function writeAssignedOfficers(props, final, names) {
  try {
    const sh = SpreadsheetApp.openById(props.getProperty('ADMIN_SHEET_ID')).getSheetByName('JobOrders');
    const values = sh.getDataRange().getValues();
    const head = values[0].map(h => String(h).trim());
    const idCol = head.indexOf('jo_id'), col = head.indexOf('Assigned Officers');
    if (idCol < 0 || col < 0) return;
    const byJo = {};
    Object.keys(final).forEach(id => {
      const r = final[id];
      (byJo[r.jo_id] = byJo[r.jo_id] || {})[names[r.editor_id] || r.editor_id] = true;
    });
    values.forEach((row, i) => {
      if (i === 0) return;
      const text = Object.keys(byJo[String(row[idCol]).trim()] || {}).sort().join(', ');
      if (String(row[col]) !== text) sh.getRange(i + 1, col + 1).setValue(sheetSafe(text));
    });
  } catch (e) {
    Logger.log('could not write assigned_officers: ' + e);
  }
}

// Turns the names people use into the IDs behind them, gives new rows a permanent ID (written back at
// once, so a retry cannot add them twice), and fills in names when only the ID is known. A row that
// cannot be sent yet is noted on the row and left out, so one unfinished row never stops the sync.
function resolveSharedRows(sheetId, payload) {
  const ss = SpreadsheetApp.openById(sheetId);
  const tabOf = { users: 'Users', kumiai: 'Kumiai', companies: 'Companies', job_orders: 'JobOrders' };
  const nextId = (rows, layout) => {
    const top = rows.reduce((max, r) => {
      const m = new RegExp('^' + layout.idPrefix + '(\\d+)$').exec(String(r[layout.idField] || ''));
      return m ? Math.max(max, Number(m[1])) : max;
    }, 0) + 1;
    // j9 is skipped: applyMasterlistFixes() drops it from every sync.
    return layout.idPrefix + (layout.idPrefix === 'j' && top === 9 ? 10 : top);
  };
  const byName = (rows, idField) => {
    const out = { id: {}, name: {} };
    rows.forEach(r => { if (r.name) { out.id[r.name] = r[idField]; out.name[r[idField]] = r.name; } });
    return out;
  };

  Object.keys(tabOf).forEach(table => {
    const tab = tabOf[table], layout = SHARED_COLUMNS[tab], rows = payload[table];
    const sh = ss.getSheetByName(tab);
    const head = sh.getRange(1, 1, 1, sh.getLastColumn()).getValues()[0].map(h => String(h).trim());
    const put = (row, name, value) => sh.getRange(row, head.indexOf(name) + 1).setValue(value);
    const kumiai = byName(payload.kumiai || [], 'kumiai_id'), companies = byName(payload.companies || [], 'company_id');
    const seen = {};

    payload[table] = rows.filter(r => {
      const problems = [];
      const link = (nameField, idField, list, label, shownAs) => {
        if (r[nameField]) {
          if (list.id[r[nameField]]) r[idField] = list.id[r[nameField]];
          else problems.push(label + ' ' + r[nameField] + ' is not on the ' + label + ' list');
        } else if (r[idField] && list.name[r[idField]]) {
          put(r._row, shownAs, list.name[r[idField]]);
        } else if (!r[idField]) {
          problems.push('Choose a ' + label);
        }
        delete r[nameField];
      };
      if (table === 'companies') link('kumiai_name', 'kumiai_id', kumiai, 'Kumiai', 'Kumiai');
      if (table === 'job_orders') {
        link('company_name', 'company_id', companies, 'Company', 'Company');
        if (!r.jo_number) problems.push('Fill in the Job Order No.');
        if (!r.worker_name) problems.push('Fill in the Worker Name');
        if (!r.target_deployment_date) problems.push('Fill in the Target Deployment Date');
        if (r.jo_number) {
          if (seen[r.jo_number]) problems.push('Job Order No. ' + r.jo_number + ' is already on this tab');
          seen[r.jo_number] = true;
        }
        if (r.active === null || r.active === undefined) r.active = true;
      } else if (!r.name) {
        problems.push('Fill in the name');
      }
      if (table === 'users' && !r.role) problems.push('Choose a Role');
      if (table === 'users' && r.role && ROLES.indexOf(String(r.role).trim()) < 0) problems.push('Role must be ' + ROLES.join(', '));
      if (table === 'users' && r.email && !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(String(r.email).trim())) problems.push('Email ' + r.email + ' is not an email address');

      const first = sh.getRange(r._row, 1);
      const note = problems.length ? NOTE_PREFIX + 'Not saved yet. ' + problems.join('. ') : '';
      if (first.getNote() !== note && (note || first.getNote().indexOf(NOTE_PREFIX) === 0)) {
        first.setNote(note);
        first.setBackground(note ? '#FBECEB' : null);
      }
      if (problems.length) return false;
      if (!r[layout.idField]) {
        r[layout.idField] = nextId(rows, layout);
        put(r._row, layout.idField, r[layout.idField]);
      }
      return true;
    });
    payload[table].forEach(r => { delete r._row; });
  });
}

// ---------------------------------------------------------------- Friendly Tasks tabs
// Run once, before the first sync of this version, then again whenever the layout looks wrong.
// Changes the Tasks tab of all five sheets to the friendly columns. First it copies each tab to a
// hidden "Backup Tasks <date>" tab, so nothing can be lost. Technical columns stay, hidden and locked.
// Unsynced edits in the sheets are kept: the first sync picks them up as usual.
function setupFriendlySheets() {
  const props = PropertiesService.getScriptProperties();
  const url = props.getProperty('SUPABASE_URL');
  const key = props.getProperty('SUPABASE_SERVICE_KEY');
  masterlistId();
  const lock = LockService.getScriptLock();
  lock.waitLock(60000);
  try {
    const ctx = readTaskContext(url, key);
    const agreed = readAgreedTasks(url, key, ctx);
    setupSharedTabs(SpreadsheetApp.openById(masterlistId()));
    taskSources(props).forEach(src => {
      const ss = SpreadsheetApp.openById(props.getProperty(src.idProp));
      const sh = ss.getSheetByName('Tasks') || ss.insertSheet('Tasks');
      const legacy = sh.getLastRow() > 0 && sh.getRange(1, 1, 1, sh.getLastColumn()).getValues()[0]
        .map(h => String(h).trim()).indexOf('Status') < 0;
      if (legacy) {
        backupTasksTab(ss, sh);
        convertTasksTab(ss, sh, agreed, ctx, src);
      } else if (sh.getLastRow() === 0) {
        sh.getRange(1, 1, 1, VISIBLE_COLUMNS.length + HIDDEN_COLUMNS.length).setValues([VISIBLE_COLUMNS.concat(HIDDEN_COLUMNS)]);
      }
      formatTasksTab(sh, ctx, src);
      if (src.owner) {
        const activity = ss.getSheetByName(ACTIVITY_TAB);
        if (activity) activity.hideSheet();
      }
      Logger.log(src.key + ': Tasks tab ready' + (legacy ? ' (converted, backup kept)' : ''));
    });
  } finally {
    lock.releaseLock();
  }
}

// Users, Kumiai, Companies and JobOrders in everyday words. IDs stay, hidden and locked.
function setupSharedTabs(ss) {
  const rowsOf = tab => {
    const sh = ss.getSheetByName(tab);
    const values = sh.getDataRange().getValues();
    const head = values[0].map(h => String(h).trim());
    return values.slice(1).map(v => { const o = {}; head.forEach((h, i) => { if (h) o[h] = v[i]; }); return o; });
  };
  const names = {};
  ['Kumiai', 'Companies'].forEach(tab => {
    const idField = SHARED_COLUMNS[tab].idField;
    names[tab] = {};
    rowsOf(tab).forEach(r => { if (r[idField] !== undefined) names[tab][cellText2(r[idField])] = cellText2(r.name !== undefined ? r.name : r[tab === 'Kumiai' ? 'Kumiai' : 'Company']); });
  });
  Object.keys(SHARED_COLUMNS).forEach(tab => {
    const layout = SHARED_COLUMNS[tab];
    const sh = ss.getSheetByName(tab);
    const values = sh.getDataRange().getValues();
    const old = values[0].map(h => String(h).trim());
    const shown = layout.columns.map(c => c[0]);
    if (old.indexOf(shown[0]) < 0) {
      backupTasksTab(ss, sh, 'Backup ' + tab);
      // Any other column is kept, hidden, so nothing is lost.
      const extras = old.filter(h => h && h !== 'assigned_officers' && layout.columns.every(c => c[1] !== h) && layout.hidden.indexOf(h) < 0);
      const head = shown.concat(layout.hidden, extras);
      const rows = values.slice(1).filter(v => v.some(c => c !== '')).map(v => {
        const get = name => { const i = old.indexOf(name); return i < 0 ? '' : v[i]; };
        return head.map(h => {
          const c = layout.columns.find(x => x[0] === h);
          const f = c ? c[1] : h;
          if (f === 'kumiai_name') return names.Kumiai[cellText2(get('kumiai_id'))] || '';
          if (f === 'company_name') return names.Companies[cellText2(get('company_id'))] || '';
          if (h === 'Assigned Officers') return get('assigned_officers');
          return get(f);
        });
      });
      const filter = sh.getFilter();
      if (filter) filter.remove();
      sh.clear();
      sh.getRange(1, 1, rows.length + 1, head.length).setValues([head].concat(rows));
    }
    formatSharedTab(ss, sh, tab);
  });
}

function formatSharedTab(ss, sh, tab) {
  const layout = SHARED_COLUMNS[tab];
  const head = sh.getRange(1, 1, 1, sh.getLastColumn()).getValues()[0].map(h => String(h).trim());
  const col = name => head.indexOf(name) + 1;
  if (sh.getMaxRows() < 300) sh.insertRowsAfter(sh.getMaxRows(), 300 - sh.getMaxRows());
  const rows = sh.getMaxRows() - 1;
  const column = name => sh.getRange(2, col(name), rows, 1);
  const dropdown = list => SpreadsheetApp.newDataValidation().requireValueInList(list, true).setAllowInvalid(false).build();

  sh.setFrozenRows(1);
  sh.getRange(1, 1, sh.getMaxRows(), head.length).setFontFamily('Arial').setFontSize(11).setVerticalAlignment('middle').setFontColor('#1A1D22');
  sh.getRange(1, 1, 1, head.length).setFontWeight('bold').setBackground('#F5F5F7');
  sh.setRowHeight(1, 34);
  layout.columns.forEach(c => sh.setColumnWidth(col(c[0]), c[0] === 'Assigned Officers' ? 280 : 170));

  const listOf = (other, field) => {
    const s = ss.getSheetByName(other);
    const v = s.getDataRange().getValues();
    const i = v[0].map(h => String(h).trim()).indexOf(field);
    return v.slice(1).map(r => cellText2(r[i])).filter(Boolean);
  };
  if (tab === 'Users') column('Role').setDataValidation(dropdown(ROLES));
  if (tab === 'Companies') column('Kumiai').setDataValidation(dropdown(listOf('Kumiai', 'Kumiai')));
  if (tab === 'JobOrders') {
    column('Job Order No.').setNumberFormat('@');
    column('Company').setDataValidation(dropdown(listOf('Companies', 'Company')));
    column('Target Deployment Date').setNumberFormat('yyyy-mm-dd').setHorizontalAlignment('left');
    column('Work Category').setDataValidation(dropdown(WORK_CATEGORIES));
    column('Program Type').setDataValidation(dropdown(PROGRAM_TYPES));
    column('Active').setDataValidation(SpreadsheetApp.newDataValidation().requireCheckbox().build());
  }
  if (!sh.getFilter()) sh.getRange(1, 1, sh.getMaxRows(), head.length).createFilter();

  const firstHidden = col(layout.hidden[0]);
  sh.hideColumns(firstHidden, head.length - firstHidden + 1);
  sh.getProtections(SpreadsheetApp.ProtectionType.RANGE).forEach(p => { if (p.getDescription() === 'Kiroku') p.remove(); });
  const lock = range => {
    const p = range.protect().setDescription('Kiroku');
    p.removeEditors(p.getEditors());
    if (p.canDomainEdit()) p.setDomainEdit(false);
  };
  lock(sh.getRange(1, 1, 1, head.length));
  lock(sh.getRange(2, firstHidden, rows, head.length - firstHidden + 1));
  if (tab === 'JobOrders') lock(column('Assigned Officers'));
}

function backupTasksTab(ss, sh, prefix) {
  const name = (prefix || 'Backup Tasks') + ' ' + Utilities.formatDate(new Date(), TZ, 'yyyy-MM-dd');
  if (ss.getSheetByName(name)) return;
  sh.copyTo(ss).setName(name).hideSheet();
}

function convertTasksTab(ss, sh, agreed, ctx, src) {
  const tz = ss.getSpreadsheetTimeZone();
  const values = sh.getDataRange().getValues();
  const old = values[0].map(h => String(h).trim());
  const get = (row, name) => { const c = old.indexOf(name); return c < 0 ? '' : row[c]; };
  const head = VISIBLE_COLUMNS.concat(HIDDEN_COLUMNS);
  const rows = [];
  values.slice(1).forEach(row => {
    const id = cellText2(get(row, 'task_id'));
    if (!id) return;
    const editor = cellText2(get(row, 'editor_id'));
    if (src.owner && editor !== src.owner) return;
    const done = asText(get(row, 'done'), 'done') === 'TRUE';
    // Keep In Progress set in Kiroku: the old tab can only say done or not done.
    const known = agreed[id];
    const status = known && (known.status === 'Completed') === done ? known.status : (done ? 'Completed' : 'Pending');
    const out = {
      'Job Order No.': ctx.joToNumber[cellText2(get(row, 'jo_id'))] || '', 'Worker Name': ctx.joToWorker[cellText2(get(row, 'jo_id'))] || '',
      'Track': cellText2(get(row, 'track')),
      'Task Description': cellText2(get(row, 'task_name')), 'Due Date': asText(get(row, 'due_date'), 'due_date', tz),
      'Status': status, 'Assigned Officer': ctx.idToName[editor] || editor, 'Remarks': known ? known.remarks : '',
      'task_id': id, 'jo_id': cellText2(get(row, 'jo_id')), 'editor_id': editor, 'order': get(row, 'order'),
      'offset_days': get(row, 'offset_days'), 'done': done, 'done_at': asText(get(row, 'done_at'), 'done_at', tz),
    };
    rows.push(head.map(h => out[h]));
  });
  const filter = sh.getFilter();
  if (filter) filter.remove();
  sh.clear();
  sh.clearNotes();
  sh.setConditionalFormatRules([]);
  sh.getRange(1, 1, sh.getMaxRows(), sh.getMaxColumns()).clearDataValidations();
  if (sh.getMaxColumns() < head.length) sh.insertColumnsAfter(sh.getMaxColumns(), head.length - sh.getMaxColumns());
  sh.getRange(1, 1, rows.length + 1, head.length).setValues([head].concat(rows));
}

function formatTasksTab(sh, ctx, src) {
  const head = sh.getRange(1, 1, 1, sh.getLastColumn()).getValues()[0].map(h => String(h).trim());
  const col = name => head.indexOf(name) + 1;
  if (sh.getMaxRows() < 1000) sh.insertRowsAfter(sh.getMaxRows(), 1000 - sh.getMaxRows());
  const rows = sh.getMaxRows() - 1;
  const column = name => sh.getRange(2, col(name), rows, 1);

  sh.setFrozenRows(1);
  sh.getRange(1, 1, sh.getMaxRows(), head.length).setFontFamily('Arial').setFontSize(11).setVerticalAlignment('middle').setFontColor('#1A1D22');
  sh.getRange(1, 1, 1, head.length).setFontWeight('bold').setBackground('#F5F5F7').setFontColor('#1A1D22');
  sh.setRowHeight(1, 34);
  [['Job Order No.', 120], ['Worker Name', 170], ['Track', 70], ['Task Description', 280], ['Due Date', 110], ['Status', 120], ['Assigned Officer', 150], ['Remarks', 280]]
    .forEach(w => sh.setColumnWidth(col(w[0]), w[1]));
  column('Job Order No.').setNumberFormat('@');
  column('Track').setNumberFormat('@');
  column('Remarks').setWrap(true);
  column('Due Date').setNumberFormat('yyyy-mm-dd').setHorizontalAlignment('left');

  const dropdown = list => SpreadsheetApp.newDataValidation().requireValueInList(list, true).setAllowInvalid(false).build();
  column('Track').setDataValidation(dropdown(TASK_TRACKS));
  column('Status').setDataValidation(dropdown(TASK_STATUSES));
  column('Assigned Officer').setDataValidation(dropdown(ctx.officerNames));
  column('Due Date').setDataValidation(SpreadsheetApp.newDataValidation().requireDate().setAllowInvalid(false).build());
  setJobOrderDropdown(sh, head, ctx);

  const letter = c => sh.getRange(1, c).getA1Notation().replace(/\d+/g, '');
  const due = letter(col('Due Date')), status = letter(col('Status'));
  const paint = (name, text, bg, ink) => SpreadsheetApp.newConditionalFormatRule().whenTextEqualTo(text)
    .setBackground(bg).setFontColor(ink).setRanges([column(name)]).build();
  sh.setConditionalFormatRules([
    paint('Status', 'Pending', '#EFEFF1', '#5D6470'),
    paint('Status', 'In Progress', '#E3ECF8', '#1F57A0'),
    paint('Status', 'Completed', '#E3F3E8', '#1E7B44'),
    SpreadsheetApp.newConditionalFormatRule()
      .whenFormulaSatisfied('=AND($' + due + '2<>"",$' + due + '2<TODAY(),$' + status + '2<>"Completed")')
      .setBackground('#FBECEB').setFontColor('#B3261E').setBold(true).setRanges([column('Due Date')]).build(),
  ]);

  // Filter arrows on every column, hidden ones too, so a row always stays together.
  if (!sh.getFilter()) sh.getRange(1, 1, sh.getMaxRows(), head.length).createFilter();

  const firstHidden = col(HIDDEN_COLUMNS[0]);
  sh.hideColumns(firstHidden, head.length - firstHidden + 1);
  // Everything on an officer's own sheet is theirs, so Assigned Officer would only repeat their name.
  if (src.owner) sh.hideColumns(col('Assigned Officer'), 1);

  // Locks: the header, technical columns and Worker Name for everyone, Assigned Officer for Doc Officers.
  // The sync ignores edits to these anyway; this just stops them being made by accident.
  sh.getProtections(SpreadsheetApp.ProtectionType.RANGE).forEach(p => { if (p.getDescription() === 'Kiroku') p.remove(); });
  const lock = range => {
    const p = range.protect().setDescription('Kiroku');
    p.removeEditors(p.getEditors());
    if (p.canDomainEdit()) p.setDomainEdit(false);
  };
  lock(sh.getRange(1, 1, 1, head.length));
  lock(sh.getRange(2, firstHidden, rows, head.length - firstHidden + 1));
  lock(column('Worker Name'));
  if (src.owner) lock(column('Assigned Officer'));
}

// ---------------------------------------------------------------- Activity tabs
// Each Doc Officer sheet's Activity tab is a copy of that officer's own rows in Supabase
// activity_logs (user_id = the sheet's owner), newest first. The Admin Masterlist's has everyone's.
//   1. Rows typed into the tab (activity_id blank) are added to activity_logs as the sheet's
//      owner (or Admin), through import_sheet_activity() (supabase/09_merge_activity.sql).
//   2. The tab is rewritten from activity_logs: every action the officer took, in the app or the sheet.
// A typed row Supabase refuses (unknown task_id, action_type, date) is kept at the bottom in red.
// Edits to rows that have an activity_id are overwritten: activity_logs rows are permanent.
// Never throws: a failed copy must not stop the sync.
const ACTIVITY_TAB = 'Activity';
const ACTIVITY_COLUMNS = ['task_id', 'action_type', 'date', 'time', 'details', 'user_name',
  'jo_id', 'previous_status', 'updated_status', 'source', 'activity_id'];
// The kinds that can be added from a sheet (Mark Done and the rest need the app).
const SHEET_ACTIVITY_TYPES = ['Follow Up', 'Send Message', 'Log Note', 'Upload'];
const ACTIVITY_NOTE = 'This sheet\'s actions, copied from Supabase activity_logs after every sync (every 5 minutes).\n' +
  'To add an activity: type a new row at the bottom (task_id, action_type, date, time, details) ' +
  'and leave activity_id blank. It is recorded as this sheet\'s user.\n' +
  'Rows with an activity_id cannot be changed: edits to them are put back.';

function syncActivityTabs(url, key, props) {
  const sheets = SOURCES.filter(src => (src.owner || src.activityUser) && props.getProperty(src.idProp))
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
    try { writeActivityTab(s.sheetId, s.src.owner ? logs.filter(r => r.user_id === s.src.owner) : logs, s.keep); }
    catch (e) { Logger.log(s.src.key + ': could not write the Activity tab: ' + e); }
  });
}

// Sends the tab's rows with a blank activity_id. Returns the refused rows (as sheet values) with the reason.
function importTypedActivity(url, key, src, sheetId) {
  const sh = SpreadsheetApp.openById(sheetId).getSheetByName(ACTIVITY_TAB);
  if (!sh || sh.getLastRow() < 2) return [];
  // Date and time are taken as the sheet shows them ("2026-07-29", "10:30"), which is Philippine
  // time. Reading them as Date values would shift them by the sheet's own time zone setting.
  const range = sh.getDataRange();
  const values = range.getValues();
  const shown = range.getDisplayValues();
  const head = values[0].map(h => String(h).trim());
  const typed = [];
  values.slice(1).forEach((row, i) => {
    const obj = {};
    head.forEach((h, j) => {
      if (!h) return;
      obj[h] = (h === 'date' || h === 'time') ? shown[i + 1][j].trim() : cell(row[j], h);
    });
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
    payload: JSON.stringify({ p_source: src.key, p_user: src.owner || src.activityUser, p_rows: typed }),
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

// Sheet header -> Supabase column (the reverse of RENAME.tasks).
const RENAME_BACK = { order: 'sort_order' };

// One value as text, so a sheet cell and a Supabase value can be compared.
// tz = the time zone of the sheet the value came from: a cell date read in another zone
// would shift, and the sync would take that for an edit.
function asText(v, header, tz) {
  if (v === '' || v === null || v === undefined) return '';
  if (typeof v === 'number') return String(v);
  if (v instanceof Date) {
    const zone = tz || TZ;
    if (header === 'time') return Utilities.formatDate(v, zone, 'HH:mm');
    return Utilities.formatDate(v, zone, /_at$/.test(header) ? 'yyyy-MM-dd HH:mm' : 'yyyy-MM-dd');
  }
  const s = String(v).trim();
  if (/^(true|false)$/i.test(s)) return s.toUpperCase();
  // Supabase timestamps ("2026-06-11T01:00:00+00:00") -> Philippine time, like the sheet
  if (/_at$/.test(header) && /^\d{4}-\d{2}-\d{2}T/.test(s)) {
    return Utilities.formatDate(new Date(s), TZ, 'yyyy-MM-dd HH:mm');
  }
  return s;
}

// Read-only copy of the latest event_logs rows, in the Admin Masterlist's "Event Log" tab, in everyday
// words. Supabase stays the real log: the tab is rewritten after every sync and never synced back.
// Never throws: a failed copy must not stop the sync.
const EVENT_LOG_TAB = 'Event Log';
const EVENT_LOG_LIMIT = 500;
const EVENT_LOG_COLUMNS = [
  ['event_at', 'Date & Time', 135], ['event_type', 'What Happened', 135], ['source_sheet', 'From', 120], ['module', 'Section', 95],
  ['record_id', 'Record', 280], ['field_changed', 'Field', 140], ['old_value', 'Old Value', 150],
  ['new_value', 'New Value', 150], ['description', 'Details', 300], ['sync_status', 'Result', 80],
];
const EVENT_FIELD_NAMES = {
  'Jo Number': 'Job Order No.', 'Worker Name': 'Worker Name', 'Target Deployment Date': 'Target Deployment Date', 'Task Name': 'Task Description',
  'Editor Id': 'Assigned Officer', 'Done At': 'Completed At', 'Sort Order': 'Order', 'Offset Days': 'Days From Deployment',
  'Company Id': 'Company', 'Kumiai Id': 'Kumiai',
};

// "doc-officer-2" -> "Doc Officer 2"
function eventSheetName(key) {
  if (!key) return '';
  if (key === 'admin') return 'Admin';
  if (key === 'masterlist') return 'Old Masterlist';
  return String(key).replace(/-/g, ' ').replace(/\b\w/g, c => c.toUpperCase());
}

// The name of a record instead of its code: "j1-TIO-0" -> "JO# 2026-0143 · TIO · Fill Up".
function eventRecordNames(url, key) {
  const names = {};
  const jos = {};
  readAllRows(url, key, 'job_orders?select=jo_id,jo_number').forEach(j => { jos[j.jo_id] = j.jo_number; names[j.jo_id] = 'JO# ' + j.jo_number; });
  readAllRows(url, key, 'tasks?select=task_id,jo_id,track,task_name').forEach(t => {
    names[t.task_id] = 'JO# ' + (jos[t.jo_id] || t.jo_id) + ' · ' + t.track + ' · ' + t.task_name;
  });
  readAllRows(url, key, 'users?select=user_id,name').forEach(u => { names[u.user_id] = u.name; });
  readAllRows(url, key, 'kumiai?select=kumiai_id,name').forEach(k => { names[k.kumiai_id] = k.name; });
  readAllRows(url, key, 'companies?select=company_id,name').forEach(c => { names[c.company_id] = c.name; });
  return names;
}

function writeAdminEventLog(url, key, props) {
  try {
    const query = '?select=' + EVENT_LOG_COLUMNS.map(c => c[0]).join(',') + '&order=event_at.desc&limit=' + EVENT_LOG_LIMIT;
    const res = UrlFetchApp.fetch(url + '/rest/v1/event_logs' + query, { headers: supabaseHeaders(key), muteHttpExceptions: true });
    if (res.getResponseCode() >= 300) throw new Error(res.getContentText());
    const records = eventRecordNames(url, key);

    const rows = JSON.parse(res.getContentText()).map(e => EVENT_LOG_COLUMNS.map(([col]) => {
      const v = e[col];
      if (v === null || v === undefined) return '';
      if (col === 'event_at') return Utilities.formatDate(new Date(v), TZ, 'yyyy-MM-dd HH:mm');
      if (col === 'source_sheet') return eventSheetName(v);
      if (col === 'record_id') return records[v] || String(v);
      if (col === 'field_changed') return EVENT_FIELD_NAMES[v] || String(v);
      return String(v);
    }));
    const head = EVENT_LOG_COLUMNS.map(c => c[1]);
    const values = [head].concat(rows);

    const ss = SpreadsheetApp.openById(props.getProperty('ADMIN_SHEET_ID'));
    const sh = ss.getSheetByName(EVENT_LOG_TAB) || ss.insertSheet(EVENT_LOG_TAB);
    if (sh.getProtections(SpreadsheetApp.ProtectionType.SHEET).length === 0) {
      sh.protect().setDescription('Copied from Supabase after each sync. Edits here are overwritten.').setWarningOnly(true);
    }
    const laidOut = !!sh.getFilter();
    sh.clearContents();
    // Plain text, so a value like "=SUM(...)" from the log is shown, not run as a formula.
    sh.getRange(1, 1, values.length, head.length).setNumberFormat('@').setValues(values);
    if (!laidOut) formatEventLogTab(sh);
  } catch (e) {
    Logger.log('could not write the Event Log tab: ' + e);
  }
}

function formatEventLogTab(sh) {
  const width = EVENT_LOG_COLUMNS.length;
  if (sh.getMaxRows() < EVENT_LOG_LIMIT + 1) sh.insertRowsAfter(sh.getMaxRows(), EVENT_LOG_LIMIT + 1 - sh.getMaxRows());
  sh.setFrozenRows(1);
  sh.getRange(1, 1, sh.getMaxRows(), width).setFontFamily('Arial').setFontSize(11).setVerticalAlignment('middle').setFontColor('#1A1D22');
  sh.getRange(1, 1, 1, width).setFontWeight('bold').setBackground('#F5F5F7');
  sh.setRowHeight(1, 34);
  EVENT_LOG_COLUMNS.forEach((c, i) => sh.setColumnWidth(i + 1, c[2]));
  const result = sh.getRange(2, width, sh.getMaxRows() - 1, 1);
  sh.setConditionalFormatRules([
    SpreadsheetApp.newConditionalFormatRule().whenTextEqualTo('Success').setBackground('#E3F3E8').setFontColor('#1E7B44').setRanges([result]).build(),
    SpreadsheetApp.newConditionalFormatRule().whenTextEqualTo('Failed').setBackground('#FBECEB').setFontColor('#B3261E').setRanges([result]).build(),
  ]);
  if (!sh.getFilter()) sh.getRange(1, 1, sh.getMaxRows(), width).createFilter();
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
  const ss = SpreadsheetApp.openById(sheetId);
  const sh = ss.getSheetByName(tab);
  if (!sh) throw new Error('Tab "' + tab + '" not found in sheet ' + sheetId);

  const tz = ss.getSpreadsheetTimeZone();
  const values = sh.getDataRange().getValues();
  const head = values.shift().map(h => String(h).trim());
  const rename = Object.assign({}, RENAME[table]);
  (SHARED_COLUMNS[tab] ? SHARED_COLUMNS[tab].columns : []).forEach(c => { if (c[1]) rename[c[0]] = c[1]; });
  const derived = DERIVED_COLUMNS[table] || [];
  // Only the columns this tab is meant to have. A column added by hand (for example "auth_user_id", "role" on
  // another tab, or "created_at") is never sent. Supabase checks the same list again (sync_entity, 13_security_hardening.sql).
  const layout = SHARED_COLUMNS[tab];
  const allowed = layout ? layout.hidden.concat(layout.columns.map(c => c[1]).filter(Boolean)) : null;

  return values
    .map((row, i) => [row, i + 2])
    .filter(pair => pair[0].some(c => c !== ''))
    .map(pair => {
      const row = pair[0];
      const obj = { _row: pair[1] };
      head.forEach((h, i) => {
        const field = rename[h] || h;
        if (h && derived.indexOf(h) < 0 && (!allowed || allowed.indexOf(field) >= 0)) obj[field] = cell(row[i], h, tz);
      });
      return obj;
    });
}

// One sheet cell -> JSON value Supabase accepts.
function cell(v, header, tz) {
  if (v === '' || v === null) return null;
  if (v instanceof Date) {
    const zone = tz || TZ;
    if (header === 'time') return Utilities.formatDate(v, zone, 'HH:mm');
    const midnight = v.getHours() === 0 && v.getMinutes() === 0 && v.getSeconds() === 0;
    return Utilities.formatDate(v, zone, midnight ? 'yyyy-MM-dd' : "yyyy-MM-dd'T'HH:mm:ssXXX");
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

// One-time cleanup: each Doc Officer sheet keeps only the tabs it uses (Tasks, Activity).
// The shared tabs live in the Admin Masterlist. Run it once by hand.
// Deleted tabs can be restored from File > Version history.
const UNUSED_OFFICER_TABS = Object.keys(SHARED_TABS).concat(['Event Log']);

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

// One-time setup: fills the Admin Masterlist from the old masterlist and Supabase, so it holds
// every record before the sync starts using it. The old masterlist is only read, never changed.
// Refuses to touch a tab that already has rows, so it cannot overwrite the Admin's data.
function setupAdminSheet() {
  const props = PropertiesService.getScriptProperties();
  const url = props.getProperty('SUPABASE_URL');
  const key = props.getProperty('SUPABASE_SERVICE_KEY');
  const adminId = masterlistId();
  if (adminId === OLD_MASTERLIST_ID) throw new Error('ADMIN_SHEET_ID is the old masterlist. Give the Admin\'s sheet.');

  const admin = SpreadsheetApp.openById(adminId);
  const old = SpreadsheetApp.openById(OLD_MASTERLIST_ID);
  const emptyTab = name => {
    const sh = admin.getSheetByName(name) || admin.insertSheet(name);
    if (sh.getLastRow() > 1) throw new Error('Tab "' + name + '" in the Admin sheet already has rows. Nothing was changed there.');
    return sh;
  };
  ['Users', 'Kumiai', 'Companies', 'JobOrders', 'Tasks'].forEach(name => {
    const sh = admin.getSheetByName(name);
    if (sh && sh.getLastRow() > 1) throw new Error('Tab "' + name + '" in the Admin sheet already has rows. Nothing was copied.');
  });
  admin.setSpreadsheetTimeZone(TZ);

  Object.keys(SHARED_TABS).forEach(name => {
    const values = old.getSheetByName(name).getDataRange().getValues();
    const head = values[0].map(h => String(h).trim());
    if (name === 'Users' && head.indexOf('email') < 0) {
      values.forEach((row, i) => row.push(i === 0 ? 'email' : ''));
      head.push('email');
    }
    if (name === 'Users' && !values.some(row => String(row[head.indexOf('user_id')]).trim() === ADMIN_USER_ID)) {
      values.push(head.map(h => ({ user_id: ADMIN_USER_ID, name: 'Admin', role: 'Admin' }[h] || '')));
    }
    if (name === 'JobOrders' && head.indexOf('assigned_officers') < 0) {
      values.forEach((row, i) => row.push(i === 0 ? 'assigned_officers' : ''));
    }
    emptyTab(name).getRange(1, 1, values.length, values[0].length).setValues(values);
    admin.getSheetByName(name).getRange(1, 1, 1, values[0].length).setFontWeight('bold');
    admin.getSheetByName(name).setFrozenRows(1);
  });

  const names = {};
  readAllRows(url, key, 'users?select=user_id,name').forEach(u => { names[u.user_id] = u.name; });
  const taskHead = ['task_id', 'jo_id', 'track', 'task_name', 'order', 'offset_days', 'editor_id', 'due_date', 'done', 'done_at', 'assigned_officer'];
  const taskRows = readAllRows(url, key, 'tasks?select=*&order=task_id').map(t => taskHead.map(h => {
    if (h === 'assigned_officer') return names[t.editor_id] || t.editor_id || '';
    const f = RENAME_BACK[h] || h;
    return f === 'done' ? t[f] === true : asText(t[f], f);
  }));
  const taskSh = emptyTab('Tasks');
  taskSh.getRange(1, 1, taskRows.length + 1, taskHead.length).setValues([taskHead].concat(taskRows));
  taskSh.getRange(1, 1, 1, taskHead.length).setFontWeight('bold');
  taskSh.setFrozenRows(1);
  Logger.log('Admin Masterlist filled: ' + taskRows.length + ' tasks. Next: run setupFriendlySheets.');
}
