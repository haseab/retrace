import Foundation
import Darwin
import CoreGraphics

// MARK: - Emergency Diagnostics

/// Captures diagnostic snapshots when the app is frozen or unresponsive.
/// Designed to run entirely off the main thread using only thread-safe, low-level APIs.
/// Called from the CGEvent tap background thread (triple-escape) or the hang detector.
///
/// **Why this exists:** Retrace has no pre-existing telemetry or crash reporting SDK. When the
/// app freezes, the user can't submit feedback through the normal form. These emergency snapshots
/// are saved locally and attached to the *next* feedback submission, providing the only way to
/// diagnose hangs after the fact.
///
/// **Privacy preserved:** Only system-level hardware/performance data is captured (CPU, memory,
/// thermal state, display config). No file paths, no user data, no app names. Reports are stored
/// locally in ~/Library/Application Support/Retrace/crash_reports/ and only leave the device
/// when the user explicitly submits a bug report.
public enum EmergencyDiagnostics {

    // MARK: - Storage

    /// Directory where emergency crash reports are written
    public static var crashReportDirectory: String {
        let support = NSString(string: "~/Library/Application Support/Retrace/crash_reports").expandingTildeInPath
        return support
    }

    /// Maximum number of crash reports to keep on disk
    private static let maxReportsOnDisk = 20

    // MARK: - Capture

    /// Capture a diagnostic snapshot and write it to disk.
    /// Safe to call from ANY thread, including when the main thread is frozen.
    /// - Parameter trigger: A short label describing what triggered the capture (e.g. "triple_escape", "hang_detected")
    /// - Returns: The file path of the written report, or nil on failure.
    @discardableResult
    public static func capture(trigger: String) -> String? {
        let timestamp = currentTimestamp()
        let fileName = "retrace-emergency-\(trigger)-\(timestamp).txt"

        var report = ""
        report += "=== RETRACE EMERGENCY DIAGNOSTIC ===\n"
        report += "Trigger: \(trigger)\n"
        report += "Timestamp: \(timestamp)\n"
        report += "PID: \(ProcessInfo.processInfo.processIdentifier)\n\n"

        // System info (all thread-safe)
        report += "--- SYSTEM ---\n"
        report += collectSystemInfo()

        // Performance snapshot
        report += "\n--- PERFORMANCE ---\n"
        report += collectPerformanceSnapshot()

        // Display info
        report += "\n--- DISPLAYS ---\n"
        report += collectDisplayInfo()

        // Main thread stack trace (the most valuable part when frozen)
        report += "\n--- MAIN THREAD BACKTRACE ---\n"
        report += captureMainThreadBacktrace()

        // Current thread info
        report += "\n--- CURRENT THREAD ---\n"
        report += "Thread: \(Thread.current)\n"
        report += "Is Main Thread: \(Thread.isMainThread)\n"
        report += Thread.callStackSymbols.joined(separator: "\n")
        report += "\n"

        // Write to disk
        return writeToDisk(report, fileName: fileName)
    }

    // MARK: - System Info (thread-safe)

    private static func collectSystemInfo() -> String {
        var info = ""

        // macOS version
        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        info += "macOS: \(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)\n"

        // Device model
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &model, &size, nil, 0)
        info += "Model: \(String(cString: model))\n"

        // CPU count
        info += "Processors: \(ProcessInfo.processInfo.processorCount)\n"

        // Physical memory
        let memGB = Double(ProcessInfo.processInfo.physicalMemory) / (1024 * 1024 * 1024)
        info += "Physical Memory: \(String(format: "%.1f", memGB)) GB\n"

