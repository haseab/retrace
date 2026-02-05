import SwiftUI
import Combine
import Shared
import App
import Database
import ApplicationServices
import Dispatch

/// Debug logger that writes to /tmp/retrace_debug.log
private func debugLog(_ message: String) {
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let logLine = "[\(timestamp)] \(message)\n"
    let logPath = "/tmp/retrace_debug.log"

    if let handle = FileHandle(forWritingAtPath: logPath) {
        handle.seekToEndOfFile()
        if let data = logLine.data(using: .utf8) {
            handle.write(data)
        }
        handle.closeFile()
    } else {
        // Create file if it doesn't exist
        FileManager.default.createFile(atPath: logPath, contents: logLine.data(using: .utf8))
    }
}

/// ViewModel for the Dashboard view
/// Manages weekly app usage statistics from the database
@MainActor
public class DashboardViewModel: ObservableObject {

    // MARK: - Published State

    // Recording status
    @Published public var isRecording = false

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

    // Permission warnings
    @Published public var showAccessibilityWarning = false
    @Published public var showScreenRecordingWarning = false

    // Track user dismissals — re-nag after 30 minutes
    private var accessibilityDismissedUntil: Date?
    private var screenRecordingDismissedUntil: Date?

    /// How long to suppress a permission warning after the user dismisses it
    private static let dismissSnoozeInterval: TimeInterval = 30 * 60 // 30 minutes

    // MARK: - Dependencies

