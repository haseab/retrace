import Foundation

// MARK: - Feedback Type

/// Types of feedback users can submit
public enum FeedbackType: String, CaseIterable, Identifiable {
    case bug = "Bug Report"
    case feature = "Feature Request"
    case question = "Question"

    public var id: String { rawValue }

    public var icon: String {
        switch self {
        case .bug: return "ladybug"
        case .feature: return "lightbulb"
        case .question: return "questionmark.circle"
        }
    }

    /// Short label for compact button display
    public var shortLabel: String {
        switch self {
        case .bug: return "Bug"
        case .feature: return "Feature"
        case .question: return "Question"
        }
    }

    public var placeholder: String {
        switch self {
        case .bug: return "Describe what happened and what you expected..."
        case .feature: return "Describe the feature you'd like to see..."
        case .question: return "What would you like to know?"
        }
    }
}

// MARK: - Diagnostic Info

/// System and app diagnostic information included with feedback.
///
/// **Why this data is collected:**
/// Retrace has no pre-existing telemetry, analytics, or crash reporting SDK. When a user submits
/// a bug report, this diagnostic snapshot is the *only* context available to understand and
/// reproduce the issue. Each field was chosen because it has directly helped diagnose a real
/// class of user-reported problem (e.g. display scaling bugs, MDM interference, memory pressure).
///
/// **Privacy preserved:** Process info reports category counts only, never app names.
/// No file paths, no user data. Settings snapshot uses a strict whitelist — no raw queries,
/// app lists, or browsing data are ever included.
public struct DiagnosticInfo: Codable {
    public let appVersion: String
    public let buildNumber: String
    public let macOSVersion: String
    public let deviceModel: String
    public let totalDiskSpace: String
    public let freeDiskSpace: String
    public let databaseStats: DatabaseStats
    /// Sanitized settings snapshot (strict whitelist of keys only) for debugging misconfiguration
    /// reports. No raw paths, queries, app lists, or user data — only behavioral toggles and
    /// numeric thresholds. See `collectSanitizedSettingsSnapshot()` for the exact whitelist.
    public let settingsSnapshot: [String: String]
    public let recentErrors: [String]
    public let recentLogs: [String]
    public let timestamp: Date

    // Enhanced diagnostics for debugging edge cases
    public let displayInfo: DisplayInfo
    public let processInfo: ProcessInfo
    public let accessibilityInfo: AccessibilityInfo
    public let performanceInfo: PerformanceInfo
    public let emergencyCrashReports: [String]?

    public struct DatabaseStats: Codable {
        public let sessionCount: Int
        public let frameCount: Int
        public let segmentCount: Int
        public let databaseSizeMB: Double
    }

    /// Display configuration — needed to diagnose scaling, color space, and multi-monitor
    /// rendering issues that are otherwise impossible to reproduce without the exact setup.
    /// No file paths, no user data — only hardware display properties.
    public struct DisplayInfo: Codable {
        public let count: Int
        public let displays: [Display]
        public let mainDisplayIndex: Int

        public init(count: Int, displays: [Display], mainDisplayIndex: Int) {
            self.count = count
            self.displays = displays
            self.mainDisplayIndex = mainDisplayIndex
        }

        public struct Display: Codable {
            public let index: Int
            public let resolution: String  // "2560x1440"
            public let backingScaleFactor: String  // "2.0" or "1.0"
            public let colorSpace: String  // "RGB", "P3"
            public let refreshRate: String  // "60Hz", "120Hz"
            public let isRetina: Bool
            public let frame: String  // "(0,0,2560,1440)" - position info
        }
    }

    /// Running process diagnostics — needed because event-monitoring, window-management,
    /// and MDM/security tools are the most common source of capture and accessibility
    /// interference that users report. Without this, these issues are nearly impossible
    /// to diagnose remotely.
    ///
    /// **Privacy preserved:** Only category counts are reported, never individual app names.
    /// The whitelist of bundle-ID prefixes is checked locally; no app list leaves the device.
    public struct ProcessInfo: Codable {
        public let totalRunning: Int
        public let eventMonitoringApps: Int   // count only — e.g. BTT, Alfred, Raycast
        public let windowManagementApps: Int  // count only — e.g. Rectangle, Magnet
        public let securityApps: Int          // count only — e.g. antivirus, MDM agents
        // MDM presence flags — Jamf/Kandji frequently block screen capture permissions
        public let hasJamf: Bool
        public let hasKandji: Bool
        // System process CPU — high values indicate accessibility or compositing contention
        public let axuiServerCPU: Double      // % CPU
        public let windowServerCPU: Double

