# Sample meeting: plan (2026-10-20)

Goal: a new user gets one useful, cited answer before they record anything.
They install the app, download only the models the sample needs, import a
bundled sample recording, ask one suggested question, and open the cited
passage. The same sample also serves as the launch demo ("a meeting decision
reaches the coding agent") and as a reusable native-speaker test.

The feature adds no tracking. Nothing records that the sample was tried except
the sample meeting itself on disk.

## 1. The sample

**Meeting.** "Sample: Orders API delivery window". It is a fictional
3½–4 minute call between Maya, an API product lead, and Daniel, a backend
engineer. The first line says it is a LokalBot sample with synthetic voices
and made-up people, so the audio is labelled even outside the app.

| What the brief asks for | In the script |
| --- | --- |
| About 5 names | Maya, Daniel, Priya (partner success), Tomás (mobile), Lena (QA), and the partner Fernhill |
| Numbers | 42 partners, 19 strict clients, p95 180 ms, mobile release 4.2, about two million open orders |
| Dates | November 18 (first target), November 11 (new target), Friday (spec update) |
| One decision | Priya emails the three partners who asked; Daniel updates the API spec and changelog by Friday |
| A decision that changes later | Early on: version 3 replaces the `ETA` field with `delivery window`, due November 18. Later: no version 3. The response stays backward-compatible, `ETA` is unchanged, `delivery window` is a new **optional** field left out when unknown, due November 11. Maya says outright that this replaces the earlier decision. |
| One unresolved question | Whether to backfill delivery windows for orders created before the change. It is left open. |

The draft script is in the appendix. Dates have no year, so the sample doesn't
go stale.

**Voices.** Two premade ElevenLabs `eleven_v4` voices, one female and one
male, with a fixed seed. This follows the zh-Hans screenshot meetings
(`Assets/screenshots/zh-Hans/README.md`). Each turn is synthesized with its
neighbouring turns passed as context. Turns are joined with 0.4–0.9 s gaps and
no overlaps. Only the script text goes to ElevenLabs, and only once, at build
time on the developer's Mac. The apps never call it.

**Format.** One mono mixed track, the shape an imported recording has.
AAC-LC in `.m4a` at about 40 kbit/s comes to about 1.1 MB. symphonia's `aac`
and `isomp4` features already decode it on Linux and Windows, and AVFoundation
decodes it on Mac.

**Files in the repo** (`Assets/SampleMeeting/`):

- `orders-api.en.m4a`: the audio
- `script.en.json`: turns with stable ids, speaker, text, and measured start/end
- `reference.en.md`: the human-checkable reference transcript, with timestamps and speakers
- `expected.en.json`: entity checklist, the decision, the changed decision, the open question, the Ask question, the key points of the expected answer, and the turn id it should cite
- `README.md`: how it was made, the voices, and how to regenerate or translate it

`Scripts/sample_meeting.py build` regenerates the audio from the script.
`Scripts/sample_meeting.py check <transcript.json>` scores a LokalBot
transcript against the reference: WER (CER for Chinese), entity recall, and
speaker count. It also prints the checklist for a human reviewer.

## 2. Where the audio lives: bundled

The audio is bundled. Downloading it on demand would save about 1 MB per
language, and bundling avoids:

- a new outbound connection, plus its entry in both PRIVACY.md network lists
- a second hash-pinned asset whose release-asset URL is tied to each version
- a failure mode when offline after the models are already there

1.1 MB is about 0.6% of the 193 MB Mac app, and less of the Linux and Windows
packages. Each later language adds about 1 MB. If four languages ever feel
too heavy, non-English samples can move to an on-demand download through the
existing `download.rs` (HTTPS, pinned size and SHA-256), and that would get a
PRIVACY.md entry then.

- **Linux/Windows:** `include_bytes!` in `lokalbot-app`, the way fonts and icons are embedded today.
- **Mac:** a new `LokalBot/Resources/SampleMeeting/` folder in `project.yml`, like `ModelChecks/speech.wav`.

## 3. How it is marked, and kept out of personal memory

**Marker.** meta.json gets a new optional key, `"sampleID": "orders-api/en"`
(Rust: `sample_id: Option<String>` with an explicit serde rename; Swift:
`sampleID: String?`). Older builds ignore it, Rust preserves it through
`extra`, and Swift's optional keys decode it safely. `is_sample()` /
`isSample` is derived from it. The language suffix picks the matching Ask
question.

**Visible marking.**

- A "Sample" badge on the list row, which reads "Sample · time · duration" in place of "Imported file".
- A banner on the meeting: "Sample meeting with synthetic voices", with **Ask the suggested question** and **Remove sample** buttons.
- The title starts with "Sample:".

**What still sees the sample:** the meetings list, search, Ask, meaning
search, and the CLI and MCP `list`/`get`/`search` commands. That's the point:
Ask must cite it and a coding agent must find it. CLI and MCP results get
`"sample": true`.

**What skips it.** On Linux/Windows there's no per-meeting exclusion yet. I'd
add one helper, `Meeting::feeds_personal_memory()`, which is false for samples
and merged sources (`build_people` already skips merged sources), and use it
at each consumer:

- day digest evidence and digest timing (`ai/digest.rs`, `core/digest.rs`)
- Today/Timeline day activity (`core/timeline.rs`)
- people and projects (`core/people.rs`, `core/projects.rs`)
- upcoming-meeting prep (`ai/upcoming.rs`) and follow-ups (`ai/follow_up.rs`)
- autocomplete meeting memory (`engine/autocomplete.rs`)
- global action lists ("Daniel: update the spec by Friday" shouldn't nag), including `lokalbot-cli actions`
- the CLI `brief` "recent work" section
- the Today "Get started" panel's three-meeting cutoff

The Rust app has no About-you writer, and its day memory holds only activity
blocks, so neither needs a change.

On Mac the same filter goes into:

- `DreamCompiler` (day memory)
- `DailyEvidenceSnapshot` (digest)
- `PeopleDirectory`/`ProjectLinks`
- `PersonalLearning`, as a guard. Imported system-track audio has no "me" turns anyway.
- outcomeIndex's Needs attention
- the GitHub-star prompt count
- transcription vocabulary
- Cotyping memory
- daily and memory exports
- `Briefing`

Speaker voices from imported system tracks are never enrolled, so the
synthetic voices can't enter speaker identity.

**Removal is one step.** **Remove sample** calls the existing single-call
delete (`Library::delete_meeting` / `AppState.deleteMeetings`), which
tombstones the meeting, clears indexes and withdraws derived memory. It skips
the usual confirmation dialog, because the sample can be added again at any
time.

## 4. Seed and demo infrastructure: reuse the layout, not the data

`Scripts/seed_demo_library.py --profile studio` and its Rust port,
`lokalbot-core/src/demo.rs`, write ready-made transcripts and summaries with
tone audio, for screenshots. They can't stand in for a real first run.
`--profile full-day` makes real `say` speech, but only for test hooks. The
reusable parts are:

- the meeting layout knowledge
- the per-turn synthesis and placement approach (`say_track`), which the build script follows with ElevenLabs instead of `say`

There's a licensing reason too. macOS system voices are licensed for personal,
non-commercial use, so `say` audio shouldn't ship in a public download.

The sample goes through the real import and processing path, so it also
proves that the user's models work on their machine.

## 5. Flow and the model-download stage (Linux/Windows first)

**Entry points.**

- The Meetings empty state gets a **Try a sample meeting** button. `ui::empty_state` grows an optional action.
- The Today "Get started" panel gets the same step, after "Download the transcription model".
- When the sample already exists, both read **Open sample meeting**.

I'd leave the onboarding window alone. Its Models step already prepares
models, and the sample is more useful once the main window is visible.

**The sample card.** It sits in the Meetings detail pane, where "No meeting
selected" shows today, and runs through these stages:

1. **Models.** It lists only what's missing for the sample: the speech model and speaker separation (`meeting_requirements(summarize: true)`), with sizes from the catalog, e.g. "Speech model 879 MB" and "Notes model 2.5 GB".
   - Nothing downloads until the user presses **Download and continue**, because this can be several GB.
   - Progress comes from the existing `EngineEvent::Download` stream.
   - An external Think server needs no Think download, so that row disappears.
   - A failed download shows Retry.
2. **Import.** Writes the embedded bytes to a temporary file named after the title and calls the existing `import_recording` with the sample id. This is instant.
3. **Transcribe** and 4. **Write notes.** These mirror the pipeline's existing `Stage` events for this meeting.
5. **Ask.** "Try asking: *Is the delivery window field required in the Orders API response?*" The button opens Ask through the existing `AskRequest { question, meeting_ids: [sample], submit: true }`.
   - The expected answer: no. It's optional and left out when unknown, `ETA` is unchanged, and the earlier version 3 plan was dropped.
   - It should cite the "let's change the decision" passage, about two minutes in. Clicking the citation opens the transcript there.

The meeting's own banner carries the same Ask button afterwards.

The sample is picked by interface language: German, Simplified Chinese or
Serbian (Latin) once those exist, falling back to English. New strings go into
all 24 `LinuxWindows/localizations/*.json`.

## 6. Mac

The Mac app already has everything the flow needs:

- import (`MeetingImportService`)
- an empty-state button and the GettingStartedCard
- `openAsk(query:meetingIDs:submit:)`
- one-call delete

Its cost is in the roughly 10 exclusion sites listed above, the 24
`Localizable.strings` files, a new resource folder, and the hour-long UI gate
on the PR.

**Decision (2026-10-20):** the Mac app ships in the same PR as Linux/Windows,
with the same audio, the same meta key, and the same flow.

## 7. The coding-agent demo

The sample's changed decision is technical on purpose. In a demo repo with an
`OrderResponse` type, the agent is asked to add delivery windows, and it
checks LokalBot first. Either of these returns the passage:

- `lokalbot-cli search "delivery window"`
- MCP `search_meetings`

`get … --include summary` then gives the decision: keep the response
backward-compatible, add the field as optional, and leave it out when unknown.
`Assets/SampleMeeting/README.md` documents the exact prompt and commands.

## 8. Native-language test (planned, English first)

Translations keep the turn ids, speakers, names and facts. Numbers and dates
are said the local way. Each language gets its own `script`, `reference`,
`expected` and audio files.

The test for a native speaker:

1. Switch the interface language.
2. Run the sample.
3. Run `sample_meeting.py check` on the resulting transcript.
4. Go through the printed checklist: the names and numbers are correct, the
   notes state the final decision rather than the reversed one, the open
   question stays open, and the Ask answer cites the right passage.

Languages: German, Simplified Chinese, and Serbian Latin (ElevenLabs v4 covers
all three). Each is about 1 MB and gets its own PR.

## 9. Verification for this PR

- **Rust tests:**
  - the embedded asset decodes to the expected length
  - sample import writes `sampleID` and the title
  - the exclusion helpers drop the sample from the digest, timeline, people, projects, actions and brief, but not from list, search, Ask retrieval or CLI list
  - Remove deletes it
  - the locale tests
- **A real run on the Ubuntu box:** import the sample through the engine with the real default models, score the transcript with `check`, and ask the suggested question to confirm the citation lands on the changed-decision turn.
- **Linux GUI under Xvfb on the box:** screenshots of the empty state, the stage card and the sample banner.
- **Not done:** any GUI launch on this Mac.

## Appendix: draft script (English)

> **Maya:** This is the LokalBot sample meeting. The voices are synthetic, and the company and people are made up. Okay, Daniel, let's sort out the delivery window for the Orders API.
> **Daniel:** Sure. Quick context: support wants customers to see a delivery window, like "between two and four in the afternoon", instead of the single ETA time we return today.
> **Maya:** Right. And Priya from partner success says three of our biggest partners asked for the same thing.
> **Maya:** So, the plan from last week: we replace the ETA field with a new delivery window object, and we ship it as version three of the API.
> **Daniel:** That was the plan. The window would be two timestamps, a start and an end, both in UTC. I can have version three ready by November eighteenth.
> **Maya:** Okay. Decision for now: version three, delivery window replaces ETA, target November eighteenth.
> **Daniel:** Performance is fine either way. I measured it: p95 latency stays around a hundred and eighty milliseconds.
> **Maya:** Good. What about the mobile app?
> **Daniel:** Tomás says the mobile team can pick it up in release four point two, not earlier.
> **Maya:** And testing?
> **Daniel:** Lena will add contract tests. She needs two days once the schema is frozen.
> **Daniel:** Actually, before we lock this in. I went through the partner integrations last night. Forty-two partners call the orders endpoint, and nineteen of them use generated clients that fail when a field they expect is missing. If we remove ETA, those nineteen break the day we ship.
> **Maya:** Nineteen out of forty-two. That's almost half. And version three means every partner has to migrate.
> **Daniel:** Exactly. Fernhill alone took four months to move to version two.
> **Maya:** Then let's change the decision. No version three. The response stays backward-compatible: ETA stays exactly as it is, and delivery window is added as a new, optional field. If we don't know the window, we leave the field out.
> **Daniel:** Optional, left out when unknown, ETA unchanged, still version two. That's less work, too. I can ship it by November eleventh instead of the eighteenth.
> **Maya:** Great. So for the notes: this replaces what we said at the start. Backward-compatible response, delivery window optional, ship November eleventh.
> **Maya:** Priya will email the three partners who asked for it. Daniel, can you update the API spec and the changelog?
> **Daniel:** Yes, by Friday.
> **Daniel:** One thing we still haven't figured out: do we backfill delivery windows for orders created before the change, or only for new orders?
> **Maya:** Hm. Backfill means rerunning the estimator on about two million open orders. I don't know if that's worth it. Let's leave it open. I'll ask Priya whether partners even need it for old orders.
> **Daniel:** Okay. So backfill is still open.
> **Maya:** Yes. Thanks, Daniel. That's it for today.

This runs about 3 minutes at a natural pace. The final script adds a few
lines of realistic back-and-forth, such as the response size and a contract
test detail, to reach about 3½–4 minutes without adding facts that compete
with the checklist.

## Outcome (2026-10-20)

Built in [PR 333](https://github.com/stevyhacker/LokalBot/pull/333) for Mac,
Windows and Linux. On the Ubuntu box, a release build was run end to end under
Xvfb from an empty library with the default models (Qwen3-ASR 0.6B, Qwen3.5 4B):

- The model stage listed 3.7 GB, and nothing downloaded until asked.
- The sample was added as soon as the downloads finished.
- `Scripts/sample_meeting.py check` scored 3.0% WER and found all 14 names,
  numbers and dates. 93% of speech time landed on the right voice, although
  speaker separation reported 3 speakers for 2 voices.
- The notes stated the changed decision rather than the reversed one, and kept
  the backfill question open.
- Ask answered the suggested question correctly and cited 02:05 and 02:12,
  both inside the changed-decision passage. Opening the citation needed a fix
  in the same PR, so the transcript now scrolls to rows it hasn't drawn yet.
- Remove sample deleted it in one step.

The Mac app compiles and its unit tests run in CI. It hasn't been run as an
app on a Mac yet.
