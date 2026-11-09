import SwiftUI

extension LBTokens {
    /// The Mac's type roles mapped to Dynamic Type styles, as tokens.json
    /// "type" says. The Mac's sizes are desktop sizes; the roles carry over.
    public enum Typography {
        /// Mac largeTitle bold.
        public static var pageTitle: Font { .largeTitle.bold() }
        /// The question in Ask. Mac title2 semibold.
        public static var question: Font { .title3.weight(.semibold) }
        /// Column and detail titles. Mac title3 bold.
        public static var columnTitle: Font { .title3.bold() }
        /// Section headers. Mac headline.
        public static var section: Font { .headline }
        public static var body: Font { .body }
        /// Transcript lines, digests and answers, with `readingLineSpacing`.
        public static var reading: Font { .body }
        public static let readingLineSpacing: CGFloat = 3
        /// Metadata. Mac callout.
        public static var secondary: Font { .subheadline }
        /// Mac subheadline.
        public static var caption: Font { .footnote }
        public static var timestamp: Font { .subheadline.monospacedDigit() }
    }
}

extension View {
    /// Long-form text: the reading font with the Mac's line spacing.
    public func readingText() -> some View {
        font(LBTokens.Typography.reading).lineSpacing(LBTokens.Typography.readingLineSpacing)
    }
}
