# 0004. Mac app: AgentAccess

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `LokalBot/Services/AgentAccess/`, `LokalBotTests/Services/AgentAccess/`.

## Decisions

### `LokalBot/Services/AgentAccess/AgentAccessManager.swift`

#### Surface enable failures so Privacy toggle is not silently off
`AgentAccessManager.onError`: Surfaces enable failures to the user (feeds `AppState.lastError`); a
silently-off Privacy toggle would read as a broken switch.

#### Test seam; production wakes via wakeMainLLM with TTL lease
`AgentAccessManager.startEngine`: Test seam. When nil (production), wakes go through `wakeMainLLM`,
which holds a TTL lease on the broker.

#### Lease replaced not stacked; released on disable; expires on TTL
`AgentAccessManager.agentLease`: The lease behind the most recent ask_library wake. Replaced (not
stacked) on every wake; released on disable; expires on its own TTL.

#### Ten-minute TTL keeps model warm for follow-up questions
`AgentAccessManager.agentLeaseTTL`: One external question rarely comes alone: the TTL keeps the model
warm for follow-ups, then returns the RAM ten minutes after the last.

#### Release lease again if disable raced the wake
`AgentAccessManager wake handling`: Disable may race a suspended ensure and run before the fresh
lease is assigned. Release again after the wake completes.

#### Failure strings are relayed verbatim to external agents
`AgentAccessManager.resolveBuiltInModelURL`: Pure resolution half of the wake path. The failure strings are the
exact messages the CLI relays to external agents — keep them verbatim.

#### Acquire fresh lease before releasing old; revives crashed server
`AgentAccessManager.acquireOrRenewAgentLease`: Acquires a fresh TTL lease, then releases the previous one — in that
order, so the lease count never dips to zero and starts a linger.
Re-acquiring instead of renewing means the broker's ensure runs on
every wake: a llama-server that crashed since the last question is
revived instead of trusted.

### `LokalBot/Services/AgentAccess/AgentReadAccess.swift`

#### One switch writes per-kind markers; on exactly while a kind is granted
`AgentReadAccess`: Settings → External Agents: one switch for reading LokalBot data,
with a box for each kind under it. Each kind keeps its own marker in
`control/`, which is what `lokalbot-cli` and its MCP server check, with the
app closed too. The switch only writes and removes those markers: turning
it on grants the ticked kinds; turning it off removes them all and
remembers the boxes and the screen history range for next time.

The switch is on exactly while some kind is granted, so grants made before
it existed (a toggle per kind), or by an agent setup request, show as they
are and nothing widens on upgrade. Changing LokalBot's settings stays a
separate grant.

#### Remember boxes and history range while switch is off
`AgentReadAccess.Choices`: The boxes and history range while the switch is off.

#### Switch and boxes follow grants changed by setup and managers
`AgentReadAccess.init`: Agent setup and the per-kind managers change grants directly; the
switch and boxes follow them.

#### Box shows granted when on, remembered when off
`AgentReadAccess.isTicked`: What the box shows: granted while the switch is on, remembered while it is off.

#### Last ticked box cannot be unticked; switch turns all off
`AgentReadAccess.canUntick`: The last ticked box can't be unticked; the switch turns everything off.

#### Feature page box grants exactly its kind; last untick turns switch off
`AgentReadAccess.setGranted`: A feature page's own box for its kind. Ticking it grants exactly that
kind, turning the main switch on without granting the others;
unticking the last granted kind turns the switch off.

#### Granted screen history is the one shown while off
`AgentReadAccess.setGranted`: The history shown while screen memory was off is the one granted.

### `LokalBotTests/Services/AgentAccess/AgentReadAccessTests.swift`

#### One switch writes per-kind markers, remembers boxes while off, never widens old grants
`AgentReadAccess`: The one switch for reading LokalBot data and its boxes: it writes and
removes the per-kind markers agents check, remembers the boxes while off,
and never widens a grant made before it existed.

#### A feature page's own box grants only that kind, never other kinds
`AgentReadAccess.setGranted`: A feature page's own box grants that kind alone: ticking Files on the
Files page never lets agents read meetings too.

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
