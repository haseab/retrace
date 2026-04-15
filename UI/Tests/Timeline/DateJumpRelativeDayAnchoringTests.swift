import XCTest
import AppKit
import Combine
import Shared
import App
@testable import Retrace

@MainActor
final class DateJumpRelativeDayAnchoringTests: XCTestCase {
    func testMonthAndYearUseFirstFrameInResolvedMonth() async {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        let calendar = Calendar.current
        let month = makeDate(year: 2025, month: 7, day: 1, hour: 0, minute: 0)
        guard let monthInterval = calendar.dateInterval(of: .month, for: month) else {
            XCTFail("Failed to construct expected month interval")
            return
        }

        var anchoredTimestamp: Date?
        var sawMonthAnchorFetch = false
        var sawWindowFetch = false

        viewModel.test_windowFetchHooks.getFramesWithVideoInfo = { start, end, limit, _, reason in
            switch reason {
            case "searchForDate.anchor.firstFrameInMonth":
                sawMonthAnchorFetch = true
                XCTAssertEqual(limit, 1)
                XCTAssertEqual(start.timeIntervalSince(monthInterval.start), 0, accuracy: 0.01)
                XCTAssertEqual(end.timeIntervalSince(monthInterval.end), -0.001, accuracy: 0.01)
                let firstFrameInMonth = start.addingTimeInterval(123)
                anchoredTimestamp = firstFrameInMonth
                return [self.makeFrameWithVideoInfo(id: 6999, timestamp: firstFrameInMonth, processingStatus: 4)]

            case "searchForDate":
                sawWindowFetch = true
                guard let anchoredTimestamp else {
                    XCTFail("Expected month anchor to resolve before window fetch")
                    return []
                }
                XCTAssertEqual(limit, 1000)
                XCTAssertEqual(start.timeIntervalSince(anchoredTimestamp), -600, accuracy: 0.01)
                XCTAssertEqual(end.timeIntervalSince(anchoredTimestamp), 600, accuracy: 0.01)
                return [self.makeFrameWithVideoInfo(id: 6999, timestamp: anchoredTimestamp, processingStatus: 4)]

            case "loadNewerFrames.reason=searchForDate",
                 "loadOlderFrames.reason=searchForDate":
                return []

            default:
                XCTFail("Unexpected fetch reason: \(reason)")
                return []
            }
        }

        await viewModel.searchForDate("july 2025")

        XCTAssertTrue(sawMonthAnchorFetch)
        XCTAssertTrue(sawWindowFetch)
        XCTAssertEqual(viewModel.currentTimelineFrame?.frame.id.value, 6999)
        XCTAssertEqual(viewModel.currentTimelineFrame?.frame.timestamp, anchoredTimestamp)
    }

    func testDaysAgoUsesFirstFrameInRecentLookbackWindow() async {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        let calendar = Calendar.current
        var anchoredTimestamp: Date?
        var sawLookbackAnchorFetch = false
        var sawWindowFetch = false

        viewModel.test_windowFetchHooks.getFramesWithVideoInfo = { start, end, limit, _, reason in
            switch reason {
            case "searchForDate.anchor.firstFrameInRelativeLookback":
                sawLookbackAnchorFetch = true
                XCTAssertEqual(limit, 1)
                XCTAssertLessThan(abs(end.timeIntervalSinceNow), 5.0)
                guard let reconstructedEnd = calendar.date(byAdding: .day, value: 2, to: start) else {
                    XCTFail("Expected two-day lookback window")
                    return []
                }
                XCTAssertEqual(reconstructedEnd.timeIntervalSince(end), 0, accuracy: 1.0)
                let firstFrameInLookbackWindow = start.addingTimeInterval(123)
                anchoredTimestamp = firstFrameInLookbackWindow
                return [self.makeFrameWithVideoInfo(id: 7001, timestamp: firstFrameInLookbackWindow, processingStatus: 4)]

            case "searchForDate":
                sawWindowFetch = true
                guard let anchoredTimestamp else {
                    XCTFail("Expected lookback anchor to resolve before window fetch")
                    return []
                }
                XCTAssertEqual(limit, 1000)
                XCTAssertEqual(start.timeIntervalSince(anchoredTimestamp), -600, accuracy: 0.01)
                XCTAssertEqual(end.timeIntervalSince(anchoredTimestamp), 600, accuracy: 0.01)
                return [self.makeFrameWithVideoInfo(id: 7001, timestamp: anchoredTimestamp, processingStatus: 4)]

            case "loadNewerFrames.reason=searchForDate",
                 "loadOlderFrames.reason=searchForDate":
                return []

            default:
                XCTFail("Unexpected fetch reason: \(reason)")
                return []
            }
        }

        await viewModel.searchForDate("2 days ago")

        XCTAssertTrue(sawLookbackAnchorFetch)
        XCTAssertTrue(sawWindowFetch)
        XCTAssertEqual(viewModel.currentTimelineFrame?.frame.id.value, 7001)
        XCTAssertEqual(viewModel.currentTimelineFrame?.frame.timestamp, anchoredTimestamp)
    }

