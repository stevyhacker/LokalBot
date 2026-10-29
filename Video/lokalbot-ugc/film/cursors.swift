// Saves macOS's own pointer images (arrow, pointing hand, I-beam) at 4x with
// their hot spots, so the edit draws the real system pointer where the take's
// pointer track says it was (the recordings leave it out).
//
//   swift cursors.swift <out-dir>     writes <name>.png and cursors.json
import AppKit

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: swift cursors.swift <out-dir>\n".utf8))
    exit(2)
}
let out = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let scale = 4.0
var listing: [String: Any] = ["scale": scale]
for (name, cursor) in [("arrow", NSCursor.arrow), ("hand", NSCursor.pointingHand), ("ibeam", NSCursor.iBeam)] {
    let size = cursor.image.size
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
                                     pixelsHigh: Int(size.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                                     hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else { continue }
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    cursor.image.draw(in: NSRect(origin: .zero, size: size))
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("\(name).png"))
    listing[name] = ["size": [size.width, size.height], "hotSpot": [cursor.hotSpot.x, cursor.hotSpot.y]]
}
let json = try JSONSerialization.data(withJSONObject: listing, options: [.prettyPrinted, .sortedKeys])
try json.write(to: out.appendingPathComponent("cursors.json"))
print("cursors: \(out.path)")
