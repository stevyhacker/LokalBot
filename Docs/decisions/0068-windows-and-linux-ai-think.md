# 0068. Windows and Linux: ai — think

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `LinuxWindows/crates/lokalbot-ai/src/think.rs`.

## Decisions

### `LinuxWindows/crates/lokalbot-ai/src/think.rs`

#### Think clients mirror Swift engines; remote servers need approved origin and HTTPS
Think, embedding and autocomplete clients (`Engines/TextEngine.swift`,
`ThinkExecution.swift`, `ReasoningLevels.swift`, `EmbeddingIndex.swift`).

The built-in backend leases the local `llama-server` for each request.
Ollama and OpenAI-compatible servers on another machine are refused until
the user approves their exact origin, and need HTTPS even on their own
network (`access::remote_block_reason`).
Anthropic's API speaks its own Messages API ([`crate::anthropic`]). A
ChatGPT or Claude plan ([`crate::plans`]) needs its own approval entry.

#### Default thinking ceiling matches macOS highReasoningBudgetTokens
`DEFAULT_THINKING_BUDGET`: The built-in model's default thinking ceiling (`highReasoningBudgetTokens`).

#### Pin Ollama context so it never silently drops the prompt start
`OLLAMA_CONTEXT_TOKENS`: Ollama's context is pinned so it never silently drops the prompt's start.

#### Chat timeout is 15 minutes because long meetings generate slowly on laptops
`CHAT_TIMEOUT`: Generation can take minutes for a long meeting on a laptop.

#### Chat request is system plus one user message, context joined by blank lines as on macOS
`ChatRequest`: One chat request: a system prompt and a single user message (context
blocks already joined with blank lines, as on macOS).

#### Context precedes user; Anthropic caches its end, others get it joined
`ChatRequest.context`: Shared material that comes before `user`, such as a transcript.
Servers that cache prompts (Anthropic) mark its end; every other
server gets it joined in front of `user` with blank lines.

#### Some(0) disables thinking for the task
`ChatRequest.reasoning_budget`: Thinking tokens for this task; `Some(0)` disables thinking.

#### Schema enforced by decode-time grammar locally, response_format elsewhere
`ChatRequest.json_schema`: JSON Schema the reply must satisfy (decode-time grammar on llama-server
and Ollama, `response_format` elsewhere).

#### Return replies cut off at max_tokens instead of failing
`ChatRequest.keep_truncated`: Return a reply cut off at `max_tokens` instead of failing.

#### Completion text excludes reasoning blocks
`Completion.text`: Visible text, reasoning blocks removed.

#### Explicit dialect keeps one provider's request extensions out of another's
`Dialect`: Request fields differ by server; keep the dialect explicit so one
provider's extensions never leak into another's request.

