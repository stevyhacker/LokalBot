import Foundation

/// Where a setting lives in Settings. Mirrors `AppState.SettingsTab` without
/// depending on the app target, so the CLI can group and describe settings.
enum SettingCategory: String, CaseIterable, Codable {
    case general, recording, dayMemory, writing, dictation, models, privacy, advanced
}

/// How a terminal change to a setting is authorized once the person allows
/// external agents to change settings.
enum SettingTier: String, Codable {
    /// Changes nothing about what is captured, read, recorded, or sent.
    case preference
    /// Widening it (turning it on, raising it, removing an exclusion,
    /// approving an origin) needs the person's approval in the app.
    /// Narrowing it is a preference.
    case consent
    /// Shown, never changed from the terminal.
    case readOnly
}

/// What a text setting holds, for `config describe` and the schema.
enum SettingTextFormat: String, Codable {
    case plain, url, path, commaSeparated, languageCode, modelID
}

/// One allowed value: the stable token agents read and write, and the value
/// `AppSettings` stores for it (some enums store display strings or key codes).
struct SettingChoice: Equatable, ExpressibleByStringLiteral {
    let token: String
    let stored: JSONValue

    init(_ token: String, stored: JSONValue) {
        self.token = token
        self.stored = stored
    }

    init(stringLiteral token: String) {
        self.init(token, stored: .string(token))
    }
}

enum SettingKind: Equatable {
    case bool
    case integer(ClosedRange<Int>?)
    case number(ClosedRange<Double>?)
    case text(SettingTextFormat)
    case textList
    case choice([SettingChoice])
    case choiceList([SettingChoice])
    /// A nested value (a shortcut, a model description) reported as stored.
    case structured

    var typeName: String {
        switch self {
        case .bool: "boolean"
        case .integer: "integer"
        case .number: "number"
        case .text: "string"
        case .textList: "string-list"
        case .choice: "choice"
        case .choiceList: "choice-list"
        case .structured: "structured"
        }
    }

    var choices: [SettingChoice]? {
        switch self {
        case .choice(let choices), .choiceList(let choices): choices
        default: nil
        }
    }
}

/// One persisted `AppSettings` key as the terminal sees it. The key is the
/// stored coding key, which Settings search already uses as `settings.<key>`.
struct SettingSpec: Equatable {
    let key: String
    let category: SettingCategory
    let title: String
    let kind: SettingKind
    let tier: SettingTier
    let aliases: String
    let summary: String

    /// The stored value presented to agents: choice values become tokens.
    /// A stored value that matches no known choice is returned unchanged.
    func presented(_ stored: JSONValue) -> JSONValue {
        switch kind {
        case .choice(let choices):
            return choices.first { $0.stored == stored }.map { JSONValue.string($0.token) } ?? stored
        case .choiceList(let choices):
            guard case .array(let values) = stored else { return stored }
            return .array(values.map { value in
                choices.first { $0.stored == value }.map { JSONValue.string($0.token) } ?? value
            })
        default:
            return stored
        }
    }

    /// What `config describe` prints.
    var descriptionJSON: JSONValue {
        var object: [String: JSONValue] = [
            "key": .string(key),
            "title": .string(title),
            "summary": .string(summary),
            "category": .string(category.rawValue),
            "tier": .string(tier.rawValue),
            "type": .string(kind.typeName),
        ]
        switch kind {
        case .integer(let range?):
            object["minimum"] = .number(Double(range.lowerBound))
            object["maximum"] = .number(Double(range.upperBound))
        case .number(let range?):
            object["minimum"] = .number(range.lowerBound)
            object["maximum"] = .number(range.upperBound)
        case .text(let format):
            object["format"] = .string(format.rawValue)
        case .choice(let choices), .choiceList(let choices):
            object["values"] = .array(choices.map { .string($0.token) })
        default:
            break
        }
        return .object(object)
    }

    /// The JSON Schema property for this key.
    var schemaProperty: JSONValue {
        var object: [String: JSONValue] = [
            "title": .string(title),
            "description": .string(summary),
            "x-lokalbot-category": .string(category.rawValue),
            "x-lokalbot-tier": .string(tier.rawValue),
        ]
        switch kind {
        case .bool:
            object["type"] = "boolean"
        case .integer(let range):
            object["type"] = "integer"
            if let range {
                object["minimum"] = .number(Double(range.lowerBound))
                object["maximum"] = .number(Double(range.upperBound))
            }
        case .number(let range):
            object["type"] = "number"
            if let range {
                object["minimum"] = .number(range.lowerBound)
                object["maximum"] = .number(range.upperBound)
            }
        case .text(let format):
            object["type"] = "string"
            if format == .url {
                object["format"] = "uri"
            } else if format != .plain {
                object["x-lokalbot-format"] = .string(format.rawValue)
            }
        case .textList:
            object["type"] = "array"
            object["items"] = ["type": "string"]
        case .choice(let choices):
            object["type"] = "string"
            object["enum"] = .array(choices.map { .string($0.token) })
        case .choiceList(let choices):
            object["type"] = "array"
            object["uniqueItems"] = true
            object["items"] = ["type": "string", "enum": .array(choices.map { .string($0.token) })]
        case .structured:
            break
        }
        return .object(object)
    }
}

