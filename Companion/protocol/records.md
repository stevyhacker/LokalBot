# Companion records, schema version 1

The Mac turns its library into records: small JSON documents that hold only
allowlisted fields. Phones store them and never see the Mac's files.
[`fixtures/sample-library.json`](fixtures/sample-library.json) is a complete
example library; every client and test uses it.

Conventions:

- JSON keys are camelCase. Unknown keys are ignored.
- Instants are ISO 8601 UTC with milliseconds: `2026-10-30T09:30:00.000Z`.
  Calendar days are `YYYY-MM-DD` in the Mac's local time zone. Offsets within
  a meeting (`start`, `end`, `at`) are seconds from the start of its audio, as
  numbers.
- Optional fields are omitted, never `null`.
- Never present in any record: calendar attendee emails, speaker evidence or
  voice profiles, screenshot pixels or paths, OCR screen text, email, Personal
  Context, overnight (Dream) memory, API keys, settings. The Mac's exclusion
  test enforces this.

## Envelope

Every record travels and is stored in an envelope:

```json
{ "kind": "meeting", "key": "3f6c2a10-…", "version": 3, "seq": 1842,
  "deleted": false, "sortKey": "2026-10-30T09:30:00.000Z", "body": { … } }
```

| field | meaning |
| --- | --- |
| `kind` | `manifest`, `meeting`, `transcript`, `day`, `person`, `project` |
| `key` | Unique within a kind: meeting UUID, `YYYY-MM-DD`, person id, project UUID; `manifest` uses `library` |
| `version` | Increases by 1 each time this record's content changes |
| `seq` | Host-wide change counter at the time of this version; strictly increasing |
| `deleted` | `true` for a tombstone (the body is `{}`) |
| `sortKey` | Instant or day that orders catch-up newest first (meeting `startedAt`, day `date`, others the publish time) |
| `body` | The record below |

The host computes `version`, `seq` and `sortKey`; the Mac app publishes only
`kind`, `key` and `body`, and a publish whose body is byte-identical (after
canonical JSON serialisation with sorted keys) to the stored one is a no-op.
A client upserts by `(kind, key)` and keeps the higher `version`. Its cursor
moves to the highest `seq` seen only after a batch with `done: true`, so an
interrupted catch-up repeats safely.

## manifest (key `library`)

```json
{
  "schemaVersion": 1,
  "libraryName": "Work",
  "macName": "Stevan's MacBook Pro",
  "dataClasses": { "meetings": true, "transcripts": true, "digests": true,
                   "timeline": true, "windowTitles": true, "people": true,
                   "projects": true },
  "historyDays": 0,
  "askEnabled": true,
  "generatedAt": "2026-10-31T10:12:00.000Z"
}
```

`historyDays` 0 = all history; otherwise 30, 90 or 365. Records outside the
window are sent as tombstones.

## meeting (key = meeting UUID)

| field | type | notes |
| --- | --- | --- |
| `id` | string | Meeting UUID |
| `title` | string | |
| `startedAt`, `endedAt` | instant | |
| `day` | `YYYY-MM-DD` | Local day of `startedAt` |
| `timeZoneOffsetMinutes` | int | Mac's offset at `startedAt`, for display |
| `durationSeconds` | number | Recorded duration |
| `appName` | string? | "Zoom", "Google Meet", "In person", … |
| `people` | `[{id, displayName}]` | Display names only |
| `projects` | `[{id, name}]` | |
| `summaryMarkdown` | string? | Generated summary, with the person's action corrections applied |
| `notesMarkdown` | string? | The person's own notes |
| `actions` | `[Action]` | See below |
| `decisions` | `[{id, text, citations}]` | |
| `openQuestions` | `[{id, text, citations}]` | |
| `hasTranscript` | bool | A `transcript` record exists |
| `mergedInto` | string? | Meeting UUID this one was merged into; clients hide it |

**Action**: `{id, text, owner?, ownerIsUser, ownerUnclear, dueDate?,
dueText?, status, importance, citations}`. `status` is `open`, `done` or
`deferred`; `dueDate` is a resolved `YYYY-MM-DD`; `dueText` the phrase as
spoken ("by Thursday"); `importance` 1–5. Owner, due and text corrections are
already applied.

**Citation**: `{start, end, speaker?, excerpt}`: an offset range in seconds
and the quoted words.

## transcript (key = meeting UUID)

```json
{ "meetingId": "…", "segments": [
  { "start": 721.4, "end": 728.9, "speaker": "Maya Chen", "colorIndex": 1,
    "text": "Could you send me the revised deck by Thursday?" } ] }
```