    func testDaysAgoPreservesAndAppliesActiveFilters() async {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        let expectedFilters = FilterCriteria(selectedApps: ["com.apple.Safari"])
        viewModel.replaceAppliedAndPendingFilterCriteria(expectedFilters)

        var anchorFilters: [FilterCriteria] = []
        var windowFilters: [FilterCriteria] = []
        var anchoredTimestamp: Date?

        viewModel.test_windowFetchHooks.getFramesWithVideoInfo = { start, end, limit, filters, reason in
            switch reason {
            case "searchForDate.anchor.firstFrameInRelativeLookback":
                anchorFilters.append(filters)
                XCTAssertEqual(limit, 1)
                XCTAssertLessThan(abs(end.timeIntervalSinceNow), 5.0)
                let firstFrameInLookbackWindow = start.addingTimeInterval(90)
                anchoredTimestamp = firstFrameInLookbackWindow
                return [self.makeFrameWithVideoInfo(id: 7101, timestamp: firstFrameInLookbackWindow, processingStatus: 4)]

            case "searchForDate":
                windowFilters.append(filters)
                guard let anchoredTimestamp else {
                    XCTFail("Expected lookback anchor to resolve before window fetch")
                    return []
                }
                XCTAssertEqual(start.timeIntervalSince(anchoredTimestamp), -600, accuracy: 0.01)
                XCTAssertEqual(end.timeIntervalSince(anchoredTimestamp), 600, accuracy: 0.01)
                return [self.makeFrameWithVideoInfo(id: 7101, timestamp: anchoredTimestamp, processingStatus: 4)]

            case "loadNewerFrames.reason=searchForDate",
                 "loadOlderFrames.reason=searchForDate":
                return []

            default:
                XCTFail("Unexpected fetch reason: \(reason)")
                return []
            }
        }

        await viewModel.searchForDate("1 day ago")

        XCTAssertEqual(anchorFilters.count, 1)
        XCTAssertEqual(windowFilters.count, 1)
        XCTAssertEqual(anchorFilters.first?.selectedApps, expectedFilters.selectedApps)
        XCTAssertEqual(windowFilters.first?.selectedApps, expectedFilters.selectedApps)
        XCTAssertEqual(viewModel.filterCriteria.selectedApps, expectedFilters.selectedApps)
        XCTAssertEqual(viewModel.pendingFilterCriteria.selectedApps, expectedFilters.selectedApps)
    }

    func testMonthsAgoUsesFirstFrameInRecentLookbackWindow() async {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        let calendar = Calendar.current
        var anchoredTimestamp: Date?
        var sawLookbackAnchorFetch = false
        var sawWindowFetch = false

        viewModel.test_windowFetchHooks.getFramesWithVideoInfo = { start, end, limit, _, reason in
            switch reason {
            case "searchForDate.anchor.firstFrameInRelativeLookback":
                sawLookbackAnchorFetch = true
                XCTAssertEqual(limit, 1)
                XCTAssertLessThan(abs(end.timeIntervalSinceNow), 5.0)
                guard let reconstructedEnd = calendar.date(byAdding: .month, value: 2, to: start) else {
                    XCTFail("Expected two-month lookback window")
                    return []
                }
                XCTAssertEqual(reconstructedEnd.timeIntervalSince(end), 0, accuracy: 1.0)
                let firstFrameInLookbackWindow = start.addingTimeInterval(150)
                anchoredTimestamp = firstFrameInLookbackWindow
                return [self.makeFrameWithVideoInfo(id: 7210, timestamp: firstFrameInLookbackWindow, processingStatus: 4)]

            case "searchForDate":
                sawWindowFetch = true
                guard let anchoredTimestamp else {
                    XCTFail("Expected month lookback anchor to resolve before window fetch")
                    return []
                }
                XCTAssertEqual(start.timeIntervalSince(anchoredTimestamp), -600, accuracy: 0.01)
                XCTAssertEqual(end.timeIntervalSince(anchoredTimestamp), 600, accuracy: 0.01)
                return [self.makeFrameWithVideoInfo(id: 7210, timestamp: anchoredTimestamp, processingStatus: 4)]

            case "loadNewerFrames.reason=searchForDate",
                 "loadOlderFrames.reason=searchForDate":
                return []

            default:
                XCTFail("Unexpected fetch reason: \(reason)")
                return []
            }
        }

        await viewModel.searchForDate("2 months ago")

        XCTAssertTrue(sawLookbackAnchorFetch)
        XCTAssertTrue(sawWindowFetch)
        XCTAssertEqual(viewModel.currentTimelineFrame?.frame.id.value, 7210)
        XCTAssertEqual(viewModel.currentTimelineFrame?.frame.timestamp, anchoredTimestamp)
    }

