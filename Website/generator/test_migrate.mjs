#!/usr/bin/env node
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import { createRequire } from "node:module";
import os from "node:os";
import path from "node:path";
import test from "node:test";
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

test("Granola CSV, copied text, and ProseMirror JSON align with LokalBot Obsidian frontmatter", () => {
  const granolaCsv = [
    "document_id,user_email,document_title,workspace_name,document_created,summary,notes,transcript",
    '"doc-101","alice@example.com","Q4 Launch Sync","Acme","2026-11-18T15:00:00Z","- Decided on ""local-first"" rollout\n- Ship Obsidian plugin","My quick jottings","Alice: Let us move off cloud bots.\nBob: Agreed!"',
  ].join("\r\n");
  const csvMeetings = M.parseFile("granola-historical-export.csv", granolaCsv);
  assert.equal(csvMeetings.length, 1);
  assert.equal(csvMeetings[0].source, "Granola");
  assert.equal(csvMeetings[0].title, "Q4 Launch Sync");
  assert.equal(csvMeetings[0].date, "2026-11-18");
  assert.deepEqual(csvMeetings[0].projects, ["Acme"]);
  assert.ok(csvMeetings[0].summary.includes('Decided on "local-first" rollout'));
  assert.ok(csvMeetings[0].summary.includes("### My notes"));
  assert.equal(csvMeetings[0].transcript.length, 2);
  assert.deepEqual(csvMeetings[0].attendees, ["Alice", "Bob"]);

  const csvNote = M.renderNote(csvMeetings[0], opts);
  assert.ok(csvNote.markdown.includes("source: LokalBot"));
  assert.ok(csvNote.markdown.includes('app: "Granola"'));
  assert.ok(csvNote.markdown.includes("date: 2026-11-18"));
  assert.ok(csvNote.markdown.includes("people:\n"));
  assert.ok(csvNote.markdown.includes('  - "[[Alice]]"'));
  assert.ok(csvNote.markdown.includes("projects:\n"));
  assert.ok(csvNote.markdown.includes('  - "[[Acme]]"'));
  assert.ok(csvNote.markdown.includes("tags:\n  - lokalbot/meeting"));

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
        title: "Q4 Planning Cafe Review",
        created_at: "2026-11-18T14:30:00Z",
        projects: ["Desktop v0.14"],
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
          { speaker: "Bob Novak", start_timestamp: 72, text: "Agreed, zero uploads." },
        ],
      },
    ],
  });
  const gMeetings = M.parseFile("granola-export.json", granolaJson);
  assert.equal(gMeetings.length, 1);
  assert.equal(gMeetings[0].source, "Granola");
  assert.equal(gMeetings[0].date, "2026-11-18");
  assert.deepEqual(gMeetings[0].attendees, ["Alice Chen", "Bob Novak"]);
  assert.deepEqual(gMeetings[0].projects, ["Desktop v0.14"]);
  assert.ok(gMeetings[0].summary.includes("## Decisions"));
  assert.ok(gMeetings[0].summary.includes("- Ship Obsidian plugin."));
  assert.equal(gMeetings[0].actions.length, 1);
  assert.equal(gMeetings[0].transcript.length, 2);
  assert.equal(gMeetings[0].transcript[1].timestamp, "01:12");

  const gNote = M.renderNote(gMeetings[0], opts);
  assert.ok(gNote.markdown.startsWith("---\n"));
  assert.ok(gNote.markdown.includes("aliases:\n  - \"Q4 Planning Cafe Review\""));
  assert.ok(gNote.markdown.includes("source: LokalBot"));
  assert.ok(gNote.markdown.includes('app: "Granola"'));
  assert.ok(gNote.markdown.includes('"[[Alice Chen]]"'));
  assert.ok(gNote.markdown.includes('"[[Bob Novak]]"'));
  assert.ok(gNote.markdown.includes('"[[Desktop v0.14]]"'));
  assert.ok(gNote.markdown.includes("- [ ] Submit plugin to Obsidian directory (Alice Chen)"));
  assert.ok(gNote.markdown.includes("> [!note]- Transcript"));
  assert.ok(gNote.markdown.includes("**[[Alice Chen]]** (00:05): Let us ship the migrator today."));
});

