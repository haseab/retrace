import Foundation
import AppKit
import Shared
import OSLog
import IOKit.ps

// MARK: - Feedback Stats Provider

/// Protocol for providing database statistics to feedback service
public protocol FeedbackStatsProvider {
    func getDatabaseStats() async throws -> DatabaseStatistics
    func getAppSessionCount() async throws -> Int
}

// MARK: - Feedback Service

/// Collects diagnostic information and submits feedback.
///
/// **Why this exists:** Retrace has no pre-existing telemetry, analytics, or crash reporting SDK.
/// This service is the *only* mechanism for understanding user-reported issues. All data is
/// collected on-demand when the user explicitly submits feedback — nothing is collected in the
/// background or sent automatically.
///
/// **Privacy preserved:** Process info reports category counts only, never app names.
/// No file paths, no user data. Settings use a strict whitelist (see `collectSanitizedSettingsSnapshot`).
public final class FeedbackService {

    public static let shared = FeedbackService()

    private init() {}

    // MARK: - Diagnostic Collection

    /// Collect current diagnostic information (with placeholder database stats)
    public func collectDiagnostics() -> DiagnosticInfo {
        let logs = collectRecentLogs()
        let errors = logs.filter { $0.contains("[ERROR]") || $0.contains("[FAULT]") }
        let settingsSnapshot = collectSanitizedSettingsSnapshot()
        let enhanced = collectEnhancedDiagnostics()

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
            recentLogs: logs,
            displayInfo: enhanced.displayInfo,
            processInfo: enhanced.processInfo,
            accessibilityInfo: enhanced.accessibilityInfo,
            performanceInfo: enhanced.performanceInfo,
            emergencyCrashReports: enhanced.emergencyCrashReports
        )
    }

    /// Collect current diagnostic information with real database stats from provider
    public func collectDiagnostics(with stats: DiagnosticInfo.DatabaseStats) -> DiagnosticInfo {
        // Use file-based logs for submission (more complete, includes all logs)
        let logs = Log.getRecentLogs(maxCount: 500)
        let errors = Log.getRecentErrors(maxCount: 50)
        let settingsSnapshot = collectSanitizedSettingsSnapshot()
        let enhanced = collectEnhancedDiagnostics()

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
            recentLogs: logs,
            displayInfo: enhanced.displayInfo,
            processInfo: enhanced.processInfo,
            accessibilityInfo: enhanced.accessibilityInfo,
            performanceInfo: enhanced.performanceInfo,
            emergencyCrashReports: enhanced.emergencyCrashReports
        )
    }

    /// Collect diagnostics quickly for preview using in-memory log buffer (instant)
    /// This avoids the slow OSLogStore query entirely
    public func collectDiagnosticsQuick(with stats: DiagnosticInfo.DatabaseStats) -> DiagnosticInfo {
        // Use the fast file-based log buffer instead of OSLogStore
        let logs = Log.getRecentLogs(maxCount: 100)
        let errors = Log.getRecentErrors(maxCount: 20)
        let settingsSnapshot = collectSanitizedSettingsSnapshot()
        let enhanced = collectEnhancedDiagnostics()

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
            recentLogs: logs,
            displayInfo: enhanced.displayInfo,
            processInfo: enhanced.processInfo,
            accessibilityInfo: enhanced.accessibilityInfo,
            performanceInfo: enhanced.performanceInfo,
            emergencyCrashReports: enhanced.emergencyCrashReports
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
    /// Uses a strict whitelist of keys — only behavioral toggles and numeric thresholds.
    /// Never includes: raw file paths, search queries, app names/lists, or any user content.
    /// For list-type settings (excluded apps, OCR filtered apps), only the *count* is reported.
    /// Path settings are reduced to a boolean "is custom path set?" flag.
    private func collectSanitizedSettingsSnapshot() -> [String: String] {
        let defaults = UserDefaults(suiteName: "io.retrace.app") ?? .standard

        var settings: [String: String] = [:]

        func boolString(_ value: Bool) -> String { value ? "true" : "false" }

        // Capture + OCR behavior (effective values)
        settings["ocrEnabled"] = boolString(defaults.object(forKey: "ocrEnabled") as? Bool ?? true)
        settings["ocrOnlyWhenPluggedIn"] = boolString(defaults.bool(forKey: "ocrOnlyWhenPluggedIn"))
        let ocrProcessingLevel = (defaults.object(forKey: "ocrProcessingLevel") as? NSNumber)?.intValue ?? 3
        settings["ocrProcessingLevel"] = "\(ocrProcessingLevel)"
        settings["ocrAppFilterMode"] = defaults.string(forKey: "ocrAppFilterMode") ?? "all"

        // Privacy: include counts only, never raw app lists
        let ocrFilteredAppsRaw = defaults.string(forKey: "ocrFilteredApps") ?? ""
        settings["ocrFilteredAppsCount"] = String(jsonArrayCount(from: ocrFilteredAppsRaw) ?? 0)

        settings["captureIntervalSeconds"] = String(format: "%.2f", defaults.object(forKey: "captureIntervalSeconds") as? Double ?? 2.0)
        settings["deleteDuplicateFrames"] = boolString(defaults.object(forKey: "deleteDuplicateFrames") as? Bool ?? true)
        settings["deduplicationThreshold"] = String(format: "%.4f", defaults.object(forKey: "deduplicationThreshold") as? Double ?? CaptureConfig.defaultDeduplicationThreshold)
        settings["captureOnWindowChange"] = boolString(defaults.object(forKey: "captureOnWindowChange") as? Bool ?? true)
        settings["excludePrivateWindows"] = boolString(defaults.object(forKey: "excludePrivateWindows") as? Bool ?? false)
        settings["excludeCursor"] = boolString(defaults.object(forKey: "excludeCursor") as? Bool ?? false)

        // Privacy: count only, never raw app names/bundle IDs
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

        // Privacy: boolean flag only — never the actual file path
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

    // MARK: - Enhanced Diagnostics Collection

    /// Collected enhanced diagnostic fields (grouped for reuse across factory methods)
    private struct EnhancedFields {
        let displayInfo: DiagnosticInfo.DisplayInfo
        let processInfo: DiagnosticInfo.ProcessInfo
        let accessibilityInfo: DiagnosticInfo.AccessibilityInfo
        let performanceInfo: DiagnosticInfo.PerformanceInfo
        let emergencyCrashReports: [String]?
    }

    /// Collect all enhanced diagnostic fields in one call
    private func collectEnhancedDiagnostics() -> EnhancedFields {
        return EnhancedFields(
            displayInfo: collectDisplayInfo(),
            processInfo: collectProcessInfo(),
            accessibilityInfo: collectAccessibilityInfo(),
            performanceInfo: collectPerformanceInfo(),
            emergencyCrashReports: collectEmergencyCrashReports()
        )
    }

    // MARK: - Display Info

    private func collectDisplayInfo() -> DiagnosticInfo.DisplayInfo {
        let screens = NSScreen.screens
        let mainScreen = NSScreen.main
        let mainIndex = mainScreen.flatMap { main in screens.firstIndex(of: main) } ?? 0

        let displays = screens.enumerated().map { (index, screen) in
            let frame = screen.frame
            let backingScale = screen.backingScaleFactor

            var refreshRate = "unknown"
            if #available(macOS 12.0, *) {
                refreshRate = "\(screen.maximumFramesPerSecond)Hz"
            }

            return DiagnosticInfo.DisplayInfo.Display(
                index: index,
                resolution: "\(Int(frame.width))x\(Int(frame.height))",
                backingScaleFactor: String(format: "%.1f", backingScale),
                colorSpace: screen.colorSpace?.localizedName ?? "unknown",
                refreshRate: refreshRate,
                isRetina: backingScale > 1.0,
                frame: "(\(Int(frame.origin.x)),\(Int(frame.origin.y)),\(Int(frame.width)),\(Int(frame.height)))"
            )
        }

        return DiagnosticInfo.DisplayInfo(
            count: screens.count,
            displays: displays,
            mainDisplayIndex: mainIndex
        )
    }

    // MARK: - Process Info (Privacy-Preserving)

    /// Collects running process diagnostics in a privacy-preserving way.
    /// Only category counts are reported — never individual app names or bundle IDs.
    /// This data is essential because event-monitoring tools (BTT, Alfred), window managers
    /// (Rectangle, Magnet), and MDM agents (Jamf, Kandji) are the most common sources of
    /// capture interference, accessibility conflicts, and permission issues that users report.
    private func collectProcessInfo() -> DiagnosticInfo.ProcessInfo {
        let runningApps = NSWorkspace.shared.runningApplications

        // Known bundle ID prefixes by category — matched locally, only counts leave the device
        let eventMonitoringPrefixes = ["com.hegenberg.BetterTouchTool", "com.runningwithcrayons.Alfred",
                                       "com.raycast.macos", "com.contexts.Contexts", "org.pqrs.Karabiner",
                                       "com.if.Amphetamine"]
        let windowManagementPrefixes = ["com.knollsoft.Rectangle", "com.spectacleapp.Spectacle",
                                        "com.manytricks.Moom", "com.crowdcafe.windowmagnet",
                                        "com.sempliva.Tiles"]
        let securityPrefixes = ["com.jamf", "com.kandji", "io.kandji",
                                "com.microsoft.wdav", "com.crowdstrike",
                                "com.sentinelone", "com.eset", "com.avast",
                                "com.bitdefender", "com.cisco.amp", "com.carbonblack"]

        var eventMonitoringCount = 0
        var windowManagementCount = 0
        var securityCount = 0
        var hasJamf = false
        var hasKandji = false

        for app in runningApps {
            guard let bundleID = app.bundleIdentifier else { continue }
            let lowered = bundleID.lowercased()

            if eventMonitoringPrefixes.contains(where: { lowered.hasPrefix($0.lowercased()) }) {
                eventMonitoringCount += 1
            }
            if windowManagementPrefixes.contains(where: { lowered.hasPrefix($0.lowercased()) }) {
                windowManagementCount += 1
            }
            if securityPrefixes.contains(where: { lowered.hasPrefix($0.lowercased()) }) {
                securityCount += 1
            }
            if lowered.contains("jamf") { hasJamf = true }
            if lowered.contains("kandji") { hasKandji = true }
        }

        let axuiServerCPU = getProcessCPU(processName: "AXUIServer")
        let windowServerCPU = getProcessCPU(processName: "WindowServer")

        return DiagnosticInfo.ProcessInfo(
            totalRunning: runningApps.count,
            eventMonitoringApps: eventMonitoringCount,
            windowManagementApps: windowManagementCount,
            securityApps: securityCount,
            hasJamf: hasJamf,
            hasKandji: hasKandji,
            axuiServerCPU: axuiServerCPU,
            windowServerCPU: windowServerCPU
        )
    }

    /// Get CPU usage for a specific system process by name using `ps`.
    /// Runs in a subprocess - safe to call from main thread (fast, non-blocking for short output).
    private func getProcessCPU(processName: String) -> Double {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-eo", "comm,%cpu"]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()

            guard let output = String(data: data, encoding: .utf8) else { return 0 }

            for line in output.components(separatedBy: "\n") {
                if line.contains(processName) {
                    let parts = line.trimmingCharacters(in: .whitespaces)
                        .components(separatedBy: .whitespaces)
                        .filter { !$0.isEmpty }
                    if let cpuString = parts.last, let cpu = Double(cpuString) {
                        return cpu
                    }
                }
            }
        } catch {
            // Silently fail - non-critical diagnostic
        }

        return 0
    }

    // MARK: - Accessibility Info

    private func collectAccessibilityInfo() -> DiagnosticInfo.AccessibilityInfo {
        let workspace = NSWorkspace.shared
        return DiagnosticInfo.AccessibilityInfo(
            voiceOverEnabled: workspace.isVoiceOverEnabled,
            switchControlEnabled: workspace.isSwitchControlEnabled,
            reduceMotionEnabled: workspace.accessibilityDisplayShouldReduceMotion,
            increaseContrastEnabled: workspace.accessibilityDisplayShouldIncreaseContrast,
            reduceTransparencyEnabled: workspace.accessibilityDisplayShouldReduceTransparency,
            differentiateWithoutColorEnabled: workspace.accessibilityDisplayShouldDifferentiateWithoutColor,
            displayHasInvertedColors: workspace.accessibilityDisplayShouldInvertColors
        )
    }

    // MARK: - Performance Info

    private func collectPerformanceInfo() -> DiagnosticInfo.PerformanceInfo {
        let sysInfo = ProcessInfo.processInfo

        let physicalMemory = Double(sysInfo.physicalMemory) / (1024 * 1024 * 1024)
        let (usedMemory, memoryPressure) = getMemoryInfo()
        let swapUsed = getSwapUsage()

        let thermalState: String
        switch sysInfo.thermalState {
        case .nominal: thermalState = "nominal"
        case .fair: thermalState = "fair"
        case .serious: thermalState = "serious"
        case .critical: thermalState = "critical"
        @unknown default: thermalState = "unknown"
        }

        let (powerSource, batteryLevel) = getPowerInfo()

        var isLowPowerMode = false
        if #available(macOS 12.0, *) {
            isLowPowerMode = sysInfo.isLowPowerModeEnabled
        }

        return DiagnosticInfo.PerformanceInfo(
            cpuUsagePercent: getCPUUsage(),
            memoryUsedGB: usedMemory,
            memoryTotalGB: physicalMemory,
            memoryPressure: memoryPressure,
            swapUsedGB: swapUsed,
            thermalState: thermalState,
            processorCount: sysInfo.processorCount,
            isLowPowerModeEnabled: isLowPowerMode,
            powerSource: powerSource,
            batteryLevel: batteryLevel
        )
    }

    private func getCPUUsage() -> Double {
        var cpuInfo: processor_info_array_t?
        var numCPUInfo: mach_msg_type_number_t = 0
        var numCPUs: natural_t = 0

        let result = host_processor_info(mach_host_self(),
                                         PROCESSOR_CPU_LOAD_INFO,
                                         &numCPUs,
                                         &cpuInfo,
                                         &numCPUInfo)

        guard result == KERN_SUCCESS, let cpuInfo = cpuInfo else { return 0 }

        defer {
            vm_deallocate(mach_task_self_,
                         vm_address_t(bitPattern: cpuInfo),
                         vm_size_t(numCPUInfo) * vm_size_t(MemoryLayout<integer_t>.stride))
        }

        var totalUsage: Double = 0

        for i in 0..<Int(numCPUs) {
            let offset = Int(CPU_STATE_MAX) * i
            let user = Double(cpuInfo[offset + Int(CPU_STATE_USER)])
            let system = Double(cpuInfo[offset + Int(CPU_STATE_SYSTEM)])
            let nice = Double(cpuInfo[offset + Int(CPU_STATE_NICE)])
            let idle = Double(cpuInfo[offset + Int(CPU_STATE_IDLE)])

            let total = user + system + nice + idle
            if total > 0 {
                totalUsage += (user + system + nice) / total * 100.0
            }
        }

        return numCPUs > 0 ? totalUsage / Double(numCPUs) : 0
    }

    private func getMemoryInfo() -> (usedGB: Double, pressure: String) {
        var vmStats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)

        let result = withUnsafeMutablePointer(to: &vmStats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }

        guard result == KERN_SUCCESS else { return (0, "unknown") }

        let pageSize = Double(vm_kernel_page_size)
        let active = Double(vmStats.active_count) * pageSize
        let wired = Double(vmStats.wire_count) * pageSize
        let compressed = Double(vmStats.compressor_page_count) * pageSize

        let usedMemory = (active + wired + compressed) / (1024 * 1024 * 1024)

        let freeCount = vmStats.free_count
        let totalPages = vmStats.active_count + vmStats.inactive_count + vmStats.wire_count + vmStats.free_count
        let freePercent = totalPages > 0 ? Double(freeCount) / Double(totalPages) * 100.0 : 0

        let pressure: String
        if freePercent > 20 { pressure = "normal" }
        else if freePercent > 10 { pressure = "warning" }
        else { pressure = "critical" }

        return (usedMemory, pressure)
    }

    private func getSwapUsage() -> Double {
        var swapInfo = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &swapInfo, &size, nil, 0) == 0 else { return 0 }
        return Double(swapInfo.xsu_used) / (1024 * 1024 * 1024)
    }

    private func getPowerInfo() -> (source: String, batteryLevel: Int?) {
        guard let powerSources = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sourceList = IOPSCopyPowerSourcesList(powerSources)?.takeRetainedValue() as? [CFTypeRef] else {
            return ("unknown", nil)
        }

        for source in sourceList {
            guard let info = IOPSGetPowerSourceDescription(powerSources, source)?
                    .takeUnretainedValue() as? [String: Any] else {
                continue
            }

            let powerSourceState = info[kIOPSPowerSourceStateKey] as? String
            let isOnAC = powerSourceState == kIOPSACPowerValue
            let currentCapacity = info[kIOPSCurrentCapacityKey] as? Int

            return (isOnAC ? "AC" : "battery", currentCapacity)
        }

        return ("unknown", nil)
    }

    // MARK: - Emergency Crash Report Collection

    private func collectEmergencyCrashReports() -> [String]? {
        let reports = EmergencyDiagnostics.loadReports(maxReports: 5)
        return reports.isEmpty ? nil : reports
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