    func testYearsAgoUsesFirstFrameInRecentLookbackWindow() async {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        let calendar = Calendar.current
        var anchoredTimestamp: Date?
        var sawLookbackAnchorFetch = false
        var sawWindowFetch = false

        viewModel.test_windowFetchHooks.getFramesWithVideoInfo = { start, end, limit, _, reason in
            switch reason {
            case "searchForDate.anchor.firstFrameInRelativeLookback":
                sawLookbackAnchorFetch = true
                XCTAssertEqual(limit, 1)
                XCTAssertLessThan(abs(end.timeIntervalSinceNow), 5.0)
                guard let reconstructedEnd = calendar.date(byAdding: .year, value: 1, to: start) else {
                    XCTFail("Expected one-year lookback window")
                    return []
                }
                XCTAssertEqual(reconstructedEnd.timeIntervalSince(end), 0, accuracy: 1.0)
                let firstFrameInLookbackWindow = start.addingTimeInterval(165)
                anchoredTimestamp = firstFrameInLookbackWindow
                return [self.makeFrameWithVideoInfo(id: 7211, timestamp: firstFrameInLookbackWindow, processingStatus: 4)]

            case "searchForDate":
                sawWindowFetch = true
                guard let anchoredTimestamp else {
                    XCTFail("Expected year lookback anchor to resolve before window fetch")
                    return []
                }
                XCTAssertEqual(start.timeIntervalSince(anchoredTimestamp), -600, accuracy: 0.01)
                XCTAssertEqual(end.timeIntervalSince(anchoredTimestamp), 600, accuracy: 0.01)
                return [self.makeFrameWithVideoInfo(id: 7211, timestamp: anchoredTimestamp, processingStatus: 4)]

            case "loadNewerFrames.reason=searchForDate",
                 "loadOlderFrames.reason=searchForDate":
                return []

            default:
                XCTFail("Unexpected fetch reason: \(reason)")
                return []
            }
        }

        await viewModel.searchForDate("1 year ago")

        XCTAssertTrue(sawLookbackAnchorFetch)
        XCTAssertTrue(sawWindowFetch)
        XCTAssertEqual(viewModel.currentTimelineFrame?.frame.id.value, 7211)
        XCTAssertEqual(viewModel.currentTimelineFrame?.frame.timestamp, anchoredTimestamp)
    }

