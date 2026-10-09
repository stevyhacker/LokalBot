# Cotyping Parity QA

This checklist keeps LokalBot's cotyping work aligned with the quality bar observed in Cotypist: a dedicated local model, prompt context, accepted-completion learning, streaming feedback, and measurable latency.

LokalBot defaults:

- LFM2.5 1.2B Instruct Q4_K_M is the benchmarked default cotyping model.
  Cotyping runs its own dedicated model in-process on Apple Silicon, with a
  separate `llama-server` as the conservative fallback — it never reuses the
  summarization model.
- Suggestion length defaults to 4 words, the length Cotypist usually shows.
- A suggestion is topped up while it is accepted or typed through: once two
  words are left, the next few are appended in place, so the ghost stays two to
  five words ahead and never runs out mid-sentence. It stops at the end of the
  sentence, and words already on screen never change
  (`CotypingSuggestionExtension`, `CotypingCoordinator+Extension`).
- Tab takes a word without its trailing punctuation, as in Cotypist; a full
  stop or comma is its own press. "Accept punctuation with the word" in
  Settings restores the attached behavior.
- Escape on a visible suggestion dismisses it, does not reach the app, and
  holds suggestions in that field for 10 seconds, as in Cotypist. The setting
  "Escape on a suggestion" can send the key through instead. A composing input
  method always receives its own Escape.
- Search fields (`AXSearchField`) stay quiet, as in Cotypist.
- Open and save dialogs stay quiet, as in Cotypist 2026.5
  (`CotypingFileDialogDetector`). AppKit names the panel's window
  `save-panel` or `open-panel` in every language; a sheet on the panel, such
  as Go to Folder, is checked through the window it hangs from. Sandboxed
  apps show the panel from another process, whose fields are never read.
- A suggestion left alone for a minute is taken down, so a Tab pressed long
  afterwards reaches the app. Every key either advances a suggestion or
  clears it, so the clock restarts on each one. Cotypist 2026.5 fixed the
  same bug.
- When macOS's own inline predictions are on ("Show inline predictive
  text", global default `NSAutomaticInlinePredictionEnabled`, unset means
  on), Settings → Writing → Autocomplete says two suggestions may compete and
  opens Keyboard settings, as Cotypist does.
- `LokalBot --event-taps` lists the keyboard and mouse hooks on the Mac by
  app. LokalBot holds at most three (autocomplete's key listener, its Tab tap
  while a suggestion shows, dictation's shortcut); an app holding five or
  more is flagged, the pattern Cotypist 2026.4 traced to leaking apps that
  slow every keystroke.
- Autocomplete stays quiet when the model is unsure, as Cotypist does
  (`CotypingFirstWordConfidence`). A suggestion at the start of a word is
  dropped when the model's own probability of its first word (the product of
  its tokens' probabilities, up to the token that ends the word) is below 0.1,
  and generation stops there. Suggestions inside a word are not gated: their
  first token is forced to re-type the fragment. Measured on 2026-10-06 (E2B,
  GitHub issue replies, Serbian tweets, the user's own agent prompts and
  messages): wrong suggestions shown halve (100–122 → 48–58 per 100 words) for
  1.4–2.0 points of keystrokes saved, the share of shown suggestions that are
  right goes from 15–27% to 24–43%, and the median request takes half as long
  because unsure ones stop after a token or two.
- The initial/server pause defaults to 160 ms. It controls the first local
  request and the model-server floor; after the first latency sample, the
  in-process route uses 20/25/55 ms adaptive tiers. The settings label states
  that distinction instead of implying a fixed local delay.
- A suggestion appears whole, as in Cotypist. There is no streaming of
  partial suggestions: each partial needed its own Accessibility re-read and
  made the ghost grow word by word.
- Suggestions appear instantly with no fade-in animation, and ghost text is
  always bare, matching Cotypist's understated inline presentation — the accept
  shortcut is configured (and discoverable) in Settings, never displayed beside
  the suggestion.
- Inline ghost text is drawn in the field's own font at its own size, starting
  exactly at the caret on the field's baseline (`CotypingInlineGhostLayout`,
  `CotypingGhostFontSizing`). Wrapped lines line up with the field's text edge.
  A re-read of the field that leaves out its font keeps the suggestion's font,
  so the ghost never changes size mid-line.