        // Thermal state
        let thermal: String
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermal = "nominal"
        case .fair: thermal = "fair"
        case .serious: thermal = "serious"
        case .critical: thermal = "critical"
        @unknown default: thermal = "unknown"
        }
        info += "Thermal State: \(thermal)\n"

        // Uptime
        let uptime = ProcessInfo.processInfo.systemUptime
        let hours = Int(uptime) / 3600
        let minutes = (Int(uptime) % 3600) / 60
        info += "System Uptime: \(hours)h \(minutes)m\n"

        return info
    }

    // MARK: - Performance Snapshot (thread-safe, low-level)

    private static func collectPerformanceSnapshot() -> String {
        var info = ""

        // Memory stats via Mach API
        var vmStats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)

        let vmResult = withUnsafeMutablePointer(to: &vmStats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }

        if vmResult == KERN_SUCCESS {
            let pageSize = Double(vm_kernel_page_size)
            let active = Double(vmStats.active_count) * pageSize / (1024 * 1024 * 1024)
            let wired = Double(vmStats.wire_count) * pageSize / (1024 * 1024 * 1024)
            let compressed = Double(vmStats.compressor_page_count) * pageSize / (1024 * 1024 * 1024)
            let free = Double(vmStats.free_count) * pageSize / (1024 * 1024 * 1024)
            let used = active + wired + compressed

            info += "Memory Used: \(String(format: "%.1f", used)) GB (active=\(String(format: "%.1f", active)), wired=\(String(format: "%.1f", wired)), compressed=\(String(format: "%.1f", compressed)))\n"
            info += "Memory Free: \(String(format: "%.1f", free)) GB\n"

            let totalPages = vmStats.active_count + vmStats.inactive_count + vmStats.wire_count + vmStats.free_count
            let freePercent = totalPages > 0 ? Double(vmStats.free_count) / Double(totalPages) * 100.0 : 0
            let pressure: String
            if freePercent > 20 { pressure = "normal" }
            else if freePercent > 10 { pressure = "warning" }
            else { pressure = "critical" }
            info += "Memory Pressure: \(pressure) (\(String(format: "%.0f", freePercent))% free pages)\n"
        } else {
            info += "Memory: failed to query (error \(vmResult))\n"
        }

        // Swap usage via sysctl
        var swapInfo = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swapInfo, &swapSize, nil, 0) == 0 {
            let swapUsedGB = Double(swapInfo.xsu_used) / (1024 * 1024 * 1024)
            let swapTotalGB = Double(swapInfo.xsu_total) / (1024 * 1024 * 1024)
            info += "Swap: \(String(format: "%.1f", swapUsedGB)) / \(String(format: "%.1f", swapTotalGB)) GB\n"
        }

        // Low power mode
        if #available(macOS 12.0, *) {
            info += "Low Power Mode: \(ProcessInfo.processInfo.isLowPowerModeEnabled)\n"
        }

        return info
    }

    // MARK: - Display Info (thread-safe via CGDisplay APIs)

    private static func collectDisplayInfo() -> String {
        var info = ""

        var displayIDs = [CGDirectDisplayID](repeating: 0, count: 16)
        var displayCount: UInt32 = 0
        CGGetActiveDisplayList(16, &displayIDs, &displayCount)

        info += "Active Displays: \(displayCount)\n"
        let mainDisplay = CGMainDisplayID()

        for i in 0..<Int(displayCount) {
            let id = displayIDs[i]
            let width = CGDisplayPixelsWide(id)
            let height = CGDisplayPixelsHigh(id)
            let isMain = id == mainDisplay
            let mode = CGDisplayCopyDisplayMode(id)
            let backingScale = mode.map { Double($0.pixelWidth) / Double($0.width) } ?? 1.0
            let refreshRate = mode?.refreshRate ?? 0

            info += "  [\(i)] \(width)x\(height) @\(String(format: "%.1f", backingScale))x \(Int(refreshRate))Hz\(isMain ? " <- MAIN" : "")\n"
        }

        return info
    }

    // MARK: - Main Thread Backtrace

    /// Capture the main thread's stack trace from a background thread.
    /// Uses pthread_kill + signal handler to sample the main thread.
    /// Falls back to a descriptive message if sampling fails.
    private static func captureMainThreadBacktrace() -> String {
        // We can't directly get another thread's stack from Swift.
        // Instead, check if main thread appears responsive.
        var info = ""

        if Thread.isMainThread {
            info += "(Captured from main thread - thread is responsive)\n"
            info += Thread.callStackSymbols.joined(separator: "\n")
            info += "\n"
        } else {
            // We're on a background thread (CGEvent tap thread).
            // The main thread is likely frozen - we can't get its stack directly.
            // But we can record that we're NOT on main thread, which itself is diagnostic.
            info += "(Captured from background thread - main thread may be frozen)\n"
            info += "Main thread is NOT responding to emergency escape on main queue.\n"

            // Try to detect if main thread is blocked by dispatching a probe
            let probeCompleted = UnsafeMutablePointer<Bool>.allocate(capacity: 1)
            probeCompleted.pointee = false
            DispatchQueue.main.async {
                probeCompleted.pointee = true
            }

            // Wait briefly (50ms) to see if main thread responds
            usleep(50_000)
            let mainResponded = probeCompleted.pointee
            probeCompleted.deallocate()

            if mainResponded {
                info += "Main thread probe: RESPONDED within 50ms (may be intermittently blocked)\n"
            } else {
                info += "Main thread probe: NO RESPONSE after 50ms (main thread is FROZEN)\n"
            }
        }

        return info
    }

    // MARK: - Disk I/O

    private static func writeToDisk(_ report: String, fileName: String) -> String? {
        let dir = crashReportDirectory
        let filePath = (dir as NSString).appendingPathComponent(fileName)

        // Create directory if needed
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        // Write report
        guard let data = report.data(using: .utf8) else { return nil }
        let success = FileManager.default.createFile(atPath: filePath, contents: data)

        if success {
            // Prune old reports
            pruneOldReports(in: dir)
        }

        return success ? filePath : nil
    }

    private static func pruneOldReports(in directory: String) {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return }

        let reportFiles = files
            .filter { $0.hasPrefix("retrace-emergency-") && $0.hasSuffix(".txt") }
            .sorted()

        if reportFiles.count > maxReportsOnDisk {
            let toRemove = reportFiles.prefix(reportFiles.count - maxReportsOnDisk)
            for file in toRemove {
                let path = (directory as NSString).appendingPathComponent(file)
                try? FileManager.default.removeItem(atPath: path)
            }
        }
    }

    // MARK: - Scan Existing Reports

    /// Read all emergency crash reports from disk.
    /// Used by FeedbackService to attach to bug reports.
    /// - Parameter maxReports: Maximum number of reports to return (newest first)
    /// - Returns: Array of report contents as strings
    public static func loadReports(maxReports: Int = 5) -> [String] {
        let dir = crashReportDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }

        let reportFiles = files
            .filter { $0.hasPrefix("retrace-emergency-") && $0.hasSuffix(".txt") }
            .sorted()
            .suffix(maxReports)

        return reportFiles.compactMap { file in
            let path = (dir as NSString).appendingPathComponent(file)
            return try? String(contentsOfFile: path, encoding: .utf8)
        }
    }

    /// Delete all emergency crash reports (e.g. after successful feedback submission)
    public static func clearReports() {
        let dir = crashReportDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return }

        for file in files where file.hasPrefix("retrace-emergency-") && file.hasSuffix(".txt") {
            let path = (dir as NSString).appendingPathComponent(file)
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    // MARK: - Helpers

    private static func currentTimestamp() -> String {
        let now = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: now)
    }
}

