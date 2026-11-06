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
        XCTAssertEqual(end.timeIntervalSince(start), 25 * 60 * 60 - 1)
    }

    func testBareDashboardLinkOpensWithoutReplacingTheCurrentRange() throws {
        let url = try XCTUnwrap(URL(string: "retrace://dashboard"))
        XCTAssertEqual(DeeplinkHandler.route(for: url), .dashboard(dateRange: nil))
    }

    func testDashboardRejectsIncompleteInvalidReversedAndOversizedRanges() throws {
        for query in [
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

        guard case let .search(query, timestamp, appBundleID)? = route else {
            XCTFail("Expected search route")
            return
        }

        XCTAssertEqual(query, "error")
        XCTAssertEqual(appBundleID, "com.google.Chrome")
        guard let parsedTimestamp = timestamp?.timeIntervalSince1970 else {
            XCTFail("Expected parsed timestamp")
            return
        }
        XCTAssertEqual(parsedTimestamp, 1_704_067_200.123, accuracy: 0.0001)
    }

    func testSearchRouteParsesLegacyTimestampAlias() {
        let url = URL(string: "retrace://search?q=errors&timestamp=1704067200456")!

        let route = DeeplinkHandler.route(for: url)

        guard case let .search(query, timestamp, appBundleID)? = route else {
            XCTFail("Expected search route")
            return
        }

        XCTAssertEqual(query, "errors")
        XCTAssertEqual(appBundleID, nil)
        guard let parsedTimestamp = timestamp?.timeIntervalSince1970 else {
            XCTFail("Expected parsed timestamp")
            return
        }
        XCTAssertEqual(parsedTimestamp, 1_704_067_200.456, accuracy: 0.0001)
    }

    func testTimelineRouteParsesLegacyTimestampAlias() {
        let url = URL(string: "retrace://timeline?timestamp=1704067200999")!

        let route = DeeplinkHandler.route(for: url)

        guard case let .timeline(timestamp)? = route else {
            XCTFail("Expected timeline route")
            return
        }

        guard let parsedTimestamp = timestamp?.timeIntervalSince1970 else {
            XCTFail("Expected parsed timestamp")
            return
        }
        XCTAssertEqual(parsedTimestamp, 1_704_067_200.999, accuracy: 0.0001)
    }

    func testGenerateSearchLinkUsesCanonicalTimestampKey() {
        let timestamp = Date(timeIntervalSince1970: 1_704_067_200.123)
        let url = DeeplinkHandler.generateSearchLink(
            query: "error",
            timestamp: timestamp,
            appBundleID: "com.apple.Safari"
        )

        XCTAssertNotNil(url)
        let components = URLComponents(url: url!, resolvingAgainstBaseURL: false)
        let queryItems = components?.queryItems ?? []
        let queryMap = Dictionary(uniqueKeysWithValues: queryItems.map { ($0.name, $0.value) })

        XCTAssertEqual(queryMap["q"]!, "error")
        XCTAssertEqual(queryMap["app"]!, "com.apple.Safari")
        XCTAssertEqual(queryMap["t"]!, "1704067200123")
        XCTAssertFalse(queryMap.keys.contains("timestamp"))
    }
}
