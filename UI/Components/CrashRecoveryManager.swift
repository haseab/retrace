import Combine
import CrashRecoverySupport
import Foundation
import ServiceManagement
import Shared

private let sharedCrashRecoveryWorker = CrashRecoveryWorker()
// Keep the caller-side timeout tight so watchdog recovery is not blocked for minutes
// if the helper never replies. Leave a small buffer above the helper's sample timeout.
private let watchdogHangSampleTimeoutMs: UInt64 = 6_000

private func crashRecoveryServiceStatusDescription(_ status: SMAppService.Status) -> String {
    switch status {
    case .enabled:
        return "enabled"
    case .requiresApproval:
        return "requiresApproval"
    case .notRegistered:
        return "notRegistered"
    case .notFound:
        return "notFound"
    @unknown default:
        return "unknown"
    }
}

private func crashRecoveryLaunchTargetDescription(
    _ target: CrashRecoverySupport.LaunchTarget?
) -> String {
    guard let target else { return "nil" }

    switch target {
    case .appBundle(let url):
        return "appBundle(\(url.path))"
    case .executable(let url):
        return "executable(\(url.path))"
    }
}

private func crashRecoveryUnavailableReasonDescription(
    _ reason: CrashRecoverySupport.Status.UnavailableReason?
) -> String {
    guard let reason else { return "nil" }

    switch reason {
    case .registrationFailed:
        return "registrationFailed"
    case .helperArmFailed:
        return "helperArmFailed"
    }
}

