import AppKit
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
    /// Uses the currently running app bundle so restart flows preserve the active build.
    /// Falls back to /Applications/Retrace.app only if the current bundle path is unavailable.
    static func relaunch() {
        relaunch(atPath: preferredRelaunchPath())
    }

    static func preferredRelaunchPath(
        currentBundlePath: String = Bundle.main.bundlePath,
        currentExecutablePath: String? = Bundle.main.executablePath,
        applicationsAppExists: Bool = FileManager.default.fileExists(atPath: applicationsPath)
    ) -> String {
        let normalizedBundlePath = currentBundlePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedBundlePath.hasSuffix(".app") {
            return normalizedBundlePath
        }

        if let currentExecutablePath {
            let normalizedExecutablePath = currentExecutablePath.trimmingCharacters(in: .whitespacesAndNewlines)
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
        let normalizedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let launchMode = launchMode(forPath: normalizedPath)
        Log.info("[AppRelaunch] Relaunching from: \(normalizedPath) mode=\(launchMode.rawValue)", category: .app)

        // Set flag so the new instance skips the single-instance check
        UserDefaults.standard.set(true, forKey: "isRelaunching")
        UserDefaults.standard.synchronize()

        // Remove quarantine attribute that may prevent the app from launching
        removeQuarantineAttribute(atPath: normalizedPath)

        let resolvedLaunchTargetPath: String
        do {
            resolvedLaunchTargetPath = try launchTargetPath(forPath: normalizedPath, launchMode: launchMode)
        } catch {
            Log.error("[AppRelaunch] Failed to prepare launch target for \(normalizedPath): \(error)", category: .app)
            UserDefaults.standard.removeObject(forKey: "isRelaunching")
            return
        }

        // We must terminate BEFORE launching, because macOS won't create a new instance
        // of an app with the same bundle ID that's already running.
        // Use a shell script to launch the app after we exit.
        let script = """
            sleep 1
            if [ "$1" = "openItem" ]; then
                open "$2"
            elif [ "$1" = "openTerminal" ]; then
                open -a "\(terminalApplicationName)" "$2"
            else
                nohup "$2" >/dev/null 2>&1 &
            fi
            """

        let task = Process()
        task.launchPath = "/bin/bash"
        task.arguments = ["-c", script, "--", launchMode.rawValue, resolvedLaunchTargetPath]

        do {
            try task.run()
            Log.info("[AppRelaunch] Terminating for relaunch", category: .app)
            exit(0)
        } catch {
            Log.error("[AppRelaunch] Failed to start launch script: \(error)", category: .app)
            UserDefaults.standard.removeObject(forKey: "isRelaunching")
        }
    }

    static func launchMode(forPath path: String, isDevBuild: Bool = BuildInfo.isDevBuild) -> LaunchMode {
        if path.hasSuffix(".app") {
            return .openItem
        }

        var isDirectory = ObjCBool(false)
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
            return .openItem
        }

        if isDevBuild && isDebugExecutablePath(path) {
            return .openTerminal
        }

        return .executeFile
    }

    static func terminalLauncherScriptContents(forExecutablePath path: String) -> String {
        """
        #!/bin/zsh
        rm -f -- "$0"
        exec \(shellQuoted(path))
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

    private static func launchTargetPath(forPath path: String, launchMode: LaunchMode) throws -> String {
        switch launchMode {
        case .openItem, .executeFile:
            return path
        case .openTerminal:
            return try createTerminalLauncherScript(forExecutablePath: path)
        }
    }

    private static func createTerminalLauncherScript(forExecutablePath path: String) throws -> String {
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("retrace-relaunch-\(UUID().uuidString).command")
        try terminalLauncherScriptContents(forExecutablePath: path)
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

    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
