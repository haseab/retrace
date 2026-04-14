import Darwin
import Foundation
import ServiceManagement

public enum CrashRecoverySupport {
    public enum Status: Equatable {
        public enum UnavailableReason: Equatable {
            case registrationFailed
            case helperArmFailed
        }

        case available
        case requiresApproval
        case unavailable(UnavailableReason)
    }

    public enum RelaunchSource: String, Equatable {
        case crashRecoveryHelper = "crash_recovery_helper"
        case watchdogAutoQuit = "watchdog_auto_quit"
        case unknown = "unknown"
    }

    public enum SessionDisposition: Equatable {
        case idle
        case armed
        case expectedExit
        case relaunch(String?)

        public func disconnectLaunchParameters(
            disconnectSuppressed: Bool
        ) -> (targetAppPath: String?, markAsCrashRecovery: Bool)? {
            guard disconnectSuppressed == false else { return nil }

            switch self {
            case .idle, .expectedExit:
                return nil
            case .armed:
                return (targetAppPath: nil, markAsCrashRecovery: true)
            case .relaunch(let targetAppPath):
                return (targetAppPath: targetAppPath, markAsCrashRecovery: false)
            }
        }
    }

    public enum LaunchTarget: Equatable {
        case appBundle(URL)
        case executable(URL)

        public var url: URL {
            switch self {
            case .appBundle(let url), .executable(let url):
                return url
            }
        }

        public var path: String { url.path }

        public var isAppBundle: Bool {
            if case .appBundle = self { return true }
            return false
        }
    }

    public struct RelaunchProcess: Equatable {
        public let executablePath: String
        public let arguments: [String]

        public init(executablePath: String, arguments: [String]) {
            self.executablePath = executablePath
            self.arguments = arguments
        }
    }

    public struct CrashAutoRestartDecision: Equatable {
        public let shouldRelaunch: Bool
        public let recentCount: Int

        public init(shouldRelaunch: Bool, recentCount: Int) {
            self.shouldRelaunch = shouldRelaunch
            self.recentCount = recentCount
        }
    }

    public struct DisconnectSuppressionSnapshot: Equatable {
        public let exists: Bool
        public let ageSeconds: TimeInterval?
        public let withinWindow: Bool

        public init(exists: Bool, ageSeconds: TimeInterval?, withinWindow: Bool) {
            self.exists = exists
            self.ageSeconds = ageSeconds
            self.withinWindow = withinWindow
        }
    }

    public struct RestartDebuggingSessionState: Equatable {
        public let sessionID: String
        public let reusedPendingSession: Bool

        public init(sessionID: String, reusedPendingSession: Bool) {
            self.sessionID = sessionID
            self.reusedPendingSession = reusedPendingSession
        }
    }

    public static let launchAgentLabel = "io.retrace.app.crash-recovery"
    public static let launchAgentPlistName = "io.retrace.app.crash-recovery.plist"
    public static let machServiceName = launchAgentLabel
    public static let crashRecoveryLaunchArgument = "--retrace-crash-recovery-relaunch"
    public static let crashRecoverySourceArgument = "--retrace-crash-recovery-source"
    public static let registeredBuildKey = "crashRecoveryRegisteredBuild"
    public static let registeredLaunchTargetPathKey = "crashRecoveryRegisteredLaunchTargetPath"
    public static let preferencesSuiteName = "io.retrace.app"
    public static let restartDebuggingLabelName = "restartDebugging"
    public static let restartDebuggingPendingMaxAgeSeconds: TimeInterval = 15 * 60
    public static let disconnectSuppressionMaxAgeSeconds: TimeInterval = 20
    public static let crashAutoRestartWindowSeconds: TimeInterval = 5 * 60
    public static let maxCrashAutoRestartsPerWindow = 2

