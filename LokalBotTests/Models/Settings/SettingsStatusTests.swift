import XCTest
@testable import LokalBot

/// What the Settings window says about each feature: the "Off" and "Paused"
/// marks and the count badges in its list, what needs the person on
/// Overview, each permission's state on Privacy & permissions, and the
/// status lines under the page headers.
final class SettingsStatusTests: XCTestCase {
    private let allGranted: [AppPermission: Bool] = [
        .microphone: true, .accessibility: true, .inputMonitoring: true, .screenRecording: true,
    ]

    private func model(_ role: ModelRole, _ status: ModelRoleStatus, downloads: Bool = true,
                       bytes: Int64? = 1_000_000_000) -> SettingsStatus.Model {
        let name = [ModelRole.transcribe: "Speech", .think: "Thinker", .autocomplete: "Typist"][role] ?? ""
        return .init(role: role, name: name, bytes: bytes, downloads: downloads, status: status)
    }

    private func readyModels() -> [SettingsStatus.Model] {
        [model(.transcribe, .ready), model(.think, .ready), model(.autocomplete, .ready)]
    }

    /// Everything granted and downloaded, with the default settings.
    private func input(_ change: (inout SettingsStatus.Input) -> Void = { _ in }) -> SettingsStatus.Input {
        var input = SettingsStatus.Input(settings: AppSettings(), granted: allGranted, grantedAtLaunch: allGranted,
                                         calendar: .allowed, models: readyModels(), freeBytes: 50_000_000_000)
        change(&input)
        return input
    }

    private func status(_ change: (inout SettingsStatus.Input) -> Void = { _ in }) -> SettingsStatus {
        SettingsStatus(input(change))
    }

    private func text(_ text: SettingsText) -> String { text.string { $0 } }

    // MARK: Everything set up

    func testNothingNeedsYouWhenEverythingIsGrantedAndDownloaded() {
        let status = status()

        XCTAssertTrue(status.needs.isEmpty)
        XCTAssertFalse(status.needsAttention)
        XCTAssertEqual(status.summary.key, "Everything is working")
        XCTAssertEqual(status.headline.detail.key, "Nothing needs you, and everything stays on this Mac.")
        XCTAssertEqual(status.badge(.privacy), 0)
        XCTAssertEqual(status.badge(.models), 0)
        XCTAssertEqual(status.lines(for: .privacy).map(\.text.key), ["All set. Nothing leaves this Mac."])
        // Ready models say what they take and what is free.
        XCTAssertEqual(status.lines(for: .models).map(\.text.key),
                       ["All ready. The models take about %@ on this Mac, and %@ is free."])
    }

    /// A permission that has not been read yet counts as granted, so no
    /// warning flashes while the window opens.
    func testUnreadPermissionsCountAsGranted() {
        let status = status { $0.granted = [:] }

        XCTAssertTrue(status.missingPermissions.isEmpty)
        XCTAssertEqual(status.access(.microphone), .allowed)
    }

    // MARK: Permissions

    func testMicrophoneIsAlwaysNeededAndPausesMeetings() {
        let status = status { $0.granted[.microphone] = false }

        XCTAssertEqual(status.access(.microphone), .missing)
        XCTAssertEqual(status.rowState(.recording), .paused)
        XCTAssertEqual(status.badge(.privacy), 1)
        XCTAssertEqual(status.needs, [.permission(.microphone, features: [.meetings])])
        XCTAssertEqual(status.summary.key, "1 thing needs you")
        XCTAssertEqual(status.lines(for: .recording).first?.action, .allow(.microphone))
        XCTAssertEqual(status.lines(for: .privacy).map(\.text.key), ["1 permission is off, so a feature is paused."])
    }

