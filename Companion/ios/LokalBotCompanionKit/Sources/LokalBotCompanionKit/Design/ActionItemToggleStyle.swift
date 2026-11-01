import SwiftUI

/// The round, Reminders-like toggle used for action items everywhere they
/// appear. Done is a filled teal check; open is an empty circle.
public struct ActionItemToggleStyle: ToggleStyle {
    var pending: Bool

    public init(pending: Bool = false) { self.pending = pending }

    public func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            ActionCheck(isDone: configuration.isOn, pending: pending) { configuration.isOn.toggle() }
            configuration.label
        }
    }
}

extension ToggleStyle where Self == ActionItemToggleStyle {
    public static var actionItem: ActionItemToggleStyle { .init() }
    public static func actionItem(pending: Bool) -> ActionItemToggleStyle { .init(pending: pending) }
}

/// The circle itself, with a 44 pt target. A change waiting for the Mac
/// shows an amber ring.
public struct ActionCheck: View {
    let isDone: Bool
    let pending: Bool
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 22

    public init(isDone: Bool, pending: Bool = false, action: @escaping () -> Void) {
        self.isDone = isDone
        self.pending = pending
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                .font(.system(size: size, weight: .regular))
                .foregroundStyle(isDone ? AnyShapeStyle(Brand.teal) : AnyShapeStyle(LBTokens.Palette.supporting.opacity(0.8)))
                .contentTransition(.symbolEffect(.replace))
                .overlay {
                    if pending {
                        Circle()
                            .strokeBorder(Brand.amber, style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
                            .padding(-4)
                    }
                }
                .workspaceAnimation(.selection, value: isDone)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .lbHoverEffect()
        .accessibilityLabel(isDone ? "Mark as open" : "Mark as done")
        .accessibilityValue(pending ? "Waiting for your Mac" : "")
    }
}
