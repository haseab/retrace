import Foundation

/// Shared by the main-thread quit path and background watchdog recovery.
final class WatchdogRecoveryState: @unchecked Sendable {
    private let lock = NSLock()
    private var expectedExit = false

    var isRecoveryAllowed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !expectedExit
    }

    func beginExpectedExit() {
        lock.lock()
        defer { lock.unlock() }
        expectedExit = true
    }
}