    private static let disconnectSuppressionCreatedAtKey = "crashRecoveryDisconnectSuppressionCreatedAtMs"
    private static let crashAutoRestartTimestampsKey = "crashRecoveryAutoRestartTimestamps"
    private static let pendingCrashRecoveryLaunchSourceKey = "crashRecoveryPendingLaunchSource"
    private static let restartDebuggingActiveSessionKey = "restartDebuggingActiveSession"
    private static let restartDebuggingPendingSessionKey = "restartDebuggingPendingSession"
    private static let restartDebuggingPendingCreatedAtKey = "restartDebuggingPendingCreatedAtMs"
    private static let crashAutoRestartLock = NSLock()

    public static func beginRestartDebuggingSession(
        now: Date = Date(),
        defaults: UserDefaults? = nil
    ) -> RestartDebuggingSessionState {
        let defaults = defaults ?? crashRecoveryDefaults()
        let reusedPendingSession: Bool
        let sessionID: String

        if let pendingSessionID = validPendingRestartDebuggingSession(now: now, defaults: defaults) {
            sessionID = pendingSessionID
            reusedPendingSession = true
            _ = clearRestartDebuggingPending(defaults: defaults)
        } else {
            sessionID = makeRestartDebuggingSessionID()
            reusedPendingSession = false
        }

        defaults.set(sessionID, forKey: restartDebuggingActiveSessionKey)
        defaults.synchronize()
        return RestartDebuggingSessionState(
            sessionID: sessionID,
            reusedPendingSession: reusedPendingSession
        )
    }

    public static func currentRestartDebuggingSessionID(
        defaults: UserDefaults? = nil
    ) -> String? {
        let defaults = defaults ?? crashRecoveryDefaults()
        return defaults.string(forKey: restartDebuggingActiveSessionKey)
    }

    @discardableResult
    public static func markRestartDebuggingPendingForNextLaunch(
        now: Date = Date(),
        defaults: UserDefaults? = nil
    ) -> String {
        let defaults = defaults ?? crashRecoveryDefaults()
        let sessionID = currentRestartDebuggingSessionID(defaults: defaults) ?? makeRestartDebuggingSessionID()
        defaults.set(sessionID, forKey: restartDebuggingActiveSessionKey)
        defaults.set(sessionID, forKey: restartDebuggingPendingSessionKey)
        defaults.set(Int64(now.timeIntervalSince1970 * 1000), forKey: restartDebuggingPendingCreatedAtKey)
        defaults.synchronize()
        return sessionID
    }

    @discardableResult
    public static func clearRestartDebuggingPending(
        defaults: UserDefaults? = nil
    ) -> Bool {
        let defaults = defaults ?? crashRecoveryDefaults()
        defaults.removeObject(forKey: restartDebuggingPendingSessionKey)
        defaults.removeObject(forKey: restartDebuggingPendingCreatedAtKey)
        return defaults.synchronize()
    }

    public static func restartDebuggingLogLabel(
        defaults: UserDefaults? = nil
    ) -> String {
        let sessionID = currentRestartDebuggingSessionID(defaults: defaults) ?? "none"
        return "label=\(restartDebuggingLabelName) session=\(sessionID)"
    }

    public static func restartDebuggingTagged(
        _ message: String,
        defaults: UserDefaults? = nil
    ) -> String {
        "\(restartDebuggingLogLabel(defaults: defaults)) \(message)"
    }

    public static func launchedFromCrashRecovery(arguments: [String] = CommandLine.arguments) -> Bool {
        arguments.contains(crashRecoveryLaunchArgument)
    }

    public static func consumeCrashRecoveryLaunchSource(
        arguments: [String] = CommandLine.arguments,
        defaults: UserDefaults? = nil
    ) -> RelaunchSource? {
        guard launchedFromCrashRecovery(arguments: arguments) else {
            return nil
        }

        if let explicitSource = crashRecoveryLaunchSource(arguments: arguments) {
            _ = clearPendingCrashRecoveryLaunchSource(defaults: defaults)
            return explicitSource
        }

        return consumePendingCrashRecoveryLaunchSource(defaults: defaults) ?? .unknown
    }

