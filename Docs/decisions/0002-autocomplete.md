# 0002. Autocomplete

- Status: Accepted
- Date: 2026-11-20

## Context

Autocomplete (Cotyping in the Mac code) reads the text field the user types in, in any app, asks a model for a continuation and shows it as ghost text after the caret; the accept keys type the next word, phrase or the rest, and Esc dismisses it. The Mac app implements it in `LokalBot/Cotyping/`, with the model in process, on its own `llama-server` or on a server the user approves. The Windows and Linux app splits it across `lokalbot-ai` (prompt, decoding and servers), `lokalbot-engine` (requests and context), `lokalbot-platform` (reading fields, taking keys, typing and input methods) and `lokalbot-app` (the ghost and settings). These decisions were moved here from code comments when the code stopped carrying comments ([ADR 0001](0001-code-carries-no-comments.md)).

## Requests, prompt and decoding

### One request is in flight, and a late result must still fit the field

The desktop sends a `FieldContext` on every change: a text change asks for a suggestion after the debounce, and a caret move only drops the one on screen. One request is in flight at a time; a newer field read supersedes it, and a result that arrives late is shown only if the field still continues it. Typing a suggestion's next characters or accepting part of it keeps it, shortened, and may top it up with a few more words, but only a top-up that landed is followed up, so a refused one cannot loop. A newly focused field has its prompt read ahead so the first keystroke adds only what was typed, and a field read that arrives while the server is starting is answered once it is up, unless it was dismissed or answered meanwhile.

Where: `LinuxWindows/crates/lokalbot-engine/src/autocomplete.rs` (`Worker.on_top_up`).

### Cache entries are recorded under the request's own settings

The fingerprint is captured from the request in flight, not from settings read after the model returns, so a settings change during generation cannot bless stale output for reuse under the new configuration.

Where: `LokalBot/Cotyping/CotypingCoordinator.swift` (`CotypingCoordinator.activeSuggestionRequestFingerprint`).

### Debounce is short only for the in-process model

The wait after a keystroke is chosen from the last generation's latency. The in-process model can use Cotabby-style short tiers because cancelling stops local work directly; a model server keeps the conservative backoff, because dropping a request does not stop a prompt the server is reading.

Where: `LinuxWindows/crates/lokalbot-ai/src/autocomplete/debounce.rs`, `LokalBot/Cotyping/CotypingDebouncePolicy.swift` (`CotypingDebouncePolicy`).

### The model continues raw text, with the text before the caret last

