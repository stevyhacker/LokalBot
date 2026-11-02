import Foundation
import LokalBotCompanionKit
import SwiftUI

/// Debug-only launch arguments that open the app on a given screen with the
/// sample library presented as a paired Mac, for screenshots without UI
/// automation. For example:
///
///     -demoPaired YES -demoSection meetings -demoMeeting <id> -demoTab transcript
enum DemoLaunch {
    private static var defaults: UserDefaults { .standard }

    @MainActor
    static func store() -> (any CompanionStore)? {
        #if DEBUG
        guard defaults.bool(forKey: "demoPaired") else { return nil }
        let now = SampleLibrary.referenceDate
        let status = SyncStatus(paired: true, lastSyncAt: now.addingTimeInterval(-120),
                                lastAddress: defaults.bool(forKey: "demoTailscale") ? "100.101.102.103:17890" : "192.168.1.20:17890",
                                cursor: 19, macName: "Stevan's MacBook Pro")
        return try? FixtureStore.sampleLibrary(configuration: .init(
            now: { now }, keepsChangesPending: true, pairedStatus: status,
            macReachable: !defaults.bool(forKey: "demoUnreachable")))
        #else
        return nil
        #endif
    }

    /// Exercises the real store end to end against a test host:
    /// `-demoPairLink <lokalbot://pair?d=…>` pairs at launch, and
    /// `-demoToggleAction <meetingID>/<actionID>` marks an action done.
    @MainActor
    static func exercise(_ environment: AppEnvironment) async {
        #if DEBUG
        let session = environment.session
        if defaults.bool(forKey: "demoSample") {
            do {
                try await session.showSampleLibrary()
            } catch {
                session.notice = "The sample library didn't load: \(error.localizedDescription)"
            }
        }
        if let link = defaults.string(forKey: "demoPairLink") {
            do {
                if let name = defaults.string(forKey: "demoDeviceName") {
                    try await StoreFactory.useDeviceName(name, in: session)
                }
                _ = try await session.pair(payload: link)
            } catch {
                session.notice = "Pairing failed: \(error.localizedDescription)"
            }
        }
        if let toggle = defaults.string(forKey: "demoToggleAction") {
            let parts = toggle.split(separator: "/", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                try? await session.setActionStatus(.done, meetingID: parts[0], actionID: parts[1])
            }
        }
        #endif
    }

    @MainActor
    static func apply(to environment: AppEnvironment) {
        #if DEBUG
        if defaults.bool(forKey: "demoPaired") {
            environment.session.referenceDateOverride = SampleLibrary.referenceDate.addingTimeInterval(120)
        }
        let navigator = environment.navigator
        if let action = defaults.string(forKey: "demoAction") { navigator.actionSelection = action }
        if let person = defaults.string(forKey: "demoPerson") { navigator.personSelection = person }
        if let project = defaults.string(forKey: "demoProject") { navigator.projectSelection = project }
        if let day = defaults.string(forKey: "demoDay").flatMap(DayKey.init) { navigator.timelineDay = day }
        if let question = defaults.string(forKey: "demoAsk") { navigator.demoQuestion = question }
        if let link = defaults.string(forKey: "demoPairingLink") { navigator.demoPairingLink = link }
        if let meeting = defaults.string(forKey: "demoMeeting") {
            navigator.meetingSelection = meeting
            let offset = defaults.string(forKey: "demoAt").flatMap(Double.init)
            navigator.meetingFocus = .init(meetingID: meeting, offset: offset)
            navigator.demoMeetingTab = defaults.string(forKey: "demoTab")
        }
        if let section = defaults.string(forKey: "demoSection").flatMap(AppSection.init(rawValue:)) {
            navigator.open(section)
        }
        #endif
    }

    /// `-demoWidth 375` narrows the window's content and makes it compact,
    /// approximating Split View and Slide Over widths in screenshots.
    struct Frame<Content: View>: View {
        @ViewBuilder let content: Content

        /// `-demoSizeClass regular` keeps a narrow window regular, like an
        /// unfolded foldable that reports regular width.
        private var sizeClass: UserInterfaceSizeClass? {
            switch UserDefaults.standard.string(forKey: "demoSizeClass") {
            case "regular": .regular
            case "compact": .compact
            default: nil
            }
        }

        var body: some View {
            #if DEBUG
            if let width = UserDefaults.standard.string(forKey: "demoWidth").flatMap(Double.init) {
                content
                    .frame(width: width)
                    .environment(\.horizontalSizeClass, sizeClass ?? (width < 700 ? .compact : .regular))
                    .overlay(alignment: .trailing) {
                        Rectangle().fill(Color.black).frame(width: 1).offset(x: 1).ignoresSafeArea()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                content
            }
            #else
            content
            #endif
        }
    }
}
