// Text helpers: prompt normalization and hashing (the cache key and the blocklist key), canonical JSON for the
// mod car key, and the string cleaning every AI text field goes through. Read by: handler.ts, schema.ts, brands.ts.
import { createHash } from "node:crypto";

// Control and format characters (zero-width spaces and the like) are dropped from every text we keep.
const INVISIBLE = /[\p{Cc}\p{Cf}]/gu;

export function charCount(text: string): number {
	return Array.from(text).length;
}

// Cleans one text value: NFC, no invisible characters, single spaces, trimmed, cut to `maxChars` characters.
export function cleanText(text: string, maxChars: number): string {
	const cleaned = text.normalize("NFC").replace(INVISIBLE, " ").replace(/\s+/gu, " ").trim();
	const chars = Array.from(cleaned);
	return chars.length > maxChars ? chars.slice(0, maxChars).join("").trimEnd() : cleaned;
}

// Letters and digits that survived the game's TextService filter (it masks blocked words with '#').
export function meaningfulChars(text: string): number {
	return charCount(text.replace(/[^\p{L}\p{N}]/gu, ""));
}

// The same description written two ways ("Red  sports car!" / "red sports car") normalizes to the same text.
// TextService masks ("####") collapse to a single '#' so a masked word still counts as one word.
export function normalizePrompt(text: string): string {
	return text
		.normalize("NFKC")
		.toLowerCase()
		.replace(INVISIBLE, "")
		.replace(/#+/gu, " # ")
		.replace(/[^\p{L}\p{N}#]+/gu, " ")
		.trim();
}

export function sha256Hex(text: string): string {
	return createHash("sha256").update(text, "utf8").digest("hex");
}

export function hashPrompt(text: string): string {
	return sha256Hex(normalizePrompt(text));
}

// JSON with object keys sorted at every level, so the same car always hashes the same way.
export function canonicalJson(value: unknown): string {
	return JSON.stringify(sortKeys(value));
}

function sortKeys(value: unknown): unknown {
	if (Array.isArray(value)) {
		return value.map(sortKeys);
	}
	if (value !== null && typeof value === "object") {
		const sorted: Record<string, unknown> = {};
		for (const key of Object.keys(value).sort()) {
			sorted[key] = sortKeys((value as Record<string, unknown>)[key]);
		}
		return sorted;
	}
	return value;
}

export function utf8Bytes(text: string): number {
	return Buffer.byteLength(text, "utf8");
}
