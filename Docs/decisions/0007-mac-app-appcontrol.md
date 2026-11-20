# 0007. Mac app: AppControl

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `LokalBot/Services/AppControl/`, `LokalBotTests/Services/AppControl/`.

## Decisions

### `LokalBot/Services/AppControl/AgentSettingsChanges.swift`

#### Log stores values as stored so Undo restores exactly
`AgentSettingsChanges`: Settings changed from the terminal: an append-only log in
`diagnostics/settings-changes.jsonl` and the recent list Settings shows
with Undo. Values are kept as stored, so Undo restores them exactly.

#### Log trimmed to newest entries past 1 MB
`AgentSettingsChanges.maximumLogBytes`: The log keeps the newest entries once it grows past this size.

#### Log names API key changes but never stores the key
`AgentSettingsChanges.recordSecret`: An API key, which the log names but never stores.

#### Non-setting agent actions are listed but never undone
`AgentSettingsChanges.recordEvent`: Something an agent did that is not a stored setting, such as choosing
a model preset or launch at login. Listed, never undone.

#### Retention undo could delete without review; change in Settings
`AgentSettingsChanges.keysWithoutUndo`: Undoing a retention change could delete without the review a shorter
policy needs, so those are changed back in Settings instead.

#### Undo offered only while setting still holds agent's value
`AgentSettingsChanges.canUndo`: Undo is offered only while the setting still holds the agent's value.

#### Undo requests permissions like the Settings control would
`AgentSettingsChanges.undo`: The person clicked Undo, so turning a feature back on asks for its
permissions the way its Settings control would.

### `LokalBot/Services/AppControl/AgentSetupRequests.swift`

#### Request answered once; answer written to setup-answer.json for CLI
`AgentSetupRequests`: The request an agent left with `lokalbot-cli setup start`, shown to the
person in the agent setup window. Allowing it turns on the settings grant,
plus whichever read access the person ticks; declining leaves everything
off. Each request is answered once, and the answer is written back to
`control/setup-answer.json` for the CLI to read.

#### Unreadable or expired request is answered and removed
`AgentSetupRequests.check`: Picks up a request left by the CLI and says whether one is waiting.
An unreadable or expired request is answered and removed.

#### Marker write failure is already shown; answer denied
`AgentSetupRequests.allow`: The marker could not be written; the error is already shown.

#### Remove only the answered request; CLI may have left newer one
`AgentSetupRequests.answer`: Only remove the request this answers; the CLI may have left a newer one.

### `LokalBot/Services/AppControl/AppControlHandler+Setup.swift`

#### Prompts, launch at login, restarts act only in interactive app
`AppControlHandler+Setup`: The setup half of the control socket: what an agent needs to take the
person from a new install to a working LokalBot. Permission prompts,
launch at login, and restarts act only in the interactive app, where the
person can see them.

#### Balanced models when stack plus transcription fit memory, else lightweight
`AppControlHandler.suggestedPreset`: The balanced models when their Think and autocomplete models, plus
room for transcription, fit comfortably in memory; otherwise the
lightweight ones.

#### Mirrors the Permissions row in Memory Health
`AppControlHandler.permissions`: Each permission, whether it is granted, and which enabled features
need it. Mirrors the Permissions row in Memory Health.

#### Shows prompt or guidance; the person still decides
`AppControlHandler.requestPermission`: Shows the macOS prompt, or System Settings with LokalBot's guidance.
The person still decides.

### `LokalBot/Services/AppControl/AppControlHandler.swift`

#### Every request re-checks marker so revoking affects open connections
`AppControlHandler`: Answers control-socket requests on the main actor, against the live
`AppState`. Every request re-checks the Privacy marker, so revoking the
grant takes effect even for a connection already accepted.

#### Widening changes wait for approval; all-or-none application
`AppControlHandler.setSettings`: Applies preference and narrowing changes, all or none. A change that
widens what LokalBot captures, reads, records, or sends waits, with the
rest of its request, until the person approves it in the app.

#### Validate everything first, even dry run, before asking person
`AppControlHandler.setSettings`: Validate everything that would apply, even for a dry run, and
before asking the person about a value LokalBot would reject.