test("Otter, Fireflies, Zoom VTT, SRT, and Markdown exports parse cleanly", () => {
  const otterTxt =
    "Product Sync\n2026-11-17\n\nMaya Patel  0:04\nWe need local Markdown export.\n\nLiam O'Connor  1:15\nLet us move to Obsidian.\n";
  const oMeetings = M.parseFile("product-sync_otter_ai.txt", otterTxt);
  assert.equal(oMeetings.length, 1);
  assert.equal(oMeetings[0].source, "Otter.ai");
  assert.equal(oMeetings[0].title, "Product Sync");
  assert.equal(oMeetings[0].date, "2026-11-17");
  assert.equal(oMeetings[0].transcript.length, 2);

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

  const srt =
    "1\n00:00:02,000 --> 00:00:05,500\nJordan: Let us test SRT.\n\n2\n00:01:02,000 --> 00:01:05,000\nCasey: Works offline.\n";
  const srtMeetings = M.parseFile("call.srt", srt);
  assert.equal(srtMeetings.length, 1);
  assert.equal(srtMeetings[0].transcript.length, 2);

  const mdMeetings = M.parseFile("weekly-sync.md", "# Weekly Sync\n\n- [ ] Follow up with design\n- Shipped v0.14.0\n");
  assert.equal(mdMeetings.length, 1);
  assert.equal(mdMeetings[0].title, "Weekly Sync");
});