/// Every persisted `AppSettings` key, for `lokalbot-cli config` and the app's
/// control channel. `AppSettingsRegistryTests` keeps this table complete and
/// its choices identical to the real enums.
enum SettingRegistry {
    /// Coding keys that are bookkeeping, not settings: never listed or changed.
    static let internalKeys: Set<String> = [
        "meetingSettingsVersion",
        "cotypingSettingsVersion",
        "languageHint",
        "dreamingFirstEligibleDayKey",
        "chatGPTPlanNoticeAcknowledged",
    ]

    static func spec(for key: String) -> SettingSpec? {
        byKey[key]
    }

    /// Settings matching every word of the query in the key, title, aliases,
    /// summary, or category, best matches first.
    static func search(_ query: String) -> [SettingSpec] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return all
            .filter {
                SettingsSearchRanker.matches(query: query, haystack: [
                    $0.key, $0.title, $0.aliases, $0.summary, $0.category.rawValue,
                ])
            }
            .sorted { lhs, rhs in
                func score(_ spec: SettingSpec) -> Int {
                    let title = spec.title.lowercased()
                    if spec.key.lowercased() == normalized || title == normalized { return 3 }
                    if title.hasPrefix(normalized) { return 2 }
                    return 1
                }
                if score(lhs) != score(rhs) { return score(lhs) > score(rhs) }
                return lhs.key < rhs.key
            }
    }

    static var jsonSchema: JSONValue {
        [
            "$schema": "https://json-schema.org/draft/2020-12/schema",
            "title": "LokalBot settings",
            "description": "Keys accepted by lokalbot-cli config. Values use the tokens listed here.",
            "type": "object",
            "properties": .object(Dictionary(uniqueKeysWithValues: all.map { ($0.key, $0.schemaProperty) })),
        ]
    }

    private static let byKey = Dictionary(uniqueKeysWithValues: all.map { ($0.key, $0) })

    private static func entry(
        _ key: String,
        _ category: SettingCategory,
        _ title: String,
        _ kind: SettingKind,
        _ tier: SettingTier = .preference,
        aliases: String = "",
        summary: String
    ) -> SettingSpec {
        SettingSpec(key: key, category: category, title: title, kind: kind,
                    tier: tier, aliases: aliases, summary: summary)
    }

    private static let hours: SettingKind = .integer(0...23)

    private static let reasoningLevels: SettingKind = .choice([
        "automatic", "off", "minimal", "low", "medium", "high", "xhigh", "max",
    ])

    static let all: [SettingSpec] = general + recording + dayMemory + privacy + models + writing + dictation

    private static let general: [SettingSpec] = [
        entry("menuBarOnly", .general, "Menu bar only (hide Dock icon)", .bool,
              summary: "Run from the menu bar without a Dock icon or a window at launch."),
        entry("appTheme", .general, "Theme", .choice(["system", "light", "dark"]),
              aliases: "appearance dark mode light mode color scheme",
              summary: "Window appearance: match the system, light, or dark."),
        // The CLI target doesn't compile AppLanguage; SettingRegistryTests keeps
        // this list in step with AppLanguage.allCases.
        entry("appLanguage", .general, "App language",
              .choice([
                  "system", .init("english", stored: "en"), .init("simplifiedChinese", stored: "zh-Hans"),
                  .init("traditionalChinese", stored: "zh-Hant"),
                  .init("hindi", stored: "hi"), .init("spanish", stored: "es"), .init("arabic", stored: "ar"),
                  .init("french", stored: "fr"), .init("bengali", stored: "bn"), .init("portuguese", stored: "pt"),
                  .init("indonesian", stored: "id"), .init("urdu", stored: "ur"), .init("russian", stored: "ru"),
                  .init("german", stored: "de"), .init("japanese", stored: "ja"), .init("nigerianPidgin", stored: "pcm"),
                  .init("egyptianArabic", stored: "ar-EG"), .init("marathi", stored: "mr"), .init("vietnamese", stored: "vi"),
                  .init("telugu", stored: "te"), .init("swahili", stored: "sw"), .init("hausa", stored: "ha"),
                  .init("korean", stored: "ko"), .init("italian", stored: "it"), .init("serbianLatin", stored: "sr-Latn"),
              ]),
              aliases: "interface language English Chinese Hindi Spanish Arabic French Bengali Portuguese Indonesian "
                  + "Urdu Russian German Japanese Nigerian Pidgin Egyptian Arabic Marathi Vietnamese Telugu Swahili Hausa Korean "
                  + "Traditional Chinese Italian Serbian Montenegrin",
              summary: "Interface language: follow the system or choose one of the supported languages."),
        entry("textSize", .general, "Text size", .choice(["small", "standard", "large", "larger", "largest"]),
              aliases: "font size larger text smaller text zoom readability",
              summary: "App-wide text size."),
        entry("quickRecallEnabled", .general, "Enable the system-wide Ask shortcut", .bool, .consent,
              aliases: "quick recall global hotkey",
              summary: "Register a global shortcut that opens Ask from any app."),
        entry("quickRecallShortcut", .general, "Ask shortcut", .structured,
              aliases: "quick recall hotkey keyboard key combination",
              summary: "Key combination that opens Ask, as a key code and modifier flags."),
    ]

    private static let recording: [SettingSpec] = [
        entry("autoRecordMode", .recording, "When a meeting is detected",
              .choice([
                  .init("automatic", stored: "Record automatically"),
                  .init("ask", stored: "Ask via notification"),
                  .init("manual", stored: "Never auto-record"),
              ]),
              .consent, aliases: "auto record detection notification",
              summary: "Record detected meetings automatically, ask with a notification, or never record automatically."),
        entry("stopDebounceSeconds", .recording, "Wait before stopping", .number(5...120),
              aliases: "stop debounce delay seconds audio",
              summary: "Seconds the meeting app's audio must be gone before the recording stops."),
        entry("calendarDetectionEnabled", .recording, "Use calendar to improve detection", .bool, .consent,
              aliases: "calendar events detection",
              summary: "Read the Mac calendar to confirm meetings and title recordings."),
        entry("useCalendarTitles", .recording, "Use calendar titles for recordings", .bool,
              summary: "Name recordings after the matched calendar event."),
        entry("requireCalendarForBrowser", .recording, "Require a calendar match for browser auto-recording", .bool,
              .consent,
              summary: "Only auto-record a browser meeting when a calendar event with a meeting link backs it. Turning it off widens auto-recording."),
        entry("autoTranscribe", .recording, "Transcribe automatically after each meeting", .bool,
              summary: "Transcribe each meeting when it ends."),
        entry("autoSummarize", .recording, "Summarize automatically after transcription", .bool,
              summary: "Write meeting notes once transcription finishes."),
        entry("echoCancellation", .recording, "Remove the other side from your microphone track", .bool,
              aliases: "echo cancellation headphones",
              summary: "Subtract the system-audio track from the microphone track before transcription."),
        entry("noteTemplate", .recording, "Notes template",
              .choice(["meeting", "lecture", "studyGuide", "podcast", "freeform"]),
              aliases: "summary sections headings",
              summary: "Section headings the notes use: meeting, lecture, study guide, podcast, or free-form."),
        entry("summaryLanguage", .recording, "Notes language", .text(.languageCode),
              aliases: "summary language translate",
              summary: "Language of meeting notes: \"match\" follows the transcript, a language code forces one, \"custom:<name>\" names another."),
        entry("meetingNotesUseCalendarContext", .recording, "Give notes the calendar title and invited names", .bool,
              .consent, aliases: "attendees participants names summary context",
              summary: "Let meeting notes use the calendar title and invited names as context."),
        entry("meetingNotesUseScreenTitles", .recording, "Give notes the titles of documents on screen", .bool,
              .consent, aliases: "screen documents slides summary context",
              summary: "Let meeting notes use the titles of documents on screen during the call."),
        entry("useCalendarAgenda", .recording, "Use invitation agendas", .bool, .consent,
              aliases: "agenda calendar invitation notes description",
              summary: "Read the invitation agenda and save it with calendar-matched recordings."),
        entry("meetingNoteExportEnabled", .recording, "Export a note for each meeting", .bool, .consent,
              aliases: "obsidian logseq markdown vault meeting notes export folder",
              summary: "Write one note per meeting to the meeting note export folder."),
        entry("meetingNoteExportFolder", .recording, "Meeting note export folder", .text(.path), .consent,
              aliases: "obsidian logseq markdown vault meeting notes export folder",
              summary: "Folder that receives one note per meeting."),
        entry("meetingNoteExportFormat", .recording, "Format",
              .choice([
                  .init("markdown", stored: "Markdown"),
                  .init("obsidian", stored: "Obsidian"),
                  .init("logseq", stored: "Logseq"),
              ]),
              aliases: "meeting note export format obsidian logseq markdown",
              summary: "Meeting note format: Markdown, Obsidian, or Logseq."),
        entry("meetingNoteExportIncludesTranscript", .recording, "Include the transcript", .bool, .consent,
              aliases: "meeting notes export transcript",
              summary: "Add the transcript to each exported meeting note."),
        entry("multiSpeakerDiarization", .recording, "Separate speakers", .bool,
              aliases: "diarization speakers voices",
              summary: "Separate voices on the microphone and system tracks after recording."),
        entry("diarizationModel", .recording, "Speaker separation model", .choice(["community1", "nemotron3"]),
              aliases: "diarization pyannote nemotron",
              summary: "Model that separates speakers: Pyannote Community-1 or Nemotron 3."),
        entry("rememberSpeakersOnMac", .recording, "Remember speakers on this Mac", .bool, .consent,
              aliases: "voice profiles speaker recognition",
              summary: "Keep voices you confirm, to recognize those speakers in later meetings."),
        entry("microphoneIsUser", .recording, "Microphone speech is mine", .bool,
              aliases: "speaker attribution me shared microphone",
              summary: "Attribute microphone speech to you unless corrected. Turn off when several people share this Mac's microphone."),
    ]

    private static let dayMemory: [SettingSpec] = [
        entry("trackingEnabled", .dayMemory, "Track app & window activity", .bool, .consent,
              aliases: "activity timeline apps windows",
              summary: "Record the active app and window title for the day timeline."),
        entry("screenContextCaptureMode", .dayMemory, "Screen context",
              .choice([
                  .init("activityOnly", stored: "Activity only"),
                  .init("accessibleText", stored: "Text context"),
                  .init("visualContext", stored: "Text + visual context"),
              ]),
              .consent, aliases: "screen capture text screenshots ocr",
              summary: "What screen memory keeps: activity only, visible text, or text with encrypted screenshots."),
        entry("screenshotsEnabled", .dayMemory, "Screenshots (legacy switch)", .bool, .readOnly,
              summary: "Kept for older builds and set from screenContextCaptureMode. Change that instead."),
        entry("screenshotIntervalMinutes", .dayMemory, "Idle capture interval", .number(nil),
              aliases: "screenshot frequency fallback minutes",
              summary: "Minutes between fallback captures while you stay active in one place."),
        entry("meetingVisualContextEnabled", .dayMemory, "Capture low-frequency visual context during meetings", .bool,
              .consent, summary: "Capture change-driven screen context while a meeting is recording."),
        entry("suggestActionCompletion", .dayMemory, "Suggest actions that look done", .bool,
              aliases: "completed actions done mark done screen evidence",
              summary: "Offer \"Looks done?\" on open actions when retained screen text shows them finished."),
        entry("dayDigestAutoEnabled", .dayMemory, "Generate the day digest automatically", .bool,
              aliases: "journal daily summary",
              summary: "Write the day digest automatically after the digest hour."),
        entry("dayDigestHour", .dayMemory, "Day digest hour", hours,
              aliases: "journal daily summary time",
              summary: "Local hour (0–23) after which today's digest is generated."),
        entry("dayDigestCustomPrompt", .dayMemory, "Digest instructions", .text(.plain),
              aliases: "prompt daily journal",
              summary: "Extra guidance for the digest prompt. Empty keeps the built-in prompt."),
        entry("codingAgentEvidenceEnabled", .dayMemory, "Read coding agent sessions", .bool, .consent,
              aliases: "claude code codex agent transcripts sessions digest pull requests commits",
              summary: "Read local Claude Code and Codex sessions into day evidence."),
        entry("codingAgentReadsClaudeCode", .dayMemory, "Read Claude Code sessions", .bool, .consent,
              summary: "Include Claude Code sessions when coding-agent sessions are read."),
        entry("codingAgentReadsCodex", .dayMemory, "Read Codex sessions", .bool, .consent,
              summary: "Include Codex sessions when coding-agent sessions are read."),
        entry("codingAgentExcludedFolders", .dayMemory, "Never read sessions in these folders",
              .text(.commaSeparated), .consent,
              aliases: "coding agent exclude folders projects repositories",
              summary: "Comma-separated folders whose coding-agent sessions are never read."),
        entry("dailyMemoryExportEnabled", .dayMemory, "Export a daily memory note", .bool, .consent,
              aliases: "markdown obsidian logseq export",
              summary: "Write a daily memory note to the export folder."),
        entry("dailyMemoryExportFolder", .dayMemory, "Daily memory export folder", .text(.path), .consent,
              aliases: "markdown obsidian logseq export folder",
              summary: "Folder that receives the daily memory note."),
        entry("dailyMemoryExportFormat", .dayMemory, "Format",
              .choice([
                  .init("markdown", stored: "Markdown"),
                  .init("obsidian", stored: "Obsidian"),
                  .init("logseq", stored: "Logseq"),
              ]),
              aliases: "daily memory export format",
              summary: "Daily memory note format: Markdown, Obsidian, or Logseq."),
        entry("dailyMemoryExportHour", .dayMemory, "Daily memory export hour", hours,
              summary: "Local hour (0–23) at which the daily memory note is refreshed."),
        entry("dreamingEnabled", .dayMemory, "Review the day overnight", .bool,
              aliases: "dream morning brief projects goals pins",
              summary: "Compile the previous day into a morning brief and project memory overnight."),
        entry("dreamingHour", .dayMemory, "Overnight review hour", hours,
              aliases: "dream time",
              summary: "Local hour (0–23) after which the overnight review may run."),
        entry("askMemoryEnabled", .dayMemory, "Remember what I tell Ask", .bool,
              aliases: "about you remember memory facts preferences goals principles",
              summary: "Save \"Remember …\" statements from Ask and give the selected ones to the Think model."),
        entry("personalLearningEnabled", .dayMemory, "Learn about me from my meetings and work", .bool, .consent,
              aliases: "learn about me automatic facts goals profile overnight",
              summary: "After the overnight review, learn facts and goals about you from your own lines in that day's meetings."),
        entry("personalLearningFromDictation", .dayMemory, "Learn from my dictation", .bool, .consent,
              aliases: "about you learn dictation dictated speech",
              summary: "Also learn from what you dictate; the dictated words are kept, encrypted, for at most two days."),
        entry("memoryRoutinesEnabled", .dayMemory, "Enable safe local routines", .bool, .consent,
              aliases: "routines standup work log journal",
              summary: "Run the curated local routines that write into the routine folder."),
        entry("memoryRoutineFolder", .dayMemory, "Routine folder", .text(.path), .consent,
              summary: "The only folder routines write to."),
        entry("enabledMemoryRoutines", .dayMemory, "Enabled routines",
              .choiceList(["postMeetingFollowUp", "dailyStandup", "weeklyWorkLog", "unfinishedActions", "localJournal"]),
              aliases: "routines standup work log journal follow-up",
              summary: "Which routines run."),
        entry("memoryRoutineHour", .dayMemory, "Routine hour", hours,
              summary: "Local hour (0–23) at which daily routines run."),
        entry("memoryRoutineWeekday", .dayMemory, "Weekly log day", .integer(1...7),
              summary: "Weekday of the weekly work log: 1 is Sunday, 7 is Saturday."),
    ]

    private static let privacy: [SettingSpec] = [
        entry("retentionDays", .privacy, "Screen context retention", .integer(nil), .consent,
              aliases: "delete cleanup days images",
              summary: "Days screen context is kept. Shortening it deletes older captures, so it goes through the retention review."),
        entry("keepOCRTextForever", .privacy, "Keep screen text forever", .bool, .consent,
              aliases: "retention text OCR vectors",
              summary: "Keep captured screen text after the retention period."),
        entry("excludedApps", .privacy, "Never capture these apps", .text(.commaSeparated), .consent,
              aliases: "exclude applications",
              summary: "Comma-separated app names never captured; their time shows as Private."),
        entry("excludedScreenDomains", .privacy, "Never capture these sites", .text(.commaSeparated), .consent,
              aliases: "domain exclusions",
              summary: "Comma-separated hosts or URL prefixes excluded from screen text and pixels."),
    ]

    private static let models: [SettingSpec] = [
        entry("transcriptionModel", .models, "Transcribe model",
              .choice([
                  .init("parakeetUltra", stored: "parakeet-ultra"),
                  .init("parakeetV3", stored: "parakeet-v3"),
                  .init("parakeetV2", stored: "parakeet-v2"),
                  .init("qwenASR17B", stored: "qwen3-asr-1.7b"),
                  .init("qwenASR06B", stored: "qwen3-asr-0.6b"),
                  .init("graniteSpeech", stored: "granite-speech"),
                  .init("graniteTurbo", stored: "granite-speech-5-turbo"),
                  .init("whisperLarge", stored: "whisper-large-v3-turbo"),
                  .init("funASRNano", stored: "fun-asr-nano-2512"),
                  .init("senseVoice", stored: "sense-voice"),
                  .init("gigaamRussian", stored: "gigaam-russian"),
                  .init("cohere", stored: "cohere-transcribe"),
                  .init("remoteServer", stored: "remote-server"),
              ]),
              aliases: "ASR speech whisper qwen parakeet",
              summary: "Speech model for meetings and dictation. remoteServer uses the transcription server."),
        entry("graniteSpeechModel", .models, "Granite Speech model", .structured,
              summary: "Model and projector files used when Granite Speech is selected."),
        entry("funASRNanoModelDirectory", .models, "Fun-ASR-Nano model folder", .text(.path),
              summary: "Your sherpa-onnx model folder for Fun-ASR-Nano; never copied or deleted."),
        entry("remoteTranscriptionBaseURL", .models, "Transcription server URL", .text(.url),
              aliases: "speech to text server openai groq whisper.cpp",
              summary: "OpenAI-style speech-to-text server. Audio is sent only to an approved origin."),
        entry("remoteTranscriptionModel", .models, "Transcription server model", .text(.modelID),
              summary: "Model sent to the transcription server. Empty sends none."),
        entry("approvedRemoteTranscriptionOrigins", .models, "Origins approved for audio", .textList, .consent,
              aliases: "approval transcription server audio",
              summary: "Origins allowed to receive meeting, dictation, and live-preview audio."),
        entry("transcriptionLanguage", .models, "Transcription language", .text(.languageCode),
              aliases: "ASR spoken language",
              summary: "Spoken language: \"auto\" detects it, or a language code such as en or de."),
        entry("transcriptionPrompt", .models, "Transcription vocabulary", .text(.plain),
              aliases: "names acronyms spelling",
              summary: "Names and terms passed to prompt-capable speech models."),
        entry("autoTranscriptionVocabulary", .models, "Add known names to transcription", .bool,
              aliases: "names attendees calendar vocabulary spelling",
              summary: "Add names LokalBot already knows to prompt-capable speech models."),
        entry("semanticSearchEnabled", .models, "Semantic search", .bool,
              aliases: "embeddings embeddinggemma meaning search",
              summary: "Search by meaning with a local embedding model, downloaded on first use."),
        entry("speechVoice", .models, "Read-aloud voice",
              .choice([
                  .init("heart", stored: "af_heart"),
                  .init("bella", stored: "af_bella"),
                  .init("sarah", stored: "af_sarah"),
                  .init("sky", stored: "af_sky"),
                  .init("adam", stored: "am_adam"),
                  .init("puck", stored: "am_puck"),
                  .init("emma", stored: "bf_emma"),
                  .init("fable", stored: "bm_fable"),
                  .init("george", stored: "bm_george"),
              ]),
              aliases: "kokoro tts text to speech",
              summary: "Kokoro voice used to read text aloud."),
        entry("speechSpeed", .models, "Read-aloud speed", .number(0.5...2.0),
              aliases: "kokoro tts rate",
              summary: "Playback speed for read-aloud."),
        entry("summarizerBackend", .models, "Think model backend",
              .choice([
                  .init("builtIn", stored: "Built-in (no setup)"),
                  .init("appleIntelligence", stored: "Apple Intelligence"),
                  .init("ollama", stored: "Ollama"),
                  .init("openAICompatible", stored: "OpenAI-compatible server"),
                  .init("chatGPTPlan", stored: "ChatGPT plan"),
                  .init("claudePlan", stored: "Claude plan"),
              ]),
              aliases: "main llm remote processing destination inference think summarization apple ollama openai chatgpt claude subscription plan",
              summary: "Where the Think model runs. Remote servers receive content only after their origin is approved."),
        entry("builtInModelID", .models, "Built-in Think model", .text(.modelID),
              aliases: "gguf llama model",
              summary: "Catalog id of the on-device Think model."),
        entry("customBuiltInModels", .models, "Imported Think models", .structured, .readOnly,
              summary: "Models added from Hugging Face or a file. Managed in Settings → Models."),
        entry("ollamaBaseURL", .models, "Ollama server URL", .text(.url),
              aliases: "local remote endpoint host",
              summary: "Ollama server used when Think runs on Ollama."),
        entry("ollamaModel", .models, "Ollama model", .text(.modelID),
              summary: "Ollama model name for Think."),
        entry("openAIBaseURL", .models, "OpenAI-compatible server URL", .text(.url),
              aliases: "remote processing endpoint host base URL",
              summary: "OpenAI-compatible server used when Think runs on one."),
        entry("openAIModel", .models, "OpenAI-compatible model", .text(.modelID),
              aliases: "remote inference model name",
              summary: "Model name sent to the OpenAI-compatible server."),
        entry("openRouterDataPolicy", .models, "OpenRouter data policy", .choice(["privateOnly", "accountPolicy"]),
              .consent, aliases: "openrouter provider data collection",
              summary: "privateOnly asks OpenRouter for providers that don't collect data; accountPolicy follows your account settings."),
        entry("approvedRemoteInferenceOrigins", .models, "Origins approved for Think", .textList, .consent,
              aliases: "approval remote server",
              summary: "Origins allowed to receive transcript, screen text, and agent context, including scheduled runs."),
        entry("chatGPTPlanModel", .models, "ChatGPT plan model", .text(.modelID),
              summary: "Model slug for the ChatGPT plan."),
        entry("claudePlanModel", .models, "Claude plan model", .text(.modelID),
              summary: "Model for the Claude plan: an alias such as sonnet or a full model id. Empty uses Claude Code's default."),
        entry("generationBudgetPreset", .models, "Think processing budget",
              .choice(["conservative", "standard", "generous", "unlimited"]),
              aliases: "generation budget limit tokens time requests unlimited conservative generous summary meeting notes",
              summary: "Time and token budget for meeting notes."),
        entry("thinkReasoningLevel", .models, "Think reasoning level", reasoningLevels,
              aliases: "reasoning effort thinking budget think off low medium high",
              summary: "How much the Think model reasons. automatic keeps per-task budgets."),
        entry("agentReasoningLevel", .models, "Agent reasoning level", reasoningLevels,
              aliases: "agent mode reasoning effort",
              summary: "Agent Mode's reasoning level. Absent follows the Think reasoning level."),
        entry("cotypingBuiltInModelID", .models, "Autocomplete model", .text(.modelID),
              aliases: "writing code suggestions weights",
              summary: "Catalog id of the on-device autocomplete model."),
        entry("cotypingBackend", .models, "Autocomplete server", .choice(["onDevice", "thinkServer", "server"]),
              aliases: "run autocomplete remote cloud api key url openrouter ollama lm studio llama-server tailscale network another computer think's server request type",
              summary: "Where autocomplete runs: this Mac, Think's server, or another server."),
        entry("cotypingServerBaseURL", .models, "Autocomplete server URL", .text(.url),
              summary: "OpenAI-compatible server for autocomplete. Typing is sent only to an approved origin."),
        entry("cotypingServerModel", .models, "Autocomplete server model", .text(.modelID),
              summary: "Model id on the autocomplete server."),
        entry("cotypingThinkServerModel", .models, "Autocomplete model on Think's server", .text(.modelID),
              summary: "Model id on Think's server. Empty uses Think's model."),
        entry("cotypingServerRequestStyle", .models, "Autocomplete request type",
              .choice(["automatic", "textCompletion", "chat"]),
              summary: "Request format for the autocomplete server."),
        entry("approvedRemoteAutocompleteOrigins", .models, "Origins approved for autocomplete", .textList, .consent,
              aliases: "approval autocomplete server typing",
              summary: "Origins allowed to receive what you type for autocomplete."),
    ]

    private static let writing: [SettingSpec] = [
        entry("cotypingEnabled", .writing, "Enable autocomplete", .bool, .consent,
              aliases: "ghost text suggestions cotyping",
              summary: "Show inline suggestions as you type in other apps."),
        entry("cotypingUserName", .writing, "Your name (optional)", .text(.plain),
              summary: "Author name used as a voice cue."),
        entry("cotypingStyleNote", .writing, "Writing style (optional)", .text(.plain),
              summary: "Free-form style guidance such as concise or British spelling."),
        entry("cotypingLanguages", .writing, "Languages (optional)", .text(.commaSeparated),
              summary: "Languages you usually write in."),
        entry("cotypingExtendedContext", .writing, "Notes for autocomplete", .text(.plain),
              aliases: "glossary jargon context",
              summary: "Notes, glossary, or jargon added to the autocomplete prompt."),
        entry("cotypingMultiLine", .writing, "Allow multi-line suggestions", .bool,
              summary: "Allow suggestions that span lines."),
        entry("cotypingMaxWords", .writing, "Suggestion length", .integer(nil),
              aliases: "words length",
              summary: "Target suggestion length in words."),
        entry("cotypingDebounceMs", .writing, "Pause before suggesting", .integer(20...1_000),
              aliases: "autocomplete delay latency milliseconds",
              summary: "Milliseconds of idle typing before the first suggestion request."),
        entry("cotypingAcceptGranularity", .writing, "Each accept takes", .choice(["word", "phrase"]),
              summary: "How much the accept key takes: one word or one phrase."),
        entry("cotypingAcceptKey", .writing, "Accept next",
              .choice([.init("tab", stored: 48), .init("rightArrow", stored: 124)]),
              summary: "Key that accepts the next word or phrase."),
        entry("cotypingFullAcceptKey", .writing, "Accept the rest",
              .choice([.init("backtick", stored: 50), .init("rightArrow", stored: 124), .init("off", stored: -1)]),
              summary: "Key that accepts the whole suggestion."),
        entry("cotypingAutoAcceptTrailingPunctuation", .writing, "Accept punctuation with the word", .bool,
              aliases: "autocomplete tab full stop comma period",
              summary: "Take punctuation attached to the next word in the same press."),
        entry("cotypingEscapeBehavior", .writing, "Escape on a suggestion", .choice(["pause", "passThrough"]),
              aliases: "autocomplete esc dismiss pause suggestion",
              summary: "Escape dismisses and pauses briefly, or dismisses and passes Escape to the app."),
        entry("cotypingAddSpaceAfterAccept", .writing, "Add a space after accepting a word", .bool,
              summary: "Add or consume a space after accepting a completed word."),
        entry("cotypingExcludedApps", .writing, "Never suggest in these apps", .text(.commaSeparated), .consent,
              aliases: "exclude autocomplete applications",
              summary: "Comma-separated app names or bundle ids where autocomplete never runs."),
        entry("cotypingExcludedDomains", .writing, "Never suggest on these sites", .text(.commaSeparated), .consent,
              aliases: "exclude autocomplete websites",
              summary: "Comma-separated sites where autocomplete never runs."),
        entry("cotypingSuggestInIntegratedTerminals", .writing, "Suggest in integrated terminals", .bool, .consent,
              summary: "Allow suggestions in editor and browser terminals."),
        entry("cotypingUseAppContext", .writing, "Use app and window context", .bool, .consent,
              summary: "Use the focused app, window title, and field label as context."),
        entry("cotypingUseClipboard", .writing, "Use clipboard as temporary context", .bool, .consent,
              summary: "Use the current clipboard as context; never stored."),
        entry("cotypingUseVisibleContext", .writing, "Use visible text above the field", .bool, .consent,
              aliases: "autocomplete screen context reply message email",
              summary: "Use visible text above the field as context."),
        entry("cotypingUseWindowText", .writing, "Use the focused window as context", .bool, .consent,
              aliases: "autocomplete window screen recording ocr text recognition whole screen conversation",
              summary: "Read the focused window with on-device text recognition; held in memory only."),
        entry("cotypingUseMeetingMemory", .writing, "Use meeting and work memory", .bool, .consent,
              aliases: "autocomplete context notes decisions projects people",
              summary: "Use relevant meeting notes and work memory as context."),
        entry("cotypingUseScreenMemory", .writing, "Use screen-derived work memory", .bool, .consent,
              aliases: "autocomplete saved context screen activity",
              summary: "Use facts derived from screen memory as context."),
        entry("cotypingUseLocalLearning", .writing, "Learn locally from accepted completions", .bool, .consent,
              summary: "Keep accepted completions, encrypted on this Mac, to improve later suggestions."),
        entry("cotypingLearningExamplesInPrompt", .writing, "Learned examples per suggestion", .integer(1...5),
              summary: "Similar accepted completions added to each request."),
        entry("cotypingMatchHostStyle", .writing, "Match the app font and text color", .bool,
              summary: "Draw suggestions in the field's font and color."),
        entry("cotypingMirrorPreference", .writing, "Suggestion display",
              .choice(["auto", "alwaysInline", "alwaysMirror"]),
              summary: "Show suggestions inline at the caret, in a popup, or choose automatically."),
        entry("cotypingAutocorrect", .writing, "Autocorrect the current word", .bool,
              summary: "Offer a one-key correction for the word you are typing."),
        entry("cotypingEmoji", .writing, "Emoji autocomplete", .bool,
              summary: "Complete :shortcode: emoji."),
        entry("cotypingMacros", .writing, "Macros", .bool,
              summary: "Complete /macros such as math, dates, units, and currency."),
        entry("cotypingInProcessRuntime", .writing, "Use fast in-process runtime", .bool,
              summary: "Run the on-device autocomplete model in process instead of through llama-server."),
    ]

    private static let dictation: [SettingSpec] = [
        entry("dictationEnabled", .dictation, "Enable dictation shortcut", .bool, .consent,
              aliases: "speech voice global",
              summary: "Register the global dictation shortcut."),
        entry("dictationIntent", .dictation, "Dictation mode",
              .choice([.init("transcribe", stored: "Transcribe"), .init("compose", stored: "Compose")]),
              aliases: "compose rewrite transcribe",
              summary: "Paste what you said, or compose a message from it with the Think model."),
        entry("dictationTriggerMode", .dictation, "Dictation trigger",
              .choice([
                  .init("pushToTalk", stored: "Push to talk"),
                  .init("toggle", stored: "Toggle"),
                  .init("tapOrHold", stored: "Tap or hold"),
              ]),
              aliases: "push to talk toggle",
              summary: "Hold to talk, press to start and stop, or either."),
        entry("dictationShortcut", .dictation, "Dictation shortcut", .structured,
              aliases: "hotkey keyboard key combination change",
              summary: "Key combination for dictation, as a key code and modifier flags."),
        entry("dictationOutputMode", .dictation, "Dictation output",
              .choice([
                  .init("pasteIntoFocusedApp", stored: "Paste into focused app"),
                  .init("copyToClipboard", stored: "Copy to clipboard"),
                  .init("showInLokalBot", stored: "Show in LokalBot"),
              ]),
              aliases: "clipboard paste focused app",
              summary: "Where dictated text goes."),
        entry("dictationShowOverlay", .dictation, "Show floating dictation status", .bool,
              aliases: "overlay pill",
              summary: "Show the floating status pill while dictating."),
        entry("dictationPlaysStartSound", .dictation, "Play a sound when the microphone is ready", .bool,
              aliases: "dictation start cue chime beep tone",
              summary: "Play a short sound once the microphone delivers audio."),
        entry("dictationMicrophoneID", .dictation, "Microphone", .text(.plain),
              aliases: "dictation input device airpods headset bluetooth built-in macbook mic",
              summary: "Capture device id for dictation. Empty follows the macOS default input."),
        entry("dictationLivePreview", .dictation, "Show live transcript", .bool,
              aliases: "speech preview",
              summary: "Show a live transcript while you speak."),
        entry("dictationRetainAudio", .dictation, "Keep dictation audio files", .bool, .consent,
              aliases: "speech recording retention",
              summary: "Keep the audio of each dictation."),
        entry("dictationUseScreenContext", .dictation, "Use the focused window as context", .bool, .consent,
              aliases: "dictation compose screenshot screen recording ocr window",
              summary: "Let Compose read the focused window."),
        entry("dictationUseVisibleContext", .dictation, "Use visible text above the field", .bool, .consent,
              aliases: "dictation compose screen context messages accessibility",
              summary: "Let Compose use visible text above the field."),
        entry("dictationUseMeetingMemory", .dictation, "Use meeting and work memory", .bool, .consent,
              aliases: "dictation compose saved facts notes context",
              summary: "Let Compose use meeting notes and work memory."),
        entry("dictationUseScreenMemory", .dictation, "Use screen-derived work memory", .bool, .consent,
              aliases: "dictation compose saved screen facts context",
              summary: "Let Compose use facts derived from screen memory."),
        entry("dictationCompositionBuiltInModelID", .dictation, "Compose model", .text(.modelID),
              summary: "On-device model used only for Compose. Empty uses the Think model."),
    ]
}
