// Where the backend keeps settings, the usage log (limits and spend), the result cache and the prompt blocklist.
// - SupabaseStore: the real one (supabase/migrations/0001_designer.sql), shared by every server and instance, so
//   limits hold across Roblox servers. Uses the service role key; the tables have RLS on with no policies.
// - MemoryStore: the same behavior inside one process. Used when SUPABASE_URL is unset (before the Supabase project
//   exists; limits then only hold per warm instance) and by the tests.
// Read by: handler.ts and the tests.
import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import { DEFAULT_SETTINGS, type Settings, type UsageStats, type Windows } from "./limits.ts";

export type RequestKind = "design" | "mod";

export type Outcome = "ok" | "cached" | "refused" | "blocked" | "error";

export type UsageRow = {
	userHash: string; // the game's salted SHA-256 of the UserId, never a raw UserId
	kind: RequestKind;
	promptHash: string;
	carKey: string;
	prompt: string; // the description after the game's TextService filter
	outcome: Outcome;
	result: unknown; // the spec, the refusal text or the error reason
	inputTokens: number;
	outputTokens: number;
	cacheReadTokens: number;
	cacheWriteTokens: number;
	costUsd: number;
	createdAt: Date;
};

export type UsageQuery = Windows & { userHash: string };

export interface Store {
	getSettings(): Promise<Settings>;
	usageStats(query: UsageQuery): Promise<UsageStats>;
	recordUsage(row: UsageRow): Promise<void>;
	getCached(kind: RequestKind, promptHash: string, carKey: string): Promise<unknown>; // null when not cached
	putCached(kind: RequestKind, promptHash: string, carKey: string, spec: unknown): Promise<void>;
	isBlocked(promptHash: string): Promise<boolean>;
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// In memory
////////////////////////////////////////////////////////////////////////////////////////////////////////////////

export class MemoryStore implements Store {
	settings: Settings;
	usage: UsageRow[] = [];
	cache = new Map<string, unknown>();
	blocked = new Set<string>();

	constructor(settings: Partial<Settings> = {}) {
		this.settings = { ...DEFAULT_SETTINGS, ...settings };
	}

	async getSettings(): Promise<Settings> {
		return { ...this.settings };
	}

	async usageStats(query: UsageQuery): Promise<UsageStats> {
		const since = (row: UsageRow, from: Date): boolean => row.createdAt.getTime() >= from.getTime();
		const mine = this.usage.filter((row) => row.userHash === query.userHash);
		return {
			playerHour: mine.filter((row) => since(row, query.hourAgo)).length,
			playerDay: mine.filter((row) => since(row, query.dayAgo)).length,
			globalHour: this.usage.filter((row) => since(row, query.hourAgo)).length,
			spendTodayUsd: this.usage
				.filter((row) => since(row, query.dayStart))
				.reduce((sum, row) => sum + row.costUsd, 0),
		};
	}

	async recordUsage(row: UsageRow): Promise<void> {
		this.usage.push(row);
	}

	async getCached(kind: RequestKind, promptHash: string, carKey: string): Promise<unknown> {
		return this.cache.get(cacheKey(kind, promptHash, carKey)) ?? null;
	}

	async putCached(kind: RequestKind, promptHash: string, carKey: string, spec: unknown): Promise<void> {
		const key = cacheKey(kind, promptHash, carKey);
		if (!this.cache.has(key)) {
			this.cache.set(key, structuredClone(spec));
		}
	}

