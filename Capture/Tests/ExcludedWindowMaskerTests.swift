import XCTest
import CoreGraphics
import Shared
@testable import Capture

final class ExcludedWindowMaskerTests: XCTestCase {
    func testProtectionFailureNeverReturnsOriginalScreenshot() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8,
            bytesPerRow: 256, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let regions = [CGRect(x: 0, y: 0, width: 32, height: 32)]
        XCTAssertNil(ExcludedWindowMasker.mask(image, regions: regions, blur: { _ in nil }))
        XCTAssertNil(ExcludedWindowMasker.mask(image, regions: regions, blur: { $0 }, contextFactory: { _ in nil }))
        XCTAssertNil(ExcludedWindowMasker.mask(image, regions: regions, blur: { $0 }, imageFactory: { _ in nil }))
    }

    func testFullRectIsProtectedIncludingEdgesAndPixelsOutsideStayUnchanged() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8,
            bytesPerRow: 256, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0,y: 0,width: 64,height: 64))
        let original = try XCTUnwrap(context.makeImage())
        context.setFillColor(CGColor(gray: 0, alpha: 1)); context.fill(CGRect(x: 0,y: 0,width: 64,height: 64))
        let black = try XCTUnwrap(context.makeImage())
        let output = try XCTUnwrap(ExcludedWindowMasker.mask(original,
            regions: [CGRect(x: 0,y: 0,width: 32,height: 64)], blur: { _ in black }))
        let bytes = try Shared.BGRAImageUtilities.makeData(from: output)
        XCTAssertEqual(Array(bytes[0..<4]), [0,0,0,255])
        XCTAssertEqual(Array(bytes[(31*4)..<(32*4)]), [0,0,0,255])
        XCTAssertEqual(Array(bytes[(32*4)..<(33*4)]), [255,255,255,255])
    }
}
