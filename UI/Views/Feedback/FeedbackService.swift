import Foundation
import AppKit
import Shared
import OSLog

// MARK: - Feedback Stats Provider

/// Protocol for providing database statistics to feedback service
public protocol FeedbackStatsProvider {
    func getDatabaseStats() async throws -> DatabaseStatistics
    func getAppSessionCount() async throws -> Int
}

// MARK: - Feedback Service

/// Collects diagnostic information and submits feedback
public final class FeedbackService {

    public static let shared = FeedbackService()

    private init() {}

    // MARK: - Diagnostic Collection

    /// Collect current diagnostic information (with placeholder database stats)
    public func collectDiagnostics() -> DiagnosticInfo {
        let logs = collectRecentLogs()
        let errors = logs.filter { $0.contains("[ERROR]") || $0.contains("[FAULT]") }
        let settingsSnapshot = collectSanitizedSettingsSnapshot()

        return DiagnosticInfo(
            appVersion: appVersion,
            buildNumber: buildNumber,
            macOSVersion: macOSVersion,
            deviceModel: deviceModel,
            totalDiskSpace: totalDiskSpace,
            freeDiskSpace: freeDiskSpace,
            databaseStats: collectDatabaseStats(),
            settingsSnapshot: settingsSnapshot,
            recentErrors: errors,
            recentLogs: logs
        )
    }

    /// Collect current diagnostic information with real database stats from provider
    public func collectDiagnostics(with stats: DiagnosticInfo.DatabaseStats) -> DiagnosticInfo {
        // Use file-based logs for submission (more complete, includes all logs)
        let logs = Log.getRecentLogs(maxCount: 500)
        let errors = Log.getRecentErrors(maxCount: 50)
        let settingsSnapshot = collectSanitizedSettingsSnapshot()

        return DiagnosticInfo(
            appVersion: appVersion,
            buildNumber: buildNumber,
            macOSVersion: macOSVersion,
            deviceModel: deviceModel,
            totalDiskSpace: totalDiskSpace,
            freeDiskSpace: freeDiskSpace,
            databaseStats: stats,
            settingsSnapshot: settingsSnapshot,
            recentErrors: errors,
            recentLogs: logs
        )
    }

    /// Collect diagnostics quickly for preview using in-memory log buffer (instant)
    /// This avoids the slow OSLogStore query entirely
    public func collectDiagnosticsQuick(with stats: DiagnosticInfo.DatabaseStats) -> DiagnosticInfo {
        // Use the fast file-based log buffer instead of OSLogStore
        let logs = Log.getRecentLogs(maxCount: 100)
        let errors = Log.getRecentErrors(maxCount: 20)
        let settingsSnapshot = collectSanitizedSettingsSnapshot()

        return DiagnosticInfo(
            appVersion: appVersion,
            buildNumber: buildNumber,
            macOSVersion: macOSVersion,
            deviceModel: deviceModel,
            totalDiskSpace: totalDiskSpace,
            freeDiskSpace: freeDiskSpace,
            databaseStats: stats,
            settingsSnapshot: settingsSnapshot,
            recentErrors: errors,
            recentLogs: logs
        )
    }

    /// Collect diagnostics without any logs (instant, for immediate display)
    /// Database stats should be passed in, logs will show as empty
    public func collectDiagnosticsNoLogs(with stats: DiagnosticInfo.DatabaseStats) -> DiagnosticInfo {
        let settingsSnapshot = collectSanitizedSettingsSnapshot()

        return DiagnosticInfo(
            appVersion: appVersion,
            buildNumber: buildNumber,
            macOSVersion: macOSVersion,
            deviceModel: deviceModel,
            totalDiskSpace: totalDiskSpace,
            freeDiskSpace: freeDiskSpace,
            databaseStats: stats,
            settingsSnapshot: settingsSnapshot,
            recentErrors: [],
            recentLogs: []
        )
    }

    // MARK: - App Info

    /// Get the app bundle - handles both running as .app bundle and debug mode
    private var appBundle: Bundle {
        // First try Bundle.main
        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String, !version.isEmpty {
            return Bundle.main
        }

        // If running in debug mode, try to find the app bundle by identifier
        if let bundle = Bundle(identifier: "io.retrace.app") {
            return bundle
        }

        // Fallback to main bundle
        return Bundle.main
    }

    private var appVersion: String {
        // First try bundle lookup
        if let version = appBundle.infoDictionary?["CFBundleShortVersionString"] as? String, !version.isEmpty {
            return version
        }
        // Fallback for debug builds where bundle info isn't available
        return "unknown"
    }

    private var buildNumber: String {
        // First try bundle lookup
        if let build = appBundle.infoDictionary?["CFBundleVersion"] as? String, !build.isEmpty {
            return build
        }
        // Fallback to hardcoded build for debug builds
        return "dev"
    }

    // MARK: - System Info

