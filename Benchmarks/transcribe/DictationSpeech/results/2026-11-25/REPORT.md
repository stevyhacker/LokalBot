# Qwen3-ASR on Automatic: keeping the first decode, on the LokalBot v3 weights — 2026-11-25

## Outcome

The 2026-11-23 measurements used the earlier Qwen3-ASR 1.7B weights. The app's default is now Qwen3-ASR-1.7B-LokalBot-v3,
so the same before/after was repeated on it: same 32 recordings (30 to 134 seconds, 43.1 minutes), same runner, Release
builds of master and of this branch alternating in one session. **The speed-up is the same as before; the accuracy
difference is now slightly in the wrong direction and within noise.** The language benchmark (ten languages, code-switched
tracks, word layout) was repeated too: `LANGUAGE.md`; plain-layout and code-switched text is unchanged, and the word layout
trades +3 word errors in German for −2 in Spanish.

| Qwen3-ASR 1.7B, LokalBot v3 | Word error rate | Median time | Paired time vs. the first row | Total for the 32 | × real time |
|---|---:|---:|---:|---:|---:|
| Automatic, before (`e06d7968`) | 3.15% | 7.82 s | 1.00 | 238.8 s | 10.8 |
| Automatic, after (`06e56e81`) | 3.21% (+0.06, 0.00 to +0.14) | 4.74 s | 0.58 (0.57 to 0.59) | 146.8 s | 17.6 |
| English (after build) | 3.15% (+0.00) | 4.51 s | 0.58 (0.56 to 0.59) | 137.1 s | 18.9 |
| Automatic, after, repeat | 3.21% | 4.77 s | 0.58 (0.56 to 0.59) | 146.9 s | 17.6 |
| Automatic, before, repeat (last) | 3.15% | 7.92 s | 1.00 (1.00 to 1.01) | 242.9 s | 10.6 |

Word error rate intervals are a paired 2,000-sample bootstrap over recordings; the interval after the time ratio is the same
bootstrap of the median ratio. Per-recording ratios of Automatic after to before range from 0.53 to 1.00 (no recording
slower than 1.003).

Median seconds per recording by length:

| | 30 s (8) | 60 s (7) | 90 s (7) | 120 s (10) |
|---|---:|---:|---:|---:|
| Automatic, before | 3.69 | 6.28 | 8.54 | 10.30 |
| Automatic, after | 2.21 | 3.52 | 5.12 | 5.97 |
| English | 2.22 | 3.53 | 4.91 | 5.95 |

- **Time:** unchanged by the weights. Automatic after takes 0.58 of Automatic before (0.58 on 2026-11-23); English is 0.58
  of it (0.57). Medians and totals match the 2026-11-23 table to within 3%: before 7.82 s against 7.79 s, after 4.74 s
  against 4.77 s, English 4.51 s against 4.51 s, totals 238.8 / 146.8 / 137.1 s against 239.9 / 151.4 / 137.3 s.
- **Accuracy:** the v3 weights are better than the earlier ones on this set (Automatic before 3.15% against 3.40%, English
  3.15% against 3.40%). The change itself now costs a little: 204 word errors after against 200 before, of 6,356
  reference words (+0.06 points, interval 0.00 to +0.14, which touches zero). On 2026-11-23 the same comparison was −0.05
  (−0.14 to +0.03). Neither result separates from zero, but this one does not support "same or slightly better".
  The extra errors sit in three recordings (+1, +2 and +1 errors); no recording got better.
- **Text:** Automatic after differs from Automatic before in 14 of the 32 recordings (17 on 2026-11-23): 7 of them
  recordings that decode once in the whole-track path, 7 of the 14 that go through the language sample. Only 5 of the 14
  differ after the word-error normalizer; the other 9 differ only in text the normalizer treats as equal (punctuation, casing, number format). English matches Automatic before exactly
  in all 32 (the pinned decode is what Automatic before returns on this set). Automatic after matches English in 18 of
  32. Repeats are exact: each build gives identical text in both of its runs (32 of 32), which means the
  differences are the rules' and not run-to-run decoding noise.
