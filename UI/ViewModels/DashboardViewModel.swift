import SwiftUI
import Combine
import CrashRecoverySupport
import Shared
import App
import Database
import ApplicationServices
import Dispatch

enum DashboardCrashReportSource: String, Equatable {
    case watchdogAutoQuit = "watchdog_auto_quit"
    case macOSDiagnosticReport = "macos_diagnostic_report"
}

struct DashboardCrashReportSummary: Equatable {
    let source: DashboardCrashReportSource
    let fileName: String
    let fileURL: URL
    let capturedAt: Date

    var acknowledgmentIdentifier: String {
        "\(source.rawValue):\(fileURL.resolvingSymlinksInPath().path)"
    }
}

struct WALFailureCrashReportSummary: Equatable {
    let fileName: String
    let fileURL: URL
    let capturedAt: Date
}

struct StorageHealthBannerState: Equatable {
    enum Severity: String {
        case warning
        case critical
    }

    let severity: Severity
    let availableGB: Double
    let shouldStop: Bool

    var signature: String {
        "\(severity.rawValue)|\(shouldStop)|\(String(format: "%.2f", availableGB))"
    }

    var messageText: String {
        let availableText = String(format: "%.2f", availableGB)

        if shouldStop {
            return "Recording stopped because storage is critically low (\(availableText) GB free). Free up disk space before restarting capture."
        }

        switch severity {
        case .warning:
            return "Storage is running low (\(availableText) GB free). Free space soon to avoid interrupted recording."
        case .critical:
            return "Storage is critically low (\(availableText) GB free). Recording may stop soon if space is not freed."
        }
    }
}

private enum StorageHealthNotificationNames {
    static let low = Notification.Name("StorageLow")
    static let criticalLow = Notification.Name("StorageCriticalLow")
}

/// ViewModel for the Dashboard view
/// Manages weekly app usage statistics from the database
@MainActor
public class DashboardViewModel: ObservableObject {

    // MARK: - Published State

    // Recording status
    @Published public var isRecording = false
    @Published public var isRecordingPaused = false
    @Published public var recordingPauseRemainingSeconds: Int?

    // Weekly app usage
    @Published public var weeklyAppUsage: [AppUsageData] = []
    @Published public var totalWeeklyTime: TimeInterval = 0
    @Published public var totalDailyTime: TimeInterval = 0
    @Published public var weekDateRange: String = ""
    @Published public var appUsageRangeStart: Date
    @Published public var appUsageRangeEnd: Date
    @Published public var appUsageRangeLabel: String = ""
    @Published public var appUsageRangeErrorText: String?

    // Overall statistics
    @Published public var totalStorageBytes: Int64 = 0
    @Published public var weeklyStorageBytes: Int64 = 0
    @Published public var daysRecorded: Int = 0
    @Published public var oldestRecordedDate: Date?

    // Weekly engagement metrics (aggregated from daily data)
    @Published public var timelineOpensThisWeek: Int64 = 0
    @Published public var searchesThisWeek: Int64 = 0
    @Published public var textCopiesThisWeek: Int64 = 0

    // Daily graph data for the currently selected dashboard range
    @Published public var dailyScreenTimeData: [DailyDataPoint] = []
    @Published public var dailyStorageData: [DailyDataPoint] = []
    @Published public var dailyTimelineOpensData: [DailyDataPoint] = []
    @Published public var dailySearchesData: [DailyDataPoint] = []
    @Published public var dailyTextCopiesData: [DailyDataPoint] = []

    // Loading state
    @Published public var isLoading = false
    @Published public var error: String?

    // Queue monitoring
    @Published public var ocrQueueDepth: Int = 0
    @Published public var ocrTotalProcessed: Int = 0
    @Published public var ocrIsPaused: Bool = false
    @Published public var powerSource: String = "unknown"

    // Permission warnings
    @Published public var showAccessibilityWarning = false
    @Published public var showScreenRecordingWarning = false
    @Published var storageHealthBanner: StorageHealthBannerState?
    @Published var recentCrashReport: DashboardCrashReportSummary?
    @Published var recentWALFailureCrash: WALFailureCrashReportSummary?

    // Track user dismissals — re-nag after 30 minutes
    private var accessibilityDismissedUntil: Date?
    private var screenRecordingDismissedUntil: Date?

    /// How long to suppress a permission warning after the user dismisses it
    private static let dismissSnoozeInterval: TimeInterval = 30 * 60 // 30 minutes
    nonisolated private static let recentCrashReportWindow: TimeInterval = 7 * 24 * 60 * 60
    nonisolated private static let walFailureCrashRecentWindow: TimeInterval = 7 * 24 * 60 * 60
    nonisolated private static var diagnosticCrashReportDirectories: [String] {
        [
            NSString(string: "~/Library/Logs/DiagnosticReports").expandingTildeInPath,
            "/Library/Logs/DiagnosticReports"
        ]
    }
    private static let acknowledgedCrashReportIDsKey = "acknowledgedCrashReportIDs"
    private static let acknowledgedCrashReportCutoffTimestampMsKey = "acknowledgedCrashReportCutoffTimestampMs"
    private static let legacyAcknowledgedWatchdogCrashReportKey = "acknowledgedWatchdogCrashReportFileName"
    private static let legacyAcknowledgedWatchdogCrashReportKeysKey = "acknowledgedWatchdogCrashReportFileNames"
    private static let acknowledgedWALFailureCrashReportKey = "acknowledgedWALFailureCrashReportFileName"
    private static let acknowledgedWALFailureCrashReportKeysKey = "acknowledgedWALFailureCrashReportFileNames"
    private static let acknowledgedWALFailureCrashReportCutoffTimestampMsKey = "acknowledgedWALFailureCrashReportCutoffTimestampMs"

    // MARK: - Dependencies

    private let coordinator: AppCoordinator
    private let settingsStore = UserDefaults(suiteName: "io.retrace.app") ?? .standard
    private var cancellables = Set<AnyCancellable>()
    private var refreshTimer: DispatchSourceTimer?
    /// Prevents the 2s poll from clobbering optimistic toggle UI while start/stop is in flight.
    private var isRecordingToggleInFlight = false
    private var lastTrackedCrashBannerIdentifier: String?
    private var lastTrackedWALFailureBannerFileName: String?
    private var lastTrackedStorageHealthBannerSignature: String?
    private var isAutoRefreshInFlight = false
    private var dashboardLoadTraceID: UInt64 = 0
    private static let defaultAppUsageRangeDays = 7
    public nonisolated static let maxAppUsageRangeDays = 31
    private static let dashboardPerfDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// Whether the dashboard window is currently visible
    /// Set by DashboardWindowController on show/hide to gate UI updates
    public var isWindowVisible: Bool = false

    // MARK: - Initialization

    public init(coordinator: AppCoordinator) {
        let defaultRange = Self.defaultAppUsageDateRange()
        self.coordinator = coordinator
        self.appUsageRangeStart = defaultRange.start
        self.appUsageRangeEnd = defaultRange.end
        self.appUsageRangeLabel = Self.formatAppUsageRangeLabel(start: defaultRange.start, end: defaultRange.end)
        self.weekDateRange = self.appUsageRangeLabel
        setupAutoRefresh()
        setupDataSourceObserver()
        setupStorageHealthObserver()
        // Check permissions immediately on init
        checkPermissions()
    }

    // MARK: - Setup

