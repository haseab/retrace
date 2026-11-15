import XCTest
import AppKit
import Combine
import Shared
import App
@testable import Retrace

@MainActor
final class DeeplinkHandlerTests: XCTestCase {

    func testSearchRouteParsesCanonicalTimestampAndApp() {
        let url = URL(string: "retrace://search?q=error&t=1704067200123&app=com.google.Chrome")!

        let route = DeeplinkHandler.route(for: url)

        guard case let .search(state)? = route else {
            XCTFail("Expected search route")
            return
        }

        XCTAssertEqual(state.queryText, "error")
        XCTAssertEqual(state.appBundleIDs, ["com.google.Chrome"])
        guard let parsedTimestamp = state.timestamp?.timeIntervalSince1970 else {
            XCTFail("Expected parsed timestamp")
            return
        }
        XCTAssertEqual(parsedTimestamp, 1_704_067_200.123, accuracy: 0.0001)
    }

    func testSearchRouteParsesLegacyTimestampAlias() {
        let url = URL(string: "retrace://search?q=errors&timestamp=1704067200456")!

        let route = DeeplinkHandler.route(for: url)

        guard case let .search(state)? = route else {
            XCTFail("Expected search route")
            return
        }

        XCTAssertEqual(state.queryText, "errors")
        XCTAssertEqual(state.appBundleIDs, [])
        guard let parsedTimestamp = state.timestamp?.timeIntervalSince1970 else {
            XCTFail("Expected parsed timestamp")
            return
        }
        XCTAssertEqual(parsedTimestamp, 1_704_067_200.456, accuracy: 0.0001)
    }

    func testTimelineRouteParsesLegacyTimestampAlias() {
        let url = URL(string: "retrace://timeline?timestamp=1704067200999")!

        let route = DeeplinkHandler.route(for: url)

        guard case let .timeline(state)? = route else {
            XCTFail("Expected timeline route")
            return
        }

        guard let parsedTimestamp = state.timestamp?.timeIntervalSince1970 else {
            XCTFail("Expected parsed timestamp")
            return
        }
        XCTAssertEqual(parsedTimestamp, 1_704_067_200.999, accuracy: 0.0001)
    }

    func testGenerateSearchLinkRoundTripsEncodedState() {
        let timestamp = Date(timeIntervalSince1970: 1_704_067_200.123)
        let state = CLIDeeplinkSearchState(
            queryText: "\"error\"",
            appBundleIDs: ["com.apple.Safari"],
            appFilterMode: .include,
            tagIDs: [42],
            tagFilterMode: .exclude,
            hiddenFilter: .showAll,
            commentFilter: .commentsOnly,
            dateRanges: [DateRangeCriterion(start: timestamp, end: timestamp.addingTimeInterval(60))],
            windowNameTerms: ["Console"],
            windowNameExcludedTerms: ["Help"],
            browserURLTerms: ["openai.com"],
            browserURLExcludedTerms: ["logout"],
            sort: .oldest,
            timestamp: timestamp
        )

        let url = DeeplinkHandler.generateSearchLink(state: state)
        XCTAssertNotNil(url)

        guard case let .search(parsedState)? = DeeplinkHandler.route(for: url!) else {
            return XCTFail("Expected encoded search route")
        }

        XCTAssertEqual(parsedState, state)
    }

    func testGenerateTimelineLinkRoundTripsFrameID() {
        let state = CLIDeeplinkTimelineState(
            timestamp: Date(timeIntervalSince1970: 1_704_067_200.999),
            frameID: 123_456
        )

        let url = DeeplinkHandler.generateTimelineLink(state: state)
        XCTAssertNotNil(url)

        guard case let .timeline(parsedState)? = DeeplinkHandler.route(for: url!) else {
            return XCTFail("Expected encoded timeline route")
        }

        XCTAssertEqual(parsedState, state)
    }
}