- **Still decoding twice:** 3 of 32 (4 on 2026-11-23). In the app log's `twice` field, before is `true` for 18 of the 32 and
  after for 1 (a 60-second recording, `test-other-533-131564`, 11 spans, a span the language recognizer does not place with
  confidence). The 14 recordings with more than 12 spans go through the 12-span language sample under both builds, so the
  log's `twice` field does not show their second decode. Two of them stay slow in the after build (`test-clean-1089-134691`,
  `test-other-2414-128292`, both 15 spans, 1.64 and 1.77 times as long as English); that count is inferred from their
  time, not from a log field. The other 29 recordings are within 3% of English.
- **Drift check:** the repeat of the first row at the end of the session (before, last) is within 1.3% on median time and
  identical in text; the repeat of the after build is within 0.5%. Three recordings were more than 10% slower in the last run
  (largest ratio 1.17), run-to-run noise.

## Model and builds

- **Weights loaded:** `Qwen3-ASR-1.7B-LokalBot-v3-Q8_0.gguf` (2,165,035,040 bytes, SHA-256
  `a3611b68d5065e3984d0cf8a93adaf7cfaf5f4a09b33da8d68914a7ae85aee19`) and `mmproj-Qwen3-ASR-1.7B-LokalBot-v3-Q8_0.gguf`
  (355,709,376 bytes, SHA-256 `0eb673620a73c412a0de2bb31a427ac5367f686e14db0922944023e44356c785`), both matching the app's
  catalog entry (`QwenLlamaASR.accuracyLokalBotV3`; the runner's `--model qwen3-asr-1.7b-lokalbot-v3`).
- **How they were placed:** the disposable home held only these two files (with their SHA-256 markers) at the folder the
  app reads, so the app had nothing to download and the earlier weights were absent. The check of what was loaded: each
  run's app log (`runs/*/stderr.log` in the archive) has 97 `qwen-asr profile` lines, every one with
  `model=…Qwen3-ASR-1.7B-LokalBot-v3-Q8_0.gguf`, and `runs/*/llama-server-args.txt` has the `llama-server -m` and `--mmproj`
  paths sampled from the process list during the run (v3 decoder and projector, in all 5 runs). No download line appears.
- **Server build:** the llama.cpp runtime bundled in both apps, `b12613-macos15.0-arm64-generic-loader-rpath`, the same in
  both. The disposable home used on 2026-11-23 held runtime `v1.0.0-macos15.0-arm64-generic-loader-rpath`, so the
  comparison with 2026-11-23 mixes weights, runtime and base commit; the identical timings suggest the runtime made no
  difference to these decodes.
- **Builds:** Release, ad hoc signed, from `e06d7968` (master, with the speech replay) and `06e56e81` (this branch). They
  differ in `QwenASREngine.swift` and `TranscriptLanguageVote.swift` only. Each manifest has the commit and the SHA-256 of
  the app's executable: before `e1ddea36…`, after `eeba90e9…`.
- **Machine:** Apple M4 Pro, 48 GB (Mac16,8), macOS 26.7.3, 2026-11-25.

## Eval design

- **Recordings, runner and scoring:** as in `../2026-11-23/REPORT.md`; one warm-up, three passes, the middle one reversed.
  `run.py` gained the configurations `qwen-v3-auto` and `qwen-v3-en` for the v3 weights.
- **Order (one session, `PLAN.md` written before any inference):** before, after, English (after build), after (repeat),
  before (repeat). English ran once, on the after build.
- **Conditions:** four of the five runs started with no process above 25% of a core; the second run (after) began while
  another application's helper process was at about 80% of a core, and its repeat, started on an idle machine, agrees to 0.5%. A development copy of the app was open and idle throughout. Nothing else heavy ran.
- Outputs and the app's logs are in `raw-runs.tar.gz`; `runs/` has each run's manifest and `summary.json` every aggregate,
  with `before` as the baseline.

## Not covered

- **The language benchmark** was re-run on the v3 weights: see `LANGUAGE.md`. AMI was not part of it.
- **Meetings:** tracks of more than 24 spans take the unchanged path; AMI and the real-meeting sets were not re-run.
- **Read speech, not dictation**, as in the earlier reports. English was not run on the before build.
