import XCTest
import CoreText
import AppKit
import Shared
@testable import Processing

final class WindowOCRTests: XCTestCase {
    private let layout = [CGRect(x: 0, y: 0, width: 0.5, height: 1),
                          CGRect(x: 0.5, y: 0, width: 0.5, height: 1)]

    func testPixelPlannerAcceptsOrderedWindowOverlapButRejectsInvalidCoordinates() {
        XCTAssertNil(WindowOCRPlanner.pixelRegions([.init(x: CGFloat.nan, y: 0, width: 1, height: 1)], width: 1280, height: 600))
        XCTAssertNotNil(WindowOCRPlanner.pixelRegions([.init(x: 0, y: 0, width: 0.8, height: 1),
                                                  .init(x: 0.5, y: 0, width: 0.5, height: 1)], width: 1280, height: 600))
        XCTAssertEqual(WindowOCRPlanner.pixelRegions(layout, width: 1280, height: 600)?.map(\.width), [640, 640])
    }

    func testRealVisionKeepsWindowsSeparateAndRefreshesChangedWindow() async throws {
        let ocr = VisionOCR()
        let cache = FullFrameOCRCache()
        let first = try frame(rightText: "Right gamma document")
        let output = try await ocr.recognizeTextRegionBased(frame: first, previousFrame: nil, cache: cache, config: .default)
        let text = output.regions.map(\.text).joined(separator: " ")
        XCTAssertTrue(text.contains("Left alpha document"), text)
        XCTAssertTrue(text.contains("Right gamma document"), text)
        let leftIndex = try XCTUnwrap(output.regions.firstIndex { $0.text.contains("Left alpha") })
        let rightIndex = try XCTUnwrap(output.regions.firstIndex { $0.text.contains("Right gamma") })
        XCTAssertLessThan(leftIndex, rightIndex)
        XCTAssertLessThan(output.regions[leftIndex].bounds.maxX, 640)
        XCTAssertGreaterThan(output.regions[rightIndex].bounds.minX, 640)

        let second = try frame(rightText: "Right updated document")
        let updated = try await ocr.recognizeTextRegionBased(frame: second, previousFrame: first, cache: cache, config: .default)
        XCTAssertTrue(updated.regions.contains { $0.text.contains("Right updated document") })
        XCTAssertFalse(updated.regions.contains { $0.text.contains("Right gamma document") })
        XCTAssertEqual(updated.regions.filter { $0.bounds.maxX <= 640 }.map(\.text),
                       output.regions.filter { $0.bounds.maxX <= 640 }.map(\.text))
        XCTAssertGreaterThan(updated.stats.tilesCached, 0)
        let unchanged = try await ocr.recognizeTextRegionBased(frame: second, previousFrame: second, cache: cache, config: .default)
        XCTAssertEqual(unchanged.stats.tilesOCRed, 0)
        XCTAssertEqual(unchanged.regions.map(\.text), updated.regions.map(\.text))
    }

    func testOnlyEligibleScreenshotPixelsAreRecognized() async throws {
        let source = try frame(rightText: "Right visible document")
        var metadata = source.metadata
        metadata.ocrRegions = [CGRect(x: 0.5, y: 0.25, width: 0.5, height: 0.5)]
        let restricted = CapturedFrame(imageData: source.imageData, width: source.width, height: source.height,
            bytesPerRow: source.bytesPerRow, metadata: metadata)
        let output = try await VisionOCR().recognizeTextRegionBased(frame: restricted, previousFrame: nil,
            cache: FullFrameOCRCache(), config: .default)
        XCTAssertTrue(output.regions.contains { $0.text.contains("Right visible document") })
        XCTAssertFalse(output.regions.contains { $0.text.contains("Left alpha") })
        for region in output.regions {
            XCTAssertTrue(CGRect(x: 640, y: 150, width: 640, height: 300).contains(region.bounds))
        }
    }

