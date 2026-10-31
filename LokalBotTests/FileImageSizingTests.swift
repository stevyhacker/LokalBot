import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import LokalBot

/// The media embedder has to see the pixels the reference sees: transformers'
/// resize target, then Pillow's bicubic. The fixtures are DigUp's
/// (`Tests/LlamaRuntimeTests/ImageSizingTests.swift`, MIT), made with PIL.
final class FileImageSizingTests: XCTestCase {
    func testAZeroSidedImageHasNoTargetSize() {
        XCTAssertNil(FileImageSizing.targetSize(height: 0, width: 1440, budget: 140))
        XCTAssertNil(FileImageSizing.targetSize(height: 900, width: 0, budget: 140))
    }

    func testTargetSizeFillsTheBudget() {
        // A 1440×900 screenshot and a 768×768 photo, at the budgets the indexer uses.
        assertSize(height: 900, width: 1440, budget: 280, is: (624, 1008))
        assertSize(height: 900, width: 1440, budget: 140, is: (432, 672))
        assertSize(height: 900, width: 1440, budget: 70, is: (288, 480))
        assertSize(height: 768, width: 768, budget: 280, is: (768, 768))
        assertSize(height: 768, width: 768, budget: 140, is: (528, 528))
        // Small images grow to fill the budget, as in the reference.
        assertSize(height: 300, width: 300, budget: 140, is: (528, 528))
    }

    func testTargetSizeOfAThinImage() {
        // One side rounds to zero: it gets one 48 px row, the other side capped at the budget.
        assertSize(height: 10, width: 4000, budget: 140, is: (48, 6720))
    }

    /// A 7×5 image resized by PIL (`Image.resize`, BICUBIC).
    private static let source: [UInt8] = [0, 115, 230, 3, 118, 233, 6, 121, 236, 9, 124, 239, 12, 127, 242, 15, 130,
        245, 18, 133, 248, 77, 192, 51, 80, 195, 54, 83, 198, 57, 86, 201, 60, 89, 204, 63, 92, 207, 66, 95, 210, 69,
        154, 13, 128, 157, 16, 131, 160, 19, 134, 163, 22, 137, 166, 25, 140, 169, 28, 143, 172, 31, 146, 231, 90, 205,
        234, 93, 208, 237, 96, 211, 240, 99, 214, 243, 102, 217, 246, 105, 220, 249, 108, 223, 52, 167, 26, 55, 170, 29,
        58, 173, 32, 61, 176, 35, 64, 179, 38, 67, 182, 41, 70, 185, 44]

    func testShrinkMatchesPillow() {
        let pil: [UInt8] = [28, 151, 152, 33, 156, 157, 39, 162, 163, 44, 167, 168, 165, 68, 129, 170, 73, 134, 176, 79,
            140, 181, 84, 145, 132, 133, 106, 137, 138, 111, 143, 144, 117, 148, 149, 122]
        XCTAssertEqual(resize(toWidth: 4, toHeight: 3), pil)
    }

    func testGrowMatchesPillow() {
        let pil: [UInt8] = [0, 112, 237, 0, 113, 238, 1, 116, 241, 3, 118, 243, 5, 120, 245, 7, 122, 247, 9, 124, 249,
            11, 126, 251, 14, 129, 254, 15, 130, 255, 55, 187, 85, 56, 188, 86, 59, 191, 89, 61, 193, 91, 63, 195, 93,
            65, 197, 95, 67, 199, 97, 69, 201, 99, 72, 204, 102, 73, 205, 103, 122, 82, 83, 123, 83, 84, 126, 86, 87,
            128, 88, 89, 130, 90, 91, 132, 92, 93, 134, 94, 95, 136, 96, 97, 139, 99, 100, 140, 100, 101, 199, 27, 173,
            200, 28, 174, 203, 31, 177, 205, 33, 179, 207, 35, 181, 209, 37, 183, 211, 39, 185, 213, 41, 187, 216, 44,
            190, 217, 45, 191, 197, 112, 171, 198, 113, 172, 201, 116, 175, 203, 118, 177, 205, 120, 179, 207, 122, 181,
            209, 124, 183, 211, 126, 185, 214, 129, 188, 215, 130, 189, 45, 170, 19, 46, 171, 20, 49, 174, 23, 51, 176,
            25, 53, 178, 27, 55, 180, 29, 57, 182, 31, 59, 184, 33, 62, 187, 36, 63, 188, 37]
        XCTAssertEqual(resize(toWidth: 10, toHeight: 6), pil)
    }

