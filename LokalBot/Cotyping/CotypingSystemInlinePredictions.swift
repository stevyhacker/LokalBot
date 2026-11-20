import Foundation

enum CotypingSystemInlinePredictions {
    static let defaultsKey = "NSAutomaticInlinePredictionEnabled"
    static let keyboardSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!

    static func isOn(globalDomain: [String: Any]?) -> Bool {
        switch globalDomain?[defaultsKey] {
        case let value as NSNumber: return value.boolValue
        case let value as String: return (value as NSString).boolValue
        default: return true
        }
    }

    static func isOn() -> Bool {
        isOn(globalDomain: UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain))
    }
}
