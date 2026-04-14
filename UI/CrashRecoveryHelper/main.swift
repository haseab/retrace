import CrashRecoverySupport
import Darwin
import Dispatch
import Foundation
import OSLog

private let helperLogger = Logger(subsystem: "io.retrace.app", category: "CrashRecoveryHelper")

private func helperDispositionDescription(_ disposition: CrashRecoverySupport.SessionDisposition) -> String {
    switch disposition {
    case .idle:
        return "idle"
    case .armed:
        return "armed"
    case .expectedExit:
        return "expectedExit"
    case .relaunch(let targetAppPath):
        return "relaunch(\(targetAppPath ?? "nil"))"
    }
}

private func helperDisconnectSuppressionDescription(
    _ snapshot: CrashRecoverySupport.DisconnectSuppressionSnapshot
) -> String {
    let ageDescription: String
    if let ageSeconds = snapshot.ageSeconds {
        ageDescription = String(format: "%.3f", ageSeconds)
    } else {
        ageDescription = "nil"
    }

    return "exists=\(snapshot.exists) ageSeconds=\(ageDescription) withinWindow=\(snapshot.withinWindow)"
}

private func helperTagged(_ message: String) -> String {
    CrashRecoverySupport.restartDebuggingTagged(message)
}

private final class CrashRecoveryHelperService: NSObject, NSXPCListenerDelegate, CrashRecoveryHelperXPCProtocol {
    private struct HangCaptureRequest {
        let trigger: String
        let timestamp: String
        let outputURL: URL
    }

    private static let watchdogSampleDurationSeconds = 1
    private static let watchdogSampleIntervalMilliseconds = 300
    private static let watchdogSampleTimeoutSeconds: TimeInterval = 5
    private static let watchdogSampleToolPath = "/usr/bin/sample"

    private let listener = NSXPCListener(machServiceName: CrashRecoverySupport.machServiceName)
    private let stateLock = NSLock()
    private var connection: NSXPCConnection?
    private var connectionID: ObjectIdentifier?
    private var deferredInvalidationConnections: [ObjectIdentifier: NSXPCConnection] = [:]
    private var appProcessIdentifier: pid_t?
    private var disposition: CrashRecoverySupport.SessionDisposition = .idle
    private var inFlightHangCaptureCount = 0

    func run() {
        NSLog(
            helperTagged("[CrashRecoveryHelper] Starting listener pid=\(getpid()) executable=\(CommandLine.arguments.first ?? "unknown")")
        )
        listener.delegate = self
        listener.resume()
        dispatchMain()
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        let newConnectionID = ObjectIdentifier(newConnection)
        var connectionsToInvalidate: [NSXPCConnection] = []
        let previousDisposition: CrashRecoverySupport.SessionDisposition
        newConnection.exportedInterface = NSXPCInterface(with: CrashRecoveryHelperXPCProtocol.self)
        newConnection.exportedObject = self
        newConnection.interruptionHandler = { [weak self] in
            self?.handleConnectionLoss(connectionID: newConnectionID, event: "interrupted")
        }
        newConnection.invalidationHandler = { [weak self] in
            self?.handleConnectionLoss(connectionID: newConnectionID, event: "invalidated")
        }

        stateLock.lock()
        previousDisposition = disposition
        if let currentConnection = connection {
            if let currentConnectionID = connectionID, inFlightHangCaptureCount > 0 {
                deferredInvalidationConnections[currentConnectionID] = currentConnection
            } else {
                connectionsToInvalidate.append(currentConnection)
            }
        }
        connection = newConnection
        connectionID = newConnectionID
        appProcessIdentifier = newConnection.processIdentifier
        disposition = .idle
        stateLock.unlock()

        for staleConnection in connectionsToInvalidate {
            staleConnection.invalidate()
        }
        newConnection.resume()
        NSLog(
            helperTagged("[CrashRecoveryHelper] Accepted app connection pid=\(newConnection.processIdentifier) previousDisposition=\(helperDispositionDescription(previousDisposition))")
        )
        return true
    }

    func arm(reply: @escaping () -> Void) {
        stateLock.lock()
        disposition = .armed
        stateLock.unlock()
        NSLog(helperTagged("[CrashRecoveryHelper] Received arm request"))
        reply()
    }

