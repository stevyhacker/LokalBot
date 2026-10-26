"""Posts for lokalbot.com/blog: releases, benchmarks, and notes on how LokalBot is built.

Rendered by Scripts/render_web.py into web/blog.html, web/blog/<slug>.html, and
the Atom feed at web/blog/feed.xml. Newest first. Keep product facts aligned
with the README. A post about something published in full elsewhere summarizes
it and links to the original instead of copying it.

Bodies are served from /blog/<slug>, so every internal link and image path
must be root-relative ("/benchmarks", "/assets/blog/...").
"""

# Head and structured-data copy for web/blog.html.
BLOG_INDEX = {
    "title": "LokalBot Blog — Releases, Benchmarks, and Build Notes",
    "description": "News from the LokalBot project: releases, local model benchmarks, and notes on how the app is built. Subscribe with the Atom feed.",
    "h1": "Blog",
    "lead": "Releases, local model benchmarks, and notes on how LokalBot is built. When something is posted elsewhere first, the full version ends up here.",
}

POSTS = [
    {
        "slug": "recall-vs-restraint-memory-benchmark",
        "published": "2026-10-23",
        "updated": "2026-10-25",
        "title": "Recall vs. Restraint: Testing Which Local Models Know When Not to Save a Memory",
        "description": "A 120-case benchmark of local models writing personal memories, scored on what they save and on what they correctly leave out: Qwen3.5 4B and 9B, Hy-Memory 30B-A3B, LFM2.5 24B-A2B, and MemT-1.0-Nano.",
        "eyebrow": "Benchmark",
        "h1": "Recall vs. restraint: which local models know when not to save a memory",
        "lead": "A memory writer has two jobs: save what is useful, and leave out everything else. Most memory benchmarks only measure the first. This one measures both.",
        "read_time": "6 min read",
        "body": """
        <h2>Why restraint matters</h2>
        <p>On Mac, LokalBot's Personal Context learns facts, preferences, goals, and principles from what you type and say, so that agents you allow can tailor their work to you. A missed memory costs little: the next conversation usually brings it up again. A wrong one is worse. It quietly ends up in the context every agent reads, and nobody notices until an answer is off.</p>
        <p>So the test asks for both recall and restraint. Three kinds of cases make the difference visible:</p>
        <ul>
          <li><strong>Who said it.</strong> “I live in Valencia” should be saved. “My colleague said, ‘I live in Valencia’” should not.</li>
          <li><strong>Already known.</strong> A new preference should be saved. One already in the known-memories list should be skipped.</li>
          <li><strong>Policy.</strong> A job title mentioned alongside a salary should be kept, and the salary left out.</li>
        </ul>

        <h2>The test</h2>
        <p>The benchmark has 120 synthetic cases arranged as 60 contrast pairs. The main comparison uses the 96 English cases: 52 contain one useful memory to extract, and in 44 the correct output is an empty list. A separate 24-case Serbian slice is reported on its own.</p>
        <p>Every model received the same application prompt with its native chat template, an enforced JSON schema, temperature 0, seed 0, thinking disabled, and a single pass, with no model-specific prompt tuning. The GGUF models ran one after another through llama.cpp on the same Ryzen 7 9700X server. This measures accuracy, not speed. A recalled memory only counts when it also cites the right source line.</p>

        <h2>Results</h2>
        <div class="guide-table-wrap">
          <table class="guide-table">
            <caption class="visually-hidden">Results on the 96 English cases</caption>
            <thead>
              <tr><th scope="col">Model</th><th scope="col">Useful memories recalled</th><th scope="col">Unwanted proposals</th><th scope="col">Empty cases correct</th></tr>
            </thead>
            <tbody>
              <tr><th scope="row">Qwen3.5 4B, Q4_K_M</th><td>30/52 (57.7%)</td><td>3</td><td>42/44 (95.5%)</td></tr>
              <tr><th scope="row">Qwen3.5 9B, Q4_K_M</th><td>37/52 (71.2%)</td><td>5</td><td>40/44 (90.9%)</td></tr>
              <tr><th scope="row">Hy-Memory 30B-A3B, official Q4_K_M</th><td>52/52 (100%)</td><td>76</td><td>0/44 (0%)</td></tr>
              <tr><th scope="row">LFM2.5 24B-A2B, QAD Q4_0</th><td>40/52 (76.9%)</td><td>53</td><td>10/44 (22.7%)</td></tr>
              <tr><th scope="row">MemT-1.0-Nano, NF4 experts / BF16 dense</th><td>51/52 (98.1%)</td><td>6</td><td>39/44 (88.6%)</td></tr>
            </tbody>
          </table>
        </div>
        <figure class="blog-figure">
          <img src="/assets/blog/memory-retention-recall-vs-restraint.webp" width="1600" height="864" alt="Bar charts comparing five models on useful memories recalled, empty cases handled correctly, and unwanted memory proposals, with the numbers from the table above." loading="lazy" decoding="async" />
          <figcaption>The 96 English cases. Higher is better in the first two columns, lower in the third.</figcaption>
        </figure>

        <h2>What stood out</h2>
        <ul>
          <li><strong>Perfect recall can hide the real problem.</strong> Hy-Memory captured every eligible memory and failed all 44 cases where the right answer was nothing, with 76 unwanted proposals. Scored on recall alone, it would look like the best model here.</li>
          <li><strong>The Qwen models held back.</strong> Both missed more valid memories, but they handled over 90% of the empty cases and made only three and five unwanted proposals.</li>
          <li><strong>LFM2.5 copied from the instructions.</strong> In several cases it proposed “I live in Belgrade”, an example from the prompt with no support in the conversation. It also often returned the source sentence instead of the required source-line ID. Accepting exact quotations recovered 9 of its 18 invalid English citations, raising exact source selection from 51 to 56 of 96 cases, but that only repairs formatting. The table keeps the strict scoring.</li>
          <li><strong>MemT-1.0-Nano was the best balance.</strong> A reader on <a href="https://www.reddit.com/r/LocalLLaMA/comments/1xd95n0/recall_vs_restraint_testing_which_local_llms_know/" target="_blank" rel="noopener">r/LocalLLaMA</a> suggested it, and it was added on October 25: 51 of 52 useful memories, 6 unwanted proposals, and 39 of 44 empty cases. On the Serbian slice it recalled 13 of 13, made 3 unwanted proposals, and passed 8 of 11 empty cases, but three of its outputs switched language or script.</li>
        </ul>

        <h2>Caveats</h2>
        <ul>
          <li>MemT-1.0-Nano ran with experimental NF4 expert offload through Transformers on a Radeon RX 6600 XT; the other models ran as GGUF files in llama.cpp on a CPU. There is no matched run of its Qwen3.6-35B-A3B backbone, so the comparison isn't controlled for hardware or precision.</li>
          <li>Each case starts from a fresh state, so MemT's persistent memory feature isn't exercised.</li>
          <li>An AI assistant wrote the cases and graded the semantic decisions with the model names visible. There is no independent human validation and no claim of statistical significance.</li>
        </ul>

        <h2>What it means for LokalBot</h2>
        <p>These results don't change LokalBot's defaults. What they confirm is that a memory writer has to be judged on what it leaves out as much as on what it finds. On Mac, the suggestions Personal Context learns appear under <strong>To review</strong> in Settings → Personal Context, where you keep or dismiss them.</p>

        <h2>Data</h2>
        <p>Everything needed to check or rerun the comparison is in the repository: the <a href="https://github.com/stevyhacker/lokalbot/tree/master/Benchmarks/MemoryRetention/2026-10-23" target="_blank" rel="noopener">benchmark folder</a> with the cases, prompts, and scorer, the <a href="https://github.com/stevyhacker/lokalbot/blob/master/Benchmarks/MemoryRetention/2026-10-23/memt-nano/REPORT.md" target="_blank" rel="noopener">MemT report</a> with every failed case, and the raw responses. Other model results are on the <a href="/benchmarks">benchmarks page</a>.</p>
        """,
    },
    {
        "slug": "windows-and-linux-alpha",
        "published": "2026-10-20",
        "updated": "2026-10-22",
        "title": "LokalBot for Windows and Linux Is in Alpha",
        "description": "LokalBot 0.11 adds a native Windows and Linux app written in Rust with GPUI: meeting notes, transcription, dictation, autocomplete, and search on your own computer, reading the same library as the Mac app.",
        "eyebrow": "Release",
        "h1": "LokalBot is on Windows and Linux, in alpha",
        "lead": "Until version 0.11, LokalBot only ran on Apple Silicon Macs. Now there is a native app for Windows and Linux with the same pages and the same library format, so a library recorded on one computer opens on the others.",
        "read_time": "5 min read",
        "body": """
        <h2>What works</h2>
        <p>The Windows and Linux app is written in Rust with <a href="https://www.gpui.rs" target="_blank" rel="noopener">GPUI</a>, the UI framework behind the Zed editor. Meetings, transcription, Ask, search, day memory, screen context, dictation, autocomplete, calendar, Agent Mode, and the CLI and MCP server for coding agents all work. Like the Mac app, it runs its models on your computer by default, and it has no account and no telemetry.</p>
        <figure class="blog-figure">
          <img src="/assets/blog/linux-meetings.webp" width="1600" height="1000" alt="LokalBot on Linux showing a meeting's recap, action items with timestamps, and decisions, next to a list of recent meetings." loading="lazy" decoding="async" />
          <figcaption>A meeting's recap and action items on Linux, with fictional demo data.</figcaption>
        </figure>

        <h2>What's still missing</h2>
        <ul>
          <li><strong>The Windows build isn't code-signed yet.</strong> SmartScreen asks before the first launch: choose <strong>More info → Run anyway</strong>.</li>
          <li><strong>Wayland support is partial.</strong> Autocomplete in other apps needs X11; on Wayland it works in the practice editor in Settings. For dictation on Wayland, bind <code>lokalbot dictate</code> to a shortcut in your desktop's settings.</li>
          <li><strong>Meeting audio is the whole computer's.</strong> On Windows and Linux LokalBot records everything the computer plays, not one app as on Mac.</li>
          <li><strong>Some features are Mac-only for now:</strong> selection actions, meeting note export, Personal Context, spoken summaries, and coding-agent sessions in day memory.</li>
        </ul>
        <p>The full list is in <a href="https://github.com/stevyhacker/lokalbot/blob/master/LinuxWindows/README.md#what-works-where" target="_blank" rel="noopener">what works where</a>.</p>
        <figure class="blog-figure">
          <img src="/assets/blog/windows-today.webp" width="1600" height="900" alt="LokalBot on Windows showing Today, with open actions and the day digest." loading="lazy" decoding="async" />
          <figcaption>Today on Windows, with fictional demo data.</figcaption>
        </figure>

        <h2>The models</h2>
        <ul>
          <li><strong>Transcription:</strong> Qwen3-ASR 0.6B through sherpa-onnx, with Parakeet v3, SenseVoice, and Whisper turbo as options.</li>
          <li><strong>Speaker separation:</strong> pyannote segmentation and TitaNet.</li>
          <li><strong>Notes and Ask:</strong> Qwen3.5 4B, the same as on Mac.</li>
          <li><strong>Search:</strong> EmbeddingGemma 2, the same as on Mac.</li>
          <li><strong>Autocomplete:</strong> LFM2.5 1.2B.</li>
        </ul>
        <p>The default download is about 4 GB. llama.cpp runs on a Vulkan GPU or the CPU, and since 0.11.3 you can choose <strong>CUDA (experimental)</strong> in Settings → Models → llama.cpp on a supported NVIDIA GPU. You can swap any model in Settings.</p>

        <h2>Install</h2>
        <ul>
          <li><strong>Windows 10 or 11, x64:</strong> run <code>LokalBot-&lt;version&gt;-windows-x86_64-setup.exe</code> from the <a href="https://github.com/stevyhacker/lokalbot/releases/latest" target="_blank" rel="noopener">latest release</a>. It installs for your user, without administrator rights. A portable zip is in the same release.</li>
          <li><strong>Linux x86_64:</strong> install the <code>.deb</code> (Debian, Ubuntu), the <code>.rpm</code> (Fedora, openSUSE), or the Arch package, or extract the <code>.tar.gz</code> and run <code>./install.sh</code>. Since 0.11.2 the <code>.deb</code>, and the <code>.rpm</code> on Fedora, add the LokalBot repository, so <code>sudo apt upgrade</code> or <code>sudo dnf upgrade</code> brings later versions.</li>
        </ul>
        <p>Linux needs glibc 2.39 or later (Ubuntu 24.04, Debian 13, Fedora 40, or newer), PulseAudio or PipeWire, and a Vulkan or OpenGL driver. See the <a href="/system-requirements">system requirements</a>.</p>

        <h2>On Omarchy and other Hyprland desktops</h2>
        <p><a href="https://omarchy.org" target="_blank" rel="noopener">Omarchy</a> already has everything LokalBot uses on Wayland: <code>grim</code> for screen context, <code>wtype</code> and <code>wl-clipboard</code> for dictation, PipeWire for meeting audio, and the Hyprland desktop portal. Install the Arch package with <code>sudo pacman -U</code>, then bind LokalBot's commands in <code>~/.config/hypr/bindings.lua</code>. These keys are free in Omarchy's defaults:</p>
        <pre class="code" aria-label="Hyprland key bindings for LokalBot on Omarchy">o.bind(<span class="c-str">"SUPER + ALT + D"</span>, <span class="c-str">"LokalBot dictation"</span>, <span class="c-str">"lokalbot dictate"</span>)
o.bind(<span class="c-str">"SUPER + ALT + A"</span>, <span class="c-str">"Ask LokalBot"</span>, <span class="c-str">"lokalbot quick-recall"</span>)</pre>
        <p>The tray icon appears in Omarchy's bar, and the dictation pill and Quick Recall float instead of tiling.</p>

        <h2>Tell us what breaks</h2>
        <p>Most testing so far has been on a handful of personal and rented machines, so reports from real hardware help the most. <a href="https://github.com/stevyhacker/lokalbot/issues/new/choose" target="_blank" rel="noopener">Open an issue</a> with your distribution, desktop, X11 or Wayland, CPU and GPU, and what you tried.</p>
        """,
    },
    {
        "slug": "porting-to-windows-and-linux-with-agents",
        "published": "2026-10-20",
        "title": "How the Windows and Linux Port Was Built with Coding Agents",
        "description": "The Windows and Linux app was ported from 150,000 lines of Swift to Rust in three days by coding agents. What made it work, how the result was checked, and a link to the full write-up.",
        "eyebrow": "Build notes",
        "h1": "How the Windows and Linux port was built",
        "lead": "The port began with one message sent from a phone on a Sunday morning and shipped as LokalBot 0.11.0 two days later. Here is the short version, with a link to the full write-up.",
        "read_time": "3 min read",
        "body": """
        <h2>A first attempt that only looked right</h2>
        <p>On October 2 a coding agent built a working Windows and Linux app with a native interface and CI on both platforms in one morning. It had its own data model and its own library on disk, so it couldn't open anything recorded on a Mac, and nothing would show when it drifted from how the Mac app behaves. That pull request was closed.</p>

        <h2>Specs before code</h2>
        <p>The second attempt spent its first hour on specs. Four agents read the Mac app's 150,000 lines of Swift without changing anything and wrote down the library format, the processing pipeline with every model prompt, every screen with its exact text, and the command-line tools and privacy rules. The core data types were written to match the Mac app's files, and every agent tested against a real library recorded by the Mac app. Six implementation agents then each took one part of the code.</p>

        <h2>How the work was checked</h2>
        <p>The port landed as one large pull request, so the checks mattered more than reading every line of the diff:</p>
        <ul>
          <li>CI runs the app on a virtual display on Linux and on Windows and takes a screenshot of every page.</li>
          <li>The live transcript is tested by playing a scripted conversation into virtual audio devices. That caught two bugs the unit tests had missed.</li>
          <li>Autocomplete is tested by typing into Notepad and checking that the suggestion appears after the cursor.</li>
          <li>End-to-end runs use the real models from an empty library: they download the models, process a short meeting, and ask a question about it.</li>
          <li>Meetings recorded on a Mac are played on Linux, with their timestamps required to line up exactly.</li>
          <li>Afterwards, the Mac and Windows/Linux apps were compared feature by feature, and the gaps were closed in five separate pull requests.</li>
        </ul>

        <h2>Read the full write-up</h2>
        <p>The full story, including the build machines, the rules for agents working side by side, and the decisions that were left to a person, is on Field Notes: <a href="https://bogosavljevic.me/blog/posts/porting-lokalbot-to-linux-and-windows/" target="_blank" rel="noopener">Porting LokalBot to Linux and Windows with agents</a>. The result is described in <a href="/blog/windows-and-linux-alpha">LokalBot is on Windows and Linux, in alpha</a>.</p>
        """,
    },
]
