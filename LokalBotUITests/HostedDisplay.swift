import CoreGraphics
import Foundation
import XCTest

enum HostedDisplay {
    static func prepareForModelLayouts() throws {
        let minimum = CGSize(width: 1600, height: 1000)
        func hasRoom() -> Bool {
            let bounds = CGDisplayBounds(CGMainDisplayID())
            return bounds.width >= minimum.width && bounds.height >= minimum.height
        }
        XCTAssertTrue(UITestHarness.waitUntil(timeout: 8, hasRoom),
                      "Run Scripts/ci/prepare-display.swift before interactive layout tests")
    }
}
