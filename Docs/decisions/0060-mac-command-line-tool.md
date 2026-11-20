# 0060. Mac command-line tool

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `CLI/Commands/`.

## Decisions

### `CLI/Commands/ApprovalCommands.swift`

#### Exit codes 3, 4, 5 distinguish waiting, denied and expired requests
`ApprovalExit`: Exit codes for requests that need the person, so a script can tell a
request still waiting from one they declined or nobody answered.

#### Waiting request exits 3; --wait follows to 0, 4 or 5
`ControlOutput.sendForApproval`: Sends a request that may need the person and prints the reply. A
request left waiting prints as JSON and exits 3, or, with --wait, is
followed until the person answers: 0 approved, 4 denied, 5 expired.

#### Polling never starts LokalBot; a request lives only in the copy that took it
`ControlOutput.waitForAnswer`: Polls the running app until the request is answered or `seconds` pass.
Never starts LokalBot: a request lives only in the copy that took it.

### `CLI/Commands/AskCommand.swift`

#### Engine enforces the character limit; the byte check only bounds memory
`readMessageFromStandardInput`: The engine checks the character limit; this only bounds memory.

#### Failures exit with status 1 after printing JSON that says why
`printAskOutcome`: Prints JSON or text on standard output; failures exit with status 1 so
scripts notice, after the JSON that says why.

### `CLI/Commands/ImportCommand.swift`

#### Import preview shows titles and counts only, never notes or transcripts
`ImportCommand.previewJSON`: What the files hold, newest first. Titles and counts only: notes and
transcripts stay in the files.

### `CLI/Commands/PersonalContextCommand.swift`

#### A switched-off feature prints its error code, as the MCP tools do
`PersonalContextCommand failure handling`: A switch that is off prints its code, as the MCP tools do.

### `CLI/Commands/SearchFilesCommand.swift`

#### A switched-off feature prints its error code, as the MCP tools do
`SearchFilesCommand failure handling`: A switch that is off prints its code, as the MCP tools do.

### `CLI/Commands/SearchNotesCommand.swift`

#### A switched-off feature prints its error code, as the MCP tools do
`SearchNotesCommand failure handling`: A switch that is off prints its code, as the MCP tools do.

### `CLI/Commands/SetupCommands.swift`

#### Check appResponding after approval because the socket opens just after
`SetupStartCommand`: The socket opens right after the person allows it.

#### Open or notify LokalBot; return a hint when the CLI cannot start it
`SetupStartCommand.show`: Opens LokalBot on the request, or tells a running copy to show it.
Returns a hint when this CLI can't start LokalBot itself.

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
