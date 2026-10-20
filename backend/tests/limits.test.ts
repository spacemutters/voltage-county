// Per-player and global limits, the daily spend cap and the on/off switch (designer_settings).
import assert from "node:assert/strict";
import { test } from "node:test";
import { handleDesign, handleMod } from "../lib/handler.ts";
import { checkLimits, costUsd, DEFAULT_SETTINGS, HOUR_MS, windowsAt } from "../lib/limits.ts";
import { REFUSALS } from "../lib/messages.ts";
import { createStore, MemoryStore, type UsageRow } from "../lib/store.ts";
import { designBody, fakeClaude, json, makeDeps, modBody, NOW, post, textReply, USER_HASH, validDesign } from "./helpers.ts";

function row(overrides: Partial<UsageRow> = {}): UsageRow {
	return {
		userHash: USER_HASH,
		kind: "design",
		promptHash: "p",
		carKey: "sports",
		prompt: "a car",
		outcome: "ok",
		result: null,
		inputTokens: 0,
		outputTokens: 0,
		cacheReadTokens: 0,
		cacheWriteTokens: 0,
		costUsd: 0,
		createdAt: new Date(NOW - 60_000),
		...overrides,
	};
}

async function expectStopped(store: MemoryStore, refusal: string): Promise<void> {
	const claude = fakeClaude(textReply(validDesign()));
	const deps = makeDeps({ store, claude });
	const before = store.usage.length;
	const response = await handleDesign(post("/api/design", designBody({ prompt: "a fresh new idea for a car" })), deps);
	assert.equal(response.status, 429);
	const body = await json(response);
	assert.equal(body.ok, false);
	assert.equal(body.refusal, refusal);
	assert.equal(claude.calls.length, 0, "Claude must not be called");
	assert.equal(store.usage.length, before, "a stopped request isn't logged");
}

test("the off switch stops every request with a friendly message", async () => {
	await expectStopped(new MemoryStore({ enabled: false }), REFUSALS.off);
	const store = new MemoryStore({ enabled: false });
	const response = await handleMod(post("/api/mod", modBody()), makeDeps({ store }));
	assert.equal(response.status, 429);
});

test("a player over the hourly limit is stopped", async () => {
	const store = new MemoryStore({ playerHourly: 3 });
	store.usage.push(row(), row(), row());
	await expectStopped(store, REFUSALS.playerLimit);
});

test("a player over the daily limit is stopped, even if the last hour was quiet", async () => {
	const store = new MemoryStore({ playerDaily: 2 });
	store.usage.push(row({ createdAt: new Date(NOW - 5 * HOUR_MS) }), row({ createdAt: new Date(NOW - 20 * HOUR_MS) }));
	await expectStopped(store, REFUSALS.playerLimit);
});

test("the global hourly limit counts everyone", async () => {
	const store = new MemoryStore({ globalHourly: 2 });
	store.usage.push(row({ userHash: "b".repeat(64) }), row({ userHash: "c".repeat(64) }));
	await expectStopped(store, REFUSALS.busy);
});

test("the daily spend cap stops requests once today's spend reaches it", async () => {
	const store = new MemoryStore({ dailySpendCapUsd: 0.5 });
	store.usage.push(row({ userHash: "d".repeat(64), costUsd: 0.3 }), row({ userHash: "e".repeat(64), costUsd: 0.25 }));
	await expectStopped(store, REFUSALS.busy);
});

test("yesterday's spend and old requests don't count", async () => {
	const store = new MemoryStore({ dailySpendCapUsd: 0.5, playerHourly: 1, playerDaily: 5 });
	const yesterday = new Date(windowsAt(NOW).dayStart.getTime() - 1000);
	store.usage.push(row({ costUsd: 10, createdAt: yesterday }), row({ createdAt: new Date(NOW - 2 * HOUR_MS) }));
	const response = await handleDesign(post("/api/design", designBody()), makeDeps({ store }));
	assert.equal(response.status, 200);
	assert.equal((await json(response)).ok, true);
});

test("limits are counted from the shared store, so two game servers share them", async () => {
	const store = new MemoryStore({ playerHourly: 2 });
	const serverA = makeDeps({ store });
	const serverB = makeDeps({ store });
	assert.equal((await handleDesign(post("/api/design", designBody({ prompt: "first car idea here" })), serverA)).status, 200);
	assert.equal((await handleDesign(post("/api/design", designBody({ prompt: "second car idea here" })), serverB)).status, 200);
	assert.equal((await handleDesign(post("/api/design", designBody({ prompt: "third car idea here" })), serverA)).status, 429);
	// Another player is unaffected.
	const other = designBody({ prompt: "third car idea here", userHash: "f".repeat(64) });
	assert.equal((await handleDesign(post("/api/design", other), serverB)).status, 200);
});

test("each request is logged with its tokens and cost", async () => {
	const deps = makeDeps();
	await handleDesign(post("/api/design", designBody()), deps);
	assert.equal(deps.store.usage.length, 1);
	const logged = deps.store.usage[0];
	assert.ok(logged);
	assert.equal(logged.outcome, "ok");
	assert.equal(logged.userHash, USER_HASH);
	assert.equal(logged.prompt, "a small red sports car with round lights");
	assert.equal(logged.inputTokens, 300);
	assert.equal(logged.outputTokens, 400);
	assert.equal(logged.cacheReadTokens, 1500);
	assert.ok(logged.costUsd > 0 && logged.costUsd < 0.001, "a request costs well under a tenth of a cent");
});

test("production never runs on the per-instance memory store unless told to", () => {
	// Without Supabase the spend cap and limits would reset on every cold start, so production refuses to start
	// (serve() then answers 503 "not set up yet" and the game refunds).
	assert.throws(() => createStore({ VERCEL_ENV: "production" }), /SUPABASE_URL/u);
	assert.throws(() => createStore({ VERCEL_ENV: "production", SUPABASE_URL: " " }), /SUPABASE_URL/u);
	assert.ok(createStore({ VERCEL_ENV: "production", DESIGNER_ALLOW_MEMORY_STORE: "1" }) instanceof MemoryStore);
	assert.ok(createStore({ VERCEL_ENV: "preview" }) instanceof MemoryStore);
	assert.ok(createStore({}) instanceof MemoryStore);
	assert.throws(() => createStore({ SUPABASE_URL: "https://example.supabase.co" }), /SERVICE_ROLE_KEY/u);
});

test("checkLimits and costUsd", () => {
	const quiet = { playerHour: 0, playerDay: 0, globalHour: 0, spendTodayUsd: 0 };
	assert.deepEqual(checkLimits(DEFAULT_SETTINGS, quiet), { ok: true });
	assert.equal(checkLimits({ ...DEFAULT_SETTINGS, enabled: false }, quiet).ok, false);
	assert.equal(costUsd({ inputTokens: 1_000_000, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0 }), 0.1);
	assert.equal(costUsd({ inputTokens: 0, outputTokens: 1_000_000, cacheReadTokens: 0, cacheWriteTokens: 0 }), 0.5);
});
