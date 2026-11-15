import Foundation
import Shared
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Storage Health Notifications

public extension NSNotification.Name {
    /// Storage drive is about to be ejected or became inaccessible
    static let storageInaccessible = NSNotification.Name("StorageInaccessible")
    /// Storage space is running low (< 5GB)
    static let storageLow = NSNotification.Name("StorageLow")
    /// Storage space is critically low (< 1GB), may auto-stop recording
    static let storageCriticalLow = NSNotification.Name("StorageCriticalLow")
    /// Storage space recovered to a healthy level (>= 5GB)
    static let storageHealthy = NSNotification.Name("StorageHealthy")
    /// I/O latency is critically high (> 500ms)
    static let storageSlowIO = NSNotification.Name("StorageSlowIO")
    /// Storage volume mounted (used to trigger cache validation)
    static let storageVolumeMounted = NSNotification.Name("StorageVolumeMounted")
}

// MARK: - Storage Health Monitor

/// Unified monitor for all external drive health concerns.
/// Consolidates: volume events, disk space, I/O latency, keep-alive, and path validation.
/// Uses a single background task with periodic checks instead of multiple monitors.
public final class StorageHealthMonitor: @unchecked Sendable {
    public static let shared = StorageHealthMonitor()

    // MARK: - Configuration

    private struct Config {
        // Check intervals
        static let healthCheckInterval: TimeInterval = 30 // seconds
        static let keepAliveInterval: TimeInterval = 30   // seconds (combined with health check)
        static let diskCheckFailureLogThrottleSeconds: TimeInterval = 300

        // Disk space thresholds
        static let warningThresholdGB: Double = 5.0
        static let criticalThresholdGB: Double = 1.0
        static let stopThresholdGB: Double = 0.5

        // I/O latency thresholds (milliseconds)
        static let slowIOWarningMs: Double = 100
        static let slowIOCriticalMs: Double = 500
        static let spinupDetectionMs: Double = 500

        // Rolling window for I/O stats
        static let maxLatencySamples = 100
    }

    // MARK: - State

    private let lock = NSLock()
    private var isMonitoring = false
    private var monitorTask: Task<Void, Never>?
    private var volumeObservers: [NSObjectProtocol] = []

    // Storage path being monitored
    private var storagePath: String?
    private var storageURL: URL?

    // I/O latency tracking (written to by frame writers, read by monitor)
    private var recentLatencies: [Double] = []
    private var slowWriteCount = 0
    private var criticalWriteCount = 0
    private var spinupCount = 0

    // Disk space state
    private var lastDiskCheckFailureLogTime: Date?
    private var lastAvailableGB: Double = 0

    // Keep-alive file
    private var keepAliveURL: URL?

    // Callback for stopping recording (set by AppCoordinator)
    private var onCriticalError: (() async -> Void)?

    private init() {}

    private struct Snapshot {
        let isMonitoring: Bool
        let storagePath: String?
        let storageURL: URL?
        let keepAliveURL: URL?
        let onCriticalError: (() async -> Void)?
    }