        public init(totalRunning: Int, eventMonitoringApps: Int, windowManagementApps: Int, securityApps: Int, hasJamf: Bool, hasKandji: Bool, axuiServerCPU: Double, windowServerCPU: Double) {
            self.totalRunning = totalRunning
            self.eventMonitoringApps = eventMonitoringApps
            self.windowManagementApps = windowManagementApps
            self.securityApps = securityApps
            self.hasJamf = hasJamf
            self.hasKandji = hasKandji
            self.axuiServerCPU = axuiServerCPU
            self.windowServerCPU = windowServerCPU
        }
    }

    /// Accessibility feature flags — these macOS settings directly affect rendering behavior
    /// (e.g. reduce-transparency changes compositing, reduce-motion disables animations).
    /// Only boolean flags from public NSWorkspace APIs; no user-specific data.
    public struct AccessibilityInfo: Codable {
        public let voiceOverEnabled: Bool
        public let switchControlEnabled: Bool
        public let reduceMotionEnabled: Bool
        public let increaseContrastEnabled: Bool
        public let reduceTransparencyEnabled: Bool
        public let differentiateWithoutColorEnabled: Bool
        public let displayHasInvertedColors: Bool

        public init(voiceOverEnabled: Bool, switchControlEnabled: Bool, reduceMotionEnabled: Bool, increaseContrastEnabled: Bool, reduceTransparencyEnabled: Bool, differentiateWithoutColorEnabled: Bool, displayHasInvertedColors: Bool) {
            self.voiceOverEnabled = voiceOverEnabled
            self.switchControlEnabled = switchControlEnabled
            self.reduceMotionEnabled = reduceMotionEnabled
            self.increaseContrastEnabled = increaseContrastEnabled
            self.reduceTransparencyEnabled = reduceTransparencyEnabled
            self.differentiateWithoutColorEnabled = differentiateWithoutColorEnabled
            self.displayHasInvertedColors = displayHasInvertedColors
        }
    }

    /// System performance snapshot — needed to distinguish "app bug" from "machine under
    /// resource pressure" when users report slowness, dropped frames, or high CPU usage.
    public struct PerformanceInfo: Codable {
        public let cpuUsagePercent: Double
        public let memoryUsedGB: Double
        public let memoryTotalGB: Double
        public let memoryPressure: String  // "normal", "warning", "critical"
        public let swapUsedGB: Double
        public let thermalState: String  // "nominal", "fair", "serious", "critical"
        public let processorCount: Int
        public let isLowPowerModeEnabled: Bool
        public let powerSource: String  // "battery", "AC", "unknown"
        public let batteryLevel: Int?  // 0-100 or nil

        public init(cpuUsagePercent: Double, memoryUsedGB: Double, memoryTotalGB: Double, memoryPressure: String, swapUsedGB: Double, thermalState: String, processorCount: Int, isLowPowerModeEnabled: Bool, powerSource: String, batteryLevel: Int?) {
            self.cpuUsagePercent = cpuUsagePercent
            self.memoryUsedGB = memoryUsedGB
            self.memoryTotalGB = memoryTotalGB
            self.memoryPressure = memoryPressure
            self.swapUsedGB = swapUsedGB
            self.thermalState = thermalState
            self.processorCount = processorCount
            self.isLowPowerModeEnabled = isLowPowerModeEnabled
            self.powerSource = powerSource
            self.batteryLevel = batteryLevel
        }
    }

