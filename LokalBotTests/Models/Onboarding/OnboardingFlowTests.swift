import XCTest
@testable import LokalBot

@MainActor
final class OnboardingFlowTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "OnboardingFlowTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testSetupStartsFromTheAppsOwnDefaultsAndApplyingThemChangesNothing() {
        let fresh = AppSettings()
        let draft = CaptureSetupDraft(settings: fresh)
        XCTAssertEqual(draft.meetingMode, .ask)
        XCTAssertTrue(draft.recordsDetectedCalls)
        XCTAssertTrue(draft.dayMemory)
        XCTAssertEqual(draft.contextMode, .activityOnly)
        XCTAssertTrue(draft.codingAgentSessions)
        XCTAssertEqual(draft.applying(to: fresh), fresh, "clicking through setup must not change a new install")
    }

    func testMeetingNotesSwitchKeepsTheChoiceForDetectedCalls() {
        var settings = AppSettings()
        settings.autoRecordMode = .automatic
        var draft = CaptureSetupDraft(settings: settings)
        draft.recordsDetectedCalls = false
        XCTAssertEqual(draft.meetingMode, .manual, "off records only on Record")
        draft.recordsDetectedCalls = true
        XCTAssertEqual(draft.meetingMode, .automatic, "back on returns to the earlier choice")
        draft.meetingMode = .ask
        draft.recordsDetectedCalls = false
        draft.recordsDetectedCalls = true
        XCTAssertEqual(draft.meetingMode, .ask)
    }

    func testMeetingNotesTurnedOnFromManualUsesTheNewInstallDefault() {
        var settings = AppSettings()
        settings.autoRecordMode = .manual
        var draft = CaptureSetupDraft(settings: settings)
        XCTAssertFalse(draft.recordsDetectedCalls)
        XCTAssertEqual(draft.applying(to: settings), settings)
        draft.recordsDetectedCalls = true
        XCTAssertEqual(draft.meetingMode, AppSettings().autoRecordMode)
        XCTAssertEqual(CaptureSetupDraft.detectedCallModes, [.automatic, .ask])
    }

    private func draft(dayMemory: Bool, mode: AppSettings.ScreenContextCaptureMode) -> CaptureSetupDraft {
        var draft = CaptureSetupDraft(settings: AppSettings())
        draft.dayMemory = dayMemory
        draft.contextMode = mode
        return draft
    }

    func testOnlyThePermissionsTheChoicesNeedAreAsked() {
        XCTAssertEqual(OnboardingAccess.permissions(for: draft(dayMemory: false, mode: .visualContext)), [.microphone])
        XCTAssertEqual(OnboardingAccess.permissions(for: draft(dayMemory: true, mode: .activityOnly)),
                       [.microphone, .accessibility])
        XCTAssertEqual(OnboardingAccess.permissions(for: draft(dayMemory: true, mode: .accessibleText)),
                       [.microphone, .accessibility])
        XCTAssertEqual(OnboardingAccess.permissions(for: draft(dayMemory: true, mode: .visualContext)),
                       [.microphone, .accessibility, .screenRecording])
        var manual = draft(dayMemory: false, mode: .activityOnly)
        manual.recordsDetectedCalls = false
        XCTAssertEqual(OnboardingAccess.permissions(for: manual), [], "microphone is not forced when automatic meeting capture is off")
        var manualWithDayMemory = draft(dayMemory: true, mode: .activityOnly)
        manualWithDayMemory.recordsDetectedCalls = false
        XCTAssertEqual(OnboardingAccess.permissions(for: manualWithDayMemory), [.accessibility])
    }

    func testPermissionRowsShowTheirRealState() {
        let visual = draft(dayMemory: true, mode: .visualContext)
        let untouched = OnboardingAccess(draft: visual, granted: [:], grantedAtLaunch: [:], requested: [], turnedOff: [])
        XCTAssertEqual(untouched.rows.map(\.state), [.needed, .needed, .needed])
        XCTAssertEqual(untouched.allowedCount, 0)
        XCTAssertTrue(untouched.showsSettingsGuide)
        XCTAssertTrue(untouched.restartPermissions.isEmpty)

        let midway = OnboardingAccess(
            draft: visual,
            granted: [.microphone: true, .screenRecording: true],
            grantedAtLaunch: [:],
            requested: [.microphone, .accessibility, .screenRecording],
            turnedOff: [])
        XCTAssertEqual(midway.rows.map(\.state), [.allowed, .waiting, .allowedAfterRestart],
                       "the microphone works at once; Screen Recording granted since launch needs a restart")
        XCTAssertEqual(midway.allowedCount, 2)
        XCTAssertEqual(midway.restartPermissions, [.screenRecording])
        XCTAssertTrue(midway.showsSettingsGuide, "Accessibility is still to come")

        let afterRestart = OnboardingAccess(
            draft: visual,
            granted: [.microphone: true, .accessibility: true, .screenRecording: true],
            grantedAtLaunch: [.microphone: true, .accessibility: true, .screenRecording: true],
            requested: [], turnedOff: [])
        XCTAssertEqual(afterRestart.rows.map(\.state), [.allowed, .allowed, .allowed])
        XCTAssertTrue(afterRestart.restartPermissions.isEmpty)
        XCTAssertFalse(afterRestart.showsSettingsGuide)
    }

    func testRefusedMicrophoneOffersSystemSettingsAndNeverWaits() {
        let refused = OnboardingAccess(
            draft: draft(dayMemory: false, mode: .activityOnly),
            granted: [.microphone: false], grantedAtLaunch: [:],
            requested: [.microphone], turnedOff: [.microphone])
        XCTAssertEqual(refused.rows.map(\.state), [.turnedOff])
        XCTAssertFalse(refused.showsSettingsGuide, "the microphone has no list to drag into")

        let asked = OnboardingAccess(
            draft: draft(dayMemory: false, mode: .activityOnly),
            granted: [:], grantedAtLaunch: [:], requested: [.microphone], turnedOff: [])
        XCTAssertEqual(asked.rows.map(\.state), [.needed], "the macOS prompt is the waiting state")

        let granted = OnboardingAccess(
            draft: draft(dayMemory: false, mode: .activityOnly),
            granted: [.microphone: true], grantedAtLaunch: [:], requested: [], turnedOff: [.microphone])
        XCTAssertEqual(granted.rows.map(\.state), [.allowed], "a grant wins over an earlier refusal")
    }

    func testAccessibilityReasonFollowsWhatTheWorkdayKeeps() {
        XCTAssertNotEqual(AppPermission.accessibility.onboardingReason(readsScreenText: true),
                          AppPermission.accessibility.onboardingReason(readsScreenText: false))
        XCTAssertEqual(AppPermission.microphone.onboardingFeature, "Meeting notes")
        XCTAssertEqual(AppPermission.screenRecording.onboardingFeature, "Your workday")
        XCTAssertFalse(AppPermission.microphone.needsRelaunchAfterGrant)
        XCTAssertTrue(AppPermission.accessibility.needsRelaunchAfterGrant)
    }

    private func resumeState(step: OnboardingStep = .access, settings: AppSettings = AppSettings(),
                             reopens: Bool = false) -> OnboardingResumeState {
        var draft = CaptureSetupDraft(settings: settings)
        draft.contextMode = .visualContext
        draft.codingAgentSessions = false
        draft.recordsDetectedCalls = false
        return OnboardingResumeState(step: step, draft: draft, baseline: CaptureSetupDraft(settings: settings),
                                     includeAutocomplete: true, opensSampleMeeting: false,
                                     reopensAfterRestart: reopens)
    }

    func testResumeStateSurvivesARestart() {
        let store = OnboardingResumeStore(defaults: defaults)
        XCTAssertNil(store.load(for: AppSettings()))
        let saved = resumeState(reopens: true)
        store.save(saved)
        let restored = OnboardingResumeStore(defaults: defaults).load(for: AppSettings())
        XCTAssertEqual(restored, saved)
        XCTAssertEqual(restored?.step, .access)
        XCTAssertEqual(restored?.draft.contextMode, .visualContext)
        XCTAssertEqual(restored?.draft.meetingMode, .manual)
        var back = restored?.draft
        back?.recordsDetectedCalls = true
        XCTAssertEqual(back?.meetingMode, .ask, "the call choice behind the switch is restored too")
    }

    func testResumeStateIsDroppedWhenTheSettingsChangedSinceOrSetupFinished() {
        let store = OnboardingResumeStore(defaults: defaults)
        store.save(resumeState())
        var changed = AppSettings()
        changed.trackingEnabled = false
        XCTAssertNil(store.load(for: changed), "a draft started from other settings no longer applies")
        XCTAssertNotNil(store.load(for: AppSettings()))
        store.clear()
        XCTAssertNil(store.load(for: AppSettings()))
        XCTAssertNil(defaults.object(forKey: OnboardingResumeStore.key))
        store.clear()
    }

    func testResumeStateIgnoresDataItCannotRead() {
        defaults.set(Data("not json".utf8), forKey: OnboardingResumeStore.key)
        XCTAssertNil(OnboardingResumeStore(defaults: defaults).load(for: AppSettings()))
    }

    func testLaunchReopensAnInterruptedSetup() {
        let resume = resumeState()
        XCTAssertEqual(OnboardingLaunch.decision(finished: false, coreGranted: false, resume: nil, agentSetupPending: false), .open)
        XCTAssertEqual(OnboardingLaunch.decision(finished: false, coreGranted: true, resume: nil, agentSetupPending: false), .markFinished)
        XCTAssertEqual(OnboardingLaunch.decision(finished: false, coreGranted: false, resume: nil, agentSetupPending: true),
                       .stayClosed(clearsResume: false))
        XCTAssertEqual(OnboardingLaunch.decision(finished: false, coreGranted: true, resume: resume, agentSetupPending: false), .open)
        XCTAssertEqual(OnboardingLaunch.decision(finished: true, coreGranted: true, resume: nil, agentSetupPending: false),
                       .stayClosed(clearsResume: false))
        XCTAssertEqual(OnboardingLaunch.decision(finished: true, coreGranted: true, resume: resume, agentSetupPending: false),
                       .stayClosed(clearsResume: true))
        XCTAssertEqual(OnboardingLaunch.decision(finished: true, coreGranted: true, resume: resumeState(reopens: true),
                                                 agentSetupPending: false), .open)
    }

    func testStepsRunInOrder() {
        XCTAssertEqual(OnboardingStep.allCases, [.choose, .access, .download])
        XCTAssertNil(OnboardingStep.choose.previous)
        XCTAssertEqual(OnboardingStep.choose.next, .access)
        XCTAssertEqual(OnboardingStep.download.previous, .access)
        XCTAssertNil(OnboardingStep.download.next)
    }

    private func plan(_ statuses: [ModelRole: ModelRoleStatus] = [:], settings: AppSettings = AppSettings(),
                      autocomplete: Bool = false, started: Bool = false, readyBefore: Set<ModelRole> = [],
                      available: Int64? = 200_000_000_000) -> OnboardingDownloadPlan {
        OnboardingDownloadPlan(settings: settings, statuses: statuses, includeAutocomplete: autocomplete,
                               started: started, readyBefore: readyBefore, availableBytes: available)
    }

    private func bytes(_ role: ModelRole, in plan: OnboardingDownloadPlan) -> Int64 {
        plan.models.first { $0.role == role }?.bytes ?? 0
    }

    func testBeforeDownloadingEachModelHasItsSizeAndTheTotalCountsOnlyWhatIsChosen() {
        let before = plan()
        XCTAssertEqual(before.phase, .before)
        XCTAssertEqual(before.models.map(\.role), [.transcribe, .think, .autocomplete])
        XCTAssertEqual(before.selected, [.transcribe, .think])
        XCTAssertEqual(before.models.map(\.name),
                       ["Qwen3-ASR 1.7B (LokalBot v3)", "Qwen3.5 4B (LokalBot v4)", "Gemma 4 E2B (LokalBot v4)"])
        XCTAssertTrue(before.models.allSatisfy { ($0.bytes ?? 0) > 0 && $0.downloads })
        XCTAssertEqual(before.remainingBytes, bytes(.transcribe, in: before) + bytes(.think, in: before))
        XCTAssertFalse(before.allReady)
        XCTAssertTrue(before.fitsOnDisk)

        let withAutocomplete = plan(autocomplete: true)
        XCTAssertEqual(withAutocomplete.selected, [.transcribe, .think, .autocomplete])
        XCTAssertEqual(withAutocomplete.remainingBytes,
                       before.remainingBytes.map { $0 + bytes(.autocomplete, in: before) })
    }

    func testModelsAlreadyOnThisMacAreNotDownloadedAgain() {
        let partly = plan([.transcribe: .ready])
        XCTAssertEqual(partly.phase, .before)
        XCTAssertEqual(partly.remainingBytes, bytes(.think, in: partly))
        let all = plan([.transcribe: .ready, .think: .ready], readyBefore: [.transcribe, .think])
        XCTAssertEqual(all.phase, .finished)
        XCTAssertTrue(all.allReady)
        XCTAssertEqual(all.totalBytes, 0, "nothing was downloaded here, so no amount is claimed")
        XCTAssertEqual(all.remainingBytes, 0)
    }

    func testFreeSpaceIsCheckedWithHeadroom() {
        let tight = plan(available: 6_000_000_000)
        XCTAssertFalse(tight.fitsOnDisk, "the download fits only with no room to spare")
        XCTAssertTrue(plan(available: nil).fitsOnDisk, "unknown free space does not warn")
        XCTAssertEqual(tight.availableBytes, 6_000_000_000)
    }

    func testRunningDownloadReportsProgressPerModelAndOverall() {
        let running = plan([.transcribe: .preparing(progress: 0.5, label: "Downloading"),
                            .think: .downloading(progress: 0.25)], started: true)
        XCTAssertEqual(running.phase, .running)
        XCTAssertTrue(running.isDownloading)
        XCTAssertEqual(running.models.map(\.role), [.transcribe, .think],
                       "autocomplete is no longer offered once the download runs without it")
        XCTAssertEqual(running.models.map(\.state), [.downloading(0.5), .downloading(0.25)])
        let transcribe = bytes(.transcribe, in: running), think = bytes(.think, in: running)
        XCTAssertEqual(running.totalBytes, transcribe + think)
        XCTAssertEqual(running.downloadedBytes, Int64((Double(transcribe) * 0.5).rounded()) + Int64((Double(think) * 0.25).rounded()))
        XCTAssertEqual(running.fraction ?? 0,
                       (Double(transcribe) * 0.5 + Double(think) * 0.25) / Double(transcribe + think), accuracy: 0.0001)

        let unknown = plan([.transcribe: .preparing(progress: nil, label: "Preparing…"),
                            .think: .downloading(progress: 0.25)], started: true)
        XCTAssertNil(unknown.downloadedBytes, "no amount while one download has not said how far it is")
        XCTAssertNil(unknown.fraction)

        let justPressed = plan(started: true)
        XCTAssertEqual(justPressed.phase, .running, "the button counts before the first status arrives")
    }

    func testProgressCountsOnlyWhatThisDownloadFetches() {
        let running = plan([.transcribe: .ready, .think: .downloading(progress: 0.5)],
                           started: true, readyBefore: [.transcribe])
        XCTAssertEqual(running.totalBytes, bytes(.think, in: running))
        XCTAssertEqual(running.fraction ?? 0, 0.5, accuracy: 0.0001)
        let finished = plan([.transcribe: .ready, .think: .ready], started: true, readyBefore: [.transcribe])
        XCTAssertEqual(finished.phase, .finished)
        XCTAssertTrue(finished.allReady)
        XCTAssertEqual(finished.downloadedBytes, bytes(.think, in: finished))
    }

    func testStoppedDownloadLeadsWhileAnotherStillRuns() {
        let stopped = plan([.transcribe: .preparing(progress: 0.72, label: "Downloading"),
                            .think: .needsAttention("The network connection was lost.")], started: true)
        XCTAssertEqual(stopped.phase, .stopped)
        XCTAssertTrue(stopped.isDownloading)
        XCTAssertEqual(stopped.stoppedModels.map(\.role), [.think])
        XCTAssertEqual(stopped.models.last?.state, .stopped("The network connection was lost."))
        XCTAssertEqual(stopped.downloadedBytes, Int64((Double(bytes(.transcribe, in: stopped)) * 0.72).rounded()),
                       "a stopped download counts as nothing until it is retried")
        let retried = plan([.transcribe: .ready, .think: .downloading(progress: 0)], started: true)
        XCTAssertEqual(retried.phase, .running)
    }

    func testAutocompleteJoinsTheDownloadOnlyWhenChosenOrAlreadyHere() {
        let chosen = plan([.transcribe: .ready, .think: .ready, .autocomplete: .downloading(progress: 0.1)],
                          autocomplete: true, started: true)
        XCTAssertEqual(chosen.phase, .running)
        XCTAssertEqual(chosen.models.map(\.role), [.transcribe, .think, .autocomplete])
        let here = plan([.autocomplete: .ready])
        XCTAssertEqual(here.selected, [.transcribe, .think, .autocomplete])
        XCTAssertEqual(here.remainingBytes, bytes(.transcribe, in: here) + bytes(.think, in: here))
        var server = AppSettings()
        server.cotypingBackend = .server
        XCTAssertEqual(plan(settings: server).models.map(\.role), [.transcribe, .think],
                       "a server needs nothing downloaded for autocomplete")
    }

    func testServerThinkModelHasNothingToDownload() {
        var settings = AppSettings()
        settings.summarizerBackend = .ollama
        let waiting = plan([.think: .unavailable], settings: settings)
        let think = waiting.models.first { $0.role == .think }
        XCTAssertEqual(think?.downloads, false)
        XCTAssertNil(think?.bytes)
        XCTAssertEqual(think?.state, .needsSetup)
        XCTAssertEqual(waiting.remainingBytes, bytes(.transcribe, in: waiting))
        let transcribed = plan([.transcribe: .ready, .think: .unavailable], settings: settings)
        XCTAssertEqual(transcribed.phase, .finished, "nothing is left to download")
        XCTAssertFalse(transcribed.allReady, "but the server still needs setting up")
        XCTAssertTrue(plan([.transcribe: .ready, .think: .ready], settings: settings).allReady)
    }

    func testAppleSpeechHasNothingToDownloadInPlan() {
        var settings = AppSettings()
        settings.transcriptionModel = .appleSpeech
        let waiting = plan([.transcribe: .unavailable], settings: settings)
        let transcribe = waiting.models.first { $0.role == .transcribe }
        XCTAssertEqual(transcribe?.name, "Apple Speech")
        XCTAssertEqual(transcribe?.downloads, false)
        XCTAssertNil(transcribe?.bytes)
        XCTAssertEqual(transcribe?.state, .needsSetup)

        let ready = plan([.transcribe: .ready, .think: .ready], settings: settings)
        XCTAssertTrue(ready.allReady)
        XCTAssertEqual(ready.models.first { $0.role == .transcribe }?.state, .ready)
    }

    func testSmallMemoryMacDefaultsToLightweightPresetAndFreshInstall() {
        let gib: UInt64 = 1_073_741_824
        let mac8GB = HardwareCapability(physicalMemoryBytes: 8 * gib, isAppleSilicon: true)
        let mac12GB = HardwareCapability(physicalMemoryBytes: 12 * gib, isAppleSilicon: true)
        let mac16GB = HardwareCapability(physicalMemoryBytes: 16 * gib, isAppleSilicon: true)
        let mac32GB = HardwareCapability(physicalMemoryBytes: 32 * gib, isAppleSilicon: true)

        XCTAssertEqual(ModelStackPreset.defaultPreset(for: mac8GB), .lightweight)
        XCTAssertEqual(ModelStackPreset.defaultPreset(for: mac12GB), .lightweight)
        XCTAssertEqual(ModelStackPreset.defaultPreset(for: mac16GB), .recommended)
        XCTAssertEqual(ModelStackPreset.defaultPreset(for: mac32GB), .recommended)

        let fresh8GB = AppSettings.load(from: defaults, capability: mac8GB)
        XCTAssertEqual(ModelStackPreset.matching(fresh8GB), .lightweight)
        XCTAssertEqual(fresh8GB.builtInModelID, ModelStackPreset.lightweight.mainModelID)
        XCTAssertEqual(fresh8GB.transcriptionModel, ModelStackPreset.lightweight.transcription)
        XCTAssertEqual(fresh8GB.cotypingBuiltInModelID, ModelStackPreset.lightweight.autocompleteModelID)

        let fresh16GB = AppSettings.load(from: defaults, capability: mac16GB)
        XCTAssertEqual(ModelStackPreset.matching(fresh16GB), .recommended)
        XCTAssertEqual(fresh16GB.builtInModelID, ModelStackPreset.recommended.mainModelID)
        XCTAssertEqual(fresh16GB.transcriptionModel, ModelStackPreset.recommended.transcription)
    }

    func testAppleBuiltInOptionHasZeroDownloadBytesAndSurfacesWhenAvailable() {
        XCTAssertEqual(
            OnboardingModelOption.availableCases(appleBuiltInAvailable: false),
            [.recommended, .lightweight])
        XCTAssertEqual(
            OnboardingModelOption.availableCases(appleBuiltInAvailable: true),
            [.recommended, .lightweight, .appleBuiltIn])

        let settings = OnboardingModelOption.appleBuiltIn.patch.applying(to: AppSettings())
        XCTAssertEqual(settings.transcriptionModel, .appleSpeech)
        XCTAssertEqual(settings.summarizerBackend, .appleIntelligence)
        XCTAssertEqual(OnboardingModelOption.matching(settings), .appleBuiltIn)

        let zeroDownloadPlan = plan([.transcribe: .ready, .think: .ready], settings: settings)
        XCTAssertEqual(zeroDownloadPlan.phase, .finished)
        XCTAssertEqual(zeroDownloadPlan.remainingBytes, 0)
        XCTAssertTrue(zeroDownloadPlan.allReady)
    }

    func testActivityOnlySetupLabelMatchesWindowTitleBehavior() {
        XCTAssertEqual(AppSettings.ScreenContextCaptureMode.activityOnly.setupTitle, "App and window titles")
    }

    func testSampleMeetingChosenInSetupHydratesImmediatelyWithoutWaitingForModels() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OnboardingSample-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let app = AppState(storage: StorageManager(rootURL: root))
        var testError: Error?
        do {
            XCTAssertFalse(app.modelRoles.snapshot.meetingReady)
            app.openSampleMeetingWhenReady()
            for _ in 0..<100 where app.sampleMeeting == nil {
                try await Task.sleep(for: .milliseconds(50))
            }
            let sample = try XCTUnwrap(
                app.sampleMeeting,
                "sample meeting must hydrate immediately without downloaded models")
            XCTAssertFalse(app.sampleMeetingWaitsForModels)
            XCTAssertFalse(app.showsSampleSetup)
            let folder = sample.folderURL(in: app.storage)
            let transcriptData = try Data(contentsOf: folder.appendingPathComponent("transcript.json"))
            let transcript = try JSONDecoder().decode(Transcript.self, from: transcriptData)
            XCTAssertEqual(transcript.engine, SampleMeeting.precomputedEngine)
        } catch {
            testError = error
        }
        await app.finishSearchIndexingForTesting()
        if let testError { throw testError }
    }

    func testTimeLeftWaitsForASteadySpeed() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        var estimator = DownloadTimeEstimator()
        XCTAssertNil(estimator.minutesLeft(totalBytes: 6_000_000_000))
        estimator.record(downloadedBytes: 0, at: start)
        estimator.record(downloadedBytes: 40_000_000, at: start.addingTimeInterval(2))
        XCTAssertNil(estimator.secondsLeft(totalBytes: 6_000_000_000), "two seconds is too little to judge")
        estimator.record(downloadedBytes: 200_000_000, at: start.addingTimeInterval(10))
        XCTAssertEqual(estimator.secondsLeft(totalBytes: 6_000_000_000) ?? 0, 290, accuracy: 0.5)
        XCTAssertEqual(estimator.minutesLeft(totalBytes: 6_000_000_000), 5)
        XCTAssertEqual(estimator.minutesLeft(totalBytes: 210_000_000), 1, "never less than a minute")
        XCTAssertNil(estimator.secondsLeft(totalBytes: 200_000_000), "nothing is left")
    }

    func testTimeLeftForgetsOldSpeedsAndStalledDownloads() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        var estimator = DownloadTimeEstimator()
        estimator.record(downloadedBytes: 0, at: start)
        estimator.record(downloadedBytes: 1_000_000_000, at: start.addingTimeInterval(10))
        estimator.record(downloadedBytes: 1_020_000_000, at: start.addingTimeInterval(30))
        estimator.record(downloadedBytes: 1_050_000_000, at: start.addingTimeInterval(60))
        XCTAssertEqual(estimator.secondsLeft(totalBytes: 1_110_000_000) ?? 0, 60, accuracy: 0.5)
        estimator.record(downloadedBytes: 1_050_000_000, at: start.addingTimeInterval(95))
        XCTAssertNil(estimator.secondsLeft(totalBytes: 1_110_000_000))
        estimator.record(downloadedBytes: 400_000_000, at: start.addingTimeInterval(96))
        XCTAssertNil(estimator.secondsLeft(totalBytes: 1_110_000_000))
        estimator.reset()
        XCTAssertNil(estimator.minutesLeft(totalBytes: 1_110_000_000))
    }
}
