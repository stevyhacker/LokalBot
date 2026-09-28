# LokalBot 30-second README demo

Follow the [video agreements](../AGENTS.md). This project renders the README hero video from recorded native-app takes.

- Start from `BRIEF.md`, `STORYBOARD.md`, and `SCRIPT.md`; `README.md` explains the footage, narration, and rebuild.
- Keep the HyperFrames CLI pinned at `hyperframes@0.8.82`. Timing lives on the root timeline in `index.html`; video clips carry their own `data-start` inside untimed window wrappers.
- Re-run `prepare_media.sh` after changing a clip range, then `lint`, `check`, a snapshot review, and the render.
- Keep the "Real app · fictional demo data" label and the privacy wording from `BRIEF.md`. The filming patch in `filming/` is never applied to the app source.