    private var macOSVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    private var deviceModel: String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &model, &size, nil, 0)
        return String(cString: model)
    }

    // MARK: - Disk Space

    private var totalDiskSpace: String {
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()),
              let total = attrs[.systemSize] as? Int64 else {
            return "Unknown"
        }
        return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }

    private var freeDiskSpace: String {
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()),
              let free = attrs[.systemFreeSize] as? Int64 else {
            return "Unknown"
        }
        return ByteCountFormatter.string(fromByteCount: free, countStyle: .file)
    }

    // MARK: - Database Stats

    private func collectDatabaseStats() -> DiagnosticInfo.DatabaseStats {
        // Get database file size
        let dbPath = NSString(string: AppPaths.databasePath).expandingTildeInPath
        let dbSize: Double
        if let attrs = try? FileManager.default.attributesOfItem(atPath: dbPath),
           let size = attrs[.size] as? Int64 {
            dbSize = Double(size) / (1024 * 1024) // MB
        } else {
            dbSize = 0
        }

        // For now, return placeholder counts
        // In production, query actual counts from DatabaseManager
        return DiagnosticInfo.DatabaseStats(
            sessionCount: 0,
            frameCount: 0,
            segmentCount: 0,
            databaseSizeMB: dbSize
        )
    }

    // MARK: - Log Collection

    /// Collect recent logs using OSLogStore
    /// - Parameters:
    ///   - minutes: Time window to fetch logs from (default 60 minutes)
    ///   - maxEntries: Maximum number of log entries to return (default 200)
    /// - Returns: Array of formatted log strings
    private func collectRecentLogs(minutes: Int = 60, maxEntries: Int = 200) -> [String] {
        guard #available(macOS 12.0, *) else {
            return ["Log collection requires macOS 12.0+"]
        }

        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let startTime = Date().addingTimeInterval(-Double(minutes * 60))
            let position = store.position(date: startTime)

            let entries = try store.getEntries(at: position)
                .compactMap { $0 as? OSLogEntryLog }
                .filter { $0.subsystem == "io.retrace.app" }
                .suffix(maxEntries)

            return entries.map { entry in
                let level = logLevelString(entry.level)
                return "[\(Log.timestamp(from: entry.date))] [\(level)] [\(entry.category)] \(entry.composedMessage)"
            }
        } catch {
            return ["Failed to collect logs: \(error.localizedDescription)"]
        }
    }

    /// Convert OSLogEntryLog.Level to readable string
    @available(macOS 12.0, *)
    private func logLevelString(_ level: OSLogEntryLog.Level) -> String {
        switch level {
        case .debug: return "DEBUG"
        case .info: return "INFO"
        case .notice: return "NOTICE"
        case .error: return "ERROR"
        case .fault: return "FAULT"
        default: return "UNKNOWN"
        }
    }

    // MARK: - Settings Snapshot

    /// Collect a sanitized settings snapshot for support diagnostics.
    /// Includes only whitelisted keys and avoids raw paths/query text/app lists.
    private func collectSanitizedSettingsSnapshot() -> [String: String] {
        let defaults = UserDefaults(suiteName: "io.retrace.app") ?? .standard

        var settings: [String: String] = [:]

        func boolString(_ value: Bool) -> String { value ? "true" : "false" }

        // Capture + OCR behavior (effective values)
        settings["ocrEnabled"] = boolString(defaults.object(forKey: "ocrEnabled") as? Bool ?? true)
        settings["ocrOnlyWhenPluggedIn"] = boolString(defaults.bool(forKey: "ocrOnlyWhenPluggedIn"))
        let ocrMaxFPS = (defaults.object(forKey: "ocrMaxFramesPerSecond") as? NSNumber)?.doubleValue ?? 1.0
        settings["ocrMaxFramesPerSecond"] = String(format: "%.2f", ocrMaxFPS)
        settings["ocrAppFilterMode"] = defaults.string(forKey: "ocrAppFilterMode") ?? "all"

        // Include counts, never raw app lists
        let ocrFilteredAppsRaw = defaults.string(forKey: "ocrFilteredApps") ?? ""
        settings["ocrFilteredAppsCount"] = String(jsonArrayCount(from: ocrFilteredAppsRaw) ?? 0)

        settings["captureIntervalSeconds"] = String(format: "%.2f", defaults.object(forKey: "captureIntervalSeconds") as? Double ?? 2.0)
        settings["deleteDuplicateFrames"] = boolString(defaults.object(forKey: "deleteDuplicateFrames") as? Bool ?? true)
        settings["deduplicationThreshold"] = String(format: "%.4f", defaults.object(forKey: "deduplicationThreshold") as? Double ?? CaptureConfig.defaultDeduplicationThreshold)
        settings["captureOnWindowChange"] = boolString(defaults.object(forKey: "captureOnWindowChange") as? Bool ?? true)
        settings["excludePrivateWindows"] = boolString(defaults.object(forKey: "excludePrivateWindows") as? Bool ?? false)
        settings["excludeCursor"] = boolString(defaults.object(forKey: "excludeCursor") as? Bool ?? false)

        // Include count for excluded apps, never raw values
        let excludedAppsRaw = defaults.string(forKey: "excludedApps") ?? ""
        settings["excludedAppsCount"] = String(jsonArrayCount(from: excludedAppsRaw) ?? 0)

        // Storage + retention behavior
        let retentionDays = defaults.object(forKey: "retentionDays") as? Int ?? 0
        settings["retentionDays"] = String(retentionDays)
        settings["maxStorageGB"] = String(format: "%.1f", defaults.object(forKey: "maxStorageGB") as? Double ?? 500.0)
        settings["videoQuality"] = String(format: "%.2f", defaults.object(forKey: "videoQuality") as? Double ?? 0.5)

        // Integration + startup flags
        settings["useRewindData"] = boolString(defaults.bool(forKey: "useRewindData"))
        settings["launchAtLogin"] = boolString(defaults.bool(forKey: "launchAtLogin"))
        settings["shouldAutoStartRecording"] = boolString(defaults.bool(forKey: "shouldAutoStartRecording"))

        // Privacy-preserving path diagnostics (flag only)
        settings["customRetraceDBLocationSet"] = boolString((defaults.string(forKey: "customRetraceDBLocation") ?? "").isEmpty == false)
        settings["customRewindDBLocationSet"] = boolString((defaults.string(forKey: "customRewindDBLocation") ?? "").isEmpty == false)

        // UI toggles helpful for reproducing behavior
        settings["timelineColoredBorders"] = boolString(defaults.bool(forKey: "timelineColoredBorders"))
        settings["showVideoControls"] = boolString(defaults.bool(forKey: "showVideoControls"))
        settings["enableFrameIDSearch"] = boolString(defaults.bool(forKey: "enableFrameIDSearch"))

        return settings
    }

    private func jsonArrayCount(from jsonString: String) -> Int? {
        guard !jsonString.isEmpty, let data = jsonString.data(using: .utf8) else {
            return nil
        }

        guard let array = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
            return nil
        }

        return array.count
    }

    // MARK: - Submission

    /// Submit feedback to the backend
    /// - Parameter submission: The feedback to submit
    /// - Returns: True if successful
    public func submitFeedback(_ submission: FeedbackSubmission) async throws -> Bool {
        // TODO: Replace with your actual feedback endpoint
        let endpoint = URL(string: "https://retrace.to/api/feedback")!

        Log.info("[FeedbackService] Submitting feedback to \(endpoint.absoluteString)", category: .app)
        Log.debug("[FeedbackService] Type: \(submission.type), Email: \(submission.email ?? "none"), HasImage: \(submission.screenshotData != nil)", category: .app)

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        request.httpBody = try encoder.encode(submission)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                Log.error("[FeedbackService] Invalid response type", category: .app)
                throw FeedbackError.submissionFailed
            }

            Log.info("[FeedbackService] Response status: \(httpResponse.statusCode)", category: .app)

            if !(200...299).contains(httpResponse.statusCode) {
                let responseBody = String(data: data, encoding: .utf8) ?? "no body"
                Log.error("[FeedbackService] Submission failed with status \(httpResponse.statusCode): \(responseBody)", category: .app)
                throw FeedbackError.submissionFailed
            }

            Log.info("[FeedbackService] Feedback submitted successfully", category: .app)
            return true
        } catch let urlError as URLError {
            Log.error("[FeedbackService] Network error (code: \(urlError.code.rawValue))", category: .app, error: urlError)
            throw FeedbackError.networkError(urlError.localizedDescription)
        } catch {
            Log.error("[FeedbackService] Submission error", category: .app, error: error)
            throw error
        }
    }

    // MARK: - Screenshot

    /// Capture current screen (main display)
    public func captureScreenshot() -> Data? {
        guard let screen = NSScreen.main else { return nil }

        let rect = screen.frame
        guard let image = CGWindowListCreateImage(
            rect,
            .optionOnScreenOnly,
            kCGNullWindowID,
            .bestResolution
        ) else { return nil }

        let nsImage = NSImage(cgImage: image, size: rect.size)
        guard let tiffData = nsImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            return nil
        }

        return pngData
    }

    // MARK: - Export

    /// Export diagnostics as a shareable text file
    public func exportDiagnostics() -> URL? {
        let diagnostics = collectDiagnostics()
        let content = diagnostics.formattedText()

        let fileName = "retrace-diagnostics-\(Log.timestamp()).txt"
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)

        do {
            try content.write(to: tempURL, atomically: true, encoding: .utf8)
            return tempURL
        } catch {
            return nil
        }
    }
}

// MARK: - Errors

public enum FeedbackError: LocalizedError {
    case submissionFailed
    case invalidData
    case networkError(String)

    public var errorDescription: String? {
        switch self {
        case .submissionFailed:
            return "Failed to submit feedback. Please try again."
        case .invalidData:
            return "Invalid feedback data."
        case .networkError(let message):
            return "Network error: \(message)"
        }
    }
}
