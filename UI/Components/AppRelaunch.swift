import AppKit
import Shared

/// Utility for relaunching the app
enum AppRelaunch {

    /// Relaunch the app from the best available location.
    /// Prefers /Applications/Retrace.app if it exists, otherwise uses current bundle path.
    static func relaunch() {
        let applicationsPath = "/Applications/Retrace.app"
        let appPath: String

        if FileManager.default.fileExists(atPath: applicationsPath) {
            appPath = applicationsPath
        } else {
            let url = URL(fileURLWithPath: Bundle.main.resourcePath!)
            appPath = url.deletingLastPathComponent().deletingLastPathComponent().path
        }

        relaunch(atPath: appPath)
    }

    /// Relaunch the app from a specific path
    static func relaunch(atPath path: String) {
        Log.info("[AppRelaunch] Relaunching from: \(path)", category: .app)

        // Set flag so the new instance skips the single-instance check
        UserDefaults.standard.set(true, forKey: "isRelaunching")
        UserDefaults.standard.synchronize()

        // Remove quarantine attribute that may prevent the app from launching
        removeQuarantineAttribute(atPath: path)

        // We must terminate BEFORE launching, because macOS won't create a new instance
        // of an app with the same bundle ID that's already running.
        // Use a shell script to launch the app after we exit.
        let script = """
            sleep 1
            open "\(path)"
            """

        let task = Process()
        task.launchPath = "/bin/bash"
        task.arguments = ["-c", script]

        do {
            try task.run()
            Log.info("[AppRelaunch] Terminating for relaunch", category: .app)
            exit(0)
        } catch {
            Log.error("[AppRelaunch] Failed to start launch script: \(error)", category: .app)
            UserDefaults.standard.removeObject(forKey: "isRelaunching")
        }
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
}
