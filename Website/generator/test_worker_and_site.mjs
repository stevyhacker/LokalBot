import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import { createRequire } from "node:module";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import mediaWorker from "../worker/media-ranges.js";

const require = createRequire(import.meta.url);
const __dirname = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(__dirname, "..", "..");
const migrate = require(path.join(repoRoot, "Website", "public", "migrate.js"));

function makeEnv(responseFactory) {
  return {
    ASSETS: {
      async fetch(request) {
        return responseFactory(request);
      },
    },
  };
}

test("media-ranges serves 206 partial content for explicit, open-ended, and suffix ranges", async () => {
  const payload = new TextEncoder().encode("0123456789abcdef");
  const env = makeEnv(() => new Response(payload, {
    status: 200,
    headers: { "Content-Type": "video/mp4", "Content-Length": String(payload.byteLength) },
  }));

  const middle = await mediaWorker.fetch(
    new Request("https://www.lokalbot.com/assets/demo.mp4", { headers: { Range: "bytes=2-5" } }),
    env,
  );
  assert.equal(middle.status, 206);
  assert.equal(middle.headers.get("Accept-Ranges"), "bytes");
  assert.equal(middle.headers.get("Content-Range"), "bytes 2-5/16");
  assert.equal(middle.headers.get("Content-Length"), "4");
  assert.equal(await middle.text(), "2345");

  const openEnded = await mediaWorker.fetch(
    new Request("https://www.lokalbot.com/assets/demo.mp4", { headers: { Range: "bytes=12-" } }),
    env,
  );
  assert.equal(openEnded.status, 206);
  assert.equal(openEnded.headers.get("Content-Range"), "bytes 12-15/16");
  assert.equal(await openEnded.text(), "cdef");

  const suffix = await mediaWorker.fetch(
    new Request("https://www.lokalbot.com/assets/demo.mp4", { headers: { Range: "bytes=-4" } }),
    env,
  );
  assert.equal(suffix.status, 206);
  assert.equal(suffix.headers.get("Content-Range"), "bytes 12-15/16");
  assert.equal(await suffix.text(), "cdef");
});

test("media-ranges serves 206 partial content when env.ASSETS omits Content-Length", async () => {
  const payload = new TextEncoder().encode("0123456789abcdef");
  const seenRequests = [];
  const env = makeEnv((req) => {
    seenRequests.push(req);
    return new Response(payload, {
      status: 200,
      headers: { "Content-Type": "video/mp4" },
    });
  });

  const safariProbe = await mediaWorker.fetch(
    new Request("https://www.lokalbot.com/assets/demos/full-wide-light.mp4", { headers: { Range: "bytes=0-1" } }),
    env,
  );
  assert.equal(safariProbe.status, 206);
  assert.equal(safariProbe.headers.get("Accept-Ranges"), "bytes");
  assert.equal(safariProbe.headers.get("Content-Range"), "bytes 0-1/16");
  assert.equal(safariProbe.headers.get("Content-Length"), "2");
  assert.equal(await safariProbe.text(), "01");
  assert.equal(seenRequests[0].method, "GET");
  assert.equal(seenRequests[0].headers.get("Range"), null);

  const audioSeek = await mediaWorker.fetch(
    new Request("https://www.lokalbot.com/assets/demo-sandbox/orders-api.en.m4a", { headers: { Range: "bytes=4-9" } }),
    env,
  );
  assert.equal(audioSeek.status, 206);
  assert.equal(audioSeek.headers.get("Content-Range"), "bytes 4-9/16");
  assert.equal(audioSeek.headers.get("Content-Length"), "6");
  assert.equal(await audioSeek.text(), "456789");

  const suffix = await mediaWorker.fetch(
    new Request("https://www.lokalbot.com/assets/demos/full-wide-light.mp4", { headers: { Range: "bytes=-3" } }),
    env,
  );
  assert.equal(suffix.status, 206);
  assert.equal(suffix.headers.get("Content-Range"), "bytes 13-15/16");
  assert.equal(await suffix.text(), "def");

  const oob = await mediaWorker.fetch(
    new Request("https://www.lokalbot.com/assets/demos/full-wide-light.mp4", { headers: { Range: "bytes=20-25" } }),
    env,
  );
  assert.equal(oob.status, 416);
  assert.equal(oob.headers.get("Content-Range"), "bytes */16");
});

