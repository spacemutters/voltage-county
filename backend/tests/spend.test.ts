// The daily spend cap and the per-player daily limit end to end on the in-memory store, with the clock moving:
// what a stopped request answers (the game refunds anything but ok: true), that cache hits cost nothing, and what
// counts toward the cap and the limits (docs/SECURITY.md "Backend review").
import assert from "node:assert/strict";
import { test } from "node:test";
import { tokensOf } from "../lib/claude.ts";
import { handleDesign, handleMod } from "../lib/handler.ts";
import { costUsd, DAY_MS, HOUR_MS, windowsAt } from "../lib/limits.ts";
import { REFUSALS } from "../lib/messages.ts";
import { MemoryStore } from "../lib/store.ts";
import {
	bannedExample,
	designBody,
	fakeClaude,
	json,
	makeDeps,
	modBody,
	NOW,
	post,
	textReply,
	USAGE,
	USER_HASH,
	validDesign,
	type TestDeps,
} from "./helpers.ts";

// What one fake Claude call costs (helpers' USAGE: 300 in, 400 out, 1500 cache reads), about $0.00025.
const ONE_CALL = costUsd(tokensOf(USAGE));

// A distinct player hash for each number (64 hex-like characters, like the game's salted SHA-256).
function player(index: number): string {
	return `${String(index).padStart(4, "0")}${"c".repeat(60)}`;
}

function ask(deps: TestDeps, prompt: string, userHash = USER_HASH): Promise<Response> {
	return handleDesign(post("/api/design", designBody({ prompt, userHash })), deps);
}

async function spendToday(deps: TestDeps): Promise<number> {
	return (await deps.store.usageStats({ userHash: USER_HASH, ...windowsAt(deps.clock.now) })).spendTodayUsd;
}

test("a player's daily limit fills up over the day, and frees up 24 hours after their first request", async () => {
	const deps = makeDeps({ store: new MemoryStore({ playerHourly: 2, playerDaily: 3 }) });
	const first = deps.clock.now;
	const prompts = ["a blue coupe with tail fins", "a green wagon with wood sides", "a silver roadster with chrome"];
	for (const [index, prompt] of prompts.entries()) {
		deps.clock.now = first + index * 2 * HOUR_MS; // never two in one hour
		assert.equal((await ask(deps, prompt)).status, 200);
	}
	deps.clock.now = first + 5 * HOUR_MS; // the last hour was quiet, but the day is full
	const stopped = await ask(deps, "an orange pickup with a light bar");
	assert.equal(stopped.status, 429);
	assert.deepEqual(await json(stopped), { ok: false, refusal: REFUSALS.playerLimit });
	// Another player is unaffected.
	assert.equal((await ask(deps, "an orange pickup with a light bar", player(1))).status, 200);
	// 24 hours after the first request it has dropped out of the window, so one more fits.
	deps.clock.now = first + DAY_MS + 60_000;
	assert.equal((await ask(deps, "a purple hatchback with big wheels")).status, 200);
	assert.equal((await ask(deps, "a white van with a ladder rack")).status, 429);
});

