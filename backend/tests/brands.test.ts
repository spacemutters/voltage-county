// Banned names never pass: every name on the blocklist is caught in every string field, written plainly or with
// tricks (case, accents, full-width letters, separators), the endpoint retries once with a stricter note and
// then refuses. Names come from lib/banned-names.txt, so none is written in this file.
import assert from "node:assert/strict";
import { test } from "node:test";
import { exampleFor, findBanned, loadBannedPatterns, textVariants } from "../lib/brands.ts";
import { handleDesign, handleMod } from "../lib/handler.ts";
import { REFUSALS } from "../lib/messages.ts";
import { STRICT_NOTE } from "../lib/prompt.ts";
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

const deps = makeDeps();
const examples = loadBannedPatterns().map(exampleFor);

function fullWidth(text: string): string {
	return Array.from(text)
		.map((char) => {
			const code = char.codePointAt(0) ?? 0;
			return code > 0x20 && code < 0x7f ? String.fromCodePoint(code + 0xfee0) : char;
		})
		.join("");
}

test("the blocklist has names and every example matches its own pattern", () => {
	assert.ok(examples.length > 40);
	for (const example of examples) {
		assert.notEqual(findBanned(example, deps.banned), null, example);
	}
});

test("every banned name is caught in every string field of a design and a mod", () => {
	const designFields = ["name", "tagline", "meshPrompt"];
	const modFields = ["summary", "accessoryPrompt"];
	for (const example of examples) {
		for (const field of designFields) {
			const spec = validDesign({ [field]: `the new ${example} edition` });
			assert.notEqual(findBanned(spec, deps.banned), null, `${field}: ${example}`);
		}
		for (const field of modFields) {
			const spec = validMod({ [field]: `inspired by ${example}` });
			assert.notEqual(findBanned(spec, deps.banned), null, `${field}: ${example}`);
		}
	}
});

test("case, accents, full-width letters and separators don't slip past", () => {
	for (const example of examples) {
		const variants = [
			example.toUpperCase(),
			example.toLowerCase(),
			fullWidth(example),
			example.replace(/ /gu, "-"),
			example.replace(/ /gu, "_"),
			Array.from(example).join("."),
		];
		for (const variant of variants) {
			// Dotting every letter only rejoins names without spaces or dashes; the rest are covered above.
			if (variant.includes(".") && /[\s-]/u.test(example)) {
				continue;
			}
			assert.notEqual(findBanned(`a ${variant} car`, deps.banned), null, variant);
		}
	}
	const accented = Array.from(bannedExample(10))
		.map((char) => (/[aeiou]/iu.test(char) ? `${char}́` : char))
		.join("");
	assert.notEqual(findBanned(accented, deps.banned), null, "combining accents");
	assert.equal(textVariants("café naïve")[0], "cafe naive", "precomposed accents are removed too");
});

test("ordinary car words are not flagged", () => {
	for (const text of [
		"a sleek two-door coupe with round lights",
		"rugged off-roader with a roof rack and a light bar",
		"Volt Comet",
		"Desert Fox",
		"a model of efficiency",
		"affordable family wagon",
		"skiing trip wagon",
	]) {
		assert.equal(findBanned(text, deps.banned), null, text);
	}
});

test("a brand in the answer gets one stricter retry; a clean retry is returned", async () => {
	const claude = fakeClaude(
		textReply(validDesign({ name: `${bannedExample(0)} Junior` })),
		textReply(validDesign({ name: "Bolt Runner" })),
	);
	const response = await handleDesign(post("/api/design", designBody()), makeDeps({ claude }));
	const body = await json(response);
	assert.equal(body.ok, true);
	assert.equal((body.spec as { name: string }).name, "Bolt Runner");
	assert.equal(claude.calls.length, 2);
	const retryContent = claude.calls[1]?.body.messages[0]?.content;
	assert.ok(Array.isArray(retryContent));
	assert.equal(retryContent.some((block) => block.type === "text" && block.text === STRICT_NOTE), true);
	const firstContent = claude.calls[0]?.body.messages[0]?.content;
	assert.ok(Array.isArray(firstContent));
	assert.equal(firstContent.length, 1, "the first try has no stricter note");
});

test("a brand in both tries is refused kindly, never returned, never cached", async () => {
	for (let index = 0; index < examples.length; index += 7) {
		const name = bannedExample(index);
		const claude = fakeClaude(textReply(validDesign({ meshPrompt: `a coupe shaped like the ${name}` })));
		const testDeps = makeDeps({ claude });
		const response = await handleDesign(post("/api/design", designBody()), testDeps);
		assert.equal(response.status, 200);
		const body = await json(response);
		assert.deepEqual(body, { ok: false, refusal: REFUSALS.brand });
		assert.equal(JSON.stringify(body).toLowerCase().includes(name.toLowerCase()), false);
		assert.equal(claude.calls.length, 2);
		assert.equal(testDeps.store.cache.size, 0);
		assert.equal(testDeps.store.usage[0]?.outcome, "refused");
	}
});

test("mods get the same brand protection", async () => {
	const claude = fakeClaude(textReply(validMod({ summary: `a ${bannedExample(20)} roof scoop` })));
	const body = await json(await handleMod(post("/api/mod", modBody()), makeDeps({ claude })));
	assert.deepEqual(body, { ok: false, refusal: REFUSALS.brand });
});

test("no answer ever reaches the game with a banned name, whatever the field", async () => {
	const fields: Array<[string, (name: string) => Record<string, unknown>]> = [
		["name", (name) => validDesign({ name })],
		["tagline", (name) => validDesign({ tagline: `faster than a ${name}` })],
		["meshPrompt", (name) => validDesign({ meshPrompt: `${name} style hood` })],
	];
	for (const example of examples) {
		for (const [field, make] of fields) {
			const claude = fakeClaude(textReply(make(example)));
			const body = await json(await handleDesign(post("/api/design", designBody()), makeDeps({ claude })));
			assert.equal(body.ok, false, `${field}: ${example}`);
			assert.equal(findBanned(body, deps.banned), null, `${field}: ${example}`);
		}
	}
});