    public init(
        appVersion: String,
        buildNumber: String,
        macOSVersion: String,
        deviceModel: String,
        totalDiskSpace: String,
        freeDiskSpace: String,
        databaseStats: DatabaseStats,
        settingsSnapshot: [String: String] = [:],
        recentErrors: [String],
        recentLogs: [String] = [],
        displayInfo: DisplayInfo = DisplayInfo(count: 0, displays: [], mainDisplayIndex: 0),
        processInfo: ProcessInfo = ProcessInfo(totalRunning: 0, eventMonitoringApps: 0, windowManagementApps: 0, securityApps: 0, hasJamf: false, hasKandji: false, axuiServerCPU: 0, windowServerCPU: 0),
        accessibilityInfo: AccessibilityInfo = AccessibilityInfo(voiceOverEnabled: false, switchControlEnabled: false, reduceMotionEnabled: false, increaseContrastEnabled: false, reduceTransparencyEnabled: false, differentiateWithoutColorEnabled: false, displayHasInvertedColors: false),
        performanceInfo: PerformanceInfo = PerformanceInfo(cpuUsagePercent: 0, memoryUsedGB: 0, memoryTotalGB: 0, memoryPressure: "unknown", swapUsedGB: 0, thermalState: "unknown", processorCount: 0, isLowPowerModeEnabled: false, powerSource: "unknown", batteryLevel: nil),
        emergencyCrashReports: [String]? = nil
    ) {
        self.appVersion = appVersion
        self.buildNumber = buildNumber
        self.macOSVersion = macOSVersion
        self.deviceModel = deviceModel
        self.totalDiskSpace = totalDiskSpace
        self.freeDiskSpace = freeDiskSpace
        self.databaseStats = databaseStats
        self.settingsSnapshot = settingsSnapshot
        self.recentErrors = recentErrors
        self.recentLogs = recentLogs
        self.displayInfo = displayInfo
        self.processInfo = processInfo
        self.accessibilityInfo = accessibilityInfo
        self.performanceInfo = performanceInfo
        self.emergencyCrashReports = emergencyCrashReports
        self.timestamp = Date()
    }

    /// Format as readable text for display (summary without full logs).
    /// Each section explains *why* this data helps diagnose the issue.
    public func formattedText() -> String {
        // -- App & System: identifies the exact build so we can check if the bug is already fixed
        var text = """
        === APP & SYSTEM ===
        (Identifies your build — helps us check if the bug is already fixed)
        App Version: \(appVersion) (\(buildNumber))
        macOS: \(macOSVersion)
        Device: \(deviceModel)
        Disk: \(freeDiskSpace) free of \(totalDiskSpace)
        """

        // -- Database: helps diagnose data-related issues (corruption, retention, storage pressure)
        text += "\n\n=== DATABASE ==="
        text += "\n(Helps diagnose data corruption, retention, and storage pressure issues)"
        text += "\n- Sessions: \(databaseStats.sessionCount)"
        text += "\n- Frames: \(databaseStats.frameCount)"
        text += "\n- Segments: \(databaseStats.segmentCount)"
        text += "\n- Size: \(String(format: "%.1f", databaseStats.databaseSizeMB)) MB"

        // -- Displays: needed to reproduce scaling, color, and multi-monitor rendering bugs
        text += "\n\n=== DISPLAYS (\(displayInfo.count)) ==="
        text += "\n(Needed to reproduce scaling, color space, and multi-monitor rendering bugs)"
        for display in displayInfo.displays {
            let mainTag = display.index == displayInfo.mainDisplayIndex ? " <- MAIN" : ""
            text += "\n  [\(display.index)] \(display.resolution) @\(display.backingScaleFactor)x\(display.isRetina ? " Retina" : "") \(display.refreshRate) \(display.colorSpace) \(display.frame)\(mainTag)"
        }

        // -- Performance: distinguishes app bugs from system resource pressure
        text += "\n\n=== PERFORMANCE ==="
        text += "\n(Distinguishes app bugs from system resource pressure)"
        text += "\n- CPU: \(String(format: "%.1f", performanceInfo.cpuUsagePercent))%"
        text += "\n- Memory: \(String(format: "%.1f", performanceInfo.memoryUsedGB)) GB / \(String(format: "%.1f", performanceInfo.memoryTotalGB)) GB (\(performanceInfo.memoryPressure))"
        text += "\n- Swap: \(String(format: "%.1f", performanceInfo.swapUsedGB)) GB"
        text += "\n- Thermal: \(performanceInfo.thermalState)"
        text += "\n- Power: \(performanceInfo.powerSource)"
        if let battery = performanceInfo.batteryLevel {
            text += " (\(battery)%)"
        }
        text += "\n- Low Power Mode: \(performanceInfo.isLowPowerModeEnabled)"
        text += "\n- Processors: \(performanceInfo.processorCount)"

        // -- Running Apps: category counts only (never app names) — detects interference
        text += "\n\n=== RUNNING APPS (category counts only, never app names) ==="
        text += "\n(Detects tools that commonly interfere with screen capture and accessibility)"
        text += "\n- Total: \(processInfo.totalRunning)"
        if processInfo.eventMonitoringApps > 0 { text += "\n- Event Monitoring: \(processInfo.eventMonitoringApps)" }
        if processInfo.windowManagementApps > 0 { text += "\n- Window Management: \(processInfo.windowManagementApps)" }
        if processInfo.securityApps > 0 { text += "\n- Security/MDM: \(processInfo.securityApps)" }
        if processInfo.hasJamf { text += "\n- Jamf: detected" }
        if processInfo.hasKandji { text += "\n- Kandji: detected" }
        if processInfo.axuiServerCPU > 1.0 { text += "\n- AXUIServer CPU: \(String(format: "%.1f", processInfo.axuiServerCPU))%" }
        if processInfo.windowServerCPU > 5.0 { text += "\n- WindowServer CPU: \(String(format: "%.1f", processInfo.windowServerCPU))%" }

        // -- Accessibility: these OS settings directly affect rendering behavior
        let axFeatures: [(String, Bool)] = [
            ("VoiceOver", accessibilityInfo.voiceOverEnabled),
            ("SwitchControl", accessibilityInfo.switchControlEnabled),
            ("ReduceMotion", accessibilityInfo.reduceMotionEnabled),
            ("IncreaseContrast", accessibilityInfo.increaseContrastEnabled),
            ("ReduceTransparency", accessibilityInfo.reduceTransparencyEnabled),
            ("DifferentiateWithoutColor", accessibilityInfo.differentiateWithoutColorEnabled),
            ("InvertColors", accessibilityInfo.displayHasInvertedColors),
        ]
        let enabledFeatures = axFeatures.filter(\.1).map(\.0)
        if !enabledFeatures.isEmpty {
            text += "\n\n=== ACCESSIBILITY ==="
            text += "\n(These OS settings directly affect rendering and compositing behavior)"
            text += "\n\(enabledFeatures.joined(separator: ", "))"
        }

        text += "\n\nRecent Errors: \(recentErrors.isEmpty ? "None" : "\(recentErrors.count) error(s)")"

        // -- Settings: whitelisted toggles/thresholds only (no paths, no app lists, no user content)
        if !settingsSnapshot.isEmpty {
            text += "\n\n=== SETTINGS (whitelisted keys only, no paths or app names) ==="
            text += "\n(Helps reproduce misconfiguration issues — only behavioral toggles and thresholds)"
            for key in settingsSnapshot.keys.sorted() {
                if let value = settingsSnapshot[key] {
                    text += "\n- \(key): \(value)"
                }
            }
        }

        if !recentLogs.isEmpty {
            text += "\nRecent Logs: \(recentLogs.count) entries from last hour"
        }

        return text
    }

