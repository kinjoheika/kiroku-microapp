-- Kiroku V4 — sync from Google Sheets into Supabase.
-- Run after 01_schema.sql and 04_event_logs.sql (in the SQL Editor), before the first sync.
--
-- sync_import(source, payload) is called by apps-script/Sync.gs with the
-- service_role key. payload is { "users": [rows], "tasks": [rows], ... } where
-- each row is an object keyed by table column name.
--
-- Per row:
--   new key            -> insert, log 'Record Created' in event_logs
--   key exists, changed-> update only the changed fields, log one 'Record Updated' per field
--   key exists, same   -> nothing (no write, no log)
-- So re-running the sync with unchanged sheets adds no rows and no log entries.

-- ---------------------------------------------------------------- one table
create or replace function public.sync_entity(
  p_source text, p_run bigint, p_entity text, p_key text, p_rows jsonb
) returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  r        jsonb;
  k        text;
  old_row  jsonb;
  norm     jsonb;
  cols     text;
  f        text;
  changed  boolean;
  n_ins    int := 0;
  n_upd    int := 0;
  n_same   int := 0;
begin
  for r in select value from jsonb_array_elements(p_rows) loop
    k := r->>p_key;
    if k is null then
      raise exception 'sync %: row is missing key column %', p_entity, p_key;
    end if;

    execute format('select to_jsonb(t) from public.%I t where t.%I = $1', p_entity, p_key)
      into old_row using k;

    -- the incoming row as the table would store it (types converted by Postgres),
    -- so "2026-06-11" vs "2026-06-11" and "TRUE" vs true compare equal
    execute format('select to_jsonb(x) from jsonb_populate_record(null::public.%I, $1) x', p_entity)
      into norm using r;

    select string_agg(format('%I', c.name), ', ') into cols
      from jsonb_object_keys(r) as c(name);

    if old_row is null then
      execute format(
        'insert into public.%1$I (%2$s) select %2$s from jsonb_populate_record(null::public.%1$I, $1)',
        p_entity, cols) using r;
      insert into public.event_logs (event_type, source, action, module, record_id, description, source_sheet)
        values ('Record Created', 'Google Sheets', 'Create', initcap(replace(p_entity, '_', ' ')), k,
                initcap(replace(p_entity, '_', ' ')) || ' record added', p_source);
      n_ins := n_ins + 1;
    else
      changed := false;
      for f in select c.name from jsonb_object_keys(r) as c(name) loop
        if old_row->>f is distinct from norm->>f then
          insert into public.event_logs
            (event_type, source, action, module, record_id, field_changed, old_value, new_value, description, source_sheet)
          values ('Record Updated', 'Google Sheets', 'Update', initcap(replace(p_entity, '_', ' ')), k,
                  initcap(replace(f, '_', ' ')), old_row->>f, norm->>f,
                  initcap(replace(f, '_', ' ')) || ' updated', p_source);
          changed := true;
        end if;
      end loop;

      if changed then
        execute format(
          'update public.%1$I t set (%2$s) = (select %2$s from jsonb_populate_record(null::public.%1$I, $1)) where t.%3$I = $2',
          p_entity, cols, p_key) using r, k;
        n_upd := n_upd + 1;
      else
        n_same := n_same + 1;
      end if;
    end if;
  end loop;

  return jsonb_build_object('inserted', n_ins, 'updated', n_upd, 'unchanged', n_same);
end $$;

-- ---------------------------------------------------------------- whole sync
create or replace function public.sync_import(p_source text, p_payload jsonb)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_run   bigint;
  t       text;
  key_col text;
  res     jsonb := '{}'::jsonb;
begin
  insert into public.sync_runs (source_key) values (p_source) returning run_id into v_run;

  -- parents before children, so foreign keys always resolve.
  -- Activity is not synced here: rows typed into a sheet go to activity_logs through
  -- import_sheet_activity() (09_merge_activity.sql). An 'activity' key in the payload is ignored.
  foreach t in array array['users','kumiai','companies','job_orders','tasks'] loop
    if p_payload ? t then
      key_col := case t
        when 'users'      then 'user_id'
        when 'kumiai'     then 'kumiai_id'
        when 'companies'  then 'company_id'
        when 'job_orders' then 'jo_id'
        when 'tasks'      then 'task_id'
      end;
      res := res || jsonb_build_object(t, public.sync_entity(p_source, v_run, t, key_col, p_payload -> t));
    end if;
  end loop;

  update public.sync_runs set status = 'succeeded', finished_at = now(), counts = res
    where run_id = v_run;

  -- Only log a sync when something changed, so the page is not flooded every 5 minutes.
  if exists (select 1 from jsonb_each(res) e
             where (e.value->>'inserted')::int + (e.value->>'updated')::int > 0) then
    insert into public.event_logs (event_type, source, action, module, description, source_sheet)
      values ('Sync Completed', 'Google Sheets', 'Sync', 'Sync', 'Sheet changes synced to Supabase', p_source);
  end if;

  return jsonb_build_object('run_id', v_run, 'counts', res);
end $$;

-- Only the service_role key may run a sync.
revoke execute on function public.sync_entity(text, bigint, text, text, jsonb) from public, anon, authenticated;
revoke execute on function public.sync_import(text, jsonb) from public, anon, authenticated;
grant  execute on function public.sync_import(text, jsonb) to service_role;
