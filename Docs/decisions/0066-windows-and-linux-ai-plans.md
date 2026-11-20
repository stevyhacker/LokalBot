# 0066. Windows and Linux: ai — plans

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `LinuxWindows/crates/lokalbot-ai/src/plans/`, `LinuxWindows/crates/lokalbot-ai/src/plans/chatgpt/`, `LinuxWindows/crates/lokalbot-ai/src/plans/chatgpt/relay/`, `LinuxWindows/crates/lokalbot-ai/src/plans/claude/`.

## Decisions

### `LinuxWindows/crates/lokalbot-ai/src/plans/antigravity.rs`

#### agy runs in private temp dir with three tool-isolation layers; no credentials touched
The Antigravity plan through the user's own Antigravity CLI (`agy`)
(`AntigravityCLI.swift`, `AntigravityPlanEngine.swift`).

The user signs in to Antigravity CLI through Google's own flow (`agy`);
LokalBot never reads, stores, or forwards Antigravity or Google credentials
and never offers an Antigravity login of its own. Every request runs `agy`
in a fresh private temporary directory with three defense-in-depth
tool-isolation layers:
1. `.agents/agents/lokalbot-think.md` restricting tools to `finish` and
   carrying the system prompt.
2. `--settings settings.json` setting `toolPermission: "strict"`,
   `allowNonWorkspaceAccess: false`, `disableSlashCommands: true`, and
   explicit deny rules for commands, files, URLs, and MCP.
3. `.agents/hooks.json` with a `PreToolUse` RE2 matcher that denies every
   tool call except `finish` (used internally by `--json-schema`).

Content travels over stdin (`--input-format stream-json`), and structured
schemas travel in a private temporary file (`--json-schema schema.json`),
never on the command line.

#### Regex denies every tool except finish, which json-schema needs
`DENY_NON_FINISH_MATCHER`: RE2 regular expression matching every non-empty tool name except `"finish"`,
so `agy --json-schema`'s internal `finish` step succeeds while every other
tool (including MCP and task tools) is hard-denied.

#### Remove enclosing Antigravity/ACP env so agy runs standalone
`scrubbed_command`: Removes enclosing Antigravity/ACP session variables so `agy` runs as a
standalone invocation.

#### Multi-effort model families collapse to their base slug
`parse_models_output`: Parses `agy models` stdout into grouped models. Multi-effort families
(e.g. `gemini-4-neon-low`/`-medium`/`-high`/`-xhigh`) collapse to their
base slug (`gemini-4-neon`).

#### Non-TTY output uses a tab separator; TTY pads with two spaces
`parse_models_output`: Non-TTY `agy models` separates columns with a single tab; TTY output
pads with two or more spaces.

#### Sign-in checked via agy models without touching credentials
`auth_status`: Checks whether `agy` is signed in and returns its available models via
`agy models`, without touching credentials.

### `LinuxWindows/crates/lokalbot-ai/src/plans/chatgpt.rs`

#### ChatGPT plan sign-in uses token sharing, PKCE, credential store, no sampling fields
The ChatGPT plan (`ChatGPTPlanOAuth.swift`, `ChatGPTPlanAccount.swift`,
`ChatGPTPlanEngine.swift`).

Sign-in is OpenAI's Sign in with ChatGPT for open-source apps ("token
sharing"): the first sign-in registers this PC's LokalBot as a client
(`dynamic_agent_client`), OpenAI returns the issued client id in the
callback, and later sign-ins and refreshes use that id. There is no client
secret or API key. The browser returns to a listener on 127.0.0.1 that
accepts only that redirect; the code is exchanged with PKCE and the ID
token is checked against OpenAI's published keys. Tokens, the
registration and a random per-PC id live only in the system credential
store: without one, sign-in fails before the browser opens.

