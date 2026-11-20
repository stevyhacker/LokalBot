# 0034. Mac app: LiveRadar

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `LokalBot/Views/LiveRadar/`.

## Decisions

### `LokalBot/Views/LiveRadar/FilmCallWindow.swift`

#### UI-test host only: stand-in video call behind Live Radar panel for film
`FilmCall`: UI-test host only: with `LOKALBOT_UI_TEST_CALL=1`, Start Radar also opens
a stand-in video call behind the floating Live Radar panel, so the
hackathon film shows the panel over a call the way it is used. The call
shows the live script's words as they arrive in the live transcript, so
its captions and speaking tiles keep time with the radar. Open LokalBot in
the panel closes it, which brings the LokalBot window behind it forward.

#### One accessibility element: XCUITest tree reads slowed the film script
`FilmCall.body`: One element: XCUITest reads the app's whole tree a few times a
second during the film, and the call's views slowed the script down.

### `LokalBot/Views/LiveRadar/FollowThroughSheet.swift`

#### Disclosure follows wherever Think model runs; blocked shows as run error
`FollowThroughSheet.destination`: Where the action and what is read about it go: wherever the Think
model runs. A blocked connection shows as the run's own error.

#### Pending steps editable; the person's edited version is what runs
`ProposalCard`: One proposed step. Pending steps are editable; the person's version is
what runs.

#### Set on Approve or Decline so a second click cannot send twice
`ProposalCard.submitted`: Set on Approve or Decline, so a second click can't send twice while the
step runs.

### `LokalBot/Views/LiveRadar/LiveRadarFloatingPanel.swift`

#### Floating panel never takes focus, opens on recording/radar start, hidden from capture by default
`LiveRadarPanelController`: A small always-on-top window with Live Radar, for checking it from the
meeting app: it floats over other apps and full-screen calls and never
takes focus from them. It opens when a recording starts (if Live Radar is
on, with Start Radar in it) and when the radar starts, remembers where
it was dragged, and collapses to its header. By default it is left out of
screen sharing and screen recordings.

#### Hide-from-sharing applies at once, using published value not app.settings
`LiveRadarPanelController.init`: "Hide from screen sharing" applies at once, also to a panel that is
already up: `show()` alone set it only the next time the panel
opened. The published value is the new one; `app.settings` is not yet.

#### Turning panel setting off takes down open panel; menu bar item still opens it
`LiveRadarPanelController.init`: Turning "Show the floating Live Radar panel" off also takes down a
panel that is already up. The menu bar item still opens it on request.

#### Visible to sharing only if hiding turned off; films need it visible
`LiveRadarPanelController.sharingType`: Shown to others when sharing the screen only if the person turned the
hiding off, for example to record a demo. Films need it visible.

#### Floating-window subrole for VoiceOver and UI tests, not a dialog
`LiveRadarPanelController.makePanel`: A floating window to VoiceOver (and to UI tests), not a dialog
waiting for an answer.

#### Collapsing keeps top edge fixed
`LiveRadarPanelController.resize`: Keeps the top edge where it is, so collapsing pulls the bottom up.

#### Restore saved origin if on a screen; else top-right of front screen
`LiveRadarPanelController.origin`: Where it was left, if that is still on a screen; else the top-right
corner of the screen in front.

#### Clicked item stays in spotlight until a newer one arrives
`LiveRadarPanelModel.pinnedID`: An item the person clicked, shown in the spotlight until a newer one
arrives.

#### Microphone track is the person; call track is everyone else
`LiveRadarPanelView.transcriptLine`: The microphone track is the person; the call track is everyone else.

### `LokalBot/Views/LiveRadar/LiveRadarSettingsSection.swift`

#### Live Radar reads with Think model from Models settings; no model picker here
`LiveRadarSettingsSection`: Settings → Meetings → Live Radar: whether it is offered, what it may look
up to answer a question, and its floating panel. It reads with the Think
model chosen in Settings → Models, so there is no model to pick here.

### `LokalBot/Views/LiveRadar/MeetingRadarPanel.swift`

#### Nothing sent until Start Radar pressed for this meeting
`MeetingRadarPanel`: Live Radar in the live meeting view: the main area, beside the transcript
and notes. Nothing is sent until the person presses Start Radar for this
meeting; once it runs, the floating panel shows the same items over the
meeting app.

#### Think model reports no cost; show cost only when present
`MeetingRadarPanel.passSummary`: The Think model reports no cost, so the cost shows only when there is one.

#### One colour per kind across board, floating panel and meeting page
`RadarItem.Kind.tint`: One color per kind across the board, the floating panel, and the
meeting page.

#### Item order: contradictions and screen-answered questions first, full width; used live and finished
`RadarItemList`: Radar items as cards: contradictions and questions answered from the
screen first and full width, then commitments, decisions, and questions
in a grid, newest first. Used live and on the finished meeting.

#### Follow-through offered on own commitments once meeting has ended
`RadarItemList.followThrough`: Offered on the person's own commitments once the meeting has ended.

#### Meeting folder is where screen-answer crops are saved
`RadarItemList.folder`: The meeting folder, where screen-answer crops are saved.

#### False inside a page that already scrolls
`RadarItemList.scrolls`: False inside a page that already scrolls.

#### Accessibility id prefix keeps floating panel copies from colliding with main window
`RadarCard.idPrefix`: Prefix of the accessibility identifiers, so the floating panel's
copies don't collide with the main window's.

#### False where a popover cannot open, as in floating panel
`RadarCard.allowsEnlarge`: False where a popover can't open, as in the floating panel.

#### Panel too narrow for readable crop; board has room
`RadarCard.body`: The panel is narrow; the board has room for a readable crop.

### `LokalBot/Views/LiveRadar/MetaMuseSettingsSection.swift`

#### Meta Muse key and approval only for fast live text; radar runs on Think
`MetaMuseSettingsSection`: Settings → Meetings → Meta Muse: the key and the api.meta.ai approval for
fast live text, the one thing that still uses Meta's models. Live Radar
and Follow-through run on the Think model.

#### Acknowledge a saved key only if it reads back from Keychain
`MetaMuseSettingsSection.keyControl`: Acknowledge only what reads back from Keychain.

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
