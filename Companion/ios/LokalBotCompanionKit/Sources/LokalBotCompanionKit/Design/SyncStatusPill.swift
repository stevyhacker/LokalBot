import SwiftUI

/// What the phone knows about its copy, for the status pill and Settings.
public enum SyncPresentation: Equatable, Sendable {
    case sample
    case notPaired
    case neverSynced
    case syncing(lastSync: Date?)
    case synced(at: Date, route: NetworkRoute?)
    case unreachable(lastSync: Date?)
    case failed(message: String, lastSync: Date?)

    public var isAttention: Bool {
        switch self {
        case .unreachable, .failed: true
        default: false
        }
    }
}

/// "Synced with your Mac · 2 min ago · Wi-Fi". Teal while fresh, amber when
/// the Mac couldn't be reached.
public struct SyncStatusPill: View {
    let state: SyncPresentation
    var format: LBFormat
    /// Pins "now" for the sample library, previews and screenshots.
    var pinnedNow: Date?

    public init(state: SyncPresentation, format: LBFormat = .current, pinnedNow: Date? = nil) {
        self.state = state
        self.format = format
        self.pinnedNow = pinnedNow
    }

    public var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            content(now: pinnedNow ?? context.date)
        }
    }

    private func content(now: Date) -> some View {
        let tint = state.isAttention ? LBTokens.Palette.attentionText : Brand.teal
        return HStack(spacing: 6) {
            switch state {
            case .syncing:
                ProgressView().controlSize(.mini).tint(tint)
            case .sample, .notPaired:
                Image(systemName: "shippingbox").imageScale(.small)
            default:
                StatusDot(color: state.isAttention ? Brand.amber : LBTokens.Palette.accentFill, size: 7)
            }
            Text(text(now: now))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(LBTokens.Typography.caption.weight(.medium))
        .foregroundStyle(tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(state.isAttention ? LBTokens.Palette.attentionWash : LBTokens.Palette.accentWash, in: Capsule())
        .accessibilityElement(children: .combine)
    }

    nonisolated public func text(now: Date) -> String {
        switch state {
        case .sample:
            return "Sample library · not connected to a Mac"
        case .notPaired:
            return "Not paired with a Mac"
        case .neverSynced:
            return "Waiting for the first sync with your Mac"
        case .syncing:
            return "Syncing with your Mac…"
        case .synced(let at, let route):
            return (["Synced with your Mac", format.ago(at, now: now)] + [route?.label].compactMap { $0 })
                .joined(separator: " · ")
        case .unreachable(let lastSync):
            return "Mac not reachable" + (lastSync.map { " · last synced \(format.ago($0, now: now))" } ?? "")
        case .failed(let message, _):
            return message
        }
    }
}
