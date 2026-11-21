import AppKit
import CoreAudio

struct MeetingContinuationLease: Equatable {
    private(set) var lastReliableAudioAt: Date?

    mutating func allowsContinuation(
        reliableAudioActive: Bool,
        alwaysOpenAudioActive: Bool,
        now: Date,
        grace: TimeInterval
    ) -> Bool {
        if reliableAudioActive {
            lastReliableAudioAt = now
            return true
        }
        guard alwaysOpenAudioActive,
              let lastReliableAudioAt,
              grace.isFinite,
              grace >= 0 else { return false }
        let age = now.timeIntervalSince(lastReliableAudioAt)
        return age >= 0 && age <= grace
    }

    mutating func recordReliableAudio(at date: Date) {
        lastReliableAudioAt = date
    }

    mutating func reset() {
        lastReliableAudioAt = nil
    }
}

@MainActor
final class MeetingDetector {

    struct DetectedApp: Equatable {
        let name: String
        let bundleID: String
        let pid: pid_t
        var meetingURL: URL?
        var usesMicrophoneDetection = false
    }

    nonisolated static let knownApps: [String: String] = [
        "us.zoom.xos": "Zoom",
        "com.microsoft.teams2": "Teams",
        "com.microsoft.teams": "Teams",
        "com.tinyspeck.slackmacgap": "Slack",
        "com.webex.meetingmanager": "Webex",
        "Cisco-Systems.Spark": "Webex",
        "com.apple.FaceTime": "FaceTime",
        "com.tencent.meeting": "Tencent Meeting",
        "com.tencent.tencentmeeting": "VooV Meeting",
        "com.electron.lark": "Feishu",
        "com.larksuite.larkApp": "Lark",
        "com.alibaba.DingTalkMac": "DingTalk",
        "com.tencent.WeWorkMac": "WeCom",
        "ru.yandex.desktop.telemost": "Yandex Telemost",
        "ru.unlimitedtech.express.desktop": "eXpress",
    ]

    nonisolated private static let highConfidenceNativeAudioBundles: Set<String> = [
        "us.zoom.xos",
        "com.webex.meetingmanager",
        "Cisco-Systems.Spark",
        "com.tencent.meeting",
        "com.tencent.tencentmeeting",
    ]

    nonisolated static func shouldAutoRecordNativeAudioMonitor(bundleID: String, calendarBacked: Bool) -> Bool {
        bundleID != expressBundleID && (highConfidenceNativeAudioBundles.contains(bundleID) || calendarBacked)
    }

    nonisolated private static let expressBundleID = "ru.unlimitedtech.express.desktop"

    nonisolated static let nativeAudioMinimumConfirmationDuration: TimeInterval = 12

    nonisolated static let nativeAudioConfirmationGapTolerance: TimeInterval = 6

    nonisolated static let alwaysOpenAudioBundles: Set<String> = [
        "com.microsoft.teams2.modulehost",
    ]

    nonisolated static func carriesMeetingSignal(bundleID: String?) -> Bool {
        guard let bundleID else { return true }
        return !alwaysOpenAudioBundles.contains(bundleID.lowercased())
    }

    nonisolated static func requiresSustainedAudioForStart(bundleID: String, calendarBacked: Bool) -> Bool {
        guard knownApps[bundleID] != nil else { return false }
        return !shouldAutoRecordNativeAudioMonitor(bundleID: bundleID, calendarBacked: calendarBacked)
    }

    nonisolated static let browsers: Set<String> = [
        "com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser",
        "com.microsoft.edgemac", "com.brave.Browser", "org.mozilla.firefox",
    ]

    nonisolated static let documentCallHosts = browsers.union(BrowserMeetingSession.nativeWebClients.keys)
    nonisolated static let microphoneBrowsers = browsers.union([
        "ru.yandex.desktop.yandex-browser", "com.operasoftware.Opera",
        "com.vivaldi.Vivaldi", "org.chromium.Chromium"
    ])

    var onMeetingStarted: ((MeetingDetectionContext) -> Void)?
    var onMeetingSwitched: ((MeetingDetectionContext) -> Void)?
    var onMeetingEnded: ((MeetingDetectionEnd) -> Void)?
    var onBrowserObservation: ((UUID, Bool, Date?) -> Void)?
    var onVerifiedSourceAvailable: ((MeetingDetectionContext) -> Void)?
    var stopDebounce: TimeInterval = AppSettings.defaultStopDebounceSeconds
    nonisolated static let calendarBackedGrace: TimeInterval = 180
    nonisolated static let browserObservationGrace: TimeInterval = 120
    nonisolated static let alwaysOpenAudioContinuationGrace: TimeInterval = 45

    var calendar: CalendarEventProviding?
    var calendarEnabled = false
    var requireCalendarForBrowser = false
    var detectOtherBrowserCalls = false
    var additionalCallBundleIDs: Set<String> = []

    private(set) var activeApp: DetectedApp?
    private(set) var activeSessionID: UUID?
    private var activeCalendarEvent: CalendarMeetingCandidate?
    private var continuationLease = MeetingContinuationLease()
    private var environment: CaptureEnvironment { .current }
    private var timer: CaptureTimer?
    private var pendingStop: CaptureTimer?
    private var browserStart = BrowserMeetingSession.StartGate()
    private(set) var detectedContentEnd: Date?
    private(set) var endedMeetingURL: URL?
    private var browserLifecycle = BrowserMeetingSession.LifecycleTracker()
    private var startConfirmation = MeetingMatcher.StartConfirmationState()
    private var lastLoggedStartState: String?
    private var pendingStartRecheck: CaptureTimer?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var browserPollGeneration = 0
    private var browserPollTask: Task<Void, Never>?
    private var browserPollStartedAt: Date?
    private var reportedLongBrowserPoll = false
    nonisolated static let longBrowserPollReport: TimeInterval = 30
    private var browserSnapshots: [pid_t: BrowserMeetingSession.Snapshot] = [:]
    private var otherRoomSnapshots: [pid_t: BrowserMeetingSession.Snapshot] = [:]
    private var browserMicrophoneCandidates: [DetectedApp] = []
    private let microphoneWindowsAllowed: @Sendable ([pid_t]) async -> Set<pid_t>

    init(microphoneWindowsAllowed: @escaping @Sendable ([pid_t]) async -> Set<pid_t> = {
        await BrowserMeetingSession.microphoneFallbackAllowed(processIDs: $0)
    }) {
        self.microphoneWindowsAllowed = microphoneWindowsAllowed
    }

