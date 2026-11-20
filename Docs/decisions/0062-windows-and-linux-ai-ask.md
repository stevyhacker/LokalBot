# 0062. Windows and Linux: ai — ask

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `LinuxWindows/crates/lokalbot-ai/src/ask.rs`.

## Decisions

### `LinuxWindows/crates/lokalbot-ai/src/ask.rs`

#### Ask retrieves first, one answer, then verifies citations, since small local models misuse tool loops
Ask: answers from the user's meetings and screen memory with citations
(`Services/Chat/ChatAgent.swift`, `ChatCitation.swift`, `CLISupport/AskLibrary*`).

The macOS agent lets the model call tools in a loop. Small local models
follow that protocol unreliably, so here the app retrieves first (keyword
search, meaning search when embeddings exist, title matches and the
scoped meetings), hands the model numbered sources with their citation
markers, streams one answer, and verifies every marker afterwards: a
marker for a source it was not given becomes "(source not verified)".

#### Empty meeting_ids means all meetings
`AskScope.meeting_ids`: Only these meetings (empty: all).

#### until bound is exclusive
`AskScope.until`: Exclusive.

#### Activity means time in apps, served by activity_summary tool
`AskScope.include_activity`: Time spent in apps (the tool loop's `activity_summary`).

#### Personal Context text for this question; empty when none applies
`AskScope.personal_context`: What Personal Context gives this question; empty when none applies.

#### Overnight review work memory; empty for restricted questions
`AskScope.work_memory`: The overnight review's work memory; empty for restricted questions.

#### On: vectors take part in search; off: words alone
`AskScope.search_by_meaning`: Search by meaning is on: vectors take part. Off, it's words alone.

#### Files searched through search_files in folders chosen under Files
`AskScope.include_files`: The folders chosen under Files, searched through `search_files`.

#### Empty while Files is off, and then the tool is not offered
`AskScope.file_folders`: Those folders; empty while Files is off, and then the tool isn't offered.

#### Agent notes tool offered only if notes are readable and saved
`AskScope.include_agent_notes`: The notes the person's coding agents saved for themselves, searched
through `search_agent_notes`. False while Read coding agent notes is off
or nothing is saved, and then the tool isn't offered.

#### Screens this question is bound to, attached or from results
`AskScope.screen_ids`: Screens this question is bound to (attached or from the results).

#### Attached screens are primary evidence; conversation shows only the question
`AskScope.attached_context`: Screens the person attached, as primary evidence for the model
(`ScreenAskContext.prompt`); the conversation shows only their question.

#### Words at a file's matched moment, only when transcription is available
`AskScope.moments`: The words at a file's matched moment, when transcription is available.

#### Describes meeting_ids, since and until to the model; None when unrestricted
`AskScope.limit`: What `meeting_ids`, `since` and `until` hold, for the model; `None`
when the question may look at everything.

#### Focus is where the answer starts, never a limit
`AskScope.focus`: The day or meeting a device's question was asked about: where the
answer starts, never a limit.

#### Ask About Today once limited to that day and answered library has one meeting
`QuestionFocus`: Where a question asked from a day or a meeting starts. "Ask About Today"
on a tablet once held the question to that day, and the answer said the
library had only one meeting.

#### Subject is a phrase like the day or the meeting with date
`QuestionFocus.subject`: "the day 4 Nov 2026", "the meeting “Standup” [1a2b3c4d] on 4 Nov 2026".

#### Single-turn answer reads the named meetings first
`QuestionFocus.meeting_ids`: The meetings it names, which the single-turn answer reads first.

#### Forms its part of Question scope section, matching ChatPrompt.questionFocus
`QuestionFocus::prompt`: Its part of the Question scope section (`ChatPrompt.questionFocus`).

#### Tell the model what a limited question sees so one meeting is not read as whole library
`QuestionLimit`: What a limited question can see, in words for the model
(`ScopedChatToolRunner.limit`). Without it, the one meeting a question
limited to today could find read as the whole library.

#### Words complete the phrase limited to
`QuestionLimit.words`: Completes "limited to", e.g. "what happened on 4 Nov 2026".

#### Person chose the date limit and can remove it
`QuestionLimit.removable_dates`: The person chose the date limit, and can remove it.

#### Dates are local days with exclusive until; None when no dates or meetings
`QuestionLimit::new`: The dates from `since` to `until` (exclusive) as local days, and the
meetings the question was held to; `None` when neither applies.

#### Question scope section of system prompt, matching ChatPrompt.questionScope
`QuestionLimit::prompt`: The Question scope section of the system prompt
(`ChatPrompt.questionScope`).

#### First line of any meeting list held to this limit
`QuestionLimit::note`: The first line of a meeting list held to this limit.

#### Date phrases use local days with exclusive until
`dates_phrase`: "on 4 Nov 2026", "from 1 Sep 2026 to 7 Sep 2026", "since 6 Oct 2026",
"before 1 Sep 2026", in local days; `until` is exclusive.

#### Mirrors ChatPrompt's ambient blocks at end of system prompt
`ambient_block`: `ChatPrompt`'s ambient blocks, for the end of the system prompt.

#### Answer replaces earlier text because citations are rechecked while streaming
`AskEvent::Answer`: The whole visible answer so far, replacing earlier text (the tool loop
re-checks citations as it streams, so text can change).

#### Marker stamp is HH:MM:SS as the Mac chat prompt asks
`marker_time`: `HH:MM:SS`, the stamp the Mac chat prompt asks for.

#### Only sources given to the answer may be cited
`Sources`: The sources one answer was given: meeting moments and screen moments
(`ChatEvidence`). Only these may be cited.

#### Whole seconds of every moment marker handed to the model per meeting
`Sources.moments`: Whole seconds of every moment marker handed to the model, per meeting.

#### Agent notes are keyed by lowercase hex ids
`Sources.notes`: Saved coding-agent notes, by their lowercase hex ids.

#### Short follow-ups of eight words or fewer search with the previous question
`retrieval_text`: A short follow-up ("and the second one?") searches with the question before it.

#### Attached screens citable only while existing and inside question dates
`attached_screen_sources`: Attached screens are citable while they exist and fall inside the question's
dates (`attachedScreenEvidence`).

#### Rank text and picture vectors with keywords; keep keyword hits when no vectors
`scoped_screen_hits`: Keyword hits and, with search by meaning, the screen's text and picture vectors
ranked with them, within the question's dates, app and attached screens
(`ScreenSearch`). With no vectors yet the keyword results stay.

#### Activity needs no search: use chosen dates or today
`answer`: Time in apps needs no search: the chosen dates, or today.

#### Mac chat prompt without tool catalogue since sources are supplied up front
`system_prompt`: The Mac chat system prompt (`ChatAgent.systemPrompt`) without its tool
catalogue: sources are retrieved up front and supplied in the user
message, so one model turn answers.

#### Small models cite by label or group meetings in one marker despite prompt
`GROUPED`: Small models often cite a source by its label ("[M1]", "[M1@00:00:43]")
rather than its marker; turns labels into the markers they stand for.
`[meetings:A, B]` or `[meeting:A; B@00:01:10]`: several meetings in one
marker, which small models write despite the prompt.

#### Split grouped meeting markers so each is verified separately
`split_grouped`: Splits grouped meeting markers into one `[meeting:…]` per meeting, so each
is verified on its own.

#### Hold back markers still being written rather than show then retract
`verified_partial`: `verified` for a partial answer: a marker still being written is held
back rather than shown and then retracted.

#### Rewrite markers to canonical form, keeping only sources the answer was given
`verified`: Rewrites markers to the canonical `[meeting:<UUID>@HH:MM:SS]` form, keeping
only those the answer was given (`ChatEvidence`).

#### Note ids are twelve hex characters, never with a time
`verified`: Twelve hex characters, never with a time.

#### Cancel stops the answer promptly and keeps what arrived
`answer`: Answers `question` from the library within `scope`, streaming deltas
through `on_event`. When `cancel` is set the answer stops promptly and
keeps what arrived.

#### App-served ask_library: title matches, keyword snippets, one answer, Sources list; CLI talks to server itself
`ask_library`: `ask_library` served by the app (the CLI talks to the app's server itself;
see `lokalbot-cli`): title-matched summaries, then keyword snippets, one
answer, and a `Sources:` list.

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
