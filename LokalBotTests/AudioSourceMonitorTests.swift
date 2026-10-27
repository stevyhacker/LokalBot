import CoreAudio
import XCTest
@testable import LokalBot

/// `AudioSourceMonitor` detects when an app newly starts producing audio.
/// Pure media/music players (Spotify, Apple Music, …) must be excluded so
/// playing music never becomes a recording candidate, while meeting apps and
/// the browsers that host web meetings stay eligible.
final class AudioSourceMonitorTests: XCTestCase {

    func testMusicAndMediaPlayersAreExcluded() {
        // Streaming music
        XCTAssertTrue(AudioSourceMonitor.isMediaPlayer("com.spotify.client"), "Spotify")
        XCTAssertTrue(AudioSourceMonitor.isMediaPlayer("com.apple.Music"), "Apple Music")
        XCTAssertTrue(AudioSourceMonitor.isMediaPlayer("com.amazon.music"), "Amazon Music")
        XCTAssertTrue(AudioSourceMonitor.isMediaPlayer("com.tidal.desktop"), "TIDAL")
        XCTAssertTrue(AudioSourceMonitor.isMediaPlayer("com.deezer.deezer-desktop"), "Deezer")
        // Local-library / audiophile players
        XCTAssertTrue(AudioSourceMonitor.isMediaPlayer("com.swinsian.Swinsian"), "Swinsian")
        XCTAssertTrue(AudioSourceMonitor.isMediaPlayer("com.foobar2000.mac"), "foobar2000")
        XCTAssertTrue(AudioSourceMonitor.isMediaPlayer("com.coppertino.Vox"), "VOX")
        // Podcasts & video players
        XCTAssertTrue(AudioSourceMonitor.isMediaPlayer("com.apple.podcasts"), "Podcasts")
        XCTAssertTrue(AudioSourceMonitor.isMediaPlayer("org.videolan.vlc"), "VLC")
    }

    func testMeetingAppsAreNotExcluded() {
        XCTAssertFalse(AudioSourceMonitor.isMediaPlayer("us.zoom.xos"), "Zoom")
        XCTAssertFalse(AudioSourceMonitor.isMediaPlayer("com.microsoft.teams2"), "Teams")
        XCTAssertFalse(AudioSourceMonitor.isMediaPlayer("com.apple.FaceTime"), "FaceTime")
    }

    /// Browsers host web meetings (Meet/Jitsi/Whereby), so they must NEVER be
    /// treated as media — otherwise a browser meeting would stop being detected.
    func testBrowsersAreNotExcluded() {
        XCTAssertFalse(AudioSourceMonitor.isMediaPlayer("com.google.Chrome"), "Chrome")
        XCTAssertFalse(AudioSourceMonitor.isMediaPlayer("com.apple.Safari"), "Safari")
        XCTAssertFalse(AudioSourceMonitor.isMediaPlayer("company.thebrowser.Browser"), "Arc")
    }

    func testBrowserAudioHelpersMapToBrowserHost() {
        XCTAssertEqual(MeetingDetector.hostBrowserBundleID(forAudioBundleID: "com.google.Chrome.helper"),
                       "com.google.Chrome")
        XCTAssertEqual(MeetingDetector.hostBrowserBundleID(forAudioBundleID: "com.google.Chrome"),
                       "com.google.Chrome")
        XCTAssertNil(MeetingDetector.hostBrowserBundleID(forAudioBundleID: "com.spotify.client"))
    }

    func testBrowserCapturePrefersRunningHelperOverHostProcess() {
        let host = AudioProcess(id: 100,
                                name: "Google Chrome",
                                bundleID: "com.google.Chrome",
                                objectID: AudioObjectID(100),
                                isRunningOutput: true)
        let helper = AudioProcess(id: 200,
                                  name: "Google Chrome Helper",
                                  bundleID: "com.google.Chrome.helper",
                                  objectID: AudioObjectID(200),
                                  isRunningOutput: true)
        let app = MeetingDetector.DetectedApp(name: "Google Chrome",
                                              bundleID: "com.google.Chrome",
                                              pid: host.id)

        XCTAssertEqual(MeetingDetector.bestCaptureAudioProcess(for: app, in: [host, helper])?.id,
                       helper.id)
    }

