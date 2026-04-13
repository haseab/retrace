import Foundation
import AppKit
import Shared
import IOKit.ps
import Darwin

extension FeedbackService {
    private static let memoryProfileCategory = "FeedbackMemoryProfile"

    // MARK: - Diagnostic Collection

    /// Collect current diagnostic information (with placeholder database stats)
    public func collectDiagnostics() -> DiagnosticInfo {
        let baseFields = collectBaseDiagnosticsFields()
        let logSnapshot = Self.collectFeedbackLogSnapshotWithErrors(
            rawLimit: Self.diagnosticsLogLimit,
            errorLimit: 50
        )
        let logs = collectRetraceMemorySummaryLogsOnCurrentThread(
            performanceInfo: baseFields.enhanced.performanceInfo
        ) + logSnapshot.retainedLogs

        return makeDiagnostics(
            databaseStats: collectDatabaseStats(),
            settingsSnapshot: baseFields.settingsSnapshot,
            enhanced: baseFields.enhanced,
            recentErrors: logSnapshot.recentErrors,
            recentLogs: logs,
            groupedRecentLogs: logSnapshot.groupedLogs
        )
    }

    /// Collect current diagnostic information with real database stats from provider
    public func collectDiagnostics(with stats: DiagnosticInfo.DatabaseStats) -> DiagnosticInfo {
        // Use the file-based log buffer for submission/export.
        let baseFields = collectBaseDiagnosticsFields()
        let logSnapshot = Self.collectFeedbackLogSnapshotWithErrors(
            rawLimit: Self.diagnosticsLogLimit,
            errorLimit: 50
        )
        let logs = collectRetraceMemorySummaryLogsOnCurrentThread(
            performanceInfo: baseFields.enhanced.performanceInfo
        ) + logSnapshot.retainedLogs

        return makeDiagnostics(
            databaseStats: stats,
            settingsSnapshot: baseFields.settingsSnapshot,
            enhanced: baseFields.enhanced,
            recentErrors: logSnapshot.recentErrors,
            recentLogs: logs,
            groupedRecentLogs: logSnapshot.groupedLogs
        )
    }

    /// Collect diagnostics quickly for preview using in-memory log buffer (instant)
    /// This avoids the slow OSLogStore query entirely
    public func collectDiagnosticsQuick(with stats: DiagnosticInfo.DatabaseStats) -> DiagnosticInfo {
        // Use the fast file-based log buffer with the same log cap shown in exports.
        let baseFields = collectBaseDiagnosticsFields()
        let logSnapshot = Self.collectFeedbackLogSnapshotWithErrors(
            rawLimit: Self.diagnosticsLogLimit,
            errorLimit: 20
        )
        let logs = collectRetraceMemorySummaryLogsOnCurrentThread(
            performanceInfo: baseFields.enhanced.performanceInfo
        ) + logSnapshot.retainedLogs

        return makeDiagnostics(
            databaseStats: stats,
            settingsSnapshot: baseFields.settingsSnapshot,
            enhanced: baseFields.enhanced,
            recentErrors: logSnapshot.recentErrors,
            recentLogs: logs,
            groupedRecentLogs: logSnapshot.groupedLogs
        )
    }

    public func collectDiagnosticsAsync() async -> DiagnosticInfo {
        await Task.detached(priority: .userInitiated) { [self] in
            let baseFields = collectBaseDiagnosticsFields()
            let logSnapshot = Self.collectFeedbackLogSnapshotWithErrors(
                rawLimit: Self.diagnosticsLogLimit,
                errorLimit: 50
            )
            let logs = await collectRetraceMemorySummaryLogs(
                performanceInfo: baseFields.enhanced.performanceInfo
            ) + logSnapshot.retainedLogs

            return makeDiagnostics(
                databaseStats: collectDatabaseStats(),
                settingsSnapshot: baseFields.settingsSnapshot,
                enhanced: baseFields.enhanced,
                recentErrors: logSnapshot.recentErrors,
                recentLogs: logs,
                groupedRecentLogs: logSnapshot.groupedLogs
            )
        }.value
    }