#### New API key always waits; held in memory, never in replies
`AppControlHandler.setSecret`: A new API key always waits for the person. The key itself is held in
memory until the request is answered and never appears in a reply.

#### App reads files after approval; CLI only names them
`AppControlHandler.importMeetings`: Imports another app's meetings, after the person approves. The app
reads the files itself; the CLI only names them. A dry run, or a plan
with nothing new, returns the counts without asking anyone.

#### Open Settings for steps only the person can do
`AppControlHandler.openSettings`: Opens Settings at one setting or section, for what only the person can
do there: permissions, sign-in, or a change they want to make themselves.

### `LokalBot/Services/AppControl/AppControlServer.swift`

#### Runs only while allowed; same-user connections only
`AppControlServer`: The app end of the CLI control socket. Runs only while the person allows
external agents to change settings; accepts connections from this user
only and hands each request to the main actor.

#### Unlink stale socket; instance lock prevents other servers
`AppControlServer.start`: A socket left by a crashed run would make bind fail. The library
instance lock guarantees no other app serves this path.

#### Clear inherited O_NONBLOCK; blocking I/O bounded by socket timeouts
`AppControlServer.acceptPending`: Accepted sockets inherit O_NONBLOCK; requests use blocking I/O
bounded by the socket timeouts instead.

#### Audit log records client process and agent that started its shell
`AppControlPeer`: Who sent a control request, for the audit log: the client process and,
when it runs under a shell, the agent that started that shell.

### `LokalBot/Services/AppControl/AppState+AgentSettings.swift`

#### Tests swap in memory store so they never touch the login Keychain
`AgentSecretStore`: Where API keys are kept. Tests swap in memory so they never touch the
login Keychain.

#### Write saves or removes a key (nil) and reports whether it persisted
`AgentSecretStore.write`: Saves a key, or removes it for nil, and says whether it stuck.

#### Terminal, approval and Undo changes apply the same coupling rules as Settings controls
`AppState.coupledSettings`: Settings changed outside their Settings control: from the terminal, after
an approval, or by Undo. The rules match the controls, so a change made
anywhere leaves the same settings and asks for the same permissions.

#### Apply couplings first, then permission prompts for newly enabled features
`AppState.changeSettings`: Changes settings the way a Settings control does: couplings, then the
permission prompts for whatever the change turned on.

#### Flush settings before syncing Dock policy because it reads saved settings
`AppState.applySettings`: The Dock policy reads saved settings.

#### Delete listed evidence first, then set policy; return incompletely cleaned moments
`AppState.applyRetentionReview`: Deletes what a reviewed retention change lists, then sets the policy.
Returns the moments that could not be fully cleaned up.

#### Record applied items for audit log and Undo; warn for values that did not stick
`AppState.applyAgentSettings`: Applies checked plan items and records them for the audit log and
Undo. Returns a warning for each value that did not stick.

#### Some settings self-correct, such as Quick Recall shortcut reverting on key conflicts
`AppState.applyAgentSettings`: Some settings correct themselves: the Quick Recall shortcut reverts when
another app already owns the key combination.

#### Review needed only when the change shortens retention; nil when nothing is deleted
`AppState.retentionReview`: The cleanup a change's shorter retention policy needs reviewed, or nil
when the change deletes nothing.

#### Rebase approved changes on current settings; re-show card if approval would widen or delete more
`AppState.applyApprovedSettings`: Applies the changes an approved card showed to the settings as they
are now. Settings the request left as they were stay as the person has
them since. When approving would widen more than the card showed, or a
shorter retention policy would delete more than its review, the card
gets the new changes and keeps waiting.

#### Validate every value before anything is deleted
`AppState.applyApprovedSettings`: Check every value before anything is deleted.

#### Approved import rereads files and skips existing meetings, so approving twice is safe
`AppState.applyApprovedImport`: Starts an import the person approved. It reads the files again and
skips anything already in the library, so approving twice is safe.

### `LokalBot/Services/AppControl/SettingsApprovals.swift`

#### Widening requests wait on one card each, answered once, expire, never bulk-approved
`SettingsApprovals`: Requests from the terminal that wait for the person: settings changes that
widen what LokalBot captures, reads, records, or sends, new API keys, and
imports of another app's meetings into the library.
Each request is one card in the approval window listing every change it
makes. It is answered once, expires after a few minutes, and is never
approved in bulk.