    func testBrowserCaptureKeepsDetectedPidWhenItIsAlreadyHelper() {
        let helper = AudioProcess(id: 200,
                                  name: "Google Chrome Helper",
                                  bundleID: "com.google.Chrome.helper",
                                  objectID: AudioObjectID(200),
                                  isRunningOutput: true)
        let otherHelper = AudioProcess(id: 300,
                                       name: "Google Chrome Helper",
                                       bundleID: "com.google.Chrome.helper",
                                       objectID: AudioObjectID(300),
                                       isRunningOutput: true)
        let app = MeetingDetector.DetectedApp(name: "Google Chrome",
                                              bundleID: "com.google.Chrome",
                                              pid: helper.id)

        XCTAssertEqual(MeetingDetector.bestCaptureAudioProcess(for: app, in: [otherHelper, helper])?.id,
                       helper.id)
    }

    func testZoomCaptureMapsCptHostAndPrefersItOverTheHost() {
        let host = AudioProcess(id: 100,
                                name: "zoom.us",
                                bundleID: "us.zoom.xos",
                                objectID: AudioObjectID(100),
                                isRunningOutput: true)
        let helper = AudioProcess(id: 200,
                                  name: "CptHost",
                                  bundleID: "us.zoom.CptHost",
                                  objectID: AudioObjectID(200),
                                  isRunningOutput: true)
        let app = MeetingDetector.DetectedApp(
            name: "Zoom", bundleID: "us.zoom.xos", pid: host.id)

        XCTAssertTrue(MeetingDetector.audioBundleID(
            "us.zoom.CptHost", belongsTo: "us.zoom.xos"))
        XCTAssertEqual(
            MeetingDetector.bestCaptureAudioProcess(for: app, in: [host, helper])?.id,
            helper.id)
    }

    /// Electron meeting apps (Teams, Slack, Webex) emit call audio from a
    /// helper process exactly as Chromium browsers do, and ``audioBundleID``
    /// already models that `<host>.helper` relationship for every host — not
    /// just the browser/Zoom special cases. The capture lookup must honour it
    /// outside those branches too: when it does not, `hasOutputAudio` is false,
    /// the detector never surfaces the app, and `RecordingController` skips the
    /// process tap entirely — the meeting silently records mic-only.
    func testNativeAppCaptureFallsBackToHelperProcess() {
        let host = AudioProcess(id: 100,
                                name: "Microsoft Teams",
                                bundleID: "com.microsoft.teams2",
                                objectID: AudioObjectID(100),
                                isRunningOutput: false)
        let helper = AudioProcess(id: 200,
                                  name: "Microsoft Teams Helper",
                                  bundleID: "com.microsoft.teams2.helper",
                                  objectID: AudioObjectID(200),
                                  isRunningOutput: true)
        let app = MeetingDetector.DetectedApp(name: "Teams",
                                              bundleID: "com.microsoft.teams2",
                                              pid: host.id)

        XCTAssertTrue(MeetingDetector.audioBundleID(
            "com.microsoft.teams2.helper", belongsTo: "com.microsoft.teams2"))
        XCTAssertEqual(MeetingDetector.bestOutputAudioProcess(for: app, in: [host, helper])?.id,
                       helper.id)
    }

    /// Teams' modulehost keeps its stream open even while Teams is idle. That
    /// makes it a useful tap target but unusable as evidence that a call exists.
    func testAlwaysOpenNamespaceProcessIsCaptureOnly() {
        MeetingDetector.resetCaptureTargetMemory()
        XCTAssertTrue(MeetingDetector.audioBundleID(
            "com.microsoft.teams2.modulehost", belongsTo: "com.microsoft.teams2"))
        XCTAssertFalse(MeetingDetector.carriesMeetingSignal(
            bundleID: "com.microsoft.teams2.modulehost"))

        let host = AudioProcess(id: 100,
                                name: "Microsoft Teams",
                                bundleID: "com.microsoft.teams2",
                                objectID: AudioObjectID(100),
                                isRunningOutput: false)
        let moduleHost = AudioProcess(id: 300,
                                      name: "Microsoft Teams ModuleHost",
                                      bundleID: "com.microsoft.teams2.modulehost",
                                      objectID: AudioObjectID(300),
                                      isRunningOutput: true)
        let app = MeetingDetector.DetectedApp(name: "Teams",
                                              bundleID: "com.microsoft.teams2",
                                              pid: host.id)

        XCTAssertNil(MeetingDetector.bestOutputAudioProcess(for: app, in: [host, moduleHost]))
        XCTAssertEqual(MeetingDetector.captureTargetProcess(
            for: app, in: [host, moduleHost])?.id, moduleHost.id)
    }

