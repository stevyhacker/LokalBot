import Foundation

/// Replaces every personal string in a capture trace with a structure-
/// preserving placeholder before the trace is written. Letters become
/// consonants (so any vowel in a scrubbed field reveals unscrubbed text),
/// digits stay digits, punctuation stays, so detection patterns such as Meet
/// codes survive while content does not. Keep `allowlist` equal to
/// `Scripts/record-capture/scrub-allowlist.json`.
struct CaptureTraceScrubber {
    static let version = 1

    struct Allowlist {
        let vocabulary: Set<String>
        let appNames: Set<String>
        let meetingHosts: Set<String>
        /// Detection-relevant apps; their helper processes (an allowed ID
        /// followed by ".") are kept too.
        let bundleIDs: Set<String>
        let bundlePrefixes: [String]
    }

    static let allowlist = Allowlist(
        vocabulary: ["meet", "meeting", "meetings", "zoom", "teams", "microsoft", "google", "chrome", "call",
                     "calls", "webex", "slack", "huddle", "facetime", "safari", "firefox", "edge", "brave", "arc",
                     "join", "leave", "mute", "unmute", "camera", "microphone", "present", "presenting", "screen",
                     "share", "sharing", "https", "http", "www", "chat", "participants", "people", "recording",
                     "lokalbot", "new", "tab", "untitled", "settings", "password", "sign", "in",
                     "tencent", "voov", "feishu", "lark", "dingtalk", "wecom"],
        appNames: ["Google Chrome", "Safari", "Firefox", "Arc", "Microsoft Edge", "Brave Browser",
                   "Microsoft Teams", "zoom.us", "Zoom", "Slack", "FaceTime", "Webex", "Xcode", "Terminal",
                   "Finder", "Notion", "Figma", "Visual Studio Code", "Code", "Discord", "Spotify", "Mail",
                   "Messages", "Notes", "Pages", "Keynote", "Numbers", "Google Chrome Helper",
                   "Google Chrome Helper (Renderer)", "Microsoft Teams (work or school)",
                   "Tencent Meeting", "腾讯会议", "VooV Meeting", "Feishu", "飞书", "Lark", "DingTalk", "钉钉",
                   "WeCom", "企业微信"],
        meetingHosts: ["meet.google.com", "teams.microsoft.com", "teams.live.com", "zoom.us", "app.zoom.us",
                       "webex.com", "whereby.com", "app.slack.com", "meeting.tencent.com", "voovmeeting.com",
                       "vc.feishu.cn", "vc.larksuite.com", "meeting.dingtalk.com"],
        bundleIDs: ["us.zoom.xos", "com.microsoft.teams2", "com.microsoft.teams", "com.tinyspeck.slackmacgap",
                    "com.webex.meetingmanager", "Cisco-Systems.Spark", "Cisco-Systems.SparkHelper",
                    "com.apple.FaceTime", "com.google.Chrome",
                    "com.apple.Safari", "company.thebrowser.Browser", "com.microsoft.edgemac", "com.brave.Browser",
                    "org.mozilla.firefox", "com.microsoft.teams2.modulehost", "me.dotenv.LokalBot",
                    "com.tencent.meeting", "com.tencent.tencentmeeting", "com.electron.lark",
                    "com.bytedance.lark.helper", "com.larksuite.larkApp", "com.alibaba.DingTalkMac",
                    "com.alibaba.DingTalk-Helper", "com.tencent.WeWorkMac"],
        bundlePrefixes: ["com.apple."])

