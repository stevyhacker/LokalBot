import CoreGraphics
import Foundation

protocol CotypingVisibleContextSource {
    func target() -> CotypingVisibleContext.Target?
    func region(_ id: String) -> CotypingVisibleContext.Region?
    func children(_ id: String) -> [String]
    func text(_ id: String) -> String?
    var withinBudget: Bool { get }
}

enum CotypingVisibleContext {
    struct Policy: Codable, Equatable, Sendable {
        var enabled = false
        var windowText = false
        var excludedApps: [String] = []
        var excludedDomains: [String] = []
        var autocompleteExcludedDomains: [String] = []

        init(enabled: Bool = false, windowText: Bool = false, excludedApps: [String] = [],
             excludedDomains: [String] = []) {
            self.enabled = enabled
            self.windowText = windowText
            self.excludedApps = excludedApps
            self.excludedDomains = excludedDomains
        }

        init(settings: AppSettings) {
            enabled = settings.cotypingEnabled && settings.cotypingUseVisibleContext
            windowText = settings.cotypingEnabled && settings.cotypingUseWindowText
            excludedApps = settings.excludedAppList + settings.cotypingExcludedAppList
            excludedDomains = settings.excludedScreenDomainList + settings.cotypingExcludedDomainList
            autocompleteExcludedDomains = settings.cotypingExcludedDomainList
        }

        func permits(_ snapshot: Snapshot) -> Bool {
            permits(snapshot.target, source: snapshot.source)
        }

        func permits(_ target: Target, source: Source = .accessibility) -> Bool {
            guard source == .windowText ? windowText : enabled, !CotypingBrowserDomain.isHostDisabled(
                target.sourceURL.flatMap(CotypingBrowserDomain.host(fromURLString:)),
                excludedDomains: autocompleteExcludedDomains) else { return false }
            let observation = ScreenContextPrivacy.Observation(
                appName: target.appName, bundleIdentifier: target.bundleID,
                windowTitle: target.windowTitle, sourceURL: target.sourceURL,
                focusedSecureField: target.focusedSecureField, hasWebContent: target.hasWebContent)
            guard !ScreenContextPrivacy.isBrowser(observation) && !target.hasWebContent
                    || ScreenContextPrivacy.sanitizedURL(target.sourceURL) != nil else { return false }
            guard !ScreenContextPrivacy.isPrivateWindow(title: target.windowTitle ?? "") else { return false }
            return ScreenContextPrivacy.permitsContent(
                observation, excludedApps: excludedApps, excludedDomains: excludedDomains)
        }
    }

    struct Target: Codable, Equatable, Sendable {
        var appName: String
        var bundleID: String?
        var windowID: String
        var focusID: String
        var scopeID: String
        var windowTitle: String?
        var sourceURL: String?
        var hasWebContent: Bool
        var focusedSecureField: Bool?
        var windowFrame: CGRect
        var fieldFrame: CGRect
        var scopeFrame: CGRect
    }

    struct Region: Codable, Equatable, Sendable {
        var id: String
        var role: String
        var frame: CGRect?
        var hidden: Bool
        var secure: Bool
        var sourceURL: String?
    }

    struct Excerpt: Codable, Equatable, Sendable {
        var id: String
        var frame: CGRect
        var text: String
    }

    enum Source: String, Codable, Equatable, Sendable {
        case accessibility
        case windowText
    }

    struct Snapshot: Equatable, Sendable {
        var target: Target
        var excerpts: [Excerpt]
        var source: Source = .accessibility
        var text: String? {
            excerpts.isEmpty ? nil : excerpts.map(\.text).joined(separator: source == .windowText ? "\n" : " | ")
        }
        var nearbyText: String? { source == .accessibility ? text : nil }
        var windowText: String? { source == .windowText ? text : nil }
    }

    static let maximumNodes = 180
    static let maximumCharacters = 420
    static let maximumExcerpts = 3
    private static let excludedRoles: Set<String> = [
        "AXToolbar", "AXMenuBar", "AXMenu", "AXOutline", "AXSecureTextField",
        "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"
    ]