    func testEmptyGeometryDoesNotFallBackToFullScreenRecognition() async throws {
        let source = try frame(rightText: "Right visible document")
        var metadata = source.metadata
        metadata.ocrRegions = []
        let excluded = CapturedFrame(imageData: source.imageData, width: source.width, height: source.height,
            bytesPerRow: source.bytesPerRow, metadata: metadata)
        let output = try await VisionOCR().recognizeTextRegionBased(frame: excluded, previousFrame: nil,
            cache: FullFrameOCRCache(), config: .default)
        XCTAssertTrue(output.regions.isEmpty)
        XCTAssertEqual(output.stats.tilesOCRed, 0)
    }

    func testSequentialAndConcurrentCropsHaveTheSameResultOrder() async throws {
        let source = try frame(rightText: "Right parallel document")
        let regions = try XCTUnwrap(WindowOCRPlanner.pixelRegions(layout, width: source.width, height: source.height))
        let sequential = try await VisionOCR().recognizeWindowRegions(frame: source, previousFrame: nil,
            cache: FullFrameOCRCache(), config: .default, pixelRegions: regions, maximumConcurrentRequests: 1)
        let concurrent = try await VisionOCR().recognizeWindowRegions(frame: source, previousFrame: nil,
            cache: FullFrameOCRCache(), config: .default, pixelRegions: regions, maximumConcurrentRequests: 2)
        XCTAssertFalse(sequential.regions.isEmpty)
        XCTAssertEqual(sequential.regions.map(\.text), concurrent.regions.map(\.text))
        XCTAssertEqual(sequential.regions.map(\.bounds), concurrent.regions.map(\.bounds))
    }

    func testOverlappingWindowCropMasksForegroundAndCachesOnlyItsOwnText() async throws {
        let source = try frame(rightText: "Right gamma document")
        var metadata = source.metadata
        metadata.ocrRegions = [CGRect(x: 0, y: 0, width: 0.5, height: 1),
                               CGRect(x: 0, y: 0, width: 1, height: 1)]
        let first = CapturedFrame(imageData: source.imageData, width: source.width, height: source.height,
                                  bytesPerRow: source.bytesPerRow, metadata: metadata)
        let ocr = VisionOCR(), cache = FullFrameOCRCache()
        let output = try await ocr.recognizeTextRegionBased(frame: first, previousFrame: nil,
            cache: cache, config: .default)
        XCTAssertEqual(output.regions.filter { $0.text.contains("Left alpha") }.count, 1)
        XCTAssertEqual(output.regions.filter { $0.text.contains("Right gamma") }.count, 1)
        let unchanged = try await ocr.recognizeTextRegionBased(frame: first, previousFrame: first,
            cache: cache, config: .default)
        XCTAssertEqual(unchanged.regions.map(\.text), output.regions.map(\.text),
                       "Overlapping crop bounds must not duplicate cached foreground text")
        XCTAssertEqual(unchanged.stats.tilesOCRed, 0)
        let changed = try frame(rightText: "Right updated document")
        let next = CapturedFrame(imageData: changed.imageData, width: changed.width, height: changed.height,
                                 bytesPerRow: changed.bytesPerRow, metadata: metadata)
        let refreshed = try await ocr.recognizeTextRegionBased(frame: next, previousFrame: first,
            cache: cache, config: .default)
        XCTAssertEqual(refreshed.regions.filter { $0.text.contains("Left alpha") }.count, 1)
        XCTAssertEqual(refreshed.regions.filter { $0.text.contains("Right updated") }.count, 1)
        XCTAssertFalse(refreshed.regions.contains { $0.text.contains("Right gamma") })
    }

