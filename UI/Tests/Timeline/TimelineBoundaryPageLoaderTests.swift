import XCTest
import Shared
@testable import Retrace

final class TimelineBoundaryPageLoaderTests: XCTestCase {
    func testLoadOlderPageSkipsWhenBoundedWindowDoesNotOverlapFilters() async throws {
        let oldest = Date(timeIntervalSince1970: 1_700_020_000)
        let filters = FilterCriteria(
            startDate: oldest.addingTimeInterval(60),
            endDate: oldest.addingTimeInterval(600)
        )
        let recorder = OlderFetchRecorder(responses: [])

        let outcome = try await TimelineBoundaryPageLoader.loadOlderPage(
            oldestTimestamp: oldest,
            requestFilters: filters,
            reason: "test.skip",
            loadWindowSpanSeconds: 3_600,
            loadBatchSize: 35,
            olderSparseRetryThreshold: 35,
            nearestFallbackBatchSize: 35,
            fetchFramesBefore: recorder.fetch
        )

        switch outcome {
        case let .skippedNoOverlap(rangeStart, rangeEnd):
            XCTAssertEqual(rangeEnd, oldest.addingTimeInterval(-0.001))
            XCTAssertEqual(rangeStart, rangeEnd.addingTimeInterval(-3_600))
        case .loaded:
            XCTFail("Expected no-overlap skip")
        }

        let calls = await recorder.calls()
        XCTAssertEqual(calls.count, 0)
    }

    func testLoadOlderPageMetadataStrategyClampsEndDateWithoutFallback() async throws {
        let oldest = Date(timeIntervalSince1970: 1_700_020_000)
        let explicitEnd = oldest.addingTimeInterval(300)
        let filters = FilterCriteria(
            windowNameFilter: "Inbox",
            startDate: oldest.addingTimeInterval(-7_200),
            endDate: explicitEnd
        )
        let recorder = OlderFetchRecorder(
            responses: [[makeFrameWithVideoInfo(id: 1, timestamp: oldest.addingTimeInterval(-5))]]
        )

        let outcome = try await TimelineBoundaryPageLoader.loadOlderPage(
            oldestTimestamp: oldest,
            requestFilters: filters,
            reason: "test.metadata",
            loadWindowSpanSeconds: 3_600,
            loadBatchSize: 35,
            olderSparseRetryThreshold: 35,
            nearestFallbackBatchSize: 35,
            fetchFramesBefore: recorder.fetch
        )

        guard case let .loaded(result) = outcome else {
            return XCTFail("Expected loaded result")
        }

        XCTAssertEqual(result.framesDescending.map(\.frame.id.value), [1])

        let calls = await recorder.calls()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].endDate, oldest.addingTimeInterval(-0.001))
        XCTAssertEqual(calls[0].startDate, oldest.addingTimeInterval(-7_200))
        XCTAssertEqual(calls[0].limit, 35)
    }

    func testLoadOlderPageReplacesSparseBoundedResultWithNearestFallback() async throws {
        let oldest = Date(timeIntervalSince1970: 1_700_020_000)
        let filters = FilterCriteria()
        let recorder = OlderFetchRecorder(
            responses: [
                [makeFrameWithVideoInfo(id: 3, timestamp: oldest.addingTimeInterval(-3))],
                [
                    makeFrameWithVideoInfo(id: 5, timestamp: oldest.addingTimeInterval(-5)),
                    makeFrameWithVideoInfo(id: 4, timestamp: oldest.addingTimeInterval(-4)),
                    makeFrameWithVideoInfo(id: 3, timestamp: oldest.addingTimeInterval(-3))
                ]
            ]
        )

        let outcome = try await TimelineBoundaryPageLoader.loadOlderPage(
            oldestTimestamp: oldest,
            requestFilters: filters,
            reason: "test.fallback",
            loadWindowSpanSeconds: 3_600,
            loadBatchSize: 35,
            olderSparseRetryThreshold: 2,
            nearestFallbackBatchSize: 50,
            fetchFramesBefore: recorder.fetch
        )

        guard case let .loaded(result) = outcome else {
            return XCTFail("Expected loaded result")
        }

        XCTAssertEqual(result.framesDescending.map(\.frame.id.value), [5, 4, 3])

        let calls = await recorder.calls()
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0].limit, 35)
        XCTAssertEqual(calls[0].startDate, oldest.addingTimeInterval(-3_600.001))
        XCTAssertEqual(calls[0].endDate, oldest.addingTimeInterval(-0.001))
        XCTAssertNil(calls[1].startDate)
        XCTAssertNil(calls[1].endDate)
        XCTAssertEqual(calls[1].limit, 50)
        XCTAssertTrue(calls[1].reason.contains(".nearestFallback"))
    }

    func testLoadNewerPageKeepsBoundedResultWhenFallbackDoesNotImproveCount() async throws {
        let newest = Date(timeIntervalSince1970: 1_700_020_000)
        let rangeRecorder = NewerRangeFetchRecorder(
            responses: [[
                makeFrameWithVideoInfo(id: 2, timestamp: newest.addingTimeInterval(1)),
                makeFrameWithVideoInfo(id: 3, timestamp: newest.addingTimeInterval(2))
            ]]
        )
        let afterRecorder = NewerAfterFetchRecorder(
            responses: [[makeFrameWithVideoInfo(id: 2, timestamp: newest.addingTimeInterval(1))]]
        )

        let result = try await TimelineBoundaryPageLoader.loadNewerPage(
            newestTimestamp: newest,
            requestFilters: FilterCriteria(),
            reason: "test.keep",
            loadWindowSpanSeconds: 3_600,
            loadBatchSize: 35,
            newerSparseRetryThreshold: 3,
            nearestFallbackBatchSize: 50,
            fetchFramesInRange: rangeRecorder.fetch,
            fetchFramesAfter: afterRecorder.fetch
        )

        XCTAssertEqual(result.frames.map(\.frame.id.value), [2, 3])

        let rangeCalls = await rangeRecorder.calls()
        XCTAssertEqual(rangeCalls.count, 1)
        XCTAssertEqual(rangeCalls[0].from, newest.addingTimeInterval(0.001))
        XCTAssertEqual(rangeCalls[0].to, newest.addingTimeInterval(3_600.001))
        XCTAssertEqual(rangeCalls[0].limit, 35)

        let afterCalls = await afterRecorder.calls()
        XCTAssertEqual(afterCalls.count, 1)
        XCTAssertEqual(afterCalls[0].timestamp, newest)
        XCTAssertEqual(afterCalls[0].limit, 50)
    }

    private func makeFrameWithVideoInfo(id: Int64, timestamp: Date) -> FrameWithVideoInfo {
        FrameWithVideoInfo(
            frame: FrameReference(
                id: FrameID(value: id),
                timestamp: timestamp,
                segmentID: AppSegmentID(value: id),
                frameIndexInSegment: Int(id),
                metadata: FrameMetadata(
                    appBundleID: "com.apple.Safari",
                    appName: "Safari",
                    displayID: 1
                )
            ),
            videoInfo: nil,
            processingStatus: 2
        )
    }
}

