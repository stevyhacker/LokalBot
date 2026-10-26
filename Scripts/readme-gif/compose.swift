// Lays recorded takes out as GIF frames: one flat canvas in the takes' own
// fill colour, a caption per shot, the take's pixels (only cropped or scaled),
// and a ring where each recorded click landed. Writes numbered PNGs for ffmpeg.
//
//   compose <edit.json> <light|dark> <takes-dir> <out-frames-dir>
//
// Takes are read from <takes-dir>/<appearance>/<take>/ as written by rig.
// Build: swiftc -O -swift-version 5 compose.swift -o compose
import AppKit
import ImageIO
import UniformTypeIdentifiers

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data("compose: \(message)\n".utf8))
    exit(1)
}

struct Edit: Decodable {
    struct Theme: Decodable { var text, muted, ring: String }
    struct Shot: Decodable {
        var take: String           // take name, e.g. "recall"
        var from: Double           // seconds into the take
        var to: Double
        var hold: Double?          // extra seconds the frame at `to` stays up
        var caption: String
        var crop: [Double]?        // capture points x, y, w, h
        var radius: Double?        // corner radius in points to restore after a crop
        var scale: Double?         // overrides the edit's scale for this shot
    }
    var canvas: [Int]
    var fps: Double
    var scale: Double              // canvas pixels per capture pixel
    var themes: [String: Theme]
    var captionSize: Double
    var captionTop: Double         // canvas pixels from the top to the caption's first line
    var stageTop: Double           // top of the area takes are centred in
    var footer: String
    var start: Double?             // seconds into the cut where the loop begins
    var shots: [Shot]
}

struct Take {
    let dir: URL
    let stamps: [(index: Int, t: Double)]
    let scale: Double
    let fill: [UInt8]          // the capture's own fill, sampled outside the window corner
    let clicks: [(t: Double, x: Double, y: Double)]

    init(_ dir: URL) {
        self.dir = dir
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("take.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            die("cannot read \(dir.path)/take.json")
        }
        stamps = (json["frames"] as? [[Double]] ?? []).map { (Int($0[0]), $0[1]) }
        guard let first = stamps.first else { die("\(dir.path) has no frames") }
        scale = json["scale"] as? Double ?? 2
        clicks = (json["events"] as? [[String: Any]] ?? []).compactMap { event in
            guard event["kind"] as? String == "click", let t = event["t"] as? Double,
                  let x = event["x"] as? Double, let y = event["y"] as? Double else { return nil }
            return (t, x, y)
        }
        fill = Self.corner(Self.load(dir, first.index))
    }

    /// The top-left pixel, which lies outside the window's rounded corner.
    static func corner(_ image: CGImage) -> [UInt8] {
        var pixel = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        ctx?.draw(image, in: CGRect(x: 0, y: 1 - CGFloat(image.height), width: CGFloat(image.width),
                                    height: CGFloat(image.height)))
        return Array(pixel[0..<3])
    }

    /// The frame on screen at time t: the last one delivered at or before it.
    func frame(at t: Double) -> Int {
        var lo = 0, hi = stamps.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if stamps[mid].t <= t { lo = mid } else { hi = mid - 1 }
        }
        return stamps[lo].index
    }

    func image(_ index: Int) -> CGImage { Self.load(dir, index) }

    static func load(_ dir: URL, _ index: Int) -> CGImage {
        let url = dir.appendingPathComponent(String(format: "frames/%05d.png", index))
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { die("cannot read \(url.path)") }
        return image
    }
}

func color(_ hex: String, alpha: CGFloat = 1) -> NSColor {
    var value: UInt64 = 0
    Scanner(string: hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))).scanHexInt64(&value)
    return NSColor(srgbRed: CGFloat((value >> 16) & 0xff) / 255, green: CGFloat((value >> 8) & 0xff) / 255,
                   blue: CGFloat(value & 0xff) / 255, alpha: alpha)
}

func write(_ image: CGImage, to url: URL) {
    guard let out = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        die("cannot write \(url.path)")
    }
    CGImageDestinationAddImage(out, image, nil)
    CGImageDestinationFinalize(out)
}

let args = CommandLine.arguments
guard args.count == 5 else { die("usage: compose <edit.json> <light|dark> <takes-dir> <out-frames-dir>") }
guard let editData = FileManager.default.contents(atPath: args[1]) else { die("cannot read \(args[1])") }
let edit: Edit
do { edit = try JSONDecoder().decode(Edit.self, from: editData) } catch { die("bad edit: \(error)") }
guard let theme = edit.themes[args[2]] else { die("no theme \(args[2])") }
let takesDir = URL(fileURLWithPath: args[3]).appendingPathComponent(args[2])
let outDir = URL(fileURLWithPath: args[4])
try? FileManager.default.removeItem(at: outDir)
do { try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true) } catch { die("\(error)") }

