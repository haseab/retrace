import AppKit

/// Utility to prompt users to move the app to /Applications folder
/// Based on LetsMove/AppMover concepts - only works for non-sandboxed apps
enum AppMover {

    private static let applicationsPath = "/Applications"

    /// Check if app is already in /Applications and prompt to move if not
    static func moveToApplicationsFolderIfNecessary() {
        // Skip in debug builds (running from .build/debug)
        #if DEBUG
        return
        #else
        guard let bundlePath = Bundle.main.bundlePath as NSString? else { return }

        // Check if already in /Applications
        if bundlePath.deletingLastPathComponent == applicationsPath {
            return
        }

        // Check if already in ~/Applications
        let userApplications = NSHomeDirectory() + "/Applications"
        if bundlePath.deletingLastPathComponent == userApplications {
            return
        }

        // Show move dialog
        promptToMove()
        #endif
    }

    private static func promptToMove() {
        let alert = NSAlert()
        alert.messageText = "Move to Applications folder?"
        alert.informativeText = "Retrace works best when run from the Applications folder. Would you like to move it there now?"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Don't Move")

        let response = alert.runModal()

        if response == .alertFirstButtonReturn {
            moveToApplicationsFolder()
        }
    }

    private static func moveToApplicationsFolder() {
        guard let bundlePath = Bundle.main.bundlePath as NSString? else { return }
        let appName = bundlePath.lastPathComponent
        let destinationPath = "\(applicationsPath)/\(appName)"

        let fileManager = FileManager.default

        // Check if app already exists in Applications
        if fileManager.fileExists(atPath: destinationPath) {
            let alert = NSAlert()
            alert.messageText = "Replace existing app?"
            alert.informativeText = "A version of Retrace already exists in the Applications folder. Do you want to replace it?"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Replace")
            alert.addButton(withTitle: "Cancel")

            if alert.runModal() != .alertFirstButtonReturn {
                return
            }

            // Remove existing app
            do {
                try fileManager.removeItem(atPath: destinationPath)
            } catch {
                showError("Failed to remove existing app: \(error.localizedDescription)")
                return
            }
        }

        // Copy app to Applications
        do {
            try fileManager.copyItem(atPath: bundlePath as String, toPath: destinationPath)
        } catch {
            showError("Failed to copy app: \(error.localizedDescription)")
            return
        }

        // Relaunch from new location
        relaunch(atPath: destinationPath)
    }

    private static func relaunch(atPath path: String) {
        let task = Process()
        task.launchPath = "/usr/bin/open"
        task.arguments = [path]

        do {
            try task.run()
            // Give the new instance time to start
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                NSApp.terminate(nil)
            }
        } catch {
            showError("Failed to relaunch: \(error.localizedDescription)")
        }
    }

    private static func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Move Failed"
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
