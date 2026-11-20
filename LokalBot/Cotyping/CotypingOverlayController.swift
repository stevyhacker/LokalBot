import AppKit

@MainActor
final class CotypingOverlayController {
    private var panel: CotypingOverlayPanel?
    private var ghostView: CotypingGhostTextView?
    private(set) var isVisible = false
    private(set) var acceptanceText: String?
    private let sampler = CotypingBackgroundSampler()
    private var sampleGeneration = 0
    private var samplingInFlight = false
    private var inline: InlineState?

    private struct InlineState {
        var text: String
        var layout: CotypingInlineGhostLayout
        var caretRect: CGRect
        var inputFrameRect: CGRect?
        var precedingLine: String
        var linesBelowAreFree: Bool
        var visible: CGRect?
        var style: CotypingFieldStyle?
        var emphasisLength: Int
        var luminance: CGFloat?
    }

    private static let inlinePadding: CGFloat = 2
    private static let chromePadding = CGSize(width: 8, height: 4)
    private static let mirrorPointSizes: ClosedRange<CGFloat> = 11...17

    var isShowingInline: Bool { isVisible && inline != nil }

    func show(
        text: String,
        caretRect: CGRect,
        inputFrameRect: CGRect? = nil,
        style: CotypingFieldStyle? = nil,
        placement: CotypingOverlayPlacement = .inlineDefault,
        acceptanceText: String? = nil,
        mayShowPart: Bool = true,
        isRightToLeft: Bool = false,
        precedingText: String = "",
        trailingText: String = "",
        emphasisLength: Int? = nil,
        backgroundKey: String? = nil
    ) {
        guard !text.isEmpty,
              caretRect.origin.x.isFinite, caretRect.origin.y.isFinite,
              caretRect.width.isFinite, caretRect.height.isFinite else {
            hide()
            return
        }
        let font = CotypingGhostFontSizing.font(
            for: style, caretHeight: caretRect.height, caretIsExact: placement.caretIsExact)
        let visible = screenVisibleFrame(containing: caretRect)
        let emphasis = emphasisLength ?? text.count
        sampleGeneration += 1
        switch placement.mode {
        case .inline:
            let precedingLine = Self.lastParagraph(of: precedingText)
            let linesBelowAreFree = Self.linesBelowAreFree(trailingText: trailingText)
            guard let fitted = CotypingInlineGhostLayout.longestDrawable(
                text, allowsPartial: mayShowPart && acceptanceText == nil, layout: { candidate in
                    .make(
                        text: candidate, font: font, caretRect: caretRect, inputFrameRect: inputFrameRect,
                        precedingLine: precedingLine, visible: visible, isRightToLeft: isRightToLeft,
                        linesBelowAreFree: linesBelowAreFree)
                }) else {
                hide()
                return
            }
            let state = InlineState(
                text: fitted.text, layout: fitted.layout,
                caretRect: caretRect, inputFrameRect: inputFrameRect, precedingLine: precedingLine,
                linesBelowAreFree: linesBelowAreFree, visible: visible, style: style, emphasisLength: emphasis,
                luminance: sampler.cachedLuminance(forField: backgroundKey))
            guard presentInline(state) else {
                hide()
                return
            }
            if state.luminance == nil { sampleBackground(behind: caretRect, forField: backgroundKey) }
            self.acceptanceText = acceptanceText ?? fitted.text
        case .mirror:
            inline = nil
            guard presentMirror(
                text: text, font: font, caretRect: caretRect, caretIsExact: placement.caretIsExact,
                inputFrameRect: inputFrameRect, visible: visible,
                emphasisLength: emphasis, isRightToLeft: isRightToLeft) else {
                hide()
                return
            }
            self.acceptanceText = acceptanceText ?? text
        case .withheld:
            hide()
        }
    }

    @discardableResult
    func advanceInline(
        to remainingText: String,
        insertedText: String,
        isRightToLeft: Bool = false,
        emphasisLength: Int? = nil
    ) -> Bool {
        guard isVisible,
              var state = inline,
              state.layout.isRightToLeft == isRightToLeft,
              !remainingText.isEmpty,
              !insertedText.isEmpty,
              state.text.hasPrefix(insertedText),
              String(state.text.dropFirst(insertedText.count)) == remainingText,
              let caret = CotypingInlineGhostLayout.caretRect(
                  afterTyping: insertedText, font: state.layout.font,
                  caretRect: state.caretRect, inputFrameRect: state.inputFrameRect,
                  precedingLine: state.precedingLine, visible: state.visible, isRightToLeft: isRightToLeft,
                  linesBelowAreFree: state.linesBelowAreFree, wrapEdge: state.layout.wrapEdge) else {
            return false
        }
        state.caretRect = caret
        state.precedingLine += insertedText
        state.text = remainingText
        state.emphasisLength = emphasisLength ?? remainingText.count
        state.layout = relayout(state)
        guard state.layout.isComplete, !state.layout.lines.isEmpty else { return false }
        return presentInline(state)
    }

