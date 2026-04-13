import XCTest
import Database
@testable import App

final class FeedbackRecentMetricSupportTests: XCTestCase {
    func testSanitizeRecentMetricEventsRedactsLegacySensitiveMetadata() {
        let events: [DailyMetricsQueries.RecentEvent] = [
            .init(
                metricType: .filteredSearchQuery,
                timestamp: Date(timeIntervalSince1970: 1_774_800_000),
                metadata: #"{"query":"bank account password","filters":{"app":"Safari","date":"today"}}"#
            ),
            .init(
                metricType: .timelineFilterQuery,
                timestamp: Date(timeIntervalSince1970: 1_774_800_010),
                metadata: #"{"bundleID":"com.apple.Safari","windowName":"Private window","browserUrl":"https://example.com","startDate":"2026-03-29"}"#
            ),
            .init(
                metricType: .shiftDragTextCopy,
                timestamp: Date(timeIntervalSince1970: 1_774_800_020),
                metadata: "super secret text"
            ),
        ]

        let sanitized = FeedbackRecentMetricSupport.sanitize(events)

        XCTAssertEqual(sanitized.count, 3)
        XCTAssertEqual(
            sanitized[0].details,
            ["queryLength": "21", "filterCount": "2"]
        )
        XCTAssertEqual(
            sanitized[1].details,
            [
                "hasAppFilter": "true",
                "hasWindowFilter": "true",
                "hasURLFilter": "true",
                "hasStartDate": "true",
            ]
        )
        XCTAssertEqual(
            sanitized[2].details,
            ["textLength": "17"]
        )
        XCTAssertFalse(
            sanitized[0].details.values.contains("bank account password")
        )
        XCTAssertFalse(
            sanitized[1].details.values.contains("com.apple.Safari")
        )
    }

    func testSanitizeRecentMetricEventsUsesTypedFilteredSearchMetadata() throws {
        let metadata = try XCTUnwrap(
            encodedJSON(
                FilteredSearchMetricMetadata(
                    queryLength: 27,
                    filterCount: 3
                )
            )
        )

        let sanitized = FeedbackRecentMetricSupport.sanitize([
            .init(
                metricType: .filteredSearchQuery,
                timestamp: Date(timeIntervalSince1970: 1_774_800_030),
                metadata: metadata
            )
        ])

        XCTAssertEqual(
            sanitized,
            [
                FeedbackRecentMetricEvent(
                    timestamp: Date(timeIntervalSince1970: 1_774_800_030),
                    metricType: "filtered_search_query",
                    summary: "Filtered search submitted",
                    details: [
                        "queryLength": "27",
                        "filterCount": "3",
                    ]
                )
            ]
        )
    }

    func testSanitizeRecentMetricEventsUsesTypedTimelineFilterMetadata() throws {
        let metadata = try XCTUnwrap(
            encodedJSON(
                TimelineFilterMetricMetadata(
                    hasAppFilter: true,
                    hasWindowFilter: false,
                    hasURLFilter: true,
                    hasStartDate: true,
                    hasEndDate: false
                )
            )
        )

        let sanitized = FeedbackRecentMetricSupport.sanitize([
            .init(
                metricType: .timelineFilterQuery,
                timestamp: Date(timeIntervalSince1970: 1_774_800_040),
                metadata: metadata
            )
        ])

        XCTAssertEqual(
            sanitized.first?.details,
            [
                "hasAppFilter": "true",
                "hasURLFilter": "true",
                "hasStartDate": "true",
            ]
        )
    }

    func testSanitizeRecentMetricEventsExcludesAdditionalNoiseAndRedactsPlainSearches() {
        let events: [DailyMetricsQueries.RecentEvent] = [
            .init(
                metricType: .helpOpened,
                timestamp: Date(timeIntervalSince1970: 1_774_800_050),
                metadata: #"{"source":"feedback"}"#
            ),
            .init(
                metricType: .searches,
                timestamp: Date(timeIntervalSince1970: 1_774_800_060),
                metadata: "  sensitive query  "
            ),
            .init(
                metricType: .timelineOpens,
                timestamp: Date(timeIntervalSince1970: 1_774_800_070),
                metadata: nil
            ),
            .init(
                metricType: .inPageURLHover,
                timestamp: Date(timeIntervalSince1970: 1_774_800_080),
                metadata: #"{"url":"https://example.com"}"#
            ),
        ]

        let sanitized = FeedbackRecentMetricSupport.sanitize(events)

        XCTAssertEqual(sanitized.count, 1)
        XCTAssertEqual(sanitized[0].metricType, "searches")
        XCTAssertEqual(sanitized[0].summary, "Search submitted")
        XCTAssertEqual(sanitized[0].details, ["queryLength": "15"])
    }

    func testSanitizeRecentMetricEventsCollapsesDuplicateTimelineFilterBurstsWithinTenSeconds() throws {
        let repeatedMetadata = try XCTUnwrap(
            encodedJSON(
                TimelineFilterMetricMetadata(
                    hasAppFilter: true,
                    hasWindowFilter: false,
                    hasURLFilter: true,
                    hasStartDate: false,
                    hasEndDate: false
                )
            )
        )
        let changedMetadata = try XCTUnwrap(
            encodedJSON(
                TimelineFilterMetricMetadata(
                    hasAppFilter: true,
                    hasWindowFilter: true,
                    hasURLFilter: true,
                    hasStartDate: false,
                    hasEndDate: false
                )
            )
        )

        let sanitized = FeedbackRecentMetricSupport.sanitize([
            .init(
                metricType: .timelineFilterQuery,
                timestamp: Date(timeIntervalSince1970: 1_774_800_100),
                metadata: repeatedMetadata
            ),
            .init(
                metricType: .timelineFilterQuery,
                timestamp: Date(timeIntervalSince1970: 1_774_800_108),
                metadata: repeatedMetadata
            ),
            .init(
                metricType: .timelineFilterQuery,
                timestamp: Date(timeIntervalSince1970: 1_774_800_119),
                metadata: repeatedMetadata
            ),
            .init(
                metricType: .timelineFilterQuery,
                timestamp: Date(timeIntervalSince1970: 1_774_800_125),
                metadata: changedMetadata
            ),
        ])

        XCTAssertEqual(sanitized.count, 3)
        XCTAssertEqual(
            sanitized.map(\.timestamp),
            [
                Date(timeIntervalSince1970: 1_774_800_108),
                Date(timeIntervalSince1970: 1_774_800_119),
                Date(timeIntervalSince1970: 1_774_800_125),
            ]
        )
        XCTAssertEqual(
            sanitized.last?.details,
            [
                "hasAppFilter": "true",
                "hasWindowFilter": "true",
                "hasURLFilter": "true",
            ]
        )
    }

    private func encodedJSON<T: Encodable>(_ value: T) -> String? {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(value) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}
