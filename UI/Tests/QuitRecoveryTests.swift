import Foundation
import XCTest
@testable import Retrace

final class QuitRecoveryTests: XCTestCase {
    func testConfirmedQuitCancelsRecoveryAndRemovesDiagnosticSample() async throws {
        let state = WatchdogRecoveryState()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sample = directory.appendingPathComponent("sample.txt")
        let restart = directory.appendingPathComponent("restart.txt")
        try Data("diagnostic sample".utf8).write(to: sample)
        let diagnosticsStarted = expectation(description: "diagnostics started")
        let finishDiagnostics = QuitRecoveryTestGate()
        let recovery = Task.detached {
            await state.recoverAfterDiagnostics {
                diagnosticsStarted.fulfill()
                await finishDiagnostics.wait()
                return sample.path
            } recover: { _ in
                try? Data().write(to: restart)
            }
        }
        await fulfillment(of: [diagnosticsStarted], timeout: 2)
        state.beginExpectedExit()
        await finishDiagnostics.open()
        await recovery.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: restart.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sample.path))
    }

    func testQuitDuringRestartPreparationPreventsLaunchCommit() {
        let state = WatchdogRecoveryState()
        // Restart preparation has begun, but the final launch has not committed.
        XCTAssertTrue(state.isRecoveryAllowed)
        state.beginExpectedExit()
        let committed = state.performRecoveryIfAllowed {
            XCTFail("A confirmed quit must prevent the restart process from launching")
        }
        XCTAssertFalse(committed)
    }

    func testNormalFreezeStillRecoversAndCleansSample() async throws {
        let state = WatchdogRecoveryState()
        let sample = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("diagnostic sample".utf8).write(to: sample)
        defer { try? FileManager.default.removeItem(at: sample) }
        let recovered = expectation(description: "recovery ran")
        await state.recoverAfterDiagnostics {
            sample.path
        } recover: { path in
            XCTAssertEqual(path, sample.path)
            XCTAssertTrue(FileManager.default.fileExists(atPath: sample.path))
            XCTAssertTrue(state.performRecoveryIfAllowed { recovered.fulfill() })
        }
        await fulfillment(of: [recovered], timeout: 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sample.path))
    }
}

private actor QuitRecoveryTestGate {
    private var isOpen = false
    private var waiter: CheckedContinuation<Void, Never>?

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func open() {
        isOpen = true
        waiter?.resume()
        waiter = nil
    }
}
