import AppKit
import SwiftUI

/// A compact native control for transcript speaker labels. AppKit owns the hit
/// testing and accessibility role while the attributed title preserves meeting
/// find highlighting. This avoids SwiftUI flattening a plain button inside the
/// nested meeting ScrollView on macOS 15.
struct TranscriptSpeakerButton: NSViewRepresentable {
    let title: String
    let query: String
    let activeMatchIndex: Int?
    let identifier: String
    let action: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(
            title: title,
            target: context.coordinator,
            action: #selector(Coordinator.invoke))
        button.setButtonType(.momentaryPushIn)
        button.isBordered = false
        button.alignment = .left
        button.controlSize = .small
        button.focusRingType = .exterior
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.cell?.lineBreakMode = .byTruncatingTail
        button.cell?.usesSingleLineMode = true
        button.identifier = NSUserInterfaceItemIdentifier(identifier)
        button.setAccessibilityIdentifier(identifier)
        update(button, coordinator: context.coordinator)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
        update(button, coordinator: context.coordinator)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSButton, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? nsView.intrinsicContentSize.width,
               height: proposal.height ?? nsView.intrinsicContentSize.height)
    }

    private func update(_ button: NSButton, coordinator: Coordinator) {
        let presentation = Presentation(title: title, query: query, activeMatchIndex: activeMatchIndex)
        guard coordinator.presentation != presentation else { return }
        coordinator.presentation = presentation
        button.attributedTitle = Self.attributedTitle(
            title,
            query: query,
            activeMatchIndex: activeMatchIndex)
        button.setAccessibilityLabel(title)
        button.toolTip = "Rename speaker: \(title)"
    }

    private static func attributedTitle(
        _ title: String,
        query: String,
        activeMatchIndex: Int?
    ) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let result = NSMutableAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(
                    ofSize: NSFont.smallSystemFontSize,
                    weight: .bold),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph,
            ])
        for (index, range) in MeetingPageSearch.ranges(
            in: title,
            query: query).enumerated() {
            result.addAttribute(
                .backgroundColor,
                value: index == activeMatchIndex
                    ? NSColor.systemOrange.withAlphaComponent(0.58)
                    : NSColor.systemYellow.withAlphaComponent(0.34),
                range: NSRange(range, in: title))
        }
        return result
    }

    fileprivate struct Presentation: Equatable {
        let title: String
        let query: String
        let activeMatchIndex: Int?
    }

    final class Coordinator: NSObject {
        var action: () -> Void
        fileprivate var presentation: Presentation?

        init(action: @escaping () -> Void) {
            self.action = action
        }

        @objc func invoke() {
            uiTestDiagnosticLog("transcript.speaker native button invoke")
            action()
        }
    }
}
