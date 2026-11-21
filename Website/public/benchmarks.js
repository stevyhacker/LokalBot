/* =========================================================================
   LokalBot — Local Desktop AI Leaderboard (/benchmarks)
   Zero-dependency progressive enhancement over /benchmarks.json.
   ========================================================================= */
(function (root, factory) {
  if (typeof module === "object" && module.exports) {
    module.exports = factory();
  } else {
    var api = factory();
    root.LokalBotBenchmarks = api;
    if (typeof document !== "undefined") {
      if (document.readyState === "loading") {
        document.addEventListener("DOMContentLoaded", function () { api.boot(); });
      } else {
        api.boot();
      }
    }
  }
})(typeof globalThis !== "undefined" ? globalThis : this, function () {
  "use strict";

  var STATUS_LABELS = {
    default: "Default",
    option: "Local option",
    cloud: "Cloud API",
    rejected: "Not adopted",
    experimental: "Experimental",
    baseline: "Baseline",
  };

  function escapeHtml(value) {
    return String(value == null ? "" : value)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;")
      .replace(/'/g, "&#39;");
  }

  function findCategoryAndSuite(data, hashValue) {
    var categories = (data && data.categories) || [];
    if (!categories.length) return { category: null, suite: null };
    var clean = String(hashValue || "").replace(/^#/, "").trim().toLowerCase();
    if (clean) {
      for (var i = 0; i < categories.length; i++) {
        var cat = categories[i];
        if (cat.id.toLowerCase() === clean) {
          return { category: cat, suite: (cat.suites && cat.suites[0]) || null };
        }
        var suites = cat.suites || [];
        for (var j = 0; j < suites.length; j++) {
          if (suites[j].id.toLowerCase() === clean) {
            return { category: cat, suite: suites[j] };
          }
        }
      }
    }
    return { category: categories[0], suite: (categories[0].suites && categories[0].suites[0]) || null };
  }

  function filterRows(rows, filterMode) {
    var list = Array.isArray(rows) ? rows.slice() : [];
    if (!filterMode || filterMode === "all") return list;
    if (filterMode === "local") {
      return list.filter(function (row) { return row.kind === "local"; });
    }
    if (filterMode === "small") {
      return list.filter(function (row) {
        return row.kind === "local" && typeof row.sizeGb === "number" && row.sizeGb <= 1.0;
      });
    }
    if (filterMode === "compact") {
      return list.filter(function (row) {
        return row.kind === "local" && typeof row.sizeGb === "number" && row.sizeGb <= 4.0;
      });
    }
    return list;
  }

  function sortRows(rows, sortKey, sortDir) {
    var list = Array.isArray(rows) ? rows.slice() : [];
    if (!sortKey) return list;
    var dir = sortDir === "desc" ? -1 : 1;
    return list.sort(function (a, b) {
      var av = a.values && a.values[sortKey] ? a.values[sortKey].num : null;
      var bv = b.values && b.values[sortKey] ? b.values[sortKey].num : null;
      var aMissing = typeof av !== "number" || Number.isNaN(av);
      var bMissing = typeof bv !== "number" || Number.isNaN(bv);
      if (aMissing && bMissing) return 0;
      if (aMissing) return 1;
      if (bMissing) return -1;
      if (av === bv) return 0;
      return av < bv ? -dir : dir;
    });
  }

  function computeBarPercent(num, metric) {
    if (typeof num !== "number" || Number.isNaN(num) || !metric || !metric.max) return 0;
    var ratio = Math.max(0, Math.min(1, num / metric.max));
    return Math.round(ratio * 1000) / 10;
  }

  function availableFilters(suite) {
    var rows = (suite && suite.rows) || [];
    var hasCloud = rows.some(function (r) { return r.kind === "cloud"; });
    var sizedLocals = rows.filter(function (r) { return r.kind === "local" && typeof r.sizeGb === "number"; });
    var hasSmall = sizedLocals.some(function (r) { return r.sizeGb <= 1.0; }) &&
                   sizedLocals.some(function (r) { return r.sizeGb > 1.0; });
    var hasCompact = sizedLocals.some(function (r) { return r.sizeGb <= 4.0; }) &&
                     sizedLocals.some(function (r) { return r.sizeGb > 4.0; });

    var opts = [{ id: "all", label: "All (" + rows.length + ")" }];
    if (hasCloud) {
      var localCount = rows.filter(function (r) { return r.kind === "local"; }).length;
      opts.push({ id: "local", label: "Local only (" + localCount + ")" });
    }
    if (hasSmall) {
      var smallCount = sizedLocals.filter(function (r) { return r.sizeGb <= 1.0; }).length;
      opts.push({ id: "small", label: "≤ 1 GB (" + smallCount + ")" });
    }
    if (hasCompact) {
      var compactCount = sizedLocals.filter(function (r) { return r.sizeGb <= 4.0; }).length;
      opts.push({ id: "compact", label: "≤ 4 GB (" + compactCount + ")" });
    }
    return opts;
  }

  function toMarkdownTable(suite, rows) {
    var cols = suite.columns || [];
    var headers = ["Model", "Type / Runtime"].concat(cols.map(function (c) { return c.label; }));
    var sep = ["---", "---"].concat(cols.map(function (c) { return c.align === "right" ? "---:" : "---"; }));
    var lines = [
      "### " + suite.label,
      "",
      "| " + headers.join(" | ") + " |",
      "| " + sep.join(" | ") + " |",
    ];
    for (var i = 0; i < rows.length; i++) {
      var row = rows[i];
      var cells = [
        row.status === "default" ? "**" + row.model + "**" : row.model,
        (row.runtime || "") + (row.quant ? " (" + row.quant + ")" : ""),
      ];
      for (var j = 0; j < cols.length; j++) {
        var cell = row.values && row.values[cols[j].key];
        cells.push(cell ? cell.display : "—");
      }
      lines.push("| " + cells.join(" | ") + " |");
    }
    lines.push("");
    lines.push("Source: https://www.lokalbot.com/benchmarks#" + suite.id + " · Hardware: " + suite.hardware + " · Report: " + suite.reportUrl);
    return lines.join("\n");
  }

  function renderScatterSvg(suite, rows) {
    if (!suite.scatter) return "";
    var sc = suite.scatter;
    var w = 920;
    var h = 290;
    var padL = 62;
    var padR = 32;
    var padT = 26;
    var padB = 46;
    var plotW = w - padL - padR;
    var plotH = h - padT - padB;

    function xPos(pct) { return padL + (Math.max(0, Math.min(100, pct)) / 100) * plotW; }
    function yPos(pct) { return padT + plotH - (Math.max(0, Math.min(100, pct)) / 100) * plotH; }

    var grid = [];
    var ticks = [0, 25, 50, 75, 100];
    for (var t = 0; t < ticks.length; t++) {
      var v = ticks[t];
      var gx = xPos(v);
      var gy = yPos(v);
      grid.push('<line x1="' + gx + '" y1="' + padT + '" x2="' + gx + '" y2="' + (padT + plotH) + '" class="lb-scatter__grid" />');
      grid.push('<line x1="' + padL + '" y1="' + gy + '" x2="' + (padL + plotW) + '" y2="' + gy + '" class="lb-scatter__grid" />');
      grid.push('<text x="' + gx + '" y="' + (padT + plotH + 18) + '" text-anchor="middle" class="lb-scatter__tick">' + v + '%</text>');
      grid.push('<text x="' + (padL - 10) + '" y="' + (gy + 4) + '" text-anchor="end" class="lb-scatter__tick">' + v + '%</text>');
    }

    // Ideal corner callout (top-right: high recall + high empty restraint)
    var idealBox =
      '<rect x="' + xPos(80) + '" y="' + yPos(100) + '" width="' + (xPos(100) - xPos(80)) + '" height="' + (yPos(75) - yPos(100)) + '" rx="8" class="lb-scatter__ideal" />' +
      '<text x="' + (xPos(100) - 10) + '" y="' + (yPos(100) + 17) + '" text-anchor="end" class="lb-scatter__ideal-label">Ideal zone</text>';

    var labelPos = {
      "mem-qwen35-4b":   { anchor: "end",    dx: -13, dy: 4 },
      "mem-qwen35-9b":   { anchor: "middle", dx: 0,   dy: 22 },
      "mem-memt-nano":   { anchor: "end",    dx: -13, dy: 6 },
      "mem-lfm25-24b":   { anchor: "end",    dx: -13, dy: 4 },
      "mem-hymemory-30b":{ anchor: "end",    dx: -13, dy: -6 },
      "mem-sr-qwen4b":   { anchor: "end",    dx: -13, dy: 4 },
      "mem-sr-qwen9b":   { anchor: "end",    dx: -13, dy: 4 },
      "mem-sr-memt":     { anchor: "end",    dx: -13, dy: 20 },
      "mem-sr-lfm24b":   { anchor: "end",    dx: -13, dy: -6 },
      "mem-sr-hymemory": { anchor: "end",    dx: -13, dy: -6 },
    };

    var points = [];
    for (var i = 0; i < rows.length; i++) {
      var row = rows[i];
      var xv = row.values && row.values[sc.xKey] ? row.values[sc.xKey].num : null;
      var yv = row.values && row.values[sc.yKey] ? row.values[sc.yKey].num : null;
      if (typeof xv !== "number" || typeof yv !== "number") continue;
      var unw = row.values && row.values[sc.sizeKey] ? row.values[sc.sizeKey].num : 0;
      var cx = xPos(xv);
      var cy = yPos(yv);
      var cls = "lb-scatter__dot lb-scatter__dot--" + escapeHtml(row.status || "option");
      var radius = row.status === "default" || row.status === "experimental" ? 7.5 : 6.5;

      var cfg = labelPos[row.id] || {
        anchor: xv > 75 ? "end" : "start",
        dx: xv > 75 ? -13 : 13,
        dy: yv < 15 ? -8 : 4,
      };

      points.push(
        '<g class="lb-scatter__point">' +
          '<circle cx="' + cx + '" cy="' + cy + '" r="' + radius + '" class="' + cls + '">' +
            '<title>' + escapeHtml(row.model + ": " + xv + "% recall, " + yv + "% empty correct, " + unw + " unwanted") + '</title>' +
          '</circle>' +
          '<text x="' + (cx + cfg.dx) + '" y="' + (cy + cfg.dy) + '" text-anchor="' + cfg.anchor + '" class="lb-scatter__label">' +
            escapeHtml(row.model) +
            ' <tspan class="lb-scatter__sub">(' + escapeHtml(unw) + ' unw.)</tspan>' +
          '</text>' +
        '</g>'
      );
    }

    return (
      '<figure class="lb-scatter-card">' +
        '<div class="lb-scatter-card__head">' +
          '<span class="lb-scatter-card__title">' + escapeHtml(sc.title) + '</span>' +
          '<span class="lb-scatter-card__legend">' +
            '<span><i class="lb-dot lb-dot--default"></i>Default</span>' +
            '<span><i class="lb-dot lb-dot--experimental"></i>Experimental</span>' +
            '<span><i class="lb-dot lb-dot--option"></i>Option</span>' +
            '<span><i class="lb-dot lb-dot--rejected"></i>Not adopted</span>' +
          '</span>' +
        '</div>' +
        '<svg viewBox="0 0 ' + w + ' ' + h + '" class="lb-scatter" role="img" aria-label="' + escapeHtml(sc.title) + '">' +
          idealBox +
          grid.join("") +
          '<text x="' + (padL + plotW / 2) + '" y="' + (h - 8) + '" text-anchor="middle" class="lb-scatter__axis">' + escapeHtml(sc.xLabel) + ' →</text>' +
          '<text x="18" y="' + (padT + plotH / 2) + '" text-anchor="middle" transform="rotate(-90 18 ' + (padT + plotH / 2) + ')" class="lb-scatter__axis">' + escapeHtml(sc.yLabel) + ' →</text>' +
          points.join("") +
        '</svg>' +
      '</figure>'
    );
  }

  function initUI(rootEl, data) {
    if (!rootEl || !data || !Array.isArray(data.categories) || !data.categories.length) return null;

    var initial = findCategoryAndSuite(data, typeof window !== "undefined" ? window.location.hash : "");
    var state = {
      categoryId: initial.category.id,
      suiteId: initial.suite.id,
      filter: "all",
      sortKey: initial.suite.defaultSort ? initial.suite.defaultSort.key : null,
      sortDir: initial.suite.defaultSort ? initial.suite.defaultSort.dir : "asc",
    };

    function getActive() {
      var cat = data.categories.find(function (c) { return c.id === state.categoryId; }) || data.categories[0];
      var suite = (cat.suites || []).find(function (s) { return s.id === state.suiteId; }) || cat.suites[0];
      return { cat: cat, suite: suite };
    }

    function selectCategory(catId, suiteId, pushHash) {
      var cat = data.categories.find(function (c) { return c.id === catId; }) || data.categories[0];
      var suite = suiteId
        ? (cat.suites || []).find(function (s) { return s.id === suiteId; }) || cat.suites[0]
        : cat.suites[0];
      state.categoryId = cat.id;
      state.suiteId = suite.id;
      state.filter = "all";
      state.sortKey = suite.defaultSort ? suite.defaultSort.key : null;
      state.sortDir = suite.defaultSort ? suite.defaultSort.dir : "asc";
      if (pushHash && typeof window !== "undefined" && window.history && window.history.replaceState) {
        window.history.replaceState(null, "", "#" + suite.id);
      }
      render();
    }

    function render() {
      var active = getActive();
      var cat = active.cat;
      var suite = active.suite;
      var filters = availableFilters(suite);
      if (!filters.some(function (f) { return f.id === state.filter; })) {
        state.filter = "all";
      }

      var filtered = filterRows(suite.rows, state.filter);
      var rows = sortRows(filtered, state.sortKey, state.sortDir);

      // Identify best local numeric value for primary metric highlighting
      var pMetric = suite.primaryMetric;
      var bestVal = null;
      if (pMetric) {
        for (var k = 0; k < rows.length; k++) {
          var cell = rows[k].values && rows[k].values[pMetric.key];
          if (!cell || typeof cell.num !== "number") continue;
          if (bestVal === null) bestVal = cell.num;
          else if (pMetric.dir === "asc" && cell.num < bestVal) bestVal = cell.num;
          else if (pMetric.dir === "desc" && cell.num > bestVal) bestVal = cell.num;
        }
      }

      // 1. Category tabs
      var catTabsHtml = data.categories.map(function (c) {
        var isActive = c.id === cat.id;
        return (
          '<button type="button" role="tab" class="lb-tab' + (isActive ? " is-active" : "") + '"' +
            ' aria-selected="' + (isActive ? "true" : "false") + '"' +
            ' data-lb-cat="' + escapeHtml(c.id) + '">' +
            escapeHtml(c.shortLabel) +
          '</button>'
        );
      }).join("");

      // 2. Sub-suite pills (only when category has > 1 suite)
      var suiteTabsHtml = "";
      if (cat.suites.length > 1) {
        suiteTabsHtml =
          '<div class="lb-subtabs" role="tablist" aria-label="Benchmark suites in ' + escapeHtml(cat.shortLabel) + '">' +
          cat.suites.map(function (s) {
            var isSel = s.id === suite.id;
            return (
              '<button type="button" role="tab" class="lb-subtab' + (isSel ? " is-active" : "") + '"' +
                ' aria-selected="' + (isSel ? "true" : "false") + '"' +
                ' data-lb-suite="' + escapeHtml(s.id) + '">' +
                escapeHtml(s.shortLabel) +
              '</button>'
            );
          }).join("") +
          '</div>';
      }

      // 3. Filter pills
      var filterHtml = filters.length > 1
        ? '<div class="lb-filters" role="group" aria-label="Filter models">' +
            filters.map(function (f) {
              var on = f.id === state.filter;
              return (
                '<button type="button" class="lb-filter' + (on ? " is-active" : "") + '"' +
                  ' aria-pressed="' + (on ? "true" : "false") + '"' +
                  ' data-lb-filter="' + escapeHtml(f.id) + '">' +
                  escapeHtml(f.label) +
                '</button>'
              );
            }).join("") +
          '</div>'
        : "";

      // 4. Table header
      var headCols = suite.columns.map(function (col) {
        var isSorted = state.sortKey === col.key;
        var alignCls = col.align === "right" ? " is-num" : "";
        if (!col.sortable) {
          return '<th scope="col" class="lb-th' + alignCls + '">' + escapeHtml(col.label) + '</th>';
        }
        var ariaSort = isSorted ? (state.sortDir === "asc" ? "ascending" : "descending") : "none";
        var arrow = isSorted ? (state.sortDir === "asc" ? " ▲" : " ▼") : "";
        return (
          '<th scope="col" class="lb-th lb-th--sort' + alignCls + (isSorted ? " is-sorted" : "") + '" aria-sort="' + ariaSort + '">' +
            '<button type="button" class="lb-sort-btn" data-lb-sort="' + escapeHtml(col.key) + '" data-lb-default-dir="' + escapeHtml(col.dir || "asc") + '">' +
              escapeHtml(col.label) + '<span class="lb-sort-arrow" aria-hidden="true">' + arrow + '</span>' +
            '</button>' +
          '</th>'
        );
      }).join("");

      // 5. Table rows
      var bodyRows = rows.map(function (row, idx) {
        var badgeLabel = STATUS_LABELS[row.status] || row.status;
        var rowCls = "lb-row lb-row--" + escapeHtml(row.status || "option");
        var cellsHtml = suite.columns.map(function (col) {
          var cell = row.values && row.values[col.key];
          var display = cell ? cell.display : "—";
          var sub = cell && cell.sub ? '<span class="lb-cell-sub">' + escapeHtml(cell.sub) + '</span>' : "";
          var alignCls = col.align === "right" ? " is-num" : "";
          var isPrimary = pMetric && pMetric.key === col.key && cell && typeof cell.num === "number";
          var isWinner = isPrimary && bestVal !== null && cell.num === bestVal;

          if (isPrimary) {
            var pct = computeBarPercent(cell.num, pMetric);
            return (
              '<td class="lb-td lb-td--primary' + alignCls + (isWinner ? " is-best" : "") + '">' +
                '<div class="lb-metric">' +
                  '<span class="lb-metric__val">' + escapeHtml(display) + '</span>' +
                  sub +
                  '<span class="lb-bar" aria-hidden="true"><span class="lb-bar__fill' +
                    (row.status === "default" ? " is-default" : "") +
                    (row.kind === "cloud" ? " is-cloud" : "") +
                    '" style="width:' + pct + '%"></span></span>' +
                '</div>' +
              '</td>'
            );
          }

          return (
            '<td class="lb-td' + alignCls + '">' +
              '<span class="lb-cell-val">' + escapeHtml(display) + '</span>' +
              sub +
            '</td>'
          );
        }).join("");

        var noteHtml = row.note
          ? '<div class="lb-model-note">' + escapeHtml(row.note) + '</div>'
          : "";

        return (
          '<tr class="' + rowCls + '">' +
            '<th scope="row" class="lb-td lb-td--model">' +
              '<div class="lb-model-line">' +
                '<span class="lb-rank">' + (idx + 1) + '</span>' +
                '<div class="lb-model-meta">' +
                  '<div class="lb-model-top">' +
                    '<span class="lb-model-name">' + escapeHtml(row.model) + '</span>' +
                    '<span class="lb-badge lb-badge--' + escapeHtml(row.status || "option") + '">' + escapeHtml(badgeLabel) + '</span>' +
                  '</div>' +
                  '<div class="lb-model-sub">' +
                    escapeHtml(row.org || "") +
                    (row.runtime ? " · " + escapeHtml(row.runtime) : "") +
                    (row.quant ? " · " + escapeHtml(row.quant) : "") +
                  '</div>' +
                  noteHtml +
                '</div>' +
              '</div>' +
            '</th>' +
            cellsHtml +
          '</tr>'
        );
      }).join("");

      var scatterHtml = renderScatterSvg(suite, rows);
      var blogLink = suite.blogUrl
        ? '<a class="lb-meta-link" href="' + escapeHtml(suite.blogUrl) + '">Deep dive →</a>'
        : "";

      rootEl.innerHTML =
        '<div class="lb-tabs" role="tablist" aria-label="Benchmark categories">' + catTabsHtml + '</div>' +
        '<div class="lb-panel" role="tabpanel">' +
          '<div class="lb-panel__head">' +
            '<div>' +
              '<p class="lb-panel__eyebrow">' + escapeHtml(cat.label) + '</p>' +
              '<h2 class="lb-panel__title">' + escapeHtml(suite.label) + '</h2>' +
              '<p class="lb-panel__summary">' + escapeHtml(cat.summary) + '</p>' +
            '</div>' +
            '<div class="lb-panel__actions">' +
              '<button type="button" class="lb-action-btn" data-lb-copy-link>Copy link</button>' +
              '<button type="button" class="lb-action-btn" data-lb-copy-md>Copy Markdown</button>' +
            '</div>' +
          '</div>' +
          suiteTabsHtml +
          '<div class="lb-controls">' +
            filterHtml +
            '<div class="lb-run-meta">' +
              '<span>Run: <strong>' + escapeHtml(suite.runDate) + '</strong></span>' +
              '<span>' + escapeHtml(suite.hardware) + '</span>' +
            '</div>' +
          '</div>' +
          scatterHtml +
          '<div class="lb-table-wrap">' +
            '<table class="lb-table">' +
              '<thead><tr><th scope="col" class="lb-th lb-th--model">Model / Configuration</th>' + headCols + '</tr></thead>' +
              '<tbody>' + bodyRows + '</tbody>' +
            '</table>' +
          '</div>' +
          '<div class="lb-footnotes">' +
            '<p><strong>Dataset:</strong> ' + escapeHtml(suite.dataset) + '. ' + escapeHtml(suite.note) + '</p>' +
            '<p class="lb-caveat"><strong>Honest caveat:</strong> ' + escapeHtml(suite.caveat) + '</p>' +
            '<div class="lb-links">' +
              '<a class="lb-meta-link" href="' + escapeHtml(suite.reportUrl) + '" target="_blank" rel="noopener">Full REPORT.md ↗</a>' +
              '<a class="lb-meta-link" href="' + escapeHtml(suite.harnessUrl) + '" target="_blank" rel="noopener">Reproduce harness ↗</a>' +
              blogLink +
            '</div>' +
          '</div>' +
        '</div>';

      // Bind interactive listeners
      rootEl.querySelectorAll("[data-lb-cat]").forEach(function (btn) {
        btn.addEventListener("click", function () {
          selectCategory(btn.getAttribute("data-lb-cat"), null, true);
        });
      });

      rootEl.querySelectorAll("[data-lb-suite]").forEach(function (btn) {
        btn.addEventListener("click", function () {
          selectCategory(state.categoryId, btn.getAttribute("data-lb-suite"), true);
        });
      });

      rootEl.querySelectorAll("[data-lb-filter]").forEach(function (btn) {
        btn.addEventListener("click", function () {
          state.filter = btn.getAttribute("data-lb-filter");
          render();
        });
      });

      rootEl.querySelectorAll("[data-lb-sort]").forEach(function (btn) {
        btn.addEventListener("click", function () {
          var key = btn.getAttribute("data-lb-sort");
          var defDir = btn.getAttribute("data-lb-default-dir") || "asc";
          if (state.sortKey === key) {
            state.sortDir = state.sortDir === "asc" ? "desc" : "asc";
          } else {
            state.sortKey = key;
            state.sortDir = defDir;
          }
          render();
        });
      });

      var copyLinkBtn = rootEl.querySelector("[data-lb-copy-link]");
      if (copyLinkBtn) {
        copyLinkBtn.addEventListener("click", function () {
          var url = "https://www.lokalbot.com/benchmarks#" + suite.id;
          copyText(url, copyLinkBtn, "Copied link");
        });
      }

      var copyMdBtn = rootEl.querySelector("[data-lb-copy-md]");
      if (copyMdBtn) {
        copyMdBtn.addEventListener("click", function () {
          var md = toMarkdownTable(suite, rows);
          copyText(md, copyMdBtn, "Copied Markdown");
        });
      }
    }

    function copyText(text, btn, doneLabel) {
      var prev = btn.textContent;
      if (typeof navigator !== "undefined" && navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(text).then(function () {
          btn.textContent = doneLabel;
          setTimeout(function () { btn.textContent = prev; }, 1600);
        }).catch(function () {});
      }
    }

    // Wire Reference Stack jump cards if present on the page
    if (typeof document !== "undefined") {
      document.querySelectorAll("[data-lb-jump-cat]").forEach(function (el) {
        el.addEventListener("click", function (ev) {
          ev.preventDefault();
          var targetCat = el.getAttribute("data-lb-jump-cat");
          var targetSuite = el.getAttribute("data-lb-jump-suite");
          selectCategory(targetCat, targetSuite, true);
          rootEl.scrollIntoView({ behavior: "smooth", block: "start" });
        });
      });

      if (typeof window !== "undefined") {
        window.addEventListener("hashchange", function () {
          var target = findCategoryAndSuite(data, window.location.hash);
          if (target.category && target.suite) {
            selectCategory(target.category.id, target.suite.id, false);
          }
        });
      }
    }

    render();
    return { selectCategory: selectCategory, getState: function () { return Object.assign({}, state); } };
  }

  function boot() {
    var rootEl = document.getElementById("leaderboard-root");
    if (!rootEl) return;
    fetch("/benchmarks.json")
      .then(function (res) {
        if (!res.ok) throw new Error("HTTP " + res.status);
        return res.json();
      })
      .then(function (data) {
        initUI(rootEl, data);
      })
      .catch(function () {
        // Static HTML fallback inside #leaderboard-root stays visible on error.
      });
  }

  return {
    findCategoryAndSuite: findCategoryAndSuite,
    filterRows: filterRows,
    sortRows: sortRows,
    computeBarPercent: computeBarPercent,
    availableFilters: availableFilters,
    toMarkdownTable: toMarkdownTable,
    renderScatterSvg: renderScatterSvg,
    initUI: initUI,
    boot: boot,
  };
});
