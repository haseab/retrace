import XCTest
import CoreGraphics
@testable import Capture

final class AccessibilityPixelVisibilityTests: XCTestCase {
    private func image(_ pixels: [UInt8], width: Int = 2, height: Int = 2) -> CGImage {
        CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: CGDataProvider(data: Data(pixels) as CFData)!, decode: nil,
                shouldInterpolate: false, intent: .defaultIntent)!
    }
    private let white: [UInt8] = Array(repeating: 255, count: 16)
    private let bounds = CGRect(x: 0, y: 0, width: 2, height: 2)

    func testIdenticalCapturedPixelsSurviveAnOverlappingWindowRectangle() {
        var budget = 4
        XCTAssertTrue(AccessibilityPixelVisibility.matches(captured: image(white), window: image(white),
                                                          rect: bounds, remainingPixels: &budget))
        XCTAssertEqual(budget, 0)
    }
    func testEvenOneCoveredPixelRejectsTheWholeTextElement() {
        var covered = white; covered[0] = 0; covered[1] = 0; covered[2] = 0
        var budget = 4
        XCTAssertFalse(AccessibilityPixelVisibility.matches(captured: image(covered), window: image(white),
                                                           rect: bounds, remainingPixels: &budget))
    }
    func testOcclusionOutsideTextRegionDoesNotRejectVisibleText() {
        var covered = white; covered[0] = 0; covered[1] = 0; covered[2] = 0
        var budget = 4
        XCTAssertTrue(AccessibilityPixelVisibility.matches(captured: image(covered), window: image(white),
            rect: CGRect(x: 1, y: 0, width: 1, height: 2), remainingPixels: &budget))
    }
    func testTransparentReferenceCannotProveTextVisibility() {
        var budget = 4
        XCTAssertFalse(AccessibilityPixelVisibility.matches(captured: image(white),
            window: image(Array(repeating: 0, count: 16)), rect: bounds, remainingPixels: &budget))
    }
    func testUnverifiableGeometryAndBudgetFailClosed() {
        var budget = 3
        XCTAssertFalse(AccessibilityPixelVisibility.matches(captured: image(white), window: image(white),
                                                           rect: bounds, remainingPixels: &budget))
        budget = 4
        XCTAssertFalse(AccessibilityPixelVisibility.matches(captured: image(white),
            window: image(Array(white.prefix(8)), width: 1), rect: bounds, remainingPixels: &budget))
        XCTAssertFalse(AccessibilityPixelVisibility.matches(captured: image(white), window: image(white),
            rect: bounds.offsetBy(dx: -1, dy: 0), remainingPixels: &budget))
    }
}
