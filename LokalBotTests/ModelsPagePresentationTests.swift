import XCTest
@testable import LokalBot

/// Settings › Models: what each role row says, the model set, and which
/// downloads are checked without being asked.
@MainActor
final class ModelsPagePresentationTests: XCTestCase {
    private func text(_ text: SettingsText) -> String { text.string { $0 } }

    private func presentation(_ change: (inout AppSettings) -> Void = { _ in },
                              statuses: [ModelRole: ModelRoleStatus] = [:],
                              checks: ModelCheckSummary = .init()) -> ModelsPagePresentation {
        var settings = AppSettings()
        change(&settings)
        return ModelsPagePresentation(settings: settings, statuses: statuses, checks: checks)
    }

    // MARK: Role rows

    func testEachRoleSaysItsJobItsModelWhereItRunsAndItsSize() throws {
        let page = presentation()

        XCTAssertEqual(page.rows.map(\.role), [.transcribe, .think, .autocomplete])
        let think = try XCTUnwrap(page.row(.think))
        let entry = try XCTUnwrap(ModelCatalog.entry(id: ModelCatalog.defaultSummarizationID))
        XCTAssertEqual(think.name, entry.displayName)
        XCTAssertEqual(think.job, "Writes summaries and answers questions")
        XCTAssertEqual(think.place, .thisMac)
        XCTAssertEqual(think.bytes, entry.sizeBytes)
        XCTAssertFalse(think.sizeIsEstimate)
        XCTAssertEqual(text(think.placeText), "On this Mac · \(SettingsStatus.size(try XCTUnwrap(entry.sizeBytes)))")

        // A speech model has no exact size, so its row says "about".
        let transcribe = try XCTUnwrap(page.row(.transcribe))
        let estimate = try XCTUnwrap(ModelSettingsPresentation.estimatedTranscriptionBytes(
            AppSettings().transcriptionModel, granite: AppSettings().graniteSpeechModel))
        XCTAssertTrue(transcribe.sizeIsEstimate)
        XCTAssertEqual(text(transcribe.placeText), "On this Mac · about \(SettingsStatus.size(estimate))")
        XCTAssertEqual(transcribe.job, "Turns meeting audio and dictation into text")
        XCTAssertEqual(page.row(.autocomplete)?.job, "Suggests the next words as you type")
    }

    /// The sizes are the ones the download is announced with.
    func testRowSizesMatchTheDownloadPlan() {
        let settings = AppSettings()
        let plan = OnboardingDownloadPlan(settings: settings, statuses: [:], includeAutocomplete: true,
                                          started: false, readyBefore: [], availableBytes: nil)
        let page = ModelsPagePresentation(settings: settings, statuses: [:])

        for model in plan.models {
            XCTAssertEqual(page.row(model.role)?.bytes, model.bytes, "\(model.role)")
        }
    }

    func testAModelOnAServerIsOnlineAndHasNoSize() throws {
        let page = presentation {
            $0.summarizerBackend = .openAICompatible
            $0.openAIBaseURL = "https://ai.example.test/v1"
            $0.openAIModel = "atlas-chat"
            $0.approvedRemoteInferenceOrigins = ["https://ai.example.test"]
        }

        let think = try XCTUnwrap(page.row(.think))
        XCTAssertEqual(think.place, .online("ai.example.test"))
        XCTAssertNil(think.bytes)
        XCTAssertEqual(text(think.placeText), "Online · ai.example.test")
        XCTAssertEqual(think.name, "atlas-chat")
    }

    /// A server at this Mac's own address sends nothing anywhere.
    func testAServerOnThisMacIsNotOnline() {
        let page = presentation {
            $0.summarizerBackend = .ollama
            $0.ollamaBaseURL = "http://localhost:11434"
            $0.ollamaModel = "llama"
        }

        XCTAssertEqual(page.row(.think)?.place, .thisMac)
        XCTAssertEqual(page.row(.think).map { text($0.placeText) }, "On this Mac")
    }

    func testAServerThatIsNotApprovedIsNotSetUp() {
        let page = presentation({
            $0.summarizerBackend = .openAICompatible
            $0.openAIBaseURL = "https://ai.example.test/v1"
            $0.openAIModel = "atlas-chat"
        }, statuses: [.think: .unavailable])

        XCTAssertEqual(page.row(.think)?.place, .notSetUp)
        XCTAssertEqual(page.row(.think)?.chip, .notSetUp)
        XCTAssertEqual(page.row(.think).map { text($0.placeText) }, "Online")
    }

    // MARK: Chips