    func testHoursAgoUsesFirstFrameInRecentLookbackWindowWithinActiveFilters() async {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        let expectedFilters = FilterCriteria(selectedApps: ["com.apple.Safari"])
        viewModel.replaceAppliedAndPendingFilterCriteria(expectedFilters)

        var sawLookbackAnchorFetch = false
        var sawWindowFetch = false
        var anchoredTimestamp: Date?

        viewModel.test_windowFetchHooks.getFramesWithVideoInfo = { start, end, limit, filters, reason in
            switch reason {
            case "searchForDate.anchor.firstFrameInRelativeLookback":
                sawLookbackAnchorFetch = true
                XCTAssertEqual(limit, 1)
                XCTAssertEqual(filters.selectedApps, expectedFilters.selectedApps)
                XCTAssertEqual(end.timeIntervalSince(start), 60 * 60, accuracy: 1.0)
                XCTAssertLessThan(abs(end.timeIntervalSinceNow), 5.0)
                let firstFrameInLookbackWindow = start.addingTimeInterval(45)
                anchoredTimestamp = firstFrameInLookbackWindow
                return [self.makeFrameWithVideoInfo(id: 7201, timestamp: firstFrameInLookbackWindow, processingStatus: 4)]

            case "searchForDate":
                sawWindowFetch = true
                guard let anchoredTimestamp else {
                    XCTFail("Expected hour anchor to resolve before window fetch")
                    return []
                }
                XCTAssertEqual(filters.selectedApps, expectedFilters.selectedApps)
                XCTAssertEqual(start.timeIntervalSince(anchoredTimestamp), -600, accuracy: 0.01)
                XCTAssertEqual(end.timeIntervalSince(anchoredTimestamp), 600, accuracy: 0.01)
                return [self.makeFrameWithVideoInfo(id: 7201, timestamp: anchoredTimestamp, processingStatus: 4)]

            case "loadNewerFrames.reason=searchForDate",
                 "loadOlderFrames.reason=searchForDate":
                return []

            default:
                XCTFail("Unexpected fetch reason: \(reason)")
                return []
            }
        }

        await viewModel.searchForDate("1 hour ago")

        XCTAssertTrue(sawLookbackAnchorFetch)
        XCTAssertTrue(sawWindowFetch)
        XCTAssertEqual(viewModel.currentTimelineFrame?.frame.id.value, 7201)
        XCTAssertEqual(viewModel.currentTimelineFrame?.frame.timestamp, anchoredTimestamp)
        XCTAssertEqual(viewModel.filterCriteria.selectedApps, expectedFilters.selectedApps)
    }

    func testHourBeforeUsesFirstFrameInPlayheadLookbackWindow() async {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        let base = makeDate(year: 2026, month: 2, day: 23, hour: 9, minute: 48)
        viewModel.frames = [makeTimelineFrame(id: 7300, timestamp: base, processingStatus: 4)]
        viewModel.currentIndex = 0

        var anchoredTimestamp: Date?
        var sawLookbackFetch = false
        var sawWindowFetch = false

        viewModel.test_windowFetchHooks.getFramesWithVideoInfo = { start, end, limit, _, reason in
            switch reason {
            case "searchForDate.anchor.firstFrameInRelativeLookback":
                sawLookbackFetch = true
                XCTAssertEqual(limit, 1)
                XCTAssertEqual(start.timeIntervalSince(base), -60 * 60, accuracy: 0.01)
                XCTAssertEqual(end.timeIntervalSince(base), 0, accuracy: 0.01)
                let firstFrameInWindow = start.addingTimeInterval(30)
                anchoredTimestamp = firstFrameInWindow
                return [self.makeFrameWithVideoInfo(id: 7301, timestamp: firstFrameInWindow, processingStatus: 4)]

            case "searchForDate":
                sawWindowFetch = true
                guard let anchoredTimestamp else {
                    XCTFail("Expected lookback anchor to resolve before window fetch")
                    return []
                }
                XCTAssertEqual(start.timeIntervalSince(anchoredTimestamp), -600, accuracy: 0.01)
                XCTAssertEqual(end.timeIntervalSince(anchoredTimestamp), 600, accuracy: 0.01)
                return [self.makeFrameWithVideoInfo(id: 7301, timestamp: anchoredTimestamp, processingStatus: 4)]

            case "loadNewerFrames.reason=searchForDate",
                 "loadOlderFrames.reason=searchForDate":
                return []

            default:
                XCTFail("Unexpected fetch reason: \(reason)")
                return []
            }
        }

        await viewModel.searchForDate("1 hour before")

        XCTAssertTrue(sawLookbackFetch)
        XCTAssertTrue(sawWindowFetch)
        XCTAssertEqual(viewModel.currentTimelineFrame?.frame.id.value, 7301)
        XCTAssertEqual(viewModel.currentTimelineFrame?.frame.timestamp, anchoredTimestamp)
    }