test("Screenpipe, Microsoft Teams VTT, Krisp, Tactiq, and Wispr Flow parsers work offline", () => {
  const spJson = JSON.stringify({
    data: [
      {
        type: "Audio",
        content: {
          timestamp: "2026-11-22T10:15:04Z",
          transcription: "Let us switch the default STT to Qwen3-ASR v3.",
          device_name: "MacBook Pro Microphone",
          speaker: { name: "Stevan" },
        },
      },
      {
        type: "Audio",
        content: {
          timestamp: "2026-11-22T10:15:18Z",
          transcription: "Sounds good, zero silence hallucinations.",
          speaker_id: 2,
        },
      },
    ],
  });
  const spMeetings = M.parseFile("screenpipe-export.json", spJson);
  assert.equal(spMeetings.length, 1);
  assert.equal(spMeetings[0].source, "Screenpipe");
  assert.equal(spMeetings[0].date, "2026-11-22");
  assert.deepEqual(spMeetings[0].attendees, ["Stevan", "Speaker 2"]);
  assert.equal(spMeetings[0].transcript.length, 2);

  const spMd = "# Screenpipe Audio Log\n[2026-11-22T09:05:10Z] (microphone) Ship local search today.\n[2026-11-22T09:05:24Z] (output) Verified 39 ms p50.\n";
  const spMdMeetings = M.parseFile("screenpipe-daily.md", spMd);
  assert.equal(spMdMeetings.length, 1);
  assert.equal(spMdMeetings[0].source, "Screenpipe");
  assert.equal(spMdMeetings[0].transcript.length, 2);

  const teamsVtt = [
    "WEBVTT",
    "",
    "9a3d5f10-1234-4abc-9def-000000000001/1-0",
    "00:00:03.200 --> 00:00:07.800",
    "<v Novak, Ana>Good morning everyone, sharing Q4 metrics.</v>",
    "",
    "9a3d5f10-1234-4abc-9def-000000000001/2-0",
    "00:00:08.100 --> 00:00:12.000",
    "<v Markovic, Ivan>Thanks Ana, latency looks steady.</v>",
  ].join("\n");
  const tvMeetings = M.parseFile("q4-metrics.vtt", teamsVtt);
  assert.equal(tvMeetings.length, 1);
  assert.equal(tvMeetings[0].source, "Microsoft Teams");
  assert.deepEqual(tvMeetings[0].attendees, ["Novak, Ana", "Markovic, Ivan"]);
  assert.equal(tvMeetings[0].transcript.length, 2);

  const krispTxt = [
    "Meeting: Architecture Sync",
    "Date: 2026-11-21",
    "Summary:",
    "Agreed to run models on-device.",
    "Action Items:",
    "- Ship Linux package",
    "Transcript:",
    "Nora (00:12): Zero uploads is non-negotiable.",
    "00:25 - Dan: Agreed, keeping everything local.",
  ].join("\n");
  const kMeetings = M.parseFile("krisp-architecture.txt", krispTxt);
  assert.equal(kMeetings.length, 1);
  assert.equal(kMeetings[0].source, "Krisp");
  assert.equal(kMeetings[0].actions.length, 1);
  assert.equal(kMeetings[0].transcript.length, 2);

  const krispJson = JSON.stringify({
    krisp_id: "kr-99",
    meeting_name: "Security Review",
    started_at: "2026-11-20T16:00:00Z",
    key_points: ["No cloud uploads", "Signed DMG builds"],
    action_items: ["Update PRIVACY.md"],
    utterances: [{ speaker_name: "Luka", start_time: 8, text: "All checks green." }],
  });
  const kjMeetings = M.parseFile("krisp-review.json", krispJson);
  assert.equal(kjMeetings.length, 1);
  assert.equal(kjMeetings[0].source, "Krisp");
  assert.ok(kjMeetings[0].summary.includes("No cloud uploads"));

  const tactiqTxt = [
    "Sprint Retro",
    "2026-11-19",
    "https://meet.google.com/abc-defg-hij",
    "Transcript exported by Tactiq",
    "00:00:14 Sara Kim: Velocity improved this sprint.",
    "00:00:29 Leo Park: Local benchmarks caught the regression early.",
  ].join("\n");
  const tqMeetings = M.parseFile("tactiq-retro.txt", tactiqTxt);
  assert.equal(tqMeetings.length, 1);
  assert.equal(tqMeetings[0].source, "Tactiq");
  assert.equal(tqMeetings[0].transcript.length, 2);

  const tactiqJson = JSON.stringify({
    title: "Customer Call",
    meetingDate: "2026-11-18",
    highlights: ["Wants Obsidian vault sync"],
    actionItems: ["Send plugin link"],
    entries: [{ speaker: "Mia", time: "00:05", text: "Can it run offline?" }],
  });
  const tqjMeetings = M.parseFile("tactiq-call.json", tactiqJson);
  assert.equal(tqjMeetings.length, 1);
  assert.equal(tqjMeetings[0].source, "Tactiq");
  assert.equal(tqjMeetings[0].actions.length, 1);

  const wisprCsv = [
    "timestamp,app,formatted_text",
    '"2026-11-23T09:10:00Z","Slack","Shipping v0.14.0 models today."',
    '"2026-11-23T09:42:00Z","Mail","Let us review the calculator copy."',
  ].join("\n");
  const wCsvMeetings = M.parseFile("wispr-flow-history.csv", wisprCsv);
  assert.equal(wCsvMeetings.length, 1);
  assert.equal(wCsvMeetings[0].source, "Wispr Flow");
  assert.equal(wCsvMeetings[0].date, "2026-11-23");
  assert.equal(wCsvMeetings[0].transcript.length, 2);
  assert.equal(wCsvMeetings[0].transcript[0].speaker, "Slack");

  const wisprJson = JSON.stringify({
    dictations: [
      { created_at: "2026-11-24T11:00:00Z", app_name: "Linear", formatted_text: "Close issue 561." },
    ],
  });
  const wJsonMeetings = M.parseFile("wispr-export.json", wisprJson);
  assert.equal(wJsonMeetings.length, 1);
  assert.equal(wJsonMeetings[0].source, "Wispr Flow");
  assert.equal(wJsonMeetings[0].transcript[0].speaker, "Linear");

  const wisprTxt = "[2026-11-24 14:22] (Notes) Add offline ZIP and DOCX unpacking.\n";
  const wTxtMeetings = M.parseFile("wispr-flow.txt", wisprTxt);
  assert.equal(wTxtMeetings.length, 1);
  assert.equal(wTxtMeetings[0].source, "Wispr Flow");
  assert.equal(wTxtMeetings[0].transcript[0].speaker, "Notes");
});

