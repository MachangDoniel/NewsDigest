-- NewsDigest schema. Paste into Supabase → SQL Editor → Run.

create table if not exists public.digests (
  id          bigint generated always as identity primary key,
  date        date        not null,
  paper       text        not null check (paper in ('dailystar', 'prothomalo')),
  sections    jsonb       not null default '[]',
  mcqs        jsonb       not null default '[]',
  page_count  int         not null default 0,
  created_at  timestamptz not null default now(),
  unique (date, paper)
);

create table if not exists public.run_status (
  date        date        not null,
  paper       text        not null,
  state       text        not null check (state in ('ok', 'login_expired', 'challenge', 'not_published', 'error')),
  message     text,
  updated_at  timestamptz not null default now(),
  primary key (date, paper)
);

create index if not exists digests_date_idx on public.digests (date desc);

-- Row Level Security: the app (signed-in user) can only read.
-- The server writes with the service_role key, which bypasses RLS.
-- Also turn OFF "Allow new users to sign up" in Authentication → Sign In / Providers,
-- after creating your own user, so nobody else can get an account.
alter table public.digests    enable row level security;
alter table public.run_status enable row level security;

drop policy if exists "signed-in users read digests" on public.digests;
create policy "signed-in users read digests" on public.digests
  for select to authenticated using (true);

drop policy if exists "signed-in users read status" on public.run_status;
create policy "signed-in users read status" on public.run_status
  for select to authenticated using (true);

-- Read-aloud audio made by the summarize Edge Function (Gemini voice), one WAV per story section.
-- Private: the function hands the app short-lived signed links. Old files are deleted by the
-- daily workflow (server/scripts/cleanup-speech.ts).
insert into storage.buckets (id, name, public)
values ('speech', 'speech', false)
on conflict (id) do nothing;

-- Admin: accounts listed here see the Admin screen in the app and may start digest runs.
-- Everyone else who signs in is a reader. Add or remove a row (email in lower case) to change who is admin.
-- No policies on purpose: only the summarize Edge Function (service_role) reads these tables.
create table if not exists public.admins (
  email text primary key
);
alter table public.admins enable row level security;
insert into public.admins (email) values ('donieltripura121@gmail.com') on conflict do nothing;

-- One row per request the app makes to the summarize Edge Function, for the Admin usage screen.
-- Rows older than 30 days are deleted when the Admin screen is opened.
create table if not exists public.usage_events (
  id      bigint generated always as identity primary key,
  at      timestamptz not null default now(),
  email   text,
  action  text        not null,
  ok      boolean     not null default true
);
create index if not exists usage_events_at_idx on public.usage_events (at desc);
alter table public.usage_events enable row level security;

-- More detail per request for the Admin screen: how long it took and what kind of device asked.
alter table public.usage_events add column if not exists latency_ms int;
alter table public.usage_events add column if not exists device text;

-- Real sizes for the Admin screen: the whole database, row counts, and the saved read-aloud audio.
create or replace function public.admin_db_stats() returns json
language sql security definer set search_path = '' as $$
  select json_build_object(
    'dbBytes',     pg_database_size(current_database()),
    'digests',     (select count(*) from public.digests),
    'runStatus',   (select count(*) from public.run_status),
    'usageEvents', (select count(*) from public.usage_events),
    'audioFiles',  (select count(*) from storage.objects where bucket_id = 'speech'),
    'audioBytes',  (select coalesce(sum((metadata->>'size')::bigint), 0) from storage.objects where bucket_id = 'speech')
  );
$$;
revoke execute on function public.admin_db_stats() from public, anon, authenticated;
grant execute on function public.admin_db_stats() to service_role;

-- Who asked and how it ended, for the Admin screen's "Who is accessing" and audit log views.
alter table public.usage_events add column if not exists ip text;
alter table public.usage_events add column if not exists user_agent text;
alter table public.usage_events add column if not exists status int;
