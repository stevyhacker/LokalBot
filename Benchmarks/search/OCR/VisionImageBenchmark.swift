import AppKit
import Foundation
import Vision

struct Row {
    let id: String
    let app: String
    let imagePath: String
    let truthPath: String
}

func usage() -> Never {
    fputs("Usage: VisionImageBenchmark.swift <synthetic-manifest.tsv> <output-dir>\n", stderr)
    exit(2)
}

let args = CommandLine.arguments
guard args.count == 3 else { usage() }

let manifestURL = URL(fileURLWithPath: args[1])
let outputDir = URL(fileURLWithPath: args[2], isDirectory: true)
try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

func loadRows(from manifestURL: URL) throws -> [Row] {
    let contents = try String(contentsOf: manifestURL, encoding: .utf8)
    return contents.components(separatedBy: .newlines).compactMap { line in
        if line.isEmpty {
            return nil
        }
        if line.hasPrefix("id\t") {
            return nil
        }
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
        guard fields.count == 4 else {
            return nil
        }
        return Row(
            id: String(fields[0]),
            app: String(fields[1]),
            imagePath: String(fields[2]),
            truthPath: String(fields[3])
        )
    }
}

func cgImage(from path: String) -> CGImage? {
    guard let nsImage = NSImage(contentsOfFile: path) else {
        return nil
    }
    var rect = CGRect(origin: .zero, size: nsImage.size)
    return nsImage.cgImage(forProposedRect: &rect, context: nil, hints: nil)
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

let rows = try loadRows(from: manifestURL)
print("engine\tid\tapp\tinfer_ms\tchars\toutput_path\ttruth_path\tpng_path")

for row in rows {
    guard let image = cgImage(from: row.imagePath) else {
        fputs("Could not decode image for row \(row.id): \(row.imagePath)\n", stderr)
        continue
    }

    let start = DispatchTime.now().uptimeNanoseconds
    let text = try recognizeText(in: image)
    let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000.0

    let outputURL = outputDir.appendingPathComponent("\(row.id).apple-vision.txt")
    try text.write(to: outputURL, atomically: true, encoding: .utf8)
    print("apple-vision\t\(row.id)\t\(row.app)\t\(String(format: "%.1f", elapsed))\t\(text.count)\t\(outputURL.path)\t\(row.truthPath)\t\(row.imagePath)")
}
