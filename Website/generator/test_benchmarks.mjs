import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";

const require = createRequire(import.meta.url);
const __dirname = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(__dirname, "../..");
const publicDir = path.join(repoRoot, "Website", "public");

const lb = require(path.join(publicDir, "benchmarks.js"));
const data = JSON.parse(fs.readFileSync(path.join(publicDir, "benchmarks.json"), "utf8"));
const html = fs.readFileSync(path.join(publicDir, "benchmarks.html"), "utf8");

test("benchmarks.json schema, counts, and tracked GitHub source paths", () => {
  assert.equal(data.schemaVersion, 1);
  assert.match(data.updated, /^\d{4}-\d{2}-\d{2}$/);
  assert.equal(data.categories.length, 7);
  assert.equal(data.referenceStack.length, 6);

  const tracked = new Set(
    execFileSync("git", ["ls-files", "Benchmarks/"], { cwd: repoRoot, encoding: "utf8" })
      .trim()
      .split("\n")
      .filter(Boolean)
  );
  const trackedDirs = new Set();
  for (const file of tracked) {
    let dir = path.dirname(file);
    while (dir && dir !== ".") {
      trackedDirs.add(dir);
      dir = path.dirname(dir);
    }
  }

  let suiteCount = 0;
  let rowCount = 0;
  const seenSuiteIds = new Set();

  for (const cat of data.categories) {
    assert.ok(cat.id && cat.shortLabel && cat.label && cat.summary);
    assert.ok(cat.suites.length >= 1);
    for (const suite of cat.suites) {
      suiteCount++;
      assert.ok(!seenSuiteIds.has(suite.id), `duplicate suite id: ${suite.id}`);
      seenSuiteIds.add(suite.id);
      assert.match(suite.runDate, /^\d{4}-\d{2}-\d{2}$/);
      assert.ok(suite.hardware && suite.dataset && suite.note && suite.caveat);
      assert.ok(suite.columns.length >= 3);
      assert.ok(suite.rows.length >= 2);

      // Verify every reportUrl and harnessUrl resolves to a tracked repo file/dir
      const reportPrefix = "https://github.com/stevyhacker/LokalBot/blob/master/";
      assert.ok(suite.reportUrl.startsWith(reportPrefix), `unexpected reportUrl: ${suite.reportUrl}`);
      const relReport = suite.reportUrl.slice(reportPrefix.length);
      assert.ok(tracked.has(relReport), `reportUrl not tracked in git: ${relReport}`);

      const harnessPrefix = "https://github.com/stevyhacker/LokalBot/tree/master/";
      assert.ok(suite.harnessUrl.startsWith(harnessPrefix), `unexpected harnessUrl: ${suite.harnessUrl}`);
      const relHarness = suite.harnessUrl.slice(harnessPrefix.length);
      assert.ok(trackedDirs.has(relHarness), `harnessUrl not tracked in git: ${relHarness}`);

      // Verify every row populates all declared columns
      for (const row of suite.rows) {
        rowCount++;
        assert.ok(row.id && row.model && (row.kind === "local" || row.kind === "cloud"));
        for (const col of suite.columns) {
          assert.ok(
            row.values && row.values[col.key] && typeof row.values[col.key].display === "string",
            `missing cell ${col.key} on ${suite.id}/${row.id}`
          );
        }
      }
    }
  }

  assert.equal(suiteCount, 17);
  assert.ok(rowCount >= 50, `expected >= 50 rows, got ${rowCount}`);

  // Every reference stack card points to a real category + suite
  for (const item of data.referenceStack) {
    const resolved = lb.findCategoryAndSuite(data, item.suiteId);
    assert.equal(resolved.category.id, item.categoryId);
    assert.equal(resolved.suite.id, item.suiteId);
  }
});

test("benchmarks.js hash lookup, filtering, sorting, bars, scatter, and Markdown export", () => {
  // Hash resolution (category ID, suite ID, fallback)
  assert.equal(lb.findCategoryAndSuite(data, "#memory").suite.id, "memory-english");
  assert.equal(lb.findCategoryAndSuite(data, "#stt-llamacpp-vs-mlx").category.id, "stt");
  assert.equal(lb.findCategoryAndSuite(data, "#nonexistent").suite.id, "stt-ami-cloud");

  // Filtering cloud vs local on AMI STT
  const ami = lb.findCategoryAndSuite(data, "#stt-ami-cloud").suite;
  const localOnly = lb.filterRows(ami.rows, "local");
  assert.equal(localOnly.length, 2);
  assert.ok(localOnly.every((r) => r.kind === "local"));

  // Sorting asc/desc with missing values sinking to the bottom
  const diar = lb.findCategoryAndSuite(data, "#diarization-ami").suite;
  const bySpeedDesc = lb.sortRows(diar.rows, "speed", "desc");
  assert.equal(bySpeedDesc[0].id, "diar-nemotron-offline");
  assert.equal(bySpeedDesc[bySpeedDesc.length - 1].id, "diar-muse-cloud");
  const bySpeedAsc = lb.sortRows(diar.rows, "speed", "asc");
  assert.equal(bySpeedAsc[0].id, "diar-pyannote");
  assert.equal(bySpeedAsc[bySpeedAsc.length - 1].id, "diar-muse-cloud");

  // Proportional bar clamping
  assert.equal(lb.computeBarPercent(17.6, { max: 25 }), 70.4);
  assert.equal(lb.computeBarPercent(null, { max: 25 }), 0);
  assert.equal(lb.computeBarPercent(50, { max: 25 }), 100);

  // Memory Pareto scatter SVG renders all 5 English models
  const mem = lb.findCategoryAndSuite(data, "#memory-english").suite;
  const svg = lb.renderScatterSvg(mem, mem.rows);
  assert.ok(svg.includes("<svg"));
  for (const row of mem.rows) {
    assert.ok(svg.includes(row.model), `scatter missing ${row.model}`);
  }

  // Markdown table export includes headers, default bolding, and canonical anchor
  const md = lb.toMarkdownTable(ami, ami.rows);
  assert.ok(md.includes("| Model | Type / Runtime | AMI WER ↓"));
  assert.ok(md.includes("**Qwen3-ASR 1.7B**"));
  assert.ok(md.includes("https://www.lokalbot.com/benchmarks#stt-ami-cloud"));
});

test("benchmarks.html SEO, JSON-LD, OG image, and CSS fallback invariants", () => {
  assert.ok(html.includes('<link rel="canonical" href="https://www.lokalbot.com/benchmarks" />'));
  assert.ok(html.includes("https://www.lokalbot.com/assets/og-benchmarks.png"));
  assert.ok(fs.existsSync(path.join(publicDir, "assets", "og-benchmarks.png")));
  assert.ok(html.includes("prefers-reduced-transparency: reduce"));
  assert.ok(html.includes("@supports not ((-webkit-backdrop-filter: blur(1px))"));
  assert.ok(!/href="(?!https?:\/\/)[^"]+\.html"/.test(html), "benchmarks.html should use extensionless internal links");

  // Validate embedded JSON-LD parses cleanly
  const ldMatch = html.match(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/);
  assert.ok(ldMatch, "missing JSON-LD script");
  const ld = JSON.parse(ldMatch[1]);
  assert.ok(Array.isArray(ld["@graph"]) && ld["@graph"].length === 4);
  const dataset = ld["@graph"].find((n) => n["@type"] === "Dataset");
  assert.ok(dataset.distribution.some((d) => d.contentUrl === "https://www.lokalbot.com/benchmarks.json"));
});
