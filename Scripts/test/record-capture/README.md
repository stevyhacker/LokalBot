# Scripted capture recordings

`run.sh` records what LokalBot's capture, tracking, and meeting-detection
services see while a browser shows a synthetic local page, then adds the
scrubbed trace to `LokalBotTests/Fixtures/capture-traces/`.

```bash
LOKALBOT_APP=/path/to/Debug/LokalBot.app Scripts/test/record-capture/run.sh chrome 60
LOKALBOT_APP=/path/to/Debug/LokalBot.app Scripts/test/record-capture/run.sh safari 60
```

What it does:

- Serves `page/index.html` (synthetic text, a password field, and a title
  change after 5 s) on a random `127.0.0.1` port and opens it in Chrome or
  Safari. **This launches GUI apps; ask before running it.**
- Runs a Debug LokalBot with `--record-capture <seconds>` against a throwaway
  library (`LOKALBOT_STORAGE_ROOT` in a temporary folder, deleted on exit). The
  script refuses a Release build, which does not have the flag.
- LokalBot needs Accessibility and Screen Recording access for the recording to
  contain real reads.

Every trace is scrubbed before it is written: letters become consonants,
digits stay digits, punctuation stays, and only the shared allowlist
(`scrub-allowlist.json`) survives. CI runs `Scripts/ci/check-capture-recordings.py`
on the fixtures folder and rejects any trace with a vowel or non-ASCII letter
outside the allowlist, or with an old scrubber version. Read every new trace
before committing it; the repository is public.

Rule: every escaped capture bug gets a trace (scripted when it can be
reproduced with the local page, otherwise reconstructed by hand in scrubbed
form) and a replay test in `LokalBotTests/Integration/CaptureReplayTests.swift`.
