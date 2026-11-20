import App
import Shared
import XCTest
@testable import Retrace

final class HyperlinkMappingTests: XCTestCase {
    func testHyperlinkMatchesFromStoredRowsUsesPrimaryKeyNodeIDs() {
        let rows = [
            AppCoordinator.FrameInPageURLRow(
                order: 0,
                url: "https://retrace.to/help",
                nodeID: 42
            )
        ]
        let nodes = [
            OCRNodeWithText(
                id: 42,
                nodeOrder: 7,
                frameId: 99,
                x: 0.1,
                y: 0.2,
                width: 0.3,
                height: 0.05,
                text: "Primary key match"
            )
        ]

        let matches = SimpleTimelineViewModel.hyperlinkMatchesFromStoredRows(rows, nodes: nodes)

        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].nodeText, "Primary key match")
    }

    func testHyperlinkMatchesFromStoredRowsUsesResolvedNodeGeometry() {
        let rows = [
            AppCoordinator.FrameInPageURLRow(
                order: 0,
                url: "https://retrace.to/help",
                nodeID: 42
            )
        ]
        let nodes = [
            OCRNodeWithText(
                id: 42,
                nodeOrder: 7,
                frameId: 99,
                x: 0.1,
                y: 0.2,
                width: 0.3,
                height: 0.05,
                text: "Primary key match"
            )
        ]

        let matches = SimpleTimelineViewModel.hyperlinkMatchesFromStoredRows(rows, nodes: nodes)

        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].x, 0.1)
        XCTAssertEqual(matches[0].y, 0.2)
        XCTAssertEqual(matches[0].width, 0.3)
        XCTAssertEqual(matches[0].height, 0.05)
    }

    func testHyperlinkMatchesFromStoredRowsFallsBackToLegacyNodeOrderRows() {
        let rows = [
            AppCoordinator.FrameInPageURLRow(
                order: 0,
                url: "https://retrace.to/help",
                nodeID: 7
            )
        ]
        let nodes = [
            OCRNodeWithText(
                id: 42,
                nodeOrder: 7,
                frameId: 99,
                x: 0.1,
                y: 0.2,
                width: 0.3,
                height: 0.05,
                text: "Legacy nodeOrder match"
            )
        ]

        let matches = SimpleTimelineViewModel.hyperlinkMatchesFromStoredRows(rows, nodes: nodes)

        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].nodeText, "Legacy nodeOrder match")
    }

    func testHyperlinkMatchesFromStoredRowsDropsRowWhenNodeIsMissing() {
        let rows = [
            AppCoordinator.FrameInPageURLRow(
                order: 0,
                url: "https://retrace.to/help",
                nodeID: 999
            )
        ]

        let matches = SimpleTimelineViewModel.hyperlinkMatchesFromStoredRows(rows, nodes: [])

        XCTAssertTrue(matches.isEmpty)
    }

    func testHyperlinkMatchesFromStoredRowsIgnoresDuplicateOCRNodeIDs() {
        let rows = [
            AppCoordinator.FrameInPageURLRow(
                order: 0,
                url: "https://retrace.to/watchdog",
                nodeID: 5_069_399_747
            )
        ]
        let nodes = [
            OCRNodeWithText(
                id: 5_069_399_747,
                nodeOrder: 3,
                frameId: 42,
                x: 0.1,
                y: 0.2,
                width: 0.3,
                height: 0.05,
                text: "Primary link text"
            ),
            OCRNodeWithText(
                id: 5_069_399_747,
                nodeOrder: 3,
                frameId: 42,
                x: 0.1,
                y: 0.25,
                width: 0.3,
                height: 0.05,
                text: "Duplicate link text"
            )
        ]

        let matches = SimpleTimelineViewModel.hyperlinkMatchesFromStoredRows(rows, nodes: nodes)

        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].nodeText, "Primary link text")
        XCTAssertEqual(matches[0].url, "https://retrace.to/watchdog")
    }
}
