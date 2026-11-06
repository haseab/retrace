import XCTest
import AppKit
import App
import Combine
import Shared
@testable import Retrace

@MainActor
final class DashboardAppUsageDateRangeTests: XCTestCase {
    func testCustomRangeLoadsDayStorageWithoutRefreshingAllTimeMetadata() async throws {
        let (viewModel, day) = try await makeStatisticsViewModel()
        viewModel.isDefaultAppUsageRangeSelected = false
        viewModel.appUsageRangeStart = day.addingTimeInterval(12 * 60 * 60)
        viewModel.appUsageRangeEnd = day.addingTimeInterval(13 * 60 * 60)
        viewModel.totalStorageBytes = -1
        viewModel.totalCapturedDuration = -1
        viewModel.daysRecorded = -1

        var graphsWereReadyWhenUsagePublished: Bool?
        let publication = viewModel.$isLoading.dropFirst().filter { !$0 }.prefix(1).sink { _ in
            graphsWereReadyWhenUsagePublished = !viewModel.dailyStorageData.isEmpty
        }

        await viewModel.loadStatistics(reason: "test_custom_range")
        withExtendedLifetime(publication) {}

        XCTAssertNil(viewModel.error)
        XCTAssertFalse(viewModel.isLoading)
        XCTAssertEqual(viewModel.weeklyStorageBytes, 256)
        XCTAssertEqual(viewModel.totalStorageBytes, -1)
        XCTAssertEqual(viewModel.totalCapturedDuration, -1)
        XCTAssertEqual(viewModel.daysRecorded, -1)
        XCTAssertEqual(graphsWereReadyWhenUsagePublished, false)
    }

    func testDefaultDashboardStillRefreshesAllTimeMetadata() async throws {
        let (viewModel, _) = try await makeStatisticsViewModel()

        await viewModel.loadStatistics(reason: "test_default_range")

        XCTAssertNil(viewModel.error)
        XCTAssertGreaterThan(viewModel.totalStorageBytes, 256 + 512)
        XCTAssertEqual(viewModel.totalCapturedDuration, 0)
        XCTAssertEqual(viewModel.daysRecorded, 2)
    }

    func testDashboardDeeplinkAppliesExactRangeThroughTheRealStatisticsLoad() async throws {
        let (viewModel, day) = try await makeStatisticsViewModel()
        let start = day.addingTimeInterval(12 * 60 * 60 + 17 * 60)
        let end = start.addingTimeInterval(13 * 60)
        let url = try XCTUnwrap(DeeplinkHandler.generateDashboardLink(start: start, end: end))
        guard case let .dashboard(dateRange)? = DeeplinkHandler.route(for: url), let dateRange else {
            return XCTFail("Expected dashboard date range")
        }

        await viewModel.setAppUsageDateRange(from: dateRange, source: "dashboard_deeplink")

        XCTAssertNil(viewModel.error)
        XCTAssertFalse(viewModel.isDefaultAppUsageRangeSelected)
        XCTAssertEqual(viewModel.appUsageQueryRange.start, start)
        XCTAssertEqual(viewModel.appUsageQueryRange.end, end)
        XCTAssertEqual(viewModel.weeklyStorageBytes, 256)
        XCTAssertEqual(viewModel.totalStorageBytes, 0, "Deeplinks must not start an all-time storage scan")
    }

    private func makeStatisticsViewModel() async throws -> (DashboardViewModel, Date) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dashboard-range-\(UUID().uuidString)")
        let calendar = Calendar.current
        let day = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: Date())))
        let olderDay = try XCTUnwrap(calendar.date(byAdding: .day, value: -2, to: day))
        for (date, bytes) in [(day, 256), (olderDay, 512)] {
            let components = calendar.dateComponents([.year, .month, .day], from: date)
            let folder = root.appendingPathComponent(String(format: "chunks/%04d%02d/%02d", components.year!, components.month!, components.day!))
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(repeating: 1, count: bytes).write(to: folder.appendingPathComponent("recording.mp4"))
        }

        let services = ServiceContainer(
            databasePath: root.appendingPathComponent("retrace.db").path,
            storageConfig: StorageConfig(storageRootPath: root.path)
        )
        let database = await services.database
        try await database.initialize()
        addTeardownBlock {
            try await database.close()
            try FileManager.default.removeItem(at: root)
        }
        return (DashboardViewModel(coordinator: AppCoordinator(services: services)), day)
    }

    func testNormalizedAppUsageDateRangePreservesExactTimes() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2025, month: 12, day: 4, hour: 12, minute: 17)))
        let end = start.addingTimeInterval(13 * 60)
        let now = end.addingTimeInterval(24 * 60 * 60)

        let normalized = DashboardViewModel.normalizedAppUsageDateRange(start: start, end: end, calendar: calendar, now: now)

        XCTAssertEqual(normalized.start, start)
        XCTAssertEqual(normalized.end, end)
    }

    func testAppUsageCacheDistinguishesTimeRangesOnTheSameDay() {
        let start = Date(timeIntervalSince1970: 1_764_850_620)
        let first = DashboardAppUsageRangeCacheKey(start: start, end: start.addingTimeInterval(13 * 60))
        let second = DashboardAppUsageRangeCacheKey(start: start.addingTimeInterval(60), end: start.addingTimeInterval(14 * 60))
        var cache = DashboardAppUsageRangeCache()
        cache.insert(makeSnapshot(), for: first)

        XCTAssertNotEqual(first, second)
        XCTAssertNotNil(cache.snapshot(for: first))
        XCTAssertNil(cache.snapshot(for: second))
    }

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
            calendar.date(bySettingHour: 23, minute: 59, second: 59, of: calendar.date(byAdding: .day, value: 29, to: start)!)!
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
            calendar.date(bySettingHour: 23, minute: 59, second: 59, of: now)!
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
                end: calendar.date(from: DateComponents(year: 2026, month: 4, day: offset + 1))!
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
                keyCode: 51,
                charactersIgnoringModifiers: nil,
                modifiers: [.command],
                isDatePopoverPresented: false,
                isFeedbackPresented: false,
                isSessionsPresented: false,
                isTextInputFocused: false
            ),
            .reset
        )
        XCTAssertEqual(
            DashboardView.appUsageRangeKeyboardShortcut(
                keyCode: 117,
                charactersIgnoringModifiers: nil,
                modifiers: [.command],
                isDatePopoverPresented: false,
                isFeedbackPresented: false,
                isSessionsPresented: false,
                isTextInputFocused: false
            ),
            .reset
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
