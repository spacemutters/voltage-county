// The Claude call: claude-haiku-5-5 with structured outputs (output_config.format = the kit's JSON schema), prompt
// caching on the static system prompt, low effort (a short, well-specified answer), a per-call timeout and at
// most one SDK retry inside the request's time budget. The client is injected so the tests can mock it.
// Read by: handler.ts and the tests.
import Anthropic, { APIConnectionTimeoutError } from "@anthropic-ai/sdk";
import { CALL_TIMEOUT_MS, MIN_CALL_MS, NO_TOKENS, type TokenCounts } from "./limits.ts";
import { STRICT_NOTE, SYSTEM_PROMPT } from "./prompt.ts";
import type { JsonSchema } from "./schema.ts";

export const MODEL = "claude-haiku-5-5";

// A spec is a few hundred output tokens; the rest leaves room for adaptive thinking (on by default on this model,
// and counted against max_tokens) so an answer is never cut off.
export const MAX_TOKENS = 4096;

// Haiku 5.5 defaults to medium; low keeps the answer fast and cheap for this short, fully specified task.
export const EFFORT = "low";

// The parts of a Messages API response the backend reads (a real Anthropic.Message has all of them).
export type ClaudeReply = {
	content: Anthropic.ContentBlock[];
	stop_reason: Anthropic.StopReason | null;
	usage: Pick<
		Anthropic.Usage,
		"input_tokens" | "output_tokens" | "cache_read_input_tokens" | "cache_creation_input_tokens"
	>;
};

export type CallOptions = { timeout: number; maxRetries: number };

export type MessagesClient = {
	create(body: Anthropic.MessageCreateParamsNonStreaming, options: CallOptions): PromiseLike<ClaudeReply>;
};

export function createMessagesClient(apiKey: string): MessagesClient {
	const client = new Anthropic({ apiKey, timeout: CALL_TIMEOUT_MS, maxRetries: 1 });
	return { create: (body, options) => client.messages.create(body, options) };
}

export function buildRequest(
	schema: JsonSchema,
	userText: string,
	strict: boolean,
): Anthropic.MessageCreateParamsNonStreaming {
	const content: Anthropic.TextBlockParam[] = [{ type: "text", text: userText }];
	if (strict) {
		content.push({ type: "text", text: STRICT_NOTE });
	}
	return {
		model: MODEL,
		max_tokens: MAX_TOKENS,
		system: [{ type: "text", text: SYSTEM_PROMPT, cache_control: { type: "ephemeral" } }],
		messages: [{ role: "user", content }],
		output_config: { effort: EFFORT, format: { type: "json_schema", schema } },
	};
}

// How long one call may take with `remainingMs` of the request's budget left, and whether the SDK may retry it
// (one retry only when both tries fit). null: not enough time to start a call.
export function callPlan(remainingMs: number): CallOptions | null {
	if (remainingMs < MIN_CALL_MS) {
		return null;
	}
	const half = Math.floor(remainingMs / 2);
	if (half >= MIN_CALL_MS) {
		return { timeout: Math.min(CALL_TIMEOUT_MS, half), maxRetries: 1 };
	}
	return { timeout: Math.min(CALL_TIMEOUT_MS, remainingMs), maxRetries: 0 };
}

export type ClaudeOutcome =
	| { kind: "json"; value: unknown; tokens: TokenCounts }
	| { kind: "refusal"; tokens: TokenCounts } // the model's safety classifier declined (stop_reason "refusal")
	| { kind: "error"; reason: "timeout" | "truncated" | "invalid" | "api"; tokens: TokenCounts; detail: string };

export function tokensOf(usage: ClaudeReply["usage"]): TokenCounts {
	return {
		inputTokens: usage.input_tokens,
		outputTokens: usage.output_tokens,
		cacheReadTokens: usage.cache_read_input_tokens ?? 0,
		cacheWriteTokens: usage.cache_creation_input_tokens ?? 0,
	};
}

function describe(error: unknown): string {
	if (error instanceof Anthropic.APIError) {
		return `${error.name} ${error.status ?? ""}`.trim();
	}
	return error instanceof Error ? error.name : "unknown error";
}

export async function askClaude(
	client: MessagesClient,
	request: Anthropic.MessageCreateParamsNonStreaming,
	options: CallOptions,
): Promise<ClaudeOutcome> {
	let reply: ClaudeReply;
	try {
		reply = await client.create(request, options);
	} catch (error) {
		const reason = error instanceof APIConnectionTimeoutError ? "timeout" : "api";
		return { kind: "error", reason, tokens: NO_TOKENS, detail: describe(error) };
	}
	const tokens = tokensOf(reply.usage);
	if (reply.stop_reason === "refusal") {
		return { kind: "refusal", tokens };
	}
	if (reply.stop_reason === "max_tokens") {
		return { kind: "error", reason: "truncated", tokens, detail: "max_tokens" };
	}
	if (reply.stop_reason !== "end_turn") {
		return { kind: "error", reason: "invalid", tokens, detail: `stop_reason ${String(reply.stop_reason)}` };
	}
	const text = reply.content
		.filter((block): block is Anthropic.TextBlock => block.type === "text")
		.map((block) => block.text)
		.join("");
	try {
		return { kind: "json", value: JSON.parse(text) as unknown, tokens };
	} catch {
		return { kind: "error", reason: "invalid", tokens, detail: "not JSON" };
	}
}
