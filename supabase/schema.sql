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
