import Foundation
import Shared
import XCTest
@testable import Retrace

final class TimelineCommentPresentationSupportTests: XCTestCase {
    func testAllCommentsPresentationPrefersAppNameAndMarksAnchorState() {
        let row = makeTimelineRow(
            commentID: 4,
            author: "Tester",
            appBundleID: "com.apple.Safari",
            appName: "Safari",
            browserURL: "https://example.com",
            tagName: "Work"
        )

        let presentation = TimelineCommentPresentationSupport.makeAllCommentsCardPresentation(
            row: row,
            anchorID: SegmentCommentID(value: 4),
            highlightedID: nil,
            dateFormatter: makeFormatter()
        )

        XCTAssertEqual(presentation.headerLabel, "Safari")
        XCTAssertEqual(presentation.headerSubtitle, "com.apple.Safari")
        XCTAssertEqual(presentation.primaryTagName, "Work")
        XCTAssertEqual(presentation.browserURL, "https://example.com")
        XCTAssertTrue(presentation.isAnchor)
        XCTAssertFalse(presentation.isSearchHighlighted)
    }

    func testAllCommentsPresentationFallsBackToAuthorAndSearchHighlight() {
        let row = makeTimelineRow(
            commentID: 8,
            author: "Tester",
            appBundleID: nil,
            appName: nil,
            browserURL: nil,
            tagName: nil
        )

        let presentation = TimelineCommentPresentationSupport.makeAllCommentsCardPresentation(
            row: row,
            anchorID: SegmentCommentID(value: 2),
            highlightedID: SegmentCommentID(value: 8),
            dateFormatter: makeFormatter()
        )

        XCTAssertEqual(presentation.headerLabel, "Tester")
        XCTAssertNil(presentation.headerSubtitle)
        XCTAssertFalse(presentation.isAnchor)
        XCTAssertTrue(presentation.isSearchHighlighted)
    }

    func testThreadCardPresentationShowsDeleteOnlyForHoveredComment() {
        let comment = makeComment(id: 3, body: "Hello")

        let hovered = TimelineCommentPresentationSupport.makeThreadCommentCardPresentation(
            comment: comment,
            hoveredCommentID: SegmentCommentID(value: 3),
            dateFormatter: makeFormatter()
        )

        let notHovered = TimelineCommentPresentationSupport.makeThreadCommentCardPresentation(
            comment: comment,
            hoveredCommentID: SegmentCommentID(value: 4),
            dateFormatter: makeFormatter()
        )

        XCTAssertEqual(hovered.author, "Tester")
        XCTAssertTrue(hovered.showsDeleteAction)
        XCTAssertFalse(notHovered.showsDeleteAction)
    }

    func testPreviewTextUsesFirstNonEmptyLineAndTruncatesLongBodies() {
        XCTAssertEqual(
            TimelineCommentPresentationSupport.previewText(from: "\n  \nFirst line\nSecond line"),
            "First line"
        )

        let longBody = String(repeating: "a", count: 181)
        XCTAssertEqual(
            TimelineCommentPresentationSupport.previewText(from: longBody),
            String(repeating: "a", count: 180) + "..."
        )
    }

    func testNormalizedLinesAndMarkdownHeadingLevelSupportMarkdownBodyParsing() {
        XCTAssertEqual(
            TimelineCommentPresentationSupport.normalizedLines(from: "One\r\nTwo\rThree"),
            ["One", "Two", "Three"]
        )

        XCTAssertEqual(
            TimelineCommentPresentationSupport.markdownHeadingLevel(in: "### Heading"),
            3
        )

        XCTAssertNil(TimelineCommentPresentationSupport.markdownHeadingLevel(in: "###Heading"))
        XCTAssertNil(TimelineCommentPresentationSupport.markdownHeadingLevel(in: "Body"))
    }

    private func makeTimelineRow(
        commentID: Int64,
        author: String,
        appBundleID: String?,
        appName: String?,
        browserURL: String?,
        tagName: String?
    ) -> CommentTimelineRow {
        CommentTimelineRow(
            comment: makeComment(id: commentID, body: "Hello", author: author),
            context: CommentTimelineSegmentContext(
                segmentID: SegmentID(value: 12),
                appBundleID: appBundleID,
                appName: appName,
                browserURL: browserURL,
                referenceTimestamp: Date(timeIntervalSince1970: 1_000)
            ),
            primaryTagName: tagName
        )
    }

    private func makeComment(
        id: Int64,
        body: String,
        author: String = "Tester"
    ) -> SegmentComment {
        SegmentComment(
            id: SegmentCommentID(value: id),
            body: body,
            author: author,
            createdAt: Date(timeIntervalSince1970: TimeInterval(id)),
            updatedAt: Date(timeIntervalSince1970: TimeInterval(id))
        )
    }

    private func makeFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "MMM d, h:mm a"
        return formatter
    }
}
