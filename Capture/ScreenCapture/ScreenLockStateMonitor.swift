import Foundation
import AppKit

/// Tracks session lock/screensaver transitions published via distributed notifications.
final class ScreenLockStateMonitor: @unchecked Sendable {
    private let distributedCenter = DistributedNotificationCenter.default()
    private let stateLock = NSLock()
    private var observerTokens: [NSObjectProtocol] = []
    private var isObserving = false
    private var isScreenLocked = false
    private var isScreenSaverRunning = false

    private static let screenLockedNotification = Notification.Name("com.apple.screenIsLocked")
    private static let screenUnlockedNotification = Notification.Name("com.apple.screenIsUnlocked")
    private static let screenSaverDidStartNotification = Notification.Name("com.apple.screensaver.didstart")
    private static let screenSaverDidStopNotification = Notification.Name("com.apple.screensaver.didstop")

    func start() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !isObserving else { return }
        isObserving = true

        observerTokens = [
            distributedCenter.addObserver(
                forName: Self.screenLockedNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                self?.setScreenLocked(true)
            },
            distributedCenter.addObserver(
                forName: Self.screenUnlockedNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                self?.setScreenLocked(false)
                self?.setScreenSaverRunning(false)
            },
            distributedCenter.addObserver(
                forName: Self.screenSaverDidStartNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                self?.setScreenSaverRunning(true)
            },
            distributedCenter.addObserver(
                forName: Self.screenSaverDidStopNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                self?.setScreenSaverRunning(false)
            }
        ]
    }

    func stop() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard isObserving else { return }

        for token in observerTokens {
            distributedCenter.removeObserver(token)
        }
        observerTokens.removeAll()
        isObserving = false
        isScreenLocked = false
        isScreenSaverRunning = false
    }

    func captureBlockReason() -> String? {
        stateLock.lock()
        defer { stateLock.unlock() }

        if isScreenLocked {
            return "session-locked"
        }
        if isScreenSaverRunning {
            return "screensaver-active"
        }
        return nil
    }

    private func setScreenLocked(_ value: Bool) {
        stateLock.lock()
        isScreenLocked = value
        stateLock.unlock()
    }

    private func setScreenSaverRunning(_ value: Bool) {
        stateLock.lock()
        isScreenSaverRunning = value
        stateLock.unlock()
    }
}