- The caret is the trailing edge of the character before it
  (`CotypingCaretGeometry`). TextEdit and Telegram on macOS 26 report the
  empty range at the caret one line above where it is drawn, which put the
  ghost on the line above the text; the character before the caret is reported
  on its own line. Measured live on 2026-10-04 by reading the ghost window's
  bounds, since the ghost itself is hidden from screen capture.
- The word the next accept keypress takes is drawn a little stronger than the
  rest of the suggestion, inline and in the popup.
- The ghost is never drawn over text (reported 2026-10-09 for LinkedIn in
  Chrome and for Viber). A key that leaves the suggestion takes it down at
  once; it used to stay until the app published the key, which in Chrome took
  long enough to sit over every new letter. A typed space moved the ghost by
  nothing, because the ghost draws runs of spaces as one, so letters typed
  after it landed on the ghost; typed text now moves it by its width as typed.
  Once the app publishes the caret, the ghost moves to it whenever it would
  cover typed text (it used to hold up to 6 pt of overlap).
- Wrapped ghost lines go only onto empty lines inside the field. A one-line
  chat box shows the words that fit after the caret, and Tab and the
  full-accept key take only what is shown. The rest of a word that does not
  fit after the caret is not drawn, since the app moves the whole word down.
- Chromium sometimes answers the caret query with the whole line's or field's
  box (a one-character message in the Claude app gave 788×23); such a box is
  not taken for the caret, and the text runs place it instead.
- Viber (Qt Quick) reports no caret at all, so its suggestions are placed from
  the field's text on screen, as in Chrome's text areas. Until that caret is
  found nothing is shown, rather than a popup above or below the field.

## Keystroke latency

Each keystroke reads the field once to see the host publish it, builds the
prompt from context cached per field, runs the model, and reads the field once
more before painting. Nothing else waits on the keystroke:

- The field's font, its document scope and the text above it are cached per
  focused field (`CotypingFieldContextCache`) and refreshed in the background.
  Walking the window for visible text takes tens of milliseconds.
- Saved-memory lookups read the library (about 47 ms with 101 meetings) and run
  in the background; a suggestion uses the newest finished lookup for its field
  (`CotypingMemoryLookup`). Lookups and learned-example ranking use finished
  words only, so a half-typed word never changes the prompt.
- A long draft's context window starts at a sentence or paragraph boundary
  (`CotypingPrefixWindow`), so the model reuses what it already read instead of
  reading about 450 tokens again per keystroke.
- Focusing a field reads it as the first keystroke will and prefills that
  prompt, so the first suggestion only adds what was typed.
- A memory-pressure warning leaves the model loaded while suggestions are being
  made; critical pressure, or a warning after a minute idle, frees it.

Model time per suggestion, measured with
`CotypingTypingLatencyBenchmarkTests` (Gemma 4 E2B Q6_K, Release, M4 Max):

| Typing | Before | After |
| --- | ---: | ---: |
| Short reply, no context | 60 ms | 61 ms |
| Short reply, context changing per word | 60 ms | 59 ms |
| End of a long draft | 257 ms | 60 ms |
| Saved-memory lookup on the keystroke | 47 ms | 0 ms |
- Completion token budget follows Cotypist/Cotabby's English baseline: `ceil(words * 1.3)`, floor 5, doubled for multi-line up to 120.
- The dedicated cotyping `llama-server` launches with a 2048-token context window, matching Cotypist/Cotabby's local llama runtime configuration.
- Focus polling uses a 200 ms active cadence, then stretches after
  sustained no-change captures so idle Accessibility reads back off without
  making post-keystroke suggestions feel delayed.
- Generation start and result apply reuse a focus snapshot only when the last
  Accessibility capture is at most 30 ms old; otherwise they re-read focus and
  drop stale decode output before painting, matching Cotabby's protection
  against focus switches during generation.
- Clipboard context matches Cotabby's relevance gate: the first pasteboard read
  is only a baseline, clipboard text must be freshly copied during the app
  session, it expires after five minutes, and it must share significant tokens
  with the current prompt prefix before it can condition a suggestion. Clipboard
  text is also sanitized before prompting: ANSI escapes, shell/Markdown-style
  separators, control characters, and punctuation-heavy noise are stripped, and
  long multi-line clips keep only lines overlapping the current prefix.
- Terminal gating matches Cotabby's default: standalone terminal apps are never
  assisted, and xterm.js integrated terminals are suppressed unless explicitly
  enabled in Settings.
