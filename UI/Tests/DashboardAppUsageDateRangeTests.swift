import XCTest
@testable import Retrace

@MainActor
final class DashboardAppUsageDateRangeTests: XCTestCase {
    func testNormalizedAppUsageDateRangeCapsSpanToThirtyDays() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        let start = calendar.date(from: DateComponents(year: 2026, month: 1, day: 1))!
        let end = calendar.date(from: DateComponents(year: 2026, month: 2, day: 15))!
        let now = calendar.date(from: DateComponents(year: 2026, month: 3, day: 14))!

        let normalized = DashboardViewModel.normalizedAppUsageDateRange(
            start: start,
            end: end,
            maxDays: 30,
            calendar: calendar,
            now: now
        )

        XCTAssertEqual(normalized.start, start)
        XCTAssertEqual(
            normalized.end,
            calendar.date(byAdding: .day, value: 29, to: start)!
        )
    }

    func testNormalizedAppUsageDateRangeClampsFutureDaysToToday() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        let start = calendar.date(from: DateComponents(year: 2026, month: 3, day: 1))!
        let end = calendar.date(from: DateComponents(year: 2026, month: 3, day: 30))!
        let now = calendar.date(from: DateComponents(year: 2026, month: 3, day: 14, hour: 10))!

        let normalized = DashboardViewModel.normalizedAppUsageDateRange(
            start: start,
            end: end,
            maxDays: 30,
            calendar: calendar,
            now: now
        )

        XCTAssertEqual(normalized.start, start)
        XCTAssertEqual(
            normalized.end,
            calendar.startOfDay(for: now)
        )
    }

    func testNormalizedAppUsageDateRangeSortsDescendingInput() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        let later = calendar.date(from: DateComponents(year: 2026, month: 3, day: 10))!
        let earlier = calendar.date(from: DateComponents(year: 2026, month: 3, day: 5))!
        let now = calendar.date(from: DateComponents(year: 2026, month: 3, day: 14))!

        let normalized = DashboardViewModel.normalizedAppUsageDateRange(
            start: later,
            end: earlier,
            maxDays: 30,
            calendar: calendar,
            now: now
        )

        XCTAssertEqual(normalized.start, earlier)
        XCTAssertEqual(normalized.end, later)
    }

}
