# 0028. Mac app: Engines — Subscription

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `LokalBot/Engines/Subscription/`, `LokalBotTests/Engines/Subscription/`.

## Decisions

### `LokalBot/Engines/Subscription/AntigravityCLI.swift`

#### Run user's own agy unmodified; LokalBot never handles Antigravity credentials
`AntigravityCLI`: The user's own Antigravity CLI (`agy`), run unmodified in headless stream
mode. The user signs in through Antigravity's own flow (`agy`); LokalBot
never reads, stores, or forwards Antigravity or Google credentials and
never offers an Antigravity login of its own.

#### Strip enclosing Antigravity session variables from standalone agy
`AntigravityCLI.nestedEnvironmentPrefixes`: Environment keys inherited from an enclosing Antigravity/ACP session
that must not leak into a standalone `agy` invocation.

#### Passing --effort with suffixed slug conflicts in agy
`AntigravityCLI.effortSuffixes`: Effort suffixes `agy models` appends to model slugs (`-low`, `-medium`,
`-high`, `-xhigh`, `-max`). Passing `--effort` with a slug that already
carries one conflicts in `agy`.

#### Collapse multi-effort families to base slug so reasoning level picks effort
`AntigravityCLI.parseModelsOutput`: Parses `agy models` stdout into grouped models. Multi-effort families
(e.g. `gemini-4-neon-low`/`-medium`/`-high`/`-xhigh`) collapse to their
base slug (`gemini-4-neon`) so LokalBot's Reasoning Level setting and
task budgets select `--effort`. Single-variant entries keep their exact
slug.

#### Spinner frames overwrite with carriage return; keep final segment
`AntigravityCLI.parseModelsOutput`: Spinner frames overwrite the line with '\r'; keep only the final segment.

#### agy models verifies sign-in without touching credentials
`AntigravityCLI.authStatus`: `agy models` verifies that `agy` is signed in and lists the models
available on the account, without touching credentials.

#### Locate agy once per launch; manual check looks again
`AntigravityLocator`: Finds Antigravity CLI once per launch; a manual check looks again.

### `LokalBot/Engines/Subscription/AntigravityPlanEngine.swift`

#### Files go in fresh private working directory removed afterwards
`AntigravityRunning.run`: `files` are written into a fresh private working directory (creating
intermediate subdirectories as needed), which `arguments` may name by
relative path; it is removed afterwards.

#### Three tool-isolation layers; content via stdin, schema via private file
`AntigravityPlanEngine`: Think on the user's Google Antigravity plan, through their own signed-in
`agy` CLI.

Every request runs in a fresh private temporary directory with three
defense-in-depth tool-isolation layers:
1. A workspace custom agent (`.agents/agents/lokalbot-think.md`) whose tool
   list is restricted to `finish` (stripping shell, file, web, browser, and
   subagent tools from the model) and whose body carries the system prompt.
2. Session-only `--settings settings.json` with `toolPermission: "strict"`,
   `allowNonWorkspaceAccess: false`, `disableSlashCommands: true`, and
   explicit deny rules for commands, files, URLs, and MCP.
3. A workspace `PreToolUse` hook (`.agents/hooks.json`) whose RE2 matcher
   denies every tool call except `finish` (which `agy --json-schema` uses
   internally to return structured output).

Content travels over stdin (`--input-format stream-json`), and structured
schemas travel in a private temporary file (`--json-schema schema.json`),
never on the command line.

#### RE2 matcher denies every tool except finish used for structured output
`AntigravityPlanEngine.denyNonFinishMatcher`: RE2 regular expression matching every non-empty tool name except
`"finish"`, so `agy --json-schema`'s internal `finish` step succeeds
while every other tool (including MCP and task tools) is hard-denied.

#### Base slugs accept --effort; suffixed slugs and orchestrators fix effort
`AntigravityPlanEngine.traits`: Base model slugs accept `--effort`; slugs that already carry an effort
suffix (`gemini-4-neon-high`) or orchestrator aliases fix their effort
on the model itself.

#### Keep user content and schemas out of command-line arguments
`AntigravityPlanEngine.arguments`: Pure argument construction, covered offline. Neither user content nor
schema contents ever appear in command-line arguments.

