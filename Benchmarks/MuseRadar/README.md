# Live Radar and Follow-through replays

These harnesses run LokalBot's own Live Radar and Follow-through code against the Meta Model API on public or synthetic transcripts. Nothing here reads a LokalBot library or the Keychain. Both features were built for the Meta Global AI Developer Hackathon; see [HACKATHON.md](../../HACKATHON.md).

## What a replay does

`LokalBot Dev --radar-replay <fixture.json>` replays a timed transcript the way the app's live preview delivers it:

- **Timing.** A line becomes visible `--delay` seconds (default 12) after it starts, the preview's chunk length. A pass runs every `--interval` seconds of meeting time (default 20), as `MeetingRadar` does.
- **Requests.** Each pass goes through `MeetingRadarAnalyzer` (prompt, strict schema, quote and evidence checks, de-duplication) and `MuseChatClient` (`reasoning_effort` minimal).
- **Earlier meetings.** The fixture supplies the earlier-meeting passages instead of library search, so runs are repeatable.
- **Output.** One JSON line per pass gives timing, tokens, cost, and the items kept and rejected. A final summary line adds `shownAfter`: seconds from when a line was said to when its item would appear on screen, counting the preview delay, the wait for the next pass, and the request.

`LokalBot Dev --follow-through-replay <fixture.json>` runs `FollowThroughSession` on Muse Wonder with read tools that answer from the fixture. Every proposal is recorded and approved without being carried out.

Both read the key from `META_API_KEY`.

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
```

## AMI meetings

`prepare.py` turns the 12 AMI scenario meetings of [Benchmarks/SummaryQuality](../SummaryQuality/README.md) into radar fixtures from AMI's manual transcripts (CC BY 4.0).
- **Speakers.** The Project Manager is the microphone ("Me"). The other three people share the call track ("Others"), with no voices told apart, as in the live preview.
- **Earlier meetings.** Each fixture gets the human decision and action sentences of the same team's earlier meetings as its earlier-meeting passages.

`run.sh` replays every fixture with one model, and `score.py` scores what was caught against AMI's human summaries.

```bash
export MUSE_RADAR_DATA=/private/tmp/lokalbot-muse-radar
python3 prepare.py
META_API_KEY=... ./run.sh "$APP" muse-spark-1.3
META_API_KEY=... ./run.sh "$APP" muse-wonder-1.0
python3 score.py --app "$APP" --save results/<date>
```

## Limits

- **Clean transcripts.** The AMI fixtures use manual transcripts. They show what the radar does with clean text, not with the live preview's recognition errors.
- **Annotation size.** AMI's annotators wrote 20 action sentences and 62 decision sentences for these 12 meetings. Several decisions often share one sentence, so coverage of decisions understates recall.
- **Stand-in history.** Earlier-meeting passages are human summary sentences, standing in for the outcomes LokalBot would have saved.
- **Model updates.** The Muse models are versionless from the client's side, so a later run may differ.