    func prepareForExpectedExit(reply: @escaping () -> Void) {
        stateLock.lock()
        disposition = .expectedExit
        stateLock.unlock()
        NSLog(helperTagged("[CrashRecoveryHelper] Received expected-exit handoff"))
        reply()
    }

    func prepareForRelaunch(targetAppPath: String?, reply: @escaping () -> Void) {
        stateLock.lock()
        disposition = .relaunch(targetAppPath)
        stateLock.unlock()
        NSLog(helperTagged("[CrashRecoveryHelper] Received relaunch handoff targetAppPath=\(targetAppPath ?? "nil")"))
        reply()
    }

    func captureWatchdogHangSample(trigger: String, reply: @escaping (String?) -> Void) {
        let targetPID: pid_t?

        stateLock.lock()
        targetPID = appProcessIdentifier
        stateLock.unlock()

        guard let targetPID, targetPID > 0 else {
            NSLog("[CrashRecoveryHelper] Watchdog hang sample skipped: missing target pid")
            reply(nil)
            return
        }

        guard let captureRequest = makeHangCaptureRequest(trigger: trigger) else {
            reply(nil)
            return
        }

        registerInFlightHangCapture()

        DispatchQueue.global(qos: .userInitiated).async {
            defer {
                self.finishInFlightHangCapture()
            }
            let startedAt = Date()
            self.performHangCapture(pid: targetPID, request: captureRequest)
            let elapsed = Date().timeIntervalSince(startedAt)
            let outputPath = FileManager.default.fileExists(atPath: captureRequest.outputURL.path)
                ? captureRequest.outputURL.path
                : nil
            if outputPath == nil {
                helperLogger.error(
                    "Watchdog hang capture finished in \(elapsed, format: .fixed(precision: 3))s but no report exists at \(captureRequest.outputURL.path, privacy: .public)"
                )
            }
            reply(outputPath)
        }
    }