    @discardableResult
    func extendInline(to text: String, emphasisLength: Int? = nil) -> Bool {
        guard isVisible,
              var state = inline,
              text.count > state.text.count,
              text.hasPrefix(state.text),
              let fitted = CotypingInlineGhostLayout.longestDrawable(
                  text, allowsPartial: true, layout: { relayout(state, text: $0) }),
              fitted.text.count >= state.text.count else {
            return false
        }
        state.text = fitted.text
        state.layout = fitted.layout
        state.emphasisLength = emphasisLength ?? state.emphasisLength
        return presentInline(state)
    }

    func shouldHoldInlineReanchor(
        text: String,
        caretRect: CGRect,
        style: CotypingFieldStyle?,
        placement: CotypingOverlayPlacement,
        millisecondsSinceLastAcceptance: Int?,
        inputFrameRect: CGRect? = nil,
        isRightToLeft: Bool = false,
        precedingText: String = "",
        trailingText: String = ""
    ) -> Bool {
        guard isVisible,
              placement.mode == .inline,
              let state = inline,
              state.text == text,
              let current = state.layout.lines.first else {
            return false
        }
        let font = CotypingGhostFontSizing.font(
            for: style ?? state.style, caretHeight: caretRect.height, caretIsExact: placement.caretIsExact)
        let target = CotypingInlineGhostLayout.make(
            text: text, font: font, caretRect: caretRect, inputFrameRect: inputFrameRect,
            precedingLine: Self.lastParagraph(of: precedingText),
            visible: screenVisibleFrame(containing: caretRect), isRightToLeft: isRightToLeft,
            linesBelowAreFree: Self.linesBelowAreFree(trailingText: trailingText))
        guard target.isComplete, let targetLine = target.lines.first else { return false }
        return CotypingOverlayGeometry.shouldHoldInlineReanchor(
            currentFrame: CGRect(origin: current.origin, size: .zero),
            targetFrame: CGRect(origin: targetLine.origin, size: .zero),
            millisecondsSinceLastAcceptance: millisecondsSinceLastAcceptance,
            isRightToLeft: isRightToLeft)
    }

    func hide() {
        panel?.orderOut(nil)
        isVisible = false
        acceptanceText = nil
        inline = nil
        sampleGeneration += 1
    }

    private func relayout(_ state: InlineState, text: String? = nil) -> CotypingInlineGhostLayout {
        .make(
            text: text ?? state.text, font: state.layout.font, caretRect: state.caretRect,
            inputFrameRect: state.inputFrameRect, precedingLine: state.precedingLine,
            visible: state.visible, isRightToLeft: state.layout.isRightToLeft,
            linesBelowAreFree: state.linesBelowAreFree, wrapEdge: state.layout.wrapEdge)
    }

    private nonisolated static func lastParagraph(of precedingText: String) -> String {
        String(precedingText.split(separator: "\n", omittingEmptySubsequences: false).last ?? "")
    }

    nonisolated static func linesBelowAreFree(trailingText: String) -> Bool {
        !trailingText.contains { !$0.isWhitespace }
    }

    private func presentInline(_ state: InlineState) -> Bool {
        let box = state.layout.bounds
        guard !state.layout.lines.isEmpty, !box.isNull,
              box.origin.x.isFinite, box.origin.y.isFinite else { return false }
        let frame = box.insetBy(dx: -Self.inlinePadding, dy: -Self.inlinePadding).integral
        let color = CotypingGhostStyle.resolvedGhostColor(
            from: state.style, isDarkEnvironment: Self.prefersDarkEnvironment,
            measuredLuminance: state.luminance)
        let emphasis = CotypingInlineGhostLayout.displayText(String(state.text.prefix(state.emphasisLength))).count
        present(frame: frame, content: CotypingGhostTextView.Content(
            lines: state.layout.lines.map {
                .init(text: $0.text, offset: $0.offset,
                      origin: CGPoint(x: $0.origin.x - frame.minX, y: $0.origin.y - frame.minY))
            },
            font: state.layout.font,
            emphasisLength: emphasis,
            color: color,
            emphasisColor: color.withAlphaComponent(CotypingGhostStyle.emphasisOpacity),
            isRightToLeft: state.layout.isRightToLeft))
        inline = state
        acceptanceText = state.text
        return true
    }

