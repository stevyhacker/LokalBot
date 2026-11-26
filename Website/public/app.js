(function () {
  "use strict";

  document.documentElement.classList.add("js");

  var reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  var saveData = !!(navigator.connection && navigator.connection.saveData);
  var $ = function (sel, ctx) { return (ctx || document).querySelector(sel); };
  var $$ = function (sel, ctx) { return Array.prototype.slice.call((ctx || document).querySelectorAll(sel)); };

  var afterLoadIdle = function (fn) {
    var schedule = function () {
      if (typeof window.requestIdleCallback === "function") {
        window.requestIdleCallback(fn, { timeout: 1500 });
      } else {
        setTimeout(fn, 250);
      }
    };
    if (document.readyState === "complete") {
      schedule();
    } else {
      window.addEventListener("load", schedule, { once: true });
    }
  };

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

  var reveals = $$(".reveal");
  if (reduce || !("IntersectionObserver" in window)) {
    reveals.forEach(function (el) { el.classList.add("in"); });
  } else {
    var io = new IntersectionObserver(function (entries) {
      entries.forEach(function (e) {
        if (e.isIntersecting) { e.target.classList.add("in"); io.unobserve(e.target); }
      });
    }, { threshold: 0.15, rootMargin: "0px 0px -7% 0px" });
    reveals.forEach(function (el) {
      var rect = el.getBoundingClientRect();
      if (rect.top < window.innerHeight && rect.bottom > 0) {
        el.classList.add("in");
      } else {
        io.observe(el);
      }
    });
  }

  var loops = $$(".home-loop");
  if (window.matchMedia("(prefers-color-scheme: dark)").matches) {
    loops.forEach(function (video) {
      var name = video.getAttribute("data-clip");
      if (!name) return;
      video.setAttribute("poster", "assets/demos/" + name + "-wide-dark.webp");
      video.setAttribute("src", "assets/demos/" + name + "-wide-dark.mp4");
    });
  }
  if (loops.length && !reduce && !saveData && "IntersectionObserver" in window) {
    afterLoadIdle(function () {
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
    });
  }

  var demoStage = $("[data-demo-stage]");
  if (demoStage) {
    var demoTabs = $$(".demo-tab", demoStage);
    var demoNotes = $$("[data-demo-note]", demoStage);
    var demoFrame = $(".demo-frame", demoStage);
    var demoTabList = $(".demo-tabs", demoStage);
    var demoToggle = $(".demo-toggle", demoStage);
    var demoVideo = $("video", demoFrame);
    var demoModeButtons = $$("[data-demo-mode]", demoStage);
    var videoPanel = $('[data-demo-panel="video"]', demoStage);
    var sandboxPanel = $('[data-demo-panel="sandbox"]', demoStage);
    var demoPhone = window.matchMedia("(max-width: 640px)");
    var demoDark = window.matchMedia("(prefers-color-scheme: dark)");
    var demoAuto = !reduce && !saveData;
    var demoStarts = demoTabs.map(function (tab) { return parseFloat(tab.getAttribute("data-start")) || 0; });
    var demoIndex = -1;
    var demoHeld = false;
    var demoOnScreen = true;
    var demoTicking = false;
    var demoVideoStarted = false;
    var demoMode = "video";

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
      var tab = demoTabs[index];
      if (demoTabList.scrollWidth > demoTabList.clientWidth) {
        demoTabList.scrollTo({ left: tab.offsetLeft - (demoTabList.clientWidth - tab.offsetWidth) / 2, behavior: reduce ? "auto" : "smooth" });
      }
    };
    var demoLoad = function (time) {
      var src = demoFile("full", ".mp4");
      var changed = demoVideo.getAttribute("src") !== src;
      if (changed) {
        demoVideo.setAttribute("src", src);
        demoVideo.load();
      }
      if (time) {
        if (changed || demoVideo.readyState < 1) {
          demoVideo.addEventListener("loadedmetadata", function seekOnLoad() {
            demoVideo.removeEventListener("loadedmetadata", seekOnLoad);
            demoVideo.currentTime = time;
          });
        } else {
          demoVideo.currentTime = time;
        }
      }
    };
    var demoRecut;
    var demoResume = function () {};
    var startAutoVideo = function () {};

    if (!demoAuto) {
      var demoStill = function (index, loadMedia) {
        demoMark(index);
        demoVideo.setAttribute("poster", demoFile(demoTabs[index].getAttribute("data-demo"), ".webp"));
        if (loadMedia) {
          demoLoad(demoStarts[index]);
        } else if (demoVideo.getAttribute("src") !== demoFile("full", ".mp4")) {
          demoVideo.setAttribute("src", demoFile("full", ".mp4"));
        }
      };
      demoTabs.forEach(function (tab, index) {
        tab.addEventListener("click", function () { demoStill(index, !saveData); });
      });
      demoVideo.addEventListener("timeupdate", function () { demoMark(demoChapter(demoVideo.currentTime)); });
      demoStill(0, false);
      demoRecut = function () { demoStill(demoIndex, false); };
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
      demoResume = function () {
        if (demoMode !== "video" || demoHeld || !demoOnScreen || document.hidden || !demoVideoStarted) { return; }
        var p = demoVideo.play();
        if (p && p.catch) {
          p.catch(function (error) {
            if (error && error.name === "NotAllowedError") { demoHeld = true; demoShowHeld(); }
          });
        }
      };
      startAutoVideo = function (startIndex) {
        if (!demoVideoStarted) {
          demoVideoStarted = true;
          demoVideo.removeAttribute("poster");
          demoVideo.removeAttribute("controls");
          demoVideo.muted = true;
          demoVideo.loop = true;
          demoVideo.setAttribute("preload", "auto");
          demoFrame.classList.add("is-animated");
          demoToggle.hidden = false;
          demoLoad(demoStarts[startIndex || 0]);
        } else if (typeof startIndex === "number") {
          demoVideo.currentTime = demoStarts[startIndex];
        }
        demoMark(startIndex || 0);
        demoResume();
      };

      demoVideo.addEventListener("playing", function () {
        demoFrame.classList.add("is-playing");
        if (!demoTicking) { demoTicking = true; requestAnimationFrame(demoTick); }
      });
      demoVideo.addEventListener("pause", function () { demoTicking = false; });

      var demoToggleHold = function () {
        if (!demoVideoStarted) { startAutoVideo(0); return; }
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
          startAutoVideo(index);
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
      afterLoadIdle(function () {
        if (demoMode === "video" && !demoVideoStarted) {
          startAutoVideo(0);
        }
      });
      demoRecut = function () {
        if (!demoVideoStarted) return;
        var time = demoVideo.currentTime;
        demoLoad(0);
        demoVideo.addEventListener("loadedmetadata", function restore() {
          demoVideo.removeEventListener("loadedmetadata", restore);
          demoVideo.currentTime = time;
        });
        demoResume();
      };
    }

    [demoPhone, demoDark].forEach(function (query) {
      if (query.addEventListener) { query.addEventListener("change", demoRecut); } else if (query.addListener) { query.addListener(demoRecut); }
    });

    var sandboxLoaded = false;
    var sandboxAudio = null;
    var initSandbox = function () {
      if (sandboxLoaded || !sandboxPanel) return;
      sandboxLoaded = true;
      var statusEl = $("[data-sandbox-status]", sandboxPanel);
      var subTabs = $$("[data-sandbox-tab]", sandboxPanel);
      var subViews = $$("[data-sandbox-view]", sandboxPanel);
      var setSubView = function (name) {
        subTabs.forEach(function (btn) {
          var active = btn.getAttribute("data-sandbox-tab") === name;
          btn.classList.toggle("is-active", active);
          btn.setAttribute("aria-selected", active ? "true" : "false");
        });
        subViews.forEach(function (view) {
          view.hidden = view.getAttribute("data-sandbox-view") !== name;
        });
      };
      subTabs.forEach(function (btn) {
        btn.addEventListener("click", function () { setSubView(btn.getAttribute("data-sandbox-tab")); });
      });

      fetch("assets/demo-sandbox/sandbox-data.json")
        .then(function (r) { if (!r.ok) throw new Error("load"); return r.json(); })
        .then(function (data) {
          var meeting = data.meeting;
          var audioEl = $("[data-sandbox-audio]", sandboxPanel);
          sandboxAudio = audioEl;
          var titleEl = $("[data-sandbox-title]", sandboxPanel);
          var metaEl = $("[data-sandbox-meta]", sandboxPanel);
          var recapEl = $("[data-sandbox-recap]", sandboxPanel);
          var decisionsEl = $("[data-sandbox-decisions]", sandboxPanel);
          var actionsEl = $("[data-sandbox-actions]", sandboxPanel);
          var openEl = $("[data-sandbox-open]", sandboxPanel);
          var turnsEl = $("[data-sandbox-turns]", sandboxPanel);
          var audioStatusEl = $("[data-sandbox-audio-status]", sandboxPanel);
          var turnButtons = {};

          if (titleEl) titleEl.textContent = meeting.title;
          if (metaEl) metaEl.textContent = meeting.meta;
          if (recapEl) recapEl.textContent = meeting.recap;
          if (audioEl) {
            audioEl.setAttribute("src", meeting.audioUrl);
          }

          var markActiveTurn = function (turnId) {
            Object.keys(turnButtons).forEach(function (id) {
              turnButtons[id].classList.toggle("is-active", id === turnId);
            });
          };

          var jumpToAudio = function (seconds, turnId, labelText) {
            setSubView("meeting");
            if (turnId) {
              markActiveTurn(turnId);
              if (turnButtons[turnId] && turnButtons[turnId].scrollIntoView) {
                turnButtons[turnId].scrollIntoView({ block: "nearest", behavior: reduce ? "auto" : "smooth" });
              }
            }
            if (!audioEl) return;
            var seekAndPlay = function () {
              try { audioEl.currentTime = seconds; } catch (_) {}
              var p = audioEl.play();
              if (p && p.catch) p.catch(function () {});
            };
            if (audioEl.readyState >= 1) {
              seekAndPlay();
            } else {
              audioEl.addEventListener("loadedmetadata", function onMeta() {
                audioEl.removeEventListener("loadedmetadata", onMeta);
                seekAndPlay();
              });
              audioEl.load();
            }
            if (audioStatusEl && labelText) {
              audioStatusEl.textContent = "Jumped to " + labelText;
            }
          };

          if (audioEl) {
            audioEl.addEventListener("timeupdate", function () {
              var now = audioEl.currentTime;
              for (var i = 0; i < meeting.turns.length; i++) {
                var t = meeting.turns[i];
                if (now >= t.start && now <= t.end + 0.6) {
                  markActiveTurn(t.id);
                  break;
                }
              }
            });
          }

          var makeCiteBtn = function (timeLabel, start, turnId, ariaPrefix) {
            var btn = document.createElement("button");
            btn.type = "button";
            btn.className = "sandbox-cite";
            btn.textContent = timeLabel;
            btn.setAttribute("aria-label", ariaPrefix + " at " + timeLabel);
            btn.addEventListener("click", function () {
              jumpToAudio(start, turnId, timeLabel);
            });
            return btn;
          };

          if (decisionsEl) {
            decisionsEl.textContent = "";
            meeting.decisions.forEach(function (dec) {
              var li = document.createElement("li");
              li.className = "sandbox-note-item";
              li.appendChild(makeCiteBtn(dec.timeLabel, dec.start, dec.turnId, "Jump to decision"));
              var span = document.createElement("span");
              span.textContent = dec.text;
              li.appendChild(span);
              decisionsEl.appendChild(li);
            });
          }

          if (actionsEl) {
            actionsEl.textContent = "";
            meeting.actions.forEach(function (act) {
              var li = document.createElement("li");
              li.className = "sandbox-note-item";
              li.appendChild(makeCiteBtn(act.timeLabel, act.start, act.turnId, "Jump to action"));
              var span = document.createElement("span");
              var strong = document.createElement("strong");
              strong.textContent = act.owner + ": ";
              span.appendChild(strong);
              span.appendChild(document.createTextNode(act.text + " (" + act.due + ")"));
              li.appendChild(span);
              actionsEl.appendChild(li);
            });
          }

          if (openEl) {
            openEl.textContent = "";
            meeting.openQuestions.forEach(function (oq) {
              var li = document.createElement("li");
              li.className = "sandbox-note-item";
              li.appendChild(makeCiteBtn(oq.timeLabel, oq.start, oq.turnId, "Jump to open question"));
              var span = document.createElement("span");
              span.textContent = oq.text;
              li.appendChild(span);
              openEl.appendChild(li);
            });
          }

          if (turnsEl) {
            turnsEl.textContent = "";
            meeting.turns.forEach(function (turn) {
              var btn = document.createElement("button");
              btn.type = "button";
              btn.className = "sandbox-turn";
              btn.setAttribute("data-turn-id", turn.id);
              var meta = document.createElement("span");
              meta.className = "sandbox-turn__meta";
              meta.textContent = turn.timeLabel + " · " + turn.speaker;
              var body = document.createElement("span");
              body.className = "sandbox-turn__text";
              body.textContent = turn.text;
              btn.appendChild(meta);
              btn.appendChild(body);
              btn.addEventListener("click", function () {
                jumpToAudio(turn.start, turn.id, turn.timeLabel + " (" + turn.speaker + ")");
              });
              turnButtons[turn.id] = btn;
              turnsEl.appendChild(btn);
            });
          }

          var searchInput = $("[data-sandbox-search]", sandboxPanel);
          var searchResultsEl = $("[data-sandbox-results]", sandboxPanel);
          var searchFilterBtns = $$("[data-sandbox-filter]", sandboxPanel);
          var searchHintBtns = $$("[data-sandbox-query]", sandboxPanel);
          var activeFilter = "all";

          var renderSearch = function () {
            if (!searchResultsEl) return;
            var query = (searchInput ? searchInput.value : "").trim().toLowerCase();
            var terms = query ? query.split(/\s+/).filter(Boolean) : [];
            var matches = data.searchItems.filter(function (item) {
              if (activeFilter !== "all" && item.kind !== activeFilter) return false;
              if (!terms.length) return true;
              var hay = (item.title + " " + item.meta + " " + item.snippet).toLowerCase();
              return terms.every(function (t) { return hay.indexOf(t) !== -1; });
            });
            searchResultsEl.textContent = "";
            if (!matches.length) {
              var empty = document.createElement("p");
              empty.className = "sandbox-empty";
              empty.textContent = "No matching sample notes or screen moments. Try ETA, Northwind, Figma, or backfill.";
              searchResultsEl.appendChild(empty);
              return;
            }
            matches.slice(0, 8).forEach(function (item) {
              var card = document.createElement("div");
              card.className = "sandbox-result";
              var head = document.createElement("div");
              head.className = "sandbox-result__head";
              var badge = document.createElement("span");
              badge.className = "sandbox-kind sandbox-kind--" + item.kind;
              badge.textContent = item.kind === "screen" ? "Screen moment" : "Meeting";
              var title = document.createElement("strong");
              title.textContent = item.title;
              head.appendChild(badge);
              head.appendChild(title);
              if (typeof item.start === "number") {
                head.appendChild(makeCiteBtn("Play " + item.timeLabel, item.start, item.turnId, "Play match"));
              }
              var meta = document.createElement("p");
              meta.className = "sandbox-result__meta";
              meta.textContent = item.meta;
              var snippet = document.createElement("p");
              snippet.className = "sandbox-result__snippet";
              snippet.textContent = item.snippet;
              card.appendChild(head);
              card.appendChild(meta);
              card.appendChild(snippet);
              searchResultsEl.appendChild(card);
            });
          };

          if (searchInput) {
            searchInput.addEventListener("input", renderSearch);
          }
          searchFilterBtns.forEach(function (btn) {
            btn.addEventListener("click", function () {
              activeFilter = btn.getAttribute("data-sandbox-filter") || "all";
              searchFilterBtns.forEach(function (b) { b.classList.toggle("is-active", b === btn); });
              renderSearch();
            });
          });
          searchHintBtns.forEach(function (btn) {
            btn.addEventListener("click", function () {
              if (searchInput) {
                searchInput.value = btn.getAttribute("data-sandbox-query") || "";
                renderSearch();
                searchInput.focus();
              }
            });
          });
          renderSearch();

          var askPresetsEl = $("[data-sandbox-ask-presets]", sandboxPanel);
          var askForm = $("[data-sandbox-ask-form]", sandboxPanel);
          var askInput = $("[data-sandbox-ask-input]", sandboxPanel);
          var askAnswerEl = $("[data-sandbox-answer]", sandboxPanel);

          var showAskResult = function (questionText, answerText, citations, noteText) {
            if (!askAnswerEl) return;
            askAnswerEl.textContent = "";
            var qEl = document.createElement("p");
            qEl.className = "sandbox-answer__q";
            qEl.textContent = questionText;
            var aEl = document.createElement("p");
            aEl.className = "sandbox-answer__body";
            aEl.textContent = answerText;
            askAnswerEl.appendChild(qEl);
            askAnswerEl.appendChild(aEl);
            if (citations && citations.length) {
              var citesWrap = document.createElement("div");
              citesWrap.className = "sandbox-answer__cites";
              citations.forEach(function (cit, idx) {
                var row = document.createElement("div");
                row.className = "sandbox-answer__cite";
                var num = document.createElement("span");
                num.className = "sandbox-answer__num";
                num.textContent = "[" + (idx + 1) + "]";
                row.appendChild(num);
                if (typeof cit.start === "number") {
                  row.appendChild(makeCiteBtn(cit.label, cit.start, cit.turnId, "Play citation"));
                } else {
                  var labelSpan = document.createElement("span");
                  labelSpan.className = "sandbox-answer__src";
                  labelSpan.textContent = cit.label;
                  row.appendChild(labelSpan);
                }
                var quote = document.createElement("span");
                quote.className = "sandbox-answer__quote";
                quote.textContent = '"' + cit.quote + '"';
                row.appendChild(quote);
                citesWrap.appendChild(row);
              });
              askAnswerEl.appendChild(citesWrap);
            }
            if (noteText) {
              var note = document.createElement("p");
              note.className = "sandbox-answer__note";
              note.textContent = noteText;
              askAnswerEl.appendChild(note);
            }
          };

          var renderPreset = function (preset) {
            if (askPresetsEl) {
              $$(".sandbox-chip", askPresetsEl).forEach(function (b) {
                b.classList.toggle("is-active", b.getAttribute("data-preset-id") === preset.id);
              });
            }
            showAskResult(
              preset.question,
              preset.answer,
              preset.citations,
              "Precomputed cited answer on the sample library. In the desktop app, Qwen3.5 4B answers arbitrary questions locally."
            );
          };

          if (askPresetsEl) {
            askPresetsEl.textContent = "";
            data.askPresets.forEach(function (preset) {
              var btn = document.createElement("button");
              btn.type = "button";
              btn.className = "sandbox-chip";
              btn.setAttribute("data-preset-id", preset.id);
              btn.textContent = preset.question;
              btn.addEventListener("click", function () { renderPreset(preset); });
              askPresetsEl.appendChild(btn);
            });
          }

          if (askForm && askInput) {
            askForm.addEventListener("submit", function (e) {
              e.preventDefault();
              var raw = askInput.value.trim();
              if (!raw) return;
              var words = raw.toLowerCase().split(/\W+/).filter(function (w) { return w.length > 1; });
              var bestPreset = null;
              var bestScore = 0;
              data.askPresets.forEach(function (preset) {
                var score = 0;
                words.forEach(function (w) {
                  if (preset.keywords.indexOf(w) !== -1 || preset.question.toLowerCase().indexOf(w) !== -1) score += 2;
                  if (preset.answer.toLowerCase().indexOf(w) !== -1) score += 1;
                });
                if (score > bestScore) { bestScore = score; bestPreset = preset; }
              });
              if (bestPreset && bestScore >= 2) {
                renderPreset(bestPreset);
                return;
              }
              var matched = data.searchItems.filter(function (item) {
                var hay = (item.title + " " + item.snippet).toLowerCase();
                return words.some(function (w) { return hay.indexOf(w) !== -1; });
              }).slice(0, 3);
              if (matched.length) {
                showAskResult(
                  raw,
                  "Closest cited passages found in the sample library:",
                  matched.map(function (m) {
                    return {
                      label: m.timeLabel ? (m.timeLabel + " " + m.title) : m.title,
                      quote: m.snippet,
                      start: m.start,
                      turnId: m.turnId
                    };
                  }),
                  "Browser demo uses precomputed answers plus instant keyword matching. Install LokalBot for full on-device Ask."
                );
              } else {
                showAskResult(
                  raw,
                  "No matching lines in this sample library. Pick one of the cited questions above, or try terms like ETA, Northwind, latency, or backfill.",
                  [],
                  "Browser demo runs on the small sample fixture with zero network calls."
                );
              }
            });
          }

          if (data.askPresets.length) {
            renderPreset(data.askPresets[0]);
          }
          if (statusEl) statusEl.hidden = true;
        })
        .catch(function () {
          if (statusEl) {
            statusEl.hidden = false;
            statusEl.textContent = "Could not load sample demo data. Reload or watch the 43s tour instead.";
          }
        });
    };

    var setDemoMode = function (mode) {
      demoMode = mode;
      demoModeButtons.forEach(function (btn) {
        var active = btn.getAttribute("data-demo-mode") === mode;
        btn.classList.toggle("is-active", active);
        btn.setAttribute("aria-selected", active ? "true" : "false");
      });
      if (videoPanel) videoPanel.hidden = mode !== "video";
      if (sandboxPanel) sandboxPanel.hidden = mode !== "sandbox";
      if (mode === "sandbox") {
        demoVideo.pause();
        initSandbox();
      } else {
        if (sandboxAudio) sandboxAudio.pause();
        if (demoAuto) {
          if (!demoVideoStarted) { startAutoVideo(demoIndex >= 0 ? demoIndex : 0); } else { demoResume(); }
        }
      }
    };

    demoModeButtons.forEach(function (btn) {
      btn.addEventListener("click", function () {
        setDemoMode(btn.getAttribute("data-demo-mode"));
      });
    });

    demoStage.classList.add("is-ready");
  }

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

  var ua = navigator.userAgent || "";
  var handheld = /iPhone|iPad|iPod|Android/i.test(ua) ||
    (/Macintosh/.test(ua) && navigator.maxTouchPoints > 1) ||
    !!(navigator.userAgentData && navigator.userAgentData.mobile);
  var dmgLinks = $$('a[data-asset="mac"]:not([data-download-alt])');

  var RELEASE_PAGE = "https://github.com/stevyhacker/lokalbot/releases/latest";
  var RELEASE_API = "https://api.github.com/repos/stevyhacker/lokalbot/releases/latest";
  var ASSETS = {
    mac: { pattern: /^LokalBot-[0-9.]+-macos-arm64\.dmg$/, name: "macOS", icon: "ph-apple-logo" },
    windows: { pattern: /^LokalBot-[0-9.]+-windows-x86_64-setup\.exe$/, name: "Windows", icon: "ph-windows-logo" },
    linux: { pattern: /^LokalBot-[0-9.]+-linux-x86_64\.tar\.gz$/, name: "Linux", icon: "ph-linux-logo" },
    "linux-deb": { pattern: /^LokalBot-[0-9.]+-linux-amd64\.deb$/, name: "Linux (.deb)", icon: "ph-linux-logo" },
    "linux-rpm": { pattern: /^LokalBot-[0-9.]+-linux-x86_64\.rpm$/, name: "Linux (.rpm)", icon: "ph-linux-logo" }
  };

  var desktop = (function () {
    if (handheld) return "";
    var platform = (navigator.userAgentData && navigator.userAgentData.platform) || "";
    if (/CrOS|Chrome OS|Android/i.test(platform + " " + ua)) return "";
    if (/Win/i.test(platform) || /Windows NT/.test(ua)) return "windows";
    if (/Linux/i.test(platform) || /Linux|X11/.test(ua)) return "linux";
    return "";
  })();
  var linuxAsset = /Ubuntu|Debian|Mint|Pop!_OS/i.test(ua)
    ? "linux-deb"
    : (/Fedora|Red Hat|RHEL|CentOS|SUSE/i.test(ua) ? "linux-rpm" : "linux");

  if (desktop) {
    var primaryKey = desktop === "linux" ? linuxAsset : desktop;
    var target = ASSETS[primaryKey];
    $$("a[data-download]").forEach(function (link) {
      link.setAttribute("href", RELEASE_PAGE);
      link.setAttribute("data-asset", primaryKey);
      relabel(link, labelNode(link).nodeValue.replace(/(macOS|Mac)\s*$/, target.name), target.icon);
    });
    $$("[data-download-req]").forEach(function (el) {
      if (desktop === "linux" && el.hasAttribute("data-linux-packages")) {
        el.textContent = "";
        el.appendChild(document.createTextNode("Linux packages: "));
        var pkgs = [
          { asset: "linux-deb", href: "/dl/linux-deb", text: ".deb (Ubuntu/Debian)" },
          { asset: "linux-rpm", href: "/dl/linux-rpm", text: ".rpm (Fedora)" },
          { asset: "linux", href: "/dl/linux", text: ".tar.gz (./install.sh)" }
        ];
        pkgs.forEach(function (pkg, idx) {
          if (idx > 0) el.appendChild(document.createTextNode(" · "));
          var a = document.createElement("a");
          a.href = pkg.href;
          a.setAttribute("data-download-alt", "");
          a.setAttribute("data-asset", pkg.asset);
          a.textContent = pkg.text;
          el.appendChild(a);
        });
      } else {
        var text = el.getAttribute("data-req-" + desktop);
        if (text) el.textContent = text;
      }
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

  document.addEventListener("click", function (e) {
    var link = e.target.closest ? e.target.closest("a[data-asset]") : null;
    if (!link) return;
    if (handheld && dmgLinks.indexOf(link) !== -1) return;
    var os = link.getAttribute("data-asset");
    if (!ASSETS[os] || e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return;
    e.preventDefault();
    var timeout = new Promise(function (resolve) { setTimeout(function () { resolve(RELEASE_PAGE); }, 4000); });
    Promise.race([assetUrl(os), timeout]).then(function (url) { window.location.href = url; });
  });

  if (handheld && dmgLinks.length) {
    var SITE_URL = (window.location && window.location.origin && window.location.origin !== "null")
      ? (window.location.origin + window.location.pathname)
      : "https://www.lokalbot.com/";
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
      navigator.share({ title: document.title || "LokalBot", url: SITE_URL }).catch(function (err) {
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
      var isAndroid = /Android/i.test(ua);
      var isIOS = /iPhone|iPad|iPod/i.test(ua) || (/Macintosh/.test(ua) && navigator.maxTouchPoints > 1);
      var androidApp = $("[data-handoff-android]", hint);
      if (androidApp && isAndroid) androidApp.hidden = false;
      var iosApp = $("[data-handoff-ios]", hint);
      if (iosApp && isIOS) iosApp.hidden = false;
      hint.hidden = false;
    }
  }
  if (handheld) {
    $$("[data-desktop-only]").forEach(function (el) { el.hidden = true; });
  }

  $$("[data-copy-text]").forEach(function (button) {
    button.addEventListener("click", function () {
      var text = button.getAttribute("data-copy-text");
      var live = $("[data-copy-status]");
      var done = function (ok) {
        if (live) {
          live.textContent = "";
          live.textContent = ok ? "Command copied." : "Couldn't copy. Select the command and copy it instead.";
        }
        var glyph = $("i.ph", button);
        if (!ok || !glyph || button.dataset.copying) return;
        var before = glyph.className;
        button.dataset.copying = "1";
        glyph.className = "ph ph-check";
        setTimeout(function () { glyph.className = before; delete button.dataset.copying; }, 2000);
      };
      var fallback = function () {
        var ta = document.createElement("textarea");
        ta.value = text;
        ta.setAttribute("readonly", "");
        ta.style.position = "fixed";
        ta.style.opacity = "0";
        document.body.appendChild(ta);
        ta.select();
        ta.setSelectionRange(0, text.length);
        var ok = false;
        try { ok = document.execCommand("copy"); } catch (_) {}
        document.body.removeChild(ta);
        button.focus();
        done(ok);
      };
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(text).then(function () { done(true); }, fallback);
      } else {
        fallback();
      }
    });
  });

  $$("[data-play-demo]").forEach(function (link) {
    link.addEventListener("click", function () {
      var videoModeBtn = $('[data-demo-stage] [data-demo-mode="video"]');
      if (videoModeBtn) videoModeBtn.click();
      var first = $("[data-demo-stage] .demo-tab");
      if (first) first.click();
      var video = $("[data-demo-stage] video");
      if (video && video.hasAttribute("controls") && video.paused) {
        var p = video.play();
        if (p && p.catch) p.catch(function () {});
      }
    });
  });

  $$("[data-try-sandbox]").forEach(function (link) {
    link.addEventListener("click", function () {
      var sandboxBtn = $('[data-demo-stage] [data-demo-mode="sandbox"]');
      if (sandboxBtn) sandboxBtn.click();
    });
  });

  $$(".home-image-link").forEach(function (link) {
    var source = $("source[media]", link);
    var img = $("img", link);
    if (!source || !img || !window.matchMedia) return;
    var mq = window.matchMedia(source.media);
    var sync = function () { link.href = mq.matches ? source.getAttribute("srcset") : img.getAttribute("src"); };
    sync();
    if (mq.addEventListener) { mq.addEventListener("change", sync); } else if (mq.addListener) { mq.addListener(sync); }
  });

  var filterBox = $("[data-guide-filter]");
  var filterInput = filterBox ? $("input", filterBox) : null;
  if (filterInput) {
    var filterCards = $$(".guides-page .guide-card");
    var filterSections = $$("[data-guide-section]");
    var filterStatus = $("[data-guide-filter-status]");
    var filterEmpty = $("[data-guide-filter-empty]");
    var filterClear = $("[data-guide-filter-clear]");
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
    window.addEventListener("pageshow", function () { if (filterInput.value) applyFilter(); });
    filterBox.hidden = false;
  }
})();
