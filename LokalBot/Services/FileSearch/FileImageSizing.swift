import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Sizes a picture for EmbeddingGemma 2's vision encoder the way the model's
/// reference processor does, so the media embedder sees the pixels DigUp's
/// reference vectors were made from. Ported from DigUp's `ImageSizing`
/// (github.com/ARahim3/DigUp, MIT; see THIRD_PARTY_NOTICES.md).
///
/// The media embedder runs llama-server with `--image-min-tokens 1
/// --image-max-tokens 1120`, so llama.cpp never rescales an image that already
/// has its final size: each image's token budget is set here. Left to size
/// images itself, llama.cpp spends about twice the tokens and the vectors
/// drift from the reference (Benchmarks/EmbeddingGemma2/2026-10-30-media-embedder).
enum FileImageSizing {
    /// Soft-token budgets the encoder accepts.
    static let budgets = [70, 140, 280, 560, 1120]

    enum SizingError: Error, Equatable {
        case unreadable
        case tooThin
        case unsupportedBudget(Int)
    }

    /// transformers' Gemma 4 image processor: scale to fill `budget` soft
    /// tokens (each 3 × 3 patches of 16 px) keeping the aspect ratio, each side
    /// rounded down to a multiple of 48 px. Nil for an image with no area.
    static func targetSize(height: Int, width: Int, budget: Int) -> (height: Int, width: Int)? {
        guard height > 0, width > 0 else { return nil }
        let patch = 16, pooling = 3
        let maxPatches = budget * pooling * pooling
        let factor = (Double(maxPatches * patch * patch) / Double(height * width)).squareRoot()
        let side = pooling * patch
        var targetHeight = Int((factor * Double(height) / Double(side)).rounded(.down)) * side
        var targetWidth = Int((factor * Double(width) / Double(side)).rounded(.down)) * side
        if targetHeight == 0 && targetWidth == 0 { return nil }
        let maxSide = (maxPatches / (pooling * pooling)) * side
        if targetHeight == 0 {
            targetHeight = side
            targetWidth = min(width / height * side, maxSide)
        } else if targetWidth == 0 {
            targetWidth = side
            targetHeight = min(height / width * side, maxSide)
        }
        return (targetHeight, targetWidth)
    }

    /// The image at `url` as a PNG resized for `budget`. Pixels keep the file's
    /// own colour values, as llama.cpp's decoder reads them: no colour-space
    /// conversion unless the file is not RGB.
    static func png(ofImageAt url: URL, budget: Int) throws -> Data {
        guard budgets.contains(budget) else { throw SizingError.unsupportedBudget(budget) }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(
                  source, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { throw SizingError.unreadable }
        guard let target = targetSize(height: image.height, width: image.width, budget: budget) else {
            throw SizingError.tooThin
        }
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
            ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let pixels = try rgbPixels(of: image, space: space)
        let sized = target == (image.height, image.width)
            ? pixels
            : pixels.withUnsafeBufferPointer {
                resizeBicubic($0.baseAddress!, width: image.width, height: image.height,
                              toWidth: target.width, toHeight: target.height)
            }
        return try pngData(rgb: sized, width: target.width, height: target.height, space: space)
    }

    /// Packed 8-bit RGB, drawn in `space` so RGB files are not converted.
    private static func rgbPixels(of image: CGImage, space: CGColorSpace) throws -> [UInt8] {
        let width = image.width, height = image.height
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw SizingError.unreadable }
        var rgb = [UInt8](repeating: 0, count: width * height * 3)
        for index in 0..<(width * height) {
            rgb[index * 3] = rgba[index * 4]
            rgb[index * 3 + 1] = rgba[index * 4 + 1]
            rgb[index * 3 + 2] = rgba[index * 4 + 2]
        }
        return rgb
    }

