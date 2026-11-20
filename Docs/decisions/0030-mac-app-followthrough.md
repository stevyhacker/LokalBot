# 0030. Mac app: FollowThrough

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `LokalBot/Services/FollowThrough/`, `LokalBotTests/Services/FollowThrough/`.

## Decisions

### `LokalBot/Services/FollowThrough/AppFollowThrough.swift`

#### Reads reuse Ask's meeting tools, never screen memory
`AppFollowThroughEnvironment`: The library reads and hand-offs behind Follow-through. Reads reuse Ask's
meeting tools (never screen memory, which has its own permission).
Approved steps open as drafts in the person's own apps.

#### Hosted UI suite must not launch Mail or Calendar on runner
`AppFollowThroughEnvironment.open`: The hosted UI suite must not launch Mail or Calendar on the runner.

#### Match name to calendar address by full or first name; addresses never go to model
`AppFollowThroughEnvironment.address`: The calendar address for a name said in the meeting, matched on the
full name or the first name. Addresses never go to the model.

#### Briefing gives names only; calendar addresses stay local
`FollowThroughBriefing.make`: What the model is told about the action. Names only: calendar
addresses stay local.

#### Briefing uses the Settings Writing name so drafts are signed
`AppState.startFollowThrough`: The name from Settings → Writing, so drafts are signed.

#### Hosted film uses scripted replies or Meta models in Meta wire format
`AppState.startFollowThrough`: The hosted film runs Follow-through on scripted replies, or on
Meta's models with the film's key. Both speak Meta's wire format.

#### Uses Think model as set at each turn, with its own gates
`AppState.startFollowThrough`: The Think model, as Settings → Models has it at each turn: its
server, its approval and its request gate are Think's own.

### `LokalBot/Services/FollowThrough/FollowThroughReplay.swift`

#### Replay runs real loop on synthetic fixtures; key from META_API_KEY, nothing touched
`FollowThroughReplay`: `LokalBot --follow-through-replay <fixture.json> [--model <id>]`

Runs Follow-through's real loop and Meta Model API client against a
fixture meeting: read tools answer from the fixture, and every proposal is
recorded and approved without being carried out. Prints one JSON line per
step and a summary. For synthetic fixtures only: the key is read from
`META_API_KEY`, and no library, Keychain, mail, or calendar is touched.

### `LokalBot/Services/FollowThrough/FollowThroughSession.swift`

#### Nothing leaves the Mac without approval, and then only as a draft
`FollowThroughSession`: One Follow-through run: the Think model plans the work for one action,
reads what it needs from the library, and proposes steps. Each step waits
for the person to approve, edit, or decline it; nothing leaves the Mac as
an email, invitation, or task without that click, and even then it opens
as a draft.

#### Cost is zero on Think model, which reports no token use
`FollowThroughSession.cost`: Zero on the Think model, which reports no token use. The hosted film
runs on Meta's models, which do.

#### One tool call per turn; 4,000 tokens fit a draft email or coding task
`FollowThroughSession.turnOptions`: One tool call per turn; a draft email or a coding task is the longest.

#### Tell the model the final version so it knows the person's changes
`FollowThroughSession.describe`: The final version, so the model knows what the person changed.

#### Only names go to the model; typed addresses stay local
`FollowThroughSession.describe`: Names only: addresses the person typed stay on this Mac.

### `LokalBot/Services/FollowThrough/FollowThroughTools.swift`

#### Saved action id is needed for Mark Done
`FollowThroughTarget.actionID`: The saved action, when there is one; Mark Done needs it.

#### Evidence lines look like '00:12:09 Me: ...'
`FollowThroughTarget.evidence`: Where it was said: "00:12:09 Me: I'll send the deck to Marko by Friday."

#### Nothing happens until approved; every field editable first
`FollowThroughProposal`: A step the model proposes. Nothing happens until the person approves it,
and they may edit every field first.

#### Opens a mail draft; the person sends it there
`FollowThroughProposal.Kind.email`: Opens a draft in the mail app; the person sends it there.

#### Opens an invitation in Calendar; the person adds it there
`FollowThroughProposal.Kind.event`: Opens an invitation in Calendar; the person adds it there.

#### Fills a prompt into Claude Code or Codex; the person sends it
`FollowThroughProposal.Kind.codingTask`: Fills a prompt into Claude Code or Codex; the person sends it there.

#### Tool call id so the result returns to the right call
`FollowThroughProposal.id`: The tool call id, so the result goes back to the right call.

#### Read tools reuse Ask's; proposal tools only describe steps
`FollowThroughTools`: Tool schemas and argument checks. Read tools reuse Ask's library tools;
the proposal tools only describe a step for the person to approve.

#### Malformed call reason goes back to model to self-correct
`FollowThroughTools.proposal`: A proposal from a tool call, or the reason the call was malformed,
which goes back to the model so it can correct itself.

#### Unsent mailto draft; names without addresses go in body greeting
`FollowThroughTools.mailtoURL`: A `mailto:` link the mail app opens as an unsent draft. Names without
a known address go into the body's greeting instead of the header.

#### Encode plus as %2B because some mail clients read it as space
`FollowThroughTools.mailtoURL`: `+` is a space in some mail clients' query parsing.

#### Attendees with addresses listed; others named in notes
`FollowThroughTools.icsDocument`: An iCalendar invitation for Calendar to import. Attendees with a known
address are listed; the rest are named in the notes.

### `LokalBotTests/Services/FollowThrough/FollowThroughTests.swift`

#### Follow-through runs on Think model returning JSON text calls, earlier calls as context
`FollowThroughSessionTests.testTheLoopRunsOnAThinkEngine`: Follow-through runs on the Think model, which returns text, not tool
calls: each turn is one JSON call that `ThinkChat` reads, and earlier
calls travel as context with what they returned.

#### Model without a schema wraps the call in prose
`FollowThroughSessionTests.testTheLoopRunsOnAThinkEngine`: A model without a schema to hold it wraps the call in prose.

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