    public static func crashRecoveryLaunchSource(
        arguments: [String] = CommandLine.arguments
    ) -> RelaunchSource? {
        guard let flagIndex = arguments.firstIndex(of: crashRecoverySourceArgument) else {
            return nil
        }

        let sourceIndex = arguments.index(after: flagIndex)
        guard sourceIndex < arguments.endIndex else {
            return .unknown
        }

        return RelaunchSource(rawValue: arguments[sourceIndex]) ?? .unknown
    }

    public static func currentBuildIdentifier(bundle: Bundle = .main) -> String {
        if let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
           !build.isEmpty {
            return build
        }
        return "unknown"
    }

    public static func shouldRefreshRegistration(
        storedBuild: String?,
        currentBuild: String,
        storedLaunchTargetPath: String?,
        currentLaunchTargetPath: String,
        status: SMAppService.Status
    ) -> Bool {
        guard storedBuild == currentBuild else { return true }
        guard storedLaunchTargetPath == currentLaunchTargetPath else { return true }

        switch status {
        case .enabled, .requiresApproval:
            return false
        case .notRegistered, .notFound:
            return true
        @unknown default:
            return true
        }
    }

    public static func shouldPromptForApproval(
        status: SMAppService.Status,
        launchTarget: LaunchTarget?
    ) -> Bool {
        launchTarget?.isAppBundle == true && status == .requiresApproval
    }

    public static func makeUserFacingStatus(
        launchTarget: LaunchTarget?,
        serviceStatus: SMAppService.Status,
        unavailableReason: Status.UnavailableReason?
    ) -> Status {
        guard launchTarget?.isAppBundle == true else {
            return .available
        }

        if shouldPromptForApproval(status: serviceStatus, launchTarget: launchTarget) {
            return .requiresApproval
        }

        if let unavailableReason {
            return .unavailable(unavailableReason)
        }

        return .available
    }

    public static func shouldAttemptRegistrationRecoveryAfterArmFailure(
        serviceStatus: SMAppService.Status
    ) -> Bool {
        serviceStatus != .requiresApproval
    }

    public static func currentExecutableURL(arguments: [String] = CommandLine.arguments) -> URL? {
        guard let executablePath = arguments.first, executablePath.isEmpty == false else {
            return currentProcessExecutableURL()
        }

        if executablePath.hasPrefix("/") {
            return URL(fileURLWithPath: executablePath).resolvingSymlinksInPath()
        }

        return currentProcessExecutableURL()
    }

    public static func currentLaunchTarget(arguments: [String] = CommandLine.arguments) -> LaunchTarget? {
        if let executableURL = currentExecutableURL(arguments: arguments) {
            if let bundleURL = appBundleURL(fromExecutableURL: executableURL) {
                return .appBundle(bundleURL)
            }
            return .executable(executableURL)
        }

        let bundleURL = Bundle.main.bundleURL
        if bundleURL.pathExtension == "app" {
            return .appBundle(bundleURL)
        }
        return nil
    }

    public static func launchTarget(forPath path: String) -> LaunchTarget {
        let url = URL(fileURLWithPath: path)
        if url.pathExtension == "app" {
            return .appBundle(url)
        }
        return .executable(url)
    }

    public static func relaunchProcess(
        for target: LaunchTarget,
        markAsCrashRecovery: Bool,
        source: RelaunchSource? = nil
    ) -> RelaunchProcess {
        switch target {
        case .appBundle(let appURL):
            var arguments = [appURL.path]
            if markAsCrashRecovery {
                arguments.append("--args")
                arguments.append(contentsOf: crashRecoveryLaunchArguments(source: source))
            }
            return RelaunchProcess(executablePath: "/usr/bin/open", arguments: arguments)
        case .executable(let executableURL):
            let arguments = markAsCrashRecovery ? crashRecoveryLaunchArguments(source: source) : []
            return RelaunchProcess(executablePath: executableURL.path, arguments: arguments)
        }
    }

