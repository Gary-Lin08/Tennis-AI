-- Phase 1 canonical schema for tennis analysis payload.
-- Tables: sessions, rallies, shots, bounces.

create extension if not exists pgcrypto;

create table if not exists public.sessions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references auth.users(id) on delete cascade,
  actor_key text,
  external_session_id text not null,
  source_video_path text not null,
  generated_at_utc timestamptz,
  fps double precision,
  total_frames integer,
  width_px integer,
  height_px integer,
  duration_sec double precision,
  court_width_m double precision,
  court_length_m double precision,
  first_server_side text check (first_server_side in ('near', 'far')),
  current_server_side text check (current_server_side in ('near', 'far')),
  final_sets_near integer not null default 0,
  final_sets_far integer not null default 0,
  final_games_near integer not null default 0,
  final_games_far integer not null default 0,
  final_points_near text not null default '0',
  final_points_far text not null default '0',
  num_rallies integer not null default 0,
  num_shots integer not null default 0,
  num_bounces integer not null default 0,
  num_points_scored integer not null default 0,
  num_points_pending integer not null default 0,
  raw_summary jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (user_id, external_session_id)
);

create table if not exists public.rallies (
  id bigserial primary key,
  session_id uuid not null references public.sessions(id) on delete cascade,
  actor_key text,
  rally_id integer not null,
  start_frame integer not null,
  end_frame integer not null,
  start_sec double precision not null,
  end_sec double precision not null,
  duration_sec double precision,
  num_frames integer,
  num_shots integer,
  near_shots integer,
  far_shots integer,
  unassigned_shots integer,
  winner_side text check (winner_side in ('near', 'far')),
  winner_source text,
  point_status text,
  server_side_before text check (server_side_before in ('near', 'far')),
  server_side_after text check (server_side_after in ('near', 'far')),
  before_score text,
  after_score text,
  game_won_by text check (game_won_by in ('near', 'far')),
  set_won_by text check (set_won_by in ('near', 'far')),
  tie_break_before boolean,
  tie_break_after boolean,
  tb_points_before_near integer,
  tb_points_before_far integer,
  tb_points_after_near integer,
  tb_points_after_far integer,
  raw_row jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  unique (session_id, rally_id)
);

create table if not exists public.shots (
  id bigserial primary key,
  session_id uuid not null references public.sessions(id) on delete cascade,
  actor_key text,
  shot_id integer not null,
  rally_id integer,
  frame_num integer not null,
  time_sec double precision not null,
  x_px double precision,
  y_px double precision,
  x_m double precision,
  y_m double precision,
  hitter_side text check (hitter_side in ('near', 'far')),
  hitter_track_id integer,
  assign_distance_px double precision,
  side_matched boolean,
  shot_type text,
  speed_kmh double precision,
  confidence double precision,
  raw_row jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  unique (session_id, shot_id)
);

create table if not exists public.bounces (
  id bigserial primary key,
  session_id uuid not null references public.sessions(id) on delete cascade,
  actor_key text,
  bounce_id integer not null,
  rally_id integer,
  frame_num integer not null,
  time_sec double precision not null,
  x_px double precision,
  y_px double precision,
  x_m double precision,
  y_m double precision,
  in_court boolean,
  confidence double precision,
  detection_method text,
  raw_row jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  unique (session_id, bounce_id)
);

