import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

extension Color {
    /// A token's light or dark value, resolved by the view's appearance.
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
    /// The Mac's `LBTokens.Palette`, from the generated tokens. Prefer system
    /// semantic colors (`.primary`, `.secondary`) and backgrounds; these cover
    /// only what the system doesn't provide.
    public enum Palette {
        /// Filled buttons, selection knob, citation badges. White text on it meets 4.5:1.
        public static let accentFill = Color(Colors.accentFill)
        /// Links, timestamps, icons, done checks, evidence pills.
        public static let accentText = Color(Colors.accentText)
        /// Selected rows, the cited transcript line.
        public static let accentWash = Color(Colors.accentWash)
        /// Dots and fills for attention: remote engine, pending changes.
        public static let attention = Color(Colors.attention)
        /// "Owner unclear", blockers, "Waiting for your Mac".
        public static let attentionText = Color(Colors.attentionText)
        public static let attentionWash = Color(Colors.attentionWash)
        public static let success = Color(Colors.success)
        public static let successText = Color(Colors.successText)
        /// Destructive fills.
        public static let recording = Color(Colors.recording)
        /// Overdue dates, destructive text.
        public static let recordingText = Color(Colors.recordingText)
        public static let groupFill = Color(Colors.groupFill)
        public static let groupStroke = Color(Colors.groupStroke)
        public static let chipFill = Color(Colors.chipFill)
        public static let separator = Color(Colors.separator)
        /// Metadata lines; stays above 4.5:1 on grouped fills, unlike `.secondary`.
        public static let supporting = Color(Colors.textSupporting)
        public static let sidebar = Color(Colors.sidebar)
        public static let elevated = Color(Colors.elevated)

        /// Status surfaces: the tint at 10% with a 28% stroke.
        public static let statusFillOpacity = 0.10

        /// Speakers; index 0 is the person themselves. Always show the name
        /// next to the color.
        public static let speakers: [Color] = LBTokens.speakers.map(Color.init)

        /// A transcript `colorIndex`: -1 (grouped or unknown voices) uses the
        /// supporting color.
        public static func speaker(at index: Int) -> Color {
            guard index >= 0 else { return supporting }
            return speakers[index % speakers.count]
        }
    }
}

/// Brand roles by their Mac names.
public enum Brand {
    /// Deep teal on light surfaces, mint on dark ones.
    public static let teal = LBTokens.Palette.accentText
    /// Behind white foregrounds; deep in both appearances.
    public static let tealFill = LBTokens.Palette.accentFill
    /// Attention, remote inference, saved moments.
    public static let amber = LBTokens.Palette.attention
    /// Failure and warning text and icons.
    public static let error = LBTokens.Palette.attentionText
    public static let recording = LBTokens.Palette.recording
}

extension View {
    /// The LokalBot accent for controls, links and selection.
    public func brandTinted() -> some View { tint(Brand.teal) }
}
