import Foundation
import ImageIO
import Vision

struct Screen: Decodable {
    let id: String
    let image: String
}
struct Fixture: Decodable { let documents: [Screen] }
struct OCRResult: Encodable {
    let id: String
    let text: String
    let seconds: Double
}

let args = CommandLine.arguments
guard args.count == 3 else { fatalError("Usage: vision <screens.json> <output.json>") }
let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
var results: [OCRResult] = []
for document in fixture.documents {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: document.image) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        fatalError("Could not load synthetic fixture: \(document.id)")
    }
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    request.automaticallyDetectsLanguage = true
    let start = DispatchTime.now().uptimeNanoseconds
    try VNImageRequestHandler(cgImage: image).perform([request])
    let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
    let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    results.append(OCRResult(id: document.id, text: text, seconds: elapsed))
}
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
try encoder.encode(results).write(to: URL(fileURLWithPath: args[2]))
print("Apple Vision: \(results.count) synthetic screens")