    func testAPermissionNothingUsesIsNotNeeded() {
        let status = status {
            $0.settings.trackingEnabled = false
            $0.granted[.accessibility] = false
            $0.granted[.inputMonitoring] = false
            $0.granted[.screenRecording] = false
        }

        XCTAssertEqual(status.access(.accessibility), .notNeeded)
        XCTAssertEqual(status.access(.inputMonitoring), .notNeeded)
        XCTAssertEqual(status.access(.screenRecording), .notNeeded)
        XCTAssertTrue(status.needs.isEmpty)
        XCTAssertEqual(status.badge(.privacy), 0)
    }

    func testAccessibilityIsNeededByTheFeaturesThatAreOn() {
        let status = status {
            $0.granted[.accessibility] = false
            $0.settings.trackingEnabled = true
            $0.settings.cotypingEnabled = true
            $0.settings.selectionActionsEnabled = true
        }

        XCTAssertEqual(status.features(using: .accessibility), [.autocomplete, .windowTitles, .selectionActions])
        XCTAssertEqual(status.access(.accessibility), .missing)
        let need = SettingsStatus.Need.permission(.accessibility,
                                                  features: [.autocomplete, .windowTitles, .selectionActions])
        XCTAssertEqual(status.needs, [need])
        XCTAssertEqual(text(status.title(of: need)), "Allow Accessibility")
        XCTAssertEqual(text(status.detail(of: need)), "Needed for: Autocomplete, Window titles, Selection actions")
    }

    /// PRIVACY.md: Autocomplete reads the focused window only when Screen
    /// Recording is already granted and never asks for it.
    func testAutocompleteNeverAsksForScreenRecording() {
        let status = status {
            $0.settings.cotypingEnabled = true
            $0.settings.cotypingUseWindowText = true
            $0.granted[.screenRecording] = false
        }

        XCTAssertEqual(status.access(.screenRecording), .notNeeded)
        XCTAssertFalse(status.lines(for: .writing).contains { $0.action == .allow(.screenRecording) })
        XCTAssertFalse(status.needs.contains { $0.id == "permission.screenRecording" })
    }

    func testScreenRecordingIsNeededForScreenshotsAndForDictationReadingTheWindow() {
        let screenshots = status {
            $0.settings.screenContextCaptureMode = .visualContext
            $0.granted[.screenRecording] = false
        }
        XCTAssertEqual(screenshots.features(using: .screenRecording), [.screenText])
        XCTAssertEqual(screenshots.rowState(.dayMemory), .paused)
        XCTAssertEqual(screenshots.lines(for: .dayMemory).map(\.action), [.allow(.screenRecording)])

        let compose = status {
            $0.settings.dictationEnabled = true
            $0.settings.dictationIntent = .compose
            $0.settings.dictationUseScreenContext = true
            $0.granted[.screenRecording] = false
        }
        XCTAssertEqual(compose.features(using: .screenRecording), [.dictation])
        XCTAssertEqual(compose.rowState(.dictation), .paused)
        XCTAssertTrue(compose.lines(for: .dictation).contains { $0.action == .allow(.screenRecording) })
    }

    func testCalendarIsNeededOnlyWhileCalendarDetectionIsOn() {
        let off = status { $0.calendar = .notAsked }
        XCTAssertEqual(off.access(.calendar), .notNeeded)

        let asked = status { $0.calendar = .notAsked; $0.settings.calendarDetectionEnabled = true }
        XCTAssertEqual(asked.access(.calendar), .missing)
        XCTAssertEqual(asked.allowTitle(.calendar), "Allow…")
        XCTAssertEqual(asked.lines(for: .recording).map(\.action), [.allow(.calendar)])

        let refused = status { $0.calendar = .refused; $0.settings.calendarDetectionEnabled = true }
        XCTAssertEqual(refused.allowTitle(.calendar), "Open System Settings…")
        XCTAssertEqual(refused.lines(for: .recording).first?.buttonTitle, "Open System Settings…")
    }