    /// Measured on a real Teams call: `translatePIDToProcessObject` fails for
    /// the Teams host PID because that process owns no Core Audio object. When
    /// the meeting is momentarily quiet no sibling is `isRunningOutput` either,
    /// so a capture lookup that requires current output resolves to nothing and
    /// the tap is refused. Capture must therefore accept a silent-but-present
    /// process in the namespace — the tap records once audio starts.
    func testCaptureTargetFallsBackToASilentProcessInTheNamespace() {
        let host = AudioProcess(id: 100,
                                name: "Microsoft Teams",
                                bundleID: "com.microsoft.teams2",
                                objectID: AudioObjectID(100),
                                isRunningOutput: false)
        let quietModuleHost = AudioProcess(id: 300,
                                           name: "Microsoft Teams ModuleHost",
                                           bundleID: "com.microsoft.teams2.modulehost",
                                           objectID: AudioObjectID(300),
                                           isRunningOutput: false)
        let app = MeetingDetector.DetectedApp(name: "Teams",
                                              bundleID: "com.microsoft.teams2",
                                              pid: host.id)

        // Detection correctly reports "not producing output right now"...
        XCTAssertNil(MeetingDetector.bestOutputAudioProcess(
            for: app, in: [host, quietModuleHost]))
        // ...but capture still has somewhere to attach.
        XCTAssertEqual(
            MeetingDetector.captureTargetProcess(for: app, in: [host, quietModuleHost])?.id,
            quietModuleHost.id)
    }

    /// A process carrying a real meeting signal still wins over an always-open
    /// sibling that is valid for capture but ignored by detection.
    func testCaptureTargetPrefersTheProcessThatIsActuallyEmitting() {
        let alwaysOpen = AudioProcess(id: 300,
                                      name: "Microsoft Teams ModuleHost",
                                      bundleID: "com.microsoft.teams2.modulehost",
                                      objectID: AudioObjectID(300),
                                      isRunningOutput: true)
        let emitting = AudioProcess(id: 400,
                                    name: "Microsoft Teams WebView",
                                    bundleID: "com.microsoft.teams2.helper",
                                    objectID: AudioObjectID(400),
                                    isRunningOutput: true)
        let app = MeetingDetector.DetectedApp(name: "Teams",
                                              bundleID: "com.microsoft.teams2",
                                              pid: 100)

        XCTAssertEqual(
            MeetingDetector.captureTargetProcess(for: app, in: [alwaysOpen, emitting])?.id,
            emitting.id)
    }

    /// Capture must not attach to an unrelated app just because nothing of the
    /// meeting app is running.
    func testCaptureTargetIgnoresUnrelatedProcesses() {
        let unrelated = AudioProcess(id: 500,
                                     name: "Music",
                                     bundleID: "com.apple.Music",
                                     objectID: AudioObjectID(500),
                                     isRunningOutput: true)
        let app = MeetingDetector.DetectedApp(name: "Teams",
                                              bundleID: "com.microsoft.teams2",
                                              pid: 100)

        XCTAssertNil(MeetingDetector.captureTargetProcess(for: app, in: [unrelated]))
    }

