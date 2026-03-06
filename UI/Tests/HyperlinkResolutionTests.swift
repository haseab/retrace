import XCTest
@testable import Retrace

final class HyperlinkResolutionTests: XCTestCase {
    @MainActor
    func testResolveStoredHyperlinkURLKeepsAbsoluteURLs() {
        XCTAssertEqual(
            SimpleTimelineViewModel.resolveStoredHyperlinkURL(
                "https://example.com/docs",
                baseURL: "https://retrace.to/current"
            ),
            "https://example.com/docs"
        )
    }

    @MainActor
    func testResolveStoredHyperlinkURLExpandsRelativeURLsAgainstCurrentHost() {
        XCTAssertEqual(
            SimpleTimelineViewModel.resolveStoredHyperlinkURL(
                "/pricing?ref=timeline",
                baseURL: "https://retrace.to/docs/current"
            ),
            "https://retrace.to/pricing?ref=timeline"
        )
    }

    @MainActor
    func testHyperlinkBrowserApplicationURLPrefersResolvedDefaultBrowser() {
        let defaultBrowserURL = URL(fileURLWithPath: "/Applications/Arc.app")

        XCTAssertEqual(
            SimpleTimelineViewModel.hyperlinkBrowserApplicationURL(
                for: URL(string: "https://example.com")!,
                browserResolver: { _ in defaultBrowserURL }
            ),
            defaultBrowserURL
        )
    }

    @MainActor
    func testHyperlinkBrowserApplicationURLReturnsNilWhenDefaultBrowserLookupFails() {
        XCTAssertNil(
            SimpleTimelineViewModel.hyperlinkBrowserApplicationURL(
                for: URL(string: "https://example.com")!,
                browserResolver: { _ in nil }
            )
        )
    }

    @MainActor
    func testYouTubeTimestampedBrowserURLStringAppendsTQueryItem() {
        XCTAssertEqual(
            SimpleTimelineViewModel.youtubeTimestampedBrowserURLString(
                "https://www.youtube.com/watch?v=abc123&list=queue",
                videoCurrentTime: 95.8
            ),
            "https://www.youtube.com/watch?v=abc123&list=queue&t=95"
        )
    }

    @MainActor
    func testYouTubeTimestampedBrowserURLStringReplacesExistingTQueryItem() {
        XCTAssertEqual(
            SimpleTimelineViewModel.youtubeTimestampedBrowserURLString(
                "https://www.youtube.com/watch?v=abc123&t=12",
                videoCurrentTime: 301.2
            ),
            "https://www.youtube.com/watch?v=abc123&t=301"
        )
    }

    @MainActor
    func testYouTubeTimestampedBrowserURLStringLeavesNonYouTubeURLUntouched() {
        XCTAssertEqual(
            SimpleTimelineViewModel.youtubeTimestampedBrowserURLString(
                "https://example.com/watch?v=abc123",
                videoCurrentTime: 42
            ),
            "https://example.com/watch?v=abc123"
        )
    }

    @MainActor
    func testAppendingSmartTextFragmentAddsDirectiveWhenNoFragmentExists() {
        XCTAssertEqual(
            SimpleTimelineViewModel.appendingSmartTextFragment(
                to: "https://example.com/article?id=1",
                directive: ":~:text=hello%20world"
            ),
            "https://example.com/article?id=1#:~:text=hello%20world"
        )
    }

    @MainActor
    func testAppendingSmartTextFragmentPreservesExistingFragmentAnchor() {
        XCTAssertEqual(
            SimpleTimelineViewModel.appendingSmartTextFragment(
                to: "https://example.com/article#section-2",
                directive: ":~:text=hello%20world"
            ),
            "https://example.com/article#section-2:~:text=hello%20world"
        )
    }
}