    private func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(
            isMonitoring: isMonitoring,
            storagePath: storagePath,
            storageURL: storageURL,
            keepAliveURL: keepAliveURL,
            onCriticalError: onCriticalError
        )
    }

    // MARK: - Public API

    /// Start monitoring storage health for the given path.
    /// Call this when pipeline starts, or again to update the critical-error callback.
    public func startMonitoring(
        storagePath: String,
        onCriticalError: (() async -> Void)? = nil
    ) {
        var shouldStart = false

        lock.lock()
        if !isMonitoring {
            isMonitoring = true
            shouldStart = true
            self.storagePath = storagePath
            self.storageURL = URL(fileURLWithPath: storagePath)
            self.keepAliveURL = self.storageURL?.appendingPathComponent(".retrace_keepalive")

            // Reset stats
            recentLatencies.removeAll()
            slowWriteCount = 0
            criticalWriteCount = 0
            spinupCount = 0
            lastDiskCheckFailureLogTime = nil
        }

        self.onCriticalError = onCriticalError
        lock.unlock()

        guard shouldStart else { return }

        // Setup volume observers (instant notification)
        setupVolumeObservers()

        // Start periodic health check task
        startHealthCheckTask()

    }

    /// Stop monitoring. Call this when the app no longer needs storage-health signals.
    public func stopMonitoring() {
        let taskToCancel: Task<Void, Never>?
        let observersToRemove: [NSObjectProtocol]
        let keepAliveToRemove: URL?

        lock.lock()
        if !isMonitoring {
            lock.unlock()
            return
        }
        isMonitoring = false

        taskToCancel = monitorTask
        monitorTask = nil

        observersToRemove = volumeObservers
        volumeObservers.removeAll()

        keepAliveToRemove = keepAliveURL
        keepAliveURL = nil
        storagePath = nil
        storageURL = nil
        onCriticalError = nil
        lock.unlock()

        // Cancel task
        taskToCancel?.cancel()

        // Remove observers
        #if canImport(AppKit)
        let center = NSWorkspace.shared.notificationCenter
        for observer in observersToRemove {
            center.removeObserver(observer)
        }
        #endif

        // Clean up keep-alive file
        if let keepAliveToRemove {
            try? FileManager.default.removeItem(at: keepAliveToRemove)
        }

    }

    /// Record a write latency sample. Called by IncrementalSegmentWriter after each frame write.
    public func recordWriteLatency(_ latencyMs: Double) {
        lock.lock()
        recentLatencies.append(latencyMs)
        if recentLatencies.count > Config.maxLatencySamples {
            recentLatencies.removeFirst()
        }

        if latencyMs > Config.slowIOCriticalMs {
            criticalWriteCount += 1
        } else if latencyMs > Config.slowIOWarningMs {
            slowWriteCount += 1
        }
        lock.unlock()

        if latencyMs > Config.slowIOCriticalMs {
            postNotification(.storageSlowIO, object: latencyMs)
        }
    }

    /// Get current health statistics for diagnostics logging
    public var statistics: StorageHealthStats {
        lock.lock()
        defer { lock.unlock() }

        let avgLatency = recentLatencies.isEmpty ? 0 : recentLatencies.reduce(0, +) / Double(recentLatencies.count)
        let maxLatency = recentLatencies.max() ?? 0

        return StorageHealthStats(
            availableGB: lastAvailableGB,
            avgWriteLatencyMs: avgLatency,
            maxWriteLatencyMs: maxLatency,
            slowWriteCount: slowWriteCount,
            criticalWriteCount: criticalWriteCount,
            spinupCount: spinupCount
        )
    }

    // MARK: - Volume Observers

    private func setupVolumeObservers() {
        let center = NSWorkspace.shared.notificationCenter

        // Drive about to be ejected
        let willUnmount = center.addObserver(
            forName: NSWorkspace.willUnmountNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleVolumeWillUnmount(notification)
        }
        volumeObservers.append(willUnmount)

        // Drive was ejected (backup in case willUnmount wasn't caught)
        let didUnmount = center.addObserver(
            forName: NSWorkspace.didUnmountNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleVolumeDidUnmount(notification)
        }
        volumeObservers.append(didUnmount)

        // Drive was mounted (for cache validation)
        let didMount = center.addObserver(
            forName: NSWorkspace.didMountNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleVolumeDidMount(notification)
        }
        volumeObservers.append(didMount)
    }

    private func handleVolumeWillUnmount(_ notification: Notification) {
        guard let volumeURL = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL,
              let storagePath = snapshot().storagePath else { return }

        // Check if this volume contains our storage path
        if storagePath.hasPrefix(volumeURL.path) {
            handleStorageInaccessible(reason: "Volume ejecting")
        }
    }

    private func handleVolumeDidUnmount(_ notification: Notification) {
        guard let volumeURL = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL,
              let storagePath = snapshot().storagePath else { return }

        if storagePath.hasPrefix(volumeURL.path) {
            handleStorageInaccessible(reason: "Volume ejected")
        }
    }

    private func handleVolumeDidMount(_ notification: Notification) {
        guard let volumeURL = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL,
              let storagePath = snapshot().storagePath else { return }

        if storagePath.hasPrefix(volumeURL.path) {
            // Post notification so caches can be validated
            postNotification(.storageVolumeMounted, object: volumeURL)
        }
    }

    private func handleStorageInaccessible(reason: String) {
        let callback = snapshot().onCriticalError
        postNotification(.storageInaccessible, object: reason)

        // Trigger critical error callback to stop recording
        if let callback {
            Task {
                await callback()
            }
        }
    }

    // MARK: - Health Check Task

    private func startHealthCheckTask() {
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Config.healthCheckInterval), clock: .continuous)
                guard !Task.isCancelled else { break }

                await self?.performHealthCheck()
            }
        }
    }

    private func performHealthCheck() async {
        let snapshot = snapshot()
        guard snapshot.isMonitoring, let storageURL = snapshot.storageURL else { return }

        // 1. Check path accessibility
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: storageURL.path, isDirectory: &isDirectory)

        if !exists || !isDirectory.boolValue {
            handleStorageInaccessible(reason: "Path inaccessible")
            return
        }

        // 2. Check disk space
        await checkDiskSpace()

        // 3. Keep-alive write (also detects spinup)
        await performKeepAliveWrite()

    }

    private func checkDiskSpace() async {
        let snapshot = snapshot()
        guard snapshot.isMonitoring, let storageURL = snapshot.storageURL else { return }
        do {
            let availableBytes = try DiskSpaceMonitor.availableBytes(at: storageURL)
            let availableGB = Double(availableBytes) / (1024 * 1024 * 1024)

            updateLastAvailableGB(availableGB)

            if availableGB < Config.stopThresholdGB {
                if let callback = snapshot.onCriticalError {
                    postNotification(.storageCriticalLow, object: ["availableGB": availableGB, "shouldStop": true])
                    await callback()
                } else {
                    postNotification(.storageCriticalLow, object: ["availableGB": availableGB, "shouldStop": false])
                }
            } else if availableGB < Config.criticalThresholdGB {
                postNotification(.storageCriticalLow, object: ["availableGB": availableGB, "shouldStop": false])
            } else if availableGB < Config.warningThresholdGB {
                postNotification(.storageLow, object: ["availableGB": availableGB])
            } else {
                postNotification(.storageHealthy, object: ["availableGB": availableGB])
            }
        } catch {
            if shouldLogDiskCheckFailure() {
                Log.warning("[StorageHealth] Failed to check disk space: \(error.localizedDescription)", category: .storage)
            }
        }
    }

    private func performKeepAliveWrite() async {
        let snapshot = snapshot()
        guard snapshot.isMonitoring, let keepAliveURL = snapshot.keepAliveURL else { return }

        let writeStart = CFAbsoluteTimeGetCurrent()
        let timestamp = "\(Date())".data(using: .utf8) ?? Data()

        do {
            try timestamp.write(to: keepAliveURL)
        } catch {
            return
        }

        let latencyMs = (CFAbsoluteTimeGetCurrent() - writeStart) * 1000

        // Detect drive spinup (write takes unusually long)
        if latencyMs > Config.spinupDetectionMs {
            incrementSpinupCount()
        }
    }

    /// Thread-safe increment for spinup count (called from async context)
    private func incrementSpinupCount() {
        lock.lock()
        spinupCount += 1
        lock.unlock()
    }

    /// Thread-safe update for available GB (called from async context)
    private func updateLastAvailableGB(_ gb: Double) {
        lock.lock()
        lastAvailableGB = gb
        lock.unlock()
    }

    private func shouldLogDiskCheckFailure(now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        if let lastFailureLog = lastDiskCheckFailureLogTime,
           now.timeIntervalSince(lastFailureLog) < Config.diskCheckFailureLogThrottleSeconds {
            return false
        }

        lastDiskCheckFailureLogTime = now
        return true
    }

    private func postNotification(_ name: NSNotification.Name, object: Any?) {
        Task { @MainActor in
            NotificationCenter.default.post(name: name, object: object)
        }
    }
}

// MARK: - Storage Health Stats

public struct StorageHealthStats: Sendable {
    public let availableGB: Double
    public let avgWriteLatencyMs: Double
    public let maxWriteLatencyMs: Double
    public let slowWriteCount: Int
    public let criticalWriteCount: Int
    public let spinupCount: Int
}

// MARK: - Disk Space Monitor (preserved for standalone use)

/// Lightweight disk space querying.
public struct DiskSpaceMonitor {
    public static func availableBytes(at url: URL) throws -> Int64 {
        do {
            let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            if let cap = values.volumeAvailableCapacityForImportantUsage {
                return Int64(cap)
            }
            let fs = try FileManager.default.attributesOfFileSystem(forPath: url.path)
            if let free = fs[.systemFreeSize] as? NSNumber {
                return free.int64Value
            }
            return 0
        } catch {
            throw StorageError.fileReadFailed(path: url.path, underlying: error.localizedDescription)
        }
    }
}
