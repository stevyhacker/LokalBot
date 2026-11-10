import CryptoKit
import Foundation

/// The Mac's pairing code: `lokalbot://pair?d=<base64url(JSON)>` (protocol.md,
/// Pairing). Parsed here only to show what the phone is about to pair with;
/// the sync core checks it again before it connects.
public struct PairingPayload: Sendable, Hashable {
    public var version: Int
    public var macName: String
    /// Base64url X25519 public key.
    public var macKey: String
    public var addresses: [String]
    public var port: UInt16
    public var expiresAt: Date

    public enum ParseError: Error, Equatable, LocalizedError {
        case notAPairingLink
        case unreadable
        case unsupportedVersion(Int)

        public var errorDescription: String? {
            switch self {
            case .notAPairingLink: "This isn't a LokalBot pairing link. On your computer, open Settings → Phones & tablets → Add a device."
            case .unreadable: "The pairing link is incomplete. Scan the code on your computer again."
            case .unsupportedVersion: "This pairing link needs a newer version of LokalBot on this device."
            }
        }
    }

    private struct Body: Decodable {
        let v: Int
        let macName: String
        let macKey: String
        let addrs: [String]
        let port: UInt16
        let pid: String
        let psk: String
        let exp: Double
    }

    /// What every pairing link starts with, as the sync core checks it.
    private static let linkPrefix = "lokalbot://pair?"

    /// A code this long past its expiry on this device's clock still goes to
    /// the sync core, which allows the same (`EXPIRY_GRACE_SECS`): the
    /// computer's clock decides, so a phone that runs fast doesn't refuse a
    /// code the computer would take.
    static let expiryGrace: TimeInterval = 120

    /// The pairing link inside `text`, alone and with its scheme in lowercase:
    /// the form the sync core takes. Nil when the text holds no link.
    public static func link(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = trimmed.range(of: linkPrefix, options: .caseInsensitive) else { return nil }
        return linkPrefix + trimmed[start.upperBound...].prefix { !$0.isWhitespace }
    }

    /// Accepts the link itself or text that contains it, as pasted from a
    /// message or a note.
    public static func parse(_ text: String) throws -> PairingPayload {
        guard let link = Self.link(in: text) else {
            throw ParseError.notAPairingLink
        }
        guard let components = URLComponents(string: link),
              let encoded = components.queryItems?.first(where: { $0.name == "d" })?.value,
              let data = Base64URL.decode(encoded),
              let body = try? JSONDecoder().decode(Body.self, from: data) else {
            throw ParseError.unreadable
        }
        guard body.v == 1 else { throw ParseError.unsupportedVersion(body.v) }
        guard Base64URL.decode(body.macKey)?.count == 32, Base64URL.decode(body.psk)?.count == 32 else {
            throw ParseError.unreadable
        }
        return PairingPayload(
            version: body.v, macName: body.macName, macKey: body.macKey, addresses: body.addrs,
            port: body.port, expiresAt: Date(timeIntervalSince1970: body.exp))
    }

    public func isExpired(at now: Date = Date()) -> Bool {
        now > expiresAt.addingTimeInterval(Self.expiryGrace)
    }
}

/// The short key hash the Mac advertises in its Bonjour TXT record (`k=`):
/// the first 16 hex characters of SHA-256 of its static public key.
public enum KeyFingerprint {
    public static func fingerprint(publicKey: Data) -> String {
        SHA256.hash(data: publicKey).map { String(format: "%02x", $0) }.joined().prefix(16).lowercased()
    }

    /// For a key as the pairing code or `PairedMac` carries it, in base64 or base64url.
    public static func fingerprint(base64Key: String) -> String? {
        Base64URL.decode(base64Key).map { fingerprint(publicKey: $0) }
    }
}

public enum Base64URL {
    /// Decodes base64url or standard base64, with or without padding.
    public static func decode(_ text: String) -> Data? {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 = base64.trimmingCharacters(in: CharacterSet(charactersIn: "="))
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }

    public static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }
}