#### Plan limits and sign-in stop; transient overloads keep retryable status
`AntigravityPlanEngine.failure`: Plan limits and missing sign-in stop without retrying; transient server
overloads keep a retryable HTTP status for `GatedTextEngine`.

#### Throttle streamed partials to about 30 per second
`AntigravityPlanEngine.PartialForwarder`: Forwards streamed text deltas to the UI, at most about 30 times a second.

### `LokalBot/Engines/Subscription/ChatGPTPlanAccount.swift`

#### Registration survives sign-out so next sign-in reuses client id
`ChatGPTPlanRegistration`: This Mac's registration with OpenAI. It survives sign-out so the next
sign-in reuses the issued client id instead of registering again.

#### Session credentials stored only in Keychain
`ChatGPTPlanCredentials`: One signed-in session. Stored in the Keychain only.

#### Keychain items under app's own service like API key
`KeychainChatGPTPlanStore`: Keychain items under the app's own service, like the API key.

#### Random opaque per-Mac id, never derived from account
`KeychainChatGPTPlanStore.hostID`: An opaque per-Mac id OpenAI uses to tell this host's sessions apart.
Random, never derived from the account.

#### Accept token-sharing models list or classic data id list
`ChatGPTPlanModel.parseList`: The token-sharing model list (`models` with `slug`, `display_name`
and `visibility`), or the classic `data` list of ids.

#### One shared instance serializes refreshes so rotating tokens never race
`ChatGPTPlanAccount`: Signs in with ChatGPT, keeps the session's tokens fresh, and signs out.
One shared instance serializes refreshes, so two requests never race a
rotating refresh token.

#### Model list changes rarely; settings views share one fetch
`ChatGPTPlanAccount.modelListLifetime`: The model list changes rarely; settings views share one fetch.

#### Account endpoints are fixed OpenAI hosts; never follow redirects away
`ChatGPTPlanAccount.liveTransport`: Account endpoints are fixed OpenAI hosts; never follow a redirect away.

#### newRegistration registers again to sign in to another account
`ChatGPTPlanAccount.signIn`: Opens OpenAI's sign-in page and completes the authorization code
exchange when the browser returns to the loopback listener.
`newRegistration` registers again, for signing in to another account.

#### Record registration before exchange so failure never strands issued client
`ChatGPTPlanAccount.signIn`: The registration is recorded before the exchange, so a failed
exchange never strands a client OpenAI already issued.

#### Sign-out revokes session, keeps registration and host id; false if unconfirmed
`ChatGPTPlanAccount.signOut`: Stops using the session, asks OpenAI to revoke it, and clears its
tokens. The registration and host id stay for the next sign-in.
Returns false when revocation could not be confirmed.

#### Refresh once after rejection unless another caller already replaced token
`ChatGPTPlanAccount.accessTokenAfterRejection`: A token the API rejected may have been revoked or rotated early.
Refreshes once unless another caller already replaced it.

#### Terminal refresh error ends session but keeps registration
`ChatGPTPlanAccount.refreshed`: The session is over; the registration stays for sign-in.

#### Replace rotating refresh token together with access token
`ChatGPTPlanAccount.performRefresh`: A rotating refresh token is replaced together with the access token.

#### Sign-out during refresh wins over its result
`ChatGPTPlanAccount.performRefresh`: A sign-out during the refresh wins over its result.

#### Only OpenAI hosts may serve keys or revoke tokens
`ChatGPTPlanAccount.discovery`: Only OpenAI's own hosts may serve its keys or revoke its tokens.

### `LokalBot/Engines/Subscription/ChatGPTPlanEngine.swift`

#### Token-sharing route needs store false, stream true, no sampling or output cap
`ChatGPTPlanEngine`: Think on the user's ChatGPT plan: OpenAI's public Responses API with the
Sign in with ChatGPT access token. The token-sharing route requires
`store: false` and `stream: true` on every request and rejects sampling
and output-cap fields, so neither temperature nor `max_output_tokens` is
ever sent. Plan errors stop the request; nothing falls back to another
provider or billing path.

#### 400 naming an optional field retries once without it
`ChatGPTPlanEngine.OptionalField`: Request fields a model or account may not accept. A 400 naming one
retries once without it; generation never started.

