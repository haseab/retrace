import XCTest
import AppKit
import Combine
import Shared
import App
@testable import Retrace

@MainActor
final class TimelineHeadlessPrerenderStateTests: XCTestCase {
    func testSimpleTimelineViewOnAppearSkipsMostRecentReloadWhenFramesAlreadyExist() {
        XCTAssertFalse(
            SimpleTimelineView.shouldLoadMostRecentFrameOnAppear(
                hasInitialized: false,
                frameCount: 100
            )
        )
        XCTAssertFalse(
            SimpleTimelineView.shouldLoadMostRecentFrameOnAppear(
                hasInitialized: true,
                frameCount: 0
            )
        )
        XCTAssertTrue(
            SimpleTimelineView.shouldLoadMostRecentFrameOnAppear(
                hasInitialized: false,
                frameCount: 0
            )
        )
    }

    func testLoadMostRecentFrameMetadataOnlyLeavesCurrentImageUntouched() async {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        let sentinel = makeSolidImage(size: NSSize(width: 8, height: 8), color: .systemRed)
        viewModel.currentImage = sentinel

        viewModel.test_refreshFrameDataHooks.getMostRecentFramesWithVideoInfo = { limit, _ in
            XCTAssertEqual(limit, 100)
            return [
                self.makeFrameWithVideoInfo(
                    id: 1,
                    timestamp: Date(timeIntervalSince1970: 1_700_100_000),
                    frameIndex: 0
                ),
            ]
        }

        await viewModel.loadMostRecentFrame(refreshPresentation: false)

        XCTAssertTrue(viewModel.currentImage === sentinel)
        XCTAssertEqual(viewModel.frames.count, 1)
        XCTAssertEqual(viewModel.currentIndex, 0)
    }

    func testRefreshStaticPresentationIfNeededLeavesVideoBackedFramePresentationMetadataOnly() async {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        viewModel.setPresentationWorkEnabled(true, reason: "unit-test")

        let timelineFrame = TimelineFrame(
            frame: FrameReference(
                id: FrameID(value: 11),
                timestamp: Date(timeIntervalSince1970: 1_700_100_011),
                segmentID: AppSegmentID(value: 11),
                frameIndexInSegment: 4,
                metadata: FrameMetadata(
                    appBundleID: "test.app",
                    appName: "Test App",
                    displayID: 1
                ),
                source: .native
            ),
            videoInfo: FrameVideoInfo(
                videoPath: "/tmp/test-video-backed.mp4",
                frameIndex: 4,
                frameRate: 30,
                width: 1920,
                height: 1080,
                isVideoFinalized: true
            ),
            processingStatus: 4
        )

        viewModel.frames = [timelineFrame]
        viewModel.currentIndex = 0

        var ocrStatusLoads = 0
        var ocrNodeLoads = 0
        var frameImageLoads = 0

        viewModel.test_frameOverlayLoadHooks.getURLBoundingBox = { _, _ in nil }
        viewModel.test_frameOverlayLoadHooks.getOCRStatus = { frameID in
            XCTAssertEqual(frameID, timelineFrame.frame.id)
            ocrStatusLoads += 1
            return .completed
        }
        viewModel.test_frameOverlayLoadHooks.getAllOCRNodes = { frameID, source in
            XCTAssertEqual(frameID, timelineFrame.frame.id)
            XCTAssertEqual(source, .native)
            ocrNodeLoads += 1
            return []
        }
        viewModel.test_foregroundFrameLoadHooks.loadFrameData = { _ in
            frameImageLoads += 1
            return Data()
        }

        viewModel.refreshStaticPresentationIfNeeded()
        try? await Task.sleep(for: .milliseconds(20), clock: .continuous)

        XCTAssertEqual(viewModel.ocrStatus, .unknown)
        XCTAssertEqual(viewModel.ocrNodes, [])
        XCTAssertEqual(ocrStatusLoads, 0)
        XCTAssertEqual(ocrNodeLoads, 0)
        XCTAssertEqual(frameImageLoads, 0)
    }

