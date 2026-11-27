"""Source-backed guide content for LokalBot's search-intent pages.

Rendered by Website/generator/render_web.py. Keep claims aligned with the checked-in
README and implementation; these pages intentionally avoid competitor claims.
A guide with "kind": "question" is listed under Questions on /guides, and one
with "kind": "compare" under Compare. The AI assistants comparison lives in
Website/generator/assistant_roundup.py.
"""

from assistant_roundup import ROUNDUP
from meeting_notes_roundup import MEETING_NOTES_ROUNDUP

GUIDES_INDEX = {
    "title": "LokalBot Guides: Private AI Meeting Notes on Your Computer",
    "description": "Practical guides to local AI meeting notes, offline transcription, bot-free recording, open-source privacy, model choice, requirements, and comparisons.",
}

GUIDES = [
    {
        "slug": "local-ai-meeting-notes-mac",
        "updated": "2026-10-20",
        "updated_label": "October 20, 2026",
        "title": "Local AI Meeting Notes for Mac: A Practical Guide",
        "description": "How local AI meeting notes work on a Mac: bot-free capture, on-device transcription, private summaries, trade-offs, and setup.",
        "eyebrow": "Local meeting notes",
        "h1": "Local AI meeting notes on your Mac",
        "lead": "A practical guide to recording, transcribing, and summarizing meetings with models that run on your Mac by default: without sending a bot into the call.",
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
        "updated": "2026-11-26",
        "updated_label": "November 26, 2026",
        "title": "Local AI Meeting Notes on Linux: Bot-Free & Open Source",
        "description": "Record, transcribe, and summarize meetings on Linux without a bot or cloud: X11 and Wayland support, apt/dnf/pacman install, and local models.",
        "eyebrow": "Linux",
        "h1": "Local AI meeting notes on Linux",
        "lead": "LokalBot records both sides of a call without a bot, transcribes and summarizes it with models on your computer, and keeps every meeting searchable. Here is what works on Linux, what depends on your desktop, and how to install it.",
        "read_time": "6 min read",
        "body": """
        <h2>What works on Linux</h2>
        <p>LokalBot for Linux is a native app written in Rust with GPUI, the UI framework behind the Zed editor. It has the same pages as the Mac app (Today, Meetings, Timeline, People, Projects, Ask, and Settings) and reads the same library format, so a library recorded on a Mac opens on Linux. It's an alpha.</p>
        <ul>
          <li><strong>Meetings without a bot.</strong> LokalBot records your microphone and the meeting app's own audio streams through PulseAudio or PipeWire, so nothing joins the call. When it can't separate the app, the second track comes from the output monitor, so it holds everything your computer plays. When it detects a meeting, it asks with a notification.</li>
          <li><strong>On-device transcription.</strong> Qwen3-ASR 0.6B through sherpa-onnx by default, with Parakeet v3 and v2, SenseVoice, GigaAM for Russian, and Whisper turbo as options. Speakers are separated with pyannote segmentation and TitaNet.</li>
          <li><strong>Notes and Ask.</strong> Summaries, decisions, action items, and answers with citations come from Qwen3.5 4B in the built-in llama.cpp, or from Ollama, an OpenAI-compatible server you approve, or your ChatGPT or Claude plan.</li>
          <li><strong>Search.</strong> Keyword and meaning search across your meetings, with SQLite full-text search and EmbeddingGemma 2, plus Quick Recall from a shortcut.</li>
          <li><strong>Agent access.</strong> A read-only CLI and MCP server lets Claude Code, Codex, and other agents search your meetings, off until you allow it.</li>
          <li><strong>Selection actions.</strong> Turn them on in <strong>Settings > General</strong>, select text in any app, and press <kbd>Ctrl+Alt+Space</kbd> to fix the grammar, shorten it, translate it, or draft a reply from what your meetings say. Apps without accessibility get results you can copy but not replace in place.</li>
          <li><strong>Spoken summaries.</strong> Hear summaries and answers read aloud, or export a WAV, with Kokoro 82M on your computer.</li>
          <li><strong>Overnight review and Personal Context.</strong> LokalBot reviews your day overnight, waiting for mains power, and keeps the facts, preferences, goals, and principles you give it. Agents read only the items you choose to share.</li>
          <li><strong>Files.</strong> Search folders you choose by words and meaning, off until you turn it on. Scanned PDF pages are read only when stored as JPEG or plain raster, <code>.doc</code> and RAW files aren't read, and video frames, HEIC, and AVIF need ffmpeg.</li>
          <li><strong>Exports and coding sessions.</strong> Keep a Markdown note for every meeting and a daily note in your Obsidian or Logseq folder. Coding-agent sessions join day memory only after you choose that in setup or <strong>Settings > Day Memory</strong>.</li>
          <li><strong>Phones and tablets.</strong> LokalBot can share your meetings and day with your own devices, off until you turn it on in <strong>Settings > Phones &amp; tablets</strong>. Pair an iPhone or iPad with the <a href="https://apps.apple.com/app/id6836773709" target="_blank" rel="noopener">app on the App Store</a>, or an Android phone or tablet with the <a href="https://play.google.com/store/apps/details?id=me.dotenv.lokalbot.companion" target="_blank" rel="noopener">app on Google Play</a>. A firewall must allow TCP port 17890.</li>
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
              <tr><th scope="row">Selection actions</th><td>Yes</td><td>Bind <code>lokalbot selection-actions</code> to a shortcut in your compositor</td></tr>
              <tr><th scope="row">Autocomplete in other apps</th><td>GTK apps; Qt, Chromium, Electron, and Firefox once system accessibility is on</td><td>As an input method on Sway, Hyprland, GNOME, and KDE Plasma; elsewhere only in the practice editor in Settings</td></tr>
              <tr><th scope="row">Tray icon</th><td colspan="2">Yes; GNOME needs the AppIndicator extension</td></tr>
            </tbody>
          </table>
        </div>
        <p>On <a href="/blog/windows-and-linux-alpha">Omarchy and other Hyprland desktops</a>, <code>grim</code>, <code>wtype</code>, <code>wl-clipboard</code>, and PipeWire are already there, and the dictation pill and Quick Recall float instead of tiling.</p>
        <p>On Wayland, autocomplete in other apps takes part as an input method, the way language input tools do, and shows the suggestion inside the field. Turn it on in <strong>Settings > Writing</strong>. What else it needs depends on your desktop:</p>
        <ul>
          <li><strong>Sway and Hyprland:</strong> nothing more. A desktop runs one input method at a time, so if Fcitx or IBus is running, LokalBot stays out of its way and Settings says so. Omarchy runs Fcitx 5; if you don't use it, <code>systemctl --user disable --now omarchy-fcitx5.service</code> lets autocomplete start.</li>
          <li><strong>GNOME:</strong> add LokalBot in GNOME Settings > Keyboard > Input Sources > + > Other, then choose it in the top bar or with <kbd>Super+Space</kbd>. With the <code>.tar.gz</code>, first run the command Settings shows. Either way, log out and back in once. Firefox and Chrome stay quiet without the Window Calls extension.</li>
          <li><strong>KDE Plasma:</strong> choose LokalBot in System Settings > Keyboard > Virtual Keyboard and click Apply. If you run LokalBot from the extracted <code>.tar.gz</code> folder, first run the command Settings shows. Plasma holds one input method there, so this replaces Fcitx or IBus until you choose it again. After a LokalBot update, log out and back in once.</li>
          <li><strong>Other compositors:</strong> not yet. Settings says so and offers the practice editor.</li>
        </ul>
        <p>Not every app can take part. X11 apps running through XWayland get no suggestions, and neither do Qt 5 apps outside KDE Plasma, though typing in them is unaffected, and older Chromium and Electron apps need <code>--enable-wayland-ime</code>, according to their documentation.</p>
        <p>This route is new. It has only been tried on headless Sway 1.9, GNOME Shell 46, and KWin 6.8 with stand-in suggestions, not on real desktops with a real model. Hyprland itself hasn't been run, and neither have Firefox and Chrome on KDE Plasma. The <a href="explainers/wayland-autocomplete.pdf">one-page explainer</a> covers what it reads and keeps, and the <a href="https://github.com/stevyhacker/lokalbot/blob/master/LinuxWindows/README.md#autocomplete-on-wayland" target="_blank" rel="noopener">README</a> lists each desktop and app.</p>

        <h2>Install and stay updated</h2>
        <ul>
          <li><strong>Debian and Ubuntu:</strong> <code>sudo apt install ./LokalBot-&lt;version&gt;-linux-amd64.deb</code>. It adds the LokalBot repository at pkg.lokalbot.com, so <code>sudo apt upgrade</code> brings later versions.</li>
          <li><strong>Fedora:</strong> <code>sudo dnf install ./LokalBot-&lt;version&gt;-linux-x86_64.rpm</code>, then <code>sudo dnf upgrade</code> for later versions. On openSUSE the same package installs, and LokalBot tells you when a new version is out.</li>
          <li><strong>Arch and Omarchy:</strong> <code>sudo pacman -U ./LokalBot-&lt;version&gt;-linux-x86_64.pkg.tar.zst</code>. LokalBot tells you when a newer package is out.</li>
          <li><strong>Any distribution:</strong> extract the <code>.tar.gz</code> and run <code>./install.sh</code>. It installs into <code>~/.local/bin</code>, adds LokalBot to your applications menu, and lets the app update itself after checking each download's signature.</li>
        </ul>
        <p>All of them are on the <a href="https://github.com/stevyhacker/lokalbot/releases/latest" target="_blank" rel="noopener">latest release</a>. LokalBot needs x86_64 with glibc 2.39 or later (Ubuntu 24.04, Debian 13, Fedora 40, or newer), PulseAudio or PipeWire, and a Vulkan or OpenGL driver; Mesa is fine. Reading screen text in scripts other than Latin needs Tesseract (<code>tesseract-ocr</code> on Debian and Ubuntu, <code>tesseract</code> on Fedora and Arch), which the <code>.deb</code> and <code>.rpm</code> recommend. See the <a href="system-requirements">system requirements</a>.</p>

        <h2>Models and hardware</h2>
        <p>On first launch LokalBot asks what to remember and downloads the models you choose: about 4 GB for the default transcription, notes, and search models. llama.cpp runs on any Vulkan GPU or on the CPU. On an NVIDIA GPU you can choose <strong>CUDA (experimental)</strong> in Settings > Models > llama.cpp; in testing, CUDA read a long prompt into Qwen3.5 4B 44% faster than Vulkan on an RTX 3060. Without a capable GPU, notes on the CPU are slow, so you can point notes and Ask at Ollama on another computer or at a server you approve.</p>

        <h2>What's not there yet</h2>
        <ul>
          <li>Gmail in meeting briefs, Apple Intelligence, Granite Speech transcription, and Nemotron speaker separation are Mac only for now.</li>
          <li>Remembered speakers only suggest. Naming a speaker teaches an encrypted voice profile, and later meetings offer that name for you to apply. Unlike on a Mac, nothing is named automatically, because the matching hasn't been calibrated on real calls with this voice model.</li>
          <li>There's no Flatpak or Snap. An AUR package, <code>lokalbot-bin</code>, is on its way.</li>
          <li>Bot-free is not consent-free. Tell the people in your meeting that you're recording, and follow the rules that apply to them.</li>
        </ul>
        """,
        "faq": [
            ("Does LokalBot work on Wayland?", "Yes, with limits. Meetings, transcription, notes, search, and Ask work on any desktop. Day memory works on Hyprland, Sway, KDE, and GNOME with the Window Calls extension; screen context needs grim on Sway and Hyprland or the desktop's screenshot portal elsewhere; dictation and selection actions each need a compositor shortcut, bound to lokalbot dictate and lokalbot selection-actions; and autocomplete in other apps works as an input method on Sway, Hyprland, GNOME, and KDE Plasma, but not yet on other compositors."),
            ("Do I need an NVIDIA GPU?", "No. The built-in models run on any Vulkan GPU, including AMD and Intel graphics, or on the CPU. CUDA is an experimental option for NVIDIA GPUs."),
            ("Can I move my library between Linux and a Mac?", "Yes. Both apps read the same library format, and meetings recorded on a Mac play and transcribe on Linux. On Linux the library lives in ~/.local/share/LokalBot. LokalBot doesn't sync it between computers for you."),
        ],
        "related": ["system-requirements", "local-ai-meeting-notes-windows", "open-source-ai-meeting-notes"],
    },
    {
        "slug": "local-ai-meeting-notes-windows",
        "published": "2026-10-26",
        "updated": "2026-11-26",
        "updated_label": "November 26, 2026",
        "title": "Local AI Meeting Notes on Windows: Bot-Free & Open Source",
        "description": "Record, transcribe, and summarize Teams, Zoom, and Meet calls on Windows 10/11 without a bot or cloud: per-user install, Vulkan/CUDA, and local models.",
        "eyebrow": "Windows",
        "h1": "Local AI meeting notes on Windows",
        "lead": "LokalBot records both sides of a Teams, Zoom, or Meet call without a bot, transcribes and summarizes it with models on your PC, and keeps every meeting searchable. Here is what works on Windows and how to install it.",
        "read_time": "5 min read",
        "body": """
        <h2>What works on Windows</h2>
        <p>LokalBot for Windows is a native app written in Rust with GPUI, the UI framework behind the Zed editor. It has the same pages as the Mac app and reads the same library format, so a library recorded on a Mac opens on Windows. It's an alpha.</p>
        <ul>
          <li><strong>Meetings without a bot.</strong> LokalBot records your microphone and the meeting app's own audio through WASAPI process loopback on Windows build 20348 or later, which includes Windows 11, so nothing joins the call. On older builds, or when it can't separate the app, the second track is everything your PC plays. When it detects a meeting, it asks with a notification.</li>
          <li><strong>On-device transcription.</strong> Qwen3-ASR 0.6B by default, with Parakeet v3 and v2, SenseVoice, GigaAM for Russian, and Whisper turbo as options, and speakers separated with pyannote segmentation and TitaNet.</li>
          <li><strong>Notes and Ask.</strong> Summaries, decisions, action items, and answers with citations from Qwen3.5 4B in the built-in llama.cpp, Ollama, an OpenAI-compatible server you approve, or your ChatGPT or Claude plan.</li>
          <li><strong>Your day.</strong> App and window activity, and, if you turn it on, screen text and encrypted screenshots, read through UI Automation and the text recognizer built into Windows, in your app and system languages where Windows has that language pack.</li>
          <li><strong>Writing.</strong> Hold <kbd>Alt+Space</kbd> to dictate anywhere. Optional autocomplete suggests the next words in apps whose text fields support UI Automation, with Gemma 4 E2B on your PC, or the smaller LFM2.5 1.2B with the Lightweight local preset.</li>
          <li><strong>Calendar.</strong> Private iCal or CalDAV links from Outlook, Google, or another calendar name your recordings and list today's meetings.</li>
          <li><strong>Agents.</strong> A read-only CLI and MCP server for Claude Code, Codex, and other agents, and an optional Agent Mode that works on your files with your approval, in Git Bash or PowerShell.</li>
          <li><strong>Selection actions.</strong> Turn them on in <strong>Settings > General</strong>, select text in any app, and press <kbd>Ctrl+Alt+Space</kbd> to fix the grammar, shorten it, translate it, or draft a reply from what your meetings say. Apps without accessibility get results you can copy but not replace in place.</li>
          <li><strong>Spoken summaries.</strong> Hear summaries and answers read aloud, or export a WAV, with Kokoro 82M on your PC.</li>
          <li><strong>Overnight review and Personal Context.</strong> LokalBot reviews your day overnight, waiting for mains power, and keeps the facts, preferences, goals, and principles you give it. Agents read only the items you choose to share.</li>
          <li><strong>Files.</strong> Search folders you choose by words and meaning, off until you turn it on. Scanned PDF pages are read only when stored as JPEG or plain raster, <code>.doc</code> and RAW files aren't read, and video frames, HEIC, and AVIF need ffmpeg.</li>
          <li><strong>Exports and coding sessions.</strong> Keep a Markdown note for every meeting and a daily note in your Obsidian or Logseq folder. Coding-agent sessions join day memory only after you choose that in setup or <strong>Settings > Day Memory</strong>.</li>
          <li><strong>Phones and tablets.</strong> LokalBot can share your meetings and day with your own devices, off until you turn it on in <strong>Settings > Phones &amp; tablets</strong>. Pair an iPhone or iPad with the <a href="https://apps.apple.com/app/id6836773709" target="_blank" rel="noopener">app on the App Store</a>, or an Android phone or tablet with the <a href="https://play.google.com/store/apps/details?id=me.dotenv.lokalbot.companion" target="_blank" rel="noopener">app on Google Play</a>. A firewall must allow TCP port 17890.</li>
        </ul>

        <h2>Install without admin rights</h2>
        <p>Run <code>LokalBot-&lt;version&gt;-windows-x86_64-setup.exe</code> from the <a href="https://github.com/stevyhacker/lokalbot/releases/latest" target="_blank" rel="noopener">latest release</a>. It installs for your user into <code>%LOCALAPPDATA%\\Programs\\LokalBot</code>, without administrator rights, and adds a Start menu shortcut and an Installed apps entry. Uninstalling keeps your library. A portable zip is in the same release.</p>
        <p>The app isn't code-signed yet, so SmartScreen asks before the first launch: choose <strong>More info > Run anyway</strong>. Updates are signed: LokalBot checks for a new version once a day, verifies the download's signature, and installs it only when you choose <strong>Install and Relaunch</strong>. A winget package is in review.</p>

        <h2>Models and hardware</h2>
        <p>LokalBot needs Windows 10 or 11 on x64. On first launch it downloads the models you choose: about 4 GB for the default transcription, notes, and search models. llama.cpp runs on any Vulkan GPU, including AMD Radeon and Intel graphics, or on the CPU. On an NVIDIA GPU you can choose <strong>CUDA (experimental)</strong> in Settings > Models > llama.cpp; in testing on an NVIDIA L4, CUDA read a long prompt into Qwen3.5 4B 32% faster than Vulkan. See the <a href="system-requirements">system requirements</a>.</p>

        <h2>What's not there yet</h2>
        <ul>
          <li>Code signing, so SmartScreen will warn until it's in place.</li>
          <li>Gmail in meeting briefs, Apple Intelligence, Granite Speech transcription, and Nemotron speaker separation are Mac only for now.</li>
          <li>Remembered speakers only suggest. Naming a speaker teaches an encrypted voice profile, and later meetings offer that name for you to apply. Unlike on a Mac, nothing is named automatically, because the matching hasn't been calibrated on real calls with this voice model.</li>
          <li>Bot-free is not consent-free. Tell the people in your meeting that you're recording, and follow the rules that apply to them.</li>
        </ul>
        """,
        "faq": [
            ("Why does Windows warn me before LokalBot opens?", "The Windows build isn't code-signed yet, so SmartScreen asks first. Choose More info, then Run anyway. The source is public on GitHub, and every update LokalBot installs is checked against its signature first."),
            ("Does a bot join my Teams or Zoom calls?", "No. LokalBot records your microphone and the meeting app's audio, or everything your PC plays when it can't separate the app, on two tracks, so nothing joins the call and other participants don't see a notetaker. Tell them you're recording."),
            ("Do I need administrator rights?", "No. The installer installs LokalBot for your user only. A portable zip that runs from any folder is also available."),
        ],
        "related": ["system-requirements", "local-ai-meeting-notes-linux", "claude-code-codex-meeting-notes"],
    },
    {
        "slug": "offline-meeting-transcription-mac",
        "updated": "2026-11-10",
        "updated_label": "November 10, 2026",
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
          <li><strong>Qwen3-ASR 1.7B</strong> has been the default since LokalBot 0.8.1, covers 52 languages and dialects, and downloads about 2.5 GB.</li>
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
        "updated": "2026-11-10",
        "updated_label": "November 10, 2026",
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
        <p>LokalBot is released under GPLv3. Code in the Autocomplete engine that was ported from <a href="https://github.com/FuJacob/cotabby" target="_blank" rel="noopener">Cotabby</a> stays under <a href="https://github.com/stevyhacker/lokalbot/blob/master/LICENSES/AGPL-3.0.txt" target="_blank" rel="noopener">AGPLv3</a>, and other third-party components and models retain their own licenses; see the <a href="https://github.com/stevyhacker/lokalbot/blob/master/THIRD_PARTY_NOTICES.md" target="_blank" rel="noopener">third-party notices</a>. You can read, modify, and build the code, and distributed derivative versions must preserve the license obligations. That differs from “source available” products whose licenses restrict commercial use, redistribution, or forks. The repository's license files are the authoritative text.</p>

        <h2>Trace the meeting data path</h2>
        <p>For a private notetaker, follow the recording from capture to deletion:</p>
        <ol>
          <li>The microphone and the meeting audio produce two local audio tracks. On a Mac the second track is the selected meeting app; on Windows and Linux it is the meeting app where it can be separated, and otherwise everything the computer plays.</li>
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
<span class="c-prompt">$</span> Scripts/build/build-sync-xcframework.sh
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
            ("Is LokalBot free for commercial work?", "LokalBot is GPLv3 software, with Autocomplete code ported from Cotabby under AGPLv3, and has no usage subscription. Review the licenses themselves for obligations that apply when you modify or distribute it."),
            ("Can I audit network access?", "Yes. The source is public, and the privacy policy names the normal network paths: models, updates, optional Agent Mode setup, and approved remote inference."),
            ("Do I need an API key?", "No. The built-in local models work without one. API keys are relevant only if you choose an external compatible backend that requires them."),
        ],
        "related": ["local-ai-meeting-notes-mac", "offline-meeting-transcription-mac", "system-requirements"],
    },
    {
        "slug": "record-both-sides-mac-meeting-without-bot",
        "updated": "2026-11-02",
        "updated_label": "November 2, 2026",
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
        <p>The Windows and Linux versions (alpha) also record two tracks. The second one is the meeting app alone where it can be separated: WASAPI process loopback on Windows build 20348 or later, and the app's own PulseAudio or PipeWire streams on Linux. Otherwise it is everything the computer plays, so notifications or music playing during the call end up in the recording too. Calendar matching there uses private iCal or CalDAV links instead of macOS Calendar. See the <a href="system-requirements">system requirements</a>.</p>

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
        "updated": "2026-11-10",
        "updated_label": "November 10, 2026",
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
              <tr><td>Qwen3-ASR 1.7B</td><td>Default since LokalBot 0.8.1</td><td>52 languages/dialects; ~2.5 GB</td></tr>
              <tr><td>Qwen3-ASR 0.6B</td><td>Compact broad coverage</td><td>Global coverage; ~0.7 GB</td></tr>
              <tr><td>Whisper large-v3 turbo</td><td>Wide-language fallback and timestamps</td><td>99 languages; ~1.6 GB</td></tr>
            </tbody>
          </table>
        </div>
        <p>The table covers the Mac app. The Windows and Linux versions (alpha) use Qwen3-ASR 0.6B by default, with Parakeet v3 and v2, SenseVoice, GigaAM for Russian, and Whisper turbo as options, and no Granite Speech; see the <a href="system-requirements">system requirements</a>.</p>

        <h2>A sensible selection strategy</h2>
        <ol>
          <li><strong>Start with Qwen3-ASR 1.7B</strong>, the default speech model since LokalBot 0.8.1.</li>
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
            ("Which model does LokalBot recommend?", "Qwen3-ASR 1.7B has been the default transcription model since LokalBot 0.8.1. You can change it in Settings > Models."),
            ("Which option covers the most languages?", "Whisper large-v3 turbo has the broadest listed coverage at 99 languages. Language count alone does not guarantee the best result for a specific recording."),
            ("Can I keep several models installed?", "Yes. That is useful when your meetings vary by language or audio quality, subject to disk space."),
        ],
        "related": ["offline-meeting-transcription-mac", "system-requirements", "local-ai-meeting-notes-mac"],
    },
    {
        "slug": "system-requirements",
        "updated": "2026-11-21",
        "updated_label": "November 21, 2026",
        "title": "LokalBot System Requirements: Mac, Windows and Linux (alpha)",
        "description": "Check LokalBot's requirements on Mac, Windows and Linux (alpha): OS versions, hardware, memory, disk, permissions, and model downloads.",
        "eyebrow": "Compatibility",
        "h1": "LokalBot system requirements",
        "lead": "The short version: an Apple Silicon Mac on macOS 15 or later, a Windows 10 or 11 x64 PC (alpha), or an x86_64 Linux desktop with glibc 2.39 or later (alpha), plus enough disk for the models you choose. The iPhone and iPad companion app needs iOS or iPadOS 18 or later, and the Android app needs Android 10 or later.",
        "read_time": "7 min read",
        "body": """
        <h2>Mac</h2>
        <ul>
          <li><strong>Mac:</strong> Apple Silicon: M1 or later.</li>
          <li><strong>Operating system:</strong> macOS 15.0 or later.</li>
          <li><strong>Install:</strong> download <a href="https://github.com/stevyhacker/lokalbot/releases/latest" data-asset="mac">the DMG</a>, or run <code>brew install --cask stevyhacker/tap/lokalbot</code>.</li>
          <li><strong>Disk:</strong> room for the app, recordings, and selected models.</li>
          <li><strong>Internet:</strong> required for the initial app and model downloads; optional for the built-in workflow after setup.</li>
          <li><strong>Library:</strong> <code>~/Library/Application Support/me.dotenv.LokalBot</code>.</li>
        </ul>
        <p>Intel Macs are not supported. The Mac app is built around Apple Silicon acceleration, Core Audio process taps, the Neural Engine, and Metal. Windows and Linux have their own native app, built separately, with the same pages and the same library format.</p>

        <h2>How much memory does a Mac need?</h2>
        <p>The Mac app runs across the supported Apple Silicon range, but local language-model choice changes the practical memory requirement. Compact built-in models start around 0.53–1.28 GB. Several balanced summary and cotyping models recommend 16 GB of unified memory. The largest long-meeting models in the catalog are roughly 16.8–17.73 GB on disk and target Macs with 32 GB or more. Use the interactive <a href="hardware">Local AI Hardware &amp; RAM Calculator</a> to check exact disk, resident RAM, and KV-cache fit for your Mac or PC.</p>
        <p>You do not need the largest model to record or transcribe a meeting. Choose a compact speech model and a smaller summarizer first, then move up only if the quality gain is worthwhile on your hardware.</p>

        <h2>Plan disk space on a Mac</h2>
        <ul>
          <li><strong>Compact setup:</strong> a roughly 0.7 GB Qwen3-ASR speech model plus a small 0.53–1.28 GB language model.</li>
          <li><strong>Broader transcription:</strong> Whisper large-v3 turbo is roughly 1.6 GB; Qwen3-ASR 1.7B is roughly 2.5 GB.</li>
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
          <li><strong>Install:</strong> download <a href="https://github.com/stevyhacker/lokalbot/releases/latest" data-asset="windows">the Windows installer</a> from the latest release and run it. It installs LokalBot for your user into <code>%LOCALAPPDATA%\\Programs\\LokalBot</code>, with a Start menu shortcut and no administrator rights. It isn't code-signed yet, so SmartScreen asks first: choose <strong>More info > Run anyway</strong>. The release also has a portable zip.</li>
          <li><strong>System audio:</strong> WASAPI process loopback records just the meeting app on build 20348 or later, which includes Windows 11. On older builds, or when the app can't be separated, WASAPI loopback records everything the computer plays.</li>
          <li><strong>Disk:</strong> about 4 GB for the default transcription, summary, and search models, plus your recordings.</li>
          <li><strong>GPU:</strong> optional. The built-in llama.cpp runs on a Vulkan GPU or on the CPU.</li>
          <li><strong>Library:</strong> <code>%LOCALAPPDATA%\\LokalBot</code>.</li>
        </ul>

        <h2>Linux (alpha)</h2>
        <ul>
          <li><strong>System:</strong> x86_64 with glibc 2.39 or later, such as Ubuntu 24.04, Debian 13, or Fedora 40 or newer.</li>
          <li><strong>Graphics:</strong> a Vulkan or OpenGL driver. Mesa is fine.</li>
          <li><strong>Audio:</strong> PulseAudio or PipeWire. LokalBot records the meeting app's own streams where it can, and otherwise the output monitor, which captures everything the computer plays.</li>
          <li><strong>Install:</strong> download <a href="https://github.com/stevyhacker/lokalbot/releases/latest" data-asset="linux">the Linux archive</a> from the latest release, extract it, and run <code>./install.sh</code>. It installs LokalBot to <code>~/.local/bin</code> and adds it to your applications menu. The same release also has a <code>.deb</code> (Debian, Ubuntu), an <code>.rpm</code> (Fedora, openSUSE) and an Arch package. Installing the <code>.deb</code>, or the <code>.rpm</code> on Fedora, also adds the LokalBot repository, so <code>sudo apt upgrade</code> or <code>sudo dnf upgrade</code> brings later versions; with the Arch package, LokalBot tells you about updates instead of installing them.</li>
          <li><strong>Disk:</strong> about 4 GB for the default models, plus your recordings. The built-in llama.cpp runs on a Vulkan GPU or on the CPU.</li>
          <li><strong>Screen text in other scripts:</strong> needs Tesseract (<code>tesseract-ocr</code> on Debian and Ubuntu, <code>tesseract</code> on Fedora and Arch), which the <code>.deb</code> and <code>.rpm</code> recommend. Without it, screen text reads Latin letters with ocrs.</li>
          <li><strong>GNOME:</strong> the tray icon needs the AppIndicator extension, and day memory needs the Window Calls extension. Autocomplete in other apps needs LokalBot added as an input source, and in Firefox and Chrome it also needs Window Calls.</li>
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
              <tr><th scope="row">Selection actions</th><td>Press Ctrl+Alt+Space</td><td>Bind <code>lokalbot selection-actions</code> to a shortcut in your desktop's settings</td></tr>
              <tr><th scope="row">Autocomplete in other apps</th><td>Yes</td><td>As an input method on Sway, Hyprland, GNOME, and KDE Plasma, lightly tested so far (see the <a href="local-ai-meeting-notes-linux">Linux guide</a>); elsewhere only in the practice editor in Settings</td></tr>
            </tbody>
          </table>
        </div>

        <h2>Models on Windows and Linux</h2>
        <p>The Windows and Linux app has its own defaults:</p>
        <ul>
          <li><strong>Transcription:</strong> Qwen3-ASR 0.6B, with Parakeet v3 and v2, SenseVoice, GigaAM for Russian, and Whisper turbo as options.</li>
          <li><strong>Speakers:</strong> pyannote segmentation with TitaNet embeddings.</li>
          <li><strong>Autocomplete:</strong> Gemma 4 E2B, the same as on a Mac, or LFM2.5 1.2B with the Lightweight local preset.</li>
          <li><strong>Summaries and search:</strong> Qwen3.5 4B and EmbeddingGemma 2, the same as on a Mac.</li>
          <li><strong>Screen text:</strong> accessibility (UI Automation on Windows, AT-SPI on Linux) plus on-device OCR in your app and system languages: the recognizer built into Windows, or Tesseract on Linux, with ocrs as the fallback for Latin letters. Any download starts only when you ask.</li>
          <li><strong>Spoken summaries:</strong> Kokoro 82M.</li>
        </ul>
        <p>The <a href="benchmarks">benchmarks</a> were measured on a Mac, so these engines have not been benchmarked yet.</p>

        <h2>Mac only for now</h2>
        <p>The Windows and Linux app has the same pages and reads the same library, but these features haven't been ported yet:</p>
        <ul>
          <li>Gmail in meeting briefs</li>
          <li>Apple Intelligence</li>
          <li>Granite Speech transcription</li>
          <li>Nemotron speaker separation</li>
        </ul>

        <h2>What works differently on Windows and Linux</h2>
        <ul>
          <li><strong>Remembered speakers:</strong> later meetings offer a remembered name for you to apply. Unlike on a Mac, nothing is named automatically, because the matching hasn't been calibrated on real calls with this voice model.</li>
          <li><strong>Selection actions:</strong> the shortcut is <kbd>Ctrl+Alt+Space</kbd>, because ⌃⇧ W closes tabs and windows there. Apps without accessibility get results you can copy but not replace in place.</li>
          <li><strong>Files:</strong> scanned PDF pages are read only when stored as JPEG or plain raster, <code>.doc</code> and RAW files aren't read, and video frames, HEIC, and AVIF need ffmpeg. Results open in their default app.</li>
          <li><strong>Phones and tablets:</strong> they pair as they do with a Mac. A firewall must allow TCP port 17890.</li>
        </ul>

        <h2>Phones and tablets</h2>
        <ul>
          <li><strong>iPhone and iPad:</strong> iOS or iPadOS 18 or later. Install the <a href="https://apps.apple.com/app/id6836773709" target="_blank" rel="noopener">app from the App Store</a>.</li>
          <li><strong>Android:</strong> Android 10 or later. Install the <a href="https://play.google.com/store/apps/details?id=me.dotenv.lokalbot.companion" target="_blank" rel="noopener">app from Google Play</a>, or the APK attached to each <a href="https://github.com/stevyhacker/lokalbot/releases/latest" target="_blank" rel="noopener">release</a>. They're signed with different keys, so Android won't update one with the other: switching means uninstalling first, which removes the phone's copy and its pairing.</li>
          <li><strong>A computer to pair with:</strong> LokalBot on a Mac, Windows, or Linux, with <strong>Settings > Phones &amp; tablets</strong> turned on. The phone reaches it over your local network or Tailscale, with no LokalBot server in between.</li>
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
        "updated": "2026-11-26",
        "updated_label": "November 26, 2026",
        "title": "Granola & Otter Alternatives for Linux and Windows (2026)",
        "description": "Granola has no Linux app and caps free Windows history at 30 days. Compare bot-free local note takers for Linux and Windows: LokalBot, OpenWhispr, Meetily.",
        "eyebrow": "Linux and Windows",
        "h1": "Granola and Otter alternatives for Linux and Windows",
        "lead": "Granola has no Linux app and caps free Windows history at 30 days, while Otter and Fireflies offer Linux users only a browser tab. Here are the bot-free meeting note takers for Linux and Windows, with per-app breakdowns of where audio is transcribed and what stays free.",
        "read_time": "7 min read",
        "body": """
        <h2>The options, side by side</h2>
        <p>Verified against each project's own site, documentation, and releases on November 26, 2026. For a broader local roundup including macOS, see <a href="best-local-ai-meeting-notes">Best local and open-source AI meeting note takers</a>.</p>
        <div class="guide-table-wrap">
          <table class="guide-table">
            <thead><tr><th scope="col">App</th><th scope="col">Linux</th><th scope="col">Windows</th><th scope="col">Transcription</th><th scope="col">License &amp; free limit</th></tr></thead>
            <tbody>
              <tr><th scope="row"><a href="#lokalbot">LokalBot</a></th><td>Native Rust + GPUI (.deb, .rpm, Arch, archive; alpha)</td><td>Native Rust + GPUI (per-user installer, portable zip; alpha)</td><td>On your computer by default (Qwen3-ASR + Qwen3.5 4B v4)</td><td>GPLv3 · free, unlimited</td></tr>
              <tr><th scope="row"><a href="#openwhispr">OpenWhispr</a></th><td>Native app (AppImage, .deb, .rpm, archive)</td><td>Native app</td><td>On-device optional; setup recommends OpenWhispr Cloud</td><td>MIT client · hosted MCP paid</td></tr>
              <tr><th scope="row"><a href="#meetily">Meetily</a></th><td>Build from source</td><td>Native app</td><td>On your device (Whisper or Parakeet)</td><td>MIT Community · Pro $10/mo</td></tr>
              <tr><th scope="row"><a href="#anarlog">Anarlog (Hyprnote)</a></th><td>Native app (beta)</td><td>Native app (beta)</td><td>Cloud or self-hosted server on Linux/Windows (local on Mac)</td><td>MIT community · paid hosted</td></tr>
              <tr><th scope="row"><a href="#screenpipe">Screenpipe</a></th><td>AppImage</td><td>Native app</td><td>On your device continuously (~30 GB/mo)</td><td>Source-available · commercial paid</td></tr>
              <tr><th scope="row"><a href="#cloud-baseline">Granola / Otter / Fireflies</a></th><td>Granola: none · Otter/Fireflies: web + Chrome extension</td><td>Native desktop apps</td><td>Vendor cloud servers</td><td>Proprietary · 30d / 300-400 min free caps</td></tr>
            </tbody>
          </table>
        </div>

        <h2>App-by-app breakdown for Linux and Windows</h2>

        <section class="tool" id="lokalbot" aria-labelledby="lokalbot-title">
          <h3 id="lokalbot-title">LokalBot: free local Granola alternative for Linux and Windows (no 30-day limit)</h3>
          <p class="tool-tagline">Native Rust + GPUI (alpha) · 100% local defaults · GPLv3</p>
          <p>LokalBot captures your microphone and the meeting app's audio locally through PipeWire/PulseAudio on Linux and WASAPI process loopback on Windows 11, with no bot joining Zoom, Teams, or Meet. Unlike Granola's 30-day free history limit on Windows or missing Linux app, LokalBot stores unlimited meetings in a local SQLite database and ships Apache-2.0 fine-tuned local models (Qwen3-ASR 0.6B/1.7B, Qwen3.5 4B LokalBot v4, Gemma 4 E2B LokalBot v4, EmbeddingGemma 2) over Vulkan, experimental CUDA, or CPU. It also includes dictation, Obsidian Markdown export, E2EE iOS/Android companion sync over LAN or Tailscale, and a free read-only local MCP server.</p>
          <dl class="tool-facts">
            <dt>Linux packages</dt><dd><code>.deb</code> (apt repo at pkg.lokalbot.com), <code>.rpm</code> (dnf repo), Arch <code>.pkg.tar.zst</code>, and <code>.tar.gz</code></dd>
            <dt>Windows install</dt><dd>Per-user <code>setup.exe</code> (no admin rights) or portable <code>.zip</code>; not code-signed yet</dd>
            <dt>Tradeoffs</dt><dd>Alpha status; Gmail briefs, Granite Speech, and Nemotron diarization remain Mac only for now. See <a href="local-ai-meeting-notes-linux">Linux guide</a> and <a href="local-ai-meeting-notes-windows">Windows guide</a>.</dd>
          </dl>
        </section>

        <section class="tool" id="openwhispr" aria-labelledby="openwhispr-title">
          <h3 id="openwhispr-title">OpenWhispr: cross-platform dictation and meeting capture</h3>
          <p class="tool-tagline">MIT client · Linux AppImage/.deb/.rpm + Windows · optional local models</p>
          <p>OpenWhispr runs on Linux and Windows with strong push-to-talk dictation, per-app voice modes, and bot-free meeting recording. Its onboarding defaults toward OpenWhispr Cloud, so switch transcription to on-device Orukeet or Whisper and summaries to llama.cpp or Ollama if audio must stay local. Its local CLI is free, while its hosted MCP server requires a paid cloud plan ($8-$16/mo). Compare details in <a href="lokalbot-vs-openwhispr">LokalBot vs OpenWhispr</a>.</p>
        </section>

        <section class="tool" id="meetily" aria-labelledby="meetily-title">
          <h3 id="meetily-title">Meetily: MIT-licensed Windows meeting recorder</h3>
          <p class="tool-tagline">Native Windows binary · Linux from source · local Whisper/Parakeet</p>
          <p>Meetily Community Edition is a solid MIT-licensed local meeting recorder on Windows with on-device Whisper/Parakeet transcription and built-in Qwen 3.5 or Ollama summaries. Speaker separation, automatic meeting detection, and MCP access sit in the paid commercial Pro tier ($10/user/mo annual), and Linux users currently compile from source. See <a href="lokalbot-vs-meetily">LokalBot vs Meetily</a>.</p>
        </section>

        <section class="tool" id="anarlog" aria-labelledby="anarlog-title">
          <h3 id="anarlog-title">Anarlog (formerly Hyprnote): MIT notepad with BYO server</h3>
          <p class="tool-tagline">Linux &amp; Windows beta · bring-your-own LLM or Ollama</p>
          <p>Anarlog offers a clean meeting notepad with local SQLite storage and a local CLI/MCP server. Note that on-device transcription is currently Mac-only; on Linux and Windows betas, speech recognition relies on a cloud provider or a self-hosted transcription server you maintain. See <a href="lokalbot-vs-hyprnote">LokalBot vs Anarlog</a>.</p>
        </section>

        <section class="tool" id="screenpipe" aria-labelledby="screenpipe-title">
          <h3 id="screenpipe-title">Screenpipe: continuous local screen and audio capture</h3>
          <p class="tool-tagline">Linux AppImage &amp; Windows · ~30 GB/mo disk · source-available</p>
          <p>Screenpipe records your screen and audio continuously on Linux and Windows and exposes everything through a local REST API and MCP server. It fits developers building custom agent pipes over 24/7 capture, though commercial/work use requires a paid license ($21-$42/mo) and you supply the LLM for meeting summaries. See <a href="lokalbot-vs-screenpipe">LokalBot vs Screenpipe</a>.</p>
        </section>

        <section class="tool" id="cloud-baseline" aria-labelledby="cloud-baseline-title">
          <h3 id="cloud-baseline-title">Granola, Otter.ai, and Fireflies.ai (cloud baselines)</h3>
          <p class="tool-tagline">Proprietary cloud apps · limited Linux support · free history or minute caps</p>
          <p>Granola ships a polished Windows app (free tier keeps 30 days of history; Business is $14/user/mo) but has no Linux recorder. Otter (300 min/mo free) and Fireflies (400 min/team free) support Linux only through a browser tab and upload all audio to cloud servers. You can convert existing Granola, Otter, or Fireflies exports into plain Obsidian Markdown offline at <a href="/migrate">lokalbot.com/migrate</a>.</p>
        </section>

        <h2>What to check before you choose</h2>
        <ul>
          <li><strong>Default transcription path:</strong> Confirm whether audio actually runs on your Linux or Windows machine by default, or silently falls back to a vendor cloud.</li>
          <li><strong>Free vs Pro gates:</strong> Check whether speaker labels, history beyond 30 days, and local MCP access require a paid tier.</li>
          <li><strong>Wayland vs X11 behavior:</strong> On Linux, check how global shortcuts, PipeWire audio isolation, and screen capture behave on your specific compositor (GNOME, KDE Plasma, Sway, or Hyprland).</li>
        </ul>
        """,
        "faq": [
            ("Does Granola work on Linux?", "No. Granola ships apps for Mac, Windows, iPhone, and Android. Its web app can view and edit notes but cannot record or transcribe meetings on Linux."),
            ("What is the best free local Granola alternative for Windows with no 30-day history limit?", "LokalBot (GPLv3, alpha) records Teams, Zoom, and Meet audio locally on Windows 10 and 11 with no bot, runs Qwen3-ASR and Qwen3.5 4B LokalBot v4 on Vulkan, CUDA, or CPU, and keeps unlimited meeting history on your disk with no 30-day cutoff."),
            ("Which open-source apps transcribe locally on Linux?", "LokalBot (.deb, .rpm, Arch, .tar.gz) and OpenWhispr (select on-device models during setup) both transcribe locally on Linux. Meetily transcribes locally too, built from source on Linux. Anarlog's Linux beta uses a cloud provider or self-hosted server for transcription. Screenpipe transcribes locally under a source-available commercial license."),
        ],
        "related": ["best-local-ai-meeting-notes", "local-ai-meeting-notes-linux", "local-ai-meeting-notes-windows"],
    },
    {
        "slug": "claude-code-codex-meeting-notes",
        "kind": "question",
        "published": "2026-10-14",
        "updated": "2026-11-26",
        "updated_label": "November 26, 2026",
        "title": "Meeting Notes MCP for Claude Code, Codex & Cursor",
        "description": "Connect local meeting notes over stdio MCP to Claude Code, Codex, Cursor, Windsurf, Gemini CLI, and Antigravity. Read-only, zero cloud bots.",
        "eyebrow": "Agents and MCP",
        "h1": "How do I connect meeting notes via MCP to Claude Code, Codex, and Cursor?",
        "lead": "Keep your meeting library on your computer and connect your coding agent through a local, read-only stdio MCP server. LokalBot records and transcribes calls on-device and exposes <code>lokalbot-cli mcp</code> for Claude Code, Codex, Cursor, Windsurf, Gemini CLI, and Antigravity.",
        "read_time": "6 min read",
        "body": """
        <h2>Three pieces, all on your computer</h2>
        <p>A coding agent can only answer "what did we decide about the API migration?" if it can query the call. Cloud notetakers require a bot or cloud upload plus OAuth tokens. A local MCP setup replaces each piece:</p>
        <ol>
          <li><strong>Capture without a bot.</strong> LokalBot records your microphone and the meeting app's audio on two local tracks. Nothing joins the call.</li>
          <li><strong>Transcribe and index on-device.</strong> Fine-tuned Qwen3-ASR, Qwen3.5 4B (LokalBot v4), and EmbeddingGemma 2 run locally and store everything in SQLite (39 ms hybrid search).</li>
          <li><strong>Expose read-only stdio MCP.</strong> The bundled <code>lokalbot-cli mcp</code> command starts a local Model Context Protocol server over stdio. It stays completely off until you enable agent access in Settings.</li>
        </ol>

        <h2>Step 1: enable read-only access in LokalBot</h2>
        <ol>
          <li>Install LokalBot on Mac, Windows, or Linux (alpha), let the models finish downloading, and record a test call.</li>
          <li>On Mac, open <strong>Settings &gt; External Agents</strong>, enable <strong>Allow external agents to read your LokalBot data</strong>, and check <strong>Meetings</strong>. On Windows and Linux, enable <strong>Allow external agents to read your meeting library</strong> in <strong>Settings &gt; Privacy &amp; Data</strong>.</li>
          <li>In <strong>Settings &gt; External Agents &gt; Agent CLI</strong> on a Mac, or <strong>Settings &gt; Advanced &gt; Agent CLI</strong> on Windows and Linux, choose <strong>Install for your coding agent...</strong> to install the skill and the <code>lokalbot-cli</code> binary (<code>~/.local/bin</code> on Mac/Linux, <code>%LOCALAPPDATA%\\Programs\\LokalBot\\bin</code> on Windows). Add that folder to your PATH if it isn't there already, then restart your terminal. Apps opened from the Dock or Finder, such as Cursor or Claude Desktop, don't read your shell's PATH, so give them the full binary path shown below.</li>
        </ol>

        <h2>Step 2: connect your MCP client</h2>
        <p>Use the one-line CLI commands for Claude Code and Codex:</p>
        <pre class="code" aria-label="Add LokalBot MCP server to Claude Code and Codex"><span class="c-op"># Claude Code</span>
<span class="c-prompt">$</span> claude mcp add lokalbot <span class="c-op">--</span> lokalbot-cli mcp

<span class="c-op"># Codex</span>
<span class="c-prompt">$</span> codex mcp add lokalbot <span class="c-op">--</span> lokalbot-cli mcp</pre>
        <p>For <strong>Cursor</strong> (<code>~/.cursor/mcp.json</code>), <strong>Windsurf</strong> (<code>~/.codeium/windsurf/mcp_config.json</code>), <strong>Gemini CLI</strong> (<code>~/.gemini/settings.json</code>), and <strong>Antigravity</strong>, add the exact same stdio command under <code>mcpServers</code>:</p>
        <pre class="code" aria-label="JSON MCP configuration for Cursor, Windsurf, Gemini CLI, and Antigravity">{
  <span class="c-str">"mcpServers"</span>: {
    <span class="c-str">"lokalbot"</span>: {
      <span class="c-str">"command"</span>: <span class="c-str">"lokalbot-cli"</span>,
      <span class="c-str">"args"</span>: [<span class="c-str">"mcp"</span>]
    }
  }
}</pre>
        <p>If <code>lokalbot-cli</code> is not on your PATH yet, pass its full binary path (on Mac: <code>/Applications/LokalBot.app/Contents/Helpers/lokalbot-cli</code>). Claude Code and Codex users can also install the <a href="claude-code-codex-plugins">LokalBot plugins</a> for <code>/lokalbot:brief</code> and <code>/lokalbot:recall</code> skills, and version 0.14.0 can also read local Antigravity and T3 Code coding sessions alongside Claude Code and Codex in day memory.</p>

        <h2>MCP tools your agent receives</h2>
        <ul>
          <li><strong><code>list_meetings</code> and <code>search_meetings</code>:</strong> Filter meetings by date or title and run local hybrid search across titles, summaries, and transcripts.</li>
          <li><strong><code>get_meeting</code>:</strong> Return a meeting's metadata, summary, or transcript as Markdown so the agent pulls only what it needs.</li>
          <li><strong><code>ask_library</code>:</strong> Ask LokalBot's local model a question across your library and return a compact cited answer (~1,248 characters median) instead of dumping raw transcripts into your agent's context window.</li>
          <li><strong><code>get_action_items</code> and <code>list_people</code>:</strong> Fetch open actions with your edits applied and people by name (email addresses are never returned).</li>
          <li><strong>Opt-in screen memory and Files:</strong> Separate switches grant read-only access to captured screen text (never pixels) and keyword search over folders you chose under Files (<code>search_files</code>).</li>
        </ul>
        <p>Agents without MCP support can call the exact same commands from a shell, such as <code>lokalbot-cli search "pricing decision"</code> or <code>lokalbot-cli brief</code>.</p>

        <h2>Where your meetings go once an agent reads them</h2>
        <p>LokalBot never uploads your library, and its default MCP tools are strictly read-only. Changing LokalBot settings or running <code>lokalbot-cli reprocess</code> requires a separate opt-in switch (<strong>Allow external agents to change LokalBot settings</strong>). Remember that whatever text an MCP tool returns enters your agent's prompt, which Claude Code, Codex, Cursor, Windsurf, or Gemini CLI send to their configured model provider under that provider's terms:</p>
        <ul>
          <li>Prefer <code>search_meetings</code> and <code>ask_library</code> over pulling full raw transcripts.</li>
          <li>Enable only the data scopes (Meetings, Files, Screen memory, Personal Context) you want that agent to see, and flip the master switch off anytime to revoke access immediately.</li>
        </ul>
        """,
        "faq": [
            ("Does the MCP server work with Cursor, Windsurf, Gemini CLI, and Antigravity?", "Yes. Any MCP client that launches a local stdio server works with command 'lokalbot-cli' and args ['mcp']. That covers Claude Code, Codex, Cursor, Windsurf, Gemini CLI, and Antigravity on Mac, Windows, and Linux."),
            ("Does the agent receive raw meeting audio or screenshots?", "No. The MCP server returns text only: meeting metadata, summaries, transcripts, action items, names, cited answers, and (if explicitly enabled) extracted screen text. It never returns audio files or screenshot pixels."),
            ("Can the MCP server edit or delete my meetings?", "No. The read-only MCP server cannot edit or delete meetings. Changing settings or reprocessing a meeting via CLI requires a separate opt-in toggle."),
        ],
        "related": ["claude-code-codex-plugins", "best-local-ai-meeting-notes", "open-source-ai-meeting-notes"],
    },
    {
        "slug": "claude-code-codex-plugins",
        "published": "2026-11-09",
        "updated": "2026-11-09",
        "updated_label": "November 9, 2026",
        "title": "LokalBot Plugins for Claude Code and Codex",
        "description": "Add LokalBot to Claude Code or Codex to catch up on your work and find what was said in meetings, from a library that stays on your computer.",
        "eyebrow": "Agent plugins",
        "h1": "LokalBot plugins for Claude Code and Codex",
        "lead": "Your coding agent can catch you up on your own work and find what was said in a meeting, straight from the LokalBot library on your computer. The plugins add a catch-up brief, recall with citations, and guided setup, and each kind of data stays off until you allow it.",
        "read_time": "4 min read",
        "body": """
        <h2>What the plugins add</h2>
        <p>LokalBot keeps a library on your computer: meetings and their action items, the people in them, the folders you chose under Files, and what you shared about yourself. The plugins teach your agent when and how to use it. Both have the same four skills:</p>
        <ul>
          <li><strong>Brief.</strong> A short catch-up on your own work, with sources: what's in flight, what you owe and to whom, recent decisions, and which LokalBot sources are off.</li>
          <li><strong>Recall.</strong> Finds what you said, saw, agreed, or saved, picks the source that fits, and cites it.</li>
          <li><strong>Setup.</strong> Installs LokalBot and sets it up with you. You allow access, approve changes to what LokalBot captures, and grant system permissions in LokalBot; the agent does the rest from the terminal. The full journey is on a Mac; on Windows and Linux, the agent walks you through the install and then uses the same commands.</li>
          <li><strong>The <code>lokalbot-cli</code> skill.</strong> Tells the agent to check LokalBot at the start of a session on your own work and before asking you about past work, decisions, or commitments, and explains every command.</li>
        </ul>
        <p>In Claude Code they're commands: <code>/lokalbot:brief</code>, <code>/lokalbot:recall what did we decide about pricing?</code>, and <code>/lokalbot:setup</code>. In Codex they're the skills <code>lokalbot-brief</code>, <code>lokalbot-recall</code>, and <code>lokalbot-setup</code>, which Codex uses when a request fits, such as “catch me up on what I owe people”.</p>

        <h2>Install in Claude Code</h2>
        <pre class="code" aria-label="Install the LokalBot plugin in Claude Code"><span class="c-op"># Inside Claude Code</span>
/plugin marketplace add stevyhacker/lokalbot
/plugin install lokalbot@lokalbot
/reload-plugins</pre>
        <p>The first command adds LokalBot's repository as a plugin marketplace, and the second installs the plugin.</p>

        <h2>Install in Codex</h2>
        <pre class="code" aria-label="Install the LokalBot plugin in Codex"><span class="c-prompt">$</span> codex plugin marketplace add stevyhacker/lokalbot <span class="c-flag">--sparse</span> .agents/plugins <span class="c-flag">--sparse</span> Distribution/openai-plugin
<span class="c-prompt">$</span> codex plugin add lokalbot@lokalbot</pre>
        <p>The <code>--sparse</code> options fetch only the plugin, not the whole repository. Then ask Codex to set up LokalBot, or to catch you up.</p>

        <h2>Before the agent can read anything</h2>
        <ol>
          <li><strong>Install LokalBot.</strong> The plugins work through <code>lokalbot-cli</code>, which comes with the app. The setup skill can install it with you, or you can <a href="https://github.com/stevyhacker/lokalbot/releases/latest" target="_blank" rel="noopener">download it</a>. The Windows and Linux apps are in alpha; see the <a href="system-requirements">system requirements</a>.</li>
          <li><strong>Turn on access.</strong> On a Mac, in <strong>Settings > External Agents</strong>, turn on <strong>Allow external agents to read your LokalBot data</strong>, then tick Meetings, What I shared about myself, or Files. On Windows and Linux, each has its own switch under External agents in <strong>Settings > Privacy &amp; Data</strong>. Everything is off until you turn it on.</li>
          <li><strong>Put the CLI on your PATH.</strong> The plugins run <code>lokalbot-cli</code> by name. <strong>Install for your coding agent…</strong>, in <strong>Settings > External Agents > Agent CLI</strong> on a Mac or <strong>Settings > Advanced > Agent CLI</strong> on Windows and Linux, puts it in <code>~/.local/bin</code> on a Mac or Linux. On Windows it goes in <code>%LOCALAPPDATA%\\Programs\\LokalBot\\bin</code>; add that folder to your PATH. The setup skill asks before doing this for you.</li>
        </ol>

        <h2>Screen memory needs the MCP server</h2>
        <p>Neither plugin starts LokalBot's MCP server, so screen memory, which only that server serves, isn't part of them. To add it, connect the server yourself and tick <strong>Screen memory</strong> in LokalBot:</p>
        <pre class="code" aria-label="Connect LokalBot's MCP server to Claude Code or Codex"><span class="c-op"># Claude Code</span>
<span class="c-prompt">$</span> claude mcp add lokalbot <span class="c-op">--</span> lokalbot-cli mcp

<span class="c-op"># Codex</span>
<span class="c-prompt">$</span> codex mcp add lokalbot <span class="c-op">--</span> lokalbot-cli mcp</pre>
        <p><a href="claude-code-codex-meeting-notes">How to let Claude Code or Codex search your meeting notes</a> lists every MCP tool and what each permission opens.</p>

        <h2>What the agent can and can't do</h2>
        <ul>
          <li><strong>It reads only what you allowed.</strong> When a source is off, the agent tells you where to turn it on instead of working around it.</li>
          <li><strong>It never changes your meetings or your files.</strong> Those changes happen in the LokalBot app.</li>
          <li><strong>Settings need their own switch.</strong> With <strong>Allow external agents to change LokalBot settings</strong> on, the agent can apply your preferences. Anything that widens what LokalBot captures, reads, records, or sends, and every API key, waits for your approval in LokalBot.</li>
          <li><strong>Your agent's provider sees what it reads.</strong> LokalBot doesn't upload your library, but Claude Code and Codex send what a command returns to Anthropic or OpenAI under their own terms. The skills retrieve only what a question needs; allow only what you'd paste in yourself.</li>
        </ul>
        """,
        "faq": [
            ("Do I need LokalBot installed?", "Yes. The plugins read your library through lokalbot-cli, which comes with LokalBot. The setup skill can install it with you, or you can download it from the LokalBot releases page."),
            ("Do the plugins cost anything?", "No. The plugins and LokalBot are free and open source under GPLv3, and there's no account."),
            ("Can other agents use LokalBot?", "Yes. Install for your coding agent… installs the lokalbot-cli skill for agents that read skills, and any MCP client that can start a local command, such as Cursor, can run lokalbot-cli mcp."),
        ],
        "related": ["claude-code-codex-meeting-notes", "local-ai-meeting-notes-mac", "system-requirements"],
    },
    {
        "slug": "ai-notetaker-bots-blocked-at-work",
        "kind": "question",
        "published": "2026-10-14",
        "updated": "2026-11-20",
        "updated_label": "November 20, 2026",
        "title": "AI Meeting Bots Blocked at Work? Bot-Free Local Alternatives",
        "description": "Company or client policies blocking Otter, Read.ai, or Fireflies bots? Compare bot-free on-device meeting notes and an IT security approval checklist.",
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
          <li><strong>Ways data can leave.</strong> Markdown exports and the Obsidian and Logseq note exports are plain files in a folder the user picks. Agent access through the CLI and MCP server, and the optional Agent Mode, are off by default; once enabled, an agent's own provider receives what the agent reads.</li>
          <li><strong>Code and builds.</strong> The source is public under GPLv3, with Autocomplete code ported from Cotabby under AGPLv3. Mac releases are signed with a Developer ID and notarized by Apple, and install from the DMG or Homebrew. The Windows build (alpha) is a per-user installer or a portable zip, neither code-signed yet, so SmartScreen warns before it runs. The Linux build (alpha) comes as .deb, .rpm and Arch packages or an archive with an install script. On every platform, updates are signed and install only when the user chooses Install and Relaunch. Any version can be built from source.</li>
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
        "updated": "2026-11-02",
        "updated_label": "November 2, 2026",
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
          <li><strong>Voices, remembered.</strong> When you name a speaker and there's enough clear speech, LokalBot keeps an encrypted voice profile on your computer. That includes people on your calls, who aren't asked. On a Mac, a call voice that closely matches one remembered person is named automatically, and you can undo or correct it; microphone voices are only suggested. On Windows and Linux (alpha), a match is only offered, and <strong>Apply Names</strong> names the speaker.</li>
        </ol>
        <p>These settings and the list of remembered people are in <strong>Settings > Meetings > Speaker names</strong>.</p>

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
            ("Can I turn speaker separation off?", "Yes. Turn off Separate voices by speaker in Settings > Meetings > Speaker names. Your microphone and the call audio stay on separate tracks either way."),
        ],
        "related": ["record-both-sides-mac-meeting-without-bot", "local-transcription-models-mac", "claude-code-codex-meeting-notes"],
    },
    {
        "slug": "meeting-transcripts-obsidian-markdown",
        "kind": "question",
        "published": "2026-10-14",
        "updated": "2026-11-19",
        "updated_label": "November 19, 2026",
        "title": "How to Get Meeting Transcripts into Obsidian as Markdown",
        "description": "Put local meeting transcripts and summaries into an Obsidian vault as Markdown: a note for every meeting, a one-off export, a daily note, or your own script.",
        "eyebrow": "Obsidian and Markdown",
        "h1": "How do I get meeting transcripts into Obsidian as Markdown?",
        "lead": "Record and transcribe on your computer, and LokalBot can write a note for each meeting straight into your vault: the summary, the action items, the people and projects involved as links, and the transcript. You can also export one meeting at a time, add a daily note, or write the notes with your own script.",
        "read_time": "5 min read",
        "body": """
        <h2>Why plain files work best</h2>
        <p>An Obsidian vault is a folder of Markdown files. Anything that writes a <code>.md</code> file into that folder can feed it, and the notes keep working without an account, a plugin, or a sync service in between. If the transcript is a file you own, nothing upstream can change how you get to it.</p>

        <h2>Option 1: a note for every meeting</h2>
        <p>In <strong>Settings > Meetings > Meeting note export</strong>, turn on <strong>Export a note for each meeting</strong>, pick a folder in your vault, and set the format to <strong>Obsidian</strong>. LokalBot writes one note per meeting, including meetings you recorded before turning it on, named like <code>2026-10-14 Atlas release sync (4f7c2a91).md</code>.</p>
        <p>Each note starts with properties: date, time, duration, meeting app, and the people and tracked projects involved as <code>[[links]]</code>, so they show up in backlinks and the graph. Then come the summary, the action items as checkboxes with the ones you finished checked off, and the transcript, unless you turn off <strong>Include the transcript</strong>. Detected passwords and keys are redacted.</p>
        <p>Notes stay current: marking an action done, renaming a speaker, or regenerating a summary updates the note. A note keeps its first name when you rename the meeting, so your links to it keep working. Once you edit, move, or delete a note, it is yours: LokalBot leaves it alone and does not write that meeting again.</p>

        <h2>Option 2: export one meeting</h2>
        <p>Open a meeting and choose <strong>Share > Export as Markdown…</strong>, then save it into your vault. The file starts with the title, date, duration, and meeting app, followed by the summary and the full transcript. <strong>Share > Copy as Markdown</strong> puts the same text on the clipboard. This is fine for the occasional meeting and tedious for every one.</p>

        <h2>Option 3: a daily note in Obsidian format</h2>
        <p>In <strong>Settings > Daily Review > Daily note export</strong> on a Mac, or <strong>Settings > Day Memory > Daily note export</strong> on Windows and Linux, turn on <strong>Export a daily memory note</strong>, pick a folder in your vault, and set the format to <strong>Obsidian</strong>. Each evening (6 PM by default) LokalBot writes or refreshes one note for the day, with <code>date</code> and <code>tags</code> properties: the day's digest, a list of its meetings, app time, and saved moments. A day missed while the computer was asleep is written later. If you edit a generated note, LokalBot keeps your edits and pauses the export until you move that note or choose another folder.</p>
        <p>The daily note lists meetings by time, title, and ID. It doesn't include their transcripts, so pair it with option 1 if you want the full text in the vault.</p>

        <h2>Option 4: your own script</h2>
        <p>If you want a different layout, the bundled <code>lokalbot-cli</code> prints any meeting as Markdown, so a few lines of shell can write the notes instead. The CLI is read-only and checks the same switch agents do, so first turn it on: on a Mac, <strong>Allow external agents to read your LokalBot data</strong> in <strong>Settings > External Agents</strong>, with <strong>Meetings</strong> ticked; on Windows and Linux, <strong>Allow external agents to read your meeting library</strong> in <strong>Settings > Privacy &amp; Data</strong>. Then install the CLI from <strong>Settings > External Agents > Agent CLI</strong> on a Mac or <strong>Settings > Advanced > Agent CLI</strong> on Windows and Linux, save this as <code>lokalbot-to-obsidian.sh</code>, change the folder, and run it with <code>sh lokalbot-to-obsidian.sh</code>:</p>
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

        <h2>Option 5: use the LokalBot Obsidian plugin</h2>
        <p>If you want to browse recent meetings, search transcripts, pull open action items into Daily Notes, or ask LokalBot's local model without leaving Obsidian, install the open-source <a href="https://github.com/stevyhacker/obsidian-lokalbot" target="_blank" rel="noopener">LokalBot plugin for Obsidian</a> (macOS, Windows, and Linux). It reads your local library strictly through the read-only <code>lokalbot-cli</code> with zero network requests.</p>
        <p>Migrating existing exports from Granola, Otter.ai, Fireflies, Fathom, or Zoom into Obsidian Markdown first? Use our 100% offline browser converter at <a href="/migrate">lokalbot.com/migrate</a>: nothing leaves your computer.</p>

        <h2>Things to know</h2>
        <ul>
          <li><strong>Exports are ordinary files.</strong> LokalBot doesn't encrypt them, and if you sync the vault with Obsidian Sync, iCloud, or Git, that service's terms now cover your transcripts too.</li>
          <li><strong>Nothing syncs back.</strong> Editing a note in Obsidian doesn't change the meeting in LokalBot, and deleting a meeting in LokalBot leaves its note in the vault.</li>
          <li><strong>The vault is readable by your other tools.</strong> Any app or agent with access to that folder can read the transcripts, so keep sensitive meetings out of shared vaults, or turn off <strong>Include the transcript</strong>.</li>
        </ul>
        """,
        "faq": [
            ("Is there an Obsidian plugin for LokalBot?", "Yes: an open-source LokalBot plugin for Obsidian (github.com/stevyhacker/obsidian-lokalbot) lets you search meetings, sync notes, insert open action items into Daily Notes, and ask LokalBot's local model inside Obsidian. You still don't need a plugin if you only want automatic Markdown note export straight into your vault folder."),
            ("Do the exported transcripts include speaker names?", "Yes. Each transcript line starts with a timestamp and the speaker's name, or a default label such as Me when you haven't named that speaker."),
            ("Can I use Logseq instead?", "Yes, with Logseq OG, which keeps a graph as Markdown files. Meeting notes and the daily note both come in a Logseq format, with page properties and TODO and DONE actions; choose your graph's pages folder for meeting notes. Logseq's newer database version imports Markdown instead of reading a folder, so it won't pick up new notes on its own."),
        ],
        "related": ["claude-code-codex-meeting-notes", "local-ai-meeting-notes-mac", "open-source-ai-meeting-notes"],
    },
    {
        "slug": "rewind-limitless-mac-alternatives",
        "kind": "question",
        "published": "2026-11-26",
        "updated": "2026-11-26",
        "updated_label": "November 26, 2026",
        "title": "Best Rewind AI & Limitless Mac Alternatives (2026)",
        "description": "Rewind and Limitless stopped Mac capture after Meta's acquisition. Compare open-source and local Mac screen memory and meeting alternatives in 2026.",
        "eyebrow": "Mac recall",
        "h1": "Best Rewind AI and Limitless Mac alternatives after the Meta shutdown",
        "lead": "After Meta acquired Limitless in December 2025, the Rewind / Limitless Mac app disabled screen and audio capture on December 19, 2025, and Limitless stopped selling its Pendant. If you relied on local screen search and bot-free call recall on macOS, here are the active local replacements and how they differ.",
        "read_time": "6 min read",
        "body": """
        <h2>What happened to Rewind and Limitless on Mac</h2>
        <p>Rewind introduced searchable local screen history and meeting recall on Apple Silicon before rebranding to Limitless and focusing on its wearable Pendant. Following Meta's acquisition in December 2025, a final Mac update disabled screen and audio capture, Pendant sales stopped, and the old rewind.ai domain moved on. Anyone wanting local workday recall on macOS now needs an actively maintained replacement with clear data ownership so the same shutdown cannot lock away their history again.</p>

        <h2>Active Mac alternatives, side by side</h2>
        <div class="guide-table-wrap">
          <table class="guide-table">
            <thead><tr><th scope="col">App</th><th scope="col">Screen recall</th><th scope="col">Meeting notes</th><th scope="col">Default retention &amp; encryption</th><th scope="col">License &amp; price</th></tr></thead>
            <tbody>
              <tr><th scope="row"><a href="#lokalbot">LokalBot</a></th><td>Activity-first timeline; opt-in OCR text &amp; AES-GCM encrypted screenshots</td><td>Bot-free two-track capture, fine-tuned Qwen3-ASR + Qwen3.5 4B v4</td><td>14-day default auto-delete; screenshots AES-GCM encrypted</td><td>GPLv3 · free</td></tr>
              <tr><th scope="row"><a href="#screenpipe">Screenpipe</a></th><td>Continuous 24/7 screen + audio capture</td><td>Local Whisper + speaker ID + summary pipe</td><td>Configurable (~30 GB/mo); encryption optional</td><td>Source-available · free personal / $21-$42/mo work</td></tr>
              <tr><th scope="row"><a href="#meetings-only">Granola / MacWhisper</a></th><td>None</td><td>Bot-free meeting notes (Granola cloud; MacWhisper local files/calls)</td><td>Granola: 30d free cloud · MacWhisper: local files</td><td>Proprietary</td></tr>
            </tbody>
          </table>
        </div>

        <section class="tool" id="lokalbot" aria-labelledby="lokalbot-title">
          <h3 id="lokalbot-title">LokalBot: opt-in encrypted Mac timeline, screen search, and local meetings</h3>
          <p class="tool-tagline">GPLv3 · Free · Apple Silicon Mac + Windows/Linux alpha + E2EE mobile companion</p>
          <p>LokalBot picks up the core Rewind workflow without continuous video bloat or vendor lock-in. Out of the box, it logs app and window activity on a color-coded day timeline. Turning on screen memory adds Apple Vision OCR (120 ms synthetic / 243 ms real screenshots, 0.971 F1) and AES-GCM encrypted screenshots searchable by keywords and visual meaning via EmbeddingGemma 2, automatically pruned after 14 days by default. Pair that with bot-free meeting notes, local Ask, 56 ms autocomplete, and read-only MCP for Claude Code and Cursor. See <a href="lokalbot-vs-rewind">LokalBot vs Rewind / Limitless</a>.</p>
        </section>

        <section class="tool" id="screenpipe" aria-labelledby="screenpipe-title">
          <h3 id="screenpipe-title">Screenpipe: continuous 24/7 capture for developer automations</h3>
          <p class="tool-tagline">Source-available commercial license · macOS (ARM &amp; Intel), Windows, Linux</p>
          <p>Screenpipe is closest to Rewind's always-on capture model, storing roughly 30 GB per month of continuous screen and audio context and exposing a local REST API and MCP server. It fits developers scripting custom pipes over raw capture who accept a source-available commercial license for work ($21/mo Basic, $42/seat Business). See <a href="lokalbot-vs-screenpipe">LokalBot vs Screenpipe</a>.</p>
        </section>

        <section class="tool" id="meetings-only" aria-labelledby="meetings-only-title">
          <h3 id="meetings-only-title">Meetings-only replacements (Meetily, Anarlog, MacWhisper, Granola)</h3>
          <p class="tool-tagline">Use these if you only needed Rewind for call transcripts</p>
          <p>If you never used Rewind's screen timeline and only cared about bot-free meeting summaries, dedicated notetakers such as <a href="lokalbot-vs-meetily">Meetily</a>, <a href="lokalbot-vs-hyprnote">Anarlog</a>, <a href="lokalbot-vs-macwhisper">MacWhisper</a>, or <a href="lokalbot-vs-granola">Granola</a> cover meetings without screen permissions. Compare the full local field in <a href="best-local-ai-meeting-notes">Best local AI meeting note takers</a>.</p>
        </section>

        <h2>How to avoid another acquisition shutdown</h2>
        <ul>
          <li><strong>Pick OSI open source (GPLv3 or MIT):</strong> Even if a maintainer stops tomorrow, the source code and your local build remain runnable.</li>
          <li><strong>Verify offline operation:</strong> Confirm that transcription, OCR, and search run without an activation server or login token.</li>
          <li><strong>Check plain-file exports:</strong> Automatic Markdown and SQLite ownership ensures you can move your meeting archive to Obsidian or Git at any time.</li>
        </ul>
        """,
        "faq": [
            ("Is LokalBot an exact video-scrubber clone of Rewind?", "No. Rewind recorded continuous compressed screen video so you could scrub frame by frame. LokalBot focuses on searchable activity, opt-in OCR text, AES-GCM encrypted periodic screenshots (14-day default retention), and full bot-free meeting notes. You get fast keyword and semantic search across what you saw and heard without massive video archives."),
            ("Can LokalBot run if I also switch between Mac and Windows or Linux?", "Yes. LokalBot uses the same local SQLite library format across its Apple Silicon Mac app and its Windows and Linux (alpha) Rust + GPUI app."),
            ("What if I want to replace a Limitless Pendant for in-person meetings?", "LokalBot offers free iOS and Android companion apps that record in-person audio and sync end-to-end encrypted over LAN or Tailscale straight to your computer for local transcription, with zero cloud subscription. See LokalBot vs Plaud for details."),
        ],
        "related": ["open-source-windows-recall-alternative", "best-local-ai-meeting-notes", "open-source-ai-meeting-notes"],
    },
    {
        "slug": "open-source-windows-recall-alternative",
        "kind": "question",
        "published": "2026-11-26",
        "updated": "2026-11-26",
        "updated_label": "November 26, 2026",
        "title": "Open-Source Windows Recall Alternative (Opt-In & Encrypted)",
        "description": "Want searchable screen and meeting memory on Windows without Microsoft Recall or Copilot+ NPU lock-in? Compare LokalBot's opt-in, encrypted Rust app.",
        "eyebrow": "Windows privacy",
        "h1": "An open-source Windows Recall alternative that is opt-in and encrypted",
        "lead": "Microsoft Recall requires a Copilot+ PC NPU, ships as closed-source OS plumbing, and raised lasting privacy concerns about always-on screen snapshots. LokalBot for Windows (alpha) offers an open-source (GPLv3), opt-in, encrypted alternative that runs on any Windows 10 or 11 x64 PC.",
        "read_time": "5 min read",
        "body": """
        <h2>Microsoft Recall vs LokalBot on Windows</h2>
        <div class="guide-table-wrap">
          <table class="guide-table">
            <thead><tr><th scope="col">Property</th><th scope="col">LokalBot (Windows alpha)</th><th scope="col">Microsoft Windows Recall</th></tr></thead>
            <tbody>
              <tr><th scope="row">Hardware required</th><td>Any Windows 10 or 11 x64 PC (Vulkan GPU, experimental CUDA, or CPU)</td><td>Copilot+ PC with 40+ TOPS NPU</td></tr>
              <tr><th scope="row">Default capture on install</th><td>App names and window titles only; screen text and screenshots are off until enabled</td><td>Periodic full-screen snapshots once enabled in Windows setup</td></tr>
              <tr><th scope="row">Encryption &amp; retention</th><td>Screenshots AES-GCM encrypted; 14-day default auto-delete</td><td>Windows Hello / BitLocker / VBS enclave protected; configurable disk cap</td></tr>
              <tr><th scope="row">Bot-free meeting notes</th><td>Built-in WASAPI loopback two-track capture, local Qwen3-ASR + Qwen3.5 4B v4</td><td>No dedicated meeting notes or action-item pipeline</td></tr>
              <tr><th scope="row">Exclusions &amp; auditability</th><td>Per-app exclusions, private browser windows ignored, full GPLv3 Rust source</td><td>App and website filters; closed source</td></tr>
              <tr><th scope="row">Coding agent access</th><td>Read-only local CLI &amp; MCP server (off until enabled; text only, never pixels)</td><td>No local MCP server for Claude Code, Codex, or Cursor</td></tr>
            </tbody>
          </table>
        </div>

        <h2>How LokalBot keeps screen memory bounded</h2>
        <ul>
          <li><strong>Activity first, pixels opt-in:</strong> Fresh installs track only app names and window titles so you can build a workday timeline without storing a single pixel.</li>
          <li><strong>Separate consent for text vs screenshots:</strong> Enable visible text via Windows UI Automation and built-in Windows OCR without saving screenshots, or opt into AES-GCM encrypted screenshots with a 14-day default expiry.</li>
          <li><strong>Private windows and sensitive fields excluded:</strong> Private browser windows are skipped, and you can exclude any application (such as password managers or banking apps) in Settings.</li>
          <li><strong>No Microsoft account or telemetry:</strong> LokalBot installs per-user without administrator rights into <code>%LOCALAPPDATA%\\Programs\\LokalBot</code> and runs offline once models download.</li>
        </ul>

        <h2>What else comes in the same Rust + GPUI app</h2>
        <p>Unlike screen-only recorders, LokalBot pairs your day timeline with bot-free Teams, Zoom, and Google Meet recording (WASAPI process loopback on Windows 11), local transcription and summaries, push-to-talk dictation (<kbd>Alt+Space</kbd>), 56 ms local autocomplete, Obsidian Markdown export, and end-to-end encrypted sync with the iOS and Android companion apps over LAN or Tailscale. Read the full platform breakdown in <a href="local-ai-meeting-notes-windows">Local AI meeting notes on Windows</a>.</p>

        <h2>Honest alpha caveats on Windows</h2>
        <ul>
          <li>The Windows installer (<code>setup.exe</code>) and portable zip are not code-signed yet, so Windows SmartScreen asks before first launch (choose <strong>More info &gt; Run anyway</strong>). Updates check cryptographic signatures before installing.</li>
          <li>Windows on ARM is not supported yet; builds target x64 PCs.</li>
          <li>A few Mac features (Nemotron diarization, Gmail briefs, Granite Speech) are still Mac-only.</li>
        </ul>
        """,
        "faq": [
            ("Do I need a Copilot+ PC or an NPU to run LokalBot on Windows?", "No. LokalBot runs on any Windows 10 or 11 x64 machine using any Vulkan GPU (AMD, Intel, or NVIDIA), experimental CUDA on NVIDIA GPUs, or the CPU."),
            ("Does LokalBot take screenshots immediately after install?", "No. Fresh installs record app and window activity only. Reading screen text and saving AES-GCM encrypted screenshots are explicit opt-in toggles in Settings."),
            ("How does LokalBot compare to Screenpipe on Windows?", "Screenpipe records screen and audio continuously (~30 GB/mo) under a source-available commercial license. LokalBot starts activity-only, deletes captures after 14 days by default, ships built-in local summary models, and is free under GPLv3. See LokalBot vs Screenpipe."),
        ],
        "related": ["local-ai-meeting-notes-windows", "rewind-limitless-mac-alternatives", "open-source-ai-meeting-notes"],
    },
    {
        "slug": "gdpr-local-ai-meeting-notes",
        "kind": "question",
        "published": "2026-11-26",
        "updated": "2026-11-26",
        "updated_label": "November 26, 2026",
        "title": "GDPR AI Meeting Notes Without Cloud Subprocessors (2026)",
        "description": "Run GDPR-friendly AI meeting notes with zero cloud subprocessors, no DPA chain, and no bots. Compare on-device tools and participant consent rules.",
        "eyebrow": "GDPR & compliance",
        "h1": "GDPR AI meeting notes with zero cloud subprocessors",
        "lead": "Most 'GDPR-compliant' AI meeting tools still upload call audio to vendor servers and downstream LLM APIs, creating a subprocessor chain and Data Processing Agreements to review. Running speech recognition and summaries on your own computer removes cloud processors from the loop, while keeping participant consent squarely in focus.",
        "read_time": "6 min read",
        "body": """
        <h2>On-device vs EU cloud vs US cloud</h2>
        <div class="guide-table-wrap">
          <table class="guide-table">
            <thead><tr><th scope="col">Architecture</th><th scope="col">Example tools</th><th scope="col">Third-party data processors</th><th scope="col">Cross-border audio transfers</th><th scope="col">Data deletion control</th></tr></thead>
            <tbody>
              <tr><th scope="row">On-device local models</th><td>LokalBot (built-in defaults), Meetily Community</td><td>None for audio, transcripts, or summaries</td><td>Zero bytes leave your computer</td><td>Delete a local SQLite row or folder immediately</td></tr>
              <tr><th scope="row">EU-hosted cloud</th><td><a href="lokalbot-vs-jamie">Jamie</a>, <a href="lokalbot-vs-tldv">tl;dv</a> (EU region)</td><td>Vendor + cloud infrastructure / LLM subprocessors (requires DPA)</td><td>Audio/text transmitted to EEA cloud servers</td><td>Request deletion via vendor account &amp; retention policy</td></tr>
              <tr><th scope="row">US-hosted cloud</th><td><a href="lokalbot-vs-granola">Granola</a>, <a href="lokalbot-vs-otter">Otter</a>, <a href="lokalbot-vs-fireflies">Fireflies</a>, <a href="lokalbot-vs-fathom">Fathom</a></td><td>Vendor + multiple US cloud/AI subprocessors (DPA + SCCs)</td><td>Audio/text transmitted outside EEA</td><td>Subject to vendor retention windows &amp; enterprise tiers</td></tr>
            </tbody>
          </table>
        </div>

        <h2>What local processing solves under GDPR, and what it does not</h2>
        <p>When LokalBot runs with its built-in Apache-2.0 local models (Qwen3-ASR for transcription, Qwen3.5 4B LokalBot v4 for summaries, EmbeddingGemma 2 for search), no audio, transcript, or summary touches a LokalBot server because no LokalBot cloud backend exists. That eliminates third-party processor agreements (Article 28), cloud subprocessor audits, and international data transfers (Chapter V) for your meeting pipeline.</p>
        <p>Local software does <strong>not</strong> waive your legal duties as the data controller:</p>
        <ul>
          <li><strong>Transparency and consent (Articles 6 &amp; 13):</strong> Recording without a visible bot never excuses secret recording. Tell every participant before recording starts and follow applicable national wiretapping and workplace laws (such as Germany's Section 201 StGB or EU employment rules).</li>
          <li><strong>Data minimization and retention (Article 5):</strong> Keep only what you need. LokalBot starts day tracking activity-only, keeps screen captures off unless enabled, expires screenshots after 14 days by default, and lets you delete individual meetings or audio tracks locally.</li>
          <li><strong>Opt-in remote boundaries:</strong> If you later connect an external API, Claude/ChatGPT plan, or cloud-synced Obsidian vault, that external service becomes a processor for whatever you send to it. LokalBot requires explicit per-origin approval before sending context off the machine.</li>
        </ul>

        <h2>A 5-point verification checklist for DPOs and IT teams</h2>
        <ol>
          <li><strong>Inspect network traffic in flight:</strong> Download the open models once, disable automatic update checks, disconnect Wi-Fi (or monitor with Little Snitch / firewall logs), and run a full meeting record, transcribe, and summarize pass with zero outbound packets.</li>
          <li><strong>Verify storage encryption:</strong> Confirm the local library sits inside your OS-encrypted disk (FileVault, BitLocker, or LUKS), with LokalBot encrypting saved screenshots and speaker voice profiles at rest via AES-GCM.</li>
          <li><strong>Verify fresh-install consent prompts:</strong> Confirm that fresh installs ask via a local notification before recording a detected call rather than silently auto-recording every meeting.</li>
          <li><strong>Audit the license and source:</strong> Review LokalBot's GPLv3 repository and <a href="/privacy">PRIVACY.md</a> contract directly instead of relying on marketing claims.</li>
          <li><strong>Check language support:</strong> LokalBot's UI supports 24 languages (including <a href="/de">German</a>, <a href="/fr">French</a>, <a href="/es">Spanish</a>, and <a href="/pt">Portuguese</a>), and Qwen3-ASR 1.7B transcribes 52 languages locally.</li>
        </ol>
        """,
        "faq": [
            ("Do I need a Data Processing Agreement (DPA) to use LokalBot?", "When you run LokalBot with its built-in local models, no meeting data is sent to the LokalBot project or any hosted service, so there is no LokalBot cloud processor handling your personal data. If you opt into an external API or cloud plan in Settings, you need a DPA with that provider."),
            ("Is bot-free local recording automatically legal under GDPR?", "No. GDPR requires a lawful basis (often explicit consent) and clear notice to every participant before recording a call, regardless of whether a bot joins or the audio stays on your laptop."),
            ("How does LokalBot compare to European cloud notetakers like Jamie?", "Jamie hosts notes on EU servers in Frankfurt and deletes raw audio after transcription, which still requires trusting cloud servers and paying EUR 24-47/mo. LokalBot processes and stores everything on your own device for free under GPLv3. See LokalBot vs Jamie."),
        ],
        "related": ["ai-notetaker-bots-blocked-at-work", "best-local-ai-meeting-notes", "open-source-ai-meeting-notes"],
    },
    MEETING_NOTES_ROUNDUP,
    ROUNDUP,
]

REFERENCES = [
    {
        "slug": "about",
        "eyebrow": "Fact sheet",
        "h1": "About LokalBot",
        "description": "What LokalBot is, what it runs, and what it does not do: a free, open-source app for bot-free meeting notes, local transcription, and search on Mac, with Windows and Linux in alpha.",
        "updated": "2026-11-26",
    },
    {
        "slug": "benchmarks",
        "eyebrow": "Leaderboard",
        "h1": "Local Desktop AI Leaderboard",
        "description": "Independent, reproducible benchmarks across seven local desktop AI roles: speech-to-text vs. cloud APIs, speaker diarization, memory recall vs. restraint, 56 ms autocomplete, hybrid QMSum retrieval, structured extraction, OCR, and TTS.",
        "updated": "2026-11-26",
    },
    {
        "slug": "hardware",
        "eyebrow": "Calculator",
        "h1": "Local AI Hardware & RAM Calculator",
        "description": "Interactive client-side estimator for Apple Silicon Macs, Windows, and Linux: check disk downloads, resident RAM, GPU VRAM offload, and LokalBot's 50% memory residency cap.",
        "updated": "2026-11-26",
    },
]
