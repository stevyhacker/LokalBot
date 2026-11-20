# 0088. Windows and Linux: core — control

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `LinuxWindows/crates/lokalbot-core/src/control/`.

## Decisions

### `LinuxWindows/crates/lokalbot-core/src/control/approvals.rs`

#### Widening requests wait for the person; one-shot, expiring, never bulk-approved
Requests from the terminal that wait for the person (`SettingsApprovals.swift`):
settings changes that widen what LokalBot captures, reads, records, or sends,
and new API keys. Each request is one card in the approval window listing
every change it makes. It is answered once, expires after a few minutes, and
is never approved in bulk. Only the app's own window calls [`Approvals::approve`];
nothing on the control socket can reach it.

#### Caller comes from process tree: displayed, never trusted
`ApprovalRequest.caller`: Who asked, from the process tree: shown to the person, never trusted.

#### Approving the card applies exactly the reviewed retention cleanup
`ApprovalRequest.retention`: The cleanup a shorter retention policy deletes. Approving the card
applies exactly this review.

#### API key never appears in the request report
`ApprovalRequest::json`: What `settings.request` reports. An API key never appears in it.

#### Card re-shows changes when approving would widen beyond what was shown
`CHANGED_WHILE_WAITING`: Approving would widen more than the card showed; it now shows the changes
as they would apply.

#### Answers stay readable for config request for 30 minutes
`Approvals::ANSWERED_LIFETIME_SECONDS`: Answers stay readable for `config request` this long.

#### Identical waiting request returned instead of asking twice
`Approvals::submit`: Queues a request. An identical settings request from the same caller
that is still waiting is returned instead of asking twice. The bool
says whether the request is new, so the person is told only once.

#### Approving twice changes nothing
`Approvals::waiting`: The waiting request for `id`, or why it isn't waiting. An approved one
answers `Ok(None)`: approving twice changes nothing.

#### Turning off settings grant answers every waiting request
`Approvals::deny_all`: Turning the settings grant off answers everything still waiting.

#### API key kept only until the request is answered
`Approvals::finish`: An API key is kept only until the request is answered.

### `LinuxWindows/crates/lokalbot-core/src/control/audit.rs`

#### Append-only settings change log; values stored exactly for Undo; keys never stored
Settings changed from the terminal (`AgentSettingsChanges.swift`): an
append-only log in `diagnostics/settings-changes.jsonl` and the recent list
Settings shows with Undo. Values are kept as stored, so Undo restores them
exactly. API keys are named but never stored.

#### Log keeps newest entries once it passes size cap
`MAXIMUM_LOG_BYTES`: The log keeps the newest entries once it grows past this size.

#### Retention changes can't be undone from the log; undo could delete unreviewed
`KEYS_WITHOUT_UNDO`: Undoing a retention change could delete without the review a shorter policy
needs, so those are changed back in Settings instead.

#### Log names an API key but never stores it
`AgentSettingsChanges::record_secret`: An API key, which the log names but never stores.

#### Non-setting agent actions are listed but never undone
`AgentSettingsChanges::record_event`: Something an agent did that is not a stored setting, such as choosing a
model preset or launch at login. Listed, never undone.

#### Undo offered only while setting still holds agent's value
`can_undo`: Undo is offered only while the setting still holds the agent's value.

#### Fixture matches Swift JSONEncoder sorted keys and iso8601
`reads_the_macs_log_format`: As Swift's JSONEncoder writes `Entry`: sorted keys and `.iso8601`.

### `LinuxWindows/crates/lokalbot-core/src/control/change.rs`

#### Pure change logic shared by app and tests, mirrors Swift files
Reading a typed value, mapping it to what `Settings` stores, and deciding how
a change is authorized (`SettingChange.swift`, `SettingsSnapshot.swift`,
`SettingsChangeApplier.swift`). Pure, so the app and the tests share it.

#### Only Preference and Narrowing apply directly; Widening needs approval
`ChangeClass`: How one requested change is authorized. Only `Preference` and `Narrowing`
changes apply directly; `Widening` needs the person's approval in the app.

