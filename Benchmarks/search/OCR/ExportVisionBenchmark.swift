import AppKit
import CryptoKit
import Foundation
import UniformTypeIdentifiers
import Security
import Vision

struct ScreenshotRow {
    let id: String
    let app: String
    let path: String
}

func usage() -> Never {
    fputs("Usage: ExportVisionBenchmark.swift <manifest.tsv> <new-output-dir> --allow-decrypt-private-screen-data\n", stderr)
    exit(2)
}

let args = CommandLine.arguments
guard args.count == 4, args[3] == "--allow-decrypt-private-screen-data" else { usage() }

let manifestURL = URL(fileURLWithPath: args[1])
let outputDir = URL(fileURLWithPath: args[2], isDirectory: true)
guard !FileManager.default.fileExists(atPath: outputDir.path) else {
    fputs("Refusing an existing export directory. Choose a new private fixture directory.\n", stderr)
    exit(2)
}
umask(0o077)
try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true,
                                      attributes: [.posixPermissions: 0o700])
try Data("Decrypted private screen fixtures. Delete this entire directory after review; application retention does not clean it.\n".utf8)
    .write(to: outputDir.appendingPathComponent(".private-screen-fixtures"), options: .atomic)

func keychainData(service: String, account: String) -> Data? {
    var query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
    ]
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var existing: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &existing) == errSecSuccess else {
        return nil
    }
    return existing as? Data
}

guard let keyData = keychainData(service: "me.dotenv.LokalBot", account: "screenshot-key") else {
    fputs("Could not read screenshot key from Keychain.\n", stderr)
    exit(1)
}
let key = SymmetricKey(data: keyData)

let manifest = try String(contentsOf: manifestURL, encoding: .utf8)
let rows = manifest.split(separator: "\n").compactMap { line -> ScreenshotRow? in
    let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
    guard fields.count == 3 else { return nil }
    return ScreenshotRow(id: String(fields[0]), app: String(fields[1]), path: String(fields[2]))
}
guard !rows.isEmpty, rows.allSatisfy({ $0.id.range(of: "^[0-9]+$", options: .regularExpression) != nil }) else {
    fputs("Manifest must contain numeric screenshot IDs and explicit encrypted file paths.\n", stderr)
    exit(2)
}

func recognizeText(in image: CGImage) throws -> String {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    try VNImageRequestHandler(cgImage: image).perform([request])
    return (request.results ?? [])
        .compactMap { $0.topCandidates(1).first?.string }
        .joined(separator: "\n")
}

func imageData(from image: CGImage, type: CFString) throws -> Data {
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, type, 1, nil) else {
        throw NSError(domain: "OCRBenchmark", code: 1)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw NSError(domain: "OCRBenchmark", code: 2)
    }
    return data as Data
}

print("id\tapp\twidth\theight\tvision_ms\tchars\tpng_path\tvision_text_path")

for row in rows {
    let encrypted = try Data(contentsOf: URL(fileURLWithPath: row.path))
    let box = try AES.GCM.SealedBox(combined: encrypted)
    let imageBytes = try AES.GCM.open(box, using: key)
    guard let nsImage = NSImage(data: imageBytes),
          let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        fputs("Could not decode image for row \(row.id)\n", stderr)
        continue
    }

    let start = DispatchTime.now().uptimeNanoseconds
    let text = try recognizeText(in: cgImage)
    let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000.0

    let base = "shot-\(row.id)"
    let pngURL = outputDir.appendingPathComponent("\(base).png")
    let textURL = outputDir.appendingPathComponent("\(base).vision.txt")
    try imageData(from: cgImage, type: UTType.png.identifier as CFString).write(to: pngURL, options: .atomic)
    try text.write(to: textURL, atomically: true, encoding: .utf8)

    print("\(row.id)\t\(row.app)\t\(cgImage.width)\t\(cgImage.height)\t\(String(format: "%.1f", elapsed))\t\(text.count)\t\(pngURL.path)\t\(textURL.path)")
}
