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

    func testExactDateTimeRangesPreserveTimesAndInheritTheStartDay() throws {
        let calendar = utcCalendar
        let parser = DateRangeInputParser(calendar: calendar)
        let now = try makeDate(year: 2026, month: 11, day: 6, hour: 14, minute: 0, second: 0, calendar: calendar)
        let expectedStart = try makeDate(year: 2025, month: 12, day: 4, hour: 12, minute: 17, second: 0, calendar: calendar)
        let expectedEnd = try makeDate(year: 2025, month: 12, day: 4, hour: 12, minute: 30, second: 0, calendar: calendar)

        for input in [
            "December 4th, 2025 12:17 p.m. to 12:30 p.m.",
            "Dec 4, 2025 12:17 PM to Dec 4, 2025 12:30 PM",
            "2025-12-04 12:17 to 2025-12-04 12:30"
        ] {
            let range = try XCTUnwrap(parser.parse(input, now: now), input)
            XCTAssertEqual(range.start, expectedStart, input)
            XCTAssertEqual(range.end, expectedEnd, input)
        }
    }

    func testDateOnlyInputCoversTheWholeDay() throws {
        let calendar = utcCalendar
        let parser = DateRangeInputParser(calendar: calendar)
        let now = try makeDate(year: 2026, month: 11, day: 6, hour: 14, minute: 0, second: 0, calendar: calendar)
        let range = try XCTUnwrap(parser.parse("December 14th", now: now))

        XCTAssertEqual(range.start, try makeDate(year: 2025, month: 12, day: 14, hour: 0, minute: 0, second: 0, calendar: calendar))
        XCTAssertEqual(range.end, try makeDate(year: 2025, month: 12, day: 14, hour: 23, minute: 59, second: 59, calendar: calendar))
    }

    func testExplicitMidnightEndIsNotExpandedToTheWholeDay() throws {
        let calendar = utcCalendar
        let parser = DateRangeInputParser(calendar: calendar)
        let now = try makeDate(year: 2026, month: 11, day: 6, hour: 14, minute: 0, second: 0, calendar: calendar)
        let range = try XCTUnwrap(parser.parse("Dec 4, 2025 11:50 PM to Dec 5, 2025 12:00 AM", now: now))

        XCTAssertEqual(range.start, try makeDate(year: 2025, month: 12, day: 4, hour: 23, minute: 50, second: 0, calendar: calendar))
        XCTAssertEqual(range.end, try makeDate(year: 2025, month: 12, day: 5, hour: 0, minute: 0, second: 0, calendar: calendar))
    }

    func testMixedDateAndTimeBoundariesOnlyExpandTheDateOnlyBoundary() throws {
        let calendar = utcCalendar
        let parser = DateRangeInputParser(calendar: calendar)
        let now = try makeDate(year: 2026, month: 11, day: 6, hour: 14, minute: 0, second: 0, calendar: calendar)
        let range = try XCTUnwrap(parser.parse("Dec 4, 2025 12:17 PM to Dec 5, 2025", now: now))

        XCTAssertEqual(range.start, try makeDate(year: 2025, month: 12, day: 4, hour: 12, minute: 17, second: 0, calendar: calendar))
        XCTAssertEqual(range.end, try makeDate(year: 2025, month: 12, day: 5, hour: 23, minute: 59, second: 59, calendar: calendar))

        let sameDayRange = try XCTUnwrap(parser.parse("Dec 4, 2025 12:17 PM to Dec 4, 2025", now: now))
        XCTAssertEqual(sameDayRange.start, range.start)
        XCTAssertEqual(sameDayRange.end, try makeDate(year: 2025, month: 12, day: 4, hour: 23, minute: 59, second: 59, calendar: calendar))
    }

    func testFormattedRangesCanBeReopenedAndAppliedWithoutLosingTimePrecision() throws {
        let calendar = utcCalendar
        let parser = DateRangeInputParser(calendar: calendar)
        let now = try makeDate(year: 2026, month: 11, day: 6, hour: 14, minute: 0, second: 0, calendar: calendar)

        for input in [
            "Dec 4, 2025 12:17 PM to 12:30 PM",
            "Dec 4, 2025 11:50 PM to Dec 5, 2025 12:00 AM",
            "Dec 4, 2025 12:17:15 PM to 12:30:45 PM",
            "Dec 4, 2025 to Dec 5, 2025 12:30 PM",
            "Dec 4, 2025 12:17 PM to Dec 5, 2025",
            "December 14th",
            "Dec 4, 2025 to Dec 5, 2025"
        ] {
            let original = try XCTUnwrap(parser.parse(input, now: now), input)
            let formatted = parser.formatRange(start: original.start, end: original.end)
            let reopened = try XCTUnwrap(parser.parse(formatted, now: now), formatted)
            XCTAssertEqual(reopened.start, original.start, formatted)
            XCTAssertEqual(reopened.end, original.end, formatted)
        }
    }

    func testDateOnlyInputUsesLocalDayBoundsAcrossDaylightSavingTime() throws {
        var calendar = utcCalendar
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let parser = DateRangeInputParser(calendar: calendar)
        let now = try makeDate(year: 2026, month: 11, day: 6, hour: 14, minute: 0, second: 0, calendar: calendar)
        let range = try XCTUnwrap(parser.parse("March 8, 2026", now: now))

        XCTAssertEqual(range.start, try makeDate(year: 2026, month: 3, day: 8, hour: 0, minute: 0, second: 0, calendar: calendar))
        XCTAssertEqual(range.end, try makeDate(year: 2026, month: 3, day: 8, hour: 23, minute: 59, second: 59, calendar: calendar))
        XCTAssertEqual(range.end.timeIntervalSince(range.start), 23 * 60 * 60 - 1)
    }

    func testIntradayRangeDoesNotMatchTheWholeDayPreset() throws {
        let calendar = utcCalendar
        let now = try makeDate(year: 2026, month: 11, day: 6, hour: 14, minute: 0, second: 0, calendar: calendar)
        let range = DateRangeCriterion(start: now.addingTimeInterval(-13 * 60), end: now)

        XCTAssertNil(DateRangeQuickPreset.matchingPreset(for: range, now: now, calendar: calendar))
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

    func testNaturalLanguageRollingRangePhrasesResolveToInclusiveDaySpans() throws {
        let calendar = utcCalendar
        let parser = DateRangeInputParser(calendar: calendar)
        let now = try makeDate(year: 2026, month: 4, day: 10, hour: 13, minute: 44, second: 0, calendar: calendar)

        let pastWeek = try XCTUnwrap(parser.parse("past week", now: now))
        XCTAssertEqual(
            pastWeek.start,
            try makeDate(year: 2026, month: 4, day: 4, hour: 0, minute: 0, second: 0, calendar: calendar)
        )
        XCTAssertEqual(
            pastWeek.end,
            try makeDate(year: 2026, month: 4, day: 10, hour: 23, minute: 59, second: 59, calendar: calendar)
        )

        let pastMonth = try XCTUnwrap(parser.parse("past month", now: now))
        XCTAssertEqual(
            pastMonth.start,
            try makeDate(year: 2026, month: 3, day: 12, hour: 0, minute: 0, second: 0, calendar: calendar)
        )
        XCTAssertEqual(
            pastMonth.end,
            try makeDate(year: 2026, month: 4, day: 10, hour: 23, minute: 59, second: 59, calendar: calendar)
        )

        let lastTwelveDays = try XCTUnwrap(parser.parse("last 12 days", now: now))
        XCTAssertEqual(
            lastTwelveDays.start,
            try makeDate(year: 2026, month: 3, day: 30, hour: 0, minute: 0, second: 0, calendar: calendar)
        )
        XCTAssertEqual(
            lastTwelveDays.end,
            try makeDate(year: 2026, month: 4, day: 10, hour: 23, minute: 59, second: 59, calendar: calendar)
        )
    }

    func testNaturalLanguageCalendarWeekPhrasesResolveToWeekBounds() throws {
        let calendar = utcCalendar
        let parser = DateRangeInputParser(calendar: calendar)
        let now = try makeDate(year: 2026, month: 4, day: 10, hour: 13, minute: 44, second: 0, calendar: calendar)

        let thisWeek = try XCTUnwrap(parser.parse("this week", now: now))
        XCTAssertEqual(
            thisWeek.start,
            try makeDate(year: 2026, month: 4, day: 6, hour: 0, minute: 0, second: 0, calendar: calendar)
        )
        XCTAssertEqual(
            thisWeek.end,
            try makeDate(year: 2026, month: 4, day: 10, hour: 23, minute: 59, second: 59, calendar: calendar)
        )

        let lastWeek = try XCTUnwrap(parser.parse("last week", now: now))
        XCTAssertEqual(
            lastWeek.start,
            try makeDate(year: 2026, month: 3, day: 30, hour: 0, minute: 0, second: 0, calendar: calendar)
        )
        XCTAssertEqual(
            lastWeek.end,
            try makeDate(year: 2026, month: 4, day: 5, hour: 23, minute: 59, second: 59, calendar: calendar)
        )
    }

    func testNaturalLanguageCompactDayShorthandResolvesToRollingRange() throws {
        let calendar = utcCalendar
        let parser = DateRangeInputParser(calendar: calendar)
        let now = try makeDate(year: 2026, month: 4, day: 10, hour: 13, minute: 44, second: 0, calendar: calendar)

        let compactRange = try XCTUnwrap(parser.parse("7d", now: now))
        XCTAssertEqual(
            compactRange.start,
            try makeDate(year: 2026, month: 4, day: 4, hour: 0, minute: 0, second: 0, calendar: calendar)
        )
        XCTAssertEqual(
            compactRange.end,
            try makeDate(year: 2026, month: 4, day: 10, hour: 23, minute: 59, second: 59, calendar: calendar)
        )
    }

    func testImplicitMonthRangePrefersPastYearWhenForwardInferenceWouldBeFuture() throws {
        let calendar = utcCalendar
        let parser = DateRangeInputParser(calendar: calendar)
        let now = try makeDate(year: 2026, month: 4, day: 10, hour: 13, minute: 44, second: 0, calendar: calendar)

        let januaryRange = try XCTUnwrap(parser.parse("Jan 1 to 30", now: now))
        XCTAssertEqual(
            januaryRange.start,
            try makeDate(year: 2026, month: 1, day: 1, hour: 0, minute: 0, second: 0, calendar: calendar)
        )
        XCTAssertEqual(
            januaryRange.end,
            try makeDate(year: 2026, month: 1, day: 30, hour: 23, minute: 59, second: 59, calendar: calendar)
        )
    }

    func testImplicitFutureMonthDayPrefersPreviousYearForSingleDate() throws {
        let calendar = utcCalendar
        let parser = DateRangeInputParser(calendar: calendar)
        let now = try makeDate(year: 2026, month: 4, day: 10, hour: 13, minute: 44, second: 0, calendar: calendar)

        let decemberRange = try XCTUnwrap(parser.parse("Dec 5", now: now))
        XCTAssertEqual(
            decemberRange.start,
            try makeDate(year: 2025, month: 12, day: 5, hour: 0, minute: 0, second: 0, calendar: calendar)
        )
        XCTAssertEqual(
            decemberRange.end,
            try makeDate(year: 2025, month: 12, day: 5, hour: 23, minute: 59, second: 59, calendar: calendar)
        )
    }

    func testImplicitPastMonthDayKeepsCurrentYearWhenAlreadyInPast() throws {
        let calendar = utcCalendar
        let parser = DateRangeInputParser(calendar: calendar)
        let now = try makeDate(year: 2026, month: 4, day: 10, hour: 13, minute: 44, second: 0, calendar: calendar)

        let aprilRange = try XCTUnwrap(parser.parse("Apr 5 to Apr 7", now: now))
        XCTAssertEqual(
            aprilRange.start,
            try makeDate(year: 2026, month: 4, day: 5, hour: 0, minute: 0, second: 0, calendar: calendar)
        )
        XCTAssertEqual(
            aprilRange.end,
            try makeDate(year: 2026, month: 4, day: 7, hour: 23, minute: 59, second: 59, calendar: calendar)
        )
    }

    func testNaturalLanguageFirstDaysOfMonthPhraseResolvesToMonthSlice() throws {
        let calendar = utcCalendar
        let parser = DateRangeInputParser(calendar: calendar)
        let now = try makeDate(year: 2026, month: 4, day: 10, hour: 13, minute: 44, second: 0, calendar: calendar)

        let aprilRange = try XCTUnwrap(parser.parse("first 5 days of april", now: now))
        XCTAssertEqual(
            aprilRange.start,
            try makeDate(year: 2026, month: 4, day: 1, hour: 0, minute: 0, second: 0, calendar: calendar)
        )
        XCTAssertEqual(
            aprilRange.end,
            try makeDate(year: 2026, month: 4, day: 5, hour: 23, minute: 59, second: 59, calendar: calendar)
        )

        let namedMonthWithYearRange = try XCTUnwrap(parser.parse("first 10 days of jul 2025", now: now))
        XCTAssertEqual(
            namedMonthWithYearRange.start,
            try makeDate(year: 2025, month: 7, day: 1, hour: 0, minute: 0, second: 0, calendar: calendar)
        )
        XCTAssertEqual(
            namedMonthWithYearRange.end,
            try makeDate(year: 2025, month: 7, day: 10, hour: 23, minute: 59, second: 59, calendar: calendar)
        )
    }

    func testNaturalLanguageFirstDaysOfWeekPhrasesUseMondayWeekStart() throws {
        let calendar = utcCalendar
        let parser = DateRangeInputParser(calendar: calendar)
        let now = try makeDate(year: 2026, month: 4, day: 10, hour: 13, minute: 44, second: 0, calendar: calendar)

        let currentWeekRange = try XCTUnwrap(parser.parse("first 3 days of the week", now: now))
        XCTAssertEqual(
            currentWeekRange.start,
            try makeDate(year: 2026, month: 4, day: 6, hour: 0, minute: 0, second: 0, calendar: calendar)
        )
        XCTAssertEqual(
            currentWeekRange.end,
            try makeDate(year: 2026, month: 4, day: 8, hour: 23, minute: 59, second: 59, calendar: calendar)
        )

        let lastWeekRange = try XCTUnwrap(parser.parse("first 4 days of last week", now: now))
        XCTAssertEqual(
            lastWeekRange.start,
            try makeDate(year: 2026, month: 3, day: 30, hour: 0, minute: 0, second: 0, calendar: calendar)
        )
        XCTAssertEqual(
            lastWeekRange.end,
            try makeDate(year: 2026, month: 4, day: 2, hour: 23, minute: 59, second: 59, calendar: calendar)
        )
    }

    func testDateRangeInputFocusResolverIgnoresStalePrimaryBlurAfterAdditionalFocus() {
        let additionalID = UUID()

        let additionalFocus = DateRangeInputFocusResolver.resolve(
            current: .primary,
            event: .setAdditional(additionalID, true)
        )
        let afterPrimaryBlur = DateRangeInputFocusResolver.resolve(
            current: additionalFocus,
            event: .setPrimary(false)
        )

        XCTAssertEqual(afterPrimaryBlur, .additional(additionalID))
        XCTAssertFalse(DateRangeInputFocusResolver.isPrimaryFocused(afterPrimaryBlur))
        XCTAssertEqual(DateRangeInputFocusResolver.focusedAdditionalID(afterPrimaryBlur), additionalID)
    }

    func testDateRangeInputFocusResolverIgnoresStaleAdditionalBlurAfterPrimaryFocus() {
        let additionalID = UUID()

        let primaryFocus = DateRangeInputFocusResolver.resolve(
            current: .additional(additionalID),
            event: .setPrimary(true)
        )
        let afterAdditionalBlur = DateRangeInputFocusResolver.resolve(
            current: primaryFocus,
            event: .setAdditional(additionalID, false)
        )

        XCTAssertEqual(afterAdditionalBlur, .primary)
        XCTAssertTrue(DateRangeInputFocusResolver.isPrimaryFocused(afterAdditionalBlur))
        XCTAssertNil(DateRangeInputFocusResolver.focusedAdditionalID(afterAdditionalBlur))
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
