import Combine
import CrashRecoverySupport
import Foundation
import ServiceManagement
import Shared

private let sharedCrashRecoveryWorker = CrashRecoveryWorker()
// Keep the caller-side timeout tight so watchdog recovery is not blocked for minutes
// if the helper never replies. Leave a small buffer above the helper's sample timeout.
private let watchdogHangSampleTimeoutMs: UInt64 = 6_000

private actor CrashRecoveryWorker {
    private let service = SMAppService.agent(plistName: CrashRecoverySupport.launchAgentPlistName)
    private var connection: NSXPCConnection?
    private var connectionID: ObjectIdentifier?
    private var armTask: Task<CrashRecoverySupport.Status, Never>?
    private var suppressReconnect = false
    private var unavailableReason: CrashRecoverySupport.Status.UnavailableReason?
    private var inFlightHangSampleCount = 0
    private var reconnectDeferredUntilHangSampleCompletes = false

#if DEBUG
    private var testBundledHelperProxy: CrashRecoveryHelperXPCProtocol?
    private var testDisconnectSuppressionDefaults: UserDefaults?
    private var testLaunchTarget: CrashRecoverySupport.LaunchTarget?
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
        guard let launchTarget = currentLaunchTarget(), launchTarget.isAppBundle else {
            Log.info(
                "[CrashRecovery] Skipping launch-agent arm because the current launch target is not an app bundle",
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
        if let armTask {
            _ = await armTask.value
        }

        suppressReconnect = true

        guard currentLaunchTarget()?.isAppBundle == true else {
            return refreshStatus()
        }

        guard let proxy = ensureProxyConnection() else {
            _ = storeDisconnectSuppression()
            return refreshStatus()
        }

        let acknowledged = await CrashRecoveryManager.helperAcknowledged(.expectedExit, via: proxy)
        guard acknowledged else {
            Log.warning(
                "[CrashRecovery] Helper did not acknowledge expected-exit handoff; installing disconnect suppression",
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
        if let armTask {
            _ = await armTask.value
        }

        suppressReconnect = true

        guard currentLaunchTarget()?.isAppBundle == true else {
            let status = refreshStatus()
            return (acknowledged: false, status: status)
        }

        guard let proxy = ensureProxyConnection() else {
            let status = refreshStatus()
            return (acknowledged: false, status: status)
        }

        let acknowledged = await CrashRecoveryManager.helperAcknowledged(
            .relaunch(targetAppPath),
            via: proxy
        )
        if !acknowledged {
            Log.warning("[CrashRecovery] Helper did not acknowledge relaunch handoff", category: .app)
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
        if let armTask {
            _ = await armTask.value
        }

        guard let launchTarget = currentLaunchTarget(), launchTarget.isAppBundle else {
            return refreshStatus()
        }

        guard refreshStatus() != .requiresApproval else {
            Log.info(
                "[CrashRecovery] Retry skipped because launch agent approval is still pending",
                category: .app
            )
            return refreshStatus()
        }

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
        do {
            try ensureServiceRegistered(for: launchTarget)
        } catch {
            unavailableReason = .registrationFailed
            Log.error("[CrashRecovery] Failed to register launch agent: \(error)", category: .app)
            return refreshStatus()
        }

        var armed = await armConnection()
        if !armed,
           CrashRecoverySupport.shouldAttemptRegistrationRecoveryAfterArmFailure(
               serviceStatus: service.status
           ) {
            Log.warning(
                "[CrashRecovery] Initial helper arm failed; refreshing launch agent registration",
                category: .app
            )

            do {
                try forceServiceRegistrationRefresh(for: launchTarget)
                disconnect()
                armed = await armConnection()
            } catch {
                disconnect()
                unavailableReason = .registrationFailed
                Log.error(
                    "[CrashRecovery] Failed to refresh launch agent registration: \(error)",
                    category: .app
                )
                return refreshStatus()
            }
        }

        if armed {
            unavailableReason = nil
            _ = clearDisconnectSuppressionAfterSuccessfulArm()
            Log.info("[CrashRecovery] Crash recovery helper armed via launch agent", category: .app)
            return refreshStatus()
        }

        disconnect()
        unavailableReason = .helperArmFailed
        Log.error("[CrashRecovery] Failed to arm crash recovery helper via launch agent", category: .app)
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

        if needsRefresh {
            if service.status == .enabled || service.status == .requiresApproval {
                do {
                    try service.unregister()
                } catch {
                    Log.warning(
                        "[CrashRecovery] Ignoring unregister failure during refresh: \(error)",
                        category: .app
                    )
                }
            }

            do {
                try service.register()
                defaults.set(currentBuild, forKey: CrashRecoverySupport.registeredBuildKey)
                defaults.set(
                    currentLaunchTargetPath,
                    forKey: CrashRecoverySupport.registeredLaunchTargetPathKey
                )
            } catch {
                if service.status == .enabled || service.status == .requiresApproval {
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
                "[CrashRecovery] Launch agent requires approval in System Settings",
                category: .app
            )
        }
    }

    private func armConnection() async -> Bool {
        suppressReconnect = false
        guard let proxy = ensureProxyConnection() else {
            return false
        }

        return await CrashRecoveryManager.helperAcknowledged(.armed, via: proxy)
    }

    private func forceServiceRegistrationRefresh(
        for launchTarget: CrashRecoverySupport.LaunchTarget
    ) throws {
        let defaults = UserDefaults.standard
        let currentBuild = CrashRecoverySupport.currentBuildIdentifier()
        let currentLaunchTargetPath = launchTarget.path

        if service.status == .enabled || service.status == .requiresApproval {
            do {
                try service.unregister()
            } catch {
                Log.warning(
                    "[CrashRecovery] Ignoring unregister failure during forced refresh: \(error)",
                    category: .app
                )
            }
        }

        try service.register()
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
            return proxy
        }

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

        return remoteProxy()
    }

    private func remoteProxy() -> CrashRecoveryHelperXPCProtocol? {
        guard let connection else { return nil }

        return connection.remoteObjectProxyWithErrorHandler { error in
            Log.error("[CrashRecovery] Helper XPC error: \(error)", category: .app)
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

    private func handleConnectionLoss(connectionID lostConnectionID: ObjectIdentifier, reason: String) async {
        guard connectionID == lostConnectionID else { return }

        await processCurrentConnectionLoss(reason: reason)
    }

    private func processCurrentConnectionLoss(reason: String) async {
        connection = nil
        connectionID = nil

        guard !suppressReconnect else {
            reconnectDeferredUntilHangSampleCompletes = false
            Log.info(
                "[CrashRecovery] Helper connection \(reason) during intentional shutdown",
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

        guard currentLaunchTarget()?.isAppBundle == true else {
            reconnectDeferredUntilHangSampleCompletes = false
            return
        }

        reconnectDeferredUntilHangSampleCompletes = false
        Log.warning("[CrashRecovery] Helper connection \(reason); attempting to re-arm", category: .app)
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
            _ = await armConnection()
            return
        }
#endif
        _ = await armAtLaunch()
    }

    private func currentLaunchTarget() -> CrashRecoverySupport.LaunchTarget? {
#if DEBUG
        if let testLaunchTarget {
            return testLaunchTarget
        }
#endif
        return CrashRecoverySupport.currentLaunchTarget()
    }

#if DEBUG
    func configureForTesting(
        proxy: CrashRecoveryHelperXPCProtocol,
        defaults: UserDefaults? = nil,
        launchTarget: CrashRecoverySupport.LaunchTarget
    ) {
        testBundledHelperProxy = proxy
        testDisconnectSuppressionDefaults = defaults
        testLaunchTarget = launchTarget
        connection = nil
        connectionID = nil
        armTask = nil
        suppressReconnect = false
        unavailableReason = nil
        inFlightHangSampleCount = 0
        reconnectDeferredUntilHangSampleCompletes = false
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

        return await invoke(timeoutMs: timeoutMs) { reply in
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
