# 0045. Mac app: Resources

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `LokalBot/Resources/pi/lokalbot-extension/`.

## Decisions

### `LokalBot/Resources/pi/lokalbot-extension/index.ts`

#### Extension registers provider, gates tools, mirrors pi 1.5.2 path resolution
LokalBot pi extension: registers the app-configured model as a provider,
gates every tool except workspace reads behind the host UI, and adds the
per-run facts that LokalBot's system prompt refers to.

Runs inside pi (RPC mode) under Bun. The env contract comes from
PiLaunchPlanner; the confirm() below surfaces in LokalBot as an
extension_ui_request on stdout, answered over stdin.

Paths are resolved exactly as pi 1.5.2's file tools resolve them (a leading
"@", "~", file URLs, Unicode spaces, look-alike names, the session folder),
so the boundary check and the approval card name the file pi will open.

#### Only four tools get dedicated previews; others show full arguments
`PREVIEWED_TOOLS`: Tools whose approval card shows a dedicated preview. Any other tool is
reviewed from its exact arguments, which must fit in full.

#### Completions for local servers, Responses API for ChatGPT plan relay
`PROVIDER_APIS`: Chat completions for local and OpenAI-compatible servers; the Responses
API for LokalBot's ChatGPT plan relay.

#### Plan route needs developer messages, encrypted reasoning, no output caps
`RESPONSES_MODEL_TRAITS`: pi-ai sends a reasoning model's instructions as a developer message (the
plan route rejects system messages) and replays its encrypted reasoning.
The route also rejects output caps.

#### Budgets mirror ThinkReasoningLevel.budgetTokens for same allowance everywhere
`THINKING_BUDGETS`: ThinkReasoningLevel.budgetTokens, so a level means the same thinking
allowance in Agent Mode as in summaries.

#### Keep provider key on globalThis, out of the shell environment
`takeProviderAPIKey`: The provider key stays inside this process. pi gives every shell command
a copy of its environment, so a command or a script it starts could
otherwise read the key. pi evaluates this module again for a new session,
so the key is kept on globalThis rather than read from the environment.

#### Default placeholder key since llama.cpp ignores it, others may want one
`takeProviderAPIKey`: llama.cpp ignores the key; Ollama/LM Studio may want one.

#### Inject fetch hook and read reasoning level file per request
`lokalbotExtension.streamSimple`: Pi has its own HTTP client: the host's URLSession redirect policy does
not cover it. Inject only this provider's supported transport hook.
LokalBot writes the Agent reasoning level (already limited to what the
model accepts) to a file it may change mid-task; read it per request.

#### Set model input explicitly; pi registerProvider does not default it
`lokalbotExtension model registration`: Required: pi's registerProvider path does NOT default `input`
(unlike its models.json path), and pi-ai's openai-completions
dereferences model.input unguarded — omitting this crashes every
completion with "undefined is not an object".

#### Block bash commands too long to show in full for approval
`lokalbotExtension tool_call bash`: The exact shell command must fit in the approval payload. Never ask for
approval of a prefix and then execute the unchanged, longer request.

#### Resolve relative paths against pi's session folder, not process cwd
`lokalbotExtension tool_call cwd`: pi's tools resolve relative paths against the session folder: the
folder a resumed session was saved with, not necessarily this process's.

#### Approval payload is machine-parseable so host shows exact changes
`lokalbotExtension tool_call approval`: Machine-parseable payload: the host renders exact commands and file
changes, rather than relying on a model-authored summary.

#### Environment section is last so date changes cache only daily
`environmentSection`: The facts LokalBot's system prompt points to: today's date, what the
working folder is, and which model answers. It is the last prompt section,
and pi folds a changed section into the leading system message for this
provider, so the date only changes the cached prompt once a day.
`servedBy` names a plan's provider when a local relay forwards to it.

#### Reject all redirects since approval covers one origin
`inferenceFetchForOrigin`: A launched Agent task has approval for one origin. Reject redirects before
the HTTP client can replay context or credentials, including same-origin
redirects: configure the final inference endpoint instead.

#### Reasoning level file format; missing or unreadable means Automatic
`readReasoningLevel`: `{"level": "<ThinkReasoningLevel>"}`. Missing or unreadable: Automatic,
which leaves every request exactly as pi built it.

#### Mirrors OpenAICompatibleEngine.applyGenerationOptions; Automatic leaves request untouched
`applyReasoningLevel`: Mirrors OpenAICompatibleEngine.applyGenerationOptions for a level the host
already limited to the model's (ReasoningSupport). Automatic leaves every
request exactly as pi built it.

#### Zero budget alone still opens Qwen thinking; disable via template kwargs
`applyReasoningLevel llama-server`: A zero budget alone still opens Qwen's thinking turn.

#### Only gpt-oss takes graded levels; others only switch off
`applyReasoningLevel ollama`: Only gpt-oss takes a graded level; other thinking models can only be
switched off, which the host limits the level to.

#### Responses API level goes in reasoning.effort like ChatGPTPlanEngine
`applyResponsesReasoningLevel`: The Responses API takes a level as `reasoning.effort`, as
ChatGPTPlanEngine sends it. Automatic leaves pi's request as built.

#### Retry once when server rejects reasoning level; mirrors Swift engine
`retryRejectedReasoning`: A chosen level can be one the selected model does not accept. When the
server names reasoning in a 400/422, retry once: `none` becomes `low` for
models that always reason; any other level falls back to the server's
default. Mirrors OpenAICompatibleEngine.shouldRetryRejectedReasoningLevel.

#### Mirrors pi 1.5.2 normalizePath; Windows conversions skipped on macOS
`normalizeToolPath`: pi 1.5.2 `normalizePath` (utils/paths.js). `forTool` adds the options its
file tools pass. pi's Windows drive-path conversions never apply on macOS.

#### Mirrors pi 1.5.2 resolveToCwd used by write and edit
`resolveToCwd`: pi 1.5.2 `resolveToCwd`, which its write and edit tools use.

#### Check read against look-alike file pi will actually open
`resolveReadPath`: pi 1.5.2 `resolveReadPath`: a missing file is opened through a look-alike
name when one exists, so a read is checked against the file pi will open.

#### Return file pi will open or undefined when uncertain
`requestedPath`: The file pi's tool will open, or undefined when that is not certain.

#### Canonicalize nearest existing ancestor; dangling link fails closed
`canonicalize`: Canonicalize the nearest existing ancestor so a path through a symlink
cannot escape merely because its final component does not exist yet.
A dangling link stops the walk and fails closed.

#### Allowlist: only in-workspace non-private reads run without asking
`requiresApproval`: Allowlist: a read inside the selected workspace and outside the private
library is the only call that runs without asking. Every other tool asks,
including MCP tools, codemode, and tools that later Pi releases add.

#### Unresolvable paths and ancestor workspaces never count as safe
`requiresApproval`: Missing/unresolvable paths are never silently treated as in-workspace.
Choosing Home or another ancestor as a workspace does not silently make
the private library, server credentials, or Agent history normal files.

#### Tools without preview are approved from their exact arguments
`argumentsText`: The exact arguments a tool without a dedicated preview will run with.

#### Arguments length checked against MAX_APPROVAL_TEXT before approval
`approvalPayload default case`: Checked against MAX_APPROVAL_TEXT before approval is requested.

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
