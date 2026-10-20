// Loads tests/suite/prompts.json and fills each {{brand}} with a real name from lib/banned-names.txt (the same
// fixed choice every run), so the suite file itself never spells a real name. Read by: run.ts and the tests.
import { readFileSync } from "node:fs";
import { exampleFor, loadBannedPatterns } from "../../lib/brands.ts";

export type Category =
	| "normal"
	| "brand"
	| "franchise"
	| "offensive"
	| "injection"
	| "fastest"
	| "gibberish"
	| "non_english";

export type Expect = "spec" | "refusal" | "either";

export type CarFixture = { kind: "kit" | "catalog"; classId: string; current: unknown };

type RawDesign = { id: string; category: Category; classId: string | null; expect: Expect; prompt: string; forbid?: string[] };
type RawMod = { id: string; category: Category; car: string; expect: Expect; prompt: string; forbid?: string[] };

export type SuiteFile = {
	note: string;
	cars: Record<string, CarFixture>;
	design: RawDesign[];
	mod: RawMod[];
};

export type SuiteCase = {
	id: string;
	endpoint: "design" | "mod";
	category: Category;
	expect: Expect;
	prompt: string; // with every {{brand}} filled in
	forbid: string[]; // franchise words plus the filled-in names
	classId: string | null;
	car?: CarFixture;
};

export const BRAND_SLOT = "{{brand}}";

// Spreads the slots over the whole list: the n-th slot of the suite takes the (n * STRIDE)-th name.
const STRIDE = 7;

export function loadSuiteFile(): SuiteFile {
	return JSON.parse(readFileSync(new URL("./prompts.json", import.meta.url), "utf8")) as SuiteFile;
}

export function expandSuite(file: SuiteFile = loadSuiteFile(), names: string[] = loadBannedPatterns().map(exampleFor)): SuiteCase[] {
	let slot = 0;
	const fill = (prompt: string): { prompt: string; used: string[] } => {
		const used: string[] = [];
		const filled = prompt.split(BRAND_SLOT).reduce((text, part, index) => {
			if (index === 0) {
				return part;
			}
			const name = names[(slot * STRIDE) % names.length] ?? "";
			slot += 1;
			used.push(name);
			return `${text}${name}${part}`;
		}, "");
		return { prompt: filled, used };
	};
	const cases: SuiteCase[] = [];
	for (const entry of file.design) {
		const { prompt, used } = fill(entry.prompt);
		cases.push({
			id: entry.id,
			endpoint: "design",
			category: entry.category,
			expect: entry.expect,
			prompt,
			forbid: [...(entry.forbid ?? []), ...used],
			classId: entry.classId,
		});
	}
	for (const entry of file.mod) {
		const car = file.cars[entry.car];
		if (car === undefined) {
			throw new Error(`${entry.id}: unknown car ${entry.car}`);
		}
		const { prompt, used } = fill(entry.prompt);
		cases.push({
			id: entry.id,
			endpoint: "mod",
			category: entry.category,
			expect: entry.expect,
			prompt,
			forbid: [...(entry.forbid ?? []), ...used],
			classId: car.classId,
			car,
		});
	}
	return cases;
}

// Whole-word, case-insensitive: does any string in `value` contain one of the words?
export function findForbidden(value: unknown, words: string[]): string | null {
	const text = JSON.stringify(value) ?? "";
	for (const word of words) {
		const escaped = word.replace(/[.*+?^${}()|[\]\\]/gu, "\\$&");
		if (new RegExp(`(?<![\\p{L}\\p{N}])${escaped}(?![\\p{L}\\p{N}])`, "iu").test(text)) {
			return word;
		}
	}
	return null;
}
