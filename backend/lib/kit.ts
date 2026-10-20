// The design kit: lib/kit.json is a copy of src/shared/Config/DesignKit.json (npm run sync-kit), the single source
// of truth the game also reads. Everything the backend checks (enums, ranges, text limits) comes from here.
// Read by: schema.ts, prompt.ts, handler.ts and the tests.
import kitJson from "./kit.json" with { type: "json" };

export type Range = { min: number; max: number };

export type KitClass = { templates: string[]; energy: string[]; requiresOwnedClass?: string };

export type Kit = {
	kitVersion: number;
	limits: {
		promptChars: number;
		modPromptChars: number;
		name: number;
		tagline: number;
		summary: number;
		meshPrompt: number;
		accessoryPrompt: number;
		refusal: number;
		maxExtras: number;
		specBytes: number;
		minFilteredChars: number;
	};
	ranges: { body: Range; rideHeight: Range; wheelSize: Range };
	proportions: Record<string, Range & { note?: string }>; // how each 0..1 number scales the geometry (game side)
	classes: Record<string, KitClass>;
	surpriseClasses: string[];
	templates: Record<string, { style: string; seats: number; geometry: Record<string, number> }>;
	parts: {
		frontBumper: string[];
		rearBumper: string[];
		spoiler: string[];
		lights: string[];
		wheels: string[];
	};
	extras: Record<string, { mount: string }>;
	finishes: string[];
	stripes: string[];
	energy: string[];
	personalities: Record<string, Record<string, number>>;
	bandCeiling: number;
	mod: { keep: string; catalogAllowed: string[]; kitAllowed: string[] };
};

export const kit: Kit = kitJson;

// The design spec's body numbers and part slots (PLAN.md "Design spec"). Their ranges and ids live in the kit.
export const BODY_NUMBERS = ["length", "height", "roofline", "noseSlope", "flare"] as const;
export const PART_SLOTS = ["frontBumper", "rearBumper", "spoiler", "lights", "wheels"] as const;
export const STANCE_NUMBERS = ["rideHeight", "wheelSize"] as const;

export function classIds(k: Kit = kit): string[] {
	return Object.keys(k.classes);
}

export function templateIds(k: Kit = kit): string[] {
	return Object.keys(k.templates);
}

export function personalityIds(k: Kit = kit): string[] {
	return Object.keys(k.personalities);
}

export function extraIds(k: Kit = kit): string[] {
	return Object.keys(k.extras);
}