    func testAGrantMadeSinceLaunchAsksForARelaunchOnThePagesThatUseIt() {
        let status = status {
            $0.settings.cotypingEnabled = true
            $0.grantedAtLaunch[.accessibility] = false
        }

        XCTAssertEqual(status.permissionsAwaitingRelaunch, [.accessibility])
        let line = status.lines(for: .writing).first { $0.action == .relaunch }
        XCTAssertEqual(line.map { text($0.text) }, "Accessibility starts working after LokalBot reopens.")
        // The microphone works at once, and Dictation does not paste here.
        XCTAssertFalse(status.lines(for: .recording).contains { $0.action == .relaunch })
    }

    // MARK: Models

    func testMissingModelsAreOneNeedFixedOnModels() {
        let status = status {
            $0.models = [self.model(.transcribe, .unavailable, bytes: 2_000_000_000),
                         self.model(.think, .unavailable, bytes: 3_000_000_000),
                         self.model(.autocomplete, .unavailable, bytes: 4_000_000_000)]
        }

        // Autocomplete is off, so its model is not asked for.
        XCTAssertEqual(status.needs, [.download(roles: [.transcribe, .think], bytes: 5_000_000_000)])
        XCTAssertEqual(status.badge(.models), 1)
        XCTAssertEqual(status.badge(.privacy), 0)
        let need = status.needs[0]
        XCTAssertEqual(text(status.title(of: need)), "Download the models")
        XCTAssertEqual(text(status.detail(of: need)),
                       "\(SettingsStatus.size(5_000_000_000)) · New meetings wait to be transcribed until then.")
        let line = status.lines(for: .models).first
        // The header's "Download all" button downloads them, so the line has none of its own.
        XCTAssertNil(line?.action)
        XCTAssertEqual(status.bytesToDownload, 5_000_000_000)
        XCTAssertEqual(line.map { text($0.text) },
                       "Not downloaded yet. They need \(SettingsStatus.size(5_000_000_000)), and this Mac has "
                           + "\(SettingsStatus.size(50_000_000_000)) free.")
    }

    /// While the header shows Cancel for a running download, a model that
    /// still has to be asked for keeps its own Download button.
    func testAMissingModelKeepsItsDownloadButtonWhileAnotherDownloads() {
        let status = status {
            $0.models = [self.model(.transcribe, .unavailable, bytes: 2_000_000_000),
                         self.model(.think, .downloading(progress: 0.25), bytes: 4_000_000_000),
                         self.model(.autocomplete, .ready)]
        }

        let lines = status.lines(for: .models)
        XCTAssertEqual(lines.map(\.id), ["download", "downloading"])
        XCTAssertEqual(lines.first?.action, .download)
        XCTAssertEqual(status.bytesToDownload, 2_000_000_000)
    }

    func testADownloadSaysHowMuchHasArrivedAndHowLongItStillTakes() {
        func line(minutes: Int?) -> String? {
            let status = status {
                $0.downloadMinutesLeft = minutes
                $0.models = [self.model(.transcribe, .ready),
                             self.model(.think, .downloading(progress: 0.5), bytes: 2_000_000_000),
                             self.model(.autocomplete, .downloading(progress: 0.25), bytes: 4_000_000_000)]
            }
            XCTAssertEqual(status.runningDownload?.arrived, 2_000_000_000)
            XCTAssertEqual(status.runningDownload?.total, 6_000_000_000)
            return status.lines(for: .models).first.map { text($0.text) }
        }
        let arrived = SettingsStatus.size(2_000_000_000), total = SettingsStatus.size(6_000_000_000)

        XCTAssertEqual(line(minutes: nil), "Downloading · \(arrived) of \(total)")
        XCTAssertEqual(line(minutes: 1), "Downloading · \(arrived) of \(total) · about 1 minute left")
        XCTAssertEqual(line(minutes: 5), "Downloading · \(arrived) of \(total) · about 5 minutes left")

        // Without a size or a progress there is nothing to count.
        let unknown = status {
            $0.models = [self.model(.transcribe, .ready), self.model(.think, .downloading(progress: nil)),
                         self.model(.autocomplete, .ready)]
        }
        XCTAssertNil(unknown.runningDownload)
        XCTAssertEqual(unknown.lines(for: .models).first.map { text($0.text) }, "Thinker is downloading.")
    }

