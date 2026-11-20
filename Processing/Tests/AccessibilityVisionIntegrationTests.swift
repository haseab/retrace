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
        let metadata = FrameMetadata(appBundleID: "com.apple.TextEdit", appName: "TextEdit", windowName: "Saved fixture",
            ocrRegions: [CGRect(x: 0, y: 0, width: 1, height: 1)])
        let baselineFrame = CapturedFrame(imageData: pixels, width: width, height: height, bytesPerRow: stride, metadata: metadata)
        let baseline = try await ProcessingManager().extractText(from: baselineFrame)
        XCTAssertFalse((baseline.regions + baseline.chromeRegions).isEmpty)
        let snapshot = AccessibilitySnapshot(capturedAt: Date(), elements: [
            .init(text: document.string + " AXONLY_MUST_NOT_BE_APPENDED", bounds: CGRect(x: 0, y: 0, width: width, height: height), precise: false)
        ])
        let frame = CapturedFrame(imageData: pixels, width: width, height: height, bytesPerRow: stride,
                                  metadata: metadata, accessibilitySnapshot: snapshot)
        let result = try await ProcessingManager().extractText(from: frame)
        XCTAssertFalse(result.fullText.contains("AXONLY_MUST_NOT_BE_APPENDED"))
        XCTAssertFalse(result.chromeText.contains("AXONLY_MUST_NOT_BE_APPENDED"))
        XCTAssertEqual(result.metadata, metadata)
        XCTAssertEqual((result.regions + result.chromeRegions).map(\.bounds),
            (baseline.regions + baseline.chromeRegions).map(\.bounds))
    }
    func testDecomposedAccessibilityAccentDoesNotDowngradeCorrectVisionText() async throws {
        let reference = "Please review the cafe\u{301} menu before confirming your reservation."
        let width = 1800, height = 130, stride = width * 4
        var pixels = Data(count: stride * height)
        pixels.withUnsafeMutableBytes { raw in
            let context = CGContext(data: raw.baseAddress, width: width, height: height,
                                    bitsPerComponent: 8, bytesPerRow: stride, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let text = NSAttributedString(string: reference, attributes: [
                .font: NSFont.systemFont(ofSize: 28), .foregroundColor: NSColor.black
            ])
            context.textPosition = CGPoint(x: 25, y: 60)
            CTLineDraw(CTLineCreateWithAttributedString(text), context)
        }
        let raw = try await VisionOCR().recognizeText(imageData: pixels, width: width, height: height,
                                                      bytesPerRow: stride, config: .default)
        XCTAssertEqual(raw.map(\.text).joined(separator: " ").precomposedStringWithCanonicalMapping,
                       reference.precomposedStringWithCanonicalMapping)
        let snapshot = AccessibilitySnapshot(capturedAt: Date(), elements: [
            .init(text: reference, bounds: CGRect(x: 0, y: 0, width: width, height: height), precise: false)
        ])
        let corrected = await AccessibilityOCRCorrector.correct(raw, snapshot: snapshot)
        XCTAssertEqual(corrected.map(\.text), raw.map(\.text))
        XCTAssertEqual(corrected.map(\.bounds), raw.map(\.bounds))
    }

    func testRecordedAccentCorrectionDoesNotIntroduceSQLiteOffsetDrift() async {
        // Actual Vision output from the bundled Dev capture, before AX correction.
        let bounds = CGRect(x: 1045, y: 703, width: 395, height: 19)
        let region = TextRegion(frameID: .init(value: 37),
                                text: "Please review the cafe menu before contirming your reservation.", bounds: bounds)
        let reference = "Please review the cafe\u{301} menu before confirming your reservation."
        let before = TextRegion(frameID: .init(value: 37),
            text: "Renée Müller discussed the façade with José García at 14:35.", bounds: bounds.offsetBy(dx: 0, dy: -35))
        let after = TextRegion(frameID: .init(value: 37),
            text: "Naïve comparisons must preserve the résumé and its accents.", bounds: bounds.offsetBy(dx: 0, dy: 35))
        let snapshot = AccessibilitySnapshot(capturedAt: Date(), elements: [
            .init(text: before.text + " " + reference + " " + after.text,
                  bounds: CGRect(x: 1000, y: 650, width: 600, height: 120), precise: false)
        ])
        let results = await AccessibilityOCRCorrector.correct([before, region, after], snapshot: snapshot)
        let corrected = results[1]
        XCTAssertEqual(Array(corrected.text.utf8), Array(reference.precomposedStringWithCanonicalMapping.utf8))
        // SQLite counts Unicode scalars; existing node offsets use Swift characters.
        // A decomposed Latin accent must not add a scalar and shift later nodes.
        XCTAssertEqual(corrected.text.unicodeScalars.count, corrected.text.count)
        XCTAssertEqual(corrected.bounds, region.bounds)
    }

}