    private func presentMirror(
        text: String, font fieldFont: NSFont, caretRect: CGRect, caretIsExact: Bool,
        inputFrameRect: CGRect?, visible: CGRect?, emphasisLength: Int, isRightToLeft: Bool
    ) -> Bool {
        let size = min(Self.mirrorPointSizes.upperBound, max(Self.mirrorPointSizes.lowerBound, fieldFont.pointSize))
        let font = NSFont(descriptor: fieldFont.fontDescriptor, size: size) ?? .systemFont(ofSize: size)
        let lines = CotypingGhostTextLayout.wrappedLines(
            text: text, font: font, maxWidth: CotypingGhostTextLayout.mirrorTextWidthBudget(visible: visible))
        guard !lines.isEmpty else { return false }
        let lineHeight = NSLayoutManager().defaultLineHeight(for: font)
        let widest = lines.map { CotypingInlineGhostLayout.width(of: $0, font: font) }.max() ?? 0
        let content = CGSize(
            width: ceil(widest) + Self.chromePadding.width * 2,
            height: ceil(lineHeight * CGFloat(lines.count)) + Self.chromePadding.height * 2)
        guard let frame = CotypingOverlayGeometry.popupFrame(
            caret: caretRect, caretIsExact: caretIsExact, field: inputFrameRect,
            content: content, visible: visible)?.integral else { return false }
        let glyphBox = font.ascender - font.descender
        var offset = 0
        var drawn: [CotypingGhostTextView.Line] = []
        for (index, line) in lines.enumerated() {
            let lineTop = frame.height - Self.chromePadding.height - lineHeight * CGFloat(index)
            let baseline = lineTop - (lineHeight - glyphBox) / 2 - font.ascender
            let x = isRightToLeft ? frame.width - Self.chromePadding.width : Self.chromePadding.width
            drawn.append(.init(text: line, offset: offset, origin: CGPoint(x: x, y: baseline)))
            offset += line.count + 1
        }
        let leading = text.prefix { $0.isWhitespace }.count
        let emphasis = CotypingInlineGhostLayout.displayText(
            String(text.prefix(emphasisLength).dropFirst(leading))).count
        present(frame: frame, content: CotypingGhostTextView.Content(
            lines: drawn, font: font, emphasisLength: emphasis,
            color: .secondaryLabelColor, emphasisColor: .labelColor,
            isRightToLeft: isRightToLeft, showsChrome: true))
        return true
    }

    private func present(frame: CGRect, content: CotypingGhostTextView.Content) {
        let panel = ensurePanel()
        guard let ghostView else { return }
        panel.appearance = NSApp.effectiveAppearance
        panel.hasShadow = content.showsChrome
        panel.setFrame(frame, display: false)
        ghostView.frame = CGRect(origin: .zero, size: frame.size)
        ghostView.content = content
        ghostView.displayIfNeeded()
        if !isVisible || !panel.isVisible { panel.orderFrontRegardless() }
        isVisible = true
    }

    private func sampleBackground(behind caretRect: CGRect, forField fieldKey: String?) {
        guard !samplingInFlight else { return }
        samplingInFlight = true
        let generation = sampleGeneration
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.samplingInFlight = false }
            let luminance = await self.sampler.sampleLuminance(at: caretRect, forField: fieldKey)
            guard generation == self.sampleGeneration, self.isVisible,
                  var state = self.inline, let luminance else { return }
            state.luminance = luminance
            _ = self.presentInline(state)
        }
    }

    private static var prefersDarkEnvironment: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    private func screenVisibleFrame(containing rect: CGRect) -> CGRect? {
        let point = CGPoint(x: rect.midX, y: rect.midY)
        return NSScreen.screens.first(where: { $0.frame.contains(point) })?.visibleFrame
    }

    private func ensurePanel() -> CotypingOverlayPanel {
        if let panel { return panel }
        let panel = CotypingOverlayPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true)
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.animationBehavior = .none
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.sharingType = .none
#if LOKALBOT_TEST_HOOKS
        if TestHooks.filmsAutocomplete { panel.sharingType = .readOnly }
#endif
        let view = CotypingGhostTextView(frame: .zero)
        panel.contentView = view
        self.panel = panel
        ghostView = view
        return panel
    }
}

final class CotypingOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