    private static func pngData(rgb: [UInt8], width: Int, height: Int, space: CGColorSpace) throws -> Data {
        guard let provider = CGDataProvider(data: Data(rgb) as CFData),
              let image = CGImage(
                  width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 24,
                  bytesPerRow: width * 3, space: space,
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { throw SizingError.unreadable }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData, UTType.png.identifier as CFString, 1, nil) else { throw SizingError.unreadable }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw SizingError.unreadable }
        return data as Data
    }

    // MARK: - Pillow's bicubic resampling

    /// Pillow's bicubic resampling of packed RGB (a = −0.5, the kernel widened
    /// when shrinking, 22-bit fixed point): what the reference gets from PIL's
    /// `Image.resize`. Bit-for-bit with Pillow (see FileImageSizingTests).
    static func resizeBicubic(_ source: UnsafePointer<UInt8>, width: Int, height: Int,
                              toWidth: Int, toHeight: Int) -> [UInt8] {
        switch (toWidth != width, toHeight != height) {
        case (true, true):
            let pass = horizontal(source, width, height, toWidth)
            return pass.withUnsafeBufferPointer { vertical($0.baseAddress!, height, toWidth, toHeight) }
        case (true, false): return horizontal(source, width, height, toWidth)
        case (false, true): return vertical(source, height, width, toHeight)
        case (false, false): return Array(UnsafeBufferPointer(start: source, count: width * height * 3))
        }
    }

    private static let precision: Int32 = 22

    private static func filter(_ value: Double) -> Double {
        let x = abs(value), a = -0.5
        if x < 1 { return ((a + 2) * x - (a + 3)) * x * x + 1 }
        if x < 2 { return (((x - 5) * x + 8) * x - 4) * a }
        return 0
    }

    /// For each output pixel: the first contributing input pixel, how many
    /// contribute, and their weights.
    private static func coefficients(_ inSize: Int, _ outSize: Int) -> (bounds: [Int], weights: [Int32], size: Int) {
        let scale = Double(inSize) / Double(outSize)
        let filterScale = max(scale, 1)
        let support = 2 * filterScale
        let size = Int(support.rounded(.up)) * 2 + 1
        var bounds = [Int](repeating: 0, count: outSize * 2)
        var weights = [Int32](repeating: 0, count: outSize * size)
        var row = [Double](repeating: 0, count: size)
        for out in 0..<outSize {
            let center = (Double(out) + 0.5) * scale
            let first = max(Int(center - support + 0.5), 0)
            let count = min(Int(center + support + 0.5), inSize) - first
            var total = 0.0
            for x in 0..<size {
                row[x] = x < count ? filter((Double(x + first) - center + 0.5) / filterScale) : 0
                total += row[x]
            }
            for x in 0..<size {
                let weight = x < count && total != 0 ? row[x] / total : row[x]
                weights[out * size + x] = Int32(weight * Double(1 << precision) + (weight < 0 ? -0.5 : 0.5))
            }
            bounds[out * 2] = first
            bounds[out * 2 + 1] = count
        }
        return (bounds, weights, size)
    }

    private static func clip(_ value: Int32) -> UInt8 { UInt8(clamping: value >> precision) }

    private static func horizontal(_ source: UnsafePointer<UInt8>, _ inWidth: Int, _ rows: Int,
                                   _ outWidth: Int) -> [UInt8] {
        let (bounds, weights, size) = coefficients(inWidth, outWidth)
        var out = [UInt8](repeating: 0, count: outWidth * rows * 3)
        out.withUnsafeMutableBufferPointer { out in
            weights.withUnsafeBufferPointer { weights in
                for y in 0..<rows {
                    for x in 0..<outWidth {
                        var pixel = source + (y * inWidth + bounds[x * 2]) * 3
                        var red: Int32 = 1 << (precision - 1), green = red, blue = red
                        for k in 0..<bounds[x * 2 + 1] {
                            let weight = weights[x * size + k]
                            red &+= Int32(pixel[0]) &* weight
                            green &+= Int32(pixel[1]) &* weight
                            blue &+= Int32(pixel[2]) &* weight
                            pixel += 3
                        }
                        let offset = (y * outWidth + x) * 3
                        out[offset] = clip(red)
                        out[offset + 1] = clip(green)
                        out[offset + 2] = clip(blue)
                    }
                }
            }
        }
        return out
    }

    private static func vertical(_ source: UnsafePointer<UInt8>, _ inHeight: Int, _ rowWidth: Int,
                                 _ outHeight: Int) -> [UInt8] {
        let (bounds, weights, size) = coefficients(inHeight, outHeight)
        let stride = rowWidth * 3
        var out = [UInt8](repeating: 0, count: stride * outHeight)
        var sums = [Int32](repeating: 0, count: stride)
        out.withUnsafeMutableBufferPointer { out in
            sums.withUnsafeMutableBufferPointer { sums in
                for y in 0..<outHeight {
                    for i in 0..<stride { sums[i] = 1 << (precision - 1) }
                    for k in 0..<bounds[y * 2 + 1] {
                        let row = source + (bounds[y * 2] + k) * stride
                        let weight = weights[y * size + k]
                        for i in 0..<stride { sums[i] &+= Int32(row[i]) &* weight }
                    }
                    for i in 0..<stride { out[y * stride + i] = clip(sums[i]) }
                }
            }
        }
        return out
    }
}
