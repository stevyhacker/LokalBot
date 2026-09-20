import AppKit
import SwiftUI

/// SwiftUI Text does not expose hanging indents or paragraph spacing. One
/// non-editable NSTextView gives Agent answers those metrics and a continuous
/// selection range. SwiftUI still owns content, width, search, and link routing.
struct AgentResponseText: NSViewRepresentable {
    @Environment(\.openURL) private var openURL
    @Environment(\.colorScheme) private var colorScheme
    let text: String
    let fontSize: CGFloat
    let searchQuery: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSTextView {
        let view = NSTextView(frame: .zero)
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = true
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.delegate = context.coordinator
        view.setAccessibilityIdentifier("agent.assistant")
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {
        context.coordinator.openLink = { openURL($0) }
        view.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        let key = RenderKey(text: text, size: fontSize, query: searchQuery)
        guard context.coordinator.key != key else { return }
        context.coordinator.key = key
        let selection = view.selectedRanges
        let value = AgentResponseDocument.render(text, fontSize: fontSize, searchQuery: searchQuery)
        view.textStorage?.setAttributedString(value)
        view.selectedRanges = selection.filter { NSMaxRange($0.rangeValue) <= value.length }
        view.invalidateIntrinsicContentSize()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: NSTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0,
              let container = view.textContainer, let layout = view.layoutManager else { return nil }
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        return CGSize(width: width, height: ceil(layout.usedRect(for: container).height))
    }

    struct RenderKey: Equatable {
        let text: String
        let size: CGFloat
        let query: String
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var key: RenderKey?
        var openLink: ((URL) -> Void)?

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
            if let url { openLink?(url) }
            // All links pass through the session's existing source/file policy.
            return true
        }
    }
}

enum AgentResponseDocument {
    static func render(_ markdown: String, fontSize: CGFloat, searchQuery: String = "") -> NSAttributedString {
        let lines = SelectableDigestText.renderedLines(from: markdown, font: .system(size: fontSize), style: .agent)
        let document = NSMutableAttributedString()
        for (index, line) in lines.enumerated() {
            let kind = sectionKind(line)
            let font = baseFont(for: kind, size: fontSize)
            let paragraph = paragraphStyle(for: kind, font: font, isFirst: index == 0)
            let content = NSMutableAttributedString()
            for run in line.content.runs {
                let intent = run.inlinePresentationIntent ?? []
                var runFont = intent.contains(.code) ? NSFont.monospacedSystemFont(ofSize: fontSize - 1, weight: .regular) : font
                if intent.contains(.stronglyEmphasized) { runFont = NSFontManager.shared.convert(runFont, toHaveTrait: .boldFontMask) }
                if intent.contains(.emphasized) { runFont = NSFontManager.shared.convert(runFont, toHaveTrait: .italicFontMask) }
                var attributes: [NSAttributedString.Key: Any] = [
                    .font: runFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph
                ]
                if intent.contains(.code) || isCode(kind) { attributes[.backgroundColor] = NSColor.labelColor.withAlphaComponent(0.06) }
                if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                if let link = run.link { attributes[.link] = link; attributes[.foregroundColor] = NSColor.linkColor }
                if case .quote = kind { attributes[.foregroundColor] = NSColor.secondaryLabelColor }
                if case .separator = kind { attributes[.foregroundColor] = NSColor.separatorColor }
                content.append(NSAttributedString(string: String(line.content[run.range].characters), attributes: attributes))
            }
            if index < lines.count - 1 {
                content.append(NSAttributedString(string: "\n", attributes: [.font: font, .paragraphStyle: paragraph]))
            }
            document.append(content)
        }
        for range in MeetingPageSearch.ranges(in: document.string, query: searchQuery) {
            document.addAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.35),
                                  range: NSRange(range, in: document.string))
        }
        return document
    }

    /// Models often emit a standalone bold section label instead of ##. Treat
    /// only short, wholly emphasized paragraphs as headings; inline emphasis
    /// in prose retains the body size.
    private static func sectionKind(_ line: SelectableDigestText.RenderedLine) -> SelectableDigestText.LineKind {
        guard case .body = line.kind else { return line.kind }
        let visible = line.content.characters
        guard !visible.isEmpty, visible.count <= 100,
              line.content.runs.allSatisfy({ $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true }) else { return .body }
        return .heading(2)
    }

    private static func isCode(_ kind: SelectableDigestText.LineKind) -> Bool {
        if case .code = kind { return true }
        return false
    }

    private static func baseFont(for kind: SelectableDigestText.LineKind, size: CGFloat) -> NSFont {
        switch kind {
        case .heading(let level): return .systemFont(ofSize: size + (level == 1 ? 5 : level == 2 ? 3 : 1), weight: .semibold)
        case .tableHeader: return .monospacedSystemFont(ofSize: size - 1, weight: .semibold)
        case .code, .table: return .monospacedSystemFont(ofSize: size - 1, weight: .regular)
        default: return .systemFont(ofSize: size, weight: .regular)
        }
    }

    private static func paragraphStyle(for kind: SelectableDigestText.LineKind, font: NSFont, isFirst: Bool) -> NSParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        paragraph.paragraphSpacing = 4
        switch kind {
        case .heading:
            paragraph.paragraphSpacingBefore = isFirst ? 0 : 12
            paragraph.paragraphSpacing = 7
        case .list(let prefix):
            paragraph.headIndent = (prefix as NSString).size(withAttributes: [.font: font]).width
            paragraph.paragraphSpacing = 5
        case .blank:
            paragraph.minimumLineHeight = 6
            paragraph.maximumLineHeight = 6
            paragraph.lineSpacing = 0
            paragraph.paragraphSpacing = 0
        case .code, .table, .tableHeader:
            paragraph.lineSpacing = 2
            paragraph.paragraphSpacing = 0
        case .quote:
            paragraph.headIndent = 14
        default: break
        }
        return paragraph
    }
}
