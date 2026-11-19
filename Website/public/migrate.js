/* Zero-dependency, 100% client-side meeting export to Obsidian Markdown converter.
 * Makes zero network requests. Works offline in any modern browser and can be imported in Node tests.
 */
(function (root, factory) {
  const api = factory();
  if (typeof module === "object" && module.exports) {
    module.exports = api;
  } else {
    root.LokalBotMigrator = api;
    if (typeof document !== "undefined") {
      if (document.readyState === "loading") {
        document.addEventListener("DOMContentLoaded", function () { api.initUI(); });
      } else {
        api.initUI();
      }
    }
  }
})(typeof globalThis !== "undefined" ? globalThis : this, function () {
  "use strict";

  function pad2(n) {
    return String(n).padStart(2, "0");
  }

  function formatSeconds(sec) {
    if (!Number.isFinite(sec) || sec < 0) return "";
    const total = Math.floor(sec);
    const h = Math.floor(total / 3600);
    const m = Math.floor((total % 3600) / 60);
    const s = total % 60;
    return h > 0 ? pad2(h) + ":" + pad2(m) + ":" + pad2(s) : pad2(m) + ":" + pad2(s);
  }

  function extractIsoDay(value) {
    if (!value) return "";
    if (typeof value === "number") {
      const ms = value > 1e12 ? value : value * 1000;
      const d = new Date(ms);
      if (!Number.isNaN(d.getTime())) return d.toISOString().slice(0, 10);
      return "";
    }
    const str = String(value).trim();
    const direct = /^(\d{4}-\d{2}-\d{2})/.exec(str);
    if (direct) return direct[1];
    const parsed = new Date(str);
    if (!Number.isNaN(parsed.getTime())) return parsed.toISOString().slice(0, 10);
    return "";
  }

  function sanitizeFileName(title) {
    const cleaned = String(title || "")
      .replace(/[\\/:*?"<>|#^[\]]+/g, " ")
      .replace(/\s+/g, " ")
      .trim()
      .replace(/\.+$/g, "");
    return (cleaned || "Untitled meeting").slice(0, 96).trim();
  }

  function escapeYaml(value) {
    return '"' + String(value || "").replace(/\\/g, "\\\\").replace(/"/g, '\\"').replace(/\r?\n/g, " ") + '"';
  }

  function flattenProseMirror(node) {
    if (!node) return "";
    if (typeof node === "string") return node;
    if (Array.isArray(node)) return node.map(flattenProseMirror).filter(Boolean).join("\n\n");
    if (node.type === "text") return node.text || "";
    const children = Array.isArray(node.content) ? node.content : [];
    if (node.type === "heading") {
      const level = Math.min(6, Math.max(2, (node.attrs && node.attrs.level) || 2));
      return "#".repeat(level) + " " + children.map(flattenProseMirror).join("");
    }
    if (node.type === "bulletList") {
      return children.map(function (item) {
        return "- " + flattenProseMirror(item).replace(/\n+/g, " ");
      }).join("\n");
    }
    if (node.type === "orderedList") {
      return children.map(function (item, idx) {
        return (idx + 1) + ". " + flattenProseMirror(item).replace(/\n+/g, " ");
      }).join("\n");
    }
    if (node.type === "taskItem" || node.type === "checkItem") {
      const checked = node.attrs && node.attrs.checked ? "x" : " ";
      return "- [" + checked + "] " + children.map(flattenProseMirror).join(" ");
    }
    if (node.type === "paragraph" || node.type === "listItem") {
      return children.map(flattenProseMirror).join("");
    }
    return children.map(flattenProseMirror).filter(Boolean).join("\n\n");
  }

  function stripExtension(name) {
    return String(name || "Untitled meeting").replace(/\.[^.]+$/, "");
  }

  function parseVttOrSrt(text, fileName) {
    const clean = text.replace(/^\uFEFF/, "").replace(/\r\n/g, "\n");
    const isVtt = /^WEBVTT\b/i.test(clean.trimStart());
    const blocks = clean.split(/\n{2,}/);
    const turns = [];
    const speakers = new Set();
    const timeRe = /(\d{1,2}:)?\d{2}:\d{2}[.,]\d{3}\s*-->\s*(\d{1,2}:)?\d{2}:\d{2}[.,]\d{3}/;

    for (let i = 0; i < blocks.length; i++) {
      const lines = blocks[i].split("\n").map(function (l) { return l.trim(); }).filter(Boolean);
      if (lines.length === 0 || /^WEBVTT\b/i.test(lines[0]) || /^NOTE\b/i.test(lines[0])) continue;
      let timeIdx = -1;
      for (let j = 0; j < lines.length; j++) {
        if (timeRe.test(lines[j])) { timeIdx = j; break; }
      }
      if (timeIdx === -1) continue;
      const startRaw = lines[timeIdx].split("-->")[0].trim().replace(",", ".").replace(/\.\d+$/, "");
      const bodyLines = lines.slice(timeIdx + 1).map(function (l) {
        return l.replace(/<\/?v[^>]*>/g, function (m) {
          const vMatch = /<v\s+([^>]+)>/i.exec(m);
          return vMatch ? vMatch[1].trim() + ": " : "";
        }).replace(/<[^>]+>/g, "").trim();
      }).filter(Boolean);
      if (bodyLines.length === 0) continue;
      const joined = bodyLines.join(" ");
      const spkMatch = /^([^:]{1,50}):\s+(.+)$/.exec(joined);
      const speaker = spkMatch ? spkMatch[1].trim() : "";
      const utterance = spkMatch ? spkMatch[2].trim() : joined;
      if (speaker) speakers.add(speaker);
      const prev = turns[turns.length - 1];
      if (prev && prev.speaker === speaker && speaker) {
        prev.text += " " + utterance;
      } else {
        turns.push({ speaker: speaker, timestamp: startRaw, text: utterance });
      }
    }

    return [{
      title: stripExtension(fileName).replace(/[_-]+/g, " ").trim() || "Meeting transcript",
      date: extractIsoDay(fileName) || "",
      source: isVtt ? "Zoom / WebVTT" : "SRT transcript",
      attendees: Array.from(speakers),
      summary: "",
      actions: [],
      transcript: turns,
    }];
  }

  function parseOtterOrPlainText(text, fileName) {
    const clean = text.replace(/^\uFEFF/, "").replace(/\r\n/g, "\n").trim();
    const lines = clean.split("\n");
    const turns = [];
    const speakers = new Set();
    const otterHeader = /^(.{1,50}?)\s{2,}(\d{1,2}:\d{2}(?::\d{2})?)\s*$/;
    const colonLine = /^\[?(\d{1,2}:\d{2}(?::\d{2})?)\]?\s+([^:]{1,45}):\s+(.+)$/;
    const speakerOnly = /^([A-Z][\w .'-]{0,40}):\s+(.+)$/;
    let otterCount = 0;
    let detectedTitle = "";
    let detectedDate = extractIsoDay(fileName) || "";
    let detectedSource = "";
    let startIdx = 0;

    // Detect Granola copied transcript header ("Meeting Title:", "Date:", "Meeting participants:", "Transcript:")
    const transcriptMarkerIdx = lines.findIndex(function (l) { return l.trim() === "Transcript:"; });
    if (transcriptMarkerIdx !== -1 && transcriptMarkerIdx <= 8) {
      for (let h = 0; h < transcriptMarkerIdx; h++) {
        const hl = lines[h].trim();
        if (/^Meeting Title:\s*/i.test(hl)) detectedTitle = hl.replace(/^Meeting Title:\s*/i, "").trim();
        else if (/^Date:\s*/i.test(hl)) detectedDate = extractIsoDay(hl.replace(/^Date:\s*/i, "")) || detectedDate;
        else if (/^Meeting participants:\s*/i.test(hl)) {
          hl.replace(/^Meeting participants:\s*/i, "").split(/[,;]+/).forEach(function (p) {
            if (p.trim()) speakers.add(p.trim());
          });
        }
      }
      detectedSource = "Granola";
      startIdx = transcriptMarkerIdx + 1;
    } else {
      // Detect Otter.ai preamble lines (Title + Date before first "Speaker  0:04" header)
      const firstOtterIdx = lines.findIndex(function (l) { return otterHeader.test(l.trim()); });
      if (firstOtterIdx > 0 && firstOtterIdx <= 6) {
        for (let h = 0; h < firstOtterIdx; h++) {
          const hl = lines[h].trim();
          if (!hl) continue;
          const maybeDate = extractIsoDay(hl);
          if (maybeDate && !detectedDate) detectedDate = maybeDate;
          else if (!detectedTitle && !maybeDate) detectedTitle = hl;
        }
        startIdx = firstOtterIdx;
      }
    }

    for (let i = startIdx; i < lines.length; i++) {
      const line = lines[i].trim();
      if (!line || /^Transcribed by https?:\/\/otter\.ai/i.test(line)) continue;
      const mOtter = otterHeader.exec(line);
      if (mOtter) {
        otterCount++;
        const spk = mOtter[1].trim();
        const ts = mOtter[2].trim();
        const body = [];
        while (i + 1 < lines.length && lines[i + 1].trim() && !otterHeader.test(lines[i + 1].trim())) {
          i++;
          body.push(lines[i].trim());
        }
        if (spk) speakers.add(spk);
        turns.push({ speaker: spk, timestamp: ts, text: body.join(" ") });
        continue;
      }
      const mColon = colonLine.exec(line);
      if (mColon) {
        speakers.add(mColon[2].trim());
        turns.push({ speaker: mColon[2].trim(), timestamp: mColon[1].trim(), text: mColon[3].trim() });
        continue;
      }
      const mSpk = speakerOnly.exec(line);
      if (mSpk) {
        speakers.add(mSpk[1].trim());
        turns.push({ speaker: mSpk[1].trim(), timestamp: "", text: mSpk[2].trim() });
        continue;
      }
      turns.push({ speaker: "", timestamp: "", text: line });
    }

    return [{
      title: detectedTitle || stripExtension(fileName).replace(/[_-]+/g, " ").trim() || "Meeting note",
      date: detectedDate,
      source: detectedSource || (otterCount > 0 ? "Otter.ai" : "Transcript"),
      attendees: Array.from(speakers),
      summary: "",
      actions: [],
      transcript: turns,
    }];
  }

  function parseJsonRecord(rec, fallbackTitle, defaultSource) {
    if (!rec || typeof rec !== "object") return null;
    const title = rec.title || rec.meeting_title || rec.name || fallbackTitle || "Untitled meeting";
    const date =
      extractIsoDay(rec.created_at) ||
      extractIsoDay(rec.date) ||
      extractIsoDay(rec.dateString) ||
      extractIsoDay(rec.start_time) ||
      extractIsoDay(rec.started_at) ||
      extractIsoDay(rec.createdAt) ||
      "";

    const attendees = new Set();
    const rawPeopleList = Array.isArray(rec.people)
      ? rec.people
      : (rec.people && Array.isArray(rec.people.attendees) ? rec.people.attendees : null);
    const peopleRaw = rawPeopleList || rec.attendees || rec.participants || rec.speakers || [];
    if (Array.isArray(peopleRaw)) {
      peopleRaw.forEach(function (p) {
        if (typeof p === "string" && p.trim()) attendees.add(p.trim());
        else if (p && typeof p === "object") {
          const nested = p.details && p.details.person && p.details.person.name;
          const n =
            p.name ||
            p.display_name ||
            p.full_name ||
            (nested && (nested.fullName || nested.full_name)) ||
            p.email;
          if (n && String(n).trim()) attendees.add(String(n).trim());
        }
      });
    }

    let summary = "";
    if (typeof rec.notes_markdown === "string" && rec.notes_markdown.trim()) {
      summary = rec.notes_markdown.trim();
    } else if (typeof rec.notes_plain === "string" && rec.notes_plain.trim()) {
      summary = rec.notes_plain.trim();
    } else if (rec.notes && typeof rec.notes === "object") {
      summary = flattenProseMirror(rec.notes).trim();
    } else if (typeof rec.notes === "string" && rec.notes.trim()) {
      summary = rec.notes.trim();
    } else if (typeof rec.summary === "string" && rec.summary.trim()) {
      summary = rec.summary.trim();
    } else if (rec.summary && typeof rec.summary === "object") {
      const parts = [];
      if (rec.summary.overview) parts.push(String(rec.summary.overview).trim());
      if (rec.summary.short_summary) parts.push(String(rec.summary.short_summary).trim());
      if (Array.isArray(rec.summary.bullet_gist)) {
        parts.push(rec.summary.bullet_gist.map(function (b) { return "- " + b; }).join("\n"));
      }
      if (rec.summary.shorthand_bullet) parts.push(String(rec.summary.shorthand_bullet).trim());
      summary = parts.filter(Boolean).join("\n\n");
    }

    const actions = [];
    const rawActions =
      rec.action_items ||
      (rec.summary && rec.summary.action_items) ||
      rec.actions ||
      [];
    if (Array.isArray(rawActions)) {
      rawActions.forEach(function (a) {
        if (typeof a === "string" && a.trim()) actions.push(a.trim());
        else if (a && typeof a === "object" && (a.text || a.description || a.title)) {
          const owner = a.owner || a.assignee ? " (" + (a.owner || a.assignee) + ")" : "";
          actions.push(String(a.text || a.description || a.title).trim() + owner);
        }
      });
    } else if (typeof rawActions === "string" && rawActions.trim()) {
      rawActions.split(/\r?\n/).forEach(function (line) {
        const cleaned = line.replace(/^[-*•]\s*/, "").trim();
        if (cleaned) actions.push(cleaned);
      });
    }

    const rawTranscript =
      rec.transcript ||
      rec.sentences ||
      rec.segments ||
      rec.speeches ||
      rec.utterances ||
      [];
    const turns = [];
    if (Array.isArray(rawTranscript)) {
      rawTranscript.forEach(function (seg) {
        if (!seg || typeof seg !== "object") return;
        const text = String(seg.text || seg.raw_text || seg.transcript || seg.content || "").trim();
        if (!text) return;
        const speaker = String(seg.speaker_name || seg.speaker || seg.source || "").trim();
        if (speaker && speaker !== "microphone" && speaker !== "system") attendees.add(speaker);
        const startSec =
          typeof seg.start_time === "number" ? seg.start_time :
          typeof seg.start_timestamp === "number" ? seg.start_timestamp :
          typeof seg.start === "number" ? seg.start :
          typeof seg.start_offset === "number" ? seg.start_offset / 1000 : NaN;
        const ts =
          typeof seg.timestamp === "string" ? seg.timestamp :
          Number.isFinite(startSec) ? formatSeconds(startSec) : "";
        turns.push({ speaker: speaker, timestamp: ts, text: text });
      });
    } else if (typeof rawTranscript === "string" && rawTranscript.trim()) {
      parseOtterOrPlainText(rawTranscript, title)[0].transcript.forEach(function (t) {
        turns.push(t);
      });
    }

    let source = defaultSource || "JSON export";
    const hasProseMirrorNotes = Boolean(rec.notes && typeof rec.notes === "object" && rec.notes.type === "doc");
    if (
      rec.notes_markdown !== undefined ||
      rec.notes_plain !== undefined ||
      rec.google_calendar_event !== undefined ||
      rec.granola_id ||
      hasProseMirrorNotes
    ) {
      source = "Granola";
    } else if (Array.isArray(rec.sentences) && rec.summary && typeof rec.summary === "object") {
      source = "Fireflies.ai";
    } else if (Array.isArray(rec.speeches) || rec.otid) {
      source = "Otter.ai";
    } else if (rec.recording_id || rec.fathom_url) {
      source = "Fathom";
    }

    return {
      title: String(title).trim(),
      date: date,
      source: source,
      attendees: Array.from(attendees),
      summary: summary,
      actions: actions,
      transcript: turns,
    };
  }

  function parseCsvRows(text) {
    const rows = [];
    let row = [];
    let field = "";
    let inQuotes = false;
    const input = String(text || "").replace(/^\uFEFF/, "");

    for (let i = 0; i < input.length; i++) {
      const ch = input[i];
      if (inQuotes) {
        if (ch === "\"") {
          if (input[i + 1] === "\"") {
            field += "\"";
            i++;
          } else {
            inQuotes = false;
          }
        } else {
          field += ch;
        }
      } else if (ch === "\"") {
        inQuotes = true;
      } else if (ch === ",") {
        row.push(field);
        field = "";
      } else if (ch === "\r" || ch === "\n") {
        if (ch === "\r" && input[i + 1] === "\n") i++;
        row.push(field);
        field = "";
        if (row.some(function (cell) { return cell.trim() !== ""; })) rows.push(row);
        row = [];
      } else {
        field += ch;
      }
    }
    if (field.length > 0 || row.length > 0) {
      row.push(field);
      if (row.some(function (cell) { return cell.trim() !== ""; })) rows.push(row);
    }
    return rows;
  }

  function parseCsvExport(text, fileName) {
    const rows = parseCsvRows(text);
    if (rows.length < 2) return [];
    const headers = rows[0].map(function (h) { return h.trim().toLowerCase(); });
    const col = function (cells, names) {
      for (let i = 0; i < names.length; i++) {
        const idx = headers.indexOf(names[i]);
        if (idx !== -1 && cells[idx] !== undefined) return cells[idx].trim();
      }
      return "";
    };
    const isGranola = headers.includes("document_title") || headers.includes("document_created") || headers.includes("document_id");
    const results = [];
    for (let r = 1; r < rows.length; r++) {
      const cells = rows[r];
      const title = col(cells, ["document_title", "title", "meeting_title", "name"]) || stripExtension(fileName) + " #" + r;
      const date = extractIsoDay(col(cells, ["document_created", "created_at", "date", "started_at"])) || "";
      const summaryText = col(cells, ["summary", "ai_summary", "enhanced_notes"]);
      const userNotes = col(cells, ["notes", "my_notes", "personal_notes"]);
      const summaryParts = [];
      if (summaryText) summaryParts.push(summaryText);
      if (userNotes && userNotes !== summaryText) summaryParts.push("### My notes\n\n" + userNotes);
      const rawTranscript = col(cells, ["transcript", "full_transcript"]);
      const parsedTranscript = rawTranscript ? parseOtterOrPlainText(rawTranscript, title)[0] : null;
      const attendees = new Set(parsedTranscript ? parsedTranscript.attendees : []);
      const rawPeople = col(cells, ["attendees", "participants", "people"]);
      if (rawPeople) {
        rawPeople.split(/[,;]+/).forEach(function (p) {
          const cleaned = p.trim();
          if (cleaned) attendees.add(cleaned);
        });
      }
      results.push({
        title: title,
        date: date,
        source: isGranola ? "Granola" : "CSV export",
        attendees: Array.from(attendees),
        summary: summaryParts.join("\n\n"),
        actions: [],
        transcript: parsedTranscript ? parsedTranscript.transcript : [],
      });
    }
    return results;
  }

  function parseFile(fileName, content) {
    const ext = (fileName.split(".").pop() || "").toLowerCase();
    const trimmed = String(content || "").trim();
    if (!trimmed) return [];

    if (ext === "csv") {
      const csvMeetings = parseCsvExport(content, fileName);
      if (csvMeetings.length > 0) return csvMeetings;
    }

    if (ext === "json" || trimmed.startsWith("{") || trimmed.startsWith("[")) {
      try {
        const parsed = JSON.parse(trimmed);
        let list = [];
        if (Array.isArray(parsed)) {
          list = parsed;
        } else if (parsed && Array.isArray(parsed.documents)) {
          list = parsed.documents;
        } else if (parsed && Array.isArray(parsed.meetings)) {
          list = parsed.meetings;
        } else if (parsed && Array.isArray(parsed.transcripts)) {
          list = parsed.transcripts;
        } else if (parsed && parsed.data && Array.isArray(parsed.data.transcripts)) {
          list = parsed.data.transcripts;
        } else if (parsed && parsed.documents && typeof parsed.documents === "object") {
          list = Object.values(parsed.documents);
        } else {
          list = [parsed];
        }
        const defaultSource = /granola/i.test(fileName) ? "Granola" : "JSON export";
        const results = [];
        for (let i = 0; i < list.length; i++) {
          const item = parseJsonRecord(list[i], stripExtension(fileName), defaultSource);
          if (item) results.push(item);
        }
        if (results.length > 0) return results;
      } catch (_e) {
        // Fall through to text parser if not valid JSON.
      }
    }

    if (ext === "vtt" || ext === "srt" || /^WEBVTT\b/i.test(trimmed) || /\d{2}:\d{2}:\d{2}[.,]\d{3}\s*-->/.test(trimmed)) {
      return parseVttOrSrt(content, fileName);
    }

    if (ext === "md" || ext === "markdown") {
      const heading = /^#\s+(.+)$/m.exec(trimmed);
      const title = heading ? heading[1].trim() : stripExtension(fileName);
      return [{
        title: title,
        date: extractIsoDay(fileName) || "",
        source: "Markdown export",
        attendees: [],
        summary: trimmed.replace(/^#\s+.+\n+/, "").trim(),
        actions: [],
        transcript: [],
      }];
    }

    return parseOtterOrPlainText(content, fileName);
  }

  function renderNote(meeting, opts) {
    const options = Object.assign(
      {
        obsidianFormat: true,
        includeFrontmatter: true,
        collapseTranscript: true,
        linkSpeakers: true,
        datePrefixFilename: true,
      },
      opts || {},
    );

    const lines = [];
    if (options.includeFrontmatter) {
      lines.push("---");
      lines.push("title: " + escapeYaml(meeting.title));
      if (meeting.date) lines.push("date: " + escapeYaml(meeting.date));
      lines.push("source: " + escapeYaml(meeting.source));
      if (meeting.attendees.length > 0) {
        lines.push("attendees:");
        meeting.attendees.forEach(function (person) {
          const val = options.obsidianFormat && options.linkSpeakers ? "[[" + person + "]]" : person;
          lines.push("  - " + escapeYaml(val));
        });
      }
      lines.push("tags:");
      lines.push("  - meeting");
      lines.push("---");
      lines.push("");
    }

    lines.push("# " + meeting.title);
    lines.push("");
    const meta = [];
    if (meeting.date) meta.push("**Date:** " + meeting.date);
    if (meeting.source) meta.push("**Imported from:** " + meeting.source);
    if (meeting.attendees.length > 0) {
      const formatted = meeting.attendees.map(function (p) {
        return options.obsidianFormat && options.linkSpeakers ? "[[" + p + "]]" : p;
      }).join(", ");
      meta.push("**Participants:** " + formatted);
    }
    if (meta.length > 0) {
      lines.push(meta.join(" · "));
      lines.push("");
    }

    if (meeting.actions.length > 0) {
      lines.push("## Action items");
      lines.push("");
      meeting.actions.forEach(function (a) {
        lines.push("- [ ] " + a);
      });
      lines.push("");
    }

    if (meeting.summary) {
      lines.push("## Notes");
      lines.push("");
      lines.push(meeting.summary);
      lines.push("");
    }

    if (meeting.transcript.length > 0) {
      const renderedTurns = meeting.transcript.map(function (t) {
        const spk = t.speaker
          ? (options.obsidianFormat && options.linkSpeakers ? "**[[" + t.speaker + "]]**" : "**" + t.speaker + "**")
          : "";
        const ts = t.timestamp ? " (" + t.timestamp + ")" : "";
        if (spk) return spk + ts + ": " + t.text;
        return ts ? "`" + t.timestamp + "` " + t.text : t.text;
      });

      if (options.obsidianFormat && options.collapseTranscript) {
        lines.push("> [!note]- Transcript");
        renderedTurns.forEach(function (turn, idx) {
          lines.push("> " + turn);
          if (idx < renderedTurns.length - 1) lines.push(">");
        });
      } else {
        lines.push("## Transcript");
        lines.push("");
        lines.push(renderedTurns.join("\n\n"));
      }
      lines.push("");
    }

    const base = sanitizeFileName(meeting.title);
    const filename = (options.datePrefixFilename && meeting.date ? meeting.date + " " : "") + base + ".md";
    return {
      filename: filename,
      markdown: lines.join("\n").trimEnd() + "\n",
    };
  }

  /* Pure-JS ZIP builder (store method, CRC32, UTF-8 names) — zero external libraries. */
  const CRC_TABLE = (function () {
    const table = new Uint32Array(256);
    for (let n = 0; n < 256; n++) {
      let c = n;
      for (let k = 0; k < 8; k++) {
        c = (c & 1) ? (0xedb88320 ^ (c >>> 1)) : (c >>> 1);
      }
      table[n] = c >>> 0;
    }
    return table;
  })();

  function crc32(bytes) {
    let crc = 0xffffffff;
    for (let i = 0; i < bytes.length; i++) {
      crc = CRC_TABLE[(crc ^ bytes[i]) & 0xff] ^ (crc >>> 8);
    }
    return (crc ^ 0xffffffff) >>> 0;
  }

  function buildZip(entries) {
    const encoder = new TextEncoder();
    const localParts = [];
    const centralParts = [];
    let offset = 0;
    const usedNames = new Map();

    for (let i = 0; i < entries.length; i++) {
      let name = entries[i].filename;
      if (usedNames.has(name)) {
        const count = usedNames.get(name) + 1;
        usedNames.set(name, count);
        name = name.replace(/\.md$/i, "") + " (" + count + ").md";
      } else {
        usedNames.set(name, 1);
      }
      const nameBytes = encoder.encode(name);
      const dataBytes = encoder.encode(entries[i].markdown);
      const sum = crc32(dataBytes);

      const now = new Date();
      const dosTime =
        ((now.getHours() & 0x1f) << 11) |
        ((now.getMinutes() & 0x3f) << 5) |
        ((now.getSeconds() >> 1) & 0x1f);
      const dosDate =
        (((Math.max(1980, now.getFullYear()) - 1980) & 0x7f) << 9) |
        (((now.getMonth() + 1) & 0x0f) << 5) |
        (now.getDate() & 0x1f);

      const local = new Uint8Array(30 + nameBytes.length);
      const lv = new DataView(local.buffer);
      lv.setUint32(0, 0x04034b50, true);
      lv.setUint16(4, 20, true);
      lv.setUint16(6, 0x0800, true);
      lv.setUint16(8, 0, true);
      lv.setUint16(10, dosTime, true);
      lv.setUint16(12, dosDate, true);
      lv.setUint32(14, sum, true);
      lv.setUint32(18, dataBytes.length, true);
      lv.setUint32(22, dataBytes.length, true);
      lv.setUint16(26, nameBytes.length, true);
      local.set(nameBytes, 30);
      localParts.push(local, dataBytes);

      const central = new Uint8Array(46 + nameBytes.length);
      const cv = new DataView(central.buffer);
      cv.setUint32(0, 0x02014b50, true);
      cv.setUint16(4, 0x0314, true); // Unix (3) + ZIP 2.0 (20) so UTF-8 flag is honored by Info-ZIP/macOS
      cv.setUint16(6, 20, true);
      cv.setUint16(8, 0x0800, true);
      cv.setUint16(10, 0, true);
      cv.setUint16(12, dosTime, true);
      cv.setUint16(14, dosDate, true);
      cv.setUint32(16, sum, true);
      cv.setUint32(20, dataBytes.length, true);
      cv.setUint32(24, dataBytes.length, true);
      cv.setUint16(28, nameBytes.length, true);
      cv.setUint32(38, 0x81a40000, true); // regular file rw-r--r--
      cv.setUint32(42, offset, true);
      central.set(nameBytes, 46);
      centralParts.push(central);

      offset += local.length + dataBytes.length;
    }

    const centralSize = centralParts.reduce(function (acc, b) { return acc + b.length; }, 0);
    const eocd = new Uint8Array(22);
    const ev = new DataView(eocd.buffer);
    ev.setUint32(0, 0x06054b50, true);
    ev.setUint16(8, entries.length, true);
    ev.setUint16(10, entries.length, true);
    ev.setUint32(12, centralSize, true);
    ev.setUint32(16, offset, true);

    const totalLen = offset + centralSize + eocd.length;
    const out = new Uint8Array(totalLen);
    let pos = 0;
    localParts.forEach(function (part) { out.set(part, pos); pos += part.length; });
    centralParts.forEach(function (part) { out.set(part, pos); pos += part.length; });
    out.set(eocd, pos);
    return out;
  }

  const SAMPLE_FILES = [
    {
      name: "granola-export-sample.json",
      content: JSON.stringify({
        title: "Q4 Pricing & Launch Review",
        created_at: "2026-11-18T14:00:00Z",
        people: [{ name: "Maya Chen" }, { name: "Alex Rivera" }],
        notes_markdown: "- Team tier stays at $15/seat billed annually.\n- Ship desktop beta Thursday morning after accessibility sign-off.\n- Keep all audio transcription strictly on-device.",
        action_items: [
          { text: "Publish updated pricing FAQ before Thursday", owner: "Maya Chen" },
          { text: "Verify Windows installer signature on clean VM", owner: "Alex Rivera" },
        ],
        transcript: [
          { speaker: "Maya Chen", start_time: 12, text: "Are we aligned on keeping Team at fifteen dollars per seat annually?" },
          { speaker: "Alex Rivera", start_time: 21, text: "Yes, confirmed. Let's ship the beta Thursday morning right after accessibility sign-off." },
        ],
      }, null, 2),
    },
    {
      name: "2026-11-17-zoom-design-sync.vtt",
      content: [
        "WEBVTT",
        "",
        "1",
        "00:00:05.000 --> 00:00:11.000",
        "Elena Novak: Let's keep the Obsidian export as plain Markdown with collapsible transcripts.",
        "",
        "2",
        "00:00:12.000 --> 00:00:18.500",
        "Sam Patel: Agreed, and wikilinks on participant names make backlinks work automatically.",
      ].join("\n"),
    },
  ];

  function initUI() {
    const dropzone = document.getElementById("migrator-dropzone");
    const fileInput = document.getElementById("migrator-file-input");
    const sampleBtn = document.getElementById("migrator-sample-btn");
    const clearBtn = document.getElementById("migrator-clear-btn");
    const downloadAllBtn = document.getElementById("migrator-download-all");
    const copyCurrentBtn = document.getElementById("migrator-copy-btn");
    const downloadCurrentBtn = document.getElementById("migrator-download-one");
    const listEl = document.getElementById("migrator-list");
    const previewEl = document.getElementById("migrator-preview");
    const previewNameEl = document.getElementById("migrator-preview-name");
    const statusEl = document.getElementById("migrator-status");
    const workspaceEl = document.getElementById("migrator-workspace");

    if (!dropzone || !fileInput) return;

    let rawMeetings = [];
    let renderedNotes = [];
    let selectedIndex = 0;

    function getOptions() {
      return {
        obsidianFormat: document.getElementById("opt-obsidian").checked,
        includeFrontmatter: document.getElementById("opt-frontmatter").checked,
        collapseTranscript: document.getElementById("opt-collapse").checked,
        linkSpeakers: document.getElementById("opt-wikilinks").checked,
        datePrefixFilename: document.getElementById("opt-dateprefix").checked,
      };
    }

    function triggerDownload(blob, filename) {
      const url = URL.createObjectURL(blob);
      const a = document.createElement("a");
      a.href = url;
      a.download = filename;
      document.body.appendChild(a);
      a.click();
      document.body.removeChild(a);
      window.setTimeout(function () { URL.revokeObjectURL(url); }, 1000);
    }

    function rerender() {
      const opts = getOptions();
      renderedNotes = rawMeetings.map(function (m) {
        return { meeting: m, note: renderNote(m, opts) };
      });
      if (selectedIndex >= renderedNotes.length) selectedIndex = 0;

      const hasNotes = renderedNotes.length > 0;
      workspaceEl.hidden = !hasNotes;
      clearBtn.hidden = !hasNotes;
      downloadAllBtn.hidden = !hasNotes;

      if (!hasNotes) {
        statusEl.textContent = "Drop files above or load sample exports to preview locally.";
        return;
      }

      statusEl.textContent =
        "Converted " + renderedNotes.length + " meeting" + (renderedNotes.length === 1 ? "" : "s") +
        " locally in your browser (0 bytes uploaded).";

      listEl.textContent = "";
      renderedNotes.forEach(function (entry, idx) {
        const btn = document.createElement("button");
        btn.type = "button";
        btn.className = "migrator-item" + (idx === selectedIndex ? " is-active" : "");
        const titleEl = document.createElement("span");
        titleEl.className = "migrator-item__title";
        titleEl.textContent = entry.meeting.title;
        const metaEl = document.createElement("span");
        metaEl.className = "migrator-item__meta";
        metaEl.textContent = [entry.meeting.source, entry.meeting.date].filter(Boolean).join(" · ");
        btn.appendChild(titleEl);
        btn.appendChild(metaEl);
        btn.addEventListener("click", function () {
          selectedIndex = idx;
          rerender();
        });
        listEl.appendChild(btn);
      });

      const current = renderedNotes[selectedIndex];
      previewNameEl.textContent = current.note.filename;
      previewEl.textContent = current.note.markdown;
      downloadAllBtn.textContent = renderedNotes.length === 1 ? "Download .md" : "Download " + renderedNotes.length + " notes (.zip)";
    }

    async function ingestFiles(fileList) {
      const added = [];
      for (let i = 0; i < fileList.length; i++) {
        const f = fileList[i];
        const text = await f.text();
        parseFile(f.name, text).forEach(function (m) { added.push(m); });
      }
      if (added.length > 0) {
        rawMeetings = rawMeetings.concat(added);
        selectedIndex = rawMeetings.length - added.length;
        rerender();
      } else {
        statusEl.textContent = "No recognizable meeting content found in the dropped files.";
      }
    }

    dropzone.addEventListener("click", function () { fileInput.click(); });
    dropzone.addEventListener("keydown", function (e) {
      if (e.key === "Enter" || e.key === " ") { e.preventDefault(); fileInput.click(); }
    });
    fileInput.addEventListener("change", function () {
      if (fileInput.files && fileInput.files.length > 0) {
        void ingestFiles(fileInput.files);
        fileInput.value = "";
      }
    });
    dropzone.addEventListener("dragover", function (e) {
      e.preventDefault();
      dropzone.classList.add("is-dragover");
    });
    dropzone.addEventListener("dragleave", function () {
      dropzone.classList.remove("is-dragover");
    });
    dropzone.addEventListener("drop", function (e) {
      e.preventDefault();
      dropzone.classList.remove("is-dragover");
      if (e.dataTransfer && e.dataTransfer.files && e.dataTransfer.files.length > 0) {
        void ingestFiles(e.dataTransfer.files);
      }
    });

    sampleBtn.addEventListener("click", function () {
      rawMeetings = [];
      SAMPLE_FILES.forEach(function (sf) {
        parseFile(sf.name, sf.content).forEach(function (m) { rawMeetings.push(m); });
      });
      selectedIndex = 0;
      rerender();
    });

    clearBtn.addEventListener("click", function () {
      rawMeetings = [];
      renderedNotes = [];
      selectedIndex = 0;
      rerender();
    });

    ["opt-obsidian", "opt-frontmatter", "opt-collapse", "opt-wikilinks", "opt-dateprefix"].forEach(function (id) {
      const el = document.getElementById(id);
      if (el) el.addEventListener("change", rerender);
    });

    copyCurrentBtn.addEventListener("click", function () {
      const current = renderedNotes[selectedIndex];
      if (!current) return;
      navigator.clipboard.writeText(current.note.markdown).then(function () {
        const prev = copyCurrentBtn.textContent;
        copyCurrentBtn.textContent = "Copied";
        window.setTimeout(function () { copyCurrentBtn.textContent = prev; }, 1600);
      }).catch(function () {});
    });

    downloadCurrentBtn.addEventListener("click", function () {
      const current = renderedNotes[selectedIndex];
      if (!current) return;
      triggerDownload(new Blob([current.note.markdown], { type: "text/markdown;charset=utf-8" }), current.note.filename);
    });

    downloadAllBtn.addEventListener("click", function () {
      if (renderedNotes.length === 0) return;
      if (renderedNotes.length === 1) {
        const only = renderedNotes[0].note;
        triggerDownload(new Blob([only.markdown], { type: "text/markdown;charset=utf-8" }), only.filename);
        return;
      }
      const zipBytes = buildZip(renderedNotes.map(function (r) { return r.note; }));
      triggerDownload(new Blob([zipBytes], { type: "application/zip" }), "lokalbot-obsidian-notes.zip");
    });
  }

  return {
    parseFile: parseFile,
    renderNote: renderNote,
    buildZip: buildZip,
    initUI: initUI,
  };
});
