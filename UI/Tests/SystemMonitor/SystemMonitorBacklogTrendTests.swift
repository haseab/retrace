import XCTest
import AppKit
import Combine
import Shared
import App
@testable import Retrace

@MainActor
final class SystemMonitorBacklogTrendTests: XCTestCase {
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