    /// A tap that delivered zero buffers must not be selected again on the
    /// recovery pass; another process in the namespace gets a chance instead.
    func testCaptureTargetCanExcludeADeadCurrentProcessForRecovery() {
        MeetingDetector.resetCaptureTargetMemory()
        let dead = AudioProcess(id: 200,
                                name: "Microsoft Teams WebView",
                                bundleID: "com.microsoft.teams2.helper",
                                objectID: AudioObjectID(200),
                                isRunningOutput: false)
        let replacement = AudioProcess(id: 300,
                                       name: "Microsoft Teams WebView",
                                       bundleID: "com.microsoft.teams2.helper",
                                       objectID: AudioObjectID(300),
                                       isRunningOutput: false)
        let app = MeetingDetector.DetectedApp(name: "Teams",
                                              bundleID: "com.microsoft.teams2",
                                              pid: 100)

        XCTAssertEqual(MeetingDetector.captureTargetProcess(
            for: app, in: [replacement, dead])?.id, dead.id)
        XCTAssertEqual(MeetingDetector.captureTargetProcess(
            for: app,
            in: [replacement, dead],
            excluding: [dead.id])?.id, replacement.id)
        XCTAssertNil(MeetingDetector.captureTargetProcess(
            for: app,
            in: [dead],
            excluding: [dead.id]))
        XCTAssertEqual(MeetingDetector.captureTargetProcess(
            for: app, in: [dead])?.id, dead.id)

        // More than one process can be ruled out within a single recording:
        // every tap that delivered nothing stays excluded, not just the last.
        let third = AudioProcess(id: 400,
                                 name: "Microsoft Teams WebView",
                                 bundleID: "com.microsoft.teams2.helper",
                                 objectID: AudioObjectID(400),
                                 isRunningOutput: false)
        XCTAssertEqual(MeetingDetector.captureTargetProcess(
            for: app,
            in: [replacement, dead, third],
            excluding: [dead.id, replacement.id])?.id, third.id)
        XCTAssertNil(MeetingDetector.captureTargetProcess(
            for: app,
            in: [replacement, dead, third],
            excluding: [dead.id, replacement.id, third.id]))
    }

    /// The namespace rule must not swallow a *different* app whose bundle id
    /// merely starts with the same characters.
    func testNamespaceMatchDoesNotSpanUnrelatedBundles() {
        XCTAssertFalse(MeetingDetector.audioBundleID(
            "com.microsoft.teams2evil", belongsTo: "com.microsoft.teams2"))
        XCTAssertFalse(MeetingDetector.audioBundleID(
            "com.microsoft.teamsother", belongsTo: "com.microsoft.teams2"))
    }

    // MARK: - Chinese meeting apps

    /// Feishu is `com.electron.lark` but its Electron helpers keep ByteDance's
    /// `com.bytedance.lark.helper`, and DingTalk's helper is
    /// `com.alibaba.DingTalk-Helper`. Neither sits in its host's namespace, so
    /// without an explicit mapping a call carried by the helper is never seen.
    func testForeignHelpersBelongToTheirOwnHostsOnly() {
        XCTAssertTrue(MeetingDetector.audioBundleID(
            "com.bytedance.lark.helper", belongsTo: "com.electron.lark"))
        XCTAssertTrue(MeetingDetector.audioBundleID(
            "com.bytedance.lark.helper.Renderer", belongsTo: "com.electron.lark"))
        XCTAssertTrue(MeetingDetector.audioBundleID(
            "com.alibaba.DingTalk-Helper", belongsTo: "com.alibaba.DingTalkMac"))
        XCTAssertTrue(MeetingDetector.audioBundleID(
            "com.larksuite.larkApp.helper", belongsTo: "com.larksuite.larkApp"))

        XCTAssertFalse(MeetingDetector.audioBundleID(
            "com.bytedance.lark.helper", belongsTo: "com.larksuite.larkApp"))
        XCTAssertFalse(MeetingDetector.audioBundleID(
            "com.alibaba.DingTalk-Helper", belongsTo: "com.electron.lark"))
        XCTAssertFalse(MeetingDetector.audioBundleID(
            "com.bytedance.lark.helperx", belongsTo: "com.electron.lark"))
    }

    /// Webex renders call audio in `WebexHelper`, which Core Audio lists as
    /// `Cisco-Systems.SparkHelper` — outside the host's `Cisco-Systems.Spark.`
    /// namespace. Without the mapping the tap lands on the silent main process
    /// and the "Them" track records nothing.
    func testWebexCallOnItsMediaHelperIsTheCaptureTarget() {
        MeetingDetector.resetCaptureTargetMemory()
        let host = AudioProcess(id: 896, name: "Webex", bundleID: "Cisco-Systems.Spark",
                                objectID: AudioObjectID(896), isRunningOutput: false)
        let helper = AudioProcess(id: 70531, name: "WebexHelper", bundleID: "Cisco-Systems.SparkHelper",
                                  objectID: AudioObjectID(70531), isRunningOutput: true)
        let app = MeetingDetector.DetectedApp(name: "Webex", bundleID: "Cisco-Systems.Spark", pid: host.id)

        XCTAssertTrue(MeetingDetector.audioBundleID(
            "Cisco-Systems.SparkHelper", belongsTo: "Cisco-Systems.Spark"))
        XCTAssertFalse(MeetingDetector.audioBundleID(
            "Cisco-Systems.SparkHelper", belongsTo: "com.webex.meetingmanager"))
        XCTAssertFalse(MeetingDetector.audioBundleID(
            "Cisco-Systems.SparkHelperX", belongsTo: "Cisco-Systems.Spark"))
        XCTAssertEqual(MeetingDetector.bestOutputAudioProcess(for: app, in: [host, helper])?.id, helper.id)
        XCTAssertEqual(MeetingDetector.bestCaptureAudioProcess(for: app, in: [host, helper])?.id, helper.id)
    }

