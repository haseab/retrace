import XCTest
import AppKit
import Combine
import Shared
import App
@testable import Processing
@testable import Retrace

@MainActor
final class SystemMonitorBacklogTrendTests: XCTestCase {
    func testStartMonitoringPollsQueueStatsOnceBeforeFirstSleep() async {
        let firstPoll = expectation(description: "first queue stats poll")
        let pollCounter = PollCounter()
        let dataProvider = StubSystemMonitorDataProvider(
            queueStatisticsHandler: {
                await pollCounter.increment()
                firstPoll.fulfill()
                return nil
            }
        )

        let viewModel = SystemMonitorViewModel(dataProvider: dataProvider)

        viewModel.startMonitoring()
        await fulfillment(of: [firstPoll], timeout: 0.2)
        try? await Task.sleep(for: .milliseconds(50))

        let pollCount = await pollCounter.value()
        XCTAssertEqual(pollCount, 1)

        viewModel.stopMonitoring()
    }

    func testStartMonitoringLoadsHistoricalDataInBackground() async {
        let dataProvider = StubSystemMonitorDataProvider(
            processedHistoryHandler: { _ in
                try? await Task.sleep(for: .milliseconds(250))
                return [0: 7]
            },
            encodedHistoryHandler: { _ in
                try? await Task.sleep(for: .milliseconds(250))
                return [0: 5]
            },
            rewrittenHistoryHandler: { _ in
                try? await Task.sleep(for: .milliseconds(250))
                return [0: 3]
            }
        )
        let viewModel = SystemMonitorViewModel(dataProvider: dataProvider)

        let startedAt = CFAbsoluteTimeGetCurrent()
        viewModel.startMonitoring()
        let elapsedMs = (CFAbsoluteTimeGetCurrent() - startedAt) * 1000

        XCTAssertLessThan(elapsedMs, 100)
        XCTAssertEqual(viewModel.ocrProcessingHistory.count, 30)
        XCTAssertEqual(viewModel.encodingHistory.count, 15)
        XCTAssertEqual(viewModel.rewriteHistory.count, 15)
        XCTAssertEqual(viewModel.ocrProcessingHistory.last?.count, 0)
        XCTAssertEqual(viewModel.encodingHistory.last?.count, 0)
        XCTAssertEqual(viewModel.rewriteHistory.last?.count, 0)

        try? await Task.sleep(for: .milliseconds(900))

        XCTAssertEqual(viewModel.ocrProcessingHistory.count, 30)
        XCTAssertEqual(viewModel.encodingHistory.count, 15)
        XCTAssertEqual(viewModel.rewriteHistory.count, 15)
        XCTAssertEqual(viewModel.ocrProcessingHistory.last?.count, 7)
        XCTAssertEqual(viewModel.encodingHistory.last?.count, 5)
        XCTAssertEqual(viewModel.rewriteHistory.last?.count, 3)

        viewModel.stopMonitoring()
    }

    func testDelayedHistoricalLoadDoesNotOverwriteObservedCurrentMinuteCompletions() async {
        let pollCounter = PollCounter()
        let dataProvider = StubSystemMonitorDataProvider(
            queueStatisticsHandler: {
                let pollNumber = await pollCounter.incrementAndGet()
                let totalProcessed = pollNumber >= 2 ? 12 : 10
                return QueueStatistics(
                    ocrQueueDepth: 0,
                    ocrPendingCount: 0,
                    ocrProcessingCount: 0,
                    rewriteQueueDepth: 0,
                    rewritePendingCount: 0,
                    rewriteProcessingCount: 0,
                    totalProcessed: totalProcessed,
                    totalRewritten: 0,
                    totalFailed: 0,
                    workerCount: 0
                )
            },
            processedHistoryHandler: { _ in
                try? await Task.sleep(for: .milliseconds(1_200))
                return [0: 1]
            }
        )
        let viewModel = SystemMonitorViewModel(dataProvider: dataProvider)

        viewModel.startMonitoring()
        try? await Task.sleep(for: .milliseconds(1_450))

        XCTAssertEqual(viewModel.ocrProcessingHistory.last?.count, 2)

        viewModel.stopMonitoring()
    }

    func testQueueDepthChangePerMinutePositiveWhenBacklogGrows() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let samples: [(timestamp: Date, depth: Int)] = [
            (timestamp: t0, depth: 2),
            (timestamp: t0.addingTimeInterval(15), depth: 6),
            (timestamp: t0.addingTimeInterval(30), depth: 10)
        ]

