// Zod validation and clamping: every number in range, every text cut to the kit limit, kit enums only, unknown
// fields dropped, and the cross-field rules (class templates, energy, catalog-only mods, one extra per mount).
import assert from "node:assert/strict";
import { test } from "node:test";
import { handleDesign, handleMod } from "../lib/handler.ts";
import { kit } from "../lib/kit.ts";
import { charCount, utf8Bytes } from "../lib/normalize.ts";
import {
	designSchema,
	FALLBACK_COLOR,
	readDesign,
	readMod,
	tidyExtras,
	toHexColor,
	type DesignSpec,
	type ModSpec,
} from "../lib/schema.ts";
import { designBody, fakeClaude, json, makeDeps, modBody, post, textReply, validDesign, validMod } from "./helpers.ts";

const context = { classId: "sports", promptHash: "0".repeat(64) };

test("out-of-range numbers are clamped into the kit ranges", () => {
	const spec = readDesign(
		validDesign({
			body: { template: "coupe", length: 7, height: -3, roofline: 0.5, noseSlope: 1.0001, flare: -0.2 },
			stance: { rideHeight: 9, wheelSize: -9 },
		}),
		context,
	);
	assert.ok(spec);
	assert.deepEqual(spec.body, { template: "coupe", length: 1, height: 0, roofline: 0.5, noseSlope: 1, flare: 0 });
	assert.deepEqual(spec.stance, { rideHeight: kit.ranges.rideHeight.max, wheelSize: kit.ranges.wheelSize.min });
});

test("texts are cut to the kit limits and cleaned of invisible characters", () => {
	const spec = readDesign(
		validDesign({
			name: `  Super​ Long Name ${"z".repeat(80)}  `,
			tagline: "t".repeat(500),
			meshPrompt: "m".repeat(1000),
		}),
		context,
	);
	assert.ok(spec);
	assert.equal(charCount(spec.name) <= kit.limits.name, true);
	assert.equal(spec.name.startsWith("Super Long Name"), true);
	assert.equal(charCount(spec.tagline), kit.limits.tagline);
	assert.equal(charCount(spec.meshPrompt), kit.limits.meshPrompt);
});

test("unknown fields are dropped and wrong enums are rejected", () => {
	const spec = readDesign(validDesign({ price: 0, credits: 999, stats: { topSpeedMph: 900 } }), context);
	assert.ok(spec);
	assert.equal("price" in spec, false);
	assert.equal("credits" in spec, false);
	assert.equal("stats" in spec, false);
	assert.equal(readDesign(validDesign({ personality: "rocket" }), context), null);
	assert.equal(readDesign(validDesign({ class: "hypercar" }), context), null);
	assert.equal(readDesign(validDesign({ parts: { ...(validDesign().parts as object), wheels: "gold" } }), context), null);
	assert.equal(readDesign(validDesign({ stance: { rideHeight: "high", wheelSize: 0.5 } }), context), null);
	assert.equal(readDesign({ refusal: null }, context), null);
	assert.equal(readDesign("not an object", context), null);
});

test("colors are normalized; unreadable ones become neutral grey", () => {
	assert.equal(toHexColor("#a1b2c3"), "#A1B2C3");
	assert.equal(toHexColor("A1B2C3"), "#A1B2C3");
	assert.equal(toHexColor("#abc"), "#AABBCC");
	assert.equal(toHexColor("red"), FALLBACK_COLOR);
	assert.equal(toHexColor("#12345"), FALLBACK_COLOR);
	const spec = readDesign(validDesign({ paint: { primary: "blue", secondary: "#fff", finish: "gloss", stripe: "none" } }), context);
	assert.equal(spec?.paint.primary, FALLBACK_COLOR);
	assert.equal(spec?.paint.secondary, "#FFFFFF");
});

test("the class is always the one asked for, with a template and energy that class allows", () => {
	const raw = validDesign({ class: "economy", body: { ...(validDesign().body as object), template: "van" } });
	const spec = readDesign(raw, { classId: "muscle", promptHash: context.promptHash });
	assert.ok(spec);
	assert.equal(spec.class, "muscle");
	assert.equal(kit.classes.muscle?.templates.includes(spec.body.template), true);
});

test("surprise me always lands on a surprise class", () => {
	for (const strayClass of ["exotic", "van", "minivan"]) {
		for (const hash of ["00000000", "ffffffff", "12345678", "9abcdef0"]) {
			const spec = readDesign(validDesign({ class: strayClass }), { classId: null, promptHash: hash.padEnd(64, "0") });
			assert.ok(spec);
			assert.equal(kit.surpriseClasses.includes(spec.class), true);
			assert.equal(kit.classes[spec.class]?.templates.includes(spec.body.template), true);
		}
	}
	const kept = readDesign(validDesign({ class: "pickup", body: { ...(validDesign().body as object), template: "pickup" } }), {
		classId: null,
		promptHash: context.promptHash,
	});
	assert.equal(kept?.class, "pickup");
});

test("a normal design needs a name and a mesh prompt", () => {
	assert.equal(readDesign(validDesign({ name: "   " }), context), null);
	assert.equal(readDesign(validDesign({ meshPrompt: "​" }), context), null);
	const refused = readDesign(validDesign({ refusal: "Let's try a different car!", name: "" }), context);
	assert.equal(refused?.refusal, "Let's try a different car!");
});