    func testReadyModelsSayWhatTheyTakeAndWhatIsFree() {
        let ready = status {
            $0.models = [self.model(.transcribe, .ready, bytes: 3_000_000_000),
                         self.model(.think, .ready, bytes: 2_000_000_000),
                         // Autocomplete is off and its model is not here: it is not counted.
                         self.model(.autocomplete, .unavailable, bytes: 4_000_000_000)]
        }
        let line = ready.lines(for: .models).first
        XCTAssertEqual(line?.tone, .ok)
        XCTAssertEqual(line.map { text($0.text) },
                       "All ready. The models take about \(SettingsStatus.size(5_000_000_000)) on this Mac, and "
                           + "\(SettingsStatus.size(50_000_000_000)) is free.")

        let unknown = status { $0.freeBytes = nil }
        XCTAssertEqual(unknown.lines(for: .models).first.map { text($0.text) },
                       "All set. Every model runs on this Mac.")
    }

    /// A model that is here and did not answer its check is said on Models,
    /// with the way to the sheet that checks it again. It is not a count
    /// badge: the model may still work.
    func testAFailedCheckIsALineOnModels() {
        let status = status { $0.failedChecks = [.think] }

        let line = status.lines(for: .models).first
        XCTAssertEqual(line?.id, "check.think")
        XCTAssertEqual(line?.tone, .need)
        XCTAssertEqual(line.map { text($0.text) }, "Thinker didn’t pass its check.")
        XCTAssertEqual(line?.action, .open(.models, focus: SettingsStatus.modelChecksFocus))
        XCTAssertEqual(line?.buttonTitle, "Review…")
        XCTAssertEqual(status.badge(.models), 0)

        // A check of a model that has since gone says nothing.
        let gone = self.status {
            $0.failedChecks = [.think]
            $0.models[1].status = .unavailable
        }
        XCTAssertFalse(gone.lines(for: .models).contains { $0.id == "check.think" })
    }

    func testAutocompleteModelIsNeededOnlyWhileAutocompleteIsOn() {
        let status = status {
            $0.settings.cotypingEnabled = true
            $0.models = [self.model(.transcribe, .ready), self.model(.think, .ready),
                         self.model(.autocomplete, .unavailable, bytes: 4_000_000_000)]
        }

        XCTAssertEqual(status.needs, [.download(roles: [.autocomplete], bytes: 4_000_000_000)])
        XCTAssertEqual(text(status.detail(of: status.needs[0])),
                       "\(SettingsStatus.size(4_000_000_000)) · Autocomplete waits until then.")
        XCTAssertEqual(status.rowState(.writing), .paused)
        let line = status.lines(for: .writing).first { $0.action == .download }
        XCTAssertEqual(line.map { text($0.text) }, "Typist (\(SettingsStatus.size(4_000_000_000))) isn’t downloaded yet.")
    }

    func testDownloadingModelsNeedNothingFromYou() {
        let status = status {
            $0.models = [self.model(.transcribe, .ready),
                         self.model(.think, .downloading(progress: 0.5), bytes: 2_000_000_000),
                         self.model(.autocomplete, .ready)]
        }

        XCTAssertTrue(status.needs.isEmpty)
        XCTAssertEqual(status.summary.key, "Downloading models…")
        XCTAssertEqual(status.headline.title.key, "Almost ready")
        XCTAssertEqual(status.downloadFraction, 0.5)
        XCTAssertEqual(status.lines(for: .models).map(\.tone), [.progress(0.5)])
    }

