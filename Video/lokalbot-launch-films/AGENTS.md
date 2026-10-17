# LokalBot launch films

Follow the [video agreements](../AGENTS.md), except where they assume HyperFrames. These films are onetake compositions: each `<film>/comp.html` is one canvas driven by `window.__seek(t)` on onetake's `lib/motion.js`.

- `README.md` explains the films, their data sources and the rebuild. `tools/voice.sh` regenerates narration and timelines, and `tools/build.sh` renders and runs onetake's verify.
- Never commit onetake's files (`motion.js`, `look.js`, its scripts or templates): they are PolyForm Noncommercial. Keep generated audio and renders out of git. Copy an accepted render into `drafts/`.
- Beats find their words by text (`wd(line, 'word')`) in `timeline.js`. After a voice change, rerun `voice.sh` and re-render; do not retype times.
- On-screen data comes only from the seed library and real app output. Model names and roles follow the README's model table.
