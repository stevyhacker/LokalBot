# Live Radar and Follow-through replays

Read the [AMI evaluation](results/2026-10-27/REPORT.md) and the [fast live text check](results/2026-10-28-live-text/REPORT.md).

These harnesses run LokalBot's own Live Radar and Follow-through code against the Meta Model API on public or synthetic transcripts. Nothing here reads a LokalBot library or the Keychain. Both features were built for the Meta Global AI Developer Hackathon; see [HACKATHON.md](../../HACKATHON.md).

## What a replay does

`LokalBot Dev --radar-replay <fixture.json>` replays a timed transcript the way the app's live preview delivers it:

- **Timing.** A line becomes visible `--delay` seconds (default 12) after it starts, the preview's chunk length. A pass runs every `--interval` seconds of meeting time (default 20), as `MeetingRadar` does.
- **Requests.** Each pass goes through `MeetingRadarAnalyzer` (prompt, strict schema, quote and evidence checks, de-duplication) and `MuseChatClient` (`reasoning_effort` minimal).
- **Earlier meetings.** The fixture supplies the earlier-meeting passages instead of library search, so runs are repeatable.
- **Output.** One JSON line per pass gives timing, tokens, cost, and the items kept and rejected. A final summary line adds `shownAfter`: seconds from when a line was said to when its item would appear on screen, counting the preview delay, the wait for the next pass, and the request.

`--audio <folder>` replays the meeting as fast live text runs it instead, in real time. `voice_fixture.py` voices a fixture with macOS `say`, one voice per track, into `me.wav` and `them.wav`. The replay streams both files to Muse Voice Transcribe through the app's own client (`MuseLiveTextTrack`), each finished turn becomes a line, and a pass follows each turn at most every `--interval` seconds (default 3, the app's turn interval). `shownAfter` is then measured on the wall clock, and the summary adds each line's text and arrival time.

`LokalBot Dev --follow-through-replay <fixture.json>` runs `FollowThroughSession` on Muse Wonder with read tools that answer from the fixture. Every proposal is recorded and approved without being carried out.

Both read the key from `META_API_KEY`. `--radar-replay` also takes `--base-url <url>` to send the same requests to another OpenAI-compatible server instead, such as llama-server running Meta's open-weight Muse Glimmer, which needs no key. `--reasoning-line low` adds the "Reasoning effort: low" line Glimmer's chat template reads from the system prompt.

## Synthetic checks

`fixtures/synthetic-launch-sync.json` is a two-minute scripted meeting with six things the radar should catch:
- a commitment of the user's own;
- a commitment of someone else's;
- a question that is answered later;
- a decision;
- two contradictions with an earlier meeting: a moved launch date and a smaller free tier.

`fixtures/synthetic-follow-through.json` is the follow-through case for the user's commitment from that meeting.

```bash
APP="path/to/DerivedData/Build/Products/Debug/LokalBot Dev.app"
"$APP/Contents/MacOS/LokalBot Dev" --radar-replay fixtures/synthetic-launch-sync.json --model muse-spark-1.3
"$APP/Contents/MacOS/LokalBot Dev" --follow-through-replay fixtures/synthetic-follow-through.json --model muse-wonder-1.0
python3 -I voice_fixture.py fixtures/synthetic-launch-sync.json /private/tmp/voiced-launch-sync
"$APP/Contents/MacOS/LokalBot Dev" --radar-replay fixtures/synthetic-launch-sync.json --audio /private/tmp/voiced-launch-sync
```

## AMI meetings

`prepare.py` turns the 12 AMI scenario meetings of [Benchmarks/SummaryQuality](../SummaryQuality/README.md) into radar fixtures from AMI's manual transcripts (CC BY 4.0).
- **Speakers.** The Project Manager is the microphone ("Me"). The other three people share the call track ("Others"), with no voices told apart, as in the live preview.
- **Earlier meetings.** Each fixture gets the human decision and action sentences of the same team's earlier meetings as its earlier-meeting passages.

`run.sh` replays every fixture with one model. `prepare.py --notes` also builds a meeting library of the same transcripts, and SummaryQuality's `run.sh` writes LokalBot's post-meeting notes into it. `score.py` then scores the radar and the notes against AMI's human summaries, with one matching threshold for both.

```bash
export MUSE_RADAR_DATA=/private/tmp/lokalbot-muse-radar
python3 prepare.py --notes
META_API_KEY=... ./run.sh "$APP" muse-spark-1.3
META_API_KEY=... ./run.sh "$APP" muse-wonder-1.0 ES2004b ES2004d IS1009b IS1009d TS3003b TS3003d
SUMMARY_BENCH_DIR=$MUSE_RADAR_DATA CAP=240 ../SummaryQuality/run.sh "$APP" summary \
  es2004a-ref es2004b-ref es2004c-ref es2004d-ref is1009a-ref is1009b-ref \
  is1009c-ref is1009d-ref ts3003a-ref ts3003b-ref ts3003c-ref ts3003d-ref
python3 score.py --app "$APP" --notes $MUSE_RADAR_DATA/library --save results/<date>/scores.json
python3 score.py --app "$APP" --notes $MUSE_RADAR_DATA/library \
  --meetings ES2004b,ES2004d,IS1009b,IS1009d,TS3003b,TS3003d --save results/<date>/scores-six-meetings.json
```

The scorer needs `numpy` and LokalBot's EmbeddingGemma 2 model in the app's models folder.

## Limits

- **Clean transcripts.** The AMI fixtures use manual transcripts. They show what the radar does with clean text, not with the live preview's recognition errors.
- **Annotation size.** AMI's annotators wrote 20 action sentences and 62 decision sentences for these 12 meetings. Several decisions often share one sentence, so coverage of decisions understates recall.
- **Stand-in history.** Earlier-meeting passages are human summary sentences, standing in for the outcomes LokalBot would have saved.
- **Model updates.** The Muse models are versionless from the client's side, so a later run may differ.