#### Server backend also serves a llama-server reached directly by the CLI
`Backend::Server`: `/chat/completions` on an OpenAI-style server (including a llama-server
reached directly, e.g. by the CLI through the app's marker).

#### OpenRouter data policy is ignored by other dialects
`Backend::Server.data_policy`: OpenRouter's provider data policy (other dialects ignore it).

#### Server-published reasoning levels are read once, only for a chosen level
`Inner.published_levels`: What the server publishes about this model's reasoning levels, read once
for a chosen level (`ThinkExecution`). `None` inside: it publishes nothing.

#### Local runtime is kept for the embedder even with remote Think
`Inner.runtime`: The local runtime, for the embedder (also used with remote Think).

#### Autocomplete consent allows approved private-network plain HTTP, unlike Think
`autocomplete_consent`: Autocomplete's consent, the one its route was resolved with
(`autocomplete::server::validate`): unlike Think, an approved server on the
user's own network may use plain HTTP.

#### Scheduled runs need the same origin approval as manual Think
`allows_automatic_main_inference`: Scheduled digest and overnight runs use the same origin approval as manual
Think requests: on-device backends, loopback, or an approved origin
(`AppSettings.allowsAutomaticMainInference`).

#### Listing Ollama models requires an allowed origin; empty when unreachable
`list_ollama_models`: The models an Ollama server has installed, sorted (`OllamaEngine.listModels`).
Its origin must already be allowed to receive context; empty when it doesn't
answer.

#### Remote servers must be approved; API key comes from the platform keyring
`ThinkClient::new`: The Think backend `settings` select. Remote servers must be approved.
An OpenAI-compatible API key comes from the platform keyring; pass it
with `with_api_key`.

#### Claude endpoints use the native Messages API for schema, effort, refusals, caching
`ThinkClient::new`: Claude's native Messages API: structured output within
its schema subset, effort, refusals and prompt caching.

#### Direct llama-server access uses the marker's token and built-in dialect
`ThinkClient::llama_server`: A llama-server reached directly (`http://127.0.0.1:17872/v1` and the
marker's token), speaking the built-in dialect.

#### Default priority and purpose mirror ThinkExecution.makeTextEngine
`ThinkClient::with_runtime`: `ThinkExecution.makeTextEngine`'s defaults.

#### Rebuilt client keeps its priority and purpose
`ThinkClient::rebuilt`: The same client with another backend or level; its work stays what it was.

#### Priority applies only to remote servers' shared gate, not built-in
`ThinkClient::with_priority`: Says how urgent this client's work is on a remote server's shared gate
(no effect on the built-in model).

#### Gate keyed by server origin or plan consent key; built-in uses its own leases
`ThinkClient::gate_origin`: The gate's key: the server's origin, or the plan's consent key. The
built-in model, also when reached directly, has its own leases.

#### Whole replies replay on transient failures, mirroring GatedTextEngine.replaying
`ThinkClient::replaying`: A whole reply, replayed on transient failures (`GatedTextEngine.replaying`).

#### Streams hold a slot, are never replayed, cancel while waiting yields nothing
`ThinkClient::streaming`: A stream: it holds a slot, and is never replayed. Cancelled while it waits
for the slot, it reports what arrived: nothing.

#### API key applies only to OpenAI-compatible servers and Anthropic
`ThinkClient::with_api_key`: Sets the API key for an OpenAI-compatible server or Anthropic's API
(no effect otherwise).

#### OpenRouter data policy has no effect on other servers
`ThinkClient::with_openrouter_data_policy`: Sets OpenRouter's provider data policy (no effect on other servers).

#### Identity changes whenever a different model or server would answer; keys checkpoints
`ThinkClient::checkpoint_identity`: Changes whenever a different model or server would answer; part of
generation checkpoints.

#### Enum limit is None when the server compiles schemas locally
`ThinkClient::structured_output_enum_limit`: The most enum values a schema may hold in total, or `None` when the
server compiles schemas locally (`structuredOutputEnumLimit`).

#### Anthropic, Antigravity, Gemini publish no limit; reuse the hosted ceiling of 500
`ThinkClient::structured_output_enum_limit`: Anthropic, Antigravity, and Gemini publish no enum limit, only
that oversized schemas fail; keep the ceiling used for hosted servers.

#### OpenAI documents 1,000 enum values for strict structured outputs
`ThinkClient::structured_output_enum_limit`: OpenAI documents 1,000 enum values for strict structured outputs.

#### Structured replies need output space beyond their content
`ThinkClient::minimum_structured_output_tokens`: Output space a structured reply needs beyond its content.

#### Reasoning models that cannot turn reasoning off spend output on it
`ThinkClient::minimum_structured_output_tokens`: A reasoning model that cannot turn reasoning off spends part of
the output on it.

#### Claude plans use Claude Code's default 200k window
`ThinkClient::context_tokens`: Claude Code's default window on subscription plans.

#### Exact token counts only from llama-server tokenize; None elsewhere
`ThinkClient::token_count`: Exact prompt tokens from llama-server's `/tokenize`; `None` elsewhere.

#### Hold keeps the built-in server loaded across a multi-request job
`ThinkClient::hold`: Keeps the built-in server loaded across a multi-request job.

#### Truncated replies fail with AiError::Truncated unless the request keeps them
`ThinkClient::complete`: The reply text. A reply cut off at `max_tokens` fails with
[`AiError::Truncated`] unless the request keeps truncated replies.

#### Report truncation instead of failing so structured callers can salvage records
`ThinkClient::complete_full`: Like `complete` but reports truncation instead of
failing, so a structured caller can salvage complete records.

#### A server that died mid-job is restarted and the request replayed once
`ThinkClient::complete_full`: A server that died mid-job is restarted and the request
replayed once (`LeasedTextEngine`).

#### Cancelled stream returns what arrived with cancelled set; never replayed
`ThinkClient::stream_full`: Streams until done, cut off, or `cancel` is set; then returns what
arrived (`cancelled` set). Streams are never replayed.

#### Anthropic and plan engines choose their own effort per request
`ThinkClient::request_level`: These engines pick their own effort per request (or do not expose reasoning controls).

#### Only a chosen level looks up accepted levels; origin consent already checked
`ThinkClient::published_levels`: Only a chosen level needs to know what the model accepts. The client's
origin passed its consent check when the client was made.

#### Empty Ollama model name means the server's first installed model
`ThinkClient::ollama_model`: An empty Ollama model name means the server's first installed model.

#### One replay on transient failures after Retry-After (max 60 s) or about a second
`with_retry`: One replay for transient failures (408/409/425/429/5xx, transport), after the
server's Retry-After (≤60 s) or about a second. For a llama-server reached
directly; other servers replay through their gate.

#### reasoning_effort spells Off as none
`effort_value`: `reasoning_effort` spells Off as "none".

#### Map a task's thinking budget to the most reasoning it allows
`ceiling_for_budget`: The most reasoning a task's own budget allows.

#### GPT-6 adds Max, defaults Medium; only Sol and Luna accept none; Astra has no default
`ReasoningSupport::openai`: GPT-6 adds Max and defaults to Medium. Sol and Luna also take
`none`; 6.1 Sol and Astra reject it, so newer models get no Off.
Astra documents no default (OpenAI's model pages, 26 October 2026).

#### Chosen level capped by task budget and model; no-reasoning tasks avoid default-reasoning models
`ReasoningSupport::request_level`: The chosen level, no higher than the task's budget allows, clamped to
what the model accepts. Automatic leaves the server's default, except
that a no-reasoning task never goes to a model that reasons by default.

#### Ask servers about model levels only from origins already allowed for inference
`PublishedLevels`: What `settings` lets LokalBot ask a server about its model: OpenRouter's list
or Ollama's capabilities, only from an origin already allowed for inference.

#### Key changes when model, server or approval changes, triggering a new lookup
`reasoning_lookup_key`: Changes when the selected model, its server or its approval does: the moment to
ask again (`ReasoningSupport.lookupKey`).

#### Blocking lookup sends no key or content, only to allowed origins, off UI thread
`refresh_reasoning_choices`: Asks the server what the selected model accepts, so [`reasoning_choices`] can
say (`ReasoningSupport.resolve`). Blocking: up to a few seconds on a slow
server, so never on the UI thread. Sends only to an allowed origin, with no key
and no content; does nothing for every other backend.

#### Offer published or known levels without network reads; Agent Mode clamps to them
`reasoning_choices`: The reasoning levels the Think model in `settings` accepts, and the level
its server uses when none is sent: what the server last published about it, else
`ReasoningSupport.known(for:)`. Reads nothing from the network. Agent Mode
offers only these and clamps its choice to them.

#### Sort body keys so grammar-constrained servers generate schema properties stably
`chat_body`: The `/chat/completions` body for one dialect (`makeChatRequest`,
`applyGenerationOptions`). Keys are sorted so a grammar-constrained server
generates schema properties in a stable order.

#### Zero thinking budget alone still opens Qwen's thinking turn; disable via template kwargs
`chat_body`: A zero budget alone still opens Qwen's thinking turn and
can exhaust a short reply before any visible text.

#### Data policy applies only to bodies with an OpenRouter provider block
`with_data_policy`: OpenRouter's `provider.data_collection` from the user's policy. Bodies
without a provider block (other dialects) are unchanged.

#### A rejected stream generated nothing, so the caller retries without streaming
`StreamUnsupported`: A rejected stream generated nothing; the caller retries without streaming.

#### Hide think spans even when a tag is split across deltas
`ThinkFilter`: Hides `<think>…</think>` spans in streamed text, even when a tag is split
across deltas.

#### Autocomplete chat uses short deadline, no replay, and streams so cancel works
`short_chat`: One chat request with a short deadline and no replay, for autocomplete:
a newer keystroke supersedes a failed one anyway. Streamed, so `cancel` can
end it between tokens.

#### Some servers ignore stream:true; use their single response
`stream_chat`: Some servers ignore `stream: true`; use that single response.

#### Thinking tokens count against num_predict; zero budget disables thinking; only gpt-oss takes levels
`ollama_body`: Thinking tokens count against `num_predict`; a zero budget turns the
thinking turn off. Only gpt-oss takes a graded level.

#### Context window lookup order mirrors ServerContextWindowCatalog and sends no content
`discover_context`: `ServerContextWindowCatalog`: OpenRouter's endpoints, llama-server's
`/props`, then model-list fields. No content is sent.

#### OpenRouter lookup sends only the model id, no key or content
`discover_context`: The model id alone: no API key and no content (PRIVACY.md).

#### EmbeddingGemma's own retrieval prompt prefixes, matching EmbeddingIndex
`DOCUMENT_PREFIX`: EmbeddingGemma's own retrieval prompts (`EmbeddingIndex`).

#### Bound embedding requests so typed queries never wait long
`EMBED_MAX_INPUTS`: Bounds for one embedding request, so a typed query never waits long.

#### Embeddings come back L2-normalized from the embedder server
`EmbeddingClient`: `/v1/embeddings` on the embedder server; vectors come back L2-normalized.

#### Batch texts within per-request limits; an over-long text goes alone
`request_ranges`: Runs of texts within the per-request limits; an over-long text goes alone.

#### Unpooled servers return one row per token; take the first
`vectors_from_response`: Unpooled servers return one row per token; take the first.

#### Cotyping sampling with max(5, ceil(words*1.3)) tokens, doubled multi-line, cap 120
`CompletionRequest::cotyping`: `CotypingConfiguration.standard` sampling with the word-based length:
`max(5, ceil(words × 1.3))`, doubled for multi-line, at most 120.

#### Raw completions for autocomplete: no chat template, tight sampling, short timeout
`CompletionClient`: Raw `/v1/completions` for autocomplete: no chat template, tight sampling,
a short timeout.

#### Remote autocomplete servers need an approved autocomplete origin
`CompletionClient::server`: Another server; a remote one needs an approved autocomplete origin.

#### Think's OpenRouter data policy also applies to autocomplete
`CompletionClient::with_openrouter_data_policy`: Sets OpenRouter's provider data policy (Think's choice applies to
autocomplete too).

#### Send llama extensions only to self-hosted servers; hosted APIs may reject unknown fields
`CompletionClient::body`: A server the user runs themselves; hosted APIs may reject
unknown fields (`CotypingServerEndpoint.isSelfHosted`).

#### Stop policy can end decoding early; on_partial receives running text
`CompletionClient::stream`: Streams the continuation. `should_stop(text, chunks)` can end decoding
early (the cotyping stop policy); `on_partial` gets the running text.

#### A 2xx without SSE means a non-streaming server; its body is the whole completion
`CompletionClient::stream`: A 2xx without SSE: this server does not stream, and the
body it sent is the whole completion. Only a body that is
not one is asked for again.

#### Test: server says gpt-oss does not think despite known levels
`a_chosen_level_uses_what_ollama_says_the_model_accepts`: gpt-oss is known to take levels, but this server says it doesn't think.

#### Test guards GPT-6 levels, once empty so chosen levels never reached requests
`gpt_6_models_offer_their_documented_levels`: OpenAI's model pages on 26 October 2026. GPT-6 models used to have no
levels, so a chosen level never reached the request.

#### OpenAI treats GPT-6 as reasoning: no temperature; Automatic maps budget to effort
`gpt_6_models_offer_their_documented_levels`: OpenAI's API treats GPT-6 as a reasoning model: no temperature, and
Automatic maps a task's budget onto an effort.

#### Approval does not stand in for encryption, for Think and Ollama
`think_refuses_approved_plain_http_on_a_private_network`: Think and Ollama alike: approval doesn't stand in for encryption.

#### Reverse server rows to prove the client reorders by index
`embedding_client_test`: Reverse the rows; the client must reorder them by index.

#### Re-asking a non-streaming server doubled wait and bill per keystroke
`a_completion_server_that_does_not_stream_is_asked_once`: A server that ignores `stream: true` answers once with the whole
completion; asking again doubled the wait and the bill per keystroke.

#### Raw completion client must not refuse approved private plain-HTTP servers
`a_completion_server_on_the_private_network_may_use_plain_http_once_approved`: Autocomplete accepts an approved plain-HTTP server on the user's own
network, and its raw completion client must not refuse that server.

#### An API origin approval does not cover the ChatGPT plan
`chatgpt_plan_test`: An API approval for the same company does not cover the plan.

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
