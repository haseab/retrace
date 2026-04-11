import XCTest
import AppKit
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

    func testHistoricalAppUsageRangesAreCacheableButTodayRangesAreNot() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 4, day: 10, hour: 12))!
        let historicalStart = calendar.date(from: DateComponents(year: 2026, month: 4, day: 1))!
        let historicalEnd = calendar.date(from: DateComponents(year: 2026, month: 4, day: 5))!
        let liveStart = calendar.date(from: DateComponents(year: 2026, month: 4, day: 4))!
        let liveEnd = calendar.date(from: DateComponents(year: 2026, month: 4, day: 10))!

        XCTAssertTrue(
            DashboardViewModel.shouldCacheAppUsageRange(
                start: historicalStart,
                end: historicalEnd,
                calendar: calendar,
                now: now
            )
        )
        XCTAssertFalse(
            DashboardViewModel.shouldCacheAppUsageRange(
                start: liveStart,
                end: liveEnd,
                calendar: calendar,
                now: now
            )
        )
    }

    func testAppUsageRangeCacheEvictsOldestHistoricalRangeAfterOneHundredEntries() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var cache = DashboardAppUsageRangeCache(capacity: 100)

        let keys = (0..<101).map { offset in
            DashboardAppUsageRangeCacheKey(
                start: calendar.date(from: DateComponents(year: 2026, month: 4, day: offset + 1))!,
                end: calendar.date(from: DateComponents(year: 2026, month: 4, day: offset + 1))!,
                calendar: calendar
            )
        }

        for key in keys {
            cache.insert(makeSnapshot(), for: key)
        }

        XCTAssertEqual(cache.count, 100)
        XCTAssertNil(cache.snapshot(for: keys[0]))
        for key in keys.dropFirst() {
            XCTAssertNotNil(cache.snapshot(for: key))
        }
    }

    func testAppUsageRangeControlLabelUsesRollingCopyForDefaultRange() {
        XCTAssertEqual(
            DashboardView.appUsageRangeControlLabel(
                selectedRangeLabel: "Apr 4 - Apr 10",
                isDefaultLastSevenDays: true
            ),
            "Last 7 Days"
        )
    }

    func testAppUsageRangeControlLabelUsesSelectedDatesForCustomRange() {
        XCTAssertEqual(
            DashboardView.appUsageRangeControlLabel(
                selectedRangeLabel: "Mar 16 - Apr 5",
                isDefaultLastSevenDays: false
            ),
            "Mar 16 - Apr 5"
        )
    }

    func testAppUsageRangeResetIsDisabledForDefaultRangeOnly() {
        XCTAssertFalse(
            DashboardView.isAppUsageRangeResetEnabled(isDefaultLastSevenDays: true)
        )
        XCTAssertTrue(
            DashboardView.isAppUsageRangeResetEnabled(isDefaultLastSevenDays: false)
        )
    }

    func testEscapeResetIsAvailableOnlyForClosedCustomRanges() {
        XCTAssertTrue(
            DashboardView.shouldResetAppUsageRangeOnEscape(
                isDatePopoverPresented: false,
                isDefaultLastSevenDays: false
            )
        )
        XCTAssertFalse(
            DashboardView.shouldResetAppUsageRangeOnEscape(
                isDatePopoverPresented: true,
                isDefaultLastSevenDays: false
            )
        )
        XCTAssertFalse(
            DashboardView.shouldResetAppUsageRangeOnEscape(
                isDatePopoverPresented: false,
                isDefaultLastSevenDays: true
            )
        )
    }

    func testAppUsageRangeKeyboardShortcutsMapArrowsAndLetterAliases() {
        XCTAssertEqual(
            DashboardView.appUsageRangeKeyboardShortcut(
                keyCode: 123,
                charactersIgnoringModifiers: nil,
                modifiers: [],
                isDatePopoverPresented: false,
                isFeedbackPresented: false,
                isSessionsPresented: false,
                isTextInputFocused: false
            ),
            .previousArrow
        )
        XCTAssertEqual(
            DashboardView.appUsageRangeKeyboardShortcut(
                keyCode: 124,
                charactersIgnoringModifiers: nil,
                modifiers: [],
                isDatePopoverPresented: false,
                isFeedbackPresented: false,
                isSessionsPresented: false,
                isTextInputFocused: false
            ),
            .nextArrow
        )
        XCTAssertEqual(
            DashboardView.appUsageRangeKeyboardShortcut(
                keyCode: 37,
                charactersIgnoringModifiers: "l",
                modifiers: [],
                isDatePopoverPresented: false,
                isFeedbackPresented: false,
                isSessionsPresented: false,
                isTextInputFocused: false
            ),
            .previousLetter
        )
        XCTAssertEqual(
            DashboardView.appUsageRangeKeyboardShortcut(
                keyCode: 41,
                charactersIgnoringModifiers: ";",
                modifiers: [],
                isDatePopoverPresented: false,
                isFeedbackPresented: false,
                isSessionsPresented: false,
                isTextInputFocused: false
            ),
            .nextLetter
        )
        XCTAssertEqual(
            DashboardView.appUsageRangeKeyboardShortcut(
                keyCode: 123,
                charactersIgnoringModifiers: nil,
                modifiers: [.function],
                isDatePopoverPresented: false,
                isFeedbackPresented: false,
                isSessionsPresented: false,
                isTextInputFocused: false
            ),
            .previousArrow
        )
    }

    func testAppUsageRangeKeyboardShortcutsStandDownForBlockedStates() {
        XCTAssertNil(
            DashboardView.appUsageRangeKeyboardShortcut(
                keyCode: 123,
                charactersIgnoringModifiers: nil,
                modifiers: [.command],
                isDatePopoverPresented: false,
                isFeedbackPresented: false,
                isSessionsPresented: false,
                isTextInputFocused: false
            )
        )
        XCTAssertNil(
            DashboardView.appUsageRangeKeyboardShortcut(
                keyCode: 123,
                charactersIgnoringModifiers: nil,
                modifiers: [],
                isDatePopoverPresented: true,
                isFeedbackPresented: false,
                isSessionsPresented: false,
                isTextInputFocused: false
            )
        )
        XCTAssertNil(
            DashboardView.appUsageRangeKeyboardShortcut(
                keyCode: 123,
                charactersIgnoringModifiers: nil,
                modifiers: [],
                isDatePopoverPresented: false,
                isFeedbackPresented: true,
                isSessionsPresented: false,
                isTextInputFocused: false
            )
        )
        XCTAssertNil(
            DashboardView.appUsageRangeKeyboardShortcut(
                keyCode: 123,
                charactersIgnoringModifiers: nil,
                modifiers: [],
                isDatePopoverPresented: false,
                isFeedbackPresented: false,
                isSessionsPresented: true,
                isTextInputFocused: false
            )
        )
        XCTAssertNil(
            DashboardView.appUsageRangeKeyboardShortcut(
                keyCode: 123,
                charactersIgnoringModifiers: nil,
                modifiers: [],
                isDatePopoverPresented: false,
                isFeedbackPresented: false,
                isSessionsPresented: false,
                isTextInputFocused: true
            )
        )
    }

    private func makeSnapshot() -> DashboardAppUsageRangeSnapshot {
        DashboardAppUsageRangeSnapshot(
            weeklyAppUsage: [],
            totalWeeklyTime: 0,
            totalDailyTime: 0,
            weeklyStorageBytes: 0,
            dailyScreenTimeData: [],
            dailyStorageData: [],
            dailyTimelineOpensData: [],
            dailySearchesData: [],
            dailyTextCopiesData: [],
            timelineOpensThisWeek: 0,
            searchesThisWeek: 0,
            textCopiesThisWeek: 0
        )
    }

}
