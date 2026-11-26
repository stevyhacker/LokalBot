(function (root, factory) {
  const api = factory();
  if (typeof module === "object" && module.exports) {
    module.exports = api;
  } else {
    root.LokalBotCalculator = api;
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

  const SITE = "https://www.lokalbot.com";
  const WEEKS_PER_YEAR = 50;
  const MB_PER_HOUR_COMPRESSED = 28.8;
  const MB_PER_HOUR_PCM = 115.2;

  const TOOLS = [
    {
      id: "granola",
      name: "Granola",
      category: "Meeting notes",
      uploadsAudio: true,
      verified: "2026-10-26",
      compareUrl: "/lokalbot-vs-granola",
      defaultTier: "business",
      tiers: [
        { id: "business", label: "Business ($14/mo)", monthlyUsd: 14 },
      ],
    },
    {
      id: "wispr",
      name: "Wispr Flow",
      category: "Dictation & meetings",
      uploadsAudio: true,
      verified: "2026-10-26",
      compareUrl: "/lokalbot-vs-wispr-flow",
      defaultTier: "pro_monthly",
      tiers: [
        { id: "pro_monthly", label: "Pro monthly ($15/mo)", monthlyUsd: 15 },
        { id: "pro_annual", label: "Pro annual ($12/mo)", monthlyUsd: 12 },
      ],
    },
    {
      id: "otter",
      name: "Otter.ai",
      category: "Meeting notes",
      uploadsAudio: true,
      verified: "2026-10-26",
      compareUrl: "/lokalbot-vs-otter",
      defaultTier: "pro",
      tiers: [
        { id: "pro", label: "Pro annual ($8.33/mo)", monthlyUsd: 8.33 },
        { id: "business", label: "Business annual ($19.99/mo)", monthlyUsd: 19.99 },
      ],
    },
    {
      id: "fireflies",
      name: "Fireflies.ai",
      category: "Meeting notes",
      uploadsAudio: true,
      verified: "2026-10-26",
      compareUrl: "/lokalbot-vs-fireflies",
      defaultTier: "pro",
      tiers: [
        { id: "pro", label: "Pro annual ($10/mo)", monthlyUsd: 10 },
        { id: "business", label: "Business annual ($19/mo)", monthlyUsd: 19 },
      ],
    },
    {
      id: "fathom",
      name: "Fathom",
      category: "Meeting notes",
      uploadsAudio: true,
      verified: "2026-11-20",
      compareUrl: "/lokalbot-vs-fathom",
      defaultTier: "premium",
      tiers: [
        { id: "premium", label: "Premium annual ($16/mo)", monthlyUsd: 16 },
        { id: "business", label: "Business annual ($25/mo)", monthlyUsd: 25 },
      ],
    },
    {
      id: "notion",
      name: "Notion AI",
      category: "Workspace & meetings",
      uploadsAudio: true,
      verified: "2026-11-20",
      compareUrl: "/lokalbot-vs-notion-ai",
      defaultTier: "business",
      tiers: [
        { id: "business", label: "Business annual ($20/mo)", monthlyUsd: 20 },
      ],
    },
    {
      id: "readai",
      name: "Read.ai",
      category: "Meeting notes",
      uploadsAudio: true,
      verified: "2026-11-20",
      compareUrl: "/lokalbot-vs-read-ai",
      defaultTier: "pro",
      tiers: [
        { id: "pro", label: "Pro annual ($15/mo)", monthlyUsd: 15 },
      ],
    },
    {
      id: "superwhisper",
      name: "Superwhisper",
      category: "Dictation",
      uploadsAudio: false,
      verified: "2026-10-26",
      compareUrl: "/lokalbot-vs-superwhisper",
      defaultTier: "pro",
      tiers: [
        { id: "pro", label: "Pro ($8.49/mo)", monthlyUsd: 8.49 },
      ],
    },
    {
      id: "screenpipe",
      name: "Screenpipe",
      category: "Screen & audio memory",
      uploadsAudio: false,
      verified: "2026-10-26",
      compareUrl: "/lokalbot-vs-screenpipe",
      defaultTier: "basic",
      tiers: [
        { id: "basic", label: "Basic ($21/mo)", monthlyUsd: 21 },
      ],
    },
    {
      id: "openwhispr",
      name: "OpenWhispr",
      category: "Dictation",
      uploadsAudio: true,
      verified: "2026-10-26",
      compareUrl: "/lokalbot-vs-openwhispr",
      defaultTier: "pro",
      tiers: [
        { id: "pro", label: "Pro ($8/mo)", monthlyUsd: 8 },
        { id: "business", label: "Business ($16/mo)", monthlyUsd: 16 },
      ],
    },
  ];

  const PRESETS = [
    { id: "solo", label: "Solo stack (Granola + Wispr)", tools: ["granola", "wispr"], seats: 1, hours: 8, tiers: {} },
    { id: "startup", label: "Startup team (5 seats)", tools: ["granola", "wispr"], seats: 5, hours: 12, tiers: {} },
    { id: "sales", label: "Sales pod (15 seats)", tools: ["fathom", "notion"], seats: 15, hours: 15, tiers: { fathom: "business" } },
    { id: "org", label: "50-seat company", tools: ["otter", "wispr", "notion"], seats: 50, hours: 10, tiers: { otter: "business" } },
  ];

  const TOOL_MAP = new Map(TOOLS.map(function (t) { return [t.id, t]; }));

  function clampInt(val, min, max, fallback) {
    const n = Math.round(Number(val));
    if (!Number.isFinite(n)) return fallback;
    return Math.min(max, Math.max(min, n));
  }

  function resolveTier(tool, tierId) {
    if (!tool) return null;
    return (
      tool.tiers.find(function (tr) { return tr.id === tierId; }) ||
      tool.tiers.find(function (tr) { return tr.id === tool.defaultTier; }) ||
      tool.tiers[0]
    );
  }

  function formatUsd(amount) {
    const rounded = Math.round(amount * 100) / 100;
    const isWhole = Math.abs(rounded - Math.round(rounded)) < 0.005;
    return "$" + rounded.toLocaleString("en-US", {
      minimumFractionDigits: isWhole ? 0 : 2,
      maximumFractionDigits: isWhole ? 0 : 2,
    });
  }

  function calculate(config) {
    const seats = clampInt(config && config.seats, 1, 100, 1);
    const hours = clampInt(config && config.hours, 1, 40, 8);
    const selectedIds = Array.isArray(config && config.tools) ? config.tools : [];
    const tiers = (config && config.tiers) || {};
    const items = [];
    let perSeatMonthly = 0;
    let hasCloudAudio = false;

    const seen = new Set();
    for (let i = 0; i < selectedIds.length; i++) {
      const id = selectedIds[i];
      if (seen.has(id)) continue;
      const tool = TOOL_MAP.get(id);
      if (!tool) continue;
      seen.add(id);
      const tier = resolveTier(tool, tiers[id]);
      const monthlySeat = tier.monthlyUsd;
      const yearlyTotal = Math.round(monthlySeat * seats * 12 * 100) / 100;
      perSeatMonthly += monthlySeat;
      if (tool.uploadsAudio) hasCloudAudio = true;
      items.push({
        id: tool.id,
        name: tool.name,
        category: tool.category,
        tierId: tier.id,
        tierLabel: tier.label,
        monthlySeatUsd: monthlySeat,
        yearlyTotalUsd: yearlyTotal,
        uploadsAudio: tool.uploadsAudio,
        verified: tool.verified,
        compareUrl: tool.compareUrl,
      });
    }

    const monthlyTotalUsd = Math.round(perSeatMonthly * seats * 100) / 100;
    const oneYearUsd = Math.round(monthlyTotalUsd * 12 * 100) / 100;
    const threeYearUsd = Math.round(monthlyTotalUsd * 36 * 100) / 100;
    const annualAudioHours = hasCloudAudio ? hours * seats * WEEKS_PER_YEAR : 0;
    const annualAudioGb = Math.round(((annualAudioHours * MB_PER_HOUR_COMPRESSED) / 1000) * 10) / 10;
    const annualRawPcmGb = Math.round(((annualAudioHours * MB_PER_HOUR_PCM) / 1000) * 10) / 10;

    return {
      seats: seats,
      hours: hours,
      items: items,
      hasCloudAudio: hasCloudAudio,
      perSeatMonthlyUsd: Math.round(perSeatMonthly * 100) / 100,
      monthlyTotalUsd: monthlyTotalUsd,
      oneYearUsd: oneYearUsd,
      threeYearUsd: threeYearUsd,
      annualAudioHours: annualAudioHours,
      annualAudioGb: annualAudioGb,
      annualRawPcmGb: annualRawPcmGb,
    };
  }

  function serializeState(state) {
    const p = new URLSearchParams();
    const validTools = (state.tools || []).filter(function (id) { return TOOL_MAP.has(id); });
    p.set("tools", validTools.join(","));
    p.set("seats", String(clampInt(state.seats, 1, 100, 1)));
    p.set("hours", String(clampInt(state.hours, 1, 40, 8)));
    const tierPairs = [];
    for (let i = 0; i < validTools.length; i++) {
      const id = validTools[i];
      const tool = TOOL_MAP.get(id);
      const chosen = state.tiers && state.tiers[id];
      if (chosen && chosen !== tool.defaultTier && tool.tiers.some(function (tr) { return tr.id === chosen; })) {
        tierPairs.push(id + ":" + chosen);
      }
    }
    if (tierPairs.length > 0) p.set("tiers", tierPairs.join(","));
    return p.toString();
  }

  function parseState(searchStr) {
    const p = new URLSearchParams(searchStr || "");
    const hasTools = p.has("tools");
    const rawTools = hasTools
      ? (p.get("tools") || "").split(",").map(function (s) { return s.trim(); }).filter(function (id) { return TOOL_MAP.has(id); })
      : ["granola", "wispr"];
    const tools = Array.from(new Set(rawTools));
    const seats = clampInt(p.get("seats"), 1, 100, 1);
    const hours = clampInt(p.get("hours"), 1, 40, 8);
    const tiers = {};
    if (p.get("tiers")) {
      p.get("tiers").split(",").forEach(function (pair) {
        const parts = pair.split(":");
        const tool = TOOL_MAP.get(parts[0]);
        if (tool && parts[1] && tool.tiers.some(function (tr) { return tr.id === parts[1]; })) {
          tiers[parts[0]] = parts[1];
        }
      });
    }
    return { tools: tools, seats: seats, hours: hours, tiers: tiers };
  }

  function buildReceiptCardSpec(state, result) {
    const stackNames = result.items.length > 0
      ? result.items.map(function (it) { return it.name + " (" + formatUsd(it.monthlySeatUsd) + "/mo)"; })
      : ["No paid cloud tools selected"];
    return {
      title: "SaaS AI Stack Receipt",
      subtitle: result.seats + (result.seats === 1 ? " seat" : " seats") + " · " + result.hours + " hrs/wk per seat",
      oneYearDisplay: formatUsd(result.oneYearUsd),
      threeYearDisplay: formatUsd(result.threeYearUsd),
      audioHoursDisplay: result.annualAudioHours.toLocaleString("en-US") + " hrs/yr",
      audioGbDisplay: result.annualAudioGb.toFixed(1) + " GB/yr",
      lokalbotSpend: "$0",
      lokalbotAudio: "0 bytes uploaded",
      lines: stackNames,
      footer: "lokalbot.com/calculator",
      shareUrl: SITE + "/calculator?" + serializeState(state),
    };
  }

  function drawRoundedRect(ctx, x, y, w, h, r) {
    ctx.beginPath();
    ctx.moveTo(x + r, y);
    ctx.lineTo(x + w - r, y);
    ctx.quadraticCurveTo(x + w, y, x + w, y + r);
    ctx.lineTo(x + w, y + h - r);
    ctx.quadraticCurveTo(x + w, y + h, x + w - r, y + h);
    ctx.lineTo(x + r, y + h);
    ctx.quadraticCurveTo(x, y + h, x, y + h - r);
    ctx.lineTo(x, y + r);
    ctx.quadraticCurveTo(x, y, x + r, y);
    ctx.closePath();
  }

  function renderReceiptCanvas(state, result) {
    const spec = buildReceiptCardSpec(state, result);
    const width = 640;
    const itemHeight = 32;
    const visibleLines = spec.lines.slice(0, 8);
    const height = 470 + visibleLines.length * itemHeight;
    const scale = 2;

    const canvas = document.createElement("canvas");
    canvas.width = width * scale;
    canvas.height = height * scale;
    const ctx = canvas.getContext("2d");
    ctx.scale(scale, scale);

    const grad = ctx.createLinearGradient(0, 0, width, height);
    grad.addColorStop(0, "#080d14");
    grad.addColorStop(1, "#0f1c29");
    ctx.fillStyle = grad;
    ctx.fillRect(0, 0, width, height);

    drawRoundedRect(ctx, 24, 24, width - 48, height - 48, 22);
    ctx.fillStyle = "rgba(18, 28, 40, 0.92)";
    ctx.fill();
    ctx.strokeStyle = "rgba(110, 242, 220, 0.25)";
    ctx.lineWidth = 1.5;
    ctx.stroke();

    ctx.fillStyle = "#6ef2dc";
    ctx.font = "700 12px ui-monospace, SFMono-Regular, Menlo, monospace";
    ctx.fillText("LOKALBOT · CLOUD VS. ON-DEVICE", 48, 62);

    ctx.fillStyle = "#ecf3f7";
    ctx.font = "700 26px -apple-system, BlinkMacSystemFont, Helvetica, Arial, sans-serif";
    ctx.fillText(spec.title, 48, 96);

    ctx.fillStyle = "#8ba2b0";
    ctx.font = "500 14px ui-monospace, SFMono-Regular, Menlo, monospace";
    ctx.fillText(spec.subtitle, 48, 122);

    const kpis = [
      { label: "1-YEAR SAAS SPEND", val: spec.oneYearDisplay, sub: "vs. $0 with LokalBot" },
      { label: "3-YEAR SAAS SPEND", val: spec.threeYearDisplay, sub: "vs. $0 with LokalBot" },
      { label: "CLOUD AUDIO / YEAR", val: spec.audioHoursDisplay, sub: "vs. 0 hrs uploaded" },
      { label: "PRIVATE AUDIO SENT", val: spec.audioGbDisplay, sub: "vs. 0 bytes locally" },
    ];
    for (let i = 0; i < kpis.length; i++) {
      const col = i % 2;
      const row = Math.floor(i / 2);
      const bx = 48 + col * 278;
      const by = 144 + row * 102;
      drawRoundedRect(ctx, bx, by, 266, 88, 14);
      ctx.fillStyle = row === 0 ? "rgba(35, 196, 174, 0.12)" : "rgba(22, 33, 46, 0.85)";
      ctx.fill();
      ctx.strokeStyle = row === 0 ? "rgba(35, 196, 174, 0.4)" : "rgba(150, 180, 200, 0.2)";
      ctx.lineWidth = 1;
      ctx.stroke();

      ctx.fillStyle = "#8ba2b0";
      ctx.font = "700 11px ui-monospace, SFMono-Regular, Menlo, monospace";
      ctx.fillText(kpis[i].label, bx + 16, by + 26);
      ctx.fillStyle = "#ecf3f7";
      ctx.font = "700 24px ui-monospace, SFMono-Regular, Menlo, monospace";
      ctx.fillText(kpis[i].val, bx + 16, by + 56);
      ctx.fillStyle = "#6ef2dc";
      ctx.font = "600 12px ui-monospace, SFMono-Regular, Menlo, monospace";
      ctx.fillText(kpis[i].sub, bx + 16, by + 76);
    }

    let y = 374;
    ctx.fillStyle = "#8ba2b0";
    ctx.font = "700 11px ui-monospace, SFMono-Regular, Menlo, monospace";
    ctx.fillText("SELECTED CLOUD STACK", 48, y);
    y += 14;
    ctx.strokeStyle = "rgba(150, 180, 200, 0.2)";
    ctx.beginPath();
    ctx.moveTo(48, y);
    ctx.lineTo(width - 48, y);
    ctx.stroke();

    y += 26;
    for (let i = 0; i < visibleLines.length; i++) {
      const item = result.items[i];
      ctx.fillStyle = "#ecf3f7";
      ctx.font = "600 14px -apple-system, BlinkMacSystemFont, Helvetica, Arial, sans-serif";
      ctx.fillText(visibleLines[i], 48, y);
      if (item) {
        const rightText = formatUsd(item.yearlyTotalUsd) + "/yr";
        ctx.fillStyle = "#a2b4c2";
        ctx.font = "600 14px ui-monospace, SFMono-Regular, Menlo, monospace";
        const tw = ctx.measureText(rightText).width;
        ctx.fillText(rightText, width - 48 - tw, y);
      }
      y += itemHeight;
    }

    const footY = height - 44;
    ctx.fillStyle = "#6ef2dc";
    ctx.font = "700 13px ui-monospace, SFMono-Regular, Menlo, monospace";
    ctx.fillText(spec.footer, 48, footY);
    const badge = "Free · Open Source (GPLv3) · On-Device";
    ctx.fillStyle = "#8ba2b0";
    ctx.font = "500 12px ui-monospace, SFMono-Regular, Menlo, monospace";
    ctx.fillText(badge, width - 48 - ctx.measureText(badge).width, footY);

    return canvas;
  }

  function escapeHtml(str) {
    return String(str)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;");
  }

  function initUI() {
    const app = document.getElementById("calc-app");
    if (!app) return;

    let state = parseState(window.location.search);
    const presetsEl = document.getElementById("calc-presets");
    const toolsEl = document.getElementById("calc-tools");
    const seatsRange = document.getElementById("calc-seats");
    const seatsNum = document.getElementById("calc-seats-num");
    const hoursRange = document.getElementById("calc-hours");
    const hoursNum = document.getElementById("calc-hours-num");
    const summaryTag = document.getElementById("calc-summary-tag");
    const kpi1y = document.getElementById("calc-kpi-1y");
    const kpi3y = document.getElementById("calc-kpi-3y");
    const kpiHours = document.getElementById("calc-kpi-hours");
    const kpiGb = document.getElementById("calc-kpi-gb");
    const breakdownBody = document.getElementById("calc-breakdown-body");
    const copyLinkBtn = document.getElementById("calc-copy-link");
    const savePngBtn = document.getElementById("calc-save-png");

    function syncUrl() {
      const qs = serializeState(state);
      const next = window.location.pathname + "?" + qs;
      if (window.location.search !== "?" + qs && window.history && window.history.replaceState) {
        window.history.replaceState(null, "", next);
      }
    }

    function renderPresets() {
      presetsEl.innerHTML = PRESETS.map(function (pr) {
        const sameTools = pr.tools.length === state.tools.length && pr.tools.every(function (t) { return state.tools.includes(t); });
        const active = sameTools && pr.seats === state.seats && pr.hours === state.hours;
        return '<button type="button" class="calc-preset' + (active ? " is-active" : "") + '" data-calc-preset="' + escapeHtml(pr.id) + '">' + escapeHtml(pr.label) + "</button>";
      }).join("");
    }

    function renderTools() {
      toolsEl.innerHTML = TOOLS.map(function (tool) {
        const checked = state.tools.includes(tool.id);
        const activeTier = resolveTier(tool, state.tiers[tool.id]);
        const tierControl = tool.tiers.length > 1
          ? '<select class="calc-tier-select" data-calc-tier="' + escapeHtml(tool.id) + '" aria-label="' + escapeHtml(tool.name) + ' plan">' +
              tool.tiers.map(function (tr) {
                return '<option value="' + escapeHtml(tr.id) + '"' + (tr.id === activeTier.id ? " selected" : "") + ">" + escapeHtml(tr.label) + "</option>";
              }).join("") +
            "</select>"
          : '<span class="calc-tool__price">' + escapeHtml(formatUsd(activeTier.monthlyUsd)) + "/mo</span>";
        const audioNote = tool.uploadsAudio ? "Cloud audio" : "Local option";
        return (
          '<div class="calc-tool' + (checked ? " is-checked" : "") + '">' +
            '<input type="checkbox" id="tool-' + escapeHtml(tool.id) + '" data-calc-tool="' + escapeHtml(tool.id) + '"' + (checked ? " checked" : "") + " />" +
            '<label class="calc-tool__meta" for="tool-' + escapeHtml(tool.id) + '">' +
              '<span class="calc-tool__name">' + escapeHtml(tool.name) + "</span>" +
              '<span class="calc-tool__sub">' + escapeHtml(tool.category) + " · " + audioNote + " · Verified " + escapeHtml(tool.verified) + "</span>" +
            "</label>" +
            tierControl +
          "</div>"
        );
      }).join("");
    }

    function renderResults() {
      seatsRange.value = String(state.seats);
      seatsNum.value = String(state.seats);
      hoursRange.value = String(state.hours);
      hoursNum.value = String(state.hours);

      const res = calculate(state);
      summaryTag.textContent = res.seats + (res.seats === 1 ? " seat" : " seats") + " · " + res.hours + " hrs/wk";
      kpi1y.textContent = formatUsd(res.oneYearUsd);
      kpi3y.textContent = formatUsd(res.threeYearUsd);
      kpiHours.textContent = res.annualAudioHours.toLocaleString("en-US") + " hrs";
      kpiGb.textContent = res.annualAudioGb.toFixed(1) + " GB";

      if (res.items.length === 0) {
        breakdownBody.innerHTML = '<tr><td colspan="3">Select at least one tool on the left to estimate annual spend.</td></tr>';
      } else {
        breakdownBody.innerHTML = res.items.map(function (it) {
          return (
            "<tr>" +
              '<td><a href="' + escapeHtml(it.compareUrl) + '">' + escapeHtml(it.name) + "</a> · " + escapeHtml(it.tierLabel) + "</td>" +
              '<td class="is-num">' + escapeHtml(formatUsd(it.monthlySeatUsd)) + "</td>" +
              '<td class="is-num">' + escapeHtml(formatUsd(it.yearlyTotalUsd)) + "</td>" +
            "</tr>"
          );
        }).join("") +
        "<tr>" +
          "<td><strong>LokalBot (Desktop + Companion)</strong></td>" +
          '<td class="is-num"><strong>$0</strong></td>' +
          '<td class="is-num"><strong>$0</strong></td>' +
        "</tr>";
      }

      renderPresets();
      syncUrl();
    }

    function renderAll() {
      renderTools();
      renderResults();
    }

    presetsEl.addEventListener("click", function (e) {
      const btn = e.target.closest("[data-calc-preset]");
      if (!btn) return;
      const preset = PRESETS.find(function (p) { return p.id === btn.getAttribute("data-calc-preset"); });
      if (!preset) return;
      state = {
        tools: preset.tools.slice(),
        seats: preset.seats,
        hours: preset.hours,
        tiers: Object.assign({}, preset.tiers),
      };
      renderAll();
    });

    toolsEl.addEventListener("change", function (e) {
      const cb = e.target.closest("[data-calc-tool]");
      if (cb) {
        const id = cb.getAttribute("data-calc-tool");
        if (cb.checked && !state.tools.includes(id)) state.tools.push(id);
        else if (!cb.checked) state.tools = state.tools.filter(function (x) { return x !== id; });
        renderAll();
        return;
      }
      const sel = e.target.closest("[data-calc-tier]");
      if (sel) {
        const id = sel.getAttribute("data-calc-tier");
        state.tiers[id] = sel.value;
        if (!state.tools.includes(id)) state.tools.push(id);
        renderAll();
      }
    });

    function updateSeats(raw) {
      state.seats = clampInt(raw, 1, 100, 1);
      renderResults();
    }

    function updateHours(raw) {
      state.hours = clampInt(raw, 1, 40, 8);
      renderResults();
    }

    seatsRange.addEventListener("input", function () { updateSeats(seatsRange.value); });
    seatsNum.addEventListener("change", function () { updateSeats(seatsNum.value); });
    hoursRange.addEventListener("input", function () { updateHours(hoursRange.value); });
    hoursNum.addEventListener("change", function () { updateHours(hoursNum.value); });

    copyLinkBtn.addEventListener("click", function () {
      const url = SITE + "/calculator?" + serializeState(state);
      const prev = copyLinkBtn.textContent;
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(url).then(function () {
          copyLinkBtn.textContent = "Link copied";
          window.setTimeout(function () { copyLinkBtn.textContent = prev; }, 1600);
        }).catch(function () {});
      }
    });

    savePngBtn.addEventListener("click", function () {
      const res = calculate(state);
      const canvas = renderReceiptCanvas(state, res);
      canvas.toBlob(function (blob) {
        if (!blob) return;
        const url = URL.createObjectURL(blob);
        const a = document.createElement("a");
        a.href = url;
        a.download = "lokalbot-saas-receipt.png";
        document.body.appendChild(a);
        a.click();
        document.body.removeChild(a);
        window.setTimeout(function () { URL.revokeObjectURL(url); }, 1000);
      }, "image/png");
    });

    renderAll();
  }

  return {
    TOOLS: TOOLS,
    PRESETS: PRESETS,
    calculate: calculate,
    formatUsd: formatUsd,
    parseState: parseState,
    serializeState: serializeState,
    buildReceiptCardSpec: buildReceiptCardSpec,
    renderReceiptCanvas: renderReceiptCanvas,
    initUI: initUI,
  };
});
