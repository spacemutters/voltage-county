// npm run sync-kit: copies the game's design kit and brand blocklist into lib/ so the deployed backend has them.
// Run it after any change to src/shared/Config/DesignKit.json or scripts/banned-names.txt (a test fails until you do).
import { copyFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const here = (relative: string): string => fileURLToPath(new URL(relative, import.meta.url));

const copies: Array<[string, string]> = [
	["../../src/shared/Config/DesignKit.json", "../lib/kit.json"],
	["../../scripts/banned-names.txt", "../lib/banned-names.txt"],
];

for (const [from, to] of copies) {
	copyFileSync(here(from), here(to));
	console.log(`copied ${from} -> ${to}`);
}