`colorIndex` 0 is the person themselves ("You"); 1–7 index the speaker
palette in [`../design/tokens.json`](../design/tokens.json); grouped or
unknown voices use -1.

## day (key = `YYYY-MM-DD`)

```json
{
  "date": "2026-10-30",
  "digest": {
    "markdown": "## Highlights\n- …",
    "generatedAt": "2026-10-30T21:05:00.000Z",
    "userEdited": false,
    "sections": { "highlights": ["…"], "decisions": ["…"], "tasks": ["…"],
                  "blockers": ["…"], "followUps": ["…"] }
  },
  "timeline": {
    "trackedSeconds": 27600,
    "sessions": [ { "start": "…", "end": "…", "title": "Onboarding prototype",
                    "kind": "work", "project": "Onboarding",
                    "apps": [{"name": "Xcode", "seconds": 3200}],
                    "windowTitles": ["OnboardingFlow.swift"] } ],
    "byProject": [{"name": "Onboarding", "seconds": 9000}],
    "byApp": [{"name": "Xcode", "seconds": 5400}],
    "savedMoments": [{"at": "…", "label": "Pricing table idea"}]
  },
  "meetingIds": ["…"]
}
```

- `digest` is absent until the Day Digest exists. Screen citations in its
  Markdown are rewritten on the Mac to plain text ("screen moment at 14:32").
- Session `kind` is `work`, `meeting` (with `meetingId`) or `agent` (a coding
  agent session). `windowTitles` is present only when that data class is on.
- `byProject` and `byApp` are sorted by seconds, descending; a session or app
  with no project counts under "Other".

## person (key = person id)

```json
{ "id": "person:maya-chen", "displayName": "Maya Chen",
  "lastMetAt": "2026-10-30T13:30:00.000Z",
  "openWork": [ { "meetingId": "…", "actionId": "…", "text": "…",
                  "dueDate": "2026-11-04", "theirs": true } ],
  "decisionsTogether": [ { "meetingId": "…", "text": "…" } ],
  "meetingIds": ["…"] }
```

`openWork` lists open actions shared with this person: `theirs: true` when
they own it, `false` when the person using LokalBot owns it.

## project (key = project UUID)

```json
{ "id": "…", "name": "Onboarding",
  "whereItStands": "Markdown from the Mac's project status",
  "yourActions": [ { "meetingId": "…", "actionId": "…", "text": "…",
                     "dueDate": "…", "status": "open" } ],
  "waitingOnOthers": [ { "meetingId": "…", "actionId": "…", "text": "…",
                         "owner": "Ben Ortiz", "dueDate": "…" } ],
  "decisions": [ { "meetingId": "…", "text": "…" } ],
  "timeThisWeekSeconds": 14400,
  "people": [ { "id": "person:maya-chen", "displayName": "Maya Chen" } ],
  "meetingIds": ["…"] }
```

## Ops (phone → Mac)

```json
{ "type": "action.setStatus", "opId": "<uuid>", "meetingId": "…",
  "actionId": "…", "actionText": "Send the revised pricing deck to Maya",
  "status": "done", "at": "2026-10-31T07:12:00.000Z" }
```

The only op in version 1. The Mac applies it through its existing action
state store; when reprocessing has changed the action id it matches on
`actionText`, and otherwise reports `unmatched`. The phone shows the new
status at once, marked as waiting for the Mac, until the rebuilt meeting
record arrives.

## Ask

Request:

```json
{ "requestId": "<uuid>", "conversationId": "<uuid>",
  "question": "What did we decide about onboarding this week?",
  "history": [ { "role": "user", "text": "…" }, { "role": "assistant", "text": "…" } ],
  "scope": { "day": "2026-10-30", "meetingId": "…" } }
```

`scope` and both of its fields are optional. Result:

```json
{ "requestId": "…", "answer": "You agreed to cut onboarding to three steps [1] …",
  "citations": [ { "index": 1, "meetingId": "…", "at": 724,
                   "label": "Design review — onboarding · 12:04" } ],
  "engineLabel": "Qwen3.6 35B", "location": "mac",
  "answeredAt": "2026-10-31T07:15:02.000Z" }
```

`[n]` markers in `answer` refer to `citations[].index`. `location` is `mac`
for an on-device engine and `remote` for an approved remote engine; the phone
colours the marker teal or amber. A citation without `meetingId` (a screen
moment) is shown as text only.
