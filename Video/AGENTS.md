# LokalBot video projects

Follow the [repository agreements](../AGENTS.md). Each project owns its brief, compositions, assets, and CLI pin; use the selected project's `package.json` scripts and local guide.

Finished projects that nothing builds or links anymore live in [`archive/`](archive/); they keep their sources and renders for reference. Move a project there when its film is published and superseded.

## Scope and completion

- Resume from the existing `BRIEF.md`, `STORYBOARD.md`, and requested edit. Preserve settled choices and requested review checkpoints. Ask only about missing information that materially changes the result.
- A request for a finished local video includes applicable checks, visual inspection, correction of defects, and rendering the MP4. Continue through those steps without another render-permission question unless the user requested that checkpoint. Publication and additional spending need authorization covering them.
- Keep existing CLI pins during ordinary edits and renders. Upgrade only for requested maintenance or a verified incompatibility that blocks the task, and verify any upgrade. Do not refresh global skills as a routine project step.
- Run the project's checks when compositions or render inputs change. For checks involving browser automation, use hosted CI or a remote runner under the repository's UI-test policy. Fix failures within scope and rerun affected checks. Instruction-only changes need document checks, not a render.

## Framework references

Use HyperFrames guidance for framework-specific work: core for timing and composition structure, animation for motion, audio for mixing, media-use for asset operations, and CLI for render or preview commands. Read only the relevant reference; an existing project's small edit does not need a fresh creation interview.

Keep compositions deterministic and seekable. Register the paused root timeline on `window.__timelines`; manually nested scene timelines must advance when that root is seeked. Preserve existing timing attributes, visibility classes, sub-composition wiring, and separate video/audio tracks. Verify version-specific behavior against the pinned CLI's documentation before changing those contracts.

Use the pinned CLI's managed background preview when it supports one, and verify it is listening. Otherwise keep preview in a persistent terminal through the requested review. A foreground command that times out is not a durable preview. Stop the preview when the review is finished.