    func testHourEarlierUsesSamePlayheadLookbackWindowBehavior() async {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        let base = makeDate(year: 2026, month: 2, day: 23, hour: 9, minute: 48)
        viewModel.frames = [makeTimelineFrame(id: 7310, timestamp: base, processingStatus: 4)]
        viewModel.currentIndex = 0

        var anchoredTimestamp: Date?
        var sawLookbackFetch = false

        viewModel.test_windowFetchHooks.getFramesWithVideoInfo = { start, end, limit, _, reason in
            switch reason {
            case "searchForDate.anchor.firstFrameInRelativeLookback":
                sawLookbackFetch = true
                XCTAssertEqual(limit, 1)
                XCTAssertEqual(start.timeIntervalSince(base), -8 * 60 * 60, accuracy: 0.01)
                XCTAssertEqual(end.timeIntervalSince(base), 0, accuracy: 0.01)
                let firstFrameInWindow = start.addingTimeInterval(45)
                anchoredTimestamp = firstFrameInWindow
                return [self.makeFrameWithVideoInfo(id: 7311, timestamp: firstFrameInWindow, processingStatus: 4)]

            case "searchForDate":
                guard let anchoredTimestamp else {
                    XCTFail("Expected lookback anchor to resolve before window fetch")
                    return []
                }
                XCTAssertEqual(start.timeIntervalSince(anchoredTimestamp), -600, accuracy: 0.01)
                XCTAssertEqual(end.timeIntervalSince(anchoredTimestamp), 600, accuracy: 0.01)
                return [self.makeFrameWithVideoInfo(id: 7311, timestamp: anchoredTimestamp, processingStatus: 4)]

            case "loadNewerFrames.reason=searchForDate",
                 "loadOlderFrames.reason=searchForDate":
                return []

            default:
                XCTFail("Unexpected fetch reason: \(reason)")
                return []
            }
        }

        await viewModel.searchForDate("8 hour earlier")

        XCTAssertTrue(sawLookbackFetch)
        XCTAssertEqual(viewModel.currentTimelineFrame?.frame.id.value, 7311)
        XCTAssertEqual(viewModel.currentTimelineFrame?.frame.timestamp, anchoredTimestamp)
    }

    func testHourAfterUsesLastFrameInPlayheadForwardWindow() async {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        let base = makeDate(year: 2026, month: 2, day: 23, hour: 9, minute: 48)
        viewModel.frames = [makeTimelineFrame(id: 7315, timestamp: base, processingStatus: 4)]
        viewModel.currentIndex = 0

        var anchoredTimestamp: Date?
        var sawLastAnchorFetch = false
        var sawWindowFetch = false

        viewModel.test_windowFetchHooks.getFramesWithVideoInfoBefore = { timestamp, limit, _, reason in
            switch reason {
            case "searchForDate.anchor.lastFrameInRelativeLookback":
                sawLastAnchorFetch = true
                XCTAssertEqual(limit, 1)
                XCTAssertGreaterThan(timestamp.timeIntervalSince(base), 60 * 60)
                XCTAssertLessThan(timestamp.timeIntervalSince(base), (60 * 60) + 1.0)
                let lastFrameInWindow = base.addingTimeInterval((60 * 60) - 12)
                anchoredTimestamp = lastFrameInWindow
                return [self.makeFrameWithVideoInfo(id: 7316, timestamp: lastFrameInWindow, processingStatus: 4)]

            case "loadOlderFrames.reason=searchForDate":
                return []

            default:
                XCTFail("Unexpected before-fetch reason: \(reason)")
                return []
            }
        }

        viewModel.test_windowFetchHooks.getFramesWithVideoInfo = { start, end, _, _, reason in
            switch reason {
            case "searchForDate":
                sawWindowFetch = true
                guard let anchoredTimestamp else {
                    XCTFail("Expected forward lookback anchor to resolve before window fetch")
                    return []
                }
                XCTAssertEqual(start.timeIntervalSince(anchoredTimestamp), -600, accuracy: 0.01)
                XCTAssertEqual(end.timeIntervalSince(anchoredTimestamp), 600, accuracy: 0.01)
                return [self.makeFrameWithVideoInfo(id: 7316, timestamp: anchoredTimestamp, processingStatus: 4)]

            case "loadNewerFrames.reason=searchForDate":
                return []

            default:
                XCTFail("Unexpected window-fetch reason: \(reason)")
                return []
            }
        }

        await viewModel.searchForDate("1 hour after")

        XCTAssertTrue(sawLastAnchorFetch)
        XCTAssertTrue(sawWindowFetch)
        XCTAssertEqual(viewModel.currentTimelineFrame?.frame.id.value, 7316)
        XCTAssertEqual(viewModel.currentTimelineFrame?.frame.timestamp, anchoredTimestamp)
    }

