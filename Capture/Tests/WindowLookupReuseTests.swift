import CoreGraphics
import Foundation
import Shared
import XCTest
@testable import Capture

final class WindowLookupReuseTests: XCTestCase {
    private final class Probe: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.lock(); defer { lock.unlock() }; value += 1 }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    func testSuccessfulArrayCaptureDoesNotRefreshWindowMetadata() async throws {
        let capture = CGWindowListCapture()
        let image = try makeImage()
        let windowLookups = Probe()
        let arrayCaptures = Probe()
        let result = await capture.captureWithFiltering(
            displayID: CGMainDisplayID(), excludedWindowIDs: [99], includedWindowIDs: [10,20], forceMasking: false,
            copyOnScreenWindows: { windowLookups.increment(); return nil },
            captureArray: { _, ids in
                arrayCaptures.increment()
                XCTAssertEqual(CFArrayGetCount(ids), 2)
                return image
            }, captureDisplay: { _ in XCTFail("Array success must not fall back to unfiltered display capture"); return nil }
        )
        XCTAssertNotNil(result)
        XCTAssertEqual(windowLookups.count, 0)
        XCTAssertEqual(arrayCaptures.count, 1)
    }

    func testMaskingRequiresFreshWindowLookupAndDropsFrameIfUnavailable() async throws {
        let capture = CGWindowListCapture()
        let lookups = Probe()
        let result = await capture.captureWithFiltering(
            displayID: CGMainDisplayID(), excludedWindowIDs: [99], includedWindowIDs: [10], forceMasking: true,
            copyOnScreenWindows: { lookups.increment(); return nil },
            captureArray: { _, _ in XCTFail("Forced masking must bypass array capture"); return nil },
            captureDisplay: { _ in XCTFail("Missing geometry must fail before display capture"); return nil }
        )
        XCTAssertNil(result)
        XCTAssertEqual(lookups.count, 1)
    }

    func testArrayFailureRefreshesGeometryOnceAndRemembersFallback() async throws {
        let capture = CGWindowListCapture()
        let lookups = Probe()
        let arrays = Probe()
        let image = try makeImage()
        let missingGeometry = await capture.captureWithFiltering(
            displayID: CGMainDisplayID(), excludedWindowIDs: [99], includedWindowIDs: [10], forceMasking: false,
            copyOnScreenWindows: { lookups.increment(); return nil },
            captureArray: { _, _ in arrays.increment(); return nil }, captureDisplay: { _ in image }
        )
        XCTAssertNil(missingGeometry)
        XCTAssertEqual(lookups.count, 1)
        let previousArrays = arrays.count
        let second = await capture.captureWithFiltering(
            displayID: CGMainDisplayID(), excludedWindowIDs: [99], includedWindowIDs: [10], forceMasking: false,
            copyOnScreenWindows: { lookups.increment(); return nil },
            captureArray: { _, _ in arrays.increment(); return nil }, captureDisplay: { _ in image }
        )
        XCTAssertNil(second)
        XCTAssertEqual(lookups.count, 2)
        XCTAssertEqual(arrays.count, previousArrays, "Known-broken array capture must not repeat the attempt")
    }

    func testFreshMaskingBoundsProtectTheImage() async throws {
        let capture = CGWindowListCapture()
        let image = try makeImage()
        let lookups = Probe()
        let displayID = CGMainDisplayID()
        let bounds = CGDisplayBounds(displayID)
        let result = await capture.captureWithFiltering(
            displayID: displayID, excludedWindowIDs: [99], includedWindowIDs: [10], forceMasking: true,
            copyOnScreenWindows: {
                lookups.increment()
                return [[kCGWindowNumber as String: CGWindowID(99), kCGWindowBounds as String: bounds.dictionaryRepresentation]]
            }, captureArray: { _, _ in XCTFail("Forced masking must not capture arrays"); return nil },
            captureDisplay: { _ in image }
        )
        let masked = try XCTUnwrap(result)
        XCTAssertEqual(masked.visibleExcludedWindowIDs, [99])
        XCTAssertEqual(lookups.count, 1)
        let originalPixels = try BGRAImageUtilities.makeData(from: image)
        let protectedPixels = try BGRAImageUtilities.makeData(from: masked.image)
        XCTAssertNotEqual(originalPixels, protectedPixels)
    }

    func testCoveredExcludedWindowDoesNotAlterForegroundPixels() async throws {
        let image = try makeImage()
        let bounds = CGDisplayBounds(CGMainDisplayID())
        let result = await CGWindowListCapture().captureWithFiltering(
            displayID: CGMainDisplayID(), excludedWindowIDs: [99], includedWindowIDs: [10], forceMasking: true,
            copyOnScreenWindows: { [self.window(10, bounds: bounds), self.window(99, bounds: bounds)] },
            captureDisplay: { _ in image }
        )
        let frame = try XCTUnwrap(result)
        XCTAssertTrue(frame.visibleExcludedWindowIDs.isEmpty)
        XCTAssertEqual(try BGRAImageUtilities.makeData(from: frame.image),
                       try BGRAImageUtilities.makeData(from: image))
    }

    func testPartiallyCoveredExcludedWindowMasksOnlyExposedPixels() async throws {
        let image = try makeImage()
        let bounds = CGDisplayBounds(CGMainDisplayID())
        let foreground = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width / 2, height: bounds.height)
        let result = await CGWindowListCapture().captureWithFiltering(
            displayID: CGMainDisplayID(), excludedWindowIDs: [99], includedWindowIDs: [10], forceMasking: true,
            copyOnScreenWindows: { [self.window(10, bounds: foreground), self.window(99, bounds: bounds)] },
            captureDisplay: { _ in image }
        )
        let frame = try XCTUnwrap(result)
        XCTAssertEqual(frame.visibleExcludedWindowIDs, [99])
        let original = try BGRAImageUtilities.makeData(from: image)
        let masked = try BGRAImageUtilities.makeData(from: frame.image)
        for row in 0..<64 {
            let start = row * 256
            XCTAssertEqual(masked[start..<(start + 128)], original[start..<(start + 128)])
        }
        XCTAssertNotEqual(masked, original, "Exposed protected content must still be blurred")
    }

    func testTransparentOrOffscreenWindowDoesNotHideExcludedContent() async throws {
        let image = try makeImage()
        let bounds = CGDisplayBounds(CGMainDisplayID())
        for (alpha, onScreen) in [(0.0, true), (0.5, true), (1.0, false)] {
            let result = await CGWindowListCapture().captureWithFiltering(
                displayID: CGMainDisplayID(), excludedWindowIDs: [99], includedWindowIDs: [10], forceMasking: true,
                copyOnScreenWindows: {
                    [self.window(10, bounds: bounds, alpha: alpha, onScreen: onScreen), self.window(99, bounds: bounds)]
                }, captureDisplay: { _ in image }
            )
            XCTAssertEqual(try XCTUnwrap(result).visibleExcludedWindowIDs, [99])
        }
    }

    func testMultipleForegroundWindowsTogetherCoverExcludedWindow() async throws {
        let image = try makeImage()
        let bounds = CGDisplayBounds(CGMainDisplayID())
        let left = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width / 2, height: bounds.height)
        let right = CGRect(x: bounds.midX, y: bounds.minY, width: bounds.width / 2, height: bounds.height)
        let result = await CGWindowListCapture().captureWithFiltering(
            displayID: CGMainDisplayID(), excludedWindowIDs: [99], includedWindowIDs: [10, 20], forceMasking: true,
            copyOnScreenWindows: {
                [self.window(10, bounds: left), self.window(20, bounds: right), self.window(99, bounds: bounds)]
            }, captureDisplay: { _ in image }
        )
        let frame = try XCTUnwrap(result)
        XCTAssertTrue(frame.visibleExcludedWindowIDs.isEmpty)
        XCTAssertEqual(try BGRAImageUtilities.makeData(from: frame.image),
                       try BGRAImageUtilities.makeData(from: image))
    }

    func testWindowBehindExcludedWindowCannotSuppressItsMask() async throws {
        let image = try makeImage()
        let bounds = CGDisplayBounds(CGMainDisplayID())
        let result = await CGWindowListCapture().captureWithFiltering(
            displayID: CGMainDisplayID(), excludedWindowIDs: [99], includedWindowIDs: [10], forceMasking: true,
            copyOnScreenWindows: { [self.window(99, bounds: bounds), self.window(10, bounds: bounds)] },
            captureDisplay: { _ in image }
        )
        let frame = try XCTUnwrap(result)
        XCTAssertEqual(frame.visibleExcludedWindowIDs, [99])
        XCTAssertNotEqual(try BGRAImageUtilities.makeData(from: frame.image),
                          try BGRAImageUtilities.makeData(from: image))
    }

    private func window(_ id: CGWindowID, bounds: CGRect, alpha: Double = 1, onScreen: Bool = true) -> [String: Any] {
        [kCGWindowNumber as String: id, kCGWindowBounds as String: bounds.dictionaryRepresentation,
         kCGWindowLayer as String: 0, kCGWindowAlpha as String: alpha, kCGWindowIsOnscreen as String: onScreen]
    }

    private func makeImage() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 256,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 16, y: 16, width: 32, height: 32))
        return try XCTUnwrap(context.makeImage())
    }
}
