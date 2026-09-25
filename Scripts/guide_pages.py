"""Source-backed guide content for LokalBot's search-intent pages.

Rendered by Scripts/render_web.py. Keep claims aligned with the checked-in
README and implementation; these pages intentionally avoid competitor claims.
"""

# Head and structured-data copy for web/guides.html.
GUIDES_INDEX = {
    "title": "LokalBot Guides — Private AI Meeting Notes on Mac",
    "description": "Practical guides to local AI meeting notes, offline transcription, bot-free recording, open-source privacy, model choice, Mac requirements, and comparisons.",
}

GUIDES = [
    {
        "slug": "local-ai-meeting-notes-mac",
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
          <li><strong>Hardware:</strong> LokalBot requires an Apple Silicon Mac running macOS 15 or later.</li>
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
        "slug": "offline-meeting-transcription-mac",
        "updated": "2026-09-24",
        "updated_label": "September 24, 2026",
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
        "updated": "2026-09-24",
        "updated_label": "September 24, 2026",
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
          <li>The microphone and selected meeting process produce two local audio tracks.</li>
          <li>A downloaded speech engine creates the transcript on Apple Silicon.</li>
          <li>The built-in llama.cpp backend can generate a summary locally.</li>
          <li>SQLite stores the library and full-text search index.</li>
          <li>Day tracking starts activity-only: app names and window titles. Visible text and encrypted screenshots are opt-in, permission-gated, and deleted after 14 days by default.</li>
        </ol>
        <p>Then identify the exceptions. LokalBot connects to download models and updates, to set up optional Agent Mode, and to call any non-loopback inference origin you explicitly approve. That distinction is more useful than an absolute “never connects” claim.</p>

        <h2>Check account and telemetry requirements</h2>
        <p>An app can be open source while its useful features depend on a hosted account. LokalBot has no account, subscription, analytics service, advertising SDK, or telemetry backend. Its public issue tracker provides community support, and the security policy points vulnerability reports to a private channel.</p>

        <h2>Build it yourself</h2>
        <p>The repository includes an XcodeGen project manifest and build instructions. A source build is the strongest way to connect the code you inspected with the binary you run. It also makes the trade-off explicit: local-first software still relies on macOS frameworks and bundled or downloaded model runtimes, so dependency review remains part of a serious audit.</p>
        <pre class="code" aria-label="Build LokalBot from source"><span class="c-prompt">$</span> git clone https://github.com/stevyhacker/lokalbot.git
<span class="c-prompt">$</span> cd lokalbot
<span class="c-prompt">$</span> xcodegen generate <span class="c-op">&amp;&amp;</span> open LokalBot.xcodeproj</pre>

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
        "updated": "2026-09-24",
        "updated_label": "September 24, 2026",
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
        "updated": "2026-09-12",
        "updated_label": "September 12, 2026",
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
        "updated": "2026-09-24",
        "updated_label": "September 24, 2026",
        "title": "LokalBot System Requirements for Mac",
        "description": "Check LokalBot's macOS version, Apple Silicon, memory, disk, permissions, model downloads, and offline requirements before installing.",
        "eyebrow": "Compatibility",
        "h1": "LokalBot system requirements",
        "lead": "The short version: an Apple Silicon Mac on macOS 15 or later, enough disk for your selected models, and permission to capture the audio you choose.",
        "read_time": "5 min read",
        "body": """
        <h2>Required hardware and software</h2>
        <ul>
          <li><strong>Mac:</strong> Apple Silicon — M1 or later.</li>
          <li><strong>Operating system:</strong> macOS 15.0 or later.</li>
          <li><strong>Disk:</strong> room for the app, recordings, and selected models.</li>
          <li><strong>Internet:</strong> required for the initial app and model downloads; optional for the built-in workflow after setup.</li>
        </ul>
        <p>Intel Macs are not supported. LokalBot is built around Apple Silicon acceleration, Core Audio process taps, the Neural Engine, MLX, and Metal rather than treating macOS as one target among many.</p>

        <h2>How much memory do you need?</h2>
        <p>The application runs across the supported Apple Silicon range, but local language-model choice changes the practical memory requirement. Compact built-in models start around 0.53–1.28 GB. Several balanced summary and cotyping models recommend 16 GB of unified memory. The largest long-meeting models in the catalog are roughly 16.8–17.73 GB on disk and target Macs with 32 GB or more.</p>
        <p>You do not need the largest model to record or transcribe a meeting. Choose a compact speech model and a smaller summarizer first, then move up only if the quality gain is worthwhile on your hardware.</p>

        <h2>Plan disk space by workflow</h2>
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

        <h2>Before an important meeting</h2>
        <ol>
          <li>Install the latest release and finish the selected model downloads.</li>
          <li>Confirm the required macOS permissions in System Settings.</li>
          <li>Make a short recording in the actual meeting application.</li>
          <li>Play back both the microphone and system-audio tracks.</li>
          <li>Process the recording once, offline if offline use matters.</li>
        </ol>
        """,
        "faq": [
            ("Does LokalBot support Intel Macs?", "No. Apple Silicon (M1 or later) is required."),
            ("Does it support macOS 14?", "No. The minimum supported version is macOS 15.0."),
            ("Do I need 32 GB of memory?", "No. Smaller models run on lower-memory Apple Silicon Macs. The 32 GB recommendation applies to the largest local language-model choices."),
        ],
        "related": ["local-transcription-models-mac", "offline-meeting-transcription-mac", "record-both-sides-mac-meeting-without-bot"],
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
        "description": "What LokalBot is, what it runs, and what it does not do: a free, open-source Mac app for bot-free meeting notes, local transcription, and search.",
        "updated": "2026-09-24",
    },
    {
        "slug": "benchmarks",
        "eyebrow": "Benchmarks",
        "h1": "LokalBot local model benchmarks",
        "description": "Measured speech recognition, semantic search, summary, autocomplete, and OCR results for LokalBot's local models on Apple Silicon, with methods, sources, and known gaps.",
        "updated": "2026-09-24",
    },
]
