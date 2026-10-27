import AppKit
import CoreAudio

/// A permanently-open process may bridge a brief gap in otherwise reliable
/// meeting audio, but it may not become evidence by itself. The detector owns
/// one lease per active session and renews it only when app audio that can
/// actually stop is observed.
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

/// Detects meeting start/end by combining two signals (design doc §2.1):
///   1. A known meeting app is running.
///   2. The default input device (mic) is in use system-wide.
/// Start fires immediately; end fires after a debounce so brief mic drops
/// (e.g. switching AirPods) don't split a meeting in two.
///
/// Reacts instantly via Core Audio property listeners (mic in use, default
/// device change) and NSWorkspace launch/quit notifications; a slow safety
/// poll covers what has no notification — browser call state.
@MainActor
final class MeetingDetector {

    struct DetectedApp: Equatable {
        let name: String
        let bundleID: String
        let pid: pid_t
        var meetingURL: URL?
    }

    /// Known native meeting apps.
    ///
    /// Feishu ships as `Lark.app` with Lark's original `com.electron.lark`
    /// identifier; current international Lark builds use
    /// `com.larksuite.larkApp`. WeChat is deliberately absent: its voice
    /// messages and videos play long enough to pass the sustained-audio gate,
    /// so listing it would start meetings that are not calls.
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
    ]

    /// Native bundles whose newly-started output is a strong meeting signal on
    /// its own. Broader communication apps (Slack/Teams/FaceTime, and Feishu,
    /// Lark, DingTalk and WeCom, which also carry chat and voice messages) can
    /// make non-meeting sounds, so the audio monitor only auto-records those when
    /// an active calendar meeting backs the signal; the detector still picks them
    /// up on its own, but only once their audio has lasted
    /// `nativeAudioMinimumConfirmationDuration` (see
    /// `requiresSustainedAudioForStart`). Tencent Meeting and VooV Meeting are
    /// dedicated conferencing apps, like Zoom.
    nonisolated private static let highConfidenceNativeAudioBundles: Set<String> = [
        "us.zoom.xos",
        "com.webex.meetingmanager",
        "Cisco-Systems.Spark",
        "com.tencent.meeting",
        "com.tencent.tencentmeeting",
    ]

    nonisolated static func shouldAutoRecordNativeAudioMonitor(bundleID: String, calendarBacked: Bool) -> Bool {
        highConfidenceNativeAudioBundles.contains(bundleID) || calendarBacked
    }

    /// Minimum duration a broad communication app's audio must sustain before
    /// it counts as a meeting start. Confirmation is inclusive at exactly this
    /// duration; shorter candidates are rejected. A message ding or launch blip
    /// opens an output stream just as a call does, so the value must sit above
    /// the measured transient range.
    ///
    /// Twelve seconds leaves a 1.2 s margin above the longest observed short
    /// false start (10.8 s) while keeping real-call start latency bounded close
    /// to the previous ten-second gate. The other short samples were 0.2 s and
    /// 7.6 s, reconstructed against the 15 s stop debounce.
    /// It deliberately does not try to cover the two longer ones (21.1 s and
    /// 48.9 s) — those were an output stream held open while emitting digital
    /// silence (`peakRMS=0.000000` throughout), which no threshold separates
    /// from a real call without also refusing to record one. That case is a
    /// detection-side defect rather than a timing one; see the note on
    /// `alwaysOpenAudioBundles`.
    nonisolated static let nativeAudioMinimumConfirmationDuration: TimeInterval = 12

    /// How long the confirmation window survives a candidate producing no
    /// output audio at all, before `nativeAudioMinimumConfirmationDuration`
    /// has elapsed.
    ///
    /// `detectRunningMeetingApp` requires current audio (`requireAudio: true`)
    /// so the confirmation window is watching a signal that is not "is a call
    /// happening" but "is the remote side making sound right now" — and in a
    /// real conversation the remote side spends much of its time listening.
    /// Without this, the very first quiet turn dropped the candidate entirely
    /// (not merely the elapsed time — the app stopped being detected as
    /// running at all), and a live 12-second window essentially never
    /// completed: six consecutive real attempts on 2026-08-26 each failed
    /// after 4.2–12.7 s, two of them past the 12 s mark itself.
    ///
    /// Six seconds is half the confirmation window on purpose: a single blip
    /// followed by silence past this tolerance still resets — the case
    /// `nativeAudioMinimumConfirmationDuration` exists to guard against — while
    /// audio recurring at least this often lets a real conversation complete
    /// the window. It only ever bridges a gap in evidence; it never invents
    /// evidence on its own, so this cannot make an idle-but-open app confirm.
    nonisolated static let nativeAudioConfirmationGapTolerance: TimeInterval = 6

    /// Bundles inside a meeting app's namespace that hold their Core Audio
    /// streams open for the app's whole lifetime, so their state carries no
    /// information about whether a call is running.
    ///
    /// Measured with Teams launched and idle, 20 samples over 20 s:
    /// `com.microsoft.teams2.modulehost` reported `isRunningOutput` *and*
    /// `isRunningInput` true in 20/20, while all three
    /// `com.microsoft.teams2.helper` processes reported false in 60/60. Any
    /// detection rule that matches the whole namespace therefore sees Teams as
    /// permanently in a meeting, and neither a longer window nor the microphone
    /// can tell the two apart. Capture must still be free to tap these — a tap
    /// on a silent process simply records nothing until audio starts — so this
    /// belongs to the detection question alone.
    nonisolated static let alwaysOpenAudioBundles: Set<String> = [
        "com.microsoft.teams2.modulehost",
    ]

    /// Whether an audio process says anything about a call being under way.
    nonisolated static func carriesMeetingSignal(bundleID: String?) -> Bool {
        guard let bundleID else { return true }
        return !alwaysOpenAudioBundles.contains(bundleID.lowercased())
    }

    /// Whether this app's audio must survive
    /// `nativeAudioMinimumConfirmationDuration` before a recording starts.
    /// Dedicated conferencing bundles and
    /// calendar-backed starts stay instant, and browsers are gated by their own
    /// title/calendar rules, so they never wait here.
    nonisolated static func requiresSustainedAudioForStart(bundleID: String, calendarBacked: Bool) -> Bool {
        guard knownApps[bundleID] != nil else { return false }
        return !shouldAutoRecordNativeAudioMonitor(bundleID: bundleID, calendarBacked: calendarBacked)
    }

    /// Browsers whose supported meeting documents can be verified through
    /// Accessibility. Unsupported or unreadable call controls abstain.
    nonisolated static let browsers: Set<String> = [
        "com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser",
        "com.microsoft.edgemac", "com.brave.Browser", "org.mozilla.firefox",
    ]

    var onMeetingStarted: ((MeetingDetectionContext) -> Void)?
    var onMeetingSwitched: ((MeetingDetectionContext) -> Void)?
    var onMeetingEnded: ((MeetingDetectionEnd) -> Void)?
    var onBrowserObservation: ((UUID, Bool, Date?) -> Void)?
    var onVerifiedSourceAvailable: ((MeetingDetectionContext) -> Void)?
    var stopDebounce: TimeInterval = AppSettings.defaultStopDebounceSeconds
    /// Extra grace before stopping while a calendar-backed meeting is still in
    /// its scheduled window — brief audio drops mid-meeting shouldn't end it.
    nonisolated static let calendarBackedGrace: TimeInterval = 180
    /// Accessibility can briefly fail while Chrome rebuilds its WebArea or
    /// another bounded reader is using the same tree. Keep the recording alive
    /// through that uncertainty. This is separate from the user's short audio
    /// debounce because it protects the lifecycle signal itself.
    nonisolated static let browserObservationGrace: TimeInterval = 120
    /// A browser host can disappear for a few seconds while Chrome replaces
    /// the application process even though the Meet tab and helper audio stay
    /// alive. This shorter window avoids splitting one call while bounding the
    /// raw tail when the browser really did quit.
    nonisolated static let browserHostReconnectGrace: TimeInterval = 15
    /// Teams keeps `modulehost` open while idle, so it can bridge a pause only
    /// while backed by recent audio from a process whose signal can disappear.
    /// With the default 15-second stop debounce, the detector remains tolerant
    /// for about one minute after the last reliable sample, then ends normally.
    nonisolated static let alwaysOpenAudioContinuationGrace: TimeInterval = 45

    // Calendar-assisted detection, synced from `AppSettings` by `AppState`.
    var calendar: CalendarEventProviding?
    var calendarEnabled = false
    var requireCalendarForBrowser = false

    private(set) var activeApp: DetectedApp?
    private(set) var activeSessionID: UUID?
    /// The calendar event matched when the current session started — drives the
    /// extended stop grace and is carried into the recording's metadata.
    private var activeCalendarEvent: CalendarMeetingCandidate?
    private var continuationLease = MeetingContinuationLease()
    private var environment: CaptureEnvironment { .current }
    private var timer: CaptureTimer?
    private var pendingStop: CaptureTimer?
    private var browserStart = BrowserMeetingSession.StartGate()
    private(set) var detectedContentEnd: Date?
    private(set) var endedMeetingURL: URL?
    private var browserLifecycle = BrowserMeetingSession.LifecycleTracker()
    /// The start candidate still waiting out
    /// `nativeAudioMinimumConfirmationDuration`: when its audio was first seen,
    /// and when it was last seen — the second lets a normal conversational gap
    /// (the remote side listening rather than talking) survive without
    /// restarting the window. See `nativeAudioConfirmationGapTolerance`.
    private var startConfirmation = MeetingMatcher.StartConfirmationState()
    /// Last logged start-decision state, so the safety poll does not
    /// repeat the same line forever. Diagnostics only.
    private var lastLoggedStartState: String?
    private var pendingStartRecheck: CaptureTimer?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var browserPollGeneration = 0
    private var browserPollTask: Task<Void, Never>?
    private var browserSnapshots: [pid_t: BrowserMeetingSession.Snapshot] = [:]
    /// Calls in rooms other than the bound one, read only while the bound
    /// call cannot be verified. See `handOffIfAnotherRoomIsInCall`.
    private var otherRoomSnapshots: [pid_t: BrowserMeetingSession.Snapshot] = [:]

    /// Whether the active session's call is still proven: always for a native
    /// app session, and for a browser call until its observation is lost. A
    /// manual recording joins only a proven session.
    var verifiesActiveCall: Bool {
        guard let activeApp else { return false }
        return !Self.browsers.contains(activeApp.bundleID) || browserLifecycle.lostAt == nil
    }

    private var micListener: AudioObjectPropertyListenerBlock?
    private var listenedDevice = AudioObjectID(kAudioObjectUnknown)
    /// Added once — re-adding on every re-arm multiplies Core Audio
    /// callbacks (each mic open/close then fans out into a tick storm).
    private var deviceChangeListener: AudioObjectPropertyListenerBlock?

    /// Core Audio process enumeration is comparatively expensive and several
    /// meeting subsystems ask for the same answer in one detector/poller turn.
    /// Keep a very short-lived snapshot so detection, helper handoff, and media
    /// pausing share one system query without making process state feel stale.
    nonisolated private static let processSnapshotLock = NSLock()
    nonisolated(unsafe) private static var processSnapshot: (capturedAt: Date, processes: [AudioProcess])?
    nonisolated private static let processSnapshotLifetime: TimeInterval = 0.35

    func start() {
        guard timer == nil else { return }
        // Safety-net poll (browser call state has no change notification).
        timer = environment.clock.repeating(every: 2) { [weak self] in
            self?.tick()
        }
        // Instant signals: mic state, default-device change, app launch/quit.
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
        browserSnapshots = [:]
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

    /// Listener on the default input device's "running somewhere" property,
    /// re-armed whenever the default input device itself changes.
    private func armMicListener() {
        disarmMicListener()
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        if deviceChangeListener == nil {
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                DispatchQueue.main.async {
                    self?.armMicListener()   // device changed → re-arm on the new one
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

    /// Full teardown including the default-device listener; only called
    /// from `stop()`. `armMicListener()` calls `disarmMicListener()` (not
    /// this) to keep the device-change listener installed across re-arms.
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
        // Coalesce mic/device/timer bursts while cross-process AX is running.
        guard browserPollTask == nil else { return }
        let generation = browserPollGeneration
        let boundApp = activeApp
        let eventURL = calendarEnabled ? calendar?.activeCandidate(now: environment.clock.now())?.meetingURL : nil
        let expectedURL = boundApp?.meetingURL ?? eventURL
        let browserApps = environment.workspace.runningApplications().filter {
            $0.bundleIdentifier.map(Self.browsers.contains) ?? false
        }
        let pids = browserApps.filter {
            // Once bound, unrelated browsers cannot delay the call's evidence
            // or make a valid observation expire before it reaches the detector.
            guard let boundApp, Self.browsers.contains(boundApp.bundleID) else { return true }
            return $0.bundleIdentifier == boundApp.bundleID
        }.map(\.processIdentifier)
        // A bound call that stopped proving itself must not hide a verified
        // call in another room, so these reads look past the binding.
        let otherRoomPIDs = boundApp != nil && !verifiesActiveCall ? browserApps.map(\.processIdentifier) : []
        let otherRoomURL = Self.otherRoom(eventURL, than: boundApp?.meetingURL)
        guard !pids.isEmpty || !otherRoomPIDs.isEmpty else {
            browserSnapshots = [:]
            otherRoomSnapshots = [:]
            applyTick()
            return
        }
        browserPollTask = Task { @MainActor [weak self] in
            let clock = CaptureEnvironment.current.clock
            let started = clock.now()
            let observations = await BrowserMeetingSession.observe(processIDs: pids, expectedURL: expectedURL)
            let otherRoomsStarted = clock.now()
            var otherRooms: [pid_t: BrowserMeetingSession.Snapshot] = [:]
            if !otherRoomPIDs.isEmpty {
                otherRooms = await BrowserMeetingSession.observe(processIDs: otherRoomPIDs, expectedURL: otherRoomURL)
            }
            guard let self, !Task.isCancelled, generation == self.browserPollGeneration else { return }
            self.browserPollTask = nil
            guard self.activeApp == boundApp,
                  eventURL == (self.calendarEnabled ? self.calendar?.activeCandidate(now: self.environment.clock.now())?.meetingURL : nil) else {
                self.tick()
                return
            }
            // A slow/unresponsive browser is uncertainty, never fresh call evidence.
            self.browserSnapshots = otherRoomsStarted.timeIntervalSince(started) < 2 ? observations : [:]
            self.otherRoomSnapshots = clock.now().timeIntervalSince(otherRoomsStarted) < 2 ? otherRooms : [:]
            self.applyTick()
        }
    }

    /// The calendar event's room when it differs from the bound one, so a
    /// calendar-backed handoff reads only that room. Nil reads any single
    /// verified call. Calendar links can carry query parameters.
    nonisolated static func otherRoom(_ eventURL: URL?, than boundURL: URL?) -> URL? {
        guard let room = eventURL.flatMap({ BrowserMeetingSession.meetURL($0.absoluteString) }),
              room != boundURL?.absoluteString else { return nil }
        return URL(string: room)
    }

    private func applyTick() {
        let now = environment.clock.now()
        let running = environment.workspace.runningApplications()
        let calendarEvent = calendarEnabled ? calendar?.activeCandidate(now: now) : nil

        if let currentApp = activeApp {
            if Self.browsers.contains(currentApp.bundleID) {
                tickBrowser(currentApp, now: now)
                return
            }
            let continuingApp = Self.continuingApp(currentApp, in: running)
            let appAudioActive = continuingApp.map {
                hasContinuingAudio(for: $0, now: now)
            } ?? false
            let isBrowserApp = continuingApp.map { Self.browsers.contains($0.bundleID) } ?? false
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
                let replacementApp = Self.detectRunningMeetingApp(
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

        let runningMeetingApp = Self.detectRunningMeetingApp(
            in: running,
            calendarEvent: calendarEvent,
            calendarEnabled: calendarEnabled,
            requireCalendarForBrowser: requireCalendarForBrowser, snapshots: browserSnapshots)
        let isBrowserApp = runningMeetingApp.map { Self.browsers.contains($0.bundleID) } ?? false
        let calendarBackedBrowser = isBrowserApp && calendarEnabled && calendarEvent?.meetingURL != nil
        // Both start and continuation hinge on the selected app's OWN audio
        // (input or output), not the global mic flag. A global mic check can
        // belong to Dictation/QuickTime/another meeting app while a known meeting
        // app is merely idle in the background.
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

        // No fresh output audio this instant. `detectRunningMeetingApp`
        // requires it, so this branch also covers the remote side simply
        // listening rather than talking — the app itself may still be mid-call.
        // A candidate already inside its confirmation window gets a grace
        // period before that silence is read as the call having ended.
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

    /// The complementary native audio monitor uses the same lifecycle identity
    /// as normal detection, so its recording can be stopped by its own end event.
    func acceptNativeAudioStart(app: DetectedApp, calendarEvent: CalendarMeetingCandidate?) {
        guard activeApp == nil, Self.knownApps[app.bundleID] != nil,
              Self.shouldAutoRecordNativeAudioMonitor(
                bundleID: app.bundleID, calendarBacked: calendarEvent != nil) else { return }
        beginMeeting(app: app, calendarEvent: calendarEvent, now: environment.clock.now())
    }

    /// Tracks how long the start candidate's audio has been continuously
    /// present and answers whether it may start a recording yet. Candidates
    /// that need no confirmation answer true on their first tick.
    /// Called only when `app` has fresh output audio this tick. Advances the
    /// window's evidence clock; `tick()` separately decides whether a gap
    /// since the last call may still keep this same window alive.
    private func startConfirmed(app: DetectedApp, calendarBacked: Bool, now: Date) -> Bool {
        if Self.browsers.contains(app.bundleID) {
            guard let url = app.meetingURL else { browserStart = .init(); return false }
            return browserStart.observe(.init(url: url, state: .inCall), at: now)
        }
        guard Self.requiresSustainedAudioForStart(
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
        // Ticks are event-driven plus a slow safety poll, so a real meeting
        // would otherwise wait for the next poll boundary instead of starting
        // the moment the minimum duration elapses.
        let elapsed = now.timeIntervalSince(pendingStart.firstSeenAt)
        scheduleStartConfirmationRecheck(
            after: Self.nativeAudioMinimumConfirmationDuration - elapsed,
            generation: pendingStart.generation)
        return false
    }

    /// Keep one recording alive while a specific running meeting app earns its
    /// sustained-audio handoff confirmation. The lease exists only for the
    /// candidate that supplied fresh meeting-app audio and only through its
    /// bounded conversational gap; unrelated system audio cannot extend it.
    private func keepsActiveSessionForPendingHandoff(
        in running: [RunningApp],
        freshCandidateBundleID: String?,
        calendarBacked: Bool,
        now: Date
    ) -> Bool {
        // Browser replacements use `browserStart`; do not reset that separate
        // gate merely because there is no native-audio confirmation window.
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
        // Replace the ordinary start recheck with the earlier handoff boundary.
        // Otherwise a callback queued for the 12-second confirmation point can
        // let a one-frame candidate hold the old recording past its 6-second
        // audio-gap lease.
        cancelPendingStartRecheck()
        scheduleStartConfirmationRecheck(
            after: confirmationRemaining > 0
                ? min(gapRemaining, confirmationRemaining)
                : gapRemaining,
            generation: pending.generation)
        return true
    }

    /// Logs a start-decision state once per change. The detector otherwise
    /// says nothing at all unless it starts a recording, so "it did not fire"
    /// has no evidence behind it.
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

    /// `loggingLoss` is false when the candidate is being cleared because it
    /// just started a meeting — that clears the same state but is a success,
    /// not a loss, and must not log as one.
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

    nonisolated private static func detectRunningMeetingApp(
        in running: [RunningApp],
        calendarEvent: CalendarMeetingCandidate?,
        calendarEnabled: Bool,
        requireCalendarForBrowser: Bool,
        snapshots: [pid_t: BrowserMeetingSession.Snapshot]
    ) -> DetectedApp? {
        nativeMeetingApp(in: running, requireAudio: true)
            ?? browserMeeting(in: running,
                              calendarEvent: calendarEvent,
                              calendarEnabled: calendarEnabled,
                              requireCalendarForBrowser: requireCalendarForBrowser,
                              snapshots: snapshots)
    }

    private func scheduleStopIfNeeded(
        now: Date,
        immediately: Bool = false,
        reason: String? = nil,
        confident: Bool = true
    ) {
        guard activeApp != nil, let sessionID = activeSessionID, pendingStop == nil else { return }
        // Native app audio gaps may use calendar grace. A browser call uses
        // only its bound document state and never receives that extension.
        let isBrowser = activeApp.map { Self.browsers.contains($0.bundleID) } ?? false
        let calendarStillActive = !isBrowser && (activeCalendarEvent?.isActive(at: now) ?? false)
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

    /// A browser-wide audio stream is never evidence that the bound call is
    /// still running. A verified window that still holds the call keeps it,
    /// even when its call controls cannot be read. Otherwise a missing
    /// snapshot remains uncertainty until positive end evidence or user Stop.
    /// The last verified observation is diagnostic, never a content cutoff.
    private func tickBrowser(_ app: DetectedApp, now: Date) {
        let host = environment.workspace.runningApplications().first { $0.bundleIdentifier == app.bundleID }
        let snapshot = host.flatMap { browserSnapshots[$0.processIdentifier] }
        let observedState: BrowserMeetingSession.State? = snapshot.map {
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
            grace: max(Self.browserObservationGrace, max(0, stopDebounce)),
            hostReconnectGrace: Self.browserHostReconnectGrace)
        if let sessionID = activeSessionID {
            onBrowserObservation?(sessionID, browserLifecycle.lostAt != nil,
                                  browserLifecycle.lastEvidenceAt)
        }
        switch event {
        case .none:
            // Only an open uncertainty window may leave a pending end in place.
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

    /// Back-to-back events can share one room. While the bound call still
    /// holds its window, the next event on that room's link starts a new
    /// meeting, as it does for a native app. An event in another room does
    /// not: the current call is running over.
    private func splitAtCalendarHandoff(_ app: DetectedApp, now: Date) {
        guard calendarEnabled, let room = app.meetingURL?.absoluteString,
              let event = calendar?.activeCandidate(now: now),
              event.meetingURL.flatMap({ BrowserMeetingSession.meetURL($0.absoluteString) }) == room else { return }
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

    /// A bound call that stopped proving itself cannot hide a verified call in
    /// another room: the user has moved on, and the new room is a new meeting
    /// with the same start rules as any other. The old room's last evidence
    /// stays diagnostic, so nothing is trimmed from its recording.
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

    /// Audio-monitor events must pass the same sustained call-state gate.
    func checkNow() { tick() }

#if DEBUG
    /// One detection tick, awaiting any browser observation it starts.
    func tickForTesting() async {
        tick()
        await browserPollTask?.value
    }
#endif

    /// Which running bundles count as native meeting apps, in priority order.
    /// Split out from `NSRunningApplication` so the choice is testable.
    nonisolated static func meetingAppCandidates(bundleIDs: [(bundleID: String, pid: pid_t)]) -> [DetectedApp] {
        bundleIDs.compactMap { entry in
            guard let name = knownApps[entry.bundleID] else { return nil }
            return DetectedApp(name: name, bundleID: entry.bundleID, pid: entry.pid)
        }
    }

    /// A specific native app by bundle id, with no audio requirement at all —
    /// used to check whether a confirmation candidate is still open during a
    /// bridged gap, where the point is exactly that it may be silent right now.
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

    /// A verified supported browser call without calendar requirements.
    /// Audio capture remains a process tap; call evidence supplies lifecycle.
    nonisolated static func visibleBrowserMeeting(in running: [RunningApp] = CaptureEnvironment.current.workspace.runningApplications()) -> DetectedApp? {
        browserMeeting(in: running, calendarEvent: nil, calendarEnabled: false, requireCalendarForBrowser: false)
    }

    /// A browser with a verified in-call document, optionally restricted to
    /// the calendar event URL. Unrelated browser output never starts a call.
    nonisolated private static func browserMeeting(in running: [RunningApp],
                                                   calendarEvent: CalendarMeetingCandidate?,
                                                   calendarEnabled: Bool,
                                                   requireCalendarForBrowser: Bool,
                                                   snapshots: [pid_t: BrowserMeetingSession.Snapshot]? = nil) -> DetectedApp? {
        let calendarBacked = calendarEnabled && calendarEvent?.meetingURL != nil
        guard !requireCalendarForBrowser || calendarBacked else { return nil }
        for app in running {
            guard let bid = app.bundleIdentifier, browsers.contains(bid),
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

    /// Helper processes named outside their host's bundle namespace, keyed by
    /// the lowercased helper identifier (its own `.`-suffixed variants match
    /// too) and mapped to the lowercased host. Feishu's Electron helpers keep
    /// ByteDance's identifier while the app itself is `com.electron.lark`, and
    /// DingTalk's helper is `com.alibaba.DingTalk-Helper` beside
    /// `com.alibaba.DingTalkMac`. Webex's media engine (`WebexHelper`, which
    /// renders the remote participants' audio) registers with Core Audio as
    /// `Cisco-Systems.SparkHelper`, with no dot after `Spark`, so it is not in
    /// the `Cisco-Systems.Spark.` namespace of its host `Cisco-Systems.Spark`.
    nonisolated static let foreignHelperHosts: [String: String] = [
        "com.bytedance.lark.helper": "com.electron.lark",
        "com.alibaba.dingtalk-helper": "com.alibaba.dingtalkmac",
        "cisco-systems.sparkhelper": "cisco-systems.spark",
    ]

    /// Whether an audio process belongs to the detected meeting application's
    /// process family. Zoom routes call audio through `us.zoom.CptHost`, while
    /// Chromium-family browsers use `.helper` bundle identifiers.
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
        // Any bundle inside the host's own namespace is that app's audio.
        // Teams alone emits call audio from `<host>.helper` (WebView) *and*
        // `<host>.modulehost`, so matching only `.helper` misses the process
        // that is usually the one running. This mirrors the `us.zoom.xos.`
        // prefix rule above rather than enumerating every suffix Microsoft ships.
        return bundle == host || bundle.hasPrefix("\(host).")
    }

    /// Ranks an already-vetted set of output processes inside an app family.
    /// Detection supplies only processes that carry meeting signal; capture
    /// adds its broader open-stream and silent-process fallbacks separately.
    nonisolated private static func rankedOutputAudioProcess(for app: DetectedApp,
                                                             in processes: [AudioProcess]) -> AudioProcess? {
        if browsers.contains(app.bundleID) || app.bundleID == "us.zoom.xos" {
            let matches = processes.filter { process in
                guard process.isRunningOutput, let bundleID = process.bundleID else { return false }
                return audioBundleID(bundleID, belongsTo: app.bundleID)
            }
            // Chrome/Edge/Safari often emit meeting audio from helper processes,
            // while the browser host can still expose a tap that only delivers
            // silence. Prefer a helper unless the detected PID is already one.
            return matches.first { $0.id == app.pid && $0.bundleID != app.bundleID }
                ?? matches.first { $0.bundleID != app.bundleID }
                ?? matches.first { $0.id == app.pid }
                ?? matches.first
        }
        // Electron meeting apps (Teams, Slack, Webex) route call audio through
        // helper processes just as Chromium browsers do. `audioBundleID` already
        // models that `<host>.helper` relationship for every host, so honour it
        // here as a fallback — without it `hasOutputAudio` stays false, the
        // detector never surfaces the app, and the process tap is skipped
        // entirely, leaving the meeting recorded mic-only. The host keeps
        // precedence so apps whose main process emits audio are unaffected.
        return processes.first {
            $0.id == app.pid && $0.isRunningOutput
        } ?? processes.first {
            $0.isRunningOutput && $0.bundleID == app.bundleID
        } ?? processes.first { process in
            guard process.isRunningOutput, let bundleID = process.bundleID else { return false }
            return audioBundleID(bundleID, belongsTo: app.bundleID)
        }
    }

    /// Best output process that is evidence of a live meeting. Detection-only:
    /// capture must use ``bestCaptureAudioProcess(for:in:)`` so bundles with
    /// always-open streams remain tappable.
    nonisolated static func bestOutputAudioProcess(for app: DetectedApp,
                                                   in processes: [AudioProcess],
                                                   excluding excludedPIDs: Set<pid_t> = []) -> AudioProcess? {
        rankedOutputAudioProcess(
            for: app,
            in: processes.filter {
                !excludedPIDs.contains($0.id) && carriesMeetingSignal(bundleID: $0.bundleID)
            })
    }

    /// Canonical capture selection, including always-open streams plus the
    /// remembered and stable silent-process fallbacks. Keeping this entry point
    /// aligned with ``captureTargetProcess`` prevents detection-only ranking
    /// from leaking back into capture callers.
    nonisolated static func bestCaptureAudioProcess(for app: DetectedApp,
                                                    in processes: [AudioProcess]) -> AudioProcess? {
        captureTargetProcess(for: app, in: processes)
    }

    /// Best permanently-open stream inside this app's process family. This is
    /// ambiguous context, never standalone meeting evidence: the active
    /// detector may use it only while ``MeetingContinuationLease`` is backed by
    /// recent reliable audio.
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

    /// The process to attach the capture tap to.
    ///
    /// Detection asks whether the app is producing output *right now*; capture
    /// only needs a process that *can* produce it — a tap on a momentarily
    /// silent process simply records nothing until audio starts. Falling back
    /// to the host PID is not an option: Teams' main process owns no Core Audio
    /// object at all, so `AudioHardwarePropertyTranslatePIDToProcessObject`
    /// fails and the tap is refused with `processNotFound` whenever the meeting
    /// happens to be quiet at the moment recording starts.
    ///
    /// `excluding` is a set rather than one PID because a recording can rule out
    /// more than one process: a tap that delivered nothing stays ruled out for
    /// the rest of the session, and with several siblings alive the watchdog
    /// otherwise hands back a process it already found empty.
    nonisolated static func captureTargetProcess(for app: DetectedApp,
                                                 in processes: [AudioProcess],
                                                 excluding excludedPIDs: Set<pid_t> = []) -> AudioProcess? {
        let available = processes.filter { !excludedPIDs.contains($0.id) }
        let namespace = available.filter { process in
            guard let bundleID = process.bundleID else { return false }
            return audioBundleID(bundleID, belongsTo: app.bundleID)
        }
        // A process emitting right now is the answer, and worth remembering:
        // it is the only moment we learn which sibling of this app actually
        // carries call audio.
        if let emitting = bestOutputAudioProcess(for: app, in: available) {
            rememberCaptureTarget(emitting.id, for: app.bundleID)
            return emitting
        }
        // An always-open stream is intentionally excluded from meeting
        // detection, but it is preferable to a streamless helper for capture:
        // Core Audio will deliver silent buffers now and call audio later.
        if let openStream = namespace.filter(\.isRunningOutput).min(by: { $0.id < $1.id }) {
            rememberCaptureTarget(openStream.id, for: app.bundleID)
            return openStream
        }
        // Nothing is emitting. Core Audio specifies no order for the process
        // list, so picking the first sibling would tap a different one from
        // one call to the next — and with several Teams or browser helpers
        // alive, usually one that never carries call audio. Prefer the process
        // this app was last seen emitting from.
        if let remembered = rememberedCaptureTarget(for: app.bundleID),
           let process = namespace.first(where: { $0.id == remembered }) {
            return process
        }
        // Still nothing known: siblings before the host, for the same reason
        // the browser branch prefers helpers — the host is the process least
        // likely to own audio, and for Teams it owns no Core Audio object at
        // all. Lowest PID within each group so the choice is at least stable
        // across the retries the watchdog makes.
        let siblings = namespace.filter { $0.bundleID != app.bundleID }
        return siblings.min { $0.id < $1.id } ?? namespace.min { $0.id < $1.id }
    }

    /// The PID each app was last seen emitting from. Small and per-bundle: it
    /// only has to survive between a quiet start and the watchdog's next look.
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

    /// Clears what capture learned about which sibling carries audio. For
    /// tests, so one case cannot leak its choice into the next.
    nonisolated static func resetCaptureTargetMemory() {
        processSnapshotLock.lock()
        lastEmittingCaptureTargets.removeAll()
        processSnapshotLock.unlock()
    }

    /// A running meeting app to capture from when nothing was detected.
    /// Deliberately does *not* require current output: a recording started by
    /// hand routinely begins before the remote side says anything, and a tap on
    /// a silent process records nothing until audio arrives rather than
    /// failing. A browser is eligible only when its Accessibility tree proves
    /// one unambiguous in-call Meet document, so a manual recording does not
    /// silently widen its capture scope to arbitrary browser media.
    nonisolated static func captureCandidateApp(
        in running: [RunningApp] = CaptureEnvironment.current.workspace.runningApplications(),
        expectedMeetingURL: URL? = nil,
        expectedBundleID: String? = nil
    ) -> DetectedApp? {
        let running = running.filter { expectedBundleID == nil || $0.bundleIdentifier == expectedBundleID }
        // Prefer native apps that are actually emitting, then a verified
        // browser call. An idle Teams/Zoom process must not shadow the Chrome
        // call the user is recording just because it happens to be open.
        if expectedMeetingURL == nil, let native = nativeMeetingApp(in: running, requireAudio: true) { return native }
        for app in running {
            guard let bundleID = app.bundleIdentifier, browsers.contains(bundleID),
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
        // An idle native target is useful only when the recording is already
        // bound to it. An unrelated idle Zoom/Teams window must not seize an
        // unbound manual recording while its intended browser call is hidden.
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

    /// A meeting app whose process family holds an always-open output stream,
    /// for an unbound recording to hold while nothing verified is available.
    ///
    /// New Teams plays call audio only through `modulehost`, which is open
    /// whether or not a call is running (#179). ``captureCandidateApp`` can
    /// never return it: emitting evidence skips always-open streams, and an
    /// idle app needs a binding. Because an idle app looks the same, the caller
    /// taps this without binding the recording, and any verified source may
    /// replace it until the tap has carried the call itself. When several
    /// apps qualify, only a frontmost one is chosen.
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

    /// Compatibility entry point for callers that only need the default
    /// capture target. Recovery uses ``currentCaptureTargetProcess`` directly
    /// so it can exclude a dead attachment.
    nonisolated static func currentCaptureAudioProcess(for app: DetectedApp) -> AudioProcess? {
        currentCaptureTargetProcess(for: app)
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
        if knownApps[app.bundleID] != nil {
            return running.contains { $0.bundleIdentifier == app.bundleID } ? app : nil
        }
        if browsers.contains(app.bundleID) {
            return running.contains { $0.bundleIdentifier == app.bundleID } ? app : nil
        }
        return CaptureEnvironment.current.workspace.isRunning(processID: app.pid) ? app : nil
    }

    nonisolated private static func hasOutputAudio(for app: DetectedApp) -> Bool {
        currentOutputAudioProcess(for: app) != nil
    }

    /// The meeting app's own audio activity — output, or (native apps only)
    /// input. Reflects the app rather than our recorder's hold on the default
    /// input device.
    ///
    /// This is the *start* question, so it reads only streams that are evidence
    /// of a call. Deciding whether one is still running is
    /// ``hasContinuingAudio(for:now:)``.
    nonisolated private static func hasAudio(for app: DetectedApp) -> Bool {
        hasOutputAudio(for: app) || hasInputAudio(for: app)
    }

    /// Reliable app audio renews the active session's lease. A permanently-open
    /// stream may bridge a normal speech pause while that lease is recent, but
    /// once the lease expires it cannot prevent the ordinary stop debounce from
    /// ending a Teams call whose app remains open.
    private func hasContinuingAudio(for app: DetectedApp, now: Date) -> Bool {
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
        // Browser mic capture lives in helper processes we don't track here, so
        // browsers rely on output audio. For native apps the per-process input
        // flag is the app's own mic use — never our recorder's.
        guard !browsers.contains(app.bundleID) else { return false }
        return CaptureEnvironment.current.audio.isProcessRunningInput(processID: app.pid)
    }
}