private func crashRecoverySessionDispositionDescription(
    _ disposition: CrashRecoverySupport.SessionDisposition
) -> String {
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

private func crashRecoveryTagged(_ message: String) -> String {
    CrashRecoverySupport.restartDebuggingTagged(message)
}

private actor CrashRecoveryWorker {
    private static let armRetryAttempts = 12
    private static let armRetryDelayMs: UInt64 = 5_000
    private static let armAcknowledgementTimeoutMs: UInt64 = 800

    private let service = SMAppService.agent(plistName: CrashRecoverySupport.launchAgentPlistName)
    private var connection: NSXPCConnection?
    private var connectionID: ObjectIdentifier?
    private var armTask: Task<CrashRecoverySupport.Status, Never>?
    private var suppressReconnect = false
    private var unavailableReason: CrashRecoverySupport.Status.UnavailableReason?
    private var inFlightHangSampleCount = 0
    private var reconnectDeferredUntilHangSampleCompletes = false
    private var lastHelperXPCErrorSummary: String?
    private var lastHelperXPCErrorAt: Date?

#if DEBUG
    private var testBundledHelperProxy: CrashRecoveryHelperXPCProtocol?
    private var testDisconnectSuppressionDefaults: UserDefaults?
    private var testLaunchTarget: CrashRecoverySupport.LaunchTarget?
    private var testArmRetryAttempts: Int?
    private var testArmRetryDelayMs: UInt64?
    private var testArmAcknowledgementTimeoutMs: UInt64?
    private var disconnectCallCount = 0
#endif

    func refreshStatus() -> CrashRecoverySupport.Status {
        CrashRecoverySupport.makeUserFacingStatus(
            launchTarget: currentLaunchTarget(),
            serviceStatus: service.status,
            unavailableReason: unavailableReason
        )
    }

    func armAtLaunch() async -> CrashRecoverySupport.Status {
        let launchTarget = currentLaunchTarget()
        Log.info(
            crashRecoveryTagged("[CrashRecovery] armAtLaunch launchTarget=\(crashRecoveryLaunchTargetDescription(launchTarget)) serviceStatus=\(crashRecoveryServiceStatusDescription(service.status)) retryAttempts=\(configuredArmRetryAttempts) retryDelayMs=\(configuredArmRetryDelayMs) ackTimeoutMs=\(configuredArmAcknowledgementTimeoutMs) uptimeS=\(Int(ProcessInfo.processInfo.systemUptime.rounded()))"),
            category: .app
        )

        guard let launchTarget, launchTarget.isAppBundle else {
            Log.info(
                crashRecoveryTagged("[CrashRecovery] Skipping launch-agent arm because the current launch target is not an app bundle"),
                category: .app
            )
            disconnect()
            suppressReconnect = false
            unavailableReason = nil
            reconnectDeferredUntilHangSampleCompletes = false
            return refreshStatus()
        }

        return await startArmSequence(for: launchTarget)
    }

    func prepareForExpectedExit() async -> CrashRecoverySupport.Status {
        Log.info(
            crashRecoveryTagged("[CrashRecovery] prepareForExpectedExit launchTarget=\(crashRecoveryLaunchTargetDescription(currentLaunchTarget())) serviceStatus=\(crashRecoveryServiceStatusDescription(service.status)) hasConnection=\(connection != nil) suppressReconnect=\(suppressReconnect)"),
            category: .app
        )
        suppressReconnect = true
        cancelInFlightArmSequence()

        guard currentLaunchTarget()?.isAppBundle == true else {
            return refreshStatus()
        }

        guard let proxy = ensureProxyConnection() else {
            _ = storeDisconnectSuppression()
            return refreshStatus()
        }

        let acknowledgementStart = Date()
        clearRecentHelperXPCError()
        let disposition: CrashRecoverySupport.SessionDisposition = .expectedExit
        let acknowledged = await CrashRecoveryManager.helperAcknowledged(disposition, via: proxy)
        Log.info(
            crashRecoveryTagged("[CrashRecovery] Expected-exit handoff acknowledged=\(acknowledged) serviceStatus=\(crashRecoveryServiceStatusDescription(service.status)) failureReason=\(helperAckFailureReason(since: acknowledgementStart))"),
            category: .app
        )
        guard acknowledged else {
            Log.warning(
                crashRecoveryTagged("[CrashRecovery] Helper did not acknowledge expected-exit handoff; installing disconnect suppression"),
                category: .app
            )
            _ = storeDisconnectSuppression()
            return refreshStatus()
        }

        return refreshStatus()
    }

    func requestIntentionalRelaunch(
        targetAppPath: String? = nil
    ) async -> (acknowledged: Bool, status: CrashRecoverySupport.Status) {
        Log.info(
            crashRecoveryTagged("[CrashRecovery] requestIntentionalRelaunch targetAppPath=\(targetAppPath ?? "nil") launchTarget=\(crashRecoveryLaunchTargetDescription(currentLaunchTarget())) serviceStatus=\(crashRecoveryServiceStatusDescription(service.status))"),
            category: .app
        )
        suppressReconnect = true
        cancelInFlightArmSequence()

        guard currentLaunchTarget()?.isAppBundle == true else {
            let status = refreshStatus()
            return (acknowledged: false, status: status)
        }

        guard let proxy = ensureProxyConnection() else {
            let status = refreshStatus()
            return (acknowledged: false, status: status)
        }

        let acknowledgementStart = Date()
        clearRecentHelperXPCError()
        let disposition = CrashRecoverySupport.SessionDisposition.relaunch(targetAppPath)
        let acknowledged = await CrashRecoveryManager.helperAcknowledged(
            disposition,
            via: proxy
        )
        if !acknowledged {
            Log.warning(
                crashRecoveryTagged("[CrashRecovery] Helper did not acknowledge relaunch handoff failureReason=\(helperAckFailureReason(since: acknowledgementStart))"),
                category: .app
            )
        }

        return (acknowledged: acknowledged, status: refreshStatus())
    }

    func captureWatchdogHangSample(
        trigger: String,
        timeoutMs: UInt64 = watchdogHangSampleTimeoutMs
    ) async -> String? {
        guard let proxy = ensureProxyConnection() else {
            Log.warning("[CrashRecovery] Helper hang sample unavailable: no XPC proxy", category: .app)
            return nil
        }
        inFlightHangSampleCount += 1

        let samplePath = await CrashRecoveryManager.helperWatchdogHangSample(
            trigger,
            via: proxy,
            timeoutMs: timeoutMs
        )
        let shouldReconnect = finishHangSampleRequest()

        if samplePath == nil {
            Log.warning("[CrashRecovery] Helper hang sample request timed out or failed", category: .app)
        }

        if shouldReconnect {
            Log.warning(
                "[CrashRecovery] Re-arming helper after deferred connection loss during hang sample trigger=\(trigger)",
                category: .app
            )
            await rearmAfterDeferredHangSampleLoss()
        }

        return samplePath
    }

    func retryActivationAfterApprovalChange() async -> CrashRecoverySupport.Status {
        guard let launchTarget = currentLaunchTarget(), launchTarget.isAppBundle else {
            return refreshStatus()
        }

        guard refreshStatus() != .requiresApproval else {
            Log.info(
                crashRecoveryTagged("[CrashRecovery] Retry skipped because launch agent approval is still pending"),
                category: .app
            )
            return refreshStatus()
        }

        cancelInFlightArmSequence()
        disconnect()
        suppressReconnect = false
        unavailableReason = nil
        return await startArmSequence(for: launchTarget)
    }

    private func startArmSequence(
        for launchTarget: CrashRecoverySupport.LaunchTarget
    ) async -> CrashRecoverySupport.Status {
        if let armTask {
            return await armTask.value
        }

        let task = Task { await self.performArmSequence(for: launchTarget) }
        armTask = task
        let status = await task.value
        armTask = nil
        return status
    }

    private func performArmSequence(
        for launchTarget: CrashRecoverySupport.LaunchTarget
    ) async -> CrashRecoverySupport.Status {
        Log.info(
            crashRecoveryTagged("[CrashRecovery] Starting arm sequence launchTarget=\(crashRecoveryLaunchTargetDescription(launchTarget)) serviceStatus=\(crashRecoveryServiceStatusDescription(service.status)) unavailableReason=\(crashRecoveryUnavailableReasonDescription(unavailableReason))"),
            category: .app
        )
        do {
            try ensureServiceRegistered(for: launchTarget)
        } catch {
            unavailableReason = .registrationFailed
            Log.error(crashRecoveryTagged("[CrashRecovery] Failed to register launch agent: \(error)"), category: .app)
            return refreshStatus()
        }

        let retryAttempts = max(1, configuredArmRetryAttempts)
        let retryDelayMs = configuredArmRetryDelayMs
        var attemptedRegistrationRefresh = false

        for attempt in 1...retryAttempts {
            Log.info(
                crashRecoveryTagged("[CrashRecovery] Arm attempt \(attempt)/\(retryAttempts) begin serviceStatus=\(crashRecoveryServiceStatusDescription(service.status)) hasConnection=\(connection != nil) attemptedRegistrationRefresh=\(attemptedRegistrationRefresh)"),
                category: .app
            )
            let armed = await armConnection(timeoutMs: configuredArmAcknowledgementTimeoutMs)
            Log.info(
                crashRecoveryTagged("[CrashRecovery] Arm attempt \(attempt)/\(retryAttempts) end acknowledged=\(armed) serviceStatus=\(crashRecoveryServiceStatusDescription(service.status))"),
                category: .app
            )
            if Task.isCancelled {
                disconnect()
                unavailableReason = nil
                return refreshStatus()
            }

            if armed {
                unavailableReason = nil
                _ = clearDisconnectSuppressionAfterSuccessfulArm()
                if attempt > 1 {
                    Log.info(
                        crashRecoveryTagged("[CrashRecovery] Crash recovery helper armed via launch agent after \(attempt) attempts"),
                        category: .app
                    )
                } else {
                    Log.info(crashRecoveryTagged("[CrashRecovery] Crash recovery helper armed via launch agent"), category: .app)
                }
                return refreshStatus()
            }

            if !attemptedRegistrationRefresh,
               CrashRecoverySupport.shouldAttemptRegistrationRecoveryAfterArmFailure(
                   serviceStatus: service.status
               ) {
                attemptedRegistrationRefresh = true
                Log.warning(
                    crashRecoveryTagged("[CrashRecovery] Initial helper arm failed; refreshing launch agent registration"),
                    category: .app
                )

                do {
                    try forceServiceRegistrationRefresh(for: launchTarget)
                } catch {
                    disconnect()
                    unavailableReason = .registrationFailed
                    Log.error(
                        crashRecoveryTagged("[CrashRecovery] Failed to refresh launch agent registration: \(error)"),
                        category: .app
                    )
                    return refreshStatus()
                }
            }

            disconnect()
            guard attempt < retryAttempts else { break }

            Log.warning(
                crashRecoveryTagged("[CrashRecovery] Helper arm attempt \(attempt) failed; retrying in \(retryDelayMs) ms"),
                category: .app
            )

            do {
                try await Task.sleep(for: .milliseconds(Int64(retryDelayMs)), clock: .continuous)
            } catch {
                unavailableReason = nil
                return refreshStatus()
            }
        }

        disconnect()
        unavailableReason = .helperArmFailed
        Log.error(crashRecoveryTagged("[CrashRecovery] Failed to arm crash recovery helper via launch agent"), category: .app)
        return refreshStatus()
    }

    private func ensureServiceRegistered(for launchTarget: CrashRecoverySupport.LaunchTarget) throws {
        let defaults = UserDefaults.standard
        let currentBuild = CrashRecoverySupport.currentBuildIdentifier()
        let storedBuild = defaults.string(forKey: CrashRecoverySupport.registeredBuildKey)
        let currentLaunchTargetPath = launchTarget.path
        let storedLaunchTargetPath = defaults.string(
            forKey: CrashRecoverySupport.registeredLaunchTargetPathKey
        )
        let needsRefresh = CrashRecoverySupport.shouldRefreshRegistration(
            storedBuild: storedBuild,
            currentBuild: currentBuild,
            storedLaunchTargetPath: storedLaunchTargetPath,
            currentLaunchTargetPath: currentLaunchTargetPath,
            status: service.status
        )
        Log.info(
            crashRecoveryTagged("[CrashRecovery] ensureServiceRegistered serviceStatus=\(crashRecoveryServiceStatusDescription(service.status)) needsRefresh=\(needsRefresh) storedBuild=\(storedBuild ?? "nil") currentBuild=\(currentBuild) storedLaunchTargetPath=\(storedLaunchTargetPath ?? "nil") currentLaunchTargetPath=\(currentLaunchTargetPath)"),
            category: .app
        )

        if needsRefresh {
            if service.status == .enabled || service.status == .requiresApproval {
                do {
                    try service.unregister()
                } catch {
                    Log.warning(
                        crashRecoveryTagged("[CrashRecovery] Ignoring unregister failure during refresh: \(error)"),
                        category: .app
                    )
                }
            }

            do {
                try service.register()
                Log.info(
                    crashRecoveryTagged("[CrashRecovery] Launch agent register succeeded serviceStatus=\(crashRecoveryServiceStatusDescription(service.status)) launchTarget=\(currentLaunchTargetPath)"),
                    category: .app
                )
                defaults.set(currentBuild, forKey: CrashRecoverySupport.registeredBuildKey)
                defaults.set(
                    currentLaunchTargetPath,
                    forKey: CrashRecoverySupport.registeredLaunchTargetPathKey
                )
            } catch {
                if service.status == .enabled || service.status == .requiresApproval {
                    Log.warning(
                        crashRecoveryTagged("[CrashRecovery] Launch agent register threw but service status is \(crashRecoveryServiceStatusDescription(service.status)); preserving registration metadata"),
                        category: .app
                    )
                    defaults.set(currentBuild, forKey: CrashRecoverySupport.registeredBuildKey)
                    defaults.set(
                        currentLaunchTargetPath,
                        forKey: CrashRecoverySupport.registeredLaunchTargetPathKey
                    )
                } else {
                    throw error
                }
            }
        }

        if service.status == .requiresApproval {
            Log.warning(
                crashRecoveryTagged("[CrashRecovery] Launch agent requires approval in System Settings"),
                category: .app
            )
        }
    }

    private func armConnection(timeoutMs: UInt64) async -> Bool {
        suppressReconnect = false
        let acknowledgementStart = Date()
        clearRecentHelperXPCError()
        Log.info(
            crashRecoveryTagged("[CrashRecovery] armConnection begin timeoutMs=\(timeoutMs) serviceStatus=\(crashRecoveryServiceStatusDescription(service.status)) hasConnection=\(connection != nil)"),
            category: .app
        )
        guard let proxy = ensureProxyConnection() else {
            Log.warning(
                crashRecoveryTagged("[CrashRecovery] armConnection failed before acknowledgement because helper proxy was unavailable"),
                category: .app
            )
            return false
        }

        let acknowledged = await CrashRecoveryManager.helperAcknowledged(
            .armed,
            via: proxy,
            timeoutMs: timeoutMs
        )
        Log.info(
            crashRecoveryTagged("[CrashRecovery] armConnection end acknowledged=\(acknowledged) serviceStatus=\(crashRecoveryServiceStatusDescription(service.status)) failureReason=\(helperAckFailureReason(since: acknowledgementStart))"),
            category: .app
        )
        return acknowledged
    }

    private func forceServiceRegistrationRefresh(
        for launchTarget: CrashRecoverySupport.LaunchTarget
    ) throws {
        let defaults = UserDefaults.standard
        let currentBuild = CrashRecoverySupport.currentBuildIdentifier()
        let currentLaunchTargetPath = launchTarget.path
        Log.warning(
            crashRecoveryTagged("[CrashRecovery] Forcing launch agent registration refresh serviceStatus=\(crashRecoveryServiceStatusDescription(service.status)) currentBuild=\(currentBuild) launchTarget=\(currentLaunchTargetPath)"),
            category: .app
        )

        if service.status == .enabled || service.status == .requiresApproval {
            do {
                try service.unregister()
            } catch {
                Log.warning(
                    crashRecoveryTagged("[CrashRecovery] Ignoring unregister failure during forced refresh: \(error)"),
                    category: .app
                )
            }
        }

        try service.register()
        Log.info(
            crashRecoveryTagged("[CrashRecovery] Forced launch agent registration succeeded serviceStatus=\(crashRecoveryServiceStatusDescription(service.status)) launchTarget=\(currentLaunchTargetPath)"),
            category: .app
        )
        defaults.set(currentBuild, forKey: CrashRecoverySupport.registeredBuildKey)
        defaults.set(
            currentLaunchTargetPath,
            forKey: CrashRecoverySupport.registeredLaunchTargetPathKey
        )
    }

    private var disconnectSuppressionDefaults: UserDefaults? {
#if DEBUG
        testDisconnectSuppressionDefaults
#else
        nil
#endif
    }

    @discardableResult
    private func clearDisconnectSuppressionAfterSuccessfulArm() -> Bool {
        CrashRecoverySupport.clearDisconnectSuppression(defaults: disconnectSuppressionDefaults)
    }

    @discardableResult
    private func storeDisconnectSuppression() -> Bool {
        CrashRecoverySupport.storeDisconnectSuppression(defaults: disconnectSuppressionDefaults)
    }

    private func ensureProxyConnection() -> CrashRecoveryHelperXPCProtocol? {
#if DEBUG
        if let testBundledHelperProxy {
            return testBundledHelperProxy
        }
#endif
        if let proxy = remoteProxy() {
            Log.debug(
                crashRecoveryTagged("[CrashRecovery] Reusing existing helper XPC connection serviceStatus=\(crashRecoveryServiceStatusDescription(service.status))"),
                category: .app
            )
            return proxy
        }

        Log.info(
            crashRecoveryTagged("[CrashRecovery] Creating helper XPC connection machService=\(CrashRecoverySupport.machServiceName) serviceStatus=\(crashRecoveryServiceStatusDescription(service.status))"),
            category: .app
        )
        let newConnection = NSXPCConnection(
            machServiceName: CrashRecoverySupport.machServiceName,
            options: []
        )
        let newConnectionID = ObjectIdentifier(newConnection)
        newConnection.remoteObjectInterface = NSXPCInterface(
            with: CrashRecoveryHelperXPCProtocol.self
        )
        newConnection.interruptionHandler = { [weak self] in
            Task {
                await self?.handleConnectionLoss(connectionID: newConnectionID, reason: "interrupted")
            }
        }
        newConnection.invalidationHandler = { [weak self] in
            Task {
                await self?.handleConnectionLoss(connectionID: newConnectionID, reason: "invalidated")
            }
        }
        newConnection.resume()
        connection = newConnection
        connectionID = newConnectionID
        Log.info(
            crashRecoveryTagged("[CrashRecovery] Helper XPC connection resumed machService=\(CrashRecoverySupport.machServiceName)"),
            category: .app
        )

        return remoteProxy()
    }

    private func remoteProxy() -> CrashRecoveryHelperXPCProtocol? {
        guard let connection else { return nil }

        return connection.remoteObjectProxyWithErrorHandler { error in
            Task {
                await self.recordHelperXPCError(error)
            }
        } as? CrashRecoveryHelperXPCProtocol
    }

    private func disconnect() {
#if DEBUG
        disconnectCallCount += 1
#endif
        let currentConnection = connection
        connection = nil
        connectionID = nil
        currentConnection?.interruptionHandler = nil
        currentConnection?.invalidationHandler = nil
        currentConnection?.invalidate()
    }

    private func cancelInFlightArmSequence() {
        let currentArmTask = armTask
        armTask = nil
        currentArmTask?.cancel()
    }

    private func handleConnectionLoss(connectionID lostConnectionID: ObjectIdentifier, reason: String) async {
        guard connectionID == lostConnectionID else { return }

        await processCurrentConnectionLoss(reason: reason)
    }

    private func processCurrentConnectionLoss(reason: String) async {
        connection = nil
        connectionID = nil
        Log.warning(
            crashRecoveryTagged("[CrashRecovery] Helper connection loss reason=\(reason) suppressReconnect=\(suppressReconnect) launchTarget=\(crashRecoveryLaunchTargetDescription(currentLaunchTarget())) serviceStatus=\(crashRecoveryServiceStatusDescription(service.status)) armTaskInFlight=\(armTask != nil)"),
            category: .app
        )

        guard !suppressReconnect else {
            reconnectDeferredUntilHangSampleCompletes = false
            Log.info(
                crashRecoveryTagged("[CrashRecovery] Helper connection \(reason) during intentional shutdown"),
                category: .app
            )
            return
        }

        if inFlightHangSampleCount > 0 {
            reconnectDeferredUntilHangSampleCompletes = true
            Log.warning(
                "[CrashRecovery] Helper connection \(reason) while hang sample is in flight; deferring re-arm",
                category: .app
            )
            return
        }

        reconnectDeferredUntilHangSampleCompletes = false
        guard currentLaunchTarget()?.isAppBundle == true else {
            return
        }

        Log.warning(
            crashRecoveryTagged("[CrashRecovery] Helper connection \(reason); attempting to re-arm"),
            category: .app
        )
        _ = await armAtLaunch()
    }

    private func finishHangSampleRequest() -> Bool {
        if inFlightHangSampleCount > 0 {
            inFlightHangSampleCount -= 1
        }

        let shouldReconnect = reconnectDeferredUntilHangSampleCompletes &&
            inFlightHangSampleCount == 0 &&
            suppressReconnect == false &&
            currentLaunchTarget()?.isAppBundle == true

        if inFlightHangSampleCount == 0 {
            reconnectDeferredUntilHangSampleCompletes = false
        }

        return shouldReconnect
    }

    private func rearmAfterDeferredHangSampleLoss() async {
#if DEBUG
        if testBundledHelperProxy != nil {
            _ = await armConnection(timeoutMs: configuredArmAcknowledgementTimeoutMs)
            return
        }
#endif
        _ = await armAtLaunch()
    }

    private func recordHelperXPCError(_ error: Error) async {
        let summary = error.localizedDescription
        lastHelperXPCErrorSummary = summary
        lastHelperXPCErrorAt = Date()
        Log.error(crashRecoveryTagged("[CrashRecovery] Helper XPC error: \(error)"), category: .app)
    }

    private func clearRecentHelperXPCError() {
        lastHelperXPCErrorSummary = nil
        lastHelperXPCErrorAt = nil
    }

    private func helperAckFailureReason(since startDate: Date) -> String {
        guard let lastHelperXPCErrorAt,
              lastHelperXPCErrorAt >= startDate else {
            return "timeout_waiting_for_reply"
        }

        return "recent_xpc_error(\(lastHelperXPCErrorSummary ?? "unknown"))"
    }
    private func currentLaunchTarget() -> CrashRecoverySupport.LaunchTarget? {
#if DEBUG
        if let testLaunchTarget {
            return testLaunchTarget
        }
#endif
        return CrashRecoverySupport.currentLaunchTarget()
    }

    private var configuredArmRetryAttempts: Int {
#if DEBUG
        max(1, testArmRetryAttempts ?? Self.armRetryAttempts)
#else
        Self.armRetryAttempts
#endif
    }

    private var configuredArmRetryDelayMs: UInt64 {
#if DEBUG
        testArmRetryDelayMs ?? Self.armRetryDelayMs
#else
        Self.armRetryDelayMs
#endif
    }

    private var configuredArmAcknowledgementTimeoutMs: UInt64 {
#if DEBUG
        testArmAcknowledgementTimeoutMs ?? Self.armAcknowledgementTimeoutMs
#else
        Self.armAcknowledgementTimeoutMs
#endif
    }

#if DEBUG
    func configureForTesting(
        proxy: CrashRecoveryHelperXPCProtocol,
        defaults: UserDefaults? = nil,
        launchTarget: CrashRecoverySupport.LaunchTarget,
        armRetryAttempts: Int? = nil,
        armRetryDelayMs: UInt64? = nil,
        armAcknowledgementTimeoutMs: UInt64? = nil
    ) {
        testBundledHelperProxy = proxy
        testDisconnectSuppressionDefaults = defaults
        testLaunchTarget = launchTarget
        testArmRetryAttempts = armRetryAttempts
        testArmRetryDelayMs = armRetryDelayMs
        testArmAcknowledgementTimeoutMs = armAcknowledgementTimeoutMs
        connection = nil
        connectionID = nil
        armTask = nil
        suppressReconnect = false
        unavailableReason = nil
        inFlightHangSampleCount = 0
        reconnectDeferredUntilHangSampleCompletes = false
        lastHelperXPCErrorSummary = nil
        lastHelperXPCErrorAt = nil
        disconnectCallCount = 0
    }

    func testDisconnectCallCount() -> Int {
        disconnectCallCount
    }

    func simulateConnectionLossForTesting(reason: String) async {
        await processCurrentConnectionLoss(reason: reason)
    }
#endif
}

@MainActor
final class CrashRecoveryManager: ObservableObject {
    static let shared = CrashRecoveryManager()

    @Published private(set) var userFacingStatus: CrashRecoverySupport.Status

    private let worker: CrashRecoveryWorker
    private let launchSource: CrashRecoverySupport.RelaunchSource?

    var launchedFromCrashRecovery: Bool {
        launchSource != nil
    }

    var recoveryLaunchSource: CrashRecoverySupport.RelaunchSource? {
        launchSource
    }

    var approvalRequired: Bool {
        if case .requiresApproval = userFacingStatus {
            return true
        }
        return false
    }

    private init(
        worker: CrashRecoveryWorker = sharedCrashRecoveryWorker,
        launchSource: CrashRecoverySupport.RelaunchSource? = CrashRecoverySupport.consumeCrashRecoveryLaunchSource()
    ) {
        self.worker = worker
        self.launchSource = launchSource
        self.userFacingStatus = CrashRecoverySupport.makeUserFacingStatus(
            launchTarget: CrashRecoverySupport.currentLaunchTarget(),
            serviceStatus: SMAppService.agent(
                plistName: CrashRecoverySupport.launchAgentPlistName
            ).status,
            unavailableReason: nil
        )
    }

    func armAtLaunch() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            Log.info(
                crashRecoveryTagged("[CrashRecovery] App-side armAtLaunch launchedFromCrashRecovery=\(self.launchedFromCrashRecovery) source=\(self.launchSource?.rawValue ?? "nil") initialUserFacingStatus=\(String(describing: self.userFacingStatus))"),
                category: .app
            )
            self.userFacingStatus = await self.worker.armAtLaunch()
        }
    }

    func refreshUserFacingStatus() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.userFacingStatus = await self.worker.refreshStatus()
        }
    }

    func prepareForExpectedExit() async {
        userFacingStatus = await worker.prepareForExpectedExit()
    }

    func requestIntentionalRelaunch(targetAppPath: String? = nil) async -> Bool {
        let result = await worker.requestIntentionalRelaunch(targetAppPath: targetAppPath)
        userFacingStatus = result.status
        return result.acknowledged
    }

    func retryActivationAfterApprovalChange() async {
        userFacingStatus = await worker.retryActivationAfterApprovalChange()
    }

    func captureWatchdogHangSample(
        trigger: String,
        timeoutMs: UInt64 = watchdogHangSampleTimeoutMs
    ) async -> String? {
        await worker.captureWatchdogHangSample(trigger: trigger, timeoutMs: timeoutMs)
    }

    nonisolated static func captureWatchdogHangSample(
        trigger: String,
        timeoutMs: UInt64 = watchdogHangSampleTimeoutMs
    ) async -> String? {
        await sharedCrashRecoveryWorker.captureWatchdogHangSample(trigger: trigger, timeoutMs: timeoutMs)
    }

    nonisolated static func helperAcknowledged(
        _ disposition: CrashRecoverySupport.SessionDisposition,
        via proxy: CrashRecoveryHelperXPCProtocol,
        timeoutMs: UInt64 = 800
    ) async -> Bool {
        guard disposition != .idle else {
            return false
        }

        let acknowledged = await invoke(timeoutMs: timeoutMs) { reply in
            switch disposition {
            case .idle:
                reply()
            case .armed:
                proxy.arm(reply: reply)
            case .expectedExit:
                proxy.prepareForExpectedExit(reply: reply)
            case .relaunch(let targetAppPath):
                proxy.prepareForRelaunch(targetAppPath: targetAppPath, reply: reply)
            }
        }
        if !acknowledged {
            Log.warning(
                crashRecoveryTagged("[CrashRecovery] Helper acknowledgement timed out disposition=\(crashRecoverySessionDispositionDescription(disposition)) timeoutMs=\(timeoutMs)"),
                category: .app
            )
        }
        return acknowledged
    }

    nonisolated static func helperWatchdogHangSample(
        _ trigger: String,
        via proxy: CrashRecoveryHelperXPCProtocol,
        timeoutMs: UInt64 = watchdogHangSampleTimeoutMs
    ) async -> String? {
        await invoke(timeoutMs: timeoutMs, defaultValue: nil as String?) { reply in
            proxy.captureWatchdogHangSample(trigger: trigger) { outputPath in
                reply(outputPath)
            }
        }
    }

    private nonisolated static func invoke(
        timeoutMs: UInt64 = 800,
        _ body: @escaping (@escaping () -> Void) -> Void
    ) async -> Bool {
        await invoke(timeoutMs: timeoutMs, defaultValue: false as Bool) { reply in
            body {
                reply(true)
            }
        }
    }

    private nonisolated static func invoke<T: Sendable>(
        timeoutMs: UInt64,
        defaultValue: T,
        _ body: @escaping (@escaping (T) -> Void) -> Void
    ) async -> T {
        await withCheckedContinuation { continuation in
            let lock = NSLock()
            var finished = false

            func finish(_ result: T) {
                lock.lock()
                defer { lock.unlock() }
                guard !finished else { return }
                finished = true
                continuation.resume(returning: result)
            }

            body { result in finish(result) }

            Task {
                try? await Task.sleep(for: .milliseconds(timeoutMs))
                finish(defaultValue)
            }
        }
    }

#if DEBUG
    static func makeForTesting() -> CrashRecoveryManager {
        CrashRecoveryManager(worker: CrashRecoveryWorker(), launchSource: nil)
    }

    func configureBundledHelperForTesting(
        proxy: CrashRecoveryHelperXPCProtocol,
        defaults: UserDefaults? = nil,
        launchTarget: CrashRecoverySupport.LaunchTarget = .appBundle(
            URL(fileURLWithPath: "/Applications/Retrace.app")
        )
    ) async {
        await worker.configureForTesting(
            proxy: proxy,
            defaults: defaults,
            launchTarget: launchTarget
        )
        userFacingStatus = await worker.refreshStatus()
    }

    func testDisconnectCallCount() async -> Int {
        await worker.testDisconnectCallCount()
    }

    func simulateHelperConnectionLossForTesting(reason: String) async {
        await worker.simulateConnectionLossForTesting(reason: reason)
    }
#endif
}
