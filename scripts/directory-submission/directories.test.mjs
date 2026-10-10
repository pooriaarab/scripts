// Schema validation for directories.json — the canonical list that the
// skills repo and the directory template's data/directories.json copy from.
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import test from "node:test";
import assert from "node:assert/strict";

const HERE = dirname(new URL(import.meta.url).pathname);
const table = JSON.parse(readFileSync(join(HERE, "directories.json"), "utf8"));

const METHODS = new Set([
  "api", "github-pr", "github-issue", "verify-deploy",
  "form-anon", "form-email", "form-account", "paid", "pitch", "crawl",
]);
const COSTS = new Set(["free", "freemium", "paid"]);

const tiers = Object.keys(table).filter((k) => k !== "version" && k !== "note");

test("has version and at least one tier", () => {
  assert.ok(table.version >= 1);
  assert.ok(tiers.length > 0);
});

test("every entry carries the required fields", () => {
  for (const tier of tiers) {
    assert.ok(Array.isArray(table[tier]), `${tier} is not an array`);
    for (const e of table[tier]) {
      assert.ok(e.name?.length > 0, `${tier}: missing name`);
      assert.match(e.url ?? "", /^https:\/\//, `${tier}/${e.name}: url must be https`);
      assert.ok(e.submit?.length > 0, `${tier}/${e.name}: missing submit`);
      assert.ok(e.gate?.length > 0, `${tier}/${e.name}: missing gate`);
      assert.ok(METHODS.has(e.method), `${tier}/${e.name}: bad method "${e.method}"`);
      if (e.cost !== undefined) assert.ok(COSTS.has(e.cost), `${tier}/${e.name}: bad cost "${e.cost}"`);
      if (e.dr !== undefined) assert.ok(Number.isInteger(e.dr) && e.dr >= 0 && e.dr <= 100, `${tier}/${e.name}: bad dr`);
    }
  }
});

test("no duplicate directory names across tiers", () => {
  const seen = new Set();
  for (const tier of tiers) {
    for (const e of table[tier]) {
      assert.ok(!seen.has(e.name), `duplicate entry: ${e.name}`);
      seen.add(e.name);
    }
  }
});

test("automatable flag matches method for mcp tier", () => {
  for (const e of table.mcp ?? []) {
    if (e.automatable === "agent") {
      assert.ok(["api", "github-pr", "github-issue"].includes(e.method), `${e.name}: automatable but method is ${e.method}`);
    }
  }
});
