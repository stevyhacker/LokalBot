import SwiftUI

extension LBTokens {
    public enum Typography {
        public static var pageTitle: Font { .largeTitle.bold() }
        public static var question: Font { .title3.weight(.semibold) }
        public static var columnTitle: Font { .title3.bold() }
        public static var section: Font { .headline }
        public static var body: Font { .body }
        public static var reading: Font { .body }
        public static let readingLineSpacing: CGFloat = 3
        public static var secondary: Font { .subheadline }
        public static var caption: Font { .footnote }
        public static var timestamp: Font { .subheadline.monospacedDigit() }
    }
}

extension View {
    public func readingText() -> some View {
        font(LBTokens.Typography.reading).lineSpacing(LBTokens.Typography.readingLineSpacing)
    }
}
