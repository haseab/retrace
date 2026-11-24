import XCTest
import Shared
import App
@testable import Retrace

@MainActor
final class PinnedDisplayPresentationTests: XCTestCase {
    private func frame(_ id: Int64, display: UInt32, timestamp: Double) -> FrameWithVideoInfo {
        FrameWithVideoInfo(
            frame: FrameReference(id: FrameID(value: id), timestamp: Date(timeIntervalSince1970: timestamp),
                segmentID: AppSegmentID(value: id), videoID: VideoSegmentID(value: id), frameIndexInSegment: 0,
                metadata: FrameMetadata(appBundleID: "com.example.editor", browserURL: "https://example.com/display/\(display)",
                    displayID: display, isFocused: display == 1)),
            videoInfo: FrameVideoInfo(videoPath: "/tmp/example-\(id).mp4", frameIndex: 0, frameRate: 30),
            processingStatus: 2)
    }

    func testPinnedFrameDrivesVideoMetadataAndOCRWhileTapeKeepsAnchorTimestamp() async throws {
        let vm = SimpleTimelineViewModel(coordinator: AppCoordinator())
        let anchor = frame(9_000_000_001, display: 1, timestamp: 100)
        let secondary = frame(9_000_000_002, display: 2, timestamp: 90)
        vm.test_setBoundaryPaginationState(hasMoreOlder: false, hasMoreNewer: false)
        vm.test_foregroundFrameLoadHooks.loadFrameData = { _ in Data() }
        vm.frames = [TimelineFrame(frameWithVideoInfo: anchor)]
        vm.primaryDisplayID = 2
        vm.isPrimaryDisplayPinned = true
        vm.test_frameOverlayLoadHooks.getNearestDisplayFrame = { display, timestamp in
            XCTAssertEqual(display, 2)
            XCTAssertEqual(timestamp, anchor.frame.timestamp)
            return secondary
        }
        let ocrLoaded = expectation(description: "OCR uses pinned frame ID")
        ocrLoaded.assertForOverFulfill = false
        vm.test_frameOverlayLoadHooks.getOCRStatus = { id in
            XCTAssertEqual(id, secondary.frame.id)
            return .completed
        }
        vm.test_frameOverlayLoadHooks.getAllOCRNodes = { id, _ in
            XCTAssertEqual(id, secondary.frame.id)
            ocrLoaded.fulfill()
            return []
        }
        vm.test_frameOverlayLoadHooks.getURLBoundingBox = { _, _ in nil }
        vm.setPresentationWorkEnabled(true, reason: "test")
        XCTAssertNil(vm.currentFrame)
        XCTAssertNil(vm.displayedPrimaryVideoInfo)
        await vm.updateSecondaryDisplayFrames()
        XCTAssertEqual(vm.currentFrame?.id, secondary.frame.id)
        XCTAssertEqual(vm.currentFrame?.metadata.browserURL, secondary.frame.metadata.browserURL)
        XCTAssertEqual(vm.displayedPrimaryVideoInfo?.videoPath, secondary.videoInfo?.videoPath)
        XCTAssertEqual(vm.currentTimestamp, anchor.frame.timestamp)
        XCTAssertEqual(vm.currentTapeFrame?.frame.id, anchor.frame.id)
        await fulfillment(of: [ocrLoaded], timeout: 3)
        vm.setPresentationWorkEnabled(false, reason: "test cleanup")
    }

    func testLatePinnedLookupCannotPublishAfterDisplaySelectionChanges() async {
        let vm = SimpleTimelineViewModel(coordinator: AppCoordinator())
        let anchor = frame(9_000_000_001, display: 1, timestamp: 100)
        let secondary = frame(9_000_000_002, display: 2, timestamp: 90)
        vm.test_setBoundaryPaginationState(hasMoreOlder: false, hasMoreNewer: false)
        vm.test_foregroundFrameLoadHooks.loadFrameData = { _ in Data() }
        vm.frames = [TimelineFrame(frameWithVideoInfo: anchor)]
        vm.primaryDisplayID = 2
        vm.isPrimaryDisplayPinned = true
        vm.test_frameOverlayLoadHooks.getNearestDisplayFrame = { _, _ in
            vm.primaryDisplayID = 3
            return secondary
        }
        await vm.updateSecondaryDisplayFrames()
        XCTAssertNil(vm.currentFrame)
        XCTAssertNil(vm.displayedPrimaryVideoInfo)
    }