    public static func crashRecoveryLaunchArguments(
        source: RelaunchSource? = nil
    ) -> [String] {
        var arguments = [crashRecoveryLaunchArgument]
        if let source {
            arguments.append(contentsOf: [crashRecoverySourceArgument, source.rawValue])
        }
        return arguments
    }

    public static func appBundleURL(fromExecutableURL executableURL: URL) -> URL? {
        var currentURL = executableURL.resolvingSymlinksInPath()
        if currentURL.hasDirectoryPath == false {
            currentURL.deleteLastPathComponent()
        }

        let rootPath = currentURL.pathComponents.first == "/" ? "/" : currentURL.path
        while true {
            if currentURL.pathExtension == "app" {
                return currentURL
            }

            if currentURL.path == rootPath {
                return nil
            }

            currentURL.deleteLastPathComponent()
        }
    }

    @discardableResult
    public static func storeDisconnectSuppression(
        now: Date = Date(),
        defaults: UserDefaults? = nil
    ) -> Bool {
        let defaults = defaults ?? crashRecoveryDefaults()
        defaults.set(Int64(now.timeIntervalSince1970 * 1000), forKey: disconnectSuppressionCreatedAtKey)
        return defaults.synchronize()
    }

    public static func loadDisconnectSuppression(
        now: Date = Date(),
        maxAge: TimeInterval = disconnectSuppressionMaxAgeSeconds,
        defaults: UserDefaults? = nil
    ) -> Bool {
        disconnectSuppressionSnapshot(
            now: now,
            maxAge: maxAge,
            defaults: defaults
        ).withinWindow
    }

    @discardableResult
    public static func clearDisconnectSuppression(
        defaults: UserDefaults? = nil
    ) -> Bool {
        let defaults = defaults ?? crashRecoveryDefaults()
        defaults.removeObject(forKey: disconnectSuppressionCreatedAtKey)
        return defaults.synchronize()
    }

    public static func consumeDisconnectSuppression(
        now: Date = Date(),
        maxAge: TimeInterval = disconnectSuppressionMaxAgeSeconds,
        defaults: UserDefaults? = nil
    ) -> Bool {
        consumeDisconnectSuppressionDetails(
            now: now,
            maxAge: maxAge,
            defaults: defaults
        ).withinWindow
    }

    public static func consumeDisconnectSuppressionDetails(
        now: Date = Date(),
        maxAge: TimeInterval = disconnectSuppressionMaxAgeSeconds,
        defaults: UserDefaults? = nil
    ) -> DisconnectSuppressionSnapshot {
        let defaults = defaults ?? crashRecoveryDefaults()
        let snapshot = disconnectSuppressionSnapshot(
            now: now,
            maxAge: maxAge,
            defaults: defaults
        )
        _ = clearDisconnectSuppression(defaults: defaults)
        return snapshot
    }

    public static func evaluateAndRecordCrashAutoRestart(
        now: Date = Date(),
        defaults: UserDefaults? = nil
    ) -> CrashAutoRestartDecision {
        crashAutoRestartLock.lock()
        defer { crashAutoRestartLock.unlock() }

        let defaults = defaults ?? crashRecoveryDefaults()
        let cutoff = now.timeIntervalSince1970 - crashAutoRestartWindowSeconds
        var timestamps = (defaults.array(forKey: crashAutoRestartTimestampsKey) as? [TimeInterval] ?? [])
            .filter { $0 >= cutoff }

        if timestamps.count >= maxCrashAutoRestartsPerWindow {
            defaults.set(timestamps, forKey: crashAutoRestartTimestampsKey)
            defaults.synchronize()
            return CrashAutoRestartDecision(
                shouldRelaunch: false,
                recentCount: timestamps.count
            )
        }

        timestamps.append(now.timeIntervalSince1970)
        defaults.set(timestamps, forKey: crashAutoRestartTimestampsKey)
        defaults.synchronize()
        return CrashAutoRestartDecision(
            shouldRelaunch: true,
            recentCount: timestamps.count
        )
    }