    public func collectDiagnosticsAsync(with stats: DiagnosticInfo.DatabaseStats) async -> DiagnosticInfo {
        await Task.detached(priority: .userInitiated) { [self] in
            let baseFields = collectBaseDiagnosticsFields()
            let logSnapshot = Self.collectFeedbackLogSnapshotWithErrors(
                rawLimit: Self.diagnosticsLogLimit,
                errorLimit: 50
            )
            let logs = await collectRetraceMemorySummaryLogs(
                performanceInfo: baseFields.enhanced.performanceInfo
            ) + logSnapshot.retainedLogs

            return makeDiagnostics(
                databaseStats: stats,
                settingsSnapshot: baseFields.settingsSnapshot,
                enhanced: baseFields.enhanced,
                recentErrors: logSnapshot.recentErrors,
                recentLogs: logs,
                groupedRecentLogs: logSnapshot.groupedLogs
            )
        }.value
    }

    public func collectSubmissionDiagnosticsAsync() async -> DiagnosticInfo {
        await Task.detached(priority: .userInitiated) { [self] in
            let stats = collectDatabaseStats()
            return await collectSubmissionDiagnostics(databaseStats: stats)
        }.value
    }

    public func collectSubmissionDiagnosticsAsync(with stats: DiagnosticInfo.DatabaseStats) async -> DiagnosticInfo {
        await Task.detached(priority: .userInitiated) { [self] in
            await collectSubmissionDiagnostics(databaseStats: stats)
        }.value
    }

    private func collectSubmissionDiagnostics(
        databaseStats: DiagnosticInfo.DatabaseStats
    ) async -> DiagnosticInfo {
        let baseFields = collectBaseDiagnosticsFields()
        let memorySummaryLogs = await collectRetraceMemorySummaryLogs(
            performanceInfo: baseFields.enhanced.performanceInfo
        )

        let rawLogBudget = Self.submissionRawLogBudget(memorySummaryCount: memorySummaryLogs.count)
        let logSnapshot = Self.collectFeedbackLogSnapshotWithErrors(
            rawLimit: rawLogBudget,
            errorLimit: 50
        )

        return makeDiagnostics(
            databaseStats: databaseStats,
            settingsSnapshot: baseFields.settingsSnapshot,
            enhanced: baseFields.enhanced,
            recentErrors: logSnapshot.recentErrors,
            recentLogs: memorySummaryLogs + logSnapshot.retainedLogs,
            groupedRecentLogs: logSnapshot.groupedLogs
        )
    }

