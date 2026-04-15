import AppKit
import Shared
import XCTest
@testable import Retrace

@MainActor
final class TimelineCommentTargetPreviewControllerTests: XCTestCase {
    func testRefreshShowsLiveScreenshotWithoutLoadingFrame() async {
        let controller = TimelineCommentTargetPreviewController()
        let liveScreenshot = makeImage()
        var loadedFrameID: FrameID?

        await controller.refresh(
            context: TimelineCommentTargetPreviewContext(
                isInLiveMode: true,
                liveScreenshot: liveScreenshot,
                targetFrameID: FrameID(value: 4)
            )
        ) { frameID in
            loadedFrameID = frameID
            return nil
        }

        XCTAssertTrue(controller.previewImage === liveScreenshot)
        XCTAssertFalse(controller.isLoading)
        XCTAssertNil(loadedFrameID)
    }

    func testRefreshClearsPreviewWhenNoTargetFrameExists() async {
        let controller = TimelineCommentTargetPreviewController()

        await controller.refresh(
            context: TimelineCommentTargetPreviewContext(
                isInLiveMode: false,
                liveScreenshot: nil,
                targetFrameID: nil
            )
        ) { _ in
            XCTFail("frame loader should not be called")
            return nil
        }

        XCTAssertNil(controller.previewImage)
        XCTAssertFalse(controller.isLoading)
    }

    func testRefreshLoadsFramePreview() async {
        let controller = TimelineCommentTargetPreviewController()
        let loadedImage = makeImage()

        await controller.refresh(
            context: TimelineCommentTargetPreviewContext(
                isInLiveMode: false,
                liveScreenshot: nil,
                targetFrameID: FrameID(value: 9)
            )
        ) { frameID in
            XCTAssertEqual(frameID, FrameID(value: 9))
            return loadedImage
        }

        XCTAssertTrue(controller.previewImage === loadedImage)
        XCTAssertFalse(controller.isLoading)
    }

    func testRefreshIgnoresStaleInFlightLoad() async {
        let controller = TimelineCommentTargetPreviewController()
        let olderImage = makeImage()
        let newerImage = makeImage()
        let olderStarted = expectation(description: "older load started")
        var continuation: CheckedContinuation<NSImage?, Never>?

        let olderTask = Task { @MainActor in
            await controller.refresh(
                context: TimelineCommentTargetPreviewContext(
                    isInLiveMode: false,
                    liveScreenshot: nil,
                    targetFrameID: FrameID(value: 10)
                )
            ) { _ in
                olderStarted.fulfill()
                return await withCheckedContinuation { continuation = $0 }
            }
        }

        await fulfillment(of: [olderStarted], timeout: 0.2)

        await controller.refresh(
            context: TimelineCommentTargetPreviewContext(
                isInLiveMode: false,
                liveScreenshot: nil,
                targetFrameID: FrameID(value: 11)
            )
        ) { _ in
            newerImage
        }

        continuation?.resume(returning: olderImage)
        _ = await olderTask.result

        XCTAssertTrue(controller.previewImage === newerImage)
        XCTAssertFalse(controller.isLoading)
    }

    func testResetClearsPreviewAndLoadingState() {
        let controller = TimelineCommentTargetPreviewController()
        let expectation = expectation(description: "load started")
        var continuation: CheckedContinuation<NSImage?, Never>?

        Task { @MainActor in
            await controller.refresh(
                context: TimelineCommentTargetPreviewContext(
                    isInLiveMode: false,
                    liveScreenshot: nil,
                    targetFrameID: FrameID(value: 12)
                )
            ) { _ in
                expectation.fulfill()
                return await withCheckedContinuation { continuation = $0 }
            }
        }

        wait(for: [expectation], timeout: 0.2)
        XCTAssertTrue(controller.isLoading)

        controller.reset()
        continuation?.resume(returning: makeImage())

        XCTAssertNil(controller.previewImage)
        XCTAssertFalse(controller.isLoading)
    }

    private func makeImage() -> NSImage {
        NSImage(size: NSSize(width: 2, height: 2))
    }
}