    private func setupDataSourceObserver() {
        NotificationCenter.default.addObserver(
            forName: .dataSourceDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.loadStatistics()
            }
        }
    }

    private func setupStorageHealthObserver() {
        let center = NotificationCenter.default

        center.publisher(for: StorageHealthNotificationNames.low)
            .sink { [weak self] notification in
                Task { @MainActor [weak self] in
                    self?.handleStorageHealthNotification(notification, severity: .warning)
                }
            }
            .store(in: &cancellables)

        center.publisher(for: StorageHealthNotificationNames.criticalLow)
            .sink { [weak self] notification in
                Task { @MainActor [weak self] in
                    self?.handleStorageHealthNotification(notification, severity: .critical)
                }
            }
            .store(in: &cancellables)
    }

    private func setupAutoRefresh() {
        // Refresh recording status and permissions every 1 second with leeway for power efficiency
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: 1.0, leeway: .milliseconds(250))
        timer.setEventHandler { [weak self] in
            Task { @MainActor in
                guard let self = self else { return }
                // Skip UI updates when window is hidden to avoid SwiftUI diffing
                guard self.isWindowVisible else { return }
                guard !self.isAutoRefreshInFlight else { return }
                self.isAutoRefreshInFlight = true
                defer { self.isAutoRefreshInFlight = false }
                self.updateRecordingStatus()
                self.updatePauseStatus()
                await self.updateQueueStatus()
                self.checkPermissions()
                await self.refreshRecentCrashReportState()
                await self.refreshRecentWALFailureCrashState()
            }
        }
        timer.resume()
        refreshTimer = timer
    }

    private func updateRecordingStatus(force: Bool = false) {
        guard force || !isRecordingToggleInFlight else { return }
        // Read from thread-safe holder to avoid actor hops and keep UI updates responsive.
        isRecording = coordinator.statusHolder.status.isRunning
    }

    private func updatePauseStatus() {
        guard let menuBarManager = MenuBarManager.shared else {
            isRecordingPaused = false
            recordingPauseRemainingSeconds = nil
            return
        }
        isRecordingPaused = menuBarManager.isPausedState
        recordingPauseRemainingSeconds = menuBarManager.timedPauseRemainingSeconds
    }

    private func updateQueueStatus() async {
        if let stats = await coordinator.getQueueStatistics() {
            ocrQueueDepth = stats.ocrQueueDepth
            ocrTotalProcessed = stats.totalProcessed
        }

        let powerState = coordinator.getCurrentPowerState()
        ocrIsPaused = powerState.isPaused
        switch powerState.source {
        case .ac: powerSource = "AC"
        case .battery: powerSource = "Battery"
        case .unknown: powerSource = "Unknown"
        }
    }

    /// Polls accessibility and screen recording permissions and updates warning states.
    /// Shows warnings when a permission is missing and the user is recording OR trying to record
    /// (i.e. the pipeline can't start because of a missing permission).
    /// Only hides warnings when the user is voluntarily not recording AND all permissions are granted.
    /// If the user dismisses a warning, it's snoozed for 30 minutes then re-shown.
    private func checkPermissions() {
        let hasAccessibility = AXIsProcessTrusted()
        let hasScreenRecording = CGPreflightScreenCaptureAccess()
        let permissionsMissing = !hasAccessibility || !hasScreenRecording
        let now = Date()

        // Don't nag if the user voluntarily stopped recording and all permissions are fine.
        // But if a permission is missing, always warn — the user may be unable to start recording.
        if !isRecording && !permissionsMissing {
            showAccessibilityWarning = false
            showScreenRecordingWarning = false
            return
        }

        // Accessibility
        if hasAccessibility {
            showAccessibilityWarning = false
            accessibilityDismissedUntil = nil
        } else if let snoozeEnd = accessibilityDismissedUntil {
            if now >= snoozeEnd {
                accessibilityDismissedUntil = nil
                showAccessibilityWarning = true
            }
        } else {
            showAccessibilityWarning = true
        }

        // Screen recording
        if hasScreenRecording {
            showScreenRecordingWarning = false
            screenRecordingDismissedUntil = nil
        } else if let snoozeEnd = screenRecordingDismissedUntil {
            if now >= snoozeEnd {
                screenRecordingDismissedUntil = nil
                showScreenRecordingWarning = true
            }
        } else {
            showScreenRecordingWarning = true
        }
    }

    public func toggleRecording(to newValue: Bool) async {
        guard !isRecordingToggleInFlight else { return }
        isRecordingToggleInFlight = true

        if newValue {
            MenuBarManager.shared?.cancelScheduledResume()
        }

        // Update UI immediately for instant feedback
        isRecording = newValue
        MenuBarManager.shared?.updateRecordingStatus(newValue)

        do {
            if newValue {
                try await coordinator.startPipeline()
            } else {
                try await coordinator.stopPipeline()
            }
            updateRecordingStatus(force: true)
        } catch {
            Log.error("[DashboardViewModel] Failed to toggle recording: \(error)", category: .ui)
            // Revert to actual state on error
            updateRecordingStatus(force: true)
        }
        MenuBarManager.shared?.updateRecordingStatus(isRecording)
        updatePauseStatus()
        isRecordingToggleInFlight = false
    }

    public func pauseRecording(for duration: TimeInterval?) async {
        guard !isRecordingToggleInFlight else { return }
        isRecordingToggleInFlight = true

        // Update UI immediately for instant feedback
        isRecording = false
        MenuBarManager.shared?.updateRecordingStatus(false)

        if let menuBarManager = MenuBarManager.shared {
            await menuBarManager.pauseRecording(for: duration)
            updateRecordingStatus(force: true)
        } else {
            // Fallback path (menu bar manager should normally always be configured)
            do {
                let isTimedPause = (duration ?? 0) > 0
                try await coordinator.stopPipeline(persistState: !isTimedPause)
            } catch {
                Log.error("[DashboardViewModel] Failed to pause recording: \(error)", category: .ui)
            }
            updateRecordingStatus(force: true)
        }

        MenuBarManager.shared?.updateRecordingStatus(isRecording)
        updatePauseStatus()
        isRecordingToggleInFlight = false
    }

    public func dismissAccessibilityWarning() {
        showAccessibilityWarning = false
        accessibilityDismissedUntil = Date().addingTimeInterval(Self.dismissSnoozeInterval)
    }

    public func dismissScreenRecordingWarning() {
        showScreenRecordingWarning = false
        screenRecordingDismissedUntil = Date().addingTimeInterval(Self.dismissSnoozeInterval)
    }

    public func dismissStorageHealthBanner() {
        guard let state = storageHealthBanner else { return }
        recordStorageHealthBannerAction("dismissed", state: state)
        storageHealthBanner = nil
        lastTrackedStorageHealthBannerSignature = nil
    }

    public func dismissRecentCrashReport() {
        acknowledgeRecentCrashReport(action: "dismissed")
    }

    public func recordRecentCrashReportFeedbackOpened() {
        guard let report = recentCrashReport else { return }
        recordCrashBannerAction("submit_bug_report_clicked", report: report)
    }

    public func recordRecentCrashReportDetailsOpened() {
        guard let report = recentCrashReport else { return }
        recordCrashBannerAction("details_opened", report: report)
    }

    public func dismissRecentWALFailureCrash() {
        acknowledgeRecentWALFailureCrash(action: "dismissed")
    }

    public func recordRecentWALFailureCrashFeedbackOpened() {
        guard let report = recentWALFailureCrash else { return }
        recordWALFailureBannerAction("submit_bug_report_clicked", report: report)
    }

    public func recordRecentWALFailureCrashDetailsOpened() {
        guard let report = recentWALFailureCrash else { return }
        recordWALFailureBannerAction("details_opened", report: report)
    }

    private func handleStorageHealthNotification(
        _ notification: Notification,
        severity: StorageHealthBannerState.Severity
    ) {
        let payload = notification.object as? [String: Any]
        let availableGB = payload?["availableGB"] as? Double ?? 0
        let shouldStop = payload?["shouldStop"] as? Bool ?? false
        let state = StorageHealthBannerState(
            severity: severity,
            availableGB: availableGB,
            shouldStop: shouldStop
        )

        presentStorageHealthBanner(state)
    }

    func showDebugStorageHealthBanner(
        severity: StorageHealthBannerState.Severity,
        availableGB: Double,
        shouldStop: Bool
    ) {
        let state = StorageHealthBannerState(
            severity: severity,
            availableGB: availableGB,
            shouldStop: shouldStop
        )
        recordStorageHealthBannerAction("debug_triggered", state: state)
        presentStorageHealthBanner(state)
    }

    private func presentStorageHealthBanner(_ state: StorageHealthBannerState) {
        storageHealthBanner = state
        guard state.signature != lastTrackedStorageHealthBannerSignature else {
            return
        }

        lastTrackedStorageHealthBannerSignature = state.signature
        recordStorageHealthBannerAction("banner_shown", state: state)
    }

    nonisolated static func makeCrashFeedbackLaunchContext(
        for report: DashboardCrashReportSummary,
        now: Date = Date()
    ) -> FeedbackLaunchContext {
        FeedbackLaunchContext(
            source: .crashBanner,
            feedbackType: .bug,
            prefilledDescription: makeCrashFeedbackDescription(for: report, now: now),
            preferredFocusField: .email
        )
    }

    nonisolated static func makeWALFailureFeedbackLaunchContext(
        for report: WALFailureCrashReportSummary,
        now: Date = Date()
    ) -> FeedbackLaunchContext {
        FeedbackLaunchContext(
            source: .walFailureCrashBanner,
            feedbackType: .bug,
            prefilledDescription: makeWALFailureFeedbackDescription(for: report, now: now),
            preferredFocusField: .email
        )
    }

    nonisolated static func loadRecentCrashReport(
        fileManager: FileManager = .default,
        crashReportDirectory: String = EmergencyDiagnostics.crashReportDirectory,
        diagnosticReportDirectories: [String] = DashboardViewModel.diagnosticCrashReportDirectories,
        now: Date = Date(),
        acknowledgedReportIdentifiers: Set<String> = [],
        acknowledgedBeforeDate: Date? = nil
    ) -> DashboardCrashReportSummary? {
        let resourceKeys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .contentModificationDateKey,
            .creationDateKey
        ]

        let emergencyDirectoryURL = URL(fileURLWithPath: crashReportDirectory, isDirectory: true)
        let emergencyReports = loadEmergencyCrashReports(
            fileManager: fileManager,
            directoryURL: emergencyDirectoryURL,
            resourceKeys: resourceKeys,
            now: now
        )
        let diagnosticReports = diagnosticReportDirectories.flatMap { directory in
            loadDiagnosticCrashReports(
                fileManager: fileManager,
                directoryURL: URL(fileURLWithPath: directory, isDirectory: true),
                resourceKeys: resourceKeys,
                now: now
            )
        }

        return (emergencyReports + diagnosticReports)
            .sorted { $0.capturedAt > $1.capturedAt }
            .first {
                !isCrashReportAcknowledged(
                    $0,
                    acknowledgedIdentifiers: acknowledgedReportIdentifiers,
                    acknowledgedBeforeDate: acknowledgedBeforeDate
                )
            }
    }

    nonisolated private static func loadEmergencyCrashReports(
        fileManager: FileManager,
        directoryURL: URL,
        resourceKeys: Set<URLResourceKey>,
        now: Date
    ) -> [DashboardCrashReportSummary] {
        guard let fileURLs = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let prefix = "retrace-emergency-watchdog_auto_quit-"

        return fileURLs.compactMap { fileURL -> DashboardCrashReportSummary? in
            let fileName = fileURL.lastPathComponent
            guard fileName.hasPrefix(prefix), fileURL.pathExtension == "txt" else {
                return nil
            }

            let resourceValues = try? fileURL.resourceValues(forKeys: resourceKeys)
            if resourceValues?.isRegularFile == false {
                return nil
            }

            let capturedAt = resourceValues?.contentModificationDate
                ?? resourceValues?.creationDate
                ?? parseWatchdogCrashTimestamp(from: fileName)
                ?? .distantPast

            guard now.timeIntervalSince(capturedAt) <= recentCrashReportWindow else {
                return nil
            }

            return DashboardCrashReportSummary(
                source: .watchdogAutoQuit,
                fileName: fileName,
                fileURL: fileURL,
                capturedAt: capturedAt
            )
        }
    }

    nonisolated private static func loadDiagnosticCrashReports(
        fileManager: FileManager,
        directoryURL: URL,
        resourceKeys: Set<URLResourceKey>,
        now: Date
    ) -> [DashboardCrashReportSummary] {
        guard let fileURLs = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return fileURLs.compactMap { fileURL -> DashboardCrashReportSummary? in
            let fileName = fileURL.lastPathComponent
            guard isDiagnosticCrashReportFileName(fileName) else {
                return nil
            }

            let resourceValues = try? fileURL.resourceValues(forKeys: resourceKeys)
            if resourceValues?.isRegularFile == false {
                return nil
            }

            let capturedAt = resourceValues?.contentModificationDate
                ?? resourceValues?.creationDate
                ?? parseDiagnosticCrashTimestamp(from: fileName)
                ?? .distantPast

            guard now.timeIntervalSince(capturedAt) <= recentCrashReportWindow else {
                return nil
            }

            return DashboardCrashReportSummary(
                source: .macOSDiagnosticReport,
                fileName: fileName,
                fileURL: fileURL,
                capturedAt: capturedAt
            )
        }
    }

    nonisolated static func loadRecentWALFailureCrash(
        fileManager: FileManager = .default,
        crashReportDirectory: String = EmergencyDiagnostics.crashReportDirectory,
        now: Date = Date(),
        acknowledgedFileNames: Set<String> = [],
        acknowledgedBeforeDate: Date? = nil
    ) -> WALFailureCrashReportSummary? {
        let reports = loadRecentWALFailureCrashReports(
            fileManager: fileManager,
            crashReportDirectory: crashReportDirectory,
            now: now
        )
        return reports.first { report in
            if let acknowledgedBeforeDate, report.capturedAt <= acknowledgedBeforeDate {
                return false
            }
            return !acknowledgedFileNames.contains(report.fileName)
        }
    }

    nonisolated private static func loadRecentWALFailureCrashReports(
        fileManager: FileManager = .default,
        crashReportDirectory: String = EmergencyDiagnostics.crashReportDirectory,
        now: Date = Date()
    ) -> [WALFailureCrashReportSummary] {
        let directoryURL = URL(fileURLWithPath: crashReportDirectory, isDirectory: true)
        let resourceKeys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .contentModificationDateKey,
            .creationDateKey
        ]

        guard let fileURLs = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let prefix = "retrace-emergency-wal_unavailable-"

        let reports = fileURLs.compactMap { fileURL -> WALFailureCrashReportSummary? in
            let fileName = fileURL.lastPathComponent
            guard fileName.hasPrefix(prefix), fileURL.pathExtension == "txt" else {
                return nil
            }

            let resourceValues = try? fileURL.resourceValues(forKeys: resourceKeys)
            if resourceValues?.isRegularFile == false {
                return nil
            }

            let capturedAt = resourceValues?.contentModificationDate
                ?? resourceValues?.creationDate
                ?? parseWALFailureTimestamp(from: fileName)
                ?? .distantPast

            guard now.timeIntervalSince(capturedAt) <= walFailureCrashRecentWindow else {
                return nil
            }

            return WALFailureCrashReportSummary(
                fileName: fileName,
                fileURL: fileURL,
                capturedAt: capturedAt
            )
        }
        .sorted { $0.capturedAt > $1.capturedAt }

        return reports
    }

    nonisolated static func makeCrashFeedbackDescription(
        for report: DashboardCrashReportSummary,
        now _: Date = Date()
    ) -> String {
        let heading: String
        switch report.source {
        case .watchdogAutoQuit:
            heading = "Retrace Auto Quit Crash Logging"
        case .macOSDiagnosticReport:
            heading = "Retrace macOS Crash Report"
        }

        return """
        \(heading)

        Enter any other relevant context here:
        """
    }

    nonisolated static func makeWALFailureFeedbackDescription(
        for _: WALFailureCrashReportSummary,
        now _: Date = Date()
    ) -> String {
        return """
        Retrace Recovery Failure

        Retrace couldn't complete recovery during startup.
        New recordings may fail until storage is repaired.
        Enter any other relevant context here:
        """
    }

    nonisolated private static func parseWatchdogCrashTimestamp(from fileName: String) -> Date? {
        let prefix = "retrace-emergency-watchdog_auto_quit-"
        let suffix = ".txt"

        guard fileName.hasPrefix(prefix), fileName.hasSuffix(suffix) else {
            return nil
        }

        let timestamp = String(fileName.dropFirst(prefix.count).dropLast(suffix.count))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        return formatter.date(from: timestamp)
    }

    nonisolated private static func isDiagnosticCrashReportFileName(_ fileName: String) -> Bool {
        let normalized = fileName.lowercased()
        let pathExtension = URL(fileURLWithPath: fileName).pathExtension.lowercased()
        guard pathExtension == "ips" || pathExtension == "crash" else {
            return false
        }

        return normalized.hasPrefix("retrace-") || normalized.hasPrefix("retrace_")
    }

    nonisolated private static func parseDiagnosticCrashTimestamp(from fileName: String) -> Date? {
        let baseName = URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent

        let timestamp: String
        if baseName.hasPrefix("Retrace-") {
            timestamp = String(baseName.dropFirst("Retrace-".count))
        } else if baseName.hasPrefix("Retrace_") {
            let remainder = String(baseName.dropFirst("Retrace_".count))
            guard let firstComponent = remainder.split(separator: "_").first else {
                return nil
            }
            timestamp = String(firstComponent)
        } else {
            return nil
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter.date(from: timestamp)
    }

    nonisolated private static func isCrashReportAcknowledged(
        _ report: DashboardCrashReportSummary,
        acknowledgedIdentifiers: Set<String>,
        acknowledgedBeforeDate: Date?
    ) -> Bool {
        if let acknowledgedBeforeDate, report.capturedAt <= acknowledgedBeforeDate {
            return true
        }

        return acknowledgedIdentifiers.contains(report.acknowledgmentIdentifier)
            || acknowledgedIdentifiers.contains(report.fileName)
    }

    private func refreshRecentCrashReportState(now: Date = Date()) async {
        let acknowledgedIdentifiers = loadAcknowledgedCrashReportIdentifiers()
        let acknowledgedBeforeDate = loadAcknowledgedCrashReportCutoffDate()
        let report = await Task.detached(priority: .utility) {
            Self.loadRecentCrashReport(
                now: now,
                acknowledgedReportIdentifiers: acknowledgedIdentifiers,
                acknowledgedBeforeDate: acknowledgedBeforeDate
            )
        }.value

        recentCrashReport = report

        guard let report, report.acknowledgmentIdentifier != lastTrackedCrashBannerIdentifier else {
            return
        }

        lastTrackedCrashBannerIdentifier = report.acknowledgmentIdentifier
        recordCrashBannerAction("banner_shown", report: report, now: now)
    }

    nonisolated private static func parseWALFailureTimestamp(from fileName: String) -> Date? {
        let prefix = "retrace-emergency-wal_unavailable-"
        let suffix = ".txt"

        guard fileName.hasPrefix(prefix), fileName.hasSuffix(suffix) else {
            return nil
        }

        let timestamp = String(fileName.dropFirst(prefix.count).dropLast(suffix.count))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        return formatter.date(from: timestamp)
    }

    private func acknowledgeRecentCrashReport(action: String) {
        guard let report = recentCrashReport else { return }
        var acknowledgedIdentifiers = loadAcknowledgedCrashReportIdentifiers()
        acknowledgedIdentifiers.insert(report.acknowledgmentIdentifier)
        let acknowledgedBeforeDate = max(loadAcknowledgedCrashReportCutoffDate() ?? .distantPast, report.capturedAt)
        persistAcknowledgedCrashReportIdentifiers(acknowledgedIdentifiers)
        persistAcknowledgedCrashReportCutoffDate(acknowledgedBeforeDate)
        recordCrashBannerAction(action, report: report)
        recentCrashReport = nil
    }

    private func refreshRecentWALFailureCrashState(now: Date = Date()) async {
        let previousFileName = recentWALFailureCrash?.fileName
        let acknowledgedFileNames = loadAcknowledgedWALFailureCrashFileNames()
        let acknowledgedBeforeDate = loadAcknowledgedWALFailureCrashReportCutoffDate()
        let (reports, unacknowledgedReports) = await Task.detached(priority: .utility) {
            let reports = Self.loadRecentWALFailureCrashReports(
                now: now
            )
            let unacknowledgedReports = reports.filter { report in
                if let acknowledgedBeforeDate, report.capturedAt <= acknowledgedBeforeDate {
                    return false
                }
                return !acknowledgedFileNames.contains(report.fileName)
            }
            return (reports, unacknowledgedReports)
        }.value
        let report = unacknowledgedReports.first

        recentWALFailureCrash = report

        if report?.fileName != previousFileName {
            let acknowledgedList = acknowledgedFileNames.sorted().joined(separator: ", ")
            let unacknowledgedPreview = unacknowledgedReports
                .prefix(3)
                .map(\.fileName)
                .joined(separator: ", ")
            let nextAfterCurrent = unacknowledgedReports.dropFirst().first?.fileName ?? "none"
            let cutoffDescription = acknowledgedBeforeDate.map { String(Int64($0.timeIntervalSince1970)) } ?? "none"
            Log.info(
                "[RECOVERY BANNER] Refresh previous=\(previousFileName ?? "none") next=\(report?.fileName ?? "none") nextAfterCurrent=\(nextAfterCurrent) recentReportCount=\(reports.count) unacknowledgedCount=\(unacknowledgedReports.count) walAcknowledgedBeforeEpochSeconds=\(cutoffDescription) unacknowledgedPreview=[\(unacknowledgedPreview)] acknowledgedCount=\(acknowledgedFileNames.count) acknowledgedFiles=[\(acknowledgedList)]",
                category: .ui
            )
        }

        guard let report, report.fileName != lastTrackedWALFailureBannerFileName else {
            return
        }

        lastTrackedWALFailureBannerFileName = report.fileName
        recordWALFailureBannerAction("banner_shown", report: report, now: now)
    }

    private func acknowledgeRecentWALFailureCrash(action: String) {
        guard let report = recentWALFailureCrash else { return }
        var acknowledgedFileNames = loadAcknowledgedWALFailureCrashFileNames()
        let existingCutoff = loadAcknowledgedWALFailureCrashReportCutoffDate()
        let alreadyAcknowledged = acknowledgedFileNames.contains(report.fileName)
        acknowledgedFileNames.insert(report.fileName)
        let synchronizeSucceeded = persistAcknowledgedWALFailureCrashFileNames(acknowledgedFileNames)
        let acknowledgedBeforeDate = max(existingCutoff ?? .distantPast, report.capturedAt)
        let cutoffSynchronizeSucceeded = persistAcknowledgedWALFailureCrashReportCutoffDate(acknowledgedBeforeDate)
        let persistedAcknowledgedFileNames = loadAcknowledgedWALFailureCrashFileNames()
        let persistedCutoff = loadAcknowledgedWALFailureCrashReportCutoffDate()
        let persistedCutoffEpochSeconds = persistedCutoff.map { Int64($0.timeIntervalSince1970) }
        let intendedCutoffEpochSeconds = Int64(acknowledgedBeforeDate.timeIntervalSince1970)
        let persistedCutoffMatches = persistedCutoffEpochSeconds == intendedCutoffEpochSeconds
        let persistedContainsFile = persistedAcknowledgedFileNames.contains(report.fileName)
        let reports = Self.loadRecentWALFailureCrashReports(now: Date())
        let remainingUnacknowledgedReports = reports.filter { candidate in
            if let persistedCutoff, candidate.capturedAt <= persistedCutoff {
                return false
            }
            return !persistedAcknowledgedFileNames.contains(candidate.fileName)
        }
        let nextAfterAcknowledge = remainingUnacknowledgedReports.first?.fileName ?? "none"
        let acknowledgedList = persistedAcknowledgedFileNames.sorted().joined(separator: ", ")
        Log.info(
            "[RECOVERY BANNER] Acknowledge action=\(action) file=\(report.fileName) alreadyAcknowledged=\(alreadyAcknowledged) synchronizeSucceeded=\(synchronizeSucceeded) cutoffSynchronizeSucceeded=\(cutoffSynchronizeSucceeded) persistedContainsFile=\(persistedContainsFile) persistedCutoffMatches=\(persistedCutoffMatches) walAcknowledgedBeforeEpochSeconds=\(persistedCutoffEpochSeconds.map(String.init) ?? "none") acknowledgedCount=\(persistedAcknowledgedFileNames.count) remainingUnacknowledgedCount=\(remainingUnacknowledgedReports.count) nextAfterAcknowledge=\(nextAfterAcknowledge) acknowledgedFiles=[\(acknowledgedList)]",
            category: .ui
        )
        recordWALFailureBannerAction(action, report: report)
        recentWALFailureCrash = nil
    }

    private func loadAcknowledgedCrashReportIdentifiers() -> Set<String> {
        var acknowledgedIdentifiers = Set(
            settingsStore.stringArray(forKey: Self.acknowledgedCrashReportIDsKey) ?? []
        )
        let legacyAcknowledgedFileNames = settingsStore.stringArray(
            forKey: Self.legacyAcknowledgedWatchdogCrashReportKeysKey
        ) ?? []
        acknowledgedIdentifiers.formUnion(legacyAcknowledgedFileNames)

        if let legacyAcknowledgedFileName = settingsStore.string(
            forKey: Self.legacyAcknowledgedWatchdogCrashReportKey
        ) {
            acknowledgedIdentifiers.insert(legacyAcknowledgedFileName)
        }

        return acknowledgedIdentifiers
    }

    private func loadAcknowledgedCrashReportCutoffDate() -> Date? {
        let cutoffTimestampMs = (settingsStore.object(
            forKey: Self.acknowledgedCrashReportCutoffTimestampMsKey
        ) as? NSNumber)?.doubleValue

        guard let cutoffTimestampMs else { return nil }
        return Date(timeIntervalSince1970: cutoffTimestampMs / 1000)
    }

    private func persistAcknowledgedCrashReportIdentifiers(_ identifiers: Set<String>) {
        settingsStore.set(identifiers.sorted(), forKey: Self.acknowledgedCrashReportIDsKey)
        settingsStore.removeObject(forKey: Self.legacyAcknowledgedWatchdogCrashReportKey)
        settingsStore.removeObject(forKey: Self.legacyAcknowledgedWatchdogCrashReportKeysKey)
        settingsStore.synchronize()
    }

    private func loadAcknowledgedWALFailureCrashFileNames() -> Set<String> {
        var acknowledgedFileNames = Set(
            settingsStore.stringArray(forKey: Self.acknowledgedWALFailureCrashReportKeysKey) ?? []
        )

        if let legacyAcknowledgedFileName = settingsStore.string(
            forKey: Self.acknowledgedWALFailureCrashReportKey
        ) {
            acknowledgedFileNames.insert(legacyAcknowledgedFileName)
        }

        return acknowledgedFileNames
    }

    @discardableResult
    private func persistAcknowledgedWALFailureCrashFileNames(_ fileNames: Set<String>) -> Bool {
        settingsStore.set(fileNames.sorted(), forKey: Self.acknowledgedWALFailureCrashReportKeysKey)
        settingsStore.removeObject(forKey: Self.acknowledgedWALFailureCrashReportKey)
        return settingsStore.synchronize()
    }

    private func loadAcknowledgedWALFailureCrashReportCutoffDate() -> Date? {
        let cutoffTimestampMs = (settingsStore.object(
            forKey: Self.acknowledgedWALFailureCrashReportCutoffTimestampMsKey
        ) as? NSNumber)?.doubleValue

        guard let cutoffTimestampMs else { return nil }
        return Date(timeIntervalSince1970: cutoffTimestampMs / 1000)
    }

    @discardableResult
    private func persistAcknowledgedWALFailureCrashReportCutoffDate(_ date: Date) -> Bool {
        let timestampMs = Int64(date.timeIntervalSince1970 * 1000)
        settingsStore.set(timestampMs, forKey: Self.acknowledgedWALFailureCrashReportCutoffTimestampMsKey)
        return settingsStore.synchronize()
    }

    private func persistAcknowledgedCrashReportCutoffDate(_ date: Date) {
        let timestampMs = Int64(date.timeIntervalSince1970 * 1000)
        settingsStore.set(timestampMs, forKey: Self.acknowledgedCrashReportCutoffTimestampMsKey)
        settingsStore.synchronize()
    }

    private func recordCrashBannerAction(
        _ action: String,
        report: DashboardCrashReportSummary,
        now: Date = Date()
    ) {
        let metadata = Self.jsonMetadata([
            "action": action,
            "fileName": report.fileName,
            "source": report.source.rawValue,
            "reportAgeSeconds": max(0, Int(now.timeIntervalSince(report.capturedAt)))
        ])
        Self.recordMetric(
            coordinator: coordinator,
            type: .watchdogCrashBannerAction,
            metadata: metadata
        )
    }

    private func recordWALFailureBannerAction(
        _ action: String,
        report: WALFailureCrashReportSummary,
        now: Date = Date()
    ) {
        let metadata = Self.jsonMetadata([
            "action": action,
            "fileName": report.fileName,
            "reportAgeSeconds": max(0, Int(now.timeIntervalSince(report.capturedAt)))
        ])
        Self.recordMetric(
            coordinator: coordinator,
            type: .walFailureBannerAction,
            metadata: metadata
        )
    }

    private func recordStorageHealthBannerAction(
        _ action: String,
        state: StorageHealthBannerState
    ) {
        let metadata = Self.jsonMetadata([
            "action": action,
            "severity": state.severity.rawValue,
            "availableGB": state.availableGB,
            "shouldStop": state.shouldStop
        ])
        Self.recordMetric(
            coordinator: coordinator,
            type: .storageHealthBannerAction,
            metadata: metadata
        )
    }

    // MARK: - Data Loading

    private static func defaultAppUsageDateRange(
        calendar: Calendar = .current,
        now: Date = Date()
    ) -> (start: Date, end: Date) {
        let today = calendar.startOfDay(for: now)
        let offset = -(defaultAppUsageRangeDays - 1)
        let start = calendar.date(byAdding: .day, value: offset, to: today) ?? today
        return (start: start, end: today)
    }
    private static func normalizedUnboundedAppUsageDateRange(
        start: Date,
        end: Date,
        calendar: Calendar = .current,
        now: Date = Date()
    ) -> (start: Date, end: Date) {
        let today = calendar.startOfDay(for: now)
        var startDay = calendar.startOfDay(for: start)
        var endDay = calendar.startOfDay(for: end)

        if endDay < startDay {
            swap(&startDay, &endDay)
        }

        if startDay > today {
            startDay = today
        }
        if endDay > today {
            endDay = today
        }
        if endDay < startDay {
            startDay = endDay
        }

        return (start: startDay, end: endDay)
    }

    static func normalizedAppUsageDateRange(
        start: Date,
        end: Date,
        maxDays: Int = DashboardViewModel.maxAppUsageRangeDays,
        calendar: Calendar = .current,
        now: Date = Date()
    ) -> (start: Date, end: Date) {
        let unbounded = normalizedUnboundedAppUsageDateRange(
            start: start,
            end: end,
            calendar: calendar,
            now: now
        )
        let startDay = unbounded.start
        var endDay = unbounded.end

        let boundedMaxDays = max(1, maxDays)
        let maxOffset = boundedMaxDays - 1
        if let maxEnd = calendar.date(byAdding: .day, value: maxOffset, to: startDay),
           endDay > maxEnd {
            endDay = maxEnd
        }

        return (start: startDay, end: endDay)
    }

    public var appUsageDateRange: DateRangeCriterion {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: appUsageRangeStart)
        let endDay = calendar.startOfDay(for: appUsageRangeEnd)
        let end = calendar.date(bySettingHour: 23, minute: 59, second: 59, of: endDay) ?? endDay
        return DateRangeCriterion(start: start, end: end)
    }

    public var appUsageRangeDaySpan: Int {
        let calendar = Calendar.current
        let startDay = calendar.startOfDay(for: appUsageRangeStart)
        let endDay = calendar.startOfDay(for: appUsageRangeEnd)
        let rawSpan = (calendar.dateComponents([.day], from: startDay, to: endDay).day ?? 0) + 1
        return max(1, rawSpan)
    }

    public var isDefaultAppUsageRangeSelected: Bool {
        let calendar = Calendar.current
        let defaultRange = Self.defaultAppUsageDateRange(calendar: calendar, now: Date())
        return calendar.isDate(appUsageRangeStart, inSameDayAs: defaultRange.start)
            && calendar.isDate(appUsageRangeEnd, inSameDayAs: defaultRange.end)
    }

    public var canShiftAppUsageRangeBackward: Bool {
        true
    }

    public var canShiftAppUsageRangeForward: Bool {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let spanDays = appUsageRangeDaySpan
        guard let shiftedEnd = calendar.date(byAdding: .day, value: spanDays, to: appUsageRangeEnd) else {
            return false
        }
        return calendar.startOfDay(for: shiftedEnd) <= today
    }

    public var appUsageQueryRange: (start: Date, end: Date) {
        resolvedAppUsageQueryRange()
    }

    public func setAppUsageDateRange(
        from range: DateRangeCriterion,
        source: String = "dashboard_app_usage_calendar"
    ) async {
        guard range.hasBounds else {
            await resetAppUsageDateRangeToDefault(source: source)
            return
        }

        guard let start = range.start ?? range.end,
              let end = range.end ?? range.start else {
            return
        }

        let requestedRange = Self.normalizedUnboundedAppUsageDateRange(start: start, end: end)
        let calendar = Calendar.current
        let requestedDays = max(
            1,
            (calendar.dateComponents([.day], from: requestedRange.start, to: requestedRange.end).day ?? 0) + 1
        )
        guard requestedDays <= Self.maxAppUsageRangeDays else {
            appUsageRangeErrorText = "Date range must be 31 days or less."
            recordAppUsageDateRangeAction(
                action: "range_too_large",
                source: source,
                start: requestedRange.start,
                end: requestedRange.end,
                rangeDays: requestedDays
            )
            return
        }

        await applyAppUsageDateRange(
            start: requestedRange.start,
            end: requestedRange.end,
            source: source,
            action: "set_range",
            shouldRecordMetric: true
        )
    }

    public func resetAppUsageDateRangeToDefault(
        source: String = "dashboard_app_usage_default"
    ) async {
        let defaultRange = Self.defaultAppUsageDateRange()
        await applyAppUsageDateRange(
            start: defaultRange.start,
            end: defaultRange.end,
            source: source,
            action: "reset_default",
            shouldRecordMetric: true
        )
    }

    public func shiftAppUsageDateRange(
        by direction: Int,
        source: String
    ) async {
        guard direction == -1 || direction == 1 else { return }

        let calendar = Calendar.current
        let spanDays = appUsageRangeDaySpan
        guard let shiftedStart = calendar.date(byAdding: .day, value: direction * spanDays, to: appUsageRangeStart),
              let shiftedEnd = calendar.date(byAdding: .day, value: direction * spanDays, to: appUsageRangeEnd) else {
            return
        }

        await applyAppUsageDateRange(
            start: shiftedStart,
            end: shiftedEnd,
            source: source,
            action: direction < 0 ? "shift_previous" : "shift_next",
            shouldRecordMetric: true
        )
    }

    private func applyAppUsageDateRange(
        start: Date,
        end: Date,
        source: String,
        action: String,
        shouldRecordMetric: Bool
    ) async {
        let applyStartedAt = CFAbsoluteTimeGetCurrent()
        let normalized = Self.normalizedAppUsageDateRange(start: start, end: end)
        let calendar = Calendar.current
        let startChanged = !calendar.isDate(normalized.start, inSameDayAs: appUsageRangeStart)
        let endChanged = !calendar.isDate(normalized.end, inSameDayAs: appUsageRangeEnd)
        let normalizedRangeLabel = dashboardPerfRangeLabel(start: normalized.start, end: normalized.end)

        appUsageRangeStart = normalized.start
        appUsageRangeEnd = normalized.end
        appUsageRangeLabel = Self.formatAppUsageRangeLabel(start: normalized.start, end: normalized.end)
        weekDateRange = appUsageRangeLabel
        appUsageRangeErrorText = nil

        guard startChanged || endChanged else {
            return
        }

        if shouldRecordMetric {
            recordAppUsageDateRangeAction(
                action: action,
                source: source,
                start: normalized.start,
                end: normalized.end
            )
        }

        await loadStatistics(reason: "range_\(action):\(source)")

        let applyElapsedMs = elapsedMs(since: applyStartedAt)
        Log.recordLatency(
            "dashboard.range.apply_ms",
            valueMs: applyElapsedMs,
            category: .ui,
            summaryEvery: 10,
            warningThresholdMs: 1500,
            criticalThresholdMs: 5000
        )
        let applyMessage = "[DASHBOARD-RANGE] COMPLETE action='\(action)' source='\(source)' spanDays=\(appUsageRangeDaySpan) range=\(normalizedRangeLabel) elapsed=\(formattedMs(applyElapsedMs))ms"
        if applyElapsedMs >= 5000 {
            Log.warning(applyMessage, category: .ui)
        }
    }

    private func resolvedAppUsageQueryRange(now: Date = Date()) -> (start: Date, end: Date) {
        let calendar = Calendar.current
        let startDay = calendar.startOfDay(for: appUsageRangeStart)
        let endDay = calendar.startOfDay(for: appUsageRangeEnd)
        let endOfDay = calendar.date(bySettingHour: 23, minute: 59, second: 59, of: endDay) ?? endDay
        let queryEnd = min(endOfDay, now)
        return (start: startDay, end: max(startDay, queryEnd))
    }

    private static func formatAppUsageRangeLabel(
        start: Date,
        end: Date,
        calendar: Calendar = .current
    ) -> String {
        let startDay = calendar.startOfDay(for: start)
        let endDay = calendar.startOfDay(for: end)
        let sameDay = calendar.isDate(startDay, inSameDayAs: endDay)
        let sameYear = calendar.isDate(startDay, equalTo: endDay, toGranularity: .year)
        let currentYear = calendar.component(.year, from: Date())
        let includeYear = !sameYear || calendar.component(.year, from: startDay) != currentYear

        let formatter = DateFormatter()
        formatter.dateFormat = includeYear ? "MMM d, yyyy" : "MMM d"

        if sameDay {
            return formatter.string(from: startDay)
        }

        return "\(formatter.string(from: startDay)) - \(formatter.string(from: endDay))"
    }

    private func dashboardPerfDayLabel(_ date: Date) -> String {
        Self.dashboardPerfDateFormatter.string(from: Calendar.current.startOfDay(for: date))
    }

    private func dashboardPerfRangeLabel(start: Date, end: Date) -> String {
        "\(dashboardPerfDayLabel(start))...\(dashboardPerfDayLabel(end))"
    }

    private func elapsedMs(since start: CFAbsoluteTime) -> Double {
        (CFAbsoluteTimeGetCurrent() - start) * 1000
    }

    private func formattedMs(_ valueMs: Double) -> String {
        String(format: "%.1f", valueMs)
    }

    private func nextDashboardLoadTraceID(prefix: String = "load") -> String {
        dashboardLoadTraceID &+= 1
        return "\(prefix)-\(dashboardLoadTraceID)"
    }

    private func recordAppUsageDateRangeAction(
        action: String,
        source: String,
        start: Date,
        end: Date,
        rangeDays: Int? = nil
    ) {
        let metadata = Self.jsonMetadata([
            "action": action,
            "source": source,
            "startDate": Int64(start.timeIntervalSince1970 * 1000),
            "endDate": Int64(end.timeIntervalSince1970 * 1000),
            "rangeDays": rangeDays ?? appUsageRangeDaySpan
        ])
        Self.recordMetric(
            coordinator: coordinator,
            type: .timelineFilterQuery,
            metadata: metadata
        )
    }

    private func loadAppUsageStatsForSelectedRange(traceID: String) async throws {
        let stageStartedAt = CFAbsoluteTimeGetCurrent()
        let queryRange = resolvedAppUsageQueryRange()
        let queryRangeLabel = dashboardPerfRangeLabel(start: queryRange.start, end: queryRange.end)

        do {
            let appStats = try await coordinator.getAppUsageStats(from: queryRange.start, to: queryRange.end)

            totalWeeklyTime = appStats.reduce(0) { $0 + $1.duration }
            let appNamesByBundleID = await resolveAppNames(bundleIDs: appStats.map(\.bundleID))
            weeklyAppUsage = appStats.map { stat in
                AppUsageData(
                    appBundleID: stat.bundleID,
                    appName: appNamesByBundleID[stat.bundleID] ?? Self.fallbackAppName(for: stat.bundleID),
                    duration: stat.duration,
                    uniqueItemCount: stat.uniqueItemCount,
                    percentage: totalWeeklyTime > 0 ? stat.duration / totalWeeklyTime : 0
                )
            }
            .sorted { $0.duration > $1.duration }

            let stageElapsedMs = elapsedMs(since: stageStartedAt)
            Log.recordLatency(
                "dashboard.query.app_usage_stats_ms",
                valueMs: stageElapsedMs,
                category: .ui,
                summaryEvery: 10,
                warningThresholdMs: 800,
                criticalThresholdMs: 2500
            )
            let stageMessage = "[DASHBOARD-LOAD][\(traceID)] APP_USAGE END apps=\(weeklyAppUsage.count) totalSeconds=\(Int(totalWeeklyTime)) elapsed=\(formattedMs(stageElapsedMs))ms"
            if stageElapsedMs >= 2500 {
                Log.warning(stageMessage, category: .ui)
            }
        } catch {
            let stageElapsedMs = elapsedMs(since: stageStartedAt)
            Log.error(
                "[DASHBOARD-LOAD][\(traceID)] APP_USAGE FAIL range=\(queryRangeLabel) after \(formattedMs(stageElapsedMs))ms: \(error)",
                category: .ui
            )
            throw error
        }
    }

    private func loadBackgroundMeta(traceID: String) async {
        let backgroundStartedAt = CFAbsoluteTimeGetCurrent()

        let totalStorageStartedAt = CFAbsoluteTimeGetCurrent()
        if let storage = try? await coordinator.getTotalStorageUsed() {
            let totalStorageElapsedMs = (CFAbsoluteTimeGetCurrent() - totalStorageStartedAt) * 1000
            Log.recordLatency(
                "dashboard.query.total_storage_ms",
                valueMs: totalStorageElapsedMs,
                category: .ui,
                summaryEvery: 10,
                warningThresholdMs: 500,
                criticalThresholdMs: 2000
            )
            totalStorageBytes = storage
        } else {
            let totalStorageElapsedMs = (CFAbsoluteTimeGetCurrent() - totalStorageStartedAt) * 1000
            Log.warning(
                "[DASHBOARD-LOAD][\(traceID)] BACKGROUND_META total_storage unavailable after \(String(format: "%.1f", totalStorageElapsedMs))ms",
                category: .ui
            )
        }

        let distinctDatesStartedAt = CFAbsoluteTimeGetCurrent()
        if let allDates = try? await coordinator.getDistinctDates() {
            let distinctDatesElapsedMs = (CFAbsoluteTimeGetCurrent() - distinctDatesStartedAt) * 1000
            Log.recordLatency(
                "dashboard.query.distinct_dates_ms",
                valueMs: distinctDatesElapsedMs,
                category: .ui,
                summaryEvery: 10,
                warningThresholdMs: 500,
                criticalThresholdMs: 2000
            )
            daysRecorded = allDates.count
            oldestRecordedDate = allDates.last // sorted descending, so last is oldest
        } else {
            let distinctDatesElapsedMs = (CFAbsoluteTimeGetCurrent() - distinctDatesStartedAt) * 1000
            Log.warning(
                "[DASHBOARD-LOAD][\(traceID)] BACKGROUND_META distinct_dates unavailable after \(String(format: "%.1f", distinctDatesElapsedMs))ms",
                category: .ui
            )
        }

        let backgroundElapsedMs = (CFAbsoluteTimeGetCurrent() - backgroundStartedAt) * 1000
        Log.recordLatency(
            "dashboard.query.background_meta_ms",
            valueMs: backgroundElapsedMs,
            category: .ui,
            summaryEvery: 10,
            warningThresholdMs: 1000,
            criticalThresholdMs: 4000
        )
    }

    public func loadStatistics(reason: String = "dashboard_refresh") async {
        let traceID = nextDashboardLoadTraceID()
        let loadStartedAt = CFAbsoluteTimeGetCurrent()
        isLoading = true
        error = nil
        defer { isLoading = false }

        // Update recording status
        updateRecordingStatus()
        updatePauseStatus()
        await refreshRecentCrashReportState()
        await refreshRecentWALFailureCrashState()

        do {
            let now = Date()

            // Keep selected app-usage range valid (day-boundary, <= today, <= max range).
            let normalizedAppUsageRange = Self.normalizedAppUsageDateRange(
                start: appUsageRangeStart,
                end: appUsageRangeEnd,
                now: now
            )
            appUsageRangeStart = normalizedAppUsageRange.start
            appUsageRangeEnd = normalizedAppUsageRange.end
            appUsageRangeLabel = Self.formatAppUsageRangeLabel(
                start: normalizedAppUsageRange.start,
                end: normalizedAppUsageRange.end
            )
            weekDateRange = appUsageRangeLabel
            let selectedRange = resolvedAppUsageQueryRange(now: now)
            let rangeStart = selectedRange.start
            let rangeEnd = selectedRange.end
            let selectedRangeLabel = dashboardPerfRangeLabel(start: rangeStart, end: rangeEnd)

            let appUsageStartedAt = CFAbsoluteTimeGetCurrent()
            let dailyGraphStartedAt = CFAbsoluteTimeGetCurrent()
            async let backgroundMetaTask: Void = loadBackgroundMeta(traceID: traceID)
            async let appUsageTask: Void = loadAppUsageStatsForSelectedRange(traceID: traceID)
            async let dailyGraphTask: Void = loadDailyGraphData(rangeStart: rangeStart, rangeEnd: rangeEnd, traceID: traceID)

            // Await critical UI data first.
            try await appUsageTask
            let appUsageElapsedMs = elapsedMs(since: appUsageStartedAt)
            Log.recordLatency(
                "dashboard.load.app_usage_stage_ms",
                valueMs: appUsageElapsedMs,
                category: .ui,
                summaryEvery: 10,
                warningThresholdMs: 800,
                criticalThresholdMs: 2500
            )

            await dailyGraphTask
            let dailyGraphElapsedMs = elapsedMs(since: dailyGraphStartedAt)
            Log.recordLatency(
                "dashboard.load.daily_graph_stage_ms",
                valueMs: dailyGraphElapsedMs,
                category: .ui,
                summaryEvery: 10,
                warningThresholdMs: 1200,
                criticalThresholdMs: 5000
            )

            // Keep metadata updates in-flight with chart/query work.
            await backgroundMetaTask

            weeklyStorageBytes = dailyStorageData.reduce(0) { $0 + $1.value }
            totalDailyTime = totalWeeklyTime

            let loadElapsedMs = elapsedMs(since: loadStartedAt)
            Log.recordLatency(
                "dashboard.load.total_ms",
                valueMs: loadElapsedMs,
                category: .ui,
                summaryEvery: 10,
                warningThresholdMs: 1800,
                criticalThresholdMs: 7000
            )
            let completionMessage = "[DASHBOARD-LOAD][\(traceID)] END reason='\(reason)' range=\(selectedRangeLabel) apps=\(weeklyAppUsage.count) days=\(dailyScreenTimeData.count) elapsed=\(formattedMs(loadElapsedMs))ms"
            if loadElapsedMs >= 7000 {
                Log.warning(completionMessage, category: .ui)
            }
        } catch {
            let loadElapsedMs = elapsedMs(since: loadStartedAt)
            Log.recordLatency(
                "dashboard.load.total_ms",
                valueMs: loadElapsedMs,
                category: .ui,
                summaryEvery: 10,
                warningThresholdMs: 1800,
                criticalThresholdMs: 7000
            )
            Log.error(
                "[DASHBOARD-LOAD][\(traceID)] FAIL reason='\(reason)' after \(formattedMs(loadElapsedMs))ms: \(error)",
                category: .ui
            )
            self.error = "Failed to load statistics: \(error.localizedDescription)"
        }
    }

    // MARK: - Daily Graph Data

    /// Load daily data for all metric graphs using the selected dashboard date range.
    private func loadDailyGraphData(rangeStart: Date, rangeEnd: Date, traceID: String) async {
        let totalStartedAt = CFAbsoluteTimeGetCurrent()
        let calendar = Calendar.current

        // Generate all days in the selected range.
        var allDaysAccumulator: [Date] = []
        let firstDay = calendar.startOfDay(for: rangeStart)
        let lastDay = calendar.startOfDay(for: rangeEnd)
        var currentDay = firstDay
        while currentDay <= lastDay {
            allDaysAccumulator.append(currentDay)
            currentDay = calendar.date(byAdding: .day, value: 1, to: currentDay)!
        }
        let allDays = allDaysAccumulator

        var stage = "daily_screen_time"
        do {
            async let screenTimeResult: ([(date: Date, value: Int64)], Double) = {
                let startedAt = CFAbsoluteTimeGetCurrent()
                let data = try await coordinator.getDailyScreenTime(
                    from: rangeStart,
                    to: rangeEnd
                )
                return (data, (CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
            }()

            async let dailyStorageResult: ([DailyDataPoint], Double) = {
                let startedAt = CFAbsoluteTimeGetCurrent()
                let data = try await loadDailyStorageData(for: allDays, traceID: traceID)
                return (data, (CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
            }()

            async let timelineResult: ([(date: Date, value: Int64)], Double) = {
                let startedAt = CFAbsoluteTimeGetCurrent()
                let data = try await coordinator.getDailyMetrics(
                    metricType: .timelineOpens,
                    from: rangeStart,
                    to: rangeEnd
                )
                return (data, (CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
            }()

            async let searchesResult: ([(date: Date, value: Int64)], Double) = {
                let startedAt = CFAbsoluteTimeGetCurrent()
                let data = try await coordinator.getDailyMetrics(
                    metricType: .searches,
                    from: rangeStart,
                    to: rangeEnd
                )
                return (data, (CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
            }()

            async let textCopiesResult: ([(date: Date, value: Int64)], Double) = {
                let startedAt = CFAbsoluteTimeGetCurrent()
                let data = try await coordinator.getDailyMetrics(
                    metricType: .textCopies,
                    from: rangeStart,
                    to: rangeEnd
                )
                return (data, (CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
            }()

            stage = "daily_screen_time"
            let (screenTimeData, screenTimeElapsedMs) = try await screenTimeResult
            Log.recordLatency(
                "dashboard.query.daily_screen_time_ms",
                valueMs: screenTimeElapsedMs,
                category: .ui,
                summaryEvery: 10,
                warningThresholdMs: 700,
                criticalThresholdMs: 2000
            )
            dailyScreenTimeData = fillMissingDays(data: screenTimeData, allDays: allDays)

            stage = "daily_storage"
            let (storageData, dailyStorageElapsedMs) = try await dailyStorageResult
            dailyStorageData = storageData
            Log.recordLatency(
                "dashboard.query.daily_storage_ms",
                valueMs: dailyStorageElapsedMs,
                category: .ui,
                summaryEvery: 10,
                warningThresholdMs: 1200,
                criticalThresholdMs: 5000
            )

            stage = "daily_timeline_opens"
            let (timelineData, timelineElapsedMs) = try await timelineResult
            Log.recordLatency(
                "dashboard.query.daily_timeline_opens_ms",
                valueMs: timelineElapsedMs,
                category: .ui,
                summaryEvery: 10,
                warningThresholdMs: 500,
                criticalThresholdMs: 1500
            )
            dailyTimelineOpensData = fillMissingDays(data: timelineData, allDays: allDays)
            timelineOpensThisWeek = dailyTimelineOpensData.reduce(0) { $0 + $1.value }

            stage = "daily_searches"
            let (searchesData, searchesElapsedMs) = try await searchesResult
            Log.recordLatency(
                "dashboard.query.daily_searches_ms",
                valueMs: searchesElapsedMs,
                category: .ui,
                summaryEvery: 10,
                warningThresholdMs: 500,
                criticalThresholdMs: 1500
            )
            dailySearchesData = fillMissingDays(data: searchesData, allDays: allDays)
            searchesThisWeek = dailySearchesData.reduce(0) { $0 + $1.value }

            stage = "daily_text_copies"
            let (textCopiesData, textCopiesElapsedMs) = try await textCopiesResult
            Log.recordLatency(
                "dashboard.query.daily_text_copies_ms",
                valueMs: textCopiesElapsedMs,
                category: .ui,
                summaryEvery: 10,
                warningThresholdMs: 500,
                criticalThresholdMs: 1500
            )
            dailyTextCopiesData = fillMissingDays(data: textCopiesData, allDays: allDays)
            textCopiesThisWeek = dailyTextCopiesData.reduce(0) { $0 + $1.value }

            let totalElapsedMs = elapsedMs(since: totalStartedAt)
            Log.recordLatency(
                "dashboard.load.daily_graph_ms",
                valueMs: totalElapsedMs,
                category: .ui,
                summaryEvery: 10,
                warningThresholdMs: 1400,
                criticalThresholdMs: 6000
            )
            let completionMessage = "[DASHBOARD-LOAD][\(traceID)] DAILY_GRAPH END days=\(allDays.count) elapsed=\(formattedMs(totalElapsedMs))ms"
            if totalElapsedMs >= 6000 {
                Log.warning(completionMessage, category: .ui)
            }

        } catch {
            let totalElapsedMs = elapsedMs(since: totalStartedAt)
            Log.recordLatency(
                "dashboard.load.daily_graph_ms",
                valueMs: totalElapsedMs,
                category: .ui,
                summaryEvery: 10,
                warningThresholdMs: 1400,
                criticalThresholdMs: 6000
            )
            Log.error(
                "[DASHBOARD-LOAD][\(traceID)] DAILY_GRAPH FAIL stage=\(stage) after \(formattedMs(totalElapsedMs))ms: \(error)",
                category: .ui
            )
            // Initialize with empty data on error
            dailyScreenTimeData = allDays.map { DailyDataPoint(date: $0, value: 0) }
            dailyStorageData = allDays.map { DailyDataPoint(date: $0, value: 0) }
            dailyTimelineOpensData = allDays.map { DailyDataPoint(date: $0, value: 0) }
            dailySearchesData = allDays.map { DailyDataPoint(date: $0, value: 0) }
            dailyTextCopiesData = allDays.map { DailyDataPoint(date: $0, value: 0) }
            timelineOpensThisWeek = 0
            searchesThisWeek = 0
            textCopiesThisWeek = 0
        }
    }

    /// Load storage for each day's folder
    private func loadDailyStorageData(for days: [Date], traceID: String) async throws -> [DailyDataPoint] {
        let totalStartedAt = CFAbsoluteTimeGetCurrent()
        let calendar = Calendar.current

        let dbEstimateStartedAt = CFAbsoluteTimeGetCurrent()
        let dbEstimates: [(date: Date, value: Int64)]
        if let firstDay = days.first, let lastDay = days.last {
            dbEstimates = try await coordinator.getDailyDBStorageEstimatedBytes(
                from: firstDay,
                to: lastDay
            )
        } else {
            dbEstimates = []
        }
        let dbEstimateElapsedMs = elapsedMs(since: dbEstimateStartedAt)
        Log.recordLatency(
            "dashboard.query.daily_db_estimates_ms",
            valueMs: dbEstimateElapsedMs,
            category: .ui,
            summaryEvery: 10,
            warningThresholdMs: 500,
            criticalThresholdMs: 2000
        )
        let dbEstimateByDay = Dictionary(
            uniqueKeysWithValues: dbEstimates.map { (calendar.startOfDay(for: $0.date), $0.value) }
        )

        var dataPoints: [DailyDataPoint] = []
        var dayQueryTotalMs = 0.0
        var slowestDay: Date?
        var slowestDayMs = 0.0
        for day in days {
            let dayQueryStartedAt = CFAbsoluteTimeGetCurrent()
            let dayStorage = try await coordinator.getStorageUsedForDateRange(from: day, to: day)
            let dayQueryElapsedMs = elapsedMs(since: dayQueryStartedAt)
            dayQueryTotalMs += dayQueryElapsedMs
            if dayQueryElapsedMs > slowestDayMs {
                slowestDayMs = dayQueryElapsedMs
                slowestDay = day
            }
            Log.recordLatency(
                "dashboard.query.storage_single_day_ms",
                valueMs: dayQueryElapsedMs,
                category: .ui,
                summaryEvery: 20,
                warningThresholdMs: 250,
                criticalThresholdMs: 1000
            )
            if dayQueryElapsedMs >= 1000 {
                Log.warning(
                    "[DASHBOARD-LOAD][\(traceID)] DAILY_STORAGE slow_day date=\(dashboardPerfDayLabel(day)) elapsed=\(formattedMs(dayQueryElapsedMs))ms",
                    category: .ui
                )
            }
            let dbEstimate = dbEstimateByDay[calendar.startOfDay(for: day)] ?? 0
            dataPoints.append(DailyDataPoint(date: day, value: dayStorage + dbEstimate))
        }

        let totalElapsedMs = elapsedMs(since: totalStartedAt)
        let averageDayMs = days.isEmpty ? 0 : dayQueryTotalMs / Double(days.count)
        let slowestDayLabel = slowestDay.map(dashboardPerfDayLabel) ?? "none"
        Log.recordLatency(
            "dashboard.load.daily_storage_ms",
            valueMs: totalElapsedMs,
            category: .ui,
            summaryEvery: 10,
            warningThresholdMs: 1200,
            criticalThresholdMs: 5000
        )
        let completionMessage = "[DASHBOARD-LOAD][\(traceID)] DAILY_STORAGE END days=\(days.count) elapsed=\(formattedMs(totalElapsedMs))ms avgDay=\(formattedMs(averageDayMs))ms slowestDay=\(slowestDayLabel) slowestDayMs=\(formattedMs(slowestDayMs))ms"
        if totalElapsedMs >= 5000 {
            Log.warning(completionMessage, category: .ui)
        }
        return dataPoints
    }

    /// Fill missing days with zero values so the graph has a point for every day in-range.
    private func fillMissingDays(data: [(date: Date, value: Int64)], allDays: [Date]) -> [DailyDataPoint] {
        let calendar = Calendar.current
        let dataByDay = Dictionary(uniqueKeysWithValues: data.map { (calendar.startOfDay(for: $0.date), $0.value) })

        return allDays.map { day in
            let startOfDay = calendar.startOfDay(for: day)
            let value = dataByDay[startOfDay] ?? 0
            return DailyDataPoint(date: day, value: value)
        }
    }

    // MARK: - App Session Details

    /// Fetch detailed sessions for a specific app with pagination
    /// - Parameters:
    ///   - bundleID: The app's bundle identifier
    ///   - offset: Number of sessions to skip (for pagination)
    ///   - limit: Maximum number of sessions to return
    /// - Returns: Array of sessions sorted by most recent first
    public func getSessionsForApp(bundleID: String, offset: Int, limit: Int) async -> [AppSessionDetail] {
        do {
            let queryRange = resolvedAppUsageQueryRange()

            // Use efficient SQL query with bundleID filter, time range, and pagination
            let segments = try await coordinator.getSegments(
                bundleID: bundleID,
                from: queryRange.start,
                to: queryRange.end,
                limit: limit,
                offset: offset
            )
            let appNamesByBundleID = await resolveAppNames(bundleIDs: segments.map(\.bundleID))

            return segments.map { segment in
                AppSessionDetail(
                    id: segment.id.value,
                    appBundleID: segment.bundleID,
                    appName: appNamesByBundleID[segment.bundleID] ?? Self.fallbackAppName(for: segment.bundleID),
                    startDate: segment.startDate,
                    endDate: segment.endDate,
                    windowName: segment.windowName
                )
            }
        } catch {
            Log.error("[DashboardViewModel] Failed to fetch sessions for app: \(error)", category: .ui)
            return []
        }
    }

    /// Fetch window usage data for a specific app (aggregated by windowName or domain for browsers)
    /// For browsers: includes pre-aggregated tab counts for website rows.
    /// - Parameter bundleID: The app's bundle identifier
    /// - Returns: Array of window usage sorted by type (websites first) then duration descending
    public func getWindowUsageForApp(bundleID: String) async -> [WindowUsageData] {
        do {
            let queryRange = resolvedAppUsageQueryRange()

            let windowStats = try await coordinator.getWindowUsageForApp(
                bundleID: bundleID,
                from: queryRange.start,
                to: queryRange.end
            )

            // Calculate total duration for percentage calculation
            let totalDuration = windowStats.reduce(0) { $0 + $1.duration }

            return windowStats.map { stat in
                WindowUsageData(
                    windowName: stat.windowName,
                    isWebsite: stat.isWebsite,
                    duration: stat.duration,
                    percentage: totalDuration > 0 ? stat.duration / totalDuration : 0,
                    tabCount: stat.tabCount
                )
            }
        } catch {
            Log.error("[DashboardViewModel] Failed to fetch window usage for app: \(error)", category: .ui)
            return []
        }
    }

    /// Fetch browser tab usage data (aggregated by tab title/windowName with full URL)
    /// - Parameter bundleID: The browser's bundle identifier
    /// - Returns: Array of tab usage sorted by duration descending, with full URLs for subtitle display
    public func getBrowserTabUsage(bundleID: String) async -> [WindowUsageData] {
        do {
            let queryRange = resolvedAppUsageQueryRange()

            let tabStats = try await coordinator.getBrowserTabUsage(
                bundleID: bundleID,
                from: queryRange.start,
                to: queryRange.end
            )

            // Calculate total duration for percentage calculation
            let totalDuration = tabStats.reduce(0) { $0 + $1.duration }

            return tabStats.map { stat in
                WindowUsageData(
                    windowName: stat.windowName,
                    browserUrl: stat.browserUrl,
                    isWebsite: true,
                    duration: stat.duration,
                    percentage: totalDuration > 0 ? stat.duration / totalDuration : 0
                )
            }
        } catch {
            Log.error("[DashboardViewModel] Failed to fetch browser tab usage: \(error)", category: .ui)
            return []
        }
    }

    /// Fetch browser tabs filtered by a specific domain (for nested website breakdown)
    public func getBrowserTabsForDomain(bundleID: String, domain: String) async -> [WindowUsageData] {
        do {
            let queryRange = resolvedAppUsageQueryRange()

            let tabStats = try await coordinator.getBrowserTabUsageForDomain(
                bundleID: bundleID,
                domain: domain,
                from: queryRange.start,
                to: queryRange.end
            )

            // Calculate total duration for percentage calculation
            let totalDuration = tabStats.reduce(0) { $0 + $1.duration }

            return tabStats.map { stat in
                WindowUsageData(
                    windowName: stat.windowName,
                    browserUrl: stat.browserUrl,
                    isWebsite: true,
                    duration: stat.duration,
                    percentage: totalDuration > 0 ? stat.duration / totalDuration : 0
                )
            }
        } catch {
            Log.error("[DashboardViewModel] Failed to fetch browser tabs for domain: \(error)", category: .ui)
            return []
        }
    }

    /// Fetch detailed sessions for a specific app and window/domain with pagination
    /// - Parameters:
    ///   - bundleID: The app's bundle identifier
    ///   - windowNameOrDomain: The window name or domain to filter by
    ///   - offset: Number of sessions to skip (for pagination)
    ///   - limit: Maximum number of sessions to return
    /// - Returns: Array of sessions sorted by most recent first
    public func getSessionsForAppWindow(bundleID: String, windowNameOrDomain: String, offset: Int, limit: Int) async -> [AppSessionDetail] {
        do {
            let queryRange = resolvedAppUsageQueryRange()

            // Use efficient SQL query with bundleID and window/domain filter, time range, and pagination
            let segments = try await coordinator.getSegments(
                bundleID: bundleID,
                windowNameOrDomain: windowNameOrDomain,
                from: queryRange.start,
                to: queryRange.end,
                limit: limit,
                offset: offset
            )
            let appNamesByBundleID = await resolveAppNames(bundleIDs: segments.map(\.bundleID))

            return segments.map { segment in
                AppSessionDetail(
                    id: segment.id.value,
                    appBundleID: segment.bundleID,
                    appName: appNamesByBundleID[segment.bundleID] ?? Self.fallbackAppName(for: segment.bundleID),
                    startDate: segment.startDate,
                    endDate: segment.endDate,
                    windowName: segment.windowName
                )
            }
        } catch {
            Log.error("[DashboardViewModel] Failed to fetch sessions for app window: \(error)", category: .ui)
            return []
        }
    }

    private func resolveAppNames(bundleIDs: [String]) async -> [String: String] {
        let uniqueBundleIDs = Array(Set(bundleIDs.filter { !$0.isEmpty }))
        guard !uniqueBundleIDs.isEmpty else { return [:] }

        return await Task.detached(priority: .utility) {
            var resolved: [String: String] = [:]
            resolved.reserveCapacity(uniqueBundleIDs.count)
            for bundleID in uniqueBundleIDs {
                resolved[bundleID] = AppNameResolver.shared.displayName(for: bundleID)
            }
            return resolved
        }.value
    }

    nonisolated private static func fallbackAppName(for bundleID: String) -> String {
        let candidate = bundleID.components(separatedBy: ".").last ?? bundleID
        return candidate.isEmpty ? bundleID : candidate
    }

    // MARK: - Metric Event Recording

    /// Record a timeline open event
    public static func recordTimelineOpen(coordinator: AppCoordinator) {
        Task {
            try? await coordinator.recordMetricEvent(metricType: .timelineOpens)
        }
    }

    /// Record a search event
    /// - Parameters:
    ///   - coordinator: The app coordinator
    ///   - query: The search query text to store in metadata
    public static func recordSearch(coordinator: AppCoordinator, query: String) {
        Task {
            try? await coordinator.recordMetricEvent(metricType: .searches, metadata: query)
        }
    }

    /// Record a text copy event
    /// - Parameters:
    ///   - coordinator: The app coordinator
    ///   - text: The copied text to store in metadata
    public static func recordTextCopy(coordinator: AppCoordinator, text: String) {
        Task {
            try? await coordinator.recordMetricEvent(metricType: .textCopies, metadata: text)
        }
    }

    /// Record an image copy event
    /// - Parameters:
    ///   - coordinator: The app coordinator
    ///   - frameID: Optional frame ID that was copied
    public static func recordImageCopy(coordinator: AppCoordinator, frameID: Int64? = nil) {
        Task {
            let metadata = frameID.map { "\($0)" }
            try? await coordinator.recordMetricEvent(metricType: .imageCopies, metadata: metadata)
        }
    }

    /// Record an image save event
    /// - Parameters:
    ///   - coordinator: The app coordinator
    ///   - frameID: Optional frame ID that was saved
    public static func recordImageSave(coordinator: AppCoordinator, frameID: Int64? = nil) {
        Task {
            let metadata = frameID.map { "\($0)" }
            try? await coordinator.recordMetricEvent(metricType: .imageSaves, metadata: metadata)
        }
    }

    /// Record a deeplink copy event
    /// - Parameters:
    ///   - coordinator: The app coordinator
    ///   - url: The deeplink URL that was copied
    public static func recordDeeplinkCopy(coordinator: AppCoordinator, url: String) {
        Task {
            try? await coordinator.recordMetricEvent(metricType: .deeplinkCopies, metadata: url)
        }
    }

    /// Record timeline session duration (only if > 3 seconds)
    /// - Parameters:
    ///   - coordinator: The app coordinator
    ///   - duration: Duration in milliseconds
    public static func recordTimelineSession(coordinator: AppCoordinator, durationMs: Int64) {
        guard durationMs > 3000 else { return }  // Only record if > 3 seconds
        Task {
            try? await coordinator.recordMetricEvent(metricType: .timelineSessionDuration, metadata: "\(durationMs)")
        }
    }

    /// Record a filtered search query
    /// - Parameters:
    ///   - coordinator: The app coordinator
    ///   - query: The search query text
    ///   - filters: JSON string of applied filters
    public static func recordFilteredSearch(coordinator: AppCoordinator, query: String, filters: String) {
        Task {
            let json = "{\"query\":\"\(query)\",\"filters\":\(filters)}"
            try? await coordinator.recordMetricEvent(metricType: .filteredSearchQuery, metadata: json)
        }
    }

    /// Record a timeline filter query
    /// - Parameters:
    ///   - coordinator: The app coordinator
    ///   - filterJson: JSON string of timeline filters
    public static func recordTimelineFilter(coordinator: AppCoordinator, filterJson: String) {
        Task {
            try? await coordinator.recordMetricEvent(metricType: .timelineFilterQuery, metadata: filterJson)
        }
    }

    /// Record scrub distance for the session
    /// - Parameters:
    ///   - coordinator: The app coordinator
    ///   - distancePixels: Total scrub distance in pixels
    public static func recordScrubDistance(coordinator: AppCoordinator, distancePixels: Double) {
        Task {
            try? await coordinator.recordMetricEvent(metricType: .scrubDistance, metadata: "\(Int(distancePixels))")
        }
    }

    /// Record a search dialog open event
    public static func recordSearchDialogOpen(coordinator: AppCoordinator) {
        Task {
            try? await coordinator.recordMetricEvent(metricType: .searchDialogOpens)
        }
    }

    /// Record an OCR reprocess request
    public static func recordOCRReprocess(coordinator: AppCoordinator) {
        Task {
            try? await coordinator.recordMetricEvent(metricType: .ocrReprocessRequests)
        }
    }

    /// Record an arrow key navigation event
    /// - Parameters:
    ///   - coordinator: The app coordinator
    ///   - direction: "left" or "right"
    public static func recordArrowKeyNavigation(coordinator: AppCoordinator, direction: String) {
        Task {
            try? await coordinator.recordMetricEvent(metricType: .arrowKeyNavigation, metadata: direction)
        }
    }

    /// Record a shift+drag zoom region event
    /// - Parameters:
    ///   - coordinator: The app coordinator
    ///   - region: The bounding box of the zoom region
    ///   - screenSize: The size of the screen
    public static func recordShiftDragZoom(coordinator: AppCoordinator, region: CGRect, screenSize: CGSize) {
        Task {
            let json = "{\"region\":{\"x\":\(region.origin.x),\"y\":\(region.origin.y),\"width\":\(region.width),\"height\":\(region.height)},\"screenSize\":{\"width\":\(screenSize.width),\"height\":\(screenSize.height)}}"
            try? await coordinator.recordMetricEvent(metricType: .shiftDragZoomRegion, metadata: json)
        }
    }

    /// Record a shift+drag text copy event
    /// - Parameters:
    ///   - coordinator: The app coordinator
    ///   - copiedText: The text that was copied
    public static func recordShiftDragTextCopy(coordinator: AppCoordinator, copiedText: String) {
        Task {
            try? await coordinator.recordMetricEvent(metricType: .shiftDragTextCopy, metadata: copiedText)
        }
    }

    /// Record transient OCR triggered by drag-start on a still-only frame (p=4).
    /// - Parameters:
    ///   - coordinator: The app coordinator
    ///   - gesture: Gesture that triggered OCR ("shift-drag" or "cmd-drag")
    ///   - frameID: Frame identifier for diagnostic correlation
    public static func recordStillFrameDragOCR(coordinator: AppCoordinator, gesture: String, frameID: Int64) {
        Task {
            let json = "{\"gesture\":\"\(gesture)\",\"frameID\":\(frameID)}"
            try? await coordinator.recordMetricEvent(metricType: .stillFrameDragOCR, metadata: json)
        }
    }

    /// Record an app launch event
    public static func recordAppLaunch(coordinator: AppCoordinator) {
        Task {
            try? await coordinator.recordMetricEvent(metricType: .appLaunches)
        }
    }

    public static func recordCrashAutoRestart(
        coordinator: AppCoordinator,
        source: CrashRecoverySupport.RelaunchSource
    ) {
        recordMetric(
            coordinator: coordinator,
            type: .crashAutoRestart,
            metadata: jsonMetadata(["source": source.rawValue])
        )
    }

    /// Record a keyboard shortcut usage
    /// - Parameters:
    ///   - coordinator: The app coordinator
    ///   - shortcut: The shortcut identifier (e.g. "cmd+shift+t", "cmd+f")
    public static func recordKeyboardShortcut(coordinator: AppCoordinator, shortcut: String) {
        Task {
            try? await coordinator.recordMetricEvent(metricType: .keyboardShortcut, metadata: shortcut)
        }
    }

    /// Record a debug-only watchdog hang trigger from the dashboard.
    public static func recordDebugWatchdogHangTriggered(coordinator: AppCoordinator) {
        recordMetric(coordinator: coordinator, type: .debugWatchdogHangTriggered)
    }

    /// Record a debug-only forced termination trigger from the dashboard.
    public static func recordDebugForcedTerminationTriggered(coordinator: AppCoordinator) {
        recordMetric(coordinator: coordinator, type: .debugForcedTerminationTriggered)
    }

    public static func recordDeveloperSettingToggle(
        coordinator: AppCoordinator,
        source: String,
        settingKey: String,
        isEnabled: Bool
    ) {
        let metadata = jsonMetadata([
            "source": source,
            "settingKey": settingKey,
            "isEnabled": isEnabled
        ])
        recordMetric(
            coordinator: coordinator,
            type: .developerSettingToggle,
            metadata: metadata
        )
    }
    /// Record a debug-only crash trigger from the dashboard.
    public static func recordDebugCrashTriggered(coordinator: AppCoordinator) {
        recordMetric(coordinator: coordinator, type: .debugCrashTriggered)
    }

    public static func recordDateSearchSubmitted(
        coordinator: AppCoordinator,
        source: String,
        query: String,
        queryLength: Int,
        frameIDSearchEnabled: Bool,
        lookedLikeFrameID: Bool
    ) {
        let metadata = jsonMetadata([
            "source": source,
            "query": query,
            "queryLength": queryLength,
            "frameIDSearchEnabled": frameIDSearchEnabled,
            "lookedLikeFrameID": lookedLikeFrameID
        ])
        recordMetric(coordinator: coordinator, type: .dateSearchSubmitted, metadata: metadata)
    }

    public static func recordDateSearchOutcome(
        coordinator: AppCoordinator,
        source: String,
        query: String,
        outcome: String,
        queryLength: Int,
        frameIDLookupAttempted: Bool,
        frameCount: Int? = nil
    ) {
        var payload: [String: Any] = [
            "source": source,
            "query": query,
            "outcome": outcome,
            "queryLength": queryLength,
            "frameIDLookupAttempted": frameIDLookupAttempted
        ]
        if let frameCount {
            payload["frameCount"] = frameCount
        }
        recordMetric(
            coordinator: coordinator,
            type: .dateSearchOutcome,
            metadata: jsonMetadata(payload)
        )
    }

    // MARK: - Extended Metrics

    private static func recordMetric(
        coordinator: AppCoordinator,
        type: DailyMetricsQueries.MetricType,
        metadata: String? = nil
    ) {
        Task {
            try? await coordinator.recordMetricEvent(metricType: type, metadata: metadata)
        }
    }

    private static func jsonMetadata(_ payload: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let json = String(data: data, encoding: .utf8) else {
            return nil
        }
        return json
    }

    public static func recordBrowserLinkOpened(
        coordinator: AppCoordinator,
        source: String,
        url: String,
        usedTextFragment: Bool,
        usedYouTubeTimestamp: Bool
    ) {
        let metadata = jsonMetadata([
            "source": source,
            "url": url,
            "usedTextFragment": usedTextFragment,
            "usedYouTubeTimestamp": usedYouTubeTimestamp
        ])
        recordMetric(
            coordinator: coordinator,
            type: .browserLinkOpened,
            metadata: metadata
        )
    }

    public static func recordSegmentHide(
        coordinator: AppCoordinator,
        source: String,
        segmentCount: Int,
        frameCount: Int,
        hiddenFilter: String
    ) {
        let metadata = jsonMetadata([
            "source": source,
            "segmentCount": segmentCount,
            "frameCount": frameCount,
            "hiddenFilter": hiddenFilter
        ])
        recordMetric(coordinator: coordinator, type: .segmentHide, metadata: metadata)
    }

    public static func recordSegmentUnhide(
        coordinator: AppCoordinator,
        source: String,
        segmentCount: Int,
        frameCount: Int,
        hiddenFilter: String,
        removedFromCurrentView: Bool
    ) {
        let metadata = jsonMetadata([
            "source": source,
            "segmentCount": segmentCount,
            "frameCount": frameCount,
            "hiddenFilter": hiddenFilter,
            "removedFromCurrentView": removedFromCurrentView
        ])
        recordMetric(coordinator: coordinator, type: .segmentUnhide, metadata: metadata)
    }

    public static func recordTagSubmenuOpen(
        coordinator: AppCoordinator,
        source: String,
        segmentCount: Int?,
        frameCount: Int?,
        selectedTagCount: Int?
    ) {
        var payload: [String: Any] = ["source": source]
        if let segmentCount {
            payload["segmentCount"] = segmentCount
        }
        if let frameCount {
            payload["frameCount"] = frameCount
        }
        if let selectedTagCount {
            payload["selectedTagCount"] = selectedTagCount
        }
        recordMetric(
            coordinator: coordinator,
            type: .tagSubmenuOpen,
            metadata: jsonMetadata(payload)
        )
    }

    public static func recordTagToggleOnBlock(
        coordinator: AppCoordinator,
        source: String,
        tagID: Int64,
        tagName: String,
        action: String,
        segmentCount: Int
    ) {
        let metadata = jsonMetadata([
            "source": source,
            "tagID": tagID,
            "tagName": tagName,
            "action": action,
            "segmentCount": segmentCount
        ])
        recordMetric(coordinator: coordinator, type: .tagToggleOnBlock, metadata: metadata)
    }

    public static func recordTagCreateAndAddOnBlock(
        coordinator: AppCoordinator,
        source: String,
        tagID: Int64,
        tagName: String,
        segmentCount: Int
    ) {
        let metadata = jsonMetadata([
            "source": source,
            "tagID": tagID,
            "tagName": tagName,
            "segmentCount": segmentCount
        ])
        recordMetric(coordinator: coordinator, type: .tagCreateAndAddOnBlock, metadata: metadata)
    }

    public static func recordCommentSubmenuOpen(
        coordinator: AppCoordinator,
        source: String,
        segmentCount: Int?,
        frameCount: Int?,
        existingCommentCount: Int?
    ) {
        var payload: [String: Any] = ["source": source]
        if let segmentCount {
            payload["segmentCount"] = segmentCount
        }
        if let frameCount {
            payload["frameCount"] = frameCount
        }
        if let existingCommentCount {
            payload["existingCommentCount"] = existingCommentCount
        }
        recordMetric(
            coordinator: coordinator,
            type: .commentSubmenuOpen,
            metadata: jsonMetadata(payload)
        )
    }

    public static func recordQuickCommentOpened(
        coordinator: AppCoordinator,
        source: String
    ) {
        recordMetric(
            coordinator: coordinator,
            type: .quickCommentOpened,
            metadata: jsonMetadata(["source": source])
        )
    }

    public static func recordQuickCommentClosed(
        coordinator: AppCoordinator,
        source: String
    ) {
        recordMetric(
            coordinator: coordinator,
            type: .quickCommentClosed,
            metadata: jsonMetadata(["source": source])
        )
    }

    public static func recordQuickCommentContextPreviewToggle(
        coordinator: AppCoordinator,
        source: String,
        isCollapsed: Bool
    ) {
        recordMetric(
            coordinator: coordinator,
            type: .quickCommentContextPreviewToggle,
            metadata: jsonMetadata([
                "source": source,
                "isCollapsed": isCollapsed
            ])
        )
    }

    public static func recordCommentAdded(
        coordinator: AppCoordinator,
        source: String,
        requestedSegmentCount: Int,
        linkedSegmentCount: Int,
        bodyLength: Int,
        attachmentCount: Int,
        hasFrameAnchor: Bool
    ) {
        let metadata = jsonMetadata([
            "source": source,
            "requestedSegmentCount": requestedSegmentCount,
            "linkedSegmentCount": linkedSegmentCount,
            "bodyLength": bodyLength,
            "attachmentCount": attachmentCount,
            "hasFrameAnchor": hasFrameAnchor
        ])
        recordMetric(coordinator: coordinator, type: .commentAdded, metadata: metadata)
    }

    public static func recordCommentDeletedFromBlock(
        coordinator: AppCoordinator,
        source: String,
        linkedSegmentCount: Int,
        hadFrameAnchor: Bool
    ) {
        let metadata = jsonMetadata([
            "source": source,
            "linkedSegmentCount": linkedSegmentCount,
            "hadFrameAnchor": hadFrameAnchor
        ])
        recordMetric(coordinator: coordinator, type: .commentDeletedFromBlock, metadata: metadata)
    }

    public static func recordCommentAttachmentPickerOpened(coordinator: AppCoordinator, source: String) {
        let metadata = jsonMetadata(["source": source])
        recordMetric(
            coordinator: coordinator,
            type: .commentAttachmentPickerOpened,
            metadata: metadata
        )
    }

    public static func recordCommentAttachmentOpened(
        coordinator: AppCoordinator,
        source: String,
        fileExtension: String
    ) {
        let metadata = jsonMetadata([
            "source": source,
            "fileExtension": fileExtension
        ])
        recordMetric(
            coordinator: coordinator,
            type: .commentAttachmentOpened,
            metadata: metadata
        )
    }

    public static func recordAllCommentsOpened(
        coordinator: AppCoordinator,
        source: String,
        anchorCommentID: Int64?
    ) {
        var payload: [String: Any] = ["source": source]
        if let anchorCommentID {
            payload["anchorCommentID"] = anchorCommentID
        }
        recordMetric(coordinator: coordinator, type: .allCommentsOpened, metadata: jsonMetadata(payload))
    }

    public static func recordPlaybackToggled(
        coordinator: AppCoordinator,
        source: String,
        wasPlaying: Bool,
        isPlaying: Bool,
        speed: Double
    ) {
        let metadata = jsonMetadata([
            "source": source,
            "wasPlaying": wasPlaying,
            "isPlaying": isPlaying,
            "speed": speed
        ])
        recordMetric(coordinator: coordinator, type: .playbackToggled, metadata: metadata)
    }

    public static func recordPlaybackSpeedChanged(
        coordinator: AppCoordinator,
        source: String,
        previousSpeed: Double,
        newSpeed: Double,
        isPlaying: Bool
    ) {
        let metadata = jsonMetadata([
            "source": source,
            "previousSpeed": previousSpeed,
            "newSpeed": newSpeed,
            "isPlaying": isPlaying
        ])
        recordMetric(coordinator: coordinator, type: .playbackSpeedChanged, metadata: metadata)
    }

    public static func recordRecordingStartedFromMenu(coordinator: AppCoordinator, source: String) {
        recordMetric(
            coordinator: coordinator,
            type: .recordingStartedFromMenu,
            metadata: jsonMetadata(["source": source])
        )
    }

    public static func recordRecordingPauseSelected(
        coordinator: AppCoordinator,
        source: String,
        durationSeconds: Int
    ) {
        let metadata = jsonMetadata([
            "source": source,
            "durationSeconds": durationSeconds
        ])
        recordMetric(
            coordinator: coordinator,
            type: .recordingPauseSelected,
            metadata: metadata
        )
    }

    public static func recordRecordingTurnedOff(coordinator: AppCoordinator, source: String) {
        recordMetric(
            coordinator: coordinator,
            type: .recordingTurnedOff,
            metadata: jsonMetadata(["source": source])
        )
    }

    public static func recordRecordingAutoResumed(
        coordinator: AppCoordinator,
        source: String,
        pausedDurationSeconds: Int
    ) {
        let metadata = jsonMetadata([
            "source": source,
            "pausedDurationSeconds": pausedDurationSeconds
        ])
        recordMetric(
            coordinator: coordinator,
            type: .recordingAutoResumed,
            metadata: metadata
        )
    }

    public static func recordSystemMonitorOpened(coordinator: AppCoordinator, source: String) {
        recordMetric(
            coordinator: coordinator,
            type: .systemMonitorOpened,
            metadata: jsonMetadata(["source": source])
        )
    }

    public static func recordHelpOpened(coordinator: AppCoordinator, source: String) {
        recordMetric(
            coordinator: coordinator,
            type: .helpOpened,
            metadata: jsonMetadata(["source": source])
        )
    }

    public static func recordSettingsSearchOpened(coordinator: AppCoordinator, source: String) {
        recordMetric(
            coordinator: coordinator,
            type: .settingsSearchOpened,
            metadata: jsonMetadata(["source": source])
        )
    }

    public static func recordRedactionRulesUpdated(
        coordinator: AppCoordinator,
        windowPatternCount: Int,
        urlPatternCount: Int
    ) {
        let metadata = jsonMetadata([
            "windowPatternCount": windowPatternCount,
            "urlPatternCount": urlPatternCount
        ])
        recordMetric(coordinator: coordinator, type: .redactionRulesUpdated, metadata: metadata)
    }

    public static func recordPrivateWindowRedactionToggle(
        coordinator: AppCoordinator,
        enabled: Bool,
        source: String
    ) {
        let metadata = jsonMetadata([
            "enabled": enabled,
            "source": source
        ])
        recordMetric(coordinator: coordinator, type: .privateWindowRedactionToggle, metadata: metadata)
    }

    public static func recordSystemMonitorSettingsOpened(coordinator: AppCoordinator, source: String) {
        recordMetric(
            coordinator: coordinator,
            type: .systemMonitorSettingsOpened,
            metadata: jsonMetadata(["source": source])
        )
    }

    public static func recordSystemMonitorOpenPowerOCRCard(coordinator: AppCoordinator, source: String) {
        recordMetric(
            coordinator: coordinator,
            type: .systemMonitorOpenPowerOCRCard,
            metadata: jsonMetadata(["source": source])
        )
    }

    public static func recordSystemMonitorOpenPowerOCRPriority(coordinator: AppCoordinator, source: String) {
        recordMetric(
            coordinator: coordinator,
            type: .systemMonitorOpenPowerOCRPriority,
            metadata: jsonMetadata(["source": source])
        )
    }

    public static func recordFrameDeleted(
        coordinator: AppCoordinator,
        source: String,
        frameID: Int64
    ) {
        let metadata = jsonMetadata([
            "source": source,
            "frameID": frameID
        ])
        recordMetric(coordinator: coordinator, type: .frameDeleted, metadata: metadata)
    }

    public static func recordSegmentDeleted(
        coordinator: AppCoordinator,
        source: String,
        segmentCount: Int,
        frameCount: Int
    ) {
        let metadata = jsonMetadata([
            "source": source,
            "segmentCount": segmentCount,
            "frameCount": frameCount
        ])
        recordMetric(coordinator: coordinator, type: .segmentDeleted, metadata: metadata)
    }

    // MARK: - Cleanup

    deinit {
        refreshTimer?.cancel()
        cancellables.removeAll()
    }
}

// MARK: - Supporting Types

/// Browser bundle IDs used for browser-specific breakdown behavior (references shared list)
private var browserBundleIDs: Set<String> { AppInfo.browserBundleIDs }

public struct AppUsageData: Identifiable {
    public let id = UUID()
    public let appBundleID: String
    public let appName: String
    public let duration: TimeInterval
    public let uniqueItemCount: Int
    public let percentage: Double

    /// Returns true if this app is a browser
    public var isBrowser: Bool {
        browserBundleIDs.contains(appBundleID)
    }

    /// Display label for the unique item count (e.g. "42 websites" or "15 tabs")
    public var uniqueItemLabel: String {
        let itemType = isBrowser ? "website" : "tab"
        let plural = uniqueItemCount == 1 ? "" : "s"
        return "\(uniqueItemCount) \(itemType)\(plural)"
    }
}

/// Represents a single session (continuous usage period) for an app
public struct AppSessionDetail: Identifiable {
    public let id: Int64
    public let appBundleID: String
    public let appName: String
    public let startDate: Date
    public let endDate: Date
    public let windowName: String?

    public var duration: TimeInterval {
        endDate.timeIntervalSince(startDate)
    }
}

/// Represents aggregated window usage within an app
public struct WindowUsageData: Identifiable {
    public let id = UUID()
    public let windowName: String?
    public let browserUrl: String?  // Full URL for browser tabs (optional)
    public let isWebsite: Bool      // True for website entries (with browserUrl), false for windowName fallbacks
    public let duration: TimeInterval
    public let percentage: Double
    public let tabCount: Int?

    public init(windowName: String?, browserUrl: String? = nil, isWebsite: Bool = true, duration: TimeInterval, percentage: Double, tabCount: Int? = nil) {
        self.windowName = windowName
        self.browserUrl = browserUrl
        self.isWebsite = isWebsite
        self.duration = duration
        self.percentage = percentage
        self.tabCount = tabCount
    }

    /// Display name for the window (handles nil/empty cases)
    public var displayName: String {
        if let name = windowName, !name.isEmpty {
            return name
        }
        return "Untitled Window"
    }
}

/// Represents a single data point for daily graphs
public struct DailyDataPoint: Identifiable {
    public let id = UUID()
    public let date: Date
    public let value: Int64
    public let label: String  // Formatted as MM/DD

    public init(date: Date, value: Int64) {
        self.date = date
        self.value = value

        let formatter = DateFormatter()
        formatter.dateFormat = "MM/dd"
        self.label = formatter.string(from: date)
    }
}