    private func handleConnectionLoss(connectionID lostConnectionID: ObjectIdentifier, event: String) {
        let currentDisposition: CrashRecoverySupport.SessionDisposition

        stateLock.lock()
        if deferredInvalidationConnections.removeValue(forKey: lostConnectionID) != nil {
            stateLock.unlock()
            return
        }

        guard connectionID == lostConnectionID else {
            stateLock.unlock()
            return
        }

        connection = nil
        connectionID = nil
        appProcessIdentifier = nil
        currentDisposition = disposition
        disposition = .idle
        stateLock.unlock()

        let suppressionSnapshot = CrashRecoverySupport.consumeDisconnectSuppressionDetails()
        let disconnectSuppressed = suppressionSnapshot.withinWindow
        NSLog(
            helperTagged("[CrashRecoveryHelper] Connection lost event=\(event) disposition=\(helperDispositionDescription(currentDisposition)) disconnectSuppression=\(helperDisconnectSuppressionDescription(suppressionSnapshot))")
        )
        guard let launchParameters = currentDisposition.disconnectLaunchParameters(
            disconnectSuppressed: disconnectSuppressed
        ) else {
            if disconnectSuppressed || currentDisposition == .expectedExit {
                NSLog(
                    helperTagged("[CrashRecoveryHelper] No relaunch action event=\(event) disposition=\(helperDispositionDescription(currentDisposition)); keeping helper resident")
                )
            } else {
                NSLog(
                    helperTagged("[CrashRecoveryHelper] No relaunch action event=\(event) disposition=\(helperDispositionDescription(currentDisposition))")
                )
            }
            return
        }

        if launchParameters.markAsCrashRecovery {
            guard shouldAttemptCrashAutoRelaunch() else {
                return
            }
            NSLog(
                helperTagged("[CrashRecoveryHelper] App disconnected unexpectedly; relaunching targetAppPath=\(launchParameters.targetAppPath ?? "nil")")
            )
            relaunchApp(
                targetAppPath: launchParameters.targetAppPath,
                markAsCrashRecovery: true,
                source: .crashRecoveryHelper
            )
        } else {
            NSLog(helperTagged("[CrashRecoveryHelper] App requested relaunch; reopening target"))
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
        let pendingSessionID = CrashRecoverySupport.markRestartDebuggingPendingForNextLaunch()
        guard let target = resolveTarget(explicitPath: targetAppPath) else {
            NSLog(helperTagged("[CrashRecoveryHelper] Unable to resolve launch target for relaunch pendingSession=\(pendingSessionID)"))
            return
        }

        NSLog(
            helperTagged("[CrashRecoveryHelper] Resolved relaunch target path=\(target.path) markAsCrashRecovery=\(markAsCrashRecovery) source=\(source?.rawValue ?? "nil") pendingSession=\(pendingSessionID)")
        )
        launch(target: target, markAsCrashRecovery: markAsCrashRecovery, source: source)
    }

    private func registerInFlightHangCapture() {
        stateLock.lock()
        inFlightHangCaptureCount += 1
        stateLock.unlock()
    }

    private func finishInFlightHangCapture() {
        var remainingCount = 0
        var connectionsToInvalidate: [NSXPCConnection] = []

        stateLock.lock()
        if inFlightHangCaptureCount > 0 {
            inFlightHangCaptureCount -= 1
        }
        remainingCount = inFlightHangCaptureCount
        if remainingCount == 0, !deferredInvalidationConnections.isEmpty {
            connectionsToInvalidate = Array(deferredInvalidationConnections.values)
            deferredInvalidationConnections.removeAll()
        }
        stateLock.unlock()

        for staleConnection in connectionsToInvalidate {
            staleConnection.invalidate()
        }
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

    private func makeHangCaptureRequest(trigger: String) -> HangCaptureRequest? {
        let sanitizedTrigger = sanitizeTrigger(trigger)
        let timestamp = Self.sampleTimestampFormatter.string(from: Date())
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("retrace-watchdog-sample-\(sanitizedTrigger)-\(timestamp).txt")

        return HangCaptureRequest(
            trigger: trigger,
            timestamp: timestamp,
            outputURL: outputURL
        )
    }

    private func performHangCapture(pid: pid_t, request: HangCaptureRequest) {
        captureHangSample(pid: pid, request: request)
    }

    private func captureHangSample(pid: pid_t, request: HangCaptureRequest) {
        let launchStartedAt = Date()
        let process = Process()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: Self.watchdogSampleToolPath)
        process.arguments = [
            String(pid),
            String(Self.watchdogSampleDurationSeconds),
            String(Self.watchdogSampleIntervalMilliseconds),
            "-mayDie",
            "-file",
            request.outputURL.path
        ]
        process.standardError = stderrPipe

        helperLogger.log(
            "Launching sample trigger=\(request.trigger, privacy: .public) pid=\(pid) duration=\(Self.watchdogSampleDurationSeconds)s interval=\(Self.watchdogSampleIntervalMilliseconds)ms output=\(request.outputURL.path, privacy: .public)"
        )

        do {
            try process.run()
        } catch {
            let launchElapsed = Date().timeIntervalSince(launchStartedAt)
            helperLogger.error(
                "Failed to launch sample trigger=\(request.trigger, privacy: .public) pid=\(pid) after \(launchElapsed, format: .fixed(precision: 3))s: \(error.localizedDescription, privacy: .public)"
            )
            let report = failedSampleReport(
                trigger: request.trigger,
                timestamp: request.timestamp,
                pid: pid,
                terminationStatus: -1,
                timedOut: false,
                stderr: error.localizedDescription
            )
            writeHangCaptureReport(
                report,
                to: request.outputURL,
                successLogMessage: "[CrashRecoveryHelper] Wrote watchdog hang sample failure report to %@",
                failureLogPrefix: "[CrashRecoveryHelper] Failed to write watchdog hang sample failure report"
            )
            return
        }

        let timeoutStateLock = NSLock()
        var didTimeOut = false
        let timeoutItem = DispatchWorkItem {
            guard process.isRunning else { return }
            timeoutStateLock.lock()
            didTimeOut = true
            timeoutStateLock.unlock()
            helperLogger.error("sample timed out for pid \(pid); terminating")
            process.terminate()
        }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(
            deadline: .now() + Self.watchdogSampleTimeoutSeconds,
            execute: timeoutItem
        )
        process.waitUntilExit()
        timeoutItem.cancel()

        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        timeoutStateLock.lock()
        let sampleTimedOut = didTimeOut
        timeoutStateLock.unlock()
        let stderr = String(data: stderrData, encoding: .utf8)

        if process.terminationStatus == 0 {
            NSLog("[CrashRecoveryHelper] Wrote watchdog hang sample to %@", request.outputURL.path)
            return
        }

        let report = failedSampleReport(
            trigger: request.trigger,
            timestamp: request.timestamp,
            pid: pid,
            terminationStatus: process.terminationStatus,
            timedOut: sampleTimedOut,
            stderr: stderr
        )
        writeHangCaptureReport(
            report,
            to: request.outputURL,
            successLogMessage: "[CrashRecoveryHelper] Wrote watchdog hang sample failure report to %@",
            failureLogPrefix: "[CrashRecoveryHelper] Failed to write watchdog hang sample failure report"
        )
    }

    private func failedSampleReport(
        trigger: String,
        timestamp: String,
        pid: pid_t,
        terminationStatus: Int32,
        timedOut: Bool,
        stderr: String?
    ) -> String {
        var report = ""
        report += "=== RETRACE WATCHDOG HANG SAMPLE ===\n"
        report += "Trigger: \(trigger)\n"
        report += "Timestamp: \(timestamp)\n"
        report += "Target PID: \(pid)\n"
        report += "Tool: sample \(Self.watchdogSampleDurationSeconds)s \(Self.watchdogSampleIntervalMilliseconds)ms -mayDie -file\n"
        report += "Termination Status: \(terminationStatus)\n"
        report += "Timed Out: \(timedOut)\n\n"
        report += "(sample did not produce a usable report file)\n"

        if let stderr, !stderr.isEmpty {
            report += "\n--- STDERR ---\n"
            report += stderr
            if !stderr.hasSuffix("\n") {
                report += "\n"
            }
        }

        return report
    }

    private func writeHangCaptureReport(
        _ report: String,
        to outputURL: URL,
        successLogMessage: String,
        failureLogPrefix: String
    ) {
        do {
            try report.write(to: outputURL, atomically: true, encoding: .utf8)
            NSLog(successLogMessage, outputURL.path)
        } catch {
            NSLog("%@ %@: %@", failureLogPrefix, outputURL.path, error.localizedDescription)
        }
    }

    private func sanitizeTrigger(_ trigger: String) -> String {
        let scalars = trigger.unicodeScalars.map { scalar -> Character in
            switch scalar.value {
            case 48...57, 65...90, 97...122:
                return Character(scalar)
            case 45, 95:
                return Character(scalar)
            default:
                return "-"
            }
        }

        let sanitized = String(scalars)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return sanitized.isEmpty ? "watchdog" : sanitized
    }

    private static let sampleTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
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
            helperTagged("[CrashRecoveryHelper] Requested relaunch via \(relaunchProcess.executablePath) \(relaunchProcess.arguments.joined(separator: " "))")
        )
    } catch {
        if markAsCrashRecovery {
            _ = CrashRecoverySupport.clearPendingCrashRecoveryLaunchSource()
        }
        NSLog(
            helperTagged("[CrashRecoveryHelper] Failed to start relaunch via \(relaunchProcess.executablePath): \(error.localizedDescription)")
        )
    }
}

private func shouldAttemptCrashAutoRelaunch() -> Bool {
    let decision = CrashRecoverySupport.evaluateAndRecordCrashAutoRestart()
    NSLog(
        helperTagged("[CrashRecoveryHelper] Auto-restart decision shouldRelaunch=\(decision.shouldRelaunch) recentCount=\(decision.recentCount)")
    )
    guard decision.shouldRelaunch else {
        NSLog(
            helperTagged("[CrashRecoveryHelper] Auto-restart suppressed to prevent restart loop (\(decision.recentCount) restarts in last 5 minutes)")
        )
        return false
    }
    return true
}

private let service = CrashRecoveryHelperService()
service.run()
