import CoreGraphics
import Foundation
import ImageIO
import XCTest
import Shared
@testable import Capture

final class CaptureFrameCandidateTests: XCTestCase {
    func testExactScreenshotDuplicateCanReusePixelsButDifferentCropCannot() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(root.appendingPathComponent("UI/Assets.xcassets/InPageURLInstructions.imageset/safari_instructions.png") as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let metadata = FrameMetadata(displayID: 1)
        let first = CaptureFrameCandidate(image: image, timestamp: Date(), metadata: metadata)
        let duplicate = CaptureFrameCandidate(image: try XCTUnwrap(image.copy()), timestamp: Date(), metadata: metadata)
        XCTAssertTrue(duplicate.hasIdenticalPixels(to: first))
        let materialized = try XCTUnwrap(first.materialize())
        let reused = try XCTUnwrap(duplicate.materialize(reusingPixels: materialized.imageData))
        XCTAssertEqual(reused.imageData, materialized.imageData)
        let cropped = try XCTUnwrap(image.cropping(to: CGRect(x: 0, y: 0, width: image.width / 2, height: image.height)))
        XCTAssertFalse(CaptureFrameCandidate(image: cropped, timestamp: Date(), metadata: metadata).hasIdenticalPixels(to: first))
    }
}
