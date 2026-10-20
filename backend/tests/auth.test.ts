// The shared secret (x-api-key), methods and malformed requests.
import assert from "node:assert/strict";
import { test } from "node:test";
import { handleDesign, handleMod, keyMatches } from "../lib/handler.ts";
import { REFUSALS } from "../lib/messages.ts";
import { designBody, fakeClaude, json, makeDeps, modBody, post, SECRET, textReply, validDesign, validMod } from "./helpers.ts";

test("a request without the key is refused with 401 and never reaches Claude", async () => {
	const claude = fakeClaude(textReply(validDesign()));
	const deps = makeDeps({ claude });
	const response = await handleDesign(post("/api/design", designBody(), null), deps);
	assert.equal(response.status, 401);
	assert.equal((await json(response)).ok, false);
	assert.equal(claude.calls.length, 0);
	assert.equal(deps.store.usage.length, 0);
});

test("a wrong key is refused with 401 on both endpoints", async () => {
	const deps = makeDeps();
	assert.equal((await handleDesign(post("/api/design", designBody(), "wrong"), deps)).status, 401);
	assert.equal((await handleMod(post("/api/mod", modBody(), `${SECRET}x`), deps)).status, 401);
	assert.equal((await handleDesign(post("/api/design", designBody(), ""), deps)).status, 401);
});

test("the right key gets a design", async () => {
	const response = await handleDesign(post("/api/design", designBody()), makeDeps());
	assert.equal(response.status, 200);
	const body = await json(response);
	assert.equal(body.ok, true);
	assert.equal(body.cached, false);
});

test("without ROBLOX_SHARED_SECRET set nothing gets in", async () => {
	const deps = makeDeps({ secret: undefined });
	const response = await handleDesign(post("/api/design", designBody(), ""), deps);
	assert.equal(response.status, 503);
	assert.equal((await json(response)).refusal, REFUSALS.unavailable);
	assert.equal(deps.logs.some((line) => line.includes("ROBLOX_SHARED_SECRET")), true);
});

test("keyMatches only accepts the exact key (surrounding spaces from a header are ignored)", () => {
	assert.equal(keyMatches(SECRET, SECRET), true);
	assert.equal(keyMatches(` ${SECRET} `, SECRET), true);
	assert.equal(keyMatches(null, SECRET), false);
	assert.equal(keyMatches(SECRET.slice(1), SECRET), false);
	assert.equal(keyMatches(SECRET.toUpperCase(), SECRET), false);
});

test("only POST is accepted", async () => {
	const response = await handleDesign(post("/api/design", null, SECRET, "GET"), makeDeps());
	assert.equal(response.status, 405);
	assert.equal(response.headers.get("allow"), "POST");
});

test("malformed bodies are 400, a wrong kit version is 409, a huge body is 413", async () => {
	const deps = makeDeps();
	assert.equal((await handleDesign(post("/api/design", "{not json"), deps)).status, 400);
	assert.equal((await handleDesign(post("/api/design", designBody({ userHash: "short" })), deps)).status, 400);
	assert.equal((await handleDesign(post("/api/design", designBody({ classId: "hypercar" })), deps)).status, 400);
	assert.equal((await handleDesign(post("/api/design", designBody({ prompt: 42 })), deps)).status, 400);
	assert.equal((await handleDesign(post("/api/design", designBody({ prompt: "x".repeat(201) })), deps)).status, 400);
	assert.equal((await handleDesign(post("/api/design", designBody({ kitVersion: 2 })), deps)).status, 409);
	assert.equal((await handleMod(post("/api/mod", modBody({ kind: "paint" })), deps)).status, 400);
	assert.equal((await handleMod(post("/api/mod", modBody({ kind: "kit", classId: "hypercar" })), deps)).status, 400);
	const bigCar = { ...validDesign(), meshPrompt: "x".repeat(3000) };
	assert.equal((await handleMod(post("/api/mod", modBody({ current: bigCar })), deps)).status, 400);
	const huge = designBody({ prompt: "y".repeat(20_000) });
	assert.equal((await handleDesign(post("/api/design", huge), deps)).status, 413);
	assert.equal(deps.store.usage.length, 0);
});

test("a catalog car of a class the designer can't make can still be modded", async () => {
	const deps = makeDeps({ claude: fakeClaude(textReply(validMod())) });
	const look = { paint: "factory", finish: "gloss", wheels: "stock", rideHeight: 0, extras: [] };
	const response = await handleMod(post("/api/mod", modBody({ kind: "catalog", classId: "hypercar", current: look })), deps);
	assert.equal(response.status, 200);
	assert.equal((await json(response)).ok, true);
});

test("an empty Luau table (encoded as []) is accepted as the current car", async () => {
	const deps = makeDeps({ claude: fakeClaude(textReply(validMod())) });
	const response = await handleMod(post("/api/mod", modBody({ kind: "catalog", classId: "sedan", current: [] })), deps);
	assert.equal(response.status, 200);
});
