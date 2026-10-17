// Seals a file with AES-GCM under a hex key, the way PersonalModelStore
// writes memory/personal-model.json.enc, so upgrade fixtures carry the
// encrypted form a real library has.
// Usage: swift seal.swift <key-hex> <input> <output>
import CryptoKit
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 4 else {
    FileHandle.standardError.write(Data("usage: seal.swift <key-hex> <input> <output>\n".utf8))
    exit(2)
}
var keyBytes: [UInt8] = []
var hex = Substring(arguments[1])
while hex.count >= 2, let byte = UInt8(hex.prefix(2), radix: 16) {
    keyBytes.append(byte)
    hex = hex.dropFirst(2)
}
guard keyBytes.count == 32, hex.isEmpty else {
    FileHandle.standardError.write(Data("seal.swift: the key must be 64 hex characters\n".utf8))
    exit(2)
}
let plaintext = try Data(contentsOf: URL(fileURLWithPath: arguments[2]))
guard let sealed = try AES.GCM.seal(plaintext, using: SymmetricKey(data: keyBytes)).combined else { exit(1) }
try sealed.write(to: URL(fileURLWithPath: arguments[3]), options: .atomic)
