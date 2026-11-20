# 0104. Windows and Linux: engine — pipeline

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `LinuxWindows/crates/lokalbot-engine/src/pipeline.rs`.

## Decisions

### `LinuxWindows/crates/lokalbot-engine/src/pipeline.rs`

#### Pipeline mirrors ProcessingPipeline.swift and PipelineJobStore.swift: transcribe then notes, one meeting at a time
The processing queue: transcribe, then write notes and actions, one meeting
at a time (`ProcessingPipeline.swift`, `PipelineJobStore.swift`).

#### Jobs parked for missing models stay pending and requeue when models arrive
`Inner.waiting`: Automatic jobs parked because a model was missing. Their saved rows
stay pending, and they go back into the queue once what they waited
for is here (`waitingForModelsJobs`).

#### Idle worker wakes every 5 s to check stop requests and parked jobs
`IDLE_WAKE`: How often the idle worker looks for a stop request and for parked jobs
whose models have arrived.

#### Automatic summaries run only while the automatic-summaries setting is on
`Job.summary_follows_setting`: The summary was asked for automatically, so it runs only while
automatic summaries are on.

#### A job picked up at launch transcribes with the terms saved earlier
`Job.resumed`: Picked up at launch, so it transcribes with the terms saved earlier.

#### Resumed saved job mirrors ProcessingPipeline.resumedWork
`Job::resumed`: A saved job picked up at launch (`ProcessingPipeline.resumedWork`).

#### Automatic summary follows the setting at run time, even after a restart
`Job::writes_notes`: Whether to write notes now. An automatic summary follows the setting
as it is at this point, so turning automatic summaries off also stops
a job queued earlier, even one that waited through a restart.

#### User request decides the summary and makes it explicit when merged
`Job::merge`: Folds another request for the same meeting into this queued job. The
user's request decides the summary and makes it explicit.

#### Transcription need covers models or a transcription server's approval
`Need::Transcription`: The transcription models, or a transcription server's approval.

#### Prune jobs for meetings deleted between crash and launch
`Pipeline::start`: Meetings deleted between the crash and this launch (`resumePending`).

#### Jobs out of automatic attempts stay parked until user retries; failure shown again
`Pipeline::start`: A job that used up its automatic attempts stays parked until the
user retries it; show why it stopped again (`parkedJobs`).

#### Repair of untranscribed recordings runs off the engine thread because it reads every meeting folder
`Pipeline::start`: Finished recordings a run never transcribed, off the engine thread:
this reads every meeting folder (`enqueueMissingTranscriptions`).

#### Queue missing transcripts once; merged gap marked first so repaired at most once
`Pipeline::enqueue_missing_transcriptions`: Queues finished recordings whose transcript is missing or incomplete and
that have no queued, parked or running job. A merged gap is marked first,
so it is repaired at most once. Returns what it queued.

#### Ready means a job would start now rather than park
`Pipeline::transcription_ready`: Whether the transcription models are here, so a job would start now
rather than park (`ModelReadinessSnapshot.transcriptionReady`).

#### Defer saves a job for next launch and keeps an already saved request
`Pipeline::defer_until_next_launch`: Saves a job for the next launch and leaves this run's queue alone. A
request already saved stays as it is (`deferUntilNextLaunch`).

#### A job that cannot be saved is not queued, since it would be lost on quit
`Pipeline::enqueue`: Queues a meeting. False when the job could not be saved: it is not
queued, since a job that isn't saved would be lost on quit.

#### A new request takes over a job parked for models and keeps its work
`Pipeline::enqueue`: A new request takes over a job parked for models and keeps its work.

#### A finished meeting triggers note reconsideration and follow-up evidence
`Inner::run`: A finished meeting has a note and a follow-up due.

#### A job parked for Think never retranscribes: costly and would replace corrected transcripts
`Inner::park`: Sets a job aside until what it waits for is here. A job that got as
far as its notes has committed its transcript, so it goes on without
asking for one: transcribing the meeting a second time would cost as
long as the first and replace a transcript people may have corrected.
`Job::resumed` drops a finished transcription the same way at launch.