    func testDingTalkCallOnItsHelperIsTheCaptureTarget() {
        MeetingDetector.resetCaptureTargetMemory()
        let host = AudioProcess(id: 100,
                                name: "DingTalk",
                                bundleID: "com.alibaba.DingTalkMac",
                                objectID: AudioObjectID(100),
                                isRunningOutput: false)
        let helper = AudioProcess(id: 200,
                                  name: "DingTalk Helper",
                                  bundleID: "com.alibaba.DingTalk-Helper",
                                  objectID: AudioObjectID(200),
                                  isRunningOutput: true)
        let app = MeetingDetector.DetectedApp(name: "DingTalk",
                                              bundleID: "com.alibaba.DingTalkMac",
                                              pid: host.id)

        XCTAssertEqual(MeetingDetector.bestOutputAudioProcess(for: app, in: [host, helper])?.id,
                       helper.id)
        XCTAssertEqual(MeetingDetector.bestCaptureAudioProcess(for: app, in: [host, helper])?.id,
                       helper.id)
    }

    /// WeChat stays out: its voice messages and videos play long enough to
    /// pass the sustained-audio gate and would start meetings that are not
    /// calls.
    func testChineseMeetingAppsAreCandidatesButWeChatIsNot() {
        let candidates = MeetingDetector.meetingAppCandidates(bundleIDs: [
            (bundleID: "com.tencent.meeting", pid: 10),
            (bundleID: "com.tencent.tencentmeeting", pid: 11),
            (bundleID: "com.electron.lark", pid: 12),
            (bundleID: "com.larksuite.larkApp", pid: 13),
            (bundleID: "com.alibaba.DingTalkMac", pid: 14),
            (bundleID: "com.tencent.WeWorkMac", pid: 15),
            (bundleID: "com.tencent.xinWeChat", pid: 16),
        ])

        XCTAssertEqual(candidates.map(\.name),
                       ["Tencent Meeting", "VooV Meeting", "Feishu", "Lark", "DingTalk", "WeCom"])
    }

    /// The helper fallback must stay a *fallback*: when the host process itself
    /// is producing output it remains the capture target, so apps that work
    /// today are unaffected.
    func testNativeAppCapturePrefersHostWhenItIsProducingOutput() {
        let host = AudioProcess(id: 100,
                                name: "Microsoft Teams",
                                bundleID: "com.microsoft.teams2",
                                objectID: AudioObjectID(100),
                                isRunningOutput: true)
        let helper = AudioProcess(id: 200,
                                  name: "Microsoft Teams Helper",
                                  bundleID: "com.microsoft.teams2.helper",
                                  objectID: AudioObjectID(200),
                                  isRunningOutput: true)
        let app = MeetingDetector.DetectedApp(name: "Teams",
                                              bundleID: "com.microsoft.teams2",
                                              pid: host.id)

        XCTAssertEqual(MeetingDetector.bestOutputAudioProcess(for: app, in: [host, helper])?.id,
                       host.id)
    }

    /// Unknown apps stay eligible so a genuinely-new meeting tool is still
    /// surfaced via the monitor's fallback candidate path.
    func testUnknownAppIsNotExcluded() {
        XCTAssertFalse(AudioSourceMonitor.isMediaPlayer("com.example.SomeNewMeetingApp"))
    }

    // MARK: - Choosing a target when nothing is emitting

    private func teamsApp(pid: pid_t = 100) -> MeetingDetector.DetectedApp {
        MeetingDetector.DetectedApp(name: "Teams", bundleID: "com.microsoft.teams2", pid: pid)
    }

    private func teamsHelper(_ id: pid_t) -> AudioProcess {
        AudioProcess(id: id, name: "Microsoft Teams WebView",
                     bundleID: "com.microsoft.teams2.helper",
                     objectID: AudioObjectID(id), isRunningOutput: false)
    }

