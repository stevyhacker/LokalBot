/* LokalBot landing page interactions. Vanilla, no dependencies. */
(function () {
  "use strict";

  var reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  var $ = function (sel, ctx) { return (ctx || document).querySelector(sel); };
  var $$ = function (sel, ctx) { return Array.prototype.slice.call((ctx || document).querySelectorAll(sel)); };

  /* ---------- scroll reveal (IntersectionObserver, no scroll listeners) ---------- */
  var reveals = $$(".reveal");
  if (reduce || !("IntersectionObserver" in window)) {
    reveals.forEach(function (el) { el.classList.add("in"); });
  } else {
    var io = new IntersectionObserver(function (entries) {
      entries.forEach(function (e) {
        if (e.isIntersecting) { e.target.classList.add("in"); io.unobserve(e.target); }
      });
    }, { threshold: 0.15, rootMargin: "0px 0px -7% 0px" });
    reveals.forEach(function (el) { io.observe(el); });
  }

  /* ---------- hero demo video: never autoplay; pause if the user scrolls away ---------- */
  var heroDemo = $(".hero__demo");
  if (heroDemo && "IntersectionObserver" in window) {
    var heroIO = new IntersectionObserver(function (entries) {
      entries.forEach(function (e) {
        if (!e.isIntersecting) { heroDemo.pause(); }
      });
    }, { threshold: 0.05 });
    heroIO.observe(heroDemo);
  }

  /* ---------- full-size screenshot links open the appearance on screen ---------- */
  $$(".home-image-link").forEach(function (link) {
    var source = $("source[media]", link);
    var img = $("img", link);
    if (!source || !img || !window.matchMedia) return;
    var mq = window.matchMedia(source.media);
    var sync = function () { link.href = mq.matches ? source.getAttribute("srcset") : img.getAttribute("src"); };
    sync();
    if (mq.addEventListener) { mq.addEventListener("change", sync); } else if (mq.addListener) { mq.addListener(sync); }
  });

  /* ---------- waveform: randomize bar timing for an organic pulse ---------- */
  if (!reduce) {
    $$("[data-wave] span").forEach(function (bar) {
      var dur = 560 + Math.random() * 720;
      bar.style.animationDuration = dur.toFixed(0) + "ms";
      bar.style.animationDelay = (-Math.random() * dur).toFixed(0) + "ms";
    });
  }

  /* ---------- cotyping demo: ghost text + Tab to accept ---------- */
  var input = $("#ctInput");
  var typedEl = $("#ctTyped");
  var ghostEl = $("#ctGhost");
  var field = $("#cotypeField");
  var cotype = field ? field.closest(".cotype") : null;

  if (input && typedEl && ghostEl && field) {
    var SNIPPETS = [
      "Following up on our sync, the on-device build is ready to ship.",
      "Thanks for the call. I'll send the recap and action items shortly.",
      "Action item: ship the on-device summary by Friday.",
      "Let's circle back on this once the transcript lands."
    ];
    var dismissed = false;

    function ghostFor(val) {
      if (!val || dismissed) return "";
      var v = val.toLowerCase();
      for (var i = 0; i < SNIPPETS.length; i++) {
        if (SNIPPETS[i].toLowerCase().indexOf(v) === 0) return SNIPPETS[i].slice(val.length);
      }
      return "";
    }
    function render() {
      typedEl.textContent = input.value;
      ghostEl.textContent = ghostFor(input.value);
    }
    function acceptWord() {
      var g = ghostFor(input.value);
      if (!g) return false;
      var m = g.match(/^\s*\S+/);
      input.value += m ? m[0] : g;
      render();
      return true;
    }

    /* seed with the static teaser so the field is meaningful before any motion */
    input.value = (typedEl.textContent || "").trim() === "" ? "" : typedEl.textContent;
    render();

    field.addEventListener("mousedown", function (e) {
      e.preventDefault();
      input.focus();
      var L = input.value.length;
      try { input.setSelectionRange(L, L); } catch (_) {}
    });
    input.addEventListener("focus", function () { if (cotype) cotype.classList.add("is-focused"); });
    input.addEventListener("blur", function () { if (cotype) cotype.classList.remove("is-focused"); });
    input.addEventListener("input", function () { dismissed = false; render(); });
    input.addEventListener("keydown", function (e) {
      if (e.key === "Tab" && ghostFor(input.value)) {
        e.preventDefault();
        acceptWord();
      } else if (e.key === "Escape") {
        dismissed = true;
        render();
      }
    });
  }
})();