    private let coordinator: AppCoordinator
    private var cancellables = Set<AnyCancellable>()
    private var refreshTimer: DispatchSourceTimer?

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
        // Refresh recording status and permissions every 2 seconds with leeway for power efficiency
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: 2.0, leeway: .milliseconds(500))
        timer.setEventHandler { [weak self] in
            Task { @MainActor in
                await self?.updateRecordingStatus()
                self?.checkPermissions()
            }
        }
        timer.resume()
        refreshTimer = timer
    }

    private func updateRecordingStatus() async {
        isRecording = await coordinator.isCapturing()
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
        // Update UI immediately for instant feedback
        isRecording = newValue
        MenuBarManager.shared?.updateRecordingStatus(newValue)

        do {
            if newValue {
                try await coordinator.startPipeline()
            } else {
                try await coordinator.stopPipeline()
            }
        } catch {
            Log.error("[DashboardViewModel] Failed to toggle recording: \(error)", category: .ui)
            // Revert to actual state on error
            await updateRecordingStatus()
        }
    }

    public func dismissAccessibilityWarning() {
        showAccessibilityWarning = false
        accessibilityDismissedUntil = Date().addingTimeInterval(Self.dismissSnoozeInterval)
    }

    public func dismissScreenRecordingWarning() {
        showScreenRecordingWarning = false
        screenRecordingDismissedUntil = Date().addingTimeInterval(Self.dismissSnoozeInterval)
    }

    // MARK: - Data Loading

    public func loadStatistics() async {
        let overallStart = CFAbsoluteTimeGetCurrent()
        debugLog("loadStatistics() START")
        isLoading = true
        error = nil

        // Update recording status
        await updateRecordingStatus()
        debugLog("Recording status updated in \(Int((CFAbsoluteTimeGetCurrent() - overallStart) * 1000))ms")

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
            debugLog("Date range: \(weekDateRange)")

            // Fire slow queries (storage + dates) in background - don't block
            Task {
                let bgStart = CFAbsoluteTimeGetCurrent()
                debugLog("BG: starting getTotalStorageUsed")
                if let storage = try? await coordinator.getTotalStorageUsed() {
                    await MainActor.run { self.totalStorageBytes = storage }
                    debugLog("BG: getTotalStorageUsed done in \(Int((CFAbsoluteTimeGetCurrent() - bgStart) * 1000))ms, storage=\(storage)")
                } else {
                    debugLog("BG: getTotalStorageUsed FAILED in \(Int((CFAbsoluteTimeGetCurrent() - bgStart) * 1000))ms")
                }

                let bgStart2 = CFAbsoluteTimeGetCurrent()
                debugLog("BG: starting getDistinctDates")
                if let allDates = try? await coordinator.getDistinctDates() {
                    await MainActor.run {
                        self.daysRecorded = allDates.count
                        self.oldestRecordedDate = allDates.last // sorted descending, so last is oldest
                    }
                    debugLog("BG: getDistinctDates done in \(Int((CFAbsoluteTimeGetCurrent() - bgStart2) * 1000))ms, count=\(allDates.count)")
                } else {
                    debugLog("BG: getDistinctDates FAILED in \(Int((CFAbsoluteTimeGetCurrent() - bgStart2) * 1000))ms")
                }
            }

            // Fire all queries in parallel - but log each one individually
            let todayStart = calendar.startOfDay(for: now)
            debugLog("Starting parallel queries at \(Int((CFAbsoluteTimeGetCurrent() - overallStart) * 1000))ms")

            // Run queries sequentially to identify which one hangs
            let queryStart1 = CFAbsoluteTimeGetCurrent()
            debugLog("Q1: starting getStorageUsedForDateRange")
            let weeklyStorage = try await coordinator.getStorageUsedForDateRange(from: weekStart, to: weekEnd)
            debugLog("Q1: getStorageUsedForDateRange done in \(Int((CFAbsoluteTimeGetCurrent() - queryStart1) * 1000))ms")

            let queryStart2 = CFAbsoluteTimeGetCurrent()
            debugLog("Q2: starting getAppUsageStats (weekly)")
            let appStats = try await coordinator.getAppUsageStats(from: weekStart, to: weekEnd)
            debugLog("Q2: getAppUsageStats (weekly) done in \(Int((CFAbsoluteTimeGetCurrent() - queryStart2) * 1000))ms, count=\(appStats.count)")

            let queryStart3 = CFAbsoluteTimeGetCurrent()
            debugLog("Q3: starting getAppUsageStats (today)")
            let todayStats = try await coordinator.getAppUsageStats(from: todayStart, to: weekEnd)
            debugLog("Q3: getAppUsageStats (today) done in \(Int((CFAbsoluteTimeGetCurrent() - queryStart3) * 1000))ms, count=\(todayStats.count)")

            let queryStart4 = CFAbsoluteTimeGetCurrent()
            debugLog("Q4: starting loadDailyGraphData")
            await loadDailyGraphData(weekStart: weekStart, weekEnd: weekEnd)
            debugLog("Q4: loadDailyGraphData done in \(Int((CFAbsoluteTimeGetCurrent() - queryStart4) * 1000))ms")

            debugLog("All queries complete in \(Int((CFAbsoluteTimeGetCurrent() - overallStart) * 1000))ms, appStats.count=\(appStats.count)")

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

            debugLog("loadStatistics() COMPLETE - weeklyAppUsage.count=\(weeklyAppUsage.count)")
            isLoading = false
        } catch {
            debugLog("loadStatistics() FAILED: \(error)")
            self.error = "Failed to load statistics: \(error.localizedDescription)"
            isLoading = false
        }
    }

    // MARK: - Daily Graph Data

    /// Load 7-day daily data for all metric graphs
    private func loadDailyGraphData(weekStart: Date, weekEnd: Date) async {
        let graphStart = CFAbsoluteTimeGetCurrent()
        debugLog("loadDailyGraphData START")
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
            var subStart = CFAbsoluteTimeGetCurrent()
            debugLog("G1: starting getDailyScreenTime")
            let screenTimeData = try await coordinator.getDailyScreenTime(
                from: weekStart,
                to: weekEnd
            )
            dailyScreenTimeData = fillMissingDays(data: screenTimeData, allDays: allDays)
            debugLog("G1: getDailyScreenTime done in \(Int((CFAbsoluteTimeGetCurrent() - subStart) * 1000))ms")

            // Load storage data for each day (just that day's folder size)
            subStart = CFAbsoluteTimeGetCurrent()
            debugLog("G2: starting loadDailyStorageData for \(allDays.count) days")
            dailyStorageData = try await loadDailyStorageData(for: allDays)
            debugLog("G2: loadDailyStorageData done in \(Int((CFAbsoluteTimeGetCurrent() - subStart) * 1000))ms")

            // Load timeline opens data
            subStart = CFAbsoluteTimeGetCurrent()
            debugLog("G3: starting getDailyMetrics(timelineOpens)")
            let timelineData = try await coordinator.getDailyMetrics(
                metricType: .timelineOpens,
                from: weekStart,
                to: weekEnd
            )
            dailyTimelineOpensData = fillMissingDays(data: timelineData, allDays: allDays)
            timelineOpensThisWeek = dailyTimelineOpensData.reduce(0) { $0 + $1.value }
            debugLog("G3: getDailyMetrics(timelineOpens) done in \(Int((CFAbsoluteTimeGetCurrent() - subStart) * 1000))ms")

            // Load searches data
            subStart = CFAbsoluteTimeGetCurrent()
            debugLog("G4: starting getDailyMetrics(searches)")
            let searchesData = try await coordinator.getDailyMetrics(
                metricType: .searches,
                from: weekStart,
                to: weekEnd
            )
            dailySearchesData = fillMissingDays(data: searchesData, allDays: allDays)
            searchesThisWeek = dailySearchesData.reduce(0) { $0 + $1.value }
            debugLog("G4: getDailyMetrics(searches) done in \(Int((CFAbsoluteTimeGetCurrent() - subStart) * 1000))ms")

            // Load text copies data
            subStart = CFAbsoluteTimeGetCurrent()
            debugLog("G5: starting getDailyMetrics(textCopies)")
            let textCopiesData = try await coordinator.getDailyMetrics(
                metricType: .textCopies,
                from: weekStart,
                to: weekEnd
            )
            dailyTextCopiesData = fillMissingDays(data: textCopiesData, allDays: allDays)
            textCopiesThisWeek = dailyTextCopiesData.reduce(0) { $0 + $1.value }
            debugLog("G5: getDailyMetrics(textCopies) done in \(Int((CFAbsoluteTimeGetCurrent() - subStart) * 1000))ms")

            debugLog("loadDailyGraphData COMPLETE in \(Int((CFAbsoluteTimeGetCurrent() - graphStart) * 1000))ms")
        } catch {
            debugLog("Failed to load daily graph data in \(Int((CFAbsoluteTimeGetCurrent() - graphStart) * 1000))ms: \(error)")
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
        for (index, day) in days.enumerated() {
            let dayStart = CFAbsoluteTimeGetCurrent()
            let dayStorage = try await coordinator.getStorageUsedForDateRange(from: day, to: day)
            dataPoints.append(DailyDataPoint(date: day, value: dayStorage))
            debugLog("G2-\(index): day \(index) storage done in \(Int((CFAbsoluteTimeGetCurrent() - dayStart) * 1000))ms")
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
    /// For browsers: returns websites (from browserUrl) first, then windowName fallbacks with isWebsite=false
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
                    percentage: totalDuration > 0 ? stat.duration / totalDuration : 0
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
                    isWebsite: true,  // These are nested tabs within a domain, always websites
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
                    isWebsite: true,  // These are nested tabs within a domain, always websites
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

    // MARK: - Cleanup

    deinit {
        refreshTimer?.cancel()
        cancellables.removeAll()
    }
}

// MARK: - Supporting Types

/// Browser bundle IDs that show "websites" instead of "windows" (references shared list)
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

    public init(windowName: String?, browserUrl: String? = nil, isWebsite: Bool = true, duration: TimeInterval, percentage: Double) {
        self.windowName = windowName
        self.browserUrl = browserUrl
        self.isWebsite = isWebsite
        self.duration = duration
        self.percentage = percentage
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
