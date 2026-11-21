import CoreAudio
import XCTest
@testable import LokalBot

final class AudioSourceMonitorTests: XCTestCase {

    func testMusicAndMediaPlayersAreExcluded() {
        XCTAssertTrue(AudioSourceMonitor.isMediaPlayer("com.spotify.client"), "Spotify")
        XCTAssertTrue(AudioSourceMonitor.isMediaPlayer("com.apple.Music"), "Apple Music")
        XCTAssertTrue(AudioSourceMonitor.isMediaPlayer("com.amazon.music"), "Amazon Music")
        XCTAssertTrue(AudioSourceMonitor.isMediaPlayer("com.tidal.desktop"), "TIDAL")
        XCTAssertTrue(AudioSourceMonitor.isMediaPlayer("com.deezer.deezer-desktop"), "Deezer")
        XCTAssertTrue(AudioSourceMonitor.isMediaPlayer("com.swinsian.Swinsian"), "Swinsian")
        XCTAssertTrue(AudioSourceMonitor.isMediaPlayer("com.foobar2000.mac"), "foobar2000")
        XCTAssertTrue(AudioSourceMonitor.isMediaPlayer("com.coppertino.Vox"), "VOX")
        XCTAssertTrue(AudioSourceMonitor.isMediaPlayer("com.apple.podcasts"), "Podcasts")
        XCTAssertTrue(AudioSourceMonitor.isMediaPlayer("org.videolan.vlc"), "VLC")
    }

    func testMeetingAppsAreNotExcluded() {
        XCTAssertFalse(AudioSourceMonitor.isMediaPlayer("us.zoom.xos"), "Zoom")
        XCTAssertFalse(AudioSourceMonitor.isMediaPlayer("com.microsoft.teams2"), "Teams")
        XCTAssertFalse(AudioSourceMonitor.isMediaPlayer("com.apple.FaceTime"), "FaceTime")
    }

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

        XCTAssertNil(MeetingDetector.bestOutputAudioProcess(
            for: app, in: [host, quietModuleHost]))
        XCTAssertEqual(
            MeetingDetector.captureTargetProcess(for: app, in: [host, quietModuleHost])?.id,
            quietModuleHost.id)
    }

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

    func testNamespaceMatchDoesNotSpanUnrelatedBundles() {
        XCTAssertFalse(MeetingDetector.audioBundleID(
            "com.microsoft.teams2evil", belongsTo: "com.microsoft.teams2"))
        XCTAssertFalse(MeetingDetector.audioBundleID(
            "com.microsoft.teamsother", belongsTo: "com.microsoft.teams2"))
    }

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

    func testUnknownAppIsNotExcluded() {
        XCTAssertFalse(AudioSourceMonitor.isMediaPlayer("com.example.SomeNewMeetingApp"))
    }

    @MainActor
    func testPlaybackFromAnyLokalBotBuildIsNeverARecordingCandidate() {
        let builds: [AppIdentifiers.Identity] = [.release, .development, .uiTestHost]
        for (index, identity) in builds.enumerated() {
            let monitor = AudioSourceMonitor()
            monitor.apply([AudioProcess(id: pid_t(500 + index), name: "LokalBot", bundleID: identity.bundleID,
                                        objectID: AudioObjectID(500 + index), isRunningOutput: true)])
            XCTAssertNil(monitor.detectedProcess, identity.bundleID)
            monitor.stop()
        }
    }

    @MainActor
    func testACallThatStartsWhileAnotherSoundIsHeldIsStillReported() {
        func process(_ id: Int, _ bundleID: String) -> AudioProcess {
            AudioProcess(id: pid_t(id), name: bundleID, bundleID: bundleID,
                         objectID: AudioObjectID(id), isRunningOutput: true)
        }
        let chime = process(700, "com.example.ChatApp")
        let zoom = process(701, "us.zoom.xos")
        let meet = process(702, "com.google.Chrome")
        let monitor = AudioSourceMonitor()
        defer { monitor.stop() }

        monitor.apply([chime])
        XCTAssertEqual(monitor.detectedProcess?.objectID, chime.objectID)
        monitor.apply([chime, zoom])
        XCTAssertEqual(monitor.detectedProcess?.objectID, zoom.objectID)

        monitor.apply([chime, zoom, meet])
        XCTAssertEqual(monitor.detectedProcess?.objectID, zoom.objectID)
        monitor.accept()
        monitor.apply([chime, zoom, meet])
        XCTAssertEqual(monitor.detectedProcess?.objectID, meet.objectID, "it was not swallowed while the slot was busy")

        monitor.accept()
        monitor.apply([chime, zoom, meet])
        XCTAssertNil(monitor.detectedProcess)
    }

    private func teamsApp(pid: pid_t = 100) -> MeetingDetector.DetectedApp {
        MeetingDetector.DetectedApp(name: "Teams", bundleID: "com.microsoft.teams2", pid: pid)
    }

    private func teamsHelper(_ id: pid_t) -> AudioProcess {
        AudioProcess(id: id, name: "Microsoft Teams WebView",
                     bundleID: "com.microsoft.teams2.helper",
                     objectID: AudioObjectID(id), isRunningOutput: false)
    }

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

        let quiet = teamsHelper(400)
        XCTAssertEqual(
            MeetingDetector.captureTargetProcess(for: app, in: [otherHelper, quiet])?.id,
            quiet.id)
    }

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
