import CoreGraphics
import CoreText
import DigUpKit
import ImageIO
import SQLite3
import UniformTypeIdentifiers
import XCTest
@testable import LokalBot

/// The index size the add-folder sheet projects (`FileIndexSize`) against
/// the index DigUp really writes for a folder of documents, pictures,
/// screenshots, a PDF and a recording, with real-sized vectors.
@MainActor
final class FileIndexSizeTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("index-size-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testTheProjectedIndexSizeIsCloseToTheRealIndex() async throws {
        // About 60 KB of LokalBot's developer notes: real prose, as keyword search sees it.
        let prose = Array(try String(contentsOf: try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "prose", withExtension: "txt", subdirectory: "Fixtures/IndexSize")), encoding: .utf8))
        func slice(_ index: Int, _ length: Int) -> String {
            let start = (index * 104_729) % max(1, prose.count - length)
            return String(prose[start..<(start + length)])
        }
        let empty = try await indexSize(of: "empty") { _ in }
        let folder = root.appendingPathComponent("mixed", isDirectory: true)
        let mixed = try await indexSize(of: "mixed") { folder in
            for index in 0..<40 {
                try slice(index, 9000).write(to: folder.appendingPathComponent("notes-\(index).txt"),
                                             atomically: true, encoding: .utf8)
                try self.writePicture(folder.appendingPathComponent("IMG_\(1000 + index).png"), seed: index)
            }
            for index in 0..<5 {
                try self.writeTextImage(folder.appendingPathComponent("Screenshot 2026-10-2\(index) at 10.00.00.png"),
                                        text: slice(index + 500, 1400))
            }
            try self.writePDF(folder.appendingPathComponent("paper.pdf"), pages: (0..<30).map { slice($0 + 900, 2400) })
            try self.writeTone(folder.appendingPathComponent("talk.wav"), seconds: 600)
        }

        let projected = FileSearchService.estimate(of: [folder.path], excluding: [],
                                                   options: FileSearchService.indexOptions(),
                                                   costsFolder: root.appendingPathComponent("costs"),
                                                   checksSpeed: false).indexBytes
        let written = Double(mixed - empty)
        XCTAssertEqual(projected, written, accuracy: written * 0.2,
                       "projected \(Int(projected)) bytes, the index took \(Int(written))")
    }

    /// The index file's size once `fill`'s folder is read and the log checkpointed.
    private func indexSize(of name: String, fill: (URL) throws -> Void) async throws -> Int64 {
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try fill(folder)
        let index = root.appendingPathComponent("index-\(name)", isDirectory: true)
        let service = FileSearchService(indexFolder: index, startEmbedder: { _ in
            .init(source: NoiseEmbedder.workerInfo.vectorSource, makeEmbedder: { NoiseEmbedder() }, end: {})
        })
        service.apply(.init(enabled: true, folders: [folder.path]))
        await service.waitUntilIdle()
        XCTAssertEqual(service.state, .ready, name)
        let file = index.appendingPathComponent(IndexStore.mainFile)
        let database = try XCTUnwrap(SQLiteDatabase(url: file))
        database.exec("PRAGMA wal_checkpoint(TRUNCATE)")
        return (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int64) ?? 0
    }

    private func writePicture(_ url: URL, seed: Int) throws {
        let width = 800, height = 600
        var rgb = [UInt8](repeating: 0, count: width * height * 3)
        for index in rgb.indices { rgb[index] = UInt8((index / 3 * (seed + 3) + index % 3 * 77) % 251) }
        let image = try XCTUnwrap(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 24, bytesPerRow: width * 3,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: 0),
            provider: try XCTUnwrap(CGDataProvider(data: Data(rgb) as CFData)), decode: nil,
            shouldInterpolate: false, intent: .defaultIntent))
        try write(image, to: url)
    }

    private func writeTextImage(_ url: URL, text: String) throws {
        let width = 1440, height = 900
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        draw(text, in: CGRect(x: 40, y: 40, width: width - 80, height: height - 80), context: context, size: 20)
        try write(try XCTUnwrap(context.makeImage()), to: url)
    }

    private func writePDF(_ url: URL, pages: [String]) throws {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        for page in pages {
            context.beginPDFPage(nil)
            draw(page, in: box.insetBy(dx: 50, dy: 50), context: context, size: 9)
            context.endPDFPage()
        }
        context.closePDF()
    }

    private func draw(_ text: String, in rect: CGRect, context: CGContext, size: CGFloat) {
        let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let attributed = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 0, green: 0, blue: 0, alpha: 1),
        ])
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), CGPath(rect: rect, transform: nil), nil)
        CTFrameDraw(frame, context)
    }

    private func write(_ image: CGImage, to url: URL) throws {
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    private func writeTone(_ url: URL, seconds: Int) throws {
        let rate = 16_000
        var samples = Data(capacity: rate * seconds * 2)
        for index in 0..<(rate * seconds) {
            let value = Int16(sin(Double(index) * 2 * .pi * (300 + Double(index / rate % 7) * 50) / Double(rate)) * 9_000)
            withUnsafeBytes(of: value.littleEndian) { samples.append(contentsOf: $0) }
        }
        var wav = Data("RIFF".utf8)
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) } }
        append(UInt32(36 + samples.count))
        wav.append(Data("WAVEfmt ".utf8))
        append(UInt32(16)); append(UInt16(1)); append(UInt16(1)); append(UInt32(rate))
        append(UInt32(rate * 2)); append(UInt16(2)); append(UInt16(16))
        wav.append(Data("data".utf8))
        append(UInt32(samples.count))
        wav.append(samples)
        try wav.write(to: url)
    }
}

/// Vectors that don't repeat, as the model's don't.
private final class NoiseEmbedder: Embedder {
    static let workerInfo = WorkerInfo(model: "test/noise", revision: "0000000", runtime: "fake", dtype: "f32",
                                       dim: 768, textOnly: false, loadSeconds: nil)
    let info = NoiseEmbedder.workerInfo

    private static func vector(seed: Int) -> [Float] {
        var generator = seed &* 2_654_435_761 | 1
        var vector = (0..<768).map { _ -> Float in
            generator = generator &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(Int32(truncatingIfNeeded: generator >> 32)) / Float(Int32.max)
        }
        let norm = sqrt(vector.reduce(0) { $0 + $1 * $1 })
        vector = vector.map { $0 / norm }
        return vector
    }

    func embedTexts(_ texts: [String]) throws -> [[Float]] { texts.map { Self.vector(seed: $0.hashValue) } }
    func embedImages(_ paths: [String], budget: Int) throws -> [Embedding] {
        paths.map { Embedding(vector: Self.vector(seed: $0.hashValue), error: nil) }
    }
    func embedAudio(_ paths: [String]) throws -> [Embedding] {
        paths.map { Embedding(vector: Self.vector(seed: $0.hashValue), error: nil) }
    }
    func close() {}
}
