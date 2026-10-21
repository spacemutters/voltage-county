// The 90-day cleanup of the usage log (docs/privacy.html "How long things are kept"; backend/README.md "How long
// records are kept"): a request deletes rows older than USAGE_RETENTION_DAYS once the reply is decided, at most once
// an hour per store, and a failing cleanup never changes the reply.
import assert from "node:assert/strict";
import { test } from "node:test";
import { handleDesign } from "../lib/handler.ts";
import { DAY_MS, HOUR_MS, NO_TOKENS, PRUNE_EVERY_MS, USAGE_RETENTION_DAYS } from "../lib/limits.ts";
import { MemoryStore, type UsageRow } from "../lib/store.ts";
import { designBody, json, makeDeps, NOW, post, USER_HASH } from "./helpers.ts";

const RETENTION_MS = USAGE_RETENTION_DAYS * DAY_MS;

function row(createdAt: number, prompt: string): UsageRow {
	return {
		userHash: USER_HASH,
		kind: "design",
		promptHash: prompt,
		carKey: "sports",
		prompt,
		outcome: "ok",
		result: null,
		...NO_TOKENS,
		costUsd: 0,
		createdAt: new Date(createdAt),
	};
}

function prompts(store: MemoryStore): string[] {
	return store.usage.map((entry) => entry.prompt);
}

test("the usage log keeps 90 days", () => {
	assert.equal(USAGE_RETENTION_DAYS, 90);
	assert.equal(PRUNE_EVERY_MS, HOUR_MS);
});

test("a request deletes rows older than 90 days and keeps newer ones", async () => {
	const store = new MemoryStore();
	store.usage.push(
		row(NOW - RETENTION_MS - DAY_MS, "old"),
		row(NOW - RETENTION_MS - 1, "just past"),
		row(NOW - RETENTION_MS + HOUR_MS, "just inside"),
		row(NOW - DAY_MS, "yesterday"),
	);
	const deps = makeDeps({ store });
	const response = await handleDesign(post("/api/design", designBody()), deps);
	assert.equal(response.status, 200);
	assert.equal((await json(response)).ok, true);
	// The request itself is logged too.
	assert.deepEqual(prompts(store), ["just inside", "yesterday", "a small red sports car with round lights"]);
});

test("the cleanup runs at most once an hour per store", async () => {
	const store = new MemoryStore();
	const deps = makeDeps({ store });
	await handleDesign(post("/api/design", designBody()), deps); // cleans up now
	store.usage.push(row(NOW - RETENTION_MS - DAY_MS, "old"));
	deps.clock.now = NOW + HOUR_MS - 1;
	await handleDesign(post("/api/design", designBody({ prompt: "a blue coupe with tail fins" })), deps);
	assert.ok(prompts(store).includes("old"), "within the hour the old row is still there");
	deps.clock.now = NOW + HOUR_MS;
	await handleDesign(post("/api/design", designBody({ prompt: "a green wagon with wood sides" })), deps);
	assert.ok(!prompts(store).includes("old"), "an hour later it is gone");
});

test("a failing cleanup is logged and never changes the reply", async () => {
	const store = new MemoryStore();
	store.pruneUsage = async () => {
		throw new Error("database down");
	};
	const deps = makeDeps({ store });
	const response = await handleDesign(post("/api/design", designBody()), deps);
	assert.equal(response.status, 200);
	assert.equal((await json(response)).ok, true);
	assert.ok(deps.logs.includes("usage cleanup failed: database down"));
});

test("a request refused before the job (a bad key) never touches the log", async () => {
	const store = new MemoryStore();
	store.usage.push(row(NOW - RETENTION_MS - DAY_MS, "old"));
	const deps = makeDeps({ store });
	const response = await handleDesign(post("/api/design", designBody(), "wrong key"), deps);
	assert.equal(response.status, 401);
	assert.deepEqual(prompts(store), ["old"]);
});