    func testAModelThatStoppedOrIsNotSetUpNeedsAttention() {
        let stopped = status {
            $0.models = [self.model(.transcribe, .ready), self.model(.think, .needsAttention("disk full")),
                         self.model(.autocomplete, .ready)]
        }
        XCTAssertEqual(stopped.needs, [.modelAttention(.think)])
        XCTAssertEqual(stopped.badge(.models), 1)

        let server = status {
            $0.models = [self.model(.transcribe, .ready), self.model(.think, .unavailable, downloads: false, bytes: nil),
                         self.model(.autocomplete, .ready)]
        }
        XCTAssertEqual(server.needs, [.modelAttention(.think)])
        XCTAssertTrue(server.modelsToDownload.isEmpty)
    }

    // MARK: The list

    func testFeaturesThatAreOffSayOff() {
        let status = status {
            $0.settings.trackingEnabled = false
            $0.settings.fileSearchEnabled = false
            $0.settings.cotypingEnabled = false
            $0.settings.dictationEnabled = false
            $0.settings.companionSharingEnabled = false
        }

        for page in [AppState.SettingsTab.dayMemory, .files, .email, .writing, .dictation, .agents, .devices] {
            XCTAssertEqual(status.rowState(page), .off, "\(page)")
        }
        for page in [AppState.SettingsTab.overview, .general, .models, .privacy, .recording, .ask,
                     .personalContext, .daily, .advanced] {
            XCTAssertEqual(status.rowState(page), .normal, "\(page)")
        }
        XCTAssertEqual(status.lines(for: .writing).map(\.text.key), ["Off. No suggestions appear in other apps."])
        XCTAssertEqual(status.lines(for: .dictation).map(\.text.key),
                       ["Off. The shortcut does nothing until you turn it on."])
        XCTAssertEqual(status.lines(for: .email).map(\.text.key), ["Not connected"])
    }

    func testFeaturesThatAreOnAndWorkingSayNothing() {
        let status = status {
            $0.settings.fileSearchEnabled = true
            $0.settings.cotypingEnabled = true
            $0.settings.dictationEnabled = true
            $0.settings.companionSharingEnabled = true
            $0.emailConnected = true
            $0.agentKinds = 2
        }

        for page in AppState.SettingsTab.allCases {
            XCTAssertEqual(status.rowState(page), .normal, "\(page)")
        }
        XCTAssertEqual(status.lines(for: .writing).map(\.tone), [.ok])
        XCTAssertEqual(status.lines(for: .writing).first.map { text($0.text) }, "Ready · Typist, on this Mac")
        XCTAssertEqual(status.lines(for: .dictation).map(\.tone), [.ok])
    }

    func testAutocompleteIsPausedByAMissingPermissionOrModel() {
        let noAccessibility = status {
            $0.settings.cotypingEnabled = true
            $0.granted[.accessibility] = false
        }
        XCTAssertEqual(noAccessibility.rowState(.writing), .paused)
        XCTAssertEqual(noAccessibility.lines(for: .writing).first?.action, .allow(.accessibility))

        let noShortcut = status {
            $0.settings.cotypingEnabled = true
            $0.granted[.inputMonitoring] = false
        }
        XCTAssertEqual(noShortcut.rowState(.writing), .paused)
        XCTAssertEqual(noShortcut.lines(for: .writing).first?.action, .allow(.inputMonitoring))

        let downloading = status {
            $0.settings.cotypingEnabled = true
            $0.models = [self.model(.transcribe, .ready), self.model(.think, .ready),
                         self.model(.autocomplete, .downloading(progress: nil))]
        }
        XCTAssertEqual(downloading.rowState(.writing), .paused)
        XCTAssertEqual(downloading.lines(for: .writing).map(\.tone), [.progress(nil)])
    }

