# Agent handoff demo

Films the after-meeting agent handoff on a hosted Mac in CI: a call ends,
LokalBot transcribes it, writes the notes, and each action the person took
on starts as its own Agent Mode task with no one touching the app.

| File | Role |
| --- | --- |
| `stage.py` | Seeds the fictional launch-pricing library from `Scripts/readme-gif/seed_library.py`, adds "Launch follow-up" (a two-track call in macOS speech: the person on the microphone, Priya on the system track), and writes the settings. Only microphone speech is the person's, so only their four actions are handed off; Priya's stays in the notes. |
| `film.sh` | Picks the first OpenRouter model in `DEMO_MODELS` that answers with private routing, puts the key in a throwaway keychain, warms up Parakeet with a user-initiated `--process`, installs Agent Mode, then launches the app on the call and records it until the director is done. Copies the logs, the meeting's notes and what the agents wrote. |
| `record.py` | Captures the main window with `screencapture` twice a second, so the shell running it needs Screen Recording (hosted runners have it). |
| `edit.py` | Cuts the frames into `agent-handoff.mp4` and `agent-handoff.gif` with a caption per scene, speeding up the agents' work. Uses Pillow, which `film.sh` installs in a throwaway virtualenv. |
| `LokalBot/Support/FilmDirector.swift` | Debug-only (`LOKALBOT_TEST_HOOKS`). Opens the meeting, then Agent Mode once the tasks exist, moves between them while they work, and ends on each task's report and the last one's results. Logs the scenes and the window's frame for the recorder. |

The film runs Agent Mode on Full access, so no tool asks first and the agents
work unattended; in the narrower modes each `lokalbot-cli` lookup asks.

`.github/workflows/agent-handoff-demo.yml` runs it on pull requests that
change these files and on dispatch. The transcription runs on the runner;
the notes and the agents use OpenRouter through the `OPENROUTER_API_KEY`
secret. Results are the `agent-handoff-demo` artifact and the orphan branch
`pr-assets/<pr>-agent-handoff-demo`.

On a Mac with a Debug build:

```sh
LOKALBOT_APP=.build/dd/Build/Products/Debug/LokalBot.app OPENROUTER_API_KEY=... \
  Scripts/agent-handoff-demo/film.sh /tmp/agent-handoff-demo
```

It changes the user keychain search list while it runs and restores it at
exit, so prefer CI or a throwaway account.
