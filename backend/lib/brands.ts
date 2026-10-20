// The brand blocklist: lib/banned-names.txt is a copy of scripts/banned-names.txt (npm run sync-kit), one regular
// expression per line, matched case-insensitively as whole words. Every string in an AI result is scanned; a hit
// means the result never reaches the game (handler.ts retries once with a stricter note, then refuses kindly).
// Read by: handler.ts, the tests and the prompt suite runner.
import { readFileSync } from "node:fs";

export function parseBannedList(text: string): string[] {
	return text
		.split(/\r?\n/u)
		.map((line) => line.trim())
		.filter((line) => line !== "" && !line.startsWith("#"));
}

export function compileBanned(patterns: string[]): RegExp {
	return new RegExp(`\\b(?:${patterns.join("|")})\\b`, "iu");
}

// The text the blocklist sees: accents removed (NFKD turns full-width letters into plain ones too), then the
// same text with separators turned into spaces and with separators removed, so spelling a name with dashes,
// dots or underscores doesn't slip past. Apostrophes are only removed, never turned into spaces, so a
// possessive "'s" never becomes a word of its own.
export function textVariants(text: string): string[] {
	const plain = text.normalize("NFKD").replace(/\p{M}/gu, "");
	return [plain, plain.replace(/[-_.·•/\\|]+/gu, " "), plain.replace(/[-_.·•'’/\\|]+/gu, "")];
}

// The first banned name found in any string anywhere inside `value` (objects and arrays are walked), or null.
export function findBanned(value: unknown, banned: RegExp): string | null {
	if (typeof value === "string") {
		for (const variant of textVariants(value)) {
			const match = banned.exec(variant);
			if (match) {
				return match[0];
			}
		}
		return null;
	}
	if (Array.isArray(value)) {
		for (const item of value) {
			const hit = findBanned(item, banned);
			if (hit !== null) {
				return hit;
			}
		}
		return null;
	}
	if (value !== null && typeof value === "object") {
		for (const item of Object.values(value)) {
			const hit = findBanned(item, banned);
			if (hit !== null) {
				return hit;
			}
		}
	}
	return null;
}

// One plain example of text each pattern matches ("X?" keeps X, "[ab]" picks a). The tests and the prompt suite
// use these so no real name has to be written anywhere else in the backend.
export function exampleFor(pattern: string): string {
	return pattern
		.replace(/\[([^\]])[^\]]*\]/gu, "$1")
		.replace(/\\(.)/gu, "$1")
		.replace(/\?/gu, "");
}

export function loadBannedPatterns(): string[] {
	return parseBannedList(readFileSync(new URL("./banned-names.txt", import.meta.url), "utf8"));
}

let cached: RegExp | undefined;

export function bannedRegex(): RegExp {
	cached ??= compileBanned(loadBannedPatterns());
	return cached;
}