    func testTheChipFollowsTheRoleStatus() {
        let page = presentation(statuses: [
            .transcribe: .ready,
            .think: .downloading(progress: 0.457),
            .autocomplete: .needsAttention("The disk is full."),
        ])

        XCTAssertEqual(page.row(.transcribe)?.chip, .ready)
        XCTAssertEqual(page.row(.transcribe)?.chipTone, .good)
        XCTAssertEqual(page.row(.think)?.chip, .downloading(0.457))
        XCTAssertEqual(page.row(.think).map { text($0.chip.text) }, "Downloading · 46%")
        XCTAssertEqual(page.row(.think)?.chipTone, .quiet)
        XCTAssertEqual(page.row(.autocomplete)?.chip, .stopped)
        XCTAssertEqual(page.row(.autocomplete)?.problem, "The disk is full.")
        XCTAssertEqual(page.row(.autocomplete)?.chipTone, .attention)

        let preparing = presentation(statuses: [.transcribe: .preparing(progress: nil, label: "Unpacking")])
        XCTAssertEqual(preparing.row(.transcribe)?.chip, .downloading(nil))
        XCTAssertEqual(preparing.row(.transcribe).map { text($0.chip.text) }, "Downloading…")
    }

    /// Nothing waits for Autocomplete's model while Autocomplete is off, so
    /// its missing download is not drawn as a warning.
    func testAMissingModelWarnsOnlyWhenItIsNeeded() {
        let off = presentation { $0.cotypingEnabled = false }
        XCTAssertEqual(off.row(.autocomplete)?.chip, .notDownloaded)
        XCTAssertEqual(off.row(.autocomplete)?.chipTone, .quiet)
        XCTAssertEqual(off.row(.think)?.chipTone, .attention)

        let on = presentation { $0.cotypingEnabled = true }
        XCTAssertEqual(on.row(.autocomplete)?.chipTone, .attention)
    }

    func testACheckShowsOnAReadyModelOnly() {
        let checks = ModelCheckSummary(testing: .transcribe, failures: [.think: "No answer", .autocomplete: "Stale"])
        let page = presentation(statuses: [.transcribe: .ready, .think: .ready, .autocomplete: .unavailable],
                                checks: checks)

        XCTAssertEqual(page.row(.transcribe)?.chip, .checking)
        XCTAssertEqual(page.row(.think)?.chip, .checkFailed)
        XCTAssertEqual(page.row(.think)?.problem, "No answer")
        // A check result for a model that is no longer here says nothing.
        XCTAssertEqual(page.row(.autocomplete)?.chip, .notDownloaded)
        XCTAssertNil(page.row(.autocomplete)?.problem)
    }

    // MARK: Model set

    func testTheModelSetIsThePresetTheChoicesMatch() throws {
        let balanced = presentation { $0 = ModelStackPreset.recommended.patch.applying(to: $0) }
        XCTAssertEqual(balanced.modelSet, .recommended)
        let bytes = try XCTUnwrap(ModelsPagePresentation.bytes(of: .recommended, settings: AppSettings()))
        XCTAssertEqual(text(balanced.modelSetHelp),
                       "\(ModelStackPreset.recommended.subtitle) \(SettingsStatus.size(bytes)) in all.")

        let lighter = presentation { $0 = ModelStackPreset.lightweight.patch.applying(to: $0) }
        XCTAssertEqual(lighter.modelSet, .lightweight)
        let lighterBytes = try XCTUnwrap(ModelsPagePresentation.bytes(of: .lightweight, settings: AppSettings()))
        XCTAssertLessThan(lighterBytes, bytes)

        let custom = presentation {
            $0 = ModelStackPreset.recommended.patch.applying(to: $0)
            $0.builtInModelID = ModelCatalog.compactFallbackID
        }
        XCTAssertNil(custom.modelSet)
        XCTAssertTrue(text(custom.modelSetHelp).hasPrefix("You picked your own models."))
    }

    /// A set's size is the sum of the three sizes its rows would show.
    func testAModelSetWeighsWhatItsThreeModelsWeigh() throws {
        for preset in ModelStackPreset.allCases {
            let settings = preset.patch.applying(to: AppSettings())
            let rows = ModelsPagePresentation(settings: settings, statuses: [:]).rows
            let sum = rows.reduce(Int64(0)) { $0 + ($1.bytes ?? 0) }
            XCTAssertEqual(ModelsPagePresentation.bytes(of: preset, settings: AppSettings()), sum, preset.rawValue)
        }
    }

    func testThePagesMoreRowsOpenKeepTheirSavedNames() {
        // The page is restored from scene storage by raw value.
        XCTAssertEqual(ModelsSettingsPage.allCases.map(\.rawValue), ["active", "downloaded", "connections", "other"])
    }