    func testForegroundPresentationLoadCachesVideoBackedFramesInDiskBuffer() async throws {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        viewModel.setPresentationWorkEnabled(true, reason: "unit-test")
        let timelineFrame = TimelineFrame(
            frame: FrameReference(
                id: FrameID(value: 42),
                timestamp: Date(timeIntervalSince1970: 1_700_100_042),
                segmentID: AppSegmentID(value: 42),
                frameIndexInSegment: 12,
                metadata: FrameMetadata(
                    appBundleID: "test.app",
                    appName: "Test App",
                    displayID: 1
                ),
                source: .native
            ),
            videoInfo: FrameVideoInfo(
                videoPath: "/tmp/test-video.mp4",
                frameIndex: 12,
                frameRate: 30,
                width: 32,
                height: 24
            ),
            processingStatus: 4
        )

        let expectedImage = makeSolidImage(size: NSSize(width: 32, height: 24), color: .systemPurple)
        let expectedImageData = try XCTUnwrap(expectedImage.tiffRepresentation)
        let cacheFileURL = timelineDiskBufferFileURL(frameID: timelineFrame.frame.id)
        try? FileManager.default.removeItem(at: cacheFileURL)
        defer { try? FileManager.default.removeItem(at: cacheFileURL) }
        var dataLoads = 0

        viewModel.test_foregroundFrameLoadHooks.loadFrameData = { frame in
            XCTAssertEqual(frame.frame.id, timelineFrame.frame.id)
            dataLoads += 1
            return expectedImageData
        }

        let firstImage = try await viewModel.test_loadForegroundPresentationImage(timelineFrame)
        let secondImage = try await viewModel.test_loadForegroundPresentationImage(timelineFrame)

        XCTAssertEqual(dataLoads, 1)
        XCTAssertNotNil(firstImage.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertNotNil(secondImage.cgImage(forProposedRect: nil, context: nil, hints: nil))
    }

    func testForegroundPresentationLoadReadsUnindexedDiskBufferFileWithoutStorageRead() async throws {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        viewModel.setPresentationWorkEnabled(true, reason: "unit-test")
        let frameID = FrameID(value: 42_424_201)
        let timelineFrame = TimelineFrame(
            frame: FrameReference(
                id: frameID,
                timestamp: Date(timeIntervalSince1970: 1_700_100_200),
                segmentID: AppSegmentID(value: frameID.value),
                frameIndexInSegment: 1,
                metadata: FrameMetadata(
                    appBundleID: "test.app",
                    appName: "Test App",
                    displayID: 1
                ),
                source: .native
            ),
            videoInfo: FrameVideoInfo(
                videoPath: "/tmp/test-video-unindexed.mp4",
                frameIndex: 1,
                frameRate: 30,
                width: 24,
                height: 24,
                isVideoFinalized: true
            ),
            processingStatus: 4
        )

        let image = makeSolidImage(size: NSSize(width: 24, height: 24), color: .systemGreen)
        let jpegData = try makeJPEGData(image)
        let cacheFileURL = timelineDiskBufferFileURL(frameID: frameID)
        try FileManager.default.createDirectory(
            at: cacheFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try jpegData.write(to: cacheFileURL, options: [.atomic])
        defer { try? FileManager.default.removeItem(at: cacheFileURL) }

        var dataLoads = 0
        viewModel.test_foregroundFrameLoadHooks.loadFrameData = { _ in
            dataLoads += 1
            return Data("should-not-be-used".utf8)
        }
        let loadedImage = try await viewModel.test_loadForegroundPresentationImage(timelineFrame)

        XCTAssertEqual(dataLoads, 0)
        XCTAssertNotNil(loadedImage.cgImage(forProposedRect: nil, context: nil, hints: nil))
    }

    func testRefreshStaticPresentationShowsCaptureTimeStillForProcessingStatus4Frame() async throws {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        viewModel.setPresentationWorkEnabled(true, reason: "unit-test")

        let frameID = FrameID(value: 42_424_202)
        let timelineFrame = TimelineFrame(
            frame: FrameReference(
                id: frameID,
                timestamp: Date(timeIntervalSince1970: 1_700_100_202),
                segmentID: AppSegmentID(value: frameID.value),
                frameIndexInSegment: 2,
                metadata: FrameMetadata(
                    appBundleID: "test.app",
                    appName: "Test App",
                    displayID: 1
                ),
                source: .native
            ),
            videoInfo: nil,
            processingStatus: 4
        )
        viewModel.frames = [timelineFrame]
        viewModel.currentIndex = 0

        let stillImage = makeSolidImage(size: NSSize(width: 28, height: 28), color: .systemOrange)
        let stillData = try makeJPEGData(stillImage)
        let cacheFileURL = timelineDiskBufferFileURL(frameID: frameID)
        try FileManager.default.createDirectory(
            at: cacheFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try stillData.write(to: cacheFileURL, options: [.atomic])
        defer { try? FileManager.default.removeItem(at: cacheFileURL) }

        var dataLoads = 0
        viewModel.test_foregroundFrameLoadHooks.loadFrameData = { _ in
            dataLoads += 1
            return Data("should-not-be-used".utf8)
        }
        viewModel.test_frameOverlayLoadHooks.getURLBoundingBox = { _, _ in nil }
        viewModel.test_frameOverlayLoadHooks.getOCRStatus = { _ in .unknown }
        viewModel.test_frameOverlayLoadHooks.getAllOCRNodes = { _, _ in [] }

        viewModel.refreshStaticPresentationIfNeeded()

        for _ in 0..<50 {
            if viewModel.currentImage != nil && !viewModel.frameNotReady {
                break
            }
            try? await Task.sleep(for: .milliseconds(10), clock: .continuous)
        }

        XCTAssertEqual(dataLoads, 0)
        XCTAssertNotNil(viewModel.currentImage)
        XCTAssertFalse(viewModel.frameNotReady)
        XCTAssertFalse(viewModel.frameLoadError)
    }

    func testMissingProcessingStatus4FramePrefersNearestOlderProcessingStatus4StillAsFallback() async throws {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        viewModel.setPresentationWorkEnabled(true, reason: "unit-test")

        let olderStatus4FrameID = FrameID(value: 42_424_210)
        let readyFrameID = FrameID(value: 42_424_211)
        let currentStatus4FrameID = FrameID(value: 42_424_212)

        viewModel.frames = [
            makeVideoTimelineFrame(
                frameID: olderStatus4FrameID,
                timestamp: Date(timeIntervalSince1970: 1_700_100_210),
                frameIndex: 10,
                processingStatus: 4
            ),
            makeVideoTimelineFrame(
                frameID: readyFrameID,
                timestamp: Date(timeIntervalSince1970: 1_700_100_211),
                frameIndex: 11,
                processingStatus: 2
            ),
            makeVideoTimelineFrame(
                frameID: currentStatus4FrameID,
                timestamp: Date(timeIntervalSince1970: 1_700_100_212),
                frameIndex: 12,
                processingStatus: 4
            ),
        ]
        viewModel.currentIndex = 1
        viewModel.currentImage = makeSolidImage(size: NSSize(width: 17, height: 17), color: .systemRed)

        let olderStatus4Still = makeSolidImage(size: NSSize(width: 29, height: 29), color: .systemOrange)
        let olderStatus4StillData = try makeJPEGData(olderStatus4Still)
        let olderStatus4StillURL = timelineDiskBufferFileURL(frameID: olderStatus4FrameID)
        let currentStatus4StillURL = timelineDiskBufferFileURL(frameID: currentStatus4FrameID)

        try FileManager.default.createDirectory(
            at: olderStatus4StillURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try olderStatus4StillData.write(to: olderStatus4StillURL, options: [.atomic])
        try? FileManager.default.removeItem(at: currentStatus4StillURL)
        defer {
            try? FileManager.default.removeItem(at: olderStatus4StillURL)
            try? FileManager.default.removeItem(at: currentStatus4StillURL)
        }

        viewModel.test_frameOverlayLoadHooks.getURLBoundingBox = { _, _ in nil }
        viewModel.test_frameOverlayLoadHooks.getOCRStatus = { _ in .unknown }
        viewModel.test_frameOverlayLoadHooks.getAllOCRNodes = { _, _ in [] }

        viewModel.navigateToFrame(2)

        for _ in 0..<60 {
            if let fallbackImage = viewModel.waitingFallbackImage,
               Int(fallbackImage.size.width) == 29,
               Int(fallbackImage.size.height) == 29 {
                break
            }
            try? await Task.sleep(for: .milliseconds(10), clock: .continuous)
        }

        let fallbackImage = try XCTUnwrap(viewModel.waitingFallbackImage)
        XCTAssertEqual(Int(fallbackImage.size.width), 29)
        XCTAssertEqual(Int(fallbackImage.size.height), 29)
        XCTAssertTrue(viewModel.frameNotReady)
        XCTAssertFalse(viewModel.frameLoadError)
    }

    func testTimelineClosePreservesIndexedCaptureStillForReopen() async throws {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        viewModel.setPresentationWorkEnabled(true, reason: "unit-test")
        viewModel.handleTimelineOpened()

        let frameID = FrameID(value: 42_424_203)
        let timelineFrame = TimelineFrame(
            frame: FrameReference(
                id: frameID,
                timestamp: Date(timeIntervalSince1970: 1_700_100_203),
                segmentID: AppSegmentID(value: frameID.value),
                frameIndexInSegment: 3,
                metadata: FrameMetadata(
                    appBundleID: "test.app",
                    appName: "Test App",
                    displayID: 1
                ),
                source: .native
            ),
            videoInfo: nil,
            processingStatus: 4
        )
        viewModel.frames = [timelineFrame]
        viewModel.currentIndex = 0

        let stillImage = makeSolidImage(size: NSSize(width: 30, height: 30), color: .systemYellow)
        let stillData = try makeJPEGData(stillImage)
        let cacheFileURL = timelineDiskBufferFileURL(frameID: frameID)
        try FileManager.default.createDirectory(
            at: cacheFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try stillData.write(to: cacheFileURL, options: [.atomic])
        defer { try? FileManager.default.removeItem(at: cacheFileURL) }

        viewModel.test_frameOverlayLoadHooks.getURLBoundingBox = { _, _ in nil }
        viewModel.test_frameOverlayLoadHooks.getOCRStatus = { _ in .unknown }
        viewModel.test_frameOverlayLoadHooks.getAllOCRNodes = { _, _ in [] }

        viewModel.refreshStaticPresentationIfNeeded()
        for _ in 0..<50 {
            if viewModel.currentImage != nil && !viewModel.frameNotReady {
                break
            }
            try? await Task.sleep(for: .milliseconds(10), clock: .continuous)
        }
        XCTAssertNotNil(viewModel.currentImage)

        viewModel.handleTimelineClosed()
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheFileURL.path))

        viewModel.handleTimelineOpened()
        viewModel.refreshStaticPresentationIfNeeded()
        for _ in 0..<50 {
            if viewModel.currentImage != nil && !viewModel.frameNotReady {
                break
            }
            try? await Task.sleep(for: .milliseconds(10), clock: .continuous)
        }
        XCTAssertNotNil(viewModel.currentImage)
        XCTAssertFalse(viewModel.frameNotReady)
        XCTAssertFalse(viewModel.frameLoadError)
    }

    func testReadyFrameEvictsExternalStillAndUsesDecodedPath() async throws {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        viewModel.setPresentationWorkEnabled(true, reason: "unit-test")

        let frameID = FrameID(value: 42_424_204)
        let timelineFrame = TimelineFrame(
            frame: FrameReference(
                id: frameID,
                timestamp: Date(timeIntervalSince1970: 1_700_100_204),
                segmentID: AppSegmentID(value: frameID.value),
                frameIndexInSegment: 4,
                metadata: FrameMetadata(
                    appBundleID: "test.app",
                    appName: "Test App",
                    displayID: 1
                ),
                source: .native
            ),
            videoInfo: nil,
            processingStatus: 2
        )
        viewModel.frames = [timelineFrame]
        viewModel.currentIndex = 0

        let captureStill = makeSolidImage(size: NSSize(width: 30, height: 30), color: .systemPink)
        let captureStillData = try makeJPEGData(captureStill)
        let cacheFileURL = timelineDiskBufferFileURL(frameID: frameID)
        try FileManager.default.createDirectory(
            at: cacheFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try captureStillData.write(to: cacheFileURL, options: [.atomic])
        defer { try? FileManager.default.removeItem(at: cacheFileURL) }

        let decodedImageData = try XCTUnwrap(
            makeSolidImage(size: NSSize(width: 30, height: 30), color: .systemBlue).tiffRepresentation
        )
        var dataLoads = 0
        viewModel.test_foregroundFrameLoadHooks.loadFrameData = { _ in
            dataLoads += 1
            return decodedImageData
        }
        viewModel.test_frameOverlayLoadHooks.getURLBoundingBox = { _, _ in nil }
        viewModel.test_frameOverlayLoadHooks.getOCRStatus = { _ in .unknown }
        viewModel.test_frameOverlayLoadHooks.getAllOCRNodes = { _, _ in [] }

        viewModel.refreshStaticPresentationIfNeeded()

        for _ in 0..<50 {
            if viewModel.currentImage != nil {
                break
            }
            try? await Task.sleep(for: .milliseconds(10), clock: .continuous)
        }

        XCTAssertEqual(dataLoads, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheFileURL.path))
        XCTAssertNotNil(viewModel.currentImage)
        XCTAssertFalse(viewModel.frameNotReady)
        XCTAssertFalse(viewModel.frameLoadError)
    }

    func testReadyFrameFallsBackToCaptureStillWhenDecodedPathIsStale() async throws {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        viewModel.setPresentationWorkEnabled(true, reason: "unit-test")

        let frameID = FrameID(value: 42_424_205)
        let timelineFrame = TimelineFrame(
            frame: FrameReference(
                id: frameID,
                timestamp: Date(timeIntervalSince1970: 1_700_100_205),
                segmentID: AppSegmentID(value: frameID.value),
                frameIndexInSegment: 5,
                metadata: FrameMetadata(
                    appBundleID: "test.app",
                    appName: "Test App",
                    displayID: 1
                ),
                source: .native
            ),
            videoInfo: nil,
            processingStatus: 2
        )
        viewModel.frames = [timelineFrame]
        viewModel.currentIndex = 0

        let captureStill = makeSolidImage(size: NSSize(width: 31, height: 31), color: .systemOrange)
        let captureStillData = try makeJPEGData(captureStill)
        let cacheFileURL = timelineDiskBufferFileURL(frameID: frameID)
        try FileManager.default.createDirectory(
            at: cacheFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try captureStillData.write(to: cacheFileURL, options: [.atomic])
        defer { try? FileManager.default.removeItem(at: cacheFileURL) }

        var dataLoads = 0
        viewModel.test_foregroundFrameLoadHooks.loadFrameData = { _ in
            dataLoads += 1
            throw StorageError.fileReadFailed(
                path: "/tmp/test-video-stale.mp4",
                underlying: "Timestamp mismatch: requested=0.867s actual=0.833s frameIndex=26"
            )
        }
        viewModel.test_frameOverlayLoadHooks.getURLBoundingBox = { _, _ in nil }
        viewModel.test_frameOverlayLoadHooks.getOCRStatus = { _ in .unknown }
        viewModel.test_frameOverlayLoadHooks.getAllOCRNodes = { _, _ in [] }

        viewModel.refreshStaticPresentationIfNeeded()

        for _ in 0..<50 {
            if viewModel.currentImage != nil {
                break
            }
            try? await Task.sleep(for: .milliseconds(10), clock: .continuous)
        }

        let currentImage = try XCTUnwrap(viewModel.currentImage)
        XCTAssertEqual(dataLoads, 1)
        XCTAssertEqual(Int(currentImage.size.width), 31)
        XCTAssertEqual(Int(currentImage.size.height), 31)
        XCTAssertFalse(viewModel.frameNotReady)
        XCTAssertFalse(viewModel.frameLoadError)
    }

    func testCommandDragOnProcessingStatus4FrameRunsTransientStillOCR() async throws {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        viewModel.setPresentationWorkEnabled(true, reason: "unit-test")

        let frameID = FrameID(value: 42_424_206)
        viewModel.frames = [
            makeVideoTimelineFrame(
                frameID: frameID,
                timestamp: Date(timeIntervalSince1970: 1_700_100_206),
                frameIndex: 6,
                processingStatus: 4
            ),
        ]
        viewModel.currentIndex = 0
        viewModel.currentImage = makeSolidImage(size: NSSize(width: 32, height: 32), color: .systemTeal)

        viewModel.test_dragStartStillOCRHooks.recognizeTextFromCGImage = { _ in
            [
                TextRegion(
                    frameID: FrameID(value: 0),
                    text: "cmd drag ocr",
                    bounds: CGRect(x: 0.10, y: 0.20, width: 0.30, height: 0.10)
                ),
            ]
        }

        viewModel.startDragSelection(at: CGPoint(x: 0.2, y: 0.2), mode: .box)

        for _ in 0..<50 {
            if !viewModel.ocrNodes.isEmpty {
                break
            }
            try? await Task.sleep(for: .milliseconds(10), clock: .continuous)
        }

        XCTAssertEqual(viewModel.ocrStatus, .completed)
        XCTAssertEqual(viewModel.ocrNodes.count, 1)
        XCTAssertEqual(viewModel.ocrNodes.first?.text, "cmd drag ocr")
        XCTAssertNotNil(viewModel.dragStartPoint)
    }

    func testShiftDragOnProcessingStatus4FrameRunsTransientStillOCR() async throws {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        viewModel.setPresentationWorkEnabled(true, reason: "unit-test")

        let frameID = FrameID(value: 42_424_207)
        viewModel.frames = [
            makeVideoTimelineFrame(
                frameID: frameID,
                timestamp: Date(timeIntervalSince1970: 1_700_100_207),
                frameIndex: 7,
                processingStatus: 4
            ),
        ]
        viewModel.currentIndex = 0
        viewModel.currentImage = makeSolidImage(size: NSSize(width: 32, height: 32), color: .systemMint)

        viewModel.test_dragStartStillOCRHooks.recognizeTextFromCGImage = { _ in
            [
                TextRegion(
                    frameID: FrameID(value: 0),
                    text: "shift drag ocr",
                    bounds: CGRect(x: 0.12, y: 0.22, width: 0.28, height: 0.08)
                ),
            ]
        }

        viewModel.startZoomRegion(at: CGPoint(x: 0.3, y: 0.3))

        for _ in 0..<50 {
            if !viewModel.ocrNodes.isEmpty {
                break
            }
            try? await Task.sleep(for: .milliseconds(10), clock: .continuous)
        }

        XCTAssertEqual(viewModel.ocrStatus, .completed)
        XCTAssertEqual(viewModel.ocrNodes.first?.text, "shift drag ocr")
        XCTAssertTrue(viewModel.isDraggingZoomRegion)
    }

    func testCommandDragOnReadyFrameSkipsTransientStillOCR() async throws {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        viewModel.setPresentationWorkEnabled(true, reason: "unit-test")

        let frameID = FrameID(value: 42_424_208)
        viewModel.frames = [
            makeVideoTimelineFrame(
                frameID: frameID,
                timestamp: Date(timeIntervalSince1970: 1_700_100_208),
                frameIndex: 8,
                processingStatus: 2
            ),
        ]
        viewModel.currentIndex = 0
        viewModel.currentImage = makeSolidImage(size: NSSize(width: 32, height: 32), color: .systemGray)

        var ocrCalls = 0
        viewModel.test_dragStartStillOCRHooks.recognizeTextFromCGImage = { _ in
            ocrCalls += 1
            return []
        }

        viewModel.startDragSelection(at: CGPoint(x: 0.2, y: 0.2), mode: .box)
        try? await Task.sleep(for: .milliseconds(30), clock: .continuous)

        XCTAssertEqual(ocrCalls, 0)
    }

    func testHistoricalOpenUsesDiskBufferFallbackUntilVideoReady() async throws {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        viewModel.setPresentationWorkEnabled(true, reason: "unit-test")

        let frameID = FrameID(value: 42_424_209)
        viewModel.frames = [
            makeVideoTimelineFrame(
                frameID: frameID,
                timestamp: Date(timeIntervalSince1970: 1_700_100_209),
                frameIndex: 9,
                processingStatus: 2
            ),
        ]
        viewModel.currentIndex = 0

        let stillImage = makeSolidImage(size: NSSize(width: 33, height: 33), color: .systemPurple)
        let stillData = try makeJPEGData(stillImage)
        let cacheFileURL = timelineDiskBufferFileURL(frameID: frameID)
        try FileManager.default.createDirectory(
            at: cacheFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try stillData.write(to: cacheFileURL, options: [.atomic])
        defer { try? FileManager.default.removeItem(at: cacheFileURL) }

        let didPreload = await viewModel.prepareHistoricalOpenStillFallbackIfNeeded()

        XCTAssertTrue(didPreload)
        XCTAssertEqual(viewModel.pendingVideoPresentationFrameID, frameID)
        XCTAssertFalse(viewModel.isPendingVideoPresentationReady)
        XCTAssertEqual(viewModel.currentFrameMediaDisplayMode, .decodedVideo)
        XCTAssertEqual(viewModel.currentFrameStillDisplayMode, .waitingFallback)

        let fallbackImage = try XCTUnwrap(viewModel.waitingFallbackImage)
        XCTAssertEqual(Int(fallbackImage.size.width), 33)
        XCTAssertEqual(Int(fallbackImage.size.height), 33)

        viewModel.markVideoPresentationReady(frameID: frameID)

        XCTAssertTrue(viewModel.isPendingVideoPresentationReady)
        XCTAssertEqual(viewModel.currentFrameStillDisplayMode, .none)
        XCTAssertNil(viewModel.waitingFallbackImage)
    }

    func testAdjacentVideoSeekDropsStaleOlderFallbackBeforeNextSeek() async throws {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        viewModel.setPresentationWorkEnabled(true, reason: "unit-test")

        let olderFrameID = FrameID(value: 50_901_532)
        let intermediateFrameID = FrameID(value: 50_901_534)
        let targetFrameID = FrameID(value: 50_901_535)
        viewModel.frames = [
            makeVideoTimelineFrame(
                frameID: olderFrameID,
                timestamp: Date(timeIntervalSince1970: 1_700_100_300),
                frameIndex: 32,
                processingStatus: 2
            ),
            makeVideoTimelineFrame(
                frameID: intermediateFrameID,
                timestamp: Date(timeIntervalSince1970: 1_700_100_301),
                frameIndex: 34,
                processingStatus: 2
            ),
            makeVideoTimelineFrame(
                frameID: targetFrameID,
                timestamp: Date(timeIntervalSince1970: 1_700_100_302),
                frameIndex: 35,
                processingStatus: 2
            ),
        ]
        viewModel.currentIndex = 0

        let fallbackImage = makeSolidImage(size: NSSize(width: 35, height: 35), color: .systemOrange)
        let fallbackData = try makeJPEGData(fallbackImage)
        let cacheFileURL = timelineDiskBufferFileURL(frameID: olderFrameID)
        try FileManager.default.createDirectory(
            at: cacheFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fallbackData.write(to: cacheFileURL, options: [.atomic])
        defer { try? FileManager.default.removeItem(at: cacheFileURL) }

        let didPreload = await viewModel.prepareHistoricalOpenStillFallbackIfNeeded()
        XCTAssertTrue(didPreload)
        XCTAssertEqual(viewModel.waitingFallbackImageFrameID, olderFrameID)

        viewModel.currentIndex = 1

        XCTAssertEqual(viewModel.pendingVideoPresentationFrameID, intermediateFrameID)
        XCTAssertEqual(viewModel.currentFrameStillDisplayMode, .waitingFallback)
        XCTAssertEqual(viewModel.waitingFallbackImageFrameID, olderFrameID)

        viewModel.currentIndex = 2

        XCTAssertEqual(viewModel.pendingVideoPresentationFrameID, targetFrameID)
        XCTAssertEqual(viewModel.currentFrameMediaDisplayMode, .decodedVideo)
        XCTAssertEqual(viewModel.currentFrameStillDisplayMode, .none)
        XCTAssertNil(viewModel.waitingFallbackImage)
        XCTAssertNil(viewModel.waitingFallbackImageFrameID)
    }

    func testCompactPresentationStateClearsPresentationPayloadsButPreservesTimelineState() {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        viewModel.frames = [
            makeTimelineFrame(id: 1, frameIndex: 0, bundleID: "test.app"),
            makeTimelineFrame(id: 2, frameIndex: 1, bundleID: "test.app"),
        ]
        viewModel.currentIndex = 1
        viewModel.searchViewModel.searchQuery = "test query"
        viewModel.currentImage = makeSolidImage(size: NSSize(width: 12, height: 12), color: .systemBlue)
        viewModel.liveScreenshot = makeSolidImage(size: NSSize(width: 10, height: 10), color: .systemGreen)
        viewModel.shiftDragDisplaySnapshot = makeSolidImage(size: NSSize(width: 6, height: 6), color: .systemOrange)
        viewModel.shiftDragDisplaySnapshotFrameID = 2
        viewModel.forceVideoReload = true
        viewModel.isInLiveMode = true
        XCTAssertNotNil(viewModel.currentImage)
        XCTAssertNotNil(viewModel.liveScreenshot)
        XCTAssertNotNil(viewModel.shiftDragDisplaySnapshot)

        viewModel.compactPresentationState(reason: "unit-test", purgeDiskFrameBuffer: false)

        XCTAssertEqual(viewModel.frames.count, 2)
        XCTAssertEqual(viewModel.currentIndex, 1)
        XCTAssertEqual(viewModel.searchViewModel.searchQuery, "test query")
        XCTAssertNil(viewModel.currentImage)
        XCTAssertNil(viewModel.liveScreenshot)
        XCTAssertNil(viewModel.shiftDragDisplaySnapshot)
        XCTAssertNil(viewModel.shiftDragDisplaySnapshotFrameID)
        XCTAssertFalse(viewModel.forceVideoReload)
        XCTAssertFalse(viewModel.isInLiveMode)
    }

    func testCompactPresentationStateClearsHistoricalOpenFallbackState() async throws {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        viewModel.setPresentationWorkEnabled(true, reason: "unit-test")

        let frameID = FrameID(value: 42_424_210)
        viewModel.frames = [
            makeVideoTimelineFrame(
                frameID: frameID,
                timestamp: Date(timeIntervalSince1970: 1_700_100_210),
                frameIndex: 10,
                processingStatus: 2
            ),
        ]
        viewModel.currentIndex = 0

        let stillImage = makeSolidImage(size: NSSize(width: 34, height: 34), color: .systemRed)
        let stillData = try makeJPEGData(stillImage)
        let cacheFileURL = timelineDiskBufferFileURL(frameID: frameID)
        try FileManager.default.createDirectory(
            at: cacheFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try stillData.write(to: cacheFileURL, options: [.atomic])
        defer { try? FileManager.default.removeItem(at: cacheFileURL) }

        let didPreload = await viewModel.prepareHistoricalOpenStillFallbackIfNeeded()
        XCTAssertTrue(didPreload)
        XCTAssertNotNil(viewModel.waitingFallbackImage)
        XCTAssertEqual(viewModel.pendingVideoPresentationFrameID, frameID)

        viewModel.compactPresentationState(reason: "unit-test", purgeDiskFrameBuffer: false)

        XCTAssertNil(viewModel.currentImage)
        XCTAssertNil(viewModel.currentImageFrameID)
        XCTAssertNil(viewModel.waitingFallbackImage)
        XCTAssertNil(viewModel.pendingVideoPresentationFrameID)
        XCTAssertFalse(viewModel.isPendingVideoPresentationReady)
    }

    func testInFlightMostRecentLoadDoesNotRebuildPresentationAfterCompaction() async throws {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        viewModel.setPresentationWorkEnabled(true, reason: "unit-test")
        let frameImageData = try XCTUnwrap(
            makeSolidImage(size: NSSize(width: 16, height: 16), color: .systemTeal).tiffRepresentation
        )
        let fetchStarted = expectation(description: "most recent fetch started")
        var releaseFetch: CheckedContinuation<Void, Never>?
        var dataLoads = 0

        viewModel.test_refreshFrameDataHooks.getMostRecentFramesWithVideoInfo = { _, _ in
            fetchStarted.fulfill()
            await withCheckedContinuation { continuation in
                releaseFetch = continuation
            }
            return [
                self.makeFrameWithVideoInfo(
                    id: 77,
                    timestamp: Date(timeIntervalSince1970: 1_700_100_077),
                    frameIndex: 3
                ),
            ]
        }
        viewModel.test_foregroundFrameLoadHooks.loadFrameData = { _ in
            dataLoads += 1
            return frameImageData
        }

        let loadTask = Task {
            await viewModel.loadMostRecentFrame()
        }

        await fulfillment(of: [fetchStarted], timeout: 1.0)
        viewModel.compactPresentationState(reason: "unit-test", purgeDiskFrameBuffer: false)
        releaseFetch?.resume()
        await loadTask.value

        XCTAssertEqual(viewModel.frames.count, 1)
        XCTAssertNil(viewModel.currentImage)
        XCTAssertEqual(dataLoads, 0)
    }

    func testHiddenRefreshAfterCompactionStaysMetadataOnly() async throws {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        viewModel.setPresentationWorkEnabled(true, reason: "unit-test")
        viewModel.frames = [
            makeTimelineFrame(id: 1, frameIndex: 0, bundleID: "test.app"),
        ]
        viewModel.currentIndex = 0
        viewModel.currentImage = makeSolidImage(size: NSSize(width: 12, height: 12), color: .systemPink)

        let frameImageData = try XCTUnwrap(
            makeSolidImage(size: NSSize(width: 16, height: 16), color: .systemIndigo).tiffRepresentation
        )
        var dataLoads = 0
        viewModel.test_foregroundFrameLoadHooks.loadFrameData = { _ in
            dataLoads += 1
            return frameImageData
        }
        viewModel.test_refreshFrameDataHooks.getMostRecentFramesWithVideoInfo = { _, _ in
            [
                self.makeFrameWithVideoInfo(
                    id: 2,
                    timestamp: Date(timeIntervalSince1970: 1_700_100_100),
                    frameIndex: 1
                ),
            ]
        }

        viewModel.compactPresentationState(reason: "unit-test", purgeDiskFrameBuffer: false)
        await viewModel.refreshFrameData(
            navigateToNewest: true,
            allowNearLiveAutoAdvance: true,
            refreshPresentation: false
        )

        XCTAssertEqual(viewModel.frames.count, 2)
        XCTAssertEqual(viewModel.currentIndex, 1)
        XCTAssertNil(viewModel.currentImage)
        XCTAssertEqual(dataLoads, 0)
    }

    private func makeTimelineFrame(id: Int64, frameIndex: Int, bundleID: String) -> TimelineFrame {
        let frame = FrameReference(
            id: FrameID(value: id),
            timestamp: Date(timeIntervalSince1970: 1_700_100_000 + Double(frameIndex)),
            segmentID: AppSegmentID(value: id),
            frameIndexInSegment: frameIndex,
            metadata: FrameMetadata(
                appBundleID: bundleID,
                appName: "Test App",
                displayID: 1
            )
        )

        return TimelineFrame(frame: frame, videoInfo: nil, processingStatus: 2)
    }

    private func makeFrameWithVideoInfo(id: Int64, timestamp: Date, frameIndex: Int) -> FrameWithVideoInfo {
        let frame = FrameReference(
            id: FrameID(value: id),
            timestamp: timestamp,
            segmentID: AppSegmentID(value: id),
            frameIndexInSegment: frameIndex,
            metadata: FrameMetadata(
                appBundleID: "test.app",
                appName: "Test App",
                displayID: 1
            )
        )
        return FrameWithVideoInfo(frame: frame, videoInfo: nil, processingStatus: 2)
    }

    private func makeVideoTimelineFrame(
        frameID: FrameID,
        timestamp: Date,
        frameIndex: Int,
        processingStatus: Int
    ) -> TimelineFrame {
        let frame = FrameReference(
            id: frameID,
            timestamp: timestamp,
            segmentID: AppSegmentID(value: frameID.value),
            frameIndexInSegment: frameIndex,
            metadata: FrameMetadata(
                appBundleID: "test.app",
                appName: "Test App",
                displayID: 1
            ),
            source: .native
        )

        let videoInfo = FrameVideoInfo(
            videoPath: "/tmp/test-video-\(frameID.value).mp4",
            frameIndex: frameIndex,
            frameRate: 30,
            width: 64,
            height: 64,
            isVideoFinalized: true
        )

        return TimelineFrame(
            frame: frame,
            videoInfo: videoInfo,
            processingStatus: processingStatus
        )
    }

    private func makeSolidImage(size: NSSize, color: NSColor) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        color.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
        image.unlockFocus()
        return image
    }

    private func timelineDiskBufferFileURL(frameID: FrameID) -> URL {
        SimpleTimelineViewModel.timelineDiskFrameBufferFileURL(for: frameID)
    }

    private func makeJPEGData(_ image: NSImage) throws -> Data {
        let tiffData = try XCTUnwrap(image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiffData))
        return try XCTUnwrap(
            bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
        )
    }
}