create table if not exists public.analysis_jobs (
  id uuid primary key default gen_random_uuid(),
  actor_key text not null,
  local_session_id text not null,
  source_video_name text not null,
  source_video_path text not null,
  state text not null,
  stage text not null,
  error_message text,
  remote_session_id uuid references public.sessions(id) on delete set null,
  remote_external_session_id text,
  local_summary_json jsonb not null default '{}'::jsonb,
  manual_calibration_json jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.analysis_assets (
  id uuid primary key default gen_random_uuid(),
  job_id uuid not null references public.analysis_jobs(id) on delete cascade,
  session_id uuid references public.sessions(id) on delete cascade,
  actor_key text not null,
  asset_type text not null,
  storage_path text not null,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create table if not exists public.session_overrides (
  id uuid primary key default gen_random_uuid(),
  session_id uuid not null references public.sessions(id) on delete cascade,
  actor_key text not null,
  override_type text not null,
  payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create table if not exists public.model_versions (
  id uuid primary key default gen_random_uuid(),
  model_name text not null,
  version text not null,
  platform text not null,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  unique (model_name, version, platform)
);

create table if not exists public.app_events (
  id bigserial primary key,
  event_id text,
  install_id text not null,
  app_session_id text not null,
  local_user_id text,
  platform text not null default 'ios',
  app_version text,
  os_version text,
  event_name text not null,
  event_ts_utc timestamptz not null,
  screen_name text,
  target_name text,
  dwell_ms integer,
  duration_ms integer,
  metadata jsonb not null default '{}'::jsonb,
  received_at timestamptz not null default now()
);

alter table public.sessions drop constraint if exists sessions_external_session_id_key;
create unique index if not exists uq_sessions_user_external on public.sessions (user_id, external_session_id);
create unique index if not exists uq_sessions_actor_external on public.sessions (actor_key, external_session_id);
create index if not exists idx_sessions_user_id on public.sessions (user_id);
create index if not exists idx_sessions_actor_key on public.sessions (actor_key);
create index if not exists idx_sessions_created_at on public.sessions (created_at desc);

create index if not exists idx_rallies_session_rally on public.rallies (session_id, rally_id);
create index if not exists idx_rallies_session_start_frame on public.rallies (session_id, start_frame);
create index if not exists idx_rallies_actor_key on public.rallies (actor_key);

create index if not exists idx_shots_session_shot on public.shots (session_id, shot_id);
create index if not exists idx_shots_session_frame on public.shots (session_id, frame_num);
create index if not exists idx_shots_session_rally on public.shots (session_id, rally_id);
create index if not exists idx_shots_actor_key on public.shots (actor_key);

create index if not exists idx_bounces_session_bounce on public.bounces (session_id, bounce_id);
create index if not exists idx_bounces_session_frame on public.bounces (session_id, frame_num);
create index if not exists idx_bounces_actor_key on public.bounces (actor_key);

create index if not exists idx_analysis_jobs_actor_created on public.analysis_jobs (actor_key, created_at desc);
create index if not exists idx_analysis_jobs_state_created on public.analysis_jobs (state, created_at asc);
create index if not exists idx_analysis_assets_session on public.analysis_assets (session_id, created_at desc);
create index if not exists idx_session_overrides_session on public.session_overrides (session_id, created_at desc);

create index if not exists idx_app_events_received_at on public.app_events (received_at desc);
create index if not exists idx_app_events_event_ts on public.app_events (event_ts_utc desc);
create index if not exists idx_app_events_install_id on public.app_events (install_id);
create index if not exists idx_app_events_local_user_id on public.app_events (local_user_id);
create index if not exists idx_app_events_event_name on public.app_events (event_name);

create or replace view public.app_events_daily_summary as
select
  date_trunc('day', event_ts_utc) as day_utc,
  coalesce(local_user_id, install_id) as actor_id,
  count(*) as event_count,
  count(*) filter (where event_name = 'tap') as tap_count,
  count(*) filter (where event_name = 'screen_view') as screen_view_count,
  count(*) filter (where event_name = 'screen_leave') as screen_leave_count,
  count(*) filter (where event_name = 'app_usage_segment') as usage_segments,
  coalesce(sum(duration_ms) filter (where event_name = 'app_usage_segment'), 0) as usage_ms,
  coalesce(sum(dwell_ms) filter (where event_name = 'screen_leave'), 0) as screen_dwell_ms
from public.app_events
group by 1, 2;

create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists trg_sessions_updated_at on public.sessions;
create trigger trg_sessions_updated_at
before update on public.sessions
for each row execute function public.set_updated_at();

alter table public.sessions enable row level security;
alter table public.rallies enable row level security;
alter table public.shots enable row level security;
alter table public.bounces enable row level security;

drop policy if exists sessions_select_own on public.sessions;
create policy sessions_select_own
on public.sessions for select
using (auth.uid() = user_id);

drop policy if exists sessions_insert_own on public.sessions;
create policy sessions_insert_own
on public.sessions for insert
with check (auth.uid() = user_id);

drop policy if exists sessions_update_own on public.sessions;
create policy sessions_update_own
on public.sessions for update
using (auth.uid() = user_id)
with check (auth.uid() = user_id);

drop policy if exists sessions_delete_own on public.sessions;
create policy sessions_delete_own
on public.sessions for delete
using (auth.uid() = user_id);

drop policy if exists rallies_select_own on public.rallies;
create policy rallies_select_own
on public.rallies for select
using (
  exists (
    select 1
    from public.sessions s
    where s.id = rallies.session_id
      and s.user_id = auth.uid()
  )
);

drop policy if exists rallies_write_own on public.rallies;
create policy rallies_write_own
on public.rallies for all
using (
  exists (
    select 1
    from public.sessions s
    where s.id = rallies.session_id
      and s.user_id = auth.uid()
  )
)
with check (
  exists (
    select 1
    from public.sessions s
    where s.id = rallies.session_id
      and s.user_id = auth.uid()
  )
);

drop policy if exists shots_select_own on public.shots;
create policy shots_select_own
on public.shots for select
using (
  exists (
    select 1
    from public.sessions s
    where s.id = shots.session_id
      and s.user_id = auth.uid()
  )
);

drop policy if exists shots_write_own on public.shots;
create policy shots_write_own
on public.shots for all
using (
  exists (
    select 1
    from public.sessions s
    where s.id = shots.session_id
      and s.user_id = auth.uid()
  )
)
with check (
  exists (
    select 1
    from public.sessions s
    where s.id = shots.session_id
      and s.user_id = auth.uid()
  )
);

drop policy if exists bounces_select_own on public.bounces;
create policy bounces_select_own
on public.bounces for select
using (
  exists (
    select 1
    from public.sessions s
    where s.id = bounces.session_id
      and s.user_id = auth.uid()
  )
);

drop policy if exists bounces_write_own on public.bounces;
create policy bounces_write_own
on public.bounces for all
using (
  exists (
    select 1
    from public.sessions s
    where s.id = bounces.session_id
      and s.user_id = auth.uid()
  )
)
with check (
  exists (
    select 1
    from public.sessions s
    where s.id = bounces.session_id
      and s.user_id = auth.uid()
  )
);