#### Import files are reread at approval, so card counts describe the earlier state
`SettingsApprovals.Subject.meetingImport`: Meetings from another app's exports or files. The files are read
again when the person approves, so the card's counts describe them
as they were when it was shown.

#### Approving the card applies exactly the retention review it showed
`SettingsApprovals.Request.retention`: The cleanup a shorter retention policy deletes. Approving the card
applies exactly this review.

#### Answered requests stay readable for config request for 30 minutes
`SettingsApprovals.answeredLifetime`: Answers stay readable for `config request` this long.

#### Announce by notification, or approval window when notifications are off; set on interactive launch
`SettingsApprovals.announce`: Tells the person a request is waiting: a notification, or the approval
window when notifications are off. Set on the interactive launch path.

#### Remove a request's notification once answered or expired
`SettingsApprovals.withdraw`: Removes a request's notification once it is answered or expires.

#### Identical pending settings request from same caller is returned, not asked twice
`SettingsApprovals.submit`: Queues a request. An identical settings request from the same caller
that is still waiting is returned instead of asking twice.

#### Apply may throw to keep request waiting, such as when retention cleanup changed
`SettingsApprovals.approve`: Applies a request through `apply`, which throws to keep it waiting,
for example when the retention cleanup changed and needs a new look.

#### Turning the settings grant off denies all waiting requests
`SettingsApprovals.denyAll`: Turning the settings grant off answers everything still waiting.

#### Lets approval path refresh a card it could not apply as shown
`SettingsApprovals.update`: Lets the approval path refresh a card it could not apply as shown.

#### An API key is kept only until its request is answered
`SettingsApprovals.finish`: An API key is kept only until the request is answered.

#### API keys are never matched against other requests nor kept after answering
`SettingsApprovals.Subject.holdsSecret`: An API key is never matched against another request or kept after
it is answered.

#### Approval that would widen beyond the card re-shows the card with new changes
`SettingsApprovalError.changedWhileWaiting`: Approving would widen more than the card showed; it now shows the
changes as they would apply.

### `LokalBot/Services/AppControl/SettingsChangeApplier.swift`

#### Apply through the real decoder so rejected or adjusted values are reported, then couple
`SettingsChangeApplier`: Applies checked plan items to `AppSettings` through the real decoder, so a
value the app would reject or adjust is reported instead of silently stored
as something else, then applies the couplings Settings enforces
(`AppState.coupledSettings`).

#### Assigning nil removes an optional key, restoring its default
`SettingsChangeApplier.apply`: Assigning nil removes an optional key, which restores its default.

### `LokalBot/Services/AppControl/SettingsControlAccessManager.swift`

#### Control socket exists only while the external-agent settings grant is on
`SettingsControlAccessManager`: App-side owner of "Allow external agents to change LokalBot settings":
the Privacy marker plus the control socket, which exists only while the
grant is on.

#### Waiting requests are denied when the grant is turned off
`SettingsControlAccessManager.setEnabled`: Requests already waiting go with the grant.

### `LokalBotTests/Services/AppControl/AppControlTests.swift`

#### Client blocks on the socket so keep it off the main actor running the server
`AppControlClient.request`: The client blocks on the socket; keep it off the main actor that
runs the server's handler.

### `LokalBotTests/Services/AppControl/SettingsApprovalFlowTests.swift`

#### Undoing a shorter retention could delete without review, so Settings handles it
`AgentSettingsChanges.canUndo`: Undoing it could delete without a review, so Settings handles that.

#### A lengthened retention policy shortened again before approval would delete, so it waits for review
`SettingsApprovals.approve`: Lengthening needs no cleanup when asked, but the person lengthens
further before approving, so applying it now would delete.

#### The approval card shows only changed items; approval keeps later user changes
`SettingsApprovals.approve`: The origin list is unchanged, so the card shows only the capture change.

#### A widening that grew while waiting is shown again before approval
`SettingsApprovals.approve`: The card adds one origin; approving now would add both.

#### A change only in what a URL hides still shows in the card
`SettingSpec.changeLines`: A change only in what a URL hides still says so.

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