#### App decoder still has the last word on values
`SettingSpec::stored_from_presented`: The value `Settings` stores for a presented value, after type, range,
and choice checks. The app's decoder still has the last word.

#### Consent setting widens when it captures, reads, records, keeps or sends more
`SettingSpec::classify`: Whether a change from `old` to `new` (both stored values) can apply
directly. A consent setting widens when it captures, reads, records,
keeps, or sends more; narrowing it is always allowed.

#### Requiring calendar match narrows auto-recording; dropping it widens
`SettingSpec::widens`: Requiring a calendar match narrows auto-recording; dropping it widens.

#### Retention changes always need the person; shorter goes through reviewed cleanup
`SettingSpec::widens`: Longer retention keeps more; shorter deletes, which goes through
the reviewed cleanup. Either way the person decides.

#### Later download sources add third-party hosts; only moving toward Hugging Face narrows
`SettingSpec::widens`: Each later source puts another third-party host ahead of the
earlier ones (ModelScope, then HF-Mirror, then Hugging Face), so
only moving back toward Hugging Face narrows.

#### Later companion history choice shares more with paired devices
`SettingSpec::widens`: Choices run from the shortest window to all history, so a later
choice shares more with paired devices.

#### Removing an exclusion entry widens capture or suggestions
`SettingSpec::widens`: Exclusions: removing an entry captures or suggests in more places.

#### A new export or routine folder writes outside the library
`SettingSpec::widens`: A new export or routine folder writes outside the library.

#### Adding an approved origin sends data to a new place
`SettingSpec::widens`: Approved origins: adding one sends data to a new place.

#### stored None removes key, resetting optional setting to default
`PlanItem`: One change in a plan. `stored: None` removes the key, for an optional
setting reset to its default.

#### Redacted URL written back must not strip user info or query
`ChangePlan::make`: `config list` and `export` show URLs without user info or query.
Writing that form back must not strip them from the real value.

#### Detects widening not on the reviewed card or from another starting value
`ChangePlan::widens_beyond`: Whether this plan widens something `reviewed` did not show: a widening
change that was not on it, or one that now starts from another value.

#### URLs shown without user info and query
`display_text`: A setting's whole value as the person reads it. URLs leave out user info and
query.

#### Config list shows registry keys, choice tokens, URLs without user info or query
`snapshot_entries`: What `config list` and `config get` report: registry keys only, choice
values as tokens, URLs without user info or query.

#### Settings couplings applied to every change path, mirroring AppState.coupledSettings
`coupled_settings`: The rules the Settings controls apply alongside a change, so a change made
anywhere leaves the same settings (`AppState.coupledSettings`).

#### Dreaming first eligible day is yesterday, under the Mac's key
`coupled_settings`: The Mac's key: the overnight review starts from the day before.

#### Apply through real decoder so rejected values are reported, not stored differently
`apply_items`: Applies checked plan items through the real decoder, so a value the app
would reject or adjust is reported instead of silently stored as something
else, then applies the couplings Settings enforces.

#### Approved enabling of coding agent evidence counts as the person's own choice
`apply_items`: Turning this on from an approved card or Undo is the person's
own choice, which is what reading depends on.

#### Consent setting with no rule would treat turning it off as widening
`every_consent_setting_has_a_direction`: A consent setting with no rule would treat every change as widening,
including turning it off. Check each one can be narrowed.

#### Dreaming keeps first eligible day in step under the Mac's key
`applying_uses_the_real_decoder_and_the_couplings_settings_use`: Dreaming keeps its first day in step, under the Mac's key.

#### Person's approval is what lets sessions be read
`applying_uses_the_real_decoder_and_the_couplings_settings_use`: The person approving this is what lets sessions be read.

#### Unrelated changes leave an install that never chose unchanged
`applying_uses_the_real_decoder_and_the_couplings_settings_use`: Other changes leave an install that never chose exactly as it was.

### `LinuxWindows/crates/lokalbot-core/src/control/mod.rs`

#### Control socket exists only while allowed; widening changes await the person
Agents changing settings from the terminal, shared by the app and
`lokalbot-cli` (`AppControl*.swift`, `Setting*.swift`, `AgentSetup.swift`).

