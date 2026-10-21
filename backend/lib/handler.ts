// The request pipeline behind POST /api/design and POST /api/mod (docs/phase-11-contracts.md "Backend";
// docs/SECURITY.md): shared secret (or the previous one during a rotation) -> request checks -> on/off switch,
// limits and spend cap -> blocklist -> cache -> Claude (structured output, validated and clamped, brand scan with
// one stricter retry) -> usage log -> reply. Once the reply is decided, usage rows older than USAGE_RETENTION_DAYS
// are deleted, at most once every PRUNE_EVERY_MS per warm instance (never failing the request).
// Replies: 200 { ok: true, spec, cached } or 200 { ok: false, refusal }; 401 bad key; 429 { ok: false, refusal }
// for limits, the spend cap and the off switch; 400/409/413 bad requests; 5xx errors (the game refunds on all
// of these). Dependencies are injected so the tests run without the network. Read by: api/design.ts, api/mod.ts.
import { createHash, timingSafeEqual } from "node:crypto";
import { z } from "zod";
import { bannedRegex, findBanned } from "./brands.ts";
import { askClaude, buildRequest, callPlan, createMessagesClient, type MessagesClient } from "./claude.ts";
import { kit } from "./kit.ts";
import {
	addTokens,
	checkLimits,
	costUsd,
	DAY_MS,
	MAX_BODY_BYTES,
	NO_TOKENS,
	PRUNE_EVERY_MS,
	REQUEST_BUDGET_MS,
	type TokenCounts,
	USAGE_RETENTION_DAYS,
	windowsAt,
} from "./limits.ts";
import { REFUSALS } from "./messages.ts";
import { canonicalJson, charCount, cleanText, hashPrompt, meaningfulChars, sha256Hex, utf8Bytes } from "./normalize.ts";
import { designUserText, modUserText } from "./prompt.ts";
import { designJsonSchema, modJsonSchema, readDesign, readMod, type JsonSchema } from "./schema.ts";
import { createStore, type Outcome, type RequestKind, type Store, type StoreEnv } from "./store.ts";

export type Deps = {
	store: Store;
	claude: MessagesClient | null; // null when ANTHROPIC_API_KEY isn't set
	secret: string | undefined; // ROBLOX_SHARED_SECRET, the same value as the game's designer_key secret
	// ROBLOX_SHARED_SECRET_PREVIOUS: the old value, still accepted while a rotation is under way (game servers
	// started before the change keep the old designer_key until they close). docs/SECURITY.md has the steps.
	previousSecret: string | undefined;
	now: () => number;
	banned: RegExp;
	log: (line: string) => void; // never given prompts, keys or user hashes
};

const DESIGN_JSON_SCHEMA = designJsonSchema();
const MOD_JSON_SCHEMA = modJsonSchema();

// The game's salted SHA-256 of the UserId (64 hex characters); any url-safe id of a sane length is accepted.
const USER_HASH = z.string().regex(/^[A-Za-z0-9_-]{16,128}$/u);
const CLASS_ID = z.string().regex(/^[a-z][a-z0-9_]{0,31}$/u);

const DESIGN_BODY = z.object({
	kitVersion: z.number().int(),
	userHash: USER_HASH,
	prompt: z.string(),
	classId: CLASS_ID.nullish(), // missing or null: "surprise me"
	reroll: z.boolean().optional(), // true: skip the cache so a re-roll gets a fresh design
});

const MOD_BODY = z.object({
	kitVersion: z.number().int(),
	userHash: USER_HASH,
	prompt: z.string(),
	kind: z.enum(["kit", "catalog"]),
	classId: CLASS_ID, // the car's class (catalog cars can be classes the designer can't make)
	current: z.union([z.record(z.string(), z.unknown()), z.array(z.unknown())]), // its spec or look
	reroll: z.boolean().optional(),
});

////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// Replies
////////////////////////////////////////////////////////////////////////////////////////////////////////////////

function reply(status: number, body: Record<string, unknown>, headers: Record<string, string> = {}): Response {
	return new Response(JSON.stringify(body), {
		status,
		headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store", ...headers },
	});
}

