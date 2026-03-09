import SwiftUI
import Combine
import Shared
import App
import Database
import ApplicationServices
import Dispatch

struct WatchdogCrashReportSummary: Equatable {
    let fileName: String
    let fileURL: URL
    let capturedAt: Date
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

    // Overall statistics
    @Published public var totalStorageBytes: Int64 = 0
    @Published public var weeklyStorageBytes: Int64 = 0
    @Published public var daysRecorded: Int = 0
    @Published public var oldestRecordedDate: Date?

    // Weekly engagement metrics (aggregated from daily data)
    @Published public var timelineOpensThisWeek: Int64 = 0
    @Published public var searchesThisWeek: Int64 = 0
    @Published public var textCopiesThisWeek: Int64 = 0

    // Daily graph data (7 days, Monday through Sunday)
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
    @Published var recentWatchdogCrash: WatchdogCrashReportSummary?

    // Track user dismissals — re-nag after 30 minutes
    private var accessibilityDismissedUntil: Date?
    private var screenRecordingDismissedUntil: Date?

    /// How long to suppress a permission warning after the user dismisses it
    private static let dismissSnoozeInterval: TimeInterval = 30 * 60 // 30 minutes
    nonisolated private static let watchdogCrashRecentWindow: TimeInterval = 7 * 24 * 60 * 60
    private static let acknowledgedWatchdogCrashReportKey = "acknowledgedWatchdogCrashReportFileName"
    private static let acknowledgedWatchdogCrashReportKeysKey = "acknowledgedWatchdogCrashReportFileNames"

    // MARK: - Dependencies

    private let coordinator: AppCoordinator
    private let settingsStore = UserDefaults(suiteName: "io.retrace.app") ?? .standard
    private var cancellables = Set<AnyCancellable>()
    private var refreshTimer: DispatchSourceTimer?
    /// Prevents the 2s poll from clobbering optimistic toggle UI while start/stop is in flight.
    private var isRecordingToggleInFlight = false
    private var lastTrackedWatchdogCrashBannerFileName: String?

    /// Whether the dashboard window is currently visible
    /// Set by DashboardWindowController on show/hide to gate UI updates
    public var isWindowVisible: Bool = false

    // MARK: - Initialization

    public init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        setupAutoRefresh()
        setupDataSourceObserver()
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

