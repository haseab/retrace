import XCTest
import AppKit
import Combine
import Shared
import App
@testable import Retrace

@MainActor
final class DateJumpTimeOnlyParsingTests: XCTestCase {
    func testMinuteAgoAbbreviationParses() {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        let now = makeDate(year: 2026, month: 2, day: 23, hour: 10, minute: 0)

        guard let result = viewModel.test_parseNaturalLanguageDateForDateSearch("2 min ago", now: now) else {
            XCTFail("Expected parser to resolve minute abbreviation")
            return
        }

        XCTAssertEqual(result.timeIntervalSince(now), -2 * 60, accuracy: 0.001)
        assertDateComponents(result, year: 2026, month: 2, day: 23, hour: 9, minute: 58)
    }

    func testHourAbbreviationWithPeriodParses() {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        let now = makeDate(year: 2026, month: 2, day: 23, hour: 10, minute: 0)

        guard let result = viewModel.test_parseNaturalLanguageDateForDateSearch("2 hr. ago", now: now) else {
            XCTFail("Expected parser to resolve hour abbreviation with period")
            return
        }

        XCTAssertEqual(result.timeIntervalSince(now), -2 * 60 * 60, accuracy: 0.001)
        assertDateComponents(result, year: 2026, month: 2, day: 23, hour: 8, minute: 0)
    }

    func testCompactDayAgoShorthandParses() {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        let now = makeDate(year: 2026, month: 2, day: 23, hour: 10, minute: 0)

        guard let result = viewModel.test_parseNaturalLanguageDateForDateSearch("2da", now: now) else {
            XCTFail("Expected parser to resolve compact day-ago shorthand")
            return
        }

        assertDateComponents(result, year: 2026, month: 2, day: 21, hour: 0, minute: 0)
    }

    func testSingleLetterDayUnitWithAgoParses() {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        let now = makeDate(year: 2026, month: 2, day: 23, hour: 10, minute: 0)

        guard let result = viewModel.test_parseNaturalLanguageDateForDateSearch("2d ago", now: now) else {
            XCTFail("Expected parser to resolve single-letter day unit with ago")
            return
        }

        assertDateComponents(result, year: 2026, month: 2, day: 21, hour: 0, minute: 0)
    }

    func testCompactHourAgoShorthandParses() {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        let now = makeDate(year: 2026, month: 2, day: 23, hour: 10, minute: 0)

        guard let result = viewModel.test_parseNaturalLanguageDateForDateSearch("2ha", now: now) else {
            XCTFail("Expected parser to resolve compact hour-ago shorthand")
            return
        }

        XCTAssertEqual(result.timeIntervalSince(now), -2 * 60 * 60, accuracy: 0.001)
        assertDateComponents(result, year: 2026, month: 2, day: 23, hour: 8, minute: 0)
    }

    func testCompactMinuteAgoShorthandParses() {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        let now = makeDate(year: 2026, month: 2, day: 23, hour: 10, minute: 0)

        guard let result = viewModel.test_parseNaturalLanguageDateForDateSearch("2ma", now: now) else {
            XCTFail("Expected parser to resolve compact minute-ago shorthand")
            return
        }

        XCTAssertEqual(result.timeIntervalSince(now), -2 * 60, accuracy: 0.001)
        assertDateComponents(result, year: 2026, month: 2, day: 23, hour: 9, minute: 58)
    }

    func testCompactDayAgoWithExplicitTimeParsesAsExactTime() {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        let now = makeDate(year: 2026, month: 2, day: 23, hour: 10, minute: 0)

        guard let result = viewModel.test_parseNaturalLanguageDateForDateSearch("2da 6pm", now: now) else {
            XCTFail("Expected parser to resolve compact day-ago shorthand with explicit time")
            return
        }

        assertDateComponents(result, year: 2026, month: 2, day: 21, hour: 18, minute: 0)
    }

    func testFutureTimeOnlyInputResolvesToPreviousDay() {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        let now = makeDate(year: 2026, month: 2, day: 23, hour: 10, minute: 0)

        guard let result = viewModel.test_parseNaturalLanguageDateForDateSearch("4pm", now: now) else {
            XCTFail("Expected parser to resolve a time-only date")
            return
        }

        assertDateComponents(result, year: 2026, month: 2, day: 22, hour: 16, minute: 0)
    }

    func testPastTimeOnlyInputStaysOnCurrentDay() {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        let now = makeDate(year: 2026, month: 2, day: 23, hour: 18, minute: 0)

        guard let result = viewModel.test_parseNaturalLanguageDateForDateSearch("4pm", now: now) else {
            XCTFail("Expected parser to resolve a time-only date")
            return
        }

        assertDateComponents(result, year: 2026, month: 2, day: 23, hour: 16, minute: 0)
    }

    func testDateWithCompact24HourTimeParsesAsExactTime() {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        let now = makeDate(year: 2026, month: 3, day: 1, hour: 9, minute: 0)

        guard let result = viewModel.test_parseNaturalLanguageDateForDateSearch("feb 28 1417", now: now) else {
            XCTFail("Expected parser to resolve compact 24-hour time in date input")
            return
        }

        assertDateComponents(result, year: 2026, month: 2, day: 28, hour: 14, minute: 17)
    }

    func testDateWithExplicitYearKeepsYearInterpretation() {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        let now = makeDate(year: 2026, month: 3, day: 1, hour: 9, minute: 0)

        guard let result = viewModel.test_parseNaturalLanguageDateForDateSearch("feb 28 2024", now: now) else {
            XCTFail("Expected parser to resolve explicit year input")
            return
        }

        assertDateComponents(result, year: 2024, month: 2, day: 28, hour: 0, minute: 0)
    }

    func testBareFourDigitInputParsesAsCompact24HourTime() {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        let now = makeDate(year: 2026, month: 3, day: 1, hour: 21, minute: 0)

        guard let result = viewModel.test_parseNaturalLanguageDateForDateSearch("2024", now: now) else {
            XCTFail("Expected parser to resolve bare four-digit input as compact 24-hour time")
            return
        }

        assertDateComponents(result, year: 2026, month: 3, day: 1, hour: 20, minute: 24)
    }

    func testLastYearInputParsesAsStartOfPreviousYear() {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        let now = makeDate(year: 2026, month: 3, day: 1, hour: 9, minute: 0)

        guard let result = viewModel.test_parseNaturalLanguageDateForDateSearch("last year", now: now) else {
            XCTFail("Expected parser to resolve last-year input")
            return
        }

        assertDateComponents(result, year: 2025, month: 1, day: 1, hour: 0, minute: 0)
    }

    func testLastMonthInputParsesAsStartOfPreviousMonth() {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        let now = makeDate(year: 2026, month: 8, day: 5, hour: 9, minute: 0)

        guard let result = viewModel.test_parseNaturalLanguageDateForDateSearch("last month", now: now) else {
            XCTFail("Expected parser to resolve last-month input")
            return
        }

        assertDateComponents(result, year: 2026, month: 7, day: 1, hour: 0, minute: 0)
    }

    func testMonthAndYearInputParses() {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        let now = makeDate(year: 2026, month: 3, day: 1, hour: 9, minute: 0)

        guard let result = viewModel.test_parseNaturalLanguageDateForDateSearch("july 2025", now: now) else {
            XCTFail("Expected parser to resolve month and year input")
            return
        }

        let components = Calendar.current.dateComponents([.year, .month], from: result)
        XCTAssertEqual(components.year, 2025)
        XCTAssertEqual(components.month, 7)
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
