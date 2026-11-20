# 0071. Windows and Linux: app — control

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `LinuxWindows/crates/lokalbot-app/src/control/`.

## Decisions

### `LinuxWindows/crates/lokalbot-app/src/control/handler.rs`

#### Answers control-socket requests on the UI thread, mirroring AppControlHandler
Answers control-socket requests on the UI thread, against the live settings
(`AppControlHandler.swift`, `AppControlHandler+Setup.swift`).

#### Balanced models when they fit comfortably in memory, else lightweight
`suggested_preset`: The balanced models when their Think and autocomplete models, plus room for
transcription, fit comfortably in memory; otherwise the lightweight ones.

#### Model needs file size plus about 30% resident, within 60% of memory
`suggested_preset`: A model needs its file size plus about 30% resident, within 60% of memory.

#### Revoking the grant applies even to already accepted connections
`ControlHost.handle`: Revoking the grant takes effect even for a connection already accepted.

#### Credential-store requests answer later because they can block
`ControlHost.handle`: These reach the credential store, which can block, so they answer later.

#### Widening changes wait for approval with the rest of the request, all or none
`ControlHost.set_settings`: Applies preference and narrowing changes, all or none. A change that
widens what LokalBot captures, reads, records, or sends waits, with the
rest of its request, until the person approves it in the app.

#### Validate before asking the person, even for dry runs
`ControlHost.set_settings`: Validate everything that would apply, even for a dry run, and before
asking the person about a value LokalBot would reject.

#### New API keys always wait; key held in memory, never in a reply
`ControlHost.secret_set`: A new API key always waits for the person. The key itself is held in
memory until the request is answered and never appears in a reply.

#### checked is false where nothing can be read before first run
`ControlHost permissions reply`: False where nothing can be read before the feature
first runs: then "granted" claims nothing.

#### Granted is null where it can't be known before first run
`ControlHost.status`: Null where it can't be known before the feature first runs.

#### Reply first because the relaunch quits this copy
`ControlHost.restart`: Reply first; the relaunch quits this copy.

#### Open Settings for what only the person can do there
`ControlHost.open_settings`: Opens Settings at one setting or section, for what only the person can do
there: permissions, sign-in, or a change they want to make themselves.

### `LinuxWindows/crates/lokalbot-app/src/control/mod.rs`

#### Every request rechecks the Privacy marker; socket cannot approve anything
Agents changing settings from the terminal (`Services/AppControl/*`): the
control socket, which exists only while the person allows it, the approvals
that wait for them, the audit log with Undo, and the agent setup request.

Every request re-checks the Privacy marker, so revoking the grant takes
effect even for a connection already accepted. The socket has no method that
approves anything: [`ControlHost::approve`] is called only from the approval
window, by the person.

#### Bumped when a setup request changes read access, for Settings to reread
`ControlHost.access_generation`: Bumped when a setup request changes read access, for Settings to reread.

#### Socket opens only if the grant is on
`control::start`: Starts the control host; the socket opens only if the grant is on.

#### A waiting agent setup request replaces the first-run wizard
`setup_waiting`: True when an agent's setup request waits, which replaces the first-run wizard.

#### Values go through the real decoder; shortcuts and model ids through their checks
`checked_apply`: Settings as the app would hold them after `items`, or why not. The values go
through the real decoder, and shortcuts and model ids through their checks.

#### Grant on opens the socket; off closes it and denies waiting requests
`ControlHost.set_enabled`: Turning the grant on opens the socket; off closes it and denies what waits.

#### Requests already waiting go with the grant
`ControlHost.set_enabled`: Requests already waiting go with the grant.

#### Use the approval window when notifications are off; only the person can answer
`ControlHost.announce`: Tells the person a request is waiting: a notification, or the approval
window when notifications are off, because only the person can answer.

#### A problem stays on the card
`ControlHost.approve`: The person approved a request on its card. A problem stays on the card.

#### Apply approved changes to current settings; re-wait if widening or deletion grows
`ControlHost.approve_settings`: Applies the changes an approved card showed to the settings as they are
now. Settings the request left as they were stay as the person has them
since. When approving would widen more than the card showed, or a shorter
retention policy would delete more than its review, the card gets the new
changes and keeps waiting.

#### Check every value before anything is deleted
`ControlHost.approve_settings`: Check every value before anything is deleted.

#### Applied items are recorded for audit log and Undo, with warnings
`ControlHost.apply_agent_settings`: Applies checked plan items and records them for the audit log and Undo.
Returns a warning for each value that did not stick.

#### Undo restores the earlier value only while the setting still holds the agent's
`ControlHost.undo`: The person clicked Undo. It restores the earlier value while the setting
still holds the agent's.