    var verifiesActiveCall: Bool {
        guard let activeApp else { return false }
        return activeApp.usesMicrophoneDetection || !Self.documentCallHosts.contains(activeApp.bundleID)
            || browserLifecycle.lostAt == nil
    }

    private var micListener: AudioObjectPropertyListenerBlock?
    private var listenedDevice = AudioObjectID(kAudioObjectUnknown)
    private var deviceChangeListener: AudioObjectPropertyListenerBlock?

    nonisolated private static let processSnapshotLock = NSLock()
    nonisolated(unsafe) private static var processSnapshot: (capturedAt: Date, processes: [AudioProcess])?
    nonisolated private static let processSnapshotLifetime: TimeInterval = 0.35

    func start() {
        guard timer == nil else { return }
        timer = environment.clock.repeating(every: 2) { [weak self] in
            self?.tick()
        }
        armMicListener()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Self.invalidateAudioProcessSnapshot()
                MainActor.assumeIsolated { self?.tick() }
            }
            workspaceObservers.append(observer)
        }
        tick()
    }

    func stop() {
        browserPollGeneration &+= 1
        browserPollTask?.cancel()
        browserPollTask = nil
        browserPollStartedAt = nil
        browserSnapshots = [:]
        browserMicrophoneCandidates = []
        otherRoomSnapshots = [:]
        timer?.cancel()
        timer = nil
        pendingStop?.cancel()
        pendingStop = nil
        clearPendingStart()
        continuationLease.reset()
        browserLifecycle = .init()
        detectedContentEnd = nil
        endedMeetingURL = nil
        activeSessionID = nil
        activeApp = nil
        activeCalendarEvent = nil
        let center = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers { center.removeObserver(observer) }
        workspaceObservers.removeAll()
        disarmAll()
    }

    private func armMicListener() {
        disarmMicListener()
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        if deviceChangeListener == nil {
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                DispatchQueue.main.async {
                    self?.armMicListener()
                    self?.tick()
                }
            }
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                                &addr, .main, block)
            deviceChangeListener = block
        }

        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &addr, 0, nil, &size, &deviceID) == noErr,
              deviceID != kAudioObjectUnknown else { return }
        var runningAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let micBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            BrowserMeetingSession.quietWindows.removeAll()
            DispatchQueue.main.async { self?.tick() }
        }
        AudioObjectAddPropertyListenerBlock(deviceID, &runningAddr, .main, micBlock)
        micListener = micBlock
        listenedDevice = deviceID
    }

    private func disarmMicListener() {
        guard let micListener, listenedDevice != kAudioObjectUnknown else { return }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectRemovePropertyListenerBlock(listenedDevice, &addr, .main, micListener)
        self.micListener = nil
        listenedDevice = AudioObjectID(kAudioObjectUnknown)
    }

    private func disarmAll() {
        disarmMicListener()
        if let deviceChangeListener {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultInputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                                   &addr, .main, deviceChangeListener)
            self.deviceChangeListener = nil
        }
    }

    private func tick() {
        guard browserPollTask == nil else {
            noteBrowserPollStillRunning()
            return
        }
        let generation = browserPollGeneration
        let boundApp = activeApp
        let eventURL = calendarEnabled ? calendar?.activeCandidate(now: environment.clock.now())?.meetingURL : nil
        let expectedURL = boundApp?.meetingURL ?? eventURL
        let running = environment.workspace.runningApplications()
        let allowBrowserMicrophone = detectOtherBrowserCalls
        let checkMicrophoneWindows = microphoneWindowsAllowed
        let microphoneApps = allowBrowserMicrophone
            ? Self.microphoneCandidates(in: running, additional: [], browser: true) : []
        let browserApps = running.filter { app in
            guard let bundleID = app.bundleIdentifier, Self.documentCallHosts.contains(bundleID) else {
                return false
            }
            guard BrowserMeetingSession.nativeWebClients[bundleID] != nil, boundApp?.bundleID != bundleID else {
                return true
            }
            return Self.currentAudioProcesses().contains { stream in
                guard let owner = stream.bundleID, Self.audioBundleID(owner, belongsTo: bundleID) else {
                    return false
                }
                return stream.isRunningOutput || environment.audio.isProcessRunningInput(processID: stream.id)
            }
        }
        let pids = browserApps.filter {
            guard let boundApp, !boundApp.usesMicrophoneDetection,
                  Self.documentCallHosts.contains(boundApp.bundleID) else { return true }
            return $0.bundleIdentifier == boundApp.bundleID
        }.map(\.processIdentifier)
        let otherRoomPIDs = boundApp != nil && !verifiesActiveCall ? browserApps.map(\.processIdentifier) : []
        let otherRoomURL = Self.otherRoom(eventURL, than: boundApp?.meetingURL)
        guard !pids.isEmpty || !otherRoomPIDs.isEmpty || !microphoneApps.isEmpty else {
            browserSnapshots = [:]
            otherRoomSnapshots = [:]
            browserMicrophoneCandidates = []
            applyTick()
            return
        }
        browserPollStartedAt = environment.clock.now()
        reportedLongBrowserPoll = false
        browserPollTask = Task { @MainActor [weak self] in
            let clock = CaptureEnvironment.current.clock
            let started = clock.now()
            let observations = await BrowserMeetingSession.observe(processIDs: pids, expectedURL: expectedURL)
            let otherRoomsStarted = clock.now()
            var otherRooms: [pid_t: BrowserMeetingSession.Snapshot] = [:]
            if !otherRoomPIDs.isEmpty {
                otherRooms = await BrowserMeetingSession.observe(processIDs: otherRoomPIDs, expectedURL: otherRoomURL)
            }
            let microphonePIDs = microphoneApps.filter { observations[$0.pid] == nil }.map(\.pid)
            let micCheckStarted = clock.now()
            let publicWindows = await checkMicrophoneWindows(microphonePIDs)
            guard let self, !Task.isCancelled, generation == self.browserPollGeneration else { return }
            if self.reportedLongBrowserPoll, let started = self.browserPollStartedAt {
                lokalbotLog("detector browser observation finished after="
                    + String(format: "%.1fs", clock.now().timeIntervalSince(started)))
            }
            self.browserPollTask = nil
            self.browserPollStartedAt = nil
            guard self.activeApp == boundApp, self.detectOtherBrowserCalls == allowBrowserMicrophone,
                  eventURL == (self.calendarEnabled ? self.calendar?.activeCandidate(now: self.environment.clock.now())?.meetingURL : nil) else {
                self.tick()
                return
            }
            self.browserSnapshots = otherRoomsStarted.timeIntervalSince(started) < 2 ? observations : [:]
            self.otherRoomSnapshots = clock.now().timeIntervalSince(otherRoomsStarted) < 2 ? otherRooms : [:]
            self.browserMicrophoneCandidates = clock.now().timeIntervalSince(micCheckStarted) < 2
                ? microphoneApps.filter { publicWindows.contains($0.pid) } : []
            self.applyTick()
        }
    }

    private func noteBrowserPollStillRunning() {
        guard !reportedLongBrowserPoll, let started = browserPollStartedAt else { return }
        let elapsed = environment.clock.now().timeIntervalSince(started)
        guard elapsed >= Self.longBrowserPollReport else { return }
        reportedLongBrowserPoll = true
        lokalbotLog("detector browser observation still running after="
            + String(format: "%.0fs", elapsed) + "; call checks wait for it")
    }

    nonisolated static func otherRoom(_ eventURL: URL?, than boundURL: URL?) -> URL? {
        guard let room = eventURL.flatMap({ BrowserMeetingSession.roomURL($0.absoluteString) }),
              room != boundURL?.absoluteString else { return nil }
        return URL(string: room)
    }

    private func applyTick() {
        let now = environment.clock.now()
        let running = environment.workspace.runningApplications()
        let calendarEvent = calendarEnabled ? calendar?.activeCandidate(now: now) : nil

        if let currentApp = activeApp {
            if Self.documentCallHosts.contains(currentApp.bundleID), !currentApp.usesMicrophoneDetection {
                tickBrowser(currentApp, now: now)
                return
            }
            let continuingApp = Self.continuingApp(currentApp, in: running)
            let appAudioActive = continuingApp.map {
                hasContinuingAudio(for: $0, now: now)
            } ?? false
            let isBrowserApp = continuingApp.map {
                !$0.usesMicrophoneDetection && Self.documentCallHosts.contains($0.bundleID)
            } ?? false
            let calendarBackedBrowserWithAudio = isBrowserApp
                && calendarEnabled
                && calendarEvent?.meetingURL != nil
                && appAudioActive
            let inMeeting = MeetingMatcher.isMeetingOngoing(
                hasActiveSession: true,
                hasRunningMeetingApp: false,
                hasContinuingApp: continuingApp != nil,
                startAudioActive: false,
                appAudioActive: appAudioActive,
                calendarBackedBrowserWithAudio: calendarBackedBrowserWithAudio)

            guard inMeeting, let app = continuingApp else {
                let replacementApp = detectRunningMeetingApp(
                    in: running,
                    calendarEvent: calendarEvent,
                    calendarEnabled: calendarEnabled,
                    requireCalendarForBrowser: requireCalendarForBrowser,
                    snapshots: browserSnapshots)
                if let replacementApp,
                   startConfirmed(app: replacementApp, calendarBacked: calendarEvent != nil, now: now) {
                    pendingStop?.cancel()
                    pendingStop = nil
                    let previousApp = activeApp
                    activeApp = replacementApp
                    browserLifecycle = .init(verifiedAt: replacementApp.meetingURL == nil ? nil : now)
                    activeCalendarEvent = calendarEvent
                    continuationLease.recordReliableAudio(at: now)
                    clearPendingStart(loggingLoss: false)
                    if previousApp != replacementApp {
                        onMeetingSwitched?(MeetingDetectionContext(
                            detectedApp: replacementApp,
                            calendarEvent: calendarEvent,
                            confidence: MeetingMatcher.confidence(
                                hasApp: true, hasCalendar: calendarEvent != nil),
                            reason: "meeting-app-handoff",
                            detectorSessionID: activeSessionID))
                    }
                    return
                }
                if keepsActiveSessionForPendingHandoff(
                    in: running,
                    freshCandidateBundleID: replacementApp?.bundleID,
                    calendarBacked: calendarEvent != nil,
                    now: now
                ) {
                    pendingStop?.cancel()
                    pendingStop = nil
                    return
                }
                scheduleStopIfNeeded(now: now)
                return
            }

            pendingStop?.cancel()
            pendingStop = nil
            let previousEventID = activeCalendarEvent?.externalID
            activeApp = app
            if app.usesMicrophoneDetection {
                onVerifiedSourceAvailable?(.init(
                    detectedApp: app, calendarEvent: activeCalendarEvent,
                    confidence: .high, reason: "verified-microphone-source",
                    detectorSessionID: activeSessionID))
            }
            if let calendarEvent {
                activeCalendarEvent = calendarEvent
                if MeetingMatcher.shouldSplitForCalendarHandoff(
                    activeEventID: previousEventID,
                    nextEventID: calendarEvent.externalID) {
                    onMeetingSwitched?(MeetingDetectionContext(
                        detectedApp: app,
                        calendarEvent: calendarEvent,
                        confidence: MeetingMatcher.confidence(hasApp: true, hasCalendar: true),
                        reason: "calendar-handoff",
                        detectorSessionID: activeSessionID))
                }
            }
            return
        }

        let runningMeetingApp = detectRunningMeetingApp(
            in: running,
            calendarEvent: calendarEvent,
            calendarEnabled: calendarEnabled,
            requireCalendarForBrowser: requireCalendarForBrowser, snapshots: browserSnapshots)
        let isBrowserApp = runningMeetingApp.map {
            !$0.usesMicrophoneDetection && Self.documentCallHosts.contains($0.bundleID)
        } ?? false
        let calendarBackedBrowser = isBrowserApp && calendarEnabled && calendarEvent?.meetingURL != nil
        let startAudioActive = runningMeetingApp.map { $0.meetingURL != nil || Self.hasAudio(for: $0) } ?? false
        let calendarBackedBrowserWithAudio = calendarBackedBrowser
            && (runningMeetingApp.map { Self.hasOutputAudio(for: $0) } ?? false)
        let inMeeting = MeetingMatcher.isMeetingOngoing(
            hasActiveSession: false,
            hasRunningMeetingApp: runningMeetingApp != nil,
            hasContinuingApp: false,
            startAudioActive: startAudioActive,
            appAudioActive: false,
            calendarBackedBrowserWithAudio: calendarBackedBrowserWithAudio)

        if inMeeting, let app = runningMeetingApp {
            guard startConfirmed(app: app, calendarBacked: calendarEvent != nil, now: now) else { return }
            logStartState("detector confirmed app=\(app.bundleID)")
            beginMeeting(app: app, calendarEvent: calendarEvent, now: now)
            return
        }

        if let pendingStart = startConfirmation.window,
           Self.requiresSustainedAudioForStart(
               bundleID: pendingStart.bundleID, calendarBacked: calendarEvent != nil),
           Self.nativeApp(bundleID: pendingStart.bundleID, in: running) != nil {
            switch MeetingMatcher.startConfirmationGapOutcome(
                firstSeenAt: pendingStart.firstSeenAt,
                lastAudioSeenAt: pendingStart.lastAudioSeenAt,
                now: now,
                gapTolerance: Self.nativeAudioConfirmationGapTolerance,
                minimumDuration: Self.nativeAudioMinimumConfirmationDuration) {
            case .stillWaiting:
                let gapRemaining = Self.nativeAudioConfirmationGapTolerance
                    - now.timeIntervalSince(pendingStart.lastAudioSeenAt)
                scheduleStartConfirmationRecheck(
                    after: min(gapRemaining, 1),
                    generation: pendingStart.generation)
                return
            case .abandoned:
                break
            }
        }

        logStartState(
            runningMeetingApp.map {
                "detector idle app=\($0.bundleID) audio=\(startAudioActive) "
                    + "calendar=\(calendarEvent != nil)"
            } ?? "detector idle app=none")
        clearPendingStart()
    }

    private func beginMeeting(app: DetectedApp, calendarEvent: CalendarMeetingCandidate?, now: Date) {
        activeSessionID = UUID()
        detectedContentEnd = nil
        endedMeetingURL = nil
        browserLifecycle = .init(verifiedAt: app.meetingURL == nil ? nil : now)
        browserStart = .init()
        clearPendingStart(loggingLoss: false)
        pendingStop?.cancel()
        pendingStop = nil
        activeApp = app
        activeCalendarEvent = calendarEvent
        continuationLease.recordReliableAudio(at: now)
        onMeetingStarted?(MeetingDetectionContext(
            detectedApp: app,
            calendarEvent: calendarEvent,
            confidence: MeetingMatcher.confidence(hasApp: true, hasCalendar: calendarEvent != nil),
            reason: "detector",
            detectorSessionID: activeSessionID))
    }

    func acceptNativeAudioStart(app: DetectedApp, calendarEvent: CalendarMeetingCandidate?) {
        guard activeApp == nil, Self.knownApps[app.bundleID] != nil,
              Self.shouldAutoRecordNativeAudioMonitor(
                bundleID: app.bundleID, calendarBacked: calendarEvent != nil) else { return }
        beginMeeting(app: app, calendarEvent: calendarEvent, now: environment.clock.now())
    }

    private func startConfirmed(app: DetectedApp, calendarBacked: Bool, now: Date) -> Bool {
        if Self.documentCallHosts.contains(app.bundleID), !app.usesMicrophoneDetection {
            guard let url = app.meetingURL else { browserStart = .init(); return false }
            return browserStart.observe(.init(url: url, state: .inCall), at: now)
        }
        guard app.usesMicrophoneDetection || Self.requiresSustainedAudioForStart(
            bundleID: app.bundleID, calendarBacked: calendarBacked) else { return true }
        let startedNewWindow = startConfirmation.observeAudio(
            bundleID: app.bundleID,
            at: now,
            gapTolerance: Self.nativeAudioConfirmationGapTolerance)
        if startedNewWindow {
            cancelPendingStartRecheck()
            lokalbotLog(
                "detector waiting for sustained audio app=\(app.bundleID) "
                    + "needs=\(Int(Self.nativeAudioMinimumConfirmationDuration))s")
        }
        guard let pendingStart = startConfirmation.window else { return false }
        if MeetingMatcher.sustainedAudioConfirmed(
            firstSeenAt: pendingStart.firstSeenAt,
            now: now,
            minimumDuration: Self.nativeAudioMinimumConfirmationDuration) {
            return true
        }
        let elapsed = now.timeIntervalSince(pendingStart.firstSeenAt)
        scheduleStartConfirmationRecheck(
            after: Self.nativeAudioMinimumConfirmationDuration - elapsed,
            generation: pendingStart.generation)
        return false
    }

    private func keepsActiveSessionForPendingHandoff(
        in running: [RunningApp],
        freshCandidateBundleID: String?,
        calendarBacked: Bool,
        now: Date
    ) -> Bool {
        guard let pending = startConfirmation.window else { return false }
        guard Self.requiresSustainedAudioForStart(
                bundleID: pending.bundleID,
                calendarBacked: calendarBacked),
              Self.nativeApp(bundleID: pending.bundleID, in: running) != nil,
              MeetingMatcher.shouldKeepActiveSessionForPendingHandoff(
                confirmationWindow: pending,
                freshCandidateBundleID: freshCandidateBundleID,
                runningMeetingBundleIDs: Set(running.compactMap { app -> String? in
                    guard let bundleID = app.bundleIdentifier,
                          Self.knownApps[bundleID] != nil else { return nil }
                    return bundleID
                }),
                now: now,
                gapTolerance: Self.nativeAudioConfirmationGapTolerance) else {
            clearPendingStart()
            return false
        }
        let gapRemaining = Self.nativeAudioConfirmationGapTolerance
            - now.timeIntervalSince(pending.lastAudioSeenAt)
        let confirmationRemaining = Self.nativeAudioMinimumConfirmationDuration
            - now.timeIntervalSince(pending.firstSeenAt)
        cancelPendingStartRecheck()
        scheduleStartConfirmationRecheck(
            after: confirmationRemaining > 0
                ? min(gapRemaining, confirmationRemaining)
                : gapRemaining,
            generation: pending.generation)
        return true
    }

    private func logStartState(_ state: String) {
        guard lastLoggedStartState != state else { return }
        lastLoggedStartState = state
        lokalbotLog(state)
    }

    private func scheduleStartConfirmationRecheck(after delay: TimeInterval,
                                                  generation: UInt64) {
        guard startConfirmation.acceptsRecheck(for: generation),
              pendingStartRecheck == nil else { return }
        pendingStartRecheck = environment.clock.schedule(after: max(delay, 0.25)) { [weak self] in
            guard let self,
                  self.startConfirmation.acceptsRecheck(for: generation) else { return }
            self.pendingStartRecheck = nil
            self.tick()
        }
    }

    private func clearPendingStart(loggingLoss: Bool = true) {
        browserStart = .init()
        if loggingLoss, let pendingStart = startConfirmation.window {
            lokalbotLog(
                "detector lost the audio it was waiting on app=\(pendingStart.bundleID) "
                    + "after=\(String(format: "%.1fs", environment.clock.now().timeIntervalSince(pendingStart.firstSeenAt)))")
        }
        startConfirmation.clear()
        cancelPendingStartRecheck()
    }

    private func cancelPendingStartRecheck() {
        pendingStartRecheck?.cancel()
        pendingStartRecheck = nil
    }

    private func detectRunningMeetingApp(
        in running: [RunningApp],
        calendarEvent: CalendarMeetingCandidate?,
        calendarEnabled: Bool,
        requireCalendarForBrowser: Bool,
        snapshots: [pid_t: BrowserMeetingSession.Snapshot]
    ) -> DetectedApp? {
        Self.nativeMeetingApp(in: running, requireAudio: true)
            ?? Self.browserMeeting(in: running,
                              calendarEvent: calendarEvent,
                              calendarEnabled: calendarEnabled,
                              requireCalendarForBrowser: requireCalendarForBrowser,
                              snapshots: snapshots)
            ?? Self.microphoneCandidates(in: running, additional: additionalCallBundleIDs, browser: false).first
            ?? ((!requireCalendarForBrowser || (calendarEnabled && calendarEvent?.meetingURL != nil))
                ? browserMicrophoneCandidates.first : nil)
    }

    private func scheduleStopIfNeeded(
        now: Date,
        immediately: Bool = false,
        reason: String? = nil,
        confident: Bool = true
    ) {
        guard activeApp != nil, let sessionID = activeSessionID, pendingStop == nil else { return }
        let isBrowser = activeApp.map { Self.documentCallHosts.contains($0.bundleID) } ?? false
        let calendarStillActive = !isBrowser && activeApp?.usesMicrophoneDetection != true
            && (activeCalendarEvent?.isActive(at: now) ?? false)
        let debounce = immediately ? 0 : calendarStillActive ? max(stopDebounce, Self.calendarBackedGrace) : stopDebounce
        pendingStop = environment.clock.schedule(after: debounce) { [weak self] in
            guard let self else { return }
            if let reason { lokalbotLog("detector ending meeting reason=\(reason) confident=\(confident)") }
            self.completeMeetingEnd(sessionID: sessionID, confident: confident)
        }
    }

    func completeMeetingEnd(sessionID: UUID, confident: Bool = true) {
        guard activeSessionID == sessionID else { return }
        let event = MeetingDetectionEnd(sessionID: sessionID, contentEndedAt: detectedContentEnd,
                                        confident: confident)
        endedMeetingURL = activeApp?.meetingURL
        activeApp = nil
        activeSessionID = nil
        activeCalendarEvent = nil
        continuationLease.reset()
        pendingStop = nil
        browserLifecycle = .init()
        onMeetingEnded?(event)
    }

    private func tickBrowser(_ app: DetectedApp, now: Date) {
        let host = environment.workspace.runningApplications().first { $0.bundleIdentifier == app.bundleID }
        let snapshot = host.flatMap { browserSnapshots[$0.processIdentifier] }
        let nativeHostQuit = host == nil && BrowserMeetingSession.nativeWebClients[app.bundleID] != nil
        let observedState: BrowserMeetingSession.State? = nativeHostQuit ? .ended : snapshot.map {
            $0.url == app.meetingURL ? $0.state : .unavailable
        }
        if observedState == .inCall, let host {
            let verified = DetectedApp(name: app.name, bundleID: app.bundleID,
                                       pid: host.processIdentifier, meetingURL: app.meetingURL)
            onVerifiedSourceAvailable?(.init(detectedApp: verified, calendarEvent: activeCalendarEvent,
                                             confidence: .high, reason: "verified-browser-source",
                                             detectorSessionID: activeSessionID))
        }
        let event = browserLifecycle.observe(
            observedState,
            hostPresent: host != nil,
            now: now,
            grace: max(Self.browserObservationGrace, max(0, stopDebounce)))
        if let sessionID = activeSessionID {
            onBrowserObservation?(sessionID, browserLifecycle.lostAt != nil,
                                  browserLifecycle.lastEvidenceAt)
        }
        switch event {
        case .none:
            if browserLifecycle.lostAt == nil {
                pendingStop?.cancel()
                pendingStop = nil
                detectedContentEnd = nil
            }
        case .suspended(let state):
            lokalbotLog(state == .minimized
                ? "browser lifecycle observation suspended: bound window minimized"
                : "browser lifecycle observation suspended: meeting tab still open")
            pendingStop?.cancel()
            pendingStop = nil
        case .recovered(let after):
            lokalbotLog("browser lifecycle observation recovered after=" + String(format: "%.1fs", after))
            pendingStop?.cancel()
            pendingStop = nil
            detectedContentEnd = nil
        case .lost(let state):
            let issue = host.flatMap { environment.accessibility.browserReadIssue(processID: $0.processIdentifier) }
            lokalbotLog("browser lifecycle observation lost state="
                + (state.map(String.init(describing:)) ?? "missing")
                + (issue.map { " issue=\($0.rawValue)" } ?? ""))
        case .end(let reason, let confident, let contentEnd):
            if reason != "browser-ended" {
                lokalbotLog("browser lifecycle observation grace expired reason=\(reason) after="
                    + String(format: "%.1fs", now.timeIntervalSince(browserLifecycle.lostAt ?? now)))
            }
            detectedContentEnd = contentEnd
            browserLifecycle = .init()
            pendingStop?.cancel()
            pendingStop = nil
            scheduleStopIfNeeded(now: now, immediately: true, reason: reason, confident: confident)
            return
        }
        if verifiesActiveCall {
            browserStart = .init()
            splitAtCalendarHandoff(app, now: now)
        } else {
            handOffIfAnotherRoomIsInCall(from: app, now: now)
        }
    }

    private func splitAtCalendarHandoff(_ app: DetectedApp, now: Date) {
        guard calendarEnabled, let room = app.meetingURL?.absoluteString,
              let event = calendar?.activeCandidate(now: now),
              event.meetingURL.flatMap({ BrowserMeetingSession.roomURL($0.absoluteString) }) == room else { return }
        let previousEventID = activeCalendarEvent?.externalID
        activeCalendarEvent = event
        guard MeetingMatcher.shouldSplitForCalendarHandoff(activeEventID: previousEventID,
                                                           nextEventID: event.externalID) else { return }
        onMeetingSwitched?(MeetingDetectionContext(
            detectedApp: app,
            calendarEvent: event,
            confidence: MeetingMatcher.confidence(hasApp: true, hasCalendar: true),
            reason: "calendar-handoff",
            detectorSessionID: activeSessionID))
    }

    private func handOffIfAnotherRoomIsInCall(from app: DetectedApp, now: Date) {
        let calendarEvent = calendarEnabled ? calendar?.activeCandidate(now: now) : nil
        let backingEvent = Self.otherRoom(calendarEvent?.meetingURL, than: app.meetingURL) == nil ? nil : calendarEvent
        guard let replacement = Self.browserMeeting(in: environment.workspace.runningApplications(),
                                                    calendarEvent: backingEvent,
                                                    calendarEnabled: calendarEnabled,
                                                    requireCalendarForBrowser: requireCalendarForBrowser,
                                                    snapshots: otherRoomSnapshots),
              replacement.meetingURL != app.meetingURL else {
            browserStart = .init()
            return
        }
        guard startConfirmed(app: replacement, calendarBacked: backingEvent != nil, now: now),
              let sessionID = activeSessionID else { return }
        lokalbotLog("detector ending meeting reason=browser-room-changed confident=true")
        pendingStop?.cancel()
        pendingStop = nil
        completeMeetingEnd(sessionID: sessionID)
        lokalbotLog("detector confirmed app=\(replacement.bundleID) in another room")
        beginMeeting(app: replacement, calendarEvent: calendarEvent, now: now)
    }

    func checkNow() { tick() }