    /// Full formatted text including all logs
    public func fullFormattedText() -> String {
        var text = formattedText()

        // -- Errors: recent error-level log entries that may indicate the root cause
        if !recentErrors.isEmpty {
            text += "\n\n--- ERRORS ---\n"
            text += "(Recent error-level log entries — may indicate root cause)\n"
            text += recentErrors.joined(separator: "\n")
        }

        // -- Emergency crash reports: captured automatically when the app freezes
        // Stored locally only, attached here so we can diagnose hangs after the fact
        if let crashReports = emergencyCrashReports, !crashReports.isEmpty {
            text += "\n\n--- EMERGENCY CRASH REPORTS ---\n"
            text += "(Auto-captured when app was frozen — stored locally, included only with your permission)\n"
            text += crashReports.joined(separator: "\n---\n")
        }

        // -- Full logs: complete log output from the last hour for tracing event sequences
        if !recentLogs.isEmpty {
            text += "\n\n--- FULL LOGS (last hour) ---\n"
            text += "(Complete log output for tracing event sequences leading to the issue)\n"
            text += recentLogs.joined(separator: "\n")
        }

        return text
    }
}

// MARK: - Feedback Submission

/// Complete feedback submission payload
public struct FeedbackSubmission: Codable {
    public let type: String
    public let email: String?
    public let description: String
    public let diagnostics: DiagnosticInfo
    public let includeScreenshot: Bool
    public let screenshotData: Data?

    public init(
        type: FeedbackType,
        email: String = "",
        description: String,
        diagnostics: DiagnosticInfo,
        includeScreenshot: Bool = false,
        screenshotData: Data? = nil
    ) {
        self.type = type.rawValue
        self.email = email.isEmpty ? nil : email
        self.description = description
        self.diagnostics = diagnostics
        self.includeScreenshot = includeScreenshot
        self.screenshotData = screenshotData
    }
}
