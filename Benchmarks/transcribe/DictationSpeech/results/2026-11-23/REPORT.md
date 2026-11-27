# Qwen3-ASR on Automatic: keeping the first decode — 2026-11-23

## Outcome

The 2026-11-21 report found that on Automatic a dictation is transcribed twice. Two rules now keep the language-free
decode when it already reads as the voted language. Same 32 recordings (30 to 134 seconds, 43.1 minutes), same runner,
Release builds of the commit before the change and of each rule, alternating in one session on an idle machine:

| Qwen3-ASR 1.7B | Word error rate | Median time | Paired time vs. the first row | Total for the 32 | × real time |
|---|---:|---:|---:|---:|---:|
| Automatic, before (`a9085e7a`) | 3.40% | 7.79 s | 1.00 | 239.9 s | 10.8 |
| Automatic, first rule (`18c7ada3`) | 3.37% (−0.03, −0.11 to 0.00) | 4.93 s | 0.61 (0.54 to 1.00) | 198.2 s | 13.0 |
| Automatic, both rules (`e229b812`) | 3.35% (−0.05, −0.14 to +0.03) | 4.77 s | 0.58 (0.54 to 1.00) | 151.4 s | 17.1 |
| English | 3.40% | 4.51 s | 0.57 (0.54 to 0.62) | 137.3 s | 18.8 |

Median seconds per recording by length:

| | 30 s (8) | 60 s (7) | 90 s (7) | 120 s (10) |
|---|---:|---:|---:|---:|
| Automatic, before | 3.71 | 6.33 | 8.59 | 10.35 |
| Automatic, first rule | 2.22 | 3.51 | 7.37 | 10.32 |
| Automatic, both rules | 2.22 | 3.51 | 5.15 | 5.97 |
| English | 2.20 | 3.54 | 4.88 | 5.96 |

- **First rule: a track sampled whole keeps its decode.** With up to 12 speech spans the language sample is every span.
  When the whole-track vote is for a language outside the Serbian family and every span long enough to judge reads as
  that language (and those spans are at least 80% of the text), the first decode is returned and nothing decodes again.
  This covered 17 of the 18 recordings that were sampled whole; the other one had a span the recognizer could not place
  and still decodes twice. It does nothing for the 14 recordings with more than 12 spans.
- **Second rule: a sample that is at least half the track keeps its decodes.** Those 14 recordings went through the
  sample (12 spans on Automatic), then every span again pinned. Under the same conditions on the sampled spans, they keep
  their text and only the unsampled spans decode pinned. This applies up to 24 spans; longer tracks decode as before.
  It covered 11 of the 14; in the other three a sampled span did not read as English with confidence.
- **Same accuracy, slightly different punctuation.** The pinned and the language-free decode of an English span are not
  always the same text: against the run before the change, the first rule's text differs in 9 of 32 recordings and both
  rules' in 17. The word error rate moved by −0.03 and −0.05 points, with paired intervals that include zero.
- **No recording got slower** (largest paired ratio 1.00). Automatic is now within 3% of English on 28 of the 32; the
  other four still decode their spans twice and take 1.65 to 1.80 times as long as English.
- Repeats: each build ran twice, with identical text and paired times of 1.00 (0.98 to 1.01).

## Other languages

`Benchmarks/transcribe/QwenLanguageSample` (FLEURS in ten languages and seven code-switched tracks, plain and word
layouts, 34 runs per build), the new path against the old one:

- **First rule alone:** 31 of 34 runs have the same pinned language and the same text as before the change. The three that
  differ are Bosnian, Croatian and Serbian in the word layout, which go to speaker regions under both builds and so carry
  no whole-track text to compare; their pinned language is unchanged.
- **Serbian, Croatian, Bosnian:** always excluded from both rules, because the pinned decode is the better one there
  (Croatian FLEURS: 24.77% pinned against 33.68% on Automatic). Their plain-layout text is identical before and after.
  This has not been checked by a Serbian speaker.
- **Japanese and Chinese:** written without spaces, their spans are too short in words to judge, so the 80% condition keeps
  them on the pinned decode. Text identical before and after.
- **Code-switched tracks:** text identical before and after in all seven. Replaying the rule over every run of 2 to 12
  consecutive windows of the recorded decodes (9,130 dictation-length stretches): the old path decoded twice in 6,927 and
  the first rule skips that in 3,969; of 1,285 stretches that truly cross a language change, 15 keep the first decode,
  all on the track that alternates English and German sentence by sentence.
- **Second rule on the word layout:** merged spans make a six-minute track 14 to 20 spans, so the rule applies to German,
  English, Spanish, French and Russian there. Decoded windows fell from 26–32 to 14–20 and decode time by about 40%
  (single runs, not paired). Word errors: German 25 → 27 of 834, Spanish 41 → 39 of 945, English, French and Russian
  unchanged. In the plain layout every track has more than 24 spans and is unchanged.

## Eval design

- **Recordings, runner and scoring:** as in `../2026-11-21/REPORT.md` (`../../long-dictation-v1.json`, `LokalBot Dev
  --dictation-speech-replay`, `../../score.py`); one warm-up, three passes, the middle one reversed. Apple M4 Pro, 48 GB,
  macOS 26.7.3, no other process above 25% of a core when each run started.
- **Order:** two sessions on the same afternoon. First: before, first rule, English, first rule, before. Second: first
  rule, both rules, both rules, first rule. The first rule's four runs across the two sessions agree within 0.2%, so the
  tables place both sessions side by side; `runs/` has every run's manifest and `summary.json` every aggregate, with
  `before` as the baseline. Each manifest's commit is the commit of the app that ran.
- **Paired time** is the median over recordings of the ratio to the first row, with the smallest and largest ratio in
  parentheses; word error rate intervals are a paired 2,000-sample bootstrap over recordings.
- Outputs and the app's logs (spans, sample size and second decode per recording) are in `raw-runs.tar.gz`.

## Not covered

- **Meetings:** tracks of more than 24 spans take the unchanged path, and AMI and the real-meeting sets were not re-run.
  A meeting track of up to 24 merged spans (a few minutes) does take the second rule; only the FLEURS word-layout tracks
  above measure that.
- **The four recordings that still decode twice** (one sampled whole, three through the sample; two of them in the
  90-second group, which is why its median stays above English) have a span the language recognizer does not place with
  confidence. A looser rule was not tried.
- **Read speech, not dictation**, as in the earlier report.
