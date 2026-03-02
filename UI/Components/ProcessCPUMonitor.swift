import Foundation
import SwiftUI
import Shared
import Darwin
import AppKit

struct ProcessCPURow: Identifiable {
    let id: String
    let name: String
    let cpuSeconds: Double
    let shareOfTrackedPercent: Double
    let capacityPercent: Double
    let averagePercent: Double
}

struct ProcessMemoryRow: Identifiable {
    let id: String
    let name: String
    let currentBytes: UInt64
    let averageBytes: UInt64
    let peakBytes: UInt64
    let currentSharePercent: Double
    let averageSharePercent: Double
}

struct ProcessCPUSnapshot {
    static let empty = ProcessCPUSnapshot(
        sampleDurationSeconds: 0,
        peakInstantPercent: 0,
        peakCapacityPercent: 0,
        averagePercent: 0,
        capacityPercent: 0,
        trackedSharePercent: 0,
        logicalCoreCount: 0,
        retraceCPUSeconds: 0,
        totalTrackedCPUSeconds: 0,
        retraceRank: nil,
        retraceGroupKey: nil,
        peakPercentByGroup: [:],
        topProcesses: [],
        totalTrackedCurrentResidentBytes: 0,
        totalTrackedAverageResidentBytes: 0,
        peakResidentBytesByGroup: [:],
        topMemoryProcesses: [],
        latestSampleTimestamp: nil
    )

    let sampleDurationSeconds: TimeInterval
    let peakInstantPercent: Double
    let peakCapacityPercent: Double
    let averagePercent: Double
    let capacityPercent: Double
    let trackedSharePercent: Double
    let logicalCoreCount: Int
    let retraceCPUSeconds: Double
    let totalTrackedCPUSeconds: Double
    let retraceRank: Int?
    let retraceGroupKey: String?
    let peakPercentByGroup: [String: Double]
    let topProcesses: [ProcessCPURow]
    let totalTrackedCurrentResidentBytes: UInt64
    let totalTrackedAverageResidentBytes: UInt64
    let peakResidentBytesByGroup: [String: UInt64]
    let topMemoryProcesses: [ProcessMemoryRow]
    let latestSampleTimestamp: TimeInterval?

    var hasEnoughData: Bool {
        sampleDurationSeconds >= 5 && !topProcesses.isEmpty
    }

    var hasEnoughMemoryData: Bool {
        sampleDurationSeconds >= 5 && !topMemoryProcesses.isEmpty
    }
}

@MainActor
final class ProcessCPUMonitor: ObservableObject {
    enum Consumer: Hashable {
        case settingsPower
        case systemMonitor
    }

    static let shared = ProcessCPUMonitor()

    @Published private(set) var snapshot = ProcessCPUSnapshot.empty

    private var samplingTask: Task<Void, Never>?
    private let sampler = ProcessCPULogSampler()
    private let samplerRequestGate = SamplerRequestGate()
    private var sampleIntervalSeconds: TimeInterval = 5
    private var activeConsumers: Set<Consumer> = []

    private static let fastPollingInterval: TimeInterval = 1
    private static let slowPollingInterval: TimeInterval = 15
    private static let batteryPollingInterval: TimeInterval = 30
    private static let snapshotWindowDuration: TimeInterval = 12 * 60 * 60

    private init() {}

    func start() {
        guard samplingTask == nil else { return }
        restartSamplingLoop()
    }

    func setConsumerVisible(_ consumer: Consumer, isVisible: Bool) {
        if isVisible {
            activeConsumers.insert(consumer)
        } else {
            activeConsumers.remove(consumer)
        }

        if activeConsumers.isEmpty {
            Task(priority: .utility) { [sampler] in
                await sampler.dropWindowState()
            }
        }

        let desiredInterval = preferredSamplingInterval()
        if samplingTask == nil {
            sampleIntervalSeconds = desiredInterval
            restartSamplingLoop()
            return
        }

        guard sampleIntervalSeconds != desiredInterval else { return }
        sampleIntervalSeconds = desiredInterval
        restartSamplingLoop()
    }

    private func preferredSamplingInterval() -> TimeInterval {
        if !activeConsumers.isEmpty {
            return Self.fastPollingInterval
        }

        if ProcessInfo.processInfo.isLowPowerModeEnabled {
            return Self.batteryPollingInterval
        }

        let powerSource = PowerStateMonitor.shared.getCurrentPowerSource()
        if powerSource == .battery {
            return Self.batteryPollingInterval
        }

        return Self.slowPollingInterval
    }

    private func restartSamplingLoop() {
        samplingTask?.cancel()
        let initialInterval = max(1, sampleIntervalSeconds)
        let taskPriority: TaskPriority = activeConsumers.isEmpty ? .utility : .userInitiated

        samplingTask = Task(priority: taskPriority) { [weak self] in
            guard let self else { return }
            await runSamplingLoop(initialIntervalSeconds: initialInterval)
        }
    }

    func stop() {
        samplingTask?.cancel()
        samplingTask = nil
    }

    deinit {
        samplingTask?.cancel()
    }

