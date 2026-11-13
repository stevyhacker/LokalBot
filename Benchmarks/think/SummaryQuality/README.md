# Summary quality

This benchmark measures how well LokalBot's meeting notes match human summaries, and whether the notes finish at all. It runs the app's own pipeline headlessly (`LokalBot Dev --process`) on 12 AMI scenario meetings and scores the notes against AMI's abstractive summaries (CC BY 4.0).

Each meeting is summarized from one or more transcript conditions. `ref` is AMI's manual transcript. `new` and `old` are the mixed headset recording, transcribed by two app builds. Every condition shares the same neutral title and metadata, so only the transcript differs.

## Run

Requirements:
- Xcode;
- `ffprobe`;
- a built `LokalBot Dev.app` (scheme `LokalBot Dev`);
- the app's models installed in `~/Library/Application Support/me.dotenv.LokalBot/models`;
- Python with `rouge-score`, `numpy`, `rapidfuzz` and `transformers`. The last two are needed by the shared word normalizer in `../CloudSTT/score.py`.

```bash
export SUMMARY_BENCH_DIR=/private/tmp/lokalbot-summary-bench
python3 prepare.py
APP="/path/to/DerivedData/Build/Products/Debug/LokalBot Dev.app"
CAP=180 ./run.sh "$APP" summary es2004a-ref is1009a-ref is1009c-ref ts3003a-ref
./run.sh "$APP" full es2004a-new is1009a-new
python3 score_summaries.py --app "$APP" --conditions ref,new --out results.json
```

`prepare.py` downloads the AMI annotations and recordings once and builds a meeting library under `$SUMMARY_BENCH_DIR/library`. Recordings already fetched for `Benchmarks/transcribe/CloudSTT` are reused. The library links to the installed models instead of copying them.

`run.sh` runs one meeting at a time with the Dev app's identity and a separate defaults suite, so it never touches the user's meetings or settings.
- `summary` uses `--summary-only` on an existing transcript.
- `full` transcribes, then summarizes.
- `transcript` transcribes only.

Finished folders are skipped, so a stopped batch resumes where it left off. Summaries of the reference transcripts take 10–80 s per meeting with the built-in Qwen3.5 4B. Transcribing takes about 1 minute per 20 minutes of audio. Run short batches with pauses between them: long back-to-back runs heat a laptop.

## Known limits

- **Sample size:** 12 meetings from three design teams. Small differences between conditions are within run-to-run variation, because summaries are sampled at temperature 0.1 without a seed.
- **ROUGE:** it rewards wording overlap with one human summary. Use it to compare conditions, not as an absolute quality score.
- **Coverage threshold:** it is calibrated against other teams' summaries of the same design task. A match therefore has to beat what any remote-control design meeting would score.
- **Decisions:** AMI states a team's decisions in one sentence, while the app writes one bullet per detail. Decision coverage understates the app's recall for that reason.
- **Keychain stall:** a Dev build that did not create the speaker-evidence Keychain key stalls on a Keychain prompt when it reads or writes speaker evidence. Transcribe each condition with a single build, and let `run.sh` set evidence aside before summary-only runs. The per-run `CAP` ends any stalled run.
- **Embedder leak:** headless runs leave the app's search embedder running after they exit, so `run.sh` stops it after each run.
