import SwiftUI

public enum WorkspaceMotionKind: Sendable {
    case selection
    case disclosure
    case drawer
    case tabs
    case autoScroll
    /// Rare moments: paired with a Mac, the first sync done.
    case milestone
}

/// The Mac's motion policy, with durations from tokens.json. Everything is off
/// under Reduce Motion.
public enum WorkspaceMotion {
    public static func animation(_ kind: WorkspaceMotionKind, reduceMotion: Bool) -> Animation? {
        guard !reduceMotion else { return nil }
        switch kind {
        case .selection: return .easeOut(duration: LBTokens.Motion.selection)
        case .disclosure: return .easeInOut(duration: LBTokens.Motion.disclosure)
        case .drawer: return .easeOut(duration: LBTokens.Motion.drawer)
        case .tabs: return .snappy(duration: LBTokens.Motion.tabs)
        case .autoScroll: return .easeOut(duration: 0.15)
        case .milestone: return .snappy(duration: LBTokens.Motion.milestone)
        }
    }
}

extension View {
    /// Animates `value` changes with a motion kind, or not at all under Reduce Motion.
    public func workspaceAnimation<V: Equatable>(_ kind: WorkspaceMotionKind, value: V) -> some View {
        modifier(WorkspaceAnimationModifier(kind: kind, value: value))
    }
}

private struct WorkspaceAnimationModifier<V: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let kind: WorkspaceMotionKind
    let value: V

    func body(content: Content) -> some View {
        content.animation(WorkspaceMotion.animation(kind, reduceMotion: reduceMotion), value: value)
    }
}