    private func runSamplingLoop(initialIntervalSeconds: TimeInterval) async {
        var intervalSeconds = max(1, initialIntervalSeconds)

        while !Task.isCancelled {
            let shouldRebuildSnapshot = !activeConsumers.isEmpty
            let intervalForRequest = intervalSeconds
            var nextSnapshot = await samplerRequestGate.runIfIdle { [sampler] in
                await sampler.sampleAndMaybeLoadSnapshot(
                    windowDuration: Self.snapshotWindowDuration,
                    expectedIntervalSeconds: intervalForRequest,
                    shouldBuildSnapshot: shouldRebuildSnapshot
                )
            }
            if nextSnapshot == nil, shouldRebuildSnapshot {
                // If we raced with a one-off reset request, try once more before reporting a miss.
                nextSnapshot = await samplerRequestGate.runIfIdle { [sampler] in
                    await sampler.sampleAndMaybeLoadSnapshot(
                        windowDuration: Self.snapshotWindowDuration,
                        expectedIntervalSeconds: intervalForRequest,
                        shouldBuildSnapshot: shouldRebuildSnapshot
                    )
                }
            }
            if let nextSnapshot {
                snapshot = nextSnapshot
            }
            sampleIntervalSeconds = preferredSamplingInterval()
            intervalSeconds = max(1, sampleIntervalSeconds)

            let sleepNanoseconds = Int64(intervalSeconds * 1_000_000_000)
            do {
                try await Task.sleep(for: .nanoseconds(sleepNanoseconds), clock: .continuous)
            } catch {
                break
            }
        }
    }

    func resetSampler() {
        Task(priority: .utility) { [weak self] in
            guard let self else { return }
            let intervalSeconds = max(1, self.sampleIntervalSeconds)
            let refreshedSnapshot = await self.samplerRequestGate.runIfIdle { [sampler = self.sampler] in
                await sampler.resetAndLoadSnapshot(
                    windowDuration: Self.snapshotWindowDuration,
                    expectedIntervalSeconds: intervalSeconds
                )
            }
            guard let refreshedSnapshot else { return }
            await MainActor.run {
                self.snapshot = refreshedSnapshot
            }
        }
    }
}

private actor SamplerRequestGate {
    private var isRunning = false

    func runIfIdle<T: Sendable>(_ operation: @Sendable () async -> T?) async -> T? {
        guard !isRunning else { return nil }
        isRunning = true
        defer { isRunning = false }
        return await operation()
    }
}

