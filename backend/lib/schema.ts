// The design spec and mod spec (PLAN.md "Design spec" / "Mod spec"), built from the kit two ways:
// - designJsonSchema / modJsonSchema: the JSON schema sent as output_config.format, so Claude can only answer with
//   kit enums. Structured outputs can't enforce number ranges or text lengths, so those are left to code.
// - designSchema / modSchema: Zod schemas that validate an answer and clamp every number, cut every text to the
//   kit limit, normalize colors and drop unknown fields; finalizeDesign / finalizeMod then apply the rules that
//   span fields (class templates and energy, catalog-only mod fields, one extra per mount, the spec size).
// Read by: handler.ts, the tests and the prompt suite runner.
import { z } from "zod";
import { kit, classIds, extraIds, personalityIds, templateIds, type Kit, type Range } from "./kit.ts";
import { charCount, cleanText, utf8Bytes } from "./normalize.ts";

export type JsonSchema = { [key: string]: unknown };

// A color that can't be read becomes this neutral grey rather than failing the whole design.
export const FALLBACK_COLOR = "#808080";

// A mod's accessoryPrompt is always this: the game doesn't build generated add-ons yet (it would charge for an
// add-on the player never sees), so add-ons go on as kit extras instead.
export const NO_ACCESSORY = "none";

// Each cut of an over-size spec keeps this share of the text being shortened.
const SHRINK_STEP = 0.8;

////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// JSON schema (output_config.format)
////////////////////////////////////////////////////////////////////////////////////////////////////////////////

function objectSchema(properties: Record<string, JsonSchema>, description?: string): JsonSchema {
	const schema: JsonSchema = {
		type: "object",
		properties,
		required: Object.keys(properties),
		additionalProperties: false,
	};
	if (description !== undefined) {
		schema.description = description;
	}
	return schema;
}

function stringSchema(description: string): JsonSchema {
	return { type: "string", description };
}

function enumSchema(values: string[], description: string): JsonSchema {
	return { type: "string", enum: values, description };
}

function numberSchema(description: string): JsonSchema {
	return { type: "number", description };
}

function refusalSchema(k: Kit): JsonSchema {
	return {
		anyOf: [{ type: "string" }, { type: "null" }],
		description:
			`null for every normal answer. Only when nothing safe can be made: a short, kind message for a kid ` +
			`(at most ${k.limits.refusal} characters) with no brand or franchise names.`,
	};
}

function rangeText(range: Range, normal: string): string {
	return `${range.min} to ${range.max}; ${normal}`;
}

const BODY_DESCRIPTIONS = {
	length: "0.5 is the template's normal length; higher is longer",
	height: "0.5 is the template's normal height; higher is taller",
	roofline: "0.5 is normal; low is a sleek low cabin, high is an upright tall cabin",
	noseSlope: "0 is a blunt upright nose, 1 is a long sloped hood",
	flare: "0 is slim arches, 1 is wide flared arches",
};

export function designJsonSchema(k: Kit = kit): JsonSchema {
	const body = k.ranges.body;
	return objectSchema({
		refusal: refusalSchema(k),
		name: stringSchema(
			`Original car name, at most ${k.limits.name} characters, in the player's language. ` +
				"Never a real carmaker, model or franchise name.",
		),
		tagline: stringSchema(`One fun line about the car, at most ${k.limits.tagline} characters, in the player's language.`),
		class: enumSchema(classIds(k), "The class given in the request, or for surprise me one of the listed surprise classes."),
		energy: enumSchema(k.energy, "battery or fuel; one the class allows."),
		personality: enumSchema(
			Object.keys(k.personalities),
			"How it drives inside its class: efficient (long range), balanced, torquey (quick off the line), track (sharp and fast).",
		),
		meshPrompt: stringSchema(
			`English, at most ${k.limits.meshPrompt} characters: the body's shape, era and style only. ` +
				"No brands, logos, badges, writing, numbers or people.",
		),
		body: objectSchema({
			template: enumSchema(templateIds(k), "A body template the class allows."),
			length: numberSchema(rangeText(body, BODY_DESCRIPTIONS.length)),
			height: numberSchema(rangeText(body, BODY_DESCRIPTIONS.height)),
			roofline: numberSchema(rangeText(body, BODY_DESCRIPTIONS.roofline)),
			noseSlope: numberSchema(rangeText(body, BODY_DESCRIPTIONS.noseSlope)),
			flare: numberSchema(rangeText(body, BODY_DESCRIPTIONS.flare)),
		}),
		parts: objectSchema({
			frontBumper: enumSchema(k.parts.frontBumper, "Front bumper style."),
			rearBumper: enumSchema(k.parts.rearBumper, "Rear bumper style."),
			spoiler: enumSchema(k.parts.spoiler, "Spoiler."),
			lights: enumSchema(k.parts.lights, "Headlight style."),
			wheels: enumSchema(k.parts.wheels, "Wheel style."),
		}),
		paint: objectSchema({
			primary: stringSchema("Main body color as #RRGGBB."),
			secondary: stringSchema("Second color (stripes, trim, two-tone) as #RRGGBB."),
			finish: enumSchema(k.finishes, "Paint finish."),
			stripe: enumSchema(k.stripes, "Stripes."),
		}),
		stance: objectSchema({
			rideHeight: numberSchema(rangeText(k.ranges.rideHeight, "0 is the template's normal height; -1 slammed, 1 lifted")),
			wheelSize: numberSchema(rangeText(k.ranges.wheelSize, "0.5 is normal; higher is bigger wheels")),
		}),
	});
}

