import XCTest
@testable import Retrace

final class DashboardRevealSchedulerTests: XCTestCase {
    @MainActor
    func testOrdinaryActivationRevealsDashboardAfterURLDeliveryWindow() async throws {
        let gate = SharedAsyncTestGate()
        let scheduler = DashboardRevealScheduler(delay: { await gate.enterAndWait() })
        var reveals = 0
        let task = try XCTUnwrap(scheduler.schedule { reveals += 1 })
        await gate.waitUntilEntered()
        XCTAssertEqual(reveals, 0)
        await gate.release()
        await task.value
        XCTAssertEqual(reveals, 1)
    }

    @MainActor
    func testDeepLinkCancelsActivationThatArrivedBeforeURL() async throws {
        let gate = SharedAsyncTestGate()
        let scheduler = DashboardRevealScheduler(delay: { await gate.enterAndWait() })
        var reveals = 0
        let task = try XCTUnwrap(scheduler.schedule { reveals += 1 })
        await gate.waitUntilEntered()
        scheduler.beginDeeplinkPresentation()
        // Even a delay that ignores cancellation must not reveal the dashboard.
        await gate.release()
        await task.value
        XCTAssertEqual(reveals, 0)
    }

    @MainActor
    func testActivationAndReopenDuringDeeplinkPresentationAreIgnored() async {
        let scheduler = DashboardRevealScheduler(delay: {})
        var reveals = 0
        scheduler.beginDeeplinkPresentation()
        XCTAssertNil(scheduler.schedule { reveals += 1 })
        XCTAssertNil(scheduler.schedule { reveals += 1 })
        XCTAssertEqual(reveals, 0)
    }

    @MainActor
    func testLaterDockReopenWorksAfterTimelinePresentationCompletes() async throws {
        let scheduler = DashboardRevealScheduler(delay: {})
        var reveals = 0
        scheduler.beginDeeplinkPresentation()
        scheduler.finishDeeplinkPresentation()
        let task = try XCTUnwrap(scheduler.schedule { reveals += 1 })
        await task.value
        XCTAssertEqual(reveals, 1)
    }

    @MainActor
    func testCoalescesActivationAndReopenIntoOneReveal() async throws {
        let firstGate = SharedAsyncTestGate()
        let secondGate = SharedAsyncTestGate()
        var delayCalls = 0
        let scheduler = DashboardRevealScheduler(delay: {
            delayCalls += 1
            await (delayCalls == 1 ? firstGate : secondGate).enterAndWait()
        })
        var sources: [String] = []
        let first = try XCTUnwrap(scheduler.schedule { sources.append("activation") })
        await firstGate.waitUntilEntered()
        let second = try XCTUnwrap(scheduler.schedule { sources.append("reopen") })
        await secondGate.waitUntilEntered()
        await firstGate.release()
        await secondGate.release()
        await first.value
        await second.value
        XCTAssertEqual(sources, ["reopen"])
    }

    @MainActor
    func testExplicitDashboardRequestCanCancelAutomaticReveal() async throws {
        let gate = SharedAsyncTestGate()
        let scheduler = DashboardRevealScheduler(delay: { await gate.enterAndWait() })
        var reveals = 0
        let task = try XCTUnwrap(scheduler.schedule { reveals += 1 })
        await gate.waitUntilEntered()
        scheduler.cancelPendingReveal()
        await gate.release()
        await task.value
        XCTAssertEqual(reveals, 0)
    }
}
