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
