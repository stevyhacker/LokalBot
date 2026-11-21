#!/usr/bin/env node
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import { createRequire } from "node:module";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const require = createRequire(import.meta.url);
const __dirname = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(__dirname, "..", "..");
const M = require(path.join(repoRoot, "Website", "public", "migrate.js"));

const opts = {
  obsidianFormat: true,
  includeFrontmatter: true,
  collapseTranscript: true,
  linkSpeakers: true,
  datePrefixFilename: true,
};

const granolaCsv = [
  "document_id,user_email,document_title,workspace_name,document_created,summary,notes,transcript",
  '"doc-101","alice@example.com","Q4 Launch Sync","Acme","2026-11-18T15:00:00Z","- Decided on ""local-first"" rollout\n- Ship Obsidian plugin","My quick jottings","Alice: Let us move off cloud bots.\nBob: Agreed!"',
].join("\r\n");
const csvMeetings = M.parseFile("granola-historical-export.csv", granolaCsv);
assert.equal(csvMeetings.length, 1);
assert.equal(csvMeetings[0].source, "Granola");
assert.equal(csvMeetings[0].title, "Q4 Launch Sync");
assert.equal(csvMeetings[0].date, "2026-11-18");
assert.ok(csvMeetings[0].summary.includes('Decided on "local-first" rollout'));
assert.ok(csvMeetings[0].summary.includes("### My notes"));
assert.equal(csvMeetings[0].transcript.length, 2);
assert.deepEqual(csvMeetings[0].attendees, ["Alice", "Bob"]);

const granolaCopied =
  "Meeting Title: Design Critique\nDate: 2026-11-15\nMeeting participants: Ana, Leo\n\nTranscript:\nAna: Keep the glass cards readable.\nLeo: Already verified reduced-transparency.\n";
const gcMeetings = M.parseFile("copied-transcript.txt", granolaCopied);
assert.equal(gcMeetings.length, 1);
assert.equal(gcMeetings[0].source, "Granola");
assert.equal(gcMeetings[0].title, "Design Critique");
assert.equal(gcMeetings[0].date, "2026-11-15");
assert.deepEqual(gcMeetings[0].attendees, ["Ana", "Leo"]);
assert.equal(gcMeetings[0].transcript.length, 2);

const granolaJson = JSON.stringify({
  documents: [
    {
      id: "doc-1",
      title: "Q4 Planning — Café Review",
      created_at: "2026-11-18T14:30:00Z",
      people: {
        attendees: [
          { name: "Alice Chen" },
          { details: { person: { name: { fullName: "Bob Novak" } } } },
        ],
      },
      notes: {
        type: "doc",
        content: [
          { type: "heading", attrs: { level: 2 }, content: [{ type: "text", text: "Decisions" }] },
          {
            type: "bulletList",
            content: [
              {
                type: "listItem",
                content: [{ type: "paragraph", content: [{ type: "text", text: "Ship Obsidian plugin." }] }],
              },
            ],
          },
        ],
      },
      action_items: [{ text: "Submit plugin to Obsidian directory", owner: "Alice Chen" }],
      transcript: [
        { speaker: "Alice Chen", start_timestamp: 5, text: "Let us ship the migrator today." },
        { speaker: "Bob Novak", start_timestamp: 72, text: "Agreed — zero uploads." },
      ],
    },
  ],
});
const gMeetings = M.parseFile("granola-export.json", granolaJson);
assert.equal(gMeetings.length, 1);
assert.equal(gMeetings[0].source, "Granola");
assert.equal(gMeetings[0].date, "2026-11-18");
assert.deepEqual(gMeetings[0].attendees, ["Alice Chen", "Bob Novak"]);
assert.ok(gMeetings[0].summary.includes("## Decisions"));
assert.ok(gMeetings[0].summary.includes("- Ship Obsidian plugin."));
assert.equal(gMeetings[0].actions.length, 1);
assert.equal(gMeetings[0].transcript.length, 2);
assert.equal(gMeetings[0].transcript[1].timestamp, "01:12");

const gNote = M.renderNote(gMeetings[0], opts);
assert.ok(gNote.markdown.startsWith("---\n"));
assert.ok(gNote.markdown.includes('source: "Granola"'));
assert.ok(gNote.markdown.includes('"[[Alice Chen]]"'));
assert.ok(gNote.markdown.includes('"[[Bob Novak]]"'));
assert.ok(gNote.markdown.includes("- [ ] Submit plugin to Obsidian directory (Alice Chen)"));
assert.ok(gNote.markdown.includes("> [!note]- Transcript"));
assert.ok(gNote.markdown.includes("**[[Alice Chen]]** (00:05): Let us ship the migrator today."));

const otterTxt =
  "Product Sync\n2026-11-17\n\nMaya Patel  0:04\nWe need local Markdown export.\n\nLiam O'Connor  1:15\nLet us move to Obsidian.\n";