    func testDeletePinnedCarryForwardFrameDoesNotDeleteUnionTapeAnchor() async {
        let vm = SimpleTimelineViewModel(coordinator: AppCoordinator())
        let anchor = frame(9_000_000_001, display: 1, timestamp: 100)
        let secondary = frame(9_000_000_002, display: 2, timestamp: 90)
        vm.test_setBoundaryPaginationState(hasMoreOlder: false, hasMoreNewer: false)
        vm.test_foregroundFrameLoadHooks.loadFrameData = { _ in Data() }
        vm.frames = [TimelineFrame(frameWithVideoInfo: anchor)]
        vm.primaryDisplayID = 2
        vm.isPrimaryDisplayPinned = true
        vm.test_frameOverlayLoadHooks.getNearestDisplayFrame = { _, _ in secondary }
        await vm.updateSecondaryDisplayFrames()
        vm.selectedFrameIndex = vm.currentIndex
        vm.confirmDeleteSelectedFrame()
        XCTAssertEqual(vm.frames.map { $0.frame.id }, [anchor.frame.id])
        XCTAssertNil(vm.currentFrame)
        vm.undoPendingDelete()
        await vm.updateSecondaryDisplayFrames()
        XCTAssertEqual(vm.currentFrame?.id, secondary.frame.id)
        XCTAssertEqual(vm.frames.map { $0.frame.id }, [anchor.frame.id])
    }

    func testExternalDeletionInvalidatesPinnedFrameAndUnionTapeWithoutRefresh() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let services = ServiceContainer(databasePath: root.appendingPathComponent("test.db").path,
            storageConfig: StorageConfig(storageRootPath: root.path),
            storageCrashReportDirectory: root.appendingPathComponent("crash").path)
        let db = await services.database
        try await db.initialize()
        let timestamp = Date(timeIntervalSince1970: 100)
        let segmentID = try await db.insertSegment(bundleID: "com.example.editor", startDate: timestamp,
            endDate: timestamp, windowName: nil, browserUrl: nil, type: 0)
        let id = try await db.insertFrame(FrameReference(id: FrameID(value: 0), timestamp: timestamp,
            segmentID: AppSegmentID(value: segmentID), videoID: VideoSegmentID(value: 0), frameIndexInSegment: 0,
            metadata: FrameMetadata(appBundleID: "com.example.editor", displayID: 2)))
        let coordinator = AppCoordinator(services: services)
        let vm = SimpleTimelineViewModel(coordinator: coordinator)
        let anchor = frame(9_000_000_001, display: 1, timestamp: 101)
        let secondary = frame(id, display: 2, timestamp: 100)
        vm.test_setBoundaryPaginationState(hasMoreOlder: false, hasMoreNewer: false)
        vm.test_foregroundFrameLoadHooks.loadFrameData = { _ in Data() }
        vm.frames = [TimelineFrame(frameWithVideoInfo: anchor), TimelineFrame(frameWithVideoInfo: secondary)]
        vm.primaryDisplayID = 2
        vm.isPrimaryDisplayPinned = true
        vm.test_frameOverlayLoadHooks.getNearestDisplayFrame = { _, _ in
            try await db.getFrame(id: FrameID(value: id)) == nil ? nil : secondary
        }
        await vm.updateSecondaryDisplayFrames()
        XCTAssertEqual(vm.currentFrame?.id, FrameID(value: id))
        _ = try await coordinator.deleteFrame(frameID: FrameID(value: id), timestamp: secondary.frame.timestamp, source: .native)
        let deleted = try await db.getFrame(id: FrameID(value: id))
        XCTAssertNil(deleted)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertNil(vm.currentFrame)
        XCTAssertNil(vm.displayedPrimaryVideoInfo)
        XCTAssertEqual(vm.frames.map { $0.frame.id }, [anchor.frame.id])
        try await db.close()
    }
}
