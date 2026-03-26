import XCTest
import AppKit
import Combine
import Shared
import App
@testable import Retrace

@MainActor
final class SearchHighlightQueryParsingTests: XCTestCase {
    func testSearchTreatsFullInputAsExactPhrase() {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        viewModel.ocrNodes = [
            makeNode(id: 1, text: "Create a feature quickly"),
            makeNode(id: 2, text: "Create a feature branch"),
            makeNode(id: 3, text: "Feature quickly")
        ]
        viewModel.searchHighlightQuery = "create a feature"
        viewModel.isShowingSearchHighlight = true

        let matches = viewModel.searchHighlightNodes

        XCTAssertEqual(matches.map(\.node.id), [1, 2])
        XCTAssertEqual(matches.first?.ranges.count, 1)
        XCTAssertEqual(String(matches[0].node.text[matches[0].ranges[0]]), "Create a feature")
    }

    func testSearchDoesNotSplitSpacesIntoSeparateTerms() {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        viewModel.ocrNodes = [
            makeNode(id: 1, text: "Error message handler"),
            makeNode(id: 2, text: "Error handler"),
            makeNode(id: 3, text: "Message handler")
        ]
        viewModel.searchHighlightQuery = "error message"
        viewModel.isShowingSearchHighlight = true

        let matches = viewModel.searchHighlightNodes

        XCTAssertEqual(matches.map(\.node.id), [1])
    }

    func testSearchSplitsCommaSeparatedPhrases() {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        viewModel.ocrNodes = [
            makeNode(id: 1, text: "Create a feature quickly"),
            makeNode(id: 2, text: "Launch checklist"),
            makeNode(id: 3, text: "Status table")
        ]
        viewModel.searchHighlightQuery = "create a feature, launch"
        viewModel.isShowingSearchHighlight = true

        let matches = viewModel.searchHighlightNodes

        XCTAssertEqual(matches.map(\.node.id), [1, 2])
        XCTAssertEqual(matches.first?.ranges.count, 1)
    }

    func testSearchTrimsWhitespaceAroundCommaSeparatedPhrases() {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        viewModel.ocrNodes = [
            makeNode(id: 1, text: "Create a feature quickly"),
            makeNode(id: 2, text: "Launch checklist"),
            makeNode(id: 3, text: "Status table")
        ]
        viewModel.searchHighlightQuery = "  create a feature  ,   launch   "
        viewModel.isShowingSearchHighlight = true

        let matches = viewModel.searchHighlightNodes

        XCTAssertEqual(matches.map(\.node.id), [1, 2])
    }

    func testHighlightedSearchTextLinesGroupsByVisualLine() {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        viewModel.ocrNodes = [
            makeNode(id: 1, text: "Error", x: 0.10, y: 0.10),
            makeNode(id: 2, text: "message", x: 0.24, y: 0.11),
            makeNode(id: 3, text: "Error", x: 0.10, y: 0.22),
            makeNode(id: 4, text: "handler", x: 0.24, y: 0.23)
        ]
        viewModel.searchHighlightQuery = "error, message, handler"
        viewModel.isShowingSearchHighlight = true

        let lines = viewModel.highlightedSearchTextLines()

        XCTAssertEqual(lines, ["Error message", "Error handler"])
    }

    func testInFrameSearchReturnsSpecificWordRangeWithinNode() {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        viewModel.ocrNodes = [
            makeNode(id: 1, text: "Fatal error occurred")
        ]
        viewModel.searchHighlightQuery = "error"
        viewModel.isShowingSearchHighlight = true

        let matches = viewModel.searchHighlightNodes

        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].node.id, 1)
        XCTAssertEqual(matches[0].ranges.count, 1)
        XCTAssertEqual(String(matches[0].node.text[matches[0].ranges[0]]), "error")
    }

    func testInFrameSearchReturnsSpecificPhraseRangeWithinNode() {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        viewModel.ocrNodes = [
            makeNode(id: 1, text: "Fatal error occurred")
        ]
        viewModel.searchHighlightQuery = "\"error occurred\""
        viewModel.isShowingSearchHighlight = true

        let matches = viewModel.searchHighlightNodes

        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].ranges.count, 1)
        XCTAssertEqual(String(matches[0].node.text[matches[0].ranges[0]]), "error occurred")
    }

    private func makeNode(id: Int, text: String, x: CGFloat = 0.1, y: CGFloat = 0.1) -> OCRNodeWithText {
        OCRNodeWithText(
            id: id,
            frameId: 1,
            x: x,
            y: y,
            width: 0.3,
            height: 0.1,
            text: text
        )
    }
}
