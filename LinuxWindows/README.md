# LokalBot for Linux and Windows

A native Rust port of LokalBot built with [GPUI](https://github.com/zed-industries/zed/tree/main/crates/gpui),
Zed's GPU-accelerated UI framework, and [GPUI Kit](https://github.com/longbridge/gpui-kit). It follows the
macOS app's experience (the same Today, Meetings, Timeline, People, Projects, Ask and Settings) and its
library format, so a library recorded on one platform opens on the other. Recording, transcription,
summaries, search and the read-only CLI/MCP server all run on your computer by default.

It is an **alpha**: the Windows build isn't code-signed yet, some features depend on your Linux desktop,
and a few macOS features haven't been ported (see below). Bug reports are welcome.

<p>
  <img src="docs/screenshots/linux-desktop-meetings.png" width="49%" alt="LokalBot on Linux">
  <img src="docs/screenshots/windows-desktop-today.png" width="49%" alt="LokalBot on Windows">
</p>

More screenshots of both apps are in [docs/screenshots](docs/screenshots).

## What works where

| Feature | Linux | Windows | Notes |
| --- | --- | --- | --- |
| Meetings: record mic + system audio | ✓ (PulseAudio/PipeWire monitor) | ✓ (WASAPI loopback) | No bot joins the call. Tracks are 16 kHz WAV files; meetings recorded on macOS (AAC `.m4a`) play and transcribe too. A recording cut short by a crash or power loss is closed at its last audio when LokalBot starts again, then processed as usual. |
| On-device transcription | ✓ | ✓ | sherpa-onnx: Qwen3-ASR 0.6B by default; Parakeet v3, SenseVoice and Whisper turbo optional. Speakers are separated with pyannote segmentation and TitaNet embeddings. |
| Notes, actions, decisions, day digest, project notes, follow-up drafts | ✓ | ✓ | The macOS prompts, run by the built-in llama.cpp server (Vulkan, experimental CUDA or CPU), Ollama, an OpenAI-compatible server you approve, or your own ChatGPT or Claude plan (see [Think providers](#think-providers)). Follow-ups are written only by a model on your computer, and LokalBot never sends them. |
| Ask with citations | ✓ | ✓ | As on macOS, the model looks things up with tools (search, list and read meetings, action items, screen text, app activity) and answers once it has enough; each citation must match a source a tool returned. A Think model running on the CPU, or one with a context window under 16K tokens, instead gets the relevant meetings found first (keyword and meaning search) and answers in one turn. |
| Keyword and meaning search, Quick Recall | ✓ | ✓ | SQLite FTS5 plus EmbeddingGemma vectors, kept up to date in the background. |
| Day memory (app and window activity) | X11, Hyprland, Sway, KDE; GNOME with the Window Calls extension | ✓ | Window titles are cleared after the retention window in Privacy settings. |
| Screen context (visible text, optional encrypted screenshots) | X11; Sway and Hyprland with `grim`; other Wayland desktops through the screenshot portal when it can capture just the active window | ✓ | Off until you choose it in Settings → Day Memory. Text comes from accessibility (AT-SPI, UI Automation) and on-device OCR (ocrs, downloaded on request); screenshots are AES-GCM encrypted with a key in the system credential store. |
| Dictation (hold a shortcut, speak, release) | X11; Wayland through your compositor's shortcut + `lokalbot dictate` | ✓ | Transcribe inserts what you said; Compose rewrites it with the Think model. Pastes at the cursor, or copies to the clipboard when it cannot. |
| Meeting detection | ✓ (PulseAudio source outputs) | ✓ (WASAPI capture sessions) | Asks with a notification by default. |
| System tray, launch at login | ✓ (StatusNotifierItem; GNOME needs the AppIndicator extension) | ✓ | |
| `lokalbot-cli` + MCP for coding agents | ✓ | ✓ | Read-only, off until you allow it in Settings → Privacy & Data. |
| Signed automatic updates | ✓ (installed with `install.sh`, or run from the extracted folder) | ✓ (installed with the installer, or run from the extracted folder) | Checks GitHub daily; installs only when you choose Install and Relaunch. Package installs are told how to update with the package manager; other copies under `/usr`, `/opt` or Program Files are pointed at the download. On Windows, Installed apps (and winget) then shows the new version. |
| Live transcript preview while recording | ✓ | ✓ | Opt-in from the live meeting view. Each track is transcribed in 4–12 s chunks cut at a pause, as Me and Remote speaker; the full transcript replaces it after the meeting. |
| Autocomplete in other apps | X11 (GTK; Qt, Chromium/Electron and Firefox once system accessibility is on); Wayland: the practice editor in Settings only | ✓ (apps whose fields support UI Automation) | Off until you turn it on in Settings → Writing. LFM2.5 1.2B on this computer by default, about 250 ms to a suggestion on CPU. Tab accepts a word, Esc dismisses. Password fields, terminals and excluded apps are never read, and nothing is stored. |
| Agent Mode | ✓ | ✓ (Git Bash, or PowerShell without it) | Runs the pi coding agent with your Think model. Setup downloads Bun and pi (pinned and checksum-verified, about 65 MB on Linux and 70 MB on Windows). File changes and commands need your approval. |
| Import recordings, merge meetings, meeting boundaries | ✓ | ✓ | Import an audio or video file from the Meetings header or by dropping it on the list: MP3, M4A/AAC, MP4/MOV, WAV, AIFF, CAF, FLAC, Ogg Vorbis and MKV (not Opus). Every audio track is mixed into the meeting's `system.wav`. Ctrl-click or Shift-click meetings to merge them into one timeline, with Undo; **Meeting boundaries…** keeps part of a recording and rebuilds its notes. A Mac reads the WAV tracks these write. |
| Calendar | ✓ (private iCal/CalDAV links; Evolution Data Server, including GNOME Online Accounts) | ✓ (private iCal/CalDAV links) | Off until you turn it on in Settings → Meetings. Titles and stamps recordings like macOS, backs browser calls with the event's meeting link, splits back-to-back meetings, suggests attendee names for speakers, and lists today's meetings on Today with Join, Record and a pre-meeting brief from the local Think model. Links are kept in the system credential store. |
| Spoken summaries, coding-agent sessions in day memory, selection actions, meeting note export and daily memory notes, Personal Context | — | — | macOS only for now. |

## Think providers

### NVIDIA CUDA (experimental)

Settings → Models → llama.cpp offers **CUDA (experimental)** on Linux x86_64 and
Windows x64. It accelerates the built-in Think, search and autocomplete models;
transcription and speaker separation still use their separate CPU engines.

Setup picks one of two pinned llama.cpp CUDA builds from the driver's CUDA
version and each GPU's compute capability (read with `nvidia-smi`):

| Build | Prebuilt kernels | Other GPUs (compiled from PTX) |
| --- | --- | --- |
| CUDA 13.4 | RTX 30, 40 and 50 (compute capability 8.6, 8.9, 12.x) on a CUDA 13.0+ driver (R580+) | Turing, A100, H100 and newer with a CUDA 13.4+ driver |
| CUDA 12.8 (Linux) / 12.4 (Windows) | RTX 30 and 40 on a CUDA 12.0+ driver (R525+) | Maxwell, Pascal, Volta, Turing and newer with a CUDA 12.8 / 12.4+ driver |

[NVIDIA's minor-version compatibility](https://docs.nvidia.com/deploy/cuda-compatibility/minor-version-compatibility.html)
lets a driver run prebuilt kernels from any toolkit of its CUDA major version,
but it compiles PTX only from a toolkit no newer than itself. So a Turing GPU
on an R580 driver gets the CUDA 12 build, and a GTX 10-series GPU works with a
CUDA 12.8 (Linux) or 12.4 (Windows) driver. LokalBot takes the newest build
that every NVIDIA GPU in the PC can run; without `nvidia-smi` it takes one whose
PTX the driver can compile. `LOKALBOT_CUDA_RUNTIME=13.4`, `12.8` or `12.4` forces
a build for troubleshooting. Actual device detection and model offload must
still succeed. Kepler and older GPUs, and drivers older than CUDA 12.0, can keep
using Vulkan or CPU. **Automatic** continues to select Vulkan or CPU; CUDA
remains opt-in pending broader hardware validation and performance comparisons.

LokalBot first tries compatible system CUDA libraries. If the CUDA backend cannot
use them, it downloads the pinned CUDA runtime, cuBLAS and cuBLASLt libraries into
its own runtime folder. You do not need the CUDA compiler or full toolkit. A fresh
download is at most about 594 MB (CUDA 13.4) or 767 MB (CUDA 12.8) on Linux, and
578 MB (CUDA 13.4) or 658 MB (CUDA 12.4) on Windows. Reusing system libraries
reduces that to the server archive: about 154 MB for CUDA 13.4, 173 MB for
CUDA 12.8 and 267 MB for CUDA 12.4, excluding models. Settings estimates the CUDA
13.4 size until setup has picked a build. Downloads are verified and an
incomplete setup does not count as installed.

Changing the backend lets in-flight requests finish; models switch when next
loaded. Selecting CUDA does not stop the built-in models: they keep using the
Vulkan or CPU runtime Automatic would choose until CUDA setup succeeds, and no
background role starts a CUDA download. Download under Settings → Models →
llama.cpp prepares CUDA. If setup downloads everything but the final GPU check
fails, for example because another app has filled GPU memory, the verified files
are kept, Settings shows "Not ready · CUDA", and **Check again** repeats only the
check. Once CUDA is set up, explicit CUDA reports a startup error if it cannot
accelerate the model, rather than silently labeling a CPU run as CUDA. Choose
Automatic, Vulkan or CPU to recover. **Check again** stays available for CUDA so
it can retry detection and repair missing system libraries without reinstalling
the server. Transient GPU failures
preserve installed files. Device probes are cached for the session, and healthy
helpers are reused before probing. Model Storage lists runtime folders even
after switching backends.

For native NVIDIA validation, run the ignored runtime test with
`LOKALBOT_E2E_BACKEND=cuda` and a separate `LOKALBOT_E2E_ROOT`, and run the
`lokalbot-engine` `autocomplete_eval` example with `--backend cuda`. The runtime
test checks actual model offload as well as text generation and embeddings.
The runtime and autocomplete path have been exercised on NVIDIA L4, RTX 3080,
RTX 5060 Ti and RTX 5090 GPUs under Ubuntu 24.04. The RTX 5090 additionally passed
bundled libraries, system-library reuse and in-place repair on a CUDA 13.2 driver.
On that card, three release-mode autocomplete runs per backend measured pooled
p50/p95 of 180/210 ms for CUDA versus 218/346 ms for Vulkan, including the
160 ms debounce. Both produced 57/60 suggestions; this is one synthetic model
workload, not a general performance guarantee. Native Windows CUDA passed the
runtime test on an NVIDIA L4 under Windows Server 2022 with both the CUDA 13.4
and 12.4 builds, and the CUDA 12.8 build passed on a Pascal Titan Xp with a CUDA
12.8 driver. With `llama-bench`, CUDA read a 4,096-token prompt into the default
Qwen3.5 4B model 44% faster than Vulkan on an RTX 3060 (Linux) and 32% faster on
the L4 (Windows); generation speed was within 9%. On GPUs without prebuilt CUDA
kernels (Maxwell to Turing, A100, H100), the first CUDA reply after setup took
1–3 minutes in testing while the driver compiled them; later starts reuse its
cache. See the
[hardware validation report](docs/cuda-validation.md).

### Other Think providers

Think (notes, digests, Ask, Compose) runs on the built-in model by default. On a PC without a
supported GPU, local models are slow, so Settings → Models → Connections also offers:

- **OpenAI-compatible server**: any `/v1` URL, such as OpenRouter, OpenAI, Cerebras, LM Studio or
  llama-server. With OpenRouter, **Provider data use** keeps every request on private endpoints
  (providers that do not collect inference data) unless you choose to follow your OpenRouter
  privacy settings. A URL on `api.anthropic.com` uses Anthropic's Messages API, with structured
  output, effort control and prompt caching for the system prompt and transcript.
- **Ollama**, on this PC or another one.
- **ChatGPT plan**: **Continue with ChatGPT** signs in through your browser (OpenAI's Sign in with
  ChatGPT) and returns to LokalBot on `127.0.0.1`. Requests go to OpenAI's Responses API and count
  toward your plan. The sign-in is kept only in the system credential store; on a Linux desktop
  without a Secret Service (GNOME Keyring, KWallet) it cannot be used.
- **Claude plan**: runs the Claude Code you installed and signed in to yourself (`claude` on PATH,
  in `~/.local/bin`, or npm's `claude.cmd` on Windows), with its tools, MCP servers, settings and
  session history turned off. LokalBot never sees your Claude credentials.

Every remote server and each plan needs its own approval before any context leaves your computer.
Agent Mode runs on the built-in model, Ollama or an OpenAI-compatible server, not on a plan.

## Install

Download the archive for your platform from [GitHub Releases](https://github.com/stevyhacker/lokalbot/releases).
Releases attach the Linux and Windows archives next to the macOS DMG, under the same version. If the latest
release has none yet, use a CI run's artifacts (`lokalbot-linux-x86_64`, `lokalbot-windows-x86_64`) or
[build from source](#build-from-source):

- **Linux** (x86_64): extract `LokalBot-<version>-linux-x86_64.tar.gz` and run `./install.sh`. It installs
  `lokalbot` and `lokalbot-cli` into `~/.local/bin` and adds LokalBot to your applications menu.
  Runtime needs: a Vulkan or OpenGL driver (Mesa is fine), PulseAudio or PipeWire for system audio, and
  for the built-in models the GCC OpenMP runtime (`libgomp1` on Debian and Ubuntu, `libgomp` on Fedora and Arch).
  The same release has packages that install into `/usr/bin` with their dependencies:
  `LokalBot-<version>-linux-amd64.deb` (Debian, Ubuntu: `sudo apt install ./LokalBot-…deb`),
  `LokalBot-<version>-linux-x86_64.rpm` (Fedora, openSUSE: `sudo dnf install ./LokalBot-…rpm`) and
  `LokalBot-<version>-linux-x86_64.pkg.tar.zst` (Arch: `sudo pacman -U ./LokalBot-…zst`). Installing the
  `.deb`, or the `.rpm` on Fedora, also adds the LokalBot repository at `pkg.lokalbot.com`, so
  `sudo apt upgrade` or `sudo dnf upgrade` brings later versions. The Arch package comes from no repository,
  so when a newer version is out LokalBot asks you to download the new package and install it the same way.
- **Windows** 10/11 (x64): run `LokalBot-<version>-windows-x86_64-setup.exe`. It installs for your user into
  `%LOCALAPPDATA%\Programs\LokalBot` without administrator rights, adds a Start menu shortcut (which also
  lets notifications show LokalBot's name) and an Installed apps entry; uninstalling keeps your library. Or
  extract the portable `LokalBot-<version>-windows-x86_64.zip` anywhere and run `lokalbot.exe`. Neither is
  code-signed yet, so SmartScreen may ask you to confirm.

### Omarchy and other Hyprland desktops

[Omarchy](https://omarchy.org) already has everything LokalBot uses on Wayland: `grim` for screen context,
`wtype` and `wl-clipboard` for dictation, PipeWire for meeting audio and the Hyprland desktop portal.

On Omarchy and other Arch-based systems, install the release's Arch package. pacman manages it and installs
its dependencies:

```bash
v=$(curl -fsSLI -o /dev/null -w '%{url_effective}' https://github.com/stevyhacker/LokalBot/releases/latest); v=${v##*/v}
curl -fLO "https://github.com/stevyhacker/LokalBot/releases/download/v$v/LokalBot-$v-linux-x86_64.pkg.tar.zst"
sudo pacman -U "./LokalBot-$v-linux-x86_64.pkg.tar.zst"
```

The first line looks up the latest version. Download the file before `pacman -U`: given a URL, pacman also
asks for a signature file, which releases don't have. When a newer version is out, LokalBot tells you; run the
same commands again. An AUR package, `lokalbot-bin`, is on its way. Once it is published,
`yay -S lokalbot-bin` replaces this package and `yay -Syu` keeps it up to date. You can also use `./install.sh`
from the `.tar.gz` (see above), which installs into `~/.local/bin` and lets LokalBot update itself.

Either way, LokalBot is in the app launcher and its tray icon appears in Omarchy's bar. The welcome window, the
dictation pill and Quick Recall float above your windows instead of being tiled.

Hyprland has no settings screen for other apps' shortcuts, so bind LokalBot's commands in
`~/.config/hypr/bindings.lua` (these keys are free in Omarchy's defaults):

```lua
-- Press to start dictating, press again to insert the text where you are typing.
o.bind("SUPER + ALT + D", "LokalBot dictation", "lokalbot dictate")
-- Search your memory and ask about it (Quick Recall).
o.bind("SUPER + ALT + A", "Ask LokalBot", "lokalbot quick-recall")
```

After `./install.sh`, write `~/.local/bin/lokalbot` instead of `lokalbot`, because Hyprland may not have
`~/.local/bin` on its PATH. On Hyprland without Omarchy, the same commands go in `hyprland.conf`, for example
`bind = SUPER ALT, A, exec, lokalbot quick-recall`. Autocomplete in other apps needs X11, so on Hyprland it
works in the practice editor in Settings only.

### Updates

With **Check for updates automatically** on (Settings → General → Updates; on for new installs), LokalBot
reads the latest release's update feed from GitHub when it starts and once a day. **Check for Updates…**
checks at any time. Like the macOS app, it never installs on its own: when a newer version is out, Settings
and the tray menu offer **Install and Relaunch**, and a notification says so once. `lokalbot install-update`
does the same from a terminal.

`lokalbot --version` and `lokalbot-cli --version` print the installed version. On Windows the app has no
console window, so use `lokalbot-cli --version` or pipe the app's output: `lokalbot.exe --version | Write-Output`.

Installing downloads the archive and checks its size, SHA-256 and Ed25519 signature (the macOS app's
Sparkle key) before unpacking anything. It then replaces `lokalbot` and `lokalbot-cli` where they are
(Linux: `~/.local/bin`, refreshing the applications-menu entry and icons that `install.sh` added; Windows:
the extracted folder, and the copy `lokalbot-cli install-skill` made), stops the local model servers and Agent
Mode, and starts the new version. On Windows a running `lokalbot-cli` (an agent's MCP server) keeps working;
its old file is removed on a later start. Your library is never touched.

When LokalBot cannot replace its own files, it says how to update instead. It asks the package database
which package installed it (`pacman -Qo`, `dpkg-query -S`, `rpm -qf`). A package from a repository, such as
an AUR package, or a `.deb` or `.rpm` that added the LokalBot repository (below), updates with your package
manager (for example `yay -Syu` or `sudo apt upgrade`). The release's Arch package, and a `.deb` or `.rpm`
installed before the repository existed, have no repository, so Settings shows the command that installs the
downloaded package (for example `sudo pacman -U ./LokalBot-<version>-linux-x86_64.pkg.tar.zst`) next to
**Download**. Other copies
(`/usr`, `/opt`, Program Files, a folder you cannot write) get the download from GitHub. Debug builds never
update.

The `.deb` and `.rpm` update with your package manager, from the LokalBot repository they add:
`/etc/apt/sources.list.d/lokalbot.sources` with its key in `/usr/share/keyrings`, or
`/etc/yum.repos.d/lokalbot.repo` with its key in `/etc/pki/rpm-gpg`. apt and dnf check the repository's
signature and each package's. Your edits to those files survive upgrades; add `Enabled: no` or set
`enabled=0` to stop updates from it. The repository has the newest three stable versions, never pre-releases.
openSUSE's zypper doesn't read `/etc/yum.repos.d`, so there the `.rpm` is told about updates like the Arch
package.

On first launch LokalBot asks what to remember and downloads the models you choose: about 4 GB for the
default transcription, Think and search models.

Your library lives in `~/.local/share/LokalBot` on Linux and `%LOCALAPPDATA%\LokalBot` on Windows.
Set `LOKALBOT_STORAGE_ROOT` or pass `--lokalbot-storage-root <dir>` to use another folder. Logs are in
the library's `logs` folder (Settings → Advanced → Logs).

### Coding agents

To let Claude Code, Codex and other coding agents read your library, turn on "Allow external agents to read
your meeting library" in Settings → Privacy & Data, then click **Install for your coding agent…** in
Settings → Advanced → Agent CLI. It installs the LokalBot skill into `~/.agents/skills` and `~/.claude/skills`
(under your user folder on Windows) and puts `lokalbot-cli` here:

- **Linux**: `~/.local/bin/lokalbot-cli`. If you used `install.sh`, the CLI is already there and is left as
  it is. If `~/.local/bin` isn't on your PATH, add it to `~/.bashrc` (or `~/.zshrc`):

  ```bash
  echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
  ```

- **Windows**: `%LOCALAPPDATA%\Programs\LokalBot\bin\lokalbot-cli.exe`. Add that folder to your PATH from
  PowerShell, then open a new terminal:

  ```powershell
  [Environment]::SetEnvironmentVariable('Path', [Environment]::GetEnvironmentVariable('Path', 'User') + ";$env:LOCALAPPDATA\Programs\LokalBot\bin", 'User')
  ```

The same section has Copy buttons for the MCP setup commands (Claude Code, Codex and other MCP clients), which
use the full path above. Try it in a terminal with `lokalbot-cli brief`. Without the app,
`lokalbot-cli install-skill` does the same, and `lokalbot-cli install-skill --uninstall` removes what it installed.

## Build from source

Requires Rust 1.99.1 (pinned in `rust-toolchain.toml`).

```bash
# Ubuntu/Debian build dependencies
sudo apt-get install -y libxkbcommon-x11-dev libwayland-dev libvulkan1 libfontconfig-dev \
  libasound2-dev libxcb1-dev libx11-xcb-dev libssl-dev pkg-config clang

cargo run -p lokalbot-app            # the app (binary: lokalbot)
cargo run -p lokalbot-cli -- list    # the CLI
cargo test --workspace
scripts/package.sh                   # release archive in dist/
```

On Windows, install Visual Studio 2022 Build Tools (C++ workload, Windows 11 SDK) and CMake, then run
the same `cargo` commands. Note that the repository's macOS test fixtures contain file names Windows
cannot create; check out only `LinuxWindows/` there (see `.github/workflows/linux-windows.yml`).

To check the whole pipeline without the UI (downloads the default models, transcribes, writes notes,
then answers a question with citations):

```bash
cargo run -p lokalbot-engine --example process_meeting -- <library> mic.wav system.wav \
  --prepare --ask "What did we decide?"
```

`cargo run -p lokalbot-app -- --seed-demo --lokalbot-storage-root <empty dir>` writes the fictional demo
library used for the screenshots.

## Interface languages

Choose **App language** in Settings → General → Appearance, or during setup.
Windows and Linux offer the same 24 interface languages as macOS, including
Serbian Latin, both Chinese scripts, Arabic, Egyptian Arabic and Urdu. The default
is **Follow System**. Linux honors `LC_ALL`, `LC_MESSAGES`, `LANG` and the GNU
`LANGUAGE` preference list; Windows uses its OS language preferences. An explicit
choice is saved as `appLanguage` in the shared settings format. The notes language,
transcription, user content, shortcuts and agent commands stay independent.

Shared copy comes from `../LokalBot/Resources/*.lproj/Localizable.strings` and the
language names/matching rules follow `AppLanguage.swift`. Desktop-specific copy is
in `localizations/<locale>.json`; it must not override a shared key. Translations
are embedded at build time. There is no translation service at runtime. The new
desktop-only translations are machine-assisted and need native-speaker review,
particularly longer help text and regional wording.

After changing either catalog, run these from `LinuxWindows/`:

```bash
python3 scripts/sync-localizations.py
python3 -m unittest discover -s scripts/tests
cargo test -p lokalbot-i18n -p lokalbot-core
```

CI checks every locale's keys, placeholders and line breaks, keyboard names,
embedded direction controls, source-key coverage and generated-file freshness. Commit the generated
Rust catalog too: Windows builds use an archive without the macOS source tree.
Language changes redraw open windows and update input hints without replacing
the input entities. Interface rows mirror for right-to-left languages; text
answers choose alignment from their content and code stays left-to-right.
Plain interface paragraphs use Unicode line breaks before shaping each display
line. This avoids the pinned GPUI renderer's glyph-order wrapping problem with
Arabic and Urdu and keeps Indic graphemes intact. Inputs and rich-text editors
continue to use the framework's native renderer.

## Crates

```text
crates/
├── lokalbot-i18n      Embedded shared interface catalogs, language matching and formatting
├── lokalbot-core      Library format (macOS-compatible), SQLite search, actions, timeline, settings, screen moments
├── lokalbot-ai        Model catalog, downloads, llama.cpp runtime, Think/embedding clients, prompts, autocomplete, OCR
├── lokalbot-audio     Microphone + system audio capture, playback, waveforms
├── lokalbot-speech    sherpa-onnx transcription, voice activity detection, speaker separation
├── lokalbot-platform  Activity, screen capture, text fields and keys for autocomplete, shortcuts, tray, notifications
├── lokalbot-engine    Background work: recording, live transcript, processing queue, Ask, digests, day memory,
│                      screen context, dictation, autocomplete
├── lokalbot-agent     Agent Mode: the pinned Bun + pi runtime, sessions, approvals
├── lokalbot-cli       Read-only CLI and stdio MCP server
└── lokalbot-app       The GPUI app
```

See [docs/dependency-provenance.md](docs/dependency-provenance.md) for how the GPUI crates were checked
against Zed's source, and [../PRIVACY.md](../PRIVACY.md) for the data and network contract, which this
port follows.