    @discardableResult
    public static func clearCrashAutoRestartHistory(
        defaults: UserDefaults? = nil
    ) -> Bool {
        let defaults = defaults ?? crashRecoveryDefaults()
        defaults.removeObject(forKey: crashAutoRestartTimestampsKey)
        return defaults.synchronize()
    }

    @discardableResult
    public static func storePendingCrashRecoveryLaunchSource(
        _ source: RelaunchSource,
        defaults: UserDefaults? = nil
    ) -> Bool {
        let defaults = defaults ?? crashRecoveryDefaults()
        defaults.set(source.rawValue, forKey: pendingCrashRecoveryLaunchSourceKey)
        return defaults.synchronize()
    }

    @discardableResult
    public static func clearPendingCrashRecoveryLaunchSource(
        defaults: UserDefaults? = nil
    ) -> Bool {
        let defaults = defaults ?? crashRecoveryDefaults()
        defaults.removeObject(forKey: pendingCrashRecoveryLaunchSourceKey)
        return defaults.synchronize()
    }

    private static func crashRecoveryDefaults() -> UserDefaults {
        UserDefaults(suiteName: preferencesSuiteName) ?? .standard
    }

    private static func validPendingRestartDebuggingSession(
        now: Date = Date(),
        defaults: UserDefaults
    ) -> String? {
        guard let sessionID = defaults.string(forKey: restartDebuggingPendingSessionKey),
              let createdAtMs = (defaults.object(forKey: restartDebuggingPendingCreatedAtKey) as? NSNumber)?
                .doubleValue else {
            return nil
        }

        let createdAt = Date(timeIntervalSince1970: createdAtMs / 1000)
        let ageSeconds = now.timeIntervalSince(createdAt)
        guard ageSeconds >= -5, ageSeconds <= restartDebuggingPendingMaxAgeSeconds else {
            _ = clearRestartDebuggingPending(defaults: defaults)
            return nil
        }

        return sessionID
    }

    private static func makeRestartDebuggingSessionID() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)).lowercased()
    }

    public static func disconnectSuppressionSnapshot(
        now: Date = Date(),
        maxAge: TimeInterval = disconnectSuppressionMaxAgeSeconds,
        defaults: UserDefaults? = nil
    ) -> DisconnectSuppressionSnapshot {
        let defaults = defaults ?? crashRecoveryDefaults()
        let createdAtMs = (defaults.object(forKey: disconnectSuppressionCreatedAtKey) as? NSNumber)?.doubleValue
        guard let createdAtMs else {
            return DisconnectSuppressionSnapshot(
                exists: false,
                ageSeconds: nil,
                withinWindow: false
            )
        }

        let createdAt = Date(timeIntervalSince1970: createdAtMs / 1000)
        let ageSeconds = now.timeIntervalSince(createdAt)
        return DisconnectSuppressionSnapshot(
            exists: true,
            ageSeconds: ageSeconds,
            withinWindow: ageSeconds >= -5 && ageSeconds <= maxAge
        )
    }

    private static func consumePendingCrashRecoveryLaunchSource(
        defaults: UserDefaults? = nil
    ) -> RelaunchSource? {
        let defaults = defaults ?? crashRecoveryDefaults()
        let rawValue = defaults.string(forKey: pendingCrashRecoveryLaunchSourceKey)
        _ = clearPendingCrashRecoveryLaunchSource(defaults: defaults)
        guard let rawValue else { return nil }
        return RelaunchSource(rawValue: rawValue) ?? .unknown
    }

    private static func currentProcessExecutableURL() -> URL? {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        guard size > 0 else { return nil }

        var buffer = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buffer, &size) == 0 else { return nil }
        return URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath()
    }
}

@objc public protocol CrashRecoveryHelperXPCProtocol {
    func arm(reply: @escaping () -> Void)
    func prepareForExpectedExit(reply: @escaping () -> Void)
    func prepareForRelaunch(targetAppPath: String?, reply: @escaping () -> Void)
    func captureWatchdogHangSample(trigger: String, reply: @escaping (String?) -> Void)
}
