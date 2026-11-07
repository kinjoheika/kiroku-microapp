-- Kiroku V4 — Supabase schema
-- Mirrors the Google Sheet tabs (Users, Kumiai, Companies, JobOrders, Tasks, Activity)
-- and adds sync_runs. The change log is event_logs (04_event_logs.sql). IDs keep the sheet's text IDs (u1, k1, c1, j1,
-- j1-TIO-0) so existing data and the UI can map over without remapping.
--
-- Run once in: Supabase dashboard > SQL Editor > New query > paste > Run.
-- Then run 02_seed.sql (sample data) OR let apps-script/Sync.gs load the real sheets.

-- ---------------------------------------------------------------- users
create table public.users (
  user_id      text primary key,                 -- u1, u2 ...
  name         text not null,
  role         text not null,                    -- 'Doc Officer', 'CEO', 'Admin'
  auth_user_id uuid unique references auth.users(id) on delete set null,
  created_at   timestamptz not null default now()
);

-- ---------------------------------------------------------------- kumiai
create table public.kumiai (
  kumiai_id  text primary key,                   -- k1, k2 ...
  name       text not null,
  created_at timestamptz not null default now()
);

-- ---------------------------------------------------------------- companies
create table public.companies (
  company_id text primary key,                   -- c1, c2 ...
  kumiai_id  text not null references public.kumiai(kumiai_id),
  name       text not null,
  created_at timestamptz not null default now()
);
create index on public.companies (kumiai_id);

-- ---------------------------------------------------------------- job_orders
create table public.job_orders (
  jo_id                  text primary key,       -- j1, j2 ...
  jo_number              text not null unique,   -- 2026-0143
  company_id             text not null references public.companies(company_id),
  worker_name            text not null,
  target_deployment_date date not null,
  work_category          text,
  program_type           text,
  active                 boolean not null default true,
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now()
);
create index on public.job_orders (company_id);

-- ---------------------------------------------------------------- tasks
-- One row per checklist gate. Sheet column `order` is stored as `sort_order`
-- (ORDER is a reserved word in SQL); Sync.gs does the rename.
create table public.tasks (
  task_id     text primary key,                  -- j1-TIO-0
  jo_id       text not null references public.job_orders(jo_id) on delete cascade,
  track       text not null check (track in ('TIO','OTIT','COE')),
  task_name   text not null,
  sort_order  int  not null,
  offset_days int  not null,
  editor_id   text references public.users(user_id),
  due_date    date not null,
  done        boolean not null default false,
  done_at     timestamptz,
  updated_at  timestamptz not null default now()
);
create index on public.tasks (jo_id);
create index on public.tasks (editor_id);

-- ---------------------------------------------------------------- activity
-- Follow-ups, messages, notes and uploads against a task.
-- activity_key = task_id|type|date|time for rows imported from the sheet, so a
-- repeated sync finds the same row instead of inserting a duplicate.
-- UI-created rows leave it null (unique allows many nulls).
create table public.activity (
  activity_id   bigint generated always as identity primary key,
  activity_key  text unique,
  task_id       text not null references public.tasks(task_id) on delete cascade,
  type          text not null check (type in ('followup','message','note','upload')),
  activity_date date not null default current_date,
  activity_time time not null default localtime,
  user_id       text references public.users(user_id),
  body          text,
  file_path     text,
  created_at    timestamptz not null default now()
);
create index on public.activity (task_id);

-- ---------------------------------------------------------------- sync_runs
-- One row per call of sync_import(): which sheet, when, and what changed.
create table public.sync_runs (
  run_id      bigint generated always as identity primary key,
  source_key  text not null,                     -- which Google Sheet (e.g. 'sheet-1')
  status      text not null default 'running' check (status in ('running','succeeded')),
  started_at  timestamptz not null default now(),
  finished_at timestamptz,
  counts      jsonb
);

-- ---------------------------------------------------------------- updated_at trigger
create function public.touch_updated_at() returns trigger
language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;

create trigger job_orders_touch before update on public.job_orders
  for each row execute function public.touch_updated_at();
create trigger tasks_touch before update on public.tasks
  for each row execute function public.touch_updated_at();

-- ---------------------------------------------------------------- row level security
-- Public (anon key) can READ the data and the activity history.
-- Only the service_role key (used by Sync.gs) writes during sync.
-- Logged-in writes are added with the login step (later).
alter table public.users      enable row level security;
alter table public.kumiai     enable row level security;
alter table public.companies  enable row level security;
alter table public.job_orders enable row level security;
alter table public.tasks      enable row level security;
alter table public.activity   enable row level security;
alter table public.sync_runs  enable row level security;

do $$
declare t text;
begin
  foreach t in array array['users','kumiai','companies','job_orders','tasks','activity','sync_runs'] loop
    execute format('create policy "read %1$s" on public.%1$I for select to anon, authenticated using (true)', t);
  end loop;
end $$;
