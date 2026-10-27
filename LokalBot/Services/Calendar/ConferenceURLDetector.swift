import Foundation

/// Recognizes video-conferencing links inside free text (calendar notes,
/// location, the event URL). Two jobs: flag an event as an online meeting, and
/// — crucially — let a browser's audio count as a meeting when the window title
/// is generic or Accessibility missed it. Pure and trivially testable.
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

    /// First conferencing URL in `text`, or nil. Uses `NSDataDetector` so it
    /// catches bare and embedded links alike.
    static func firstMeetingURL(in text: String?) -> URL? {
        guard let text, !text.isEmpty,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        for match in detector.matches(in: text, range: range) where isMeetingURL(match.url) {
            return match.url
        }
        return nil
    }

    /// Whether `url`'s host is (a subdomain of) a known conferencing host.
    static func isMeetingURL(_ url: URL?) -> Bool {
        guard let host = url?.host?.lowercased() else { return false }
        return hosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }
}
