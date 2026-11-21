import AppKit
import AVFoundation
import Carbon.HIToolbox
import CoreGraphics

enum DictationMicrophone {
    struct Option: Equatable, Identifiable {
        let id: String
        let name: String
    }

    static func available() -> [Option] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified
        ).devices.map { Option(id: $0.uniqueID, name: $0.localizedName) }
    }

    static func device(preferredID: String) -> AVCaptureDevice? {
        if !preferredID.isEmpty {
            if let preferred = AVCaptureDevice(uniqueID: preferredID), preferred.isConnected {
                return preferred
            }
            lokalbotLog("dictation preferred microphone is not connected; using the default input")
        }
        return AVCaptureDevice.default(for: .audio)
    }

    static func options(preferredID: String, available: [Option], defaultName: String) -> [Option] {
        var rows = [Option(id: "", name: defaultName)] + available
        if !preferredID.isEmpty, !available.contains(where: { $0.id == preferredID }) {
            rows.append(Option(id: preferredID, name: "Not connected"))
        }
        return rows
    }
}

enum DictationSecureInput {
    static func holder() -> String?? {
        guard IsSecureEventInputEnabled() else { return nil }
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        let pid = (session?["kCGSSessionSecureInputPID"] as? NSNumber)?.int32Value
        let name = pid.flatMap { NSRunningApplication(processIdentifier: $0)?.localizedName }
        return .some(name)
    }

    static func message(appName: String?, localized: (String) -> String = { $0 }) -> String {
        if let appName {
            return String(format: localized(
                "Secure Input is on in %@, so macOS hides the dictation shortcut. Turn it off there (for example Terminal → Secure Keyboard Entry) or switch apps."), appName)
        }
        return localized(
            "Secure Input is on in another app, so macOS hides the dictation shortcut. Turn it off there (for example Terminal → Secure Keyboard Entry) or switch apps.")
    }
}
