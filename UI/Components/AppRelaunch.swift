import CrashRecoverySupport
import Darwin
import Foundation
import Shared

/// Utility for relaunching the app
enum AppRelaunch {
    private static let applicationsPath = "/Applications/Retrace.app"
    private static let terminalApplicationName = "Terminal"

    enum LaunchMode: String {
        case openItem
        case openTerminal
        case executeFile
    }

    /// Relaunch the app from the best available location.
    /// Prefers the current launch target so follow-up work stays on the same build.
    /// Falls back to /Applications/Retrace.app when no launch target can be recovered.
    static func relaunch() {
        relaunch(markAsCrashRecovery: false, crashRecoverySource: nil)
    }

    /// Relaunch the app after an unexpected crash/watchdog-triggered termination.
    static func relaunchForCrashRecovery(
        source: CrashRecoverySupport.RelaunchSource = .watchdogAutoQuit
    ) {
        relaunch(markAsCrashRecovery: true, crashRecoverySource: source)
    }

    private static func relaunch(
        markAsCrashRecovery: Bool,
        crashRecoverySource: CrashRecoverySupport.RelaunchSource?
    ) {
        let currentLaunchTarget = CrashRecoverySupport.currentLaunchTarget()
        let appPath = preferredRelaunchPath(currentLaunchTarget: currentLaunchTarget)

        relaunch(
            atPath: appPath,
            markAsCrashRecovery: markAsCrashRecovery,
            currentLaunchTarget: currentLaunchTarget,
            crashRecoverySource: crashRecoverySource
        )
    }

    static func preferredRelaunchPath(
        currentLaunchTarget: CrashRecoverySupport.LaunchTarget? = nil,
        currentBundlePath: String = Bundle.main.bundlePath,
        currentExecutablePath: String? = Bundle.main.executablePath,
        applicationsAppExists: Bool = FileManager.default.fileExists(atPath: applicationsPath)
    ) -> String {
        if let currentLaunchTarget {
            return currentLaunchTarget.path
        }

        let normalizedBundlePath = currentBundlePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedBundlePath.hasSuffix(".app") {
            return normalizedBundlePath
        }

        if let currentExecutablePath {
            let normalizedExecutablePath = currentExecutablePath.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            if !normalizedExecutablePath.isEmpty {
                return normalizedExecutablePath
            }
        }

        if !normalizedBundlePath.isEmpty {
            return normalizedBundlePath
        }

        if applicationsAppExists {
            return applicationsPath
        }

        if let resourcePath = Bundle.main.resourcePath {
            let derivedPath = URL(fileURLWithPath: resourcePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .path
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !derivedPath.isEmpty {
                return derivedPath
            }
        }

        return applicationsPath
    }

    /// Relaunch the app from a specific path
    static func relaunch(atPath path: String) {
        relaunch(atPath: path, markAsCrashRecovery: false, crashRecoverySource: nil)
    }

    private static func relaunch(
        atPath path: String,
        markAsCrashRecovery: Bool,
        currentLaunchTarget: CrashRecoverySupport.LaunchTarget? = CrashRecoverySupport.currentLaunchTarget(),
        crashRecoverySource: CrashRecoverySupport.RelaunchSource?
    ) {
        let normalizedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let launchMode = launchMode(forPath: normalizedPath)
        Log.info(
            "[AppRelaunch] Relaunching from: \(normalizedPath) mode=\(launchMode.rawValue) crashRecovery=\(markAsCrashRecovery)",
            category: .app
        )

        // Set flag so the new instance skips the single-instance check
        UserDefaults.standard.set(true, forKey: "isRelaunching")
        UserDefaults.standard.synchronize()

        // Remove quarantine attribute that may prevent the app from launching
        removeQuarantineAttribute(atPath: normalizedPath)

        let resolvedLaunchTargetPath: String
        do {
            resolvedLaunchTargetPath = try launchTargetPath(
                forPath: normalizedPath,
                launchMode: launchMode,
                markAsCrashRecovery: markAsCrashRecovery,
                crashRecoverySource: crashRecoverySource
            )
        } catch {
            Log.error(
                "[AppRelaunch] Failed to prepare launch target for \(normalizedPath): \(error)",
                category: .app
            )
            UserDefaults.standard.removeObject(forKey: "isRelaunching")
            return
        }

        if !markAsCrashRecovery && shouldUseBundledHelperForIntentionalRelaunch(
            currentLaunchTarget: currentLaunchTarget
        ) {
            Task { @MainActor in
                let helperPrepared = await CrashRecoveryManager.shared
                    .requestIntentionalRelaunch(targetAppPath: normalizedPath)
                if helperPrepared {
                    Log.info("[AppRelaunch] Relaunch handed off to crash recovery helper", category: .app)
                    Darwin.exit(0)
                } else {
                    fallbackShellRelaunch(
                        atPath: resolvedLaunchTargetPath,
                        launchMode: launchMode,
                        markAsCrashRecovery: false,
                        crashRecoverySource: nil
                    )
                }
            }
            return
        }

        fallbackShellRelaunch(
            atPath: resolvedLaunchTargetPath,
            launchMode: launchMode,
            markAsCrashRecovery: markAsCrashRecovery,
            crashRecoverySource: crashRecoverySource
        )
    }

    static func shouldUseBundledHelperForIntentionalRelaunch(
        currentLaunchTarget: CrashRecoverySupport.LaunchTarget? = CrashRecoverySupport.currentLaunchTarget(),
        isMainThread: Bool = Thread.isMainThread
    ) -> Bool {
        isMainThread && currentLaunchTarget?.isAppBundle == true
    }

    static func launchMode(forPath path: String, isDevBuild: Bool = BuildInfo.isDevBuild) -> LaunchMode {
        if path.hasSuffix(".app") {
            return .openItem
        }

        var isDirectory = ObjCBool(false)
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            return .openItem
        }

        if isDevBuild && isDebugExecutablePath(path) {
            return .openTerminal
        }

        return .executeFile
    }

