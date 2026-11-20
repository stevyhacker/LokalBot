# 0048. Mac app: SelectionActions

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `LokalBot/Models/SelectionActions/`, `LokalBot/Services/SelectionActions/`, `LokalBot/Views/SelectionActions/`.

## Decisions

### `LokalBot/Models/SelectionActions/SelectionAction.swift`

#### Rewrite actions replace the selection in place; others produce text that is copied
`SelectionAction`: A built-in action on text selected in another app, or a typed instruction.
Actions that rewrite the selection can replace it in place; the others
produce new text (an answer, a summary, a reply) that is copied instead.

#### Reads matching meetings and work memory before writing
`SelectionAction.usesMemory`: Reads matching meetings and work memory before writing.

#### False for actions that only make sense on selected text
`SelectionAction.worksWithoutSelection`: False for actions that only make sense on selected text.

#### Typed instruction replaces a selection, or writes new text at cursor
`SelectionAction.custom`: A typed instruction. With a selection it can replace it; without one
it writes new text at the cursor.

#### Panel lists source meetings so the result can be checked
`SelectionMemoryContext`: Retrieved work memory for one request: prompt-ready excerpts plus the
meetings they came from, which the panel lists so the result can be checked.

#### Prompt text is pure so tests pin what the model is told
`SelectionActionPrompt`: Prompt text for selection actions. Pure, so tests can pin what the model
is told without an engine.

#### No thinking turn because someone waits to paste; ceiling fits long rewrites
`SelectionActionPrompt.options`: No thinking turn: someone is waiting to paste. The output ceiling fits
a long rewritten passage.

#### Longer selections are cut and the panel says so
`SelectionActionPrompt.selectionCharacterLimit`: The selection sent to the model. Longer selections are cut, and the
panel says so.

#### Memory search uses the selection start, where messages state their topic
`SelectionActionPrompt.memoryQueryCharacterLimit`: What the memory search looks for: the start of the selection is where
a message usually says what it is about.

#### Strip reasoning, fences, quotes wrapping the answer; applies to partial output
`SelectionActionPrompt.normalizedOutput`: Strips reasoning, code fences, and quotation marks the model wrapped
around the whole answer. Applied to partial output too.

### `LokalBot/Services/SelectionActions/SelectionActionsController.swift`

#### Selection actions run on Think model; nothing is persisted
`SelectionActionsController`: Selection actions: a system-wide shortcut reads the text selected in the
frontmost app, the panel runs the Think model on it (optionally with
matching work memory), and the result replaces the selection, goes in at
the cursor, or is copied. Nothing here is persisted.

#### Unconfirmed paste leaves result on clipboard
`SelectionActionsController.DeliveryOutcome.unconfirmed`: Pasted, but the app never read it; the result stays on the clipboard.

#### Copied outcome carries reason and result is on clipboard
`SelectionActionsController.DeliveryOutcome.copied`: Not pasted, for this reason; the result is on the clipboard.

#### Notice explains why paste back failed, shown above result
`SelectionActionsController.notice`: Why the last result could not be pasted back; shown above it.

#### Generation counter stops superseded requests writing state
`SelectionActionsController.generation`: Bumped by every new request, so a superseded one never writes state.

#### Read selection before opening panel because panel moves focus
`SelectionActionsController.invoke`: The shortcut was pressed. Reads the selection first, because opening
the panel moves focus away from it.

#### Shortcut while LokalBot frontmost preserves open panel state
`SelectionActionsController.invoke`: Pressed while LokalBot is in front: keep any open panel's state.

#### Copy returns focus to source app ready for paste and closes panel
`SelectionActionsController.copyOutput`: Copies the result and hands focus back to the app it came from, ready
for ⌘V. The panel closes.

#### Insert replaces selection; if field changed panel returns with result copied
`SelectionActionsController.insertOutput`: Replaces the selection with the result, or inserts it at the cursor
when nothing was selected. The panel closes; if the field changed
meanwhile, the panel comes back with the result already copied.

#### Restore panel only if nothing newer took it
`SelectionActionsController.insertOutput`: Nothing newer took the panel meanwhile.

