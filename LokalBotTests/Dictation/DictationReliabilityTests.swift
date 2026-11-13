import AppKit
import AVFoundation
import CoreMedia
import XCTest
@testable import LokalBot

/// Dictation failures reported from a Bluetooth headset (AirPods) and the
/// delivery problems found while investigating them.
@MainActor
final class DictationReliabilityTests: XCTestCase {

    // MARK: - Microphone recovery

    func testFlapDetectorTripsOnlyOnRepeatedRecoveriesInsideTheWindow() {
        var detector = MicRecoveryFlapDetector(limit: 3, window: 20)
        let start = Date()
        XCTAssertFalse(detector.recordRecovery(at: start))
        XCTAssertFalse(detector.recordRecovery(at: start.addingTimeInterval(2)))
        XCTAssertFalse(detector.recordRecovery(at: start.addingTimeInterval(4)))
        XCTAssertTrue(detector.recordRecovery(at: start.addingTimeInterval(6)),
                      "a fourth recovery within 20 s is a device that keeps dropping")

        var spaced = MicRecoveryFlapDetector(limit: 3, window: 20)
        for minute in 0..<10 {
            XCTAssertFalse(spaced.recordRecovery(at: start.addingTimeInterval(Double(minute) * 60)),
                           "occasional recoveries are ordinary device changes")
        }
    }

    /// The AirPods loop: every rebuild succeeded, reset the retry budget, and
    /// the device dropped again, so dictation recorded fragments forever and
    /// never told anyone. A successful rebuild must not reset the flap budget.
    func testRecorderDegradesWhenTheInputKeepsDroppingAfterSuccessfulRecoveries() async throws {
        let folder = try Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let inputs = ScriptedInputs()
        let recorder = MicRecorder(
            makeInput: { inputs.make() },
            flapPolicy: MicRecoveryFlapDetector(limit: 2, window: 60))
        try recorder.start(writingTo: folder.appendingPathComponent("dictation.caf"))
        defer { recorder.stop() }

        for cycle in 1...2 {
            inputs.current?.running = false
            recorder.recoverCapture(reason: "The microphone stopped.")
            try await Self.waitUntil(timeout: 4) {
                inputs.made == cycle + 1 && recorder.captureHealth().recoveryState == .healthy
            }
        }

        inputs.current?.running = false
        recorder.recoverCapture(reason: "The microphone stopped.")
        guard case .degraded = recorder.captureHealth().recoveryState else {
            return XCTFail("expected degraded, got \(recorder.captureHealth().recoveryState)")
        }
    }

    func testMeetingRecorderWithoutAFlapPolicyKeepsRecovering() async throws {
        let folder = try Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let inputs = ScriptedInputs()
        let recorder = MicRecorder(makeInput: { inputs.make() })
        try recorder.start(writingTo: folder.appendingPathComponent("mic.caf"))
        defer { recorder.stop() }

        for cycle in 1...3 {
            inputs.current?.running = false
            recorder.recoverCapture(reason: "The microphone stopped.")
            if case .degraded = recorder.captureHealth().recoveryState {
                return XCTFail("meetings keep retrying (cycle \(cycle))")
            }
            try await Self.waitUntil(timeout: 4) {
                inputs.made == cycle + 1 && recorder.captureHealth().recoveryState == .healthy
            }
        }
    }

    func testMicrophoneFailureKeepsSpeechThatWasAlreadyCaptured() {
        XCTAssertTrue(DictationCoordinator.shouldTranscribeAfterMicrophoneFailure(capturedDuration: 6))
        XCTAssertFalse(DictationCoordinator.shouldTranscribeAfterMicrophoneFailure(capturedDuration: 0.2))
    }

    func testHUDShowsWhenTheMicrophoneIsNotDeliveringAudio() {
        let start = Date()
        XCTAssertEqual(DictationCoordinator.idleMicrophoneStatus(
            lastAudioWriteAt: nil, startedAt: start, now: start.addingTimeInterval(0.5)), "")
        XCTAssertEqual(DictationCoordinator.idleMicrophoneStatus(
            lastAudioWriteAt: nil, startedAt: start, now: start.addingTimeInterval(3)),
                       "Waiting for the microphone")
        XCTAssertEqual(DictationCoordinator.idleMicrophoneStatus(
            lastAudioWriteAt: start.addingTimeInterval(1), startedAt: start,
            now: start.addingTimeInterval(1.5)), "")
        XCTAssertEqual(DictationCoordinator.idleMicrophoneStatus(
            lastAudioWriteAt: start.addingTimeInterval(1), startedAt: start,
            now: start.addingTimeInterval(4)), "No audio from the microphone")

        XCTAssertFalse(DictationCoordinator.isReceivingAudio(lastAudioWriteAt: nil, now: start))
        XCTAssertTrue(DictationCoordinator.isReceivingAudio(
            lastAudioWriteAt: start, now: start.addingTimeInterval(0.4)))
        XCTAssertFalse(DictationCoordinator.isReceivingAudio(
            lastAudioWriteAt: start, now: start.addingTimeInterval(1.5)))
    }