    static func terminalLauncherScriptContents(forExecutablePath path: String) -> String {
        terminalLauncherScriptContents(forExecutablePath: path, arguments: [])
    }

    private static func terminalLauncherScriptContents(
        forExecutablePath path: String,
        arguments: [String]
    ) -> String {
        let command = ([shellQuoted(path)] + arguments.map(shellQuoted)).joined(separator: " ")
        return """
        #!/bin/zsh
        rm -f -- "$0"
        exec \(command)
        """
    }

    private static func removeQuarantineAttribute(atPath path: String) {
        let task = Process()
        task.launchPath = "/usr/bin/xattr"
        task.arguments = ["-dr", "com.apple.quarantine", path]
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            // Ignore - quarantine removal is not critical
        }
    }

    private static func launchTargetPath(
        forPath path: String,
        launchMode: LaunchMode,
        markAsCrashRecovery: Bool,
        crashRecoverySource: CrashRecoverySupport.RelaunchSource?
    ) throws -> String {
        switch launchMode {
        case .openItem, .executeFile:
            return path
        case .openTerminal:
            let arguments = markAsCrashRecovery
                ? CrashRecoverySupport.crashRecoveryLaunchArguments(source: crashRecoverySource)
                : []
            return try createTerminalLauncherScript(forExecutablePath: path, arguments: arguments)
        }
    }

    private static func createTerminalLauncherScript(
        forExecutablePath path: String,
        arguments: [String]
    ) throws -> String {
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("retrace-relaunch-\(UUID().uuidString).command")
        try terminalLauncherScriptContents(forExecutablePath: path, arguments: arguments)
            .write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int(0o755))],
            ofItemAtPath: scriptURL.path
        )
        return scriptURL.path
    }

    private static func isDebugExecutablePath(_ path: String) -> Bool {
        let normalizedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalizedPath.contains("/.build/") && normalizedPath.contains("/debug/")
    }

    static func fallbackLaunchCommand(
        atPath path: String,
        markAsCrashRecovery: Bool,
        crashRecoverySource: CrashRecoverySupport.RelaunchSource? = nil
    ) -> String {
        let quotedPath = shellQuoted(path)
        let crashRecoveryArguments = CrashRecoverySupport.crashRecoveryLaunchArguments(
            source: crashRecoverySource
        )
            .joined(separator: " ")
        if path.hasSuffix(".app") {
            if markAsCrashRecovery {
                return "open \(quotedPath) --args \(crashRecoveryArguments)"
            }
            return "open \(quotedPath)"
        }

        if markAsCrashRecovery {
            return "\(quotedPath) \(crashRecoveryArguments)"
        }
        return quotedPath
    }

    @discardableResult
    static func prepareDisconnectSuppressionForShellFallback(
        defaults: UserDefaults? = nil
    ) -> Bool {
        CrashRecoverySupport.storeDisconnectSuppression(defaults: defaults)
    }

    private static func fallbackShellRelaunch(
        atPath path: String,
        launchMode: LaunchMode,
        markAsCrashRecovery: Bool,
        crashRecoverySource: CrashRecoverySupport.RelaunchSource?
    ) {
        // Fallback for environments where the bundled helper is unavailable or the main actor is unavailable.
        let launchCommand = fallbackLaunchCommand(
            atPath: path,
            launchMode: launchMode,
            markAsCrashRecovery: markAsCrashRecovery,
            crashRecoverySource: crashRecoverySource
        )

        let script = """
            sleep 1
            \(launchCommand)
            """

        let task = Process()
        task.launchPath = "/bin/bash"
        task.arguments = ["-c", script]
        let preparedHelperSuppression = prepareDisconnectSuppressionForShellFallback()

        do {
            try task.run()
            Log.info("[AppRelaunch] Terminating for relaunch via shell fallback", category: .app)
            Darwin.exit(0)
        } catch {
            if preparedHelperSuppression {
                _ = CrashRecoverySupport.clearDisconnectSuppression()
            }
            if markAsCrashRecovery {
                _ = CrashRecoverySupport.clearPendingCrashRecoveryLaunchSource()
            }
            Log.error("[AppRelaunch] Failed to start fallback launch script: \(error)", category: .app)
            UserDefaults.standard.removeObject(forKey: "isRelaunching")
        }
    }

    private static func fallbackLaunchCommand(
        atPath path: String,
        launchMode: LaunchMode,
        markAsCrashRecovery: Bool,
        crashRecoverySource: CrashRecoverySupport.RelaunchSource?
    ) -> String {
        switch launchMode {
        case .openItem:
            return fallbackLaunchCommand(
                atPath: path,
                markAsCrashRecovery: markAsCrashRecovery,
                crashRecoverySource: crashRecoverySource
            )
        case .openTerminal:
            return "open -a \(shellQuoted(terminalApplicationName)) \(shellQuoted(path))"
        case .executeFile:
            return fallbackLaunchCommand(
                atPath: path,
                markAsCrashRecovery: markAsCrashRecovery,
                crashRecoverySource: crashRecoverySource
            )
        }
    }

    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