    // MARK: Checks without being asked

    func testADownloadThatFinishesInThisLaunchIsCheckedOnce() {
        var tracker = ModelAutoCheckTracker()
        let settings = AppSettings()

        XCTAssertEqual(tracker.observe([.think: .unavailable], settings: settings), [])
        XCTAssertEqual(tracker.observe([.think: .downloading(progress: 0.1)], settings: settings), [])
        // Between the last byte and the file being found, the role reads as missing.
        XCTAssertEqual(tracker.observe([.think: .unavailable], settings: settings), [])
        XCTAssertEqual(tracker.observe([.think: .ready], settings: settings), [.think])
        XCTAssertEqual(tracker.observe([.think: .ready], settings: settings), [], "checked once")
    }

    func testAModelThatWasAlreadyHereIsNotChecked() {
        var tracker = ModelAutoCheckTracker()
        let ready: [ModelRole: ModelRoleStatus] = [.transcribe: .ready, .think: .ready, .autocomplete: .ready]

        XCTAssertEqual(tracker.observe([:], settings: AppSettings()), [])
        XCTAssertEqual(tracker.observe(ready, settings: AppSettings()), [])
    }

    /// A check of an online model sends it a sample, which only the sheet
    /// that says so may do.
    func testAModelThatRunsOnlineIsNeverCheckedByItself() {
        var remote = AppSettings()
        remote.summarizerBackend = .openAICompatible
        remote.transcriptionModel = .remoteServer
        remote.cotypingEnabled = true
        remote.cotypingBackend = .thinkServer
        var tracker = ModelAutoCheckTracker()
        let working: [ModelRole: ModelRoleStatus] = [
            .transcribe: .preparing(progress: 0.5, label: ""), .think: .downloading(progress: 0.5),
            .autocomplete: .downloading(progress: 0.5),
        ]
        let ready: [ModelRole: ModelRoleStatus] = [.transcribe: .ready, .think: .ready, .autocomplete: .ready]

        XCTAssertEqual(tracker.observe(working, settings: remote), [])
        XCTAssertEqual(tracker.observe(ready, settings: remote), [])
        for role in ModelRole.allCases {
            XCTAssertNil(ModelAutoCheckTracker.localModelID(role, settings: remote), "\(role)")
        }
    }

    func testAutocompleteIsCheckedOnlyWhileItIsOn() {
        var settings = AppSettings()
        settings.cotypingEnabled = false
        XCTAssertNil(ModelAutoCheckTracker.localModelID(.autocomplete, settings: settings))
        settings.cotypingEnabled = true
        XCTAssertEqual(ModelAutoCheckTracker.localModelID(.autocomplete, settings: settings),
                       settings.cotypingBuiltInModelID)
    }

    func testChoosingAnotherModelWhileOneDownloadsDropsTheCheck() {
        var tracker = ModelAutoCheckTracker()
        var settings = AppSettings()
        XCTAssertEqual(tracker.observe([.think: .downloading(progress: 0.5)], settings: settings), [])

        // Another model, already here, becomes the Think model.
        settings.builtInModelID = ModelCatalog.compactFallbackID
        XCTAssertEqual(tracker.observe([.think: .ready], settings: settings), [])
        XCTAssertTrue(tracker.awaiting.isEmpty)
    }

    // MARK: Dictation's writer

    func testWhoWritesDictatedTextFollowsTheModeAndWhereTheModelRuns() {
        var settings = AppSettings()
        settings.dictationIntent = .transcribe
        var writer = DictationWriterPresentation(settings: settings)
        XCTAssertEqual(writer.pickerRole, .transcription)
        XCTAssertFalse(writer.online)
        XCTAssertEqual(text(writer.text), "The Transcribe model, \(settings.transcriptionModelDisplayName), on this Mac")

        settings.dictationIntent = .compose
        writer = DictationWriterPresentation(settings: settings)
        XCTAssertEqual(writer.pickerRole, .dictation)
        XCTAssertFalse(writer.online)
        XCTAssertEqual(text(writer.text), "The Think model, \(settings.thinkModelDisplayName), on this Mac")

        settings.summarizerBackend = .openAICompatible
        settings.openAIBaseURL = "https://ai.example.test/v1"
        settings.openAIModel = "atlas-chat"
        settings.approvedRemoteInferenceOrigins = ["https://ai.example.test"]
        writer = DictationWriterPresentation(settings: settings)
        XCTAssertTrue(writer.online)
        XCTAssertEqual(text(writer.text),
                       "The Think model, online at ai.example.test. What you dictate is sent there.")

        // A model chosen for Compose alone always runs on this Mac.
        settings.dictationCompositionBuiltInModelID = ModelCatalog.compactFallbackID
        writer = DictationWriterPresentation(settings: settings)
        XCTAssertFalse(writer.online)
        let name = ModelCatalog.entry(id: ModelCatalog.compactFallbackID)?.displayName ?? ""
        XCTAssertEqual(text(writer.text), "\(name), on this Mac")

        settings.dictationCompositionBuiltInModelID = ""
        settings.approvedRemoteInferenceOrigins = []
        XCTAssertEqual(text(DictationWriterPresentation(settings: settings).text), "The Think model isn’t set up yet.")
    }