test("Client-side ZIP (stored & deflated) and Teams DOCX unpacking work offline", async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "lokalbot-migrate-bin-"));
  try {
    const docxPath = path.join(tmpDir, "teams-meeting.docx");
    const bulkZipPath = path.join(tmpDir, "otter-zoom-bulk.zip");

    const pyScript = [
      "import sys, zipfile",
      "docx_path, bulk_path = sys.argv[1], sys.argv[2]",
      "doc_xml = '''<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>",
      "<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:body>",
      "<w:p><w:r><w:t>Quarterly Roadmap Review</w:t></w:r></w:p>",
      "<w:p><w:r><w:t>November 20, 2026, 2:00PM</w:t></w:r></w:p>",
      "<w:p><w:r><w:t>32m 10s</w:t></w:r></w:p>",
      "<w:p><w:r><w:t>Transcript</w:t></w:r></w:p>",
      "<w:p><w:r><w:t>Ana Novak</w:t><w:tab/><w:t>0:05</w:t></w:r></w:p>",
      "<w:p><w:r><w:t>Welcome to the roadmap review &amp; Q4 check-in.</w:t></w:r></w:p>",
      "<w:p><w:r><w:t>Ivan Petrovic</w:t><w:tab/><w:t>0:18</w:t></w:r></w:p>",
      "<w:p><w:r><w:t>All fine-tuned models are Apache-2.0.</w:t></w:r></w:p>",
      "</w:body></w:document>'''",
      "with zipfile.ZipFile(docx_path, 'w', compression=zipfile.ZIP_DEFLATED) as z:",
      "    z.writestr('word/document.xml', doc_xml)",
      "with zipfile.ZipFile(bulk_path, 'w') as z:",
      "    z.writestr('__MACOSX/._ignore.txt', 'junk', compress_type=zipfile.ZIP_STORED)",
      "    z.writestr('.DS_Store', 'junk', compress_type=zipfile.ZIP_STORED)",
      "    z.writestr('otter-call.txt', 'Standup\\n2026-11-21\\n\\nMaya  0:02\\nDeflated entry works.\\n', compress_type=zipfile.ZIP_DEFLATED)",
      "    z.writestr('zoom-call.vtt', 'WEBVTT\\n\\n1\\n00:00:01.000 --> 00:00:04.000\\nSam: Stored entry works.\\n', compress_type=zipfile.ZIP_STORED)",
      "    z.writestr('nested/teams-meeting.docx', open(docx_path, 'rb').read(), compress_type=zipfile.ZIP_DEFLATED)",
    ].join("\n");

    execFileSync("python3", ["-c", pyScript, docxPath, bulkZipPath]);

    const docxBytes = new Uint8Array(fs.readFileSync(docxPath));
    const docxText = await M.extractDocxText(docxBytes);
    assert.ok(docxText.includes("Welcome to the roadmap review & Q4 check-in."));
    const docxMeetings = await M.parseBinaryFile("teams-meeting.docx", docxBytes);
    assert.equal(docxMeetings.length, 1);
    assert.equal(docxMeetings[0].source, "Microsoft Teams");
    assert.equal(docxMeetings[0].title, "Quarterly Roadmap Review");
    assert.equal(docxMeetings[0].date, "2026-11-20");
    assert.deepEqual(docxMeetings[0].attendees, ["Ana Novak", "Ivan Petrovic"]);
    assert.equal(docxMeetings[0].transcript.length, 2);

    const bulkBytes = new Uint8Array(fs.readFileSync(bulkZipPath));
    const bulkMeetings = await M.parseBinaryFile("otter-zoom-bulk.zip", bulkBytes);
    assert.equal(bulkMeetings.length, 3);
    const sources = new Set(bulkMeetings.map((m) => m.source));
    assert.ok(sources.has("Otter.ai"));
    assert.ok(sources.has("Zoom / WebVTT"));
    assert.ok(sources.has("Microsoft Teams"));
  } finally {
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
});