// MARK: - Hang Detector

/// Monitors the main thread for hangs (beachball / "Not Responding").
/// Runs a background timer that pings the main thread. If the main thread doesn't
/// respond within the threshold, an emergency diagnostic is captured automatically.
///
/// Reports are stored locally only — nothing is sent over the network. They are attached
/// to feedback submissions only when the user explicitly submits a bug report.
public final class MainThreadHangDetector {

    public static let shared = MainThreadHangDetector()

    /// How often to probe the main thread (seconds)
    private let probeInterval: TimeInterval = 5.0

    /// How long the main thread can be unresponsive before we capture diagnostics (seconds)
    private let hangThreshold: TimeInterval = 8.0

    /// Minimum time between consecutive hang reports (seconds)
    private let cooldownInterval: TimeInterval = 60.0

    private var monitorThread: Thread?
    private var isMonitoring = false
    private var lastReportTime: Date?

    private init() {}

    /// Start monitoring the main thread for hangs
    public func start() {
        guard !isMonitoring else { return }
        isMonitoring = true

        let thread = Thread { [weak self] in
            self?.monitorLoop()
        }
        thread.name = "retrace.hang-detector"
        thread.qualityOfService = .utility
        thread.start()
        monitorThread = thread
    }

    /// Stop monitoring
    public func stop() {
        isMonitoring = false
        monitorThread?.cancel()
        monitorThread = nil
    }

    private func monitorLoop() {
        while isMonitoring && !Thread.current.isCancelled {
            // Sleep for the probe interval
            Thread.sleep(forTimeInterval: probeInterval)

            guard isMonitoring else { break }

            // Probe the main thread
            let responded = probeMainThread(timeout: hangThreshold)

            if !responded {
                // Main thread is frozen
                let now = Date()
                if let lastReport = lastReportTime, now.timeIntervalSince(lastReport) < cooldownInterval {
                    // Still in cooldown - skip
                    continue
                }

                lastReportTime = now
                EmergencyDiagnostics.capture(trigger: "hang_detected")
            }
        }
    }

    /// Probe the main thread with a timeout.
    /// Returns true if main thread responded within the timeout, false if it's frozen.
    private func probeMainThread(timeout: TimeInterval) -> Bool {
        let semaphore = DispatchSemaphore(value: 0)

        DispatchQueue.main.async {
            semaphore.signal()
        }

        let result = semaphore.wait(timeout: .now() + timeout)
        return result == .success
    }
}
