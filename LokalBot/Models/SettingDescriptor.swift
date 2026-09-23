import Foundation

struct SettingDescriptor: Identifiable {
    let id: String
    let title: String
    let category: AppState.SettingsTab
    let aliases: String

    func currentValue(in settings: AppSettings) -> String {
        if id == "settings.models" { return InferencePresentation(settings: settings).label }
        if id == "settings.effectiveScreenContextCaptureMode" { return settings.effectiveScreenContextCaptureMode.rawValue }
        if id == "settings.generationBudgetPreset" { return settings.generationBudgetPreset.displayName }
        guard let data = try? JSONEncoder().encode(settings),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = object[String(id.dropFirst("settings.".count))] else { return "Open details" }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "On" : "Off" }
            return number.stringValue
        }
        if let string = value as? String { return string.isEmpty ? "Not set" : String(string.prefix(70)) }
        if let array = value as? [Any] { return "\(array.count) selected" }
        return "Configured"
    }

    func focusTarget(in settings: AppSettings) -> String {
        if !settings.calendarDetectionEnabled,
           ["settings.useCalendarTitles", "settings.requireCalendarForBrowser"].contains(id) { return "settings.calendarDetectionEnabled" }
        if !settings.dailyMemoryExportEnabled, id == "settings.dailyMemoryExportFormat" { return "settings.dailyMemoryExportEnabled" }
        if !settings.memoryRoutinesEnabled, id == "settings.memoryRoutineWeekday" { return "settings.memoryRoutinesEnabled" }
        if ["settings.openAIBaseURL", "settings.openAIModel"].contains(id), settings.summarizerBackend != .openAICompatible {
            return "settings.summarizerBackend"
        }
        if id == "settings.ollamaBaseURL", settings.summarizerBackend != .ollama { return "settings.summarizerBackend" }
        if id == "settings.screenshotIntervalMinutes", !settings.effectiveScreenContextCaptureMode.capturesText {
            return "settings.effectiveScreenContextCaptureMode"
        }
        return id
    }

    func prerequisite(in settings: AppSettings) -> String? {
        focusTarget(in: settings) == id ? nil : "Enable the parent feature to edit this setting. Opens that control."
    }

    @MainActor
    static func search(_ query: String) -> [Self] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return all.filter { SettingsSearchRanker.matches(query: query, haystack: [$0.title, $0.aliases, $0.category.displayName]) }
            .sorted { lhs, rhs in
                func score(_ entry: Self) -> Int {
                    if entry.title.lowercased() == normalized { return 3 }
                    if entry.title.lowercased().hasPrefix(normalized) { return 2 }
                    return 1
                }
                if score(lhs) != score(rhs) { return score(lhs) > score(rhs) }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
    }

    static let all: [Self] = [
        .init(id: "settings.stopDebounceSeconds", title: "Wait before stopping", category: .recording, aliases: "stop debounce delay seconds audio"),
        .init(id: "settings.cotypingDebounceMs", title: "Pause before suggesting", category: .writing, aliases: "autocomplete delay latency milliseconds"),
        .init(id: "settings.screenshotIntervalMinutes", title: "Idle capture interval", category: .dayMemory, aliases: "screenshot frequency fallback minutes"),
        .init(id: "settings.summarizerBackend", title: "Think model backend", category: .models, aliases: "main llm remote processing destination inference think summarization apple ollama openai"),
        .init(id: "settings.openAIBaseURL", title: "OpenAI-compatible server URL", category: .models, aliases: "remote processing endpoint host base URL"),
        .init(id: "settings.openAIModel", title: "OpenAI-compatible model", category: .models, aliases: "remote inference model name"),
        .init(id: "settings.ollamaBaseURL", title: "Ollama server URL", category: .models, aliases: "local remote endpoint host"),
        .init(id: "settings.generationBudgetPreset", title: "Notes processing budget", category: .models,
              aliases: "generation budget limit tokens time requests unlimited conservative generous summary meeting notes"),
        .init(id: "settings.transcriptionModel", title: "Transcription model", category: .models, aliases: "ASR speech whisper qwen"),
        .init(id: "settings.transcriptionLanguage", title: "Transcription language", category: .models, aliases: "ASR spoken language"),
        .init(id: "settings.transcriptionPrompt", title: "Transcription vocabulary", category: .models, aliases: "names acronyms spelling"),
        .init(id: "settings.cotypingBuiltInModelID", title: "Autocomplete model", category: .models, aliases: "writing code suggestions weights"),
        .init(id: "settings.capturePrivateWindows", title: "Allow private/incognito browser windows", category: .privacy, aliases: "capturePrivateWindows"),
        .init(id: "settings.menuBarOnly", title: "Menu bar only (hide Dock icon)", category: .general, aliases: "menuBarOnly"),
        .init(id: "settings.quickRecallEnabled", title: "Enable the system-wide Ask shortcut", category: .general, aliases: "quickRecallEnabled"),
        .init(id: "settings.cotypingEnabled", title: "Enable autocomplete", category: .writing, aliases: "cotypingEnabled"),
        .init(id: "settings.cotypingMultiLine", title: "Allow multi-line suggestions", category: .writing, aliases: "cotypingMultiLine"),
        .init(id: "settings.cotypingAcceptKey", title: "Accept next", category: .writing, aliases: "cotypingAcceptKey"),
        .init(id: "settings.cotypingAcceptGranularity", title: "Each accept takes", category: .writing, aliases: "cotypingAcceptGranularity"),
        .init(id: "settings.cotypingUseAppContext", title: "Use app and window context", category: .writing, aliases: "cotypingUseAppContext"),
        .init(id: "settings.cotypingUseClipboard", title: "Use clipboard as temporary context", category: .writing, aliases: "cotypingUseClipboard"),
        .init(id: "settings.cotypingUseLocalLearning", title: "Learn locally from accepted completions", category: .writing, aliases: "cotypingUseLocalLearning"),
        .init(id: "settings.cotypingUserName", title: "Your name (optional)", category: .writing, aliases: "cotypingUserName"),
        .init(id: "settings.cotypingStyleNote", title: "Writing style (optional)", category: .writing, aliases: "cotypingStyleNote"),
        .init(id: "settings.cotypingLanguages", title: "Languages (optional)", category: .writing, aliases: "cotypingLanguages"),
        .init(id: "settings.cotypingSuggestInIntegratedTerminals", title: "Suggest in integrated terminals", category: .writing, aliases: "cotypingSuggestInIntegratedTerminals"),
        .init(id: "settings.cotypingStreamSuggestionsWhileGenerating", title: "Stream partial suggestions", category: .writing, aliases: "cotypingStreamSuggestionsWhileGenerating"),
        .init(id: "settings.cotypingInProcessRuntime", title: "Use fast in-process runtime", category: .writing, aliases: "cotypingInProcessRuntime"),
        .init(id: "settings.cotypingMatchHostStyle", title: "Match the app font and text color", category: .writing, aliases: "cotypingMatchHostStyle"),
        .init(id: "settings.cotypingAutocorrect", title: "Autocorrect the current word", category: .writing, aliases: "cotypingAutocorrect"),
        .init(id: "settings.cotypingEmoji", title: "Emoji autocomplete", category: .writing, aliases: "cotypingEmoji"),
        .init(id: "settings.cotypingMacros", title: "Macros", category: .writing, aliases: "cotypingMacros"),
        .init(id: "settings.autoRecordMode", title: "When a meeting is detected", category: .recording, aliases: "autoRecordMode"),
        .init(id: "settings.calendarDetectionEnabled", title: "Use calendar to improve detection", category: .recording, aliases: "calendarDetectionEnabled"),
        .init(id: "settings.useCalendarTitles", title: "Use calendar titles for recordings", category: .recording, aliases: "useCalendarTitles"),
        .init(id: "settings.requireCalendarForBrowser", title: "Require a calendar match for browser auto-recording", category: .recording, aliases: "requireCalendarForBrowser"),
        .init(id: "settings.autoTranscribe", title: "Transcribe automatically after each meeting", category: .recording, aliases: "autoTranscribe"),
        .init(id: "settings.autoSummarize", title: "Summarize automatically after transcription", category: .recording, aliases: "autoSummarize"),
        .init(id: "settings.echoCancellation", title: "Remove the other side from your microphone track", category: .recording, aliases: "echoCancellation"),
        .init(id: "settings.noteTemplate", title: "Notes template", category: .recording, aliases: "noteTemplate"),
        .init(id: "settings.summaryLanguage", title: "Notes language", category: .recording, aliases: "summaryLanguage"),
        .init(id: "settings.trackingEnabled", title: "Track app & window activity", category: .dayMemory, aliases: "trackingEnabled"),
        .init(id: "settings.effectiveScreenContextCaptureMode", title: "Screen context", category: .dayMemory, aliases: "effectiveScreenContextCaptureMode"),
        .init(id: "settings.meetingVisualContextEnabled", title: "Capture low-frequency visual context during meetings", category: .dayMemory, aliases: "meetingVisualContextEnabled"),
        .init(id: "settings.dayDigestAutoEnabled", title: "Generate the day digest automatically", category: .dayMemory, aliases: "dayDigestAutoEnabled"),
        .init(id: "settings.dailyMemoryExportEnabled", title: "Export a daily memory note", category: .dayMemory, aliases: "dailyMemoryExportEnabled"),
        .init(id: "settings.dailyMemoryExportFormat", title: "Format", category: .dayMemory, aliases: "dailyMemoryExportFormat"),
        .init(id: "settings.memoryRoutinesEnabled", title: "Enable safe local routines", category: .dayMemory, aliases: "memoryRoutinesEnabled"),
        .init(id: "settings.memoryRoutineWeekday", title: "Weekly log day", category: .dayMemory, aliases: "memoryRoutineWeekday"),
        .init(id: "settings.dreamingEnabled", title: "Review the day overnight", category: .dayMemory, aliases: "dreamingEnabled dream morning brief projects goals pins"),
        .init(id: "settings.retentionDays", title: "Screen context retention", category: .privacy, aliases: "delete cleanup days images"),
        .init(id: "settings.keepOCRTextForever", title: "Keep screen text forever", category: .privacy, aliases: "retention text OCR vectors"),
        .init(id: "settings.excludedApps", title: "Never capture these apps", category: .privacy, aliases: "exclude applications"),
        .init(id: "settings.excludedScreenDomains", title: "Never capture these sites", category: .privacy, aliases: "domain exclusions"),
        .init(id: "settings.cotypingExcludedApps", title: "Never suggest in these apps", category: .writing, aliases: "exclude autocomplete applications"),
        .init(id: "settings.cotypingExcludedDomains", title: "Never suggest on these sites", category: .writing, aliases: "exclude autocomplete websites"),
        .init(id: "settings.dayDigestCustomPrompt", title: "Digest instructions", category: .dayMemory, aliases: "prompt daily journal"),
        .init(id: "settings.dictationEnabled", title: "Enable dictation shortcut", category: .writing, aliases: "speech voice global"),
        .init(id: "settings.dictationTriggerMode", title: "Dictation trigger", category: .writing, aliases: "push to talk toggle"),
        .init(id: "settings.dictationOutputMode", title: "Dictation output", category: .writing, aliases: "clipboard paste focused app"),
        .init(id: "settings.dictationShowOverlay", title: "Show floating dictation status", category: .writing, aliases: "overlay pill"),
        .init(id: "settings.dictationLivePreview", title: "Show live transcript", category: .writing, aliases: "speech preview"),
        .init(id: "settings.dictationRetainAudio", title: "Keep dictation audio files", category: .writing, aliases: "speech recording retention"),
        .init(id: "settings.models", title: "Configured models", category: .models, aliases: "transcribe think autocomplete LLM backend download ollama openai"),
        .init(id: "settings.permissions", title: "Permissions", category: .privacy, aliases: "microphone screen recording accessibility input monitoring"),
        .init(id: "settings.memoryHealth", title: "Memory health", category: .advanced, aliases: "diagnostics capture recovery"),
        .init(id: "settings.resourceMonitor", title: "Resource monitor", category: .advanced, aliases: "cpu ram memory footprint"),
        .init(id: "settings.agentAccess", title: "External meeting access", category: .privacy, aliases: "mcp claude coding agent CLI"),
        .init(id: "settings.screenMemoryAccess", title: "External screen access", category: .privacy, aliases: "mcp screen memory agent"),
    ]
}
