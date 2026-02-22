import XCTest
@testable import Capture

final class BrowserURLAppleScriptCoordinatorTests: XCTestCase {

    actor RunnerProbe {
        private var callCount = 0
        private var observedTimeouts: [TimeInterval] = []
        private var observedBootstrapFlags: [Bool] = []

        private var shouldBlock = false
        private var isReleased = false
        private var blockContinuation: CheckedContinuation<Void, Never>?

        func enableBlocking() {
            shouldBlock = true
            isReleased = false
            blockContinuation = nil
        }

        func releaseBlocking() {
            isReleased = true
            blockContinuation?.resume()
            blockContinuation = nil
        }

        func recordCall(timeoutSeconds: TimeInterval, isBootstrapTimeout: Bool) {
            callCount += 1
            observedTimeouts.append(timeoutSeconds)
            observedBootstrapFlags.append(isBootstrapTimeout)
        }

        func waitIfBlockingEnabled() async {
            guard shouldBlock, !isReleased else { return }
            await withCheckedContinuation { continuation in
                blockContinuation = continuation
            }
        }

        func waitForCallCount(atLeast minimum: Int) async {
            while callCount < minimum {
                try? await Task.sleep(for: .milliseconds(5), clock: .continuous)
            }
        }

        func snapshot() -> (callCount: Int, timeouts: [TimeInterval], bootstrapFlags: [Bool]) {
            return (callCount, observedTimeouts, observedBootstrapFlags)
        }
    }

    func testTimeoutEntersCooldownAndSkipsImmediateRelaunch() async {
        let probe = RunnerProbe()
        let coordinator = BrowserURLAppleScriptCoordinator(
            timeoutBaseBackoffSeconds: 5.0,
            runner: { _, _, _, timeoutSeconds, isBootstrapTimeout in
                await probe.recordCall(timeoutSeconds: timeoutSeconds, isBootstrapTimeout: isBootstrapTimeout)
                return BrowserURLAppleScriptResult(didTimeOut: true)
            }
        )

        let first = await coordinator.execute(
            source: "tell application \"Arc\" to return \"\"",
            browserBundleID: "company.thebrowser.Browser",
            pid: 123
        )
        XCTAssertTrue(first.didTimeOut)

        let second = await coordinator.execute(
            source: "tell application \"Arc\" to return \"\"",
            browserBundleID: "company.thebrowser.Browser",
            pid: 123
        )
        XCTAssertTrue(second.skippedByCooldown)

        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.callCount, 1)
    }

    func testPermissionDeniedEntersCooldownAndSkipsImmediateRelaunch() async {
        let probe = RunnerProbe()
        let coordinator = BrowserURLAppleScriptCoordinator(
            deniedBaseBackoffSeconds: 20.0,
            runner: { _, _, _, timeoutSeconds, isBootstrapTimeout in
                await probe.recordCall(timeoutSeconds: timeoutSeconds, isBootstrapTimeout: isBootstrapTimeout)
                return BrowserURLAppleScriptResult(
                    permissionDenied: true,
                    completedWithoutTimeout: true
                )
            }
        )

        let first = await coordinator.execute(
            source: "tell application \"Firefox\" to return \"\"",
            browserBundleID: "org.mozilla.firefox",
            pid: 321
        )
        XCTAssertTrue(first.permissionDenied)

        let second = await coordinator.execute(
            source: "tell application \"Firefox\" to return \"\"",
            browserBundleID: "org.mozilla.firefox",
            pid: 321
        )
        XCTAssertTrue(second.skippedByCooldown)

        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.callCount, 1)
    }

    func testBootstrapTimeoutTransitionsToNormalAfterNonTimeoutCompletion() async {
        let probe = RunnerProbe()
        let coordinator = BrowserURLAppleScriptCoordinator(
            bootstrapTimeoutSeconds: 11.0,
            normalTimeoutSeconds: 3.0,
            runner: { _, _, _, timeoutSeconds, isBootstrapTimeout in
                await probe.recordCall(timeoutSeconds: timeoutSeconds, isBootstrapTimeout: isBootstrapTimeout)
                return BrowserURLAppleScriptResult(completedWithoutTimeout: true)
            }
        )

        _ = await coordinator.execute(
            source: "tell application \"Arc\" to return \"\"",
            browserBundleID: "company.thebrowser.Browser",
            pid: 555
        )
        _ = await coordinator.execute(
            source: "tell application \"Arc\" to return \"\"",
            browserBundleID: "company.thebrowser.Browser",
            pid: 555
        )

        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.callCount, 2)
        XCTAssertEqual(snapshot.bootstrapFlags, [true, false])
        XCTAssertEqual(snapshot.timeouts.count, 2)
        XCTAssertEqual(snapshot.timeouts[0], 11.0, accuracy: 0.0001)
        XCTAssertEqual(snapshot.timeouts[1], 3.0, accuracy: 0.0001)
    }

    func testInFlightCallsJoinSingleRunnerTask() async {
        let probe = RunnerProbe()
        await probe.enableBlocking()

        let coordinator = BrowserURLAppleScriptCoordinator(
            runner: { _, _, _, timeoutSeconds, isBootstrapTimeout in
                await probe.recordCall(timeoutSeconds: timeoutSeconds, isBootstrapTimeout: isBootstrapTimeout)
                await probe.waitIfBlockingEnabled()
                return BrowserURLAppleScriptResult(
                    output: "https://example.com",
                    completedWithoutTimeout: true
                )
            }
        )

        async let first = coordinator.execute(
            source: "tell application \"Arc\" to return \"https://example.com\"",
            browserBundleID: "company.thebrowser.Browser",
            pid: 777
        )

        await probe.waitForCallCount(atLeast: 1)

        async let second = coordinator.execute(
            source: "tell application \"Arc\" to return \"https://example.com\"",
            browserBundleID: "company.thebrowser.Browser",
            pid: 777
        )

        await probe.releaseBlocking()

        let firstResult = await first
        let secondResult = await second

        XCTAssertEqual(firstResult.output, "https://example.com")
        XCTAssertEqual(secondResult.output, "https://example.com")

        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.callCount, 1)
    }
}