    /// The moment a process emits is the only time we learn which sibling
    /// actually carries call audio, so that choice must survive the quiet
    /// stretch that follows rather than being re-guessed from list order.
    func testCaptureTargetRemembersTheProcessLastSeenEmitting() {
        MeetingDetector.resetCaptureTargetMemory()
        let app = teamsApp()
        let emitting = AudioProcess(id: 400, name: "Microsoft Teams WebView",
                                    bundleID: "com.microsoft.teams2.helper",
                                    objectID: AudioObjectID(400), isRunningOutput: true)
        let otherHelper = teamsHelper(700)

        XCTAssertEqual(
            MeetingDetector.captureTargetProcess(for: app, in: [otherHelper, emitting])?.id,
            emitting.id)

        // Same processes, none of them emitting any more.
        let quiet = teamsHelper(400)
        XCTAssertEqual(
            MeetingDetector.captureTargetProcess(for: app, in: [otherHelper, quiet])?.id,
            quiet.id)
    }

    /// With nothing emitting and nothing remembered, the choice must not
    /// depend on the order Core Audio happened to return the processes in.
    func testCaptureTargetIsStableAcrossProcessListOrder() {
        MeetingDetector.resetCaptureTargetMemory()
        let app = teamsApp()
        let first = teamsHelper(700)
        let second = teamsHelper(300)

        let forward = MeetingDetector.captureTargetProcess(for: app, in: [first, second])?.id
        MeetingDetector.resetCaptureTargetMemory()
        let reversed = MeetingDetector.captureTargetProcess(for: app, in: [second, first])?.id

        XCTAssertEqual(forward, reversed)
        XCTAssertEqual(forward, second.id)
    }

    // MARK: - Capture target for a recording started by hand

    /// A hand-started recording has no detected app, but the tap still needs a
    /// target; a running meeting app qualifies even while it is silent.
    func testMeetingAppCandidatesIgnoreAudioAndUnknownBundles() {
        let candidates = MeetingDetector.meetingAppCandidates(bundleIDs: [
            (bundleID: "com.apple.Music", pid: 10),
            (bundleID: "com.microsoft.teams2", pid: 20),
            (bundleID: "us.zoom.xos", pid: 30),
        ])

        XCTAssertEqual(candidates.map(\.bundleID), ["com.microsoft.teams2", "us.zoom.xos"])
        XCTAssertEqual(candidates.first?.pid, 20)

        XCTAssertTrue(MeetingDetector.meetingAppCandidates(bundleIDs: [
            (bundleID: "com.apple.Music", pid: 10),
        ]).isEmpty)
    }

    // MARK: - Continuing a meeting that is already under way

    /// Teams' modulehost is useful context during a call, but it remains open
    /// while Teams is idle and therefore cannot be reliable evidence itself.
    func testAlwaysOpenStreamIsClassifiedSeparatelyFromReliableAudio() {
        let host = AudioProcess(id: 100,
                                name: "Microsoft Teams",
                                bundleID: "com.microsoft.teams2",
                                objectID: AudioObjectID(100),
                                isRunningOutput: false)
        let moduleHost = AudioProcess(id: 300,
                                      name: "Microsoft Teams ModuleHost",
                                      bundleID: "com.microsoft.teams2.modulehost",
                                      objectID: AudioObjectID(300),
                                      isRunningOutput: true)
        let app = MeetingDetector.DetectedApp(name: "Teams",
                                              bundleID: "com.microsoft.teams2",
                                              pid: host.id)

        XCTAssertNil(MeetingDetector.bestOutputAudioProcess(for: app, in: [host, moduleHost]),
                     "starting must not read an always-open stream as a call")
        XCTAssertEqual(
            MeetingDetector.bestAlwaysOpenAudioProcess(for: app, in: [host, moduleHost])?.id,
            moduleHost.id)
    }