function refuse(status: number, refusal: string, headers: Record<string, string> = {}): Response {
	return reply(status, { ok: false, refusal }, headers);
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// Request checks
////////////////////////////////////////////////////////////////////////////////////////////////////////////////

function digest(text: string): Buffer {
	return createHash("sha256").update(text, "utf8").digest();
}

// Compares hashes of the two keys, so the time taken never depends on how much of the key was right.
export function keyMatches(given: string | null, secret: string): boolean {
	return given !== null && timingSafeEqual(digest(given.trim()), digest(secret));
}

export type KeyCheck = "current" | "previous" | null;

// Which secret the given key is: the current one, the previous one (during a rotation) or neither. Both are always
// compared, the same way whether or not a previous secret is set, so the time taken says nothing about which one
// matched. A blank previous secret is no secret: it never lets a blank key in.
export function checkKey(given: string | null, secret: string, previous: string | undefined): KeyCheck {
	const old = previous?.trim();
	const hasOld = old !== undefined && old !== "";
	const key = digest(given?.trim() ?? "");
	const isCurrent = timingSafeEqual(key, digest(secret));
	const isPrevious = timingSafeEqual(key, digest(hasOld ? old : secret)) && hasOld;
	if (given === null) {
		return null;
	}
	return isCurrent ? "current" : isPrevious ? "previous" : null;
}

type Preflight = { ok: true; body: unknown } | { ok: false; response: Response };

async function preflight(request: Request, deps: Deps): Promise<Preflight> {
	if (request.method !== "POST") {
		return { ok: false, response: refuse(405, REFUSALS.method, { allow: "POST" }) };
	}
	const secret = deps.secret?.trim();
	if (secret === undefined || secret === "") {
		deps.log("ROBLOX_SHARED_SECRET is not set");
		return { ok: false, response: refuse(503, REFUSALS.unavailable) };
	}
	const key = checkKey(request.headers.get("x-api-key"), secret, deps.previousSecret);
	if (key === null) {
		return { ok: false, response: refuse(401, REFUSALS.notAllowed) };
	}
	if (key === "previous") {
		// Shows in the Vercel logs while old game servers still run; once it stops, the old secret can go.
		deps.log("a request used ROBLOX_SHARED_SECRET_PREVIOUS (rotation under way)");
	}
	const declared = Number(request.headers.get("content-length") ?? "0");
	if (declared > MAX_BODY_BYTES) {
		return { ok: false, response: refuse(413, REFUSALS.badRequest) };
	}
	const text = await request.text();
	if (utf8Bytes(text) > MAX_BODY_BYTES) {
		return { ok: false, response: refuse(413, REFUSALS.badRequest) };
	}
	try {
		return { ok: true, body: JSON.parse(text) as unknown };
	} catch {
		return { ok: false, response: refuse(400, REFUSALS.badRequest) };
	}
}

type PromptCheck = { ok: true; prompt: string } | { ok: false; response: Response };

// The game cuts descriptions to the kit's limit and filters them; a longer one is a bad request, and one with
// too little left after filtering gets a friendly "tell us more" without calling Claude.
function checkPrompt(raw: string, maxChars: number): PromptCheck {
	if (charCount(raw) > maxChars) {
		return { ok: false, response: refuse(400, REFUSALS.badRequest) };
	}
	const prompt = cleanText(raw, maxChars);
	if (meaningfulChars(prompt) < kit.limits.minFilteredChars) {
		return { ok: false, response: refuse(200, REFUSALS.tooShort) };
	}
	return { ok: true, prompt };
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// The job: limits, blocklist, cache, Claude, log
////////////////////////////////////////////////////////////////////////////////////////////////////////////////

type Spec = { refusal: string | null };

type Job = {
	kind: RequestKind;
	userHash: string;
	prompt: string;
	promptHash: string;
	carKey: string;
	reroll: boolean;
	schema: JsonSchema;
	userText: string;
	read: (raw: unknown) => Spec | null; // validate, clamp and finalize; null when unusable
};

type Result = {
	response: Response;
	outcome: Outcome;
	logged: unknown; // what the usage log keeps as the result
	tokens: TokenCounts;
	cacheSpec?: Spec; // set on a fresh success that may be cached
};

function failure(status: number, refusal: string, reason: string, tokens: TokenCounts): Result {
	return { response: refuse(status, refusal), outcome: "error", logged: { reason }, tokens };
}

async function designWithClaude(job: Job, deps: Deps, claude: MessagesClient, deadline: number): Promise<Result> {
	let tokens = NO_TOKENS;
	for (let attempt = 0; attempt < 2; attempt += 1) {
		const plan = callPlan(deadline - deps.now());
		if (plan === null) {
			// No time for the stricter retry: the first answer used a brand name, so refuse kindly.
			return attempt === 0
				? failure(504, REFUSALS.timeout, "no time", tokens)
				: { response: refuse(200, REFUSALS.brand), outcome: "refused", logged: { brand: true }, tokens };
		}
		const answer = await askClaude(claude, buildRequest(job.schema, job.userText, attempt > 0), plan);
		tokens = addTokens(tokens, answer.tokens);
		if (answer.kind === "error") {
			deps.log(`claude ${job.kind}: ${answer.reason} (${answer.detail})`);
			return answer.reason === "timeout"
				? failure(504, REFUSALS.timeout, answer.reason, tokens)
				: failure(502, REFUSALS.error, answer.reason, tokens);
		}
		if (answer.kind === "refusal") {
			return { response: refuse(200, REFUSALS.safety), outcome: "refused", logged: { stop: "refusal" }, tokens };
		}
		const spec = job.read(answer.value);
		if (spec === null) {
			deps.log(`claude ${job.kind}: answer failed validation`);
			return failure(502, REFUSALS.error, "invalid spec", tokens);
		}
		if (spec.refusal !== null) {
			const text = findBanned(spec.refusal, deps.banned) === null ? spec.refusal : REFUSALS.safety;
			return { response: refuse(200, text), outcome: "refused", logged: { refusal: text }, tokens };
		}
		if (findBanned(spec, deps.banned) === null) {
			return {
				response: reply(200, { ok: true, spec, cached: false }),
				outcome: "ok",
				logged: spec,
				tokens,
				cacheSpec: spec,
			};
		}
		deps.log(`claude ${job.kind}: brand name in answer (attempt ${attempt + 1})`);
	}
	return { response: refuse(200, REFUSALS.brand), outcome: "refused", logged: { brand: true }, tokens };
}

async function record(job: Job, deps: Deps, outcome: Outcome, logged: unknown, tokens: TokenCounts): Promise<void> {
	try {
		await deps.store.recordUsage({
			userHash: job.userHash,
			kind: job.kind,
			promptHash: job.promptHash,
			carKey: job.carKey,
			prompt: job.prompt,
			outcome,
			result: logged,
			...tokens,
			costUsd: costUsd(tokens),
			createdAt: new Date(deps.now()),
		});
	} catch (error) {
		deps.log(`usage log failed: ${error instanceof Error ? error.message : "unknown"}`);
	}
}

// When each store last deleted old usage rows (one store per warm instance in production; one per test).
const lastPrune = new WeakMap<Store, number>();

// The 90-day cleanup: deletes usage rows older than USAGE_RETENTION_DAYS, at most once every PRUNE_EVERY_MS for a
// store. A failure is logged and tried again after the same wait; it never changes the reply.
async function pruneUsage(deps: Deps): Promise<void> {
	const now = deps.now();
	const last = lastPrune.get(deps.store);
	if (last !== undefined && now - last < PRUNE_EVERY_MS) {
		return;
	}
	lastPrune.set(deps.store, now);
	try {
		await deps.store.pruneUsage(new Date(now - USAGE_RETENTION_DAYS * DAY_MS));
	} catch (error) {
		deps.log(`usage cleanup failed: ${error instanceof Error ? error.message : "unknown"}`);
	}
}

async function runJob(job: Job, deps: Deps): Promise<Response> {
	const response = await decide(job, deps);
	await pruneUsage(deps); // awaited: Vercel may freeze the instance once the reply is sent
	return response;
}

async function decide(job: Job, deps: Deps): Promise<Response> {
	const started = deps.now();
	try {
		const settings = await deps.store.getSettings();
		const stats = await deps.store.usageStats({ userHash: job.userHash, ...windowsAt(started) });
		const verdict = checkLimits(settings, stats);
		if (!verdict.ok) {
			return refuse(429, verdict.refusal);
		}
		if (await deps.store.isBlocked(job.promptHash)) {
			await record(job, deps, "blocked", { blocked: true }, NO_TOKENS);
			return refuse(200, REFUSALS.blocked);
		}
		if (!job.reroll) {
			const cached = await deps.store.getCached(job.kind, job.promptHash, job.carKey);
			const spec = cached === null ? null : job.read(cached);
			// The cache is re-checked like a fresh answer (the blocklist may have grown since it was written).
			if (spec !== null && spec.refusal === null && findBanned(spec, deps.banned) === null) {
				await record(job, deps, "cached", spec, NO_TOKENS);
				return reply(200, { ok: true, spec, cached: true });
			}
		}
	} catch (error) {
		deps.log(`store failed: ${error instanceof Error ? error.message : "unknown"}`);
		return refuse(503, REFUSALS.error);
	}

	if (deps.claude === null) {
		deps.log("ANTHROPIC_API_KEY is not set");
		return refuse(503, REFUSALS.unavailable);
	}
	const result = await designWithClaude(job, deps, deps.claude, started + REQUEST_BUDGET_MS);
	if (result.cacheSpec !== undefined && !job.reroll) {
		try {
			await deps.store.putCached(job.kind, job.promptHash, job.carKey, result.cacheSpec);
		} catch (error) {
			deps.log(`cache write failed: ${error instanceof Error ? error.message : "unknown"}`);
		}
	}
	await record(job, deps, result.outcome, result.logged, result.tokens);
	return result.response;
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// Endpoints
////////////////////////////////////////////////////////////////////////////////////////////////////////////////

export async function handleDesign(request: Request, deps: Deps): Promise<Response> {
	const pre = await preflight(request, deps);
	if (!pre.ok) {
		return pre.response;
	}
	const parsed = DESIGN_BODY.safeParse(pre.body);
	if (!parsed.success) {
		return refuse(400, REFUSALS.badRequest);
	}
	const body = parsed.data;
	if (body.kitVersion !== kit.kitVersion) {
		return refuse(409, REFUSALS.kitVersion);
	}
	const classId = body.classId ?? null;
	if (classId !== null && kit.classes[classId] === undefined) {
		return refuse(400, REFUSALS.badRequest);
	}
	const checked = checkPrompt(body.prompt, kit.limits.promptChars);
	if (!checked.ok) {
		return checked.response;
	}
	const prompt = checked.prompt;
	const promptHash = hashPrompt(prompt);
	return runJob(
		{
			kind: "design",
			userHash: body.userHash,
			prompt,
			promptHash,
			carKey: classId ?? "surprise",
			reroll: body.reroll === true,
			schema: DESIGN_JSON_SCHEMA,
			userText: designUserText(prompt, classId),
			read: (raw) => readDesign(raw, { classId, promptHash }),
		},
		deps,
	);
}

export async function handleMod(request: Request, deps: Deps): Promise<Response> {
	const pre = await preflight(request, deps);
	if (!pre.ok) {
		return pre.response;
	}
	const parsed = MOD_BODY.safeParse(pre.body);
	if (!parsed.success) {
		return refuse(400, REFUSALS.badRequest);
	}
	const body = parsed.data;
	if (body.kitVersion !== kit.kitVersion) {
		return refuse(409, REFUSALS.kitVersion);
	}
	if (body.kind === "kit" && kit.classes[body.classId] === undefined) {
		return refuse(400, REFUSALS.badRequest);
	}
	const current = canonicalJson(body.current);
	if (utf8Bytes(current) > kit.limits.specBytes) {
		return refuse(400, REFUSALS.badRequest);
	}
	const checked = checkPrompt(body.prompt, kit.limits.modPromptChars);
	if (!checked.ok) {
		return checked.response;
	}
	const prompt = checked.prompt;
	const kind = body.kind;
	const classId = body.classId;
	return runJob(
		{
			kind: "mod",
			userHash: body.userHash,
			prompt,
			promptHash: hashPrompt(prompt),
			// The same words on the same car (kind, class and current look) give the same mod.
			carKey: `${kind}:${classId}:${sha256Hex(current)}`,
			reroll: body.reroll === true,
			schema: MOD_JSON_SCHEMA,
			userText: modUserText(prompt, kind, classId, body.current),
			read: (raw) => readMod(raw, { kind, classId }),
		},
		deps,
	);
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// Production wiring (Vercel env vars)
////////////////////////////////////////////////////////////////////////////////////////////////////////////////

export type DepsEnv = StoreEnv & {
	ANTHROPIC_API_KEY?: string;
	ROBLOX_SHARED_SECRET?: string;
	ROBLOX_SHARED_SECRET_PREVIOUS?: string;
};

export function depsFromEnv(env: DepsEnv): Deps {
	const apiKey = env.ANTHROPIC_API_KEY?.trim();
	return {
		store: createStore(env),
		claude: apiKey === undefined || apiKey === "" ? null : createMessagesClient(apiKey),
		secret: env.ROBLOX_SHARED_SECRET,
		previousSecret: env.ROBLOX_SHARED_SECRET_PREVIOUS,
		now: () => Date.now(),
		banned: bannedRegex(),
		log: (line) => console.error(`[designer] ${line}`),
	};
}

let shared: Deps | undefined;

export function defaultDeps(): Deps {
	shared ??= depsFromEnv(process.env);
	return shared;
}

// What api/design.ts and api/mod.ts export: a missing or broken setup answers 503 instead of crashing.
export function serve(kind: RequestKind): (request: Request) => Promise<Response> {
	return async (request) => {
		let deps: Deps;
		try {
			deps = defaultDeps();
		} catch (error) {
			console.error(`[designer] setup failed: ${error instanceof Error ? error.message : "unknown"}`);
			return refuse(503, REFUSALS.unavailable);
		}
		return kind === "design" ? handleDesign(request, deps) : handleMod(request, deps);
	};
}
