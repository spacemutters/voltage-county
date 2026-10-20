// The prompt suite's data is complete (60 new-car + 30 mod prompts over every category, valid fixtures, prompts
// inside the kit limit), and no backend file spells a real carmaker or model name (CLAUDE.md hard rule 4); only
// lib/banned-names.txt, the blocklist itself, holds them. scripts/check.ps1 doesn't scan backend/, so this does.
import assert from "node:assert/strict";
import { readdirSync, readFileSync, statSync } from "node:fs";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { bannedRegex, findBanned } from "../lib/brands.ts";
import { kit } from "../lib/kit.ts";
import { charCount } from "../lib/normalize.ts";
import { readDesign } from "../lib/schema.ts";
import { BRAND_SLOT, expandSuite, findForbidden, loadSuiteFile, type Category } from "./suite/data.ts";

const CATEGORIES: Category[] = ["normal", "brand", "franchise", "offensive", "injection", "fastest", "gibberish", "non_english"];

test("the suite has 60 new-car and 30 mod prompts covering every category", () => {
	const file = loadSuiteFile();
	assert.equal(file.design.length, 60);
	assert.equal(file.mod.length, 30);
	for (const list of [file.design, file.mod]) {
		for (const category of CATEGORIES) {
			assert.ok(list.some((entry) => entry.category === category), category);
		}
	}
	const ids = [...file.design, ...file.mod].map((entry) => entry.id);
	assert.equal(new Set(ids).size, ids.length, "ids are unique");
	assert.ok(file.design.some((entry) => entry.classId === null), "surprise me is covered");
	assert.ok(file.mod.some((entry) => file.cars[entry.car]?.kind === "catalog"));
	assert.ok(file.mod.some((entry) => file.cars[entry.car]?.kind === "kit"));
});

test("every expanded prompt fits the kit limit and brand prompts carry real names", () => {
	const cases = expandSuite();
	assert.equal(cases.length, 90);
	for (const suiteCase of cases) {
		const max = suiteCase.endpoint === "design" ? kit.limits.promptChars : kit.limits.modPromptChars;
		assert.ok(charCount(suiteCase.prompt) <= max, suiteCase.id);
		assert.equal(suiteCase.prompt.includes(BRAND_SLOT), false, suiteCase.id);
		if (suiteCase.classId !== null && suiteCase.endpoint === "design") {
			assert.ok(kit.classes[suiteCase.classId], `${suiteCase.id}: ${suiteCase.classId}`);
		}
	}
	const withNames = cases.filter((suiteCase) => findBanned(suiteCase.prompt, bannedRegex()) !== null);
	assert.ok(withNames.length >= 15, `${withNames.length} prompts use real names`);
});

test("the kit-car fixtures are valid design specs", () => {
	const file = loadSuiteFile();
	for (const [id, car] of Object.entries(file.cars)) {
		if (car.kind === "kit") {
			const spec = readDesign(car.current, { classId: car.classId, promptHash: "0".repeat(64) });
			assert.deepEqual(spec, car.current, id);
		}
	}
});

test("findForbidden matches whole words only", () => {
	assert.equal(findForbidden({ name: "Bat Runner" }, ["Batman"]), null);
	assert.equal(findForbidden({ name: "the batman edition" }, ["Batman"]), "Batman");
	assert.equal(findForbidden({ name: "Kitty Cruiser" }, ["KITT"]), null);
});

function filesUnder(folder: string): string[] {
	const out: string[] = [];
	for (const name of readdirSync(folder)) {
		if (name === "node_modules" || name === ".vercel" || name === "results" || name.startsWith(".")) {
			continue;
		}
		const path = `${folder}/${name}`;
		if (statSync(path).isDirectory()) {
			out.push(...filesUnder(path));
		} else {
			out.push(path);
		}
	}
	return out;
}

test("no backend file except the blocklist spells a real carmaker or model name", () => {
	const root = fileURLToPath(new URL("..", import.meta.url)).replace(/[\\/]+$/u, "");
	const files = filesUnder(root).filter(
		(path) => !path.endsWith("banned-names.txt") && !path.endsWith("package-lock.json") && /\.(ts|json|md|sql|txt)$/u.test(path),
	);
	assert.ok(files.length > 15);
	for (const path of files) {
		const lines = readFileSync(path, "utf8").split(/\r?\n/u);
		lines.forEach((line, index) => {
			const hit = findBanned(line, bannedRegex());
			assert.equal(hit, null, `${path}:${index + 1}: ${hit}`);
		});
	}
});