- Spell-based guards (typo gate, seam guard, word-prefix validity) only apply
  when the caret context is confidently in a language macOS has a spell
  dictionary for. Text in Serbian, Croatian, Montenegrin, or any other
  unsupported language runs the continuation pipeline ungated
  (`CotypingSpellLanguageGate`) — otherwise every word would be flagged as a
  "typo" by whichever dictionary is active and cotyping would silently go dark
  for the whole language, while Cotypist keeps completing.
- Accept-key ownership is fail-closed around input methods and opaque editors.
  A composing or unknown input source, active marked text, a live selection, or
  a field without bounded native/marker range APIs passes the original key
  through and dismisses the ghost; cotyping never touches the pasteboard or
  walks a host menu from its consuming event tap. Direct-input fields use one
  synthetic Unicode event pair only after bounded live context, selection, and
  exact-field checks.
- Word-by-word acceptance follows Cotabby's space-less-script cadence: CJK,
  Japanese, Korean, Thai, and related runs are split with word segmentation
  instead of being accepted as one long whitespace-delimited token. Phrase
  acceptance stops at sentence/newline boundaries and CJK clause punctuation;
  ASCII commas stay inside the phrase.

## Mid-Word Word Completion (Cotypist parity)

Cotypist's signature behavior — "keep typing and it snaps to the word you
meant" — is a *required-prefix constrained decode* (its binary calls it
`requiredPrefix`/`remainingRequiredPrefix`). LokalBot reproduces it with three
cooperating layers:

- **Typo gate**: a word still being typed (no trailing space) that is a live
  prefix of a real word ("follo") is an unfinished word, not a typo — the gate
  returns `.proceed` so the LLM can complete it. Only fragments no dictionary
  word starts with ("recieve") get the inline correction / suppression
  (`CotypingTypoGate` + `CotypingSpellChecker.isCompletableWordPrefix`).
- **Token healing** (in-process runtime): the prompt is cut back to the last
  word boundary and the cut bytes (separator + fragment) become a decode
  constraint. Generation must re-produce them through naturally tokenized
  pieces — typically one boundary-merging token like " follow" against
  " follo" — then continues free. Only the text past the constraint is
  emitted, so the ghost extends the word (`CotypingTokenHealing`,
  `LlamaCotypingRuntime.generate(requiredPrefixUTF8:)`).
- **Normalizer guard**: on the HTTP fallback (no byte-level constraint), a
  whitespace-leading completion after a non-word fragment ("follo" + " up")
  is suppressed as `wordCompletionMismatch` rather than shown broken.

Note: Cotypist ships the *base* Gemma 4 E4B GGUF
(`gemma-4-E4B-UD-Q5_K_XL`). LokalBot now defaults to LFM2.5 1.2B Instruct and
keeps Gemma 4 E4B Instruct as its higher-capacity option. The 2026-07-21 model
matrix also tested Cotabby's E2B base and the E4B base; both missed LokalBot's
current safety/word-completion gate, so they were not added as defaults.

## Live comparison with Cotypist (2026-10-03)

Cotypist 2026.4 (Gemma 4 E4B base, default length, free tier) and LokalBot
(Gemma 4 E2B base) were each driven with real keystrokes in the same TextEdit
document, one app running at a time, on the prompts in
`Benchmarks/Cotyping/prompts.tsv`. Cotypist's ghost is visible to screen
capture; LokalBot's is not, so LokalBot was read through what the accept keys
inserted.

| Behavior | Cotypist | LokalBot before | LokalBot now |
| --- | --- | --- | --- |
| Words shown at first | 1–5, usually 4 | exactly 3 | up to 4 |
| While tabbing through | topped up at 2 words left, to about 5; ends with the sentence | ran out every 3 words, then a new suggestion | topped up at 2 words left |
| Typing the suggested letters | ghost shrinks, then is topped up | ghost shrinks | ghost shrinks, then is topped up |
| Tab on a word before punctuation | word only; punctuation is the next press | word and punctuation | word only |
| Escape | swallowed; field quiet for 9–13 s even while typing | reached the app; next key suggested again | swallowed; field quiet for 10 s |
| Search field (TextEdit Find) | no suggestion | suggested and inserted | no suggestion |
| Plain single-line field (TextEdit Replace) | suggests | suggests | suggests |
| Text after the caret on the line | no suggestion | no suggestion | no suggestion |
| "Hi" / "Hi team," in an empty document | no suggestion | "," / "I'm working" glued on without a space | suggestion, correctly spaced |
| Misspelled word ("recieve", "teh ") | no suggestion, no fix | offers the fix; continues after "teh " | unchanged |
| Keystroke to visible | ghost present 0.2–0.4 s after the last key | median about 0.14 s | unchanged |