    // MARK: Pages that rows open

    func testSearchLandsOnTheRowsPageThatHoldsASetting() {
        XCTAssertEqual(SettingsSubpage.containing(settingID: "settings.cotypingUserName", on: .writing),
                       .autocompleteProfile)
        XCTAssertEqual(SettingsSubpage.containing(settingID: "settings.cotypingExcludedDomains", on: .writing),
                       .autocompleteExclusions)
        XCTAssertEqual(SettingsSubpage.containing(settingID: "settings.autocompleteStatistics", on: .writing),
                       .autocompleteUsage)
        XCTAssertEqual(SettingsSubpage.containing(settingID: "settings.cotypingInProcessRuntime", on: .writing),
                       .autocompleteAdvanced)
        XCTAssertEqual(SettingsSubpage.containing(settingID: "settings.dictationWritingProfile", on: .dictation),
                       .dictationProfile)
        // Settings on the page itself open no other page.
        XCTAssertNil(SettingsSubpage.containing(settingID: "settings.cotypingDebounceMs", on: .writing))
        XCTAssertNil(SettingsSubpage.containing(settingID: "settings.cotypingUserName", on: .dictation))
        for subpage in SettingsSubpage.allCases {
            for id in subpage.settingIDs {
                let descriptor = SettingDescriptor.all.first { $0.id == id }
                XCTAssertEqual(descriptor?.category, subpage.page, "\(id) is searched on another page")
            }
        }
    }

    func testTheTryOutCommandsOpenTheirSheet() {
        XCTAssertEqual(SettingsSheet(focusedSettingID: "settings.autocompletePreview", on: .writing)?.id,
                       SettingsSheet.tryAutocomplete.id)
        XCTAssertEqual(SettingsSheet(focusedSettingID: "settings.dictationPreview", on: .dictation)?.id,
                       SettingsSheet.tryDictation.id)
        XCTAssertNil(SettingsSheet(focusedSettingID: "settings.dictationPreview", on: .writing))
        XCTAssertNil(SettingsSheet(focusedSettingID: "settings.cotypingEnabled", on: .writing))
        XCTAssertNil(SettingsSheet(focusedSettingID: nil, on: .writing))
    }

    func testSkippedAppsAndSitesAreCounted() {
        XCTAssertEqual(ExclusionRuleCount.count("", ""), 0)
        XCTAssertEqual(ExclusionRuleCount.count("Terminal, iTerm, ", " example.com"), 3)
        XCTAssertEqual(ExclusionRuleCount.count(AppSettings().cotypingExcludedApps), 6)
    }

    // MARK: Settings search

    /// The rows have plainer names; their settings are still found by the
    /// old ones, and by the same identifiers.
    func testRenamedSettingsAreFoundByTheirOldAndNewNames() {
        let expected = [
            "pause before suggesting": "settings.cotypingDebounceMs",
            "wait after you stop typing": "settings.cotypingDebounceMs",
            "multi-line": "settings.cotypingMultiLine",
            "accept punctuation": "settings.cotypingAutoAcceptTrailingPunctuation",
            "clipboard": "settings.cotypingUseClipboard",
            "whole window": "settings.cotypingUseWindowText",
            "meeting and work memory": "settings.cotypingUseMeetingMemory",
            "screen-derived work memory": "settings.dictationUseScreenMemory",
            "emoji": "settings.cotypingEmoji",
            "autocorrect": "settings.cotypingAutocorrect",
            "suggestion length": "settings.cotypingMaxWords",
            "live transcript": "settings.dictationLivePreview",
            "floating dictation status": "settings.dictationShowOverlay",
            "dictation trigger": "settings.dictationTriggerMode",
            "dictation output": "settings.dictationOutputMode",
            "dictation mode": "settings.dictationIntent",
            "processing budget": "settings.generationBudgetPreset",
            "reasoning level": "settings.thinkReasoningLevel",
        ]
        for (query, id) in expected {
            XCTAssertTrue(SettingDescriptor.search(query, language: .english).contains { $0.id == id },
                          "“\(query)” no longer finds \(id)")
        }
        XCTAssertEqual(Set(SettingDescriptor.all.map(\.id)).count, SettingDescriptor.all.count, "duplicate setting")
    }

