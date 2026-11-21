// Contains code ported from Cotabby (https://github.com/FuJacob/cotabby),
// copyright the Cotabby authors, under the GNU AGPL v3.0
// (LICENSES/AGPL-3.0.txt). Modified for LokalBot since 23 June 2026.
// See THIRD_PARTY_NOTICES.md.

import CoreGraphics
import Foundation

enum CotypingSurfaceClass: String, Equatable, Sendable {
    case codeEditor, terminal, email, chat, browser, other
}

enum CotypingSurfaceClassifier {
    static func classify(bundleID: String?, isIntegratedTerminal: Bool = false) -> CotypingSurfaceClass {
        if isIntegratedTerminal { return .terminal }
        guard let raw = bundleID?.lowercased(), !raw.isEmpty else { return .other }
        if terminalPrefixes.contains(where: raw.hasPrefix) { return .terminal }
        if codeEditorPrefixes.contains(where: raw.hasPrefix) { return .codeEditor }
        if emailPrefixes.contains(where: raw.hasPrefix) { return .email }
        if chatPrefixes.contains(where: raw.hasPrefix) { return .chat }
        if browserPrefixes.contains(where: raw.hasPrefix) { return .browser }
        return .other
    }

    static let terminalPrefixes = [
        "com.apple.terminal", "com.googlecode.iterm2", "dev.warp.",
        "io.alacritty", "net.kovidgoyal.kitty", "co.zeit.hyper", "com.github.wez.wezterm",
        "com.mitchellh.ghostty", "io.rio.terminal",
    ]
    static let codeEditorPrefixes = [
        "com.apple.dt.xcode", "com.microsoft.vscode", "com.jetbrains.",
        "com.sublimetext.", "com.panic.nova", "dev.zed.", "com.zed.",
    ]
    static let emailPrefixes = [
        "com.apple.mail", "com.readdle.smartemail", "com.airmailapp.airmail",
        "com.microsoft.outlook", "com.superhuman.",
    ]
    static let chatPrefixes = [
        "com.tinyspeck.slackmacgap", "com.microsoft.teams", "com.hnc.discord",
        "com.apple.mobilesms", "ru.keepcoder.telegram", "net.whatsapp.whatsapp",
    ]
    static let browserPrefixes = [
        "com.apple.safari", "com.google.chrome", "org.mozilla.firefox",
        "com.microsoft.edgemac", "com.brave.browser", "company.thebrowser.browser",
        "com.operasoftware.opera", "com.vivaldi.vivaldi",
    ]

    static func isIntegratedTerminal(domClassList: [String]) -> Bool {
        domClassList.contains { $0.lowercased().hasPrefix("xterm") }
    }
}

struct CotypingSurfaceContext: Equatable, Sendable {
    let surfaceClass: CotypingSurfaceClass
    let applicationName: String
    let windowTitle: String?
    let fieldPlaceholder: String?
}

struct CotypingSurfaceCapture: Equatable, Sendable {
    var windowTitle: String?
    var fieldPlaceholder: String?
    var urlString: String?

    static let empty = CotypingSurfaceCapture(
        windowTitle: nil,
        fieldPlaceholder: nil,
        urlString: nil)
}

struct CotypingSurfaceCaptureCache: Sendable {
    private var key: String?
    private var captured: CotypingSurfaceCapture = .empty

    mutating func capture(forKey key: String, resolve: () -> CotypingSurfaceCapture) -> CotypingSurfaceCapture {
        if key == self.key {
            return captured
        }
        let resolved = resolve()
        self.key = key
        captured = resolved
        return resolved
    }

    mutating func removeAll() {
        key = nil
        captured = .empty
    }

    static func key(
        processID: pid_t,
        bundleID: String?,
        role: String,
        subrole: String?,
        focusIdentityKey: String?,
        inputFrameRect: CGRect?,
        includeSurface: Bool,
        includeURL: Bool
    ) -> String {
        [
            String(processID),
            bundleID ?? "",
            role,
            subrole ?? "",
            focusIdentityKey ?? "",
            roundedFrameKey(inputFrameRect),
            includeSurface ? "surface" : "",
            includeURL ? "url" : "",
        ].joined(separator: "\u{1f}")
    }

    private static func roundedFrameKey(_ rect: CGRect?) -> String {
        guard let rect else { return "" }
        return [
            rect.origin.x, rect.origin.y, rect.size.width, rect.size.height,
        ]
            .map { String(Int($0.rounded())) }
            .joined(separator: ",")
    }
}

enum CotypingSurfaceComposer {
    private static let maxTitleLength = 80
    private static let maxPlaceholderLength = 60

    static func compose(
        appName: String,
        bundleID: String?,
        windowTitle: String?,
        fieldPlaceholder: String?,
        isIntegratedTerminal: Bool = false
    ) -> CotypingSurfaceContext? {
        let surfaceClass = CotypingSurfaceClassifier.classify(
            bundleID: bundleID,
            isIntegratedTerminal: isIntegratedTerminal)
        switch surfaceClass {
        case .codeEditor, .terminal:
            return nil
        case .email, .chat, .browser, .other:
            break
        }
        let cleanedApp = collapseWhitespace(appName)
        guard !cleanedApp.isEmpty else { return nil }
        let rawTitle = sanitizedTitle(windowTitle, applicationName: cleanedApp)
        let title = rawTitle.flatMap { isGenericDocumentTitle($0) ? nil : $0 }
        let placeholder = sanitizedPlaceholder(fieldPlaceholder)
        if surfaceClass == .other, title == nil, placeholder == nil { return nil }
        return CotypingSurfaceContext(
            surfaceClass: surfaceClass, applicationName: cleanedApp,
            windowTitle: title, fieldPlaceholder: placeholder)
    }

    static func prefaceLines(for surface: CotypingSurfaceContext) -> [String] {
        switch surface.surfaceClass {
        case .codeEditor, .terminal: return []
        case .email, .chat, .browser, .other: break
        }
        if let title = surface.windowTitle {
            let label = surface.surfaceClass == .email ? "Subject" : "Topic"
            return ["\(label): \(title)"]
        }
        if surface.surfaceClass == .chat, let placeholder = surface.fieldPlaceholder,
           let channel = placeholder.range(of: "#") {
            return ["Topic: \(placeholder[channel.lowerBound...])"]
        }
        return []
    }

    static func sanitizedTitle(_ rawTitle: String?, applicationName: String) -> String? {
        guard var title = nonEmptyCleaned(rawTitle) else { return nil }
        for separator in [" - ", " — ", " – "] {
            let suffix = separator + applicationName
            if let range = title.range(of: suffix, options: [.caseInsensitive, .anchored, .backwards]) {
                title = String(title[..<range.lowerBound])
                break
            }
        }
        title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        return String(title.prefix(maxTitleLength))
    }

    private static func isGenericDocumentTitle(_ title: String) -> Bool {
        let folded = title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if folded == "untitled" || folded == "new document" { return true }
        if folded.hasPrefix("untitled.") || folded.hasPrefix("untitled ") { return true }
        return false
    }

    private static func sanitizedPlaceholder(_ raw: String?) -> String? {
        guard let placeholder = nonEmptyCleaned(raw) else { return nil }
        return String(placeholder.prefix(maxPlaceholderLength))
    }

    private static func nonEmptyCleaned(_ text: String?) -> String? {
        guard let text else { return nil }
        let cleaned = collapseWhitespace(String(text.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && $0 != "\""
        }))
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func collapseWhitespace(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