Every model in the catalog is treated as a text continuer, not an instruction follower (ported from Cotabby's `BaseCompletionPromptRenderer`): no chat template and no control token besides the BOS llama-server adds. Persona, style and language go into a short conditioning preface, because in this mode a model conditions on a description and does not obey a command; the text before the caret is the last thing in the prompt, its whitespace intact. Instruction-tuned alternatives to the recommended base Gemma model also continue this prompt through raw `/v1/completions`, so the renderer returns the preface separately and the output boundary can suppress a partial or complete echo of it.

Where: `LinuxWindows/crates/lokalbot-ai/src/autocomplete/prompt.rs`, `LokalBot/Cotyping/CotypingPromptRenderer.swift` (`CotypingPromptRenderer`).

### The preface describes the writing topic, never the interface

Descriptions of the interface ("text being typed", "the window is titled") pull small models toward talking about buttons and fields instead of continuing the passage.

Where: `LinuxWindows/crates/lokalbot-ai/src/autocomplete/surface.rs` (`preface_lines`), `LokalBot/Cotyping/CotypingSurfaceContext.swift` (`CotypingSurfaceComposer.prefaceLines`).

### The prompt's start is kept stable so the model reuses what it has read

Window text has its own budget and comes first, since it changes least while typing. The text before the caret is bounded by characters and words without rewriting paragraph breaks, list indentation or the whitespace at the caret, which are prediction inputs. A window cut from longer text starts at a sentence, line or paragraph boundary near its front: a window that moved by one character per keystroke would make the model read the whole window again every time.

Where: `LinuxWindows/crates/lokalbot-ai/src/autocomplete/prompt.rs` (`render`), `LinuxWindows/crates/lokalbot-ai/src/autocomplete/window.rs` (`truncated_prefix`), `LokalBot/Cotyping/CotypingPrefixWindow.swift` (`CotypingPrefixWindow.truncatedPrefix`).

### llama-server gets one streamed raw `/completion` request with `cache_prompt`

Each suggestion is one `/completion` request with the raw prompt and `cache_prompt`, so the server reads only the newly typed tokens (macOS's `IncrementalPrefill`); it is streamed with each token's probabilities (`n_probs`) so the client applies what the in-process macOS decode loop applies: token healing, the first-word confidence gate, stopping when the most likely next token ends the text even if the sampler picked another, and stopping at a sentence end, a control token (`CotypingDecodeStopPolicy`) or a complete line unless multi-line suggestions are on. When the grammar's token-by-token path through a fragment ("to", "mo", "r…") is less likely than one token that spells it ("tomorrow"), the request restarts from that token, the case macOS's prefix search exists for; a reply that starts on a new line is kept and joined with a space, as the in-process output is. Stopping drops the connection, which llama-server notices at its next token and only after it finishes reading the prompt, so the caller keeps one request in flight.

Where: `LinuxWindows/crates/lokalbot-ai/src/autocomplete/client.rs`.

### Token healing makes generation re-type the word fragment at the caret

A prompt that ends mid-word ("…I wanted to follo") tokenizes unnaturally, and a small model often treats the fragment as a finished word and continues with " up …". Healing cuts the prompt back to the last word boundary and makes the cut text (" follo") a decode constraint: generation must re-produce those bytes through natural tokens (" fol" + "lo", or " follow" overshooting the caret) before it runs free, and the suggestion is what follows (Cotypist's "snaps to the word you meant", `requiredPrefix` in its binary); a trailing space is healed the same way, so " is" is one natural token instead of a lone space. Matching is by bytes, because a BPE piece can carry only part of a UTF-8 scalar (0xC3 of "ü"). macOS enforces the constraint in its llama.cpp decode loop (`LlamaCotypingRuntime`) and searches four tokenizations of the fragment for the most probable path; on llama-server it is a GBNF grammar on the request, `root ::= "<cut text>" any*`, whose sampler picks the best compatible token one step at a time.

Where: `LinuxWindows/crates/lokalbot-ai/src/autocomplete/healing.rs`, `LokalBot/Cotyping/Llama/CotypingTokenHealing.swift` (`CotypingTokenHealing`), `LokalBotTests/Cotyping/Llama/CotypingTokenHealingTests.swift` (`testMatchesAtByteLevelInsideMultiByteScalar`).

### The healing grammar writes every character as a code point escape

No prefix can then break out of the grammar's string literal.

Where: `LinuxWindows/crates/lokalbot-ai/src/autocomplete/healing.rs` (`grammar`).

### Plain HTTP servers heal by filtering the output

Over plain HTTP the prompt is sent cut back to the word boundary and only output that re-types the cut text counts; a server cannot be constrained to that prefix, so other output is suppressed. It is off for llama-server, whose prompt stays byte-for-byte.

Where: `LokalBot/Cotyping/CotypingEngine.swift` (`CotypingEngine.healsCaretBoundary`).

### Inside a word the suggestion must continue that word, enforced on the output

When the caret sits strictly inside a word (word characters on both sides), the suggestion continues it. Cotabby's `MidWordContinuationPolicy` masks the first sampled token so it has no leading whitespace; the HTTP route cannot mask a token mid-generation, so `CotypingTextNormalizer` reaches the same result on the output for both routes: never re-type the current partial word, and strictly inside never begin with whitespace or an incompatible word tail.

Where: `LokalBot/Cotyping/CotypingMidWord.swift` (`CotypingMidWord`).

### A suggestion needs a confident first word, with a one-word fallback

As Cotypist does, a suggestion at the start of a word is dropped when the model's probability of its first word (the product of the emitted tokens' probabilities up to the token in which the first word ends, softmax at temperature 1 whatever the sampler's settings) is below 0.1. Measured on real replies and the user's own prompts and messages (2026-10-06, E2B), this halves wrong suggestions for about 1.5 points of keystrokes saved, because a hidden suggestion usually comes back as a completion once the first letter is typed; suggestions inside a word are not gated, since their first token is forced to re-type the fragment. When the gate fails but the probability that the first word is complete (the mass of every token that starts a new word or ends the text) clears 0.31, the suggestion is cut to that word (the "selective one-word hybrid"); llama-server reports only the top candidates (`n_probs`), so there the mass is summed over them, which makes it a little stricter.

Where: `LinuxWindows/crates/lokalbot-ai/src/autocomplete/confidence.rs`, `LokalBot/Cotyping/Llama/CotypingFirstWordConfidence.swift` (`CotypingFirstWordConfidence`).

### `</s>` is not a stop marker

It also closes HTML `<s>`, so it is left out of the end-of-turn markers.

Where: `LinuxWindows/crates/lokalbot-ai/src/autocomplete/normalize.rs` (`STOP_MARKERS`), `LokalBot/Cotyping/CotypingTextNormalizer.swift` (`CotypingControlTokens.stopMarkers`).

### A chat reply that drops the space before a new word gets it back

Chat models often leave out the space before a new word: "at a" + "higher level" would show as "ahigher level", or not at all once the seam guard sees the misspelling. After a whole word, a reply that starts with a letter or digit gets the space back; inside a word, after a fragment the spell checker does not know ("follo"), when the reply restates the word at the caret, and in scripts written without spaces, the reply is left as it is.

Where: `LinuxWindows/crates/lokalbot-ai/src/autocomplete/server.rs` (`restoring_word_space`), `LokalBot/Cotyping/CotypingEngine.swift` (`CotypingEngine.restoringWordSpace`).

### A word still being typed that starts a real word is not a typo

A word with no trailing space that is a live prefix of a real word ("follo" for follow) is unfinished, and the continuation runs so it can complete it inline (Cotypist's core mid-word behaviour). Only a fragment no dictionary word starts with ("recieve") is a typo mid-word, and once the word has a trailing space completability no longer applies. The spell checks are injected (`CotypingSpellChecker` in production, stubs in tests) so the gate stays pure.

Where: `LokalBot/Cotyping/CotypingTypo.swift` (`CotypingTypoGate.resolve`).

### Spell verdicts stand down for a language with no dictionary

macOS ships dictionaries for a fixed set of languages, with none for Serbian, Croatian, Bosnian or Montenegrin. Text in such a language is flagged word by word by whichever dictionary is active, and the typo gate, the seam guard and the word-prefix validity signal would then suppress autocomplete for the whole language, so when the text at the caret is confidently in a language with no installed dictionary, spell verdicts stand down and the pipeline runs ungated. On Windows and Linux `whatlang` stands in for `NLLanguageRecognizer`, and its confidence is on its own scale.

Where: `LinuxWindows/crates/lokalbot-ai/src/autocomplete/typo.rs` (`spell_verdicts_apply`), `LokalBot/Cotyping/CotypingSpellLanguageGate.swift` (`CotypingSpellLanguageGate`), `LokalBotTests/Cotyping/CotypingSpellLanguageGateTests.swift` (`stockLanguages`).

### Only whole words are spell-checked

`NSSpellChecker` finds the misspelled word inside a token, so "wrld," or "foo-bar" is not flagged whole on the Mac; a checker asked about the whole token would call it a typo.

Where: `LinuxWindows/crates/lokalbot-platform/src/autocomplete/spell.rs` (`is_checkable`).

### Partial KV reuse falls back to a full re-prefill

The in-process runtime keeps the shared prefix's KV and re-decodes only the diverged suffix, dropping [reuse, end) with `llama_memory_seq_rm`. Prompts are not guaranteed to fit the production Gemma4 model's 512-token sliding window (worst case about 850–1100 tokens: a 150-word prefix, the ~900-character preface and up to 2,500 prefix characters), and `seq_rm` returns false when the kept prefix has aged out of it. The full re-prefill on that false must stay: partial reuse is safe only when `seq_rm` confirms the kept prefix is still resident.

Where: `LokalBot/Cotyping/Llama/LlamaCotypingRuntime.swift` (`LlamaCotypingRuntime.generate`).

### Autocomplete decodes with two threads

All app autocomplete uses the measured hybrid policy with two generation and prefill threads, which won the fixed-E2B latency study on an M4 Max; other hardware and cancellation responsiveness still need broader trials. Replay keeps its explicit controls and the initializer's baseline defaults for historical parity.

Where: `LokalBot/Cotyping/Llama/LlamaCotypingRuntime.swift` (`LlamaCotypingRuntime.forAutocomplete`).

### Macros never run code or reach the network

The arithmetic macro uses a hand-written parser, so nothing in a query is evaluated as code. The currency macro uses bundled, offline, approximate exchange rates (units per USD), in keeping with LokalBot's strictly local posture.

Where: `LinuxWindows/crates/lokalbot-ai/src/autocomplete/macros.rs` (`Arithmetic`), `LokalBot/Cotyping/CotypingMacro.swift` (`CotypingMacro.CurrencyRateTable`).

## Where the model runs

### Autocomplete never downloads anything

Autocomplete starts as the user types, so starting its server only ever uses a llama.cpp build that is already installed. Without the Autocomplete model and the runtime, or a server the user set up and approved, no suggestion is made; without an on-device OCR engine there is no window text.

Where: `LinuxWindows/crates/lokalbot-ai/src/runtime.rs` (`Role::downloads_runtime`), `LinuxWindows/crates/lokalbot-engine/src/autocomplete.rs`, `LinuxWindows/crates/lokalbot-engine/src/autocomplete_window_text.rs`.

### On the Mac autocomplete has its own llama server

The Mac's own model runs on the dedicated `LlamaServer.cotyping` instance so it never thrashes the shared summarizer server; a chosen server is reached through `cotypingServer`. The route is resolved for each completion, so changes apply live.

Where: `LokalBot/AppState.swift` (`AppState.cotypingEngine`).

### Two copies of the autocomplete model are never resident

Lifecycle transitions are serialized: a disable finishes unloading both runtimes before a quick re-enable can prewarm a fresh model, and selectors await the engine's `unload` (the in-process engine releases its model and context, the HTTP engine stops its dedicated `llama-server`) before changing routes. `@MainActor` prevents simultaneous mutation, but async model verification and unloads are re-entrant, so a generation counter invalidates work that crossed a suspension under an older route; otherwise an older generate or prewarm could recreate the local runtime after shutdown.

Where: `LokalBot/AppState.swift` (`AppState.cotypingRuntimeTask`), `LokalBot/Cotyping/CotypingEngine.swift` (`CotypingCompleting.unload`), `LokalBot/Cotyping/Llama/CotypingEngineSelector.swift` (`CotypingEngineSelector.lifecycleGeneration`).

### A failed in-process model is unloaded before the HTTP fallback starts

The fallback runs the same GGUF in its own `llama-server` process, and a local failure is likely memory pressure, so the unload is awaited before the fallback can cold-load the server's copy. Autocomplete then routes to HTTP for `localRetryCooldown` and rebuilds and retries local once it passes: a cold reload at most once per cooldown, never per keystroke. Each failure episode is logged once.

Where: `LokalBot/Cotyping/Llama/CotypingEngineSelector.swift` (`CotypingEngineSelector.handleLocalFailure`), `LokalBotTests/Cotyping/Llama/CotypingEngineSelectorTests.swift` (`testLocalFailureFreesModelAndCoolsDownBeforeRetry`).

### An idle in-process model is warmed by any activity

llama.cpp stops holding the weights resident three minutes after the last decode, and the system then pages or compresses them: on 2026-10-06 the first suggestion after half an hour took 1.9 s against 62 ms while typing. Any key or click the input monitor sees, and the screen waking or unlocking, runs one throwaway token if the model has not run for a while (`LocalLlamaCotypingEngine.warmAfterIdle`), which also renews llama.cpp's keep-alive while the Mac is in use. The warm-up waits for its GPU work, because `llama_decode` only queues it and the next suggestion would otherwise wait for it.

Where: `LokalBot/Cotyping/CotypingCoordinator+ModelWarmth.swift`, `LokalBot/Cotyping/Llama/LlamaCotypingRuntime.swift` (`LlamaCotypingRuntime.touch`), `LokalBotTests/Cotyping/CotypingCoordinatorTests.swift` (`testAKeyAfterAPauseReadiesTheModel`).

### The llama context is freed in `deinit`

Without it the Metal backend's residency set is still live at process exit, which trips a teardown assertion in the vendored ggml-metal build.

Where: `LokalBot/Cotyping/Llama/LlamaCotypingRuntime.swift` (`LlamaCotypingRuntime.deinit`).

### Typing goes to a server only after its origin is approved for autocomplete

Autocomplete runs on this computer, on Think's server with the same or another model, or on any OpenAI-compatible server, hosted or on the user's own network; the settings pane edits a draft that Use model applies, and the route is built from settings for every request, so a change applies to the next keystroke. Approved origins are kept apart from Think's (`approvedRemoteAutocompleteOrigins` against `approvedRemoteInferenceOrigins`), because autocomplete sends what is typed in other apps, which approving a server for Think never covered. Only the on-device model or a loopback server keeps the prompt on the computer and needs no approval; a server not yet set up counts as off the Mac (`cotypingLeavesThisMac`).

Where: `LinuxWindows/crates/lokalbot-ai/src/autocomplete/server.rs`, `LinuxWindows/crates/lokalbot-app/src/pages/settings/writing_server.rs`, `LokalBot/Views/Autocomplete/AutocompleteServerSetup.swift` (`AutocompleteServerSetup`), `LokalBot/Models/Settings/AppSettings.swift` (`AppSettings.approvedRemoteAutocompleteOrigins`), `LokalBot/Cotyping/CotypingServerRoute.swift` (`AppSettings.cotypingLeavesThisMac`).

### An approved server on the user's own network may use plain HTTP

Autocomplete's consent, the one its route was resolved with, allows plain HTTP to an approved server on the user's own network, unlike Think's.

Where: `LinuxWindows/crates/lokalbot-ai/src/think.rs` (`autocomplete_consent`).

### Choosing a server is consent to the context the user turned on

The context toggles apply to a chosen server as set, the same as on the Mac itself.

Where: `LokalBotTests/Cotyping/CotypingServerRouteTests.swift` (`testAChosenServerGetsTheContextTheUserTurnedOn`).

### Hosted APIs get chat continuation; servers people run get raw completions

OpenAI and Anthropic offer no raw completions for current models, and OpenRouter's raw route continues text as gibberish on many hosts (`Benchmarks/autocomplete/Cotyping/README.md`); servers people run themselves, such as llama-server, LM Studio and Ollama, offer them. Extra completion fields go only to a self-hosted server (`CotypingServerEndpoint.isSelfHosted`), since hosted APIs may reject unknown fields.

Where: `LinuxWindows/crates/lokalbot-ai/src/autocomplete/server.rs` (`Endpoint::starts_with_chat`), `LinuxWindows/crates/lokalbot-ai/src/think.rs` (`CompletionClient::body`), `LokalBot/Cotyping/CotypingServerRoute.swift` (`CotypingServerEndpoint.startsWithChat`).

### A failed server request is not replayed, and a non-streaming reply is the whole completion

A newer keystroke supersedes a failed request anyway, and there is no prefill, since a server keeps its own cache. A 2xx without SSE means the server does not stream and its body is the whole completion; only a body that is not one is asked for again.

Where: `LinuxWindows/crates/lokalbot-ai/src/autocomplete/server.rs`, `LinuxWindows/crates/lokalbot-ai/src/think.rs` (`CompletionClient::stream`).

### Chat replies get room for reasoning

A reply gets room for reasoning a model cannot turn off, on top of the phrase: OpenRouter's `z-ai/glm-5.3-flash` always reasons, and on 2026-10-15 a 32-token reply ended inside that reasoning with no suggestion.

Where: `LokalBot/Cotyping/CotypingServerRoute.swift` (`ChatContinuationEngine.reasoningRoomTokens`).

### Server error text is never kept or logged

A request error can quote the prompt, so the record of why the last request brought no suggestion holds no server message; Writing shows that record, since typing elsewhere shows no error. Failures are logged once per episode, without the server's message.

Where: `LinuxWindows/crates/lokalbot-ai/src/autocomplete/server.rs` (`Failure`), `LinuxWindows/crates/lokalbot-engine/src/autocomplete.rs` (`EngineHost.failed`).

### Typed text follows chat's provider data policy

Typed text is as private as Think's context, so OpenAI-compatible requests carry the same provider data policy as chat.

Where: `LokalBot/Engines/TextEngine.swift` (`OpenAICompatibleEngine.completionBody`).

## Context beyond the field

### Saved facts need their own grant and a reason to be relevant

Facts from saved sources come from a retrieval policy, not a second model call or a stored profile, and reading the meeting library is its own grant (`cotypingUseMeetingMemory`, off by default), separate from turning Autocomplete on. A fact is used only when the draft, the window title or the conversation above the field names its source, or when it shares two distinctive words with the user's own draft or window title, one of them written as a name, or three when none is; a notes line must not be a heading, while work-memory entries are statements even when one is its own title. Everyday wording never counts (two common words in a generic sentence once borrowed a date from an unrelated meeting), and the conversation above the field may name a source but never counts as the user's own wording: a visible conversation naming Willow must not admit Mistral through "export" or "format". The memory search uses only the grants' words, nothing for integrated terminals, and no title without the app context grant.

Where: `LinuxWindows/crates/lokalbot-ai/src/autocomplete/memory.rs` (`Query`), `LinuxWindows/crates/lokalbot-engine/src/autocomplete.rs` (`query_for`), `LokalBot/Cotyping/CotypingMemoryContext.swift` (`CotypingMemoryContext.relevance`), `LokalBotTests/Cotyping/CotypingVisibleContextTests.swift` (`testVisibleGenericVocabularyCannotRetrieveAnotherProjectsMemory`).

### The writing grants alone authorize saved work memory

Whether new overnight reviews are scheduled is a separate choice and is not consulted. Projects and goals from the overnight reviews (`memory/memory.json` in a macOS library) each need the grants of every kind of source behind them; items with unattributed or no sources are left out, and an unfinished revocation reads as nothing at all.

Where: `LokalBot/Cotyping/CotypingMemoryContext.swift` (`CotypingMemoryContext.Policy`), `LinuxWindows/crates/lokalbot-ai/src/autocomplete/memory.rs` (`work_memory_items`), `LinuxWindows/crates/lokalbot-engine/src/autocomplete.rs` (`look_up_guarded`), `LokalBotTests/Cotyping/CotypingMemoryContextTests.swift` (`testSavedWorkMemoryIsReadUnderTheWritingGrantsAlone`).

### Facts come from current files, and a changed source ends what it shaped

Full-text search only finds candidates; prompts use the current files, read off the UI thread, so an old index row cannot resurrect edited or deleted text, and no private fact is cached or copied into a new store. A lookup records the paths and stamps it read (no text), stamping sources before reading them so an edit made meanwhile still shows; editing or deleting a source, or withdrawing a grant, ends the suggestions it shaped, including at accept, where the suggestion goes and the app gets its key. The Mac drops both visible and cached text before such a change, never copies accepted facts into learning, and fails closed during a source mutation without waiting on a store or file lock inside the keyboard acceptance callback.

Where: `LokalBot/Cotyping/CotypingMemoryContextProvider.swift` (`CotypingMemoryContextProvider`), `LinuxWindows/crates/lokalbot-ai/src/autocomplete/memory.rs` (`MemoryGuard`), `LinuxWindows/crates/lokalbot-engine/src/autocomplete.rs` (`look_up_guarded`), `LinuxWindows/crates/lokalbot-app/src/autocomplete/mod.rs` (`Autocomplete.on_accept_key`), `LokalBot/Cotyping/CotypingCoordinator+Lifecycle.swift` (`CotypingCoordinator.invalidateMemoryContext`), `LokalBot/Services/Dreaming/DreamStore.swift` (`DreamStore.autocompleteEvidenceIsAvailable`).

### A privacy setting change cancels work and drops what it shaped

A change to `CotypingPrivacySettings` cancels work in progress and drops what was read or shaped under the old settings.

Where: `LinuxWindows/crates/lokalbot-engine/src/autocomplete.rs` (`PrivacySettings`).

### Only a fresh, related clipboard copy enters the prompt

As in CoTabby, the first clipboard observation is a baseline of unknown age, not a fresh copy; only later copies made during this session count, while fresh and related to what is being typed. Sensitivity markers are checked before any text is asked for: `org.nspasteboard`'s types, plus what password managers set on Windows and Linux (X11's KDE hint, Windows' monitor and history opt-outs), compared lowercased. A concurrent pasteboard change invalidates the whole observation.

Where: `LinuxWindows/crates/lokalbot-ai/src/autocomplete/clipboard.rs` (`RelevanceFilter`), `LinuxWindows/crates/lokalbot-platform/src/autocomplete/clipboard.rs` (`SENSITIVE_TYPES`), `LokalBot/Cotyping/CotypingClipboardContext.swift` (`CotypingClipboardRelevanceFilter`, `CotypingClipboardProvider`).

### Text above the field comes from one bounded background walk

The conversation being answered is read by one bounded walk over the window's accessibility tree, in the background once per field: metadata is checked before text, rejected branches are never read, and only static labels and links in a column above the field count. Toolbars, menus, trees and any editable or secure field are never entered (another field's draft is not context), and nothing comes from a private or incognito window, as `PRIVACY.md` promises; activity tracking keeps its own rule. On the Mac it runs only on the serialized background focus worker, with no pixels, OCR, saved screen history, whole document values or reads on the Tab path, and nothing is kept once focus leaves the field.

Where: `LinuxWindows/crates/lokalbot-platform/src/autocomplete/visible.rs` (`NodeKind::Excluded`), `LokalBot/Cotyping/CotypingVisibleContextAXSource.swift` (`CotypingVisibleContextAXSource`), `LokalBot/Cotyping/CotypingVisibleContext.swift` (`CotypingVisibleContext.Policy.permits`), `LokalBotTests/Cotyping/CotypingVisibleContextTests.swift` (`testPrivateWindowsAreNeverRead`).

### Snippets that carry a credential are dropped, not redacted

A redaction marker would teach the model to complete one, so an excerpt or window line that carries a credential is left out; so is an excerpt that reads like an instruction to the model, and a window line with no letters or digits. Control characters become spaces, whitespace collapses, and an excerpt is cut at a word boundary with an ellipsis.

Where: `LinuxWindows/crates/lokalbot-platform/src/autocomplete/visible.rs` (`sanitize_excerpt`), `LokalBot/Cotyping/CotypingVisibleContext.swift` (`CotypingVisibleContext.capture`), `LokalBot/Cotyping/CotypingWindowText.swift` (`CotypingWindowText.cleaned`).

### Window text is read in the background and adopted only when typing pauses

Text from the focused window ("Use the focused window as context") is never read on a keystroke: the first request in a field goes without it, and later ones use the result, reread every few seconds. New text starts the prompt, so it waits for a pause in typing; adopted mid-typing on 2026-10-16, it made the next keystroke reread a ~500-token prompt, 268 ms instead of 41. The text is held for the focused field only, forgotten as soon as focus leaves it, and never logged.

Where: `LinuxWindows/crates/lokalbot-ai/src/autocomplete/window_text.rs`, `LinuxWindows/crates/lokalbot-engine/src/autocomplete.rs` (`Worker.on_left_field`), `LokalBot/Cotyping/CotypingWindowTextCapture.swift` (`CotypingWindowTextCapture.typingPause`), `LokalBotTests/Cotyping/CotypingWindowTextTests.swift` (`testNewTextWaitsForAPauseInTyping`).

### Window text comes from the focused window only, recognized on the device

Only the focused window is captured, while its app is still in front; its text is recognized by the on-device OCR engine and the image is dropped at once. Autocomplete never asks for Screen Recording: without it there is no window text. An image unchanged outside the field reuses the last lines, and logs carry counts and times only. The Mac uses the same recognizer as screen memory and Compose, because `.fast` drops every accent and all Cyrillic and the en-US default cannot read CJK.

Where: `LinuxWindows/crates/lokalbot-engine/src/autocomplete_window_text.rs`, `LokalBot/Cotyping/CotypingWindowTextCapture.swift` (`CotypingWindowTextCapture.read`, `CotypingWindowTextCapture.recognize`), `LokalBotTests/Models/Settings/SettingsStatusTests.swift` (`testAutocompleteNeverAsksForScreenRecording`).

### The window title and placeholder are read again once a second old

CoTabby freezes this context while focus stays in one field, but chat apps reuse one composer across conversations, so a frozen title named the conversation left behind. A second still lets one suggestion's prediction and validation reads share a capture. Clearing the cache does not block an AX read in flight, but that read's result cannot repopulate the cache or satisfy a newer caller.

Where: `LokalBot/Cotyping/CotypingAXHelper.swift` (`CotypingAXHelper.surfaceCaptureMaximumAgeSeconds`), `LokalBot/Cotyping/CotypingSurfaceContext.swift` (`CotypingSurfaceCapture`), `LokalBot/Cotyping/CotypingSurfaceCaptureSingleFlight.swift` (`CotypingSurfaceCaptureSingleFlight.removeAll`).

### Learning happens only in a positively identified document

An accepted suggestion becomes an example later prompts in the same document can show ("Previously accepted completion: …"), but only in a Google Docs document in a browser, identified by its address. Generic windows, mail, chat, code editors, terminals and unknown documents or websites cannot establish a recipient boundary, so they neither learn nor reuse examples, and neither do suggestions that used saved facts or the text above the field. Only a web area's own URL identifies a browser document, never a link's `AXURL`; examples are kept for 30 days and sealed on disk in the Mac's format.

Where: `LinuxWindows/crates/lokalbot-ai/src/autocomplete/learning.rs`, `LokalBot/Cotyping/CotypingLearningStore.swift` (`CotypingLearningScope`), `LokalBot/Cotyping/CotypingAXHelper.swift` (`CotypingAXHelper.learningDocumentURL`).

### Forgotten learned text cannot come back

Forgetting cancels what could bring the text back, clears memory at once and deletes after every older queued write, and new learning waits until that is done, so a late write cannot restore it. Examples that cannot be opened are left alone on Windows and Linux: nothing is written over them (the Mac reads them as empty and later overwrites them).

Where: `LinuxWindows/crates/lokalbot-engine/src/autocomplete.rs` (`Worker.forget_learned`, `LearningOpen`), `LokalBot/Cotyping/CotypingLearningStore.swift` (`CotypingLearningStore.forgetAll`).

## Which fields are read

### Nothing is read while autocomplete is off, and typed text is never logged or stored

Nothing is read while autocomplete is off, LokalBot's own windows are skipped, and nothing read is kept on disk (`PRIVACY.md`). Typed text stays in memory and is never logged, including in the engine commands that carry it; what stays on disk is counts (`autocomplete_measure`) and, when on, examples sealed under a key in the credential store. The engine checks the excluded apps again.

Where: `LinuxWindows/crates/lokalbot-platform/src/autocomplete/mod.rs`, `LinuxWindows/crates/lokalbot-engine/src/autocomplete.rs`, `LinuxWindows/crates/lokalbot-engine/src/lib.rs` (`dispatch`).

### Autocomplete stays quiet during dictation, recordings, after Esc and in LokalBot's windows

It stays quiet while dictation runs or a meeting records, in a field for ten seconds after Esc, in LokalBot's own windows and whenever `cotyping_enabled` is off. The practice editor in Settings → Autocomplete feeds the engine itself, with no window title, as on macOS, since "Settings" would steer the model toward settings talk. `LOKALBOT_FAKE_AUTOCOMPLETE=<text>` makes the app suggest `<text>` without the engine, a development switch for checking the desktop side without a model that is off unless set.

Where: `LinuxWindows/crates/lokalbot-app/src/autocomplete/mod.rs` (`Autocomplete.practice_changed`), `LinuxWindows/crates/lokalbot-engine/src/autocomplete.rs`.

### App exclusions authorize the read itself

An excluded app's fields are never read, not read and then dropped: the check runs before any field text exists, and an app owner that cannot be identified fails closed.

Where: `LinuxWindows/crates/lokalbot-platform/src/autocomplete/policy.rs` (`ReadPolicy`), `LokalBot/Cotyping/CotypingAvailability.swift` (`CotypingAppReadPolicy`).

### Secure-field detection errs toward hiding

Hosts do not always expose a native password box as `AXSecureTextField`; some surface only a role description or label, so the check looks at every label a toolkit exposes. A false positive only hides autocomplete, while a false negative could show a secret as ghost text.

Where: `LinuxWindows/crates/lokalbot-platform/src/autocomplete/policy.rs` (`is_secure_field`), `LokalBot/Cotyping/CotypingAvailability.swift` (`CotypingSecureFieldDetector`).

### Code, PIN and one-time-password fields stay quiet

A code is not prose to continue. Pages often name such a field only through its placeholder, label or element id, so those are checked too, by whole words so "pin" never matches "pinned"; a false positive only hides autocomplete in one field.

Where: `LinuxWindows/crates/lokalbot-platform/src/autocomplete/policy.rs` (`is_code_field`).

### Site exclusions fail closed when the page cannot be read

A configured site exclusion is a privacy boundary, not a best-effort hint: a browser whose current host cannot be proven is paused, never treated as allowed. Apps that are not browsers stay usable, having no tab URL to authorize.

Where: `LinuxWindows/crates/lokalbot-platform/src/autocomplete/policy.rs` (`disabled_reason`), `LokalBot/Cotyping/CotypingAvailability.swift` (`CotypingAvailability.disabledReason`).

### A brief selection blip is smoothed, except in secure fields

Some apps briefly report a selection while redrawing the caret, which would tear the ghost down and rebuild it, so one `supported → selected → supported` blip on the same element is smoothed. Selected text is the only blocked state safe to smooth; secure-field blocks never are, because privacy beats visual stability.

Where: `LinuxWindows/crates/lokalbot-platform/src/autocomplete/policy.rs` (`FlickerGate`), `LokalBot/Cotyping/CotypingFocusCapabilityFlickerGate.swift` (`CotypingFocusCapabilityFlickerGate.isSmoothableBlockedReason`).

### A validation capture fails closed on timeout

Generated text about to be displayed must not be validated against a cached field once the live target stops responding.

Where: `LokalBot/Cotyping/CotypingFocusTracker.swift` (`CotypingFocusTracker.refreshForValidation`).

## Accepting a suggestion

### Accept keys are taken only while a suggestion is visible

A session exists exactly while ghost text is on screen, and only then are the accept keys (Tab and the key left of 1 unless changed) and Esc taken from other apps. On the Mac the invariant *session exists ⟺ overlay visible ⟺ state == .ready ⟺ accept tap armed* is set up in `present` and torn down in `clearSuggestion`, never by hand at call sites; generation in flight is never enough, since swallowing Tab with no visible suggestion breaks keyboard navigation and can accept output the user has not reviewed. A key taken but not used goes on to the focused app, so a Tab pressed as a suggestion went away still moves focus.

Where: `LinuxWindows/crates/lokalbot-app/src/autocomplete/mod.rs`, `LinuxWindows/crates/lokalbot-platform/src/autocomplete/mod.rs` (`KeyInterceptor::pass_through`), `LokalBot/Cotyping/CotypingCoordinator+Acceptance.swift` (`CotypingCoordinator.present`), `LokalBot/Cotyping/CotypingModels.swift` (`CotypingAcceptanceOwnershipPolicy`).

### The accept tap does bounded, constant-time work

The consuming event tap never touches the pasteboard or walks an app's AX menu tree, and a direct-input continuation is one synthetic Unicode event pair whatever its length or lines. Its snapshot omits geometry, style, window, URL, DOM and ancestor reads, so a slow host cannot hold the global keyboard event in the tap callback for an unbounded Accessibility walk.

Where: `LokalBot/Cotyping/CotypingCoordinator+Acceptance.swift` (`CotypingCoordinator.acceptFromTap`), `LokalBot/Cotyping/CotypingAXPolicies.swift` (`CotypingAXAcceptanceSnapshot`).

### An accept needs a live caret in the exact field

A live collapsed selection and bounded surrounding text must both be read at accept time: a mouse selection can change without crossing the keyboard observer, and a synthetic insert would overwrite the newly selected text. The field is keyed by its AX identifier plus the element's hash, because identifiers are app-provided and not unique (repeated SwiftUI rows can share one); a hit-test fallback describes what is under the pointer, so each candidate must prove ownership, editability and focus on its own. Replacements delete host text, so they share one exact-field and exact-trigger validation, and a same-PID match is not enough.

Where: `LokalBot/Cotyping/CotypingAXPolicies.swift` (`CotypingAXAcceptanceSnapshot.hasLiveContent`, `CotypingAXFocusIdentityKey`, `CotypingAXHitTestFocusValidator`), `LokalBot/Cotyping/CotypingCoordinator+Acceptance.swift` (`CotypingCoordinator.acceptFromTap`).

### A composing or unknown input source keeps its Tab

Tab may belong to an IME's candidate UI even when the host reports no marked range, so a composing or unknown input source always gets the original key untouched.

Where: `LokalBot/Cotyping/CotypingAXPolicies.swift` (`CotypingAcceptanceSnapshotPolicy.canAccept`).

### Deletion bursts from the accept tap are capped

Every deleted grapheme posts a down/up event pair, so an unbounded typo or overlap could trigger the event-tap watchdog before the original key can fail open.

Where: `LokalBot/Cotyping/CotypingAXPolicies.swift` (`CotypingSyntheticEditPolicy`).

### The accept tap outlives a final accept briefly

The inserter posts synthetic key events from inside the tap callback, and invalidating the tap at once can pull it from the event chain before those events reach the host app.

Where: `LokalBot/Cotyping/CotypingInputMonitor.swift` (`CotypingInputMonitor.acceptTapTeardownDelaySeconds`).

### The ghost moves on before the app shows an accept

Typing the ghost's next characters, or the app showing what an accept typed, shortens it at once; anything else leaves it behind. An accept advances the ghost before the app shows the text, so a quick second Tab takes the next chunk, and reads from before the oldest unshown accept arrives are not a change (`shouldAwaitPostInsertionSync`). On Windows and X11, intermediate echoes while simulated keystrokes are still arriving hold back `FieldContext` updates (`PendingInsert`) and record the accepted prefix in `SentContexts`, so per-character delivery cannot mark the engine's session stale mid-accept. An accept may delete user-perceived characters before the caret first, such as an emoji's `:shortcode`.

Where: `LinuxWindows/crates/lokalbot-platform/src/autocomplete/session.rs` (`GhostSession::accept`, `GhostSession.awaiting`, `SentContexts`), `LinuxWindows/crates/lokalbot-app/src/autocomplete/mod.rs` (`PendingInsert`, `on_accept_key`, `on_engine`), `LokalBot/Cotyping/CotypingCoordinator+Acceptance.swift` (`shouldAwaitPostInsertionSync`).

### Accepted text is typed, never pasted

An accepted chunk goes in through AT-SPI `EditableText` where the field supports it, else XTest on Linux, and `SendInput` Unicode keystrokes on Windows; never through the clipboard.

Where: `LinuxWindows/crates/lokalbot-platform/src/autocomplete/mod.rs`.

### A stored punctuation-accept `true` from before version 4 is the default

Attaching punctuation was the default before settings version 4 and had no control in Settings, so a stored `true` from then is not a choice. From version 4 on the stored value is the user's.

Where: `LokalBot/Models/Settings/AppSettings.swift` (`AppSettings.migratedCotypingAutoAcceptTrailingPunctuation`).

## Finding the caret

### The caret is the trailing edge of the character before it

TextEdit and Telegram on macOS 26 report the empty range at the caret one line above where it is drawn (2026-10-04: TextEdit at y 190 for a line at y 204, above the field's own top edge), with the right x, and Chrome reports it with no size, so a GitHub review box fell back to a guess at the field's top-left corner (2026-10-05). In all three the character before the caret is reported where it is drawn, so its trailing edge is used when it lies one glyph inside the field, else the empty range.

Where: `LinuxWindows/crates/lokalbot-platform/src/autocomplete/policy.rs` (`choose_caret`), `LokalBot/Cotyping/CotypingAXGeometryResolver.swift` (`CotypingCaretGeometry`), `LokalBotTests/Cotyping/CotypingTextLeafCaretTests.swift` (`CotypingCaretGeometryTests`).

### Web engines are asked for caret geometry through text markers

Chromium, WebKit and Electron ignore NSRange-based `BoundsForRange` and expose caret geometry only through opaque AX text markers; this fixes ghost placement in Chrome, Slack and VS Code on the web.

Where: `LokalBot/Cotyping/CotypingAXGeometryResolver.swift` (`CotypingAXGeometryResolver.caretRect`).

### A zero-size Chromium caret is taken from the last text run

Chromium and Electron (measured in Chrome and Discord) return zero-size rects for a collapsed caret from both `AXBoundsForRange` and `AXBoundsForTextMarkerRange`, and lack the marker-extraction attributes that would widen the range. Blink still exposes every laid-out text run as an `AXStaticText` child with a tight frame, so with the caret at the end of the text the last run's trailing edge is the caret; this fixes inline placement in Discord, and is pure geometry, unit-testable without AX.

Where: `LokalBot/Cotyping/CotypingAXGeometryResolver.swift` (`CotypingAXGeometryResolver.caretRect`), `LokalBot/Cotyping/CotypingTextLeafCaret.swift` (`CotypingTextLeafCaret`).

### A line or field box is not a caret

Chromium sometimes answers the text-marker query for the collapsed selection with the whole line's or the field's box (2026-10-05: 788×23, the field, for a one-character message in the Claude app; 548×26 at the start of a Chrome text box), and its trailing edge put the ghost on the line below.

Where: `LokalBot/Cotyping/CotypingAXGeometryResolver.swift` (`CotypingCaretGeometry.isCollapsedCaret`).

### AX rects are flipped through the display that holds the caret

Accessibility rects are top-left-origin display coordinates; flipping them through the display and screen pair containing the caret keeps external displays from inheriting the primary display's height.

Where: `LokalBot/Cotyping/CotypingAXGeometryResolver.swift` (`CotypingAXGeometryResolver.cocoaRect(fromAX:)`).

### Chrome is asked for enhanced accessibility once per process

Chrome turns on its complete accessibility mode, where text markers report the caret's exact bounds and text its font size, only for `AXEnhancedUserInterface` and ignores `AXManualAccessibility`; without it Reddit suggestions came out too large or in a popup over the text (2026-10-21), and Cotypist asks the same way. Chrome then behaves as if a screen reader were running, which costs it some speed and can slow window-manager animations, so Settings can turn it off. Chrome counts these requests, so one is sent per browser process (a forced quit leaves the mode on until the browser restarts), and since Chrome switched modes in testing (2026-10-21) although the request reported an error, only a timeout leaves a browser to be asked again; asking again would raise the count past what one release takes back.

Where: `LokalBot/Cotyping/CotypingAXHelper.swift` (`CotypingAXHelper.requestChromiumEnhancedAccessibilityIfNeeded`), `LokalBot/Cotyping/CotypingAXPolicies.swift` (`CotypingEnhancedAccessibilityRequest`), `LokalBotTests/Cotyping/CotypingSettingsTests.swift` (`testOnlyATimeoutLeavesEnhancedAccessibilityUnasked`).

### Chromium's selection is realigned to the paragraph breaks in its value

Chromium counts a rich-text field's selection, and the text it returns for `AXStringForRange`, without the line breaks between paragraphs that its `AXValue` has. Split at the reported offset, the value put the caret one character early for every paragraph above it: in a Reddit post on 2026-10-21 a suggestion after "elabor" began "rate", and the "r" left after the caret made it look mid-line, so it showed in a popup over the text. `CotypingParagraphBreakAlignment` moves the caret into the value's count; only when the app's range text ends short of its value (`skipsBreaks`) is the text before the caret read with `AXStringForRange` and the selection moved, so one-line values and hosts whose counts agree are unchanged.

Where: `LokalBot/Cotyping/CotypingMarkerSelection.swift` (`CotypingParagraphBreakAlignment`), `LokalBot/Cotyping/CotypingAXHelper.swift` (`CotypingAXHelper.paragraphAlignedSelection`), `LokalBotTests/Cotyping/CotypingMarkerSelectionTests.swift` (`CotypingParagraphBreakAlignmentTests`).

### Where Accessibility gives no caret, it is found by recognizing the field's text on screen

In a GitHub comment box in Chrome every range and text-marker query answered an empty box at the page's corner, with Chrome's text metrics and screen-reader mode on or off (2026-10-05), so a suggestion could only be shown beside the field. Recognizing the line that ends at the caret puts it back on the line being typed. The locator is pure geometry over plain values, unit-testable without the screen; it never captures a secure field, an app excluded from screen capture or autocomplete, or, while any site is excluded, a browser page whose address is unknown or excluded.

Where: `LokalBot/Cotyping/CotypingVisualCaret.swift` (`CotypingVisualCaretLocator`, `CotypingVisualCaretLocator.permitsCapture`).

### The field is captured with `scalesToFit`, at three times on non-Retina displays

Without `scalesToFit` a non-Retina display's pixels land unscaled in the image's top-left quarter (2026-10-05, on a 1x display) and every recognized box comes out at half its size and place. A Retina display is captured at its own scale; a non-Retina one at three times the points for a field small enough, else two, because at two times recognition misread twice as many letters of rendered chat text (9 of 371 against 5, 2026-10-09; Viber's "je" as "Je" throughout) in the same 6 ms per line.

Where: `LokalBot/Cotyping/CotypingVisualCaret.swift` (`CotypingVisualCaret.captureConfiguration`, `CotypingVisualCaret.captureScale`), `LokalBotTests/Cotyping/CotypingVisualCaretTests.swift` (`testTheCaptureIsScaledUpOnANonRetinaDisplay`).

### The font is sized from the typed text, and trusted only from a whole line

In Viber on 2026-10-09, at a 2× capture, recognition read "bolje ali i dalje nije" as "bolJe all I dalJe nlJe"; sizing the font from that made it 12.8 pt instead of 13.5 pt, so every letter typed afterwards put the ghost further behind the caret, and after "uvS" it began over the "S". A size holds for the whole field only when recognition read as many characters as were typed on a line long enough to measure: a line missing its first letters gave sizes from 11 to 15 pt for one 13.5 pt field (2026-11-02), and the ghost changed size between finds. Until then, and always on a Cyrillic line, where the system font follows the field's font worst, the caret is measured again more often: every 12 letters left it up to 5.2 pt off on Cyrillic, against 2.9 pt (replayed 2026-11-02).

Where: `LokalBot/Cotyping/CotypingVisualCaret.swift` (`Calibration.sizeIsReliable`, `CotypingVisualCaretLocator.remeasureAfterCharacters`), `LokalBotTests/Cotyping/CotypingVisualCaretTests.swift` (`testTheFontIsSizedFromTheTypedTextNotTheMisreadOne`).

### Cyrillic lines use accurate recognition and are measured from their ink

Accurate recognition reads Cyrillic where fast recognition reads none of it (20 to 60 ms on a field's frame on an M4 Max, against 5), and that decides whether a line is the typed one. It gives only word boxes, which ran up to 6 pt past the text, while the recognition with character boxes cannot read Cyrillic and lost whole words from either end (16 pt, 2026-11-02); a field's text sits on a flat background, so the line's edges, baseline and the app's caret come from its pixels.

Where: `LokalBot/Cotyping/CotypingVisualCaret.swift` (`CotypingVisualCaret.recognizeCyrillic`), `LokalBot/Cotyping/CotypingVisualCaretInk.swift` (`CotypingVisualCaretInk`).

### Accented Latin letters fast recognition cannot read do not stop a match

Fast recognition knows English, French, Italian, German, Spanish and Portuguese, in practice without their accents: on a non-Retina display "Č" came back as "&", "Ž" as "2", "Đ" as "E)" and "Š" not at all (2026-11-02), so a short Serbian message never matched and the suggestion went to a popup. Such letters count as unreadable rather than whole scripts, because a line of an unreadable script would match any text: the caret went up to 24 pt astray when all of Cyrillic was treated this way.

Where: `LokalBot/Cotyping/CotypingVisualCaret.swift` (`CotypingVisualCaretLocator.isUnreadable`), `LokalBotTests/Cotyping/CotypingVisualCaretTests.swift` (`testLettersRecognitionCannotReadDoNotStopAMatch`).

### Recognition is not detached, and waits for it are bounded by a signal

Recognition that never answered left each find holding a Swift concurrency thread from a detached task until none was free (2026-11-09). A task group cannot bound a wait: leaving one waits for every child, and a child awaiting another task's value is not stopped by cancellation, so a 150 ms budget waited for a 400 ms capture. The wait ends at the deadline; the task itself is never cancelled there.

Where: `LokalBot/Cotyping/CotypingVisualCaret.swift` (`CotypingVisualCaret.recognizeLines`, `CotypingBoundedWait`).

## Drawing the ghost

### The ghost is drawn inline only at a line's end with an exact caret, and never over text

Ghost text over the characters after the caret would be unreadable. The first line of an inline suggestion continues the caret's line; what does not fit wraps at the field's text edge, but only onto lines below that hold no text and lie inside the field. When the rest of the word at the caret does not fit, the app will move the whole word to the next line, so nothing on screen shows where the text goes; on Windows and X11 an inline suggestion with no horizontal room falls back to a pill at the caret before being dropped, and a suggestion with no place on screen that covers no text is dropped.

Where: `LinuxWindows/crates/lokalbot-platform/src/autocomplete/geometry.rs` (`render_mode`, `InlineLayout`, `InlineLayout::make`), `LinuxWindows/crates/lokalbot-app/src/autocomplete/layout.rs` (`place`), `LokalBot/Cotyping/CotypingCoordinator+Acceptance.swift` (`CotypingCoordinator.present`).

### With an estimated caret the pill goes outside the field

A caret estimated from the field says nothing about where the text is, so the pill goes just below the field, or else above it, never over its text, and nowhere without such room. An exact caret places the pill at the caret.

Where: `LinuxWindows/crates/lokalbot-platform/src/autocomplete/geometry.rs` (`pill_frame`).

### An inline ghost holds its place only just after an accept

When the caret is read again, the ghost moves to any other line, and whenever the caret is further along than the ghost starts, since it would cover text just typed. A ghost ahead of the caret is held only right after an accept, because apps often show inserted text before they move the caret.

Where: `LinuxWindows/crates/lokalbot-platform/src/autocomplete/geometry.rs` (`should_hold_reanchor`), `LinuxWindows/crates/lokalbot-app/src/autocomplete/mod.rs` (`Autocomplete.present`), `LokalBot/Cotyping/CotypingOverlayGeometry.swift` (`CotypingOverlayGeometry.shouldHoldInlineReanchor`).

### The background behind the ghost is captured whole-point at its own pixel size

The strip right of the caret is captured in whole points at the backing scale with `scalesToFit`: ScreenCaptureKit widens a fractional source to whole points, fits it inside the output keeping its aspect and leaves what lies off the display black (2026-10-05: a 166×17 pt strip asked for at 32×3 came back with its last 2–4 columns black, pulling a white field from 0.97 to 0.85). `scalesToFit` makes a scale mismatch stretch rather than leave black, since without it ScreenCaptureKit only scales down.

Where: `LokalBot/Cotyping/CotypingBackgroundSampler.swift` (`CotypingBackgroundSampler.captureConfiguration`), `LokalBotTests/Cotyping/CotypingFieldStyleTests.swift` (`testTheBackgroundCaptureIsTheWholeStripAtItsOwnPixelSize`).

### A background reading is reused per field, not per app or element

The reading is keyed by app, kind of field, window title and frame. Per app, a reading from a light page in Chrome drew black ghosts in a dark Reddit comment box (2026-10-21); per element, Chrome hands out a new one on every read, which would sample again for every suggestion.

Where: `LinuxWindows/crates/lokalbot-platform/src/autocomplete/policy.rs` (`background_cache_key`), `LokalBot/Cotyping/CotypingFieldIdentity.swift` (`CotypingFieldIdentity.background`), `LokalBotTests/Cotyping/CotypingFieldStyleTests.swift` (`testReadingFromOneFieldIsNotReusedInAnotherFieldOfTheSameApp`).

### Ghost contrast uses median linear sRGB luminance, and overlay scale comes from the caret's monitor

WinUI 3, UWP XAML, Chromium Views and OneNote often report fallback `#FFFFFF` backgrounds or `#000000` text colors on dark surfaces, so `background_luminance` returns a cached reading even while the overlay is hidden and samples the screen only when both the cache has no entry for the field key and the overlay is hidden (hiding the overlay alone does not refresh an existing cached reading). Sampling takes the median across top, middle and bottom rows of the caret's glyph band in linear sRGB relative luminance (`0.18` dark-surface midpoint), staying inside the field's right scrollbar margin (`luminance_probe_xs`) so an end-of-line caret near a window border never poisons the cache with scrollbar or desktop pixels, while WCAG contrast rejects dark ink on dark gray. Before showing the overlay, `present` queries the monitor DPI scale at the caret so high-DPI displays do not flash one frame at `1×`.

Where: `LinuxWindows/crates/lokalbot-platform/src/autocomplete/geometry.rs` (`Rgb::luminance`, `ghost_paint`), `LinuxWindows/crates/lokalbot-platform/src/autocomplete/policy.rs` (`luminance_probe_xs`), `LinuxWindows/crates/lokalbot-platform/src/autocomplete/win32.rs` (`sample_luminance`, `scale_at`), `LinuxWindows/crates/lokalbot-platform/src/autocomplete/x11.rs` (`sample_luminance`), `LinuxWindows/crates/lokalbot-app/src/autocomplete/mod.rs` (`present`, `background_luminance`).

### macOS's own inline predictions are asked to be turned off

macOS can draw its own grey inline prediction at the caret, and with LokalBot's autocomplete on two suggestions would compete in the same place; as Cotypist does, the Autocomplete settings check this setting and ask for the macOS one to be turned off.

Where: `LokalBot/Cotyping/CotypingSystemInlinePredictions.swift` (`CotypingSystemInlinePredictions`).

### The practice editor lays out the whole sentence when drawing the ghost

Drawing into a caret-width rectangle indents every continuation line beneath the insertion point; laying out the complete sentence returns wrapped lines to the editor's left margin.

Where: `LokalBot/Support/RehearsalTextEditor.swift` (`RehearsalTextEditor.draw`).

### On Windows the ghost is a plain `WS_POPUP` sized at the target monitor's DPI before painting

GPUI creates pop-ups as overlapped windows, which Windows gives a caption and border, so the client area sat inside the ghost's frame, its text was shifted and clipped, and DWM drew a thin border. A plain `WS_POPUP` without DWM's frame, rounded corners and border is exactly the ghost's frame; it is never activated, lets clicks through, stays out of the taskbar and Alt+Tab and, when asked, out of screenshots and recordings. On cross-monitor moves `place_overlay` moves the window to the target monitor before applying its new pixel size so GPUI's `WM_DPICHANGED` handler cannot overwrite the height with the old scaled rect, `Overlay::move_native` resizes before refreshing `GhostView`, and `layout::place` expands tight WinUI 3 caret boxes symmetrically to at least `1.35 × font_size` so DirectWrite's line layer never clips descenders.

Where: `LinuxWindows/crates/lokalbot-platform/src/autocomplete/win32.rs` (`prepare_overlay`, `place_overlay`), `LinuxWindows/crates/lokalbot-app/src/autocomplete/overlay.rs` (`Overlay::show`, `Overlay::move_native`), `LinuxWindows/crates/lokalbot-app/src/autocomplete/layout.rs` (`place`).

### Films use a private build whose panel is visible to screen recording

The shipping autocomplete panel sets `sharingType = .none`, so screen recording never sees a suggestion. The filming copy changes that one line to `.readOnly`, is built from `git archive` (default revision v0.11.2) so the checkout and `/Applications/LokalBot.app` are untouched, and is re-signed to the installed app's designated requirement so its Accessibility and Input Monitoring grants apply. It is never shipped or committed. Debug builds on macOS (`LOKALBOT_TEST_HOOKS`) and Windows (`debug_assertions`) also accept `--lokalbot-film-ghost` or `LOKALBOT_TEST_FILM_GHOST=1` to leave the overlay visible to screen recording (omitting `WDA_EXCLUDEFROMCAPTURE` on Windows); release builds always keep the exclusion on.

Where: `Scripts/media/readme-gif/build_filming_app.sh`, `LokalBot/Support/TestHooks.swift` (`filmsAutocomplete`), `LinuxWindows/crates/lokalbot-app/src/autocomplete/mod.rs` (`film_ghost_enabled`).

## Linux and Windows desktop integration

### AT-SPI events are subscribed through the registry

Without a subscription the registry forwards to apps, toolkits do not send the event at all.

Where: `LinuxWindows/crates/lokalbot-platform/src/autocomplete/atspi.rs` (`EVENTS`).

### AT-SPI offsets are counted per toolkit as measured live

AT-SPI says `EditableText` and `Text` count characters; the counts used are what GTK 3.24, GTK 4.14, Qt 5.15 and Qt 6.4 fields did when driven live, and a toolkit not checked that way keeps characters. `InsertText`'s length must match: too small cuts the text short, too large makes Qt pad it with NUL characters. After an insert the caret is set again, because some toolkits leave it before the inserted text and a Qt line edit sends it to the end of the field.

Where: `LinuxWindows/crates/lokalbot-platform/src/autocomplete/atspi.rs` (`Counting`, `Counting::insert_length`, `insert_editable`).

### GTK 4 is read in window coordinates

GTK 4 cannot know where its window is: it places every element at the origin in screen coordinates, and only window extents, measured from the content inside the shadow it draws itself, are right; it also never answers `GetOffsetAtPoint` before 4.16 and returns hidden entry text before 4.20. Its fields are placed from window extents plus where the X window's content is, while other toolkits, including Chromium, which answers `GetOffsetAtPoint` only in screen coordinates, are read in screen coordinates.

Where: `LinuxWindows/crates/lokalbot-platform/src/autocomplete/atspi.rs` (`Reader::window_origin`), `LinuxWindows/crates/lokalbot-platform/src/screen/atspi.rs` (`toolkit_for`).

### The X11 active window frame excludes GTK's client-side shadow

The frame is the window's content in root coordinates, without the shadow a client-side decorated GTK window draws around itself (`_GTK_FRAME_EXTENTS`).

Where: `LinuxWindows/crates/lokalbot-platform/src/autocomplete/x11.rs` (`ActiveWindow::frame`).

### A focus loss right after a taken key waits before the ghost goes

An X11 key grab gives the focused app a short focus loss, which GTK 4 reports as no focused field until the key is released.

Where: `LinuxWindows/crates/lokalbot-app/src/autocomplete/mod.rs` (`KEY_FOCUS_GRACE`).

### XTest typing waits for the accept key's release

While a grabbed key is held the keyboard is grabbed by LokalBot, so XTest typing would come back to LokalBot instead of reaching the app.

Where: `LinuxWindows/crates/lokalbot-platform/src/autocomplete/x11.rs` (`KeyHeld`).

### Accept-all is bound to the physical key left of 1

Matching the keysym would, on other layouts, take a letter key that types a backtick on a shifted level. An X server without the evdev keymap falls back to the key whose first level is a backtick.

Where: `LinuxWindows/crates/lokalbot-platform/src/autocomplete/x11.rs` (`backtick_keycode`).

### On Windows a low-level hook gates keys atomically and serializes typing with pass-through

An `AtomicBool` enables and disables key capture immediately when a suggestion appears or ends, holding the hook only until any already-taken key finishes its release so key-hold autorepeat never leaks into the app, while LokalBot's own keystrokes carry `MARKER` and pass untouched. Accepted text is injected in batched `SendInput` chunks (20 UTF-16 units with a 5 ms pause), and `PassThrough` keys share the `Inserter` FIFO queue so a raw `Tab` never overtakes queued characters. Session reconciliation compares trailing text only up to the end of the caret's line (`inline_after`) so live preview or status updates below the caret never discard an active session, capped `4,096`-unit sliding windows reconcile by suffix overlap (`progression_between`, `typed_since`), and `lokalbot-engine` ignores monotonic catch-up snapshots behind `Accepted` (`is_catching_up`).

Where: `LinuxWindows/crates/lokalbot-platform/src/autocomplete/win32.rs` (`Hook`, `hook_proc`, `insert`), `LinuxWindows/crates/lokalbot-platform/src/autocomplete/session.rs` (`GhostSession`, `progression_between`, `typed_since`), `LinuxWindows/crates/lokalbot-app/src/autocomplete/mod.rs` (`Inserter`, `PendingInsert`, `reconcile_session`), `LinuxWindows/crates/lokalbot-ai/src/autocomplete/session.rs` (`inline_after`, `reconcile`, `is_catching_up`, `typed_since`), `LinuxWindows/crates/lokalbot-engine/src/autocomplete.rs` (`Worker::read_field`, `Worker::schedule`).

### Object-replacement and Private Use Area glyphs are stripped and never inserted

Inline widgets such as embedded attachment/emoji nodes expose `U+FFFC` (`OBJECT REPLACEMENT CHARACTER`) in accessibility text, icon fonts such as VS Code's breadcrumb codicons expose Private Use Area code points (`U+E000..U+F8FF`, planes 15–16), and rich-text editors such as RoosterJS convert trailing spaces into `U+00A0` (`NO-BREAK SPACE`). Inline `@mention` and `#channel` child elements at `U+FFFC` offsets keep their accessible label (`expand_inline_mentions`), `U+00A0` normalizes to ASCII space so trailing-space reconciliation never stales on `contenteditable` editors, and remaining non-text glyphs are stripped without leaving synthetic double spaces and are rejected before insertion so the model cannot echo placeholder boxes or icon glyphs back into the draft.

Where: `LinuxWindows/crates/lokalbot-ai/src/autocomplete/text.rs` (`is_non_text_glyph`), `LinuxWindows/crates/lokalbot-ai/src/autocomplete/normalize.rs` (`is_safe_to_insert`), `LinuxWindows/crates/lokalbot-platform/src/autocomplete/policy.rs` (`strip_non_text_glyphs`), `LinuxWindows/crates/lokalbot-platform/src/autocomplete/visible.rs` (`sanitize_excerpt`), `LinuxWindows/crates/lokalbot-platform/src/autocomplete/uia.rs` (`read_text`, `expand_inline_mentions`).

### Windows UI Automation caret, toolkit and multi-process host quirks

- **Document-range clamping in web engines:** Chromium, Electron and WebView2 share one unified `AXTextRange` tree across an entire page, so `MoveEndpointByUnit` on a `contenteditable` element walks out of the field into surrounding sidebars, toolbars and completion popups; `read_text` and `style_near` clamp endpoints to `IUIAutomationTextPattern::DocumentRange` whenever the caret lies within it.
- **Padded RichEdit first lines, soft wraps and wide line boxes:** Windows 11 Notepad (`RichEditD2DPT`) folds top document padding and paragraph space-before into the first line's bounding rectangle, so inline ghost boxes clamp excess height to the natural font line box anchored to the rectangle's bottom (`inline_caret_box`). When a collapsed caret wraps onto a new line below `previous_character`, `choose_caret` follows the wrapped line instead of hanging past the right edge of the line above, and rejects non-collapsed line/field boxes on `empty_range`.
- **`QScintilla` origin carets, stale Win32 carets and Qt `QLineEdit` action buttons:** `QScintilla` passes character offsets in `wParam` instead of `lParam` for `SCI_POINTXFROMPOSITION`, returning the viewport origin for every offset; `is_stuck_at_origin_caret` drops that bogus exactness on both degenerate and previous-character ranges, skips `GetGUIThreadInfo` fallback (`is_plausible_system_caret`) so stale 3 px Win32 carets cannot place an inline ghost inside the pane, and self-disarms if upstream fixes the offset. Qt `QLineEdit` omits leading action-button insets from `characterRect`; `translate_for_leading_button` restores that horizontal offset while character `0` overlaps the child button.
- **Un-accessible Monaco placeholders and single-poll DOM blips:** Monaco editors without screen-reader mode expose a dummy `native-edit-context` element containing `"The editor is not accessible at this time"`; `is_inaccessible_editor_placeholder` marks it unsupported rather than suggesting over an inert placeholder. Chromium and CodeMirror DOM rebuilds briefly report a missing caret or non-editable container for one poll; `FlickerGate` absorbs a single same-app `NO_CARET` or `NOT_EDITABLE` read before clearing.
- **Multi-process hosts:** UWP apps under `ApplicationFrameHost.exe`, embedded `msedgewebview2.exe` controls (New Outlook, Tauri apps), and out-of-process child UI surfaces (such as WhatsApp Desktop's child window) split the foreground window and the focused UI Automation element across processes. `window_owns_pid` accepts only a matching child HWND or a visible descendant-owned top-level window substantially overlapping the foreground window (`detached_webview_windows_for`), rejecting shells, terminals, and reused parent PIDs (`GetProcessTimes`), and UI Automation checks app exclusions against both the element's process and its foreground host (`effective_app_for_pid`, `host_app_for_pid`).

Where: `LinuxWindows/crates/lokalbot-platform/src/autocomplete/geometry.rs` (`inline_caret_box`), `LinuxWindows/crates/lokalbot-platform/src/autocomplete/policy.rs` (`FlickerGate`, `choose_caret`, `is_collapsed_caret`, `is_stuck_at_origin_caret`, `is_plausible_system_caret`, `translate_for_leading_button`, `is_inaccessible_editor_placeholder`), `LinuxWindows/crates/lokalbot-platform/src/autocomplete/uia.rs` (`read_text`, `style_near`, `follow_focus`), `LinuxWindows/crates/lokalbot-platform/src/activity/win32.rs` (`window_owns_pid`, `effective_app_for_pid`, `host_app_for_pid`, `detached_webview_window_for_foreground`, `child_window_overlap_area`).

### On Wayland autocomplete is the desktop's input method

Wayland lets no ordinary app take a key from another app, place a window at its caret or type into it; an input method is told when a text field has focus, its kind and the text around the caret, shows its text in the field as preedit and commits text without the clipboard. So the field draws the ghost itself, an accept goes in together with what is left of it, and LokalBot's overlay stays closed; where no input method route exists, `support` says so and the practice editor still works. The routes are `zwp_input_method_v2` on Sway and Hyprland, an IBus engine on GNOME and `zwp_input_method_v1` on KDE Plasma; what they see, keep and do with other input methods is written down in `PRIVACY.md`, and typed text is never logged or kept past the field's next state.

Where: `LinuxWindows/crates/lokalbot-platform/src/autocomplete/input_method.rs`, `LinuxWindows/crates/lokalbot-platform/src/autocomplete/mod.rs`, `LinuxWindows/crates/lokalbot-app/src/autocomplete/mod.rs`.

### The field's owner is judged before its text is used

The input method protocols do not say who owns a field, so the compositor names the window in front and accessibility adds what it knows, asked on a thread of its own so a slow app or compositor never holds up the keyboard. Nothing is delivered until that answer is in and an app that cannot be named is ruled out, so an excluded app, a terminal or a password field never reaches the engine; the checks run in the order of what they protect, and no text is read until they pass. The same thread looks out for other input methods, since a desktop runs one at a time.

Where: `LinuxWindows/crates/lokalbot-platform/src/autocomplete/input_method/surface.rs`, `LinuxWindows/crates/lokalbot-platform/src/autocomplete/input_method.rs` (`snapshot`).

### Wayland surrounding text is cleaned before use

An app clips surrounding text to about the most `zwp_input_method_v2` carries (`SURROUNDING_LIMIT`, 4,000 bytes), so a window that full may have been clipped. Firefox, unlike most apps and the protocol, counts preedit in it, with the caret at or inside it, so a ghost is removed first: it is not the user's text. A field holding only the characters toolkits draw in place of a password's is a password field that gave no hint.

Where: `LinuxWindows/crates/lokalbot-platform/src/autocomplete/input_method.rs` (`SURROUNDING_LIMIT`, `Surrounding::without_preedit`, `Surrounding::is_masked`).

### Quiet Chromium and Electron fields are sent an empty commit

They report the text around the caret only in answer to an input method's commit, not as the user types, so a field that has gone quiet is sent an empty one now and then: the first report after a pause comes within `ASK_WHEN_IDLE`, and within `ASK_WHILE_TYPING` from then on.

Where: `LinuxWindows/crates/lokalbot-platform/src/autocomplete/input_method.rs` (`ASK_WHILE_TYPING`).

### The ghost leaves before a key goes to the field

Toolkits may commit preedit when a key arrives, so the ghost is removed first and comes back if it still applies.

Where: `LinuxWindows/crates/lokalbot-platform/src/autocomplete/input_method.rs` (`Core::blank_for_key`).

### On Sway and Hyprland the keyboard is grabbed only while a suggestion shows, and the seat is yielded

While grabbed, every key but the accept keys and Esc goes straight on through `zwp_virtual_keyboard_v1` and nothing keeps it; the thread does no blocking work, since the user's typing passes through it. A known input method starting later, or the compositor reporting that someone else holds the seat, makes this route let go at once and say why; it takes the seat again only when the other one has been gone for a while, and a session that has only just started waits a moment first, so an input method starting alongside LokalBot does not lose the seat to it.

Where: `LinuxWindows/crates/lokalbot-platform/src/autocomplete/input_method/wlroots.rs`.

### On GNOME LokalBot is an IBus engine the user chooses

GNOME has no input method protocol for ordinary apps and GNOME Shell hands every text field to IBus, so LokalBot is an IBus engine over IBus's own D-Bus, chosen as an input source next to the user's layouts; other input sources keep working and nothing reaches it unless it is chosen. While chosen it is asked about every key press in a text field, compares it to the accept keys only while a suggestion shows, and neither keeps nor logs keys. IBus finds engines through a component file read at start (packages install one; `lokalbot --ibus-component` prints it), GNOME Shell swaps engines around password fields so a stale focus-lost is ignored, and the field's content type, which IBus sends only when it changes and possibly before the focus event, is kept across fields.

Where: `LinuxWindows/crates/lokalbot-platform/src/autocomplete/input_method/ibus.rs` (`Engine::lost_focus`, `Emitter.content`).

### On KDE Plasma a helper started by KWin holds the input method connection

KWin offers `zwp_input_method_v1` only to the program it started (`lokalbot --kwin-input-method`, chosen under System Settings → Keyboard → Virtual Keyboard) and starts it again only if it crashes, so this small process holds the connection for the session, passes the active field to the app over a socket that accepts only peers running as the same user, and never exits with a crash's code so KWin does not restart it in a loop. The keyboard is taken only while the app shows a suggestion, every other key goes straight back to KWin, and with no app connected it holds no text, takes no keys and shows nothing. It maps `zwp_text_input_v1` content purposes to `zwp_text_input_v3`'s numbering (hint bits are the same), treats a deletion of [index, index + length] around the caret as applied at once, and asks again whose the field is when a text input is enabled again, since that reset may be another field; the content type that comes with most keystrokes says nothing about it.

Where: `LinuxWindows/crates/lokalbot-platform/src/autocomplete/input_method/kwin_helper.rs` (`run`, `same_user`, `content_v3`, `Helper::event`).

### On KDE Plasma the ghost is an overlay pill, never preedit

KWin passes `zwp_input_method_context_v1.preedit_string` on to apps over `zwp_text_input_v3`, which has no commit-on-reset string, and Chromium, Electron, Firefox and Thunderbird commit active preedit into the document on mousedown or blur before telling KWin the field is gone ([#562](https://github.com/stevyhacker/LokalBot/issues/562)). Clearing preedit on deactivate arrives too late, so the KWin route draws the suggestion on a click-through `zwp_input_panel_v1` overlay surface that KWin anchors under the focused field's cursor rectangle, and sends the field only an empty preedit, to make a quiet field report its text. The pill's pixels live in an anonymous `memfd`, so the helper still writes no file but its socket. GTK and native Qt discard preedit on focus loss, so a live check needs a field that commits it on blur, as the browsers do.

Where: `LinuxWindows/crates/lokalbot-platform/src/autocomplete/input_method/overlay_pill.rs`, `kwin_helper.rs` (`Helper::show`, `Helper::nudge`), `input_method.rs` (`Core::with_overlay_ghost`), `tests/live_input_method.rs` (`commit_on_blur`).

### On Sway and Hyprland the pill is an input method popup, with preedit only where the compositor places none

Sway and Hyprland pass `zwp_input_method_v2` preedit on over `zwp_text_input_v3` as KWin does, so the same browsers commit it on blur. The route draws the KDE pill on a `zwp_input_popup_surface_v2`, which the compositor places at the field's cursor rectangle. Sway before 1.10 accepts the popup but never shows it, which would leave suggestions invisible, so the popup counts as placed only once the compositor sends `text_input_rectangle`; if none arrives within `POPUP_PLACED_WITHIN` of the first suggestion, the route falls back to preedit for the session. On KDE the helper takes no keys when KWin offers no input panel, since a suggestion it cannot draw must not take Tab. The pill loads the system font database on a thread of its own when the route starts, so the first suggestion does not wait for it.

Where: `LinuxWindows/crates/lokalbot-platform/src/autocomplete/input_method/wlroots.rs` (`POPUP_PLACED_WITHIN`, `State::tick`), `overlay_pill.rs` (`OverlayPill::attach_popup`, `Fonts`), `input_method.rs` (`Core::fall_back_to_preedit`), `kwin_helper.rs` (`Helper::set_grab`).

## Consequences

- Every privacy check (grants, app and site exclusions, secure, code and private-window fields, the field's owner on Wayland) runs before any text is read and fails closed; typed text and server errors are never logged, and a withdrawn grant, edited source or changed privacy setting ends whatever it shaped, up to the accept key.
- Accept keys belong to LokalBot only while a suggestion is visible, the accept path stays bounded and constant-time, and a key it does not use goes on to the app.
- Latency depends on a stable prompt start, one request in flight and a warm model; caret and drawing workarounds are tied to measurements in named apps (TextEdit, Telegram, Chrome, Discord, Viber, Reddit), so a change there needs re-checking in those apps.
