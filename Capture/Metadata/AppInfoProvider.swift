import Foundation
import AppKit
import ApplicationServices
import Shared

/// Provides information about the currently active application
struct AppInfoProvider: Sendable {

    private static let browserURLAttachmentService = BrowserURLAttachmentService()

    private struct FrontmostAppSnapshot: Sendable {
        let pid: pid_t
        let bundleID: String?
        let appName: String?
    }

    // MARK: - Constants

    /// Known browser bundle identifiers for URL extraction (references shared list)
    static var browserBundleIDs: Set<String> { AppInfo.browserBundleIDs }

    // MARK: - App Info Retrieval

    /// Get information about the frontmost application
    /// - Returns: FrameMetadata with app info, or minimal metadata if unavailable
    ///
    /// Metadata strategy:
    /// 1) AX call #1 (fast): capture focused window title aligned with this frame.
    /// 2) AX call #2 (heavier): fetch browser URL asynchronously and attach later via cache.
    func getFrontmostAppInfo(frameTimestamp: Date) async -> FrameMetadata {
        guard let frontApp = await getFrontmostAppSnapshot() else {
            return FrameMetadata(displayID: CGMainDisplayID())
        }

        // AX call #1 (match screenshot context): focused window title
        let windowName = getWindowTitle(for: frontApp.pid)

        // AX call #2 (deferred): browser URL extraction is intentionally decoupled.
        // We use the freshest attached URL from cache and schedule a background refresh.
        var browserURL: String? = nil
        if let bundleID = frontApp.bundleID,
           Self.browserBundleIDs.contains(bundleID) {
            browserURL = await Self.browserURLAttachmentService.cachedURL(
                bundleID: bundleID,
                pid: frontApp.pid,
                windowName: windowName,
                frameTimestamp: frameTimestamp
            )
            await Self.browserURLAttachmentService.scheduleRefreshIfNeeded(
                bundleID: bundleID,
                pid: frontApp.pid,
                windowName: windowName
            )
        }

        return FrameMetadata(
            appBundleID: frontApp.bundleID,
            appName: frontApp.appName,
            windowName: windowName,
            browserURL: browserURL,
            displayID: CGMainDisplayID()
        )
    }

    func getFrontmostAppInfo() async -> FrameMetadata {
        await getFrontmostAppInfo(frameTimestamp: Date())
    }

    /// Get lightweight context for window-change handling without browser URL extraction.
    func getFrontmostWindowContext() async -> (appBundleID: String?, windowName: String?) {
        guard let frontApp = await getFrontmostAppSnapshot() else {
            return (nil, nil)
        }
        let windowName = getWindowTitle(for: frontApp.pid)
        return (frontApp.bundleID, windowName)
    }

    // MARK: - Private Helpers

    private func getFrontmostAppSnapshot() async -> FrontmostAppSnapshot? {
        await MainActor.run {
            // Get frontmost app from NSWorkspace
            guard let frontApp = NSWorkspace.shared.frontmostApplication else {
                return nil
            }

            // Use bundleIdentifier if available, otherwise check if it's the current app (dev build)
            var bundleID = frontApp.bundleIdentifier
            var appName = frontApp.localizedName

            // Dev build fix: if bundleID is nil but this is Retrace (same PID), use known bundle ID
            if bundleID == nil && frontApp.processIdentifier == ProcessInfo.processInfo.processIdentifier {
                bundleID = Bundle.main.bundleIdentifier ?? "io.retrace.app"
                appName = appName ?? "Retrace"
            }

            return FrontmostAppSnapshot(
                pid: frontApp.processIdentifier,
                bundleID: bundleID,
                appName: appName
            )
        }
    }

    /// Get the title of the focused window using Accessibility API
    /// Uses safe wrappers to prevent crashes if permissions are revoked
    /// - Parameter pid: Process ID of the application
    /// - Returns: Window title if available
    private func getWindowTitle(for pid: pid_t) -> String? {
        // Use safe wrapper that checks permissions first
        return PermissionMonitor.shared.safeGetWindowTitle(for: pid)
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

private actor BrowserURLAttachmentService {
    private struct CacheEntry: Sendable {
        let bundleID: String
        let windowName: String?
        let url: String
        let fetchedAt: Date
    }

    private var cacheByPID: [pid_t: CacheEntry] = [:]
    private var inFlightPIDs: Set<pid_t> = []
    private var lastScheduledByPID: [pid_t: Date] = [:]

    private let minRefreshSpacing: TimeInterval = 0.5

    func cachedURL(
        bundleID: String,
        pid: pid_t,
        windowName: String?,
        frameTimestamp: Date
    ) -> String? {
        guard let entry = cacheByPID[pid] else { return nil }
        guard entry.bundleID == bundleID else { return nil }
        guard entry.windowName == windowName else { return nil }
        return entry.url
    }

    func scheduleRefreshIfNeeded(bundleID: String, pid: pid_t, windowName: String?) {
        if inFlightPIDs.contains(pid) {
            return
        }

        let now = Date()
        if let lastScheduled = lastScheduledByPID[pid],
           now.timeIntervalSince(lastScheduled) < minRefreshSpacing {
            return
        }

        inFlightPIDs.insert(pid)
        lastScheduledByPID[pid] = now

        Task.detached(priority: .utility) {
            let url = await BrowserURLExtractor.getURL(bundleID: bundleID, pid: pid)
            await self.finishRefresh(pid: pid, bundleID: bundleID, windowName: windowName, url: url)
        }
    }

    private func finishRefresh(pid: pid_t, bundleID: String, windowName: String?, url: String?) async {
        defer { inFlightPIDs.remove(pid) }

        guard let url, !url.isEmpty else {
            return
        }

        // Revalidate context after the slow URL fetch. If app/window focus changed while
        // fetching, we drop the URL instead of attaching stale metadata.
        guard await contextStillMatchesRequest(
            pid: pid,
            bundleID: bundleID,
            windowName: windowName
        ) else {
            return
        }

        cacheByPID[pid] = CacheEntry(
            bundleID: bundleID,
            windowName: windowName,
            url: url,
            fetchedAt: Date()
        )
    }

    private func contextStillMatchesRequest(pid: pid_t, bundleID: String, windowName: String?) async -> Bool {
        guard let frontApp = await frontmostAppSnapshot() else {
            return false
        }
        guard frontApp.pid == pid else {
            return false
        }
        guard frontApp.bundleID == bundleID else {
            return false
        }

        let currentWindowName = PermissionMonitor.shared.safeGetWindowTitle(for: pid)
        return currentWindowName == windowName
    }

    private func frontmostAppSnapshot() async -> (pid: pid_t, bundleID: String?)? {
        await MainActor.run {
            guard let frontApp = NSWorkspace.shared.frontmostApplication else {
                return nil
            }

            var bundleID = frontApp.bundleIdentifier
            if bundleID == nil && frontApp.processIdentifier == ProcessInfo.processInfo.processIdentifier {
                bundleID = Bundle.main.bundleIdentifier ?? "io.retrace.app"
            }

            return (frontApp.processIdentifier, bundleID)
        }
    }
}