#### Retention review runs on UI thread; a failed review refuses the change
`ControlHost.retention_review`: The cleanup a change's shorter retention policy needs reviewed, or `None`
when the change deletes nothing. On the UI thread as on the Mac: it is
rare, and the card needs it. A review that can't be built refuses the
change rather than skipping the review.

### `LinuxWindows/crates/lokalbot-app/src/control/permissions.rs`

#### Linux and Windows have no prompts; entries say what this desktop allows, as setup reads it
What LokalBot needs from this computer (`AppControlHandler.permissionNeeds`,
`PermissionRow.swift`). Linux and Windows have no permission prompts like
macOS, so each entry says what this desktop allows instead, read the way
setup reads it (`crate::access`), so Settings, setup and `lokalbot-cli
permissions` say the same. Shared by Settings and `lokalbot-cli permissions`.

#### GNOME's Window Calls extension supplies the window in front
`Fix::WindowCalls`: GNOME's Window Calls extension, for the window in front.

#### Names match what `permissions request` accepts
`PermissionNeed.name`: `microphone`, `accessibility`, …, as `permissions request` takes them.

#### False both when not allowed and when it can't be known
`PermissionNeed.granted`: Allowed now. False both when it isn't and when that can't be known.

#### False where nothing can be read before the feature first runs
`PermissionNeed.checked`: False where nothing can be read before the feature first runs.

#### Missing means a feature uses it and it is known not allowed
`PermissionNeed.missing`: A feature that is on uses it, and it is known not to be allowed.

#### Wayland autocomplete reads through the input method, not accessibility
`Inputs.autocomplete_by_input_method`: Autocomplete reads other apps through the input method, not
accessibility (Linux on Wayland).

#### Read the way setup reads it so the two never disagree
`needs_from`: Read the way setup reads it, so the two never disagree.

#### Credential store keeps more than the screenshot key
`needs_from`: It keeps more than the screenshot key here.

#### No calendar is read while calendar use is off
`needs_from`: No calendar is read while calendar use is off.

#### Settings and setup read every permission from the same check
`settings_reads_each_permission_as_setup_does`: Every permission setup asks about is read from the same check here,
whatever that check says.

#### Microphone says it is checked on first record; Windows names its switch
`an_unknown_state_is_never_claimed_either_way`: The microphone says when it is checked instead; Windows also names
its own privacy switch.

#### Text capture and X11 autocomplete read through accessibility
`needs_follow_the_features_that_are_on`: Text capture and autocomplete on X11 read through accessibility.

#### On Wayland autocomplete goes through the input method instead
`needs_follow_the_features_that_are_on`: On Wayland autocomplete goes through the input method instead.

### `LinuxWindows/crates/lokalbot-app/src/control/setup.rs`

#### Agent setup request: allow turns on settings grant plus ticked access; answer written to setup-answer.json
The request an agent left with `lokalbot-cli setup start`, shown to the person
in the agent setup window (`AgentSetupRequests.swift`). Allowing it turns on
the settings grant, plus whichever read access the person ticks; declining
leaves everything off. Each request is answered once, and the answer is written
back to `control/setup-answer.json` for the CLI to read.

#### A box counts only if requested; asking grants nothing
`grant_read_access`: Turns on what the person ticked among what the request asked for, and says what
took. A box counts only if the request asked for it, and asking grants nothing.
`file_folders` is what Files reads, or `None` while Files is off.

#### An unwritable folder list doesn't undo the grant
`grant_read_access`: A list that can't be written doesn't undo the grant: the CLI
then says Files has no folder yet.

#### Unreadable or expired requests are answered and removed
`ControlHost.check_setup`: Picks up a request left by the CLI. An unreadable or expired request is
answered and removed. A new one opens its window.

#### Declining on a new install leads to onboarding
`ControlHost.deny_setup`: A new install still needs its setup, so declining leads to onboarding.

#### Setup launch has no window; without a tray nothing leads back
`ControlHost.after_setup_answer`: A setup launch has no main window; without a tray icon nothing else would
lead back to LokalBot.

#### Remove only the request answered; the CLI may have left a newer one
`ControlHost.answer_setup`: Only remove the request this answers; the CLI may have left a newer one.

### `LinuxWindows/crates/lokalbot-app/src/control/wake.rs`

#### CLI wake file starts the Think server, kept warm ten minutes after last question
The local-model wake behind `ask_library` and `lokalbot-cli ask`
(`AgentAccessManager.swift`): the CLI leaves a file in `control/`, and while
meeting access is on the app starts its Think server and keeps it warm for
follow-ups, returning the memory ten minutes after the last question.

#### Failure strings are the messages the CLI relays to agents
`ControlHost.tick_wake`: The failure strings are the messages the CLI relays to agents.

#### Replace the lease; revive a crashed server by leasing again
`ControlHost.tick_wake`: Replaced, not stacked; a crashed server is revived by
leasing again instead of being trusted.

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
