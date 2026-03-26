import XCTest
import AppKit
import Combine
import Shared
import App
@testable import Retrace

@MainActor
final class DateJumpPlayheadRelativeParsingTests: XCTestCase {
    func testCompactDayBeforeShorthandUsesPlayheadBase() {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        let base = makeDate(year: 2026, month: 2, day: 23, hour: 9, minute: 48)

        guard let result = viewModel.test_parsePlayheadRelativeDateForDateSearch("2db", baseTimestamp: base) else {
            XCTFail("Expected parser to resolve compact day-before shorthand")
            return
        }

        XCTAssertEqual(result.timeIntervalSince(base), -2 * 24 * 60 * 60, accuracy: 0.001)
        assertDateComponents(result, year: 2026, month: 2, day: 21, hour: 9, minute: 48)
    }

    func testCompactMinuteBeforeShorthandUsesPlayheadBase() {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        let base = makeDate(year: 2026, month: 2, day: 23, hour: 9, minute: 48)

        guard let result = viewModel.test_parsePlayheadRelativeDateForDateSearch("2mb", baseTimestamp: base) else {
            XCTFail("Expected parser to resolve compact minute-before shorthand")
            return
        }

        XCTAssertEqual(result.timeIntervalSince(base), -2 * 60, accuracy: 0.001)
        assertDateComponents(result, year: 2026, month: 2, day: 23, hour: 9, minute: 46)
    }

    func testCompactHourBeforeShorthandUsesPlayheadBase() {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        let base = makeDate(year: 2026, month: 2, day: 23, hour: 9, minute: 48)

        guard let result = viewModel.test_parsePlayheadRelativeDateForDateSearch("2hb", baseTimestamp: base) else {
            XCTFail("Expected parser to resolve compact before shorthand")
            return
        }

        XCTAssertEqual(result.timeIntervalSince(base), -2 * 60 * 60, accuracy: 0.001)
        assertDateComponents(result, year: 2026, month: 2, day: 23, hour: 7, minute: 48)
    }

    func testCompactHourLaterShorthandUsesPlayheadBase() {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        let base = makeDate(year: 2026, month: 2, day: 23, hour: 9, minute: 48)

        guard let result = viewModel.test_parsePlayheadRelativeDateForDateSearch("2hl", baseTimestamp: base) else {
            XCTFail("Expected parser to resolve compact later shorthand")
            return
        }

        XCTAssertEqual(result.timeIntervalSince(base), 2 * 60 * 60, accuracy: 0.001)
        assertDateComponents(result, year: 2026, month: 2, day: 23, hour: 11, minute: 48)
    }

    func testCompactMinuteLaterShorthandUsesPlayheadBase() {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        let base = makeDate(year: 2026, month: 2, day: 23, hour: 9, minute: 48)

        guard let result = viewModel.test_parsePlayheadRelativeDateForDateSearch("2ml", baseTimestamp: base) else {
            XCTFail("Expected parser to resolve compact minute-later shorthand")
            return
        }

        XCTAssertEqual(result.timeIntervalSince(base), 2 * 60, accuracy: 0.001)
        assertDateComponents(result, year: 2026, month: 2, day: 23, hour: 9, minute: 50)
    }

    func testCompactHourEarlierShorthandUsesPlayheadBase() {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        let base = makeDate(year: 2026, month: 2, day: 23, hour: 9, minute: 48)

        guard let result = viewModel.test_parsePlayheadRelativeDateForDateSearch("2he", baseTimestamp: base) else {
            XCTFail("Expected parser to resolve compact earlier shorthand")
            return
        }

        XCTAssertEqual(result.timeIntervalSince(base), -2 * 60 * 60, accuracy: 0.001)
        assertDateComponents(result, year: 2026, month: 2, day: 23, hour: 7, minute: 48)
    }

    func testCompactMinuteEarlierShorthandUsesPlayheadBase() {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        let base = makeDate(year: 2026, month: 2, day: 23, hour: 9, minute: 48)

        guard let result = viewModel.test_parsePlayheadRelativeDateForDateSearch("2me", baseTimestamp: base) else {
            XCTFail("Expected parser to resolve compact minute-earlier shorthand")
            return
        }

        XCTAssertEqual(result.timeIntervalSince(base), -2 * 60, accuracy: 0.001)
        assertDateComponents(result, year: 2026, month: 2, day: 23, hour: 9, minute: 46)
    }

    func testCompactHourAfterShorthandUsesPlayheadBase() {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        let base = makeDate(year: 2026, month: 2, day: 23, hour: 9, minute: 48)

        guard let result = viewModel.test_parsePlayheadRelativeDateForDateSearch("2haf", baseTimestamp: base) else {
            XCTFail("Expected parser to resolve compact after shorthand")
            return
        }

        XCTAssertEqual(result.timeIntervalSince(base), 2 * 60 * 60, accuracy: 0.001)
        assertDateComponents(result, year: 2026, month: 2, day: 23, hour: 11, minute: 48)
    }

