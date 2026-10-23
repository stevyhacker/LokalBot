# Agent proof — Three.js memory field

A 12-second code-rendered insert for the 60-second proof, built with Three.js,
GSAP and UnrealBloom. Eighteen translucent meeting cards sit on a curved field
around a teal wireframe core; packets run along a beam from the highlighted
Design review card into the core. The copy cuts between "Eighteen meetings.
One memory.", "Read-only. Cited." and "Your agent can read the meeting."

The 60-second cut uses 5.4–9.6 s of this piece at 46.5 s.

## Render

```sh
npm install
node render.mjs                 # 360 PNG frames at 1920×1080, 30 fps
ffmpeg -framerate 30 -i frames/%04d.png -c:v libx264 -pix_fmt yuv420p \
  -crf 18 -movflags +faststart motion.mp4
```

`render.mjs` serves the folder locally and drives `window.renderAt(t)` in
headless Chrome, so the animation is deterministic and needs no HyperFrames
render allowance. `frames/`, `node_modules/` and the encoded `motion.mp4` stay
out of git.
