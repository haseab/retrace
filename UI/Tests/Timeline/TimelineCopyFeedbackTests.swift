import XCTest
import AppKit
import Shared
import App
@testable import Retrace

@MainActor
final class TimelineCopyFeedbackTests: XCTestCase {
    func testCopySelectedTextShowsToast() {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        viewModel.ocrNodes = [
            makeNode(id: 1, text: "Alpha", x: 0.10, y: 0.10, width: 0.18, height: 0.08),
            makeNode(id: 2, text: "Beta", x: 0.32, y: 0.10, width: 0.16, height: 0.08)
        ]
        viewModel.selectionStart = (nodeID: 1, charIndex: 0)
        viewModel.selectionEnd = (nodeID: 2, charIndex: 4)

        viewModel.copySelectedText()

        XCTAssertEqual(viewModel.toastMessage, "Text copied")
        XCTAssertEqual(viewModel.toastIcon, "doc.on.doc.fill")
    }

    func testCopyZoomedRegionTextShowsToast() {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        viewModel.ocrNodes = [
            makeNode(id: 1, text: "Alpha", x: 0.10, y: 0.10, width: 0.18, height: 0.08),
            makeNode(id: 2, text: "Beta", x: 0.62, y: 0.10, width: 0.16, height: 0.08)
        ]
        viewModel.zoomRegion = CGRect(x: 0.0, y: 0.0, width: 0.5, height: 0.5)
        viewModel.isZoomRegionActive = true

        viewModel.copyZoomedRegionText()

        XCTAssertEqual(viewModel.toastMessage, "Text copied")
        XCTAssertEqual(viewModel.toastIcon, "doc.on.doc.fill")
    }

    func testCopyCurrentFrameImageShowsToastInLiveMode() {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        viewModel.isInLiveMode = true
        viewModel.liveScreenshot = makeImage(size: NSSize(width: 12, height: 12))

        viewModel.copyCurrentFrameImageToClipboard()

        XCTAssertEqual(viewModel.toastMessage, "Image copied")
        XCTAssertEqual(viewModel.toastIcon, "checkmark.circle.fill")
    }

    private func makeNode(
        id: Int,
        text: String,
        x: CGFloat,
        y: CGFloat,
        width: CGFloat,
        height: CGFloat
    ) -> OCRNodeWithText {
        OCRNodeWithText(
            id: id,
            frameId: 1,
            x: x,
            y: y,
            width: width,
            height: height,
            text: text
        )
    }

    private func makeImage(size: NSSize) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
        image.unlockFocus()
        return image
    }
}
