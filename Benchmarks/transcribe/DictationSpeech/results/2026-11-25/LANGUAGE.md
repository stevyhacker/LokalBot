# Qwen3-ASR language benchmark on the LokalBot v3 weights — 2026-11-25

`Benchmarks/transcribe/QwenLanguageSample` (FLEURS in ten languages and seven code-switched tracks, 40 dev utterances each,
plain and word layouts, 34 runs per path) was measured on 2026-11-23 with the earlier Qwen3-ASR 1.7B weights. This repeats it
on Qwen3-ASR-1.7B-LokalBot-v3, the app's default. **The findings carry over: plain-layout and code-switched text and the
pinned language are unchanged by the branch; on the word layout the second rule trades +3 word errors in German for −2 in
Spanish and halves the decodes. One of the 2026-11-23 accuracy results does not carry over: keeping the first decode now
costs a little on English and Russian at its largest exposure instead of helping.**

## What ran

- **Same corpus and test as 2026-11-23:** `items.json` and the 17 FLEURS-derived tracks from `fetch_tracks.py`, unchanged;
  `QwenLanguageSampleReplayTests` (the app's VAD, window merging and `QwenASREngine.decodeOnAuto`, one llama-server with the
  app's flags). The test gained one environment switch, `LOKALBOT_QWEN_SAMPLE_WEIGHTS=lokalbot-v3`, that selects
  `QwenLlamaASR.accuracyLokalBotV3` (and prints the weights' names) instead of `QwenLlamaASR.accuracy`.
- **Three paths, all on v3:** `old` is the replayed pre-sampling path (every window on auto, vote, every window again pinned;
  what 2026-11-23 called "before"); `master` is `decodeOnAuto` as of upstream master `e06d7968`; `branch` is `decodeOnAuto` of
  this branch at `9f2d5d3e` (both rules). `old` and `master` ran in one test run from the master worktree, `branch` in a second
  from this one, one after the other (10:52 to 11:40, nothing else heavy running).
- **Weights loaded:** `Qwen3-ASR-1.7B-LokalBot-v3-Q8_0.gguf` (2,165,035,040 bytes, SHA-256 `a3611b68…ee19`) and
  `mmproj-Qwen3-ASR-1.7B-LokalBot-v3-Q8_0.gguf` (355,709,376 bytes, SHA-256 `0eb67362…c785`), checked before the runs. The
  llama-server command line, sampled from the process list every 20 seconds during both runs (`server-args-*.txt` in the
  archive), shows the v3 decoder and projector in every sample (94 samples in the master run, 40 in the branch run) and the
  earlier weights in none. The test's own print of the weights name did not appear in the (quiet) xcodebuild log, so that
  check is the process list alone.
- **Time** is each path's decode time from single, unpaired runs and is indicative only; accuracy does not depend on run
  order (greedy decoding; a window decoded in the same language has the same text in every path: 1,369 of 1,369 sampled-vs-old
  windows identical).

## Decisions and text

| | Same pinned language and text, of 34 runs |
|---|---:|
| branch against old (2026-11-23's comparison: 31 of 34 for the first rule alone) | 27 |
| branch against master | 30 |
| master against old | 31 |

- **Plain layout: 17 of 17 identical** across old, master and branch, pinned language included.
- **Code-switched tracks: all 14 runs identical** across the three paths. Replaying the rule over every run of 2 to 12
  consecutive windows (9,130 stretches, `language-stretches.txt`): the old path decodes twice in 7,238 and the first rule
  skips that in 3,969; of 1,285 stretches that truly cross a language change, 15 keep the first decode, all on the
  English/German track that alternates every five utterances (14 plain, 1 word). Same count as on the earlier weights.
- **Word layout, 3 differences against master and old that are not new:** Bosnian, Croatian and Serbian go to speaker regions
  under every path (no whole-track text to compare), pinned language `hr` throughout; only the decode count falls (20, 17, 17
  to 12).
- **Word layout, second rule:** German, English, Spanish and Russian differ from master in text (French applies the rule
  and its text is identical). These are the tracks where merged windows make 14 to 20 spans.

## Accuracy

Word error rate (characters for Japanese and Chinese) from FLEURS references. Plain layout, identical across the three paths:

| | bs | de | en | es | fr | hr | ja | ru | sr | zh |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| v3, any path | 27.84 | 3.24 | 6.17 | 3.60 | 5.25 | 21.94 | 11.85 | 6.51 | 17.83 | 5.94 |
| earlier weights, 11-23 (pinned) | 34.89 | 3.72 | 8.52 | 4.66 | 5.04 | 24.77 | 13.30 | 7.46 | 21.59 | – |

The v3 weights are better than the earlier ones on eight of the nine tracks with an earlier figure (French is 5.25 against 5.04, +0.21 points; Chinese was not in the 2026-11-23 table).

Word layout, word errors (old / master / branch), of reference words:

| track | old | master | branch | of |
|---|---:|---:|---:|---:|
| de | 31 | 31 | **34** | 834 |
| en | 39 | 39 | 39 | 810 |
| es | 36 | 36 | **34** | 945 |
| fr | 52 | 52 | 52 | 972 |
| ru | 51 | 51 | 51 | 737 |
| ja (characters) | 229 | 229 | 229 | 2,008 |
| zh (characters) | 68 | 68 | 68 | 1,280 |

Pooled over every run that has a transcript (both layouts, 26,547 units): 2,401 / 2,401 / 2,402 errors. German goes from
3.72% to 4.08%, Spanish from 3.81% to 3.60%. On 2026-11-23: German 25 → 27, Spanish 41 → 39 (same direction, same
tracks). English and Russian text differ after the second rule but with the same error count.

Serbian, Croatian and Bosnian (plain layout, pinned against all-Automatic, `language-stretches.txt`): Croatian 21.94% against
23.23%, Bosnian 27.84% against 28.08%, **Serbian 17.83% against 17.27%**. On the earlier weights the gaps were larger (Croatian
24.77% against 33.68%); on v3 the pinned decode is still better for Croatian and Bosnian but not for Serbian, where Automatic
is ahead by 4 words of 718. The family stays excluded from both rules either way, so nothing changes for it; the reason given
in the PR ("the pinned decode is the better one there") is weaker on v3 than it was.

At the first rule's largest exposure (every agreeing window of a one-language track keeps its Automatic decode, plain
layout; no real run does this, tracks that long take the unchanged path): German 3.24% → 3.24%, Spanish 3.60% → 3.60%, French
5.25% → 5.25%, **English 6.17% → 6.30% (+1 word of 810), Russian 6.51% → 7.06% (+4 of 737)**; on the earlier weights English
improved (8.52 → 6.67) and Russian improved (7.46 → 7.06). This matches the dictation benchmark's small change in the wrong
direction on v3, within noise at these sizes.

## Work and time

Decodes (sum over 17 tracks) and decode seconds, old / master / branch, single unpaired runs:

| layout | decodes | seconds |
|---|---|---|
| plain | 1,283 / 1,029 / 1,029 | 562 / 453 / 458 |
| word | 474 / 400 / 340 | 459 / 399 / 335 |

Plain layout: the branch is the same as master (every track has more than 24 spans). Word layout: 15% fewer decodes and about
16% less time than master, 27% less than old; per track German 33.4 → 20.7 s, English 25.7 → 12.9 s, Spanish 34.2 → 20.0 s,
French 33.3 → 19.3 s, Russian 35.0 → 20.7 s.

## What weakens the case

- German word layout: +3 word errors (31 → 34 of 834) from the second rule, the same direction as on the earlier weights
  (+2); Spanish compensates (−2), English, French and Russian unchanged.
- At the first rule's largest exposure, English and Russian are now slightly worse (+1 and +4 words), where they improved on
  the earlier weights. No real run here sits at that exposure, and the sizes are within noise, but "same or better" is not
  what v3 shows.
- The justification for keeping Serbian, Croatian and Bosnian out is weaker on v3: Serbian Automatic is ahead of pinned.
- Not checked by a Serbian speaker, as before; the AMI meetings and the real-meeting sets were not re-run.

## Files

`language-aggregates.json` (per-track records: pinned language, errors, decodes, seconds, and the three comparisons),
`language-stretches.txt` (the stretch analysis, `simulate_one_decode.py` of 2026-11-23, sections 1 to 3),
`language-analyze.py` (produces the aggregates from the two runs files; run from the `QwenLanguageSample` folder with
`QLS_OUT` pointing at the folder that holds `items.json`), `language-raw-runs.tar.gz` (every window's text, language and time,
both runs files, the sampled server command lines with the key redacted, the run log).