test("media-ranges returns 416 for unsatisfiable or zero-suffix ranges", async () => {
  const payload = new TextEncoder().encode("0123456789");
  const env = makeEnv(() => new Response(payload, {
    status: 200,
    headers: { "Content-Type": "video/mp4", "Content-Length": String(payload.byteLength) },
  }));

  for (const header of ["bytes=10-12", "bytes=8-3", "bytes=-0"]) {
    const res = await mediaWorker.fetch(
      new Request("https://www.lokalbot.com/assets/demo.mp4", { headers: { Range: header } }),
      env,
    );
    assert.equal(res.status, 416, header);
    assert.equal(res.headers.get("Content-Range"), "bytes */10");
  }
});

test("media-ranges refuses buffering when Content-Length is invalid or exceeds limit", async () => {
  for (const headers of [
    { "Content-Type": "video/mp4", "Content-Length": "invalid" },
    { "Content-Type": "video/mp4", "Content-Length": String(64 * 1024 * 1024 + 1) },
  ]) {
    let buffered = false;
    const fakeResponse = new Response("streamed", { status: 200, headers });
    fakeResponse.arrayBuffer = async () => {
      buffered = true;
      return new ArrayBuffer(0);
    };
    const res = await mediaWorker.fetch(
      new Request("https://www.lokalbot.com/assets/large.mp4", { headers: { Range: "bytes=0-3" } }),
      makeEnv(() => fakeResponse),
    );
    assert.equal(res.status, 200);
    assert.equal(res.headers.get("Accept-Ranges"), "bytes");
    assert.equal(buffered, false);
  }
});

test("media-ranges serves stateless 302 redirects on /dl/* and strips query params", async () => {
  let assetCalls = 0;
  const env = makeEnv(() => {
    assetCalls += 1;
    return new Response("not found", { status: 404 });
  });

  for (const route of ["/dl/mac", "/dl/windows", "/dl/linux-deb", "/dl/linux-rpm", "/dl/linux", "/dl/mac/"]) {
    const res = await mediaWorker.fetch(
      new Request(`https://www.lokalbot.com${route}?utm_source=test&ref=123`),
      env,
    );
    assert.equal(res.status, 302, route);
    assert.equal(res.headers.get("Location"), "https://github.com/stevyhacker/lokalbot/releases/latest");
    assert.equal(res.headers.get("Set-Cookie"), null);
    assert.equal(res.headers.get("Referrer-Policy"), "no-referrer");
  }

  const headRes = await mediaWorker.fetch(
    new Request("https://www.lokalbot.com/dl/linux-deb", { method: "HEAD" }),
    env,
  );
  assert.equal(headRes.status, 302);
  assert.equal(assetCalls, 0);

  const unknown = await mediaWorker.fetch(
    new Request("https://www.lokalbot.com/dl/unknown"),
    env,
  );
  assert.equal(unknown.status, 404);
  assert.equal(assetCalls, 1);
});

test("media-ranges passes through non-media and HEAD requests without buffering", async () => {
  const htmlEnv = makeEnv(() => new Response("<html></html>", {
    status: 200,
    headers: { "Content-Type": "text/html", "Content-Length": "13" },
  }));
  const html = await mediaWorker.fetch(
    new Request("https://www.lokalbot.com/index.html", { headers: { Range: "bytes=0-3" } }),
    htmlEnv,
  );
  assert.equal(html.status, 200);
  assert.equal(html.headers.get("Accept-Ranges"), null);

  const headEnv = makeEnv(() => new Response(null, {
    status: 200,
    headers: { "Content-Type": "video/mp4", "Content-Length": "100" },
  }));
  const head = await mediaWorker.fetch(
    new Request("https://www.lokalbot.com/assets/demo.mp4", { method: "HEAD", headers: { Range: "bytes=0-3" } }),
    headEnv,
  );
  assert.equal(head.status, 200);
  assert.equal(head.headers.get("Accept-Ranges"), "bytes");
});

