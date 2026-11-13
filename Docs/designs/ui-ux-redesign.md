# UI and UX redesign

This change implements the app-wide redesign as one pull request. The main flow is Today → meeting or screen evidence → reviewed action or scoped draft. Existing recordings, source text, user corrections, approvals, and route aliases remain usable.

## Workspaces

| Area | Result |
| --- | --- |
| Today | Current capture, expandable day-memory state and next meeting lead; three personal actions link to the complete review; brief details are collapsed; generation and capture timestamps are distinct. |
| Actions | Search, retained status/due/meeting filters and selection, sorting, full personal-action lists, corrections, batch status updates and Undo. Actions and Threads share one workspace; matching threads retain all source meetings and require confirmation before a multi-meeting status change. Hidden selections are reported and excluded from the visible batch. Save and Undo failures are visible; failed Undo entries remain retryable. Relative due phrases retain the meeting date. |
| Meetings | Searchable library; persistent transport; Overview, Actions, Transcript and Notes tabs; grouped speaker turns; cross-tab Find; Ask, Export and More. |
| Search and Ask | Explicit submission behavior, grouped results, retained filters and draft, bounded source IDs, scope-aware retries/history, silent source jumps and conversation reading positions. |
| Quick Recall | Shared retrieval/grouping, Return opens evidence, new conversations reset view identity, explicit bounded draft handoff to Ask. |
| Timeline | Chronology on the left, evidence on the right or in a drawer; every retained session moment; app/text filters; in-memory image zoom and full captured text. |
| Settings | Seven categories, exact-setting search with values and navigation targets, app/domain exclusion editors and canonical retention/writing controls. |
| Models and setup | Actual processing destination, optional writing readiness, cancellable synthetic model tests, reviewed presets, four staged setup steps and upgrade-aware defaults. |
| Write | Native keyboard rehearsal, independent Transcribe/Compose intent, visible context, isolated rehearsal output, frozen per-recording configuration and existing focus-safe delivery. |
| Agent | Workspace, active model/destination and approval context beside the composer, explicit saved-session preview, operation effects and restrained output following. A running session retains its resolved model when Settings changes; new sessions use the new selection. |
| Live/menu/overlay | Separate microphone/system-audio health, explicit live preview, Follow live, checked note persistence and readable recording/dictation state. |

## Behavior and data contracts

- Return in Search cannot dispatch generation. “Ask about results” stages a draft with the displayed evidence boundary.
- Meeting and screen identifiers constrain retrieval before ranking. Bounded requests exclude unrelated ambient memory and conversation turns; follow-ups and Retry retain their scope.
- Evidence reveals a passage silently. Playback requires Play.
- Processing labels resolve the configured endpoint and approval policy. A local Dictation override is presented independently of the Main LLM.
- Reducing retention or disabling indefinite text retention reviews affected images, text, vectors, saved exceptions, dates and disk space before committing policy. New eligible data requires a new review; partial failures are reported.
- Manual capture cleanup has a separate range review. Saved moments are excluded unless explicitly included. Deletion works per moment so a failure does not misreport the whole batch.
- Action changes, thread completion, Undo and reviewed cleanup refresh the affected daily evidence. Thread Undo restores each successfully written source to its own previous status, including partial writes, while retaining the extracted commitments and correction history.
- Today and Timeline use the same clipped union of valid, non-system activity intervals. Meeting duration remains a separate metric.
- New settings use Ask first, app activity without screen text/images, and Transcribe. Legacy settings missing the new keys retain their previous behavior. Reopened onboarding stages existing choices rather than resetting them.
- Navigation alone does not prepare models, generate a brief, start an Agent session or run live transcription.

## Verification

The non-UI suite covers the existing library/runtime contracts plus the new migration, draft setup, bounded scope, grouping, calendar-day union, manual/retention review, active Agent connection, and 0/40/400-action persistence/Undo cases. Integration checks cover individual source status restoration and partial thread completion with retry. SwiftLint and whitespace validation apply to the entire patch. Exact-revision results are recorded in the PR.

Hosted XCUITest exercises the new navigation and interaction contracts with a synthetic library. `RedesignUITests` uses the existing native image exporter to attach full-size light/dark screenshots at 1000×700, 1180×740 and 1440×900, along with bounded drafts, keyboard rehearsal, retention cancellation, model/setup screens, contrast states, and scripted Agent approval/denial/Stop through the real RPC controller. A separate hosted run enables Reduce Motion and verifies the actual macOS accessibility setting. Accessibility audits check control descriptions and actions. Test result bundles are retained by the UI workflow for review. Local UI automation is not part of validation.

Accessibility and critical interaction checks run before the long screenshot matrix. Audits retain every app-control issue; the hosted Mac's system-generated virtual Touch Bar and its Emoji picker are excluded by type and membership in the native Touch Bar hierarchy. Exact-revision CI status and any remaining environment limitations belong in the PR's validation notes. This PR does not merge or release the application. The private audit screenshots are intentionally excluded from the repository.

## Recall performance

A same-input, pure Swift check of 2,000 chronological screen matches measured the initial grouping at 2.04 seconds and the sorted/bucketed implementation at 3.4 milliseconds on the development Mac. The regression fixture also shuffles relevance order and confirms every source ID survives. These measurements cover grouping, not total search latency, inference or UI scrolling; they are not a comparison with the released app.
