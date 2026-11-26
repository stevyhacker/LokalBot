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

  const MAX_ZIP_ENTRIES = 500;
  const MAX_ZIP_ENTRY_BYTES = 50 * 1024 * 1024;
  const SUPPORTED_ARCHIVE_EXTS = new Set(["csv", "json", "md", "markdown", "txt", "vtt", "srt", "docx"]);

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

  function formatIsoTime(value) {
    if (!value) return "";
    const match = /T(\d{2}:\d{2}(?::\d{2})?)/.exec(String(value));
    if (match) return match[1];
    const spaceMatch = /\b(\d{1,2}:\d{2}(?::\d{2})?)\b/.exec(String(value));
    return spaceMatch ? spaceMatch[1] : "";
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
    const direct = /(\d{4}-\d{2}-\d{2})/.exec(str);
    if (direct) return direct[1];
    const parsed = new Date(str);
    if (!Number.isNaN(parsed.getTime())) return parsed.toISOString().slice(0, 10);
    const monthMatch = /\b(January|February|March|April|May|June|July|August|September|October|November|December|Jan|Feb|Mar|Apr|Jun|Jul|Aug|Sep|Sept|Oct|Nov|Dec)\.?\s+(\d{1,2}),?\s+(\d{4})\b/i.exec(str);
    if (monthMatch) {
      const monthDate = new Date(monthMatch[1].replace(/\.$/, "") + " " + monthMatch[2] + ", " + monthMatch[3] + " UTC");
      if (!Number.isNaN(monthDate.getTime())) return monthDate.toISOString().slice(0, 10);
    }
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

  function normalizeProjects(raw) {
    const seen = new Set();
    const out = [];
    const add = function (val) {
      if (typeof val === "string") {
        val.split(/[,;]+/).forEach(function (part) {
          const cleaned = part.trim().replace(/^\[\[|\]\]$/g, "");
          if (cleaned && !seen.has(cleaned)) {
            seen.add(cleaned);
            out.push(cleaned);
          }
        });
      } else if (val && typeof val === "object") {
        const name = val.name || val.title || val.label;
        if (typeof name === "string") add(name);
      }
    };
    if (Array.isArray(raw)) raw.forEach(add);
    else if (raw) add(raw);
    return out;
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
    const base = String(name || "Untitled meeting").split(/[\\/]/).pop() || "Untitled meeting";
    return base.replace(/\.[^.]+$/, "");
  }

  function decodeXmlEntities(str) {
    return String(str || "")
      .replace(/&#x([0-9a-fA-F]+);/g, function (_, hex) {
        return String.fromCodePoint(parseInt(hex, 16));
      })
      .replace(/&#(\d+);/g, function (_, dec) {
        return String.fromCodePoint(parseInt(dec, 10));
      })
      .replace(/&lt;/g, "<")
      .replace(/&gt;/g, ">")
      .replace(/&quot;/g, '"')
      .replace(/&apos;/g, "'")
      .replace(/&amp;/g, "&");
  }

  async function inflateRawBytes(compressedBytes) {
    if (typeof DecompressionStream !== "function") {
      throw new Error("Browser does not support DecompressionStream deflate-raw");
    }
    const ds = new DecompressionStream("deflate-raw");
    const writer = ds.writable.getWriter();
    const writePromise = writer.write(compressedBytes).then(function () {
      return writer.close();
    });
    const reader = ds.readable.getReader();
    const chunks = [];
    let total = 0;
    while (true) {
      const step = await reader.read();
      if (step.done) break;
      total += step.value.byteLength;
      if (total > MAX_ZIP_ENTRY_BYTES) {
        throw new Error("Archive entry exceeds safety limit");
      }
      chunks.push(step.value);
    }
    await writePromise;
    const out = new Uint8Array(total);
    let offset = 0;
    for (let i = 0; i < chunks.length; i++) {
      out.set(chunks[i], offset);
      offset += chunks[i].byteLength;
    }
    return out;
  }

  async function extractZipEntries(inputBytes) {
    const bytes = inputBytes instanceof Uint8Array ? inputBytes : new Uint8Array(inputBytes);
    if (bytes.byteLength < 22) return [];
    const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    const minEocd = Math.max(0, bytes.byteLength - 65557);
    let eocdOffset = -1;
    for (let i = bytes.byteLength - 22; i >= minEocd; i--) {
      if (view.getUint32(i, true) === 0x06054b50) {
        eocdOffset = i;
        break;
      }
    }
    if (eocdOffset === -1) return [];

    const entryCount = Math.min(view.getUint16(eocdOffset + 10, true), MAX_ZIP_ENTRIES);
    const centralOffset = view.getUint32(eocdOffset + 16, true);
    const decoder = new TextDecoder("utf-8");
    const entries = [];
    let ptr = centralOffset;

    for (let i = 0; i < entryCount && ptr + 46 <= bytes.byteLength; i++) {
      if (view.getUint32(ptr, true) !== 0x02014b50) break;
      const method = view.getUint16(ptr + 10, true);
      const compSize = view.getUint32(ptr + 20, true);
      const uncompSize = view.getUint32(ptr + 24, true);
      const nameLen = view.getUint16(ptr + 28, true);
      const extraLen = view.getUint16(ptr + 30, true);
      const commentLen = view.getUint16(ptr + 32, true);
      const localOffset = view.getUint32(ptr + 42, true);
      const name = decoder.decode(bytes.subarray(ptr + 46, ptr + 46 + nameLen));
      ptr += 46 + nameLen + extraLen + commentLen;

      if (
        !name ||
        name.endsWith("/") ||
        name.startsWith("__MACOSX/") ||
        /(^|\/)\.DS_Store$/.test(name) ||
        uncompSize > MAX_ZIP_ENTRY_BYTES
      ) {
        continue;
      }
      if (localOffset + 30 > bytes.byteLength) continue;
      if (view.getUint32(localOffset, true) !== 0x04034b50) continue;
      const localNameLen = view.getUint16(localOffset + 26, true);
      const localExtraLen = view.getUint16(localOffset + 28, true);
      const dataStart = localOffset + 30 + localNameLen + localExtraLen;
      const dataEnd = dataStart + compSize;
      if (dataEnd > bytes.byteLength) continue;

      const rawSlice = bytes.subarray(dataStart, dataEnd);
      if (method === 0) {
        entries.push({ name: name, bytes: new Uint8Array(rawSlice) });
      } else if (method === 8) {
        try {
          const inflated = await inflateRawBytes(rawSlice);
          entries.push({ name: name, bytes: inflated });
        } catch (_e) {
        }
      }
    }
    return entries;
  }

  async function extractDocxText(inputBytes) {
    const entries = await extractZipEntries(inputBytes);
    const docEntry = entries.find(function (e) {
      return e.name.toLowerCase() === "word/document.xml";
    });
    if (!docEntry) return "";
    const xml = new TextDecoder("utf-8").decode(docEntry.bytes);
    const paragraphs = [];
    const pRe = /<w:p(?:\s[^>]*)?>([\s\S]*?)<\/w:p>/g;
    let pMatch;
    while ((pMatch = pRe.exec(xml)) !== null) {
      const inner = pMatch[1]
        .replace(/<w:tab(?:\s[^>]*)?\/>/g, "  ")
        .replace(/<w:br(?:\s[^>]*)?\/>/g, "\n");
      let text = "";
      const tokenRe = /<w:t(?:\s[^>]*)?>([\s\S]*?)<\/w:t>|(\n)|(\s{2})/g;
      let tMatch;
      while ((tMatch = tokenRe.exec(inner)) !== null) {
        if (tMatch[1] !== undefined) text += decodeXmlEntities(tMatch[1]);
        else if (tMatch[2]) text += "\n";
        else if (tMatch[3]) text += "  ";
      }
      const trimmed = text.replace(/[ \t]+\n/g, "\n").trim();
      if (trimmed) paragraphs.push(trimmed);
    }
    return paragraphs.join("\n");
  }

  function parseVttOrSrt(text, fileName) {
    const clean = text.replace(/^\uFEFF/, "").replace(/\r\n/g, "\n");
    const isVtt = /^WEBVTT\b/i.test(clean.trimStart());
    const hasVoiceTag = /<v\s+[^>]+>/i.test(clean);
    const hasTeamsCue = /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\/\d+-\d+/i.test(clean);
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
        return l.replace(/<\/?v[^>]*>/gi, function (m) {
          const vMatch = /<v\s+([^>]+)>/i.exec(m);
          return vMatch ? vMatch[1].trim() + ": " : "";
        }).replace(/<[^>]+>/g, "").trim();
      }).filter(Boolean);
      if (bodyLines.length === 0) continue;
      const joined = bodyLines.join(" ");
      const spkMatch = /^([^:]{1,60}):\s+(.+)$/.exec(joined);
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

    let source = isVtt ? "Zoom / WebVTT" : "SRT transcript";
    if (hasVoiceTag || hasTeamsCue || /teams/i.test(fileName)) {
      source = "Microsoft Teams";
    }

    return [{
      title: stripExtension(fileName).replace(/[_-]+/g, " ").trim() || "Meeting transcript",
      date: extractIsoDay(fileName) || "",
      source: source,
      attendees: Array.from(speakers),
      projects: [],
      summary: "",
      actions: [],
      transcript: turns,
    }];
  }

  function parseScreenpipeMarkdown(text, fileName) {
    const clean = text.replace(/^\uFEFF/, "").replace(/\r\n/g, "\n").trim();
    const lines = clean.split("\n");
    const turns = [];
    const speakers = new Set();
    let title = "";
    let date = extractIsoDay(fileName) || "";
    const audioLineRe = /^\[?(\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}(?::\d{2})?Z?)\]?\s*(?:\(([^)]+)\)|\[([^\]]+)\])?:?\s*(.+)$/;
    const spkTurnRe = /^\*\*([^*]{1,50})\*\*\s*(?:\[?(\d{1,2}:\d{2}(?::\d{2})?)\]?)?:?\s+(.+)$/;

    for (let i = 0; i < lines.length; i++) {
      const line = lines[i].trim();
      if (!line) continue;
      if (/^#\s+/.test(line) && !title) {
        title = line.replace(/^#\s+/, "").trim();
        continue;
      }
      const mAudio = audioLineRe.exec(line);
      if (mAudio) {
        if (!date) date = extractIsoDay(mAudio[1]);
        const ts = formatIsoTime(mAudio[1]);
        const speaker = (mAudio[2] || mAudio[3] || "").trim();
        if (speaker) speakers.add(speaker);
        turns.push({ speaker: speaker, timestamp: ts, text: mAudio[4].trim() });
        continue;
      }
      const mSpk = spkTurnRe.exec(line);
      if (mSpk) {
        const spk = mSpk[1].trim();
        speakers.add(spk);
        turns.push({ speaker: spk, timestamp: (mSpk[2] || "").trim(), text: mSpk[3].trim() });
      }
    }

    return [{
      title: title || stripExtension(fileName).replace(/[_-]+/g, " ").trim() || "Screenpipe capture",
      date: date,
      source: "Screenpipe",
      attendees: Array.from(speakers),
      projects: [],
      summary: "",
      actions: [],
      transcript: turns,
    }];
  }

  function parseWisprPlainText(text, fileName) {
    const clean = text.replace(/^\uFEFF/, "").replace(/\r\n/g, "\n").trim();
    const lines = clean.split("\n");
    const turns = [];
    let date = extractIsoDay(fileName) || "";
    const bracketRe = /^\[(\d{4}-\d{2}-\d{2})[T ](\d{1,2}:\d{2}(?::\d{2})?)\]\s*(?:\(([^)]+)\)\s*)?(.+)$/;
    const dashRe = /^(\d{4}-\d{2}-\d{2})[T ](\d{1,2}:\d{2}(?::\d{2})?)\s*-\s*([^:]{1,40}):\s+(.+)$/;

    for (let i = 0; i < lines.length; i++) {
      const line = lines[i].trim();
      if (!line || /^wispr\s*flow/i.test(line)) continue;
      const mBracket = bracketRe.exec(line);
      if (mBracket) {
        if (!date) date = mBracket[1];
        const appLabel = mBracket[3] ? mBracket[3].trim() : "Dictation";
        turns.push({ speaker: appLabel, timestamp: mBracket[2], text: mBracket[4].trim() });
        continue;
      }
      const mDash = dashRe.exec(line);
      if (mDash) {
        if (!date) date = mDash[1];
        turns.push({ speaker: mDash[3].trim(), timestamp: mDash[2], text: mDash[4].trim() });
        continue;
      }
      turns.push({ speaker: "Dictation", timestamp: "", text: line });
    }

    return [{
      title: stripExtension(fileName).replace(/[_-]+/g, " ").trim() || "Wispr Flow dictations",
      date: date,
      source: "Wispr Flow",
      attendees: [],
      projects: [],
      summary: "",
      actions: [],
      transcript: turns,
    }];
  }

  function parseOtterOrPlainText(text, fileName, forcedSource) {
    const clean = text.replace(/^\uFEFF/, "").replace(/\r\n/g, "\n").trim();
    const lines = clean.split("\n");
    const turns = [];
    const speakers = new Set();
    const summaryLines = [];
    const actions = [];
    const otterHeader = /^(.{1,55}?)\s{2,}(\d{1,2}:\d{2}(?::\d{2})?)\s*$/;
    const teamsInlineTs = /^([A-Z][\w .,'()-]{1,50}?)\s+(\d{1,2}:\d{2}(?::\d{2})?)\s*$/;
    const krispParenLine = /^([^:(\n]{1,50}?)\s*\((\d{1,2}:\d{2}(?::\d{2})?)\):\s+(.+)$/;
    const krispDashLine = /^\[?(\d{1,2}:\d{2}(?::\d{2})?)\]?\s*[-|]\s*([^:]{1,50}):\s+(.+)$/;
    const krispPipeHeader = /^([^|\n]{1,50}?)\s*\|\s*(\d{1,2}:\d{2}(?::\d{2})?)\s*$/;
    const colonLine = /^\[?(\d{1,2}:\d{2}(?::\d{2})?)\]?\s+([^:]{1,45}):\s+(.+)$/;
    const speakerOnly = /^([A-Z][\w .'-]{0,40}):\s+(.+)$/;
    const bareTimestamp = /^(\d{1,2}:\d{2}(?::\d{2})?)$/;

    let otterCount = 0;
    let teamsCount = 0;
    let detectedTitle = "";
    let detectedDate = extractIsoDay(fileName) || "";
    let detectedSource = forcedSource || "";
    let startIdx = 0;

    if (/tactiq/i.test(fileName) || /exported by tactiq|tactiq\.io/i.test(clean)) {
      detectedSource = "Tactiq";
    } else if (/krisp/i.test(fileName) || /^krisp\b/im.test(clean)) {
      detectedSource = "Krisp";
    } else if (/teams/i.test(fileName)) {
      detectedSource = "Microsoft Teams";
    }

    const transcriptMarkerIdx = lines.findIndex(function (l) {
      return /^Transcript:?$/i.test(l.trim());
    });
    if (transcriptMarkerIdx !== -1 && transcriptMarkerIdx <= 40) {
      let section = "header";
      for (let h = 0; h < transcriptMarkerIdx; h++) {
        const hl = lines[h].trim();
        if (!hl) continue;
        if (/^Transcribed by https?:\/\/otter\.ai/i.test(hl) || /^Transcript exported by Tactiq/i.test(hl)) continue;
        if (/^https?:\/\/meet\.google\.com\//i.test(hl)) {
          if (!detectedSource) detectedSource = "Tactiq";
          continue;
        }
        if (/^(Summary|Key Points|Highlights):?$/i.test(hl)) {
          section = "summary";
          continue;
        }
        if (/^Action Items:?$/i.test(hl)) {
          section = "actions";
          continue;
        }
        if (section === "summary") {
          summaryLines.push(hl);
          continue;
        }
        if (section === "actions") {
          const item = hl.replace(/^[-*•\[\] xX]+/, "").trim();
          if (item) actions.push(item);
          continue;
        }
        if (/^Meeting participants:\s*/i.test(hl)) {
          if (!detectedSource) detectedSource = "Granola";
          hl.replace(/^Meeting participants:\s*/i, "").split(/[,;]+/).forEach(function (p) {
            if (p.trim()) speakers.add(p.trim());
          });
        } else if (/^(?:Meeting Title|Meeting):\s*/i.test(hl)) {
          detectedTitle = hl.replace(/^(?:Meeting Title|Meeting):\s*/i, "").trim();
          if (/^Meeting Title:/i.test(hl) && !detectedSource) detectedSource = "Granola";
        } else if (/^Date:\s*/i.test(hl)) {
          detectedDate = extractIsoDay(hl.replace(/^Date:\s*/i, "")) || detectedDate;
        } else if (/^\d+m\s*\d+s$/.test(hl) || /^\d+h\s*\d+m/.test(hl)) {
          if (!detectedSource) detectedSource = "Microsoft Teams";
        } else {
          const maybeDate = extractIsoDay(hl);
          if (maybeDate && !detectedDate) detectedDate = maybeDate;
          else if (!detectedTitle && !maybeDate) detectedTitle = hl.replace(/^#\s+/, "");
        }
      }
      startIdx = transcriptMarkerIdx + 1;
    } else {
      const firstHeaderIdx = lines.findIndex(function (l) {
        const t = l.trim();
        return otterHeader.test(t) || colonLine.test(t) || krispParenLine.test(t) || krispDashLine.test(t);
      });
      if (firstHeaderIdx > 0 && firstHeaderIdx <= 8) {
        for (let h = 0; h < firstHeaderIdx; h++) {
          const hl = lines[h].trim();
          if (!hl || /^Transcript exported by Tactiq/i.test(hl) || /^https?:\/\/meet\.google\.com\//i.test(hl)) continue;
          const maybeDate = extractIsoDay(hl);
          if (maybeDate && !detectedDate) detectedDate = maybeDate;
          else if (!detectedTitle && !maybeDate) detectedTitle = hl.replace(/^#\s+/, "");
        }
        startIdx = firstHeaderIdx;
      }
    }

    for (let i = startIdx; i < lines.length; i++) {
      const line = lines[i].trim();
      if (!line || /^Transcribed by https?:\/\/otter\.ai/i.test(line) || /^Transcript exported by Tactiq/i.test(line)) {
        continue;
      }
      if (/^Action Items:?$/i.test(line)) {
        while (i + 1 < lines.length && lines[i + 1].trim() && !/^(Transcript|Summary|Highlights):?$/i.test(lines[i + 1].trim())) {
          i++;
          const cleaned = lines[i].trim().replace(/^[-*•\[\] xX]+/, "").trim();
          if (cleaned) actions.push(cleaned);
        }
        continue;
      }
      if (/^(Highlights|Key Points|Summary):?$/i.test(line)) {
        while (i + 1 < lines.length && lines[i + 1].trim() && !/^(Transcript|Action Items):?$/i.test(lines[i + 1].trim())) {
          i++;
          summaryLines.push(lines[i].trim());
        }
        continue;
      }

      const mOtter = otterHeader.exec(line);
      if (mOtter) {
        otterCount++;
        const spk = mOtter[1].trim();
        const ts = mOtter[2].trim();
        const body = [];
        while (
          i + 1 < lines.length &&
          lines[i + 1].trim() &&
          !otterHeader.test(lines[i + 1].trim()) &&
          !teamsInlineTs.test(lines[i + 1].trim())
        ) {
          i++;
          body.push(lines[i].trim());
        }
        if (spk) speakers.add(spk);
        turns.push({ speaker: spk, timestamp: ts, text: body.join(" ") });
        continue;
      }

      const mPipe = krispPipeHeader.exec(line);
      if (mPipe) {
        if (!detectedSource) detectedSource = "Krisp";
        const spk = mPipe[1].trim();
        const ts = mPipe[2].trim();
        const body = [];
        while (i + 1 < lines.length && lines[i + 1].trim() && !krispPipeHeader.test(lines[i + 1].trim())) {
          i++;
          body.push(lines[i].trim());
        }
        if (spk) speakers.add(spk);
        turns.push({ speaker: spk, timestamp: ts, text: body.join(" ") });
        continue;
      }

      const mTeams = teamsInlineTs.exec(line);
      if (mTeams && i + 1 < lines.length && lines[i + 1].trim() && !teamsInlineTs.test(lines[i + 1].trim())) {
        teamsCount++;
        const spk = mTeams[1].trim();
        const ts = mTeams[2].trim();
        const body = [];
        while (i + 1 < lines.length && lines[i + 1].trim() && !teamsInlineTs.test(lines[i + 1].trim())) {
          i++;
          body.push(lines[i].trim());
        }
        if (spk) speakers.add(spk);
        turns.push({ speaker: spk, timestamp: ts, text: body.join(" ") });
        continue;
      }

      if (i + 2 < lines.length && bareTimestamp.test(lines[i + 1].trim()) && !bareTimestamp.test(line)) {
        teamsCount++;
        const spk = line;
        const ts = lines[i + 1].trim();
        i += 2;
        const body = [lines[i].trim()];
        while (
          i + 1 < lines.length &&
          lines[i + 1].trim() &&
          !(i + 2 < lines.length && bareTimestamp.test(lines[i + 2].trim()))
        ) {
          i++;
          body.push(lines[i].trim());
        }
        speakers.add(spk);
        turns.push({ speaker: spk, timestamp: ts, text: body.join(" ") });
        continue;
      }

      const mKrispParen = krispParenLine.exec(line);
      if (mKrispParen) {
        if (!detectedSource) detectedSource = "Krisp";
        speakers.add(mKrispParen[1].trim());
        turns.push({ speaker: mKrispParen[1].trim(), timestamp: mKrispParen[2].trim(), text: mKrispParen[3].trim() });
        continue;
      }

      const mKrispDash = krispDashLine.exec(line);
      if (mKrispDash) {
        if (!detectedSource) detectedSource = "Krisp";
        speakers.add(mKrispDash[2].trim());
        turns.push({ speaker: mKrispDash[2].trim(), timestamp: mKrispDash[1].trim(), text: mKrispDash[3].trim() });
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

    const finalSource =
      detectedSource ||
      (teamsCount > 0 ? "Microsoft Teams" : otterCount > 0 ? "Otter.ai" : "Transcript");

    return [{
      title: detectedTitle || stripExtension(fileName).replace(/[_-]+/g, " ").trim() || "Meeting note",
      date: detectedDate,
      source: finalSource,
      attendees: Array.from(speakers),
      projects: [],
      summary: summaryLines.join("\n"),
      actions: actions,
      transcript: turns,
    }];
  }

  function parseScreenpipeJson(items, fileName) {
    const turns = [];
    const speakers = new Set();
    let date = extractIsoDay(fileName) || "";

    for (let i = 0; i < items.length; i++) {
      const entry = items[i];
      if (!entry || typeof entry !== "object") continue;
      const content = entry.content && typeof entry.content === "object" ? entry.content : entry;
      const entryType = String(entry.type || "").toLowerCase();
      const text = String(content.transcription || content.text || "").trim();
      if (!text) continue;
      if (!date) date = extractIsoDay(content.timestamp || entry.timestamp);
      const ts = formatIsoTime(content.timestamp || entry.timestamp);
      let speaker = "";
      if (content.speaker && typeof content.speaker === "object" && content.speaker.name) {
        speaker = String(content.speaker.name).trim();
      } else if (typeof content.speaker_name === "string" && content.speaker_name.trim()) {
        speaker = content.speaker_name.trim();
      } else if (content.speaker_id !== undefined && content.speaker_id !== null) {
        speaker = "Speaker " + content.speaker_id;
      } else if (entryType === "ocr" && content.app_name) {
        speaker = String(content.app_name).trim();
      } else if (content.device_name) {
        speaker = String(content.device_name).trim();
      }
      if (speaker && entryType !== "ocr") speakers.add(speaker);
      turns.push({ speaker: speaker, timestamp: ts, text: text });
    }
    if (turns.length === 0) return [];

    return [{
      title: stripExtension(fileName).replace(/[_-]+/g, " ").trim() || "Screenpipe audio export",
      date: date,
      source: "Screenpipe",
      attendees: Array.from(speakers),
      projects: [],
      summary: "",
      actions: [],
      transcript: turns,
    }];
  }

  function parseWisprJson(items, fileName) {
    const byDay = new Map();
    for (let i = 0; i < items.length; i++) {
      const item = items[i];
      if (!item || typeof item !== "object") continue;
      const text = String(item.formatted_text || item.asr_text || item.dictation || item.text || item.transcript || "").trim();
      if (!text) continue;
      const rawTs = item.timestamp || item.created_at || item.createdAt || item.date || "";
      const day = extractIsoDay(rawTs) || extractIsoDay(fileName) || "";
      const time = formatIsoTime(rawTs);
      const appLabel = String(item.app || item.app_name || item.application || "Dictation").trim();
      if (!byDay.has(day)) byDay.set(day, []);
      byDay.get(day).push({ speaker: appLabel, timestamp: time, text: text });
    }
    if (byDay.size === 0) return [];

    const results = [];
    byDay.forEach(function (turns, day) {
      results.push({
        title: day ? "Wispr Flow Dictations " + day : stripExtension(fileName).replace(/[_-]+/g, " ").trim() || "Wispr Flow Dictations",
        date: day,
        source: "Wispr Flow",
        attendees: [],
        projects: [],
        summary: "",
        actions: [],
        transcript: turns,
      });
    });
    return results;
  }

  function parseJsonRecord(rec, fallbackTitle, defaultSource) {
    if (!rec || typeof rec !== "object") return null;
    const title = rec.title || rec.meeting_title || rec.meeting_name || rec.name || fallbackTitle || "Untitled meeting";
    const date =
      extractIsoDay(rec.created_at) ||
      extractIsoDay(rec.date) ||
      extractIsoDay(rec.meetingDate) ||
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

    const projects = normalizeProjects(
      rec.projects || rec.project || rec.workspace_name || rec.workspace || rec.folder || null
    );

    let summary = "";
    if (typeof rec.notes_markdown === "string" && rec.notes_markdown.trim()) {
      summary = rec.notes_markdown.trim();
    } else if (typeof rec.notes_plain === "string" && rec.notes_plain.trim()) {
      summary = rec.notes_plain.trim();
    } else if (rec.notes && typeof rec.notes === "object") {
      summary = flattenProseMirror(rec.notes).trim();
    } else if (typeof rec.notes === "string" && rec.notes.trim()) {
      summary = rec.notes.trim();
    } else if (typeof rec.meeting_notes === "string" && rec.meeting_notes.trim()) {
      summary = rec.meeting_notes.trim();
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

    const extraBullets = Array.isArray(rec.key_points) ? rec.key_points : (Array.isArray(rec.highlights) ? rec.highlights : []);
    if (extraBullets.length > 0) {
      const bulletMd = extraBullets.map(function (b) {
        if (typeof b === "string") return "- " + b.trim();
        if (b && typeof b === "object" && (b.text || b.summary)) return "- " + String(b.text || b.summary).trim();
        return "";
      }).filter(Boolean).join("\n");
      if (bulletMd) summary = summary ? summary + "\n\n" + bulletMd : bulletMd;
    }

    const actions = [];
    const rawActions =
      rec.action_items ||
      rec.actionItems ||
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
      rec.entries ||
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
          typeof seg.time === "string" ? seg.time :
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
    } else if (rec.krisp_id || rec.meeting_name || Array.isArray(rec.key_points)) {
      source = "Krisp";
    } else if (rec.meetingDate || Array.isArray(rec.highlights) || Array.isArray(rec.actionItems) || Array.isArray(rec.entries)) {
      source = "Tactiq";
    }

    return {
      title: String(title).trim(),
      date: date,
      source: source,
      attendees: Array.from(attendees),
      projects: projects,
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
        if (ch === '"') {
          if (input[i + 1] === '"') {
            field += '"';
            i++;
          } else {
            inQuotes = false;
          }
        } else {
          field += ch;
        }
      } else if (ch === '"') {
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

    const isWispr =
      headers.includes("formatted_text") ||
      headers.includes("asr_text") ||
      headers.includes("dictation") ||
      (/wispr/i.test(fileName) && (headers.includes("text") || headers.includes("transcript")));
    if (isWispr) {
      const items = [];
      for (let r = 1; r < rows.length; r++) {
        const cells = rows[r];
        items.push({
          formatted_text: col(cells, ["formatted_text", "dictation", "text", "asr_text", "transcript"]),
          timestamp: col(cells, ["timestamp", "created_at", "date", "time"]),
          app: col(cells, ["app", "app_name", "application"]),
        });
      }
      return parseWisprJson(items, fileName);
    }

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
      const projects = normalizeProjects(col(cells, ["projects", "project", "workspace_name", "workspace", "folder"]));
      results.push({
        title: title,
        date: date,
        source: isGranola ? "Granola" : "CSV export",
        attendees: Array.from(attendees),
        projects: projects,
        summary: summaryParts.join("\n\n"),
        actions: [],
        transcript: parsedTranscript ? parsedTranscript.transcript : [],
      });
    }
    return results;
  }

  function looksLikeKnownCsv(trimmed) {
    const firstLine = trimmed.split(/\r?\n/, 1)[0].toLowerCase();
    return (
      firstLine.includes(",") &&
      (
        firstLine.includes("document_title") ||
        firstLine.includes("document_id") ||
        firstLine.includes("formatted_text") ||
        firstLine.includes("asr_text") ||
        (firstLine.includes("title") && firstLine.includes("transcript"))
      )
    );
  }

  function parseFile(fileName, content) {
    const ext = (String(fileName || "").split(".").pop() || "").toLowerCase();
    const trimmed = String(content || "").trim();
    if (!trimmed) return [];

    const looksLikeJson = trimmed.startsWith("{") || trimmed.startsWith("[");
    if (ext === "csv" || (ext !== "json" && !looksLikeJson && looksLikeKnownCsv(trimmed))) {
      const csvMeetings = parseCsvExport(content, fileName);
      if (csvMeetings.length > 0) return csvMeetings;
    }

    if (ext === "json" || looksLikeJson) {
      try {
        const parsed = JSON.parse(trimmed);
        if (
          parsed &&
          Array.isArray(parsed.data) &&
          parsed.data.length > 0 &&
          parsed.data[0] &&
          parsed.data[0].content &&
          (parsed.data[0].type === "Audio" || parsed.data[0].type === "OCR" || parsed.data[0].content.transcription !== undefined)
        ) {
          const sp = parseScreenpipeJson(parsed.data, fileName);
          if (sp.length > 0) return sp;
        }
        if (
          Array.isArray(parsed) &&
          parsed.length > 0 &&
          parsed[0] &&
          ((parsed[0].content && parsed[0].content.transcription !== undefined) || parsed[0].transcription !== undefined)
        ) {
          const spArr = parseScreenpipeJson(parsed, fileName);
          if (spArr.length > 0) return spArr;
        }
        const wisprList = Array.isArray(parsed)
          ? parsed
          : (parsed && (parsed.dictations || parsed.history || parsed.items));
        if (
          Array.isArray(wisprList) &&
          wisprList.length > 0 &&
          wisprList[0] &&
          (wisprList[0].formatted_text !== undefined || wisprList[0].asr_text !== undefined || (/wispr/i.test(fileName) && wisprList[0].text !== undefined))
        ) {
          const wp = parseWisprJson(wisprList, fileName);
          if (wp.length > 0) return wp;
        }

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
        let defaultSource = "JSON export";
        if (/granola/i.test(fileName)) defaultSource = "Granola";
        else if (/krisp/i.test(fileName)) defaultSource = "Krisp";
        else if (/tactiq/i.test(fileName)) defaultSource = "Tactiq";
        else if (/screenpipe/i.test(fileName)) defaultSource = "Screenpipe";
        else if (/wispr/i.test(fileName)) defaultSource = "Wispr Flow";

        const results = [];
        for (let i = 0; i < list.length; i++) {
          const item = parseJsonRecord(list[i], stripExtension(fileName), defaultSource);
          if (item) results.push(item);
        }
        if (results.length > 0) return results;
      } catch (_e) {
      }
    }

    if (ext === "vtt" || ext === "srt" || /^WEBVTT\b/i.test(trimmed) || /\d{2}:\d{2}:\d{2}[.,]\d{3}\s*-->/.test(trimmed)) {
      return parseVttOrSrt(content, fileName);
    }

    if (
      /screenpipe/i.test(fileName) ||
      /^#\s*screenpipe\b/im.test(trimmed) ||
      (/\[\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/.test(trimmed) && /\((?:microphone|system|output|input|speaker)/i.test(trimmed))
    ) {
      const screenpipe = parseScreenpipeMarkdown(content, fileName);
      if (screenpipe.some(function (meeting) { return meeting.transcript.length > 0; })) return screenpipe;
    }

    if (
      /wispr/i.test(fileName) ||
      /^\[\d{4}-\d{2}-\d{2}[T ]\d{1,2}:\d{2}(?::\d{2})?\]\s*\([^)]+\)\s+/m.test(trimmed)
    ) {
      return parseWisprPlainText(content, fileName);
    }

    if (ext === "md" || ext === "markdown") {
      const heading = /^#\s+(.+)$/m.exec(trimmed);
      const title = heading ? heading[1].trim() : stripExtension(fileName);
      return [{
        title: title,
        date: extractIsoDay(fileName) || "",
        source: "Markdown export",
        attendees: [],
        projects: [],
        summary: trimmed.replace(/^#\s+.+\n+/, "").trim(),
        actions: [],
        transcript: [],
      }];
    }

    return parseOtterOrPlainText(content, fileName);
  }

  async function parseBinaryFile(fileName, inputBytes) {
    const bytes = inputBytes instanceof Uint8Array ? inputBytes : new Uint8Array(inputBytes);
    const ext = (String(fileName || "").split(".").pop() || "").toLowerCase();

    if (ext === "docx") {
      const docxText = await extractDocxText(bytes);
      if (!docxText.trim()) return [];
      const forcedSource = /otter/i.test(fileName)
        ? "Otter.ai"
        : /fireflies/i.test(fileName)
          ? "Fireflies.ai"
          : "Microsoft Teams";
      return parseOtterOrPlainText(docxText, fileName, forcedSource);
    }

    if (ext === "zip") {
      const entries = await extractZipEntries(bytes);
      const decoder = new TextDecoder("utf-8");
      const out = [];
      for (let i = 0; i < entries.length; i++) {
        const entry = entries[i];
        const entryExt = (entry.name.split(".").pop() || "").toLowerCase();
        if (!SUPPORTED_ARCHIVE_EXTS.has(entryExt)) continue;
        if (entryExt === "docx") {
          const parsedDocx = await parseBinaryFile(entry.name, entry.bytes);
          parsedDocx.forEach(function (m) { out.push(m); });
        } else {
          const text = decoder.decode(entry.bytes);
          parseFile(entry.name, text).forEach(function (m) { out.push(m); });
        }
      }
      return out;
    }

    const decoded = new TextDecoder("utf-8").decode(bytes);
    return parseFile(fileName, decoded);
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

    const attendees = Array.isArray(meeting.attendees) ? meeting.attendees : [];
    const projects = Array.isArray(meeting.projects) ? meeting.projects : [];
    const actions = Array.isArray(meeting.actions) ? meeting.actions : [];
    const transcript = Array.isArray(meeting.transcript) ? meeting.transcript : [];

    const lines = [];
    if (options.includeFrontmatter) {
      lines.push("---");
      lines.push("title: " + escapeYaml(meeting.title));
      if (options.obsidianFormat) {
        lines.push("aliases:");
        lines.push("  - " + escapeYaml(meeting.title));
      }
      if (meeting.date) {
        const iso = /^\d{4}-\d{2}-\d{2}$/.test(meeting.date);
        lines.push("date: " + (iso ? meeting.date : escapeYaml(meeting.date)));
      }
      if (meeting.source) {
        lines.push("app: " + escapeYaml(meeting.source));
      }
      if (attendees.length > 0) {
        lines.push("people:");
        attendees.forEach(function (person) {
          const val = options.obsidianFormat && options.linkSpeakers ? "[[" + person + "]]" : person;
          lines.push("  - " + escapeYaml(val));
        });
      } else if (options.obsidianFormat) {
        lines.push("people: []");
      }
      if (projects.length > 0) {
        lines.push("projects:");
        projects.forEach(function (project) {
          const val = options.obsidianFormat && options.linkSpeakers ? "[[" + project + "]]" : project;
          lines.push("  - " + escapeYaml(val));
        });
      } else if (options.obsidianFormat) {
        lines.push("projects: []");
      }
      lines.push("tags:");
      lines.push("  - " + (options.obsidianFormat ? "lokalbot/meeting" : "meeting"));
      lines.push("source: " + (options.obsidianFormat ? "LokalBot" : escapeYaml(meeting.source || "Transcript")));
      lines.push("---");
      lines.push("");
    }

    lines.push("# " + meeting.title);
    lines.push("");
    const meta = [];
    if (meeting.date) meta.push("**Date:** " + meeting.date);
    if (meeting.source) meta.push("**Imported from:** " + meeting.source);
    if (attendees.length > 0) {
      const formatted = attendees.map(function (p) {
        return options.obsidianFormat && options.linkSpeakers ? "[[" + p + "]]" : p;
      }).join(", ");
      meta.push("**People:** " + formatted);
    }
    if (projects.length > 0) {
      const formattedProjects = projects.map(function (p) {
        return options.obsidianFormat && options.linkSpeakers ? "[[" + p + "]]" : p;
      }).join(", ");
      meta.push("**Projects:** " + formattedProjects);
    }
    if (meta.length > 0) {
      lines.push(meta.join(" · "));
      lines.push("");
    }

    if (actions.length > 0) {
      lines.push("## Action items");
      lines.push("");
      actions.forEach(function (a) {
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

    if (transcript.length > 0) {
      const renderedTurns = transcript.map(function (t) {
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
    const usedNames = new Set();

    for (let i = 0; i < entries.length; i++) {
      const original = entries[i].filename;
      let name = original;
      if (usedNames.has(name)) {
        const stem = original.replace(/\.md$/i, "");
        let count = 2;
        do {
          name = stem + " (" + count + ").md";
          count += 1;
        } while (usedNames.has(name));
      }
      usedNames.add(name);
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
      cv.setUint16(4, 0x0314, true);
      cv.setUint16(6, 20, true);
      cv.setUint16(8, 0x0800, true);
      cv.setUint16(10, 0, true);
      cv.setUint16(12, dosTime, true);
      cv.setUint16(14, dosDate, true);
      cv.setUint32(16, sum, true);
      cv.setUint32(20, dataBytes.length, true);
      cv.setUint32(24, dataBytes.length, true);
      cv.setUint16(28, nameBytes.length, true);
      cv.setUint32(38, 0x81a40000, true);
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
        workspace_name: "Desktop Launch",
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
      name: "2026-11-17-teams-design-sync.vtt",
      content: [
        "WEBVTT",
        "",
        "a1b2c3d4-0000-0000-0000-000000000001/1-0",
        "00:00:05.000 --> 00:00:11.000",
        "<v Elena Novak>Let's keep the Obsidian export as plain Markdown with collapsible transcripts.</v>",
        "",
        "a1b2c3d4-0000-0000-0000-000000000001/2-0",
        "00:00:12.000 --> 00:00:18.500",
        "<v Sam Patel>Agreed, and wikilinks on participant names make backlinks work automatically.</v>",
      ].join("\n"),
    },
  ];

  function initUI() {
    const dropzone = document.getElementById("migrator-dropzone");
    const fileInput = document.getElementById("migrator-file-input");
    const tabFiles = document.getElementById("migrator-tab-files");
    const tabPaste = document.getElementById("migrator-tab-paste");
    const pastePanel = document.getElementById("migrator-paste-panel");
    const pasteTitle = document.getElementById("migrator-paste-title");
    const pasteInput = document.getElementById("migrator-paste-input");
    const pasteBtn = document.getElementById("migrator-paste-btn");
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

    function setMode(mode) {
      const isPaste = mode === "paste";
      if (dropzone) dropzone.hidden = isPaste;
      if (pastePanel) pastePanel.hidden = !isPaste;
      if (tabFiles) {
        tabFiles.classList.toggle("is-active", !isPaste);
        tabFiles.setAttribute("aria-selected", !isPaste ? "true" : "false");
      }
      if (tabPaste) {
        tabPaste.classList.toggle("is-active", isPaste);
        tabPaste.setAttribute("aria-selected", isPaste ? "true" : "false");
      }
    }

    if (tabFiles) tabFiles.addEventListener("click", function () { setMode("files"); });
    if (tabPaste) tabPaste.addEventListener("click", function () { setMode("paste"); });

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
        statusEl.textContent = "Drop files above, paste text, or load sample exports to preview locally.";
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
        const ext = (f.name.split(".").pop() || "").toLowerCase();
        if (ext === "zip" || ext === "docx") {
          const buf = await f.arrayBuffer();
          const parsed = await parseBinaryFile(f.name, new Uint8Array(buf));
          parsed.forEach(function (m) { added.push(m); });
        } else {
          const text = await f.text();
          parseFile(f.name, text).forEach(function (m) { added.push(m); });
        }
      }
      if (added.length > 0) {
        rawMeetings = rawMeetings.concat(added);
        selectedIndex = rawMeetings.length - added.length;
        rerender();
      } else {
        statusEl.textContent = "No recognizable meeting content found in the dropped files.";
      }
    }

    if (pasteBtn && pasteInput) {
      pasteBtn.addEventListener("click", function () {
        const raw = pasteInput.value;
        if (!raw || !raw.trim()) {
          statusEl.textContent = "Paste a meeting transcript, JSON, CSV, or VTT snippet first.";
          return;
        }
        const customTitle = pasteTitle && pasteTitle.value.trim() ? pasteTitle.value.trim() : "";
        const nameHint = customTitle ? customTitle + ".txt" : "pasted-meeting.txt";
        const parsed = parseFile(nameHint, raw);
        if (parsed.length > 0) {
          if (customTitle && parsed.length === 1) {
            parsed[0].title = customTitle;
          }
          rawMeetings = rawMeetings.concat(parsed);
          selectedIndex = rawMeetings.length - parsed.length;
          rerender();
        } else {
          statusEl.textContent = "Could not parse the pasted text as a meeting note.";
        }
      });
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
      if (pasteInput) pasteInput.value = "";
      if (pasteTitle) pasteTitle.value = "";
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
    parseBinaryFile: parseBinaryFile,
    extractZipEntries: extractZipEntries,
    extractDocxText: extractDocxText,
    renderNote: renderNote,
    buildZip: buildZip,
    initUI: initUI,
  };
});