    func testDictationIsPausedByWhatItUses() {
        let noMicrophone = status {
            $0.settings.dictationEnabled = true
            $0.granted[.microphone] = false
        }
        XCTAssertEqual(noMicrophone.rowState(.dictation), .paused)
        XCTAssertEqual(noMicrophone.lines(for: .dictation).first?.action, .allow(.microphone))
        XCTAssertEqual(noMicrophone.needs, [.permission(.microphone, features: [.meetings, .dictation])])

        // Copying to the clipboard needs no Accessibility; pasting does.
        let copies = status {
            $0.settings.trackingEnabled = false
            $0.settings.dictationEnabled = true
            $0.settings.dictationOutputMode = .copyToClipboard
            $0.settings.dictationUseVisibleContext = false
            $0.granted[.accessibility] = false
        }
        XCTAssertEqual(copies.rowState(.dictation), .normal)
        let pastes = status {
            $0.settings.trackingEnabled = false
            $0.settings.dictationEnabled = true
            $0.settings.dictationOutputMode = .pasteIntoFocusedApp
            $0.granted[.accessibility] = false
        }
        XCTAssertEqual(pastes.rowState(.dictation), .paused)
        XCTAssertTrue(pastes.lines(for: .dictation).contains { $0.action == .allow(.accessibility) })
    }

    func testScreenAndActivityIsPausedOnlyWhenWhatItReadsIsBlocked() {
        // Apps are still tracked without Accessibility; only titles are missing.
        let titles = status { $0.granted[.accessibility] = false }
        XCTAssertEqual(titles.rowState(.dayMemory), .normal)
        XCTAssertEqual(titles.lines(for: .dayMemory).map(\.action), [.allow(.accessibility)])

        let screenText = status {
            $0.settings.screenContextCaptureMode = .accessibleText
            $0.granted[.accessibility] = false
        }
        XCTAssertEqual(screenText.rowState(.dayMemory), .paused)
    }

    func testBadgesCountWhatIsFixedOnEachPage() {
        let status = status {
            $0.settings.cotypingEnabled = true
            $0.granted[.microphone] = false
            $0.granted[.accessibility] = false
            $0.models = [self.model(.transcribe, .unavailable), self.model(.think, .ready),
                         self.model(.autocomplete, .ready)]
        }

        XCTAssertEqual(status.badge(.privacy), 2)
        XCTAssertEqual(status.badge(.models), 1)
        XCTAssertEqual(status.needs.count, 3)
        XCTAssertEqual(text(status.summary), "3 things need you")
        XCTAssertEqual(status.lines(for: .privacy).first.map { text($0.text) },
                       "2 permissions are off, so some features are paused.")
        for page in AppState.SettingsTab.allCases where page != .privacy && page != .models {
            XCTAssertEqual(status.badge(page), 0, "\(page)")
        }
    }

    // MARK: What leaves this Mac

    func testSharingWithPhonesIsNotEverythingStayingHere() {
        let status = status { $0.settings.companionSharingEnabled = true }

        XCTAssertFalse(status.everythingStaysHere)
        XCTAssertEqual(status.headline.detail.key, "Nothing needs you.")
        XCTAssertEqual(status.lines(for: .privacy).map(\.tone), [.online])
    }

    // MARK: Text

    func testTextFillsItsPlaceholdersFromTheCatalog() {
        let catalog = ["%lld things need you": "%lld Dinge", "Needed for: %@": "Für: %@", "Meetings": "Besprechungen"]
        func localized(_ key: String) -> String { catalog[key] ?? key }

        XCTAssertEqual(SettingsText("%lld things need you", .count(4)).string(localized), "4 Dinge")
        XCTAssertEqual(SettingsText("Needed for: %@", .list(["Meetings", "Dictation"])).string(localized),
                       "Für: Besprechungen, Dictation")
        XCTAssertEqual(SettingsText("Everything is working").string(localized), "Everything is working")
    }