test("wrangler.jsonc and _headers configure worker routes, workers_dev, caching, and AEO signals", () => {
  const wrangler = JSON.parse(fs.readFileSync(path.join(repoRoot, "wrangler.jsonc"), "utf8"));
  assert.equal(wrangler.workers_dev, false);
  assert.ok(wrangler.assets.run_worker_first.includes("/dl/*"));
  assert.ok(wrangler.assets.run_worker_first.includes("/*.mp4"));
  assert.ok(wrangler.assets.run_worker_first.includes("/*.m4a"));

  const headersFile = fs.readFileSync(path.join(repoRoot, "Website", "public", "_headers"), "utf8");
  assert.ok(headersFile.includes("Content-Signal: ai-train=yes, search=yes, ai-input=yes"));
  assert.ok(headersFile.includes('Link: <https://www.lokalbot.com/llms.txt>; rel="llms-txt"'));
  assert.ok(headersFile.includes("Cache-Control: public, max-age=3600"));
  assert.ok(headersFile.includes("Cache-Control: public, max-age=86400"));
});

test("migrate buildZip deduplicates colliding filenames regardless of order", () => {
  for (const filenames of [
    ["Foo.md", "Foo.md", "Foo (2).md"],
    ["Foo (2).md", "Foo.md", "Foo.md"],
    ["Foo.md", "Foo (2).md", "Foo.md", "Foo (3).md"],
  ]) {
    const zipBytes = migrate.buildZip(filenames.map((filename, index) => ({
      filename,
      markdown: `# Note ${index}\n`,
    })));
    const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "lokalbot-zip-dedup-"));
    try {
      const zipPath = path.join(tmpDir, "out.zip");
      fs.writeFileSync(zipPath, Buffer.from(zipBytes));
      const names = JSON.parse(execFileSync(
        "python3",
        [
          "-c",
          "import json, sys, zipfile; z = zipfile.ZipFile(sys.argv[1]); assert z.testzip() is None; print(json.dumps(z.namelist()))",
          zipPath,
        ],
        { encoding: "utf8" },
      ));
      assert.equal(names.length, filenames.length);
      assert.equal(new Set(names).size, filenames.length, `duplicate entries for ${JSON.stringify(filenames)}: ${JSON.stringify(names)}`);
    } finally {
      fs.rmSync(tmpDir, { recursive: true, force: true });
    }
  }
});

test("migrate handles malformed and YAML-tricky inputs without throwing", () => {
  assert.deepEqual(migrate.parseFile("empty.txt", ""), []);
  const fallback = migrate.parseFile("broken.json", "{not json");
  assert.equal(fallback.length, 1);
  assert.equal(fallback[0].source, "Transcript");

  const note = migrate.renderNote({
    source: "Granola",
    title: 'Pricing: "Q4" — review',
    date: "2026-11-20",
    attendees: ['Maya: "Lead"'],
    summary: "Summary text",
    actions: [],
    transcript: [],
  }, {
    obsidianFormat: true,
    includeFrontmatter: true,
    collapseTranscript: true,
    linkSpeakers: true,
    datePrefixFilename: true,
  });
  assert.ok(note.markdown.startsWith("---\n"));
  assert.ok(note.markdown.includes('title: "Pricing: \\"Q4\\" — review"'));
  assert.ok(!note.filename.includes(":"));
});

