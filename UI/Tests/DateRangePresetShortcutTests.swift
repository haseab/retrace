import XCTest
import AppKit
import Shared
@testable import Retrace

final class DateRangePresetShortcutTests: XCTestCase {
    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar
    }

    func testShortcutKeysMapToExpectedPresets() {
        XCTAssertEqual(DateRangeQuickPreset.preset(for: "a", modifiers: []), .today)
        XCTAssertEqual(DateRangeQuickPreset.preset(for: "s", modifiers: []), .yesterday)
        XCTAssertEqual(DateRangeQuickPreset.preset(for: "d", modifiers: []), .lastSevenDays)
        XCTAssertEqual(DateRangeQuickPreset.preset(for: "f", modifiers: []), .lastThirtyDays)
        XCTAssertEqual(DateRangeQuickPreset.preset(for: "A", modifiers: [.shift]), .today)
    }

    func testShortcutKeysRejectCommandOptionAndControlModifiers() {
        XCTAssertNil(DateRangeQuickPreset.preset(for: "a", modifiers: [.command]))
        XCTAssertNil(DateRangeQuickPreset.preset(for: "s", modifiers: [.option]))
        XCTAssertNil(DateRangeQuickPreset.preset(for: "d", modifiers: [.control]))
    }

    func testTodayPresetResolvesToCurrentDayBounds() throws {
        let calendar = utcCalendar
        let now = try makeDate(year: 2026, month: 3, day: 29, hour: 14, minute: 12, second: 5, calendar: calendar)

        let range = DateRangeQuickPreset.today.resolvedRange(now: now, calendar: calendar)

        XCTAssertEqual(range.start, try makeDate(year: 2026, month: 3, day: 29, hour: 0, minute: 0, second: 0, calendar: calendar))
        XCTAssertEqual(range.end, try makeDate(year: 2026, month: 3, day: 29, hour: 23, minute: 59, second: 59, calendar: calendar))
    }

    func testYesterdayPresetResolvesToPreviousDayBounds() throws {
        let calendar = utcCalendar
        let now = try makeDate(year: 2026, month: 3, day: 29, hour: 14, minute: 12, second: 5, calendar: calendar)

        let range = DateRangeQuickPreset.yesterday.resolvedRange(now: now, calendar: calendar)

        XCTAssertEqual(range.start, try makeDate(year: 2026, month: 3, day: 28, hour: 0, minute: 0, second: 0, calendar: calendar))
        XCTAssertEqual(range.end, try makeDate(year: 2026, month: 3, day: 28, hour: 23, minute: 59, second: 59, calendar: calendar))
    }

    func testRollingPresetsResolveToInclusiveDaySpans() throws {
        let calendar = utcCalendar
        let now = try makeDate(year: 2026, month: 3, day: 29, hour: 14, minute: 12, second: 5, calendar: calendar)

        let lastSevenDays = DateRangeQuickPreset.lastSevenDays.resolvedRange(now: now, calendar: calendar)
        XCTAssertEqual(lastSevenDays.start, try makeDate(year: 2026, month: 3, day: 23, hour: 0, minute: 0, second: 0, calendar: calendar))
        XCTAssertEqual(lastSevenDays.end, try makeDate(year: 2026, month: 3, day: 29, hour: 23, minute: 59, second: 59, calendar: calendar))

        let lastThirtyDays = DateRangeQuickPreset.lastThirtyDays.resolvedRange(now: now, calendar: calendar)
        XCTAssertEqual(lastThirtyDays.start, try makeDate(year: 2026, month: 2, day: 28, hour: 0, minute: 0, second: 0, calendar: calendar))
        XCTAssertEqual(lastThirtyDays.end, try makeDate(year: 2026, month: 3, day: 29, hour: 23, minute: 59, second: 59, calendar: calendar))
    }

    func testMatchingPresetRecognizesEquivalentDateRange() throws {
        let calendar = utcCalendar
        let now = try makeDate(year: 2026, month: 3, day: 29, hour: 14, minute: 12, second: 5, calendar: calendar)
        let yesterdayRange = DateRangeCriterion(
            start: try makeDate(year: 2026, month: 3, day: 28, hour: 0, minute: 0, second: 0, calendar: calendar),
            end: try makeDate(year: 2026, month: 3, day: 28, hour: 23, minute: 59, second: 59, calendar: calendar)
        )

        XCTAssertEqual(
            DateRangeQuickPreset.matchingPreset(for: yesterdayRange, now: now, calendar: calendar),
            .yesterday
        )
    }

    private func makeDate(
        year: Int,
        month: Int,
        day: Int,
        hour: Int,
        minute: Int,
        second: Int,
        calendar: Calendar
    ) throws -> Date {
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        return try XCTUnwrap(calendar.date(from: components))
    }
}
