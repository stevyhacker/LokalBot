import CryptoKit
import Foundation

enum ContentFingerprint {
    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func fields(_ fields: [String]) -> String {
        var data = Data()
        for field in fields {
            let bytes = Data(field.utf8)
            data.append(Data("\(bytes.count):".utf8))
            data.append(bytes)
        }
        return digest(data)
    }
}