const oMeetings = M.parseFile("product-sync_otter_ai.txt", otterTxt);
assert.equal(oMeetings.length, 1);
assert.equal(oMeetings[0].source, "Otter.ai");
assert.equal(oMeetings[0].title, "Product Sync");
assert.equal(oMeetings[0].date, "2026-11-17");
assert.equal(oMeetings[0].transcript.length, 2);
assert.equal(oMeetings[0].transcript[0].speaker, "Maya Patel");
assert.equal(oMeetings[0].transcript[1].speaker, "Liam O'Connor");

const ffJson = JSON.stringify({
  title: "Customer Discovery #42",
  dateString: "2026-11-16T09:00:00Z",
  summary: {
    overview: "Customer wants bot-free recording.",
    action_items: "- Send Homebrew command\n- Share /migrate link",
  },
  sentences: [
    { speaker_name: "Stevan", start_time: 12, text: "Thanks for joining!" },
    { speaker_name: "Elena", start_time: 30, text: "IT blocks bots here." },
  ],
});
const ffMeetings = M.parseFile("fireflies.json", ffJson);
assert.equal(ffMeetings.length, 1);
assert.equal(ffMeetings[0].source, "Fireflies.ai");
assert.equal(ffMeetings[0].actions.length, 2);
assert.equal(ffMeetings[0].transcript.length, 2);

const zoomVtt =
  "WEBVTT\n\n1\n00:00:01.000 --> 00:00:04.500\nAlex Rivera: Welcome everyone.\n\n2\n00:00:05.000 --> 00:00:09.000\nAlex Rivera: Quick update on Linux.\n\n3\n00:00:10.000 --> 00:00:13.000\nSam: Looking good!\n";
const zMeetings = M.parseFile("zoom-standup.vtt", zoomVtt);
assert.equal(zMeetings.length, 1);
assert.equal(zMeetings[0].transcript.length, 2);
assert.equal(zMeetings[0].transcript[0].speaker, "Alex Rivera");
assert.ok(zMeetings[0].transcript[0].text.includes("Welcome everyone."));
assert.ok(zMeetings[0].transcript[0].text.includes("Quick update on Linux."));
assert.equal(zMeetings[0].transcript[1].speaker, "Sam");

const srt =
  "1\n00:00:02,000 --> 00:00:05,500\nJordan: Let us test SRT.\n\n2\n00:01:02,000 --> 00:01:05,000\nCasey: Works offline.\n";
const srtMeetings = M.parseFile("call.srt", srt);
assert.equal(srtMeetings.length, 1);
assert.equal(srtMeetings[0].transcript.length, 2);

const mdMeetings = M.parseFile("weekly-sync.md", "# Weekly Sync\n\n- [ ] Follow up with design\n- Shipped v0.13.2\n");
assert.equal(mdMeetings.length, 1);
assert.equal(mdMeetings[0].title, "Weekly Sync");

const html = fs.readFileSync(path.join(repoRoot, "Website", "public", "migrate.html"), "utf8");
const ldMatch = html.match(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/);
assert.ok(ldMatch, "Missing JSON-LD script in migrate.html");
const ld = JSON.parse(ldMatch[1]);
assert.equal(ld["@graph"].length, 3);

const oNote = M.renderNote(oMeetings[0], { ...opts, collapseTranscript: false, linkSpeakers: false });
const csvNote = M.renderNote(csvMeetings[0], opts);
const zipBytes = M.buildZip([
  gNote,
  { filename: gNote.filename, markdown: gNote.markdown + "\n<!-- copy -->\n" },
  csvNote,
  oNote,
]);
const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "lokalbot-migrate-test-"));
try {
  const zipPath = path.join(tmpDir, "out.zip");
  fs.writeFileSync(zipPath, Buffer.from(zipBytes));
  const namesJson = execFileSync(
    "python3",
    [
      "-c",
      "import json, sys, zipfile; z = zipfile.ZipFile(sys.argv[1]); assert z.testzip() is None; print(json.dumps(sorted(z.namelist())))",
      zipPath,
    ],
    { encoding: "utf8" },
  ).trim();
  const names = JSON.parse(namesJson);
  assert.equal(names.length, 4);
  assert.ok(names.includes("2026-11-18 Q4 Planning — Café Review.md"));
  assert.ok(names.includes("2026-11-18 Q4 Planning — Café Review (2).md"));

  if (process.platform === "darwin") {
    const unzipOut = execFileSync("unzip", ["-t", zipPath], { encoding: "utf8" });
    assert.ok(unzipOut.includes("No errors detected"));
    const extractDir = path.join(tmpDir, "extracted");
    fs.mkdirSync(extractDir);
    execFileSync("unzip", ["-q", zipPath, "-d", extractDir]);
    assert.equal(fs.readdirSync(extractDir).length, 4);
  }
} finally {
  fs.rmSync(tmpDir, { recursive: true, force: true });
}

console.log("test_migrate.mjs: all 10 checks passed.");