	async isBlocked(promptHash: string): Promise<boolean> {
		return this.blocked.has(promptHash);
	}
}

function cacheKey(kind: RequestKind, promptHash: string, carKey: string): string {
	return `${kind}|${promptHash}|${carKey}`;
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// Supabase
////////////////////////////////////////////////////////////////////////////////////////////////////////////////

type SettingsRow = {
	enabled: boolean;
	daily_spend_cap_usd: number | string;
	player_hourly_limit: number;
	player_daily_limit: number;
	global_hourly_limit: number;
};

type StatsRow = {
	player_hour: number | string;
	player_day: number | string;
	global_hour: number | string;
	spend_today: number | string;
};

// The designer's tables live in a Supabase project shared with other apps, so every name carries the vc_ prefix
// (supabase/migrations/0001_designer.sql).
export const TABLES = {
	settings: "vc_designer_settings",
	usage: "vc_designer_usage",
	usageStats: "vc_designer_usage_stats",
	designs: "vc_designs",
	blocklist: "vc_designer_blocklist",
} as const;

function fail(what: string, error: { message: string } | null): void {
	if (error !== null) {
		throw new Error(`supabase ${what}: ${error.message}`);
	}
}

export class SupabaseStore implements Store {
	client: SupabaseClient;

	constructor(url: string, serviceRoleKey: string) {
		this.client = createClient(url, serviceRoleKey, {
			auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
		});
	}

	// A missing settings row means the switch is off: nothing runs until the migration's row exists.
	async getSettings(): Promise<Settings> {
		const { data, error } = await this.client
			.from(TABLES.settings)
			.select("enabled, daily_spend_cap_usd, player_hourly_limit, player_daily_limit, global_hourly_limit")
			.eq("id", 1)
			.maybeSingle();
		fail(TABLES.settings, error);
		const row = data as SettingsRow | null;
		if (row === null) {
			return { ...DEFAULT_SETTINGS, enabled: false };
		}
		return {
			enabled: row.enabled,
			dailySpendCapUsd: Number(row.daily_spend_cap_usd),
			playerHourly: row.player_hourly_limit,
			playerDaily: row.player_daily_limit,
			globalHourly: row.global_hourly_limit,
		};
	}

	async usageStats(query: UsageQuery): Promise<UsageStats> {
		const { data, error } = await this.client.rpc(TABLES.usageStats, {
			p_user_hash: query.userHash,
			p_hour_ago: query.hourAgo.toISOString(),
			p_day_ago: query.dayAgo.toISOString(),
			p_day_start: query.dayStart.toISOString(),
		});
		fail(TABLES.usageStats, error);
		const row = (Array.isArray(data) ? data[0] : data) as StatsRow | undefined | null;
		if (row === undefined || row === null) {
			throw new Error(`supabase ${TABLES.usageStats}: no row`);
		}
		return {
			playerHour: Number(row.player_hour),
			playerDay: Number(row.player_day),
			globalHour: Number(row.global_hour),
			spendTodayUsd: Number(row.spend_today),
		};
	}

	async recordUsage(row: UsageRow): Promise<void> {
		const { error } = await this.client.from(TABLES.usage).insert({
			user_hash: row.userHash,
			kind: row.kind,
			prompt_hash: row.promptHash,
			car_key: row.carKey,
			prompt: row.prompt,
			outcome: row.outcome,
			result: row.result,
			input_tokens: row.inputTokens,
			output_tokens: row.outputTokens,
			cache_read_tokens: row.cacheReadTokens,
			cache_write_tokens: row.cacheWriteTokens,
			tokens: row.inputTokens + row.outputTokens + row.cacheReadTokens + row.cacheWriteTokens,
			cost_usd: row.costUsd,
			created_at: row.createdAt.toISOString(),
		});
		fail(`${TABLES.usage} insert`, error);
	}

	async getCached(kind: RequestKind, promptHash: string, carKey: string): Promise<unknown> {
		const { data, error } = await this.client
			.from(TABLES.designs)
			.select("spec")
			.eq("kind", kind)
			.eq("prompt_hash", promptHash)
			.eq("car_key", carKey)
			.maybeSingle();
		fail(`${TABLES.designs} select`, error);
		const row = data as { spec: unknown } | null;
		return row?.spec ?? null;
	}

	async putCached(kind: RequestKind, promptHash: string, carKey: string, spec: unknown): Promise<void> {
		const { error } = await this.client
			.from(TABLES.designs)
			.upsert(
				{ kind, prompt_hash: promptHash, car_key: carKey, spec },
				{ onConflict: "kind,prompt_hash,car_key", ignoreDuplicates: true },
			);
		fail(`${TABLES.designs} upsert`, error);
	}

	async isBlocked(promptHash: string): Promise<boolean> {
		const { data, error } = await this.client
			.from(TABLES.blocklist)
			.select("prompt_hash")
			.eq("prompt_hash", promptHash)
			.maybeSingle();
		fail(TABLES.blocklist, error);
		return data !== null;
	}
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////

// One memory store per warm instance, so limits and the cache last between requests until Supabase is set up.
let memory: MemoryStore | undefined;

export type StoreEnv = {
	SUPABASE_URL?: string;
	SUPABASE_SERVICE_ROLE_KEY?: string;
	VERCEL_ENV?: string; // "production" on the live deployment (set by Vercel)
	DESIGNER_ALLOW_MEMORY_STORE?: string; // "1" lets production run on the memory store anyway
};

// The memory store keeps limits, the spend cap, the blocklist and the cache per warm instance only, so they reset
// on every cold start and aren't shared between instances: on production that would leave the spend cap
// unenforced. So production without Supabase refuses to start (serve() answers 503 "not set up yet" and the game
// refunds) unless DESIGNER_ALLOW_MEMORY_STORE is "1".
export function createStore(env: StoreEnv): Store {
	const url = env.SUPABASE_URL?.trim();
	const key = env.SUPABASE_SERVICE_ROLE_KEY?.trim();
	if (url !== undefined && url !== "") {
		if (key === undefined || key === "") {
			throw new Error("SUPABASE_URL is set but SUPABASE_SERVICE_ROLE_KEY is not");
		}
		return new SupabaseStore(url, key);
	}
	if (env.VERCEL_ENV === "production" && env.DESIGNER_ALLOW_MEMORY_STORE?.trim() !== "1") {
		throw new Error("SUPABASE_URL is not set on production (set DESIGNER_ALLOW_MEMORY_STORE=1 to run without it)");
	}
	memory ??= new MemoryStore();
	return memory;
}
