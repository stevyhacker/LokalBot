# 0012. Models and inference

- Status: Accepted
- Date: 2026-11-20

## Context

This feature covers how LokalBot gets, runs and talks to language models: the built-in llama.cpp runtime, model downloads, the catalog and model switching, and Think requests to Ollama, OpenAI-compatible servers, Anthropic's API and the user's own ChatGPT, Claude, Antigravity or Gemini plans. The Mac app (`LokalBot/Engines`, `LokalBot/Models/ModelSetup`) and the Windows and Linux app (`LinuxWindows/crates/lokalbot-ai`, the model Settings pages in `lokalbot-app`) make the same decisions. They were moved here from code comments when the code stopped carrying comments ([ADR 0001](0001-code-carries-no-comments.md)).

## Built-in llama.cpp runtime

### Each model role runs its own loopback-only `llama-server` with a random bearer token

Think, embeddings and autocomplete each run as a separate `llama-server` subprocess on a fixed loopback port with a random bearer token that rotates on every start; a non-loopback base URL for a built-in server would be a data-exfiltration bug, not a configuration choice. A `Lease` keeps a server loaded, and after the last lease drops it lingers for the role's idle time, then stops. The on-disk marker that shares the token is mode 0600, and CLI callers check that its PID is alive, is the recorded executable and owns the expected listening port before trusting localhost.

Where: `LinuxWindows/crates/lokalbot-ai/src/runtime.rs`, `LokalBot/CLISupport/AskLibraryEngine.swift` (`LocalLlamaServerMarker`), `LokalBotTests/Engines/LlamaServerTests.swift` (`testSharedServersAreLoopbackOnlyAndOnDistinctPorts`).

### The installed app's ports never move, and Agent Mode shares the Think server

The CLI, MCP clients and `DEVELOPMENT.md` rely on the installed app's ports. Agent Mode leases the Think server from the engine's runtime, so both use one process on port 17872.

Where: `LokalBot/CLISupport/LlamaServerRole.swift` (`LlamaServerRole.releasePort`), `LinuxWindows/crates/lokalbot-engine/src/lib.rs` (`Engine::runtime`).

### Each app copy gets its own ports and helper folder, and reclaims only orphaned helpers

Every copy of LokalBot (Dev, UI Test Host, unit tests, an older release) gets its own `llama-server` ports and its own folder for helper binaries, PID markers and bearer tokens: from 2026-10-09 to 10-12 an orphaned UI Test Host embedder held 127.0.0.1:17873, the installed app's embedder could not start and meeting and screen embeddings silently stopped, and the unit-test host also wrote the installed app's PID marker. A start stops LokalBot `llama-server`s that hold its port after their app died (reparented to launchd, running from a LokalBot `llama-cpp` runtime, named by no PID marker with a live owner). It never adopts a helper a live app owns, even for the same model, because its later eviction or shutdown would interrupt that app's work.

Where: `LokalBot/CLISupport/LlamaServerRole.swift` (`LocalRuntimeOwner`), `LokalBot/Engines/LlamaServer.swift` (`LlamaServer.start`, `LlamaServer.stopOrphanedHelpers`), `LokalBotTests/Engines/LlamaServerIsolationTests.swift` (`LlamaServerIsolationTests`).

### An agent task holds the built-in model only while a turn runs

An open task on the built-in model used to keep the model server for as long as its tab stayed open, so work on any other model (a changed Think model, a separate dictation model) waited until the tab closed.

Where: `LokalBotTests/Agent/AgentSessionControllerTests.swift` (`testBuiltInModelIsHeldOnlyWhileATurnRuns`).

### The Mac shuts the in-process llama runtime down before exit

Quitting gives the runtime a real shutdown window before AppKit calls `exit()`: C++ static destructors running while Metal buffers are still resident trip ggml-metal's residency-set assertion on quit.

Where: `LokalBot/AppLifecycle.swift` (`AppDelegate.applicationShouldTerminate`).

### Windows and Linux run a pinned prebuilt llama.cpp release with an app-local Visual C++ runtime

