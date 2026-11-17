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

    /// Diagnostics may finish after Quit. Clean up their temporary sample and
    /// skip the remaining recovery work when that happens.
    func recoverAfterDiagnostics(
        capture: @Sendable () async -> String?,
        recover: @Sendable (String?) -> Void
    ) async {
        guard isRecoveryAllowed else { return }
        let samplePath = await capture()
        defer {
            if let samplePath {
                try? FileManager.default.removeItem(atPath: samplePath)
            }
        }
        guard isRecoveryAllowed else { return }
        recover(samplePath)
    }

    /// Serialize the final launch/exit commit with confirmed Quit. Slow launch
    /// preparation must happen before entering this short critical section.
    @discardableResult
    func performRecoveryIfAllowed(_ action: () throws -> Void) rethrows -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !expectedExit else { return false }
        try action()
        return true
    }
}