    func testHourLaterUsesSameLastFrameForwardWindowBehavior() async {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        let base = makeDate(year: 2026, month: 2, day: 23, hour: 9, minute: 48)
        viewModel.frames = [makeTimelineFrame(id: 7317, timestamp: base, processingStatus: 4)]
        viewModel.currentIndex = 0

        var anchoredTimestamp: Date?
        var sawLastAnchorFetch = false

        viewModel.test_windowFetchHooks.getFramesWithVideoInfoBefore = { timestamp, limit, _, reason in
            switch reason {
            case "searchForDate.anchor.lastFrameInRelativeLookback":
                sawLastAnchorFetch = true
                XCTAssertEqual(limit, 1)
                XCTAssertGreaterThan(timestamp.timeIntervalSince(base), 2 * 60 * 60)
                XCTAssertLessThan(timestamp.timeIntervalSince(base), (2 * 60 * 60) + 1.0)
                let lastFrameInWindow = base.addingTimeInterval((2 * 60 * 60) - 9)
                anchoredTimestamp = lastFrameInWindow
                return [self.makeFrameWithVideoInfo(id: 7318, timestamp: lastFrameInWindow, processingStatus: 4)]

            case "loadOlderFrames.reason=searchForDate":
                return []

            default:
                XCTFail("Unexpected before-fetch reason: \(reason)")
                return []
            }
        }

        viewModel.test_windowFetchHooks.getFramesWithVideoInfo = { start, end, _, _, reason in
            switch reason {
            case "searchForDate":
                guard let anchoredTimestamp else {
                    XCTFail("Expected forward lookback anchor to resolve before window fetch")
                    return []
                }
                XCTAssertEqual(start.timeIntervalSince(anchoredTimestamp), -600, accuracy: 0.01)
                XCTAssertEqual(end.timeIntervalSince(anchoredTimestamp), 600, accuracy: 0.01)
                return [self.makeFrameWithVideoInfo(id: 7318, timestamp: anchoredTimestamp, processingStatus: 4)]

            case "loadNewerFrames.reason=searchForDate":
                return []

            default:
                XCTFail("Unexpected window-fetch reason: \(reason)")
                return []
            }
        }

        await viewModel.searchForDate("2 hours later")

        XCTAssertTrue(sawLastAnchorFetch)
        XCTAssertEqual(viewModel.currentTimelineFrame?.frame.id.value, 7318)
        XCTAssertEqual(viewModel.currentTimelineFrame?.frame.timestamp, anchoredTimestamp)
    }

    func testDayBeforeUsesFirstFrameInPlayheadLookbackWindow() async {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        let base = makeDate(year: 2026, month: 2, day: 23, hour: 9, minute: 48)
        viewModel.frames = [makeTimelineFrame(id: 7320, timestamp: base, processingStatus: 4)]
        viewModel.currentIndex = 0

        var anchoredTimestamp: Date?
        var sawLookbackFetch = false

        viewModel.test_windowFetchHooks.getFramesWithVideoInfo = { start, end, limit, _, reason in
            switch reason {
            case "searchForDate.anchor.firstFrameInRelativeLookback":
                sawLookbackFetch = true
                XCTAssertEqual(limit, 1)
                XCTAssertEqual(start.timeIntervalSince(base), -24 * 60 * 60, accuracy: 0.01)
                XCTAssertEqual(end.timeIntervalSince(base), 0, accuracy: 0.01)
                let firstFrameInWindow = start.addingTimeInterval(75)
                anchoredTimestamp = firstFrameInWindow
                return [self.makeFrameWithVideoInfo(id: 7321, timestamp: firstFrameInWindow, processingStatus: 4)]

            case "searchForDate":
                guard let anchoredTimestamp else {
                    XCTFail("Expected lookback anchor to resolve before window fetch")
                    return []
                }
                XCTAssertEqual(start.timeIntervalSince(anchoredTimestamp), -600, accuracy: 0.01)
                XCTAssertEqual(end.timeIntervalSince(anchoredTimestamp), 600, accuracy: 0.01)
                return [self.makeFrameWithVideoInfo(id: 7321, timestamp: anchoredTimestamp, processingStatus: 4)]

            case "loadNewerFrames.reason=searchForDate",
                 "loadOlderFrames.reason=searchForDate":
                return []

            default:
                XCTFail("Unexpected fetch reason: \(reason)")
                return []
            }
        }

        await viewModel.searchForDate("1 day before")

        XCTAssertTrue(sawLookbackFetch)
        XCTAssertEqual(viewModel.currentTimelineFrame?.frame.id.value, 7321)
        XCTAssertEqual(viewModel.currentTimelineFrame?.frame.timestamp, anchoredTimestamp)
    }

