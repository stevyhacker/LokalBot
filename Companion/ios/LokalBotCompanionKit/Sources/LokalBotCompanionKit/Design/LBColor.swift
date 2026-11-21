import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

extension Color {
    public init(_ token: LBColorToken) {
        #if canImport(UIKit)
        self.init(uiColor: UIColor { traits in
            UIColor(rgba: traits.userInterfaceStyle == .dark ? token.dark : token.light)
        })
        #elseif canImport(AppKit)
        self.init(nsColor: NSColor(name: nil) { appearance in
            NSColor(rgba: appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? token.dark : token.light)
        })
        #endif
    }
}

#if canImport(UIKit)
private extension UIColor {
    convenience init(rgba: UInt32) {
        self.init(red: CGFloat((rgba >> 24) & 0xFF) / 255, green: CGFloat((rgba >> 16) & 0xFF) / 255,
                  blue: CGFloat((rgba >> 8) & 0xFF) / 255, alpha: CGFloat(rgba & 0xFF) / 255)
    }
}
#elseif canImport(AppKit)
private extension NSColor {
    convenience init(rgba: UInt32) {
        self.init(srgbRed: CGFloat((rgba >> 24) & 0xFF) / 255, green: CGFloat((rgba >> 16) & 0xFF) / 255,
                  blue: CGFloat((rgba >> 8) & 0xFF) / 255, alpha: CGFloat(rgba & 0xFF) / 255)
    }
}
#endif

extension LBTokens {
    public enum Palette {
        public static let accentFill = Color(Colors.accentFill)
        public static let accentText = Color(Colors.accentText)
        public static let accentWash = Color(Colors.accentWash)
        public static let attention = Color(Colors.attention)
        public static let attentionText = Color(Colors.attentionText)
        public static let attentionWash = Color(Colors.attentionWash)
        public static let success = Color(Colors.success)
        public static let successText = Color(Colors.successText)
        public static let recording = Color(Colors.recording)
        public static let recordingText = Color(Colors.recordingText)
        public static let groupFill = Color(Colors.groupFill)
        public static let groupStroke = Color(Colors.groupStroke)
        public static let chipFill = Color(Colors.chipFill)
        public static let separator = Color(Colors.separator)
        public static let supporting = Color(Colors.textSupporting)
        public static let sidebar = Color(Colors.sidebar)
        public static let elevated = Color(Colors.elevated)

        public static let statusFillOpacity = 0.10

        public static let speakers: [Color] = LBTokens.speakers.map(Color.init)

        public static func speaker(at index: Int) -> Color {
            guard index >= 0 else { return supporting }
            return speakers[index % speakers.count]
        }
    }
}

public enum Brand {
    public static let teal = LBTokens.Palette.accentText
    public static let tealFill = LBTokens.Palette.accentFill
    public static let amber = LBTokens.Palette.attention
    public static let error = LBTokens.Palette.attentionText
    public static let recording = LBTokens.Palette.recording
}

extension View {
    public func brandTinted() -> some View { tint(Brand.teal) }
}
