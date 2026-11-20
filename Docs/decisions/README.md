# Decisions

Architecture decision records: the reasons, measurements, platform quirks,
privacy boundaries and invariants that the code cannot show. Code carries no
comments ([ADR 0001](0001-code-carries-no-comments.md)), so a non-obvious
decision is written here, under the file and symbol it concerns.

To find why a line is the way it is, open the ADR for its area below and search
for the symbol. To record a decision, add an entry to that ADR (a `####` heading
that states the decision, the symbol in backticks, then the reasoning); a
decision that changes an earlier one replaces its entry. A new area or a
decision that cuts across areas gets the next free number. The
[`/delete-comment` skill](../../.claude/skills/delete-comment/SKILL.md) describes
how comments are moved here.

| ADR | Area | Entries |
| --- | --- | ---: |
| [0001](0001-code-carries-no-comments.md) | Code carries no comments | — |
| [0002](0002-mac-app-actions.md) | Mac app: Actions | 172 |
| [0003](0003-mac-app-agent.md) | Mac app: Agent | 304 |
| [0004](0004-mac-app-agentaccess.md) | Mac app: AgentAccess | 16 |
| [0005](0005-mac-app-agentmemory.md) | Mac app: AgentMemory | 32 |
| [0006](0006-mac-app-app.md) | Mac app: App | 154 |
| [0007](0007-mac-app-appcontrol.md) | Mac app: AppControl | 60 |
| [0008](0008-mac-app-ask.md) | Mac app: Ask | 176 |
| [0009](0009-mac-app-audio.md) | Mac app: Audio | 229 |
| [0010](0010-mac-app-autocomplete.md) | Mac app: Autocomplete | 39 |
| [0011](0011-mac-app-clisupport.md) | Mac app: CLISupport | 293 |
| [0012](0012-mac-app-clisupport-meetingimport.md) | Mac app: CLISupport — MeetingImport | 332 |
| [0013](0013-mac-app-calendar.md) | Mac app: Calendar | 97 |
| [0014](0014-mac-app-capture.md) | Mac app: Capture | 24 |
| [0015](0015-mac-app-chat.md) | Mac app: Chat | 116 |
| [0016](0016-mac-app-codingagents.md) | Mac app: CodingAgents | 129 |
| [0017](0017-mac-app-companion.md) | Mac app: Companion | 98 |
| [0018](0018-mac-app-components.md) | Mac app: Components | 38 |
| [0019](0019-mac-app-cotyping.md) | Mac app: Cotyping | 830 |
| [0020](0020-mac-app-cotyping-tests.md) | Mac app: Cotyping tests | 190 |
| [0021](0021-mac-app-cotyping-llama.md) | Mac app: Cotyping — Llama | 143 |
| [0022](0022-mac-app-diagnostics.md) | Mac app: Diagnostics | 6 |
| [0023](0023-mac-app-dictation.md) | Mac app: Dictation | 224 |
| [0024](0024-mac-app-dreaming.md) | Mac app: Dreaming | 152 |
| [0025](0025-mac-app-email.md) | Mac app: Email | 136 |
| [0026](0026-mac-app-engines.md) | Mac app: Engines | 493 |
| [0027](0027-mac-app-engines-tests.md) | Mac app: Engines tests | 107 |
| [0028](0028-mac-app-engines-subscription.md) | Mac app: Engines — Subscription | 112 |
| [0029](0029-mac-app-filesearch.md) | Mac app: FileSearch | 137 |
| [0030](0030-mac-app-followthrough.md) | Mac app: FollowThrough | 27 |
| [0031](0031-mac-app-handoff.md) | Mac app: Handoff | 28 |
| [0032](0032-mac-app-health.md) | Mac app: Health | 10 |
| [0033](0033-mac-app-huggingface.md) | Mac app: HuggingFace | 20 |
| [0034](0034-mac-app-liveradar.md) | Mac app: LiveRadar | 27 |
| [0035](0035-mac-app-meetingradar.md) | Mac app: MeetingRadar | 125 |
| [0036](0036-mac-app-meetings.md) | Mac app: Meetings | 452 |
| [0037](0037-mac-app-modelsetup.md) | Mac app: ModelSetup | 125 |
| [0038](0038-mac-app-notes.md) | Mac app: Notes | 138 |
| [0039](0039-mac-app-onboarding.md) | Mac app: Onboarding | 72 |
| [0040](0040-mac-app-people.md) | Mac app: People | 127 |
| [0041](0041-mac-app-permissions.md) | Mac app: Permissions | 25 |
| [0042](0042-mac-app-personalmodel.md) | Mac app: PersonalModel | 103 |
| [0043](0043-mac-app-projects.md) | Mac app: Projects | 120 |
| [0044](0044-mac-app-recording.md) | Mac app: Recording | 223 |
| [0045](0045-mac-app-resources.md) | Mac app: Resources | 29 |
| [0046](0046-mac-app-screenmemory.md) | Mac app: ScreenMemory | 253 |
| [0047](0047-mac-app-search.md) | Mac app: Search | 114 |
| [0048](0048-mac-app-selectionactions.md) | Mac app: SelectionActions | 40 |
| [0049](0049-mac-app-settings.md) | Mac app: Settings | 299 |
| [0050](0050-mac-app-speakers.md) | Mac app: Speakers | 107 |
| [0051](0051-mac-app-storage.md) | Mac app: Storage | 25 |
| [0052](0052-mac-app-support.md) | Mac app: Support | 316 |
| [0053](0053-mac-app-timeline.md) | Mac app: Timeline | 408 |
| [0054](0054-mac-app-today.md) | Mac app: Today | 60 |
| [0055](0055-mac-app-transcription.md) | Mac app: Transcription | 187 |
| [0056](0056-mac-app-window.md) | Mac app: Window | 77 |
| [0057](0057-mac-app-app-shell-and-state.md) | Mac app: app shell and state | 299 |
| [0058](0058-mac-app-integration-tests.md) | Mac app: integration tests | 100 |
| [0059](0059-mac-app-test-support-and-shared-tests.md) | Mac app: test support and shared tests | 18 |
| [0060](0060-mac-command-line-tool.md) | Mac command-line tool | 11 |
| [0061](0061-windows-and-linux-agent.md) | Windows and Linux: agent | 342 |
| [0062](0062-windows-and-linux-ai-ask.md) | Windows and Linux: ai — ask | 44 |
| [0063](0063-windows-and-linux-ai-autocomplete.md) | Windows and Linux: ai — autocomplete | 326 |
| [0064](0064-windows-and-linux-ai-notes.md) | Windows and Linux: ai — notes | 112 |
| [0065](0065-windows-and-linux-ai-ocr.md) | Windows and Linux: ai — ocr | 83 |
| [0066](0066-windows-and-linux-ai-plans.md) | Windows and Linux: ai — plans | 120 |
| [0067](0067-windows-and-linux-ai-runtime.md) | Windows and Linux: ai — runtime | 117 |
| [0068](0068-windows-and-linux-ai-think.md) | Windows and Linux: ai — think | 84 |
| [0069](0069-windows-and-linux-ai-other-modules.md) | Windows and Linux: ai — other modules | 437 |
| [0070](0070-windows-and-linux-app-autocomplete.md) | Windows and Linux: app — autocomplete | 61 |
| [0071](0071-windows-and-linux-app-control.md) | Windows and Linux: app — control | 50 |
| [0072](0072-windows-and-linux-app-pages-actions.md) | Windows and Linux: app — pages / actions | 73 |
| [0073](0073-windows-and-linux-app-pages-agent.md) | Windows and Linux: app — pages / agent | 78 |
| [0074](0074-windows-and-linux-app-pages-ask.md) | Windows and Linux: app — pages / ask | 207 |
| [0075](0075-windows-and-linux-app-pages-meetings.md) | Windows and Linux: app — pages / meetings | 147 |
| [0076](0076-windows-and-linux-app-pages-projects.md) | Windows and Linux: app — pages / projects | 59 |
| [0077](0077-windows-and-linux-app-pages-settings.md) | Windows and Linux: app — pages / settings | 334 |
| [0078](0078-windows-and-linux-app-pages-timeline.md) | Windows and Linux: app — pages / timeline | 150 |
| [0079](0079-windows-and-linux-app-pages-today.md) | Windows and Linux: app — pages / today | 113 |
| [0080](0080-windows-and-linux-app-pages-other-modules.md) | Windows and Linux: app — pages, other modules | 42 |
| [0081](0081-windows-and-linux-app-state.md) | Windows and Linux: app — state | 160 |
| [0082](0082-windows-and-linux-app-ui.md) | Windows and Linux: app — ui | 124 |
| [0083](0083-windows-and-linux-app-windows.md) | Windows and Linux: app — windows | 184 |
| [0084](0084-windows-and-linux-app-other-modules.md) | Windows and Linux: app — other modules | 241 |
| [0085](0085-windows-and-linux-audio.md) | Windows and Linux: audio | 181 |
| [0086](0086-windows-and-linux-cli.md) | Windows and Linux: cli | 128 |
| [0087](0087-windows-and-linux-core-coding-agents.md) | Windows and Linux: core — coding_agents | 44 |
| [0088](0088-windows-and-linux-core-control.md) | Windows and Linux: core — control | 81 |
| [0089](0089-windows-and-linux-core-dream.md) | Windows and Linux: core — dream | 62 |
| [0090](0090-windows-and-linux-core-files.md) | Windows and Linux: core — files | 157 |
| [0091](0091-windows-and-linux-core-model.md) | Windows and Linux: core — model | 168 |
| [0092](0092-windows-and-linux-core-people.md) | Windows and Linux: core — people | 48 |
| [0093](0093-windows-and-linux-core-personal.md) | Windows and Linux: core — personal | 75 |
| [0094](0094-windows-and-linux-core-settings.md) | Windows and Linux: core — settings | 56 |
| [0095](0095-windows-and-linux-core-timeline.md) | Windows and Linux: core — timeline | 54 |
| [0096](0096-windows-and-linux-core-voice.md) | Windows and Linux: core — voice | 97 |
| [0097](0097-windows-and-linux-core-other-modules.md) | Windows and Linux: core — other modules | 526 |
| [0098](0098-windows-and-linux-engine-autocomplete.md) | Windows and Linux: engine — autocomplete | 97 |
| [0099](0099-windows-and-linux-engine-coding-agents.md) | Windows and Linux: engine — coding_agents | 111 |
| [0100](0100-windows-and-linux-engine-companion.md) | Windows and Linux: engine — companion | 155 |
| [0101](0101-windows-and-linux-engine-dictation.md) | Windows and Linux: engine — dictation | 48 |
| [0102](0102-windows-and-linux-engine-events.md) | Windows and Linux: engine — events | 75 |
| [0103](0103-windows-and-linux-engine-files.md) | Windows and Linux: engine — files | 119 |
| [0104](0104-windows-and-linux-engine-pipeline.md) | Windows and Linux: engine — pipeline | 43 |
| [0105](0105-windows-and-linux-engine-other-modules.md) | Windows and Linux: engine — other modules | 455 |
| [0106](0106-windows-and-linux-i18n.md) | Windows and Linux: i18n | 15 |
| [0107](0107-windows-and-linux-platform-activity.md) | Windows and Linux: platform — activity | 48 |
| [0108](0108-windows-and-linux-platform-autocomplete.md) | Windows and Linux: platform — autocomplete | 498 |
| [0109](0109-windows-and-linux-platform-calendar.md) | Windows and Linux: platform — calendar | 57 |
| [0110](0110-windows-and-linux-platform-meeting.md) | Windows and Linux: platform — meeting | 77 |
| [0111](0111-windows-and-linux-platform-screen.md) | Windows and Linux: platform — screen | 171 |
| [0112](0112-windows-and-linux-platform-tray.md) | Windows and Linux: platform — tray | 81 |
| [0113](0113-windows-and-linux-platform-other-modules.md) | Windows and Linux: platform — other modules | 304 |
| [0114](0114-windows-and-linux-speech.md) | Windows and Linux: speech | 221 |
| [0115](0115-windows-and-linux-sync.md) | Windows and Linux: sync | 293 |
| [0116](0116-windows-and-linux-update.md) | Windows and Linux: update | 97 |
| [0117](0117-windows-and-linux-build-packaging-and-ci-scripts.md) | Windows and Linux: build, packaging and CI scripts | 61 |
| [0118](0118-android-app.md) | Android app | 276 |
| [0119](0119-companion-end-to-end-tests.md) | Companion end-to-end tests | 10 |
| [0120](0120-iphone-and-ipad-app.md) | iPhone and iPad app | 328 |
| [0121](0121-scripts.md) | Scripts | 356 |
| [0122](0122-distribution-channels.md) | Distribution channels | 132 |
| [0123](0123-mac-app-ui-tests.md) | Mac app UI tests | 138 |
| [0124](0124-website.md) | Website | 51 |