    func testMonthBeforeUsesFirstFrameInPlayheadLookbackWindow() async {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        let calendar = Calendar.current
        let base = makeDate(year: 2026, month: 5, day: 15, hour: 9, minute: 48)
        guard let expectedStart = calendar.date(byAdding: .month, value: -1, to: base) else {
            XCTFail("Failed to construct expected one-month lookback")
            return
        }
        viewModel.frames = [makeTimelineFrame(id: 7330, timestamp: base, processingStatus: 4)]
        viewModel.currentIndex = 0

        var anchoredTimestamp: Date?
        var sawLookbackFetch = false

        viewModel.test_windowFetchHooks.getFramesWithVideoInfo = { start, end, limit, _, reason in
            switch reason {
            case "searchForDate.anchor.firstFrameInRelativeLookback":
                sawLookbackFetch = true
                XCTAssertEqual(limit, 1)
                XCTAssertEqual(start.timeIntervalSince(expectedStart), 0, accuracy: 0.01)
                XCTAssertEqual(end.timeIntervalSince(base), 0, accuracy: 0.01)
                let firstFrameInWindow = start.addingTimeInterval(90)
                anchoredTimestamp = firstFrameInWindow
                return [self.makeFrameWithVideoInfo(id: 7331, timestamp: firstFrameInWindow, processingStatus: 4)]

            case "searchForDate":
                guard let anchoredTimestamp else {
                    XCTFail("Expected lookback anchor to resolve before window fetch")
                    return []
                }
                XCTAssertEqual(start.timeIntervalSince(anchoredTimestamp), -600, accuracy: 0.01)
                XCTAssertEqual(end.timeIntervalSince(anchoredTimestamp), 600, accuracy: 0.01)
                return [self.makeFrameWithVideoInfo(id: 7331, timestamp: anchoredTimestamp, processingStatus: 4)]

            case "loadNewerFrames.reason=searchForDate",
                 "loadOlderFrames.reason=searchForDate":
                return []

            default:
                XCTFail("Unexpected fetch reason: \(reason)")
                return []
            }
        }

        await viewModel.searchForDate("1 month before")

        XCTAssertTrue(sawLookbackFetch)
        XCTAssertEqual(viewModel.currentTimelineFrame?.frame.id.value, 7331)
        XCTAssertEqual(viewModel.currentTimelineFrame?.frame.timestamp, anchoredTimestamp)
    }

    func testMinuteBeforeRemainsExactWithoutPlayheadLookbackAnchoring() async {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        let base = makeDate(year: 2026, month: 2, day: 23, hour: 9, minute: 48)
        let expectedTarget = base.addingTimeInterval(-60 * 60)
        viewModel.frames = [makeTimelineFrame(id: 7340, timestamp: base, processingStatus: 4)]
        viewModel.currentIndex = 0

        var sawLookbackFetch = false
        var sawWindowFetch = false

        viewModel.test_windowFetchHooks.getFramesWithVideoInfo = { start, end, _, _, reason in
            switch reason {
            case "searchForDate.anchor.firstFrameInRelativeLookback":
                sawLookbackFetch = true
                XCTFail("60 min before should not use playhead lookback anchoring")
                return []

            case "searchForDate":
                sawWindowFetch = true
                XCTAssertEqual(start.timeIntervalSince(expectedTarget), -600, accuracy: 0.01)
                XCTAssertEqual(end.timeIntervalSince(expectedTarget), 600, accuracy: 0.01)
                return [self.makeFrameWithVideoInfo(id: 7341, timestamp: expectedTarget, processingStatus: 4)]

            case "loadNewerFrames.reason=searchForDate",
                 "loadOlderFrames.reason=searchForDate":
                return []

            default:
                XCTFail("Unexpected fetch reason: \(reason)")
                return []
            }
        }

        await viewModel.searchForDate("60 min before")

        XCTAssertFalse(sawLookbackFetch)
        XCTAssertTrue(sawWindowFetch)
        XCTAssertEqual(viewModel.currentTimelineFrame?.frame.id.value, 7341)
        XCTAssertEqual(viewModel.currentTimelineFrame?.frame.timestamp, expectedTarget)
    }