test("the spend cap stops everyone once today's Claude spend reaches it, and the reply makes the game refund", async () => {
	const store = new MemoryStore({ dailySpendCapUsd: ONE_CALL * 1.5 });
	const claude = fakeClaude(textReply(validDesign()));
	const deps = makeDeps({ store, claude });
	// The cap is checked before each call, so the call that crosses it still finishes: the cap can be passed by at
	// most one call's cost for each request in flight at that moment.
	assert.equal((await ask(deps, "a small red sports car with round lights", player(1))).status, 200);
	assert.equal((await ask(deps, "a long black sedan with gold trim", player(2))).status, 200);
	assert.ok((await spendToday(deps)) >= ONE_CALL * 1.5);

	const stopped = await ask(deps, "a yellow taxi with a roof sign", player(3));
	assert.equal(stopped.status, 429);
	// Refund semantics: ok is false and no spec comes back. The game (DesignerService.interpretResponse) reads a 429
	// as "limited" and refunds the reserved credits, like every answer that isn't ok: true.
	assert.deepEqual(await json(stopped), { ok: false, refusal: REFUSALS.busy });
	assert.equal(claude.calls.length, 2, "Claude is never called once the cap is reached");
	assert.equal(store.usage.length, 2, "a stopped request isn't logged, so it costs nothing and counts for nothing");

	// Nothing is served until midnight UTC: not a design already in the cache, not a mod.
	assert.equal((await ask(deps, "a small red sports car with round lights", player(4))).status, 429);
	const mod = await handleMod(post("/api/mod", modBody({ userHash: player(5) })), deps);
	assert.equal(mod.status, 429);
	assert.equal((await json(mod)).refusal, REFUSALS.busy);

	// At midnight UTC the day starts again.
	deps.clock.now = windowsAt(NOW).dayStart.getTime() + DAY_MS + 1000;
	assert.equal(await spendToday(deps), 0);
	assert.equal((await ask(deps, "a yellow taxi with a roof sign", player(3))).status, 200);
	assert.equal(claude.calls.length, 3);
});

test("cache hits cost nothing, so they never move the spend cap", async () => {
	const store = new MemoryStore({ dailySpendCapUsd: ONE_CALL * 1.5 });
	const claude = fakeClaude(textReply(validDesign()));
	const deps = makeDeps({ store, claude });
	const prompt = "a small red sports car with round lights";
	const fresh = await json(await ask(deps, prompt, player(0)));
	assert.equal(fresh.cached, false);
	// Twenty other players ask for the same car: all answered from the cache, none of it spent.
	for (let index = 1; index <= 20; index += 1) {
		const hit = await json(await ask(deps, prompt, player(index)));
		assert.equal(hit.ok, true);
		assert.equal(hit.cached, true);
	}
	assert.equal(claude.calls.length, 1);
	assert.equal(await spendToday(deps), ONE_CALL);
	assert.ok(store.usage.filter((row) => row.outcome === "cached").every((row) => row.costUsd === 0));
	// The cap still has room, so a new idea is designed.
	assert.equal((await ask(deps, "a long black sedan with gold trim", player(21))).status, 200);
	assert.equal(claude.calls.length, 2);
});

test("cache hits still count toward a player's request limits", async () => {
	const deps = makeDeps({ store: new MemoryStore({ playerHourly: 2 }) });
	const prompt = "a small red sports car with round lights";
	assert.equal((await json(await ask(deps, prompt))).cached, false);
	assert.equal((await json(await ask(deps, prompt))).cached, true);
	const stopped = await ask(deps, prompt);
	assert.equal(stopped.status, 429);
	assert.equal((await json(stopped)).refusal, REFUSALS.playerLimit);
});

test("tokens spent on a refusal or a brand-name retry count toward the spend cap", async () => {
	// A safety refusal still used tokens.
	const refusing = makeDeps({
		store: new MemoryStore({ dailySpendCapUsd: ONE_CALL * 0.5 }),
		claude: fakeClaude(textReply(validDesign(), "refusal")),
	});
	const refused = await json(await ask(refusing, "a small red sports car with round lights"));
	assert.deepEqual(refused, { ok: false, refusal: REFUSALS.safety });
	assert.equal(refusing.store.usage[0]?.outcome, "refused");
	assert.equal(refusing.store.usage[0]?.costUsd, ONE_CALL);
	assert.equal((await ask(refusing, "a long black sedan with gold trim", player(1))).status, 429);

	// A brand name in both answers: two calls, both paid for.
	const branded = makeDeps({
		claude: fakeClaude(textReply(validDesign({ meshPrompt: `a coupe shaped like the ${bannedExample()}` }))),
	});
	const brand = await json(await ask(branded, "a small red sports car with round lights"));
	assert.deepEqual(brand, { ok: false, refusal: REFUSALS.brand });
	const logged = branded.store.usage[0]?.costUsd ?? 0;
	assert.ok(Math.abs(logged - ONE_CALL * 2) < 1e-12, `two calls are logged (${logged})`);
});
