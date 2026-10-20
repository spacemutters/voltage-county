// npm run suite: sends the 90 prompts in tests/suite/prompts.json (60 new cars, 30 mods) to a DEPLOYED designer
// and checks every answer is a valid, already-clamped spec or a friendly refusal, with no banned brand or model
// name and no franchise word in any field. It spends real Claude tokens (well under 10 cents a run), so it is not
// part of npm test; run it only when Davis says yes. See README.md "Run the prompt suite".
//   SUITE_URL         the deployment, e.g. https://your-project.vercel.app (required)
//   SUITE_KEY         the shared secret, the same value as ROBLOX_SHARED_SECRET (required)
//   SUITE_ONLY        design or mod: run just one half
//   SUITE_LIMIT       run only the first N prompts
//   SUITE_USE_CACHE   1: allow cached answers (by default every prompt is designed fresh)
//   SUITE_CONCURRENCY requests at a time (default 3)
import { mkdirSync, writeFileSync } from "node:fs";
import { isDeepStrictEqual } from "node:util";
import { bannedRegex, findBanned } from "../../lib/brands.ts";
import { kit } from "../../lib/kit.ts";
import { charCount, sha256Hex } from "../../lib/normalize.ts";
import { readDesign, readMod } from "../../lib/schema.ts";
import { expandSuite, findForbidden, type SuiteCase } from "./data.ts";

const REQUEST_TIMEOUT_MS = 45_000;
const DEFAULT_CONCURRENCY = 3;

type CaseResult = {
	id: string;
	endpoint: "design" | "mod";
	category: string;
	expect: string;
	prompt: string;
	status: number;
	ms: number;
	got: "spec" | "refusal" | "other";
	problems: string[];
	notes: string[];
	reply: unknown;
};

function env(name: string): string | undefined {
	const value = process.env[name]?.trim();
	return value === undefined || value === "" ? undefined : value;
}

function check(test: SuiteCase, status: number, reply: unknown): { got: CaseResult["got"]; problems: string[] } {
	const problems: string[] = [];
	const body = (reply ?? {}) as { ok?: unknown; spec?: unknown; refusal?: unknown; cached?: unknown };
	let got: CaseResult["got"] = "other";
	if (status === 429) {
		problems.push("stopped by limits, the spend cap or the off switch (see designer_settings)");
	} else if (status !== 200) {
		problems.push(`HTTP ${status}`);
	} else if (body.ok === true) {
		got = "spec";
		const final =
			test.endpoint === "design"
				? readDesign(body.spec, { classId: test.classId, promptHash: "0".repeat(64) })
				: readMod(body.spec, { kind: test.car?.kind ?? "kit", classId: test.classId ?? "" });
		if (final === null) {
			problems.push("spec failed validation");
		} else if (!isDeepStrictEqual(final, body.spec)) {
			problems.push("spec was not fully clamped by the backend");
		}
		if (typeof body.cached !== "boolean") {
			problems.push("missing cached flag");
		}
	} else if (body.ok === false) {
		got = "refusal";
		if (typeof body.refusal !== "string" || body.refusal.trim() === "" || charCount(body.refusal) > kit.limits.refusal) {
			problems.push("refusal is not a short message");
		}
	} else {
		problems.push("reply is neither { ok: true, spec } nor { ok: false, refusal }");
	}
	const banned = findBanned(reply, bannedRegex());
	if (banned !== null) {
		problems.push(`banned name in the reply: ${banned}`);
	}
	const forbidden = findForbidden(reply, test.forbid);
	if (forbidden !== null) {
		problems.push(`franchise or brand word in the reply: ${forbidden}`);
	}
	return { got, problems };
}

async function runCase(test: SuiteCase, base: string, key: string, useCache: boolean): Promise<CaseResult> {
	const common = { kitVersion: kit.kitVersion, userHash: sha256Hex(`voltage-suite:${test.id}`), prompt: test.prompt, reroll: !useCache };
	const payload =
		test.endpoint === "design"
			? { ...common, classId: test.classId }
			: { ...common, kind: test.car?.kind, classId: test.car?.classId, current: test.car?.current };
	const started = performance.now();
	let status = 0;
	let reply: unknown = null;
	const notes: string[] = [];
	try {
		const response = await fetch(`${base}/api/${test.endpoint}`, {
			method: "POST",
			headers: { "content-type": "application/json", "x-api-key": key },
			body: JSON.stringify(payload),
			signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
		});
		status = response.status;
		reply = await response.json().catch(() => null);
	} catch (error) {
		notes.push(error instanceof Error ? error.name : "request failed");
	}
	const ms = Math.round(performance.now() - started);
	const { got, problems } = check(test, status, reply);
	if (status === 0) {
		problems.push(`no answer (${notes.join(", ")})`);
	}
	if (test.expect !== "either" && got !== "other" && got !== test.expect) {
		notes.push(`expected a ${test.expect}, got a ${got}`);
	}
	return { id: test.id, endpoint: test.endpoint, category: test.category, expect: test.expect, prompt: test.prompt, status, ms, got, problems, notes, reply };
}

