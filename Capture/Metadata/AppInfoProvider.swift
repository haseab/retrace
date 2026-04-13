import Foundation
import AppKit
import ApplicationServices
import Shared

/// Provides information about the currently active application
struct AppInfoProvider: Sendable {

    private struct VisibleWindowContext: Sendable {
        let pid: pid_t
        let bundleID: String?
        let appName: String?
        let windowName: String?
    }

    // MARK: - App Info Retrieval

    /// Get information about the frontmost application
    /// - Returns: FrameMetadata with app info, or minimal metadata if unavailable
    /// - Parameters:
    ///   - includeBrowserURL: Whether browser URL extraction should run (can be expensive)
    ///   - preferredDisplayID: Optional display ID used to pick the topmost visible window on that display first
    func getFrontmostAppInfo(
        includeBrowserURL: Bool = true,
        preferredDisplayID: CGDirectDisplayID? = nil
    ) async -> FrameMetadata {
        let displayID = preferredDisplayID ?? CGMainDisplayID()
        // Prefer top-most visible window metadata from CGWindowList to keep app/window
        // context aligned with the captured pixels, especially during rapid app switches.
        if let visibleWindow = getTopVisibleWindowContext(preferredDisplayID: preferredDisplayID) {
            var bundleID = visibleWindow.bundleID
            var appName = visibleWindow.appName

            if bundleID == nil && visibleWindow.pid == ProcessInfo.processInfo.processIdentifier {
                bundleID = Bundle.main.bundleIdentifier ?? "io.retrace.app"
                appName = appName ?? "Retrace"
            }

            let windowName = visibleWindow.windowName ?? getWindowTitle(
                for: visibleWindow.pid,
                bundleID: bundleID,
                appName: appName
            )

            let browserURL = await resolveBrowserURL(
                includeBrowserURL: includeBrowserURL,
                pid: visibleWindow.pid,
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

        // Fallback to NSWorkspace frontmost app if no qualifying on-screen window was found.
        guard let frontApp = await MainActor.run(body: {
            NSWorkspace.shared.frontmostApplication
        }) else {
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
            appName: appName
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

    /// Get the title of the focused window.
    /// Uses AX first, then falls back to CGWindow metadata for apps/PWAs that
    /// omit AXTitle on their focused window.
    /// - Parameters:
    ///   - pid: Process ID of the application
    ///   - bundleID: App bundle ID (used for PWA-specific fallback behavior)
    ///   - appName: App display name
    /// - Returns: Window title if available
    private func getWindowTitle(for pid: pid_t, bundleID: String?, appName: String?) -> String? {
        // Avoid AX reads against our own process; use lightweight fallbacks instead.
        if pid == ProcessInfo.processInfo.processIdentifier {
            if let title = getWindowTitleFromWindowList(for: pid) {
                return title
            }
            return normalizedWindowTitle(appName)
        }

        // 1) AX focused-window title
        if let title = normalizedWindowTitle(PermissionMonitor.shared.safeGetWindowTitle(for: pid)) {
            return title
        }

        // 2) CGWindow fallback (works for many PWA-style windows)
        if let title = getWindowTitleFromWindowList(for: pid) {
            return title
        }

        // 3) Last-resort fallback for app-shim PWAs
        if let bundleID = bundleID,
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

    /// Find the top-most visible layer-0 window context from CGWindowList.
    /// The returned window order is front-to-back.
    private func getTopVisibleWindowContext(preferredDisplayID: CGDirectDisplayID?) -> VisibleWindowContext? {
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }

        let preferredDisplayBounds = preferredDisplayID.map(CGDisplayBounds)

        for windowInfo in windowList {
            guard isCandidateTopWindow(windowInfo, preferredDisplayBounds: preferredDisplayBounds),
                  let pid = windowInfo[kCGWindowOwnerPID as String] as? pid_t else {
                continue
            }

            let ownerName = normalizedWindowTitle(windowInfo[kCGWindowOwnerName as String] as? String)
            let windowName = normalizedWindowTitle(windowInfo[kCGWindowName as String] as? String)
            let runningApp = NSRunningApplication(processIdentifier: pid)
            let appName = normalizedWindowTitle(runningApp?.localizedName) ?? ownerName
            let bundleID = runningApp?.bundleIdentifier

            return VisibleWindowContext(
                pid: pid,
                bundleID: bundleID,
                appName: appName,
                windowName: windowName
            )
        }

        return nil
    }

    private func isCandidateTopWindow(_ windowInfo: [String: Any], preferredDisplayBounds: CGRect?) -> Bool {
        let layer = windowInfo[kCGWindowLayer as String] as? Int ?? 0
        guard layer == 0 else { return false }

        let alpha = windowInfo[kCGWindowAlpha as String] as? Double ?? 0
        guard alpha > 0 else { return false }

        let isOnScreen = windowInfo[kCGWindowIsOnscreen as String] as? Bool ?? false
        guard isOnScreen else { return false }

        guard let bounds = windowBounds(from: windowInfo) else {
            return false
        }

        if let preferredDisplayBounds, !bounds.intersects(preferredDisplayBounds) {
            return false
        }

        return true
    }

    private func windowBounds(from windowInfo: [String: Any]) -> CGRect? {
        guard let boundsDict = windowInfo[kCGWindowBounds as String] as? [String: Any],
              let x = boundsDict["X"] as? CGFloat,
              let y = boundsDict["Y"] as? CGFloat,
              let width = boundsDict["Width"] as? CGFloat,
              let height = boundsDict["Height"] as? CGFloat,
              width > 1,
              height > 1 else {
            return nil
        }

        return CGRect(x: x, y: y, width: width, height: height)
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

    /// Fallback title extraction via CoreGraphics window list.
    /// Uses front-to-back ordering returned by CGWindowListCopyWindowInfo.
    private func getWindowTitleFromWindowList(for pid: pid_t) -> String? {
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }

        for windowInfo in windowList {
            guard let ownerPID = windowInfo[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID == pid else {
                continue
            }

            // Layer 0: normal app windows
            let layer = windowInfo[kCGWindowLayer as String] as? Int ?? 0
            if layer != 0 {
                continue
            }

            let isOnScreen = windowInfo[kCGWindowIsOnscreen as String] as? Bool ?? false
            if !isOnScreen {
                continue
            }

            if let title = normalizedWindowTitle(windowInfo[kCGWindowName as String] as? String) {
                return title
            }
        }

        return nil
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