    /// A result reads like its row on the page, while the setting's own
    /// name stays the one the CLI lists.
    func testSearchShowsTheRowsWordsAndKeepsTheSettingsName() throws {
        let wait = try XCTUnwrap(SettingDescriptor.all.first { $0.id == "settings.cotypingDebounceMs" })
        XCTAssertEqual(wait.displayTitle, "Wait after you stop typing")
        XCTAssertEqual(wait.title, SettingRegistry.spec(for: "cotypingDebounceMs")?.title)
        let macros = try XCTUnwrap(SettingDescriptor.all.first { $0.id == "settings.cotypingMacros" })
        XCTAssertEqual(macros.displayTitle, macros.title)
        // An exact match on the row's words ranks first.
        XCTAssertEqual(SettingDescriptor.search("clipboard", language: .english).first?.id,
                       "settings.cotypingUseClipboard")
    }

    func testTheNewSettingsShowTheirValueInSearch() throws {
        var settings = AppSettings()
        settings.cotypingMaxWords = 7
        settings.dictationIntent = .compose
        let length = try XCTUnwrap(SettingDescriptor.all.first { $0.id == "settings.cotypingMaxWords" })
        let mode = try XCTUnwrap(SettingDescriptor.all.first { $0.id == "settings.dictationIntent" })
        XCTAssertEqual(length.currentValue(in: settings), "7")
        XCTAssertEqual(mode.currentValue(in: settings), "Compose")
    }

    // MARK: Catalog

    /// Every sentence these types put together has an entry in the catalog.
    func testPresentationTextIsInTheCatalog() throws {
        let url = try XCTUnwrap(Bundle(for: AppState.self).url(
            forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: "en"))
        let catalog = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String])
        var keys = Set<String>()
        func collect(_ text: SettingsText) {
            // "%@ · %@" only joins a place and a size or host.
            if text.key != "%@ · %@" { keys.insert(text.key) }
            for case .key(let key) in text.arguments { keys.insert(key) }
        }
        let chips: [ModelRoleRow.Chip] = [.ready, .notDownloaded, .downloading(nil), .downloading(0.5), .checking,
                                          .checkFailed, .stopped, .notSetUp]
        chips.forEach { collect($0.text) }
        var pages = [presentation(), presentation { $0.builtInModelID = ModelCatalog.compactFallbackID }]
        pages.append(presentation {
            $0.summarizerBackend = .openAICompatible
            $0.openAIBaseURL = "https://ai.example.test/v1"
            $0.approvedRemoteInferenceOrigins = ["https://ai.example.test"]
            $0.transcriptionModel = .remoteServer
        })
        for page in pages {
            collect(page.modelSetHelp)
            for row in page.rows {
                collect(row.placeText)
                keys.insert(row.job)
            }
        }
        var writers = [AppSettings](repeating: AppSettings(), count: 6)
        writers[0].dictationIntent = .transcribe
        writers[1].dictationIntent = .transcribe
        writers[1].transcriptionModel = .remoteServer
        writers[2].dictationIntent = .compose
        writers[3].dictationIntent = .compose
        writers[3].summarizerBackend = .openAICompatible
        writers[3].openAIBaseURL = "https://ai.example.test/v1"
        writers[4] = writers[3]
        writers[4].approvedRemoteInferenceOrigins = ["https://ai.example.test"]
        writers[5] = writers[4]
        writers[5].dictationCompositionBuiltInModelID = ModelCatalog.compactFallbackID
        writers.forEach { collect(DictationWriterPresentation(settings: $0).text) }
        // An approved transcription server, for the "online at" sentence.
        collect(SettingsText("The Transcribe model, online at %@. What you say is sent there."))
        keys.formUnion(ModelStackPreset.allCases.flatMap { [$0.title, $0.subtitle] })
        keys.formUnion(ModelsSettingsPage.allCases.map(\.title))
        keys.formUnion(SettingsSubpage.allCases.map(\.title))
        keys.formUnion(SettingDescriptor.all.filter { descriptor in
            [.writing, .dictation].contains(descriptor.category)
                || ["settings.generationBudgetPreset", "settings.thinkReasoningLevel"].contains(descriptor.id)
        }.flatMap { [$0.title, $0.displayTitle] })
        keys.insert("Custom")

        let missing = keys.filter { catalog[$0] == nil }.sorted()
        XCTAssertEqual(missing, [], "Add these to every Localizable.strings")
    }
}
