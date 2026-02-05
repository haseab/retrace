import AppKit
import Shared

/// Utility to prompt users to move the app to /Applications folder
/// Based on LetsMove/AppMover concepts - only works for non-sandboxed apps
enum AppMover {

    private static let applicationsPath = "/Applications"

    /// Check if app is already in /Applications and prompt to move if not
    static func moveToApplicationsFolderIfNecessary() {
        // Skip in debug builds (running from .build/debug)
        #if DEBUG
        Log.debug("[AppMover] Skipping move check - DEBUG build", category: .app)
        return
        #else
        Log.info("[AppMover] Checking if app needs to move to Applications folder", category: .app)

        guard let bundlePath = Bundle.main.bundlePath as NSString? else {
            Log.error("[AppMover] Failed to get bundle path", category: .app)
            return
        }

        Log.info("[AppMover] Current bundle path: \(bundlePath)", category: .app)
        Log.info("[AppMover] Parent directory: \(bundlePath.deletingLastPathComponent)", category: .app)

        // Check if already in /Applications
        if bundlePath.deletingLastPathComponent == applicationsPath {
            Log.info("[AppMover] Already in /Applications - no move needed", category: .app)
            return
        }

        // Check if already in ~/Applications
        let userApplications = NSHomeDirectory() + "/Applications"
        Log.debug("[AppMover] User Applications path: \(userApplications)", category: .app)
        if bundlePath.deletingLastPathComponent == userApplications {
            Log.info("[AppMover] Already in ~/Applications - no move needed", category: .app)
            return
        }

        Log.info("[AppMover] App is not in Applications folder - prompting user to move", category: .app)
        // Show move dialog
        promptToMove()
        #endif
    }

    private static func promptToMove() {
        Log.debug("[AppMover] Showing move prompt dialog", category: .app)

        let alert = NSAlert()
        alert.messageText = "Move to Applications folder?"
        alert.informativeText = "Retrace works best when run from the Applications folder. Would you like to move it there now?"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Don't Move")

        let response = alert.runModal()
        Log.info("[AppMover] User response to move prompt: \(response == .alertFirstButtonReturn ? "Move" : "Don't Move")", category: .app)

        if response == .alertFirstButtonReturn {
            moveToApplicationsFolder()
        } else {
            Log.info("[AppMover] User chose not to move app", category: .app)
        }
    }

    private static func moveToApplicationsFolder() {
        Log.info("[AppMover] Starting move to Applications folder", category: .app)

        guard let bundlePath = Bundle.main.bundlePath as NSString? else {
            Log.error("[AppMover] Failed to get bundle path for move", category: .app)
            return
        }
        let appName = bundlePath.lastPathComponent
        let destinationPath = "\(applicationsPath)/\(appName)"

        Log.info("[AppMover] Source path: \(bundlePath)", category: .app)
        Log.info("[AppMover] Destination path: \(destinationPath)", category: .app)

        let fileManager = FileManager.default

        // Check if app already exists in Applications
        if fileManager.fileExists(atPath: destinationPath) {
            Log.info("[AppMover] Existing app found at destination - prompting for replace", category: .app)

            let alert = NSAlert()
            alert.messageText = "Replace existing app?"
            alert.informativeText = "A version of Retrace already exists in the Applications folder. Do you want to replace it?"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Replace")
            alert.addButton(withTitle: "Cancel")

            let replaceResponse = alert.runModal()
            Log.info("[AppMover] User response to replace prompt: \(replaceResponse == .alertFirstButtonReturn ? "Replace" : "Cancel")", category: .app)

            if replaceResponse != .alertFirstButtonReturn {
                Log.info("[AppMover] User cancelled replace - aborting move", category: .app)
                return
            }

            // Remove existing app
            Log.info("[AppMover] Removing existing app at: \(destinationPath)", category: .app)
            do {
                try fileManager.removeItem(atPath: destinationPath)
                Log.info("[AppMover] Successfully removed existing app", category: .app)
            } catch {
                Log.error("[AppMover] Failed to remove existing app: \(error)", category: .app)
                showError("Failed to remove existing app: \(error.localizedDescription)")
                return
            }
        }

        // Copy app to Applications
        Log.info("[AppMover] Copying app to Applications folder", category: .app)
        Log.debug("[AppMover] Copy source: \(bundlePath)", category: .app)
        Log.debug("[AppMover] Copy destination: \(destinationPath)", category: .app)

        do {
            try fileManager.copyItem(atPath: bundlePath as String, toPath: destinationPath)
            Log.info("[AppMover] Successfully copied app to Applications folder", category: .app)
        } catch {
            Log.error("[AppMover] Failed to copy app: \(error)", category: .app)
            showError("Failed to copy app: \(error.localizedDescription)")
            return
        }

        // Verify copy succeeded
        if fileManager.fileExists(atPath: destinationPath) {
            Log.info("[AppMover] Verified: app exists at destination path", category: .app)
        } else {
            Log.error("[AppMover] Verification failed: app NOT found at destination path after copy", category: .app)
            showError("Failed to verify app was copied successfully")
            return
        }

        // Relaunch from new location
        Log.info("[AppMover] Initiating relaunch from new location", category: .app)
        relaunch(atPath: destinationPath)
    }

    private static func relaunch(atPath path: String) {
        Log.info("[AppMover] Relaunching app from: \(path)", category: .app)

        // Remove quarantine attribute that may prevent the app from launching
        Log.debug("[AppMover] Removing quarantine attribute from: \(path)", category: .app)
        let quarantineTask = Process()
        quarantineTask.launchPath = "/usr/bin/xattr"
        quarantineTask.arguments = ["-dr", "com.apple.quarantine", path]
        do {
            try quarantineTask.run()
            quarantineTask.waitUntilExit()
            Log.info("[AppMover] Quarantine attribute removal completed with exit code: \(quarantineTask.terminationStatus)", category: .app)
        } catch {
            Log.warning("[AppMover] Failed to remove quarantine attribute: \(error) - continuing anyway", category: .app)
        }

        let task = Process()
        task.launchPath = "/usr/bin/open"
        task.arguments = [path]

        Log.debug("[AppMover] Launch command: /usr/bin/open \(path)", category: .app)

        do {
            try task.run()
            Log.info("[AppMover] Successfully started new instance - process launched", category: .app)
            Log.info("[AppMover] Waiting 0.5s before terminating current instance", category: .app)

            // Give the new instance time to start
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                Log.info("[AppMover] Terminating current instance now", category: .app)
                NSApp.terminate(nil)
            }
        } catch {
            Log.error("[AppMover] Failed to relaunch: \(error)", category: .app)
            showError("Failed to relaunch: \(error.localizedDescription)")
        }
    }

    private static func showError(_ message: String) {
        Log.error("[AppMover] Showing error to user: \(message)", category: .app)

        let alert = NSAlert()
        alert.messageText = "Move Failed"
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.addButton(withTitle: "OK")
        alert.runModal()

        Log.debug("[AppMover] User dismissed error dialog", category: .app)
    }
}
