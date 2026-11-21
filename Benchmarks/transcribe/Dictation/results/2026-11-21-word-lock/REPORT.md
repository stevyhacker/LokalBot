# Digits, names and negation lock for cleaned dictation — 2026-11-21

## Outcome

`DictationWordLock.production` is `digitsNamesNegation`. After the cleanup-only prompt cleans direct speech, the result is checked against the transcript:

- **Digits:** the spoken digits must come back in the same order, whatever separators sit between them, so "1500" may be written "1,500" and "930" may become "9:30". New digits are allowed only when the speech has number words ("twelve hundred" → "1200"). Dropped digits are allowed only in a self-correction.
- **Negation (English):** if the speech negates something, the cleaned text must still negate, by meaning: "not anything" may become "nothing", and "can't" may become "cannot". A sentence's opening "no" after fillers is an answer, not a negation.
- **Names:** a capitalized word that isn't a sentence's first word stays, ignoring case, or is respelled to a glossary term.
- **Self-corrections:** "3, no, 4", "I mean", "actually" and the like exempt what they correct, because cleanup is meant to drop false starts.

Before falling back, spelled-out numbers are turned back into the spoken digits: when English number words line up, in order,
with spoken digits the cleaned text lost ("three releases" for "3 releases"), they are replaced by those digits and the
cleaned text is kept if every check then passes. This also runs when a self-correction cue exempted the digit check, since a
long dictation easily contains an everyday "rather" or "wait". Otherwise, when a check fails, the transcript is inserted, as
Transcribe would insert it. Writing requests are not checked.

### Replay sets

Lock off against lock on, same build, model, server and options. Counts are cleaned direct-speech (`fidelity`) outputs across the five grant conditions.

| Set | Correct, lock off | Correct, lock on | Lock fired |
|---|---:|---:|---:|
| `context-wordlock-v1` (new, frozen before it ran) | 150/150 | 150/150 | 0 |
| `context-cleanup-v4` | 80/80 | 80/80 | 0 |
| `context-cleanup-v3` | 75/80 | 75/80 | 0 |
| `context-routing-v2` | 60/65 | 65/65 | 5 |
| `context-routing-heldout` | 40/40 | 40/40 | 0 |
| `context-cases` (heldout) | 20/20 | 20/20 | 0 |
| **Total** | **425/435** | **430/435** | **5** |

- **All five fixes are one case:** v2's `d2-sr-javi-mi`, in every condition. "Javi mi sutra da li dolaziš na 3 sastanka." came back as "… na tri sastanka." with the lock off and was inserted as dictated with it on.
- **Nothing got worse:** no output that was correct with the lock off changed.
- **Latency:** median direct-speech latency moved by 10 ms or less on every set.
- **v3's misses are a routing case:** `c3-summarize-thoughts` is routed as a writing request, so its answer goes through Compose and isn't locked.
- **Routing and selection failures in v2 and v3** are identical with the lock off and on.
- **The new set never triggered the lock:** the model kept everything in it, so it shows the lock leaves good cleanups alone, not that it catches new failures.

### Real dictation

The synthetic sets can't show how often the lock gets in the way of ordinary speech, so it was also run on real dictations from the contributor's own history in another dictation app. These were English, 6 to 80 words each, picked so that a quarter each contained digits, negation, a capitalized mid-sentence word, or none of these. They were cleaned with the same local model and replay; the dictations and outputs stayed on that Mac and are not in this folder. Each firing was compared with the text the contributor finally kept. Three samples of 400 were drawn with no overlap, one per revision of the rules:

| Rules | Sample | Lock fired | Notes |
|---|---|---:|---|
| First (exact names, digit runs as sets) | 400 | 14 | Mostly capitals marking a sentence start the recognizer ran together ("Related", "Was"), "1500" as "1,500", "twelve hundred" as "1200", "not anything" as "nothing" |
| Second (case-free names, grouping and number words allowed, negation by presence) | 400 fresh | 4 | All four went against the kept text: "930" as "9:30", a regrouped number, a name the cleanup corrected, one unclear |
| Final (digits compared in order) | 399 fresh | 0 | The cleanup never changed a digit sequence, a negation or a name in this sample |

Only the last sample is a blind measure of the final rules: it fired on none of 399 real dictations. The earlier two were used to find the problems.

### Long dictation (added after the first report)

The replay sets and the real samples above are short (6 to 80 words). A speed set written for idea 5,
`context-speed-v1.json` (eight synthetic direct dictations of 43 to 220 words, frozen before its first run), showed that on
long dictation the cleanup model sometimes writes spoken digits as words. Same model, server and options; 40 cleaned outputs
(runs `speed-off`, `speed-first-digitsNamesNegation` and `speed-digitsNamesNegation`; the first came from a build without the
lock, the second from a build with the rules as first reported; raw outputs in [`raw-runs-long.tar.gz`](raw-runs-long.tar.gz)):