function percentile(values: number[], share: number): number {
	const sorted = [...values].sort((a, b) => a - b);
	return sorted[Math.min(sorted.length - 1, Math.floor(sorted.length * share))] ?? 0;
}

function describe(result: CaseResult): string {
	const body = (result.reply ?? {}) as { spec?: { name?: string; summary?: string }; refusal?: string };
	if (result.got === "spec") {
		return `"${body.spec?.name ?? body.spec?.summary ?? ""}"`;
	}
	if (result.got === "refusal") {
		return `refusal: "${body.refusal ?? ""}"`;
	}
	return "";
}

async function main(): Promise<void> {
	const base = env("SUITE_URL")?.replace(/\/+$/u, "");
	const key = env("SUITE_KEY");
	if (base === undefined || key === undefined) {
		console.error("Set SUITE_URL (the deployment) and SUITE_KEY (the shared secret) first. See README.md.");
		process.exit(2);
	}
	const only = env("SUITE_ONLY");
	const limit = Number(env("SUITE_LIMIT") ?? "0");
	const concurrency = Math.max(1, Number(env("SUITE_CONCURRENCY") ?? DEFAULT_CONCURRENCY));
	let cases = expandSuite().filter((test) => only === undefined || test.endpoint === only);
	if (limit > 0) {
		cases = cases.slice(0, limit);
	}
	console.log(`Running ${cases.length} prompts against ${base} (${concurrency} at a time)...`);

	const results: CaseResult[] = new Array(cases.length);
	let next = 0;
	const worker = async (): Promise<void> => {
		while (next < cases.length) {
			const index = next;
			next += 1;
			const test = cases[index];
			if (test === undefined) {
				continue;
			}
			const result = await runCase(test, base, key, env("SUITE_USE_CACHE") === "1");
			results[index] = result;
			const mark = result.problems.length === 0 ? "PASS" : "FAIL";
			const extra = [...result.problems, ...result.notes].join("; ");
			console.log(`${mark} ${result.id.padEnd(4)} ${result.category.padEnd(11)} ${String(result.ms).padStart(6)} ms  ${describe(result)}${extra === "" ? "" : `  [${extra}]`}`);
		}
	};
	await Promise.all(Array.from({ length: concurrency }, worker));

	const failed = results.filter((result) => result.problems.length > 0);
	const byCategory = new Map<string, { pass: number; total: number }>();
	for (const result of results) {
		const entry = byCategory.get(result.category) ?? { pass: 0, total: 0 };
		entry.total += 1;
		entry.pass += result.problems.length === 0 ? 1 : 0;
		byCategory.set(result.category, entry);
	}
	console.log("\nBy category:");
	for (const [category, entry] of byCategory) {
		console.log(`  ${category.padEnd(11)} ${entry.pass}/${entry.total}`);
	}
	const times = results.filter((result) => result.status === 200).map((result) => result.ms);
	console.log(`Answer time: p50 ${percentile(times, 0.5)} ms, p95 ${percentile(times, 0.95)} ms`);
	console.log(`Specs: ${results.filter((r) => r.got === "spec").length}, refusals: ${results.filter((r) => r.got === "refusal").length}`);

	const folder = new URL("./results/", import.meta.url);
	mkdirSync(folder, { recursive: true });
	const file = new URL(`./${new Date().toISOString().replace(/[:.]/gu, "-")}.json`, folder);
	writeFileSync(file, JSON.stringify({ base, ranAt: new Date().toISOString(), results }, null, 2));
	console.log(`Full answers saved in tests/suite/results/.`);

	if (failed.length > 0) {
		console.log(`\n${failed.length} of ${results.length} FAILED: ${failed.map((result) => result.id).join(", ")}`);
		process.exit(1);
	}
	console.log(`\nALL ${results.length} PASSED`);
}

await main();