macOS bundles a source build; the port downloads the pinned prebuilt release of ggml-org/llama.cpp once, verifies it and unpacks it into `<root>/runtimes/llama-cpp/<build>-<asset tag>/`. On Windows the bundled Visual C++ runtime is copied beside the server (Microsoft's app-local deployment), which Windows loads before any copy in System32, so the server needs no Visual C++ Redistributable and never runs against an older one; a copy that differs after an update is replaced, or at a later start if a running server holds it. The load check has to allow for a just-unpacked binary that can't run while a process forked by another thread still holds the file open from when it was written.

Where: `LinuxWindows/crates/lokalbot-ai/src/runtime.rs` (`deploy_vc_runtime`, `check_loads`).

### After an app update, the new llama.cpp build is fetched in the background

An update can move to another llama.cpp build, and every feature counts the runtime as missing until it's there; someone who had set it up shouldn't have to find that out. At launch the new build is fetched in the background, retried when that fails, and what older versions installed is removed once it's there. CUDA stays an explicit download, and built-in models run on Vulkan or CPU until then.

Where: `LinuxWindows/crates/lokalbot-engine/src/models.rs` (`Models::finish_runtime_update`).

### `llama-server` stderr keeps only crash lines after startup

Before the first healthy check every line is kept so a failed start can say why; afterwards only crash lines, since request errors can echo private text.

Where: `LinuxWindows/crates/lokalbot-ai/src/runtime.rs` (`OutputTail`).

### `waitUntilExit()` is never called after an await

An await can move the task off the launching thread, where `waitUntilExit()` could wait forever.

Where: `LokalBot/Engines/KokoroSpeechEngine.swift` (`KokoroSpeechEngine`).

## CUDA on Windows and Linux

### CUDA is opt-in and never stops built-in models from working

The `cuda` llama.cpp build is opt-in while native NVIDIA validation is pending, and auto-detection keeps picking the backend until CUDA setup succeeds, so selecting CUDA never stops working built-in models. Built-in models install a selected Vulkan or CPU build, else the automatic choice, without anyone asking; CUDA's download of up to 800 MB stays an explicit step in Settings. When setup kept complete, verified files but its final device check failed, background starts skip CUDA until explicit setup confirms one.

Where: `LinuxWindows/crates/lokalbot-core/src/settings.rs` (`Settings.llama_backend`), `LinuxWindows/crates/lokalbot-ai/src/runtime.rs` (`Installer::automatic`, `Installer::install_for_built_in_models`, `InstallRecord.cuda_unverified`).

### The CUDA 13.5 or CUDA 12 build is chosen by driver and GPU

A driver runs a build's prebuilt kernels when it supports the same CUDA major version, but compiles PTX only from a toolkit no newer than itself; CUDA 13.5 has prebuilt kernels for 8.6, 8.9 and 12.x and PTX from Turing (7.5), and the CUDA 12 builds add PTX for Maxwell, Pascal and Volta ([NVIDIA's compatibility guide](https://docs.nvidia.com/deploy/cuda-compatibility/minor-version-compatibility.html)). The driver stays system-managed, and the math libraries are reused from normal system loader paths and explicit toolkit locations, never from another application's private runtime. A real device probe, not file presence, decides whether they are usable.

Where: `LinuxWindows/crates/lokalbot-ai/src/runtime/cuda.rs` (`library_dirs`).

### CUDA repair replaces only the math libraries

The server folder may be in use by another role, particularly on Windows.

Where: `LinuxWindows/crates/lokalbot-ai/src/runtime.rs` (`Installer::repair_cuda`).

### A CUDA start reuses a healthy offloaded helper

Before creating another CUDA context, launch reuses a healthy helper that has already offloaded, since its GPU may have no free VRAM for a new probe.

Where: `LinuxWindows/crates/lokalbot-ai/src/runtime.rs` (`ServerInner::launch`).

### Server startup allows for a slow first CUDA start

Loading a large model can take a while, and on GPUs without prebuilt CUDA kernels the driver first compiles PTX, about 50 s on a Titan Xp; later starts reuse its cache.

Where: `LinuxWindows/crates/lokalbot-ai/src/runtime.rs` (`ServerInner::launch`).

### CUDA launches keep plain startup logs

llama.cpp b12359 hides offload evidence at verbosity 3.

Where: `LinuxWindows/crates/lokalbot-ai/src/runtime.rs` (`cuda_launch_args`).

## Reasoning and output budgets

### Each model uses its own default reasoning; only instant tasks turn it off

Since 2026-11-21 a Think request carries no thinking budget, only an intent: the model's default or Off. Most current models think by default, and the per-task budgets that replaced it (0 for notes, digests and personal learning; 128 to 1,024 elsewhere) made every task a tuning point while keeping those models from working the way they were trained. Instant tasks that someone waits on always send Off, whatever level is chosen: dictation Compose, selection actions, window handoff, autocomplete's chat continuation, the live Meeting Radar pass, and the CLI and MCP short answers. On Automatic every other request leaves the model at its default. A chosen level applies to every request that is not Off, clamped to what the model accepts; tasks no longer lower it. An Off request on Automatic still sends Off to a model that reasons by default and can switch it off, because on 2026-10-07 Cerebras Qwen, left at its default, spent every notes request's output on hidden reasoning. Claude models that think by default get their lowest effort for Off.

Where: `LokalBot/Engines/ReasoningLevels.swift` (`ReasoningSupport.requestLevel`, `TaskReasoning`), `LokalBot/Engines/AnthropicEngine.swift` (`AnthropicEngine.effort`), `LinuxWindows/crates/lokalbot-ai/src/think.rs` (`request_level`), `LinuxWindows/crates/lokalbot-ai/src/anthropic.rs` (`ModelTraits::effort`), `LokalBotTests/Engines/TextEngineTests.swift` (`testRequestLevelIsTheChosenLevelClampedToTheModelUnlessTheTaskIsOff`, `testInstantTasksAlwaysSkipReasoning`).

### A request that may think gets room for it on top of its answer

Thinking shares the output ceiling with the answer on llama-server, OpenAI-compatible servers, OpenRouter and Ollama. A request that may reason is sent with its answer size plus a thinking allowance: the chosen level's budget, or on Automatic the answer size capped at 8,192 tokens (High). A model whose default is known to be no thinking gets none; a model whose default is unknown may reason. On the built-in server the allowance also goes out as `thinking_budget_tokens`, so llama-server closes the thinking turn and an answer still arrives. Until 2026-11-21 thinking was squeezed into half of `max_tokens` instead. The meeting budget reserves the answer plus the allowance; a notes job whose requests may reason gets twice the time and output tokens and splits them so each part's answer stays the size it was. A notes request whose thinking room alone would not fit the context window is sent Off rather than failing.

Where: `LokalBot/Engines/ReasoningLevels.swift` (`ReasoningSupport.reasoningAllowance`), `LokalBot/Engines/TextEngine.swift` (`OpenAICompatibleEngine.applyGenerationOptions`), `LokalBot/Services/Notes/MeetingGenerationBudget.swift` (`MeetingGenerationBudget.allowance`), `LokalBot/Services/Notes/MeetingNotesGenerator.swift` (`MeetingNotesGenerator.request`), `LinuxWindows/crates/lokalbot-ai/src/think.rs` (`chat_body`).

### A reply that spends its whole output thinking is asked once more with reasoning off

A request that had thinking room, stopped at its output limit and has no visible answer is sent once more with reasoning Off. Inside a meeting budget both requests are charged. Notes' larger retry, the digest's truncation and parse retries and Dream's larger retry already run Off, so the retries don't stack.

Where: `LokalBot/Engines/TextEngine.swift` (`ReasoningExhaustedReply`, `OpenAICompatibleEngine.canRetryWithoutReasoning`, `OllamaEngine`), `LokalBot/Engines/AnthropicEngine.swift` (`AnthropicEngine.message`), `LinuxWindows/crates/lokalbot-ai/src/think.rs` (`complete_full`), `LokalBotTests/Integration/ModelServerScenarioTests.swift` (`testReplyThatSpendsItsWholeOutputThinkingIsRetriedOnceWithoutReasoning`).

### Models that don't think by default are told not to

llama-server decides thinking per request as `enable_reasoning != 0 && the template supports thinking` (llama.cpp b12359 and b12613, `server-context.cpp`), so with `--reasoning on` or `auto` every template that can think is asked to, whatever its own default; `on` also adds `enable_thinking=true` to the template's defaults. Gemma 4 and the small Qwen models, which don't think by default, therefore thought on every request, and on 2026-11-21 Qwen3.5 0.8B's notes in the runtime e2e test spent their whole output thinking with no room set aside for it. The catalog records each built-in model's default from its chat template (checked 2026-11-21): Qwen3.5 4B, Qwen3.6 35B-A3B and Qwen3.6 27B think; LFM2.5 2.6B always reasons; Qwen3.5 0.8B and 2B, Gemma 4, LFM2.5 1.2B Instruct, Granite 4.1 and Ministral 3 don't; imported models are unknown. On Automatic, a request to a model whose default is no thinking sends `enable_thinking: false`, and Agent Mode's extension does the same from the level file's `defaultOff`. A chosen level above Off sends `enable_thinking: true` only to those models, because sending both thinking controls caused HTTP 500 on LFM3 with a newer runtime (2026-10-27). The main server runs with `--reasoning auto`, which differs from `on` only in not adding that template default.

Where: `LokalBot/Engines/LlamaServer.swift` (`MainLLMRuntimePolicy.serverExtraArguments`), `LokalBot/Engines/ReasoningLevels.swift` (`ReasoningSupport.builtIn`), `LokalBot/Engines/TextEngine.swift` (`OpenAICompatibleEngine.applyGenerationOptions`), `LinuxWindows/crates/lokalbot-ai/src/think.rs` (`chat_body`), `LinuxWindows/crates/lokalbot-ai/src/runtime.rs`, `LinuxWindows/crates/lokalbot-agent/resources/lokalbot-extension/index.ts` (`applyReasoningLevel`).

### An Off request also turns off Qwen's thinking turn in the chat template

A zero thinking budget alone still opens Qwen's thinking turn in the bundled runtime and can exhaust a short reply before any visible text, so Off requests send `thinking_budget_tokens: 0` and disable that turn in the chat template too. The CLI's short grounded answers do the same: they must not spend their whole 1,024-token allowance thinking.

Where: `LokalBot/Engines/TextEngine.swift` (`OpenAICompatibleEngine.applyGenerationOptions`), `LinuxWindows/crates/lokalbot-ai/src/think.rs` (`chat_body`), `LinuxWindows/crates/lokalbot-agent/resources/lokalbot-extension/index.ts` (`applyReasoningLevel`), `LokalBot/CLISupport/AskLibraryEngine.swift` (`URLSessionLlamaChatClient.complete`).

### An Off request turns Ollama's thinking off

Ollama's thinking models think by default, and those tokens count against `num_predict`, which therefore includes the thinking room for other requests. Of the chosen levels only gpt-oss takes a graded one, and `think: true` fails on models that can't think.

Where: `LokalBot/Engines/TextEngine.swift` (`OllamaEngine.chatBody`).

### A rejected reasoning level is retried once

A chosen level can be one the selected model does not accept. When the server names reasoning in a 400 or 422, the request is retried once: `none` becomes `low` for models that always reason, and any other level falls back to the server's default. The Agent runtime's extension mirrors `OpenAICompatibleEngine.shouldRetryRejectedReasoningLevel`.

Where: `LinuxWindows/crates/lokalbot-agent/resources/lokalbot-extension/index.ts` (`retryRejectedReasoning`).

### GPT-6 reasoning levels follow OpenAI's documented per-model support

GPT-6 adds Max and defaults to Medium. Sol and Luna also take `none`; 6.1 Sol and Astra reject it, so newer models get no Off. Astra documents no default (OpenAI's model pages, 26 October 2026).

Where: `LokalBot/Engines/ReasoningLevels.swift` (`ReasoningSupport.openAI`), `LinuxWindows/crates/lokalbot-ai/src/think.rs` (`ReasoningSupport::openai`).

### The Main LLM runs a 32K context with an 8K thinking cap

The bundled models expose much larger native windows, but 32K gives summaries and Agent Mode useful headroom without the latency and linear KV-cache cost of 128K. App-authored requests cap thinking at 8K (High), on top of the answer, and Agent Mode uses the same server with its model-native budget.

Where: `LokalBot/Engines/LlamaServer.swift` (`MainLLMRuntimePolicy`).

### Models that reason anyway get output room for thinking and the answer

Thinking shares `max_tokens` with the answer, so a Claude model that thinks by default gets room for both. `z-ai/glm-5.3-flash` always reasons: on 2026-10-15 its 32-token reply ended inside the reasoning and autocomplete showed only an error, so such a model is asked with room for it from then on. The day digest's focus extraction keeps headroom far beyond what its compact JSON needs, because routed reasoning models can spend most of a small budget thinking even when asked not to; llama-server keeps its own thinking budget independent of that cap.

Where: `LinuxWindows/crates/lokalbot-ai/src/anthropic.rs` (`ModelTraits::max_tokens`), `LokalBotTests/Services/Chat/ChatContinuationEngineTests.swift` (`testAModelThatAlwaysReasonsIsAskedWithRoomForItFromThenOn`), `LokalBot/Services/Timeline/DayDigestEvidence.swift` (`DayDigestOverviewGenerator.focusTokens`).

### Structured notes calls get one larger, bounded retry

Reasoning providers count hidden tokens against the same completion ceiling as the JSON envelope, so a 4K request can spend the whole response thinking and return no usable records. Every structured call gets one larger, budgeted retry, with reasoning off, before partial content goes to the evidence validator. The retry is bounded so a genuinely huge response still falls through to checkpointed recovery instead of consuming the job.

Where: `LokalBot/Services/Notes/MeetingNotesGenerator.swift` (`MeetingNotesGenerator.request`).

### Dream's output allowance is capped

Visible replies for the retrospective plus memory update run about 1–2K tokens; without a cap a reasoning model on a remote server spent 4–27K hidden tokens and up to eight minutes per day. Dream asks for 4,096 answer tokens, so with its thinking room a request is at most 8,192; a reply cut off at that limit is asked once more with 6,144 answer tokens and reasoning off.

Where: `LokalBot/Services/Dreaming/DreamService.swift` (`DreamService.maxOutputTokens`).

### A token budget cut that would truncate a shipped preset fails in tests

The guard fails before release when a budget cut would truncate a model LokalBot ships presets for. This happened twice (e5077c3, then #117).

Where: `LokalBotTests/Engines/ModelBudgetGuardTests.swift` (`ModelBudgetGuardTests`).

## Request shape and provider quirks

### Request bodies are serialized with sorted keys

Grammar-constrained servers generate schema properties in wire order, and Swift dictionaries hash in a per-launch order, so unsorted, the same request could ask for a verdict before its evidence on one launch and after it on the next. Sorted keys also keep the schema's bytes, the compiled grammar and Anthropic's cached prefix stable.

Where: `LokalBot/Engines/TextEngine.swift` (`OpenAICompatibleEngine.makeChatRequest`), `LinuxWindows/crates/lokalbot-ai/src/json.rs` (`sort_keys`), `LinuxWindows/crates/lokalbot-ai/src/anthropic.rs` (`Engine::body`).

### Temperature is sent only where the server accepts it

Current Claude models reject non-default sampling, so Anthropic requests never carry temperature. Sampling controls vary across routed reasoning providers: OpenAI-compatible requests keep temperature only when they leave reasoning at the model default or explicitly disable it, and omit it under effort compatibility, which is always-on thinking.

Where: `LokalBot/Engines/AnthropicEngine.swift` (`AnthropicEngine.effort`), `LinuxWindows/crates/lokalbot-ai/src/anthropic.rs` (`Engine::body`), `LokalBotTests/Engines/AnthropicEngineTests.swift` (`testRequestUsesMessagesAPIWithCacheBreakpointsAfterSharedMaterial`), `LokalBot/Engines/TextEngine.swift` (`OpenAICompatibleEngine.applyGenerationOptions`).

### Hosted servers get structured-output enums of at most 500 values

Cerebras rejected a 709-value notes schema on 2026-10-07 ("cannot exceed 500"); OpenAI documents 1,000. OpenRouter and other hosted servers route to providers with unknown limits and get the smaller one. Servers on this Mac compile the schema to a grammar.

Where: `LokalBot/Engines/TextEngine.swift` (`OpenAICompatibleEngine.structuredOutputEnumLimit`).

### Ollama always gets a pinned `num_ctx`

Notes and digests are planned for this window. Without `num_ctx`, Ollama uses its own default (4K on most Macs) and silently drops the start of a longer prompt, which is where the instructions are.

Where: `LokalBot/Engines/TextEngine.swift` (`OllamaEngine.chatBody`), `LinuxWindows/crates/lokalbot-ai/src/think.rs` (`OLLAMA_CONTEXT_TOKENS`).

### `api.anthropic.com` is reached through the native Messages API

When the OpenAI-compatible Think connection's URL names `api.anthropic.com`, Think speaks `POST /v1/messages`: Anthropic's OpenAI compatibility layer rejected LokalBot's notes schemas ("For 'array' type, property 'maxItems' is not supported", 2026-10-08) and has no prompt caching. Anthropic's structured outputs accept a JSON Schema subset, so, like the official SDKs, each unsupported constraint moves into the field's description, where the model still reads it, instead of failing the request with a 400. LokalBot's parsers keep enforcing the real limits.

Where: `LokalBot/Engines/AnthropicEngine.swift` (`AnthropicAPI`), `LinuxWindows/crates/lokalbot-ai/src/anthropic.rs`, `LinuxWindows/crates/lokalbot-ai/src/anthropic.rs` (`adapt_schema`), `LokalBotTests/Engines/AnthropicEngineTests.swift` (`testMeetingNotesSchemaFitsAnthropicsSubset`).

### Anthropic prompts put shared material first, behind cache breakpoints

The system prompt and the shared context (a meeting's transcript, a chat's history) carry cache breakpoints and the varying instruction comes last, so the next request over the same material reads the prefix from Anthropic's 5-minute prompt cache instead of paying the full input price again.

Where: `LokalBot/Engines/AnthropicEngine.swift` (`AnthropicEngine`), `LinuxWindows/crates/lokalbot-ai/src/anthropic.rs`.

### OpenRouter context windows come from the last live answer, else a verified table

The live lookup's last answer is kept, so a failed lookup cannot change a meeting's part plan and discard its partial notes. Until the lookup has ever answered, the smallest context window OpenRouter advertised across every endpoint of the model (`/api/v1/models/<id>/endpoints`; 1 October 2026, and 7 October for Qwen3.8 27B and GPT-5.6 Luna) is used, for exact ids only, since variants such as `:free` route to other endpoints. The window also sets the notes part size (`notesPartTokens`).

Where: `LokalBot/Services/Notes/MeetingSummaryGenerator.swift` (`MeetingSummaryGenerator.verifiedOpenRouterContextTokens`), `LokalBot/Engines/OpenRouterModelCatalog.swift` (`OpenRouterModelCatalog`).

### Model metadata lookups carry no key or content and never block drawing

Context windows and reasoning levels (OpenRouter's model list, Ollama's capabilities) are read only from origins already allowed for inference, with the model id in the path and no API key or meeting content; callers check that the origin is allowed. On Windows and Linux callers that arrive during a read of OpenRouter's list wait for it, while the list itself has its own lock held only to look at it, because the interface asks for the cached list while drawing and must never wait for the network.

Where: `LokalBot/Engines/OpenRouterModelCatalog.swift` (`OpenRouterModelCatalog`), `LinuxWindows/crates/lokalbot-ai/src/reasoning_lookup.rs`, `LinuxWindows/crates/lokalbot-ai/src/reasoning_lookup.rs` (`OPENROUTER_READ`).

### A changed system prompt is folded into the leading message

Small local models' chat templates reject a system message after the first, so Pi folds a changed prompt into the leading one.

Where: `LinuxWindows/crates/lokalbot-agent/resources/tests/pi-runtime.test.ts` (`piTurn`).

### The port's prompts are verbatim copies of the Mac's

Every prompt the generators send is copied verbatim from the macOS app (`Services/Notes/PromptTemplates.swift` unless noted); only "Mac" becomes "PC".

Where: `LinuxWindows/crates/lokalbot-ai/src/prompts.rs`.

## Subscription plans

### A plan is used only after its own consent, never through an API approval

Think can run on the user's own ChatGPT, Claude, Antigravity or Gemini plan instead of an API key, and requests count toward that plan's usage limits. Each plan has its own entry in the approved-origins list that is not a URL origin, so approving an API server (`https://api.openai.com` with a key) never approves plan usage, and the reverse: the two run under different provider terms. Signing in, approval and the model are separate steps: a sign-in alone never lets context leave the computer, and the Mac's sheet applies the model and approval only when the user chooses Use model.

Where: `LokalBot/Engines/Subscription/SubscriptionPlan.swift` (`SubscriptionPlan`), `LinuxWindows/crates/lokalbot-core/src/settings.rs` (`SubscriptionPlan`), `LinuxWindows/crates/lokalbot-ai/src/plans/mod.rs`, `LinuxWindows/crates/lokalbot-app/src/pages/ask/composer.rs` (`inference`), `LinuxWindows/crates/lokalbot-app/src/pages/settings/models.rs` (`SettingsPage.connections`), `LinuxWindows/crates/lokalbot-app/src/pages/settings/plans.rs`, `LokalBot/Views/ModelSetup/SubscriptionPlanSetupView.swift` (`SubscriptionPlanSetupView`).

### Plan errors never fall back

A plan error stops the request; nothing falls back to another provider or billing path.

Where: `LinuxWindows/crates/lokalbot-ai/src/plans/mod.rs`, `LokalBot/Engines/Subscription/ChatGPTPlanEngine.swift` (`ChatGPTPlanEngine`).

### CLI plans sign in through the provider's own tool, and LokalBot never touches those credentials

The user signs in to Claude Code (`claude`, then `/login`), Gemini CLI (`gemini`) or Antigravity CLI (`agy`) through the provider's own flow. LokalBot never reads, stores or forwards those credentials or `~/.gemini/` files, and never offers a login of its own for them.

Where: `LinuxWindows/crates/lokalbot-ai/src/plans/claude.rs`, `LinuxWindows/crates/lokalbot-ai/src/plans/gemini.rs`, `LinuxWindows/crates/lokalbot-ai/src/plans/antigravity.rs`.

### Plan content and schemas go over stdin or private files, never the command line

A command line can be read by every process of the same user, and a schema can hold meeting text (the notes repair lists the meeting's action items as allowed values). Prompts and context go over stdin; Claude Code reads a structured request's schema from its stream-json input, Antigravity from a private temporary file (`--json-schema schema.json`), and Gemini its system prompt from a private file (`GEMINI_SYSTEM_MD`). The Claude flags are copied from the Mac and contain nothing the caller supplies.

Where: `LokalBot/Engines/Subscription/ClaudePlanEngine.swift` (`ClaudePlanEngine.arguments`), `LinuxWindows/crates/lokalbot-ai/src/plans/claude.rs` (`arguments`), `LokalBotTests/Engines/Subscription/ClaudePlanEngineTests.swift` (`ClaudePlanEngine.arguments`), `LokalBot/Engines/Subscription/AntigravityPlanEngine.swift` (`AntigravityPlanEngine`), `LinuxWindows/crates/lokalbot-ai/src/plans/antigravity.rs`, `LokalBot/Engines/Subscription/GeminiPlanEngine.swift` (`GeminiPlanEngine`), `LinuxWindows/crates/lokalbot-ai/src/plans/gemini.rs`.

### Claude Code runs in an empty folder with everything off and no session persistence

Each request runs `claude -p` in an empty private folder with tools, MCP servers, slash commands, settings files and customizations off, and without session persistence, so the prompt is never written to `~/.claude/projects`, which LokalBot itself reads as coding-agent evidence. `--bare` is never used: it ignores the subscription sign-in. The child gets LokalBot's environment minus `CLAUDECODE` (started from inside a Claude Code session it would otherwise refuse to run as a nested session) with the executable's folder first on PATH, and `--verbose`, without which Claude Code refuses stream-json output.

Where: `LokalBot/Engines/Subscription/ClaudePlanEngine.swift` (`ClaudePlanEngine`), `LinuxWindows/crates/lokalbot-ai/src/plans/claude.rs` (`Launch::command`, `arguments`).

### Antigravity runs behind three tool-isolation layers

Each `agy` request runs in a fresh private temporary directory with three defense-in-depth layers: a workspace agent (`.agents/agents/lokalbot-think.md`) whose tools are restricted to `finish`, stripping shell, file, web, browser and subagent tools, and whose body carries the system prompt; session-only `--settings settings.json` with `toolPermission: "strict"`, `allowNonWorkspaceAccess: false`, `disableSlashCommands: true` and deny rules for commands, files, URLs and MCP; and a `PreToolUse` hook (`.agents/hooks.json`) whose RE2 matcher denies every tool call except `finish`, which `--json-schema` uses internally to return structured output. Content travels over stdin (`--input-format stream-json`).

Where: `LokalBot/Engines/Subscription/AntigravityPlanEngine.swift` (`AntigravityPlanEngine`), `LinuxWindows/crates/lokalbot-ai/src/plans/antigravity.rs`.

### Gemini CLI runs under a deny-all policy

Each `gemini -p ""` request runs in a fresh private temporary directory with `--admin-policy deny-all.toml` (a tier-5 policy denying every tool call), `--extensions none`, and `GEMINI_CLI_SYSTEM_SETTINGS_PATH` turning tools, MCP servers, hooks, skills and telemetry off while keeping the user's own auth settings. The port also passes `--skip-trust` and `GEMINI_CLI_TRUST_WORKSPACE=true`.

Where: `LokalBot/Engines/Subscription/GeminiPlanEngine.swift` (`GeminiPlanEngine`), `LinuxWindows/crates/lokalbot-ai/src/plans/gemini.rs`.

### Writes to a plan CLI's stdin fail with EPIPE instead of raising SIGPIPE

A child that exits early closes its end, and SIGPIPE would end LokalBot.

Where: `LokalBot/Engines/Subscription/PlanCLIProcess.swift` (`PlanCLIProcess.run`).

### ChatGPT sign-in uses OpenAI's token sharing and keeps secrets only in the credential store

Sign-in is OpenAI's Sign in with ChatGPT for open-source apps: the first sign-in registers this LokalBot as a client (`dynamic_agent_client`), OpenAI returns the issued client id in the callback, and later sign-ins and refreshes use it, with no client secret or API key. The browser returns to a listener on 127.0.0.1 that accepts only that redirect, the code is exchanged with PKCE, and the ID token is checked against OpenAI's published keys. Tokens, the registration and a random per-computer id live only in the system credential store; without one, sign-in fails before the browser opens.

Where: `LinuxWindows/crates/lokalbot-ai/src/plans/chatgpt.rs`.

### ChatGPT callbacks validate `state` first, and account traffic stays on OpenAI's hosts

`state` is checked before anything else, so a forged request from another local process can neither complete nor cancel a sign-in. Only OpenAI's own hosts may serve its signing keys or revoke its tokens, and account requests never follow a redirect away from those fixed hosts.

Where: `LokalBot/Engines/Subscription/ChatGPTPlanOAuth.swift` (`ChatGPTPlanOAuth.parseCallback`), `LinuxWindows/crates/lokalbot-ai/src/plans/chatgpt.rs` (`parse_callback`, `Endpoints::trusted`), `LokalBot/Engines/Subscription/ChatGPTPlanAccount.swift` (`ChatGPTPlanAccount.liveTransport`).

### The client registration is recorded before the token exchange

A failed exchange then never strands a client OpenAI already issued.

Where: `LokalBot/Engines/Subscription/ChatGPTPlanAccount.swift` (`ChatGPTPlanAccount.signIn`), `LinuxWindows/crates/lokalbot-ai/src/plans/chatgpt.rs` (`Account::sign_in_with`).

### One shared account instance serializes token refreshes

Two requests then never race a rotating refresh token.

Where: `LokalBot/Engines/Subscription/ChatGPTPlanAccount.swift` (`ChatGPTPlanAccount`), `LinuxWindows/crates/lokalbot-ai/src/plans/chatgpt.rs` (`Account`).

### Credential writes are read back, and long tokens are split across items

A store that silently drops secrets must not look signed in, so every write is read back. Windows Credential Manager keeps at most 1,280 characters per item, less than one session's tokens, so long values are split across several items, the first naming how many parts follow.

Where: `LinuxWindows/crates/lokalbot-ai/src/plans/chatgpt.rs` (`Account::write`, `Chunked`).

### ChatGPT Think requests use the Responses API without sampling fields or system messages

The token-sharing route requires `store: false` and `stream: true` on every request and rejects sampling and output-cap fields, so neither temperature nor `max_output_tokens` is ever sent. It also rejects system messages, so the system prompt goes in `instructions`, the documented replacement. Agent Mode reaches the same API through `relay`, which holds the tokens for the agent runtime.

Where: `LokalBot/Engines/Subscription/ChatGPTPlanEngine.swift` (`ChatGPTPlanEngine`), `LinuxWindows/crates/lokalbot-ai/src/plans/chatgpt.rs`, `LinuxWindows/crates/lokalbot-ai/src/plans/chatgpt.rs` (`Engine::body`).

## Remote servers: approval, privacy and admission

### Remote Think servers need exact-origin approval and HTTPS

Ollama and OpenAI-compatible servers on another machine are refused until the user approves their exact origin. Only loopback may use plain HTTP for Think, Agent Mode or Dream: an approved server on the user's own network still needs HTTPS, unlike autocomplete and transcription, which opt in to private-network HTTP with their own checks. Scheduled digest and overnight runs need the same approval as manual requests (on-device backends, loopback or an approved origin), and AI actions on selected text run on the Think model so remote inference keeps its per-origin approval.

Where: `LinuxWindows/crates/lokalbot-ai/src/think.rs`, `LinuxWindows/crates/lokalbot-core/src/access.rs` (`remote_block_reason`), `LinuxWindows/crates/lokalbot-ai/src/think.rs` (`allows_automatic_main_inference`), `LokalBot/AppState.swift` (`AppState.selectionActions`).

### Origins are parsed strictly

An authority with credentials, a backslash, whitespace or a control character is rejected: WHATWG parsers (the Agent runtime's `new URL`) end the host at `\`, so `https://evil.example\@localhost` would pass as loopback while the request went to `evil.example`. `0.0.0.0` is deliberately not loopback: it is the unspecified address, and local servers should use localhost or 127.0.0.1, where a 0.0.0.0-bound server also listens. The Mac renders the authority directly because `URLComponents.host` rejects a bare IPv6 literal such as `::1` that `URL.host` returns, so loopback and approved IPv6 origins stay canonical.

Where: `LinuxWindows/crates/lokalbot-core/src/access.rs` (`origin_of`), `LokalBot/Models/ModelSetup/InferenceEndpointPolicy.swift` (`InferenceEndpointPolicy.isLoopback`, `InferenceEndpointPolicy.origin`).

### Redirects never leave the authorized origin

The engine entry point authorizes its configured origin. A redirect may change a path on that origin but cannot carry prompts or credentials to another server, including a different loopback port.

Where: `LokalBot/Engines/InferenceURLSession.swift` (`InferenceURLSession`).

### The port's HTTP agent bypasses proxies for loopback and never logs header values

Loopback servers bypass any proxy from the environment, while remote ones honour it, and status codes are returned rather than raised. Header values such as Anthropic's `x-api-key` or a plan's bearer token are never logged.

Where: `LinuxWindows/crates/lokalbot-ai/src/http.rs` (`agent`, `post_json_with`).

### Approvals are per origin and per purpose

An approval belongs to one origin, so a newly entered server shows its own saved choice. Saving a transcription server's key and audio approval replaces the approval list as a whole, so unchecking revokes the origin, and revoking a server's audio approval leaves a Think approval for the same server in place.

Where: `LinuxWindows/crates/lokalbot-app/src/pages/settings/writing_server.rs` (`ServerDraft::subscribe`), `LinuxWindows/crates/lokalbot-app/src/pages/settings/model_options.rs` (`SettingsPage.use_transcription_server`), `LokalBot/Views/ModelSetup/ModelPickerSheet.swift` (`ModelPickerSheet.applyRemoteTranscriptionAccess`), `LinuxWindows/crates/lokalbot-app/src/pages/settings/models.rs` (`revoke_audio_origin`).

### Think's API key is reused for transcription only on the same origin

When no key is saved for the transcription server and it is the same origin as Think's OpenAI-compatible connection, that connection's key is sent, so one OpenAI or OpenRouter key serves both. It is never sent to another origin.

Where: `LokalBot/Models/Settings/AppSettings.swift` (`AppSettings.remoteTranscriptionRequestKey`), `LinuxWindows/crates/lokalbot-core/src/remote_transcription.rs` (`request_key`).

### The privacy summary names every remote AI host, autocomplete included

It lists Think's server (while its connection is allowed), the transcription server and, while autocomplete is on, the server it sends typing to, each named once. Leaving autocomplete out once read "AI: on this Mac" while every suggestion request went to a server. A server on this computer's own address counts as this computer: nothing leaves it.

Where: `LokalBot/Models/ModelSetup/InferencePresentation.swift` (`AppSettings.remoteAIHosts`), `LinuxWindows/crates/lokalbot-app/src/state.rs` (`remote_ai_hosts`), `LinuxWindows/crates/lokalbot-app/src/pages/settings/model_overview.rs` (`place`).

### OpenRouter uses private routing unless the user opts in to the account's policy

The per-request provider policy for Think and Autocomplete stays on private routing by default; following the account's policy is an explicit opt-in (`openRouterDataPolicy`).

Where: `LinuxWindows/crates/lokalbot-core/src/settings.rs` (`Settings.open_router_data_policy`), `LinuxWindows/crates/lokalbot-app/src/pages/settings/plans.rs`.

### Meta models are used only in their standard variants

Contributor variants trade a discount for Meta's right to train on the content, which meeting text must never grant.

Where: `LokalBot/Engines/MetaModelAPI.swift` (`MetaModelAPI.Model`).

### One per-origin gate admits every remote request

Every external Think and autocomplete request waits for a slot from one in-process gate keyed by origin; the built-in runtime has its own leases and never comes here. Processing work (meeting notes, digests, Dream, briefs) runs at most `maximumConcurrent` requests at once and background work at most `maximumBackground` of them, so scheduled digests or Dream can't take the slot meeting notes need, and someone waiting on the answer (chat, dictation, an agent) is never queued behind processing work. Waiters are admitted in priority order, first come first served within a priority, and a blocked background waiter never holds back one that could start. After a rate limit nothing starts until the origin's cooldown has passed, instead of each caller trying again a second later.

Where: `LokalBot/Engines/RemoteInferenceGate.swift` (`RemoteRequestQueue`), `LinuxWindows/crates/lokalbot-ai/src/remote_gate.rs`.

### Transient remote failures are replayed once, never on top of a local replay and never for streams

Remote providers intermittently answer 429/5xx or drop the connection, so the day digest replays that one request after the shared policy delay instead of losing the rest of the day. Built-in requests already get one managed server relaunch and replay inside `LeasedTextEngine`, so the provider retry is never stacked on it. A streamed request is never replayed, because it could repeat text already shown.

Where: `LokalBot/Services/Timeline/DayDigestEvidence.swift` (`DayDigestOverviewGenerator.generateReplayingTransientFailure`), `LokalBot/Engines/ThinkExecution.swift` (`ThinkExecution.retryDelay`), `LinuxWindows/crates/lokalbot-ai/src/remote_gate.rs` (`Gate::once`).

## Model downloads

### Every download is verified before it is installed

A download streams into `<dest>.part`, is checked against its pinned size and SHA-256 (and GGUF magic for `.gguf`), then renamed into place with a `<dest>.sha256` sidecar so later launches skip re-hashing. Uninstalling a model deletes its sidecar too, since one left behind would vouch for whatever file is later put at that path. Plaintext sources are refused: every source today (catalog, HF Browse) is HTTPS, refusing plaintext keeps a tampered download from ever reaching the digest check, and non-HF custom URLs stay on the same encrypted footing.

Where: `LinuxWindows/crates/lokalbot-ai/src/download.rs`, `LinuxWindows/crates/lokalbot-engine/src/models.rs` (`Models::uninstall`), `LokalBot/Engines/ModelDownloadManager.swift` (`ModelDownloadManager.sourceRefusal`).

### Model files are pinned to commit SHAs and LFS digests

A revision must be a 40-character Git commit SHA: branches and tags are mutable, so accepting one would make the persisted checksums describe a different artifact once the ref moved. A Hugging Face file URL carries its LFS SHA-256 as a URL fragment, which is never sent to the server; `ModelDownloadManager` consumes it before building its network URL, so the UI carries the digest without a parallel mutable lookup table.

Where: `LokalBot/Models/ModelSetup/GraniteSpeechModelConfiguration.swift` (`GraniteSpeechModelConfiguration.isValidRevision`), `LokalBot/Services/HuggingFace/HuggingFaceAPIClient.swift` (`HFFile.downloadURL`).

### Large files download as parallel ranges, each byte written to disk once

One `URLSessionDownloadTask` can sit well below the available bandwidth on fast links, and Hugging Face's CDN supports `Accept-Ranges: bytes`, so files of 256 MiB and more arrive as 64 MiB ranges over up to six connections; smaller files, or servers that can't do ranges, use a single streamed GET. Each range streams straight into the partial file at its own offset: landing it in a download task's temp file and copying it into place wrote every byte twice, half of the 137 GB a 0.10.8 build wrote on 2026-10-14, and macOS flags an app once it dirties gigabytes of file-backed memory a day.

Where: `LokalBot/Engines/ParallelRangeDownloader.swift` (`ParallelRangeDownloader`), `LinuxWindows/crates/lokalbot-ai/src/download.rs`, `LokalBotTests/Engines/ParallelRangeDownloaderTests.swift` (`testRangedDownloadWritesEachByteToDiskOnce`).

### Interrupted downloads resume only from a matching stash

The partial file and a manifest of finished ranges (`<dest>.part.json` on the port) live at a stable per-URL path, so a failed, cancelled or app-quit download resumes instead of re-fetching 17 GB from byte zero; the Mac takes a `stashDirectory` to keep that state somewhere durable, since macOS can reap the temp default between runs. A stash is reused only for the same URL, size, part size and (on the port) server validator, so a changed upstream file is never stitched together from two versions. When checking free space, only a `.part` file's allocated blocks count, because `set_len` gives it its full length before any byte arrives and most Unix filesystems store that as a hole.

Where: `LokalBot/Engines/ParallelRangeDownloader.swift` (`ParallelRangeDownloader`, `ParallelRangeDownloader.ResumeState`), `LinuxWindows/crates/lokalbot-ai/src/download.rs` (`download_ranged`, `stashed_bytes`).

### A range answered with 200 is never written as a range

A server that ignores `Range` answers 200 with the whole file, and writing that at a part's offset would corrupt the partial file.

Where: `LokalBot/Engines/ParallelRangeDownloader.swift` (`RangeWriter.urlSession(didReceive response)`), `LinuxWindows/crates/lokalbot-ai/src/download.rs` (`fetch_part`).

### The port opens a new connection for every download request

ureq would send the GET down the connection that answered the HEAD probe even when an HTTP/1.0 server (`python -m http.server` for a dry-run update feed) closes it after one response, failing the download with "Peer disconnected".

Where: `LinuxWindows/crates/lokalbot-ai/src/download.rs` (`agent`).

### Archive extraction fails on any entry that escapes the destination

`.zip`, `.tar.gz`/`.tgz`, `.tar.bz2`/`.tbz2` and `.tar` archives are extracted into `dest`; an absolute path, `..` or a link pointing out fails the whole extraction.

Where: `LinuxWindows/crates/lokalbot-ai/src/download.rs` (`extract_archive`).

### Mirrors can make a download fail but never change a model

huggingface.co is blocked in mainland China, so two opt-in sources serve the same files: HF-Mirror (hf-mirror.com), a community mirror with Hugging Face's paths, and ModelScope (modelscope.cn), Alibaba's model hub. Only `https://huggingface.co/<owner>/<repo>/resolve/<revision>/<path>` URLs are rerouted; the Hugging Face API, GitHub archives and other hosts are untouched, and stored URLs keep their Hugging Face host so the pinning policy still applies. The chosen mirror is tried first and each later source is a fallback; a mirror's file is accepted only when it matches the pinned size and SHA-256, and callers verify every file again. The first download offers the mirrors on a computer set to that region or to Simplified Chinese, or once a mirror is already chosen, and Settings → Models always has the same picker.

Where: `LokalBot/Models/ModelSetup/ModelDownloadSource.swift` (`ModelDownloadSource`), `LokalBot/Engines/ModelDownloadRouting.swift` (`ModelDownloadRouting`), `LinuxWindows/crates/lokalbot-ai/src/download_source.rs`, `LokalBotTests/Engines/ModelDownloadRoutingTests.swift` (`ModelDownloadRoutingTests`), `LokalBot/Views/Onboarding/OnboardingDownloadStep.swift` (`OnboardingDownloadStep.showsDownloadSource`), `LinuxWindows/crates/lokalbot-app/src/windows/onboarding/download.rs` (`shows_download_source`).

### Hugging Face search always goes to huggingface.co, most downloaded first

Search goes to huggingface.co whichever download source is chosen. `direction=-1` is required: `sort=downloads` alone returns the least popular first, so popular repositories would never surface.

Where: `LinuxWindows/crates/lokalbot-app/src/pages/settings/model_browse.rs`, `LokalBot/Services/HuggingFace/HuggingFaceAPIClient.swift` (`HuggingFaceAPIClient.searchModels`), `LinuxWindows/crates/lokalbot-ai/src/hugging_face.rs` (`search_url`).

## Model catalog, switching and readiness

### Both apps share one catalog's pins and custom-model records

The Windows and Linux catalog's files, revisions, sizes and SHA-256 digests are the macOS pins, so a library moved between platforms reuses its `models/` folder. Adding a model from Hugging Face only edits `customBuiltInModels`; the model then appears in Think's and Autocomplete's choices and downloads when chosen, and both apps read the record as a catalog entry. A record with no digest or size still parses and its download is refused with the Mac's message, and a file name that isn't a plain name can't reach the models folder.

Where: `LinuxWindows/crates/lokalbot-ai/src/catalog.rs`, `LinuxWindows/crates/lokalbot-ai/src/catalog.rs` (`custom_entry`), `LinuxWindows/crates/lokalbot-app/src/pages/settings/model_browse.rs`, `LinuxWindows/crates/lokalbot-app/src/pages/settings/model_browse.rs` (`an_added_file_becomes_a_usable_model`).

### Granite Speech accepts only an integrity-pinned audio GGUF with its projector

Generic ASR checkpoints are excluded: LokalBot's Granite path requires llama.cpp's audio-capable GGUF format.

Where: `LokalBot/Views/ModelSetup/GraniteSpeechModelPicker.swift` (`GraniteSpeechModelPicker`).

### An unused LFM2.5 autocomplete default moves to Gemma 4 E2B once

Through 0.12.3 the port saved LFM2.5 1.2B as everyone's Autocomplete model, though the Mac and the catalog recommend Gemma 4 E2B, and setup and turning autocomplete on both downloaded it, so neither the saved setting nor a downloaded file is a real choice. At launch, settings that hold it while autocomplete is off, and Think isn't the Lightweight preset's, move to Gemma 4 E2B; with autocomplete on, LFM2.5 stays, and a downloaded LFM2.5 file stays on disk, listed as unused in Model Storage. The migration runs once per library, so choosing LFM2.5 afterwards sticks.

Where: `LinuxWindows/crates/lokalbot-ai/src/catalog.rs` (`adopt_default_autocomplete`).

### Presets leave Autocomplete's model alone

A preset sets the Transcribe and Think models only: Autocomplete's lighter default suits suggestions on a CPU, and a preset should not swap it unasked.

Where: `LinuxWindows/crates/lokalbot-app/src/pages/settings/models.rs` (`Preset.models`).

### The suggested preset fits a model's file size plus 30% within 60% of memory

A model needs its file size plus about 30% resident, and that must fit within 60% of memory.

Where: `LinuxWindows/crates/lokalbot-app/src/control/handler.rs` (`suggested_preset`).

### A model switch prepares the replacement first and applies a narrow patch

The replacement is prepared first and settings change only once it is ready, so the current models stay active until then; the patch never overwrites privacy choices, credentials or unrelated edits made during a download. Server approval is checked again at the end, because it can be revoked while the downloads run, and activation is refused if a custom model's files or a server changed during preparation, since ids alone don't identify them. Undo goes through the same preparation, because the old files may have been removed since the switch.

Where: `LinuxWindows/crates/lokalbot-app/src/pages/settings/model_setup.rs`, `LinuxWindows/crates/lokalbot-app/src/pages/settings/model_setup.rs` (`ModelPatch`, `ModelPatch.blocked_reason`, `ModelPatch.preparation_context_matches`, `ModelSetup.undo`).

### Automatic work never triggers a model download

Automatic jobs (auto-transcribe after a recording, launch crash-resume), prewarm and the scheduled day digest check that their model is on disk first, because a missing model means a multi-gigabyte download the user never asked for at that moment. Jobs park as `.waitingForModels` without burning auto-resume attempts, and the digest waits until the Think model is on disk or a remote backend is configured. User-initiated jobs (Retry, the Process menu, `--process`) download missing models on demand, because the user just asked for exactly that.

Where: `LokalBot/Services/Meetings/ProcessingPipeline.swift` (`ProcessingPipeline.JobOrigin`), `LokalBotTests/Services/Meetings/ProcessingPipelineAutomationGateTests.swift` (`ProcessingPipelineAutomationGateTests`), `LokalBot/Models/ModelSetup/ModelReadinessSnapshot.swift` (`ModelReadinessSnapshot.transcriptionReady`), `LokalBot/AppState.swift` (`AppState.applyDayDigestSetting`).

### Cancelling a download never activates the model or races a second install

Some backends finish their file writes after cancellation, and that completion must not turn a cancelled download into an activation. An embedding model's preparation flight stays alive after its waiters leave, since cancellation isn't instantaneous and a later caller should rejoin it instead of racing a second install against a still-unwinding first.

Where: `LokalBot/Models/ModelSetup/ModelRoles.swift` (`ModelRoles.ensureTranscriptionAvailable`), `LokalBot/Services/Search/EmbeddingIndex.swift` (`EmbeddingModelPreparationCoordinator.cancel`).

### AppState relays model readiness changes, not progress ticks

Relaying every progress tick (up to 5 Hz per download) re-rendered every window for the whole of a multi-gigabyte download, so AppState relays only what is downloading, preparing, failed or ready, and views that draw progress observe the roles directly. The model-role publisher fires before the roles hold their new state.

Where: `LokalBot/Models/ModelSetup/ModelRoles.swift` (`ModelRoles.readinessChanges`), `LokalBot/AppState.swift` (`AppState.init`).

### Only local models are checked automatically, and never while recording

A model that just finished downloading is checked without being asked only when it runs on this Mac and no meeting is recording. A check of an online model sends it a sample, which only the Check sheet's own button may do.

Where: `LokalBot/Services/ModelSetup/ModelCheckController.swift` (`ModelCheckController.readinessChanged`), `LokalBotTests/Models/ModelSetup/ModelsPagePresentationTests.swift` (`testAModelThatRunsOnlineIsNeverCheckedByItself`).

### Apple Intelligence is reached only through `FoundationModelAvailability`

FoundationModels ships only in the macOS 26 SDK while LokalBot deploys to macOS 15.0, so every framework reference sits behind `#if canImport(FoundationModels)` and `if #available(macOS 26.0, *)`. Views and engines ask this type instead of touching FoundationModels symbols, and on older systems `current()` reports the supported-OS requirement.

Where: `LokalBot/Services/ModelSetup/FoundationModelAvailability.swift` (`FoundationModelAvailability`).

## Consequences

- Anything new that sends text, audio or a sample to a server (a provider, a metadata lookup, a background job) goes through exact-origin approval, the per-origin gate and the privacy summary's host list; subscription plans keep their own approval entries and never fall back.
- Reasoning spends the same output allowance as the answer: a new provider or budget change has to be checked with zero-budget notes and digests, and the Qwen chat-template switch, the enum limit and `ModelBudgetGuardTests` must keep holding.
- Every model file stays pinned by commit, size and SHA-256 in both apps' catalogs, and a new download path, mirror or runtime build must verify against those pins before anything is installed.
