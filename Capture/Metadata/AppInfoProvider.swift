import Foundation
import AppKit
import ApplicationServices
import Shared

/// Provides information about the currently active application
struct AppInfoProvider: Sendable {

    // MARK: - App Info Retrieval

    /// Get information about the frontmost application
    /// - Returns: FrameMetadata with app info, or minimal metadata if unavailable
    /// - Parameters:
    ///   - includeBrowserURL: Whether browser URL extraction should run (can be expensive)
    ///   - preferredDisplayID: Optional display ID used to select the foreground app window on that display
    func getFrontmostAppInfo(
        includeBrowserURL: Bool = true,
        preferredDisplayID: CGDirectDisplayID? = nil
    ) async -> FrameMetadata {
        let displayID = preferredDisplayID ?? CGMainDisplayID()
        guard let frontApp = await MainActor.run(body: {
            NSWorkspace.shared.frontmostApplication
        }) else {
            return FrameMetadata(displayID: displayID)
        }

        guard !ForegroundWindowSelection.isComputerUse(bundleID: frontApp.bundleIdentifier) else {
            return FrameMetadata(displayID: displayID)
        }

        var bundleID = frontApp.bundleIdentifier
        var appName = frontApp.localizedName

        if bundleID == nil && frontApp.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            bundleID = Bundle.main.bundleIdentifier ?? "io.retrace.app"
            appName = appName ?? "Retrace"
        }

        let windowName = getWindowTitle(
            for: frontApp.processIdentifier,
            bundleID: bundleID,
            appName: appName,
            preferredDisplayID: preferredDisplayID
        )

        let browserURL = await resolveBrowserURL(
            includeBrowserURL: includeBrowserURL,
            pid: frontApp.processIdentifier,
            bundleID: bundleID,
            appName: appName,
            windowName: windowName
        )

        let metadata = FrameMetadata(
            appBundleID: bundleID,
            appName: appName,
            windowName: windowName,
            browserURL: browserURL,
            displayID: displayID
        )
        return metadata
    }

    // MARK: - Private Helpers

    private func getWindowTitle(
        for pid: pid_t,
        bundleID: String?,
        appName: String?,
        preferredDisplayID: CGDirectDisplayID?
    ) -> String? {
        if let title = getWindowTitleFromWindowList(
            for: pid,
            bundleID: bundleID,
            preferredDisplayID: preferredDisplayID
        ) {
            return title
        }

        if pid == ProcessInfo.processInfo.processIdentifier {
            return normalizedWindowTitle(appName)
        }

        if let title = normalizedWindowTitle(PermissionMonitor.shared.safeGetWindowTitle(for: pid)) {
            let isSharingIndicator = title == "Window" && PermissionMonitor.shared.safeGetWindowFrame(for: pid).map {
                ForegroundWindowSelection.isSharingIndicator(title: title, size: $0.size)
            } == true
            if !isSharingIndicator {
                return title
            }
        }

        if let bundleID,
           bundleID.hasPrefix("com.google.Chrome.app."),
           let appName = normalizedWindowTitle(appName) {
            return appName
        }

        return nil
    }

    private func normalizedWindowTitle(_ title: String?) -> String? {
        guard let title = title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else {
            return nil
        }
        return title
    }

    private func resolveBrowserURL(
        includeBrowserURL: Bool,
        pid: pid_t,
        bundleID: String?,
        appName: String?,
        windowName: String?
    ) async -> String? {
        guard includeBrowserURL,
              pid != ProcessInfo.processInfo.processIdentifier,
              let bundleID,
              (BrowserURLExtractor.isBrowser(bundleID) || bundleID == "com.apple.finder") else {
            return nil
        }

        let urlExtractionStart = CFAbsoluteTimeGetCurrent()
        let browserURL = await BrowserURLExtractor.getURL(
            bundleID: bundleID,
            pid: pid,
            windowCacheKey: windowName ?? appName
        )
        let elapsedMs = (CFAbsoluteTimeGetCurrent() - urlExtractionStart) * 1000
        if elapsedMs >= 250 {
            Log.warning(
                "[AppInfoProvider] Slow browser URL extraction bundle=\(bundleID), pid=\(pid), elapsed=\(String(format: "%.1f", elapsedMs))ms, foundURL=\(browserURL != nil)",
                category: .capture
            )
        } else if elapsedMs >= 120 {
            Log.debug(
                "[AppInfoProvider] Browser URL extraction bundle=\(bundleID), pid=\(pid), elapsed=\(String(format: "%.1f", elapsedMs))ms, foundURL=\(browserURL != nil)",
                category: .capture
            )
        }
        return browserURL
    }

    private func getWindowTitleFromWindowList(
        for pid: pid_t,
        bundleID: String?,
        preferredDisplayID: CGDirectDisplayID?
    ) -> String? {
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }

        let displayBounds = preferredDisplayID.map(CGDisplayBounds)
        guard let window = windowList.first(where: {
            ForegroundWindowSelection.isEligible(
                $0,
                foregroundPID: pid,
                bundleID: bundleID,
                displayBounds: displayBounds
            )
        }) else {
            return nil
        }

        return normalizedWindowTitle(window[kCGWindowName as String] as? String)
    }

    /// Check if accessibility permissions are granted
    /// Uses the central PermissionMonitor for consistent checking
    static func hasAccessibilityPermission() -> Bool {
        return PermissionMonitor.shared.hasAccessibilityPermission()
    }

    /// Request accessibility permission (shows system dialog)
    static func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }
}