Still different, deliberately or for lack of evidence:

- Cotypist stays quiet when its model is unsure (a two-word draft, a diverging
  letter). LokalBot always offers its best guess. Matching this needs the
  token probabilities, not a length rule.
- Cotypist offers no typo fix on the free tier and holds back after a
  misspelled word. LokalBot's inline fix is a feature and was left on.
- Cotypist's completions come from a larger model with screen context and
  personalization; content quality was not scored here.

## Automated Check

Run the in-app Cotyping tab's "Run cotyping check" action after selecting the
intended model, or headless:

```bash
"/Applications/LokalBot.app/Contents/MacOS/LokalBot" --cotyping-bench > bench.json
```

It exercises the 28 scenarios in `CotypingBenchmarkScenario.defaults`, in four
groups:

- Next-word continuations (email, chat, browser, scheduling, lists)
- **Word completions** — the caret ends on a fragment no dictionary word
  equals ("follo", "conversati", "Unterstüt"); the suggestion must begin with
  a word character and the expected tail (`expectedCompletionPrefixes`)
- Strictly-inside-word safety (text after the caret)
- Context/format robustness (questions, bullet lists, German, comma clauses)

Passing target:

- Normal scenarios return non-empty safe text.
- Word-completion scenarios extend the typed word (`wordCompletionPassed ==
  wordCompletionTotal` in the JSON/UI summary; 12/13 minimum observed on
  Gemma 4 E4B Q5 XL).
- Safety scenarios may suppress with an allowed reason.
- p95 latency is at or below 2000 ms.
- Expected-term hits are reviewed as a quality signal, not a hard pass/fail.

- **Generation runtime — DONE.** Cotyping now decodes the built-in GGUF model
  in-process via `libllama` (`b10173`), holding a persistent KV cache and
  re-prefilling only the typed suffix (`LocalLlamaCotypingEngine` →
  `LlamaCotypingRuntime`). The HTTP `llama-server` path remains as the fallback
  for non-GGUF backends, when the in-process runtime is toggled off
  (`cotypingInProcessRuntime`), or on load failure. A/B latency is measured by
  `CotypingBenchmarkRunner.runAB(local:http:...)` over the default scenarios
  (TTFT + p95 deltas).

## Manual Side-by-Side

The shared prompt set lives in `Benchmarks/Cotyping/prompts.tsv` — 25 prompts
across next-word, word-completion, valid-fragment, and typo groups, mirroring
the in-app benchmark scenarios. Both apps are driven by the same manifest, so
differences are pipeline differences, not prompt differences. Word-completion
prompts (`10-wc-*` … `20-wc-*`) are the Cotypist parity core: the accepted
insertion must begin with a word character that completes the typed fragment.

Record (per prompt, and overall):

- Time from pause to visible first suggestion.
- Whether the suggestion is grammatically valid.
- Whether it keeps the app/window topic.
- Whether accepting by word or phrase leaves correct spacing.
- Whether word-by-word acceptance in space-less scripts advances by a single
  word-sized segment, and phrase acceptance stops on CJK commas without stopping
  at ordinary English commas.
- Whether an accept key under a composing IME passes through without inserting
  the suggestion, reopening marked text, or swallowing the IME's candidate key.
- Whether switching to another field while generation is running prevents the
  old field's suggestion from appearing.
- Whether terminal apps and integrated terminals stay quiet by default.
- Whether old or unrelated clipboard contents do not steer suggestions when
  clipboard context is enabled.
- Whether copied terminal/Markdown output is cleaned into prose-like context
  instead of leaking symbols such as `$`, backticks, fences, or ANSI escapes
  into suggestions.
- Whether suggestions appear steadily, and streamed updates, word-by-word
  acceptance, and post-accept reanchors do not flicker.
- Whether ghost text stays bare — no keycap badge next to inline or popup
  suggestions.
