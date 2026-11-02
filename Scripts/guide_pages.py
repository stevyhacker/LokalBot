"""Source-backed guide content for LokalBot's search-intent pages.

Rendered by Scripts/render_web.py. Keep claims aligned with the checked-in
README and implementation; these pages intentionally avoid competitor claims.
A guide with "kind": "question" is listed under Questions on /guides.
"""

# Head and structured-data copy for web/guides.html.
GUIDES_INDEX = {
    "title": "LokalBot Guides — Private AI Meeting Notes on Your Computer",
    "description": "Practical guides to local AI meeting notes, offline transcription, bot-free recording, open-source privacy, model choice, system requirements, and comparisons.",
}

GUIDES = [
    {
        "slug": "local-ai-meeting-notes-mac",
        "updated": "2026-10-20",
        "updated_label": "October 20, 2026",
        "title": "Local AI Meeting Notes for Mac — A Practical Guide",
        "description": "How local AI meeting notes work on a Mac: bot-free capture, on-device transcription, private summaries, trade-offs, and setup.",
        "eyebrow": "Local meeting notes",
        "h1": "Local AI meeting notes on your Mac",
        "lead": "A practical guide to recording, transcribing, and summarizing meetings with models that run on your Mac by default — without sending a bot into the call.",
        "read_time": "6 min read",
        "body": """
        <h2>What “local” should mean</h2>
        <p>A meeting-notes app can store a copy on your laptop and still upload the audio for transcription. A genuinely local-first workflow keeps the recording, speech recognition, recap generation, and searchable library on the computer by default. Network access may still be needed to download the app, fetch a model, and check for updates. If you deliberately configure a remote inference server, that server receives the context needed for the request.</p>
        <p>LokalBot follows that narrower, testable definition. It has no account, telemetry backend, or LokalBot-hosted AI service. Its built-in speech and language models run on Apple Silicon, while meetings, transcripts, summaries, and search indexes live in the app's local data directory.</p>

        <h2>From call to recap</h2>
        <ol>
          <li><strong>Capture two sources.</strong> Your microphone is recorded as “Me.” A macOS Core Audio process tap captures the meeting application's output as “Them.” No participant bot needs to join.</li>
          <li><strong>Transcribe on-device.</strong> Choose Granite Speech, Parakeet, Qwen3-ASR, or Whisper. The audio stays on the Mac while the selected engine creates a timestamped transcript.</li>
          <li><strong>Write the recap.</strong> A built-in llama.cpp model can produce the summary, decisions, and action items locally. You can instead select Ollama, Apple Intelligence, or an explicitly approved OpenAI-compatible origin.</li>
          <li><strong>Search and replay.</strong> The transcript and recap are indexed in the local library. A search result can take you back to the relevant point in the recording.</li>
        </ol>

        <h2>Why two audio tracks matter</h2>
        <p>Recording the microphone and meeting app separately preserves audio-source provenance before any diarization model runs. One track contains whatever the selected microphone captured; the other contains the selected app's output. Those sources stay synchronized and avoid the audible joins and calendar invitations created by meeting bots. The source labels do not prove who spoke: shared microphones, speaker leakage, and room playback can put a person's voice on either track. Optional neural diarization can estimate speaker turns within the system-audio track.</p>

        <h2>The honest trade-offs</h2>
        <ul>
          <li><strong>Hardware:</strong> on Mac, LokalBot requires Apple Silicon and macOS 15 or later. Windows and Linux versions are in alpha; see the <a href="system-requirements">system requirements</a>.</li>
          <li><strong>Storage:</strong> selected models download before first use. Small choices start around 0.5 GB; high-quality language models can be much larger.</li>
          <li><strong>Permissions:</strong> microphone and system-audio access are necessary for capture. Other features ask separately for Calendar, Accessibility, or Screen Recording access.</li>
          <li><strong>Responsibility:</strong> bot-free is not consent-free. You must follow the recording laws and policies that apply to the people in your meeting.</li>
          <li><strong>Model quality:</strong> local accuracy depends on language, acoustics, model choice, and available memory. Keeping more than one speech model installed lets you switch for difficult recordings.</li>
        </ul>

        <h2>Who benefits most</h2>
        <p>Local meeting notes are a strong fit for confidential client work, engineering discussions, research interviews, financial conversations, or anyone who simply does not want a permanent vendor account attached to every conversation. They are less compelling when a team primarily needs shared cloud workspaces, centralized administration, or mobile capture across several platforms.</p>
        """,
        "faq": [
            ("Can LokalBot work without internet?", "Yes, after the app and selected models are downloaded. Built-in transcription, summaries, search, and replay work offline. Update checks, model downloads, and any remote backend you configure need a connection."),
            ("Does a bot join the meeting?", "No. LokalBot records your microphone and the meeting application's system audio on the Mac."),
            ("Where are meetings stored?", "In LokalBot's local Application Support data. They are not copied to a LokalBot account or cloud because neither exists."),
        ],
        "related": ["record-both-sides-mac-meeting-without-bot", "offline-meeting-transcription-mac", "system-requirements"],
    },
    {
        "slug": "local-ai-meeting-notes-linux",
        "published": "2026-10-26",
        "updated": "2026-10-26",
        "updated_label": "October 26, 2026",
        "title": "Local AI Meeting Notes on Linux — Bot-Free and Open Source",
        "description": "Record, transcribe, and summarize meetings on Linux without a bot or a cloud service: how LokalBot works on X11 and Wayland, installing with apt, dnf, or pacman, and the models it runs.",
        "eyebrow": "Linux",
        "h1": "Local AI meeting notes on Linux",
        "lead": "LokalBot records both sides of a call without a bot, transcribes and summarizes it with models on your computer, and keeps every meeting searchable. Here is what works on Linux, what depends on your desktop, and how to install it.",
        "read_time": "6 min read",
        "body": """
        <h2>What works on Linux</h2>
        <p>LokalBot for Linux is a native app written in Rust with GPUI, the UI framework behind the Zed editor. It has the same pages as the Mac app (Today, Meetings, Timeline, People, Projects, Ask, and Settings) and reads the same library format, so a library recorded on a Mac opens on Linux. It's an alpha.</p>
        <ul>
          <li><strong>Meetings without a bot.</strong> LokalBot records your microphone and your computer's audio through a PulseAudio or PipeWire monitor, so nothing joins the call. On Linux the second track is everything your computer plays, not one app. When it detects a meeting, it asks with a notification.</li>
          <li><strong>On-device transcription.</strong> Qwen3-ASR 0.6B through sherpa-onnx by default, with Parakeet v3, SenseVoice, and Whisper turbo as options. Speakers are separated with pyannote segmentation and TitaNet.</li>
          <li><strong>Notes and Ask.</strong> Summaries, decisions, action items, and answers with citations come from Qwen3.5 4B in the built-in llama.cpp, or from Ollama, an OpenAI-compatible server you approve, or your ChatGPT or Claude plan.</li>
          <li><strong>Search.</strong> Keyword and meaning search across your meetings, with SQLite full-text search and EmbeddingGemma 2, plus Quick Recall from a shortcut.</li>
          <li><strong>Agent access.</strong> A read-only CLI and MCP server lets Claude Code, Codex, and other agents search your meetings, off until you allow it.</li>
        </ul>

        <h2>Your desktop matters</h2>
        <p>Meetings, transcription, notes, search, and Ask work on any desktop. A few features depend on what your desktop lets apps do:</p>
        <div class="guide-table-wrap">
          <table class="guide-table">
            <thead><tr><th scope="col">Feature</th><th scope="col">X11</th><th scope="col">Wayland</th></tr></thead>
            <tbody>
              <tr><th scope="row">Day memory (app and window activity)</th><td>Yes</td><td>Hyprland, Sway, and KDE; GNOME with the Window Calls extension</td></tr>
              <tr><th scope="row">Screen context (visible text, optional encrypted screenshots)</th><td>Yes</td><td>Sway and Hyprland with <code>grim</code>; other desktops through the screenshot portal when it can capture just the active window</td></tr>
              <tr><th scope="row">Dictation</th><td>Yes</td><td>Bind <code>lokalbot dictate</code> to a shortcut in your compositor</td></tr>
              <tr><th scope="row">Autocomplete in other apps</th><td>GTK apps; Qt, Chromium, Electron, and Firefox once system accessibility is on</td><td>Only in the practice editor in Settings</td></tr>
              <tr><th scope="row">Tray icon</th><td colspan="2">Yes; GNOME needs the AppIndicator extension</td></tr>
            </tbody>
          </table>
        </div>
        <p>On <a href="/blog/windows-and-linux-alpha">Omarchy and other Hyprland desktops</a>, <code>grim</code>, <code>wtype</code>, <code>wl-clipboard</code>, and PipeWire are already there, and the dictation pill and Quick Recall float instead of tiling.</p>

        <h2>Install and stay updated</h2>
        <ul>
          <li><strong>Debian and Ubuntu:</strong> <code>sudo apt install ./LokalBot-&lt;version&gt;-linux-amd64.deb</code>. It adds the LokalBot repository at pkg.lokalbot.com, so <code>sudo apt upgrade</code> brings later versions.</li>
          <li><strong>Fedora:</strong> <code>sudo dnf install ./LokalBot-&lt;version&gt;-linux-x86_64.rpm</code>, then <code>sudo dnf upgrade</code> for later versions. On openSUSE the same package installs, and LokalBot tells you when a new version is out.</li>
          <li><strong>Arch and Omarchy:</strong> <code>sudo pacman -U ./LokalBot-&lt;version&gt;-linux-x86_64.pkg.tar.zst</code>. LokalBot tells you when a newer package is out.</li>
          <li><strong>Any distribution:</strong> extract the <code>.tar.gz</code> and run <code>./install.sh</code>. It installs into <code>~/.local/bin</code>, adds LokalBot to your applications menu, and lets the app update itself after checking each download's signature.</li>
        </ul>
        <p>All of them are on the <a href="https://github.com/stevyhacker/lokalbot/releases/latest" target="_blank" rel="noopener">latest release</a>. LokalBot needs x86_64 with glibc 2.39 or later (Ubuntu 24.04, Debian 13, Fedora 40, or newer), PulseAudio or PipeWire, and a Vulkan or OpenGL driver; Mesa is fine. See the <a href="system-requirements">system requirements</a>.</p>

        <h2>Models and hardware</h2>
        <p>On first launch LokalBot asks what to remember and downloads the models you choose: about 4 GB for the default transcription, notes, and search models. llama.cpp runs on any Vulkan GPU or on the CPU. On an NVIDIA GPU you can choose <strong>CUDA (experimental)</strong> in Settings → Models → llama.cpp; in testing, CUDA read a long prompt into Qwen3.5 4B 44% faster than Vulkan on an RTX 3060. Without a capable GPU, notes on the CPU are slow, so you can point notes and Ask at Ollama on another computer or at a server you approve.</p>

        <h2>What's not there yet</h2>
        <ul>
          <li>Selection actions, meeting note export and daily memory notes, Personal Context, spoken summaries, and coding-agent sessions in day memory are Mac only for now.</li>
          <li>There's no Flatpak or Snap. An AUR package, <code>lokalbot-bin</code>, is on its way.</li>
          <li>Bot-free is not consent-free. Tell the people in your meeting that you're recording, and follow the rules that apply to them.</li>
        </ul>
        """,
        "faq": [
            ("Does LokalBot work on Wayland?", "Yes, with limits. Meetings, transcription, notes, search, and Ask work on any desktop. Day memory works on Hyprland, Sway, KDE, and GNOME with the Window Calls extension; screen context needs grim on Sway and Hyprland or the desktop's screenshot portal elsewhere; dictation needs a compositor shortcut bound to lokalbot dictate; and autocomplete in other apps needs X11."),
            ("Do I need an NVIDIA GPU?", "No. The built-in models run on any Vulkan GPU, including AMD and Intel graphics, or on the CPU. CUDA is an experimental option for NVIDIA GPUs."),
            ("Can I move my library between Linux and a Mac?", "Yes. Both apps read the same library format, and meetings recorded on a Mac play and transcribe on Linux. On Linux the library lives in ~/.local/share/LokalBot. LokalBot doesn't sync it between computers for you."),
        ],
        "related": ["system-requirements", "local-ai-meeting-notes-windows", "open-source-ai-meeting-notes"],
    },
    {
        "slug": "local-ai-meeting-notes-windows",
        "published": "2026-10-26",
        "updated": "2026-10-26",
        "updated_label": "October 26, 2026",
        "title": "Local AI Meeting Notes on Windows — Bot-Free and Open Source",
        "description": "Record, transcribe, and summarize Teams, Zoom, and Meet calls on Windows 10 and 11 without a bot or a cloud service: how LokalBot works, installing it without admin rights, and the models it runs.",
        "eyebrow": "Windows",
        "h1": "Local AI meeting notes on Windows",
        "lead": "LokalBot records both sides of a Teams, Zoom, or Meet call without a bot, transcribes and summarizes it with models on your PC, and keeps every meeting searchable. Here is what works on Windows and how to install it.",
        "read_time": "5 min read",
        "body": """
        <h2>What works on Windows</h2>
        <p>LokalBot for Windows is a native app written in Rust with GPUI, the UI framework behind the Zed editor. It has the same pages as the Mac app and reads the same library format, so a library recorded on a Mac opens on Windows. It's an alpha.</p>
        <ul>
          <li><strong>Meetings without a bot.</strong> LokalBot records your microphone and your PC's audio through WASAPI loopback, so nothing joins the call. On Windows the second track is everything your PC plays, not one app. When it detects a meeting, it asks with a notification.</li>
          <li><strong>On-device transcription.</strong> Qwen3-ASR 0.6B by default, with Parakeet v3, SenseVoice, and Whisper turbo as options, and speakers separated with pyannote segmentation and TitaNet.</li>
          <li><strong>Notes and Ask.</strong> Summaries, decisions, action items, and answers with citations from Qwen3.5 4B in the built-in llama.cpp, Ollama, an OpenAI-compatible server you approve, or your ChatGPT or Claude plan.</li>
          <li><strong>Your day.</strong> App and window activity, and, if you turn it on, screen text and encrypted screenshots, read through UI Automation and on-device OCR.</li>
          <li><strong>Writing.</strong> Hold <kbd>Alt+Space</kbd> to dictate anywhere. Optional autocomplete suggests the next words in apps whose text fields support UI Automation, with LFM2.5 1.2B on your PC.</li>
          <li><strong>Calendar.</strong> Private iCal or CalDAV links from Outlook, Google, or another calendar name your recordings and list today's meetings.</li>
          <li><strong>Agents.</strong> A read-only CLI and MCP server for Claude Code, Codex, and other agents, and an optional Agent Mode that works on your files with your approval, in Git Bash or PowerShell.</li>
        </ul>

        <h2>Install without admin rights</h2>
        <p>Run <code>LokalBot-&lt;version&gt;-windows-x86_64-setup.exe</code> from the <a href="https://github.com/stevyhacker/lokalbot/releases/latest" target="_blank" rel="noopener">latest release</a>. It installs for your user into <code>%LOCALAPPDATA%\\Programs\\LokalBot</code>, without administrator rights, and adds a Start menu shortcut and an Installed apps entry. Uninstalling keeps your library. A portable zip is in the same release.</p>
        <p>The app isn't code-signed yet, so SmartScreen asks before the first launch: choose <strong>More info → Run anyway</strong>. Updates are signed: LokalBot checks for a new version once a day, verifies the download's signature, and installs it only when you choose <strong>Install and Relaunch</strong>. A winget package is in review.</p>

        <h2>Models and hardware</h2>
        <p>LokalBot needs Windows 10 or 11 on x64. On first launch it downloads the models you choose: about 4 GB for the default transcription, notes, and search models. llama.cpp runs on any Vulkan GPU, including AMD Radeon and Intel graphics, or on the CPU. On an NVIDIA GPU you can choose <strong>CUDA (experimental)</strong> in Settings → Models → llama.cpp; in testing on an NVIDIA L4, CUDA read a long prompt into Qwen3.5 4B 32% faster than Vulkan. See the <a href="system-requirements">system requirements</a>.</p>

        <h2>What's not there yet</h2>
        <ul>
          <li>Code signing, so SmartScreen will warn until it's in place.</li>
          <li>Selection actions, meeting note export and daily memory notes, Personal Context, spoken summaries, and coding-agent sessions in day memory are Mac only for now.</li>
          <li>Bot-free is not consent-free. Tell the people in your meeting that you're recording, and follow the rules that apply to them.</li>
        </ul>
        """,
        "faq": [
            ("Why does Windows warn me before LokalBot opens?", "The Windows build isn't code-signed yet, so SmartScreen asks first. Choose More info, then Run anyway. The source is public on GitHub, and every update LokalBot installs is checked against its signature first."),
            ("Does a bot join my Teams or Zoom calls?", "No. LokalBot records your microphone and what your PC plays, on two tracks, so nothing joins the call and other participants don't see a notetaker. Tell them you're recording."),
            ("Do I need administrator rights?", "No. The installer installs LokalBot for your user only. A portable zip that runs from any folder is also available."),
        ],
        "related": ["system-requirements", "local-ai-meeting-notes-linux", "claude-code-codex-meeting-notes"],
    },
    {
        "slug": "offline-meeting-transcription-mac",
        "updated": "2026-10-20",
        "updated_label": "October 20, 2026",
        "title": "Offline Meeting Transcription on Mac",
        "description": "Set up offline meeting transcription on Apple Silicon with local speech models, two-track audio, timestamps, and no cloud upload.",
        "eyebrow": "Offline transcription",
        "h1": "Offline meeting transcription on Mac",
        "lead": "What you need to download first, which local speech model to choose, and what continues working when your Mac has no network connection.",
        "read_time": "5 min read",
        "body": """
        <h2>Prepare before you go offline</h2>
        <p>Offline transcription is simple once every required file is already on the Mac. Install LokalBot, open its model settings, and download at least one speech-recognition model. Process a short test recording while connected so macOS permissions, the model, and the output folder are all confirmed before the real meeting.</p>
        <p>The app itself does not require an account or activation server. Once the selected files are present, recording, transcription, local summarization, search, and playback can run without internet access.</p>

        <h2>Choose the speech engine for the job</h2>
        <p>There is no universal best local model. LokalBot exposes several engines because language coverage, speed, timestamps, and hard-audio accuracy pull in different directions.</p>
        <ul>
          <li><strong>IBM Granite Speech 4.1 2B</strong> is another local speech-recognition option.</li>
          <li><strong>Parakeet TDT 0.6B v3</strong> is the fast multilingual option, covering 25 languages and measuring around 190× realtime in the project's benchmark.</li>
          <li><strong>Parakeet v2</strong> focuses on English and can be useful when recall matters more than broad language coverage.</li>
          <li><strong>Qwen3-ASR 1.7B</strong> is the default in LokalBot 0.8.1, covers 52 languages and dialects, and downloads about 3.2 GB.</li>
          <li><strong>Qwen3-ASR 0.6B</strong> provides a compact global-coverage option at roughly 0.7 GB.</li>
          <li><strong>Whisper large-v3 turbo</strong> covers 99 languages, supports word timestamps, and is a useful wide-language fallback at roughly 1.6 GB.</li>
        </ul>
        <p>This list is the Mac catalog. Windows and Linux (alpha) use different speech models; see the <a href="system-requirements">system requirements</a>.</p>

        <h2>What happens during an offline meeting</h2>
        <p>LokalBot writes your microphone and the meeting application's output to synchronized local tracks. When the meeting ends, the chosen speech engine turns those files into text on the Mac. The built-in language-model backend can then write a recap without a server request. The transcript, recap, audio references, and search index remain in the local library.</p>
        <p>Offline mode does not weaken recording-consent requirements. On a fresh install, LokalBot asks through a notification before it records a detected meeting. Automatic recording is opt-in, and the decision and legal responsibility stay with you.</p>

        <h2>What still uses the network</h2>
        <p>Model files and application updates have to come from somewhere, so those downloads require a connection. Optional Agent Mode setup also downloads its pinned runtime. Finally, if you replace the built-in inference backend with a non-loopback OpenAI-compatible URL, that configured service naturally needs the network and receives the request context. Loopback services such as a local Ollama instance can remain entirely on the Mac.</p>

        <h2>A useful offline checklist</h2>
        <ol>
          <li>Download the speech model and one summarization model.</li>
          <li>Record and process a 30-second test with the meeting app you will use.</li>
          <li>Confirm both the microphone and system-audio tracks contain audio.</li>
          <li>Disconnect Wi-Fi and repeat the test.</li>
          <li>Keep enough free disk space for the models and meeting audio.</li>
        </ol>
        """,
        "faq": [
            ("Will transcription start without Wi-Fi?", "Yes, provided the selected model has already finished downloading."),
            ("Can summaries also run offline?", "Yes. Select the built-in llama.cpp backend and a downloaded local model."),
            ("Which model is smallest?", "Among the highlighted speech choices, Qwen3-ASR 0.6B is about 0.7 GB. Actual on-disk usage can change with model packaging."),
        ],
        "related": ["local-transcription-models-mac", "local-ai-meeting-notes-mac", "system-requirements"],
    },
    {
        "slug": "open-source-ai-meeting-notes",
        "updated": "2026-10-20",
        "updated_label": "October 20, 2026",
        "title": "Open-Source AI Meeting Notes: What to Verify",
        "description": "A checklist for evaluating open-source AI meeting notes: license, local processing, network boundaries, storage, builds, and updates.",
        "eyebrow": "Open source",
        "h1": "Open-source AI meeting notes: what to verify",
        "lead": "A public repository is useful, but privacy depends on the whole data path. Here is how to evaluate the license, runtime, storage, network boundaries, and distribution.",
        "read_time": "6 min read",
        "body": """
        <h2>Open source is evidence, not a magic label</h2>
        <p>Source access lets you inspect what a meeting app records, where it stores the result, which hosts it contacts, and what changes when you enable an optional service. It does not automatically prove that a particular downloadable build matches the repository, or that every dependency is harmless. Treat the code as an unusually strong verification tool, then check the actual release and runtime behavior too.</p>

        <h2>Start with the license</h2>
        <p>LokalBot is released under GPLv3. You can read, modify, and build the code, and distributed derivative versions must preserve the license obligations. That differs from “source available” products whose licenses restrict commercial use, redistribution, or forks. The repository's license file is the authoritative text.</p>

        <h2>Trace the meeting data path</h2>
        <p>For a private notetaker, follow the recording from capture to deletion:</p>
        <ol>
          <li>The microphone and the meeting audio produce two local audio tracks. On a Mac the second track is the selected meeting app; on Windows and Linux it is everything the computer plays.</li>
          <li>A downloaded speech engine creates the transcript on your computer.</li>
          <li>The built-in llama.cpp backend can generate a summary locally.</li>
          <li>SQLite stores the library and full-text search index.</li>
          <li>Day tracking starts activity-only: app names and window titles. Visible text and encrypted screenshots are opt-in, permission-gated, and deleted after 14 days by default.</li>
        </ol>
        <p>Then identify the exceptions. LokalBot connects to download models and updates, to set up optional Agent Mode, and to call any non-loopback inference origin you explicitly approve. On Windows and Linux it also downloads a pinned llama.cpp runtime from GitHub once. That distinction is more useful than an absolute “never connects” claim.</p>

        <h2>Check account and telemetry requirements</h2>
        <p>An app can be open source while its useful features depend on a hosted account. LokalBot has no account, subscription, analytics service, advertising SDK, or telemetry backend. Its public issue tracker provides community support, and the security policy points vulnerability reports to a private channel.</p>

        <h2>Build it yourself</h2>
        <p>The repository has build instructions for both apps: an XcodeGen project for the Mac app, and a Rust workspace you build with <code>cargo</code> for the Windows and Linux app. A source build is the strongest way to connect the code you inspected with the binary you run. It also makes the trade-off explicit: local-first software still relies on operating-system frameworks and bundled or downloaded model runtimes, so dependency review remains part of a serious audit.</p>
        <pre class="code" aria-label="Build LokalBot from source"><span class="c-prompt">$</span> git clone https://github.com/stevyhacker/lokalbot.git
<span class="c-prompt">$</span> cd lokalbot

<span class="c-op"># Mac</span>
<span class="c-prompt">$</span> mkdir -p Vendor/llama-cpp Vendor/sherpa-onnx
<span class="c-prompt">$</span> xcodegen generate <span class="c-op">&amp;&amp;</span> open LokalBot.xcodeproj

<span class="c-op"># Windows and Linux</span>
<span class="c-prompt">$</span> cd LinuxWindows
<span class="c-prompt">$</span> cargo run -p lokalbot-app</pre>
        <p>The Rust build needs the toolchain pinned in the repository, plus system libraries on Linux and the Visual Studio 2022 Build Tools and CMake on Windows. The <a href="https://github.com/stevyhacker/lokalbot/blob/master/LinuxWindows/README.md#build-from-source" target="_blank" rel="noopener">Windows and Linux README</a> lists them.</p>

        <h2>A five-question evaluation</h2>
        <ul>
          <li>Can the core workflow run with the network disconnected?</li>
          <li>Does the license actually grant the freedoms you expect?</li>
          <li>Are remote endpoints opt-in, visible, and scoped?</li>
          <li>Can you delete the library without asking a vendor?</li>
          <li>Are releases, update metadata, and security reporting public?</li>
        </ul>
        """,
        "faq": [
            ("Is LokalBot free for commercial work?", "LokalBot is GPLv3 software and has no usage subscription. Review the license itself for obligations that apply when you modify or distribute it."),
            ("Can I audit network access?", "Yes. The source is public, and the privacy policy names the normal network paths: models, updates, optional Agent Mode setup, and approved remote inference."),
            ("Do I need an API key?", "No. The built-in local models work without one. API keys are relevant only if you choose an external compatible backend that requires them."),
        ],
        "related": ["local-ai-meeting-notes-mac", "offline-meeting-transcription-mac", "system-requirements"],
    },
    {
        "slug": "record-both-sides-mac-meeting-without-bot",
        "updated": "2026-10-20",
        "updated_label": "October 20, 2026",
        "title": "Record Both Sides of a Mac Meeting Without a Bot",
        "description": "How LokalBot captures your microphone and meeting-app audio as synchronized tracks on macOS without adding a bot participant.",
        "eyebrow": "Bot-free capture",
        "h1": "Record both sides of a Mac meeting without a bot",
        "lead": "A microphone alone misses the people coming through your speakers. A meeting bot changes the call. macOS process audio provides a third route.",
        "read_time": "5 min read",
        "body": """
        <h2>Why ordinary recording falls short</h2>
        <p>Your microphone is designed to capture your voice, not clean digital output from Zoom, Teams, Meet, Slack, Webex, or FaceTime. Turning the speakers up and recording the room mixes both sides with echo, keyboard noise, and acoustic processing. A cloud meeting bot avoids that acoustic problem but becomes another participant, may require calendar access, and sends the call through an external service.</p>

        <h2>The two-track approach</h2>
        <p>LokalBot records two synchronized audio sources: the selected microphone and a Core Audio process tap for the selected meeting application's output. The transcript labels describe where the audio was captured, not a verified speaker identity. A shared microphone, headphones leaking into the mic, or meeting audio played into the room can put the same voice on either source.</p>
        <p>When several voices occur in the system-audio source, optional on-device diarization can estimate additional speaker turns. Diarization is probabilistic, so identities and boundaries may still need editing after a difficult or overlapping conversation.</p>
        <p>The Windows and Linux versions (alpha) also record two tracks, but the second one is everything the computer plays, not one app: WASAPI loopback on Windows, and a PulseAudio or PipeWire monitor on Linux. Notifications or music playing during the call end up in the recording too. Calendar matching there uses private iCal or CalDAV links instead of macOS Calendar. See the <a href="system-requirements">system requirements</a>.</p>

        <h2>What the other participants see</h2>
        <p>No account joins the room, no virtual participant appears in the roster, and no bot announces itself. That makes the workflow less disruptive, but it does not make recording invisible in a legal or ethical sense. Tell people when required, obtain consent, and follow employer and platform policies. LokalBot is a personal recorder; it cannot decide whether a particular meeting may be recorded.</p>

        <h2>Permissions and controls</h2>
        <ul>
          <li><strong>Microphone access</strong> captures your side.</li>
          <li><strong>System-audio access</strong> enables the process tap for the other side.</li>
          <li><strong>Ask via notification</strong> is the fresh-install default: LokalBot asks before it records a detected meeting.</li>
          <li><strong>Automatic or never-auto-record modes</strong> can be chosen in Settings.</li>
          <li><strong>Calendar access</strong> is optional and can help detect and title scheduled meetings.</li>
        </ul>

        <h2>After the call</h2>
        <p>The selected local speech model transcribes the synchronized audio. The built-in language model can turn the transcript into a TL;DR, decisions, and action items. Because the capture sources are separate, you can replay the microphone and selected-app system audio independently and search from a result back to the relevant timestamp. Those sources still describe audio provenance rather than verified identity.</p>

        <h2>A pre-meeting test worth doing</h2>
        <p>Open the actual meeting app, play remote audio, speak into your microphone, and make a short recording. Verify that both tracks show activity and play back correctly. macOS permissions and device routing can change when you switch headsets, docks, or output devices, so repeat this check before an unusually important call.</p>
        """,
        "faq": [
            ("Does LokalBot join Zoom or Google Meet?", "No. It records the selected app's audio locally through macOS rather than joining as a participant."),
            ("Can it identify every speaker?", "No. It separates microphone audio from the selected app's output, and those sources do not prove identity. Optional diarization can estimate distinct voices within system audio, but accuracy depends on the recording."),
            ("Is bot-free recording legal everywhere?", "No recording method is automatically legal everywhere. You are responsible for notice, consent, workplace rules, and local law."),
        ],
        "related": ["local-ai-meeting-notes-mac", "offline-meeting-transcription-mac", "system-requirements"],
    },
    {
        "slug": "local-transcription-models-mac",
        "updated": "2026-10-20",
        "updated_label": "October 20, 2026",
        "title": "Local Transcription Models for Mac: A Guide",
        "description": "Compare Granite Speech, Parakeet, Qwen3-ASR, and Whisper for private on-device meeting transcription on Apple Silicon.",
        "eyebrow": "Model guide",
        "h1": "Local transcription models for Mac",
        "lead": "Granite, Parakeet, Qwen3-ASR, or Whisper? Choose by language, speed, timestamps, recording difficulty, and available disk space.",
        "read_time": "7 min read",
        "body": """
        <h2>There is no single best speech model</h2>
        <p>A quiet English call, a multilingual interview, and a noisy recording with domain vocabulary are different problems. LokalBot keeps several engines available so you can choose a fast default and retain a broader or more accurate fallback. All of the options below run locally after their files have downloaded.</p>

        <div class="guide-table-wrap">
          <table class="guide-table">
            <thead><tr><th>Model</th><th>Best fit</th><th>Coverage / size</th></tr></thead>
            <tbody>
              <tr><td>IBM Granite Speech 4.1 2B</td><td>Alternative local speech engine</td><td>Local llama.cpp speech model</td></tr>
              <tr><td>Parakeet TDT 0.6B v3</td><td>Very fast multilingual meetings</td><td>25 languages; ~190× realtime in project benchmarks</td></tr>
              <tr><td>Parakeet TDT 0.6B v2</td><td>English-focused recall</td><td>English only</td></tr>
              <tr><td>Qwen3-ASR 1.7B</td><td>Default in LokalBot 0.8.1</td><td>52 languages/dialects; ~3.2 GB</td></tr>
              <tr><td>Qwen3-ASR 0.6B</td><td>Compact broad coverage</td><td>Global coverage; ~0.7 GB</td></tr>
              <tr><td>Whisper large-v3 turbo</td><td>Wide-language fallback and timestamps</td><td>99 languages; ~1.6 GB</td></tr>
            </tbody>
          </table>
        </div>
        <p>The table covers the Mac app. The Windows and Linux versions (alpha) use Qwen3-ASR 0.6B by default, with Parakeet v3, SenseVoice, and Whisper turbo as options, and no Granite Speech; see the <a href="system-requirements">system requirements</a>.</p>

        <h2>A sensible selection strategy</h2>
        <ol>
          <li><strong>Start with Qwen3-ASR 1.7B</strong> for the default speech model in LokalBot 0.8.1.</li>
          <li><strong>Choose Parakeet v3</strong> when throughput and its 25 supported languages cover your meetings.</li>
          <li><strong>Keep Whisper installed</strong> if you need broader language coverage or word timestamps.</li>
          <li><strong>Compare Granite Speech</strong> as another local option on the recordings that matter to you.</li>
          <li><strong>Compare on your audio.</strong> A two-minute representative clip is more informative than a generic benchmark.</li>
        </ol>

        <h2>Speech recognition is only one stage</h2>
        <p>Speaker separation, punctuation, summary quality, and action-item extraction depend on later stages too. LokalBot begins with separate microphone and selected-app system-audio tracks, whose labels indicate capture source rather than speaker identity. It can apply on-device diarization to system audio before sending the transcript to the selected summarization backend. A perfect language model cannot recover words that the speech model never recognized, so improve capture and transcription before tuning recap prompts.</p>

        <h2>Storage and memory planning</h2>
        <p>Speech models are not the only downloads. Local summary and cotyping models range from about 0.53 GB to roughly 17.73 GB in the built-in catalog. Smaller options work on any supported Apple Silicon Mac; several quality-focused choices recommend 16 GB, while the largest long-meeting defaults target 32 GB or more. Install only what you use and keep free space for recordings.</p>

        <h2>How to evaluate output</h2>
        <ul>
          <li>Use the same audio file for every candidate.</li>
          <li>Check names, numbers, domain terms, and language switches.</li>
          <li>Review timestamps and speaker boundaries, not just prose readability.</li>
          <li>Measure end-to-end time on your own Mac.</li>
          <li>Keep the model whose errors are easiest for your workflow to notice and fix.</li>
        </ul>
        """,
        "faq": [
            ("Which model does LokalBot recommend?", "Qwen3-ASR 1.7B is the default transcription model in LokalBot 0.8.1. You can change it in Settings → Models."),
            ("Which option covers the most languages?", "Whisper large-v3 turbo has the broadest listed coverage at 99 languages. Language count alone does not guarantee the best result for a specific recording."),
            ("Can I keep several models installed?", "Yes. That is useful when your meetings vary by language or audio quality, subject to disk space."),
        ],
        "related": ["offline-meeting-transcription-mac", "system-requirements", "local-ai-meeting-notes-mac"],
    },
    {
        "slug": "system-requirements",
        "updated": "2026-10-20",
        "updated_label": "October 20, 2026",
        "title": "LokalBot System Requirements: Mac, Windows and Linux (alpha)",
        "description": "Check LokalBot's requirements on Mac, Windows and Linux (alpha): OS versions, hardware, memory, disk, permissions, and model downloads.",
        "eyebrow": "Compatibility",
        "h1": "LokalBot system requirements",
        "lead": "The short version: an Apple Silicon Mac on macOS 15 or later, a Windows 10 or 11 x64 PC (alpha), or an x86_64 Linux desktop with glibc 2.39 or later (alpha), plus enough disk for the models you choose.",
        "read_time": "7 min read",
        "body": """
        <h2>Mac</h2>
        <ul>
          <li><strong>Mac:</strong> Apple Silicon — M1 or later.</li>
          <li><strong>Operating system:</strong> macOS 15.0 or later.</li>
          <li><strong>Install:</strong> download <a href="https://github.com/stevyhacker/lokalbot/releases/latest" data-asset="mac">the DMG</a>, or run <code>brew install --cask stevyhacker/tap/lokalbot</code>.</li>
          <li><strong>Disk:</strong> room for the app, recordings, and selected models.</li>
          <li><strong>Internet:</strong> required for the initial app and model downloads; optional for the built-in workflow after setup.</li>
          <li><strong>Library:</strong> <code>~/Library/Application Support/me.dotenv.LokalBot</code>.</li>
        </ul>
        <p>Intel Macs are not supported. The Mac app is built around Apple Silicon acceleration, Core Audio process taps, the Neural Engine, MLX, and Metal. Windows and Linux have their own native app, built separately, with the same pages and the same library format.</p>

        <h2>How much memory does a Mac need?</h2>
        <p>The Mac app runs across the supported Apple Silicon range, but local language-model choice changes the practical memory requirement. Compact built-in models start around 0.53–1.28 GB. Several balanced summary and cotyping models recommend 16 GB of unified memory. The largest long-meeting models in the catalog are roughly 16.8–17.73 GB on disk and target Macs with 32 GB or more.</p>
        <p>You do not need the largest model to record or transcribe a meeting. Choose a compact speech model and a smaller summarizer first, then move up only if the quality gain is worthwhile on your hardware.</p>

        <h2>Plan disk space on a Mac</h2>
        <ul>
          <li><strong>Compact setup:</strong> a roughly 0.7 GB Qwen3-ASR speech model plus a small 0.53–1.28 GB language model.</li>
          <li><strong>Broader transcription:</strong> Whisper large-v3 turbo is roughly 1.6 GB; Qwen3-ASR 1.7B is roughly 3.2 GB.</li>
          <li><strong>Quality-focused summaries:</strong> larger catalog choices add about 5–18 GB each.</li>
          <li><strong>Meetings and day memory:</strong> audio, transcripts, and visual captures use additional space over time.</li>
        </ul>
        <p>These numbers describe model downloads and may change when publishers update packaging. LokalBot lets you choose rather than downloading every model.</p>

        <h2>macOS permissions</h2>
        <p>Grant only the permissions for features you intend to use:</p>
        <ul>
          <li><strong>Microphone</strong> records your voice.</li>
          <li><strong>System audio / Screen Recording</strong> enables the selected meeting-app audio capture and visual screen context.</li>
          <li><strong>Calendar</strong> helps detect and title scheduled meetings.</li>
          <li><strong>Accessibility</strong> supports meeting detection, Cotyping, dictation insertion, and approved agent interaction.</li>
        </ul>
        <p>On a fresh install, LokalBot asks through a notification before it records a detected meeting, and day tracking saves only app names and window titles. Visible text and encrypted screenshots are opt-in, gated by macOS permissions, and deleted after 14 days by default.</p>

        <h2>Windows (alpha)</h2>
        <ul>
          <li><strong>Operating system:</strong> Windows 10 or 11 on an x64 PC.</li>
          <li><strong>Install:</strong> download <a href="https://github.com/stevyhacker/lokalbot/releases/latest" data-asset="windows">the Windows installer</a> from the latest release and run it. It installs LokalBot for your user into <code>%LOCALAPPDATA%\\Programs\\LokalBot</code>, with a Start menu shortcut and no administrator rights. It isn't code-signed yet, so SmartScreen asks first: choose <strong>More info → Run anyway</strong>. The release also has a portable zip.</li>
          <li><strong>System audio:</strong> WASAPI loopback records everything the computer plays, not just the meeting app.</li>
          <li><strong>Disk:</strong> about 4 GB for the default transcription, summary, and search models, plus your recordings.</li>
          <li><strong>GPU:</strong> optional. The built-in llama.cpp runs on a Vulkan GPU or on the CPU.</li>
          <li><strong>Library:</strong> <code>%LOCALAPPDATA%\\LokalBot</code>.</li>
        </ul>

        <h2>Linux (alpha)</h2>
        <ul>
          <li><strong>System:</strong> x86_64 with glibc 2.39 or later, such as Ubuntu 24.04, Debian 13, or Fedora 40 or newer.</li>
          <li><strong>Graphics:</strong> a Vulkan or OpenGL driver. Mesa is fine.</li>
          <li><strong>Audio:</strong> PulseAudio or PipeWire. LokalBot records the output monitor, so it captures everything the computer plays, not just the meeting app.</li>
          <li><strong>Install:</strong> download <a href="https://github.com/stevyhacker/lokalbot/releases/latest" data-asset="linux">the Linux archive</a> from the latest release, extract it, and run <code>./install.sh</code>. It installs LokalBot to <code>~/.local/bin</code> and adds it to your applications menu. The same release also has a <code>.deb</code> (Debian, Ubuntu), an <code>.rpm</code> (Fedora, openSUSE) and an Arch package. Installing the <code>.deb</code>, or the <code>.rpm</code> on Fedora, also adds the LokalBot repository, so <code>sudo apt upgrade</code> or <code>sudo dnf upgrade</code> brings later versions; with the Arch package, LokalBot tells you about updates instead of installing them.</li>
          <li><strong>Disk:</strong> about 4 GB for the default models, plus your recordings. The built-in llama.cpp runs on a Vulkan GPU or on the CPU.</li>
          <li><strong>GNOME:</strong> the tray icon needs the AppIndicator extension, and day memory needs the Window Calls extension.</li>
          <li><strong>Library:</strong> <code>~/.local/share/LokalBot</code>.</li>
        </ul>

        <h2>X11 and Wayland</h2>
        <p>On Linux, a few features depend on whether your desktop session runs X11 or Wayland:</p>
        <div class="guide-table-wrap">
          <table class="guide-table">
            <thead><tr><th scope="col">Feature</th><th scope="col">X11</th><th scope="col">Wayland</th></tr></thead>
            <tbody>
              <tr><th scope="row">Day memory (app and window activity)</th><td>Yes</td><td>Hyprland, Sway, and KDE; GNOME with the Window Calls extension</td></tr>
              <tr><th scope="row">Screen context (visible text, optional screenshots)</th><td>Yes</td><td>Sway and Hyprland with <code>grim</code>; other desktops through the screenshot portal</td></tr>
              <tr><th scope="row">Dictation</th><td>Hold Alt+Space</td><td>Bind <code>lokalbot dictate</code> to a shortcut in your desktop's settings</td></tr>
              <tr><th scope="row">Autocomplete in other apps</th><td>Yes</td><td>Only in the practice editor in Settings</td></tr>
            </tbody>
          </table>
        </div>

        <h2>Models on Windows and Linux</h2>
        <p>The Windows and Linux app has its own defaults:</p>
        <ul>
          <li><strong>Transcription:</strong> Qwen3-ASR 0.6B, with Parakeet v3, SenseVoice, and Whisper turbo as options.</li>
          <li><strong>Speakers:</strong> pyannote segmentation with TitaNet embeddings.</li>
          <li><strong>Autocomplete:</strong> LFM2.5 1.2B.</li>
          <li><strong>Summaries and search:</strong> Qwen3.5 4B and EmbeddingGemma 2, the same as on a Mac.</li>
          <li><strong>Screen text:</strong> accessibility (UI Automation on Windows, AT-SPI on Linux) plus on-device OCR, downloaded on request.</li>
        </ul>
        <p>The <a href="benchmarks">benchmarks</a> were measured on a Mac, so these engines have not been benchmarked yet.</p>

        <h2>Mac only for now</h2>
        <p>The Windows and Linux app has the same pages and reads the same library, but these features haven't been ported yet:</p>
        <ul>
          <li>Selection actions (⌃⇧ W)</li>
          <li>Meeting note export and daily memory notes for Obsidian and Logseq</li>
          <li>Personal Context</li>
          <li>Spoken summaries</li>
          <li>Coding-agent sessions in day memory</li>
          <li>Remember speakers (voice profiles)</li>
          <li>Apple Intelligence</li>
          <li>Granite Speech and GigaAM transcription</li>
        </ul>

        <h2>Before an important meeting</h2>
        <ol>
          <li>Install the latest release and finish the selected model downloads.</li>
          <li>On a Mac, confirm the required macOS permissions in System Settings.</li>
          <li>Make a short recording in the actual meeting application.</li>
          <li>Play back both the microphone and system-audio tracks.</li>
          <li>Process the recording once, offline if offline use matters.</li>
        </ol>
        """,
        "faq": [
            ("Does LokalBot support Intel Macs?", "No. Apple Silicon (M1 or later) is required."),
            ("Does it support macOS 14?", "No. The minimum supported version is macOS 15.0."),
            ("Do I need 32 GB of memory?", "No. Smaller models run on lower-memory Apple Silicon Macs and PCs. The 32 GB recommendation applies to the largest local language-model choices."),
            ("Does it run on Windows on ARM or ARM Linux?", "No. The Windows and Linux versions are built only for x64 (x86_64) processors."),
            ("Can I move my library between a Mac and a PC?", "Yes. The Mac, Windows, and Linux apps use the same library format, so a library recorded on one opens on the others. It lives in ~/Library/Application Support/me.dotenv.LokalBot on a Mac, %LOCALAPPDATA%\\LokalBot on Windows, and ~/.local/share/LokalBot on Linux."),
        ],
        "related": ["local-ai-meeting-notes-linux", "local-ai-meeting-notes-windows", "local-ai-meeting-notes-mac"],
    },
    {
        "slug": "granola-otter-alternatives-linux-windows",
        "kind": "question",
        "published": "2026-10-26",
        "updated": "2026-10-26",
        "updated_label": "October 26, 2026",
        "title": "Granola and Otter Alternatives for Linux and Windows",
        "description": "Granola has no Linux app, and Otter and Fireflies offer Linux only a web app. Which bot-free meeting notetakers run on Linux and Windows, where they transcribe, and how they're licensed.",
        "eyebrow": "Linux and Windows",
        "h1": "Is there a Granola or Otter alternative for Linux and Windows?",
        "lead": "Yes. Granola has no Linux app, and Otter and Fireflies give Linux users only a web app and a browser extension. Several apps record meetings without a bot on Linux and Windows, but they differ a lot on where your audio is transcribed.",
        "read_time": "5 min read",
        "body": """
        <h2>The options, side by side</h2>
        <p>Checked against each project's own site, documentation, and releases on October 26, 2026:</p>
        <div class="guide-table-wrap">
          <table class="guide-table">
            <thead><tr><th scope="col">App</th><th scope="col">Linux</th><th scope="col">Windows</th><th scope="col">Transcription</th><th scope="col">License</th></tr></thead>
            <tbody>
              <tr><th scope="row">LokalBot</th><td>Native app, alpha: .deb, .rpm, Arch package, or archive</td><td>Native app, alpha</td><td>On your computer by default</td><td>GPLv3</td></tr>
              <tr><th scope="row"><a href="lokalbot-vs-openwhispr">OpenWhispr</a></th><td>Native app: AppImage, .deb, .rpm, or archive</td><td>Native app</td><td>On your device or in the cloud; setup recommends its cloud</td><td>MIT</td></tr>
              <tr><th scope="row"><a href="lokalbot-vs-hyprnote">Anarlog</a> (formerly Hyprnote)</th><td>Native app, beta</td><td>Native app, beta</td><td>On your device only on Macs; elsewhere a cloud service or a server you run</td><td>MIT, with commercial enterprise parts</td></tr>
              <tr><th scope="row"><a href="lokalbot-vs-meetily">Meetily</a></th><td>Build from source; a Pro Linux app is in development</td><td>Native app</td><td>On your device</td><td>MIT for the Community Edition; Pro is commercial</td></tr>
              <tr><th scope="row"><a href="lokalbot-vs-screenpipe">Screenpipe</a></th><td>AppImage</td><td>Native app</td><td>On your device by default</td><td>Source-available; commercial use needs a license</td></tr>
              <tr><th scope="row"><a href="lokalbot-vs-granola">Granola</a></th><td>None; the web app can't record</td><td>Native app</td><td>Cloud</td><td>Proprietary</td></tr>
              <tr><th scope="row"><a href="lokalbot-vs-otter">Otter</a></th><td>Web app and Chrome extension</td><td>Native app</td><td>Cloud</td><td>Proprietary</td></tr>
              <tr><th scope="row"><a href="lokalbot-vs-fireflies">Fireflies</a></th><td>Web app and Chrome extension</td><td>Native app</td><td>Cloud</td><td>Proprietary</td></tr>
            </tbody>
          </table>
        </div>
        <p>All of them can record without a bot joining the call. Otter and Fireflies send a notetaker bot by default; their desktop apps and browser extensions record without one.</p>

        <h2>What to check before you choose</h2>
        <ul>
          <li><strong>Where transcription runs by default.</strong> Some apps are local only on a Mac, and some recommend their cloud during setup. If audio must stay on your computer, check the setting for meetings, dictation, and file uploads separately.</li>
          <li><strong>What's free.</strong> Speaker labels, meeting detection, longer meetings, and MCP access for AI tools are paid features in some apps.</li>
          <li><strong>How agents reach your notes.</strong> A local MCP server reads the library on your computer. A hosted one needs your notes in the vendor's cloud.</li>
          <li><strong>Open source or source-available.</strong> MIT and GPLv3 let anyone use, change, and share the code; a source-available license can restrict commercial use.</li>
          <li><strong>Your desktop.</strong> On Linux, Wayland limits what any app can do with global shortcuts, typing into other apps, and screen capture. Check what works on your desktop before you rely on it.</li>
        </ul>

        <h2>Where LokalBot fits</h2>
        <p>LokalBot records, transcribes, and summarizes on your computer by default, and asks before any context goes to a remote server. Speaker separation, meeting detection, cited answers, and a local read-only MCP server are free, and the same app keeps a timeline of your day, dictation, and autocomplete. Its Windows and Linux apps are in alpha: see <a href="local-ai-meeting-notes-linux">Linux</a> and <a href="local-ai-meeting-notes-windows">Windows</a> for what works today.</p>
        """,
        "faq": [
            ("Does Granola work on Linux?", "No. Granola's apps are for Mac, Windows, iPhone, and Android. Its web app can view and edit notes but can't record or transcribe a meeting."),
            ("Can I use Otter or Fireflies on Linux?", "Only through their web apps and Chrome extensions. Their desktop apps are for Windows and Mac, their notetakers join calls as a bot unless you record from the desktop app or the extension, and transcription happens in their cloud."),
            ("Which open-source apps transcribe locally on Linux?", "LokalBot and OpenWhispr both transcribe on a Linux computer; with OpenWhispr, choose on-device transcription during setup. Meetily transcribes locally too, but on Linux you build it from source. Anarlog's Linux beta transcribes in the cloud or on a server you run. Screenpipe transcribes locally by default, under a source-available license."),
        ],
        "related": ["local-ai-meeting-notes-linux", "local-ai-meeting-notes-windows", "open-source-ai-meeting-notes"],
    },
    {
        "slug": "claude-code-codex-meeting-notes",
        "kind": "question",
        "published": "2026-10-14",
        "updated": "2026-11-01",
        "updated_label": "October 31, 2026",
        "title": "Let Claude Code or Codex Search Your Meeting Notes",
        "description": "Give Claude Code, Codex, or another MCP client read-only access to meetings recorded and transcribed on your computer, with no cloud notetaker or meeting bot.",
        "eyebrow": "Agents and MCP",
        "h1": "How do I let Claude Code or Codex search my meeting notes?",
        "lead": "Keep the meetings on your computer and give the agent a local, read-only way in. LokalBot records and transcribes calls on-device and includes an MCP server: turn on agent access, add it to Claude Code or Codex, and the agent can search, read, and ask about your meetings without a notetaker bot or a cloud account.",
        "read_time": "5 min read",
        "body": """
        <h2>Three pieces, all on your computer</h2>
        <p>An agent can only answer “what did we decide about the launch date?” if it can reach the conversation. The usual route is a cloud notetaker: a bot or app sends the audio to a vendor, and the vendor's connector hands transcripts to the agent. A local setup replaces each step:</p>
        <ol>
          <li><strong>Capture without a bot.</strong> LokalBot records your microphone and the meeting app's audio on separate tracks. Nothing joins the call.</li>
          <li><strong>Transcribe and index on-device.</strong> Speech recognition, summaries, and the search index run on your computer and stay in a local library.</li>
          <li><strong>Open it read-only.</strong> The bundled <code>lokalbot-cli</code> is both a command-line tool and an MCP server that your agent starts on your computer over stdio. It is off until you turn it on.</li>
        </ol>

        <h2>Set it up</h2>
        <ol>
          <li>Install LokalBot, let the models download, and record a short test meeting.</li>
          <li>On a Mac, in <strong>Settings → External Agents</strong>, turn on <strong>Allow external agents to read your LokalBot data</strong> and keep <strong>Meetings</strong> ticked. On Windows and Linux, turn on <strong>Allow external agents to read your meeting library</strong> in <strong>Settings → Privacy &amp; Data</strong>.</li>
          <li>In <strong>Settings → External Agents → Agent CLI</strong> on a Mac, or <strong>Settings → Advanced → Agent CLI</strong> on Windows and Linux, choose <strong>Install for your coding agent…</strong>. It installs a skill that explains the commands to agents and puts <code>lokalbot-cli</code> in <code>~/.local/bin</code> on a Mac or Linux. On Windows it goes in <code>%LOCALAPPDATA%\\Programs\\LokalBot\\bin</code>; add that folder to your PATH.</li>
          <li>Register the MCP server with your agent:</li>
        </ol>
        <pre class="code" aria-label="Add LokalBot's MCP server to Claude Code or Codex"><span class="c-op"># Claude Code</span>
<span class="c-prompt">$</span> claude mcp add lokalbot <span class="c-op">--</span> lokalbot-cli mcp

<span class="c-op"># Codex</span>
<span class="c-prompt">$</span> codex mcp add lokalbot <span class="c-op">--</span> lokalbot-cli mcp</pre>
        <p>These commands work on Mac, Windows, and Linux once <code>lokalbot-cli</code> is on your PATH. Otherwise, use its full path, such as <code>/Applications/LokalBot.app/Contents/Helpers/lokalbot-cli</code> on a Mac. The Windows and Linux versions (alpha) have the same MCP tools as the Mac, except file search.</p>
        <p>In Claude Code you can install the LokalBot plugin instead. It adds the same server and a <code>/lokalbot:recall</code> command: run <code>/plugin marketplace add stevyhacker/lokalbot</code>, then <code>/plugin install lokalbot@lokalbot</code>. Other MCP clients that can start a local command, such as Cursor, use the same <code>lokalbot-cli mcp</code>.</p>

        <h2>What the agent can do</h2>
        <ul>
          <li><strong>Find meetings.</strong> <code>list_meetings</code> filters by date and title, and <code>search_meetings</code> searches titles, summaries, and transcripts by word.</li>
          <li><strong>Read one.</strong> <code>get_meeting</code> returns a meeting's metadata, summary, or transcript as Markdown, so the agent can ask for just the summary.</li>
          <li><strong>Ask a question.</strong> <code>ask_library</code> has LokalBot's local model answer from your library, with meeting citations. The agent gets the answer instead of raw transcripts, which also keeps long calls out of its context window. The LokalBot app must be running, and the first answer can take up to a minute while the model loads.</li>
          <li><strong>Follow up.</strong> <code>get_action_items</code> lists open actions with your corrections applied, and <code>list_people</code> shows who you meet, by name only. Email addresses are never returned.</li>
        </ul>
        <p>An agent without MCP can run the same commands in a shell. For example, <code>lokalbot-cli search "pricing decision"</code> prints matching meetings as JSON.</p>
        <p>Screen memory has its own permission: on a Mac, the <strong>Screen memory</strong> box under the same switch; on Windows and Linux, a second toggle, <strong>Allow external agents to read screen memory</strong>. It grants today, the last seven days, or all retained history. Those tools return captured text and metadata, never screenshot pixels.</p>
        <p>On a Mac, the <strong>Files</strong> box lets the agent search the folders you chose under Files with <code>search_files</code>, by their words. It gets each matching file's path, a short excerpt, and the passage that matched. LokalBot never changes the files.</p>

        <h2>Where your meetings go once an agent reads them</h2>
        <p>LokalBot doesn't upload your library, and its agent access is read-only, so the agent can't change or delete meetings. But whatever a tool returns becomes part of the agent's conversation, and Claude Code and Codex send that conversation to Anthropic or OpenAI under their own terms. Treat it like pasting the text in yourself:</p>
        <ul>
          <li>Prefer <code>search_meetings</code> and <code>ask_library</code> to pulling whole transcripts.</li>
          <li>Turn access on only for agents you trust with that content, tick only what they need, and turn the switch off to cut access again.</li>
          <li>The switch controls LokalBot's CLI and MCP server. An agent that can run shell commands as you can also read any file your account can, so use the agent's own permission settings to limit file access.</li>
        </ul>
        """,
        "faq": [
            ("Does the agent get my audio?", "No. The MCP tools return text: meeting metadata, summaries, transcripts, action items, names, and answers. They don't return audio."),
            ("Can the agent edit or delete meetings?", "No. The CLI and MCP server are read-only. Changes happen in the LokalBot app."),
            ("Does this work with other MCP clients?", "Yes. Any MCP client that can start a local command can run lokalbot-cli mcp, for example Cursor. Each client's own data handling applies."),
        ],
        "related": ["local-ai-meeting-notes-mac", "open-source-ai-meeting-notes", "ai-notetaker-bots-blocked-at-work"],
    },
    {
        "slug": "ai-notetaker-bots-blocked-at-work",
        "kind": "question",
        "published": "2026-10-14",
        "updated": "2026-10-20",
        "updated_label": "October 20, 2026",
        "title": "AI Notetaker Bots Blocked at Work? What IT Should Check",
        "description": "Why companies block meeting bots, what a bot-free local recorder changes and what it doesn't, and a checklist IT can use before approving one.",
        "eyebrow": "IT approval",
        "h1": "My company blocks AI notetaker bots. What can I use?",
        "lead": "Start by asking what the policy forbids. Most bans target bots that join calls and services that keep recordings in a vendor's cloud. A recorder that runs on your computer avoids both, but it still records people, so it needs the same approval and the same notice to participants. Here is what IT should check before saying yes.",
        "read_time": "5 min read",
        "body": """
        <h2>Why the bots get blocked</h2>
        <p>A notetaker bot is a separate participant. It is often added through calendar access, can join meetings its owner doesn't attend, shows up in client and partner calls, and sends the audio to the vendor's servers, where retention and model-training terms are the vendor's to set. Meeting platforms let admins block or flag these bots, and many companies now do.</p>

        <h2>What a local recorder changes, and what it doesn't</h2>
        <div class="guide-table-wrap">
          <table class="guide-table">
            <thead><tr><th scope="col"></th><th scope="col">Notetaker bot</th><th scope="col">Recorder on your computer</th></tr></thead>
            <tbody>
              <tr><th scope="row">Joins the call</th><td>Yes, as a participant</td><td>No</td></tr>
              <tr><th scope="row">Where audio is processed</th><td>The vendor's servers</td><td>Your computer</td></tr>
              <tr><th scope="row">Account and retention</th><td>A vendor account, under the vendor's terms</td><td>No account; local files under your settings</td></tr>
              <tr><th scope="row">Visible to other participants</th><td>Usually, by name</td><td>No, so you have to tell them</td></tr>
              <tr><th scope="row">Visible to meeting admins</th><td>Yes</td><td>No</td></tr>
            </tbody>
          </table>
        </div>
        <p>The last two rows matter. A recorder nobody can see is not a way around a ban, and using one where recording isn't allowed breaks the same rules a bot would. Recording laws and client contracts apply either way. If the policy is about recording itself, no tool changes the answer.</p>

        <h2>A checklist IT can work through</h2>
        <p>Using LokalBot as the example:</p>
        <ol>
          <li><strong>Where does meeting audio go?</strong> With the built-in models, recording, transcription, summaries, and search run on the computer. To verify it, download the models, select the built-in backend, turn off automatic update checks, and watch network traffic while you record, transcribe, and summarize.</li>
          <li><strong>What else uses the network?</strong> Model downloads from Hugging Face or the model's publisher, update checks against GitHub Releases (which can be turned off), and any remote model server a user configures. On Windows and Linux, the app also downloads a pinned llama.cpp runtime from GitHub once. A server off the computer receives meeting context only after the user approves that exact origin.</li>
          <li><strong>Accounts and telemetry.</strong> None. There is no sign-in, analytics service, or telemetry backend.</li>
          <li><strong>Storage.</strong> Recordings, transcripts, and the search index are ordinary files and SQLite under the user's account, so disk encryption (FileVault, BitLocker, or LUKS) and your device policies protect them at rest. Day tracking saves app names and window titles by default; screen text and encrypted screenshots are separate opt-ins that expire after 14 days by default.</li>
          <li><strong>Consent behavior.</strong> On a fresh install, LokalBot asks through a notification before it records a detected meeting. Automatic recording is a setting the user has to turn on.</li>
          <li><strong>Ways data can leave.</strong> Markdown exports, and on a Mac the Obsidian and Logseq note exports, are plain files in a folder the user picks. Agent access through the CLI and MCP server, and the optional Agent Mode, are off by default; once enabled, an agent's own provider receives what the agent reads.</li>
          <li><strong>Code and builds.</strong> The source is public under GPLv3. Mac releases are signed with a Developer ID and notarized by Apple, and install from the DMG or Homebrew. The Windows build (alpha) is a per-user installer or a portable zip, neither code-signed yet, so SmartScreen warns before it runs. The Linux build (alpha) comes as .deb, .rpm and Arch packages or an archive with an install script. On every platform, updates are signed and install only when the user chooses Install and Relaunch. Any version can be built from source.</li>
        </ol>

        <h2>What it doesn't have</h2>
        <ul>
          <li><strong>Central administration.</strong> There is no admin console, central policy, or documented managed settings. Each user configures their own copy, so control comes from your device management: allow or block the app, require disk encryption, and set backup rules.</li>
          <li><strong>Stable Windows and Linux releases.</strong> The Mac app needs Apple Silicon and macOS 15 or later. The Windows 10 and 11 (x64) and Linux (x86_64) versions are in alpha: the Windows build isn't code-signed yet, and a few Mac features haven't been ported. See the <a href="system-requirements">system requirements</a>.</li>
          <li><strong>A shared workspace.</strong> Notes stay on one computer unless the user exports them.</li>
        </ul>

        <h2>Asking for approval</h2>
        <p>Send IT the <a href="privacy">privacy policy</a>, the <a href="https://github.com/stevyhacker/lokalbot" target="_blank" rel="noopener">source repository</a>, and this checklist, and offer to run the network test together on a short call. Once it's approved, tell people when you record, the same way you would if a bot were in the meeting.</p>
        """,
        "faq": [
            ("Will Teams, Zoom, or Meet show that LokalBot is recording?", "No. It doesn't join the call, so the meeting app has no participant to show. That is why telling people is up to you."),
            ("Is a local recorder allowed if my company bans AI notetakers?", "Only if the policy allows it, so ask IT or your manager. A local recorder changes where the data goes, not the fact that people are being recorded."),
            ("Can IT confirm that meetings never leave the computer?", "Yes. The source code is public, and the network test above shows what the app connects to while it records, transcribes, and summarizes with the built-in models."),
        ],
        "related": ["record-both-sides-mac-meeting-without-bot", "open-source-ai-meeting-notes", "bot-free-meeting-recorder-speaker-labels"],
    },
    {
        "slug": "bot-free-meeting-recorder-speaker-labels",
        "kind": "question",
        "published": "2026-10-14",
        "updated": "2026-10-20",
        "updated_label": "October 20, 2026",
        "title": "Can a Bot-Free Meeting Recorder Tell Who Said What?",
        "description": "How a recorder that never joins the call separates speakers, where the names come from, and measured speaker-separation accuracy for LokalBot on Mac.",
        "eyebrow": "Speaker labels",
        "h1": "Can a bot-free meeting recorder tell who said what?",
        "lead": "Partly. A recorder that doesn't join the call can't see the meeting app's participant list, so it doesn't know names on its own. It can tell your microphone from the call audio and separate the distinct voices in each, and then you put a name on each voice. LokalBot does all of this on your computer.",
        "read_time": "5 min read",
        "body": """
        <h2>Why bots know names and local recorders don't</h2>
        <p>A meeting bot is a participant, so the meeting platform can tell it who is talking. A bot-free recorder hears what your computer hears: your microphone, and the meeting app's audio with every remote participant mixed into one stream. To split that stream it has to group voices by how they sound, which is called speaker diarization. Diarization can say “three different people spoke, and here is when,” but not who they are.</p>

        <h2>How LokalBot labels speakers</h2>
        <ol>
          <li><strong>Two tracks first.</strong> Your microphone and the call audio are recorded separately, so your side and the call stay apart before any model runs. By default, speech on the microphone counts as yours (<strong>My microphone is me</strong>), which also puts your commitments first in action items.</li>
          <li><strong>Voices within each track.</strong> After the meeting, <strong>Separate voices by speaker</strong>, on by default, groups the voices in both tracks on your computer. New Mac installs use Nemotron 3; Windows and Linux (alpha) use pyannote segmentation with TitaNet embeddings.</li>
          <li><strong>Names from you.</strong> When you rename a speaker, calendar attendees appear as suggestions. They stay suggestions: even a one-on-one invite doesn't prove who spoke, so LokalBot never applies a calendar name on its own.</li>
          <li><strong>Voices on this Mac, remembered.</strong> On a Mac, the optional <strong>Remember speakers on this Mac</strong> setting can suggest names for voices you've confirmed on this Mac's microphone in later recordings. Remote participants' voices are never enrolled or matched, so you name them in each meeting. This setting is Mac only for now.</li>
        </ol>
        <p>All of these settings are in <strong>Settings → Meetings → Speaker names</strong>.</p>

        <h2>How accurate is it?</h2>
        <p>The test ran on a Mac and used four public AMI meeting recordings, each scored twice (headset mix and distant microphone), for 184.55 minutes of audio with four speakers per meeting. Nemotron 3 had a 14.6% diarization error rate with no forgiveness collar, against 43.4% for the previous default, Pyannote Community-1. It found the right number of speakers in all eight cases and ran about 500 times faster than real time. The error rate adds up missed speech, false alarms, and speech credited to the wrong person. See the <a href="benchmarks">benchmarks</a> for methods and raw results.</p>
        <p>The test has limits: English only, four speakers, and meeting-room recordings rather than audio that went through a video call. Larger calls, other languages, and the speaker models used on Windows and Linux haven't been measured.</p>

        <h2>When labels go wrong</h2>
        <ul>
          <li><strong>Several people on one microphone.</strong> In a meeting room, turn off <strong>My microphone is me</strong> so the room's voices are separated instead of all counted as yours.</li>
          <li><strong>Speakers instead of headphones.</strong> Call audio leaks into your microphone and can land on your side of the transcript. Headphones keep the tracks clean.</li>
          <li><strong>Crosstalk and short replies.</strong> Overlapping speech and one-word answers are the hardest parts for any diarization model.</li>
          <li><strong>Big calls.</strong> Every remote voice shares one track, and more voices mean more chances to merge two people or split one.</li>
        </ul>
        <p>When a label is wrong, correct it in the transcript. Your names and corrections stay with the meeting.</p>
        """,
        "faq": [
            ("Does LokalBot read participant names from Zoom, Meet, or Teams?", "No. It doesn't read the meeting app's participant list or who is speaking. Names come from you, with calendar attendees offered as suggestions."),
            ("Does speaker separation upload audio?", "No. It runs on your computer. The speaker model downloads once on first use. On a Mac with Qwen3-ASR, a word-timing model of about 1 GB downloads too."),
            ("Can I turn speaker separation off?", "Yes. Turn off Separate voices by speaker in Settings → Meetings → Speaker names. Your microphone and the call audio stay on separate tracks either way."),
        ],
        "related": ["record-both-sides-mac-meeting-without-bot", "local-transcription-models-mac", "claude-code-codex-meeting-notes"],
    },
    {
        "slug": "meeting-transcripts-obsidian-markdown",
        "kind": "question",
        "published": "2026-10-14",
        "updated": "2026-11-01",
        "updated_label": "October 31, 2026",
        "title": "How to Get Meeting Transcripts into Obsidian as Markdown",
        "description": "Put local meeting transcripts and summaries into an Obsidian vault as Markdown: a note for every meeting, a one-off export, a daily note, or your own script.",
        "eyebrow": "Obsidian and Markdown",
        "h1": "How do I get meeting transcripts into Obsidian as Markdown?",
        "lead": "Record and transcribe on your Mac, and LokalBot can write a note for each meeting straight into your vault: the summary, the action items, the people and projects involved as links, and the transcript. You can also export one meeting at a time, add a daily note, or write the notes with your own script. Note export and the daily note are Mac only for now; on Windows and Linux (alpha), export one meeting at a time or use the script.",
        "read_time": "5 min read",
        "body": """
        <h2>Why plain files work best</h2>
        <p>An Obsidian vault is a folder of Markdown files. Anything that writes a <code>.md</code> file into that folder can feed it, and the notes keep working without an account, a plugin, or a sync service in between. If the transcript is a file you own, nothing upstream can change how you get to it.</p>

        <h2>Option 1: a note for every meeting (Mac)</h2>
        <p>In <strong>Settings → Meetings → Meeting note export</strong>, turn on <strong>Export a note for each meeting</strong>, pick a folder in your vault, and set the format to <strong>Obsidian</strong>. LokalBot writes one note per meeting, including meetings you recorded before turning it on, named like <code>2026-10-14 Atlas release sync (4f7c2a91).md</code>.</p>
        <p>Each note starts with properties: date, time, duration, meeting app, and the people and tracked projects involved as <code>[[links]]</code>, so they show up in backlinks and the graph. Then come the summary, the action items as checkboxes with the ones you finished checked off, and the transcript, unless you turn off <strong>Include the transcript</strong>. Detected passwords and keys are redacted.</p>
        <p>Notes stay current: marking an action done, renaming a speaker, or regenerating a summary updates the note. A note keeps its first name when you rename the meeting, so your links to it keep working. Once you edit, move, or delete a note, it is yours: LokalBot leaves it alone and does not write that meeting again.</p>

        <h2>Option 2: export one meeting</h2>
        <p>Open a meeting and choose <strong>Export → Export Meeting as Markdown…</strong>, then save it into your vault. The file starts with the title, date, duration, and meeting app, followed by the summary and the full transcript. <strong>Copy Meeting as Markdown</strong> puts the same text on the clipboard. This is fine for the occasional meeting and tedious for every one.</p>

        <h2>Option 3: a daily note in Obsidian format (Mac)</h2>
        <p>In <strong>Settings → Daily Review → Daily note export</strong>, turn on <strong>Export a daily memory note</strong>, pick a folder in your vault, and set the format to <strong>Obsidian</strong>. Each evening (6 PM by default) LokalBot writes or refreshes one note for the day, with <code>date</code> and <code>tags</code> properties: the day's digest, a list of its meetings, app time, and saved moments. A day missed while the Mac was asleep is written later. If you edit a generated note, LokalBot keeps your edits and pauses the export until you move that note or choose another folder.</p>
        <p>The daily note lists meetings by time, title, and ID. It doesn't include their transcripts, so pair it with option 1 if you want the full text in the vault.</p>

        <h2>Option 4: your own script</h2>
        <p>If you want a different layout, the bundled <code>lokalbot-cli</code> prints any meeting as Markdown, so a few lines of shell can write the notes instead. The CLI is read-only and checks the same switch agents do, so first turn it on: on a Mac, <strong>Allow external agents to read your LokalBot data</strong> in <strong>Settings → External Agents</strong>, with <strong>Meetings</strong> ticked; on Windows and Linux, <strong>Allow external agents to read your meeting library</strong> in <strong>Settings → Privacy &amp; Data</strong>. Then install the CLI from <strong>Settings → External Agents → Agent CLI</strong> on a Mac or <strong>Settings → Advanced → Agent CLI</strong> on Windows and Linux, save this as <code>lokalbot-to-obsidian.sh</code>, change the folder, and run it with <code>sh lokalbot-to-obsidian.sh</code>:</p>
        <pre class="code" aria-label="Shell script that writes each LokalBot meeting into an Obsidian vault"><span class="c-op"># Folder inside your vault</span>
vault=<span class="c-str">"$HOME/Documents/Obsidian/Meetings"</span>
mkdir -p <span class="c-str">"$vault"</span>

lokalbot-cli list <span class="c-op">\\</span>
  <span class="c-op">|</span> jq -r <span class="c-str">'.[] | select(.has_summary) | "\\(.id) \\(.date | fromdateiso8601 | strflocaltime("%Y-%m-%d"))"'</span> <span class="c-op">\\</span>
  <span class="c-op">|</span> while read -r id day; do
      note=<span class="c-str">"$vault/$day $id.md"</span>
      [ -e <span class="c-str">"$note"</span> ] <span class="c-op">||</span> lokalbot-cli get <span class="c-str">"$id"</span> <span class="c-op">&gt;</span> <span class="c-str">"$note"</span>
    done</pre>
        <p>It uses <code>jq</code>, which ships with macOS 15 and later. On Linux, install jq with your package manager. On Windows, run the script in Git Bash with jq installed. Each meeting is written once its summary is ready, as a note named like <code>2026-10-14 ab12cd.md</code>. Existing notes are never overwritten, so edits you make in Obsidian are safe; delete a note to have it written again, for example after you regenerate a summary. Run the script after meetings, or from a scheduled job if you want it hands-off.</p>

        <h2>Things to know</h2>
        <ul>
          <li><strong>Exports are ordinary files.</strong> LokalBot doesn't encrypt them, and if you sync the vault with Obsidian Sync, iCloud, or Git, that service's terms now cover your transcripts too.</li>
          <li><strong>Nothing syncs back.</strong> Editing a note in Obsidian doesn't change the meeting in LokalBot, and deleting a meeting in LokalBot leaves its note in the vault.</li>
          <li><strong>The vault is readable by your other tools.</strong> Any app or agent with access to that folder can read the transcripts, so keep sensitive meetings out of shared vaults, or turn off <strong>Include the transcript</strong>.</li>
        </ul>
        """,
        "faq": [
            ("Is there an Obsidian plugin for LokalBot?", "No, and you don't need one. On a Mac, LokalBot writes a note for each meeting straight into a folder in your vault, so nothing needs installing in Obsidian. On Windows and Linux, export meetings one at a time or use the script above."),
            ("Do the exported transcripts include speaker names?", "Yes. Each transcript line starts with a timestamp and the speaker's name, or a default label such as Me when you haven't named that speaker."),
            ("Can I use Logseq instead?", "Yes, with Logseq OG, which keeps a graph as Markdown files. On a Mac, meeting notes and the daily note both come in a Logseq format, with page properties and TODO and DONE actions; choose your graph's pages folder for meeting notes. Logseq's newer database version imports Markdown instead of reading a folder, so it won't pick up new notes on its own."),
        ],
        "related": ["claude-code-codex-meeting-notes", "local-ai-meeting-notes-mac", "open-source-ai-meeting-notes"],
    },
]

# Hand-written reference pages (web/about.html, web/benchmarks.html). The
# renderer lists them on /guides and in the sitemap but does not generate them,
# so bump "updated" here whenever you edit one of those pages.
REFERENCES = [
    {
        "slug": "about",
        "eyebrow": "Fact sheet",
        "h1": "About LokalBot",
        "description": "What LokalBot is, what it runs, and what it does not do: a free, open-source app for bot-free meeting notes, local transcription, and search on Mac, with Windows and Linux in alpha.",
        "updated": "2026-10-26",
    },
    {
        "slug": "benchmarks",
        "eyebrow": "Benchmarks",
        "h1": "LokalBot local model benchmarks",
        "description": "Measured speech recognition, speaker diarization, semantic search, summary, autocomplete, and OCR results for LokalBot's local models on Apple Silicon, with methods, sources, and known gaps.",
        "updated": "2026-10-26",
    },
]
