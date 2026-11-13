# Ignoring irrelevant saved memory — 2026-10-03

A generic sentence could pick up a detail from an unrelated meeting: typing
"I'll get back to" was completed with "you on Friday" because a saved note also
said "get back to you on Friday". Two shared everyday words were enough to
retrieve a fact. Retrieval now needs a named topic or stronger overlap, and the
evaluation scores leaving writing alone alongside recalling facts.

On the new held-out cases with Gemma 4 E2B Base, generic drafts borrowed an
unrelated fact in **6 of 7** cases before and **0 of 7** after, while relevant
drafts kept **5 of 5**. The three earlier fixtures reproduce the recorded
results row for row.

**Measured on the signed Release build of this change (PR #160); not merged or
released.** Both memory settings still default off.

## What changed

A saved fact reaches the prompt only when the writing is about it:

- **Its source is named.** At least half of the distinctive words of the meeting
  title or project name appear in the draft, the window title, or the selected
  visible text. One word of a long title no longer pulls in everything filed
  under it.
- **Or the fact shares distinctive wording with the user's own draft or window
  title:** two words when one is written as a name (a mid-sentence capital or a
  digit, in the saved fact or the draft), three when none is.
- **Everyday wording never counts**: common verbs and adverbs, weekdays and
  months, meeting kinds ("weekly sync"), meeting platforms and app names, and
  frequent function words in German, French, Spanish and Serbian. The app's own
  name is dropped from its window title. These words can still be the detail a
  fact supplies ("in November").
- **A notes line that only restates its source's title is left out**, such as
  a heading. This is judged against the title and never against the draft, so
  a draft that already mentions the answer still gets the current fact.
- **Writing that names nothing distinctive opens no saved file.** The index is
  searched with distinctive words only, nearest the caret first.

Visible text above the field can still name a saved source; it never counts as
the user's own wording.

## Measurement

[memory-relevance-cases.json](../../memory-relevance-cases.json) holds 13
synthetic saved facts, most of them commitments from generically titled
meetings, and 17 drafts: nine distractors that share everyday wording with a
fact but name no topic, and eight relevant drafts (a lowercase name, a fact
filed under a generic title, a three-word title matched by two words, a name
with diacritics, and a draft that already mentions the answer while an outdated
version of the fact is also saved). Five cases are development and twelve held
out.

| Held-out, Gemma 4 E2B Base | Before | After |
| --- | ---: | ---: |
| Relevant drafts with the correct first word, memory on | 5/5 | 5/5 |
| Relevant drafts with the correct first word, memory off | 0/5 | 0/5 |
| Distractors left alone (nothing retrieved, suggestion unchanged) | **1/7** | **7/7** |
| Distractors that retrieved a fact | 6 | 0 |
| Exact source selections | 6/12 | 12/12 |
| Balanced relevance (mean of recall and abstention) | 0.57 | 1.00 |
| Inference errors | 0 | 0 |

Before the change the borrowed completions were:

| Draft | Memory off | Memory on (before) |
| --- | --- | --- |
| `I will get back to you on ` | `this.` | `Friday.` |
| `I'll call you tomorrow at noon about ` | `the 1000` | `the venue.` |
| `Let me know if the demo ` | `is still available.` | `needs to move.` |
| `I'll get back to you ` (browser mail window) | `on this one.` | `on Friday about` |
| `Javiću ti se sutra oko ` | `10:30` | `ugovora.` |
| `Could you take a look at the flow ` | `and see if` | `and see if` (fact retrieved, output unchanged) |

Development cases: recall 3/3 before and after; distractors left alone 0/2
before, 2/2 after.

The last development case was added after review. A first revision of this
change dropped facts that "only repeat the draft", so the draft "I spoke with
Priya this morning. The Atlas owner is " lost the current fact (owner Priya)
and was completed with the outdated one ("Nadja."). The build before this change
answered "Priya."; the final build does again.

Both builds are Release executables run through
[memory_replay.py](../../memory_replay.py) with the same model, seed and
production defaults (three words, five tokens). "Before" is the Release build
that preceded this change; it reproduces the recorded
[2026-10-02 finalist](../2026-10-02-memory/REPORT.md) on the original
development split output for output. Hashes are in [summary.json](summary.json)
and in each per-run report.

## Regression

The earlier fixtures were rerun on the new build and compared with the recorded
Gemma results, case by case:

| Fixture (held-out) | Result | Rows differing from the recorded run |
| --- | --- | ---: |
| [memory-cases](../2026-10-02-memory/REPORT.md) | 12/12 recalled, 22/22 selections, 10/10 controls unchanged | 0 of 22 |
| [visible-context-cases](../2026-10-02-visible-context/REPORT.md) | 16/18 with both sources, 12/18 visible only, 4/18 memory only | 0 of 128 |
| visible-memory-link-cases | 3/4 with both sources | 0 of 16 |

Retrieval for every case of all four fixtures also runs without a model in
`CotypingMemoryRelevanceTests`. With the new rules undone, that test and the
provider test that reproduces the original report
(`testEverydayWordingDoesNotBorrowAnUnrelatedMeetingsDate`) fail.

## Limits

- The supplement is small and synthetic, and it was written alongside the rule
  it tests. The split keeps model output from steering the rule; it does not
  make the held-out drafts independent of the author's idea of a distractor.
- Matching is lexical. A paraphrase ("who runs Atlas" for "Atlas owner") is not
  found, and an unlisted pair of ordinary words plus a shared name can still
  match. The stricter rule trades some recall for precision: a draft that names
  no topic, such as "The export format is ", no longer retrieves a project's
  export format.
- A first name that is also a stop word or everyday word (for example "Will",
  "May" or "April") cannot name a topic by itself.
- Only Gemma 4 E2B Base was run. Retrieval is model-independent, so the
  selection counts hold for any model; the completions do not.
- This measures retrieval and short completions, not typing latency, insertion
  or acceptance in real apps.

Changed test expectations: `CotypingVisibleContextTests`
(`testVisibleGenericVocabularyCannotRetrieveAnotherProjectsMemory`) and
`DictationGroundingTests`
(`testGenericSpokenInstructionDoesNotRetrieveAnotherProjectsFacts`) previously
asserted that two ordinary shared words retrieve a fact; they now assert the
opposite and that a named topic still does.
