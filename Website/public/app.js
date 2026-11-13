/* LokalBot landing page interactions. Vanilla, no dependencies. */
(function () {
  "use strict";

  var reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  var $ = function (sel, ctx) { return (ctx || document).querySelector(sel); };
  var $$ = function (sel, ctx) { return Array.prototype.slice.call((ctx || document).querySelectorAll(sel)); };

  /* ---------- phones: the nav links collapse into a menu (CSS shows the button) ---------- */
  var navBar = $(".nav");
  var navLinks = navBar ? $(".nav__links", navBar) : null;
  var navActions = navBar ? $(".nav__actions", navBar) : null;
  if (navLinks && navActions) {
    var menu = document.createElement("nav");
    menu.id = "nav-menu";
    menu.className = "nav__menu";
    menu.setAttribute("aria-label", "Menu");
    menu.hidden = true;
    $$("a", navLinks).forEach(function (link) { menu.appendChild(link.cloneNode(true)); });

    var menuButton = document.createElement("button");
    menuButton.type = "button";
    menuButton.className = "icon-link nav__menu-button";
    menuButton.setAttribute("aria-label", "Menu");
    menuButton.setAttribute("aria-controls", menu.id);
    menuButton.setAttribute("aria-expanded", "false");
    menuButton.innerHTML = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" aria-hidden="true"><path d="M4 7h16M4 12h16M4 17h16"/></svg>';

    var setMenu = function (open) {
      menu.hidden = !open;
      menuButton.setAttribute("aria-expanded", open ? "true" : "false");
    };
    menuButton.addEventListener("click", function () { setMenu(menu.hidden); });
    menu.addEventListener("click", function (e) { if (e.target.closest("a")) setMenu(false); });
    document.addEventListener("click", function (e) {
      if (!menu.hidden && !menu.contains(e.target) && !menuButton.contains(e.target)) setMenu(false);
    });
    document.addEventListener("keydown", function (e) {
      if (e.key === "Escape" && !menu.hidden) { setMenu(false); menuButton.focus(); }
    });

    navActions.insertBefore(menuButton, navActions.firstChild);
    navBar.appendChild(menu);
  }

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

  /* ---------- silent loops: GIFs in all but file format, so no controls; stills under reduced motion or Save-Data ---------- */
  var loops = $$(".home-loop");
  /* a clip with both appearances follows the visitor's */
  if (window.matchMedia("(prefers-color-scheme: dark)").matches) {
    loops.forEach(function (video) {
      var name = video.getAttribute("data-clip");
      if (!name) return;
      video.setAttribute("poster", "assets/demos/" + name + "-wide-dark.webp");
      video.setAttribute("src", "assets/demos/" + name + "-wide-dark.mp4");
    });
  }
  var saveData = navigator.connection && navigator.connection.saveData;
  if (loops.length && !reduce && !saveData && "IntersectionObserver" in window) {
    var loopIO = new IntersectionObserver(function (entries) {
      entries.forEach(function (e) {
        if (e.isIntersecting) {
          var p = e.target.play();
          if (p && p.catch) p.catch(function () {});
        } else {
          e.target.pause();
        }
      });
    }, { threshold: 0.4 });
    loops.forEach(function (video) { loopIO.observe(video); });
  }

  /* ---------- home hero: one short film, and the tabs are its chapters ---------- */
  /* Loops muted while on screen. With reduced motion or Save-Data nothing starts by itself:
     the tabs choose where the film starts and the browser's own controls play it. */
  var demoStage = $("[data-demo-stage]");
  if (demoStage) {
    var demoTabs = $$(".demo-tab", demoStage);
    var demoNotes = $$("[data-demo-note]", demoStage);
    var demoFrame = $(".demo-frame", demoStage);
    var demoTabList = $(".demo-tabs", demoStage);
    var demoToggle = $(".demo-toggle", demoStage);
    var demoVideo = $("video", demoFrame);
    var demoPhone = window.matchMedia("(max-width: 640px)");
    var demoDark = window.matchMedia("(prefers-color-scheme: dark)");
    var demoAuto = !reduce && !(navigator.connection && navigator.connection.saveData);
    var demoStarts = demoTabs.map(function (tab) { return parseFloat(tab.getAttribute("data-start")) || 0; });
    var demoIndex = -1;
    var demoHeld = false;
    var demoOnScreen = true;
    var demoTicking = false;

    var demoFile = function (name, extension) {
      return "assets/demos/" + name + "-" + (demoPhone.matches ? "tall" : "wide") + "-" + (demoDark.matches ? "dark" : "light") + extension;
    };
    var demoChapter = function (time) {
      var index = 0;
      demoStarts.forEach(function (start, i) { if (time >= start) { index = i; } });
      return index;
    };
    var demoMark = function (index) {
      if (index === demoIndex) { return; }
      demoIndex = index;
      demoTabs.forEach(function (tab, i) {
        tab.classList.toggle("is-active", i === index);
        if (i === index) { tab.setAttribute("aria-current", "true"); } else { tab.removeAttribute("aria-current"); }
        tab.style.removeProperty("--demo-progress");
      });
      var name = demoTabs[index].getAttribute("data-demo");
      demoVideo.setAttribute("aria-label", demoTabs[index].getAttribute("data-label"));
      demoNotes.forEach(function (note) {
        note.classList.toggle("is-active", note.getAttribute("data-demo-note") === name);
      });
      /* keep the active tab in view when the row scrolls; never moves the page */
      var tab = demoTabs[index];
      if (demoTabList.scrollWidth > demoTabList.clientWidth) {
        demoTabList.scrollTo({ left: tab.offsetLeft - (demoTabList.clientWidth - tab.offsetWidth) / 2, behavior: reduce ? "auto" : "smooth" });
      }
    };
    /* a new file for the viewer's width and appearance, from the same point in the film */
    var demoLoad = function (time) {
      var src = demoFile("full", ".mp4");
      if (demoVideo.getAttribute("src") !== src) {
        demoVideo.setAttribute("src", src);
        demoVideo.load();
      }
      if (time) { demoVideo.currentTime = time; }
    };
    var demoRecut;

    if (!demoAuto) {
      var demoStill = function (index) {
        demoMark(index);
        demoVideo.setAttribute("poster", demoFile(demoTabs[index].getAttribute("data-demo"), ".webp"));
        demoLoad(demoStarts[index]);
      };
      demoTabs.forEach(function (tab, index) {
        tab.addEventListener("click", function () { demoStill(index); });
      });
      demoVideo.addEventListener("timeupdate", function () { demoMark(demoChapter(demoVideo.currentTime)); });
      demoStill(0);
      demoRecut = function () { demoStill(demoIndex); };
    } else {
      var demoTick = function () {
        var time = demoVideo.currentTime;
        var index = demoChapter(time);
        var end = index + 1 < demoStarts.length ? demoStarts[index + 1] : demoVideo.duration;
        demoMark(index);
        if (end > demoStarts[index]) {
          demoTabs[index].style.setProperty("--demo-progress", ((time - demoStarts[index]) / (end - demoStarts[index])).toFixed(3));
        }
        if (demoTicking) { requestAnimationFrame(demoTick); }
      };
      var demoShowHeld = function () {
        var glyph = $("i.ph", demoToggle);
        demoFrame.classList.toggle("is-held", demoHeld);
        demoToggle.setAttribute("aria-label", demoHeld ? "Play the demo" : "Pause the demo");
        if (glyph) { glyph.className = "ph " + (demoHeld ? "ph-play" : "ph-pause"); }
      };
      var demoResume = function () {
        if (demoHeld || !demoOnScreen || document.hidden) { return; }
        var p = demoVideo.play();
        if (p && p.catch) {
          /* Low Power Mode and some browsers refuse: leave the still up with a play button */
          p.catch(function (error) {
            if (error && error.name === "NotAllowedError") { demoHeld = true; demoShowHeld(); }
          });
        }
      };

      demoVideo.removeAttribute("poster");
      demoVideo.removeAttribute("controls");
      demoVideo.muted = true;
      demoVideo.loop = true;
      demoVideo.setAttribute("preload", "auto");
      demoVideo.addEventListener("playing", function () {
        demoFrame.classList.add("is-playing");
        if (!demoTicking) { demoTicking = true; requestAnimationFrame(demoTick); }
      });
      demoVideo.addEventListener("pause", function () { demoTicking = false; });

      demoFrame.classList.add("is-animated");
      demoToggle.hidden = false;
      var demoToggleHold = function () {
        demoHeld = !demoHeld;
        demoShowHeld();
        if (demoHeld) { demoVideo.pause(); } else { demoResume(); }
      };
      demoToggle.addEventListener("click", function (e) { e.stopPropagation(); demoToggleHold(); });
      demoFrame.addEventListener("click", demoToggleHold);
      demoTabs.forEach(function (tab, index) {
        tab.addEventListener("click", function () {
          demoHeld = false;
          demoShowHeld();
          demoVideo.currentTime = demoStarts[index];
          demoMark(index);
          demoResume();
        });
      });

      if ("IntersectionObserver" in window) {
        new IntersectionObserver(function (entries) {
          demoOnScreen = entries[0].isIntersecting;
          if (demoOnScreen) { demoResume(); } else { demoVideo.pause(); }
        }, { threshold: 0.25 }).observe(demoFrame);
      }
      document.addEventListener("visibilitychange", function () {
        if (document.hidden) { demoVideo.pause(); } else { demoResume(); }
      });

      demoMark(0);
      demoLoad(0);
      demoResume();
      demoRecut = function () {
        var time = demoVideo.currentTime;
        demoLoad(0);
        demoVideo.addEventListener("loadedmetadata", function restore() {
          demoVideo.removeEventListener("loadedmetadata", restore);
          demoVideo.currentTime = time;
        });
        demoResume();
      };
    }

    /* a different appearance or a phone rotated past the breakpoint needs its own cut */
    [demoPhone, demoDark].forEach(function (query) {
      if (query.addEventListener) { query.addEventListener("change", demoRecut); } else if (query.addListener) { query.addListener(demoRecut); }
    });
    demoStage.classList.add("is-ready");
  }

  /* the visible label is the last non-empty text node; icons stay put */
  var labelNode = function (el) {
    var last = null;
    for (var i = 0; i < el.childNodes.length; i++) {
      var n = el.childNodes[i];
      if (n.nodeType === 3 && n.nodeValue.trim()) last = n;
    }
    if (!last) { last = document.createTextNode(""); el.appendChild(last); }
    return last;
  };
  var relabel = function (el, text, icon) {
    labelNode(el).nodeValue = text;
    var glyph = $("i.ph", el);
    if (glyph && icon) glyph.className = "ph " + icon;
  };

  /* ---------- phones and tablets: an installer is no use here, so hand the link to a computer ---------- */
  var ua = navigator.userAgent || "";
  var handheld = /iPhone|iPad|iPod|Android/i.test(ua) ||
    (/Macintosh/.test(ua) && navigator.maxTouchPoints > 1) ||
    !!(navigator.userAgentData && navigator.userAgentData.mobile);
  var dmgLinks = $$('a[data-asset="mac"]:not([data-download-alt])');

  /* ---------- downloads: each file carries the version in its name ---------- */
  /* (LokalBot-0.11.2-macos-arm64.dmg, LokalBot-0.11.2-windows-x86_64-setup.exe), so a link
     points at the latest release and a click looks up the current file. */
  var RELEASE_PAGE = "https://github.com/stevyhacker/lokalbot/releases/latest";
  var RELEASE_API = "https://api.github.com/repos/stevyhacker/lokalbot/releases/latest";
  var ASSETS = {
    mac: { pattern: /^LokalBot-[0-9.]+-macos-arm64\.dmg$/, name: "macOS", icon: "ph-apple-logo" },
    windows: { pattern: /^LokalBot-[0-9.]+-windows-x86_64-setup\.exe$/, name: "Windows", icon: "ph-windows-logo" },
    linux: { pattern: /^LokalBot-[0-9.]+-linux-x86_64\.tar\.gz$/, name: "Linux", icon: "ph-linux-logo" }
  };

  /* ---------- Windows and Linux desktops: offer their own download ---------- */
  var desktop = (function () {
    if (handheld) return "";
    var platform = (navigator.userAgentData && navigator.userAgentData.platform) || "";
    if (/CrOS|Chrome OS|Android/i.test(platform + " " + ua)) return "";
    if (/Win/i.test(platform) || /Windows NT/.test(ua)) return "windows";
    if (/Linux/i.test(platform) || /Linux|X11/.test(ua)) return "linux";
    return "";
  })();
  if (desktop) {
    var target = ASSETS[desktop];
    $$("a[data-download]").forEach(function (link) {
      link.setAttribute("href", RELEASE_PAGE);
      link.setAttribute("data-asset", desktop);
      relabel(link, labelNode(link).nodeValue.replace(/(macOS|Mac)\s*$/, target.name), target.icon);
    });
    $$("[data-download-req]").forEach(function (el) {
      var text = el.getAttribute("data-req-" + desktop);
      if (text) el.textContent = text;
    });
  }
  var latestRelease = null;
  var assetUrl = function (os) {
    if (!latestRelease) {
      latestRelease = fetch(RELEASE_API, { headers: { Accept: "application/vnd.github+json" } })
        .then(function (response) { return response.ok ? response.json() : null; })
        .catch(function () { return null; });
    }
    return latestRelease.then(function (release) {
      var assets = (release && release.assets) || [];
      for (var i = 0; i < assets.length; i++) {
        if (ASSETS[os].pattern.test(assets[i].name)) return assets[i].browser_download_url;
      }
      return RELEASE_PAGE;
    });
  };
  $$("a[data-asset]").forEach(function (link) {
    // On a phone the Mac buttons send the site to a computer instead (below).
    if (handheld && dmgLinks.indexOf(link) !== -1) return;
    link.addEventListener("click", function (e) {
      var os = link.getAttribute("data-asset");
      if (!ASSETS[os] || e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return;
      e.preventDefault();
      var timeout = new Promise(function (resolve) { setTimeout(function () { resolve(RELEASE_PAGE); }, 4000); });
      Promise.race([assetUrl(os), timeout]).then(function (url) { window.location.href = url; });
    });
  });

  if (handheld && dmgLinks.length) {
    var SITE_URL = "https://www.lokalbot.com/";
    var canShare = typeof navigator.share === "function";
    var status = $("[data-copy-status]");
    if (!status) {
      status = document.createElement("p");
      status.className = "visually-hidden";
      status.setAttribute("role", "status");
      document.body.appendChild(status);
    }


    var legacyCopy = function () {
      var ta = document.createElement("textarea");
      ta.value = SITE_URL;
      ta.setAttribute("readonly", "");
      ta.style.position = "fixed";
      ta.style.opacity = "0";
      document.body.appendChild(ta);
      ta.select();
      ta.setSelectionRange(0, SITE_URL.length);
      var ok = false;
      try { ok = document.execCommand("copy"); } catch (_) {}
      document.body.removeChild(ta);
      return ok;
    };
    var flash = function (el, ok) {
      if (!ok) {
        window.prompt("Copy this link and open it on your computer:", SITE_URL);
        return;
      }
      status.textContent = "";
      status.textContent = "Link copied. Open it on your computer to download LokalBot.";
      if (el.dataset.copying) return;
      var node = labelNode(el);
      var glyph = $("i.ph", el);
      var before = { text: node.nodeValue, icon: glyph ? glyph.className : "" };
      el.dataset.copying = "1";
      node.nodeValue = el.classList.contains("text-button") ? "link copied" : "Link copied";
      if (glyph) glyph.className = "ph ph-check";
      setTimeout(function () {
        node.nodeValue = before.text;
        if (glyph) glyph.className = before.icon;
        delete el.dataset.copying;
      }, 2200);
    };
    var copyLink = function (el) {
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(SITE_URL).then(
          function () { flash(el, true); },
          function () { flash(el, legacyCopy()); }
        );
      } else {
        flash(el, legacyCopy());
      }
    };
    var sendToComputer = function (e) {
      e.preventDefault();
      var el = e.currentTarget;
      if (!canShare) { copyLink(el); return; }
      navigator.share({ title: "LokalBot", url: SITE_URL }).catch(function (err) {
        if (!err || err.name !== "AbortError") copyLink(el);
      });
    };

    dmgLinks.forEach(function (link) {
      relabel(link, canShare ? "Send to my computer" : "Copy link", canShare ? "ph-share" : "ph-copy");
      link.setAttribute("href", SITE_URL);
      link.setAttribute("role", "button");
      link.removeAttribute("download");
      link.addEventListener("click", sendToComputer);
      link.addEventListener("keydown", function (e) {
        if (e.key === " ") sendToComputer(e);
      });
    });
    $$("[data-phone-label]").forEach(function (el) {
      relabel(el, el.getAttribute("data-phone-label"), el.getAttribute("data-phone-icon"));
    });
    $$("[data-copy-link]").forEach(function (button) {
      button.addEventListener("click", function () { copyLink(button); });
    });

    var hint = $("[data-handoff]");
    if (hint) {
      var shareCopy = $("[data-handoff-share]", hint);
      var plainCopy = $("[data-handoff-copy]", hint);
      var methods = $("[data-handoff-methods]", hint);
      if (!canShare && shareCopy && plainCopy) {
        shareCopy.hidden = true;
        plainCopy.hidden = false;
      } else if (/Android/i.test(ua) && methods) {
        methods.textContent = "email or a chat app";
      }
      var androidApp = $("[data-handoff-android]", hint);
      if (androidApp && /Android/i.test(ua)) androidApp.hidden = false;
      hint.hidden = false;
    }
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

  /* ---------- /guides: filter cards as you type; every word must match ---------- */
  var filterBox = $("[data-guide-filter]");
  var filterInput = filterBox ? $("input", filterBox) : null;
  if (filterInput) {
    var filterCards = $$(".guides-page .guide-card");
    var filterSections = $$("[data-guide-section]");
    var filterStatus = $("[data-guide-filter-status]");
    var filterEmpty = $("[data-guide-filter-empty]");
    var filterClear = $("[data-guide-filter-clear]");
    /* visible card text plus the page's FAQ questions */
    var haystacks = filterCards.map(function (card) {
      return (card.textContent + " " + (card.getAttribute("data-terms") || "")).toLowerCase();
    });
    var applyFilter = function () {
      var words = filterInput.value.toLowerCase().split(/\s+/).filter(Boolean);
      var shown = 0;
      filterCards.forEach(function (card, i) {
        var match = words.every(function (word) { return haystacks[i].indexOf(word) !== -1; });
        card.hidden = !match;
        if (match) shown++;
      });
      filterSections.forEach(function (section) {
        section.hidden = !$(".guide-card:not([hidden])", section);
      });
      if (filterEmpty) filterEmpty.hidden = shown > 0;
      if (filterStatus) {
        filterStatus.textContent = !words.length ? "" : shown === 1 ? "1 page matches." : shown + " pages match.";
      }
    };
    filterInput.addEventListener("input", applyFilter);
    if (filterClear) {
      filterClear.addEventListener("click", function () {
        filterInput.value = "";
        applyFilter();
        filterInput.focus();
      });
    }
    /* browsers can restore the typed text when you come back to the page */
    window.addEventListener("pageshow", function () { if (filterInput.value) applyFilter(); });
    filterBox.hidden = false;
  }
})();