Think requests go to OpenAI's Responses API with `store: false` and
`stream: true`. The token-sharing route rejects sampling and output-cap
fields, so neither temperature nor `max_output_tokens` is ever sent.
Agent Mode reaches the same API through [`relay`], which holds the tokens
for the agent runtime.

#### Sign-in without the plan scope authorizes no inference
`PLAN_SCOPE`: The grant that lets requests draw on the ChatGPT plan. A valid sign-in
without it identifies the user but authorizes no inference.

#### 1455 is OpenAI's example port; only the port may vary
`PREFERRED_CALLBACK_PORT`: OpenAI's example port. Any port works; only the port may vary.

#### Refresh 120 seconds before the access token expires
`REFRESH_MARGIN_SECONDS`: Refresh this long before the access token expires.

#### Model list changes rarely; settings views share one fetch
`MODEL_LIST_SECONDS`: The model list changes rarely; settings views share one fetch.

#### Endpoints are overridable so tests can use a local server
`Endpoints`: OpenAI's sign-in and API addresses. Tests point them at a local server.

#### Resource is the API root for requests and the token's resource name
`Endpoints.resource`: The API root requests and the token's `resource` name.

#### Extra trusted origin for signing keys and revocation, tests only
`Endpoints.extra_trusted_origin`: Besides `https://*.openai.com`, an origin trusted to serve signing
keys and the revocation endpoint (tests only).

#### Only OpenAI's own hosts may serve keys or revoke tokens
`Endpoints::trusted`: Only OpenAI's own hosts may serve its keys or revoke its tokens.

#### No client id means a first registration
`AuthorizationRequest.client_id`: The issued client id, or `None` for a first registration.

#### Previous ID token skips OpenAI's account picker on return
`AuthorizationRequest.id_token_hint`: A previous ID token skips OpenAI's account picker on return.

#### client_id is the issued id when the callback names one
`CallbackOutcome::Code`: `client_id` is the issued id when the callback names one.

#### Validate state first so forged local requests cannot complete or cancel sign-in
`parse_callback`: Validates `state` before anything else, so a forged request from another
local process can neither complete nor cancel a sign-in.

#### These refresh errors make the token unusable and require new sign-in
`TERMINAL_REFRESH_ERRORS`: Refresh errors after which the refresh token is unusable and the user
must sign in again with the saved registration.

#### ID token checked: RS256/ES256 signature, issuer, audience, expiry, nonce
`validate_id_token`: Validates an OpenID Connect ID token from OpenAI: the signature against
the issuer's published keys (RS256 or ES256), then issuer, audience,
expiry and nonce.

#### Sign-in lives in system credential store in app, memory in tests
`Store`: Where the sign-in lives: the system credential store in the app
(`lokalbot_engine::secrets`), memory in tests.

#### Ok(None) means nothing stored; Err means store unreachable
`Store::get`: `Ok(None)` when nothing is stored; `Err` when the store can't be reached.

#### The first installed store wins
`install_store`: Sets the store the shared account uses. The first call wins.

#### Split long values: Windows Credential Manager limits items to 1,280 characters
`Chunked`: Splits long values across several items, for stores with a small item
size: Windows Credential Manager keeps at most 1,280 characters, less than
one session's tokens. The first item names how many parts follow.

#### A missing part from an interrupted write reads as nothing stored
`Chunked::get`: An interrupted write: as good as nothing stored.

#### Registration survives sign-out so the issued client id is reused
`Registration`: This PC's registration with OpenAI. It survives sign-out so the next
sign-in reuses the issued client id instead of registering again.

#### Expiry is in Unix seconds
`Credentials.expires_at`: Unix seconds.

#### Accept token-sharing model list or classic data list of ids
`PlanModel::parse_list`: The token-sharing model list (`models` with `slug`, `display_name` and
`visibility`), or the classic `data` list of ids.

#### One shared instance serializes refreshes to avoid rotating-token races
`Account`: Signs in with ChatGPT, keeps the session's tokens fresh, and signs out.
One shared instance serializes refreshes, so two requests never race a
rotating refresh token.