        let change = SystemMonitorViewModel.queueDepthChangePerMinute(samples: samples, minimumObservationWindow: 12)

        XCTAssertNotNil(change)
        XCTAssertEqual(change ?? 0, 16, accuracy: 0.001)
    }

    func testQueueDepthChangePerMinuteNegativeWhenQueueDrains() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let samples: [(timestamp: Date, depth: Int)] = [
            (timestamp: t0, depth: 12),
            (timestamp: t0.addingTimeInterval(15), depth: 8),
            (timestamp: t0.addingTimeInterval(30), depth: 4)
        ]

        let change = SystemMonitorViewModel.queueDepthChangePerMinute(samples: samples, minimumObservationWindow: 12)

        XCTAssertNotNil(change)
        XCTAssertEqual(change ?? 0, -16, accuracy: 0.001)
    }

    func testQueueDepthChangePerMinuteReturnsNilWithoutEnoughTimeWindow() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let samples: [(timestamp: Date, depth: Int)] = [
            (timestamp: t0, depth: 2),
            (timestamp: t0.addingTimeInterval(8), depth: 4)
        ]

        let change = SystemMonitorViewModel.queueDepthChangePerMinute(samples: samples, minimumObservationWindow: 12)

        XCTAssertNil(change)
    }
}

private actor PollCounter {
    private var count = 0

    func increment() {
        count += 1
    }

    func incrementAndGet() -> Int {
        count += 1
        return count
    }

    func value() -> Int {
        count
    }
}

private final class StubSystemMonitorDataProvider: SystemMonitorDataProviding {
    private let queueStatisticsHandler: () async -> QueueStatistics?
    private let processedHistoryHandler: (Int) async throws -> [Int: Int]
    private let encodedHistoryHandler: (Int) async throws -> [Int: Int]
    private let rewrittenHistoryHandler: (Int) async throws -> [Int: Int]
    private let encodingStatisticsHandler: () async -> (queueDepth: Int, pendingCount: Int)?
    private let currentPowerStateHandler: () -> (source: PowerStateMonitor.PowerSource, isPaused: Bool)
    private let recordingActiveHandler: () -> Bool

    init(
        queueStatisticsHandler: @escaping () async -> QueueStatistics? = { nil },
        processedHistoryHandler: @escaping (Int) async throws -> [Int: Int] = { _ in [:] },
        encodedHistoryHandler: @escaping (Int) async throws -> [Int: Int] = { _ in [:] },
        rewrittenHistoryHandler: @escaping (Int) async throws -> [Int: Int] = { _ in [:] },
        encodingStatisticsHandler: @escaping () async -> (queueDepth: Int, pendingCount: Int)? = { nil },
        currentPowerStateHandler: @escaping () -> (source: PowerStateMonitor.PowerSource, isPaused: Bool) = { (.ac, false) },
        recordingActiveHandler: @escaping () -> Bool = { false }
    ) {
        self.queueStatisticsHandler = queueStatisticsHandler
        self.processedHistoryHandler = processedHistoryHandler
        self.encodedHistoryHandler = encodedHistoryHandler
        self.rewrittenHistoryHandler = rewrittenHistoryHandler
        self.encodingStatisticsHandler = encodingStatisticsHandler
        self.currentPowerStateHandler = currentPowerStateHandler
        self.recordingActiveHandler = recordingActiveHandler
    }

    func getQueueStatistics() async -> QueueStatistics? {
        await queueStatisticsHandler()
    }

    func getFramesProcessedPerMinute(lastMinutes: Int) async throws -> [Int: Int] {
        try await processedHistoryHandler(lastMinutes)
    }

    func getFramesEncodedPerMinute(lastMinutes: Int) async throws -> [Int: Int] {
        try await encodedHistoryHandler(lastMinutes)
    }

    func getFramesRewrittenPerMinute(lastMinutes: Int) async throws -> [Int: Int] {
        try await rewrittenHistoryHandler(lastMinutes)
    }

    func getEncodingStatistics() async -> (queueDepth: Int, pendingCount: Int)? {
        await encodingStatisticsHandler()
    }

    func getCurrentPowerState() -> (source: PowerStateMonitor.PowerSource, isPaused: Bool) {
        currentPowerStateHandler()
    }

    var isSystemMonitorRecordingActive: Bool {
        recordingActiveHandler()
    }
}