    private static let consonants = Array("bcdfghjklmnpqrstvwxz")
    private static let email = try? NSRegularExpression(pattern: #"[^\s@]+@[^\s@]+"#)
    let key: UInt64

    init(key: UInt64 = .random(in: 1...UInt64.max)) {
        self.key = key
    }

    func scrub(_ trace: CaptureTrace) -> CaptureTrace {
        var result = trace
        result.header.scrubberVersion = Self.version
        result.events = trace.events.map(scrub)
        return result
    }

    private func scrub(_ event: CaptureTrace.Event) -> CaptureTrace.Event {
        var event = event
        event.app = event.app.map(scrub)
        event.apps = event.apps?.map(scrub)
        event.title = event.title.map(scrubText)
        if var read = event.read, var snapshot = read.snapshot {
            snapshot.text = scrubText(snapshot.text)
            snapshot.sourceURL = snapshot.sourceURL.map(scrubURL)
            snapshot.framedURLs = snapshot.framedURLs?.map(scrubURL)
            snapshot.documentName = snapshot.documentName.map(scrubText)
            snapshot.windowTitle = snapshot.windowTitle.map(scrubText)
            read.snapshot = snapshot
            event.read = read
        }
        if var browser = event.browser {
            // Fail closed: an unparseable scrubbed URL never keeps the original.
            browser.url = URL(string: scrubURL(browser.url.absoluteString)) ?? URL(fileURLWithPath: "/")
            event.browser = browser
        }
        event.windows = event.windows?.map {
            ScreenshotCaptureLayout.Window(id: $0.id, processID: $0.processID, appName: scrubAppName($0.appName),
                                           title: scrubText($0.title), frame: $0.frame)
        }
        event.processes = event.processes?.map {
            AudioProcess(id: $0.id, name: scrubAppName($0.name), bundleID: $0.bundleID.map(scrubBundleID),
                         objectID: $0.objectID, isRunningOutput: $0.isRunningOutput)
        }
        return event
    }

    private func scrub(_ app: RunningApp) -> RunningApp {
        var app = app
        app.localizedName = app.localizedName.map(scrubAppName)
        app.bundleIdentifier = app.bundleIdentifier.map(scrubBundleID)
        return app
    }

    func scrubBundleID(_ id: String) -> String {
        let allowlist = Self.allowlist
        if allowlist.bundleIDs.contains(where: { id == $0 || id.hasPrefix($0 + ".") })
            || allowlist.bundlePrefixes.contains(where: { id.hasPrefix($0) }) {
            return id
        }
        return id.split(separator: ".", omittingEmptySubsequences: false)
            .map { scrubTokens(String($0), keepVocabulary: false) }
            .joined(separator: ".")
    }

    func scrubAppName(_ name: String) -> String {
        Self.allowlist.appNames.contains(name) ? name : scrubText(name)
    }

    func scrubText(_ text: String) -> String {
        var output = text
        if let email = Self.email {
            let matches = email.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed()
            for match in matches {
                guard let range = Range(match.range, in: output) else { continue }
                output.replaceSubrange(range, with: scrubTokens(String(output[range]), keepVocabulary: false))
            }
        }
        return scrubTokens(output, keepVocabulary: true)
    }

    private func scrubTokens(_ text: String, keepVocabulary: Bool) -> String {
        var result = ""
        var token = ""
        func flush() {
            guard !token.isEmpty else { return }
            if keepVocabulary, Self.allowlist.vocabulary.contains(token.lowercased()) {
                result += token
            } else {
                result += replace(token)
            }
            token = ""
        }
        for character in text {
            if character.isLetter || character.isNumber {
                token.append(character)
            } else {
                flush()
                result.append(character.isASCII ? character : "*")
            }
        }
        flush()
        return result
    }

    private func replace(_ token: String) -> String {
        var state = seed(token)
        return String(token.map { character -> Character in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let pick = Int((state >> 33) % UInt64(Self.consonants.count))
            if character.isNumber { return Character(String((state >> 33) % 10)) }
            let letter = Self.consonants[pick]
            return character.isUppercase ? Character(letter.uppercased()) : letter
        })
    }

    private func seed(_ token: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325 ^ key
        for byte in token.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }

    func scrubURL(_ string: String) -> String {
        guard var components = URLComponents(string: string), let scheme = components.scheme else {
            return scrubText(string)
        }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        components.scheme = ["http", "https", "file"].contains(scheme.lowercased()) ? scheme : scrubText(scheme)
        if let host = components.host, !Self.allowlist.meetingHosts.contains(host.lowercased()) {
            components.host = host.split(separator: ".").map { scrubTokens(String($0), keepVocabulary: false) }
                .joined(separator: ".")
        }
        components.percentEncodedPath = components.path.split(separator: "/", omittingEmptySubsequences: false)
            .map { segment in
                (scrubText(String(segment)).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)) ?? ""
            }
            .joined(separator: "/")
        return components.string ?? scrubText(string)
    }
}