    func testOneAxisMatchesPillow() {
        let pil: [UInt8] = [74, 120, 137, 77, 123, 140, 80, 126, 143, 83, 129, 146, 86, 132, 149, 89, 135, 152, 92, 138,
            155, 153, 100, 119, 156, 103, 122, 159, 106, 125, 162, 109, 128, 165, 112, 131, 168, 115, 134, 171, 118,
            137]
        XCTAssertEqual(resize(toWidth: 7, toHeight: 2), pil)
        XCTAssertEqual(resize(toWidth: 7, toHeight: 5), Self.source)
    }

    /// The PNG the embedder sends is the budget's size and carries the file's
    /// pixels unchanged when no resize is needed.
    func testPNGIsSizedForTheBudgetAndKeepsPixels() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let width = 768, height = 768
        var pixels = [UInt8](repeating: 0, count: width * height * 3)
        for index in 0..<(width * height) {
            pixels[index * 3] = UInt8(index % 251)
            pixels[index * 3 + 1] = UInt8((index / width) % 256)
            pixels[index * 3 + 2] = UInt8((index * 7) % 253)
        }
        let file = folder.appendingPathComponent("square.png")
        try writePNG(pixels, width: width, height: height, to: file)

        let same = try decode(FileImageSizing.png(ofImageAt: file, budget: 280))
        XCTAssertEqual(same.width, 768)
        XCTAssertEqual(same.height, 768)
        XCTAssertEqual(same.rgb, pixels)

        let smaller = try decode(FileImageSizing.png(ofImageAt: file, budget: 140))
        XCTAssertEqual(smaller.width, 528)
        XCTAssertEqual(smaller.height, 528)
        let expected = pixels.withUnsafeBufferPointer {
            FileImageSizing.resizeBicubic($0.baseAddress!, width: width, height: height, toWidth: 528, toHeight: 528)
        }
        XCTAssertEqual(smaller.rgb, expected)
    }

    func testUnsupportedBudgetAndUnreadableFileThrow() {
        let missing = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).png")
        XCTAssertThrowsError(try FileImageSizing.png(ofImageAt: missing, budget: 333)) {
            XCTAssertEqual($0 as? FileImageSizing.SizingError, .unsupportedBudget(333))
        }
        XCTAssertThrowsError(try FileImageSizing.png(ofImageAt: missing, budget: 140)) {
            XCTAssertEqual($0 as? FileImageSizing.SizingError, .unreadable)
        }
    }

    // MARK: - Helpers

    private func assertSize(height: Int, width: Int, budget: Int, is expected: (Int, Int),
                            file: StaticString = #filePath, line: UInt = #line) {
        guard let size = FileImageSizing.targetSize(height: height, width: width, budget: budget) else {
            return XCTFail("no target size", file: file, line: line)
        }
        XCTAssertEqual(size.height, expected.0, file: file, line: line)
        XCTAssertEqual(size.width, expected.1, file: file, line: line)
    }

    private func resize(toWidth: Int, toHeight: Int) -> [UInt8] {
        Self.source.withUnsafeBufferPointer {
            FileImageSizing.resizeBicubic($0.baseAddress!, width: 7, height: 5, toWidth: toWidth, toHeight: toHeight)
        }
    }

    private func writePNG(_ rgb: [UInt8], width: Int, height: Int, to url: URL) throws {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let provider = try XCTUnwrap(CGDataProvider(data: Data(rgb) as CFData))
        let image = try XCTUnwrap(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 24, bytesPerRow: width * 3,
            space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    /// Decodes PNG bytes back to packed RGB without colour conversion.
    private func decode(_ png: Data) throws -> (width: Int, height: Int, rgb: [UInt8]) {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let space = try XCTUnwrap(image.colorSpace)
        var rgba = [UInt8](repeating: 0, count: image.width * image.height * 4)
        rgba.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        var rgb: [UInt8] = []
        rgb.reserveCapacity(image.width * image.height * 3)
        for index in 0..<(image.width * image.height) {
            rgb += [rgba[index * 4], rgba[index * 4 + 1], rgba[index * 4 + 2]]
        }
        return (image.width, image.height, rgb)
    }
}