Every read and write goes through the running app over a private local
socket that exists only while the person allows it. Changes that widen what
LokalBot captures, reads, records or sends wait for the person in the app;
nothing here or on the socket can approve one.

#### Strips user, password, query and fragment; unparseable values unchanged
`redact_url`: A URL without its user, password, query and fragment, as `config list`,
`config export` and the approval card show it. Anything that doesn't parse
as a scheme and host stays as it is.

#### Evidence enabled reads as actual behavior, so agent enabling must ask
`encoded`: Settings as the terminal sees them. `codingAgentEvidenceEnabled` reads as
what actually happens: the stored default is on, but nothing is read until
the person has chosen, so an agent turning it on has to ask.

#### Numbers compare equal regardless of serde representation
`json_eq`: True when numbers are equal whichever way serde stored them.

#### Date format matches Swift .iso8601 strategy
`iso8601`: `2026-10-17T12:00:00Z`, what Swift's `.iso8601` strategy reads and writes.

### `LinuxWindows/crates/lokalbot-core/src/control/protocol.rs`

#### One JSON object per line, one request per connection
The CLI's requests to the running app (`AppControlProtocol.swift`): one JSON
object per line, one request per connection.

#### CLI-started app comes up in tray without window, same as autostart flag
`BACKGROUND_LAUNCH_ARGUMENT`: `lokalbot-cli` starting the app for a request comes up in the tray like a
login launch, with no window. The same flag the autostart entry passes.

#### Mac names plus front-window and credential store checked on Linux and Windows
`PERMISSION_NAMES`: Names `permissions request` accepts: the Mac's, plus the window in front
and the credential store, which Linux and Windows check on their own.

#### Stable error printed as [code] message like MCP tools
`ControlError`: A stable error the CLI prints as `[code] message`, like the MCP tools'
`[access_disabled]`.

#### Widening or new API key waits; details carry the request
`ControlError::needs_approval`: A widening change, or a new API key, waits for the person in LokalBot.
`details` is the request as `settings.request` reports it.

#### API keys are write-only from the terminal
`AppSecret`: The API keys `lokalbot-cli secret` can set. Keys are write-only from the
terminal: the CLI can say whether one is saved, never read it back.

#### Last four characters let person identify key without seeing it
`AppSecret::hint`: The last four characters, so the person can tell which key they are
approving without seeing it.

#### Key held only until request answered and never printed
`SecretValue`: An API key held only until its request is answered. It never prints.

#### Secret is one line of at most 4 KiB
`validated_secret_value`: Reads a key from `secret.set`: one line of at most 4 KiB.

### `LinuxWindows/crates/lokalbot-core/src/control/registry.rs`

#### Uses Mac's tokens so agents read same names everywhere
`SettingCategory`: Where a setting lives in Settings, with the Mac's tokens so agents read the
same names everywhere.

#### Authorization tier applies once person allows agents to change settings
`SettingTier`: How a terminal change to a setting is authorized once the person allows
external agents to change settings.

#### Widening a consent setting needs approval; narrowing is a preference
`SettingTier::Consent`: Widening it (turning it on, raising it, removing an exclusion,
approving an origin) needs the person's approval in the app.
Narrowing it is a preference.

#### Stable token for agents differs from stored value, which may be display string or key code
`SettingChoice`: One allowed value: the stable token agents read and write, and the value
`Settings` stores for it (some enums store display strings or key codes).

#### Key is stored JSON key, also used by Settings search as settings.\<key>
`SettingSpec`: One persisted `Settings` key as the terminal sees it. The key is the stored
JSON key, which Settings search also uses as `settings.<key>`.

#### Unknown stored choice values are returned unchanged
`SettingSpec::presented`: The stored value presented to agents: choice values become tokens. A
stored value that matches no known choice is returned unchanged.

#### Bookkeeping and app-only keys never listed or changed from terminal
`INTERNAL_KEYS`: Stored keys that are bookkeeping or that only the app's own screens change:
never listed or changed from the terminal. `launchAtLogin` has its own
method, and `codingAgentEvidenceConfirmed` records the person's own choice.

