import Foundation
import App

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

public struct FeedbackLaunchContext {
    public enum Source: String {
        case manual
        case crashBanner
        case walFailureCrashBanner
    }

    public enum PreferredFocusField {
        case email
    }

    public let source: Source
    public let feedbackType: FeedbackType
    public let prefilledDescription: String?
    public let preferredFocusField: PreferredFocusField?

    public init(
        source: Source = .manual,
        feedbackType: FeedbackType = .bug,
        prefilledDescription: String? = nil,
        preferredFocusField: PreferredFocusField? = nil
    ) {
        self.source = source
        self.feedbackType = feedbackType
        self.prefilledDescription = prefilledDescription
        self.preferredFocusField = preferredFocusField
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
/// **Privacy preserved:** Process info reports category counts only, never app names. Memory
/// diagnostics add only a small allowlist of Retrace/media-system helper process names relevant
/// to decoder debugging. No file paths, no user data. Settings snapshot uses a strict whitelist —
/// no raw queries, app lists, or browsing data are ever included.
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
    public let recentMetricEvents: [FeedbackRecentMetricEvent]
    public let timestamp: Date

    // Enhanced diagnostics for debugging edge cases
    public let displayInfo: DisplayInfo
    public let processInfo: ProcessInfo
    public let accessibilityInfo: AccessibilityInfo
    public let performanceInfo: PerformanceInfo
    public let emergencyCrashReports: [String]?

    public struct DatabaseStats: Codable, Sendable {
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
        recentMetricEvents: [FeedbackRecentMetricEvent] = [],
        displayInfo: DisplayInfo = DisplayInfo(count: 0, displays: [], mainDisplayIndex: 0),
        processInfo: ProcessInfo = ProcessInfo(totalRunning: 0, eventMonitoringApps: 0, windowManagementApps: 0, securityApps: 0, hasJamf: false, hasKandji: false, axuiServerCPU: 0, windowServerCPU: 0),
        accessibilityInfo: AccessibilityInfo = AccessibilityInfo(voiceOverEnabled: false, switchControlEnabled: false, reduceMotionEnabled: false, increaseContrastEnabled: false, reduceTransparencyEnabled: false, differentiateWithoutColorEnabled: false, displayHasInvertedColors: false),
        performanceInfo: PerformanceInfo = PerformanceInfo(cpuUsagePercent: 0, memoryUsedGB: 0, memoryTotalGB: 0, memoryPressure: "unknown", swapUsedGB: 0, thermalState: "unknown", processorCount: 0, isLowPowerModeEnabled: false, powerSource: "unknown", batteryLevel: nil),
        emergencyCrashReports: [String]? = nil,
        timestamp: Date = Date()
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
        self.recentMetricEvents = recentMetricEvents
        self.displayInfo = displayInfo
        self.processInfo = processInfo
        self.accessibilityInfo = accessibilityInfo
        self.performanceInfo = performanceInfo
        self.emergencyCrashReports = emergencyCrashReports
        self.timestamp = timestamp
    }

    public func withRecentMetricEvents(_ events: [FeedbackRecentMetricEvent]) -> DiagnosticInfo {
        DiagnosticInfo(
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
            recentMetricEvents: events,
            displayInfo: displayInfo,
            processInfo: processInfo,
            accessibilityInfo: accessibilityInfo,
            performanceInfo: performanceInfo,
            emergencyCrashReports: emergencyCrashReports,
            timestamp: timestamp
        )
    }
}

// MARK: - Feedback Submission

/// Complete feedback submission payload
public struct FeedbackSubmission {
    public let type: String
    public let email: String?
    public let description: String
    public let diagnostics: DiagnosticInfo
    public let includedDiagnosticSections: Set<DiagnosticInfo.SectionID>
    public let includeScreenshot: Bool
    public let screenshotData: Data?

    public init(
        type: FeedbackType,
        email: String = "",
        description: String,
        diagnostics: DiagnosticInfo,
        includedDiagnosticSections: Set<DiagnosticInfo.SectionID> = Set(DiagnosticInfo.SectionID.allCases),
        includeScreenshot: Bool = false,
        screenshotData: Data? = nil
    ) {
        self.type = type.rawValue
        self.email = email.isEmpty ? nil : email
        self.description = description
        self.diagnostics = diagnostics
        self.includedDiagnosticSections = includedDiagnosticSections
        self.includeScreenshot = includeScreenshot
        self.screenshotData = screenshotData
    }
}