    /// Once reliable call audio has been seen, the always-open stream bridges an
    /// ordinary speech pause without starting the stop debounce.
    func testRecentReliableAudioLetsAlwaysOpenStreamBridgeAPause() {
        let start = Date(timeIntervalSince1970: 1_000)
        var lease = MeetingContinuationLease()

        XCTAssertTrue(lease.allowsContinuation(
            reliableAudioActive: true,
            alwaysOpenAudioActive: true,
            now: start,
            grace: MeetingDetector.alwaysOpenAudioContinuationGrace))
        XCTAssertTrue(lease.allowsContinuation(
            reliableAudioActive: false,
            alwaysOpenAudioActive: true,
            now: start.addingTimeInterval(10),
            grace: MeetingDetector.alwaysOpenAudioContinuationGrace))
    }

    /// The same idle modulehost must not keep a finished call alive forever.
    /// Once recent reliable evidence expires, the detector can begin its normal
    /// stop debounce even though modulehost still reports running output.
    func testAlwaysOpenStreamExpiresAfterFiniteContinuationGrace() {
        let start = Date(timeIntervalSince1970: 1_000)
        let grace = MeetingDetector.alwaysOpenAudioContinuationGrace
        var lease = MeetingContinuationLease()

        XCTAssertFalse(lease.allowsContinuation(
            reliableAudioActive: false,
            alwaysOpenAudioActive: true,
            now: start,
            grace: grace), "an always-open stream may not create its own lease")
        XCTAssertTrue(lease.allowsContinuation(
            reliableAudioActive: true,
            alwaysOpenAudioActive: false,
            now: start,
            grace: grace))
        XCTAssertTrue(lease.allowsContinuation(
            reliableAudioActive: false,
            alwaysOpenAudioActive: true,
            now: start.addingTimeInterval(grace),
            grace: grace), "the finite boundary is inclusive")
        XCTAssertFalse(lease.allowsContinuation(
            reliableAudioActive: false,
            alwaysOpenAudioActive: true,
            now: start.addingTimeInterval(grace + 0.001),
            grace: grace))
    }

    func testAlwaysOpenLookupStillReportsNoAudioWhenNothingIsEmitting() {
        let host = AudioProcess(id: 100,
                                name: "Microsoft Teams",
                                bundleID: "com.microsoft.teams2",
                                objectID: AudioObjectID(100),
                                isRunningOutput: false)
        let quietModuleHost = AudioProcess(id: 300,
                                           name: "Microsoft Teams ModuleHost",
                                           bundleID: "com.microsoft.teams2.modulehost",
                                           objectID: AudioObjectID(300),
                                           isRunningOutput: false)
        let app = MeetingDetector.DetectedApp(name: "Teams",
                                              bundleID: "com.microsoft.teams2",
                                              pid: host.id)

        XCTAssertNil(MeetingDetector.bestAlwaysOpenAudioProcess(
            for: app, in: [host, quietModuleHost]))
    }

    func testAlwaysOpenLookupDoesNotAcceptALookalikeBundle() {
        let impostor = AudioProcess(id: 300,
                                    name: "Not Teams",
                                    bundleID: "com.microsoft.teams2evil.modulehost",
                                    objectID: AudioObjectID(300),
                                    isRunningOutput: true)
        let app = MeetingDetector.DetectedApp(name: "Teams",
                                              bundleID: "com.microsoft.teams2",
                                              pid: 100)

        XCTAssertNil(MeetingDetector.bestAlwaysOpenAudioProcess(for: app, in: [impostor]))
    }

    /// Capture health can prove the current tap silent while Core Audio still
    /// reports its stream open. Recovery must be able to exclude that current
    /// PID and discover a different helper that is actively emitting.
    func testReliableOutputLookupCanExcludeTheSilentCurrentTap() {
        let current = AudioProcess(id: 200,
                                   name: "Current Teams WebView",
                                   bundleID: "com.microsoft.teams2.helper",
                                   objectID: AudioObjectID(200),
                                   isRunningOutput: true)
        let sibling = AudioProcess(id: 300,
                                   name: "Emitting Teams WebView",
                                   bundleID: "com.microsoft.teams2.helper",
                                   objectID: AudioObjectID(300),
                                   isRunningOutput: true)
        let app = MeetingDetector.DetectedApp(name: "Teams",
                                              bundleID: "com.microsoft.teams2",
                                              pid: current.id)

        XCTAssertEqual(MeetingDetector.bestOutputAudioProcess(
            for: app, in: [current, sibling])?.id, current.id)
        XCTAssertEqual(MeetingDetector.bestOutputAudioProcess(
            for: app,
            in: [current, sibling],
            excluding: [current.id])?.id, sibling.id)
    }
}