test("app.js release asset regexes match shipped release artifact names and keep mobile share path-preserving", () => {
  const source = fs.readFileSync(path.join(repoRoot, "Website", "public", "app.js"), "utf8");
  const extract = (key) => {
    const escaped = key.includes("-") ? `"${key}"` : key;
    const match = source.match(new RegExp(`${escaped}:\\s*\\{\\s*pattern:\\s*/([^/]+)/`));
    assert.ok(match, `missing ASSETS.${key}.pattern in Website/public/app.js`);
    return new RegExp(match[1]);
  };

  const mac = extract("mac");
  const windows = extract("windows");
  const linux = extract("linux");
  const linuxDeb = extract("linux-deb");
  const linuxRpm = extract("linux-rpm");

  assert.match("LokalBot-0.14.0-macos-arm64.dmg", mac);
  assert.doesNotMatch("LokalBot-0.14.0-macos-arm64.dmg.sha256", mac);
  assert.match("LokalBot-0.14.0-windows-x86_64-setup.exe", windows);
  assert.doesNotMatch("LokalBot-0.14.0-windows-x86_64.zip", windows);
  assert.match("LokalBot-0.14.0-linux-x86_64.tar.gz", linux);
  assert.doesNotMatch("LokalBot-0.14.0-linux-x86_64.AppImage", linux);
  assert.match("LokalBot-0.14.0-linux-amd64.deb", linuxDeb);
  assert.match("LokalBot-0.14.0-linux-x86_64.rpm", linuxRpm);

  assert.ok(source.includes('document.documentElement.classList.add("js")'));
  assert.ok(source.includes("window.location.origin + window.location.pathname"));
  assert.ok(source.includes("requestIdleCallback"));

  const css = fs.readFileSync(path.join(repoRoot, "Website", "public", "styles.css"), "utf8");
  assert.ok(css.includes("html.js .reveal { opacity: 0;"));
  assert.ok(!/^\.reveal\s*\{\s*opacity:\s*0/m.test(css));
});

test("demo-sandbox data and audio fixture are complete and self-consistent", () => {
  const dataPath = path.join(repoRoot, "Website", "public", "assets", "demo-sandbox", "sandbox-data.json");
  const data = JSON.parse(fs.readFileSync(dataPath, "utf8"));
  assert.equal(data.meeting.turns.length, 29);
  assert.ok(data.meeting.decisions.length >= 2);
  assert.ok(data.meeting.actions.length >= 3);
  assert.ok(data.searchItems.some((item) => item.kind === "meeting"));
  assert.ok(data.searchItems.some((item) => item.kind === "screen"));
  assert.ok(data.askPresets.length >= 3);
  assert.ok(fs.existsSync(path.join(repoRoot, "Website", "public", data.meeting.audioUrl)));
});

test("redirect-rules.json preserves 404.html and root while enforcing 308 canonicals", () => {
  const rules = JSON.parse(fs.readFileSync(path.join(repoRoot, "Website", "worker", "redirect-rules.json"), "utf8"));
  assert.ok(Array.isArray(rules) && rules.length >= 4);
  for (const rule of rules) {
    assert.equal(rule.enabled, true);
    assert.equal(rule.action, "redirect");
    assert.equal(rule.action_parameters.from_value.status_code, 308);
  }
  const htmlRule = rules.find((r) => r.expression.includes(".html") && r.expression.includes("ends_with"));
  assert.ok(htmlRule && htmlRule.expression.includes('ne "/404.html"'));
  const slashRule = rules.find((r) => r.expression.includes('ends_with(http.request.uri.path, "/")'));
  assert.ok(slashRule && slashRule.expression.includes('ne "/"'));
  const hostRule = rules.find((r) => r.expression.includes('http.host eq "lokalbot.com"'));
  assert.ok(hostRule && hostRule.action_parameters.from_value.target_url.expression.includes("https://www.lokalbot.com"));
});

test("sitemap.xml and blog/feed.xml parse as valid XML with canonical URLs", () => {
  const sitemapPath = path.join(repoRoot, "Website", "public", "sitemap.xml");
  const feedPath = path.join(repoRoot, "Website", "public", "blog", "feed.xml");
  const summary = JSON.parse(execFileSync(
    "python3",
    [
      "-c",
      [
        "import json, sys, xml.etree.ElementTree as ET",
        "sm = ET.parse(sys.argv[1]).getroot()",
        "locs = [el.text for el in sm.findall('.//{http://www.sitemaps.org/schemas/sitemap/0.9}loc')]",
        "fd = ET.parse(sys.argv[2]).getroot()",
        "items = [el.attrib.get('href') for el in fd.findall('.//{http://www.w3.org/2005/Atom}entry/{http://www.w3.org/2005/Atom}link')]",
        "print(json.dumps({'locs': locs, 'items': items}))",
      ].join("; "),
      sitemapPath,
      feedPath,
    ],
    { encoding: "utf8" },
  ));
  assert.ok(summary.locs.length > 10);
  assert.ok(summary.locs.every((url) => url.startsWith("https://www.lokalbot.com/")));
  assert.ok(summary.items.length > 0);
  assert.ok(summary.items.every((url) => url.startsWith("https://www.lokalbot.com/")));
});