    public func collectDiagnosticsQuickAsync(with stats: DiagnosticInfo.DatabaseStats) async -> DiagnosticInfo {
        await Task.detached(priority: .userInitiated) { [self] in
            let baseFields = collectBaseDiagnosticsFields()
            let logSnapshot = Self.collectFeedbackLogSnapshotWithErrors(
                rawLimit: Self.diagnosticsLogLimit,
                errorLimit: 20
            )
            let logs = await collectRetraceMemorySummaryLogs(
                performanceInfo: baseFields.enhanced.performanceInfo
            ) + logSnapshot.retainedLogs

            return makeDiagnostics(
                databaseStats: stats,
                settingsSnapshot: baseFields.settingsSnapshot,
                enhanced: baseFields.enhanced,
                recentErrors: logSnapshot.recentErrors,
                recentLogs: logs,
                groupedRecentLogs: logSnapshot.groupedLogs
            )
        }.value
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
        settings["keepFramesOnMouseMovement"] = boolString(defaults.object(forKey: "keepFramesOnMouseMovement") as? Bool ?? true)
        settings["captureOnWindowChange"] = boolString(defaults.object(forKey: "captureOnWindowChange") as? Bool ?? true)
        settings["captureOnMouseClick"] = boolString(defaults.object(forKey: "captureOnMouseClick") as? Bool ?? false)
        settings["excludePrivateWindows"] = boolString(defaults.object(forKey: "excludePrivateWindows") as? Bool ?? false)
        settings["excludeCursor"] = boolString(defaults.object(forKey: "excludeCursor") as? Bool ?? false)

        // Privacy: count only, never raw app names/bundle IDs
        let excludedAppsRaw = defaults.string(forKey: "excludedApps") ?? ""
        settings["excludedAppsCount"] = String(jsonArrayCount(from: excludedAppsRaw) ?? 0)

        // Storage + retention behavior
        let retentionDays = defaults.object(forKey: "retentionDays") as? Int ?? 0
        settings["retentionDays"] = String(retentionDays)
        settings["maxStorageGB"] = String(format: "%.1f", defaults.object(forKey: "maxStorageGB") as? Double ?? 500.0)
        settings["videoQuality"] = String(format: "%.2f", defaults.object(forKey: "videoQuality") as? Double ?? 0.7)

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

    private func collectBaseDiagnosticsFields() -> (
        settingsSnapshot: [String: String],
        enhanced: EnhancedFields
    ) {
        (
            settingsSnapshot: collectSanitizedSettingsSnapshot(),
            enhanced: collectEnhancedDiagnostics()
        )
    }

    private func makeDiagnostics(
        databaseStats: DiagnosticInfo.DatabaseStats,
        settingsSnapshot: [String: String],
        enhanced: EnhancedFields,
        recentErrors: [String],
        recentLogs: [String],
        groupedRecentLogs: DiagnosticInfo.GroupedRecentLogs?
    ) -> DiagnosticInfo {
        return DiagnosticInfo(
            appVersion: appVersion,
            buildNumber: buildNumber,
            macOSVersion: macOSVersion,
            deviceModel: deviceModel,
            totalDiskSpace: totalDiskSpace,
            freeDiskSpace: freeDiskSpace,
            databaseStats: databaseStats,
            settingsSnapshot: settingsSnapshot,
            recentErrors: recentErrors,
            recentLogs: recentLogs,
            groupedRecentLogs: groupedRecentLogs,
            displayInfo: enhanced.displayInfo,
            processInfo: enhanced.processInfo,
            accessibilityInfo: enhanced.accessibilityInfo,
            performanceInfo: enhanced.performanceInfo,
            emergencyCrashReports: enhanced.emergencyCrashReports
        )
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
            .map(Self.compactEmergencyCrashReportForFeedback)
        let diagnosticReports = DashboardViewModel.loadRecentDiagnosticCrashReportSummariesForFeedback(maxReports: 5)
            .compactMap { summary -> String? in
                guard let data = try? Data(contentsOf: summary.fileURL) else {
                    return nil
                }
                let report = String(decoding: data, as: UTF8.self)
                return Self.compactDiagnosticCrashReportForFeedback(report, fileName: summary.fileName)
            }

        let allReports = reports + diagnosticReports
        return allReports.isEmpty ? nil : allReports
    }

    private func collectRetraceMemorySummaryLogsOnCurrentThread(
        performanceInfo: DiagnosticInfo.PerformanceInfo
    ) -> [String] {
        guard Thread.isMainThread else {
            return [memoryProfileLogEntry("Retrace memory summary unavailable off the main thread")]
        }

        let snapshot = MainActor.assumeIsolated { ProcessCPUMonitor.shared.snapshot }
        return buildRetraceMemorySummaryLogs(
            snapshot: snapshot,
            performanceInfo: performanceInfo
        )
    }

    private func collectRetraceMemorySummaryLogs(
        performanceInfo: DiagnosticInfo.PerformanceInfo
    ) async -> [String] {
        let snapshot = await MainActor.run { ProcessCPUMonitor.shared.snapshot }
        return buildRetraceMemorySummaryLogs(
            snapshot: snapshot,
            performanceInfo: performanceInfo
        )
    }

    private func buildRetraceMemorySummaryLogs(
        snapshot: ProcessCPUSnapshot,
        performanceInfo: DiagnosticInfo.PerformanceInfo
    ) -> [String] {
        guard snapshot.hasEnoughMemoryData else {
            return [memoryProfileLogEntry(
                "Retrace memory sampler warming up (\(formattedDuration(snapshot.sampleDurationSeconds)) collected)"
            )]
        }

        var entries: [String] = []
        let latestSampleAgeText: String
        if let latestSampleTimestamp = snapshot.latestSampleTimestamp {
            latestSampleAgeText = formattedAge(Date().timeIntervalSince1970 - latestSampleTimestamp)
        } else {
            latestSampleAgeText = "unknown"
        }

        entries.append(memoryProfileLogEntry(
            "Sampler window: \(formattedDuration(snapshot.sampleDurationSeconds))"
                + " | latest sample age: \(latestSampleAgeText)"
                + " | tracked current total: \(formattedMemory(snapshot.totalTrackedCurrentResidentBytes))"
                + " | tracked avg total: \(formattedMemory(snapshot.totalTrackedAverageResidentBytes))"
                + " | memory pressure: \(performanceInfo.memoryPressure)"
                + " | swap: \(formattedGigabytes(performanceInfo.swapUsedGB))"
        ))

        guard let retraceGroupKey = snapshot.retraceGroupKey,
              let retraceRow = snapshot.topMemoryProcesses.first(where: { $0.id == retraceGroupKey }) else {
            entries.append(memoryProfileLogEntry("Retrace process not present in tracked memory snapshot"))
            return entries
        }

        entries.append(memoryProfileLogEntry("Retrace memory hierarchy:"))
        entries.append(memoryProfileLogEntry(formattedRetraceMemoryHierarchyLine(for: retraceRow, indentLevel: 0)))

        let attributionTree = snapshot.retraceMemoryAttributionTree
        let hasObservedFamilies = attributionTree.categories.contains { category in
            !(attributionTree.familiesByCategory[category.id] ?? []).isEmpty
        }

        if !hasObservedFamilies {
            entries.append(memoryProfileLogEntry("  (No internal attribution families observed in this sample window)"))
            return entries
        }

        for categoryRow in attributionTree.categories {
            entries.append(memoryProfileLogEntry(formattedRetraceMemoryHierarchyLine(for: categoryRow, indentLevel: 1)))

            let familyRows = attributionTree.familiesByCategory[categoryRow.id] ?? []
            for familyRow in familyRows {
                entries.append(memoryProfileLogEntry(formattedRetraceMemoryHierarchyLine(for: familyRow, indentLevel: 2)))

                let familyExpansionKey = ProcessCPUDisplayMetrics.retraceMemoryAttributionFamilyExpansionKey(
                    categoryID: categoryRow.id,
                    familyID: familyRow.id
                )
                let componentRows = attributionTree.componentsByCategoryFamily[familyExpansionKey] ?? []
                for componentRow in componentRows {
                    entries.append(memoryProfileLogEntry(formattedRetraceMemoryHierarchyLine(for: componentRow, indentLevel: 3)))
                }
            }
        }

        return entries
    }

    private func memoryProfileLogEntry(_ message: String, level: String = "NOTICE") -> String {
        "[\(Log.timestamp())] [\(level)] [\(Self.memoryProfileCategory)] \(message)"
    }

    private func formattedRetraceMemoryHierarchyLine(
        for row: ProcessMemoryRow,
        indentLevel: Int
    ) -> String {
        let indentation = String(repeating: "  ", count: max(0, indentLevel))
        return indentation
            + "\(row.name): now \(formattedMemory(row.currentBytes))"
            + " | avg \(formattedMemory(row.averageBytes))"
            + " | peak \(formattedMemory(row.peakBytes))"
            + " | tracked share now \(formattedPercent(row.currentSharePercent))"
    }

    private func formattedMemory(_ bytes: UInt64) -> String {
        Self.formattedMemoryProfileBytes(bytes)
    }

    static func formattedMemoryProfileBytes(_ bytes: UInt64) -> String {
        let megabytes = Double(bytes) / (1024 * 1024)
        if megabytes.rounded() >= 1000 {
            let gigabytes = Double(bytes) / (1024 * 1024 * 1024)
            return String(format: "%.2f GB", gigabytes)
        }

        return String(format: "%.0f MB", megabytes)
    }

    private func formattedGigabytes(_ gigabytes: Double) -> String {
        String(format: "%.2f GB", gigabytes)
    }

    private func formattedPercent(_ percent: Double) -> String {
        String(format: "%.1f%%", percent)
    }

    private func formattedDuration(_ seconds: TimeInterval) -> String {
        if seconds >= 3600 {
            return String(format: "%.1f h", seconds / 3600)
        }
        if seconds >= 60 {
            return String(format: "%.0f min", seconds / 60)
        }
        return String(format: "%.0f s", seconds)
    }

    private func formattedAge(_ seconds: TimeInterval) -> String {
        let clampedSeconds = max(0, seconds)
        if clampedSeconds >= 60 {
            return String(format: "%.0f min", clampedSeconds / 60)
        }
        return String(format: "%.0f s", clampedSeconds)
    }
}
