import AppKit

struct DictationOverlayContent: Equatable {
    enum Activity: Hashable {
        case listening
        case transcribing
        case composing
    }

    enum Kind: Equatable {
        case pill(Activity)
        case transcript(Activity)
        case preparation(ModelPreparationPresentation, canRetry: Bool)
        case notice(DictationDeliveryNotice)
        case problem(DictationProblemNotice)
    }

    enum Layout: Equatable, CaseIterable {
        case pill
        case statusPill
        case transcript
        case preparation
        case notice
        case problem

        var size: CGSize {
            switch self {
            case .pill: CGSize(width: 176, height: 38)
            case .statusPill: CGSize(width: 316, height: 38)
            case .transcript: CGSize(width: 540, height: 172)
            case .preparation: CGSize(width: 380, height: 76)
            case .notice: CGSize(width: 384, height: 38)
            case .problem: CGSize(width: 384, height: 84)
            }
        }

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
        case .problem(let problem): problem.detail == nil ? .notice : .problem
        }
    }

    var activity: Activity? {
        switch kind {
        case .pill(let activity), .transcript(let activity): activity
        case .preparation, .notice, .problem: nil
        }
    }

    static func make(
        isStarting: Bool,
        state: DictationCoordinator.State,
        showsLiveTranscript: Bool,
        showsModelPreparation: Bool,
        preparation: ModelPreparationPresentation,
        preparationFailed: Bool,
        notice: DictationDeliveryNotice?,
        problem: DictationProblemNotice?,
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
        } else if let problem {
            kind = .problem(problem)
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
            problem: dictation.problemNotice,
            microphoneLive: dictation.hasMicrophoneAudio,
            captureStatus: dictation.captureStatus,
            timer: dictation.timerLabel,
            transcript: dictation.liveTranscript)
        else { return nil }
        self = content
    }
}

enum DictationOverlayGeometry {
    static let margins = NSEdgeInsets(top: 14, left: 20, bottom: 26, right: 20)
    static let bottomOffset: CGFloat = 48

    static var canvasSize: CGSize {
        let largest = DictationOverlayContent.Layout.largestSize
        return CGSize(
            width: largest.width + margins.left + margins.right,
            height: largest.height + margins.top + margins.bottom)
    }

    static func anchor(in visibleFrame: NSRect) -> CGPoint {
        CGPoint(x: visibleFrame.midX.rounded(), y: (visibleFrame.minY + bottomOffset).rounded())
    }

    static func panelFrame(contentSize: CGSize, anchor: CGPoint) -> NSRect {
        let width = contentSize.width + margins.left + margins.right
        let height = contentSize.height + margins.top + margins.bottom
        return NSRect(x: anchor.x - width / 2, y: anchor.y - margins.bottom, width: width, height: height)
    }

    static func canvasOrigin(inPanelOfSize panelSize: CGSize) -> CGPoint {
        CGPoint(x: (panelSize.width - canvasSize.width) / 2, y: 0)
    }
}
