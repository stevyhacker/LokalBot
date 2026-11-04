# LokalBot 30-second promo

This is the 16:9 source for a standalone product film for listings and social posts; the website itself plays the clips from `Video/lokalbot-landing-demos/`. The preserved
`Video/hero-demo/` project remains the longer legacy showcase; derived square
and vertical experiments are local working material.

## Current cut

- 1920 × 1080 at 30 fps
- 29.973 seconds
- six scenes: quiz, cited recall, bot-free capture, Dictation + Autocomplete,
  scoped network verification, and CTA
- local Kokoro narration (`am_michael`) with burned-in captions
- HyperFrames 0.8.4

The privacy scene deliberately demonstrates only the documented built-in path:
models already downloaded, update checks off, and no approved remote backend in
use. It must not imply that model downloads, update checks, approved remote
inference, or network-capable Agent commands never connect.

## Source and generated media

The storyboard, script, frame HTML, caption source, and audio request are
tracked. Generated voice, music, effects, licensed SF font files, snapshots,
and renders remain ignored under `assets/`, `snapshots/`, and `renders/`.

Before review, ensure the generated assets referenced by `index.html` exist,
then run:

```sh
npm run check
npm run dev
```

Review the Studio preview and the contact sheet before rendering. After the cut
is approved, run from the repository root:

```sh
Scripts/render-hero-video-short.sh
```

That command validates the composition, renders the master, normalizes delivery
audio, creates the poster and manifest, and writes the MP4 aliases to
`.build/hero-demo/`.