#### Readiness check never downloads anything
`Inner::ready`: Whether the models for `need` are here, so a job parked for them
would get past that point now. Nothing downloads from here.

#### Parked jobs requeue when models install, selection changes, server approved, or need gone
`Inner::requeue_ready`: Puts parked jobs back in the queue once their models are installed,
the selection changed to ones that are, the server was approved, or
the job no longer needs what it waited for.

#### Readiness looks at files so no lock is held meanwhile
`Inner::requeue_ready`: Looks at files, so no lock is held meanwhile.

#### With auto summaries off, jobs waiting on Think only for notes are released
`Inner::requeue_ready`: With automatic summaries turned off, a job that waited for the
Think model only to write one has nothing left to wait for.

#### A request made meanwhile is already queued and covers the requeue
`Inner::requeue_ready`: A request made meanwhile is already queued and covers it.

#### Heavy work never runs while a meeting or dictation is capturing
`Inner::yield_to_capture`: Heavy work never runs while a meeting or dictation is capturing.

#### Summary-only retry recovers speaker names; identity is optional and must not block notes
`Inner::recover_speakers`: A summary-only retry still gets the names an interrupted run decided.
Speaker identity is optional: it must not block notes from a saved
transcript or use up an automatic retry.

#### Audio waits for server approval; asking directly says what is missing
`Inner::process`: Audio waits for an approval; asking directly says what's missing.

#### Progress callback lets a waiting dictation or preview go first on the speech model
`Inner::process`: Reported after each span: a dictation or a
preview waiting for the model goes first.

#### Voice identity names remembered voices; its errors never fail transcription
`Inner::process`: Names remembered voices and carries over what people decided.
Identity errors never fail audio transcription.

#### User-given speaker names survive a new transcription
`Inner::process`: Names the user gave speakers survive a new transcription.

#### Saved vocabulary prompt keeps repeating rows out of notes evidence
`Inner::process`: The vocabulary this meeting was transcribed with, so rows that
only repeat it never become notes evidence.

#### On-screen titles are secondary, source-labeled context for notes
`Inner::process`: On-screen titles as secondary, source-labeled context.

#### Notes for a transcript that changed meanwhile are rejected
`Inner::process`: Notes for a transcript that changed meanwhile would be wrong.

#### Explicit user edits stay authoritative for sections beside them
`Inner::process`: Explicit user edits stay the authority for the sections beside them.

#### Removing the refresh marker means notes match the transcript again
`Inner::process`: Notes match the transcript again (`MeetingAttributionArtifacts`).

#### Transcript-only merge sources keep rows; all rows get the same cleanup
`finished_transcript`: The transcript to commit: rows a merged meeting's transcript-only sources
keep, then the cleanup every source of rows must pass, kept or new
(`transcript cleanup after merge`).

#### Launch repair runs on its own thread so tests wait for it
`tests::wait_for_jobs`: Waits for the launch repair, which runs on a thread of its own.

#### Job passes the model check then stops at no recording, loading nothing
`tests::finished_without_audio`: A finished meeting whose audio is gone, so a job that gets past the
model check stops at "No recording available." and loads nothing.

#### Parked job survives several idle wakes without using an attempt
`a_recording_that_waited_for_models_is_processed_once_they_are_installed`: Several idle wakes later it is still parked and has used no attempt.

#### Stopped pipeline lets tests inspect what a request left queued
`tests::stopped`: A pipeline whose worker has stopped, so a test can look at what a
request left in the queue.

#### Transcribed meeting waiting for Think must not transcribe again
`a_job_that_waits_for_its_notes_never_transcribes_again`: Transcription models here, the Think model still downloading: the
meeting was transcribed and waits for its notes. It must not be
transcribed again, by the model arriving or by a request for notes.

#### Server summarizer needs no download so Think counts as ready
`a_job_that_waits_for_its_notes_never_transcribes_again`: A server needs no download, so Think counts as ready.

#### Built-in Think model is not installed in the test library
`a_job_waiting_for_think_goes_on_when_automatic_summaries_are_turned_off`: The built-in Think model is not installed in this library.

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