#### Tests replace network with whole SSE body; nil streams live
`ChatGPTPlanEngine.transport`: Tests replace the network with a whole SSE body; nil streams live.

#### OpenAI documents 1000 enum values for strict structured outputs
`ChatGPTPlanEngine.structuredOutputEnumLimit`: OpenAI documents 1,000 enum values for strict structured outputs.

#### System messages rejected on this route; use instructions
`ChatGPTPlanEngine.makeRequest`: System messages are rejected on this route; `instructions` is the
documented replacement.

#### Limits stop; temporary unavailability retries through gate
`ChatGPTPlanEngine.planError`: Maps a rejected request to the documented recovery: plan limits and
eligibility stop without retrying, temporary unavailability retries
with backoff through the request gate, anything else keeps its status.

#### Success requires response.completed; incomplete or cut-off streams throw
`ChatGPTPlanEngine.StreamAccumulator`: Accumulates one Responses stream. Success requires
`response.completed`; an incomplete, failed, or cut-off stream throws.

#### Revoked or early-rotated token gets one refresh then stops
`ChatGPTPlanEngine.respond`: A revoked or early-rotated token: one refresh, then stop.

### `LokalBot/Engines/Subscription/ChatGPTPlanOAuth.swift`

#### Token-sharing sign-in registers Mac as dynamic client; no secret or API key
`ChatGPTPlanOAuth`: OpenAI's Sign in with ChatGPT for open-source apps ("token sharing"),
documented at developers.openai.com/siwc/token-sharing-open-source
(2026-10). The first sign-in registers this Mac's LokalBot as a client
(`dynamic_agent_client`); OpenAI returns the issued client id in the
callback, and later sign-ins and refreshes use that id. No client secret
or API key exists in this flow.

#### Entry point of first registration only; never stored or sent to token endpoint
`ChatGPTPlanOAuth.registrationClientID`: Only the entry point of a first registration. Never stored, never sent
to the token endpoint.

#### Without plan scope sign-in identifies user but authorizes no inference
`ChatGPTPlanOAuth.planScope`: The grant that lets requests draw on the ChatGPT plan. A valid sign-in
without it identifies the user but authorizes no inference.

#### 1455 is OpenAI's example; any port works
`ChatGPTPlanOAuth.preferredCallbackPort`: OpenAI's example port. Any port works; only the port may vary.

#### Nil client id means first registration
`ChatGPTPlanOAuth.AuthorizationRequest.clientID`: The issued client id, or nil for a first registration.

#### Previous ID token skips OpenAI account picker on return
`ChatGPTPlanOAuth.AuthorizationRequest.idTokenHint`: A previous ID token skips OpenAI's account picker on return.

#### Strictly escape query; URLComponents leaves at, plus, colon and slash
`ChatGPTPlanOAuth.AuthorizationRequest.url`: Strict escaping: URLComponents leaves "@", "+", ":" and "/"
as-is in a query, and OpenAI's examples escape the hints.

#### Validate state first so forged local requests cannot complete or cancel sign-in
`ChatGPTPlanOAuth.parseCallback`: Validates `state` before anything else, so a forged request from
another local process can neither complete nor cancel a sign-in.

#### Omit scope so refresh keeps whole grant
`ChatGPTPlanOAuth.refreshRequest`: `scope` is omitted so the refresh keeps the whole grant.

#### These refresh errors force fresh sign-in with saved registration
`ChatGPTPlanOAuth.terminalRefreshErrors`: Refresh errors after which the refresh token is unusable and the user
must sign in again with the saved registration.

#### Validate signature against issuer keys, then issuer, audience, expiry, nonce
`ChatGPTIDToken`: Validates an OpenID Connect ID token from OpenAI: signature against the
issuer's published keys (RS256 or ES256), then issuer, audience, expiry
and nonce.

### `LokalBot/Engines/Subscription/ClaudeCodeCLI.swift`

#### Run user's own Claude Code unmodified; LokalBot never handles Claude credentials
`ClaudeCodeCLI`: The user's own Claude Code installation, run unmodified in print mode.
The user signs in to Claude Code through Anthropic's own flow
(`claude`, then `/login`); LokalBot never reads, stores, or forwards
Claude credentials, and never offers a Claude login of its own.

