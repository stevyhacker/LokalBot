import SwiftUI

/// Renders the Markdown the Mac sends: summaries, notes, digests and answers.
public struct MarkdownText: View {
    let document: MarkdownDocument
    var inline: (String) -> AttributedString

    public init(_ document: MarkdownDocument, inline: @escaping (String) -> AttributedString = MarkdownInline.attributed) {
        self.document = document
        self.inline = inline
    }

    public init(_ markdown: String, inline: @escaping (String) -> AttributedString = MarkdownInline.attributed) {
        self.init(MarkdownDocument(markdown), inline: inline)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(document.blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func blockView(_ block: MarkdownDocument.Block) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(inline(text))
                .font(level <= 2 ? LBTokens.Typography.section : LBTokens.Typography.secondary.weight(.semibold))
                .padding(.top, 4)
                .accessibilityAddTraits(.isHeader)
        case .paragraph(let text):
            Text(inline(text)).readingText().fixedSize(horizontal: false, vertical: true)
        case .bullets(let items):
            list(items.map { ("•", $0) })
        case .numbered(let items):
            list(items.enumerated().map { ("\($0.offset + 1).", $0.element) })
        case .quote(let text):
            HStack(alignment: .top, spacing: 10) {
                Capsule().fill(Brand.teal.opacity(0.5)).frame(width: 3)
                Text(inline(text)).readingText().italic().fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func list(_ items: [(marker: String, text: String)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(item.marker)
                        .font(LBTokens.Typography.reading.monospacedDigit())
                        .foregroundStyle(LBTokens.Palette.supporting)
                        .accessibilityHidden(true)
                    Text(inline(item.text)).readingText().fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
