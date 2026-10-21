// Rotating the shared secret without downtime: during a rotation the backend accepts ROBLOX_SHARED_SECRET and
// ROBLOX_SHARED_SECRET_PREVIOUS (docs/SECURITY.md "Rotating the game password").
import assert from "node:assert/strict";
import { test } from "node:test";
import { checkKey, depsFromEnv, handleDesign, handleMod } from "../lib/handler.ts";
import { REFUSALS } from "../lib/messages.ts";
import { MemoryStore } from "../lib/store.ts";
import { designBody, fakeClaude, json, makeDeps, modBody, post, SECRET, textReply, validMod } from "./helpers.ts";

const OLD = "old-shared-secret-9876543210";

test("without a previous secret only the current key gets in", async () => {
	const deps = makeDeps();
	assert.equal((await handleDesign(post("/api/design", designBody()), deps)).status, 200);
	assert.equal((await handleDesign(post("/api/design", designBody(), OLD), deps)).status, 401);
	assert.equal(deps.logs.some((line) => line.includes("PREVIOUS")), false);
});

test("during a rotation the current and the previous key both get in, on both endpoints", async () => {
	const deps = makeDeps({ previousSecret: OLD });
	assert.equal((await handleDesign(post("/api/design", designBody()), deps)).status, 200);
	assert.equal((await handleDesign(post("/api/design", designBody({ prompt: "a tall green van" }), OLD), deps)).status, 200);
	const modDeps = makeDeps({ previousSecret: OLD, claude: fakeClaude(textReply(validMod())) });
	assert.equal((await handleMod(post("/api/mod", modBody()), modDeps)).status, 200);
	assert.equal((await handleMod(post("/api/mod", modBody({ prompt: "matte black, low and wide" }), OLD), modDeps)).status, 200);
});

test("during a rotation any other key is still refused", async () => {
	const deps = makeDeps({ previousSecret: OLD });
	assert.equal((await handleDesign(post("/api/design", designBody(), "wrong"), deps)).status, 401);
	assert.equal((await handleDesign(post("/api/design", designBody(), `${OLD}x`), deps)).status, 401);
	assert.equal((await handleDesign(post("/api/design", designBody(), ""), deps)).status, 401);
	assert.equal((await handleDesign(post("/api/design", designBody(), null), deps)).status, 401);
	assert.equal(deps.store.usage.length, 0, "a refused key never reaches the limits or Claude");
});

test("a request with the previous key is logged without the key", async () => {
	const deps = makeDeps({ previousSecret: OLD });
	await handleDesign(post("/api/design", designBody(), OLD), deps);
	assert.equal(deps.logs.filter((line) => line.includes("ROBLOX_SHARED_SECRET_PREVIOUS")).length, 1);
	assert.equal(deps.logs.some((line) => line.includes(OLD) || line.includes(SECRET)), false);
	await handleDesign(post("/api/design", designBody()), deps);
	assert.equal(deps.logs.filter((line) => line.includes("ROBLOX_SHARED_SECRET_PREVIOUS")).length, 1);
});

test("the previous key alone never opens the door: without ROBLOX_SHARED_SECRET nothing gets in", async () => {
	const deps = makeDeps({ secret: undefined, previousSecret: OLD });
	const response = await handleDesign(post("/api/design", designBody(), OLD), deps);
	assert.equal(response.status, 503);
	assert.equal((await json(response)).refusal, REFUSALS.unavailable);
});

test("a blank previous secret is ignored and never lets a blank key in", async () => {
	for (const blank of ["", " ", "\t"]) {
		const deps = makeDeps({ previousSecret: blank });
		assert.equal((await handleDesign(post("/api/design", designBody(), ""), deps)).status, 401);
		assert.equal((await handleDesign(post("/api/design", designBody(), " "), deps)).status, 401);
		assert.equal((await handleDesign(post("/api/design", designBody()), deps)).status, 200);
	}
});

test("checkKey says which secret matched", () => {
	assert.equal(checkKey(SECRET, SECRET, undefined), "current");
	assert.equal(checkKey(` ${SECRET} `, SECRET, OLD), "current");
	assert.equal(checkKey(OLD, SECRET, OLD), "previous");
	assert.equal(checkKey(` ${OLD}`, SECRET, ` ${OLD} `), "previous");
	assert.equal(checkKey(OLD, SECRET, undefined), null);
	assert.equal(checkKey(OLD, SECRET, ""), null);
	assert.equal(checkKey("", SECRET, ""), null);
	assert.equal(checkKey(null, SECRET, OLD), null);
	assert.equal(checkKey(OLD.toUpperCase(), SECRET, OLD), null);
	// The same value in both is simply the current key.
	assert.equal(checkKey(SECRET, SECRET, SECRET), "current");
});

test("the live wiring reads both secrets from the environment", () => {
	const deps = depsFromEnv({ ROBLOX_SHARED_SECRET: SECRET, ROBLOX_SHARED_SECRET_PREVIOUS: OLD });
	assert.equal(deps.secret, SECRET);
	assert.equal(deps.previousSecret, OLD);
	assert.equal(deps.claude, null, "no ANTHROPIC_API_KEY, no Claude client");
	assert.ok(deps.store instanceof MemoryStore);
	const single = depsFromEnv({ ROBLOX_SHARED_SECRET: SECRET });
	assert.equal(single.previousSecret, undefined);
});
