import XCTest
import AppKit
import Combine
import Shared
import App
@testable import Retrace

@MainActor
final class DeeplinkHandlerTests: XCTestCase {

    func testDashboardRouteParsesExactMillisecondsAndISO8601Offsets() throws {
        let expected = DateRangeCriterion(
            start: Date(timeIntervalSince1970: 1_793_970_000),
            end: Date(timeIntervalSince1970: 1_793_974_200)
        )
        for rawURL in [
            "retrace://dashboard?start=1793970000000&end=1793974200000",
            "retrace://dashboard?start=2026-11-06T05:00:00-08:00&end=2026-11-06T06:10:00-08:00",
            "retrace://dashboard?start=2026-11-06T13:00:00.000Z&end=2026-11-06T14:10:00.000Z"
        ] {
            let url = try XCTUnwrap(URL(string: rawURL))
            XCTAssertEqual(DeeplinkHandler.route(for: url), .dashboard(dateRange: expected), rawURL)
        }
    }

    func testDashboardDateOnlyRangeCoversTheFullLocalDayAcrossDST() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let url = try XCTUnwrap(URL(string: "retrace://dashboard?start=2026-11-01&end=2026-11-01"))
        guard case let .dashboard(range)? = DeeplinkHandler.route(for: url, calendar: calendar) else {
            return XCTFail("Expected dashboard range")
        }
        let start = try XCTUnwrap(range?.start)
        let end = try XCTUnwrap(range?.end)
        XCTAssertEqual(calendar.component(.hour, from: start), 0)
        XCTAssertEqual(calendar.component(.hour, from: end), 23)
        XCTAssertEqual(calendar.component(.minute, from: end), 59)
        XCTAssertEqual(calendar.component(.second, from: end), 59)
        XCTAssertEqual(end.timeIntervalSince(start), 25 * 60 * 60 - 0.001, accuracy: 0.001)
    }

    func testBareDashboardLinkOpensWithoutReplacingTheCurrentRange() throws {
        let url = try XCTUnwrap(URL(string: "retrace://dashboard"))
        XCTAssertEqual(DeeplinkHandler.route(for: url), .dashboard(dateRange: nil))
    }

    func testDashboardRejectsIncompleteInvalidReversedAndOversizedRanges() throws {
        for query in [
            "start", "end", "start&end", "start&end=2026-11-06",
            "start=2026-11-06&end", "start=2026-11-06&start=2026-11-07&end=2026-11-08",
            "start=2026-11-06", "end=2026-11-06", "start=&end=2026-11-06",
            "start=bad&end=2026-11-06", "start=2026-02-30&end=2026-03-01",
            "start=2026-11-06T05:00:00&end=2026-11-06T06:10:00",
            "start=2026-11-07&end=2026-11-06", "start=2026-01-01&end=2026-03-01",
            "start=9223372036854775807&end=9223372036854775807"
        ] {
            let url = try XCTUnwrap(URL(string: "retrace://dashboard?" + query))
            XCTAssertNil(DeeplinkHandler.route(for: url), query)
        }
    }

    func testGeneratedDashboardLinkRoundTripsWithMillisecondPrecision() throws {
        let start = Date(timeIntervalSince1970: 1_793_970_000.123)
        let end = Date(timeIntervalSince1970: 1_793_974_200.456)
        let url = try XCTUnwrap(DeeplinkHandler.generateDashboardLink(start: start, end: end))
        guard case let .dashboard(range)? = DeeplinkHandler.route(for: url) else {
            return XCTFail("Expected dashboard range")
        }
        XCTAssertEqual(try XCTUnwrap(range?.start).timeIntervalSince1970, start.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(range?.end).timeIntervalSince1970, end.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(DeeplinkHandler.generateDashboardLink()?.absoluteString, "retrace://dashboard")
        XCTAssertNil(DeeplinkHandler.generateDashboardLink(start: start))
    }

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
