// The hosted privacy page (public/privacy.html, served at /privacy with vercel.json cleanUrls) is the repo's
// docs/privacy.html, and it promises the retention the backend enforces (USAGE_RETENTION_DAYS).
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { USAGE_RETENTION_DAYS } from "../lib/limits.ts";

const hosted = new URL("../public/privacy.html", import.meta.url);
const source = new URL("../../docs/privacy.html", import.meta.url);

test("public/privacy.html is a copy of docs/privacy.html", () => {
	assert.equal(
		readFileSync(hosted, "utf8"),
		readFileSync(source, "utf8"),
		"copy docs/privacy.html to backend/public/privacy.html",
	);
});

test("the privacy page promises the retention the backend enforces", () => {
	const page = readFileSync(hosted, "utf8");
	assert.ok(page.includes(`${USAGE_RETENTION_DAYS} days`));
});

test("/privacy answers without the .html (cleanUrls)", () => {
	const config = JSON.parse(readFileSync(new URL("../vercel.json", import.meta.url), "utf8")) as { cleanUrls?: boolean };
	assert.equal(config.cleanUrls, true);
});