private actor ProcessCPULogSampler {
    private typealias ProcPidRusageFunction = @convention(c) (pid_t, Int32, UnsafeMutableRawPointer?) -> Int32

    private struct ProcessIdentity {
        let key: String
        let name: String
    }

    private struct ProcessTaskMetrics {
        let cpuAbsoluteUnits: UInt64
        let residentBytes: UInt64
    }

    private struct BundleMetadata {
        let bundleID: String?
        let displayName: String
        let canonicalAppPath: String
    }

    private struct CPULogEntry: Codable {
        let timestamp: TimeInterval
        let durationSeconds: TimeInterval
        let retraceGroupKey: String?
        let groupDeltaNanoseconds: [String: UInt64]
        let groupDeltaUnit: String?
        let groupResidentBytes: [String: UInt64]?
        let groupDisplayNames: [String: String]?
    }

    private static let logRetentionDuration: TimeInterval = 7 * 24 * 60 * 60
    private static let logCompactionInterval: TimeInterval = 12 * 60 * 60
    private static let displayNamePersistInterval: TimeInterval = 30
    private static let logReadChunkSize = 64 * 1024
    private static let nanosecondUnit = "ns"
    private static let acceptedSampleGapMultiplier: TimeInterval = 4.0
    private static let minimumAcceptedSampleGapSeconds: TimeInterval = 4.0
    private static let procPidRusageFunction: ProcPidRusageFunction? = {
        guard let symbol = dlsym(dlopen(nil, RTLD_NOW), "proc_pid_rusage") else {
            return nil
        }
        return unsafeBitCast(symbol, to: ProcPidRusageFunction.self)
    }()
    private static let machTimebaseInfo: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        if info.denom == 0 {
            info.denom = 1
        }
        return info
    }()

    private let retracePID: pid_t = getpid()
    private var lastSampleDate: Date?
    private var lastCPUByPID: [pid_t: UInt64] = [:]
    private var identityByPID: [pid_t: ProcessIdentity] = [:]
    private var groupDisplayNameByKey: [String: String] = [:]
    private var displayNameMapDirty = false
    private var lastDisplayNamePersistDate: Date?
    private var retraceGroupKey: String?
    private var lastCompactionDate: Date?
    private let retraceBundleID: String
    private let retraceDisplayName: String
    private var bundleMetadataByCanonicalPath: [String: BundleMetadata] = [:]
    private var loadedWindowDuration: TimeInterval?
    private var windowStateNeedsReload = true
    private var windowEntries: [CPULogEntry] = []
    private var windowTotalDuration: TimeInterval = 0
    private var windowCumulativeByGroup: [String: UInt64] = [:]
    private var windowPeakPercentByGroup: [String: Double] = [:]
    private var windowMemoryIntegralByteSecondsByGroup: [String: Double] = [:]
    private var windowPeakResidentBytesByGroup: [String: UInt64] = [:]
    private let logFileURL: URL
    private let displayNamesFileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init() {
        retraceBundleID = Bundle.main.bundleIdentifier ?? "io.retrace.app"
        retraceDisplayName = (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? "Retrace"
        logFileURL = Self.makeLogFileURL()
        displayNamesFileURL = Self.makeDisplayNamesFileURL()
        Self.ensureLogFileExists(at: logFileURL)
        groupDisplayNameByKey = Self.readGroupDisplayNameMap(from: displayNamesFileURL)
        let retraceGroup = "bundle:\(retraceBundleID)"
        if groupDisplayNameByKey[retraceGroup] != retraceDisplayName {
            groupDisplayNameByKey[retraceGroup] = retraceDisplayName
            displayNameMapDirty = true
        }
    }

    func sampleAndMaybeLoadSnapshot(
        windowDuration: TimeInterval,
        expectedIntervalSeconds: TimeInterval,
        shouldBuildSnapshot: Bool
    ) -> ProcessCPUSnapshot? {
        let now = Date()
        let appendedEntry = captureSample(at: now, expectedIntervalSeconds: expectedIntervalSeconds)
        maybePersistDisplayNameMap(at: now)
        maybeCompactLog(at: now)

        guard shouldBuildSnapshot else {
            windowStateNeedsReload = true
            return nil
        }

        if loadedWindowDuration != windowDuration || windowStateNeedsReload {
            rebuildWindowStateFromLog(windowDuration: windowDuration, now: now)
        } else if let appendedEntry {
            appendEntryToWindowState(appendedEntry)
            pruneWindowState(cutoffTimestamp: now.addingTimeInterval(-windowDuration).timeIntervalSince1970)
        } else {
            pruneWindowState(cutoffTimestamp: now.addingTimeInterval(-windowDuration).timeIntervalSince1970)
        }

        return snapshotFromWindowState()
    }

    func resetAndLoadSnapshot(
        windowDuration: TimeInterval,
        expectedIntervalSeconds: TimeInterval
    ) -> ProcessCPUSnapshot {
        clearLogAndState()
        let now = Date()
        _ = captureSample(at: now, expectedIntervalSeconds: expectedIntervalSeconds)
        maybePersistDisplayNameMap(at: now, force: true)
        rebuildWindowStateFromLog(windowDuration: windowDuration, now: now)
        return snapshotFromWindowState()
    }

    func dropWindowState() {
        loadedWindowDuration = nil
        windowStateNeedsReload = true
        windowEntries.removeAll(keepingCapacity: false)
        windowTotalDuration = 0
        windowCumulativeByGroup.removeAll(keepingCapacity: false)
        windowPeakPercentByGroup.removeAll(keepingCapacity: false)
        windowMemoryIntegralByteSecondsByGroup.removeAll(keepingCapacity: false)
        windowPeakResidentBytesByGroup.removeAll(keepingCapacity: false)
    }

    private func captureSample(at now: Date, expectedIntervalSeconds: TimeInterval) -> CPULogEntry? {
        let allPIDs = Self.listAllProcessIDs()

        var currentCPUByPID: [pid_t: UInt64] = [:]
        var currentResidentBytesByPID: [pid_t: UInt64] = [:]
        var currentIdentityByPID: [pid_t: ProcessIdentity] = [:]

        for pid in allPIDs {
            guard let taskMetrics = Self.processTaskMetrics(for: pid) else { continue }
            guard let identity = identityByPID[pid] ?? resolveIdentity(for: pid) else { continue }

            currentCPUByPID[pid] = taskMetrics.cpuAbsoluteUnits
            currentResidentBytesByPID[pid] = taskMetrics.residentBytes
            currentIdentityByPID[pid] = identity
            updateGroupDisplayNameIfNeeded(forKey: identity.key, name: identity.name)
            if pid == retracePID {
                retraceGroupKey = identity.key
            }
        }

        var appendedEntry: CPULogEntry?

        if let lastSampleDate {
            let duration = now.timeIntervalSince(lastSampleDate)
            let acceptedSampleGap = max(
                Self.minimumAcceptedSampleGapSeconds,
                max(1, expectedIntervalSeconds) * Self.acceptedSampleGapMultiplier
            )

            let groupResidentBytes = aggregatedResidentBytes(
                currentResidentBytesByPID: currentResidentBytesByPID,
                currentIdentityByPID: currentIdentityByPID
            )

            if duration > 0, duration <= acceptedSampleGap {
                var groupDeltaNanoseconds: [String: UInt64] = [:]

                for (pid, currentCPU) in currentCPUByPID {
                    guard let previousCPU = lastCPUByPID[pid], currentCPU >= previousCPU else { continue }
                    guard let identity = currentIdentityByPID[pid] else { continue }

                    let deltaAbsoluteUnits = currentCPU - previousCPU
                    if deltaAbsoluteUnits > 0 {
                        let deltaNanoseconds = Self.absoluteTimeToNanoseconds(deltaAbsoluteUnits)
                        groupDeltaNanoseconds[identity.key, default: 0] += deltaNanoseconds
                    }
                }

                if !groupDeltaNanoseconds.isEmpty || !groupResidentBytes.isEmpty {
                    let entry = CPULogEntry(
                        timestamp: now.timeIntervalSince1970,
                        durationSeconds: duration,
                        retraceGroupKey: retraceGroupKey,
                        groupDeltaNanoseconds: groupDeltaNanoseconds,
                        groupDeltaUnit: Self.nanosecondUnit,
                        groupResidentBytes: groupResidentBytes.isEmpty ? nil : groupResidentBytes,
                        groupDisplayNames: nil
                    )
                    appendLogEntry(entry)
                    appendedEntry = entry
                }
            } else if !groupResidentBytes.isEmpty {
                // Recover quickly after long scheduling gaps by appending a memory-only heartbeat.
                // This keeps "Now" memory fresh while avoiding oversized CPU deltas.
                let heartbeatDuration = max(1, expectedIntervalSeconds)
                let entry = CPULogEntry(
                    timestamp: now.timeIntervalSince1970,
                    durationSeconds: heartbeatDuration,
                    retraceGroupKey: retraceGroupKey,
                    groupDeltaNanoseconds: [:],
                    groupDeltaUnit: Self.nanosecondUnit,
                    groupResidentBytes: groupResidentBytes,
                    groupDisplayNames: nil
                )
                appendLogEntry(entry)
                appendedEntry = entry
            }
        }

        lastSampleDate = now
        lastCPUByPID = currentCPUByPID
        identityByPID = currentIdentityByPID

        return appendedEntry
    }

    private func aggregatedResidentBytes(
        currentResidentBytesByPID: [pid_t: UInt64],
        currentIdentityByPID: [pid_t: ProcessIdentity]
    ) -> [String: UInt64] {
        var groupResidentBytes: [String: UInt64] = [:]
        groupResidentBytes.reserveCapacity(currentIdentityByPID.count)

        for (pid, residentBytes) in currentResidentBytesByPID {
            guard let identity = currentIdentityByPID[pid] else { continue }
            let previous = groupResidentBytes[identity.key] ?? 0
            groupResidentBytes[identity.key] = Self.saturatingAdd(previous, residentBytes)
        }

        return groupResidentBytes
    }

    private func resolveIdentity(for pid: pid_t) -> ProcessIdentity? {
        if pid == retracePID {
            return ProcessIdentity(
                key: "bundle:\(retraceBundleID)",
                name: retraceDisplayName
            )
        }

        if let identity = resolveBundleBackedIdentity(for: pid) {
            return identity
        }

        if let identity = resolveWebKitHostedIdentity(for: pid) {
            return identity
        }

        let executableName = Self.processName(for: pid)
            ?? Self.processPath(for: pid).map { URL(fileURLWithPath: $0).lastPathComponent }
            ?? "pid\(pid)"

        let normalizedName = Self.normalizedKeyComponent(executableName)
        return ProcessIdentity(
            key: "proc:\(normalizedName)",
            name: executableName
        )
    }

    private func resolveBundleBackedIdentity(for pid: pid_t) -> ProcessIdentity? {
        guard let path = Self.processPath(for: pid),
              let appPath = Self.appBundlePath(from: path) else {
            return nil
        }

        let metadata = bundleMetadata(forAppPath: appPath)
        if let bundleID = metadata.bundleID, !bundleID.isEmpty {
            return ProcessIdentity(
                key: "bundle:\(bundleID)",
                name: metadata.displayName
            )
        }

        return ProcessIdentity(
            key: "app:\(metadata.canonicalAppPath)",
            name: metadata.displayName
        )
    }

    private func resolveWebKitHostedIdentity(for pid: pid_t) -> ProcessIdentity? {
        guard Self.isWebKitWebContentProcess(pid: pid) else {
            return nil
        }

        guard let runningApp = NSRunningApplication(processIdentifier: pid),
              let localizedName = normalizedBundleString(runningApp.localizedName),
              let hostName = normalizedWebKitHostName(from: localizedName) else {
            return nil
        }

        return ProcessIdentity(
            key: "webkit-host:\(Self.normalizedKeyComponent(hostName))",
            name: hostName
        )
    }

    private static func isWebKitWebContentProcess(pid: pid_t) -> Bool {
        if let processName = processName(for: pid),
           processName.caseInsensitiveCompare("com.apple.WebKit.WebContent") == .orderedSame {
            return true
        }

        if let executablePath = processPath(for: pid),
           executablePath.range(
               of: "/com.apple.WebKit.WebContent.xpc/",
               options: [.caseInsensitive]
           ) != nil {
            return true
        }

        return false
    }

    private func normalizedWebKitHostName(from localizedName: String) -> String? {
        let trimmed = localizedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.caseInsensitiveCompare("com.apple.WebKit.WebContent") == .orderedSame
            || trimmed.caseInsensitiveCompare("Web Content") == .orderedSame {
            return nil
        }

        let suffix = " web content"
        let lowered = trimmed.lowercased()
        if lowered.hasSuffix(suffix) {
            let endIndex = trimmed.index(trimmed.endIndex, offsetBy: -suffix.count)
            let baseName = String(trimmed[..<endIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            return baseName.isEmpty ? nil : baseName
        }

        return trimmed
    }

    private func bundleMetadata(forAppPath appPath: String) -> BundleMetadata {
        let canonicalPath = appPath.lowercased()
        if let cached = bundleMetadataByCanonicalPath[canonicalPath] {
            return cached
        }

        let appURL = URL(fileURLWithPath: appPath)
        let fallbackName = appURL.deletingPathExtension().lastPathComponent
        var bundleID: String?
        var displayName = fallbackName

        if let bundle = Bundle(url: appURL) {
            bundleID = bundle.bundleIdentifier

            if let bundleDisplayName = normalizedBundleString(
                bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ) {
                displayName = bundleDisplayName
            } else if let bundleName = normalizedBundleString(
                bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ) {
                displayName = bundleName
            }
        }

        let metadata = BundleMetadata(
            bundleID: bundleID,
            displayName: displayName,
            canonicalAppPath: canonicalPath
        )
        bundleMetadataByCanonicalPath[canonicalPath] = metadata
        return metadata
    }

    private func normalizedBundleString(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private func updateGroupDisplayNameIfNeeded(forKey key: String, name: String) {
        guard !key.isEmpty else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        if groupDisplayNameByKey[key] == trimmedName {
            return
        }
        groupDisplayNameByKey[key] = trimmedName
        displayNameMapDirty = true
    }

    private func maybePersistDisplayNameMap(at now: Date, force: Bool = false) {
        guard displayNameMapDirty else { return }
        if !force, let lastDisplayNamePersistDate,
           now.timeIntervalSince(lastDisplayNamePersistDate) < Self.displayNamePersistInterval {
            return
        }

        do {
            Self.ensureLogFileExists(at: displayNamesFileURL)
            let data = try encoder.encode(groupDisplayNameByKey)
            try data.write(to: displayNamesFileURL, options: .atomic)
            displayNameMapDirty = false
            lastDisplayNamePersistDate = now
        } catch {
            Log.warning("[SettingsView] Failed to persist CPU group display names: \(error)", category: .ui)
        }
    }

    private static func readGroupDisplayNameMap(from fileURL: URL) -> [String: String] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [:] }

        do {
            let data = try Data(contentsOf: fileURL)
            guard !data.isEmpty else { return [:] }
            let decoded = try JSONDecoder().decode([String: String].self, from: data)
            var sanitized: [String: String] = [:]
            sanitized.reserveCapacity(decoded.count)
            for (key, value) in decoded {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !key.isEmpty, !trimmed.isEmpty else { continue }
                sanitized[key] = trimmed
            }
            return sanitized
        } catch {
            Log.warning("[SettingsView] Failed to read CPU group display names: \(error)", category: .ui)
            return [:]
        }
    }

    private func applyLegacyDisplayNamesIfPresent(from entry: CPULogEntry) {
        guard let groupDisplayNames = entry.groupDisplayNames, !groupDisplayNames.isEmpty else {
            return
        }
        for (key, name) in groupDisplayNames {
            updateGroupDisplayNameIfNeeded(forKey: key, name: name)
        }
    }

    private func appendEntryToWindowState(_ entry: CPULogEntry) {
        applyLegacyDisplayNamesIfPresent(from: entry)
        windowEntries.append(entry)
        windowTotalDuration += entry.durationSeconds
        for (key, rawDelta) in entry.groupDeltaNanoseconds {
            let delta = Self.normalizedDeltaNanoseconds(rawDelta: rawDelta, unit: entry.groupDeltaUnit)
            windowCumulativeByGroup[key, default: 0] += delta
            guard entry.durationSeconds > 0 else { continue }
            let instantPercent = (Double(delta) / 1_000_000_000.0) / entry.durationSeconds * 100.0
            if instantPercent > (windowPeakPercentByGroup[key] ?? 0) {
                windowPeakPercentByGroup[key] = instantPercent
            }
        }

        guard let groupResidentBytes = entry.groupResidentBytes, !groupResidentBytes.isEmpty else {
            return
        }

        let sampleDuration = max(entry.durationSeconds, 0)
        for (key, residentBytes) in groupResidentBytes {
            if sampleDuration > 0 {
                windowMemoryIntegralByteSecondsByGroup[key, default: 0] += Double(residentBytes) * sampleDuration
            }
            if residentBytes > (windowPeakResidentBytesByGroup[key] ?? 0) {
                windowPeakResidentBytesByGroup[key] = residentBytes
            }
        }
    }

    private func pruneWindowState(cutoffTimestamp: TimeInterval) {
        guard !windowEntries.isEmpty else { return }

        var peakKeysToRebuild: Set<String> = []
        var peakMemoryKeysToRebuild: Set<String> = []
        var removeCount = 0
        while removeCount < windowEntries.count, windowEntries[removeCount].timestamp < cutoffTimestamp {
            let entry = windowEntries[removeCount]
            windowTotalDuration -= entry.durationSeconds
            for (key, rawDelta) in entry.groupDeltaNanoseconds {
                let delta = Self.normalizedDeltaNanoseconds(rawDelta: rawDelta, unit: entry.groupDeltaUnit)
                guard let current = windowCumulativeByGroup[key] else { continue }
                if current <= delta {
                    windowCumulativeByGroup.removeValue(forKey: key)
                } else {
                    windowCumulativeByGroup[key] = current - delta
                }

                guard entry.durationSeconds > 0,
                      let currentPeak = windowPeakPercentByGroup[key] else { continue }
                let instantPercent = (Double(delta) / 1_000_000_000.0) / entry.durationSeconds * 100.0
                if instantPercent >= (currentPeak - 0.000_001) {
                    peakKeysToRebuild.insert(key)
                }
            }

            if let groupResidentBytes = entry.groupResidentBytes, !groupResidentBytes.isEmpty {
                let sampleDuration = max(entry.durationSeconds, 0)
                for (key, residentBytes) in groupResidentBytes {
                    if sampleDuration > 0 {
                        let deltaByteSeconds = Double(residentBytes) * sampleDuration
                        let remaining = (windowMemoryIntegralByteSecondsByGroup[key] ?? 0) - deltaByteSeconds
                        if remaining <= 0.000_001 {
                            windowMemoryIntegralByteSecondsByGroup.removeValue(forKey: key)
                            windowPeakResidentBytesByGroup.removeValue(forKey: key)
                            peakMemoryKeysToRebuild.remove(key)
                        } else {
                            windowMemoryIntegralByteSecondsByGroup[key] = remaining
                        }
                    }

                    if let currentPeakBytes = windowPeakResidentBytesByGroup[key], residentBytes >= currentPeakBytes {
                        peakMemoryKeysToRebuild.insert(key)
                    }
                }
            }
            removeCount += 1
        }

        if removeCount > 0 {
            windowEntries.removeFirst(removeCount)
            recomputePeakPercentages(for: peakKeysToRebuild)
            recomputePeakResidentBytes(for: peakMemoryKeysToRebuild)
        }

        if windowTotalDuration < 0 {
            windowTotalDuration = 0
        }
    }

    private func rebuildWindowStateFromLog(windowDuration: TimeInterval, now: Date) {
        loadedWindowDuration = windowDuration
        windowEntries.removeAll(keepingCapacity: true)
        windowTotalDuration = 0
        windowCumulativeByGroup.removeAll(keepingCapacity: true)
        windowPeakPercentByGroup.removeAll(keepingCapacity: true)
        windowMemoryIntegralByteSecondsByGroup.removeAll(keepingCapacity: true)
        windowPeakResidentBytesByGroup.removeAll(keepingCapacity: true)

        let cutoffTimestamp = now.addingTimeInterval(-windowDuration).timeIntervalSince1970
        streamLogEntries { entry in
            guard entry.timestamp >= cutoffTimestamp else { return }
            appendEntryToWindowState(entry)
        }

        windowStateNeedsReload = false
        maybePersistDisplayNameMap(at: now)
    }

    private func recomputePeakPercentages(for keys: Set<String>) {
        guard !keys.isEmpty else { return }

        var recomputed: [String: Double] = [:]
        for entry in windowEntries where entry.durationSeconds > 0 {
            for (key, rawDelta) in entry.groupDeltaNanoseconds {
                guard keys.contains(key) else { continue }
                let delta = Self.normalizedDeltaNanoseconds(rawDelta: rawDelta, unit: entry.groupDeltaUnit)
                let instantPercent = (Double(delta) / 1_000_000_000.0) / entry.durationSeconds * 100.0
                if instantPercent > (recomputed[key] ?? 0) {
                    recomputed[key] = instantPercent
                }
            }
        }

        for key in keys {
            if windowCumulativeByGroup[key] == nil {
                windowPeakPercentByGroup.removeValue(forKey: key)
            } else if let peak = recomputed[key] {
                windowPeakPercentByGroup[key] = peak
            } else {
                windowPeakPercentByGroup.removeValue(forKey: key)
            }
        }
    }

    private func recomputePeakResidentBytes(for keys: Set<String>) {
        guard !keys.isEmpty else { return }

        var recomputed: [String: UInt64] = [:]
        for entry in windowEntries {
            guard let residentByGroup = entry.groupResidentBytes else { continue }
            for (key, residentBytes) in residentByGroup {
                guard keys.contains(key) else { continue }
                if residentBytes > (recomputed[key] ?? 0) {
                    recomputed[key] = residentBytes
                }
            }
        }

        for key in keys {
            if windowMemoryIntegralByteSecondsByGroup[key] == nil {
                windowPeakResidentBytesByGroup.removeValue(forKey: key)
            } else if let peakBytes = recomputed[key] {
                windowPeakResidentBytesByGroup[key] = peakBytes
            } else {
                windowPeakResidentBytesByGroup.removeValue(forKey: key)
            }
        }
    }

    private func snapshotFromWindowState() -> ProcessCPUSnapshot {
        let totalDuration = max(windowTotalDuration, 0)
        let cumulativeByGroup = windowCumulativeByGroup
        let peakPercentByGroup = windowPeakPercentByGroup
        let memoryIntegralByteSecondsByGroup = windowMemoryIntegralByteSecondsByGroup
        let peakResidentBytesByGroup = windowPeakResidentBytesByGroup
        let currentResidentBytesByGroup = windowEntries.last?.groupResidentBytes ?? [:]
        let displayNamesByKey = groupDisplayNameByKey
        var effectiveRetraceGroupKey = retraceGroupKey

        for entry in windowEntries {
            if effectiveRetraceGroupKey == nil {
                effectiveRetraceGroupKey = entry.retraceGroupKey
            }
        }

        let retraceNanoseconds = effectiveRetraceGroupKey.flatMap { cumulativeByGroup[$0] } ?? 0
        let retraceCPUSeconds = Double(retraceNanoseconds) / 1_000_000_000.0
        let totalTrackedNanoseconds = cumulativeByGroup.values.reduce(UInt64(0), +)
        let totalTrackedCPUSeconds = Double(totalTrackedNanoseconds) / 1_000_000_000.0
        let logicalCoreCount = max(1, ProcessInfo.processInfo.activeProcessorCount)
        let capacityDenominatorSeconds = totalDuration * Double(logicalCoreCount)

        let retracePeakCorePercent = effectiveRetraceGroupKey.flatMap { peakPercentByGroup[$0] } ?? 0
        let retracePeakCapacityPercent = retracePeakCorePercent / Double(logicalCoreCount)
        let averageRetracePercent = totalDuration > 0
            ? (retraceCPUSeconds / totalDuration) * 100.0
            : 0
        let retraceCapacityPercent = capacityDenominatorSeconds > 0
            ? (retraceCPUSeconds / capacityDenominatorSeconds) * 100.0
            : 0
        let retraceTrackedSharePercent = totalTrackedCPUSeconds > 0
            ? (retraceCPUSeconds / totalTrackedCPUSeconds) * 100.0
            : 0

        let rankedProcesses = cumulativeByGroup.map { key, nanoseconds -> ProcessCPURow in
            let seconds = Double(nanoseconds) / 1_000_000_000.0
            let shareOfTrackedPercent = totalTrackedCPUSeconds > 0
                ? (seconds / totalTrackedCPUSeconds) * 100.0
                : 0
            let capacityPercent = capacityDenominatorSeconds > 0
                ? (seconds / capacityDenominatorSeconds) * 100.0
                : 0
            let averagePercent = totalDuration > 0 ? (seconds / totalDuration) * 100.0 : 0
            let name = displayNamesByKey[key] ?? key
            return ProcessCPURow(
                id: key,
                name: name,
                cpuSeconds: seconds,
                shareOfTrackedPercent: shareOfTrackedPercent,
                capacityPercent: capacityPercent,
                averagePercent: averagePercent
            )
        }
        .sorted { $0.cpuSeconds > $1.cpuSeconds }

        let totalTrackedCurrentResidentBytes = currentResidentBytesByGroup.values.reduce(UInt64(0), Self.saturatingAdd)
        let totalTrackedAverageResidentBytesDouble = totalDuration > 0
            ? memoryIntegralByteSecondsByGroup.values.reduce(0, +) / totalDuration
            : 0
        let totalTrackedAverageResidentBytes = Self.doubleToUInt64(totalTrackedAverageResidentBytesDouble)

        let memoryKeys = Set(memoryIntegralByteSecondsByGroup.keys)
            .union(currentResidentBytesByGroup.keys)
            .union(peakResidentBytesByGroup.keys)

        let rankedMemoryProcesses = memoryKeys
            .map { key -> ProcessMemoryRow in
                let currentBytes = currentResidentBytesByGroup[key] ?? 0
                let averageBytesDouble = totalDuration > 0
                    ? (memoryIntegralByteSecondsByGroup[key] ?? 0) / totalDuration
                    : Double(currentBytes)
                let averageBytes = Self.doubleToUInt64(averageBytesDouble)
                let peakBytes = max(
                    peakResidentBytesByGroup[key] ?? 0,
                    currentBytes,
                    averageBytes
                )
                let currentSharePercent = totalTrackedCurrentResidentBytes > 0
                    ? (Double(currentBytes) / Double(totalTrackedCurrentResidentBytes)) * 100.0
                    : 0
                let averageSharePercent = totalTrackedAverageResidentBytesDouble > 0
                    ? (averageBytesDouble / totalTrackedAverageResidentBytesDouble) * 100.0
                    : 0
                let name = displayNamesByKey[key] ?? key
                return ProcessMemoryRow(
                    id: key,
                    name: name,
                    currentBytes: currentBytes,
                    averageBytes: averageBytes,
                    peakBytes: peakBytes,
                    currentSharePercent: currentSharePercent,
                    averageSharePercent: averageSharePercent
                )
            }
            .filter { $0.currentBytes > 0 || $0.averageBytes > 0 || $0.peakBytes > 0 }
            .sorted { lhs, rhs in
                if lhs.averageBytes != rhs.averageBytes {
                    return lhs.averageBytes > rhs.averageBytes
                }
                if lhs.currentBytes != rhs.currentBytes {
                    return lhs.currentBytes > rhs.currentBytes
                }
                return lhs.peakBytes > rhs.peakBytes
            }

        let retraceRank = effectiveRetraceGroupKey.flatMap { key in
            rankedProcesses.firstIndex(where: { $0.id == key }).map { $0 + 1 }
        }

        return ProcessCPUSnapshot(
            sampleDurationSeconds: totalDuration,
            peakInstantPercent: retracePeakCorePercent,
            peakCapacityPercent: retracePeakCapacityPercent,
            averagePercent: averageRetracePercent,
            capacityPercent: retraceCapacityPercent,
            trackedSharePercent: retraceTrackedSharePercent,
            logicalCoreCount: logicalCoreCount,
            retraceCPUSeconds: retraceCPUSeconds,
            totalTrackedCPUSeconds: totalTrackedCPUSeconds,
            retraceRank: retraceRank,
            retraceGroupKey: effectiveRetraceGroupKey,
            peakPercentByGroup: peakPercentByGroup,
            topProcesses: rankedProcesses,
            totalTrackedCurrentResidentBytes: totalTrackedCurrentResidentBytes,
            totalTrackedAverageResidentBytes: totalTrackedAverageResidentBytes,
            peakResidentBytesByGroup: peakResidentBytesByGroup,
            topMemoryProcesses: rankedMemoryProcesses,
            latestSampleTimestamp: windowEntries.last?.timestamp
        )
    }

    private func maybeCompactLog(at now: Date) {
        if let lastCompactionDate, now.timeIntervalSince(lastCompactionDate) < Self.logCompactionInterval {
            return
        }

        let retentionCutoff = now.addingTimeInterval(-Self.logRetentionDuration).timeIntervalSince1970
        var retainedEntries: [CPULogEntry] = []
        streamLogEntries { entry in
            if entry.timestamp >= retentionCutoff {
                retainedEntries.append(entry)
            }
        }
        rewriteLog(with: retainedEntries)
        lastCompactionDate = now
    }

    private func appendLogEntry(_ entry: CPULogEntry) {
        do {
            Self.ensureLogFileExists(at: logFileURL)
            let encodedEntry = try encoder.encode(entry)
            let handle = try FileHandle(forWritingTo: logFileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: encodedEntry)
            try handle.write(contentsOf: Data([0x0A]))
        } catch {
            Log.warning("[SettingsView] Failed to append CPU usage log entry: \(error)", category: .ui)
        }
    }

    private func streamLogEntries(_ consume: (CPULogEntry) -> Void) {
        guard FileManager.default.fileExists(atPath: logFileURL.path) else { return }

        do {
            let handle = try FileHandle(forReadingFrom: logFileURL)
            defer { try? handle.close() }

            var pending = Data()
            while let chunk = try handle.read(upToCount: Self.logReadChunkSize), !chunk.isEmpty {
                pending.append(chunk)

                var scanIndex = pending.startIndex
                while let newlineIndex = pending[scanIndex...].firstIndex(of: 0x0A) {
                    let lineData = Data(pending[scanIndex..<newlineIndex])
                    if !lineData.isEmpty, let entry = try? decoder.decode(CPULogEntry.self, from: lineData) {
                        consume(entry)
                    }
                    scanIndex = pending.index(after: newlineIndex)
                }

                if scanIndex > pending.startIndex {
                    pending.removeSubrange(..<scanIndex)
                }
            }

            if !pending.isEmpty, let entry = try? decoder.decode(CPULogEntry.self, from: pending) {
                consume(entry)
            }
        } catch {
            Log.warning("[SettingsView] Failed to stream CPU usage log file: \(error)", category: .ui)
        }
    }

    private func rewriteLog(with entries: [CPULogEntry]) {
        do {
            Self.ensureLogFileExists(at: logFileURL)
            var output = Data()
            for entry in entries {
                let encoded = try encoder.encode(entry)
                output.append(encoded)
                output.append(0x0A)
            }
            try output.write(to: logFileURL, options: .atomic)
        } catch {
            Log.warning("[SettingsView] Failed to compact CPU usage log file: \(error)", category: .ui)
        }
    }

    private func clearLogAndState() {
        rewriteLog(with: [])
        lastSampleDate = nil
        lastCPUByPID = [:]
        identityByPID = [:]
        groupDisplayNameByKey = Self.readGroupDisplayNameMap(from: displayNamesFileURL)
        updateGroupDisplayNameIfNeeded(forKey: "bundle:\(retraceBundleID)", name: retraceDisplayName)
        displayNameMapDirty = false
        lastDisplayNamePersistDate = nil
        bundleMetadataByCanonicalPath = [:]
        loadedWindowDuration = nil
        windowStateNeedsReload = true
        windowEntries = []
        windowTotalDuration = 0
        windowCumulativeByGroup = [:]
        windowPeakPercentByGroup = [:]
        windowMemoryIntegralByteSecondsByGroup = [:]
        windowPeakResidentBytesByGroup = [:]
        retraceGroupKey = nil
        lastCompactionDate = nil
    }

    private static func ensureLogFileExists(at fileURL: URL) {
        let directoryURL = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            }
        } catch {
            Log.warning("[SettingsView] Failed to create CPU usage log directory: \(error)", category: .ui)
        }
    }

    private static func makeLogFileURL() -> URL {
        let rootURL = URL(fileURLWithPath: AppPaths.expandedStorageRoot, isDirectory: true)
        return rootURL
            .appendingPathComponent("logs", isDirectory: true)
            .appendingPathComponent("cpu_process_usage.jsonl", isDirectory: false)
    }

    private static func makeDisplayNamesFileURL() -> URL {
        let rootURL = URL(fileURLWithPath: AppPaths.expandedStorageRoot, isDirectory: true)
        return rootURL
            .appendingPathComponent("logs", isDirectory: true)
            .appendingPathComponent("cpu_process_groups.json", isDirectory: false)
    }

    private static func listAllProcessIDs() -> [pid_t] {
        let maxProcessCount = 8192
        var pids = [pid_t](repeating: 0, count: maxProcessCount)
        let byteCount = Int32(maxProcessCount * MemoryLayout<pid_t>.size)
        let processCount = Int(proc_listallpids(&pids, byteCount))
        guard processCount > 0 else { return [] }

        return pids.prefix(processCount).filter { $0 > 0 }
    }

    private static func processTaskMetrics(for pid: pid_t) -> ProcessTaskMetrics? {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(pid, PROC_PIDTASKINFO, 0, pointer, size)
        }

        guard result == size else { return nil }
        let memoryBytes = processFootprintBytes(for: pid) ?? info.pti_resident_size
        return ProcessTaskMetrics(
            cpuAbsoluteUnits: info.pti_total_user + info.pti_total_system,
            residentBytes: memoryBytes
        )
    }

    private static func processFootprintBytes(for pid: pid_t) -> UInt64? {
        guard let procPidRusageFunction else { return nil }

        var usage = rusage_info_current()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            procPidRusageFunction(pid, RUSAGE_INFO_CURRENT, UnsafeMutableRawPointer(pointer))
        }
        guard result == 0 else { return nil }
        return usage.ri_phys_footprint > 0 ? usage.ri_phys_footprint : nil
    }

    private static func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? UInt64.max : sum
    }

    private static func doubleToUInt64(_ value: Double) -> UInt64 {
        guard value.isFinite, value > 0 else { return 0 }
        if value >= Double(UInt64.max) {
            return UInt64.max
        }
        return UInt64(value.rounded())
    }

    private static func absoluteTimeToNanoseconds(_ absoluteUnits: UInt64) -> UInt64 {
        let timebase = Self.machTimebaseInfo
        if timebase.numer == timebase.denom {
            return absoluteUnits
        }

        return UInt64((Double(absoluteUnits) * Double(timebase.numer)) / Double(timebase.denom))
    }

    private static func normalizedDeltaNanoseconds(rawDelta: UInt64, unit: String?) -> UInt64 {
        if unit == Self.nanosecondUnit {
            return rawDelta
        }
        // Legacy entries were stored in mach absolute-time units.
        return absoluteTimeToNanoseconds(rawDelta)
    }

    private static func processPath(for pid: pid_t) -> String? {
        let maxPathSize = Int(MAXPATHLEN * 4)
        var buffer = [CChar](repeating: 0, count: maxPathSize)
        let pathLength = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard pathLength > 0 else { return nil }
        return String(cString: buffer)
    }

    private static func processName(for pid: pid_t) -> String? {
        var nameBuffer = [CChar](repeating: 0, count: 1024)
        let nameLength = proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))
        guard nameLength > 0 else { return nil }
        return String(cString: nameBuffer)
    }

    private static func appBundlePath(from executablePath: String) -> String? {
        guard let appMarker = executablePath.range(of: ".app/", options: .caseInsensitive) else {
            return nil
        }

        let appEnd = executablePath.index(appMarker.lowerBound, offsetBy: 4)
        return String(executablePath[..<appEnd])
    }

    private static func normalizedKeyComponent(_ value: String) -> String {
        let pieces = value
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })

        let normalized = pieces.joined(separator: "-")
        return normalized.isEmpty ? "unknown" : normalized
    }
}