    static func corridor(for target: Target) -> CGRect? {
        guard valid(target.windowFrame), valid(target.fieldFrame), valid(target.scopeFrame),
              target.windowFrame.contains(target.fieldFrame),
              target.scopeFrame.contains(target.fieldFrame) else { return nil }
        let column = CGRect(x: target.fieldFrame.minX - 24, y: target.fieldFrame.minY - 600,
                            width: target.fieldFrame.width + 48, height: 600)
        let area = column.intersection(target.windowFrame).intersection(target.scopeFrame)
        return valid(area) ? area : nil
    }

    static func capture<Source: CotypingVisibleContextSource>(
        from source: Source, policy: Policy
    ) -> Snapshot? {
        guard policy.enabled, source.withinBudget, let target = source.target(),
              policy.permits(target), let area = corridor(for: target) else { return nil }
        var queue: [(String, CGRect)] = [(target.scopeID, target.scopeFrame.intersection(target.windowFrame))]
        var visited = Set<String>()
        var candidates: [Region] = []
        while !queue.isEmpty {
            guard source.withinBudget, visited.count < maximumNodes else { return nil }
            let (id, viewport) = queue.removeFirst()
            guard visited.insert(id).inserted, id != target.focusID,
                  let region = source.region(id), !region.hidden, !region.secure,
                  !excludedRoles.contains(region.role) else { continue }
            if region.role == "AXWebArea" {
                guard let url = ScreenContextPrivacy.sanitizedURL(region.sourceURL),
                      url == ScreenContextPrivacy.sanitizedURL(target.sourceURL),
                      !ScreenContextPrivacy.isExcluded(sourceURL: url, rules: policy.excludedDomains) else { continue }
            }
            let frame = region.frame
            if let frame, !valid(frame) || !frame.intersects(area) || !frame.intersects(viewport) { continue }
            if ["AXStaticText", "AXLink"].contains(region.role),
               let frame, viewport.contains(frame), area.contains(frame) {
                candidates.append(region)
            }
            let clips = ["AXScrollArea", "AXWebArea", "AXWindow", "AXSplitGroup"].contains(region.role)
            if clips && frame == nil { continue }
            let clipped = clips ? viewport.intersection(frame ?? .null) : viewport
            guard valid(clipped) else { continue }
            queue.append(contentsOf: source.children(id).prefix(80).map { ($0, clipped) })
        }
        candidates.sort {
            let left = $0.frame ?? .zero, right = $1.frame ?? .zero
            if left.maxY != right.maxY { return left.maxY > right.maxY }
            return $0.id < $1.id
        }
        var excerpts: [Excerpt] = []
        var seen = Set<String>()
        var remaining = maximumCharacters
        for candidate in candidates {
            guard excerpts.count < maximumExcerpts, remaining > 0 else { break }
            guard source.withinBudget, source.region(candidate.id) == candidate else { return nil }
            guard let raw = source.text(candidate.id), !raw.isEmpty, raw.count <= 8_000 else { continue }
            guard !CotypingSecureFieldDetector.isSecure(
                role: nil, subrole: nil, roleDescription: nil, title: raw, descriptionLabel: nil),
                  let cleaned = CotypingMemoryContext.sanitized(raw) else { continue }
            let text = PromptContextSanitizer.sanitize(cleaned, maxCharacters: min(240, remaining))
            guard !text.isEmpty, seen.insert(text).inserted else { continue }
            excerpts.append(Excerpt(id: candidate.id, frame: candidate.frame ?? .zero, text: text))
            remaining -= text.count + 3
        }
        guard source.withinBudget, source.target() == target,
              candidates.allSatisfy({ source.withinBudget && source.region($0.id) == $0 }),
              source.withinBudget else { return nil }
        excerpts.sort { $0.frame.minY == $1.frame.minY ? $0.frame.minX < $1.frame.minX : $0.frame.minY < $1.frame.minY }
        return Snapshot(target: target, excerpts: excerpts)
    }

    private static func valid(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isEmpty && rect.minX.isFinite && rect.minY.isFinite
            && rect.width.isFinite && rect.height.isFinite
    }
}