#if DEBUG
    func tickForTesting() async {
        tick()
        await browserPollTask?.value
    }
#endif

    nonisolated static func meetingAppCandidates(bundleIDs: [(bundleID: String, pid: pid_t)]) -> [DetectedApp] {
        bundleIDs.compactMap { entry in
            guard let name = knownApps[entry.bundleID] else { return nil }
            return DetectedApp(name: name, bundleID: entry.bundleID, pid: entry.pid,
                               usesMicrophoneDetection: entry.bundleID == expressBundleID)
        }
    }

    nonisolated static func hasBuiltInCallDetection(_ bundleID: String) -> Bool {
        knownApps[bundleID] != nil || documentCallHosts.contains(bundleID) || microphoneBrowsers.contains(bundleID)
    }

    nonisolated private static func microphoneCandidates(
        in running: [RunningApp], additional: Set<String>, browser: Bool
    ) -> [DetectedApp] {
        guard browser || !additional.isEmpty else { return [] }
        return running.compactMap { app in
            guard let bundle = app.bundleIdentifier, app.processIdentifier != ProcessInfo.processInfo.processIdentifier
            else { return nil }
            if browser {
                guard microphoneBrowsers.contains(bundle) else { return nil }
            } else {
                guard additional.contains(bundle.lowercased()), !hasBuiltInCallDetection(bundle) else { return nil }
            }
            let candidate = DetectedApp(name: app.localizedName ?? bundle, bundleID: bundle,
                                        pid: app.processIdentifier, usesMicrophoneDetection: true)
            return microphoneIsActive(for: candidate) ? candidate : nil
        }
    }

    nonisolated static func microphoneIsActive(for app: DetectedApp) -> Bool {
        let audio = CaptureEnvironment.current.audio
        if audio.isProcessRunningInput(processID: app.pid) { return true }
        return currentAudioProcesses().contains { stream in
            guard stream.id != app.pid, let bundle = stream.bundleID,
                  audioBundleID(bundle, belongsTo: app.bundleID) else { return false }
            return audio.isProcessRunningInput(processID: stream.id)
        }
    }

    nonisolated private static func nativeApp(bundleID: String,
                                              in running: [RunningApp]) -> DetectedApp? {
        meetingAppCandidates(bundleIDs: running.compactMap { app in
            guard app.bundleIdentifier == bundleID else { return nil }
            return (bundleID: bundleID, pid: app.processIdentifier)
        }).first
    }

    nonisolated private static func nativeMeetingApp(in running: [RunningApp],
                                                     requireAudio: Bool = false) -> DetectedApp? {
        let candidates = meetingAppCandidates(bundleIDs: running.compactMap { app in
            guard let bid = app.bundleIdentifier else { return nil }
            return (bundleID: bid, pid: app.processIdentifier)
        })
        guard requireAudio else { return candidates.first }
        let active = candidates.filter { hasAudio(for: $0) }
        guard !active.isEmpty else { return nil }
        if let frontmostPID = CaptureEnvironment.current.workspace.frontmostApplication()?.processIdentifier,
           let frontmost = active.first(where: { $0.pid == frontmostPID }) {
            return frontmost
        }
        return active.first
    }

    nonisolated static func visibleBrowserMeeting(in running: [RunningApp] = CaptureEnvironment.current.workspace.runningApplications()) -> DetectedApp? {
        browserMeeting(in: running, calendarEvent: nil, calendarEnabled: false, requireCalendarForBrowser: false)
    }

    nonisolated private static func browserMeeting(in running: [RunningApp],
                                                   calendarEvent: CalendarMeetingCandidate?,
                                                   calendarEnabled: Bool,
                                                   requireCalendarForBrowser: Bool,
                                                   snapshots: [pid_t: BrowserMeetingSession.Snapshot]? = nil) -> DetectedApp? {
        let calendarBacked = calendarEnabled && calendarEvent?.meetingURL != nil
        guard !requireCalendarForBrowser || calendarBacked else { return nil }
        for app in running {
            guard let bid = app.bundleIdentifier, documentCallHosts.contains(bid),
                  let snapshot = snapshots.map({ $0[app.processIdentifier] })
                    ?? BrowserMeetingSession.snapshot(processID: app.processIdentifier,
                        expectedURL: calendarBacked ? calendarEvent?.meetingURL : nil),
                  MeetingMatcher.browserCountsAsMeeting(titleMatchesMarker: false, hasOutputAudio: false,
                    calendarBacked: calendarBacked, requireCalendarForBrowser: requireCalendarForBrowser,
                    verifiedSession: snapshot.state == .inCall) else { continue }
            let target = DetectedApp(name: app.localizedName ?? "Browser", bundleID: bid,
                                     pid: app.processIdentifier, meetingURL: snapshot.url)
            let audioProcess = currentOutputAudioProcess(for: target)
            return DetectedApp(name: target.name, bundleID: bid,
                               pid: audioProcess?.id ?? target.pid, meetingURL: snapshot.url)
        }
        return nil
    }

    nonisolated static func hostBrowserBundleID(forAudioBundleID bundleID: String) -> String? {
        if browsers.contains(bundleID) { return bundleID }
        return browsers.first { browserAudioBundleID(bundleID, belongsTo: $0) }
    }

    nonisolated static func browserAudioBundleID(_ bundleID: String, belongsTo browserBundleID: String) -> Bool {
        let bundle = bundleID.lowercased()
        let browser = browserBundleID.lowercased()
        return bundle == browser || bundle.hasPrefix("\(browser).helper")
    }

    nonisolated static let foreignHelperHosts: [String: String] = [
        "com.bytedance.lark.helper": "com.electron.lark",
        "com.alibaba.dingtalk-helper": "com.alibaba.dingtalkmac",
        "cisco-systems.sparkhelper": "cisco-systems.spark",
    ]

    nonisolated static func audioBundleID(_ bundleID: String, belongsTo appBundleID: String) -> Bool {
        if browsers.contains(appBundleID) {
            return browserAudioBundleID(bundleID, belongsTo: appBundleID)
        }
        let bundle = bundleID.lowercased()
        let host = appBundleID.lowercased()
        if host == "us.zoom.xos" {
            return bundle == host
                || bundle == "us.zoom.cpthost"
                || bundle.hasPrefix("us.zoom.xos.")
        }
        if foreignHelperHosts.contains(where: { helper, helperHost in
            helperHost == host && (bundle == helper || bundle.hasPrefix("\(helper)."))
        }) {
            return true
        }
        return bundle == host || bundle.hasPrefix("\(host).")
    }

    nonisolated private static func rankedOutputAudioProcess(for app: DetectedApp,
                                                             in processes: [AudioProcess]) -> AudioProcess? {
        if documentCallHosts.contains(app.bundleID) || app.bundleID == "us.zoom.xos" {
            let matches = processes.filter { process in
                guard process.isRunningOutput, let bundleID = process.bundleID else { return false }
                return audioBundleID(bundleID, belongsTo: app.bundleID)
            }
            return matches.first { $0.id == app.pid && $0.bundleID != app.bundleID }
                ?? matches.first { $0.bundleID != app.bundleID }
                ?? matches.first { $0.id == app.pid }
                ?? matches.first
        }
        return processes.first {
            $0.id == app.pid && $0.isRunningOutput
        } ?? processes.first {
            $0.isRunningOutput && $0.bundleID == app.bundleID
        } ?? processes.first { process in
            guard process.isRunningOutput, let bundleID = process.bundleID else { return false }
            return audioBundleID(bundleID, belongsTo: app.bundleID)
        }
    }

    nonisolated static func bestOutputAudioProcess(for app: DetectedApp,
                                                   in processes: [AudioProcess],
                                                   excluding excludedPIDs: Set<pid_t> = []) -> AudioProcess? {
        rankedOutputAudioProcess(
            for: app,
            in: processes.filter {
                !excludedPIDs.contains($0.id) && carriesMeetingSignal(bundleID: $0.bundleID)
            })
    }

    nonisolated static func bestCaptureAudioProcess(for app: DetectedApp,
                                                    in processes: [AudioProcess]) -> AudioProcess? {
        captureTargetProcess(for: app, in: processes)
    }

    nonisolated static func bestAlwaysOpenAudioProcess(for app: DetectedApp,
                                                       in processes: [AudioProcess]) -> AudioProcess? {
        rankedOutputAudioProcess(
            for: app,
            in: processes.filter { process in
                guard process.isRunningOutput,
                      let bundleID = process.bundleID,
                      !carriesMeetingSignal(bundleID: bundleID) else { return false }
                return audioBundleID(bundleID, belongsTo: app.bundleID)
            })
    }

    nonisolated static func currentOutputAudioProcess(
        for app: DetectedApp,
        excluding excludedPIDs: Set<pid_t> = []
    ) -> AudioProcess? {
        let processes = currentAudioProcesses()
        return bestOutputAudioProcess(for: app, in: processes, excluding: excludedPIDs)
    }

    nonisolated static func captureTargetProcess(for app: DetectedApp,
                                                 in processes: [AudioProcess],
                                                 excluding excludedPIDs: Set<pid_t> = []) -> AudioProcess? {
        let available = processes.filter { !excludedPIDs.contains($0.id) }
        let namespace = available.filter { process in
            guard let bundleID = process.bundleID else { return false }
            return audioBundleID(bundleID, belongsTo: app.bundleID)
        }
        if let emitting = bestOutputAudioProcess(for: app, in: available) {
            rememberCaptureTarget(emitting.id, for: app.bundleID)
            return emitting
        }
        if let openStream = namespace.filter(\.isRunningOutput).min(by: { $0.id < $1.id }) {
            rememberCaptureTarget(openStream.id, for: app.bundleID)
            return openStream
        }
        if let remembered = rememberedCaptureTarget(for: app.bundleID),
           let process = namespace.first(where: { $0.id == remembered }) {
            return process
        }
        let siblings = namespace.filter { $0.bundleID != app.bundleID }
        return siblings.min { $0.id < $1.id } ?? namespace.min { $0.id < $1.id }
    }

    nonisolated(unsafe) private static var lastEmittingCaptureTargets: [String: pid_t] = [:]

    nonisolated private static func rememberCaptureTarget(_ pid: pid_t, for bundleID: String) {
        processSnapshotLock.lock()
        lastEmittingCaptureTargets[bundleID] = pid
        processSnapshotLock.unlock()
    }

    nonisolated private static func rememberedCaptureTarget(for bundleID: String) -> pid_t? {
        processSnapshotLock.lock()
        defer { processSnapshotLock.unlock() }
        return lastEmittingCaptureTargets[bundleID]
    }

    nonisolated static func resetCaptureTargetMemory() {
        processSnapshotLock.lock()
        lastEmittingCaptureTargets.removeAll()
        processSnapshotLock.unlock()
    }

    nonisolated static func captureCandidateApp(
        in running: [RunningApp] = CaptureEnvironment.current.workspace.runningApplications(),
        expectedMeetingURL: URL? = nil,
        expectedBundleID: String? = nil
    ) -> DetectedApp? {
        let running = running.filter { expectedBundleID == nil || $0.bundleIdentifier == expectedBundleID }
        if expectedMeetingURL == nil, let native = nativeMeetingApp(in: running, requireAudio: true) { return native }
        for app in running {
            guard let bundleID = app.bundleIdentifier, documentCallHosts.contains(bundleID),
                  let snapshot = BrowserMeetingSession.snapshot(
                    processID: app.processIdentifier,
                    expectedURL: expectedMeetingURL),
                  snapshot.state == .inCall else { continue }
            let target = DetectedApp(
                name: app.localizedName ?? "Browser",
                bundleID: bundleID,
                pid: app.processIdentifier,
                meetingURL: snapshot.url)
            let audioProcess = currentOutputAudioProcess(for: target)
            return DetectedApp(
                name: target.name,
                bundleID: target.bundleID,
                pid: audioProcess?.id ?? target.pid,
                meetingURL: target.meetingURL)
        }
        guard expectedMeetingURL == nil else { return nil }
        let nativeCandidates = meetingAppCandidates(bundleIDs: running.compactMap { app in
            guard let bundleID = app.bundleIdentifier else { return nil }
            return (bundleID: bundleID, pid: app.processIdentifier)
        })
        return idleCaptureCandidate(in: nativeCandidates, expectedBundleID: expectedBundleID,
                                    frontmostPID: CaptureEnvironment.current.workspace.frontmostApplication()?.processIdentifier)
    }

    nonisolated static func idleCaptureCandidate(in candidates: [DetectedApp], expectedBundleID: String?,
                                                 frontmostPID: pid_t?) -> DetectedApp? {
        guard let expectedBundleID else { return nil }
        let bound = candidates.filter { $0.bundleID == expectedBundleID }
        if bound.count == 1 { return bound[0] }
        return bound.first { $0.pid == frontmostPID }
    }

    nonisolated static func alwaysOpenCaptureCandidate(
        in running: [RunningApp] = CaptureEnvironment.current.workspace.runningApplications(),
        processes: [AudioProcess] = MeetingDetector.currentAudioProcesses(),
        frontmostPID: pid_t? = CaptureEnvironment.current.workspace.frontmostApplication()?.processIdentifier
    ) -> DetectedApp? {
        let nativeCandidates = meetingAppCandidates(bundleIDs: running.compactMap { app in
            guard let bundleID = app.bundleIdentifier else { return nil }
            return (bundleID: bundleID, pid: app.processIdentifier)
        })
        let holdable = nativeCandidates.filter { bestAlwaysOpenAudioProcess(for: $0, in: processes) != nil }
        if holdable.count == 1 { return holdable[0] }
        return holdable.first { $0.pid == frontmostPID }
    }

    nonisolated static func currentCaptureTargetProcess(
        for app: DetectedApp,
        excluding excludedPIDs: Set<pid_t> = []
    ) -> AudioProcess? {
        captureTargetProcess(
            for: app,
            in: currentAudioProcesses(),
            excluding: excludedPIDs)
    }

    nonisolated static func currentAudioProcesses(now: Date? = nil) -> [AudioProcess] {
        let now = now ?? CaptureEnvironment.current.clock.now()
        processSnapshotLock.lock()
        if let processSnapshot,
           now.timeIntervalSince(processSnapshot.capturedAt) <= processSnapshotLifetime {
            processSnapshotLock.unlock()
            return processSnapshot.processes
        }
        processSnapshotLock.unlock()

        let processes = (try? CaptureEnvironment.current.audio.processes()) ?? []
        processSnapshotLock.lock()
        processSnapshot = (now, processes)
        processSnapshotLock.unlock()
        return processes
    }

    nonisolated static func invalidateAudioProcessSnapshot() {
        processSnapshotLock.lock()
        processSnapshot = nil
        processSnapshotLock.unlock()
    }

    nonisolated private static func continuingApp(_ app: DetectedApp, in running: [RunningApp]) -> DetectedApp? {
        if app.usesMicrophoneDetection {
            return running.contains { $0.bundleIdentifier == app.bundleID && $0.processIdentifier == app.pid } ? app : nil
        }
        if knownApps[app.bundleID] != nil {
            return running.contains { $0.bundleIdentifier == app.bundleID } ? app : nil
        }
        if documentCallHosts.contains(app.bundleID) {
            return running.contains { $0.bundleIdentifier == app.bundleID } ? app : nil
        }
        return CaptureEnvironment.current.workspace.isRunning(processID: app.pid) ? app : nil
    }

    nonisolated private static func hasOutputAudio(for app: DetectedApp) -> Bool {
        currentOutputAudioProcess(for: app) != nil
    }

    nonisolated private static func hasAudio(for app: DetectedApp) -> Bool {
        if app.usesMicrophoneDetection { return microphoneIsActive(for: app) }
        return hasOutputAudio(for: app) || hasInputAudio(for: app)
    }

    private func hasContinuingAudio(for app: DetectedApp, now: Date) -> Bool {
        if app.usesMicrophoneDetection {
            if Self.microphoneBrowsers.contains(app.bundleID) {
                return browserMicrophoneCandidates.contains(app)
            }
            return Self.microphoneIsActive(for: app)
        }
        let processes = Self.currentAudioProcesses(now: now)
        let reliableAudioActive = Self.bestOutputAudioProcess(
            for: app,
            in: processes) != nil || Self.hasInputAudio(for: app)
        let alwaysOpenAudioActive = Self.bestAlwaysOpenAudioProcess(
            for: app,
            in: processes) != nil
        return continuationLease.allowsContinuation(
            reliableAudioActive: reliableAudioActive,
            alwaysOpenAudioActive: alwaysOpenAudioActive,
            now: now,
            grace: Self.alwaysOpenAudioContinuationGrace)
    }

    nonisolated private static func hasInputAudio(for app: DetectedApp) -> Bool {
        guard !documentCallHosts.contains(app.bundleID) else { return false }
        return CaptureEnvironment.current.audio.isProcessRunningInput(processID: app.pid)
    }
}
