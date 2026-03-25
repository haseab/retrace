import XCTest
@testable import Retrace
import Shared
import App

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
    func testInPageURLLinkMetricMetadataIncludesURLLinkTextAndNodeID() throws {
        let metadata = try XCTUnwrap(
            SimpleTimelineViewModel.inPageURLLinkMetricMetadata(
                url: "https://retrace.to/pricing?ref=timeline",
                linkText: "Pricing",
                nodeID: 7
            )
        )

        let data = try XCTUnwrap(metadata.data(using: .utf8))
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
        )

        XCTAssertEqual(payload["url"] as? String, "https://retrace.to/pricing?ref=timeline")
        XCTAssertEqual(payload["linkText"] as? String, "Pricing")
        XCTAssertEqual(payload["nodeID"] as? Int, 7)
    }

    @MainActor
    func testBeginInPageURLHoverTrackingSuppressesDuplicateContinuousHover() {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())

        XCTAssertTrue(
            viewModel.beginInPageURLHoverTracking(
                url: "https://retrace.to/pricing?ref=timeline",
                nodeID: 7,
                frameID: FrameID(value: 42)
            )
        )
        XCTAssertFalse(
            viewModel.beginInPageURLHoverTracking(
                url: "https://retrace.to/pricing?ref=timeline",
                nodeID: 7,
                frameID: FrameID(value: 42)
            )
        )

        viewModel.endInPageURLHoverTracking()

        XCTAssertTrue(
            viewModel.beginInPageURLHoverTracking(
                url: "https://retrace.to/pricing?ref=timeline",
                nodeID: 7,
                frameID: FrameID(value: 42)
            )
        )
    }

    @MainActor
    func testBeginInPageURLHoverTrackingTreatsFrameChangesAsDistinctHovers() {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())

        XCTAssertTrue(
            viewModel.beginInPageURLHoverTracking(
                url: "https://retrace.to/pricing?ref=timeline",
                nodeID: 7,
                frameID: FrameID(value: 42)
            )
        )
        XCTAssertTrue(
            viewModel.beginInPageURLHoverTracking(
                url: "https://retrace.to/pricing?ref=timeline",
                nodeID: 7,
                frameID: FrameID(value: 43)
            )
        )
    }

    @MainActor
    func testURLOverlayViewOutlineRectAddsPaddingAroundDetectedURL() {
        let rawRect = CGRect(x: 20, y: 12, width: 120, height: 24)
        let outlineRect = URLOverlayView.outlineRect(for: rawRect)

        XCTAssertEqual(outlineRect.origin.x, 16)
        XCTAssertEqual(outlineRect.origin.y, 8)
        XCTAssertEqual(outlineRect.width, 128)
        XCTAssertEqual(outlineRect.height, 32)
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
    func testResolveYouTubeOCRMatchFindsShiftedMetadataColumnOnWideLayouts() throws {
        let match = try XCTUnwrap(
            SimpleTimelineViewModel.resolveYouTubeOCRMatch(
                windowName: "Why This Layout Breaks OCR - YouTube",
                nodes: [
                    makeYouTubeOCRNode(
                        id: 1,
                        text: "Why This Layout Breaks OCR",
                        x: 0.22,
                        y: 0.18,
                        width: 0.18,
                        height: 0.038
                    ),
                    makeYouTubeOCRNode(
                        id: 2,
                        text: "Veritasium",
                        x: 0.43,
                        y: 0.27,
                        width: 0.11,
                        height: 0.028
                    ),
                    makeYouTubeOCRNode(
                        id: 3,
                        text: "17.3M subscribers",
                        x: 0.43,
                        y: 0.31,
                        width: 0.15,
                        height: 0.026
                    ),
                    makeYouTubeOCRNode(
                        id: 4,
                        text: "Up next",
                        x: 0.74,
                        y: 0.27,
                        width: 0.10,
                        height: 0.028
                    )
                ]
            )
        )

        XCTAssertEqual(match.titleText, "Why This Layout Breaks OCR")
        XCTAssertEqual(match.channelText, "Veritasium")
    }

    @MainActor
    func testResolveYouTubeOCRMatchIgnoresGenericUiLabelsWhenSubscriberLineIsMissing() throws {
        let match = try XCTUnwrap(
            SimpleTimelineViewModel.resolveYouTubeOCRMatch(
                windowName: "Building For Multiple Displays - YouTube",
                nodes: [
                    makeYouTubeOCRNode(
                        id: 1,
                        text: "Building For Multiple Displays",
                        x: 0.21,
                        y: 0.17,
                        width: 0.20,
                        height: 0.04
                    ),
                    makeYouTubeOCRNode(
                        id: 2,
                        text: "More",
                        x: 0.40,
                        y: 0.27,
                        width: 0.05,
                        height: 0.024
                    ),
                    makeYouTubeOCRNode(
                        id: 3,
                        text: "Practical Engineering",
                        x: 0.43,
                        y: 0.28,
                        width: 0.16,
                        height: 0.03
                    ),
                    makeYouTubeOCRNode(
                        id: 4,
                        text: "Autoplay",
                        x: 0.68,
                        y: 0.28,
                        width: 0.09,
                        height: 0.028
                    )
                ]
            )
        )

        XCTAssertEqual(match.titleText, "Building For Multiple Displays")
        XCTAssertEqual(match.channelText, "Practical Engineering")
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

    @MainActor
    func testCurrentFrameMediaDisplayModePrefersExactDiskBufferStillForVideoFrames() {
        XCTAssertEqual(
            SimpleTimelineViewModel.resolveCurrentFrameMediaDisplayMode(
                currentFrameID: FrameID(value: 42),
                currentImageFrameID: FrameID(value: 42),
                hasCurrentImage: true,
                hasVideo: true
            ),
            .still
        )
    }

    @MainActor
    func testCurrentFrameMediaDisplayModeRejectsMismatchedStillAndUsesDecodedVideo() {
        XCTAssertEqual(
            SimpleTimelineViewModel.resolveCurrentFrameMediaDisplayMode(
                currentFrameID: FrameID(value: 77),
                currentImageFrameID: FrameID(value: 76),
                hasCurrentImage: true,
                hasVideo: true
            ),
            .decodedVideo
        )
    }

    @MainActor
    func testCurrentFrameMediaDisplayModePrefersAnyExactStillForVideoFrames() {
        XCTAssertEqual(
            SimpleTimelineViewModel.resolveCurrentFrameMediaDisplayMode(
                currentFrameID: FrameID(value: 91),
                currentImageFrameID: FrameID(value: 91),
                hasCurrentImage: true,
                hasVideo: true
            ),
            .still
        )
    }

    @MainActor
    func testCurrentFrameMediaDisplayModeKeepsStillForNonVideoFrames() {
        XCTAssertEqual(
            SimpleTimelineViewModel.resolveCurrentFrameMediaDisplayMode(
                currentFrameID: FrameID(value: 103),
                currentImageFrameID: FrameID(value: 103),
                hasCurrentImage: true,
                hasVideo: false
            ),
            .still
        )
    }

    @MainActor
    func testCurrentFrameMediaDisplayModeReturnsNoContentWithoutFrame() {
        XCTAssertEqual(
            SimpleTimelineViewModel.resolveCurrentFrameMediaDisplayMode(
                currentFrameID: nil,
                currentImageFrameID: FrameID(value: 1),
                hasCurrentImage: true,
                hasVideo: true
            ),
            .noContent
        )
    }

    @MainActor
    func testCurrentFrameStillDisplayModeUsesWaitingFallbackUntilVideoReady() {
        XCTAssertEqual(
            SimpleTimelineViewModel.resolveCurrentFrameStillDisplayMode(
                currentFrameID: FrameID(value: 55),
                currentImageFrameID: FrameID(value: 54),
                hasCurrentImage: false,
                hasVideo: true,
                hasWaitingFallbackImage: true,
                pendingVideoPresentationFrameID: FrameID(value: 55),
                isPendingVideoPresentationReady: false
            ),
            .waitingFallback
        )
    }

    @MainActor
    func testCurrentFrameStillDisplayModeStopsUsingWaitingFallbackOnceVideoIsReady() {
        XCTAssertEqual(
            SimpleTimelineViewModel.resolveCurrentFrameStillDisplayMode(
                currentFrameID: FrameID(value: 55),
                currentImageFrameID: FrameID(value: 54),
                hasCurrentImage: false,
                hasVideo: true,
                hasWaitingFallbackImage: true,
                pendingVideoPresentationFrameID: FrameID(value: 55),
                isPendingVideoPresentationReady: true
            ),
            .none
        )
    }
}

private func makeYouTubeOCRNode(
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
