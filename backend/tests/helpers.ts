// Test helpers: a mocked Claude client, valid sample answers, request builders and dependencies wired to the
// in-memory store. No test touches the network or the real Anthropic API.
import type Anthropic from "@anthropic-ai/sdk";
import type { CallOptions, ClaudeReply, MessagesClient } from "../lib/claude.ts";
import { bannedRegex, exampleFor, loadBannedPatterns } from "../lib/brands.ts";
import type { Deps } from "../lib/handler.ts";
import { MemoryStore } from "../lib/store.ts";

export const SECRET = "test-shared-secret-0123456789";
export const USER_HASH = "a".repeat(64);
export const NOW = Date.UTC(2026, 9, 20, 12, 0, 0);

// A real name from the blocklist, so no test file has to spell one out.
export function bannedExample(index = 0): string {
	const patterns = loadBannedPatterns();
	const pattern = patterns[index % patterns.length];
	if (pattern === undefined) {
		throw new Error("banned-names.txt is empty");
	}
	return exampleFor(pattern);
}

export function validDesign(overrides: Record<string, unknown> = {}): Record<string, unknown> {
	return {
		refusal: null,
		name: "Volt Comet",
		tagline: "Quick, bright and ready for the coast road",
		class: "sports",
		energy: "battery",
		personality: "track",
		meshPrompt: "low two-door sports coupe, smooth rounded nose, short tail, wide hips, 1990s style",
		body: { template: "coupe", length: 0.5, height: 0.4, roofline: 0.3, noseSlope: 0.8, flare: 0.6 },
		parts: { frontBumper: "sport", rearBumper: "diffuser", spoiler: "lip", lights: "slim", wheels: "five_star" },
		paint: { primary: "#C81E1E", secondary: "#111111", finish: "metallic", stripe: "center" },
		stance: { rideHeight: -0.3, wheelSize: 0.6 },
		...overrides,
	};
}

export function validMod(overrides: Record<string, unknown> = {}): Record<string, unknown> {
	const same = { change: false, value: 0.5 };
	return {
		refusal: null,
		summary: "Lifted, chunky tires, roof rack, desert tan",
		body: { template: "keep", length: same, height: same, roofline: same, noseSlope: same, flare: same },
		parts: { frontBumper: "keep", rearBumper: "keep", spoiler: "keep", lights: "keep", wheels: "trail" },
		paint: { primary: "#C2A878", secondary: "keep", finish: "matte", stripe: "keep" },
		stance: { rideHeight: { change: true, value: 0.8 }, wheelSize: { change: true, value: 0.9 } },
		extras: ["roof_rack"],
		accessoryPrompt: "none",
		...overrides,
	};
}

type Usage = ClaudeReply["usage"];

export const USAGE: Usage = {
	input_tokens: 300,
	output_tokens: 400,
	cache_read_input_tokens: 1500,
	cache_creation_input_tokens: 0,
};

export function textReply(json: unknown, stop: Anthropic.StopReason = "end_turn", usage: Usage = USAGE): ClaudeReply {
	const text = typeof json === "string" ? json : JSON.stringify(json);
	return { content: [{ type: "text", text, citations: null }], stop_reason: stop, usage };
}

export type Step = ClaudeReply | Error;

export type FakeClaude = MessagesClient & {
	calls: Array<{ body: Anthropic.MessageCreateParamsNonStreaming; options: CallOptions }>;
};

// Answers with the given steps in order (an Error is thrown); the last step repeats.
export function fakeClaude(...steps: Step[]): FakeClaude {
	const calls: FakeClaude["calls"] = [];
	return {
		calls,
		async create(body, options) {
			calls.push({ body, options });
			const step = steps[Math.min(calls.length - 1, steps.length - 1)];
			if (step === undefined) {
				throw new Error("fakeClaude has no steps");
			}
			if (step instanceof Error) {
				throw step;
			}
			return step;
		},
	};
}

export type TestDeps = Deps & { store: MemoryStore; logs: string[]; clock: { now: number } };

export function makeDeps(options: { claude?: MessagesClient | null; store?: MemoryStore; secret?: string } = {}): TestDeps {
	const logs: string[] = [];
	const clock = { now: NOW };
	return {
		store: options.store ?? new MemoryStore(),
		claude: options.claude === undefined ? fakeClaude(textReply(validDesign())) : options.claude,
		secret: "secret" in options ? options.secret : SECRET,
		now: () => clock.now,
		banned: bannedRegex(),
		log: (line) => logs.push(line),
		logs,
		clock,
	};
}

export function designBody(overrides: Record<string, unknown> = {}): Record<string, unknown> {
	return { kitVersion: 1, userHash: USER_HASH, prompt: "a small red sports car with round lights", classId: "sports", ...overrides };
}

export function modBody(overrides: Record<string, unknown> = {}): Record<string, unknown> {
	return {
		kitVersion: 1,
		userHash: USER_HASH,
		prompt: "lift it, chunky off-road tires, roof rack, desert tan",
		kind: "kit",
		classId: "sports",
		current: validDesign(),
		...overrides,
	};
}

export function post(path: string, body: unknown, key: string | null = SECRET, method = "POST"): Request {
	const headers: Record<string, string> = { "content-type": "application/json" };
	if (key !== null) {
		headers["x-api-key"] = key;
	}
	return new Request(`https://designer.test${path}`, {
		method,
		headers,
		body: method === "GET" ? null : typeof body === "string" ? body : JSON.stringify(body),
	});
}

export async function json(response: Response): Promise<Record<string, unknown>> {
	return (await response.json()) as Record<string, unknown>;
}
