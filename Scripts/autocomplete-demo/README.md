# Autocomplete demo footage

Films LokalBot's autocomplete on a hosted Mac in CI for the autocomplete
launch video: real key events type into TextEdit, the default on-device
model (Gemma 4 E2B Base, in-process llama.cpp) suggests, and each suggestion
is accepted word by word with Tab. Nothing in the product UI is redrawn; the
suggestions are whatever the model wrote in that take.

| File | Role |
| --- | --- |
| `shots/*.json` | One take each, in `Scripts/readme-gif/rig.swift`'s shot format plus the document's `file` name and `opening` text. `warmup` loads the model and is not kept. |
| `stage.py` | Downloads the catalog's default autocomplete model and checks its pinned SHA-256, seeds the README GIF's fictional launch-pricing library (so "the Team plan will be $15" can be finished from that meeting), and writes a throwaway settings suite with everything that could capture or learn off. |
| `film.sh` | CI only. Grants the runner's TCC permissions to LokalBot and the rig, sets TextEdit to plain text in a large font with spelling marks and macOS inline predictions off, then films every take in each appearance and encodes it with `encode.py`. A take whose suggestion never shows is filmed again. |
| `encode.py` | Turns a take's frames into a constant 30 fps MP4 that keeps the take's timing, with its events (keystrokes, the moment the suggestion appeared, each accept) beside it. |
| `display.swift` | Gives the hosted desktop a Retina mode when the runner offers one. |

The rig's `ghost` action waits for LokalBot's suggestion panel to appear and
logs when it did; `accept` presses Tab while it is still showing. The Debug
build shows the panel to screen capture only with `--lokalbot-film-ghost`
(`TestHooks.filmsAutocomplete`); release builds keep it hidden from capture.

`.github/workflows/autocomplete-demo.yml` runs it on pull requests that change
these files and on dispatch (inputs: takes, appearances). Results are the
`autocomplete-demo` artifact and the orphan branch
`pr-assets/<pr>-autocomplete-demo`. A hosted runner is a small virtual Mac, so
a suggestion can take longer to appear than on an Apple silicon Mac; each
take's `ghost` event records how long it waited.