    func testTopOccluderMasksCorrectVerticalPixelsWithoutRemovingLowerText() async throws {
        let source = try frame(rightText: "Right gamma document")
        var metadata = source.metadata
        metadata.ocrRegions = [CGRect(x: 0, y: 0, width: 1, height: 0.5),
                               CGRect(x: 0, y: 0, width: 1, height: 1)]
        let input = CapturedFrame(imageData: source.imageData, width: source.width, height: source.height,
                                  bytesPerRow: source.bytesPerRow, metadata: metadata)
        let output = try await VisionOCR().recognizeTextRegionBased(frame: input, previousFrame: nil,
            cache: FullFrameOCRCache(), config: .default)
        for phrase in ["Left alpha", "Right gamma", "Lower sapphire"] {
            XCTAssertEqual(output.regions.filter { $0.text.contains(phrase) }.count, 1, phrase)
        }
        let lower = try XCTUnwrap(output.regions.first { $0.text.contains("Lower sapphire") })
        XCTAssertGreaterThan(lower.bounds.minY, 300)
    }

    func testConcurrentFrameExtractionsKeepTheirOwnPixelsAndCache() async throws {
        let first = try frame(rightText: "Right first document")
        let second = try frame(rightText: "Right second document")
        let manager = ProcessingManager()
        async let a = manager.extractText(from: first)
        async let b = manager.extractText(from: second)
        let (firstOutput, secondOutput) = try await (a, b)
        XCTAssertTrue(firstOutput.fullText.contains("Right first document"))
        XCTAssertFalse(firstOutput.fullText.contains("Right second document"))
        XCTAssertTrue(secondOutput.fullText.contains("Right second document"))
        XCTAssertFalse(secondOutput.fullText.contains("Right first document"))
        await manager.invalidateTileCache()
        let afterClear = try await manager.extractText(from: second)
        XCTAssertEqual(afterClear.fullText, secondOutput.fullText)
    }

    func testChangingGeometryInvalidatesCacheEvenWhenPixelsMatch() async throws {
        let cache = FullFrameOCRCache()
        _ = await cache.validateForFrame(width: 1280, height: 600, appBundleID: "test", ocrRegions: layout)
        await cache.setFullFrameResults(regions: [], tileGrid: [])
        let changed = await cache.validateForFrame(width: 1280, height: 600, appBundleID: "test",
                                                  ocrRegions: [CGRect(x: 0, y: 0, width: 1, height: 1)])
        XCTAssertTrue(changed)
    }


    func testRecordedInvoiceFragmentsReadLeftToRightOnTheSameLine() {
        let regions = recordedInvoiceFragments()
        let result = OCRReadingOrder.ordered(regions)
        let expected = [regions[0], regions[1], regions[3], regions[2], regions[4], regions[5]]
        XCTAssertEqual(result, expected)
        XCTAssertEqual(result[1...3].map(\.text).joined(separator: " "),
            "Invoice 10024 covers 36 items at a total of $1444.75.")
    }

    func testRecordedMixedFragmentsStayOnTheirOwnLines() {
        // Actual RXCASE039 0.75-scale Vision text and screenshot rectangles.
        let raw: [(String, CGRect)] = [
            ("Please review the conference requirements before confirming your reservation.", CGRect(x: 22.8, y: 22.7246, width: 627, height: 20.2754)),
            ("items", CGRect(x: 217.9162, y: 59.5336, width: 42.1676, height: 8.9327)),
            ("at a total of $1459.75.", CGRect(x: 266, y: 60, width: 186, height: 12)),
            ("Involce 10039 covers", CGRect(x: 24, y: 62, width: 164, height: 8)),
            ("and the departure time is 14:35.", CGRect(x: 314, y: 92, width: 262, height: 16)),
            ("is AB10039", CGRect(x: 226, y: 94, width: 84, height: 12)),
            ("Ine reterence identıtıer", CGRect(x: 24, y: 96, width: 196, height: 8)),
            ("Coordinator Morgan Ellis approved the conference schedule for November 12.", CGRect(x: 22.8, y: 122, width: 604.2, height: 20.029))
        ]
        let regions = raw.enumerated().map { i, item in
            TextRegion(id: Int64(i + 1), frameID: .init(value: 39), text: item.0, bounds: item.1)
        }
        let result = OCRReadingOrder.ordered(regions)
        XCTAssertEqual(result, [regions[0], regions[3], regions[1], regions[2], regions[6], regions[5], regions[4], regions[7]])
        XCTAssertEqual(OCRReadingOrder.ordered(result), result, "Ordering must be stable when a cached result is reused")
    }