function changeSchema(range: Range, normal: string): JsonSchema {
	return objectSchema(
		{
			change: { type: "boolean", description: "true only when the player asked to change this." },
			value: numberSchema(rangeText(range, normal)),
		},
		"Set change false to keep the car's current value.",
	);
}

function keepEnum(values: string[], k: Kit, description: string): JsonSchema {
	return enumSchema([k.mod.keep, ...values], `${description} "${k.mod.keep}" leaves it as it is.`);
}

export function modJsonSchema(k: Kit = kit): JsonSchema {
	const body = k.ranges.body;
	const keep = k.mod.keep;
	return objectSchema({
		refusal: refusalSchema(k),
		summary: stringSchema(
			`What changed, at most ${k.limits.summary} characters, in the player's language. No brand or franchise names.`,
		),
		body: objectSchema({
			template: enumSchema(
				[keep],
				`Always "${keep}": a mod never swaps the body template (it sets the seats and the chassis).`,
			),
			length: changeSchema(body, BODY_DESCRIPTIONS.length),
			height: changeSchema(body, BODY_DESCRIPTIONS.height),
			roofline: changeSchema(body, BODY_DESCRIPTIONS.roofline),
			noseSlope: changeSchema(body, BODY_DESCRIPTIONS.noseSlope),
			flare: changeSchema(body, BODY_DESCRIPTIONS.flare),
		}),
		parts: objectSchema({
			frontBumper: keepEnum(k.parts.frontBumper, k, "Front bumper style."),
			rearBumper: keepEnum(k.parts.rearBumper, k, "Rear bumper style."),
			spoiler: keepEnum(k.parts.spoiler, k, "Spoiler."),
			lights: keepEnum(k.parts.lights, k, "Headlight style."),
			wheels: keepEnum(k.parts.wheels, k, "Wheel style."),
		}),
		paint: objectSchema({
			primary: stringSchema(`Main body color as #RRGGBB, or "${keep}".`),
			secondary: stringSchema(`Second color as #RRGGBB, or "${keep}".`),
			finish: keepEnum(k.finishes, k, "Paint finish."),
			stripe: keepEnum(k.stripes, k, "Stripes."),
		}),
		stance: objectSchema({
			rideHeight: changeSchema(k.ranges.rideHeight, "0 is the template's normal height; -1 slammed, 1 lifted"),
			wheelSize: changeSchema(k.ranges.wheelSize, "0.5 is normal; higher is bigger wheels"),
		}),
		extras: {
			type: "array",
			items: enumSchema(extraIds(k), "A kit extra."),
			description:
				`Extras to mount, at most ${k.limits.maxExtras} and one per mount point. ` +
				"Empty when the player asked for none.",
		},
		accessoryPrompt: enumSchema(
			[NO_ACCESSORY],
			`Always "${NO_ACCESSORY}": add-ons go on as kit extras (pick the closest one, or none).`,
		),
	});
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// Zod: validate and clamp
////////////////////////////////////////////////////////////////////////////////////////////////////////////////

export function clamp(value: number, range: Range): number {
	return Math.min(range.max, Math.max(range.min, value));
}

// "#abc", "AABBCC" and "#aabbcc" all become "#AABBCC"; anything else becomes FALLBACK_COLOR.
export function toHexColor(text: string): string {
	const trimmed = text.trim();
	const six = /^#?([0-9a-f]{6})$/iu.exec(trimmed);
	if (six?.[1] !== undefined) {
		return `#${six[1].toUpperCase()}`;
	}
	const three = /^#?([0-9a-f]{3})$/iu.exec(trimmed);
	if (three?.[1] !== undefined) {
		const [r = "0", g = "0", b = "0"] = Array.from(three[1].toUpperCase());
		return `#${r}${r}${g}${g}${b}${b}`;
	}
	return FALLBACK_COLOR;
}

function textField(maxChars: number) {
	return z.string().transform((value) => cleanText(value, maxChars));
}

function rangedNumber(range: Range) {
	return z.number().transform((value) => clamp(value, range));
}

function refusalField(k: Kit) {
	return z.union([z.string(), z.null()]).transform((value) => {
		if (value === null) {
			return null;
		}
		const cleaned = cleanText(value, k.limits.refusal);
		return cleaned === "" || cleaned.toLowerCase() === "null" ? null : cleaned;
	});
}

export function designSchema(k: Kit = kit) {
	const body = rangedNumber(k.ranges.body);
	const color = z.string().transform(toHexColor);
	return z.object({
		refusal: refusalField(k),
		name: textField(k.limits.name),
		tagline: textField(k.limits.tagline),
		class: z.enum(classIds(k)),
		energy: z.enum(k.energy),
		personality: z.enum(personalityIds(k)),
		meshPrompt: textField(k.limits.meshPrompt),
		body: z.object({
			template: z.enum(templateIds(k)),
			length: body,
			height: body,
			roofline: body,
			noseSlope: body,
			flare: body,
		}),
		parts: z.object({
			frontBumper: z.enum(k.parts.frontBumper),
			rearBumper: z.enum(k.parts.rearBumper),
			spoiler: z.enum(k.parts.spoiler),
			lights: z.enum(k.parts.lights),
			wheels: z.enum(k.parts.wheels),
		}),
		paint: z.object({
			primary: color,
			secondary: color,
			finish: z.enum(k.finishes),
			stripe: z.enum(k.stripes),
		}),
		stance: z.object({
			rideHeight: rangedNumber(k.ranges.rideHeight),
			wheelSize: rangedNumber(k.ranges.wheelSize),
		}),
	});
}

export type DesignSpec = z.output<ReturnType<typeof designSchema>>;

function keepOr(values: string[], k: Kit) {
	return z.enum([k.mod.keep, ...values]);
}

function changeField(range: Range) {
	return z.object({ change: z.boolean(), value: rangedNumber(range) });
}

// Keeps the first extra for each mount point, then at most maxExtras of them.
export function tidyExtras(extras: string[], k: Kit = kit): string[] {
	const mounts = new Set<string>();
	const kept: string[] = [];
	for (const id of extras) {
		const mount = k.extras[id]?.mount;
		if (mount === undefined || mounts.has(mount) || kept.length >= k.limits.maxExtras) {
			continue;
		}
		mounts.add(mount);
		kept.push(id);
	}
	return kept;
}

export function modSchema(k: Kit = kit) {
	const body = changeField(k.ranges.body);
	const keep = k.mod.keep;
	const color = z.string().transform((value) => (value.trim().toLowerCase() === keep ? keep : toHexColor(value)));
	return z.object({
		refusal: refusalField(k),
		summary: textField(k.limits.summary),
		body: z.object({
			template: keepOr(templateIds(k), k),
			length: body,
			height: body,
			roofline: body,
			noseSlope: body,
			flare: body,
		}),
		parts: z.object({
			frontBumper: keepOr(k.parts.frontBumper, k),
			rearBumper: keepOr(k.parts.rearBumper, k),
			spoiler: keepOr(k.parts.spoiler, k),
			lights: keepOr(k.parts.lights, k),
			wheels: keepOr(k.parts.wheels, k),
		}),
		paint: z.object({
			primary: color,
			secondary: color,
			finish: keepOr(k.finishes, k),
			stripe: keepOr(k.stripes, k),
		}),
		stance: z.object({
			rideHeight: changeField(k.ranges.rideHeight),
			wheelSize: changeField(k.ranges.wheelSize),
		}),
		extras: z.array(z.enum(extraIds(k))).transform((extras) => tidyExtras(extras, k)),
		accessoryPrompt: z.string().transform((value) => {
			const cleaned = cleanText(value, k.limits.accessoryPrompt);
			return cleaned === "" || cleaned.toLowerCase() === "none" ? "none" : cleaned;
		}),
	});
}

export type ModSpec = z.output<ReturnType<typeof modSchema>>;

////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// Rules across fields
////////////////////////////////////////////////////////////////////////////////////////////////////////////////

function shrink(text: string): string {
	const chars = Array.from(text);
	return chars.slice(0, Math.floor(chars.length * SHRINK_STEP)).join("").trimEnd();
}

// Shortens the given text fields, in order, until the spec's JSON fits in `maxBytes`; null if it never does.
function fitBytes<T extends Record<string, unknown>>(spec: T, fields: Array<keyof T>, maxBytes: number): T | null {
	let fitted = { ...spec };
	for (const field of fields) {
		while (utf8Bytes(JSON.stringify(fitted)) > maxBytes) {
			const value = fitted[field];
			if (typeof value !== "string" || charCount(value) === 0) {
				break;
			}
			fitted = { ...fitted, [field]: shrink(value) };
		}
	}
	return utf8Bytes(JSON.stringify(fitted)) <= maxBytes ? fitted : null;
}

export type DesignContext = {
	classId: string | null; // the class the player picked, or null for "surprise me"
	promptHash: string; // picks a surprise class when Claude strays outside the list
};

// The class is the one asked for (or a surprise class); the template and energy are ones the class allows; the
// spec fits the kit's size limit. Returns null when a normal design is missing its name or mesh prompt.
export function finalizeDesign(spec: DesignSpec, context: DesignContext, k: Kit = kit): DesignSpec | null {
	let carClass = spec.class;
	if (context.classId !== null) {
		carClass = context.classId;
	} else if (!k.surpriseClasses.includes(carClass)) {
		const pick = Number.parseInt(context.promptHash.slice(0, 8), 16) % k.surpriseClasses.length;
		carClass = k.surpriseClasses[pick] ?? carClass;
	}
	const rules = k.classes[carClass];
	if (rules === undefined) {
		return null;
	}
	const template = rules.templates.includes(spec.body.template) ? spec.body.template : rules.templates[0];
	const energy = rules.energy.includes(spec.energy) ? spec.energy : rules.energy[0];
	if (template === undefined || energy === undefined) {
		return null;
	}
	if (spec.refusal === null && (spec.name === "" || spec.meshPrompt === "")) {
		return null;
	}
	const fixed: DesignSpec = { ...spec, class: carClass, energy, body: { ...spec.body, template } };
	return fitBytes(fixed, ["meshPrompt", "tagline"], k.limits.specBytes);
}

function allowedFor(kind: "kit" | "catalog", k: Kit): (path: string) => boolean {
	const allowed = kind === "catalog" ? k.mod.catalogAllowed : k.mod.kitAllowed;
	return (path) => allowed.includes(path) || allowed.includes(path.split(".")[0] ?? path);
}

export type ModContext = {
	kind: "kit" | "catalog";
	classId: string; // the car's class (part of the cache key; the game checks it)
};

// Fields a mod may not touch on this kind of car go back to "keep" (numbers: change false, extras: none);
// catalog cars only take paint, stance, wheels and extras (kit.mod.catalogAllowed). On every car the body
// template stays "keep" (the game never swaps it: it sets the seats and the chassis) and accessoryPrompt is
// "none" (the game doesn't build generated add-ons yet), so a mod that only asked for those changes nothing and
// the game refunds it. Returns null when a normal mod has no summary.
export function finalizeMod(spec: ModSpec, context: ModContext, k: Kit = kit): ModSpec | null {
	if (spec.refusal === null && spec.summary === "") {
		return null;
	}
	const allowed = allowedFor(context.kind, k);
	const keep = k.mod.keep;
	const keepString = (path: string, value: string): string => (allowed(path) ? value : keep);
	const keepNumber = (path: string, value: { change: boolean; value: number }) =>
		allowed(path) ? value : { change: false, value: value.value };
	const fixed: ModSpec = {
		...spec,
		body: {
			template: keep,
			length: keepNumber("body.length", spec.body.length),
			height: keepNumber("body.height", spec.body.height),
			roofline: keepNumber("body.roofline", spec.body.roofline),
			noseSlope: keepNumber("body.noseSlope", spec.body.noseSlope),
			flare: keepNumber("body.flare", spec.body.flare),
		},
		parts: {
			frontBumper: keepString("parts.frontBumper", spec.parts.frontBumper),
			rearBumper: keepString("parts.rearBumper", spec.parts.rearBumper),
			spoiler: keepString("parts.spoiler", spec.parts.spoiler),
			lights: keepString("parts.lights", spec.parts.lights),
			wheels: keepString("parts.wheels", spec.parts.wheels),
		},
		paint: {
			primary: keepString("paint.primary", spec.paint.primary),
			secondary: keepString("paint.secondary", spec.paint.secondary),
			finish: keepString("paint.finish", spec.paint.finish),
			stripe: keepString("paint.stripe", spec.paint.stripe),
		},
		stance: {
			rideHeight: keepNumber("stance.rideHeight", spec.stance.rideHeight),
			wheelSize: keepNumber("stance.wheelSize", spec.stance.wheelSize),
		},
		extras: allowed("extras") ? spec.extras : [],
		accessoryPrompt: NO_ACCESSORY,
	};
	return fitBytes(fixed, ["summary"], k.limits.specBytes);
}

// Parses and finalizes one answer (from Claude or the cache). null means it isn't a usable spec.
export function readDesign(raw: unknown, context: DesignContext, k: Kit = kit): DesignSpec | null {
	const parsed = designSchema(k).safeParse(raw);
	return parsed.success ? finalizeDesign(parsed.data, context, k) : null;
}

export function readMod(raw: unknown, context: ModContext, k: Kit = kit): ModSpec | null {
	const parsed = modSchema(k).safeParse(raw);
	return parsed.success ? finalizeMod(parsed.data, context, k) : null;
}