private struct OlderFetchCall: Sendable {
    let limit: Int
    let startDate: Date?
    let endDate: Date?
    let reason: String
}

private actor OlderFetchRecorder {
    private let responses: [[FrameWithVideoInfo]]
    private var responseIndex = 0
    private var recordedCalls: [OlderFetchCall] = []

    init(responses: [[FrameWithVideoInfo]]) {
        self.responses = responses
    }

    func fetch(
        _ timestamp: Date,
        _ limit: Int,
        _ filters: FilterCriteria,
        _ reason: String
    ) async throws -> [FrameWithVideoInfo] {
        recordedCalls.append(
            OlderFetchCall(
                limit: limit,
                startDate: filters.startDate,
                endDate: filters.endDate,
                reason: reason
            )
        )

        guard responseIndex < responses.count else {
            return []
        }

        defer { responseIndex += 1 }
        return responses[responseIndex]
    }

    func calls() -> [OlderFetchCall] {
        recordedCalls
    }
}

private struct NewerRangeFetchCall: Sendable {
    let from: Date
    let to: Date
    let limit: Int
}

private actor NewerRangeFetchRecorder {
    private let responses: [[FrameWithVideoInfo]]
    private var responseIndex = 0
    private var recordedCalls: [NewerRangeFetchCall] = []

    init(responses: [[FrameWithVideoInfo]]) {
        self.responses = responses
    }

    func fetch(
        _ from: Date,
        _ to: Date,
        _ limit: Int,
        _ filters: FilterCriteria,
        _ reason: String
    ) async throws -> [FrameWithVideoInfo] {
        _ = filters
        _ = reason
        recordedCalls.append(NewerRangeFetchCall(from: from, to: to, limit: limit))

        guard responseIndex < responses.count else {
            return []
        }

        defer { responseIndex += 1 }
        return responses[responseIndex]
    }

    func calls() -> [NewerRangeFetchCall] {
        recordedCalls
    }
}

private struct NewerAfterFetchCall: Sendable {
    let timestamp: Date
    let limit: Int
}

private actor NewerAfterFetchRecorder {
    private let responses: [[FrameWithVideoInfo]]
    private var responseIndex = 0
    private var recordedCalls: [NewerAfterFetchCall] = []

    init(responses: [[FrameWithVideoInfo]]) {
        self.responses = responses
    }

    func fetch(
        _ timestamp: Date,
        _ limit: Int,
        _ filters: FilterCriteria,
        _ reason: String
    ) async throws -> [FrameWithVideoInfo] {
        _ = filters
        _ = reason
        recordedCalls.append(NewerAfterFetchCall(timestamp: timestamp, limit: limit))

        guard responseIndex < responses.count else {
            return []
        }

        defer { responseIndex += 1 }
        return responses[responseIndex]
    }

    func calls() -> [NewerAfterFetchCall] {
        recordedCalls
    }
}
