# Digits, names and negation lock for cleaned dictation — 2026-11-21

## Outcome

`DictationWordLock.production` is `digitsNamesNegation`. After the cleanup-only prompt cleans direct speech, the result is checked against the transcript:

- **Digits:** no digit run that wasn't spoken, and none of the spoken ones lost.
- **Negation (English):** every spoken negation stays, compared by meaning ("n't" and "cannot" count as "not"). A sentence's opening "no", after fillers, is an answer, not a negation.
- **Names:** a capitalized word that isn't a sentence's first word stays, or is respelled to a glossary term.
- **Self-corrections:** "3, no, 4", "I mean", "actually" and the like exempt what they correct, because cleanup is meant to drop false starts. An invented digit is never exempt.

When a check fails, the transcript is inserted, as Transcribe would insert it. Writing requests are not checked.

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
- **Latency:** median direct-speech latency moved by 10 ms or less in either direction on every set.
- **The new set never triggered the lock:** the model kept every digit, name and negation in it, so it shows that the lock leaves good cleanups alone (fillers dropped, self-corrections applied), not that it catches new failures.
- **v3's misses are a routing case:** `c3-summarize-thoughts` ("Summarize your thoughts on the 2 proposals…") is routed as a writing request, so its answer goes through Compose and isn't locked.
- **Routing and selection failures in v2 and v3** (`routingFailures`, `selectionFailures`, `forbiddenReads`) are identical with the lock off and on.

## The first run, and the one change made after it

The first lock-on run (`runs/first-*`) had one false alarm, on the new set. "uh no I don't think that works" was cleaned to "I don't think that works.", correctly dropping the opening "no". The lock counted that "no" as a negation and inserted the transcript, "uh" included, in all five conditions (145/150).

The rule was then changed so that a sentence's opening "no" after fillers doesn't count; "There is no budget left" stays locked. Every lock-on run was repeated; the lock-off runs didn't need repeating. Because the change came after seeing the frozen set, that set no longer measures this one rule blind. None of the older sets has a direct-speech case that opens with "no", so their results are unaffected by the change.

## Offline check on earlier runs

Before any new inference, the rules were scored against the recorded outputs in this folder's earlier results, using the production prompt and routing (674 cleaned direct-speech outputs, `fidelity` cases). The lock would have fired 9 times, all on failed outputs (the same Serbian case), and never on a correct one. The 27 failures it leaves are relays rephrased into a message, such as "Tell him I am running 10 minutes late." → "I am running 10 minutes late." Those are outside a digits, names and negation lock.

## Eval design

- `context_replay.py` with `--word-lock off` or `--word-lock digitsNamesNegation`. The flag sets `DictationContextReplay.Input.wordLock` and goes through the real `DictationTextPreparation.prepare`.
- Qwen3.5-4B-Q4_K_M on the bundled llama-server, fixed seed, production Compose options. Hashes are in each run's `manifest.json`; local paths in them are rewritten to `~` and `/private/tmp/lokalbot-bench`.
- One Debug build per lock revision, run from a disposable copy with the runner's isolated home, storage and defaults (earlier rounds used Release). Latency compares off with on within the same build only.
- `context-wordlock-v1.json` (31 cases, synthetic) was written for the lock and frozen before its first inference ([`fixture-freeze.json`](fixture-freeze.json)). It covers digits (including Serbian and a repeated false start), negation in several spellings, unusual names (one at a sentence start, one spoken in lower case), self-corrections, filler controls and Transcribe.
- Raw outputs: [`raw-runs.tar.gz`](raw-runs.tar.gz).

## Not covered

- **Glossary respelling:** the replay has no personalization input, so this is covered by unit tests only.
- **Negation and self-correction cues are English.** The digit check works in any language written with ASCII digits.
- **Windows and Linux:** the port's cleanup output handling (`LinuxWindows/crates/lokalbot-ai/src/dictation.rs`) doesn't have the lock yet.