#### Replacement needs exact selection match; dictation fallback is looser
`SelectionDelivery.check`: Replacement requires the exact optional selection, including a range
being cleared to a caret. Dictation's app-only fallback is less strict.

### `LokalBot/Services/SelectionActions/SelectionCapture.swift`

#### Captured text lives only in memory for panel lifetime
`SelectionCaptureResult`: What the selection actions shortcut found in the frontmost app. The text
lives only in memory for the panel's lifetime and is never stored.

#### Excluded app is never read
`SelectionCaptureResult.Issue.excludedApp`: The app is on the user's exclusion list; nothing was read.

#### Secure fields are never read
`SelectionCaptureResult.Issue.secureField`: A password or other secure field has focus; nothing was read.

#### Unverified focus accepts no selection
`SelectionCaptureResult.Issue.focusChanged`: Focus changed or could not be verified; no selection is accepted.

#### Target is nil for read-only text such as web pages or PDFs
`SelectionCaptureResult.target`: The editable field the selection sits in (with its selection range),
where a result can replace the selection or be inserted at the caret.
Nil for read-only text such as a web page or a PDF.

#### Flag set when selection was read via copy with clipboard restored
`SelectionCaptureResult.readThroughClipboard`: The app did not share its selection through Accessibility, so LokalBot
copied it and restored the clipboard.

#### Accessibility first; synthetic Cmd-C fallback for Electron and web views
`SelectionCapture`: Reads the selected text in the frontmost app once, on an explicit
shortcut press. Accessibility comes first; apps that do not expose their
selection that way (many Electron and web views) get a synthetic ⌘C whose
result is read and the previous clipboard put back.

#### Keep up to 50,000 characters; prompt uses less
`SelectionCapture.maximumCharacters`: Longest selection kept in memory; the prompt uses less.

#### Only editable fields have identity; read-only text cannot take replacement
`SelectionCapture.capture`: Only an editable field has an identity; read-only text cannot take a replacement.

#### Read off main thread with deadline so wedged apps cost short wait
`SelectionCapture.readThroughAccessibility`: Off the main thread with a wall-clock deadline, so a wedged app costs
a short wait instead of a beachball.

#### Cmd-C fallback may be recorded by clipboard managers; clipboard restored marked generated
`SelectionClipboardCopy`: The ⌘C fallback. The copy comes from the source app, so clipboard managers
may record it like any copy the person makes; the previous clipboard is
restored right after, marked as generated.

#### Wait for shortcut modifiers to release since Ctrl-Shift-Cmd-C is not Copy
`SelectionClipboardCopy.copySelection`: The shortcut's own modifiers may still be held; ⌃⇧⌘C is not Copy.

#### Unchanged change count means nothing selected and clipboard untouched
`SelectionClipboardCopy.copySelection`: Nothing selected: the app copied nothing and the clipboard is untouched.

#### Recheck after copy; never read changed app or restore newer clipboard
`SelectionClipboardCopy.copySelection`: Re-check after the app handles Copy. A changed app/secure field is
never read, and a newer clipboard generation is not ours to restore.

#### Mark synthetic events so Autocomplete and Dictation taps ignore them
`SelectionClipboardCopy.postCommandC`: Marked so Autocomplete's and Dictation's input taps ignore it.

#### Post to pid so destination holds even if focus moves
`SelectionClipboardCopy.postCommandC`: Bind the event destination even if focus moves between validation and posting.

### `LokalBot/Views/SelectionActions/SelectionActionsView.swift`

#### Typed instructions read meetings and work memory unless turned off
`SelectionActionsContent.instructionUsesMemory`: Typed instructions read matching meetings and work memory unless this
is turned off.

#### Typed instruction leads unless it is just the start of an action name
`SelectionActionsContent.rows`: A typed instruction leads, unless it is just the start of an action's name.

#### Built-in titles are localized interface text; typed instruction is verbatim user text
`SelectionActionsContent.title`: Built-in titles are interface text; a typed instruction is the user's.

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