    func testCompactMinuteAfterShorthandUsesPlayheadBase() {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        let base = makeDate(year: 2026, month: 2, day: 23, hour: 9, minute: 48)

        guard let result = viewModel.test_parsePlayheadRelativeDateForDateSearch("2maf", baseTimestamp: base) else {
            XCTFail("Expected parser to resolve compact minute-after shorthand")
            return
        }

        XCTAssertEqual(result.timeIntervalSince(base), 2 * 60, accuracy: 0.001)
        assertDateComponents(result, year: 2026, month: 2, day: 23, hour: 9, minute: 50)
    }

    func testCompactDayAfterShorthandUsesPlayheadBase() {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        let base = makeDate(year: 2026, month: 2, day: 23, hour: 9, minute: 48)

        guard let result = viewModel.test_parsePlayheadRelativeDateForDateSearch("2daf", baseTimestamp: base) else {
            XCTFail("Expected parser to resolve compact day-after shorthand")
            return
        }

        XCTAssertEqual(result.timeIntervalSince(base), 2 * 24 * 60 * 60, accuracy: 0.001)
        assertDateComponents(result, year: 2026, month: 2, day: 25, hour: 9, minute: 48)
    }

    func testDayEarlierResolvesToExact1440MinutesFromPlayhead() {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        let base = makeDate(year: 2026, month: 2, day: 23, hour: 9, minute: 48)

        guard let result = viewModel.test_parsePlayheadRelativeDateForDateSearch("1 day earlier", baseTimestamp: base) else {
            XCTFail("Expected parser to resolve playhead-relative day offset")
            return
        }

        XCTAssertEqual(result.timeIntervalSince(base), -24 * 60 * 60, accuracy: 0.001)
        assertDateComponents(result, year: 2026, month: 2, day: 22, hour: 9, minute: 48)
    }

    func testWeekLaterResolvesToExact10080MinutesFromPlayhead() {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        let base = makeDate(year: 2026, month: 2, day: 23, hour: 9, minute: 48)

        guard let result = viewModel.test_parsePlayheadRelativeDateForDateSearch("1 week later", baseTimestamp: base) else {
            XCTFail("Expected parser to resolve playhead-relative week offset")
            return
        }

        XCTAssertEqual(result.timeIntervalSince(base), 7 * 24 * 60 * 60, accuracy: 0.001)
        assertDateComponents(result, year: 2026, month: 3, day: 2, hour: 9, minute: 48)
    }

    func testMonthEarlierUsesPlayheadAsBaseAndPreservesClockTime() {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        let base = makeDate(year: 2026, month: 5, day: 15, hour: 9, minute: 48)

        guard let result = viewModel.test_parsePlayheadRelativeDateForDateSearch("1 month earlier", baseTimestamp: base) else {
            XCTFail("Expected parser to resolve playhead-relative month offset")
            return
        }

        assertDateComponents(result, year: 2026, month: 4, day: 15, hour: 9, minute: 48)
    }

    func testHourBeforeResolvesToExact60MinutesFromPlayhead() {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        let base = makeDate(year: 2026, month: 2, day: 23, hour: 9, minute: 48)

        guard let result = viewModel.test_parsePlayheadRelativeDateForDateSearch("1 hour before", baseTimestamp: base) else {
            XCTFail("Expected parser to resolve playhead-relative hour offset")
            return
        }

        XCTAssertEqual(result.timeIntervalSince(base), -60 * 60, accuracy: 0.001)
        assertDateComponents(result, year: 2026, month: 2, day: 23, hour: 8, minute: 48)
    }

    func testMonthAfterUsesPlayheadAsBaseAndPreservesClockTime() {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        let base = makeDate(year: 2026, month: 5, day: 15, hour: 9, minute: 48)

        guard let result = viewModel.test_parsePlayheadRelativeDateForDateSearch("1 month after", baseTimestamp: base) else {
            XCTFail("Expected parser to resolve playhead-relative month offset")
            return
        }

        assertDateComponents(result, year: 2026, month: 6, day: 15, hour: 9, minute: 48)
    }

    func testAgoPhraseIsNotHandledByPlayheadEarlierLaterParser() {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        let base = makeDate(year: 2026, month: 2, day: 23, hour: 9, minute: 48)

        let result = viewModel.test_parsePlayheadRelativeDateForDateSearch("1 hour ago", baseTimestamp: base)
        XCTAssertNil(result)
    }

    private func makeDate(year: Int, month: Int, day: Int, hour: Int, minute: Int) -> Date {
        let calendar = Calendar.current
        let components = DateComponents(
            calendar: calendar,
            timeZone: .current,
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute,
            second: 0
        )
        guard let date = components.date else {
            fatalError("Failed to construct test date")
        }
        return date
    }

    private func assertDateComponents(_ date: Date, year: Int, month: Int, day: Int, hour: Int, minute: Int) {
        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        XCTAssertEqual(components.year, year)
        XCTAssertEqual(components.month, month)
        XCTAssertEqual(components.day, day)
        XCTAssertEqual(components.hour, hour)
        XCTAssertEqual(components.minute, minute)
    }
}
