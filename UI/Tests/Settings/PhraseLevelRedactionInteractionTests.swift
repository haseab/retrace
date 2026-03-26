import XCTest
import AppKit
import Combine
import Shared
import App
@testable import Retrace

@MainActor
final class PhraseLevelRedactionInteractionTests: XCTestCase {
    func testPhraseLevelRedactionTooltipStateUsesCopyTextAfterReveal() {
        let state = SimpleTimelineViewModel.phraseLevelRedactionTooltipState(
            for: 7,
            isRevealed: true
        )

        XCTAssertEqual(state, .copyText)
        XCTAssertEqual(state?.title, "Copy text")
    }

    func testCopyablePhraseLevelRedactionTextPrefersVisiblePlaintext() {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        let node = OCRNodeWithText(
            id: 101,
            nodeOrder: 0,
            frameId: 1,
            x: 0.20,
            y: 0.25,
            width: 0.18,
            height: 0.05,
            text: "revealed text",
            encryptedText: "rtx1.mock",
            isRedacted: true
        )

        viewModel.ocrNodes = [node]

        XCTAssertEqual(viewModel.copyablePhraseLevelRedactionText(for: node), "revealed text")
    }
}