#### Finder launch has minimal PATH; version-managed claude found via login shell
`ClaudeCodeCLI.locateWithLoginShell`: An app opened from Finder has a minimal PATH, so a Claude Code under a
Node version manager is only found through the user's login shell.

#### Put executable folder first on PATH so npm claude finds node
`ClaudeCodeCLI.environment`: The child environment: LokalBot's own, with the executable's folder
first on PATH so an npm-installed `claude` finds its `node`.

#### Remove CLAUDECODE so child runs when started inside Claude Code session
`ClaudeCodeCLI.environment`: Started from inside a Claude Code session (development), the child
would otherwise refuse to run as a nested session.

#### Subscription means claude.ai auth, not API key or cloud provider
`ClaudeCodeCLI.AuthStatus.usesSubscription`: True when requests draw on a Claude subscription rather than an
API key or cloud provider configured for Claude Code.

#### claude auth status reports sign-in without exposing credentials
`ClaudeCodeCLI.authStatus`: `claude auth status` reports the sign-in without exposing credentials.

#### Locate Claude Code once per launch; manual check looks again
`ClaudeCodeLocator`: Finds Claude Code once per launch; a manual check looks again.

### `LokalBot/Engines/Subscription/ClaudePlanEngine.swift`

#### Files go in fresh private working directory removed afterwards
`ClaudeCodeRunning.run`: `files` are written into a fresh private working directory, which
`arguments` may name by relative path; it is removed afterwards.

#### Run in empty folder: no project settings, system prompt not in process list
`LiveClaudeCodeRunner.run`: An empty folder of its own: no project instructions or settings to
pick up, and the system prompt never appears in a process list.

#### Tools off, no persistence; never --bare since it ignores subscription sign-in
`ClaudePlanEngine`: Think on the user's Claude plan, through their own signed-in Claude Code.

Every request runs with tools, MCP servers, slash commands, settings
files, and customizations off, and without session persistence: the
prompt is never written to `~/.claude/projects`, which LokalBot itself
reads as coding-agent evidence. `--bare` is never used, because it
ignores the Claude subscription sign-in.

#### Without it Claude Code's coding-agent prompt would apply
`ClaudePlanEngine.fallbackSystemPrompt`: Claude Code's own coding-agent prompt would otherwise apply.

#### Aliases and default follow newest models: effort low to max, thinks by default
`ClaudePlanEngine.traits`: Aliases and the default follow the newest models, which take effort
low through max and think by default.

#### On Automatic, thinking-by-default models get budget-implied level
`ClaudePlanEngine.effort`: As for Anthropic's API: a chosen level, capped by the task's budget;
on Automatic a model that thinks by default gets the level its task
budget implies, so notes and digests don't spend minutes thinking.

