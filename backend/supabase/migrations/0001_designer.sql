-- Voltage County AI Car Designer (Phase 11): settings, usage log, result cache and prompt blocklist. They live in a
-- Supabase project shared with other apps (vantage-terminal), so every name carries the vc_ prefix.
-- Only the backend touches these tables, with the service role key (which bypasses RLS). RLS is on with no
-- policies, and the anon and authenticated roles get nothing, so the public API keys can't read or write them.

-- One row (id = 1): the on/off switch, the daily spend cap and the request limits. Edit it in the Table Editor;
-- the backend reads it on every request, so changes apply at once.
create table if not exists public.vc_designer_settings (
	id smallint primary key default 1 check (id = 1),
	enabled boolean not null default true,
	daily_spend_cap_usd numeric(10, 2) not null default 5 check (daily_spend_cap_usd >= 0),
	player_hourly_limit integer not null default 10 check (player_hourly_limit >= 0),
	player_daily_limit integer not null default 40 check (player_daily_limit >= 0),
	global_hourly_limit integer not null default 1200 check (global_hourly_limit >= 0),
	updated_at timestamptz not null default now()
);

insert into public.vc_designer_settings (id) values (1) on conflict (id) do nothing;

-- Every request that got past the limits: who (the game's salted hash of the UserId, never a raw UserId),
-- what (the filtered description and its hash), what came back, the tokens used and their cost.
create table if not exists public.vc_designer_usage (
	id bigint generated always as identity primary key,
	user_hash text not null,
	kind text not null check (kind in ('design', 'mod')),
	prompt_hash text not null,
	car_key text not null,
	prompt text not null,
	outcome text not null check (outcome in ('ok', 'cached', 'refused', 'blocked', 'error')),
	result jsonb,
	input_tokens integer not null default 0,
	output_tokens integer not null default 0,
	cache_read_tokens integer not null default 0,
	cache_write_tokens integer not null default 0,
	tokens integer not null default 0,
	cost_usd numeric(12, 6) not null default 0,
	created_at timestamptz not null default now()
);

create index if not exists vc_designer_usage_user_time on public.vc_designer_usage (user_hash, created_at desc);
create index if not exists vc_designer_usage_time on public.vc_designer_usage (created_at desc);
create index if not exists vc_designer_usage_prompt on public.vc_designer_usage (prompt_hash);

-- The cache: the same normalized description (and, for mods, the same car) gets the same result.
create table if not exists public.vc_designs (
	id bigint generated always as identity primary key,
	kind text not null check (kind in ('design', 'mod')),
	prompt_hash text not null,
	car_key text not null,
	spec jsonb not null,
	created_at timestamptz not null default now(),
	unique (kind, prompt_hash, car_key)
);

-- Descriptions that are never designed again, by normalized prompt hash (copy prompt_hash from vc_designer_usage).
create table if not exists public.vc_designer_blocklist (
	prompt_hash text primary key,
	note text,
	created_at timestamptz not null default now()
);

alter table public.vc_designer_settings enable row level security;
alter table public.vc_designer_usage enable row level security;
alter table public.vc_designs enable row level security;
alter table public.vc_designer_blocklist enable row level security;

revoke all on public.vc_designer_settings, public.vc_designer_usage, public.vc_designs, public.vc_designer_blocklist
	from anon, authenticated;
grant all on public.vc_designer_settings, public.vc_designer_usage, public.vc_designs, public.vc_designer_blocklist
	to service_role;

-- Limits and spend in one round trip: this player's requests in the last hour and day, everyone's in the last
-- hour, and the Claude spend since the start of the UTC day.
create or replace function public.vc_designer_usage_stats(
	p_user_hash text,
	p_hour_ago timestamptz,
	p_day_ago timestamptz,
	p_day_start timestamptz
)
returns table (player_hour bigint, player_day bigint, global_hour bigint, spend_today numeric)
language sql
stable
security invoker
set search_path = public
as $$
	select
		(select count(*) from public.vc_designer_usage where user_hash = p_user_hash and created_at >= p_hour_ago),
		(select count(*) from public.vc_designer_usage where user_hash = p_user_hash and created_at >= p_day_ago),
		(select count(*) from public.vc_designer_usage where created_at >= p_hour_ago),
		(select coalesce(sum(cost_usd), 0) from public.vc_designer_usage where created_at >= p_day_start);
$$;

revoke all on function public.vc_designer_usage_stats(text, timestamptz, timestamptz, timestamptz)
	from public, anon, authenticated;
grant execute on function public.vc_designer_usage_stats(text, timestamptz, timestamptz, timestamptz) to service_role;
