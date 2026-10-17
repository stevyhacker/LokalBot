import AppKit
import SwiftUI
import XCTest
@testable import LokalBot

final class AppLanguageRootTests: XCTestCase {
    /// In-process environment propagation: no window is shown and no input is
    /// sent. Two independently created hosting views share the production root.
    @MainActor
    func testIndependentHostingRootsUpdateInPlaceAndOverrideInheritedLocale() async {
        var initialSettings = AppSettings()
        initialSettings.appLanguage = .english
        let store = SettingsStore(initialSettings: initialSettings)
        let languages: [AppLanguage] = [
            .english, .simplifiedChinese, .arabic, .egyptianArabic, .urdu, .nigerianPidgin, .japanese, .korean, .swahili, .french, .english
        ]
        let steps = languages.enumerated().map { expectation(description: "\($0.offset): \($0.element.rawValue)") }
        for step in steps { step.expectedFulfillmentCount = 2 }
        var observed = [[String](), [String]()]
        var directions = [[LayoutDirection](), [LayoutDirection]()]
        var creations = [0, 0]
        let hosts = ["en", "zh-Hans"].enumerated().map { index, inheritedLocale in
            let probe = LocaleProbe(
                onCreate: { creations[index] += 1 },
                onUpdate: { locale, direction in
                    guard observed[index].last != locale.identifier else { return }
                    observed[index].append(locale.identifier)
                    directions[index].append(direction)
                    let step = observed[index].count - 1
                    if steps.indices.contains(step) { steps[step].fulfill() }
                })
            let host = NSHostingView(rootView: probe
                .appLanguageRoot(store)
                .environment(\.locale, Locale(identifier: inheritedLocale))
                .environment(\.layoutDirection, .rightToLeft))
            host.frame = NSRect(x: 0, y: 0, width: 100, height: 40)
            host.layoutSubtreeIfNeeded()
            return host
        }
        // Retain the hosts while SwiftUI processes publisher updates.
        defer { _ = hosts }
        await fulfillment(of: [steps[0]], timeout: 3)
        XCTAssertEqual(observed, [["en"], ["en"]])

        for index in languages.indices.dropFirst() {
            store.current.appLanguage = languages[index]
            await fulfillment(of: [steps[index]], timeout: 3)
        }
        let expectedLocales = languages.map(\.rawValue)
        let expectedDirections: [LayoutDirection] = [
            .leftToRight, .leftToRight, .rightToLeft, .rightToLeft, .rightToLeft,
            .leftToRight, .leftToRight, .leftToRight, .leftToRight, .leftToRight, .leftToRight
        ]
        XCTAssertEqual(observed, [expectedLocales, expectedLocales])
        XCTAssertEqual(directions, [expectedDirections, expectedDirections])
        XCTAssertEqual(creations, [1, 1], "Switching language must preserve the hosted content's identity")
        XCTAssertEqual(store.current, initialSettings, "Interface changes must leave every other preference unchanged")
    }
}

private struct LocaleProbe: NSViewRepresentable {
    let onCreate: () -> Void
    let onUpdate: (Locale, LayoutDirection) -> Void

    func makeNSView(context: Context) -> NSView {
        onCreate()
        return NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        onUpdate(context.environment.locale, context.environment.layoutDirection)
    }
}