#### Stored only so a Mac library round-trips; nothing reads it here
`UNUSED_HERE_KEYS`: Stored only so a library from a Mac round-trips; nothing reads it here.

#### Keeps choice table in step with Settings enums
`choices_decode_into_the_real_settings`: Each stored choice has to be something `Settings` accepts, and it
comes back the same. This keeps the table in step with the enums.

### `LinuxWindows/crates/lokalbot-core/src/control/registry_table.rs`

#### Mirrors Mac keys, titles, tiers; Rust-only keys come last
The table behind [`super::registry`], with the Mac's keys, titles, tiers and
choices (`SettingRegistry.swift`). `Settings` keys that exist only here come
last.

### `LinuxWindows/crates/lokalbot-core/src/control/setup.rs`

#### Setup request file grants nothing until person allows it in the app
The one way the terminal can ask for access (`AgentSetup.swift`): a
short-lived request file in the library's `control/` folder that the app
shows to the person. Only the app writes grant markers, and only after the
person allows the request in LokalBot. A request written by any other
process gains nothing without that click.

#### Passed by lokalbot-cli setup start when opening the app
`LAUNCH_ARGUMENT`: Passed by `lokalbot-cli setup start` when it opens the app.

#### Keys sorted to match Swift encoder output
`SetupRequest`: Sorted keys, as Swift's encoder writes them.

#### Requester from CLI process tree is displayed, never trusted
`SetupRequest.requester`: Who asked, as the CLI saw its own process tree, for example
"lokalbot-cli via claude". Shown to the person, never trusted.

#### Control files written into private folder readable only by this user
`write`: Writes into the private control folder, readable by this user only.

#### settings has config export shape so config import reads it too
`SetupPlan`: What `setup plan` prints and `setup apply` reads: the settings a setup
conversation covers, a model preset, and launch at login. `settings` has the
same shape as `config export`, so `config import` reads it too.

#### Names process and nearest non-shell ancestor; used for audit, never trusted
`describe_process`: Names the program behind a process: its own name and, when it runs under a
shell, the nearest ancestor that is not one, such as "lokalbot-cli via
claude". Used for the audit log and the setup request. Never trusted.

#### Unsafe justified: handle checked and closed, size field required
`snapshot_entry`: SAFETY: the snapshot handle is checked and closed here, and the entry is
a plain struct whose size field the API requires.

### `LinuxWindows/crates/lokalbot-core/src/control/socket.rs`

#### Socket is user-private; client refuses endpoints owned by others
Where the control socket lives and the client end of it. A Unix socket in the
user's private runtime folder (mode 0700), or a named pipe on Windows whose
access list allows only this user, named after a hash of the library root.
The client refuses an endpoint another user owns, so a request, which can
hold an API key, never reaches anyone else's process.

#### Runtime dir falls back to /tmp, created 0700 and must be owned by user
`private_runtime_dir`: `$XDG_RUNTIME_DIR/lokalbot`, or `/tmp/lokalbot-<uid>` without a runtime
directory. Either is created 0700 and must belong to this user.

#### Reads uid without a C dependency
`current_uid`: This process's user id, without a C dependency.

#### Pipe server may identify client but never impersonate it
`connect`: The server may identify this client but never act as it.

#### Unsafe justified: handles closed, buffer sized by first call
`token_user`: SAFETY: handles are checked and closed here, and the buffer is sized
by the first call before the second writes to it.

#### Unsafe justified: buffer outlives call, string copied before free
`current_user_sid`: SAFETY: the `TOKEN_USER` buffer outlives the call, and the returned
string is copied before it is freed.

#### Unsafe justified: handles closed, buffers outlive SID comparison
`server_is_this_user`: SAFETY: `pipe` is an open handle owned by the caller; every other
handle is checked and closed, and the `TOKEN_USER` buffers outlive
the SID comparison.

#### Helper thread because named pipes have no I/O timeouts
`exchange`: On a helper thread because a named pipe has no I/O timeouts.

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