var takes: [String: Take] = [:]
for shot in edit.shots where takes[shot.take] == nil {
    takes[shot.take] = Take(takesDir.appendingPathComponent(shot.take))
}
let fill = takes[edit.shots[0].take]!.fill
if takes.values.contains(where: { $0.fill != fill }) { die("takes were filmed on different fills") }
let canvasFill = CGColor(srgbRed: CGFloat(fill[0]) / 255, green: CGFloat(fill[1]) / 255, blue: CGFloat(fill[2]) / 255, alpha: 1)

// Each shot plays from..to at recorded speed, then holds its last frame.
var starts: [Double] = []
var total = 0.0
for shot in edit.shots {
    starts.append(total)
    total += (shot.to - shot.from) + (shot.hold ?? 0)
}
let count = Int((total * edit.fps).rounded())
let width = edit.canvas[0], height = edit.canvas[1]
let w = CGFloat(width), h = CGFloat(height)
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let captionFont = NSFont.systemFont(ofSize: edit.captionSize, weight: .semibold)
let footerFont = NSFont.systemFont(ofSize: (edit.captionSize * 0.44).rounded(), weight: .medium)
let footerBand = (footerFont.pointSize * 2.8).rounded()
let centered = NSMutableParagraphStyle()
centered.alignment = .center
var cache: (key: String, image: CGImage)?

for n in 0..<count {
    let cut = (Double(n) / edit.fps + (edit.start ?? 0)).truncatingRemainder(dividingBy: total)
    let i = starts.lastIndex { $0 <= cut + 1e-9 } ?? 0
    let shot = edit.shots[i]
    let take = takes[shot.take]!
    let local = min(shot.from + (cut - starts[i]), shot.to)
    let index = take.frame(at: local)
    let key = "\(shot.take)/\(index)"
    let image: CGImage
    if let cache, cache.key == key { image = cache.image } else {
        image = take.image(index)
        cache = (key, image)
    }

    guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                              space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        die("cannot allocate the canvas")
    }
    ctx.setFillColor(canvasFill)
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))

    // The take, optionally cropped, centred in the stage below the caption.
    let px = CGFloat(take.scale)
    let scale = CGFloat(shot.scale ?? edit.scale)
    let crop = shot.crop.map { CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) }
        ?? CGRect(x: 0, y: 0, width: CGFloat(image.width) / px, height: CGFloat(image.height) / px)
    guard let source = image.cropping(to: CGRect(x: crop.minX * px, y: crop.minY * px,
                                                 width: crop.width * px, height: crop.height * px)) else {
        die("crop \(crop) is outside \(shot.take)")
    }
    let size = CGSize(width: (CGFloat(source.width) * scale).rounded(), height: (CGFloat(source.height) * scale).rounded())
    let stageHeight = h - CGFloat(edit.stageTop) - footerBand
    let origin = CGPoint(x: ((w - size.width) / 2).rounded(),
                         y: (CGFloat(edit.stageTop) + (stageHeight - size.height) / 2).rounded())
    // CG's origin is bottom-left; the layout above is top-left.
    let placed = CGRect(x: origin.x, y: h - origin.y - size.height, width: size.width, height: size.height)
    ctx.saveGState()
    if let radius = shot.radius {
        let r = CGFloat(radius) * px * scale
        ctx.addPath(CGPath(roundedRect: placed, cornerWidth: r, cornerHeight: r, transform: nil))
        ctx.clip()
    }
    ctx.interpolationQuality = .high
    ctx.draw(source, in: placed)
    ctx.restoreGState()

    // Click rings: expand and fade over 0.5 s from the press.
    for click in take.clicks where local >= click.t && local - click.t < 0.5 {
        let progress = CGFloat((local - click.t) / 0.5)
        let radius = (10 + 22 * progress) * px * scale
        let x = origin.x + (CGFloat(click.x) - crop.minX) * px * scale
        let y = origin.y + (CGFloat(click.y) - crop.minY) * px * scale
        ctx.setStrokeColor(color(theme.ring, alpha: 0.9 * (1 - progress)).cgColor)
        ctx.setLineWidth(4 * scale * px / 2)
        ctx.strokeEllipse(in: CGRect(x: x - radius, y: h - y - radius, width: radius * 2, height: radius * 2))
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    let caption = NSAttributedString(string: shot.caption, attributes: [
        .font: captionFont, .foregroundColor: color(theme.text), .paragraphStyle: centered, .kern: -0.5,
    ])
    let captionHeight = caption.size().height
    caption.draw(in: CGRect(x: 0, y: h - CGFloat(edit.captionTop) - captionHeight, width: w, height: captionHeight))
    let footer = NSAttributedString(string: edit.footer, attributes: [
        .font: footerFont, .foregroundColor: color(theme.muted), .paragraphStyle: centered,
    ])
    let footerHeight = footer.size().height
    footer.draw(in: CGRect(x: 0, y: ((footerBand - footerHeight) / 2).rounded(), width: w, height: footerHeight))
    NSGraphicsContext.restoreGraphicsState()

    guard let frame = ctx.makeImage() else { die("cannot render frame \(n)") }
    write(frame, to: outDir.appendingPathComponent(String(format: "%05d.png", n)))
}
print(String(format: "compose: %d frames, %.2fs at %.0f fps", count, total, edit.fps))
