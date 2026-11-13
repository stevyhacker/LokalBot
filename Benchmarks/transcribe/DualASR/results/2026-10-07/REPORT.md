# Two transcription models for Serbian meetings — 7 October 2026

Merging two transcripts is not worth building. Choosing the engine per track would help Serbian-language meetings, but it was not adopted (see **Decision**). On Serbian, Croatian and Bosnian speech, Whisper large-v3 turbo with the Bosnian hint (`bs`) made 25–50% fewer errors than Qwen3-ASR 1.7B on auto, the default. It also always wrote Latin script. On the owner's Serbian meeting, its WER was 26.9% against 39.1% for the app's current setting, which pins Qwen to English. On English-led audio, Whisper was far worse than Qwen. Once each track uses the better engine, a perfect per-window choice between the two transcripts gains 0.4 points on the meeting and 1.7–3.4 points on the most code-switched test track. A rule, a small classifier and a local LLM judge all did worse than simply keeping Whisper on Serbian-language tracks. No app code changed.

**Systems.** `harness/` decodes the app's Qwen 1.7B word-attribution windows (Silero VAD regions merged across pauses of up to 5 s into windows of up to 60 s) with both engines:

- **Qwen3-ASR 1.7B** (`aufklarer/Qwen3-ASR-1.7B-MLX-8bit`, speech-swift 0.0.28, repetition blocking off), with the language on auto, set to `en`, `sr`, `Serbian` or `hr`, or replaying the app's vote-and-pin. `vote-bcms` is the proposed vote-and-pin change that pins Croatian, Bosnian and Serbian votes to `sr`.
- **Whisper large-v3 turbo** (`openai_whisper-large-v3-v20240930`, WhisperKit 1.1.0, the app's pinned Core ML model and decoding options), with the language on auto or set to `sr`, `hr` or `bs`.

Everything ran serially on an Apple M4 Max with 48 GB.

**Data.** The FLEURS tracks are read speech with a human reference: Serbian (531 reference words), Croatian (616) and Bosnian (628), plus two code-switched tracks. `sr+en` repeats four Serbian utterances and one English (536 words); `en+sr` is the reverse (623 words). The meeting is the owner's 10-minute Montenegrin/Serbian call of 7 October. The app transcribed it with the setting pinned to `en`. Gemini 3.5 Transcribe rejected every request that day ("Thinking is not enabled for this model"), whatever the settings. The meeting reference is therefore Gemini 3.8 Flash, prompted for a verbatim transcript at temperature 0 (see **Reference quality**). Scoring transliterates Serbian Cyrillic to Latin, so script choice alone is never an error. The non-Latin column reports script separately.

## Results

WER in %. The best result in each column is bold.

| Condition | Serbian | Croatian | Bosnian | `sr+en` | `en+sr` | Meeting | Non-Latin letters | Speed |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| Qwen `en` (owner's setting) | 17.5 | 27.1 | 37.1 | 33.0 | 14.3 | 39.1 | 3.5% | 42× |
| Qwen auto | 17.3 | 26.8 | 36.8 | 32.8 | **12.4** | 38.3 | 3.1% | 33× |
| Qwen vote and pin (shipped) | 17.3 | 26.8 | 36.8 | 32.8 | 14.3 | 38.3 | 2.6% | 36× |
| Qwen vote and pin → `sr` | 14.5 | 29.2 | 36.5 | 32.5 | 14.3 | 38.8 | 47.1% | 20× |
| Qwen `sr` | 14.5 | 29.2 | 36.5 | 32.5 | 46.7 | 38.8 | 53.3% | — |
| Qwen `Serbian` | 14.9 | 29.4 | 35.8 | 32.6 | 68.2 | 41.9 | 47.4% | — |
| Qwen `hr` | 18.1 | 24.8 | 36.8 | 29.5 | 40.9 | 38.5 | 0.1% | — |
| Whisper auto | 13.2 | 15.7 | 22.5 | 30.0 | 46.9 | 31.8 | 2.5% | 16× |
| Whisper `sr` | **13.0** | 15.7 | 28.5 | 28.5 | 69.7 | 36.2 | 2.1% | — |
| Whisper `hr` | 13.2 | 15.7 | 22.8 | 28.4 | 78.8 | 27.4 | 0.0% | — |
| **Whisper `bs`** | **13.0** | **13.0** | **22.3** | **28.0** | 51.8 | **26.9** | **0.0%** | 17× |

Speed is audio seconds per decode second over all seven tracks. The vote rows include their auto pass.

- **Pinning Qwen to `sr` trades script for accuracy.** It cut Serbian WER from 17.3% to 14.5%, matching the 30 September result, but about half the output letters came out in Cyrillic. Croatian got worse (29.2% against 26.8%). The proposed `vote-bcms` change is therefore rejected: it would write Latin-script meetings in Cyrillic.
- **Qwen pinned to English on Serbian speech partly translates.** The app's saved transcript of the meeting has Greek, Russian and Portuguese phrases, including a short Serbian reply rendered in Russian. Apple's recognizer reads all three test languages as Croatian, and Qwen does not support Croatian, so the shipped vote-and-pin left every Serbian-language track on auto.
- **Whisper is the better engine for Serbian, Croatian and Bosnian.** With `bs`, it led every Serbian-language column and the meeting, and wrote no Cyrillic. Montenegrin speech is ijekavian (*dvije*, *dijelu*), which Bosnian spelling matches. Whisper `sr` wrote some Cyrillic on the meeting and scored 36.2%.
- **Whisper is wrong for English-led audio.** On `en+sr`, Whisper turned English sentences into garbled pseudo-Serbian, looped on repeated words and dropped sentences (46.9–78.8%). Qwen on auto was best (12.4%), ahead of pinned English (14.3%), because pinning to English garbles the Serbian minority.

## Combining the two transcripts

The oracle picks whichever transcript has fewer errors in each window. It is the ceiling for any judge.

| Main transcript / second opinion | Serbian | Croatian | Bosnian | `sr+en` | `en+sr` | Meeting |
|---|---:|---:|---:|---:|---:|---:|
| Whisper `bs` alone | 13.0 | 13.0 | 22.3 | 28.0 | 51.8 | 26.9 |
| Oracle with Qwen auto | 12.8 | 13.0 | 22.1 | 26.3 | 12.4 | 26.5 |
| Oracle with Qwen `hr` | 13.0 | 13.0 | 22.1 | 26.3 | 29.5 | 26.5 |
| Oracle with Qwen `sr` | 12.2 | 13.0 | 22.0 | 24.6 | 35.5 | 26.9 |

With each track on its better engine, the per-window ceiling is 0–0.8 points on single-language Serbian, Croatian and Bosnian, 0.4 on the meeting, and 1.7–3.4 on `sr+en`.

Judges were then asked to pick per window between Qwen auto (A) and Whisper `bs` (B), with no track-level routing. All three would have to learn the routing themselves.

| Judge | Serbian, Croatian, Bosnian | Code-switched | Meeting |
|---|---:|---:|---:|
| Always Qwen auto | 28.7 | 21.8 | 38.3 |
| Always Whisper `bs` | 19.0 | 40.8 | 26.9 |
| Oracle | 18.5 | 18.8 | 26.5 |
| Rule: switch to B when A is in an unexpected language or script | 27.8 | 23.5 | 37.9 |
| Logistic regression, leave-one-track-out | 19.0 | 40.8 | 31.8 |
| Qwen3.5 4B `Q4_K_M` (the notes model), A or B by token probability, both orders | 20.9 | 24.6 | 29.6 |

- The logistic features were script and language of each transcript, words per second, agreement between them, and Whisper's mean log-probability, no-speech probability and compression ratio. It chose Whisper for every FLEURS window, English-led ones included, and lost 4.9 points to always-Whisper on the meeting.
- The LLM judge came closest. It still lost 1.9–2.8 points to the right engine per track type.
- Every judge here reads only text. Without the audio, it can tell which transcript reads more plausibly, not which one was said.

Decision models such as TypeSafe's Jev, Cloudflare's Clef and Convai's Laya were not tried. They return calibrated probabilities over text inputs only. Jev is hosted only, so transcripts would leave the Mac. Clef's smaller model is a 9B Qwen3.5 fine-tune, larger than the notes model. Laya's 322M multilingual checkpoint could run locally. With an oracle ceiling of 0.4 points on the meeting, none can pay for itself here.

## Reference quality

- **FLEURS:** the human transcripts are in Cyrillic for Serbian and are transliterated for scoring. The tracks are read speech; the code-switched tracks are synthetic.
- **Gemini 3.8 Flash as the meeting reference:** on the 12 FLEURS Serbian and `sr+en` windows, it scored 2.8% WER on Serbian. On one 57-second mixed window, it returned only the last sentence; excluding that window, it scored 5.3% overall. On the meeting, it also rendered some short Serbian clips in Russian. Meeting windows therefore count only when they are at least 5 s long and have at least 5 reference words, mostly in Latin script, and when the reference is at least half the median length of the local transcripts. That kept 23 of 36 windows (1,589 words). The meeting comparison is one 10-minute call scored against a rough reference.

## Decision

No change was adopted. The gain would be limited to Serbian-language meetings. The owner judged it not worth the complexity: a 1.6 GB Whisper download, about 7 extra minutes per meeting hour, and new speaker-attribution work on Whisper text. The next section records the measured option for later research.

## The measured option

- Route Serbian-language tracks to Whisper with `bs`. Specifically: when the existing auto pass votes Croatian, Bosnian or Serbian for at least 80% of a track's text, re-decode that track with Whisper large-v3 turbo set to `bs`, instead of keeping Qwen's per-window auto output.
  - On these tracks, this beat Qwen on auto by 4–15 points on FLEURS and by 11 points on the meeting. Even Qwen's best setting for each column trailed by 1.5–13.5 points.
  - English-led tracks keep Qwen.
  - The cost is the Whisper download (about 1.6 GB) and decoding at 17× real time against Qwen's 33–42×: about 7 extra minutes for a one-hour, two-track meeting.
  - Not yet checked: word timing for speaker attribution on Whisper text. Qwen3-ForcedAligner does not list Serbian, and the app currently aligns Qwen's Serbian output the same way. Whisper's own word timestamps are the alternative.
- The owner's `en` setting skips the vote entirely. Auto is needed for routing to happen.
- Possible follow-up: on English-led tracks with a real Serbian minority, auto beat pinned English by 1.9 points. A rule could skip pinning when the minority vote is a language the user speaks rather than scattered misfires.

## Reproduction and privacy

`../../README.md` describes the harness. `summary.json` holds only aggregates. Meeting audio, clips, transcripts and cloud references stay in the private `DUAL_ASR_OUT` folder. With the owner's approval, the meeting's speech windows (about 10 minutes, including the other participant's voice) were sent to Google's Gemini API to build the reference.