    func testThatDayTimeUsesPlayheadCalendarDate() async {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        let base = makeDate(year: 2026, month: 3, day: 25, hour: 14, minute: 37)
        let expectedTarget = makeDate(year: 2026, month: 3, day: 25, hour: 18, minute: 0)
        viewModel.frames = [makeTimelineFrame(id: 7350, timestamp: base, processingStatus: 4)]
        viewModel.currentIndex = 0

        var sawWindowFetch = false

        viewModel.test_windowFetchHooks.getFramesWithVideoInfo = { start, end, _, _, reason in
            switch reason {
            case "searchForDate":
                sawWindowFetch = true
                XCTAssertEqual(start.timeIntervalSince(expectedTarget), -600, accuracy: 0.01)
                XCTAssertEqual(end.timeIntervalSince(expectedTarget), 600, accuracy: 0.01)
                return [self.makeFrameWithVideoInfo(id: 7351, timestamp: expectedTarget, processingStatus: 4)]

            case "loadNewerFrames.reason=searchForDate",
                 "loadOlderFrames.reason=searchForDate":
                return []

            default:
                XCTFail("Unexpected fetch reason: \(reason)")
                return []
            }
        }

        await viewModel.searchForDate("6pm that day")

        XCTAssertTrue(sawWindowFetch)
        XCTAssertEqual(viewModel.currentTimelineFrame?.frame.id.value, 7351)
        XCTAssertEqual(viewModel.currentTimelineFrame?.frame.timestamp, expectedTarget)
    }

    func testSameDayUsesPlayheadDayBucket() async {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        let calendar = Calendar.current
        let base = makeDate(year: 2026, month: 3, day: 25, hour: 14, minute: 37)
        guard let dayInterval = calendar.dateInterval(of: .day, for: base) else {
            XCTFail("Failed to construct expected playhead day interval")
            return
        }
        viewModel.frames = [makeTimelineFrame(id: 7360, timestamp: base, processingStatus: 4)]
        viewModel.currentIndex = 0

        var anchoredTimestamp: Date?
        var sawDayAnchorFetch = false
        var sawWindowFetch = false

        viewModel.test_windowFetchHooks.getFramesWithVideoInfo = { start, end, limit, _, reason in
            switch reason {
            case "searchForDate.anchor.firstFrameInDay":
                sawDayAnchorFetch = true
                XCTAssertEqual(limit, 1)
                XCTAssertEqual(start.timeIntervalSince(dayInterval.start), 0, accuracy: 0.01)
                XCTAssertEqual(end.timeIntervalSince(dayInterval.end), -0.001, accuracy: 0.01)
                let firstFrameInDay = dayInterval.start.addingTimeInterval(215)
                anchoredTimestamp = firstFrameInDay
                return [self.makeFrameWithVideoInfo(id: 7361, timestamp: firstFrameInDay, processingStatus: 4)]

            case "searchForDate":
                sawWindowFetch = true
                guard let anchoredTimestamp else {
                    XCTFail("Expected same-day anchor to resolve before window fetch")
                    return []
                }
                XCTAssertEqual(start.timeIntervalSince(anchoredTimestamp), -600, accuracy: 0.01)
                XCTAssertEqual(end.timeIntervalSince(anchoredTimestamp), 600, accuracy: 0.01)
                return [self.makeFrameWithVideoInfo(id: 7361, timestamp: anchoredTimestamp, processingStatus: 4)]

            case "loadNewerFrames.reason=searchForDate",
                 "loadOlderFrames.reason=searchForDate":
                return []

            default:
                XCTFail("Unexpected fetch reason: \(reason)")
                return []
            }
        }

        await viewModel.searchForDate("same day")

        XCTAssertTrue(sawDayAnchorFetch)
        XCTAssertTrue(sawWindowFetch)
        XCTAssertEqual(viewModel.currentTimelineFrame?.frame.id.value, 7361)
        XCTAssertEqual(viewModel.currentTimelineFrame?.frame.timestamp, anchoredTimestamp)
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

    private func makeFrameWithVideoInfo(id: Int64, timestamp: Date, processingStatus: Int) -> FrameWithVideoInfo {
        let frame = FrameReference(
            id: FrameID(value: id),
            timestamp: timestamp,
            segmentID: AppSegmentID(value: id),
            frameIndexInSegment: 0,
            metadata: FrameMetadata(
                appBundleID: "test.app",
                appName: "Test App",
                displayID: 1
            )
        )

        return FrameWithVideoInfo(frame: frame, videoInfo: nil, processingStatus: processingStatus)
    }

    private func makeTimelineFrame(id: Int64, timestamp: Date, processingStatus: Int) -> TimelineFrame {
        TimelineFrame(frameWithVideoInfo: makeFrameWithVideoInfo(id: id, timestamp: timestamp, processingStatus: processingStatus))
    }
}
