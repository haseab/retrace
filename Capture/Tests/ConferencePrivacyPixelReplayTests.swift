import CoreGraphics
import Foundation
import ImageIO
import Shared
import XCTest
@testable import Capture

/// Controlled gallery built from a real repository photo. This exercises Vision
/// and pixel rendering, but does not represent ten distinct participants or Zoom's AX tree.
final class ConferencePrivacyPixelReplayTests: XCTestCase {
    private struct CallObserver: ConferenceCallObserving {
        func observe(_ target: ConferenceCallObservationTarget) -> ConferenceCallObservation {
            target.windowTitle == "Meeting" ? .active : .unknown(.controlNotFound)
        }
    }

    private struct WindowImages: ConferenceWindowImageProviding {
        let images: [CGWindowID: CGImage]
        var bounds = CGRect(x: 0, y: 0, width: 384, height: 1080)
        var ownerPID: pid_t = 42
        func snapshot(for windowID: CGWindowID) -> ConferenceWindowImageSnapshot? {
            images[windowID].map { .init(image: $0, bounds: bounds, ownerPID: ownerPID) }
        }
    }

    private func homeWindow(width: Int = 384, height: Int = 1080) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }

    private actor Events {
        var values: [ConferenceFramePrivacyEvent] = []
        func append(_ event: ConferenceFramePrivacyEvent) { values.append(event) }
        func drain() -> [ConferenceFramePrivacyEvent] {
            defer { values.removeAll() }
            return values
        }
    }

    private func gallery(width: Int = 1920, height: Int = 1080) throws -> CGImage {
        let root = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let path = root.appendingPathComponent("UI/Assets.xcassets/CreatorProfile.imageset/haseab.png")
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(path as CFURL, nil))
        let portrait = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let cellWidth = CGFloat(width) / 5
        let cellHeight = CGFloat(height) / 2
        let side = min(cellWidth, cellHeight) * 0.8
        for row in 0..<2 {
            for column in 0..<5 {
                context.draw(portrait, in: CGRect(
                    x: CGFloat(column) * cellWidth + (cellWidth - side) / 2,
                    y: CGFloat(row) * cellHeight + (cellHeight - side) / 2,
                    width: side, height: side))
            }
        }
        return try XCTUnwrap(context.makeImage())
    }

    private func windows(includeBackground: Bool) -> [CGWindowListCapture.VisibleWindowContext] {
        var result: [CGWindowListCapture.VisibleWindowContext] = [
            .init(windowID: 10, ownerPID: 42, appBundleID: "us.zoom.xos", appName: "Zoom",
                  windowName: "Meeting", browserURL: nil, windowLayer: 0,
                  windowBounds: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        ]
        if includeBackground {
            result.append(.init(windowID: 20, ownerPID: 42, appBundleID: "us.zoom.xos", appName: "Zoom",
                windowName: "Zoom Workplace", browserURL: nil, windowLayer: 0,
                windowBounds: CGRect(x: 0, y: 0, width: 384, height: 1080)))
        }
        return result
    }

    private func selection(_ contexts: [CGWindowListCapture.VisibleWindowContext])
        -> CGWindowListCapture.ConferenceWindowSelection {
        let display = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        // Use production occlusion policy, not WindowVisibilityCandidate's test default.
        let candidates = contexts.map { context in
            CGWindowListCapture.ConferenceROIPlanner.WindowVisibilityCandidate(
                windowID: context.windowID, windowBounds: context.windowBounds,
                occludesBackgroundWindows: CGWindowListCapture.ConferenceROIPlanner.shouldUseAsOcclusionBlocker(
                    ownerName: context.appName ?? "", appBundleID: context.appBundleID,
                    windowLayer: context.windowLayer, windowBounds: context.windowBounds,
                    displayBounds: display))
        }
        let visible = CGWindowListCapture.ConferenceROIPlanner.visibleWindowIDs(from: candidates, displayBounds: display)
        return .init(contexts: contexts, visibleWindowIDs: visible, redactedWindowIDs: [])
    }

    func testBackgroundNonCallWindowCannotBlurConsentedForegroundPixels() async throws {
        let image = try gallery()
        func export(_ image: CGImage, step: Int) throws {
            guard let directory = ProcessInfo.processInfo.environment["RETRACE_PIXEL_REPLAY_OUTPUT_DIR"] else { return }
            let folder = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent("step-\(step).png")
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
        }
        let capture = CGWindowListCapture(conferenceCallObserver: CallObserver(),
            conferenceWindowImages: WindowImages(images: [20: try homeWindow()]),
            conferenceObservationClock: { Date(timeIntervalSince1970: 1000) })
        let events = Events()
        await capture.setOnConferenceFramePrivacyEvent { await events.append($0) }
        try await capture.startCapture(config: .default, displayID: 1)
        do {
            let foregroundOnly = selection(windows(includeBackground: false))
            let initial = await capture.applyConferencePrivacy(to: image, windows: foregroundOnly,
                visibleWindowContext: foregroundOnly.visible.first,
                displayBounds: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                hasActiveMediaCapture: false, captureIntervalSeconds: 2)
            XCTAssertNotNil(initial)
            let initialEvents = await events.drain()
            XCTAssertEqual(initialEvents.first?.outcome, .blurred)
            XCTAssertEqual(initialEvents.first?.faceCount, 10, "Calibration must detect all ten controlled faces")
            let token = try XCTUnwrap(initialEvents.first?.consentSessionID)
            let granted = await capture.disableFaceBlurForConferenceCall(callID: token)
            XCTAssertTrue(granted)

            // Remove, restore, and remove the background context. The same original
            // image is used every time, so old stored blur cannot explain the result.
            for (step, includeBackground) in [false, true, false, true, false].enumerated() {
                let selected = selection(windows(includeBackground: includeBackground))
                let before = await capture.prepareConferenceWindowSources(windows: selected, hasActiveMediaCapture: false)
                let validated = await capture.validateConferenceWindowSources(before)
                let output = await capture.applyConferencePrivacy(to: image, windows: selected,
                    visibleWindowContext: selected.visible.first,
                    displayBounds: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                    hasActiveMediaCapture: false, captureIntervalSeconds: 2,
                    validatedWindowSources: validated)
                let result = try XCTUnwrap(output)
                try export(result, step: step)
                let recorded = await events.drain()
                XCTAssertEqual(recorded.first?.outcome, .consentBypassed)
                let inputBytes = try XCTUnwrap(image.dataProvider?.data) as Data
                let outputBytes = try XCTUnwrap(result.dataProvider?.data) as Data
                if includeBackground {
                    XCTAssertEqual(selected.visible.count, 2)
                    XCTAssertEqual(recorded.count, 2)
                    XCTAssertEqual(recorded.last?.outcome, .noFacesDetected)
                    XCTAssertNil(recorded.last?.consentSessionID, "Background home window is not an active call")
                    XCTAssertEqual(recorded.last?.faceCount, 0)
                    XCTAssertEqual(outputBytes, inputBytes)
                } else {
                    XCTAssertEqual(recorded.count, 1)
                    XCTAssertEqual(outputBytes, inputBytes)
                }
                print("PIXEL_REPLAY background=\(includeBackground) outcomes=\(recorded.map { $0.outcome.rawValue }) faces=\(recorded.map(\.faceCount))")
            }
        } catch {
            try? await capture.stopCapture()
            throw error
        }
        try await capture.stopCapture()
    }

    func testUnconsentedBackgroundCallStillProtectsFacesFromItsOwnImage() async throws {
        let source = try XCTUnwrap(try gallery().cropping(to: CGRect(x: 0, y: 0, width: 384, height: 1080)))
        try await assertBackgroundRemainsProtected(source: source)
    }

    func testIsolatedWindowFacesProjectToTheirDesktopPosition() async throws {
        let source = try XCTUnwrap(try gallery().cropping(to: CGRect(x: 0, y: 0, width: 384, height: 1080)))
        try await assertBackgroundRemainsProtected(source: source, backgroundX: 1536)
    }

    func testUnavailableWindowImageFallsBackToDesktopProtection() async throws {
        try await assertBackgroundRemainsProtected(source: nil)
    }

    func testUnreadableTransparentWindowImageFallsBackToDesktopProtection() async throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 384, height: 1080,
            bitsPerComponent: 8, bytesPerRow: 384 * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let transparent = try XCTUnwrap(context.makeImage())
        try await assertBackgroundRemainsProtected(source: transparent)
    }

    func testChangedSourceCannotRemoveFacesCapturedBeforeVideoTurnedOff() async throws {
        let earlier = try XCTUnwrap(try gallery().cropping(to: CGRect(x: 0, y: 0, width: 384, height: 1080)))
        let before = ConferenceWindowImageSnapshot(image: earlier,
            bounds: CGRect(x: 0, y: 0, width: 384, height: 1080), ownerPID: 42)
        try await assertBackgroundRemainsProtected(source: try homeWindow(), before: before)
    }

    func testWindowSourceGeometryChangeKeepsDesktopProtection() async throws {
        let image = try homeWindow()
        let before = ConferenceWindowImageSnapshot(image: image,
            bounds: CGRect(x: 1, y: 0, width: 384, height: 1080), ownerPID: 42)
        try await assertBackgroundRemainsProtected(source: image, before: before)
    }

    func testWindowSourceOwnerChangeKeepsDesktopProtection() async throws {
        let image = try homeWindow()
        let before = ConferenceWindowImageSnapshot(image: image,
            bounds: CGRect(x: 0, y: 0, width: 384, height: 1080), ownerPID: 43)
        try await assertBackgroundRemainsProtected(source: image, before: before)
    }

    func testMissingPreCaptureSourceCannotAuthorizeNoFaces() async throws {
        try await assertBackgroundRemainsProtected(source: try homeWindow(), skipPreCapture: true)
    }

    private func assertBackgroundRemainsProtected(
        source: CGImage?, backgroundX: CGFloat = 0,
        before: ConferenceWindowImageSnapshot? = nil, skipPreCapture: Bool = false
    ) async throws {
        let image = try gallery()
        let capture = CGWindowListCapture(conferenceCallObserver: CallObserver(),
            conferenceWindowImages: WindowImages(images: source.map { [20: $0] } ?? [:],
                bounds: CGRect(x: backgroundX, y: 0, width: 384, height: 1080)),
            conferenceObservationClock: { Date(timeIntervalSince1970: 1000) })
        let events = Events()
        await capture.setOnConferenceFramePrivacyEvent { await events.append($0) }
        try await capture.startCapture(config: .default, displayID: 1)
        do {
            let primary = selection(windows(includeBackground: false))
            _ = await capture.applyConferencePrivacy(to: image, windows: primary,
                visibleWindowContext: primary.visible.first,
                displayBounds: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                hasActiveMediaCapture: false, captureIntervalSeconds: 2)
            let initial = await events.drain()
            let token = try XCTUnwrap(initial.first?.consentSessionID)
            let granted = await capture.disableFaceBlurForConferenceCall(callID: token)
            XCTAssertTrue(granted)
            var contexts = windows(includeBackground: true)
            let background = contexts[1]
            contexts[1] = .init(windowID: background.windowID, ownerPID: background.ownerPID,
                appBundleID: background.appBundleID, appName: background.appName,
                windowName: background.windowName, browserURL: background.browserURL,
                windowLayer: background.windowLayer,
                windowBounds: CGRect(x: backgroundX, y: 0, width: 384, height: 1080))
            let selected = selection(contexts)
            let prepared = skipPreCapture ? [:] : await capture.prepareConferenceWindowSources(
                windows: selected, hasActiveMediaCapture: false)
            let validated = await capture.validateConferenceWindowSources(before.map { [20: $0] } ?? prepared)
            let output = await capture.applyConferencePrivacy(to: image, windows: selected,
                visibleWindowContext: selected.visible.first,
                displayBounds: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                hasActiveMediaCapture: false, captureIntervalSeconds: 2,
                validatedWindowSources: validated)
            let result = try XCTUnwrap(output)
            let recorded = await events.drain()
            XCTAssertEqual(recorded.first?.outcome, .consentBypassed)
            XCTAssertEqual(recorded.last?.outcome, .blurred)
            XCTAssertEqual(recorded.last?.faceCount, 2)
            XCTAssertNil(recorded.last?.consentSessionID)
            XCTAssertNotEqual(try XCTUnwrap(result.dataProvider?.data) as Data,
                              try XCTUnwrap(image.dataProvider?.data) as Data)
            if backgroundX > 0 {
                let before = try XCTUnwrap(image.dataProvider?.data) as Data
                let after = try XCTUnwrap(result.dataProvider?.data) as Data
                XCTAssertEqual(image.bytesPerRow, result.bytesPerRow)
                for row in 0..<image.height {
                    let start = row * image.bytesPerRow
                    XCTAssertEqual(before[start..<(start + 384 * 4)], after[start..<(start + 384 * 4)],
                                   "Source faces on the right must not blur the leftmost column")
                }
            }
        } catch {
            try? await capture.stopCapture()
            throw error
        }
        try await capture.stopCapture()
    }

    func testMeasureRepeatedBackgroundWindowProcessingCost() async throws {
        guard ProcessInfo.processInfo.environment["RETRACE_MEASURE_FACE_BLUR"] == "1" else {
            throw XCTSkip("Set RETRACE_MEASURE_FACE_BLUR=1 for window scaling measurements")
        }
        let image = try gallery(width: 3840, height: 2160)
        let source = try homeWindow(width: 3840, height: 2160)
        let images = Dictionary(uniqueKeysWithValues: (0..<10).map { (UInt32(20 + $0), source) })
        let capture = CGWindowListCapture(conferenceCallObserver: CallObserver(),
            conferenceWindowImages: WindowImages(images: images, bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080)),
            conferenceObservationClock: { Date(timeIntervalSince1970: 1000) })
        let events = Events()
        await capture.setOnConferenceFramePrivacyEvent { await events.append($0) }
        try await capture.startCapture(config: .default, displayID: 1)
        do {
            let primary = windows(includeBackground: false)[0]
            let onlyPrimary = selection([primary])
            _ = await capture.applyConferencePrivacy(to: image, windows: onlyPrimary,
                visibleWindowContext: primary, displayBounds: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                hasActiveMediaCapture: false, captureIntervalSeconds: 2)
            let initialEvents = await events.drain()
            let token = try XCTUnwrap(initialEvents.first?.consentSessionID)
            let granted = await capture.disableFaceBlurForConferenceCall(callID: token)
            XCTAssertTrue(granted)
            // Each context is treated as potentially transparent by production.
            // These are controlled metadata inputs, not a claim about Zoom's actual window count.
            for count in [0, 1, 5, 10, 0] {
                let backgrounds: [CGWindowListCapture.VisibleWindowContext] = (0..<count).map { index in
                    .init(windowID: UInt32(20 + index), ownerPID: 42, appBundleID: "us.zoom.xos",
                          appName: "Zoom", windowName: "Zoom Workplace \(index)", browserURL: nil,
                          windowLayer: 0, windowBounds: primary.windowBounds)
                }
                let selected = selection([primary] + backgrounds)
                for iteration in 0..<3 {
                    let start = CFAbsoluteTimeGetCurrent()
                    let before = await capture.prepareConferenceWindowSources(windows: selected, hasActiveMediaCapture: false)
                    XCTAssertLessThanOrEqual(before.count, 2)
                    let validated = await capture.validateConferenceWindowSources(before)
                    let output = await capture.applyConferencePrivacy(to: image, windows: selected,
                        visibleWindowContext: primary,
                        displayBounds: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                        hasActiveMediaCapture: false, captureIntervalSeconds: 2,
                        validatedWindowSources: validated)
                    let total = (CFAbsoluteTimeGetCurrent() - start) * 1000
                    XCTAssertNotNil(output)
                    let recorded = await events.drain()
                    XCTAssertEqual(recorded.count, count + 1)
                    XCTAssertEqual(recorded.first?.outcome, .consentBypassed)
                    print("WINDOW_BENCH background_count=\(count) iteration=\(iteration) total_ms=\(total) detected_faces=\(recorded.reduce(0) { $0 + $1.faceCount })")
                }
            }
        } catch {
            try? await capture.stopCapture()
            throw error
        }
        try await capture.stopCapture()
    }

    /// Opt in to measurements; no timing thresholds because host load and hardware vary.
    func testMeasureDetectionAndRenderingCost() async throws {
        guard ProcessInfo.processInfo.environment["RETRACE_MEASURE_FACE_BLUR"] == "1" else {
            throw XCTSkip("Set RETRACE_MEASURE_FACE_BLUR=1 for controlled processing measurements")
        }
        for size in [(1920, 1080), (3840, 2160)] {
            let image = try gallery(width: size.0, height: size.1)
            let processor = ConferenceFaceBlurProcessor()
            for (label, config) in [("single", ConferenceFaceBlurConfiguration.inspectorSinglePass),
                                     ("production", .production)] {
                for iteration in 0..<6 {
                    let start = CFAbsoluteTimeGetCurrent()
                    let result = try await processor.blurFaces(in: image, regionOfInterest: nil, configuration: config)
                    let total = (CFAbsoluteTimeGetCurrent() - start) * 1000
                    XCTAssertGreaterThan(result.faceCount, 0)
                    print("FACE_BENCH size=\(size.0)x\(size.1) mode=\(label) iteration=\(iteration) faces=\(result.faceCount) detection_ms=\(result.detectionDurationMs) total_ms=\(total) rendering_tail_ms=\(total - result.detectionDurationMs)")
                }
            }
        }
    }
}
