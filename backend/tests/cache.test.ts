// The result cache: same normalized description (and for mods the same car) -> the cached spec, no Claude call.
import assert from "node:assert/strict";
import { test } from "node:test";
import { handleDesign, handleMod } from "../lib/handler.ts";
import { canonicalJson, hashPrompt, normalizePrompt } from "../lib/normalize.ts";
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

test("the same description written differently is a cache hit", async () => {
	const claude = fakeClaude(textReply(validDesign()));
	const deps = makeDeps({ claude });
	const first = await json(await handleDesign(post("/api/design", designBody({ prompt: "Red  sports car, round lights!" })), deps));
	const second = await json(await handleDesign(post("/api/design", designBody({ prompt: "red sports car round lights" })), deps));
	assert.equal(first.ok, true);
	assert.equal(first.cached, false);
	assert.equal(second.ok, true);
	assert.equal(second.cached, true);
	assert.deepEqual(second.spec, first.spec);
	assert.equal(claude.calls.length, 1);
	assert.deepEqual(
		deps.store.usage.map((row) => row.outcome),
		["ok", "cached"],
	);
	assert.equal(deps.store.usage[1]?.costUsd, 0);
});

test("a different class or surprise me is a different cache entry", async () => {
	const claude = fakeClaude(textReply(validDesign({ class: "muscle", body: { ...(validDesign().body as object), template: "fastback" } })));
	const deps = makeDeps({ claude });
	await handleDesign(post("/api/design", designBody({ classId: "muscle" })), deps);
	await handleDesign(post("/api/design", designBody({ classId: null })), deps);
	await handleDesign(post("/api/design", designBody({ classId: "muscle" })), deps);
	assert.equal(claude.calls.length, 2);
});

test("a re-roll skips the cache and doesn't overwrite it", async () => {
	const claude = fakeClaude(textReply(validDesign()), textReply(validDesign({ name: "Second Try" })));
	const deps = makeDeps({ claude });
	await handleDesign(post("/api/design", designBody()), deps);
	const reroll = await json(await handleDesign(post("/api/design", designBody({ reroll: true })), deps));
	assert.equal(reroll.cached, false);
	assert.equal((reroll.spec as { name: string }).name, "Second Try");
	const again = await json(await handleDesign(post("/api/design", designBody()), deps));
	assert.equal(again.cached, true);
	assert.equal((again.spec as { name: string }).name, "Volt Comet");
	assert.equal(claude.calls.length, 2);
});

test("mods cache per car: the same words on another car call Claude again", async () => {
	const claude = fakeClaude(textReply(validMod()));
	const deps = makeDeps({ claude });
	await handleMod(post("/api/mod", modBody()), deps);
	const hit = await json(await handleMod(post("/api/mod", modBody()), deps));
	assert.equal(hit.cached, true);
	const otherCar = validDesign({ paint: { primary: "#000000", secondary: "#FFFFFF", finish: "gloss", stripe: "none" } });
	const miss = await json(await handleMod(post("/api/mod", modBody({ current: otherCar })), deps));
	assert.equal(miss.cached, false);
	assert.equal(claude.calls.length, 2);
});

test("refusals and errors are not cached", async () => {
	const claude = fakeClaude(textReply(validDesign({ refusal: "Let's design a different car!" })));
	const deps = makeDeps({ claude });
	await handleDesign(post("/api/design", designBody()), deps);
	await handleDesign(post("/api/design", designBody()), deps);
	assert.equal(claude.calls.length, 2);
	assert.equal(deps.store.cache.size, 0);
});

test("a cached spec that now fails the brand scan is ignored and designed again", async () => {
	const claude = fakeClaude(textReply(validDesign({ name: "Fresh Original" })));
	const deps = makeDeps({ claude });
	const prompt = "a small red sports car with round lights";
	deps.store.cache.set(`design|${hashPrompt(prompt)}|sports`, validDesign({ name: `${bannedExample(3)} Star` }));
	const body = await json(await handleDesign(post("/api/design", designBody({ prompt })), deps));
	assert.equal(body.cached, false);
	assert.equal((body.spec as { name: string }).name, "Fresh Original");
	assert.equal(claude.calls.length, 1);
});

test("normalization and canonical JSON", () => {
	assert.equal(normalizePrompt("  Red   SPORTS car!!! "), "red sports car");
	assert.equal(normalizePrompt("a #### car"), normalizePrompt("a ## car"));
	assert.equal(normalizePrompt("café​ racer"), "café racer");
	assert.equal(hashPrompt("Blue car."), hashPrompt("blue car"));
	assert.notEqual(hashPrompt("blue car"), hashPrompt("blue cars"));
	assert.equal(canonicalJson({ b: 1, a: { d: 2, c: 3 } }), canonicalJson({ a: { c: 3, d: 2 }, b: 1 }));
});