    func testCaptureSessionBuffersBecomePCMWithTheirSamplesIntact() throws {
        let format = CaptureSessionMicrophoneInput.clientFormat
        let source = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_024))
        source.frameLength = 1_024
        for index in 0..<1_024 {
            source.floatChannelData![0][index] = Float(index) / 1_024
        }
        let sampleBuffer = try Self.sampleBuffer(from: source)

        let converted = try XCTUnwrap(CaptureSessionMicrophoneInput.pcmBuffer(from: sampleBuffer))

        XCTAssertEqual(converted.frameLength, 1_024)
        XCTAssertEqual(converted.format.sampleRate, 16_000)
        XCTAssertEqual(converted.format.channelCount, 1)
        XCTAssertEqual(converted.floatChannelData![0][512], 0.5, accuracy: 0.000_1)
    }

    // MARK: - Shortcut

    func testShortcutDuringTranscriptionNeverDiscardsTheDictation() {
        let transcribing = DictationCoordinator.State.transcribing(startedAt: Date())
        let composing = DictationCoordinator.State.composing(startedAt: Date())
        for state in [transcribing, composing] {
            XCTAssertEqual(DictationCoordinator.toggleAction(
                state: state, isStarting: false, hasPendingModelRetry: false, fromShortcut: true),
                           .ignore)
            XCTAssertEqual(DictationCoordinator.toggleAction(
                state: state, isStarting: false, hasPendingModelRetry: false, fromShortcut: false),
                           .cancel, "the menu's Cancel Dictation still cancels")
        }
        XCTAssertEqual(DictationCoordinator.toggleAction(
            state: transcribing, isStarting: false, hasPendingModelRetry: true, fromShortcut: true),
                       .retryModelPreparation)
        XCTAssertEqual(DictationCoordinator.toggleAction(
            state: .idle, isStarting: false, hasPendingModelRetry: false, fromShortcut: true), .start)
        XCTAssertEqual(DictationCoordinator.toggleAction(
            state: .recording(startedAt: Date()), isStarting: false,
            hasPendingModelRetry: false, fromShortcut: true), .finish)
        XCTAssertEqual(DictationCoordinator.toggleAction(
            state: .idle, isStarting: true, hasPendingModelRetry: false, fromShortcut: true), .cancelStart)
    }

    func testReadyTextMatchesTheTriggerMode() {
        let shortcut = DictationShortcut.handyDefault
        XCTAssertTrue(DictationView.readyText(triggerMode: .pushToTalk, shortcut: shortcut).contains("hold"))
        XCTAssertFalse(DictationView.readyText(triggerMode: .toggle, shortcut: shortcut).contains("hold"))
        XCTAssertTrue(DictationView.readyText(triggerMode: .toggle, shortcut: shortcut).contains("press"))
    }

    // MARK: - Delivery target

    func testTextSelectedBeforeDictatingIsReplacedNotRefused() throws {
        let selection = DictationTextSelection(location: 4, length: 6)
        let atStart = DictationFocusSnapshot(
            processID: 42, bundleID: "com.example.Editor", focusIdentityKey: "field",
            isSecureOrBlocked: false, selection: selection)
        let target = try XCTUnwrap(DictationDeliveryTarget.captured(from: atStart),
                                   "a selection is not a reason to refuse the field")

        XCTAssertEqual(target.check(atStart), .deliverable)
        XCTAssertEqual(target.check(DictationFocusSnapshot(
            processID: 42, bundleID: "com.example.Editor", focusIdentityKey: "field",
            isSecureOrBlocked: false)), .deliverable, "a cleared selection inserts at the caret")
        XCTAssertEqual(target.check(DictationFocusSnapshot(
            processID: 42, bundleID: "com.example.Editor", focusIdentityKey: "field",
            isSecureOrBlocked: false, selection: DictationTextSelection(location: 0, length: 3))),
                       .selectionChanged)
    }

    func testSelectionMadeDuringDictationIsNotOverwritten() {
        let target = DictationDeliveryTarget(
            processID: 42, bundleID: "com.example.Editor", focusIdentityKey: "field")
        XCTAssertEqual(target.check(DictationFocusSnapshot(
            processID: 42, bundleID: "com.example.Editor", focusIdentityKey: "field",
            isSecureOrBlocked: false, selection: DictationTextSelection(location: 0, length: 3))),
                       .selectionChanged)
        XCTAssertEqual(target.check(DictationFocusSnapshot(
            processID: 7, bundleID: "com.example.Chat", focusIdentityKey: "other",
            isSecureOrBlocked: false)), .focusMoved)
        XCTAssertEqual(target.check(DictationFocusSnapshot(
            processID: 42, bundleID: "com.example.Editor", focusIdentityKey: nil,
            isSecureOrBlocked: true)), .secureField)
    }

    func testSelectionStillBlocksScreenAndNearbyContext() {
        let selected = DictationFocusSnapshot(
            processID: 42, bundleID: "com.apple.mail", focusIdentityKey: "body",
            isSecureOrBlocked: false, selection: DictationTextSelection(location: 0, length: 5))
        XCTAssertTrue(selected.blocksContextCapture)
        XCTAssertFalse(DictationScreenPrivacy.allowsCapture(
            focus: .init(snapshot: selected, timedOut: false),
            target: DictationScreenTarget(processID: 42, appName: "Mail", bundleID: "com.apple.mail")))
    }

    func testMissingTargetExplainsWhyTheTextWasCopied() {
        XCTAssertEqual(DictationCoordinator.deliveryTargetIssue(for: .timeout), .fieldUnreadable)
        XCTAssertEqual(DictationCoordinator.deliveryTargetIssue(
            for: .init(snapshot: nil, timedOut: false)), .fieldUnreadable)
        XCTAssertEqual(DictationCoordinator.deliveryTargetIssue(for: .init(
            snapshot: DictationFocusSnapshot(
                processID: 42, bundleID: nil, focusIdentityKey: nil, isSecureOrBlocked: true),
            timedOut: false)), .secureField)
        XCTAssertNil(DictationCoordinator.deliveryTargetIssue(for: .init(
            snapshot: DictationFocusSnapshot(
                processID: 42, bundleID: nil, focusIdentityKey: "field", isSecureOrBlocked: false),
            timedOut: false)))
        for check in [DictationDeliveryCheck.focusMoved, .selectionChanged, .secureField, .fieldUnreadable] {
            XCTAssertNotNil(check.clipboardMessage)
        }
    }

    func testSlowAppsGetALongerFocusDeadlineBeforePasting() async {
        let executor = DictationFocusSnapshotExecutor(deadlineMilliseconds: 20) {
            Thread.sleep(forTimeInterval: 0.1)
            return DictationFocusSnapshot(
                processID: 42, bundleID: "com.tinyspeck.slackmacgap",
                focusIdentityKey: "composer", isSecureOrBlocked: false)
        }
        let quick = await executor.capture()
        XCTAssertTrue(quick.timedOut)
        let patient = await executor.capture(
            deadlineMilliseconds: DictationCoordinator.deliveryCheckDeadlineMilliseconds)
        XCTAssertFalse(patient.timedOut)
        XCTAssertEqual(patient.snapshot?.focusIdentityKey, "composer")
    }

    /// Review finding: the retry took a fresh focus read during recording, so
    /// switching apps right after the shortcut made the second app the paste
    /// destination. The late answer must come from the shortcut's own read.
    func testSlowFocusReadStillBindsTheFieldFocusedAtTheShortcut() async {
        let focus = FocusedApp(processID: 42)
        let executor = DictationFocusSnapshotExecutor(deadlineMilliseconds: 20) {
            let processID = focus.processID
            Thread.sleep(forTimeInterval: 0.25)
            return DictationFocusSnapshot(
                processID: processID, bundleID: nil, focusIdentityKey: "field-\(processID)",
                isSecureOrBlocked: false)
        }
        let full = Task { await executor.capture(deadlineMilliseconds: 2_000) }
        let started = ContinuousClock.now
        let early = await DictationCoordinator.focusCapture(full, within: .milliseconds(60))
        XCTAssertTrue(early.timedOut)
        XCTAssertLessThan(started.duration(to: .now), .milliseconds(200), "the microphone does not wait")

        focus.processID = 7 // the person switches apps while dictation starts
        let late = await full.value
        XCTAssertEqual(late.snapshot?.processID, 42)
    }

    func testLateFocusAnswerIsRefusedForAnotherApp() {
        func capture(_ processID: pid_t, secure: Bool = false) -> DictationFocusCaptureResult {
            .init(snapshot: DictationFocusSnapshot(
                processID: processID, bundleID: nil, focusIdentityKey: "field", isSecureOrBlocked: secure),
                  timedOut: false)
        }
        let other = DictationCoordinator.lateDeliveryBinding(capture: capture(7), pressedProcessID: 42)
        XCTAssertNil(other.target)
        XCTAssertEqual(other.issue, .focusMoved)

        let same = DictationCoordinator.lateDeliveryBinding(capture: capture(42), pressedProcessID: 42)
        XCTAssertEqual(same.target?.processID, 42)
        XCTAssertNil(same.issue)

        XCTAssertEqual(DictationCoordinator.lateDeliveryBinding(
            capture: capture(42, secure: true), pressedProcessID: 42).issue, .secureField)
        XCTAssertEqual(DictationCoordinator.lateDeliveryBinding(
            capture: .timeout, pressedProcessID: 42).issue, .fieldUnreadable)
        XCTAssertNil(DictationCoordinator.lateDeliveryBinding(
            capture: capture(42), pressedProcessID: nil).target)
    }

    /// Review finding: after waiting for the paste, a cancelled dictation
    /// still completed (resetting a newer recording) and could type its
    /// fallback text.
    func testCancelledDictationNeverFinishesDeliveryAfterThePasteWait() {
        for outcome in [CotypingInserter.PasteOutcome.pasted, .unconfirmed, .failed] {
            var typed = false
            XCTAssertEqual(DictationCoordinator.pasteDeliveryResult(
                outcome, sessionIsCurrent: false, typeFallback: { typed = true; return true }),
                           .cancelled)
            XCTAssertFalse(typed, "no fallback typing for a cancelled dictation (\(outcome))")
        }
        var typed = false
        XCTAssertEqual(DictationCoordinator.pasteDeliveryResult(
            .failed, sessionIsCurrent: true, typeFallback: { typed = true; return true }), .inserted)
        XCTAssertTrue(typed)
        XCTAssertEqual(DictationCoordinator.pasteDeliveryResult(
            .pasted, sessionIsCurrent: true, typeFallback: { true }), .inserted)
        XCTAssertEqual(DictationCoordinator.pasteDeliveryResult(
            .unconfirmed, sessionIsCurrent: true, typeFallback: { true }), .unconfirmed)
    }

    /// Review finding on b323141: a paste queued behind another ran even after
    /// its dictation was cancelled, into whatever app had focus by then.
    func testQueuedPasteIsDroppedWhenItsCallerIsCancelled() async throws {
        let queue = SerialTaskQueue()
        let gate = Gate()
        var ran: [String] = []
        let first = Task { await queue.run { await gate.wait(); ran.append("first"); return 1 } }
        try await Task.sleep(for: .milliseconds(20))
        let second = Task { await queue.run { ran.append("second"); return 2 } }
        try await Task.sleep(for: .milliseconds(20))
        second.cancel()
        gate.open()
        let firstResult = await first.value
        let secondResult = await second.value
        XCTAssertEqual(firstResult, 1)
        XCTAssertNil(secondResult)
        XCTAssertEqual(ran, ["first"])
    }

    func testQueuedPasteRechecksItsDestinationOnlyAfterWaiting() async throws {
        let queue = SerialTaskQueue()
        let gate = Gate()
        var checks = 0
        let unqueued = await queue.run(stillWanted: { checks += 1; return false }) { 1 }
        XCTAssertEqual(unqueued, 1, "nothing to wait for, nothing to re-check")
        XCTAssertEqual(checks, 0)

        let first = Task { await queue.run { await gate.wait(); return 1 } }
        try await Task.sleep(for: .milliseconds(20))
        let moved = Task { await queue.run(stillWanted: { checks += 1; return false }) { 2 } }
        try await Task.sleep(for: .milliseconds(20))
        gate.open()
        _ = await first.value
        let movedResult = await moved.value
        XCTAssertNil(movedResult, "focus moved while queued: do not paste")
        XCTAssertEqual(checks, 1)

        let next = await queue.run(stillWanted: { true }) { 3 }
        XCTAssertEqual(next, 3)
    }

    func testSkippedPasteForACurrentDictationFallsBackToTheClipboard() {
        XCTAssertEqual(DictationCoordinator.pasteDeliveryResult(
            .skipped, sessionIsCurrent: true, typeFallback: { XCTFail("no typing"); return true }), .failed)
        XCTAssertEqual(DictationCoordinator.pasteDeliveryResult(
            .skipped, sessionIsCurrent: false, typeFallback: { true }), .cancelled)
    }

    /// Review finding on b323141: holding ⌃⌥ while an earlier dictation was
    /// transcribing, then pressing another key, cancelled that transcription.
    func testChordCancelsOnlyTheRecordingItStarted() {
        XCTAssertFalse(DictationCoordinator.shouldCancelShortcutStart(
            startedGeneration: nil, currentGeneration: 4, isStarting: false, isRecording: false),
            "start was refused during transcription")
        XCTAssertTrue(DictationCoordinator.shouldCancelShortcutStart(
            startedGeneration: 5, currentGeneration: 5, isStarting: false, isRecording: true))
        XCTAssertTrue(DictationCoordinator.shouldCancelShortcutStart(
            startedGeneration: 5, currentGeneration: 5, isStarting: true, isRecording: false))
        XCTAssertFalse(DictationCoordinator.shouldCancelShortcutStart(
            startedGeneration: 5, currentGeneration: 6, isStarting: false, isRecording: true),
            "a later recording is not this shortcut's")
        XCTAssertFalse(DictationCoordinator.shouldCancelShortcutStart(
            startedGeneration: 5, currentGeneration: 5, isStarting: false, isRecording: false))
    }

    // MARK: - Paste

    func testPasteIsConfirmedByTheAppReadingTheText() async throws {
        let pasteboard = NSPasteboard(name: .init("lokalbot-dictation-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let handoff = DictationPasteboardHandoff(text: "Hello from dictation")
        XCTAssertTrue(handoff.place(on: pasteboard))
        XCTAssertTrue(pasteboard.types?.contains(DictationPasteboardHandoff.transientType) ?? false,
                      "clipboard managers are told to skip the dictated text")
        handoff.armConfirmation()

        XCTAssertEqual(pasteboard.string(forType: .string), "Hello from dictation")
        let confirmed = await handoff.waitForRead(timeout: .seconds(1))
        XCTAssertTrue(confirmed)
    }

    func testReadBeforeThePasteCommandDoesNotConfirmIt() async {
        let pasteboard = NSPasteboard(name: .init("lokalbot-dictation-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let handoff = DictationPasteboardHandoff(text: "Hello from dictation")
        XCTAssertTrue(handoff.place(on: pasteboard))

        XCTAssertEqual(pasteboard.string(forType: .string), "Hello from dictation")
        handoff.armConfirmation()
        let confirmed = await handoff.waitForRead(timeout: .milliseconds(80))
        XCTAssertFalse(confirmed, "a clipboard manager's early read proves nothing")
    }

    func testUnreadPasteIsReportedInsteadOfAssumed() async {
        let pasteboard = NSPasteboard(name: .init("lokalbot-dictation-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let handoff = DictationPasteboardHandoff(text: "Nobody reads this")
        XCTAssertTrue(handoff.place(on: pasteboard))
        handoff.armConfirmation()
        let read = await handoff.waitForRead(timeout: .milliseconds(80))
        XCTAssertFalse(read)
    }

    func testRestoredClipboardIsMarkedAndPasswordsAreNotRestored() throws {
        let plain: [NSPasteboard.PasteboardType: Data] = [.string: Data("notes".utf8)]
        let items = try XCTUnwrap(CotypingInserter.restoredItems([plain]))
        XCTAssertEqual(items.first?.string(forType: .string), "notes")
        XCTAssertTrue(items.first?.types.contains(DictationPasteboardHandoff.autoGeneratedType) ?? false)

        let password: [NSPasteboard.PasteboardType: Data] = [
            .string: Data("hunter2".utf8),
            DictationPasteboardHandoff.concealedType: Data(),
        ]
        XCTAssertNil(CotypingInserter.restoredItems([password]))
        XCTAssertNil(CotypingInserter.restoredItems([]))
    }

    func testTypingFallbackSendsShortChunksWithoutSplittingCharacters() {
        let text = "Dictation fallback text that is clearly longer than twenty units 👩‍👩‍👧‍👦 done."
        let chunks = CotypingInserter.typingChunks(text)
        XCTAssertEqual(chunks.joined(), text)
        XCTAssertGreaterThan(chunks.count, 3)
        for chunk in chunks where chunk.count > 1 {
            XCTAssertLessThanOrEqual(chunk.utf16.count, 20)
        }
        XCTAssertTrue(chunks.contains { $0.contains("👩‍👩‍👧‍👦") })
        XCTAssertEqual(CotypingInserter.typingChunks(""), [])
    }

    // MARK: - Speech recognition

    func testSingleWindowIsNotDecodedAgainInItsOwnLanguage() {
        let one = ["Please send the updated contract to the legal team before Friday."]
        XCTAssertNil(QwenASREngine.pinnedLanguage(for: one))
        let two = one + ["We can review the remaining comments together on Monday morning."]
        XCTAssertEqual(QwenASREngine.pinnedLanguage(for: two), "en")
    }

    func testVocabularyOnlyDictationIsDecodedAgainWithoutTheHint() {
        let empty = Transcript(segments: [], engine: "test")
        XCTAssertTrue(DictationCoordinator.shouldRetryWithoutVocabulary(
            transcript: empty, prompt: "Mila Novak, Orion Launch", speechSeconds: 1.6))
        XCTAssertFalse(DictationCoordinator.shouldRetryWithoutVocabulary(
            transcript: empty, prompt: nil, speechSeconds: 1.6))
        XCTAssertFalse(DictationCoordinator.shouldRetryWithoutVocabulary(
            transcript: empty, prompt: "Mila Novak", speechSeconds: 0.6),
            "a near-silent dictation stays empty")
        let spoken = Transcript(segments: [.init(
            start: 0, end: 1.5, speaker: "me", text: "Mila Novak", confidence: nil)], engine: "test")
        XCTAssertFalse(DictationCoordinator.shouldRetryWithoutVocabulary(
            transcript: spoken, prompt: "Mila Novak", speechSeconds: 1.6))
    }

    // MARK: - Helpers

    private static func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("dictation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static func waitUntil(
        timeout: TimeInterval,
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { throw WaitTimedOut(seconds: timeout) }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private static func sampleBuffer(from buffer: AVAudioPCMBuffer) throws -> CMSampleBuffer {
        var description: CMAudioFormatDescription?
        XCTAssertEqual(CMAudioFormatDescriptionCreate(
            allocator: nil, asbd: buffer.format.streamDescription, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil,
            formatDescriptionOut: &description), noErr)
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(buffer.format.sampleRate)),
            presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreate(
            allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil,
            refcon: nil, formatDescription: description, sampleCount: CMItemCount(buffer.frameLength),
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0,
            sampleSizeArray: nil, sampleBufferOut: &sampleBuffer), noErr)
        let result = try XCTUnwrap(sampleBuffer)
        XCTAssertEqual(CMSampleBufferSetDataBufferFromAudioBufferList(
            result, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0,
            bufferList: buffer.audioBufferList), noErr)
        return result
    }
}

/// Holds an operation open until the test releases it.
@MainActor
private final class Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

private final class FocusedApp: @unchecked Sendable {
    private let lock = NSLock()
    private var value: pid_t

    init(processID: pid_t) {
        value = processID
    }

    var processID: pid_t {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

private struct WaitTimedOut: Error {
    let seconds: TimeInterval
}

/// Inputs that start successfully and stop when told to, like a Bluetooth
/// microphone that drops each time it switches profile.
private final class ScriptedInputs: @unchecked Sendable {
    private(set) var made = 0
    private(set) var current: ScriptedInput?

    func make() -> MicrophoneInput {
        made += 1
        let input = ScriptedInput()
        current = input
        return input
    }
}

private final class ScriptedInput: MicrophoneInput {
    let inputFormat = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
    var running = false
    var isRunning: Bool { running }
    func installTap(bufferSize: AVAudioFrameCount, block: @escaping AVAudioNodeTapBlock) {}
    func removeTap() {}
    func start() throws { running = true }
    func stop() { running = false }
}
