import Foundation
import LokalBotCompanionKit
import UIKit

enum StoreFactory {
    @MainActor static var openError: String?

    @MainActor
    static func makeStore() -> any CompanionStore {
        if let demo = DemoLaunch.store() { return demo }
        do {
            return try RustStore.open()
        } catch {
            openError = "LokalBot couldn't open its copy on this device: \(error.localizedDescription)"
            return FixtureStore(envelopes: [])
        }
    }

    @MainActor
    static func prepare(_ session: CompanionSession) async {
        if let openError {
            session.notice = openError
        }
    }

    @MainActor
    static func useDeviceName(_ name: String, in session: CompanionSession) async throws {
        DeviceName.remember(name)
        guard let current = session.store as? RustStore, current.deviceName != DeviceName.current else { return }
        await session.replaceStore(try RustStore.open(deviceName: DeviceName.current))
    }
}

enum DeviceName {
    private static let key = "companion.deviceName"

    @MainActor
    static var current: String {
        let stored = UserDefaults.standard.string(forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return stored?.isEmpty == false ? stored! : UIDevice.current.model
    }

    @MainActor
    static func remember(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(trimmed.isEmpty ? nil : String(trimmed.prefix(60)), forKey: key)
    }
}
