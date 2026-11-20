# 0031. Mac app: Handoff

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `LokalBot/Services/Handoff/`.

## Decisions

### `LokalBot/Services/Handoff/WindowHandoffCapture.swift`

#### Capture lives in memory until handed off or panel closes
`WindowHandoffCapture`: What Hand off read from the focused window on one press: its whole text,
a screenshot when Screen Recording is allowed, and where it came from.
It lives in memory until the person hands it off or closes the panel.

#### Also set when address unreadable while site exclusions exist
`WindowHandoffCapture.Issue.excludedSite`: The page, or a page framed in it, is on the site exclusion list,
or its address could not be read while site exclusions are set.

#### Password field focused or visible; nothing kept
`WindowHandoffCapture.Issue.secureField`: A password field is focused or visible; nothing was kept.

#### Also set when focus moved during reading
`WindowHandoffCapture.Issue.unreadable`: The window could not be read, or focus moved while reading it.

#### Reading-order text with credentials, cards and IBANs redacted
`WindowHandoffCapture.text`: The window's text in reading order, with credentials, card numbers,
and IBANs redacted.

#### Selection is redacted the same way
`WindowHandoffCapture.selection`: What was selected in the window, redacted the same way.

#### Screenshot dropped when anything redacted since pixels still show it
`WindowHandoffCapture.screenshot`: A PNG of the window. Dropped when anything was redacted, because the
pixels would still show it.

#### Text read from screenshot when app shares little Accessibility text
`WindowHandoffCapture.textFromScreenshot`: The text came from reading the screenshot, because the app shares
little or no text through Accessibility.

#### Same exclusions and secure-field checks as screen memory; never stored there
`WindowHandoffCapturer`: Reads the focused window once, on an explicit Hand off press. The same
exclusions and secure-field checks as screen memory apply; the read is
never stored in screen memory.

#### Below 200 Accessibility characters, read screenshot text instead
`WindowHandoffCapturer.thinTextCharacters`: Below this many characters of Accessibility text, the screenshot's
text is read instead.

#### Unknown focus without secure field is fine since shortcut was deliberate
`WindowHandoffCapturer.issue`: Why the window's content must not be read, or nil. Unlike screen
memory, an unknown focus with no secure field in the window is fine:
the person pressed the shortcut on purpose.

#### Keep pixels only if same window stays focused and passes privacy checks
`WindowHandoffCapturer.screenshot`: The focused window's pixels, kept only when the same window is still
focused afterwards and still passes the privacy checks.

### `LokalBot/Services/Handoff/WindowHandoffController.swift`

#### Every handoff target runs on this Mac
`WindowHandoffTarget`: Where a window handoff goes. Every target runs on this Mac.

#### Shortcut reads window, Think model writes reviewable brief, package goes to target
`WindowHandoffController`: Hand off: a system-wide shortcut reads the focused window, the Think
model writes a brief the person reviews and edits, and the task goes to
the target they pick, with a package folder holding the full context.

#### Shortcut pressed with LokalBot frontmost means no window to read
`WindowHandoffController.needsSourceWindow`: The shortcut was pressed while LokalBot was in front, so there was no
other window to read.

#### Bumped per request so superseded ones never write state
`WindowHandoffController.generation`: Bumped by every new request, so a superseded one never writes state.

#### Read window before panel opens because panel takes focus
`WindowHandoffController.invoke`: The shortcut was pressed. Reads the window before the panel opens,
because the panel takes focus from it.

#### Keep an open handoff; otherwise tell the person what to do
`WindowHandoffController.invoke`: Keep a handoff that is already open; otherwise say what to do.

### `LokalBot/Services/Handoff/WindowHandoffPackage.swift`

#### Prompt builder is pure so tests pin what model is told
`WindowHandoffBriefPrompt`: The prompt that turns a captured window into a handoff brief. Pure, so
tests can pin what the model is told without an engine.

#### No thinking turn because the person waits in review panel
`WindowHandoffBriefPrompt.options`: No thinking turn: the person is waiting in the review panel.

#### Limit applies to text sent to model; package keeps all
`WindowHandoffBriefPrompt.textCharacterLimit`: The window text sent to the model. The package keeps all of it.

#### Template brief used when person skips model or it fails
`WindowHandoffBriefPrompt.templateBrief`: The brief used when the person skips the model or it fails: what the
window is, and where its text is.

#### Package is private plain-file folder, deleted after retention; layout fixed
`WindowHandoffPackage`: One handoff on disk: a folder of plain files the receiving agent reads,
private to this user, deleted after `retention`.

\<library>/handoffs/2026-10-27-0812-fix-safari-export/
handoff.md      the brief
handoff.json    manifest
context/page.md the window's full text
screens/01.png  the screenshot, when there is one

#### Writing a package also prunes ones older than retention
`WindowHandoffPackage.write`: Writes the package and deletes packages older than `retention`.

#### Brief clipped to limit; points agent at full package folder
`WindowHandoffPackage.prompt`: The prompt a link target gets: the brief fitted to `limit`, and where
the full package is.

#### Agent Mode attaches text up to 55,000 chars; longer stays in folder
`WindowHandoffPackage.agentModeAttachmentLimit`: Agent Mode reads the window's text as an attachment up to this size;
longer text stays in the copied folder for the agent to read.

#### Agent Mode working folder holds a copy of the package
`WindowHandoffPackage.agentModePrompt`: The prompt for an Agent Mode task, whose working folder holds a copy
of the package at `folder`.

#### Age from manifest, or folder itself when manifest unreadable
`WindowHandoffPackage.prune`: Deletes package folders whose manifest, or the folder itself when the
manifest is unreadable, is older than `retention`.

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