#### None means the store the app installed
`Account.store`: `None`: the store the app installed ([`install_store`]).

#### Read back after writing so a store that drops secrets isn't signed in
`Account::write`: Writes and reads back: a store that silently drops secrets must not
look signed in.

#### Random per-PC id, never from account; creating it proves store works
`Account::host_id`: An opaque per-PC id OpenAI uses to tell this host's sessions apart.
Random, never derived from the account. Creating it also proves the
credential store works before anything is signed in.

#### Sign-in blocks up to five minutes; new_registration signs in to another account
`Account::sign_in`: Opens OpenAI's sign-in page and completes the authorization code
exchange when the browser returns to the loopback listener. Blocks
until then (at most five minutes) or `cancel_sign_in`.
`new_registration` registers again, for signing in to another account.

#### Fail closed before the browser opens without a credential store
`Account::sign_in`: Fail closed before the browser opens: no credential store, no sign-in.

#### Record registration before exchange so a failed exchange never strands an issued client
`Account::sign_in_with`: The registration is recorded before the exchange, so a failed
exchange never strands a client OpenAI already issued.

#### Sign-out revokes and clears tokens, keeps registration and host id
`Account::sign_out`: Stops using the session, asks OpenAI to revoke it, and clears its
tokens. The registration and host id stay for the next sign-in.
Returns false when revocation could not be confirmed.

#### Forgetting registration makes next sign-in register anew
`Account::forget_registration`: Forgets this PC's registration so the next sign-in registers anew.

#### Rejected token may be revoked or rotated; refresh once unless replaced
`Account::access_token_after_rejection`: A token the API rejected may have been revoked or rotated early.
Refreshes once unless another caller already replaced it.

#### Refreshes are serialized; a token already replaced is reused
`Account::refreshed`: Refreshes the session whose access token is `stale`. Refreshes are
serialized; one that finds the token already replaced uses that.

#### Terminal refresh error ends session but keeps registration
`Account::refreshed`: The session is over; the registration stays for sign-in.

#### Rotating refresh token is replaced together with access token
`Account::refreshed`: A rotating refresh token is replaced together with the access token.

#### Models are fetched at most every ten minutes
`Account::models`: The signed-in account's models, fetched at most every ten minutes.

#### Limits and eligibility stop without retry; temporary unavailability is retryable
`plan_error_for`: The documented recovery for one plan error code: limits and eligibility
stop without retrying, temporary unavailability is retryable.

#### Success requires response.completed; incomplete, failed or cut-off streams fail
`StreamAccumulator`: Accumulates one Responses stream. Success requires `response.completed`;
an incomplete, failed, or cut-off stream fails.

#### Some(false) completed, Some(true) cut off at output limit
`StreamAccumulator.outcome`: `Some(false)` completed, `Some(true)` cut off at the output limit.

#### Rejected optional field retries once without it; generation never started
`OptionalField`: Request fields a model or account may not accept. A rejection naming one
retries once without it; generation never started.

#### Request construction is pure so it is tested offline
`Engine::body`: Pure request construction, covered offline without a sign-in.

#### System messages are rejected on this route; use instructions
`Engine::body`: System messages are rejected on this route; `instructions` is the
documented replacement.

#### One refresh on revoked token; one retry without a rejected optional field
`Engine::respond`: One request, streamed. A revoked or early-rotated token gets one
refresh; a rejected optional field one retry without it.

#### Context windows follow OpenAI docs; every plan model has at least 128K
`context_tokens`: OpenAI's documented windows by model family; every model a ChatGPT plan
offers has at least 128K.

#### GPT-6 takes at most 922K input tokens of 1.05M window
`context_tokens`: Every GPT-6 model takes at most 922K input tokens of a 1.05M window.

### `LinuxWindows/crates/lokalbot-ai/src/plans/chatgpt/relay.rs`

