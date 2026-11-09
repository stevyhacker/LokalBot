import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import dnssd
import Foundation

/// The confirmation the person answers before a device that scanned the QR
/// code is paired. The sync host calls in from a background thread and waits;
/// the alert runs on the main thread and gives up after `timeout`.
enum CompanionPairingPrompt {
    static let timeout: TimeInterval = 120

    /// A device chooses its own name; show a bounded, single-line version.
    static func displayName(_ raw: String) -> String {
        let line = raw.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
            .map(String.init).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return "A device" }
        return line.count > 60 ? String(line.prefix(59)) + "…" : line
    }

    static func platformName(_ raw: String) -> String {
        switch raw.lowercased() {
        case "ios": "iPhone"
        case "ipados": "iPad"
        case "android": "Android"
        default: raw.isEmpty ? "Device" : raw
        }
    }

    /// Blocks the calling thread. Never call it on the main thread.
    static func ask(deviceName: String, platform: String, language: AppLanguage) -> Bool {
        precondition(!Thread.isMainThread, "the pairing prompt waits for the main thread")
        let answer = DispatchSemaphore(value: 0)
        let allowed = LockedFlag()
        DispatchQueue.main.async {
            allowed.value = MainActor.assumeIsolated {
                runAlert(deviceName: displayName(deviceName),
                         platform: language.localized(platformName(platform)), language: language)
            }
            answer.signal()
        }
        guard answer.wait(timeout: .now() + timeout + 5) == .success else { return false }
        return allowed.value
    }

    @MainActor
    private static func runAlert(deviceName: String, platform: String, language: AppLanguage) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.icon = NSImage(systemSymbolName: "ipad.and.iphone", accessibilityDescription: nil)
        alert.messageText = String(
            format: language.localized("Allow “%@” to read your shared LokalBot data?"), deviceName)
        alert.informativeText = String(
            format: language.localized("This %@ scanned the code in Settings → Phones & tablets. It will receive an encrypted copy of what you share, over your local network or Tailscale. You can remove it at any time."),
            platform)
        alert.addButton(withTitle: language.localized("Allow"))
        alert.addButton(withTitle: language.localized("Don't Allow"))
        NSApp.activate(ignoringOtherApps: true)
        // An unanswered prompt expires with the device's pairing request.
        let expiry = Timer(timeInterval: timeout, repeats: false) { _ in
            NSApp.abortModal()
        }
        RunLoop.main.add(expiry, forMode: .modalPanel)
        defer { expiry.invalidate() }
        return alert.runModal() == .alertFirstButtonReturn
    }

    private final class LockedFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = false
        var value: Bool {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }
}

/// The QR code shown by "Add a device": the host's pairing payload.
enum CompanionQRCode {
    static func image(for payload: String, size: CGFloat = 220) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage, output.extent.width > 0 else { return nil }
        let scale = max(1, (size / output.extent.width).rounded(.down))
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cgImage = CIContext(options: [.useSoftwareRenderer: false])
            .createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: scaled.extent.width, height: scaled.extent.height))
    }
}

/// Advertises the listener as `_lokalbot._tcp` on the local network with a
/// neutral instance name, `LokalBot-XXXX`, and the key fingerprint in its TXT
/// record, so paired devices recognize this Mac without learning who owns it.
/// Uses the DNS-SD API directly: the listener itself lives in the sync host.
final class CompanionBonjourAdvertiser {
    static let serviceType = "_lokalbot._tcp"

    private var service: DNSServiceRef?

    var isAdvertising: Bool { service != nil }

    static func instanceName(fingerprint: String) -> String {
        "LokalBot-" + String(fingerprint.prefix(4)).uppercased()
    }

    /// One length-prefixed `k=<fingerprint>` entry.
    static func txtRecord(fingerprint: String) -> Data {
        let entry = Data("k=\(fingerprint.prefix(16))".utf8)
        return Data([UInt8(entry.count)]) + entry
    }

    func start(port: Int, fingerprint: String) {
        stop()
        guard let networkPort = UInt16(exactly: port) else { return }
        let txt = Self.txtRecord(fingerprint: fingerprint)
        var reference: DNSServiceRef?
        let status = txt.withUnsafeBytes { bytes in
            DNSServiceRegister(
                &reference, 0, 0, Self.instanceName(fingerprint: fingerprint), Self.serviceType,
                nil, nil, networkPort.bigEndian, UInt16(txt.count), bytes.baseAddress,
                { _, _, error, _, _, _, _ in
                    if error != kDNSServiceErr_NoError {
                        lokalbotLog("companion Bonjour registration failed: \(error)")
                    }
                }, nil)
        }
        guard status == kDNSServiceErr_NoError, let reference else {
            lokalbotLog("companion Bonjour registration could not start: \(status)")
            return
        }
        DNSServiceSetDispatchQueue(reference, .main)
        service = reference
    }

    func stop() {
        guard let service else { return }
        DNSServiceRefDeallocate(service)
        self.service = nil
    }

    deinit { stop() }
}

/// How a paired device last reached the Mac, for the device list.
enum CompanionNetwork {
    case tailscale, localNetwork

    var label: String {
        switch self {
        case .tailscale: "Tailscale"
        case .localNetwork: "Local network"
        }
    }

    /// Tailscale hands out `100.64.0.0/10` and `fd7a:115c:a1e0::/48`.
    static func classify(_ address: String) -> Self? {
        var host = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return nil }
        if host.hasPrefix("["), let close = host.firstIndex(of: "]") {
            host = String(host[host.index(after: host.startIndex)..<close])
        } else if host.filter({ $0 == ":" }).count == 1, let colon = host.firstIndex(of: ":") {
            host = String(host[..<colon])
        }
        if host.lowercased().hasPrefix("::ffff:") { host = String(host.dropFirst(7)) }
        let octets = host.split(separator: ".").compactMap { UInt8($0) }
        if octets.count == 4 {
            return octets[0] == 100 && (64...127).contains(octets[1]) ? .tailscale : .localNetwork
        }
        return host.lowercased().hasPrefix("fd7a:115c:a1e0:") ? .tailscale : .localNetwork
    }
}