| Rules | Correct | Transcript inserted | Digits restored |
|---|---:|---:|---:|
| Lock off | 20/40 | — | — |
| Lock as first reported | 20/40 | 5 (one case, every condition) | — |
| Lock with digit restoring | 25/40 | 0 | 15 (three cases) |

- **With the first rules,** one case fell back to the transcript, fillers and all; two others slipped through because their
  everyday "rather" and "wait" counted as self-correction cues.
- **With restoring,** all three keep their cleanup and get their digits back. The 15 failures left are cleanup keeping an
  "uh", which is outside the lock.
- **The six replay sets are unchanged:** 430/435, the same five fixes.

**Long real dictations.** A fourth sample of 150 dictations from the same history, all longer than 80 words (median 107, up
to 300), so none were in the earlier samples, ran with the lock off, with the rules as first reported, and with restoring.
Each version fell back to the transcript once, on the same dictation: cleanup had dropped four capitalized words that the
contributor's final text didn't keep either, so it was most likely a false alarm. Cleanup changed the digits in 4 dictations,
all in ways the rules allow (number words to digits, regrouping), so restoring never had to act on this real speech; it
matters for the long synthetic cases above.

## How the rules got here

1. **First lock-on replay** (`runs/first-*`): one false alarm on the new set. In "uh no I don't think that works", cleanup correctly dropped the opening "no", and the lock put the transcript back, "uh" included, in all five conditions (145/150). The rule changed so an opening "no" after fillers isn't a negation. None of the older sets has a direct-speech case that opens with "no".
2. **Real dictation, first and second samples:** the changes in the table above.
3. **Each revision was rerun on all six replay sets** with the lock on. Every revision after the first gave the same 430/435 with five firings, all the Serbian fix. The runs kept here are the lock-off runs, the first lock-on runs and the final lock-on runs.

4. **Long dictation:** digit restoring, measured on the speed set and on a fresh sample of long real dictations (above).

Because the rules changed after seeing the frozen set and the first two real samples, those no longer measure the final rules blind. The older replay sets and the third real sample do.

## Offline check on earlier runs

Scored against the recorded outputs in this folder's earlier results, using the production prompt and routing (674 cleaned direct-speech outputs), the final rules fire 9 times, all on failed outputs (the same Serbian case), and never on a correct one. The 27 failures they leave are relays rephrased into a message ("Tell him I am running 10 minutes late." → "I am running 10 minutes late."), which are outside a digits, names and negation lock.

## Eval design

- `context_replay.py` with `--word-lock off` or `--word-lock digitsNamesNegation`. The flag sets `DictationContextReplay.Input.wordLock` and goes through the real `DictationTextPreparation.prepare`.
- Qwen3.5-4B-Q4_K_M on the bundled llama-server, fixed seed, production Compose options. Hashes are in each run's `manifest.json`; local paths in them are rewritten to `~` and `/private/tmp/lokalbot-bench`.
- One Debug build per lock revision, run from a disposable copy with the runner's isolated home, storage and defaults (earlier rounds used Release). Latency compares off with on within the same build only.
- `context-wordlock-v1.json` (31 cases, synthetic) was written for the lock and frozen before its first inference ([`fixture-freeze.json`](fixture-freeze.json)). It covers digits (including Serbian and a repeated false start), negation in several spellings, unusual names (one at a sentence start, one spoken in lower case), self-corrections, filler controls and Transcribe.
- Raw outputs of the replay runs kept here: [`raw-runs.tar.gz`](raw-runs.tar.gz).

## Not covered

- **A cue anywhere exempts the whole dictation:** a self-correction cue ("actually", "rather", "wait", "sorry", "no,") switches
  off the digit, negation and name checks for the entire dictation, not just near the cue. Long dictations contain such words
  naturally: two of the eight long synthetic cases ("wait", "rather") did. Digit restoring still runs in that case; negation and
  names do not. Scoping the exemption to the sentence with the cue is a possible follow-up, but it would make the lock fall
  back more often on long dictation, so it needs its own measurement.

- **Glossary respelling:** the replay has no personalization input, so this is covered by unit tests only. Without a glossary, a name the cleanup respells counts as lost, even when the respelling is right, as one real sample showed.
- **English-only cues:** negation and self-correction cues are English. The digit check works in any language written with ASCII digits.
- **Contractions as spoken:** "can't" may come back as "cannot". Someone who wants the wording as spoken, except in formal writing, would need a formality choice for cleanup; that is a separate idea.
- **Windows and Linux:** the port's cleanup output handling (`LinuxWindows/crates/lokalbot-ai/src/dictation.rs`) doesn't have the lock yet.