#### Relay keeps plan tokens from pi; only POST /v1/responses relayed; upstream drop limits
Agent Mode on the ChatGPT plan (`ChatGPTPlanRelay.swift`). pi speaks the
Responses API to this relay on 127.0.0.1 with a key issued for one task.
The relay checks that key, shapes the body to the plan route's rules, adds
the current Sign in with ChatGPT access token ([`Account`] refreshes it),
and streams OpenAI's reply back unchanged. Only `POST /v1/responses` is
relayed, so pi and the commands it runs never hold the plan's tokens.

Blocking sockets, one thread per connection. A hang-up or [`Relay::stop`]
closes pi's connection at once. ureq's read of OpenAI's stream can't be
interrupted from another thread, so that upstream connection is dropped
when its next event arrives.

#### 32 MB leaves room for full agent context with long tool results
`MAXIMUM_REQUEST_BYTES`: Room for a full agent context with long tool results.

#### Error replies are short JSON; longer ones are cut
`MAXIMUM_ERROR_BYTES`: An error reply is short JSON; anything longer is cut.

#### pi writes at once and reads as streamed; stalled connections dropped
`STALL_TIMEOUT`: pi writes a request at once and reads its reply as it streams; a
connection stalled either way is dropped.

#### Fields the plan route rejects, per OpenAI token-sharing preview limitations
`UNSUPPORTED_FIELDS`: The plan route's request rules (developers.openai.com/siwc/token-sharing-open-source,
"Preview limitations", 2026-10): fields it rejects, server-side
conversation state it can't use over HTTP, and pi-ai fields that have no
meaning on plan usage.

#### A relay serves one task; dropping it stops it
`Relay`: One task's relay. Dropping it stops it.

#### Bearer key is random per relay and never stored
`Shared.key`: The bearer key pi presents. Random per relay and never stored.

#### Connect to wake accept loop so it sees stopped and closes
`Relay::stop`: Wakes the accept loop, which then sees `stopped` and closes.

#### Sleep after accept error so descriptor exhaustion doesn't spin
`Relay accept loop`: Out of descriptors, say; don't spin.

#### A 401 means token revoked or rotated early; refresh once
`Shared::serve`: A token can be revoked or rotated early; refresh it once.

#### Detect pi closing socket even while model is thinking, via short read timeout
`watch_for_hang_up`: pi closes its socket to abort a request. Notice that even while the model
is still thinking and nothing is being written. The socket's short read
timeout lets this thread end with the request on every platform.

#### Read returns as soon as OpenAI sends, so events pass at once
`relay_stream`: Returns as soon as OpenAI sends anything, so events pass at once.

#### On early end pi hung up or stream broke; pi sees cut stream
`relay_stream`: pi hung up, or OpenAI's stream broke; pi sees the cut stream.

#### Relay errors mimic OpenAI's shape; retry None keeps pi's default retry rules
`reply`: An error the relay itself answers, shaped like OpenAI's so pi shows the
message. `retry` `None` keeps pi's own retry rules for the status.

#### Check key as soon as head arrives, before buffering body
`Request`: The relay's reading of one HTTP/1.1 request from pi. The key is checked
as soon as the head arrives, before a body is buffered.

#### Reject Origin header: browsers always send it, pi never does
`read_request`: Browsers always send Origin; pi never does.

#### Strip unsupported fields, force store false and stream true, system to developer
`upstream_body`: pi's body with [`UNSUPPORTED_FIELDS`] removed, `store: false` and
`stream: true` set, and system messages sent as developer messages.
`None` for anything that isn't a Responses request.

#### Plan limits don't change on retry; temporary outages do
`should_retry`: pi retries 408, 409, 429 and 5xx by default. Plan limits, eligibility and
request errors don't change on a retry; temporary plan outages do. `None`
leaves pi's default for the status.

### `LinuxWindows/crates/lokalbot-ai/src/plans/chatgpt/relay/tests.rs`