- Whether suggestions keep flowing in a language without a macOS spell
  dictionary (Serbian/Montenegrin Latin is the reference case): mid-word
  fragments must complete, next-word continuations must appear after finished
  words, and no bogus wrong-language "corrections" are offered.
- Whether popup/mirror suggestions visually emphasize the next accept chunk
  rather than rendering the whole preview at the same strength.
- Whether it avoids code editors, terminals, secure fields, and excluded domains.

For the repeatable capture + merged report:

```bash
COTYPING_COMPARE_ACCEPT=1 Scripts/compare-cotyping.sh cotypist /tmp/cotyping-cotypist
COTYPING_COMPARE_ACCEPT=1 Scripts/compare-cotyping.sh lokalbot /tmp/cotyping-lokalbot
"/Applications/LokalBot.app/Contents/MacOS/LokalBot" --cotyping-bench > /tmp/bench.json
Benchmarks/Cotyping/side_by_side.py \
  --cotypist-dir /tmp/cotyping-cotypist --lokalbot-dir /tmp/cotyping-lokalbot \
  --engine-json /tmp/bench.json --output Benchmarks/Cotyping/results/<date>.md
```

The script opens TextEdit, clicks into the document, types each prompt as real
keystrokes, waits for the active cotyping app, and captures the TextEdit window
region as one PNG per prompt. It also writes `*.document.txt` with the TextEdit
document text after the wait. Set `COTYPING_COMPARE_ACCEPT=1` to press Tab after
the screenshot and write `*.accepted.txt`, which is the source of truth for
spacing/partial-accept behavior. It requires
Accessibility for the shell and Screen Recording for `screencapture`.
Set `COTYPING_COMPARE_FIRST_WAIT_SECONDS` or `COTYPING_COMPARE_WAIT_SECONDS` if
the selected model's first load or Metal compilation needs more time.

If the shell does not have Accessibility and fails with
`osascript is not allowed assistive access`, the fallback probe can capture a
lower-confidence signal without touching TextEdit documents:

```bash
swiftc Scripts/cotyping-probe.swift -o /tmp/cotyping-probe
/tmp/cotyping-probe --prompt "I wanted to follow" --slug 01-follow-up --output-dir /tmp/cotyping-probe-lokalbot --wait 12
```

The probe opens its own temporary AppKit text window, inserts text internally,
captures the full screen, and writes `*.document.txt`, `*.rect`, and `*.png`.
Use it only to inspect whether a target app responds to accessibility value
changes in a plain AppKit editor. It does not exercise System Events keystrokes
or Tab acceptance, and many cotyping apps deliberately ignore one-shot value
changes, so a no-suggestion probe is weak evidence rather than a product
failure.

For repeatable backend latency/output checks against a temporary dedicated
`llama-server`, pass the exact model file under test:

```bash
Benchmarks/Cotyping/run_llama_server_benchmark.py \
  --model LFM2.5-1.2B-Instruct-Q4_K_M.gguf \
  --surface-context --repetitions 3
```

This records first streamed chunk latency, final latency, stop reason and raw
model text for the same prompts. The script's no-argument model remains the
Cotabby Gemma base baseline for historical comparisons, so current-default runs
must pass `--model` explicitly. It is a backend microbenchmark, not a UI parity
test; use it to verify prompt/sampling/server changes before doing the
side-by-side screenshot pass.

## Local Learning Check

1. Enable "Learn from accepted completions".
2. Accept at least three email/chat continuations.
3. Re-run a similar prompt in the same app/window context.
4. Confirm the prompt uses learned examples only after acceptance and the learned example count increases.
5. Delete learned writing data from Settings and confirm the count returns to zero.

## Model Prep Check

Cotyping always runs its own dedicated model. Use "Prepare" on the recommended
cotyping model card in Cotyping, Models, or Settings to fetch it.

Expected behavior:

- LFM2.5 1.2B Instruct Q4_K_M is selected for fresh settings.
- The Hugging Face download starts if the model is missing (~0.73 GB), and the
  card links to the model's separate LFM Open License terms.
- Until the model is present, cotyping reports that it needs the download — there
  is no fallback to the bundled summarization model.
- Once downloaded, the status shows ready and cotyping uses the in-process
  runtime on Apple Silicon, with its dedicated server as the fallback.

LokalBot always downloads and manages its own copy of the model under its storage
folder. It does not reuse another app's model files.
