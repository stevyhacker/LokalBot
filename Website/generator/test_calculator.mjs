import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";

const require = createRequire(import.meta.url);
const __dirname = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(__dirname, "..", "..");
const publicDir = path.join(repoRoot, "Website", "public");
const C = require(path.join(publicDir, "calculator.js"));

test("calculator preloads all 10 verified competitor tools and tiers", () => {
  const byId = new Map(C.TOOLS.map((t) => [t.id, t]));
  assert.equal(C.TOOLS.length, 10);
  assert.equal(byId.get("granola").tiers[0].monthlyUsd, 14);
  assert.deepEqual(byId.get("wispr").tiers.map((t) => t.monthlyUsd), [15, 12]);
  assert.deepEqual(byId.get("otter").tiers.map((t) => t.monthlyUsd), [8.33, 19.99]);
  assert.deepEqual(byId.get("fireflies").tiers.map((t) => t.monthlyUsd), [10, 19]);
  assert.deepEqual(byId.get("fathom").tiers.map((t) => t.monthlyUsd), [16, 25]);
  assert.equal(byId.get("notion").tiers[0].monthlyUsd, 20);
  assert.equal(byId.get("readai").tiers[0].monthlyUsd, 15);
  assert.equal(byId.get("superwhisper").tiers[0].monthlyUsd, 8.49);
  assert.equal(byId.get("screenpipe").tiers[0].monthlyUsd, 21);
  assert.deepEqual(byId.get("openwhispr").tiers.map((t) => t.monthlyUsd), [8, 16]);
});

test("calculate computes 1-year spend, 3-year spend, and cloud audio GB accurately", () => {
  const res = C.calculate({
    tools: ["granola", "wispr"],
    seats: 5,
    hours: 12,
    tiers: { wispr: "pro_annual" },
  });
  assert.equal(res.perSeatMonthlyUsd, 26);
  assert.equal(res.monthlyTotalUsd, 130);
  assert.equal(res.oneYearUsd, 1560);
  assert.equal(res.threeYearUsd, 4680);
  assert.equal(res.hasCloudAudio, true);
  assert.equal(res.annualAudioHours, 3000);
  assert.equal(res.annualAudioGb, 86.4);

  const localOnly = C.calculate({
    tools: ["superwhisper", "screenpipe"],
    seats: 2,
    hours: 10,
  });
  assert.equal(localOnly.hasCloudAudio, false);
  assert.equal(localOnly.annualAudioHours, 0);
  assert.equal(localOnly.annualAudioGb, 0);
  assert.equal(localOnly.oneYearUsd, 707.76);

  const clamped = C.calculate({ tools: ["granola"], seats: 999, hours: -5 });
  assert.equal(clamped.seats, 100);
  assert.equal(clamped.hours, 1);
});

test("URL query state and receipt PNG card spec round-trip cleanly", () => {
  const parsed = C.parseState("?tools=granola,wispr&seats=5&hours=12");
  assert.deepEqual(parsed.tools, ["granola", "wispr"]);
  assert.equal(parsed.seats, 5);
  assert.equal(parsed.hours, 12);

  const qs = C.serializeState(parsed);
  assert.equal(qs, "tools=granola%2Cwispr&seats=5&hours=12");
  assert.deepEqual(C.parseState("?" + qs), parsed);

  const res = C.calculate(parsed);
  const spec = C.buildReceiptCardSpec(parsed, res);
  assert.equal(spec.footer, "lokalbot.com/calculator");
  assert.equal(spec.oneYearDisplay, "$1,740");
  assert.equal(spec.threeYearDisplay, "$5,220");
  assert.equal(spec.lokalbotSpend, "$0");
  assert.equal(spec.lokalbotAudio, "0 bytes uploaded");
  assert.ok(spec.shareUrl.startsWith("https://www.lokalbot.com/calculator?"));
});

test("calculator.html SEO metadata, JSON-LD, CSS fallbacks, and links are valid", () => {
  const html = fs.readFileSync(path.join(publicDir, "calculator.html"), "utf8");
  assert.ok(html.includes('<link rel="canonical" href="https://www.lokalbot.com/calculator" />'));
  assert.ok(html.includes('property="og:image:alt"'));
  assert.ok(html.includes('data-download data-asset="mac"'));
  assert.ok(html.includes("prefers-reduced-transparency: reduce"));
  assert.ok(html.includes("@supports not ((-webkit-backdrop-filter: blur(1px))"));

  const titleMatch = html.match(/<title>([^<]+)<\/title>/);
  assert.ok(titleMatch);
  const decodedTitle = titleMatch[1].replace(/&amp;/g, "&");
  assert.ok(decodedTitle.length <= 65, `Title too long (${decodedTitle.length})`);

  const descMatch = html.match(/<meta name="description" content="([^"]+)"/);
  assert.ok(descMatch);
  assert.ok(descMatch[1].length <= 160, `Description too long (${descMatch[1].length})`);

  assert.equal(html.match(/href="(?:\/|https:\/\/www\.lokalbot\.com\/)[^"]*\.html(?:[#?][^"]*)?"/g), null);
  assert.ok(!html.includes("\u2014"), "calculator.html must not contain em-dashes");
  assert.ok(!html.includes("\u2192"), "calculator.html must not contain arrow chains");

  const ldMatch = html.match(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/);
  assert.ok(ldMatch, "Missing JSON-LD");
  const graph = JSON.parse(ldMatch[1])["@graph"];
  const types = new Set(graph.map((n) => n["@type"]));
  assert.ok(types.has("WebApplication"));
  assert.ok(types.has("BreadcrumbList"));
  assert.ok(types.has("FAQPage"));
  const appNode = graph.find((n) => n["@type"] === "WebApplication");
  assert.equal(appNode.publisher["@id"], "https://www.lokalbot.com/#organization");
  assert.equal(appNode.about["@id"], "https://www.lokalbot.com/#software");
});
