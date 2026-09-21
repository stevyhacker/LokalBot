import CoreGraphics
import CoreText
import XCTest
@testable import LokalBot

/// Offline drawn shape fixtures. These prove detector rejection rules, not
/// compatibility with a live Meet layout, OCR accuracy, or voice accuracy.
final class MeetingSpeakerVisualDetectorTests: XCTestCase {
    func testThemedOutlineNeedsFourEdgesAndRejectsSolidImages() throws {
        for color in [CGColor(red: 1, green: 0.70, blue: 0.61, alpha: 1),
                      CGColor(red: 0.4, green: 0.7, blue: 1, alpha: 1)] {
            let context = try XCTUnwrap(CGContext(data: nil, width: 800, height: 600, bitsPerComponent: 8,
                bytesPerRow: 3200, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(CGColor(gray: 0.12, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 800, height: 600))
            context.setStrokeColor(color)
            context.setLineWidth(3)
            context.stroke(CGRect(x: 4, y: 4, width: 792, height: 592))
            XCTAssertTrue(MeetingSpeakerFrameSource.hasSpeakingOutline(try XCTUnwrap(context.makeImage())))
            context.setFillColor(color)
            context.fill(CGRect(x: 0, y: 0, width: 800, height: 600))
            XCTAssertFalse(MeetingSpeakerFrameSource.hasSpeakingOutline(try XCTUnwrap(context.makeImage())))
        }
    }

    func testPeopleBadgeRequiresThreeSeparateAudioGlyphs() throws {
        for bars in [0, 1, 2, 3, 4] {
            let context = try XCTUnwrap(CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8,
                bytesPerRow: 128, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(CGColor(gray: 0.12, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
            context.setFillColor(CGColor(red: 0.7, green: 0.8, blue: 1, alpha: 1))
            context.fillEllipse(in: CGRect(x: 3, y: 3, width: 26, height: 26))
            context.setFillColor(CGColor(gray: 0.08, alpha: 1))
            for index in 0..<bars {
                let height = index == 1 ? 9 : 4
                context.fill(CGRect(x: 8 + index * 5, y: 16 - height / 2, width: 3, height: height))
            }
            XCTAssertEqual(MeetingSpeakerFrameSource.hasSpeakingBadge(try XCTUnwrap(context.makeImage())), bars == 3)
        }
    }

    func testRestingAudioDotsAreNotSpeaking() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8,
            bytesPerRow: 128, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.7, green: 0.8, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        context.setFillColor(CGColor(gray: 0.08, alpha: 1))
        for x in [8, 13, 18] { context.fill(CGRect(x: x, y: 14, width: 3, height: 4)) }
        XCTAssertFalse(MeetingSpeakerFrameSource.hasSpeakingBadge(try XCTUnwrap(context.makeImage())))
    }

    func testOCRNamesSilentTilesWithoutRequiringAnActiveIndicator() throws {
        for (width, height) in [(300, 180), (1000, 700)] {
            let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(CGColor(gray: 0.12, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let text = NSAttributedString(string: "Jonathan", attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 18, nil),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1)
            ])
            context.textPosition = CGPoint(x: 12, y: 14)
            CTLineDraw(CTLineCreateWithAttributedString(text), context)
            let image = try XCTUnwrap(context.makeImage())
            XCTAssertTrue(MeetingSpeakerFrameSource.recognizesName("Jonathan", in: image))
            XCTAssertFalse(MeetingSpeakerFrameSource.recognizesName("Someone Else", in: image))
            XCTAssertFalse(MeetingSpeakerFrameSource.hasActiveBorderAndEqualizer(image))
        }
    }

    private func tile(border: Bool, equalizer: Bool, light: Bool = false, solidBlue: Bool = false) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 160, height: 100, bitsPerComponent: 8,
            bytesPerRow: 640, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let blue = CGColor(red: 0.2, green: 0.6, blue: 1, alpha: 1)
        context.setFillColor(solidBlue ? blue : CGColor(gray: light ? 1 : 0.12, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 160, height: 100))
        if border {
            context.setStrokeColor(blue)
            context.setLineWidth(4)
            context.stroke(CGRect(x: 2, y: 2, width: 156, height: 96))
        }
        if equalizer {
            context.setFillColor(blue)
            for (x, height) in [(10, 5), (16, 10), (22, 5)] {
                context.fill(CGRect(x: x, y: 10, width: 2, height: height))
            }
        }
        return try XCTUnwrap(context.makeImage())
    }

    func testBorderAndEqualizerContractWorksOnLightAndDarkCameraOffTiles() throws {
        for light in [true, false] {
            XCTAssertTrue(MeetingSpeakerFrameSource.hasActiveBorderAndEqualizer(try tile(border: true, equalizer: true, light: light)))
        }
    }

    func testPinnedSilentPresenterAndArbitraryBluePixelsAreInsufficient() throws {
        for image in [try tile(border: true, equalizer: false), try tile(border: false, equalizer: true),
                      try tile(border: false, equalizer: false, solidBlue: true), try tile(border: false, equalizer: false)] {
            XCTAssertFalse(MeetingSpeakerFrameSource.hasActiveBorderAndEqualizer(image))
        }
    }
}
