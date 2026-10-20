// lib/kit.json and lib/banned-names.txt must match the game's copies (run `npm run sync-kit` when they don't),
// and the JSON schemas sent to Claude must use only kit values and only what structured outputs supports.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { parseBannedList } from "../lib/brands.ts";
import { BODY_NUMBERS, kit, PART_SLOTS, STANCE_NUMBERS } from "../lib/kit.ts";
import { REQUEST_BUDGET_MS } from "../lib/limits.ts";
import { designJsonSchema, modJsonSchema, NO_ACCESSORY, type JsonSchema } from "../lib/schema.ts";

const read = (relative: string): string => readFileSync(new URL(relative, import.meta.url), "utf8");

test("lib/kit.json is the same as src/shared/Config/DesignKit.json (npm run sync-kit)", () => {
	const game = JSON.parse(read("../../src/shared/Config/DesignKit.json")) as unknown;
	const backend = JSON.parse(read("../lib/kit.json")) as unknown;
	assert.deepEqual(backend, game);
});

test("lib/banned-names.txt is the same as scripts/banned-names.txt (npm run sync-kit)", () => {
	assert.deepEqual(parseBannedList(read("../lib/banned-names.txt")), parseBannedList(read("../../scripts/banned-names.txt")));
});

test("the kit has everything the spec shapes need", () => {
	assert.equal(kit.kitVersion, 1);
	for (const field of [...BODY_NUMBERS, ...STANCE_NUMBERS]) {
		assert.ok(kit.proportions[field], `proportions.${field}`);
	}
	for (const slot of PART_SLOTS) {
		assert.ok(kit.parts[slot].length > 0, slot);
	}
	for (const [id, rules] of Object.entries(kit.classes)) {
		assert.ok(rules.templates.length > 0 && rules.energy.length > 0, id);
		for (const template of rules.templates) {
			assert.ok(kit.templates[template], `${id} -> ${template}`);
		}
	}
	for (const id of kit.surpriseClasses) {
		assert.ok(kit.classes[id], id);
	}
	assert.ok(kit.surpriseClasses.every((id) => kit.classes[id]?.requiresOwnedClass === undefined));
});

const UNSUPPORTED = ["minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum", "multipleOf", "minLength", "maxLength", "minItems", "maxItems", "pattern"];

// Walks a schema: every object closes its properties and requires all of them; no unsupported keywords.
function checkSchema(schema: JsonSchema, path: string): void {
	for (const keyword of UNSUPPORTED) {
		assert.equal(keyword in schema, false, `${path}: ${keyword}`);
	}
	if (schema.type === "object") {
		assert.equal(schema.additionalProperties, false, `${path}: additionalProperties`);
		const properties = schema.properties as Record<string, JsonSchema>;
		assert.deepEqual([...(schema.required as string[])].sort(), Object.keys(properties).sort(), `${path}: required`);
		for (const [key, child] of Object.entries(properties)) {
			checkSchema(child, `${path}.${key}`);
		}
	}
	if (schema.type === "array") {
		checkSchema(schema.items as JsonSchema, `${path}[]`);
	}
	if (Array.isArray(schema.anyOf)) {
		for (const option of schema.anyOf as JsonSchema[]) {
			checkSchema(option, `${path}|`);
		}
	}
}

function enumAt(schema: JsonSchema, path: string[]): unknown {
	let node: JsonSchema = schema;
	for (const key of path) {
		node = (node.properties as Record<string, JsonSchema>)[key] as JsonSchema;
	}
	return node.enum;
}

test("the design JSON schema is closed, complete and built from kit enums", () => {
	const schema = designJsonSchema();
	checkSchema(schema, "design");
	assert.deepEqual(Object.keys(schema.properties as object), [
		"refusal",
		"name",
		"tagline",
		"class",
		"energy",
		"personality",
		"meshPrompt",
		"body",
		"parts",
		"paint",
		"stance",
	]);
	assert.deepEqual(enumAt(schema, ["class"]), Object.keys(kit.classes));
	assert.deepEqual(enumAt(schema, ["personality"]), Object.keys(kit.personalities));
	assert.deepEqual(enumAt(schema, ["body", "template"]), Object.keys(kit.templates));
	assert.deepEqual(enumAt(schema, ["parts", "wheels"]), kit.parts.wheels);
	assert.deepEqual(enumAt(schema, ["paint", "finish"]), kit.finishes);
	assert.deepEqual(enumAt(schema, ["paint", "stripe"]), kit.stripes);
});

test("the mod JSON schema accepts keep everywhere a choice can stay the same", () => {
	const schema = modJsonSchema();
	checkSchema(schema, "mod");
	assert.deepEqual(enumAt(schema, ["parts", "spoiler"]), [kit.mod.keep, ...kit.parts.spoiler]);
	assert.deepEqual(enumAt(schema, ["paint", "finish"]), [kit.mod.keep, ...kit.finishes]);
	const extras = (schema.properties as Record<string, JsonSchema>).extras as JsonSchema;
	assert.deepEqual((extras.items as JsonSchema).enum, Object.keys(kit.extras));
	// The game never swaps a body template and doesn't build generated add-ons yet, so neither can change.
	assert.deepEqual(enumAt(schema, ["body", "template"]), [kit.mod.keep]);
	assert.deepEqual(enumAt(schema, ["accessoryPrompt"]), [NO_ACCESSORY]);
});

test("the game waits longer for an answer than the backend may take (Config/Designer.requestTimeoutSeconds)", () => {
	const config = read("../../src/shared/Config/Designer.luau");
	const match = /requestTimeoutSeconds\s*=\s*(\d+(?:\.\d+)?)/u.exec(config);
	assert.ok(match?.[1], "requestTimeoutSeconds not found in Config/Designer.luau");
	const timeoutMs = Number(match[1]) * 1000;
	// Five seconds over the budget covers the store round trips before and after the Claude calls.
	assert.ok(timeoutMs >= REQUEST_BUDGET_MS + 5_000, `${timeoutMs} ms is too short for a ${REQUEST_BUDGET_MS} ms budget`);
});

test("both schemas are deterministic (the same bytes every time, for the grammar cache)", () => {
	assert.equal(JSON.stringify(designJsonSchema()), JSON.stringify(designJsonSchema()));
	assert.equal(JSON.stringify(modJsonSchema()), JSON.stringify(modJsonSchema()));
});
