// Limits, the spend cap and the on/off switch. The live values sit in Supabase (designer_settings, one row Davis
// can edit in the Table Editor); DEFAULT_SETTINGS is what the in-memory store uses and what the migration seeds.
// Also holds the token prices used to log each request's cost and to enforce the daily spend cap.
// Read by: store.ts, handler.ts and the tests.
import { REFUSALS } from "./messages.ts";

export type Settings = {
	enabled: boolean; // the on/off switch
	dailySpendCapUsd: number; // Claude spend per UTC day; requests stop once it is reached
	playerHourly: number; // requests per player (salted UserId hash) in any 60 minutes
	playerDaily: number; // requests per player in any 24 hours
	globalHourly: number; // requests from everyone in any 60 minutes
};

export const DEFAULT_SETTINGS: Settings = {
	enabled: true,
	dailySpendCapUsd: 5,
	playerHourly: 10,
	playerDaily: 40,
	globalHourly: 1200,
};

export type UsageStats = {
	playerHour: number;
	playerDay: number;
	globalHour: number;
	spendTodayUsd: number;
};

export const HOUR_MS = 60 * 60 * 1000;
export const DAY_MS = 24 * HOUR_MS;

export type Windows = { hourAgo: Date; dayAgo: Date; dayStart: Date };

export function windowsAt(nowMs: number): Windows {
	const now = new Date(nowMs);
	return {
		hourAgo: new Date(nowMs - HOUR_MS),
		dayAgo: new Date(nowMs - DAY_MS),
		dayStart: new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate())),
	};
}

export type LimitVerdict = { ok: true } | { ok: false; reason: "off" | "player" | "global" | "spend"; refusal: string };

// Every request that reached the cache or Claude counts toward the request limits (cache hits and refusals too);
// only real Claude spend counts toward the cap.
export function checkLimits(settings: Settings, stats: UsageStats): LimitVerdict {
	if (!settings.enabled) {
		return { ok: false, reason: "off", refusal: REFUSALS.off };
	}
	if (stats.playerHour >= settings.playerHourly || stats.playerDay >= settings.playerDaily) {
		return { ok: false, reason: "player", refusal: REFUSALS.playerLimit };
	}
	if (stats.globalHour >= settings.globalHourly) {
		return { ok: false, reason: "global", refusal: REFUSALS.busy };
	}
	if (stats.spendTodayUsd >= settings.dailySpendCapUsd) {
		return { ok: false, reason: "spend", refusal: REFUSALS.busy };
	}
	return { ok: true };
}

// Claude Haiku 5.5 prices in USD per million tokens (October 2026, prompts up to 100K tokens; check them before
// launch). Cache reads are 0.1x input and 5-minute cache writes 1.25x input.
export const PRICES_PER_MTOK = {
	input: 0.1,
	output: 0.5,
	cacheRead: 0.01,
	cacheWrite: 0.125,
};

export type TokenCounts = {
	inputTokens: number;
	outputTokens: number;
	cacheReadTokens: number;
	cacheWriteTokens: number;
};

export const NO_TOKENS: TokenCounts = { inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0 };

export function addTokens(a: TokenCounts, b: TokenCounts): TokenCounts {
	return {
		inputTokens: a.inputTokens + b.inputTokens,
		outputTokens: a.outputTokens + b.outputTokens,
		cacheReadTokens: a.cacheReadTokens + b.cacheReadTokens,
		cacheWriteTokens: a.cacheWriteTokens + b.cacheWriteTokens,
	};
}

export function costUsd(tokens: TokenCounts): number {
	const perToken = (pricePerMTok: number): number => pricePerMTok / 1_000_000;
	return (
		tokens.inputTokens * perToken(PRICES_PER_MTOK.input) +
		tokens.outputTokens * perToken(PRICES_PER_MTOK.output) +
		tokens.cacheReadTokens * perToken(PRICES_PER_MTOK.cacheRead) +
		tokens.cacheWriteTokens * perToken(PRICES_PER_MTOK.cacheWrite)
	);
}

// Request size and timing. The game waits Config/Designer.requestTimeoutSeconds; the backend finishes inside
// REQUEST_BUDGET_MS so the game hears back before it gives up (keep the game's timeout above 30 s).
export const MAX_BODY_BYTES = 16 * 1024;
export const REQUEST_BUDGET_MS = 25_000;
export const CALL_TIMEOUT_MS = 12_000;
export const MIN_CALL_MS = 4_000; // don't start a Claude call (or the brand retry) with less time than this left