test("an empty or 'null' refusal string means no refusal", () => {
	assert.equal(readDesign(validDesign({ refusal: "" }), context)?.refusal, null);
	assert.equal(readDesign(validDesign({ refusal: "null" }), context)?.refusal, null);
	const long = readDesign(validDesign({ refusal: "r".repeat(400) }), context);
	assert.equal(charCount(long?.refusal ?? ""), kit.limits.refusal);
});

test("a design always fits in the kit's spec size, even in a 4-byte script", () => {
	const wide = "\u{1F697}";
	const spec = readDesign(
		validDesign({ name: wide.repeat(30), tagline: wide.repeat(80), meshPrompt: wide.repeat(400) }),
		context,
	);
	assert.ok(spec);
	assert.equal(utf8Bytes(JSON.stringify(spec)) <= kit.limits.specBytes, true);
});

test("mods: catalog cars only change paint, stance, wheels and extras", () => {
	const raw = validMod({
		body: {
			template: "suv",
			length: { change: true, value: 0.9 },
			height: { change: true, value: 0.9 },
			roofline: { change: false, value: 0.5 },
			noseSlope: { change: true, value: 0.1 },
			flare: { change: true, value: 1 },
		},
		parts: { frontBumper: "rugged", rearBumper: "rugged", spoiler: "wing", lights: "bar", wheels: "trail" },
	});
	const catalog = readMod(raw, { kind: "catalog", classId: "sedan" });
	assert.ok(catalog);
	assert.equal(catalog.body.template, "keep");
	for (const field of ["length", "height", "roofline", "noseSlope", "flare"] as const) {
		assert.equal(catalog.body[field].change, false);
	}
	assert.deepEqual(catalog.parts, { frontBumper: "keep", rearBumper: "keep", spoiler: "keep", lights: "keep", wheels: "trail" });
	assert.equal(catalog.paint.primary, "#C2A878");
	assert.equal(catalog.stance.rideHeight.change, true);
	assert.deepEqual(catalog.extras, ["roof_rack"]);

	const kitCar = readMod(raw, { kind: "kit", classId: "suv" });
	assert.ok(kitCar);
	assert.equal(kitCar.body.template, "keep");
	assert.equal(kitCar.body.length.change, true);
	assert.equal(kitCar.parts.spoiler, "wing");
});

test("mods never swap the body template or carry a generated accessory, on any car", () => {
	const raw = validMod({
		body: { ...(validMod().body as object), template: "pickup" },
		accessoryPrompt: "a surfboard on the roof",
	});
	for (const context of [
		{ kind: "kit", classId: "sports" },
		{ kind: "kit", classId: "offroad" },
		{ kind: "catalog", classId: "hypercar" },
	] as const) {
		const spec = readMod(raw, context);
		assert.ok(spec);
		assert.equal(spec.body.template, "keep", context.classId);
		assert.equal(spec.accessoryPrompt, "none", context.classId);
	}
});

test("mods: numbers clamp, 'keep' passes, extras are one per mount and at most the kit maximum", () => {
	const spec = readMod(
		validMod({
			stance: { rideHeight: { change: true, value: 40 }, wheelSize: { change: true, value: -2 } },
			paint: { primary: "KEEP", secondary: "#123", finish: "keep", stripe: "side" },
			extras: ["roof_rack", "light_bar", "bull_bar", "front_splitter", "wing_spoiler", "lip_spoiler", "rear_diffuser", "roof_box"],
			accessoryPrompt: "",
		}),
		{ kind: "kit", classId: "sports" },
	);
	assert.ok(spec);
	assert.deepEqual(spec.stance.rideHeight, { change: true, value: kit.ranges.rideHeight.max });
	assert.deepEqual(spec.stance.wheelSize, { change: true, value: kit.ranges.wheelSize.min });
	assert.equal(spec.paint.primary, "keep");
	assert.equal(spec.paint.secondary, "#112233");
	assert.deepEqual(spec.extras, ["roof_rack", "bull_bar", "wing_spoiler", "rear_diffuser"]);
	assert.equal(spec.extras.length <= kit.limits.maxExtras, true);
	assert.equal(spec.accessoryPrompt, "none");
	assert.equal(readMod(validMod({ extras: ["rocket_launcher"] }), { kind: "kit", classId: "sports" }), null);
	assert.equal(readMod(validMod({ summary: "" }), { kind: "kit", classId: "sports" }), null);
	assert.deepEqual(tidyExtras(["roof_box", "roof_box", "roof_rack"]), ["roof_box"]);
});

test("the endpoint returns the clamped spec, never the raw answer", async () => {
	const raw = validDesign({
		name: "N".repeat(99),
		body: { template: "coupe", length: 5, height: 0.5, roofline: 0.5, noseSlope: 0.5, flare: 0.5 },
		secretField: "drop me",
	});
	const deps = makeDeps({ claude: fakeClaude(textReply(raw)) });
	const body = await json(await handleDesign(post("/api/design", designBody()), deps));
	const spec = body.spec as DesignSpec & Record<string, unknown>;
	assert.equal(body.ok, true);
	assert.equal(charCount(spec.name), kit.limits.name);
	assert.equal(spec.body.length, 1);
	assert.equal("secretField" in spec, false);
	assert.deepEqual(designSchema().parse(spec), spec, "the returned spec is already valid and clamped");

	const modDeps = makeDeps({ claude: fakeClaude(textReply(validMod({ summary: "S".repeat(200) }))) });
	const modReply = await json(await handleMod(post("/api/mod", modBody({ kind: "catalog" })), modDeps));
	assert.equal(charCount((modReply.spec as ModSpec).summary), kit.limits.summary);
});
