import AppKit
import ApplicationServices

final class CotypingVisibleContextAXSource: CotypingVisibleContextSource {
    private let field: AXUIElement
    private let processID: pid_t
    private let appName: String
    private let bundleID: String?
    private let focusIsCurrent: () -> Bool
    private let started = ContinuousClock.now
    private var elements: [String: AXUIElement] = [:]

    init(field: AXUIElement, processID: pid_t, appName: String, bundleID: String?,
         focusIsCurrent: @escaping () -> Bool) {
        self.field = field
        self.processID = processID
        self.appName = appName
        self.bundleID = bundleID
        self.focusIsCurrent = focusIsCurrent
    }

    var withinBudget: Bool { started.duration(to: .now) < .milliseconds(70) }

    func target() -> CotypingVisibleContext.Target? { target(requiringScope: true) }

    func target(requiringScope: Bool) -> CotypingVisibleContext.Target? {
        guard withinBudget, processID != ProcessInfo.processInfo.processIdentifier,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == processID,
              focusIsCurrent(), let fieldFrame = frame(field),
              let role = string(field, kAXRoleAttribute),
              !secure(field, role: role) else { return nil }
        let app = AXUIElementCreateApplication(processID)
        guard let window = element(app, kAXFocusedWindowAttribute), let windowFrame = frame(window),
              let title = string(window, kAXTitleAttribute) else { return nil }
        var cursor: AXUIElement? = field
        var scope: AXUIElement?
        var scopeFrame: CGRect?
        var urls = Set<String>()
        var hasWeb = false
        var reachedWindow = false
        var visited = Set<String>()
        for _ in 0..<(requiringScope ? 16 : 64) {
            guard withinBudget, let node = cursor, visited.insert(register(node)).inserted,
                  let role = string(node, kAXRoleAttribute), attribute(node, "AXHidden") as? Bool != true else { return nil }
            if role == "AXWebArea" {
                hasWeb = true
                guard let url = ScreenContextPrivacy.sanitizedURL(string(node, kAXURLAttribute)) else { return nil }
                urls.insert(url)
            }
            if requiringScope, scope == nil, !CFEqual(node, field),
               ["AXGroup", "AXScrollArea", "AXWebArea", "AXSplitGroup", "AXWindow"].contains(role),
               let rect = frame(node), rect.contains(fieldFrame), fieldFrame.minY - rect.minY >= 64 {
                scope = node
                scopeFrame = rect
            }
            if CFEqual(node, window) { reachedWindow = true; break }
            cursor = element(node, kAXParentAttribute)
        }
        if !requiringScope, scope == nil {
            scope = window
            scopeFrame = windowFrame
        }
        guard reachedWindow, urls.count <= 1, let scope, let scopeFrame else { return nil }
        let documentURL = ScreenContextPrivacy.sanitizedURL(string(window, kAXDocumentAttribute))
        return CotypingVisibleContext.Target(
            appName: appName, bundleID: bundleID, windowID: register(window),
            focusID: register(field), scopeID: register(scope), windowTitle: title,
            sourceURL: urls.first ?? documentURL, hasWebContent: hasWeb,
            focusedSecureField: false, windowFrame: windowFrame, fieldFrame: fieldFrame, scopeFrame: scopeFrame)
    }

    func region(_ id: String) -> CotypingVisibleContext.Region? {
        guard withinBudget, let node = elements[id], let role = string(node, kAXRoleAttribute) else { return nil }
        return .init(id: id, role: role, frame: frame(node),
                     hidden: attribute(node, "AXHidden") as? Bool == true,
                     secure: secure(node, role: role, includeLabels: false),
                     sourceURL: role == "AXWebArea" ? string(node, kAXURLAttribute) : nil)
    }

    func children(_ id: String) -> [String] {
        guard withinBudget, let node = elements[id],
              let children = (attribute(node, kAXVisibleChildrenAttribute)
                ?? attribute(node, kAXChildrenAttribute)) as? [AXUIElement] else { return [] }
        return children.prefix(80).map(register)
    }

    func text(_ id: String) -> String? {
        guard withinBudget, let node = elements[id], let role = string(node, kAXRoleAttribute) else { return nil }
        if role == "AXStaticText" { return string(node, kAXValueAttribute) ?? string(node, kAXTitleAttribute) }
        if role == "AXLink" { return string(node, kAXTitleAttribute) }
        return nil
    }

    private func secure(_ node: AXUIElement, role: String, includeLabels: Bool = true) -> Bool {
        guard withinBudget else { return true }
        AXUIElementSetMessagingTimeout(node, 0.004)
        var subrole: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(node, kAXSubroleAttribute as CFString, &subrole)
        guard status == .success || status == .attributeUnsupported || status == .noValue else { return true }
        return CotypingSecureFieldDetector.isSecure(
            role: role, subrole: subrole as? String,
            roleDescription: string(node, kAXRoleDescriptionAttribute),
            title: includeLabels ? string(node, kAXTitleAttribute) : nil,
            descriptionLabel: includeLabels ? string(node, kAXDescriptionAttribute) : nil)
    }

    private func register(_ element: AXUIElement) -> String {
        let id = String(CFHash(element))
        elements[id] = element
        return id
    }

    private func attribute(_ node: AXUIElement, _ name: String) -> CFTypeRef? {
        guard withinBudget else { return nil }
        AXUIElementSetMessagingTimeout(node, 0.004)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(node, name as CFString, &value) == .success else { return nil }
        return value
    }

    private func string(_ node: AXUIElement, _ name: String) -> String? {
        switch attribute(node, name) {
        case let value as String: value
        case let value as NSAttributedString: value.string
        case let value as URL: value.absoluteString
        default: nil
        }
    }

    private func element(_ node: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(node, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return value as! AXUIElement
    }

    private func frame(_ node: AXUIElement) -> CGRect? {
        guard let position = attribute(node, kAXPositionAttribute), let size = attribute(node, kAXSizeAttribute),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }
}
