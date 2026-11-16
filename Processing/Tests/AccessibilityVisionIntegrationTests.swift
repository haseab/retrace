import XCTest
import AppKit
import CoreText
import Shared
@testable import Processing

final class AccessibilityVisionIntegrationTests: XCTestCase {
    func testRealDocumentOCRUsesSavedReferenceWithoutAddingTextOrChangingGeometry() async throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "AXSmallText", withExtension: "rtf", subdirectory: "Fixtures"))
        let document = try NSAttributedString(url: url, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        let width = 1800, height = 1100, stride = width * 4
        var pixels = Data(count: stride * height)
        let rendered = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: stride, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return false }
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let setter = CTFramesetterCreateWithAttributedString(document)
            let path = CGPath(rect: CGRect(x: 80, y: 80, width: width-160, height: height-160), transform: nil)
            CTFrameDraw(CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), path, nil), context)
            return true
        }
        XCTAssertTrue(rendered)
        let raw = try await VisionOCR().recognizeText(imageData: pixels, width: width, height: height, bytesPerRow: stride, config: .default)
        XCTAssertFalse(raw.isEmpty)
        let metadata = FrameMetadata(appBundleID: "com.apple.TextEdit", appName: "TextEdit", windowName: "Saved fixture")
        let snapshot = AccessibilitySnapshot(capturedAt: Date(), elements: [
            .init(text: document.string + " AXONLY_MUST_NOT_BE_APPENDED", bounds: CGRect(x: 0, y: 0, width: width, height: height), precise: false)
        ])
        let frame = CapturedFrame(imageData: pixels, width: width, height: height, bytesPerRow: stride,
                                  metadata: metadata, accessibilitySnapshot: snapshot)
        let result = try await ProcessingManager().extractText(from: frame)
        XCTAssertFalse(result.fullText.contains("AXONLY_MUST_NOT_BE_APPENDED"))
        XCTAssertFalse(result.chromeText.contains("AXONLY_MUST_NOT_BE_APPENDED"))
        XCTAssertEqual(result.metadata, metadata)
        let originalBounds = Set(raw.map(\.bounds))
        XCTAssertTrue((result.regions + result.chromeRegions).allSatisfy { originalBounds.contains($0.bounds) })
    }
}