#### Keep body open with SSE comments so fake notices relay hanging up
`FakeReply.stays_open`: Keeps the body open after the chunks, like a model still thinking.
It sends SSE comments meanwhile, so it notices the relay hanging up.

### `LinuxWindows/crates/lokalbot-ai/src/plans/chatgpt/tests.rs`

#### RSA fixtures generated with openssl, with fixed issuer, audience, nonce, expiry
`RSA_N / RSA_TOKEN`: Generated with `openssl genrsa 2048` and `openssl dgst -sha256 -sign`
(iss https://auth.openai.com, aud app_test, nonce nonce-rsa, exp 2100).

#### Forged request can neither complete nor cancel a sign-in
`callbacks_check_state_first`: A forged request can neither complete nor cancel a sign-in.

#### Simulates Linux session without a Secret Service
`BrokenStore`: A store that cannot be reached, like a Linux session without a Secret
Service.

#### Credential store entries use the Mac's account names
`sign_in_registers_exchanges_with_pkce_and_keeps_tokens_in_the_store`: Everything lives in the credential store, under the Mac's names.

#### Rotated session must keep its plan grant
`expiring_tokens_refresh_and_a_dead_refresh_token_signs_out`: The rotated session keeps its plan grant.

#### Task budget caps the chosen reasoning level
`responses_requests_stream_without_storage_or_sampling`: The task budget caps the chosen level.

#### Test store mimics Windows Credential Manager's item limit
`SmallItems`: A store with Windows Credential Manager's item limit.

### `LinuxWindows/crates/lokalbot-ai/src/plans/claude.rs`

#### Claude plan runs claude -p isolated, never reads credentials, secrets over stdin
The Claude plan through the user's own Claude Code (`ClaudeCodeCLI.swift`,
`ClaudePlanEngine.swift`).

The user signs in to Claude Code through Anthropic's own flow (`claude`,
then `/login`); LokalBot never reads, stores, or forwards Claude
credentials and never offers a Claude login of its own. Every request
runs `claude -p` in an empty private folder with tools, MCP servers,
slash commands, settings files and customizations off, and without
session persistence, so the prompt is never written to
`~/.claude/projects`, which LokalBot itself reads as coding-agent
evidence. Content goes over stdin and a private file, never the command
line, and so does a request's JSON schema, which can hold meeting text.
`--bare` is never used: it ignores the subscription sign-in.

#### Otherwise Claude Code's own coding-agent prompt would apply
`FALLBACK_SYSTEM_PROMPT`: Claude Code's own coding-agent prompt would otherwise apply.

#### npm installs a .cmd shim on Windows, native installer an .exe
`executable_names`: The names `claude` has on this platform. npm installs a `.cmd` shim on
Windows; the native installer an `.exe`.

#### Launcher sessions have minimal PATH; version-manager installs need login shell
`locate_with_login_shell`: A desktop session started from a launcher can have a minimal PATH, so a
Claude Code under a Node version manager is only found through the
user's login shell.

#### Resolve npm .cmd shim to its script so args skip cmd.exe
`Launch`: How to start Claude Code. An npm `.cmd` shim is resolved to the script it
runs, so arguments never pass through `cmd.exe`.

#### Put first on PATH so npm-installed claude finds node
`Launch.folder`: Put first on the child's PATH, so an npm-installed `claude` finds its
`node`.

#### cmd-shim targets a .js run by node or a native .exe
`Launch::from_shim`: npm's cmd-shim names its target as `"%dp0%\…"`: a `.js` entry run by
`node` (next to the shim, else on PATH) or a native `.exe`.

#### Shim also names node.exe, which must not be taken as target
`Launch::from_shim`: The shim also names the `node.exe` it may run the script with.

#### Remove CLAUDECODE so nested sessions run; executable folder first on PATH
`Launch::command`: The command, with LokalBot's environment minus `CLAUDECODE` (started
from inside a Claude Code session the child would otherwise refuse to
run as a nested session) and the executable's folder first on PATH.

