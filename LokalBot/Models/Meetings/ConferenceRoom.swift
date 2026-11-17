import Foundation

/// Canonical conference addresses used by Calendar and call detection.
struct ConferenceRoom: Sendable {
    enum Service: String, Sendable {
        case googleMeet = "meet.google.com"
        case telemost = "telemost.yandex.ru"
        case mtsLink = "my.mts-link.ru"
    }

    let service: Service
    let url: String

    nonisolated init?(_ raw: String) {
        guard let components = Self.trustedURL(raw),
              let host = components.host?.lowercased(),
              let service = Service(rawValue: host) else { return nil }
        let path = components.percentEncodedPath
        let canonicalPath: String
        switch service {
        case .googleMeet:
            // Meet also shows the same room under /meet/ (#372).
            let codePath = path.hasPrefix("/meet/") ? String(path.dropFirst(5)) : path
            guard codePath.range(of: #"^/[a-z]{3}-[a-z]{4}-[a-z]{3}$"#, options: .regularExpression) != nil
            else { return nil }
            canonicalPath = codePath
        case .telemost:
            guard path.range(of: #"^/j/[0-9]+/?$"#, options: .regularExpression) != nil else { return nil }
            canonicalPath = "/" + path.split(separator: "/").joined(separator: "/")
        case .mtsLink:
            // Invitations may have /j/; the active call adds /stream-new/<id>.
            guard path.range(of: #"^/(?:j/)?[0-9]+/[0-9]+(?:/stream-new/[0-9]+)?/?$"#,
                             options: .regularExpression) != nil else { return nil }
            let parts = path.split(separator: "/")
            let index = parts[0] == "j" ? 1 : 0
            canonicalPath = "/j/" + parts[index...index + 1].joined(separator: "/")
        }
        self.service = service
        url = "https://" + host + canonicalPath
    }

    nonisolated private static func trustedURL(_ raw: String) -> URLComponents? {
        guard let components = URLComponents(string: raw), components.scheme == "https",
              components.user == nil, components.password == nil,
              components.port == nil || components.port == 443 else { return nil }
        return components
    }

    /// Telemost embeds its call controls in a same-room iframe. Never borrow
    /// controls from an unrelated frame, even on the same service.
    nonisolated func acceptsFrame(_ raw: String) -> Bool {
        guard service == .telemost, let frame = Self.trustedURL(raw),
              frame.host?.lowercased() == service.rawValue,
              let code = url.split(separator: "/").last else { return false }
        return frame.percentEncodedPath == "/private-join/" + code
    }

    /// These pages can only end a previously verified call in its own window.
    nonisolated func isPostCallPage(_ raw: String) -> Bool {
        guard let page = Self.trustedURL(raw) else { return false }
        let host = page.host?.lowercased()
        let path = page.percentEncodedPath
        switch service {
        case .telemost: return host == Service.telemost.rawValue && (path.isEmpty || path == "/")
        case .mtsLink: return host == "mts-link.ru" && (path == "/meetingguest" || path == "/meetingguest/")
        case .googleMeet: return false
        }
    }
}
