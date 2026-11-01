import Foundation
import LokalBotCompanionKit
import UIKit

/// Chooses the store: the Rust sync core's, or the in-memory sample store for
/// debug screenshots (DemoLaunch).
enum StoreFactory {
    /// Why the local copy couldn't be opened, shown once at launch.
    @MainActor static var openError: String?

    @MainActor
    static func makeStore() -> any CompanionStore {
        if let demo = DemoLaunch.store() { return demo }
        do {
            return try RustStore.open()
        } catch {
            // The app still opens (welcome screen, sample library) and says why.
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

    /// Remembers the name the Mac will show for this device. The sync core
    /// sends it when pairing, so a changed name reopens the store first.
    @MainActor
    static func useDeviceName(_ name: String, in session: CompanionSession) async throws {
        DeviceName.remember(name)
        guard let current = session.store as? RustStore, current.deviceName != DeviceName.current else { return }
        await session.replaceStore(try RustStore.open(deviceName: DeviceName.current))
    }
}

/// What the Mac calls this device in its approval prompt and device list.
/// iOS gives apps only the model ("iPhone", "iPad"), so the person names it
/// when pairing.
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
