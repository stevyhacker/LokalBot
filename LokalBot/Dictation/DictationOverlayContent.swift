import AppKit

/// Everything the dictation HUD draws, copied from the coordinator. The panel
/// and its SwiftUI content both size themselves from this one value, so they
/// cannot disagree, and a closing HUD fades out showing what it last showed
/// instead of an empty idle capsule.
struct DictationOverlayContent: Equatable {
    enum Activity: Hashable {
        /// Starting or recording. The two look the same: a grey dot and flat
        /// bars until the microphone delivers audio, so the HUD does not
        /// change shape when recording begins.
        case listening
        case transcribing
        case composing
    }

    enum Kind: Equatable {
        case pill(Activity)
        case transcript(Activity)
        case preparation(ModelPreparationPresentation, canRetry: Bool)
        case notice(DictationDeliveryNotice)
    }

    /// The HUD's shapes. Widths and margins are even, so the panel and the
    /// capsule stay on whole points when centered on the screen.
    enum Layout: Equatable, CaseIterable {
        case pill
        /// A pill wide enough for a microphone status such as "Reconnecting".
        case statusPill
        case transcript
        case preparation
        case notice

        var size: CGSize {
            switch self {
            case .pill: CGSize(width: 176, height: 38)
            case .statusPill: CGSize(width: 316, height: 38)
            case .transcript: CGSize(width: 540, height: 172)
            case .preparation: CGSize(width: 380, height: 76)
            case .notice: CGSize(width: 384, height: 38)
            }
        }

        /// One radius for every shape, so a pill growing into the transcript
        /// panel reads as the same surface changing size. The same radius as
        /// the app's other floating surface, the composer.
        static let cornerRadius: CGFloat = LBTokens.Metric.composerRadius

        static let largestSize = CGSize(
            width: allCases.map(\.size.width).max() ?? 0,
            height: allCases.map(\.size.height).max() ?? 0)
    }

    var kind: Kind
    var microphoneLive = false
    var captureStatus = ""
    var timer = ""
    var transcript = DictationLiveTranscript()

    var layout: Layout {
        switch kind {
        case .pill(.listening): captureStatus.isEmpty ? .pill : .statusPill
        case .pill: .pill
        case .transcript: .transcript
        case .preparation: .preparation
        case .notice: .notice
        }
    }

    var activity: Activity? {
        switch kind {
        case .pill(let activity), .transcript(let activity): activity
        case .preparation, .notice: nil
        }
    }

    /// What the HUD shows for a coordinator state, or nil when it shows
    /// nothing. Starting counts as listening, so the first frame already has
    /// the shape recording will keep.
    static func make(
        isStarting: Bool,
        state: DictationCoordinator.State,
        showsLiveTranscript: Bool,
        showsModelPreparation: Bool,
        preparation: ModelPreparationPresentation,
        preparationFailed: Bool,
        notice: DictationDeliveryNotice?,
        microphoneLive: Bool,
        captureStatus: String,
        timer: String,
        transcript: DictationLiveTranscript
    ) -> DictationOverlayContent? {
        let kind: Kind
        if showsModelPreparation {
            kind = .preparation(preparation, canRetry: preparationFailed)
        } else if isStarting || state.isWorking {
            let activity: Activity
            switch state {
            case .idle, .recording: activity = .listening
            case .transcribing: activity = .transcribing
            case .composing: activity = .composing
            }
            kind = showsLiveTranscript ? .transcript(activity) : .pill(activity)
        } else if let notice {
            kind = .notice(notice)
        } else {
            return nil
        }
        let listening = isStarting || state.isRecording
        return DictationOverlayContent(
            kind: kind,
            microphoneLive: listening && microphoneLive,
            captureStatus: listening ? captureStatus : "",
            timer: timer,
            transcript: showsLiveTranscript ? transcript : DictationLiveTranscript())
    }
}

extension DictationOverlayContent {
    @MainActor
    init?(_ dictation: DictationCoordinator) {
        guard let content = Self.make(
            isStarting: dictation.isStarting,
            state: dictation.state,
            showsLiveTranscript: dictation.shouldShowLiveTranscriptPanel,
            showsModelPreparation: dictation.shouldShowModelPreparation,
            preparation: dictation.modelPreparationPresentation,
            preparationFailed: dictation.modelPreparationError != nil,
            notice: dictation.deliveryNotice,
            microphoneLive: dictation.hasMicrophoneAudio,
            captureStatus: dictation.captureStatus,
            timer: dictation.timerLabel,
            transcript: dictation.liveTranscript)
        else { return nil }
        self = content
    }
}

/// Where the HUD panel sits. The SwiftUI canvas has one fixed size and never
/// moves on screen; the panel is only a window onto its bottom-center, so
/// resizing the panel cannot shift what is drawn.
enum DictationOverlayGeometry {
    /// Transparent room around the capsule for its shadow.
    static let margins = NSEdgeInsets(top: 14, left: 20, bottom: 26, right: 20)
    /// The capsule's bottom edge above the bottom of the visible screen area.
    static let bottomOffset: CGFloat = 48

    static var canvasSize: CGSize {
        let largest = DictationOverlayContent.Layout.largestSize
        return CGSize(
            width: largest.width + margins.left + margins.right,
            height: largest.height + margins.top + margins.bottom)
    }

    /// The capsule's bottom-center point on screen.
    static func anchor(in visibleFrame: NSRect) -> CGPoint {
        CGPoint(x: visibleFrame.midX.rounded(), y: (visibleFrame.minY + bottomOffset).rounded())
    }

    /// A panel that shows a capsule of `contentSize` with room for its shadow.
    static func panelFrame(contentSize: CGSize, anchor: CGPoint) -> NSRect {
        let width = contentSize.width + margins.left + margins.right
        let height = contentSize.height + margins.top + margins.bottom
        return NSRect(x: anchor.x - width / 2, y: anchor.y - margins.bottom, width: width, height: height)
    }

    /// The canvas's origin inside a panel of `panelSize`, which keeps the
    /// canvas at the same place on screen whatever the panel's size.
    static func canvasOrigin(inPanelOfSize panelSize: CGSize) -> CGPoint {
        CGPoint(x: (panelSize.width - canvasSize.width) / 2, y: 0)
    }
}
