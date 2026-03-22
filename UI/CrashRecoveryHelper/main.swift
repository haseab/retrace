import CrashRecoverySupport
import Dispatch
import Foundation

private final class CrashRecoveryHelperService: NSObject, NSXPCListenerDelegate, CrashRecoveryHelperXPCProtocol {
    private let listener = NSXPCListener(machServiceName: CrashRecoverySupport.machServiceName)
    private let stateLock = NSLock()
    private var connection: NSXPCConnection?
    private var connectionID: ObjectIdentifier?
    private var disposition: CrashRecoverySupport.SessionDisposition = .idle

    func run() {
        listener.delegate = self
        listener.resume()
        dispatchMain()
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        let newConnectionID = ObjectIdentifier(newConnection)
        newConnection.exportedInterface = NSXPCInterface(with: CrashRecoveryHelperXPCProtocol.self)
        newConnection.exportedObject = self
        newConnection.interruptionHandler = { [weak self] in
            self?.handleConnectionLoss(connectionID: newConnectionID, event: "interrupted")
        }
        newConnection.invalidationHandler = { [weak self] in
            self?.handleConnectionLoss(connectionID: newConnectionID, event: "invalidated")
        }

        stateLock.lock()
        connection?.invalidate()
        connection = newConnection
        connectionID = newConnectionID
        disposition = .idle
        stateLock.unlock()

        newConnection.resume()
        NSLog("[CrashRecoveryHelper] Accepted app connection")
        return true
    }

    func arm(reply: @escaping () -> Void) {
        stateLock.lock()
        disposition = .armed
        stateLock.unlock()
        reply()
    }

    func prepareForExpectedExit(reply: @escaping () -> Void) {
        stateLock.lock()
        disposition = .expectedExit
        stateLock.unlock()
        reply()
    }

    func prepareForRelaunch(targetAppPath: String?, reply: @escaping () -> Void) {
        stateLock.lock()
        disposition = .relaunch(targetAppPath)
        stateLock.unlock()
        reply()
    }

    private func handleConnectionLoss(connectionID lostConnectionID: ObjectIdentifier, event: String) {
        let currentDisposition: CrashRecoverySupport.SessionDisposition

        stateLock.lock()
        guard connectionID == lostConnectionID else {
            stateLock.unlock()
            return
        }

        connection = nil
        connectionID = nil
        currentDisposition = disposition
        disposition = .idle
        stateLock.unlock()

        let disconnectSuppressed = CrashRecoverySupport.consumeDisconnectSuppression()
        guard let launchParameters = currentDisposition.disconnectLaunchParameters(
            disconnectSuppressed: disconnectSuppressed
        ) else {
            if disconnectSuppressed || currentDisposition == .expectedExit {
                NSLog("[CrashRecoveryHelper] App disconnected after expected exit; keeping helper resident")
            } else {
                NSLog("[CrashRecoveryHelper] Ignoring \(event) with idle disposition")
            }
            return
        }

        if launchParameters.markAsCrashRecovery {
            guard shouldAttemptCrashAutoRelaunch() else {
                return
            }
            NSLog("[CrashRecoveryHelper] App disconnected unexpectedly; relaunching")
            relaunchApp(
                targetAppPath: launchParameters.targetAppPath,
                markAsCrashRecovery: true,
                source: .crashRecoveryHelper
            )
        } else {
            NSLog("[CrashRecoveryHelper] App requested relaunch; reopening target")
            relaunchApp(
                targetAppPath: launchParameters.targetAppPath,
                markAsCrashRecovery: false,
                source: nil
            )
        }
    }

    private func relaunchApp(
        targetAppPath: String?,
        markAsCrashRecovery: Bool,
        source: CrashRecoverySupport.RelaunchSource?
    ) {
        guard let target = resolveTarget(explicitPath: targetAppPath) else {
            NSLog("[CrashRecoveryHelper] Unable to resolve launch target for relaunch")
            return
        }

        launch(target: target, markAsCrashRecovery: markAsCrashRecovery, source: source)
    }

    private func resolveTarget(explicitPath: String?) -> CrashRecoverySupport.LaunchTarget? {
        if let explicitPath, explicitPath.isEmpty == false {
            let target = CrashRecoverySupport.launchTarget(forPath: explicitPath)
            if FileManager.default.fileExists(atPath: target.path) {
                return target
            }
        }

        return CrashRecoverySupport.currentLaunchTarget()
    }
}

private func launch(
    target: CrashRecoverySupport.LaunchTarget,
    markAsCrashRecovery: Bool,
    source: CrashRecoverySupport.RelaunchSource?
) {
    let relaunchProcess = CrashRecoverySupport.relaunchProcess(
        for: target,
        markAsCrashRecovery: markAsCrashRecovery,
        source: source
    )
    let process = Process()
    process.executableURL = URL(fileURLWithPath: relaunchProcess.executablePath)
    process.arguments = relaunchProcess.arguments

    do {
        try process.run()
        NSLog(
            "[CrashRecoveryHelper] Requested relaunch via \(relaunchProcess.executablePath) \(relaunchProcess.arguments.joined(separator: " "))"
        )
    } catch {
        if markAsCrashRecovery {
            _ = CrashRecoverySupport.clearPendingCrashRecoveryLaunchSource()
        }
        NSLog(
            "[CrashRecoveryHelper] Failed to start relaunch via \(relaunchProcess.executablePath): \(error.localizedDescription)"
        )
    }
}

private func shouldAttemptCrashAutoRelaunch() -> Bool {
    let decision = CrashRecoverySupport.evaluateAndRecordCrashAutoRestart()
    guard decision.shouldRelaunch else {
        NSLog(
            "[CrashRecoveryHelper] Auto-restart suppressed to prevent restart loop (\(decision.recentCount) restarts in last 5 minutes)"
        )
        return false
    }
    return true
}

private let service = CrashRecoveryHelperService()
service.run()
