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
        showHighlight("create a feature", on: viewModel)

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
        showHighlight("error message", on: viewModel)

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
        showHighlight("create a feature, launch", on: viewModel)

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
        showHighlight("  create a feature  ,   launch   ", on: viewModel)

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
        showHighlight("error, message, handler", on: viewModel)

        let lines = viewModel.highlightedSearchTextLines()

        XCTAssertEqual(lines, ["Error message", "Error handler"])
    }

    func testInFrameSearchReturnsSpecificWordRangeWithinNode() {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        viewModel.ocrNodes = [
            makeNode(id: 1, text: "Fatal error occurred")
        ]
        showHighlight("error", on: viewModel)

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
        showHighlight("\"error occurred\"", on: viewModel)

        let matches = viewModel.searchHighlightNodes

        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].ranges.count, 1)
        XCTAssertEqual(String(matches[0].node.text[matches[0].ranges[0]]), "error occurred")
    }

    func testSearchResultModeTreatsCommandLikeQueryAsIndividualTerms() {
        let nodes = [
            makeNode(id: 1, text: "osascript"),
            makeNode(id: 2, text: "tell application"),
            makeNode(id: 3, text: "\"Codex\" to hide"),
            makeNode(id: 4, text: "delay 1"),
            makeNode(id: 5, text: "go to search settings"),
            makeNode(id: 6, text: "window 1"),
            makeNode(id: 7, text: "completely unrelated")
        ]

        let matches = SimpleTimelineViewModel.searchHighlightMatches(
            in: nodes,
            query: #"osascript -e 'tell application "Codex" to hide' -e 'delay 1'"#,
            mode: .matchedNodes
        )

        XCTAssertEqual(matches.map(\.node.id), [1, 2, 3, 4])
        XCTAssertTrue(matches.allSatisfy { $0.ranges.isEmpty })
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

    private func showHighlight(_ query: String, on viewModel: SimpleTimelineViewModel) {
        viewModel.showSearchHighlight(
            query: query,
            mode: .matchedTextRanges,
            delay: 0
        )
    }
}