#### Subscription only when auth method is claude.ai, not API key or cloud
`AuthStatus::uses_subscription`: True when requests draw on a Claude subscription rather than an API
key or cloud provider configured for Claude Code.

#### Aliases and default follow newest models: effort low through max, think by default
`traits`: Aliases and the default follow the newest models, which take effort low
through max and think by default.

#### On Automatic, thinking models get level implied by task budget
`effort`: As for Anthropic's API: a chosen level, capped by the task's budget; on
Automatic a model that thinks by default gets the level its task budget
implies, so notes and digests don't spend minutes thinking.

#### Isolation flags copied from Mac; schema and content never on command line
`arguments`: The isolation flags, copied from the Mac. Nothing the caller supplies is
among them: a command line can be read by every process of the same user,
and a schema can hold meeting text (the notes repair lists the meeting's
action items as allowed values). A structured request reads its schema
from stdin instead, in Claude Code's stream-json input ([`input`]).

#### Claude Code refuses stream-json output without --verbose
`arguments`: Claude Code refuses stream-json output without --verbose.

#### Structured request sends initialize with schema then user message over stdin
`input`: Stdin: context blocks, then the instruction. A structured request sends
one JSON object per line: the `initialize` request Claude Code's own SDK
sends, carrying the schema unchanged (`maxItems`, `minimum` included),
then the same text as a user message (`structuredInput`, checked on the
Mac against Claude Code 2.1.318).

#### Plan limits and missing sign-in don't retry; overloads and server errors may
`failure`: Plan limits and a missing sign-in stop without retrying; overloads and
server errors keep a status the caller may retry.

#### Files go in a fresh private directory, removed afterwards
`Runner::run`: `files` are written into a fresh private working directory, which
`arguments` may name by relative path; it is removed afterwards.

#### Empty folder avoids project settings; system prompt stays off process list
`LiveRunner::run`: An empty folder of its own: no project instructions or settings to
pick up, and the system prompt never appears in a process list.

#### Stop child and its helpers on cancel or timeout; child dies with LokalBot
`run_child`: Writes stdin, hands stdout over line by line, keeps a bounded stderr
tail, and stops the child (with anything it started) on cancel or
timeout. The child dies with LokalBot.

#### Own process group so stopping also stops helpers
`run_child`: Its own process group, so stopping it also stops its helpers.

#### Early-exiting child closes stdin; write failure is ignored
`run_child`: A child that exits early closes its end; the write then fails quietly.

#### Lines via channel so a stopped run returns though helpers hold the pipe
`run_child`: Lines arrive through a channel, so a stopped run returns at once even
if something it started still holds the pipe open.

#### SIGTERM then SIGKILL to process group; Windows terminates the child
`stop`: SIGTERM to the child's process group, then SIGKILL; on Windows the child
is terminated.

#### Signal is sent to the group we created for our unreaped child
`stop`: SAFETY: signal delivery to the process group we created for our
own, not yet reaped, child.

#### SIGKILL ends helpers that ignored SIGTERM
`stop`: SAFETY: as above; helpers that ignored SIGTERM end here.

#### Streaming output is stream-json, one object per line, result last
`reply`: `streaming` says the output is stream-json: one object per line, the
result last.

### `LinuxWindows/crates/lokalbot-ai/src/plans/claude/tests.rs`

#### Schema request reads schema from stdin and answers in lines
`arguments test`: A request with a schema reads it from stdin and answers in lines.

#### Notes with budget 0 run at lowest effort on thinking model
`arguments test`: Notes (budget 0) run at the lowest effort on a thinking model.

#### Claude Haiku 4.5 takes no effort control
`arguments_carry_the_mac_isolation_flags`: Claude Haiku 4.5 takes no effort control.

#### Command lines are readable by same-user processes; notes repair schema holds action items
`a_schema_travels_on_stdin_never_in_the_arguments`: A command line is readable by every process of the same user, and the
notes repair puts the meeting's action items in its schema.

