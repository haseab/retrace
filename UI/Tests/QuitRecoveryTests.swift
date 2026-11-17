import Foundation
import XCTest
@testable import Retrace

final class QuitRecoveryTests: XCTestCase {
    func testConfirmedQuitCancelsRecoveryAlreadyWaitingForDiagnostics() async {
        let state = WatchdogRecoveryState()
        XCTAssertTrue(state.isRecoveryAllowed)
        let diagnosticsStarted = expectation(description: "diagnostics started")
        let finishDiagnostics = DispatchSemaphore(value: 0)
        let recovered = Task.detached {
            guard state.isRecoveryAllowed else { return false }
            diagnosticsStarted.fulfill()
            finishDiagnostics.wait()
            return state.isRecoveryAllowed
        }
        await fulfillment(of: [diagnosticsStarted], timeout: 2)
        state.beginExpectedExit()
        finishDiagnostics.signal()
        let shouldRecover = await recovered.value
        XCTAssertFalse(shouldRecover)
        XCTAssertFalse(state.isRecoveryAllowed)
    }
}
