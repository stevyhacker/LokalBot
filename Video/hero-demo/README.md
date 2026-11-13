# LokalBot hero demo production

This HyperFrames project renders narrated product films. The website no longer
plays them: its home page uses the short clips from
`Video/lokalbot-landing-demos/`. It deliberately keeps generated screenshot copies,
audio stems, review renders, and local tool environments out of Git: the source
captures remain canonical under `Assets/screenshots/`, while the short film's
high-density sources live under `Assets/video-screenshots/`.

Both productions are 1872×1276 at 30 fps:

- The 30-second production renders to `.build/hero-demo/hero-demo.mp4` and is also
  preserved as `hero-demo-short.mp4`. It focuses on Quick Recall, Context Rewind,
  Dictation, Cotyping, and the local-first privacy payoff.
- The 56-second production renders to `.build/hero-demo/hero-demo-long.mp4`. It adds
  the meeting recap, transcript evidence, and cited answers.

`DESIGN.md` defines the visual and motion language; `storyboard.md` locks the
long-form narrative and claim boundaries.

Run the repository-level pipeline:

```sh
Scripts/media/render-hero-video-short.sh
```

The short render refreshes both the named short file and the canonical default.
Render the extended cut separately with `Scripts/media/render-hero-video.sh`.

If the script or narration is stale, provide an ElevenLabs key in the process
environment. The key is used in memory and is never written to the project:

```sh
ELEVENLABS_API_KEY=... Scripts/media/render-hero-video-short.sh
```

For iteration inside this folder:

```sh
./prepare_assets.sh
npm run check
npm run render -- --output renders/lokalbot-hero-demo.mp4 --fps 30 --quality high
```

The short/default production uses Eleven v3 with the young male Will narration
voice in Natural mode at its native 1.0× speed. The preserved long cut uses the
original ElevenLabs Multilingual v2/Bella performance. Neither production uses
time stretching or an editorial speed-up. The original score and UI effects are
synthesized by `generate_audio.py`. The final video contains narration, an
ambient music bed, UI sound design, and burned-in captions aligned to
ElevenLabs character timings. The short delivery remuxes the HyperFrames master
video stream directly, avoiding a second lossy pass over small interface text.
Screenshot sharpness comes from those denser source PNGs; the composition keeps
its native 1872×1276 coordinate system and original window geometry so labels,
focus rings, cursor targets, and story panels stay aligned.
