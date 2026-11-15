import XCTest
@testable import App

final class CLITimeParserTests: XCTestCase {
    func testParseRangeExpandsDateOnlyBoundsToWholeDay() throws {
        let parser = CLITimeParser()

        let range = try parser.parseRange("2026-04-15..2026-04-15")

        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: try XCTUnwrap(range.start))
        XCTAssertEqual(range.start, startOfDay)

        let nextDay = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: startOfDay))
        let distanceToNextDay = try XCTUnwrap(range.end).distance(to: nextDay)
        XCTAssertEqual(distanceToNextDay, 0.001, accuracy: 0.000_1)
    }

    func testEncodedMetadataFilterEncodesIncludeAndExcludeTerms() throws {
        let encoded = try XCTUnwrap(
            RetraceCLIService.encodedMetadataFilter(
                includeTerms: ["twitter.com", "twitter.com"],
                excludeTerms: ["explore", "TWITTER.COM"]
            )
        )

        XCTAssertTrue(encoded.hasPrefix("__retrace_meta_filter_v1__"))
        XCTAssertFalse(encoded.contains("TWITTER.COM"))
    }

    func testParseInstantHandlesNaturalLanguageToday() throws {
        let parser = CLITimeParser()
        let parsed = try parser.parseInstant("today")

        XCTAssertEqual(parsed, Calendar.current.startOfDay(for: Date()))
    }

    func testNaturalLanguageDateParserAnchorsStandaloneMonthToMonthStart() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let now = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 4, day: 16, hour: 12, minute: 0))
        )
        let parser = NaturalLanguageDateParser(calendar: calendar)

        let parsed = try XCTUnwrap(parser.parse("last month", now: now))

        XCTAssertEqual(parsed.resolution, .month)
        XCTAssertEqual(
            parsed.date,
            try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 1, hour: 0, minute: 0)))
        )
    }

    func testNaturalLanguageDateParserShiftsFutureTimeOnlyToPreviousDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let now = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 4, day: 16, hour: 10, minute: 0))
        )
        let parser = NaturalLanguageDateParser(calendar: calendar)

        let parsed = try XCTUnwrap(parser.parse("11pm", now: now))

        XCTAssertEqual(parsed.resolution, .exact)
        XCTAssertEqual(
            parsed.date,
            try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 4, day: 15, hour: 23, minute: 0)))
        )
    }
}
