// Every path that ends in a friendly refusal or an error the game refunds: model refusals, the safety classifier,
// truncated or invalid answers, timeouts, API errors, the prompt blocklist, too little text, missing setup.
import assert from "node:assert/strict";
import { test } from "node:test";
import { APIConnectionTimeoutError, InternalServerError } from "@anthropic-ai/sdk";
import { handleDesign, handleMod } from "../lib/handler.ts";
import { REFUSALS } from "../lib/messages.ts";
import { hashPrompt } from "../lib/normalize.ts";
import { MemoryStore } from "../lib/store.ts";
import {
	bannedExample,
	designBody,
	fakeClaude,
	json,
	makeDeps,
	modBody,
	post,
	textReply,
	validDesign,
	validMod,
} from "./helpers.ts";

test("a refusal written by the model reaches the game as a friendly refusal", async () => {
	const deps = makeDeps({ claude: fakeClaude(textReply(validDesign({ refusal: "Let's design a different car!" }))) });
	const response = await handleDesign(post("/api/design", designBody()), deps);
	assert.equal(response.status, 200);
	assert.deepEqual(await json(response), { ok: false, refusal: "Let's design a different car!" });
	assert.equal(deps.store.usage[0]?.outcome, "refused");
});

test("a model refusal that names a brand is replaced with our own message", async () => {
	const refusal = `I can't copy the ${bannedExample(5)}, sorry!`;
	const deps = makeDeps({ claude: fakeClaude(textReply(validMod({ refusal }))) });
	const body = await json(await handleMod(post("/api/mod", modBody()), deps));
	assert.deepEqual(body, { ok: false, refusal: REFUSALS.safety });
});

test("the safety classifier's stop_reason refusal becomes a friendly refusal", async () => {
	const deps = makeDeps({ claude: fakeClaude(textReply("", "refusal")) });
	const response = await handleDesign(post("/api/design", designBody()), deps);
	assert.equal(response.status, 200);
	assert.deepEqual(await json(response), { ok: false, refusal: REFUSALS.safety });
	assert.equal(deps.store.usage[0]?.outcome, "refused");
	assert.ok((deps.store.usage[0]?.costUsd ?? 0) > 0, "the tokens a refusal used are still counted");
});

test("a cut-off or invalid answer is an error (the game refunds)", async () => {
	for (const reply of [
		textReply(validDesign(), "max_tokens"),
		textReply("{ not json"),
		textReply(validDesign({ class: "spaceship" })),
		textReply(validDesign(), "pause_turn"),
	]) {
		const deps = makeDeps({ claude: fakeClaude(reply) });
		const response = await handleDesign(post("/api/design", designBody()), deps);
		assert.equal(response.status, 502);
		assert.deepEqual(await json(response), { ok: false, refusal: REFUSALS.error });
		assert.equal(deps.store.usage[0]?.outcome, "error");
		assert.equal(deps.store.cache.size, 0);
	}
});

test("a timeout is a 504 and an API error a 502", async () => {
	const timedOut = makeDeps({ claude: fakeClaude(new APIConnectionTimeoutError()) });
	const timeout = await handleDesign(post("/api/design", designBody()), timedOut);
	assert.equal(timeout.status, 504);
	assert.equal((await json(timeout)).refusal, REFUSALS.timeout);

	const broken = makeDeps({
		claude: fakeClaude(new InternalServerError(529, { type: "overloaded_error" }, "Overloaded", new Headers())),
	});
	const error = await handleMod(post("/api/mod", modBody()), broken);
	assert.equal(error.status, 502);
	assert.equal((await json(error)).refusal, REFUSALS.error);
	assert.equal(broken.logs.some((line) => line.includes("api")), true);
});

test("every Claude call carries a timeout inside the request budget", async () => {
	const claude = fakeClaude(textReply(validDesign()));
	await handleDesign(post("/api/design", designBody()), makeDeps({ claude }));
	const options = claude.calls[0]?.options;
	assert.ok(options);
	assert.ok(options.timeout > 0 && options.timeout <= 12_000);
	assert.ok(options.maxRetries <= 1);
});

test("a blocklisted description is refused without calling Claude", async () => {
	const store = new MemoryStore();
	store.blocked.add(hashPrompt("a small red sports car with round lights"));
	const claude = fakeClaude(textReply(validDesign()));
	const deps = makeDeps({ store, claude });
	const response = await handleDesign(post("/api/design", designBody({ prompt: "A small RED sports car, with round lights." })), deps);
	assert.equal(response.status, 200);
	assert.deepEqual(await json(response), { ok: false, refusal: REFUSALS.blocked });
	assert.equal(claude.calls.length, 0);
	assert.equal(store.usage[0]?.outcome, "blocked");
});

test("too little text after the game's filter gets 'tell us more' without calling Claude", async () => {
	const claude = fakeClaude(textReply(validDesign()));
	const deps = makeDeps({ claude });
	for (const prompt of ["#### #### ####", "car", "   ", "\u{1F697}\u{1F697}\u{1F525}"]) {
		const response = await handleDesign(post("/api/design", designBody({ prompt })), deps);
		assert.equal(response.status, 200);
		assert.deepEqual(await json(response), { ok: false, refusal: REFUSALS.tooShort });
	}
	assert.equal(claude.calls.length, 0);
});

test("without ANTHROPIC_API_KEY the designer answers 503 (and cache hits still work)", async () => {
	const store = new MemoryStore();
	const prompt = "a small red sports car with round lights";
	store.cache.set(`design|${hashPrompt(prompt)}|sports`, validDesign());
	const deps = makeDeps({ store, claude: null });
	const hit = await handleDesign(post("/api/design", designBody({ prompt })), deps);
	assert.equal(hit.status, 200);
	const miss = await handleDesign(post("/api/design", designBody({ prompt: "a tall blue van with a roof box" })), deps);
	assert.equal(miss.status, 503);
	assert.equal((await json(miss)).refusal, REFUSALS.unavailable);
});

test("a store outage answers 503 so the game refunds", async () => {
	const store = new MemoryStore();
	store.getSettings = async () => {
		throw new Error("connection refused");
	};
	const claude = fakeClaude(textReply(validDesign()));
	const response = await handleDesign(post("/api/design", designBody()), makeDeps({ store, claude }));
	assert.equal(response.status, 503);
	assert.equal(claude.calls.length, 0);
});

test("a failing usage log never loses the player's design", async () => {
	const store = new MemoryStore();
	store.recordUsage = async () => {
		throw new Error("insert failed");
	};
	const deps = makeDeps({ store });
	const body = await json(await handleDesign(post("/api/design", designBody()), deps));
	assert.equal(body.ok, true);
	assert.equal(deps.logs.some((line) => line.includes("usage log failed")), true);
});