#### Test env mutation is safe because no concurrent CLAUDECODE reads
`runs_claude_in_a_private_empty_folder_with_content_on_stdin`: SAFETY: tests in this binary do not read CLAUDECODE concurrently.

### `LinuxWindows/crates/lokalbot-ai/src/plans/cli.rs`

#### Shared CLI plan helpers mirror PlanCLIProcess.swift
Shared child-process, binary discovery, npm shim resolution, and private
temp-file helpers for CLI-backed subscription plans (`PlanCLIProcess.swift`).

#### Resolve npm .cmd shim to its target so args skip cmd.exe
`Launch`: How to start a user CLI. An npm `.cmd` shim on Windows is resolved to its
target script or `.exe` so arguments never pass through `cmd.exe`.

#### Signal is sent to the group we created for our unreaped child
`stop`: SAFETY: signal delivery to the process group we created for our
own, not yet reaped, child.

#### SIGKILL ends helpers that ignored SIGTERM
`stop`: SAFETY: as above; helpers that ignored SIGTERM end here.

### `LinuxWindows/crates/lokalbot-ai/src/plans/gemini.rs`

#### Gemini plan runs isolated: deny-all policy, no extensions, prompt over stdin, no credential reads
The Gemini plan through the user's own Gemini CLI (`gemini -p ""`)
(`GeminiCLI.swift`, `GeminiPlanEngine.swift`).

The user signs in to Gemini CLI through Google's own flow (`gemini` in a
terminal); LokalBot never reads, stores, or forwards Google credentials or
`~/.gemini/` files, and never offers a Gemini login of its own. Every
request runs `gemini -p ""` in a fresh private temporary directory with:
- `--skip-trust` and `GEMINI_CLI_TRUST_WORKSPACE=true`
- `--admin-policy deny-all.toml` (tier-5 policy denying every tool call)
- `--extensions none` disabling all CLI extensions
- `GEMINI_CLI_SYSTEM_SETTINGS_PATH` overriding tools, MCP servers, hooks,
  skills, and telemetry off while keeping the user's own auth settings
- `GEMINI_SYSTEM_MD` loading the system prompt from a private file
- prompt and context piped over stdin, never on the command line.

### `LinuxWindows/crates/lokalbot-ai/src/plans/loopback.rs`

#### Loopback-only one-shot listener answers first redirect, 404s other paths
A one-shot HTTP listener on 127.0.0.1 that receives an OAuth redirect
(`LoopbackRedirectListener.swift`). It binds to the loopback address only,
answers the first request for its path with a short page, and hands the
query to the waiting sign-in. Other paths (a browser's favicon request)
get a 404 and are ignored.

#### Empty for non-GET; None until head complete
`request_target`: The request-target of a complete `GET` request head; empty for another
method; `None` until the head is complete.

#### First value of a repeated query name wins
`query_of`: Query items of a request-target, percent-decoded; the first value of a
repeated name wins.

### `LinuxWindows/crates/lokalbot-ai/src/plans/mod.rs`

#### Signing in sends no content; plan needs consent; errors never fall back
Think on the user's own ChatGPT, Claude, Antigravity, or Gemini plan
instead of an API key (`Engines/Subscription/`). Signing in alone sends no
content; Think uses a plan only after the user approves its consent entry
([`SubscriptionPlan::consent_key`]). Plan errors stop the request; nothing
falls back to another provider or billing path.

#### Variants mirror the Mac's per-plan error types
`PlanError`: Failures a plan reports to the user (`ChatGPTPlanError`,
`ClaudePlanError`, `AntigravityPlanError`, `GeminiPlanError`,
`SubscriptionPlanError`).

#### ChatGPT sign-ins are kept only in the system credential store
`PlanError::CredentialStoreUnavailable`: ChatGPT sign-ins are kept only in the system credential store.

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