    func testRecordedFragmentsKeepWindowOrderWithoutLosingNodeIdentity() {
        let left = recordedInvoiceFragments()
        let right = left.map { region in
            TextRegion(id: (region.databaseID ?? 0) + 100, frameID: region.frameID, text: region.text,
                bounds: region.bounds.offsetBy(dx: 900, dy: -8), confidence: region.confidence, createdAt: region.createdAt)
        }
        var input: [TextRegion] = []
        for i in left.indices { input += [right[i], left[i]] }
        let windows = [CGRect(x: 0, y: 0, width: 740, height: 180), CGRect(x: 900, y: 0, width: 740, height: 180)]
        let result = OCRReadingOrder.ordered(input, windows: windows)
        let positions = [0, 1, 3, 2, 4, 5]
        XCTAssertEqual(result, positions.map { left[$0] } + positions.map { right[$0] })
        XCTAssertEqual(result.count, input.count)
        XCTAssertEqual(Set(result.compactMap(\.databaseID)), Set(input.compactMap(\.databaseID)))
    }

    private func recordedInvoiceFragments() -> [TextRegion] {
        // Actual RXCASE024 0.75-scale Vision output; 36 is two pixels lower.
        let raw: [(String, CGRect)] = [
            ("Please review the subscription requirements before confirming your reservation.", CGRect(x: 23.366659, y: 22.9999998, width: 642.583333, height: 18)),
            ("Invoice 10024 covers", CGRect(x: 23.965812, y: 57.9999998, width: 169.757835, height: 14)),
            ("items at a total of $1444.75.", CGRect(x: 215.692311, y: 58.0000001, width: 239.658104, height: 16)),
            ("36", CGRect(x: 191.726496, y: 59.9999999, width: 23.965812, height: 10)),
            ("The reference identifier is AB10024 and the departure time is 14:35.", CGRect(x: 23.366670, y: 90.686568, width: 554.958333, height: 20.477612)),
            ("Coordinator Morgan Ellis approved the subscription schedule for November 25.", CGRect(x: 23.366685, y: 122.865672, width: 619.216642, height: 20.477612))
        ]
        return raw.enumerated().map { i, entry in
            TextRegion(id: Int64(i + 1), frameID: .init(value: 24), text: entry.0, bounds: entry.1, confidence: 0.9)
        }
    }

    private func frame(rightText: String) throws -> CapturedFrame {
        let width = 1280, height = 600, stride = width * 4
        var pixels = Data(count: stride * height)
        try pixels.withUnsafeMutableBytes { raw in
            let context = try XCTUnwrap(CGContext(data: raw.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: stride, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            for (x, text) in [(40, "Left alpha document"), (680, rightText)] {
                let line = NSAttributedString(string: text, attributes: [
                    .font: NSFont.systemFont(ofSize: 30), .foregroundColor: NSColor.black])
                context.textPosition = CGPoint(x: x, y: 400)
                CTLineDraw(CTLineCreateWithAttributedString(line), context)
            }
            context.textPosition = CGPoint(x: 40, y: 100)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: "Lower sapphire ledger",
                attributes: [.font: NSFont.systemFont(ofSize: 30), .foregroundColor: NSColor.black])), context)
        }
        return CapturedFrame(imageData: pixels, width: width, height: height, bytesPerRow: stride,
                             metadata: FrameMetadata(appBundleID: "test", ocrRegions: layout))
    }
}
