# Contributing to LokalBot

Thank you for helping improve LokalBot. Bug reports, hardware benchmarks, documentation fixes, translations, and focused code pull requests are all welcome.

Please read our [Code of Conduct](CODE_OF_CONDUCT.md) and review [PRIVACY.md](PRIVACY.md) before changing anything that touches recording, screen capture, retention, external agents, mobile sync, or network requests. LokalBot is local-first with zero accounts and zero telemetry; every contribution must preserve those boundaries.

## Ways to contribute

- **Report bugs with clear repro steps:** Open an issue using the [bug report form](.github/ISSUE_TEMPLATE/bug_report.md) or [issue chooser](https://github.com/stevyhacker/LokalBot/issues/new/choose).
- **Submit hardware benchmarks:** Help fill in M1, M2, M3, Windows, and Linux measurements in [Benchmarks/README.md](Benchmarks/README.md#contribute-hardware-benchmarks).
- **Improve docs or translations:** Fix setup friction, clarify platform quirks, or improve localized strings.
- **Submit focused code fixes:** Look for open issues labeled `good first issue` or `help wanted`, or open an issue first to agree on scope for larger features.

## Bug report expectations

Include these details so we can reproduce the issue quickly:

- LokalBot version and install method (DMG, Homebrew, Scoop, Windows installer, `.deb`/`.rpm`/Arch, or source build)
- Operating system and version (on Linux, include distro, desktop environment, and X11 vs Wayland)
- Hardware: Apple Silicon chip or CPU, GPU, and RAM
- Selected models (Transcribe, Think, Autocomplete, Search) and whether you use built-in `llama.cpp`, Ollama, or another provider
- Exact steps to reproduce, expected behavior, and actual behavior
- Optional redacted excerpt from `debug.log` (see [SUPPORT.md](SUPPORT.md) for log paths)

**Never attach private recordings, meeting transcripts, screenshots of private data, API keys, or credentials to public issues.**

## Development setup and repository rules

Read [DEVELOPMENT.md](DEVELOPMENT.md) (macOS app), [LinuxWindows/README.md](LinuxWindows/README.md) (Windows and Linux Rust + GPUI app), and [AGENTS.md](AGENTS.md) (shared working agreements) before writing code.

Key repository rules:

1. **No code comments:** This repository enforces a strict zero-new-comments policy. Record non-obvious architectural decisions in an ADR under `Docs/decisions/`, file known shortcuts as issues, and keep code self-explanatory. Verify locally before pushing:

   ```sh
   python3 Scripts/ci/comment-ratchet.py --check
   ```

2. **XcodeGen owns the Mac project:** Edit `project.yml` rather than hand-editing `LokalBot.xcodeproj`, then run `xcodegen generate`.
3. **Keep UI tests off local developer Macs when running automated harnesses:** Run headless unit tests locally and let hosted CI (or `Scripts/test/ui-tests.sh --remote`) run the full macOS UI suite.
4. **Rust workspace checks (Windows and Linux):** From `LinuxWindows/`, run:

   ```sh
   cargo fmt --all -- --check
   cargo clippy --workspace --all-targets --locked -- -D warnings
   cargo test --workspace --locked
   ```

5. **Regression tests for user-facing bugs:** When fixing a bug that affected users, add a unit test, capture replay trace, or model scenario that fails with the fix reverted. See [Docs/development/testing.md](Docs/development/testing.md).

## Pull requests

1. For larger features or architectural changes, open an issue first to discuss the approach before investing time in an implementation.
2. Keep pull requests small and focused on one task. Do not bundle unrelated refactors or formatting churn.
3. Open your pull request as a draft while iterating, then mark it ready for review once checks are green (the full macOS UI test suite runs on ready PRs).
4. Complete every section of [`.github/PULL_REQUEST_TEMPLATE.md`](.github/PULL_REQUEST_TEMPLATE.md), including exact commands you ran and their observed results.
5. If a change alters what an existing test expects, list it under **Changed test expectations** with the reason.
6. For visible UI changes, attach before-and-after screenshots or short clips captured on fictional sample data (never personal meetings or messages).

## Security disclosures

Do not open a public issue for a suspected security vulnerability. Follow [SECURITY.md](SECURITY.md) to report it privately.

## Licensing

LokalBot is licensed under [GPLv3](LICENSE), except code in the Autocomplete engine ported from Cotabby, which remains under [AGPLv3](LICENSES/AGPL-3.0.txt). By submitting a contribution, you agree to license your changes under the applicable license for the files you modify.
