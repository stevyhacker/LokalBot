import Foundation

/// Recognizes video-conferencing links inside free text (calendar notes,
/// location, the event URL). This flags an event as an online meeting and
/// provides its URL so the detector can verify the right room.
enum ConferenceURLDetector {
    /// Known conferencing hosts (base domains; subdomains match via suffix).
    static let hosts: [String] = [
        "meet.google.com",
        "zoom.us",
        "zoom.com",
        "teams.microsoft.com",
        "teams.live.com",
        "webex.com",
        "whereby.com",
        "meet.jit.si",
        "jit.si",
        "bluejeans.com",
        "gotomeeting.com",
        "chime.aws",
        "around.co",
        "meeting.tencent.com",
        "voovmeeting.com",
        "vc.feishu.cn",
        "vc.larksuite.com",
        "meeting.dingtalk.com",
    ]

    /// Built once: calendar reads ask about every event's URL, location and notes.
    private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// First conferencing URL in `text`, or nil. Uses `NSDataDetector` so it
    /// catches bare and embedded links alike.
    static func firstMeetingURL(in text: String?) -> URL? {
        guard let text, !text.isEmpty, let detector = linkDetector else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        for match in detector.matches(in: text, range: range) where isMeetingURL(match.url) {
            return match.url
        }
        return nil
    }

    /// Whether `url`'s host is (a subdomain of) a known conferencing host.
    static func isMeetingURL(_ url: URL?) -> Bool {
        guard let host = url?.host?.lowercased() else { return false }
        if host == ConferenceRoom.Service.telemost.rawValue || host == ConferenceRoom.Service.mtsLink.rawValue {
            return url.flatMap { ConferenceRoom($0.absoluteString) } != nil
        }
        return hosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }
}
