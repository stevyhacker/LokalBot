import XCTest
@testable import LokalBot

/// The dictation HUD's model-preparation visibility policy. Preparation
/// begins synchronously on every recording start, so `.recording` must stay
/// quiet until real download progress (or a failure) exists — a warm model
/// never flashes the panel — while `.transcribing` keeps the historical
/// behavior of showing any status at all.
@MainActor
final class DictationModelPreparationVisibilityTests: XCTestCase {

    func testRecordingShowsPreparationOnlyOnceProgressOrErrorExists() {
        let recording = DictationCoordinator.State.recording(startedAt: Date())
        XCTAssertFalse(DictationCoordinator.shouldShowModelPreparation(
            state: recording, hasStatus: true, hasProgress: false, hasError: false),
            "the synchronous 'Checking…' status must not flash the HUD on a warm start")
        XCTAssertTrue(DictationCoordinator.shouldShowModelPreparation(
            state: recording, hasStatus: true, hasProgress: true, hasError: false),
            "a live download during recording must be visible")
        XCTAssertTrue(DictationCoordinator.shouldShowModelPreparation(
            state: recording, hasStatus: false, hasProgress: false, hasError: true),
            "a preparation failure during recording must be visible")
    }

    func testTranscribingShowsAnyStatusOrError() {
        let transcribing = DictationCoordinator.State.transcribing(startedAt: Date())
        XCTAssertTrue(DictationCoordinator.shouldShowModelPreparation(
            state: transcribing, hasStatus: true, hasProgress: false, hasError: false))
        XCTAssertTrue(DictationCoordinator.shouldShowModelPreparation(
            state: transcribing, hasStatus: false, hasProgress: false, hasError: true))
        XCTAssertFalse(DictationCoordinator.shouldShowModelPreparation(
            state: transcribing, hasStatus: false, hasProgress: false, hasError: false))
    }

    func testIdleAndComposingNeverShowPreparation() {
        for state in [DictationCoordinator.State.idle,
                      .composing(startedAt: Date())] {
            XCTAssertFalse(DictationCoordinator.shouldShowModelPreparation(
                state: state, hasStatus: true, hasProgress: true, hasError: true))
        }
    }
}