#### Keep caller content off command line; structured schema goes via stdin
`ClaudePlanEngine.arguments`: Pure argument construction, covered offline. Nothing a caller supplies
is in it: a command line is readable by every process of the same
user, and a schema can hold meeting text (the notes repair lists the
meeting's action items as allowed values). A structured request
therefore reads its schema from stdin, which takes Claude Code's
stream-json input (`structuredInput`).

#### Claude Code refuses stream-json output without --verbose
`ClaudePlanEngine.arguments`: Claude Code refuses stream-json output without --verbose.

#### Send initialize control request with unchanged schema, checked on Claude Code 2.1.318
`ClaudePlanEngine.structuredInput`: Stdin for a structured request, one JSON object per line: the
`initialize` request Claude Code's own SDK sends, carrying the schema
unchanged (`maxItems`, `minimum` included), then the prompt as a user
message. Checked against Claude Code 2.1.318.

#### Prose instead of schema JSON is a failed request
`ClaudePlanEngine.parseResult`: A Claude Code that does not take the schema from stdin answers in
its own words. The caller asked for JSON, so prose is a failed
request here, not a reply handed on as if it were structured.

#### Plan limits and sign-in stop; overloads keep status the gate retries
`ClaudePlanEngine.failure`: Plan limits and a missing sign-in stop without retrying; overloads
and server errors keep a status the request gate retries.

#### Streaming output is one JSON object per line, result last
`ClaudePlanEngine.reply`: `streaming` says the output is stream-json: one object per line, the
result last.

#### Throttle streamed partials to about 30 per second
`ClaudePlanEngine.PartialForwarder`: Forwards streamed text to the UI, at most about 30 times a second.

#### Queued partial must not replace final text after run ends
`ClaudePlanEngine.PartialForwarder.consume`: A partial still queued when the run ends must not replace the
final text the caller shows next.

### `LokalBot/Engines/Subscription/GeminiCLI.swift`

#### Run user's own Gemini CLI; never touch Google credentials or ~/.gemini
`GeminiCLI`: The user's own Gemini CLI (`gemini`), run unmodified in headless mode.
The user signs in through Gemini CLI's own flow (`gemini` in Terminal);
LokalBot never reads, stores, or forwards Google credentials or `~/.gemini`
files, and never offers a Gemini login of its own.

#### Put executable's folder first on PATH so npm gemini finds node
`GeminiCLI.environment`: The child environment: LokalBot's own with the executable's folder first
on PATH so an npm-installed `gemini` finds its `node`, plus optional
per-request isolation paths for system prompt and system settings.

#### Fallback model list for older Gemini CLI lacking models -o json
`GeminiCLI.fallbackModels`: Fallback choices if an older Gemini CLI lacks `gemini models -o json`.

#### Locate Gemini CLI once per launch; manual check looks again
`GeminiCLILocator`: Finds Gemini CLI once per launch; a manual check looks again.

### `LokalBot/Engines/Subscription/GeminiPlanEngine.swift`

#### Files go in a fresh private directory, removed afterwards
`GeminiCLIRunning.run`: `files` are written into a fresh private working directory, which
`arguments` and environment variables (`GEMINI_SYSTEM_MD`,
`GEMINI_CLI_SYSTEM_SETTINGS_PATH`) reference; the folder is removed
afterwards.

#### Isolate every Gemini request: deny-all policy, no tools, stdin prompt
`GeminiPlanEngine`: Think on the user's Google AI / Gemini plan, through their own signed-in
Gemini CLI (`gemini -p ""`).

Every request runs in an empty private temporary directory with:
- `--admin-policy deny-all.toml` (tier-5 policy denying every tool call),
- `GEMINI_CLI_SYSTEM_SETTINGS_PATH` overriding tools, MCP servers, hooks,
  skills, and usage statistics off while preserving the user's own auth,
- `--extensions none` disabling all CLI extensions,
- `GEMINI_SYSTEM_MD` loading the system prompt from a private file, and
- prompt and context piped over stdin (never in command-line arguments).

#### User content and schemas never appear in command-line arguments
`GeminiPlanEngine.arguments`: Pure argument construction, covered offline. Neither user content nor
schema contents ever appear in command-line arguments.

#### Plan limits and sign-in errors don't retry; transient errors stay retryable
`GeminiPlanEngine.failure`: Plan limits and missing sign-in stop without retrying; transient server
errors keep a retryable status for `GatedTextEngine`.

#### Forward streamed deltas to UI at most 30 times a second
`GeminiPlanEngine.PartialForwarder`: Forwards streamed text deltas to the UI, at most about 30 times a second.

### `LokalBot/Engines/Subscription/LoopbackRedirectListener.swift`

#### One-shot 127.0.0.1-only OAuth redirect listener ignoring other paths
`LoopbackRedirectListener`: A one-shot HTTP listener on 127.0.0.1 that receives an OAuth redirect.
It binds to the loopback address only, answers the first request for
`path` with a short page, and hands its query to the waiting sign-in.
Other paths (a browser's favicon request) get a 404 and are ignored.

#### Use preferred port, else any free port
`LoopbackRedirectListener.start`: Listens on `preferredPort`, or on any free port when it is taken.

#### Bind to 127.0.0.1 only, shared by sign-in and ChatGPT relay
`LoopbackListener`: A TCP listener bound to 127.0.0.1 only, so nothing off this Mac can reach
it. Shared by the sign-in redirect and Agent Mode's ChatGPT plan relay.

#### Port 0 means any free port; refuses connections until handler installed
`LoopbackListener.bind`: A started listener on `port`, or on any free port when it is 0. It
refuses connections until the caller installs its own handler.

### `LokalBot/Engines/Subscription/PlanCLIProcess.swift`

#### Short-lived CLI child: SIGPIPE-safe stdin, bounded stderr, terminate on cancel or timeout
`PlanCLIProcess`: Runs one short-lived CLI child process for a CLI-backed subscription plan:
writes stdin without SIGPIPE risk, collects stdout (or streams it line by
line) and a bounded stderr tail, and terminates the child when the calling
task is cancelled or the timeout passes.

#### Set F_SETNOSIGPIPE so early child exit gives EPIPE, not SIGPIPE
`PlanCLIProcess.run`: A child that exits early closes its end: the write must fail with
EPIPE instead of raising SIGPIPE, which would end LokalBot.

#### Name short timeouts in seconds, not whole minutes
`PlanCLIProcess.run`: Short limits (sign-in/status checks) are named in seconds:
whole minutes turned them into "0 minutes".

#### Files live in a 0700 temp folder deleted after the body runs
`PlanCLIProcess.withPrivateDirectory`: Writes `files` (relative paths, creating intermediate subdirectories
with `0700` permissions) inside a fresh private `0700` temporary folder,
invokes `body`, and deletes the folder afterwards.

#### Look up command via login shell because Finder launches with minimal PATH
`PlanCLIProcess.locateWithLoginShell`: Looks up `command` in the user's login shell when Finder launches the
app with a minimal PATH.

### `LokalBot/Engines/Subscription/SubscriptionPlan.swift`

#### Plan approvals are separate from API-server approvals, different provider terms
`SubscriptionPlan`: Think backends that run on the user's own ChatGPT, Claude, Antigravity,
or Gemini plan instead of an API key. Requests count toward that plan's
usage limits.

Each plan has its own approval entry in
`AppSettings.approvedRemoteInferenceOrigins`. The entries are not URL
origins, so approving an API server (`https://api.openai.com` with a key)
never approves plan usage, and the reverse: the two run under different
provider terms.

#### CLI-backed plans send Think content via user's CLI to the provider
`SubscriptionPlan.destinationHost`: Where Think content goes. Claude, Antigravity, and Gemini requests
travel through the user's own CLI installation, which sends them to
that provider.

#### Approval entry doubles as the request gate origin
`SubscriptionPlan.consentKey`: The approval entry, also used as the request gate's origin.

### `LokalBotTests/Engines/Subscription/AntigravityPlanEngineTests.swift`

#### Notes on Automatic with zero reasoning budget use low effort
`AntigravityPlanEngineTests.testEffortAvoidsConflictWithExplicitEffortSlugAndCapsByBudget`: Notes on Automatic with zero reasoning budget drop to low effort.

#### Slugs with a baked-in effort suffix never send --effort
`AntigravityPlanEngineTests.testEffortAvoidsConflictWithExplicitEffortSlugAndCapsByBudget`: Slugs with a baked-in effort suffix must never send --effort.

#### Non-TTY agy models output separates slug and name with one tab
`AntigravityCLI.parseModelsOutput`: Non-TTY stdout from `agy models` separates slug and display name with a single tab.

### `LokalBotTests/Engines/Subscription/ChatGPTPlanLiveTests.swift`

#### Live test of Agent Mode requests against the ChatGPT plan route, opt-in by env
`ChatGPTPlanLiveTests`: Sends Agent Mode's requests to the ChatGPT plan route with the sign-in
this Mac's LokalBot already holds: first the bodies pi-ai 1.3.0's
Responses client builds for a tool turn and its follow-up (instructions
as a developer message, top-level function tools, encrypted reasoning
replayed with the call and its output), then a real pi turn through
`ChatGPTPlanRelay`. Runs only when
`LOKALBOT_CHATGPT_PLAN_LIVE=1` (pass `TEST_RUNNER_LOKALBOT_CHATGPT_PLAN_LIVE=1`
through xcodebuild). A test build's first Keychain read asks for approval;
a refreshed token is saved back, so the app stays signed in.
`LOKALBOT_CHATGPT_PLAN_MODEL` overrides the first listed model.

#### Replay items as pi does: reasoning as returned, call without status
`ChatGPTPlanLiveTests.testFunctionToolRoundTrip`: Replay as pi does: reasoning items as returned, the call without
its status, then the tool's output.

#### Full pi path through the relay needs a tool call and encrypted reasoning replay
`ChatGPTPlanLiveTests.testPiRunsAToolTurnOnThePlanThroughTheRelay`: Agent Mode's whole path: the installed pi runtime with this build's
extension speaks the Responses API to the relay, which forwards to the
plan. pi reads a file in its working folder (no approval needed) and
answers from it, so the turn needs a tool call, its result, and pi's
replay of the encrypted reasoning. `LOKALBOT_AGENT_RUNTIME_ROOT`
overrides the installed runtime.

#### Live turn needs no approval, so UI requests are declined
`ChatGPTPlanLiveTests.testPiRunsAToolTurnOnThePlanThroughTheRelay`: Nothing in this turn needs approval.

### `LokalBotTests/Engines/Subscription/ChatGPTPlanTests.swift`

#### Reauthorization callback may omit client_id
`ChatGPTPlanOAuth.parseCallback`: Reauthorization may omit client_id.

#### A first registration callback must name the issued client
`ChatGPTPlanOAuth.parseCallback`: A first registration must say which client was issued.

#### Scopes persist when the refresh response omits them
`ChatGPTPlanAccount.refresh`: Scopes stay when the refresh response omits them.

#### ID token is verified against OpenAI's published key before anything is stored
`ChatGPTPlanAccount.signIn`: The whole browser round trip: the authorize URL opens, the "browser"
returns to the loopback listener, the code is exchanged, and the ID
token is checked against OpenAI's published key before anything is
stored.

#### Loopback listener must tolerate stray requests like a browser favicon fetch
`ChatGPTPlanAccount.signIn`: A stray request first, as a browser's favicon fetch would be.

#### A no-reasoning task stays at the model's lowest effort level
`ChatGPTPlanEngine.makeRequest`: A task tuned for no reasoning stays at the model's lowest level.

#### GPT-6.1 Sol dropped the chosen High level when it had no known levels
`ChatGPTPlanEngine.makeRequest`: GPT-6.1 Sol used to have no known levels, so the High the user chose
was dropped and every plan request ran at the model's default.

### `LokalBotTests/Engines/Subscription/ClaudePlanEngineTests.swift`

#### Notes run with no reasoning budget use the lowest effort, not default
`ClaudePlanEngine.arguments`: Notes run with no reasoning budget: the lowest effort, not the default.

#### Schema travels on stdin because command lines are readable by other processes
`ClaudePlanEngine.arguments`: A notes repair lists the meeting's action items as the allowed values
of a field. A command line is readable by other processes, so the
schema travels on stdin with the prompt.

#### A prose reply to a schema request must fail, not return as structured
`ClaudePlanEngine.parseResult`: A Claude Code that ignores the schema sent on stdin answers in prose.
That used to be returned as the structured reply, with no error.

#### JSON as text counts as a reply, with or without a code fence
`ClaudePlanEngine.parseResult`: JSON as text is still a reply, with or without a code fence around it.

#### A reply cut off at the output limit keeps its own truncated handling
`ClaudePlanEngine.parseResult`: A reply cut off at the output limit keeps its own handling.

### `LokalBotTests/Engines/Subscription/ClaudePlanLiveTests.swift`

#### Live Claude plan test runs only with LOKALBOT_CLAUDE_PLAN_LIVE, default model haiku
`ClaudePlanLiveTests`: Sends synthetic text through the Mac's own signed-in Claude Code, on the
Claude plan it is signed in with. Runs only when `LOKALBOT_CLAUDE_PLAN_LIVE`
is set (pass `TEST_RUNNER_LOKALBOT_CLAUDE_PLAN_LIVE=1` through xcodebuild);
`LOKALBOT_CLAUDE_PLAN_MODEL` overrides `haiku`.

### `LokalBotTests/Engines/Subscription/SubscriptionPlanSettingsTests.swift`

#### A settings blob from before plans keeps every default silently
`AppSettings decoding`: A blob from a build before plans keeps every default silently.

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
