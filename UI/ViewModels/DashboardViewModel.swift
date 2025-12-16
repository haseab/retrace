import SwiftUI
import Combine
import Shared
import App

/// ViewModel for the Dashboard view
/// Manages statistics, analytics, and migration state
@MainActor
public class DashboardViewModel: ObservableObject {

    // MARK: - Published State

    // Statistics
    @Published public var captureStats: CaptureStatistics?
    @Published public var storageStats: StorageStatistics?
    @Published public var databaseStats: DatabaseStatistics?
    @Published public var searchStats: SearchStatistics?
    @Published public var processingStats: ProcessingStatistics?

    // App sessions analytics
    @Published public var topApps: [(appBundleID: String, appName: String, duration: TimeInterval, percentage: Double)] = []
    @Published public var activityData: [ActivityDataPoint] = []

    // Migration
    @Published public var availableSources: [MigrationSource] = []
    @Published public var importProgress: MigrationProgress?
    @Published public var isImporting = false

    // Loading state
    @Published public var isLoading = false
    @Published public var error: String?

    // Permission warnings
    @Published public var showAccessibilityWarning = false

    // MARK: - Dependencies

    private let coordinator: AppCoordinator
    private var cancellables = Set<AnyCancellable>()
    private var refreshTimer: Timer?

    // MARK: - Initialization

    public init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        setupAutoRefresh()
        setupAccessibilityWarningCallback()
    }

    // MARK: - Setup

    private func setupAutoRefresh() {
        // Refresh stats every 10 seconds
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.loadStatistics()
            }
        }
    }

    private func setupAccessibilityWarningCallback() {
        Task {
            await coordinator.setupAccessibilityWarningCallback { [weak self] in
                Task { @MainActor in
                    self?.showAccessibilityWarning = true
                }
            }
        }
    }

    public func dismissAccessibilityWarning() {
        showAccessibilityWarning = false
    }

    // MARK: - Data Loading

    public func loadStatistics() async {
        isLoading = true
        error = nil

        do {
            let stats = try await coordinator.getStatistics()

            captureStats = stats.capture
            storageStats = await loadStorageStats()
            databaseStats = stats.database
            searchStats = stats.search
            processingStats = stats.processing

            // Load activity and app usage data
            await loadActivityData()
            await loadTopApps()

            isLoading = false
        } catch {
            self.error = "Failed to load statistics: \(error.localizedDescription)"
            isLoading = false
        }
    }

    private func loadStorageStats() async -> StorageStatistics {
        // TODO: Implement actual storage statistics from coordinator
        return StorageStatistics(
            totalStorageBytes: 0,
            videoStorageBytes: 0,
            metadataStorageBytes: 0,
            estimatedDaysUntilFull: nil
        )
    }

    private func loadActivityData() async {
        // TODO: Load actual activity data from database
        // For now, generate mock data for last 7 days
        let calendar = Calendar.current
        let now = Date()

        activityData = (0..<7).reversed().map { daysAgo in
            let date = calendar.date(byAdding: .day, value: -daysAgo, to: now)!
            let framesCount = Int.random(in: 100...500)

            return ActivityDataPoint(
                date: date,
                framesCount: framesCount
            )
        }
    }

    private func loadTopApps() async {
        // TODO: Load actual app usage from database
        // Group frames by app and calculate durations
        let mockApps = [
            (appBundleID: "com.google.Chrome", appName: "Chrome", duration: 51480.0, percentage: 0.23),
            (appBundleID: "com.apple.dt.Xcode", appName: "Xcode", duration: 42120.0, percentage: 0.19),
            (appBundleID: "com.tinyspeck.slackmacgap", appName: "Slack", duration: 29880.0, percentage: 0.14),
            (appBundleID: "com.microsoft.VSCode", appName: "VS Code", duration: 25200.0, percentage: 0.11),
            (appBundleID: "com.apple.Terminal", appName: "Terminal", duration: 19800.0, percentage: 0.09)
        ]

        topApps = mockApps
    }

    // MARK: - Migration

    public func scanForMigrationSources() async {
        availableSources = []

        // Scan for Rewind AI
        let rewindPath = NSHomeDirectory() + "/Library/Application Support/com.memoryvault.MemoryVault/chunks/"
        if FileManager.default.fileExists(atPath: rewindPath) {
            let size = calculateDirectorySize(path: rewindPath)
            availableSources.append(MigrationSource(
                id: "rewind",
                name: "Rewind AI",
                isInstalled: true,
                dataPath: rewindPath,
                estimatedSize: size
            ))
        } else {
            availableSources.append(MigrationSource(
                id: "rewind",
                name: "Rewind AI",
                isInstalled: false,
                dataPath: nil,
                estimatedSize: nil
            ))
        }

        // Scan for ScreenMemory (future)
        availableSources.append(MigrationSource(
            id: "screenmemory",
            name: "ScreenMemory",
            isInstalled: false,
            dataPath: nil,
            estimatedSize: nil
        ))

        // Scan for TimeScroll (future)
        availableSources.append(MigrationSource(
            id: "timescroll",
            name: "TimeScroll",
            isInstalled: false,
            dataPath: nil,
            estimatedSize: nil
        ))
    }

    public func startImport(from source: MigrationSource) async {
        guard let dataPath = source.dataPath else { return }

        isImporting = true

        do {
            try await coordinator.importFromRewind(
                chunkDirectory: dataPath,
                progressHandler: { [weak self] progress in
                    Task { @MainActor in
                        self?.importProgress = progress
                    }
                }
            )

            isImporting = false
            importProgress = nil
        } catch {
            self.error = "Import failed: \(error.localizedDescription)"
            isImporting = false
        }
    }

    public func pauseImport() {
        // TODO: Implement pause
    }

    public func cancelImport() {
        // TODO: Implement cancel
        isImporting = false
        importProgress = nil
    }

    // MARK: - Helpers

    private func calculateDirectorySize(path: String) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(atPath: path) else {
            return 0
        }

        var totalSize: Int64 = 0

        for case let file as String in enumerator {
            let filePath = (path as NSString).appendingPathComponent(file)
            if let attributes = try? FileManager.default.attributesOfItem(atPath: filePath),
               let fileSize = attributes[.size] as? Int64 {
                totalSize += fileSize
            }
        }

        return totalSize
    }

    // MARK: - Cleanup

    deinit {
        refreshTimer?.invalidate()
        cancellables.removeAll()
    }
}

// MARK: - Supporting Types

public struct ActivityDataPoint: Identifiable {
    public let id = UUID()
    public let date: Date
    public let framesCount: Int
}

public struct MigrationSource: Identifiable {
    public let id: String
    public let name: String
    public let isInstalled: Bool
    public let dataPath: String?
    public let estimatedSize: Int64?
}

public struct StorageStatistics {
    public let totalStorageBytes: Int64
    public let videoStorageBytes: Int64
    public let metadataStorageBytes: Int64
    public let estimatedDaysUntilFull: Int?
}