    private func setupAutoRefresh() {
        // Refresh recording status and permissions every 1 second with leeway for power efficiency
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: 1.0, leeway: .milliseconds(250))
        timer.setEventHandler { [weak self] in
            Task { @MainActor in
                guard let self = self else { return }
                // Skip UI updates when window is hidden to avoid SwiftUI diffing
                guard self.isWindowVisible else { return }
                self.updateRecordingStatus()
                self.updatePauseStatus()
                await self.updateQueueStatus()
                self.checkPermissions()
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
            ocrQueueDepth = stats.queueDepth
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

    public func dismissRecentWatchdogCrash() {
        acknowledgeRecentWatchdogCrash(action: "dismissed")
    }

    public func recordRecentWatchdogCrashFeedbackOpened() {
        guard let report = recentWatchdogCrash else { return }
        recordWatchdogCrashBannerAction("submit_bug_report_clicked", report: report)
    }

    public func recordRecentWatchdogCrashDetailsOpened() {
        guard let report = recentWatchdogCrash else { return }
        recordWatchdogCrashBannerAction("details_opened", report: report)
    }

    nonisolated static func makeWatchdogCrashFeedbackLaunchContext(
        for report: WatchdogCrashReportSummary,
        now: Date = Date()
    ) -> FeedbackLaunchContext {
        FeedbackLaunchContext(
            source: .watchdogCrashBanner,
            feedbackType: .bug,
            prefilledDescription: makeWatchdogCrashFeedbackDescription(for: report, now: now),
            preferredFocusField: .email
        )
    }

    nonisolated static func loadRecentWatchdogCrash(
        fileManager: FileManager = .default,
        crashReportDirectory: String = EmergencyDiagnostics.crashReportDirectory,
        now: Date = Date(),
        acknowledgedFileNames: Set<String> = []
    ) -> WatchdogCrashReportSummary? {
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
            return nil
        }

        let prefix = "retrace-emergency-watchdog_auto_quit-"

        let reports = fileURLs.compactMap { fileURL -> WatchdogCrashReportSummary? in
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

            guard now.timeIntervalSince(capturedAt) <= watchdogCrashRecentWindow else {
                return nil
            }

            return WatchdogCrashReportSummary(
                fileName: fileName,
                fileURL: fileURL,
                capturedAt: capturedAt
            )
        }
        .sorted { $0.capturedAt > $1.capturedAt }

        return reports.first { !acknowledgedFileNames.contains($0.fileName) }
    }

    nonisolated static func makeWatchdogCrashFeedbackDescription(
        for _: WatchdogCrashReportSummary,
        now _: Date = Date()
    ) -> String {
        return """
        Retrace Auto Quit Crash Logging

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

    private func refreshRecentWatchdogCrashState(now: Date = Date()) {
        let acknowledgedFileNames = loadAcknowledgedWatchdogCrashFileNames()
        let report = Self.loadRecentWatchdogCrash(
            now: now,
            acknowledgedFileNames: acknowledgedFileNames
        )

        recentWatchdogCrash = report

        guard let report, report.fileName != lastTrackedWatchdogCrashBannerFileName else {
            return
        }

        lastTrackedWatchdogCrashBannerFileName = report.fileName
        recordWatchdogCrashBannerAction("banner_shown", report: report, now: now)
    }

    private func acknowledgeRecentWatchdogCrash(action: String) {
        guard let report = recentWatchdogCrash else { return }
        var acknowledgedFileNames = loadAcknowledgedWatchdogCrashFileNames()
        acknowledgedFileNames.insert(report.fileName)
        persistAcknowledgedWatchdogCrashFileNames(acknowledgedFileNames)
        recordWatchdogCrashBannerAction(action, report: report)
        recentWatchdogCrash = nil
    }

    private func loadAcknowledgedWatchdogCrashFileNames() -> Set<String> {
        var acknowledgedFileNames = Set(
            settingsStore.stringArray(forKey: Self.acknowledgedWatchdogCrashReportKeysKey) ?? []
        )

        if let legacyAcknowledgedFileName = settingsStore.string(
            forKey: Self.acknowledgedWatchdogCrashReportKey
        ) {
            acknowledgedFileNames.insert(legacyAcknowledgedFileName)
        }

        return acknowledgedFileNames
    }

    private func persistAcknowledgedWatchdogCrashFileNames(_ fileNames: Set<String>) {
        settingsStore.set(fileNames.sorted(), forKey: Self.acknowledgedWatchdogCrashReportKeysKey)
        settingsStore.removeObject(forKey: Self.acknowledgedWatchdogCrashReportKey)
        settingsStore.synchronize()
    }

    private func recordWatchdogCrashBannerAction(
        _ action: String,
        report: WatchdogCrashReportSummary,
        now: Date = Date()
    ) {
        let metadata = Self.jsonMetadata([
            "action": action,
            "fileName": report.fileName,
            "reportAgeSeconds": max(0, Int(now.timeIntervalSince(report.capturedAt)))
        ])
        Self.recordMetric(
            coordinator: coordinator,
            type: .watchdogCrashBannerAction,
            metadata: metadata
        )
    }

    // MARK: - Data Loading

    public func loadStatistics() async {
        isLoading = true
        error = nil

        // Update recording status
        updateRecordingStatus()
        updatePauseStatus()
        refreshRecentWatchdogCrashState()

        do {
            // Calculate last 7 days date range
            let calendar = Calendar.current
            let now = Date()
            let sevenDaysAgo = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now))!
            let weekStart = sevenDaysAgo
            let weekEnd = now

            // Format the date range string
            let formatter = DateFormatter()
            formatter.dateFormat = "MMM d"
            weekDateRange = "\(formatter.string(from: weekStart)) - \(formatter.string(from: weekEnd))"

            // Fire slow queries (storage + dates) in background - don't block
            Task {
                if let storage = try? await coordinator.getTotalStorageUsed() {
                    await MainActor.run { self.totalStorageBytes = storage }
                }

                if let allDates = try? await coordinator.getDistinctDates() {
                    await MainActor.run {
                        self.daysRecorded = allDates.count
                        self.oldestRecordedDate = allDates.last // sorted descending, so last is oldest
                    }
                }
            }

            // Fire all queries in parallel - but log each one individually
            let todayStart = calendar.startOfDay(for: now)

            // Run queries sequentially to identify which one hangs
            let weeklyStorage = try await coordinator.getStorageUsedForDateRange(from: weekStart, to: weekEnd)

            let appStats = try await coordinator.getAppUsageStats(from: weekStart, to: weekEnd)

            let todayStats = try await coordinator.getAppUsageStats(from: todayStart, to: weekEnd)

            await loadDailyGraphData(weekStart: weekStart, weekEnd: weekEnd)


            weeklyStorageBytes = weeklyStorage
            totalWeeklyTime = appStats.reduce(0) { $0 + $1.duration }
            totalDailyTime = todayStats.reduce(0) { $0 + $1.duration }

            // Convert to AppUsageData and sort by duration
            weeklyAppUsage = appStats.map { stat in
                AppUsageData(
                    appBundleID: stat.bundleID,
                    appName: AppNameResolver.shared.displayName(for: stat.bundleID),
                    duration: stat.duration,
                    uniqueItemCount: stat.uniqueItemCount,
                    percentage: totalWeeklyTime > 0 ? stat.duration / totalWeeklyTime : 0
                )
            }
            .sorted { $0.duration > $1.duration }

            isLoading = false
        } catch {
            self.error = "Failed to load statistics: \(error.localizedDescription)"
            isLoading = false
        }
    }

    // MARK: - Daily Graph Data

    /// Load 7-day daily data for all metric graphs
    private func loadDailyGraphData(weekStart: Date, weekEnd: Date) async {
        let calendar = Calendar.current

        // Generate all 7 days of the week (Monday through Sunday)
        var allDays: [Date] = []
        var currentDay = weekStart
        while currentDay <= weekEnd {
            allDays.append(currentDay)
            currentDay = calendar.date(byAdding: .day, value: 1, to: currentDay)!
        }

        // Fill in any remaining days up to 7
        while allDays.count < 7 {
            if let nextDay = calendar.date(byAdding: .day, value: 1, to: allDays.last ?? weekStart) {
                allDays.append(nextDay)
            }
        }

        do {
            // Load daily screen time data
            let screenTimeData = try await coordinator.getDailyScreenTime(
                from: weekStart,
                to: weekEnd
            )
            dailyScreenTimeData = fillMissingDays(data: screenTimeData, allDays: allDays)

            // Load storage data for each day (just that day's folder size)
            dailyStorageData = try await loadDailyStorageData(for: allDays)

            // Load timeline opens data
            let timelineData = try await coordinator.getDailyMetrics(
                metricType: .timelineOpens,
                from: weekStart,
                to: weekEnd
            )
            dailyTimelineOpensData = fillMissingDays(data: timelineData, allDays: allDays)
            timelineOpensThisWeek = dailyTimelineOpensData.reduce(0) { $0 + $1.value }

            // Load searches data
            let searchesData = try await coordinator.getDailyMetrics(
                metricType: .searches,
                from: weekStart,
                to: weekEnd
            )
            dailySearchesData = fillMissingDays(data: searchesData, allDays: allDays)
            searchesThisWeek = dailySearchesData.reduce(0) { $0 + $1.value }

            // Load text copies data
            let textCopiesData = try await coordinator.getDailyMetrics(
                metricType: .textCopies,
                from: weekStart,
                to: weekEnd
            )
            dailyTextCopiesData = fillMissingDays(data: textCopiesData, allDays: allDays)
            textCopiesThisWeek = dailyTextCopiesData.reduce(0) { $0 + $1.value }

        } catch {
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
    private func loadDailyStorageData(for days: [Date]) async throws -> [DailyDataPoint] {
        var dataPoints: [DailyDataPoint] = []
        for day in days {
            let dayStorage = try await coordinator.getStorageUsedForDateRange(from: day, to: day)
            dataPoints.append(DailyDataPoint(date: day, value: dayStorage))
        }
        return dataPoints
    }

    /// Fill missing days with zero values to ensure we always have 7 data points
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
            let calendar = Calendar.current
            let now = Date()
            // Use rolling 7-day window (same as main dashboard app usage)
            let weekStart = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now))!

            // Use efficient SQL query with bundleID filter, time range, and pagination
            let segments = try await coordinator.getSegments(
                bundleID: bundleID,
                from: weekStart,
                to: now,
                limit: limit,
                offset: offset
            )

            return segments.map { segment in
                AppSessionDetail(
                    id: segment.id.value,
                    appBundleID: segment.bundleID,
                    appName: AppNameResolver.shared.displayName(for: segment.bundleID),
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
            let calendar = Calendar.current
            let now = Date()
            // Use rolling 7-day window (same as main dashboard app usage)
            let weekStart = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now))!

            let windowStats = try await coordinator.getWindowUsageForApp(
                bundleID: bundleID,
                from: weekStart,
                to: now
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
            let calendar = Calendar.current
            let now = Date()
            // Use rolling 7-day window (same as main dashboard app usage)
            let weekStart = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now))!

            let tabStats = try await coordinator.getBrowserTabUsage(
                bundleID: bundleID,
                from: weekStart,
                to: now
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
            let calendar = Calendar.current
            let now = Date()
            let weekStart = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now))!

            let tabStats = try await coordinator.getBrowserTabUsageForDomain(
                bundleID: bundleID,
                domain: domain,
                from: weekStart,
                to: now
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
            let calendar = Calendar.current
            let now = Date()
            // Use rolling 7-day window (same as main dashboard app usage)
            let weekStart = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now))!

            // Use efficient SQL query with bundleID and window/domain filter, time range, and pagination
            let segments = try await coordinator.getSegments(
                bundleID: bundleID,
                windowNameOrDomain: windowNameOrDomain,
                from: weekStart,
                to: now,
                limit: limit,
                offset: offset
            )

            return segments.map { segment in
                AppSessionDetail(
                    id: segment.id.value,
                    appBundleID: segment.bundleID,
                    appName: AppNameResolver.shared.displayName(for: segment.bundleID),
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

    /// Record an app launch event
    public static func recordAppLaunch(coordinator: AppCoordinator) {
        Task {
            try? await coordinator.recordMetricEvent(metricType: .appLaunches)
        }
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