test("buildZip output unpacks cleanly and deduplicates filenames", () => {
  const m1 = M.parseFile("granola.json", JSON.stringify({
    title: "Q4 Planning Cafe Review",
    created_at: "2026-11-18T14:30:00Z",
    people: [{ name: "Alice Chen" }],
    notes_markdown: "Decision made.",
  }))[0];
  const note1 = M.renderNote(m1, opts);
  const zipBytes = M.buildZip([
    note1,
    { filename: note1.filename, markdown: note1.markdown + "\nExtra\n" },
  ]);
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "lokalbot-migrate-zip-"));
  try {
    const zipPath = path.join(tmpDir, "out.zip");
    fs.writeFileSync(zipPath, Buffer.from(zipBytes));
    const names = JSON.parse(execFileSync(
      "python3",
      [
        "-c",
        "import json, sys, zipfile; z = zipfile.ZipFile(sys.argv[1]); assert z.testzip() is None; print(json.dumps(sorted(z.namelist())))",
        zipPath,
      ],
      { encoding: "utf8" },
    ).trim());
    assert.equal(names.length, 2);
    assert.ok(names.includes("2026-11-18 Q4 Planning Cafe Review.md"));
    assert.ok(names.includes("2026-11-18 Q4 Planning Cafe Review (2).md"));
  } finally {
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
});

test("migrate.html SEO metadata, JSON-LD, download CTA, paste mode, and nav/footer links", () => {
  const html = fs.readFileSync(path.join(repoRoot, "Website", "public", "migrate.html"), "utf8");
  const titleMatch = html.match(/<title>([^<]+)<\/title>/);
  assert.ok(titleMatch, "Missing <title>");
  const decodedTitle = titleMatch[1].replace(/&amp;/g, "&");
  assert.ok(decodedTitle.includes("Migrate"), "Title must include Migrate");
  assert.ok(decodedTitle.length <= 65, `Title too long (${decodedTitle.length}): ${decodedTitle}`);

  const descMatch = html.match(/<meta name="description" content="([^"]+)"/);
  assert.ok(descMatch, "Missing meta description");
  assert.ok(descMatch[1].includes("Migrate"), "Meta description must include Migrate");
  assert.ok(descMatch[1].length <= 160, `Description too long (${descMatch[1].length})`);

  const h1Match = html.match(/<h1>([^<]+)<\/h1>/);
  assert.ok(h1Match && h1Match[1].includes("Migrate"), "H1 must include Migrate");
  assert.ok(html.includes('property="og:image:alt"'));
  assert.ok(html.includes('data-download data-asset="mac"'));
  assert.ok(html.includes('id="migrator-paste-input"'));
  assert.ok(html.includes('accept=".csv,.json,.md,.markdown,.txt,.vtt,.srt,.zip,.docx"'));
  for (const href of ["/hardware", "/calculator", "/wrapped", "/benchmarks", "/de", "/zh", "/ja", "/ru"]) {
    assert.ok(html.includes(`href="${href}"`), `migrate.html missing link to ${href}`);
  }
  assert.equal(html.match(/href="(?:\/|https:\/\/www\.lokalbot\.com\/)[^"]*\.html(?:[#?][^"]*)?"/g), null);
  assert.ok(!html.includes("\u2014"), "migrate.html should not contain em-dashes");
  assert.ok(!html.includes("\u2192"), "migrate.html should not contain arrow chains");

  const ldMatch = html.match(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/);
  assert.ok(ldMatch, "Missing JSON-LD script in migrate.html");
  const ld = JSON.parse(ldMatch[1]);
  assert.equal(ld["@graph"].length, 4);
  const types = new Set(ld["@graph"].map((n) => n["@type"]));
  assert.ok(types.has("WebApplication"));
  assert.ok(types.has("WebPage"));
  assert.ok(types.has("BreadcrumbList"));
  assert.ok(types.has("FAQPage"));
});