    /// Every sentence the status can show has an entry in the English catalog.
    func testStatusTextIsInTheCatalog() throws {
        let url = try XCTUnwrap(Bundle(for: AppState.self).url(
            forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: "en"))
        let catalog = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String])
        var keys = Set<String>()
        func collect(_ status: SettingsStatus) {
            keys.insert(status.summary.key)
            keys.insert(status.headline.title.key)
            keys.insert(status.headline.detail.key)
            for need in status.needs {
                keys.insert(status.title(of: need).key)
                let detail = status.detail(of: need)
                // "%@ · %@" only joins a size and a sentence.
                if detail.key != "%@ · %@" { keys.insert(detail.key) }
                for case .key(let key) in detail.arguments { keys.insert(key) }
                for case .list(let list) in detail.arguments { keys.formUnion(list) }
            }
            for page in AppState.SettingsTab.allCases {
                for line in status.lines(for: page) {
                    keys.insert(line.text.key)
                    if let title = line.buttonTitle { keys.insert(title) }
                }
            }
        }
        collect(status())
        collect(status {
            $0.granted = [.microphone: false, .accessibility: false, .inputMonitoring: false, .screenRecording: false]
            $0.calendar = .refused
            $0.settings.calendarDetectionEnabled = true
            $0.settings.cotypingEnabled = true
            $0.settings.dictationEnabled = true
            $0.settings.dictationIntent = .compose
            $0.settings.dictationUseScreenContext = true
            $0.settings.screenContextCaptureMode = .visualContext
            $0.settings.selectionActionsEnabled = true
            $0.settings.windowHandoffEnabled = true
            $0.models = [self.model(.transcribe, .unavailable), self.model(.think, .needsAttention("x")),
                         self.model(.autocomplete, .unavailable)]
        })
        collect(status {
            $0.settings.cotypingEnabled = true
            $0.settings.dictationEnabled = true
            $0.settings.companionSharingEnabled = true
            $0.grantedAtLaunch = [:]
            $0.grantedAtLaunch[.accessibility] = false
            $0.models = [self.model(.transcribe, .downloading(progress: 0.2)), self.model(.think, .ready),
                         self.model(.autocomplete, .downloading(progress: nil))]
        })
        collect(status { $0.settings.trackingEnabled = false; $0.freeBytes = nil; $0.models[0].status = .unavailable })
        for minutes in [nil, 1, 7] as [Int?] {
            collect(status {
                $0.downloadMinutesLeft = minutes
                $0.models[1].status = .downloading(progress: 0.4)
                $0.models[2].status = .unavailable
                $0.settings.cotypingEnabled = true
            })
        }
        collect(status { $0.failedChecks = [.transcribe] })
        for permission in SettingsPermission.allCases {
            keys.formUnion([permission.title, permission.usedBy, permission.allowTitle])
        }
        keys.formUnion(AppState.SettingsTab.allCases.map(\.displayName))
        keys.formUnion(AppState.SettingsTab.allCases.map(\.summary).filter { !$0.isEmpty })
        keys.formUnion(AppState.SettingsTab.Group.allCases.map(\.rawValue))

        let missing = keys.filter { catalog[$0] == nil }.sorted()
        XCTAssertEqual(missing, [], "Add these to every Localizable.strings")
    }
}

/// Back and forward through the Settings pages visited.
final class SettingsPageHistoryTests: XCTestCase {
    func testBackAndForwardFollowTheVisits() {
        var history = SettingsPageHistory(current: .overview)
        XCTAssertFalse(history.canGoBack)
        XCTAssertFalse(history.canGoForward)

        history.visit(.privacy)
        history.visit(.models)
        XCTAssertEqual(history.goBack(), .privacy)
        XCTAssertEqual(history.goBack(), .overview)
        XCTAssertNil(history.goBack())
        XCTAssertEqual(history.goForward(), .privacy)
        XCTAssertTrue(history.canGoForward)
        XCTAssertEqual(history.current, .privacy)
    }

    func testVisitingAPageClearsForwardAndTheShownPageIsNotVisitedTwice() {
        var history = SettingsPageHistory(current: .overview)
        history.visit(.privacy)
        _ = history.goBack()
        history.visit(.overview)
        XCTAssertTrue(history.canGoForward, "Choosing the page already shown changes nothing")

        history.visit(.general)
        XCTAssertFalse(history.canGoForward)
        XCTAssertEqual(history.goBack(), .overview)
    }
}
