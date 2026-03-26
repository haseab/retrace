import Foundation
import SwiftUI
import Shared
import Darwin
import AppKit

struct ProcessCPURow: Identifiable {
    let id: String
    let name: String
    let cpuSeconds: Double
    let currentCapacityPercent: Double
    let energyJoules: Double
    let averagePowerWatts: Double
    let peakPowerWatts: Double
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
        retraceEnergyJoules: 0,
        totalTrackedEnergyJoules: 0,
        retraceRank: nil,
        retraceGroupKey: nil,
        peakPercentByGroup: [:],
        peakPowerWattsByGroup: [:],
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
    let retraceEnergyJoules: Double
    let totalTrackedEnergyJoules: Double
    let retraceRank: Int?
    let retraceGroupKey: String?
    let peakPercentByGroup: [String: Double]
    let peakPowerWattsByGroup: [String: Double]
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

    var hasRenderableCPUData: Bool {
        !topProcesses.isEmpty
    }

    var hasRenderableMemoryData: Bool {
        !topMemoryProcesses.isEmpty
    }
}

enum ProcessCPUDisplayMetrics {
    static func buildRows(
        cumulativeNanosecondsByGroup: [String: UInt64],
        latestDeltaNanosecondsByGroup: [String: UInt64],
        latestSampleDurationSeconds: TimeInterval,
        energyNanojoulesByGroup: [String: UInt64],
        peakPowerWattsByGroup: [String: Double],
        displayNamesByKey: [String: String],
        totalDuration: TimeInterval,
        logicalCoreCount: Int
    ) -> [ProcessCPURow] {
        let safeLogicalCoreCount = max(1, logicalCoreCount)
        let safeTotalDuration = max(totalDuration, 0)
        let capacityDenominatorSeconds = safeTotalDuration * Double(safeLogicalCoreCount)
        let totalTrackedCPUSeconds = Double(cumulativeNanosecondsByGroup.values.reduce(UInt64(0), +)) / 1_000_000_000.0

        return cumulativeNanosecondsByGroup.map { key, nanoseconds in
            let seconds = Double(nanoseconds) / 1_000_000_000.0
            let currentCapacityPercent = capacityPercent(
                deltaNanoseconds: latestDeltaNanosecondsByGroup[key] ?? 0,
                sampleDurationSeconds: latestSampleDurationSeconds,
                logicalCoreCount: safeLogicalCoreCount
            )
            let shareOfTrackedPercent = cumulativeSharePercent(valueSeconds: seconds, totalSeconds: totalTrackedCPUSeconds)
            let capacityPercent = capacityDenominatorSeconds > 0
                ? (seconds / capacityDenominatorSeconds) * 100.0
                : 0
            let averagePercent = safeTotalDuration > 0 ? (seconds / safeTotalDuration) * 100.0 : 0
            let energyJoules = Double(energyNanojoulesByGroup[key] ?? 0) / 1_000_000_000.0
            let averagePowerWatts = safeTotalDuration > 0 ? energyJoules / safeTotalDuration : 0
            let peakPowerWatts = peakPowerWattsByGroup[key] ?? 0
            let name = displayNamesByKey[key] ?? key
            return ProcessCPURow(
                id: key,
                name: name,
                cpuSeconds: seconds,
                currentCapacityPercent: currentCapacityPercent,
                energyJoules: energyJoules,
                averagePowerWatts: averagePowerWatts,
                peakPowerWatts: peakPowerWatts,
                shareOfTrackedPercent: shareOfTrackedPercent,
                capacityPercent: capacityPercent,
                averagePercent: averagePercent
            )
        }
        .sorted(by: rankedBefore(_:_:))
    }

    static func capacityPercent(
        deltaNanoseconds: UInt64,
        sampleDurationSeconds: TimeInterval,
        logicalCoreCount: Int
    ) -> Double {
        let safeDuration = max(sampleDurationSeconds, 0)
        let safeLogicalCoreCount = max(1, logicalCoreCount)
        guard safeDuration > 0, deltaNanoseconds > 0 else { return 0 }

        let cpuSeconds = Double(deltaNanoseconds) / 1_000_000_000.0
        let corePercent = (cpuSeconds / safeDuration) * 100.0
        return corePercent / Double(safeLogicalCoreCount)
    }

    private static func cumulativeSharePercent(valueSeconds: Double, totalSeconds: Double) -> Double {
        guard totalSeconds > 0 else { return 0 }
        return (valueSeconds / totalSeconds) * 100.0
    }

    private static func rankedBefore(_ lhs: ProcessCPURow, _ rhs: ProcessCPURow) -> Bool {
        if abs(lhs.capacityPercent - rhs.capacityPercent) > 0.000_001 {
            return lhs.capacityPercent > rhs.capacityPercent
        }
        if abs(lhs.currentCapacityPercent - rhs.currentCapacityPercent) > 0.000_001 {
            return lhs.currentCapacityPercent > rhs.currentCapacityPercent
        }
        if abs(lhs.cpuSeconds - rhs.cpuSeconds) > 0.000_001 {
            return lhs.cpuSeconds > rhs.cpuSeconds
        }
        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
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
    private static let idleWarmWindowDuration: TimeInterval = 60

    private init() {}

    func start() {
        guard samplingTask == nil else { return }
        restartSamplingLoop()
    }

    func setConsumerVisible(_ consumer: Consumer, isVisible: Bool) {
        if isVisible {
            activeConsumers.insert(consumer)
            Task(priority: .userInitiated) { [weak self] in
                guard let self else { return }
                guard let cachedSnapshot = await sampler.cachedSnapshotFromTally(
                    windowDuration: Self.snapshotWindowDuration
                ) else { return }
                await MainActor.run {
                    self.snapshot = cachedSnapshot
                }
            }
        } else {
            activeConsumers.remove(consumer)
        }

        if activeConsumers.isEmpty {
            Task(priority: .utility) { [sampler] in
                await sampler.enterIdleMode(
                    windowDuration: Self.snapshotWindowDuration,
                    warmWindowDuration: Self.idleWarmWindowDuration
                )
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

    private struct ProcessMemorySnapshot {
        let physFootprintBytes: UInt64
        let residentBytes: UInt64
        let internalBytes: UInt64
        let compressedBytes: UInt64
    }

    private struct ProcessTaskMetrics {
        let cpuAbsoluteUnits: UInt64
        let residentBytes: UInt64
        let energyNanojoules: UInt64?
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
        let groupDeltaEnergyNanojoules: [String: UInt64]?
        let groupDeltaUnit: String?
        let groupResidentBytes: [String: UInt64]?
        let groupDisplayNames: [String: String]?
    }

    private struct DownsampleBucketAccumulator {
        let bucketIndex: Int64
        let bucketSizeSeconds: TimeInterval
        var latestTimestamp: TimeInterval
        var durationSeconds: TimeInterval = 0
        var retraceGroupKey: String?
        var groupDeltaNanoseconds: [String: UInt64] = [:]
        var groupDeltaEnergyNanojoules: [String: UInt64] = [:]
        var groupResidentByteSeconds: [String: Double] = [:]
        var latestResidentBytesByGroup: [String: UInt64] = [:]

        init(entry: CPULogEntry, bucketIndex: Int64, bucketSizeSeconds: TimeInterval) {
            self.bucketIndex = bucketIndex
            self.bucketSizeSeconds = bucketSizeSeconds
            self.latestTimestamp = entry.timestamp
            append(entry)
        }

        mutating func append(_ entry: CPULogEntry) {
            latestTimestamp = max(latestTimestamp, entry.timestamp)
            durationSeconds += max(0, entry.durationSeconds)

            if retraceGroupKey == nil {
                retraceGroupKey = entry.retraceGroupKey
            }

            for (key, delta) in entry.groupDeltaNanoseconds {
                groupDeltaNanoseconds[key] = ProcessCPULogSampler.saturatingAdd(
                    groupDeltaNanoseconds[key] ?? 0,
                    delta
                )
            }

            if let entryEnergyByGroup = entry.groupDeltaEnergyNanojoules {
                for (key, deltaEnergy) in entryEnergyByGroup {
                    groupDeltaEnergyNanojoules[key] = ProcessCPULogSampler.saturatingAdd(
                        groupDeltaEnergyNanojoules[key] ?? 0,
                        deltaEnergy
                    )
                }
            }

            guard let groupResidentBytes = entry.groupResidentBytes, !groupResidentBytes.isEmpty else {
                return
            }

            latestResidentBytesByGroup = groupResidentBytes
            let sampleDuration = max(0, entry.durationSeconds)
            guard sampleDuration > 0 else { return }

            for (key, residentBytes) in groupResidentBytes {
                groupResidentByteSeconds[key, default: 0] += Double(residentBytes) * sampleDuration
            }
        }

        func makeEntry(fallbackRetraceGroupKey: String?) -> CPULogEntry {
            var mergedResidentByGroup: [String: UInt64] = [:]
            if durationSeconds > 0 {
                mergedResidentByGroup.reserveCapacity(
                    max(groupResidentByteSeconds.count, latestResidentBytesByGroup.count)
                )
                for (key, byteSeconds) in groupResidentByteSeconds {
                    mergedResidentByGroup[key] = ProcessCPULogSampler.doubleToUInt64(
                        byteSeconds / durationSeconds
                    )
                }
                for (key, bytes) in latestResidentBytesByGroup where mergedResidentByGroup[key] == nil {
                    mergedResidentByGroup[key] = bytes
                }
            } else {
                mergedResidentByGroup = latestResidentBytesByGroup
            }

            return CPULogEntry(
                timestamp: latestTimestamp,
                durationSeconds: durationSeconds,
                retraceGroupKey: retraceGroupKey ?? fallbackRetraceGroupKey,
                groupDeltaNanoseconds: groupDeltaNanoseconds,
                groupDeltaEnergyNanojoules: groupDeltaEnergyNanojoules.isEmpty ? nil : groupDeltaEnergyNanojoules,
                groupDeltaUnit: ProcessCPULogSampler.nanosecondUnit,
                groupResidentBytes: mergedResidentByGroup.isEmpty ? nil : mergedResidentByGroup,
                groupDisplayNames: nil
            )
        }
    }

    private struct ProcessTallyBucket: Codable {
        let startTimestamp: TimeInterval
        var durationSeconds: TimeInterval
        var deltaNanosecondsByGroup: [String: UInt64]
        var energyNanojoulesByGroup: [String: UInt64]
        var memoryByteSecondsByGroup: [String: Double]
        var peakPercentByGroup: [String: Double]
        var peakPowerByGroup: [String: Double]
        var peakResidentBytesByGroup: [String: UInt64]
    }

    private struct ProcessTallyState: Codable {
        let version: Int
        let bucketSeconds: TimeInterval
        let windowDurationSeconds: TimeInterval
        var latestSampleTimestamp: TimeInterval?
        var latestSampleDurationSeconds: TimeInterval?
        var latestDeltaNanosecondsByGroup: [String: UInt64]?
        var latestResidentBytesByGroup: [String: UInt64]
        var retraceGroupKey: String?
        var buckets: [ProcessTallyBucket]
    }

    private static let logRetentionDuration: TimeInterval = 7 * 24 * 60 * 60
    private static let logCompactionInterval: TimeInterval = 12 * 60 * 60
    private static let displayNamePersistInterval: TimeInterval = 30
    private static let tallyPersistInterval: TimeInterval = 5
    private static let tallyBucketDurationSeconds: TimeInterval = 60
    private static let tallyVersion = 1
    private static let memoryCompositionLogInterval: TimeInterval = 30
    private static let vmmapSummaryLogInterval: TimeInterval = 120
    private static let logReadChunkSize = 64 * 1024
    private static let nanosecondUnit = "ns"
    private static let acceptedSampleGapMultiplier: TimeInterval = 4.0
    private static let minimumAcceptedSampleGapSeconds: TimeInterval = 4.0
    private static let memoryCompositionLoggingDefaultsKey = "retrace.debug.processMonitorMemoryCompositionLoggingEnabled"
    private static let vmmapSummaryLoggingDefaultsKey = "retrace.debug.processMonitorVMMapSummaryLoggingEnabled"
    private static let memoryLedgerSummaryIntervalSeconds: TimeInterval = 30
    private static let memoryLedgerSamplerStateTag = "ui.systemMonitor.samplerWindow"
    private static let memoryLedgerLogFileTag = "ui.systemMonitor.cpuProcessLogFile"
    private static let memoryLedgerTallyFileTag = "ui.systemMonitor.tallyFile"
    private static let warmHistoryWindowDuration: TimeInterval = 60
    private static let maxGroupsPerSampleDefaultsKey = "retrace.debug.processMonitorMaxGroupsPerSample"
    private static let defaultMaxGroupsPerSample = 64
    private static let minMaxGroupsPerSample = 16
    private static let maxMaxGroupsPerSample = 512
    private static let downsampleKeepFullResolutionAgeSeconds: TimeInterval = 10 * 60
    private static let downsampleMediumResolutionAgeSeconds: TimeInterval = 60 * 60
    private static let downsampleCoarseResolutionAgeSeconds: TimeInterval = 6 * 60 * 60
    private static let downsampleMediumBucketSeconds: TimeInterval = 5
    private static let downsampleCoarseBucketSeconds: TimeInterval = 15
    private static let downsampleVeryCoarseBucketSeconds: TimeInterval = 60
    private static let downsampleMinimumEntries = 1_000
    private static let downsampleIntervalSeconds: TimeInterval = 15
    private static let tallyMediumBucketSeconds: TimeInterval = 5 * 60
    private static let tallyCoarseBucketSeconds: TimeInterval = 15 * 60
    private static let tallyDownsampleMinimumBuckets = 120
    private static let tallyDownsampleIntervalSeconds: TimeInterval = 15
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
    private var lastEnergyByPID: [pid_t: UInt64] = [:]
    private var identityByPID: [pid_t: ProcessIdentity] = [:]
    private var groupDisplayNameByKey: [String: String] = [:]
    private var displayNameMapDirty = false
    private var lastDisplayNamePersistDate: Date?
    private var retraceGroupKey: String?
    private var lastCompactionDate: Date?
    private var lastMemoryCompositionLogDate: Date?
    private var lastVMMapSummaryLogDate: Date?
    private let retraceBundleID: String
    private let retraceDisplayName: String
    private var bundleMetadataByCanonicalPath: [String: BundleMetadata] = [:]
    private var loadedWindowDuration: TimeInterval?
    private var windowStateNeedsReload = true
    private var windowEntries: [CPULogEntry] = []
    private var windowTotalDuration: TimeInterval = 0
    private var windowTotalDeltaPairs: Int = 0
    private var windowTotalEnergyPairs: Int = 0
    private var windowTotalResidentPairs: Int = 0
    private var windowCumulativeByGroup: [String: UInt64] = [:]
    private var windowPeakPercentByGroup: [String: Double] = [:]
    private var windowEnergyCumulativeByGroup: [String: UInt64] = [:]
    private var windowPeakPowerByGroup: [String: Double] = [:]
    private var windowMemoryIntegralByteSecondsByGroup: [String: Double] = [:]
    private var windowPeakResidentBytesByGroup: [String: UInt64] = [:]
    private var lastWindowDownsampleDate: Date?
    private var lastTallyDownsampleDate: Date?
    private var latestResidentBytesByGroup: [String: UInt64] = [:]
    private var latestTallySampleTimestamp: TimeInterval?
    private var tallyState: ProcessTallyState?
    private var lastTallyPersistDate: Date?
    private let logFileURL: URL
    private let tallyFileURL: URL
    private let displayNamesFileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init() {
        retraceBundleID = Bundle.main.bundleIdentifier ?? "io.retrace.app"
        retraceDisplayName = (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? "Retrace"
        logFileURL = Self.makeLogFileURL()
        tallyFileURL = Self.makeTallyFileURL()
        displayNamesFileURL = Self.makeDisplayNamesFileURL()
        Self.ensureLogFileExists(at: logFileURL)
        Self.ensureLogFileExists(at: tallyFileURL)
        groupDisplayNameByKey = Self.readGroupDisplayNameMap(from: displayNamesFileURL)
        tallyState = Self.readTallyState(from: tallyFileURL)
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
        if let appendedEntry {
            applyEntryToTally(appendedEntry, windowDuration: windowDuration, now: now)
        } else {
            pruneTally(now: now, windowDuration: windowDuration)
        }
        maybeDownsampleTally(at: now)
        maybePersistTally(at: now)

        if !shouldBuildSnapshot {
            dropWindowState()
            tallyState = nil
            loadedWindowDuration = nil
            return nil
        }
        hydrateWindowStateFromTally(windowDuration: windowDuration, now: now)
        maybeLogMemoryComposition(at: now, shouldBuildSnapshot: shouldBuildSnapshot)

        return snapshotFromWindowState()
    }

    func resetAndLoadSnapshot(
        windowDuration: TimeInterval,
        expectedIntervalSeconds: TimeInterval
    ) -> ProcessCPUSnapshot {
        clearLogAndState()
        let now = Date()
        if let entry = captureSample(at: now, expectedIntervalSeconds: expectedIntervalSeconds) {
            applyEntryToTally(entry, windowDuration: windowDuration, now: now)
        }
        maybePersistDisplayNameMap(at: now, force: true)
        maybePersistTally(at: now, force: true)
        hydrateWindowStateFromTally(windowDuration: windowDuration, now: now)
        return snapshotFromWindowState()
    }

    func cachedSnapshotFromTally(windowDuration: TimeInterval) -> ProcessCPUSnapshot? {
        let now = Date()
        if tallyState == nil {
            tallyState = Self.readTallyState(from: tallyFileURL)
        }
        pruneTally(now: now, windowDuration: windowDuration)
        hydrateWindowStateFromTally(windowDuration: windowDuration, now: now)
        let cachedSnapshot = snapshotFromWindowState()
        guard cachedSnapshot.hasRenderableCPUData || cachedSnapshot.hasRenderableMemoryData else {
            return nil
        }
        return cachedSnapshot
    }

    func dropWindowState() {
        loadedWindowDuration = nil
        windowStateNeedsReload = true
        clearWindowState(keepingCapacity: false)
        lastWindowDownsampleDate = nil
        latestResidentBytesByGroup = [:]
        latestTallySampleTimestamp = nil
    }

    func enterIdleMode(windowDuration: TimeInterval, warmWindowDuration: TimeInterval) {
        let _ = warmWindowDuration
        let now = Date()
        pruneTally(now: now, windowDuration: windowDuration)
        maybePersistTally(at: now, force: true)
        dropWindowState()
        tallyState = nil
        lastTallyDownsampleDate = nil
    }

    private func captureSample(at now: Date, expectedIntervalSeconds: TimeInterval) -> CPULogEntry? {
        let allPIDs = Self.listAllProcessIDs()

        var currentCPUByPID: [pid_t: UInt64] = [:]
        var currentEnergyByPID: [pid_t: UInt64] = [:]
        var currentResidentBytesByPID: [pid_t: UInt64] = [:]
        var currentIdentityByPID: [pid_t: ProcessIdentity] = [:]

        for pid in allPIDs {
            guard let taskMetrics = Self.processTaskMetrics(for: pid) else { continue }
            guard let identity = identityByPID[pid] ?? resolveIdentity(for: pid) else { continue }

            currentCPUByPID[pid] = taskMetrics.cpuAbsoluteUnits
            if let energyNanojoules = taskMetrics.energyNanojoules {
                currentEnergyByPID[pid] = energyNanojoules
            }
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
                var groupDeltaEnergyNanojoules: [String: UInt64] = [:]

                for (pid, currentCPU) in currentCPUByPID {
                    guard let identity = currentIdentityByPID[pid] else { continue }

                    if let previousCPU = lastCPUByPID[pid], currentCPU >= previousCPU {
                        let deltaAbsoluteUnits = currentCPU - previousCPU
                        if deltaAbsoluteUnits > 0 {
                            let deltaNanoseconds = Self.absoluteTimeToNanoseconds(deltaAbsoluteUnits)
                            groupDeltaNanoseconds[identity.key, default: 0] += deltaNanoseconds
                        }
                    }

                    if let currentEnergy = currentEnergyByPID[pid],
                       let previousEnergy = lastEnergyByPID[pid],
                       currentEnergy >= previousEnergy {
                        let deltaEnergy = currentEnergy - previousEnergy
                        if deltaEnergy > 0 {
                            groupDeltaEnergyNanojoules[identity.key, default: 0] += deltaEnergy
                        }
                    }
                }

                if !groupDeltaNanoseconds.isEmpty || !groupDeltaEnergyNanojoules.isEmpty || !groupResidentBytes.isEmpty {
                    let entry = CPULogEntry(
                        timestamp: now.timeIntervalSince1970,
                        durationSeconds: duration,
                        retraceGroupKey: retraceGroupKey,
                        groupDeltaNanoseconds: groupDeltaNanoseconds,
                        groupDeltaEnergyNanojoules: groupDeltaEnergyNanojoules.isEmpty ? nil : groupDeltaEnergyNanojoules,
                        groupDeltaUnit: Self.nanosecondUnit,
                        groupResidentBytes: groupResidentBytes.isEmpty ? nil : groupResidentBytes,
                        groupDisplayNames: nil
                    )
                    let compactedEntry = compactEntryForStorage(entry)
                    appendLogEntry(compactedEntry)
                    appendedEntry = compactedEntry
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
                    groupDeltaEnergyNanojoules: nil,
                    groupDeltaUnit: Self.nanosecondUnit,
                    groupResidentBytes: groupResidentBytes,
                    groupDisplayNames: nil
                )
                let compactedEntry = compactEntryForStorage(entry)
                appendLogEntry(compactedEntry)
                appendedEntry = compactedEntry
            }
        }

        lastSampleDate = now
        lastCPUByPID = currentCPUByPID
        lastEnergyByPID = currentEnergyByPID
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

    private static func readTallyState(from fileURL: URL) -> ProcessTallyState? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }

        do {
            let data = try Data(contentsOf: fileURL)
            guard !data.isEmpty else { return nil }

            let decoded = try JSONDecoder().decode(ProcessTallyState.self, from: data)
            guard decoded.version == tallyVersion else {
                Log.info(
                    "[ProcessMonitor] Ignoring CPU tally file with unsupported version \(decoded.version)",
                    category: .ui
                )
                return nil
            }

            let sanitizedBuckets = decoded.buckets.compactMap { bucket -> ProcessTallyBucket? in
                guard bucket.startTimestamp.isFinite else { return nil }
                let durationSeconds = max(0, bucket.durationSeconds)
                guard durationSeconds.isFinite else { return nil }

                let deltaNanosecondsByGroup = bucket.deltaNanosecondsByGroup.reduce(into: [String: UInt64]()) { result, element in
                    let (key, value) = element
                    guard !key.isEmpty else { return }
                    result[key] = value
                }
                let energyNanojoulesByGroup = bucket.energyNanojoulesByGroup.reduce(into: [String: UInt64]()) { result, element in
                    let (key, value) = element
                    guard !key.isEmpty else { return }
                    result[key] = value
                }
                let memoryByteSecondsByGroup = bucket.memoryByteSecondsByGroup.reduce(into: [String: Double]()) { result, element in
                    let (key, value) = element
                    guard !key.isEmpty, value.isFinite, value >= 0 else { return }
                    result[key] = value
                }
                let peakPercentByGroup = bucket.peakPercentByGroup.reduce(into: [String: Double]()) { result, element in
                    let (key, value) = element
                    guard !key.isEmpty, value.isFinite, value >= 0 else { return }
                    result[key] = value
                }
                let peakPowerByGroup = bucket.peakPowerByGroup.reduce(into: [String: Double]()) { result, element in
                    let (key, value) = element
                    guard !key.isEmpty, value.isFinite, value >= 0 else { return }
                    result[key] = value
                }
                let peakResidentBytesByGroup = bucket.peakResidentBytesByGroup.reduce(into: [String: UInt64]()) { result, element in
                    let (key, value) = element
                    guard !key.isEmpty else { return }
                    result[key] = value
                }

                return ProcessTallyBucket(
                    startTimestamp: bucket.startTimestamp,
                    durationSeconds: durationSeconds,
                    deltaNanosecondsByGroup: deltaNanosecondsByGroup,
                    energyNanojoulesByGroup: energyNanojoulesByGroup,
                    memoryByteSecondsByGroup: memoryByteSecondsByGroup,
                    peakPercentByGroup: peakPercentByGroup,
                    peakPowerByGroup: peakPowerByGroup,
                    peakResidentBytesByGroup: peakResidentBytesByGroup
                )
            }
            .sorted { $0.startTimestamp < $1.startTimestamp }

            let latestResidentBytesByGroup = decoded.latestResidentBytesByGroup.reduce(into: [String: UInt64]()) { result, element in
                let (key, value) = element
                guard !key.isEmpty else { return }
                result[key] = value
            }
            let latestDeltaNanosecondsByGroup = (decoded.latestDeltaNanosecondsByGroup ?? [:]).reduce(into: [String: UInt64]()) {
                result, element in
                let (key, value) = element
                guard !key.isEmpty else { return }
                result[key] = value
            }
            let latestSampleTimestamp = decoded.latestSampleTimestamp.flatMap { $0.isFinite ? $0 : nil }
            let latestSampleDurationSeconds = decoded.latestSampleDurationSeconds.flatMap { value -> TimeInterval? in
                guard value.isFinite, value > 0 else { return nil }
                return value
            }

            return ProcessTallyState(
                version: tallyVersion,
                bucketSeconds: max(1, decoded.bucketSeconds),
                windowDurationSeconds: max(0, decoded.windowDurationSeconds),
                latestSampleTimestamp: latestSampleTimestamp,
                latestSampleDurationSeconds: latestSampleDurationSeconds,
                latestDeltaNanosecondsByGroup: latestSampleTimestamp == nil ? nil : latestDeltaNanosecondsByGroup,
                latestResidentBytesByGroup: latestResidentBytesByGroup,
                retraceGroupKey: decoded.retraceGroupKey,
                buckets: sanitizedBuckets
            )
        } catch {
            Log.warning("[ProcessMonitor] Failed to read CPU tally state: \(error)", category: .ui)
            return nil
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
        let compactedEntry = compactEntryForStorage(entry)
        windowEntries.append(compactedEntry)
        let entry = compactedEntry
        latestTallySampleTimestamp = max(latestTallySampleTimestamp ?? 0, entry.timestamp)
        windowTotalDuration += entry.durationSeconds
        windowTotalDeltaPairs += entry.groupDeltaNanoseconds.count
        for (key, rawDelta) in entry.groupDeltaNanoseconds {
            let delta = Self.normalizedDeltaNanoseconds(rawDelta: rawDelta, unit: entry.groupDeltaUnit)
            windowCumulativeByGroup[key, default: 0] += delta
            guard entry.durationSeconds > 0 else { continue }
            let instantPercent = (Double(delta) / 1_000_000_000.0) / entry.durationSeconds * 100.0
            if instantPercent > (windowPeakPercentByGroup[key] ?? 0) {
                windowPeakPercentByGroup[key] = instantPercent
            }
        }

        if let groupDeltaEnergyNanojoules = entry.groupDeltaEnergyNanojoules {
            windowTotalEnergyPairs += groupDeltaEnergyNanojoules.count
            for (key, deltaEnergyNanojoules) in groupDeltaEnergyNanojoules {
                windowEnergyCumulativeByGroup[key, default: 0] = Self.saturatingAdd(
                    windowEnergyCumulativeByGroup[key] ?? 0,
                    deltaEnergyNanojoules
                )
                guard entry.durationSeconds > 0 else { continue }
                let instantPowerWatts = (Double(deltaEnergyNanojoules) / 1_000_000_000.0) / entry.durationSeconds
                if instantPowerWatts > (windowPeakPowerByGroup[key] ?? 0) {
                    windowPeakPowerByGroup[key] = instantPowerWatts
                }
            }
        }

        guard let groupResidentBytes = entry.groupResidentBytes, !groupResidentBytes.isEmpty else {
            return
        }

        latestResidentBytesByGroup = groupResidentBytes
        windowTotalResidentPairs += groupResidentBytes.count
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

    private func clearWindowState(keepingCapacity: Bool) {
        windowEntries.removeAll(keepingCapacity: keepingCapacity)
        windowTotalDuration = 0
        windowTotalDeltaPairs = 0
        windowTotalEnergyPairs = 0
        windowTotalResidentPairs = 0
        windowCumulativeByGroup.removeAll(keepingCapacity: keepingCapacity)
        windowPeakPercentByGroup.removeAll(keepingCapacity: keepingCapacity)
        windowEnergyCumulativeByGroup.removeAll(keepingCapacity: keepingCapacity)
        windowPeakPowerByGroup.removeAll(keepingCapacity: keepingCapacity)
        windowMemoryIntegralByteSecondsByGroup.removeAll(keepingCapacity: keepingCapacity)
        windowPeakResidentBytesByGroup.removeAll(keepingCapacity: keepingCapacity)
        latestResidentBytesByGroup.removeAll(keepingCapacity: keepingCapacity)
        latestTallySampleTimestamp = nil
    }

    private func replaceWindowState(with entries: [CPULogEntry]) {
        clearWindowState(keepingCapacity: true)
        for entry in entries {
            appendEntryToWindowState(entry)
        }
    }

    private func pruneWindowState(cutoffTimestamp: TimeInterval) {
        guard !windowEntries.isEmpty else { return }

        var peakKeysToRebuild: Set<String> = []
        var peakPowerKeysToRebuild: Set<String> = []
        var peakMemoryKeysToRebuild: Set<String> = []
        var removeCount = 0
        while removeCount < windowEntries.count, windowEntries[removeCount].timestamp < cutoffTimestamp {
            let entry = windowEntries[removeCount]
            windowTotalDuration -= entry.durationSeconds
            windowTotalDeltaPairs = max(0, windowTotalDeltaPairs - entry.groupDeltaNanoseconds.count)
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

            if let groupDeltaEnergyNanojoules = entry.groupDeltaEnergyNanojoules {
                windowTotalEnergyPairs = max(0, windowTotalEnergyPairs - groupDeltaEnergyNanojoules.count)
                for (key, deltaEnergyNanojoules) in groupDeltaEnergyNanojoules {
                    guard let current = windowEnergyCumulativeByGroup[key] else { continue }
                    if current <= deltaEnergyNanojoules {
                        windowEnergyCumulativeByGroup.removeValue(forKey: key)
                    } else {
                        windowEnergyCumulativeByGroup[key] = current - deltaEnergyNanojoules
                    }

                    guard entry.durationSeconds > 0,
                          let currentPeakPower = windowPeakPowerByGroup[key] else { continue }
                    let instantPowerWatts = (Double(deltaEnergyNanojoules) / 1_000_000_000.0) / entry.durationSeconds
                    if instantPowerWatts >= (currentPeakPower - 0.000_001) {
                        peakPowerKeysToRebuild.insert(key)
                    }
                }
            }

            if let groupResidentBytes = entry.groupResidentBytes, !groupResidentBytes.isEmpty {
                windowTotalResidentPairs = max(0, windowTotalResidentPairs - groupResidentBytes.count)
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
            recomputePeakPowers(for: peakPowerKeysToRebuild)
            recomputePeakResidentBytes(for: peakMemoryKeysToRebuild)
        }

        if windowTotalDuration < 0 {
            windowTotalDuration = 0
        }
    }

    private func rebuildWindowStateFromLog(windowDuration: TimeInterval, now: Date) {
        loadedWindowDuration = windowDuration
        clearWindowState(keepingCapacity: true)
        lastWindowDownsampleDate = nil

        let cutoffTimestamp = now.addingTimeInterval(-windowDuration).timeIntervalSince1970
        streamLogEntries { entry in
            guard entry.timestamp >= cutoffTimestamp else { return }
            appendEntryToWindowState(entry)
        }

        maybeDownsampleWindowState(at: now)
        windowStateNeedsReload = false
        maybePersistDisplayNameMap(at: now)
    }

    private func maybeDownsampleWindowState(at now: Date) {
        guard windowEntries.count >= Self.downsampleMinimumEntries else { return }
        if let lastWindowDownsampleDate,
           now.timeIntervalSince(lastWindowDownsampleDate) < Self.downsampleIntervalSeconds {
            return
        }

        lastWindowDownsampleDate = now

        let originalEntryCount = windowEntries.count
        let originalPairCount = windowTotalDeltaPairs + windowTotalEnergyPairs + windowTotalResidentPairs
        let downsampledEntries = Self.downsampledEntries(
            windowEntries,
            nowTimestamp: now.timeIntervalSince1970,
            maxGroupsPerSample: Self.maxGroupsPerSample(),
            fallbackRetraceGroupKey: retraceGroupKey
        )
        let downsampledPairCount = Self.totalPairCount(for: downsampledEntries)

        guard downsampledEntries.count < originalEntryCount || downsampledPairCount < originalPairCount else {
            return
        }

        replaceWindowState(with: downsampledEntries)
    }

    private func loadOrCreateTallyState(windowDuration: TimeInterval) -> ProcessTallyState {
        if let tallyState {
            return tallyState
        }
        if let loaded = Self.readTallyState(from: tallyFileURL),
           loaded.version == Self.tallyVersion {
            tallyState = loaded
            return loaded
        }
        return ProcessTallyState(
            version: Self.tallyVersion,
            bucketSeconds: Self.tallyBucketDurationSeconds,
            windowDurationSeconds: windowDuration,
            latestSampleTimestamp: nil,
            latestSampleDurationSeconds: nil,
            latestDeltaNanosecondsByGroup: nil,
            latestResidentBytesByGroup: [:],
            retraceGroupKey: retraceGroupKey,
            buckets: []
        )
    }

    private func applyEntryToTally(_ entry: CPULogEntry, windowDuration: TimeInterval, now: Date) {
        var state = loadOrCreateTallyState(windowDuration: windowDuration)
        let maxGroups = Self.maxGroupsPerSample()
        if state.retraceGroupKey == nil {
            state.retraceGroupKey = entry.retraceGroupKey ?? retraceGroupKey
        }
        let effectiveRetraceGroupKey = state.retraceGroupKey ?? entry.retraceGroupKey ?? retraceGroupKey

        let duration = max(entry.durationSeconds, 0)
        let normalizedLatestDeltaNanosecondsByGroup = Self.normalizedDeltaNanosecondsByGroup(
            entry.groupDeltaNanoseconds,
            unit: entry.groupDeltaUnit
        )
        let bucketSeconds = max(1, state.bucketSeconds)
        let bucketStart = floor(entry.timestamp / bucketSeconds) * bucketSeconds

        var bucketIndex: Int?
        if let lastIndex = state.buckets.indices.last,
           abs(state.buckets[lastIndex].startTimestamp - bucketStart) < 0.000_001 {
            bucketIndex = lastIndex
        } else {
            bucketIndex = state.buckets.firstIndex(where: { abs($0.startTimestamp - bucketStart) < 0.000_001 })
        }

        if bucketIndex == nil {
            state.buckets.append(
                ProcessTallyBucket(
                    startTimestamp: bucketStart,
                    durationSeconds: 0,
                    deltaNanosecondsByGroup: [:],
                    energyNanojoulesByGroup: [:],
                    memoryByteSecondsByGroup: [:],
                    peakPercentByGroup: [:],
                    peakPowerByGroup: [:],
                    peakResidentBytesByGroup: [:]
                )
            )
            bucketIndex = state.buckets.count - 1
        }

        guard let bucketIndex else { return }
        state.buckets[bucketIndex].durationSeconds += duration

        for (groupKey, rawDelta) in entry.groupDeltaNanoseconds {
            let deltaNanoseconds = Self.normalizedDeltaNanoseconds(rawDelta: rawDelta, unit: entry.groupDeltaUnit)
            state.buckets[bucketIndex].deltaNanosecondsByGroup[groupKey, default: 0] += deltaNanoseconds
            guard duration > 0 else { continue }
            let instantPercent = (Double(deltaNanoseconds) / 1_000_000_000.0) / duration * 100.0
            if instantPercent > (state.buckets[bucketIndex].peakPercentByGroup[groupKey] ?? 0) {
                state.buckets[bucketIndex].peakPercentByGroup[groupKey] = instantPercent
            }
        }

        if let energyByGroup = entry.groupDeltaEnergyNanojoules {
            for (groupKey, deltaEnergyNanojoules) in energyByGroup {
                state.buckets[bucketIndex].energyNanojoulesByGroup[groupKey, default: 0] = Self.saturatingAdd(
                    state.buckets[bucketIndex].energyNanojoulesByGroup[groupKey] ?? 0,
                    deltaEnergyNanojoules
                )
                guard duration > 0 else { continue }
                let instantPowerWatts = (Double(deltaEnergyNanojoules) / 1_000_000_000.0) / duration
                if instantPowerWatts > (state.buckets[bucketIndex].peakPowerByGroup[groupKey] ?? 0) {
                    state.buckets[bucketIndex].peakPowerByGroup[groupKey] = instantPowerWatts
                }
            }
        }

        if let residentBytesByGroup = entry.groupResidentBytes {
            for (groupKey, residentBytes) in residentBytesByGroup {
                if duration > 0 {
                    state.buckets[bucketIndex].memoryByteSecondsByGroup[groupKey, default: 0] += Double(residentBytes) * duration
                }
                if residentBytes > (state.buckets[bucketIndex].peakResidentBytesByGroup[groupKey] ?? 0) {
                    state.buckets[bucketIndex].peakResidentBytesByGroup[groupKey] = residentBytes
                }
            }
            state.latestResidentBytesByGroup = Self.cappedLatestResidentBytesByGroup(
                residentBytesByGroup,
                maxGroupsPerSample: maxGroups,
                retraceGroupKey: effectiveRetraceGroupKey
            )
        }

        state.buckets[bucketIndex] = Self.cappedTallyBucket(
            state.buckets[bucketIndex],
            maxGroupsPerSample: maxGroups,
            retraceGroupKey: effectiveRetraceGroupKey
        )

        state.latestSampleTimestamp = entry.timestamp
        state.latestSampleDurationSeconds = duration > 0 ? duration : nil
        state.latestDeltaNanosecondsByGroup = duration > 0
            ? Self.cappedLatestDeltaNanosecondsByGroup(
                normalizedLatestDeltaNanosecondsByGroup,
                maxGroupsPerSample: maxGroups,
                retraceGroupKey: effectiveRetraceGroupKey
            )
            : nil
        tallyState = state
        pruneTally(now: now, windowDuration: windowDuration)
    }

    private func pruneTally(now: Date, windowDuration: TimeInterval) {
        guard var state = tallyState else { return }
        let cutoff = now.addingTimeInterval(-windowDuration).timeIntervalSince1970
        state.buckets.removeAll { bucket in
            let effectiveBucketDuration = max(state.bucketSeconds, bucket.durationSeconds)
            return bucket.startTimestamp + effectiveBucketDuration < cutoff
        }
        if let latestSampleTimestamp = state.latestSampleTimestamp,
           latestSampleTimestamp < cutoff {
            state.latestSampleTimestamp = nil
            state.latestSampleDurationSeconds = nil
            state.latestDeltaNanosecondsByGroup = nil
            state.latestResidentBytesByGroup = [:]
        }
        tallyState = state
    }

    private func maybeDownsampleTally(at now: Date) {
        guard var state = tallyState else { return }
        guard state.buckets.count >= Self.tallyDownsampleMinimumBuckets else { return }
        if let lastTallyDownsampleDate,
           now.timeIntervalSince(lastTallyDownsampleDate) < Self.tallyDownsampleIntervalSeconds {
            return
        }

        lastTallyDownsampleDate = now
        let maxGroups = Self.maxGroupsPerSample()
        let effectiveRetraceGroupKey = state.retraceGroupKey ?? retraceGroupKey
        let originalBucketCount = state.buckets.count
        let originalPairCount = Self.totalTallyPairCount(state.buckets)
        let downsampledBuckets = Self.downsampledTallyBuckets(
            state.buckets,
            nowTimestamp: now.timeIntervalSince1970,
            maxGroupsPerSample: maxGroups,
            retraceGroupKey: effectiveRetraceGroupKey
        )
        let downsampledPairCount = Self.totalTallyPairCount(downsampledBuckets)

        guard downsampledBuckets.count < originalBucketCount || downsampledPairCount < originalPairCount else {
            return
        }

        state.buckets = downsampledBuckets
        state.latestResidentBytesByGroup = Self.cappedLatestResidentBytesByGroup(
            state.latestResidentBytesByGroup,
            maxGroupsPerSample: maxGroups,
            retraceGroupKey: effectiveRetraceGroupKey
        )
        if let latestDeltaNanosecondsByGroup = state.latestDeltaNanosecondsByGroup {
            state.latestDeltaNanosecondsByGroup = Self.cappedLatestDeltaNanosecondsByGroup(
                latestDeltaNanosecondsByGroup,
                maxGroupsPerSample: maxGroups,
                retraceGroupKey: effectiveRetraceGroupKey
            )
        }
        tallyState = state
    }

    private func maybePersistTally(at now: Date, force: Bool = false) {
        guard let tallyState else { return }
        if !force, let lastTallyPersistDate,
           now.timeIntervalSince(lastTallyPersistDate) < Self.tallyPersistInterval {
            return
        }

        do {
            Self.ensureLogFileExists(at: tallyFileURL)
            let data = try encoder.encode(tallyState)
            try data.write(to: tallyFileURL, options: .atomic)
            lastTallyPersistDate = now
        } catch {
            Log.warning("[ProcessMonitor] Failed to persist CPU tally state: \(error)", category: .ui)
        }
    }

    private func hydrateWindowStateFromTally(windowDuration: TimeInterval, now: Date) {
        if tallyState == nil {
            tallyState = Self.readTallyState(from: tallyFileURL)
        }
        pruneTally(now: now, windowDuration: windowDuration)

        guard let tallyState else {
            dropWindowState()
            return
        }

        loadedWindowDuration = windowDuration
        windowStateNeedsReload = false
        clearWindowState(keepingCapacity: false)
        lastWindowDownsampleDate = nil

        let sortedBuckets = tallyState.buckets.sorted { $0.startTimestamp < $1.startTimestamp }
        for bucket in sortedBuckets {
            let bucketDuration = max(bucket.durationSeconds, 0)
            windowTotalDuration += bucketDuration
            windowTotalDeltaPairs += bucket.deltaNanosecondsByGroup.count
            windowTotalEnergyPairs += bucket.energyNanojoulesByGroup.count
            windowTotalResidentPairs += bucket.memoryByteSecondsByGroup.count

            for (groupKey, deltaNanoseconds) in bucket.deltaNanosecondsByGroup {
                windowCumulativeByGroup[groupKey, default: 0] += deltaNanoseconds
                if let peakPercent = bucket.peakPercentByGroup[groupKey],
                   peakPercent > (windowPeakPercentByGroup[groupKey] ?? 0) {
                    windowPeakPercentByGroup[groupKey] = peakPercent
                }
            }

            for (groupKey, deltaEnergyNanojoules) in bucket.energyNanojoulesByGroup {
                windowEnergyCumulativeByGroup[groupKey, default: 0] = Self.saturatingAdd(
                    windowEnergyCumulativeByGroup[groupKey] ?? 0,
                    deltaEnergyNanojoules
                )
                if let peakPower = bucket.peakPowerByGroup[groupKey],
                   peakPower > (windowPeakPowerByGroup[groupKey] ?? 0) {
                    windowPeakPowerByGroup[groupKey] = peakPower
                }
            }

            for (groupKey, byteSeconds) in bucket.memoryByteSecondsByGroup {
                windowMemoryIntegralByteSecondsByGroup[groupKey, default: 0] += byteSeconds
            }
            for (groupKey, peakResidentBytes) in bucket.peakResidentBytesByGroup {
                if peakResidentBytes > (windowPeakResidentBytesByGroup[groupKey] ?? 0) {
                    windowPeakResidentBytesByGroup[groupKey] = peakResidentBytes
                }
            }
        }

        latestResidentBytesByGroup = tallyState.latestResidentBytesByGroup
        latestTallySampleTimestamp = tallyState.latestSampleTimestamp
        if retraceGroupKey == nil {
            retraceGroupKey = tallyState.retraceGroupKey
        }
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

    private func recomputePeakPowers(for keys: Set<String>) {
        guard !keys.isEmpty else { return }

        var recomputed: [String: Double] = [:]
        for entry in windowEntries where entry.durationSeconds > 0 {
            guard let groupDeltaEnergyNanojoules = entry.groupDeltaEnergyNanojoules else { continue }
            for (key, deltaEnergyNanojoules) in groupDeltaEnergyNanojoules {
                guard keys.contains(key) else { continue }
                let instantPowerWatts = (Double(deltaEnergyNanojoules) / 1_000_000_000.0) / entry.durationSeconds
                if instantPowerWatts > (recomputed[key] ?? 0) {
                    recomputed[key] = instantPowerWatts
                }
            }
        }

        for key in keys {
            if windowEnergyCumulativeByGroup[key] == nil {
                windowPeakPowerByGroup.removeValue(forKey: key)
            } else if let peakPower = recomputed[key] {
                windowPeakPowerByGroup[key] = peakPower
            } else {
                windowPeakPowerByGroup.removeValue(forKey: key)
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
        let energyCumulativeByGroup = windowEnergyCumulativeByGroup
        let peakPowerByGroup = windowPeakPowerByGroup
        let memoryIntegralByteSecondsByGroup = windowMemoryIntegralByteSecondsByGroup
        let peakResidentBytesByGroup = windowPeakResidentBytesByGroup
        let currentResidentBytesByGroup = windowEntries.last?.groupResidentBytes ?? latestResidentBytesByGroup
        let displayNamesByKey = groupDisplayNameByKey
        var effectiveRetraceGroupKey = retraceGroupKey
        let latestSampleDurationSeconds = tallyState?.latestSampleDurationSeconds
            ?? windowEntries.last.map { max($0.durationSeconds, 0) }
            ?? 0
        let latestDeltaNanosecondsByGroup = tallyState?.latestDeltaNanosecondsByGroup
            ?? windowEntries.last.map {
                Self.normalizedDeltaNanosecondsByGroup($0.groupDeltaNanoseconds, unit: $0.groupDeltaUnit)
            }
            ?? [:]

        for entry in windowEntries {
            if effectiveRetraceGroupKey == nil {
                effectiveRetraceGroupKey = entry.retraceGroupKey
            }
        }

        let retraceNanoseconds = effectiveRetraceGroupKey.flatMap { cumulativeByGroup[$0] } ?? 0
        let retraceCPUSeconds = Double(retraceNanoseconds) / 1_000_000_000.0
        let retraceEnergyNanojoules = effectiveRetraceGroupKey.flatMap { energyCumulativeByGroup[$0] } ?? 0
        let retraceEnergyJoules = Double(retraceEnergyNanojoules) / 1_000_000_000.0
        let totalTrackedNanoseconds = cumulativeByGroup.values.reduce(UInt64(0), +)
        let totalTrackedCPUSeconds = Double(totalTrackedNanoseconds) / 1_000_000_000.0
        let totalTrackedEnergyNanojoules = energyCumulativeByGroup.values.reduce(UInt64(0), Self.saturatingAdd)
        let totalTrackedEnergyJoules = Double(totalTrackedEnergyNanojoules) / 1_000_000_000.0
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

        let rankedProcesses = ProcessCPUDisplayMetrics.buildRows(
            cumulativeNanosecondsByGroup: cumulativeByGroup,
            latestDeltaNanosecondsByGroup: latestDeltaNanosecondsByGroup,
            latestSampleDurationSeconds: latestSampleDurationSeconds,
            energyNanojoulesByGroup: energyCumulativeByGroup,
            peakPowerWattsByGroup: peakPowerByGroup,
            displayNamesByKey: displayNamesByKey,
            totalDuration: totalDuration,
            logicalCoreCount: logicalCoreCount
        )

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
            retraceEnergyJoules: retraceEnergyJoules,
            totalTrackedEnergyJoules: totalTrackedEnergyJoules,
            retraceRank: retraceRank,
            retraceGroupKey: effectiveRetraceGroupKey,
            peakPercentByGroup: peakPercentByGroup,
            peakPowerWattsByGroup: peakPowerByGroup,
            topProcesses: rankedProcesses,
            totalTrackedCurrentResidentBytes: totalTrackedCurrentResidentBytes,
            totalTrackedAverageResidentBytes: totalTrackedAverageResidentBytes,
            peakResidentBytesByGroup: peakResidentBytesByGroup,
            topMemoryProcesses: rankedMemoryProcesses,
            latestSampleTimestamp: windowEntries.last?.timestamp ?? latestTallySampleTimestamp
        )
    }

    private func maybeLogMemoryComposition(at now: Date, shouldBuildSnapshot: Bool) {
        guard Self.isMemoryCompositionLoggingEnabled() else { return }
        if let lastMemoryCompositionLogDate,
           now.timeIntervalSince(lastMemoryCompositionLogDate) < Self.memoryCompositionLogInterval {
            return
        }
        lastMemoryCompositionLogDate = now

        let snapshot = Self.currentProcessMemorySnapshot()
        let entryCount = windowEntries.count
        let avgDeltaPairs = entryCount > 0
            ? Double(windowTotalDeltaPairs) / Double(entryCount)
            : 0
        let avgEnergyPairs = entryCount > 0
            ? Double(windowTotalEnergyPairs) / Double(entryCount)
            : 0
        let avgResidentPairs = entryCount > 0
            ? Double(windowTotalResidentPairs) / Double(entryCount)
            : 0
        let logFileSizeBytes = Self.fileSizeBytes(at: logFileURL)
        let tallyFileSizeBytes = Self.fileSizeBytes(at: tallyFileURL)
        let displayNameMapSize = groupDisplayNameByKey.count
        let samplerStateBytes = Self.estimatedSamplerStateBytes(
            windowEntryCount: entryCount,
            deltaPairs: windowTotalDeltaPairs,
            energyPairs: windowTotalEnergyPairs,
            residentPairs: windowTotalResidentPairs,
            cpuGroupCount: windowCumulativeByGroup.count,
            peakCPUGroupCount: windowPeakPercentByGroup.count,
            energyGroupCount: windowEnergyCumulativeByGroup.count,
            peakPowerGroupCount: windowPeakPowerByGroup.count,
            memoryGroupCount: windowMemoryIntegralByteSecondsByGroup.count,
            peakMemoryGroupCount: windowPeakResidentBytesByGroup.count,
            displayNameMapCount: displayNameMapSize
        )

        Log.info(
            "[ProcessMonitor-Memory] snapshotActive=\(shouldBuildSnapshot) footprint=\(Self.formatBytes(snapshot?.physFootprintBytes ?? 0)) resident=\(Self.formatBytes(snapshot?.residentBytes ?? 0)) internal=\(Self.formatBytes(snapshot?.internalBytes ?? 0)) compressed=\(Self.formatBytes(snapshot?.compressedBytes ?? 0)) windowEntries=\(entryCount) windowDuration=\(String(format: "%.1fs", windowTotalDuration)) deltaPairs=\(windowTotalDeltaPairs) avgDeltaPairs=\(String(format: "%.1f", avgDeltaPairs)) energyPairs=\(windowTotalEnergyPairs) avgEnergyPairs=\(String(format: "%.1f", avgEnergyPairs)) residentPairs=\(windowTotalResidentPairs) avgResidentPairs=\(String(format: "%.1f", avgResidentPairs)) cpuGroups=\(windowCumulativeByGroup.count) memoryGroups=\(windowMemoryIntegralByteSecondsByGroup.count) displayNames=\(displayNameMapSize) logSize=\(Self.formatBytes(logFileSizeBytes)) tallySize=\(Self.formatBytes(tallyFileSizeBytes))",
            category: .ui
        )

        MemoryLedger.setProcessSnapshot(
            footprintBytes: snapshot?.physFootprintBytes,
            residentBytes: snapshot?.residentBytes,
            internalBytes: snapshot?.internalBytes,
            compressedBytes: snapshot?.compressedBytes
        )
        MemoryLedger.set(
            tag: Self.memoryLedgerSamplerStateTag,
            bytes: samplerStateBytes,
            count: entryCount,
            unit: "samples",
            function: "ui.system_monitor",
            kind: "telemetry-window",
            note: "estimated"
        )
        MemoryLedger.set(
            tag: Self.memoryLedgerLogFileTag,
            bytes: Int64(min(logFileSizeBytes, UInt64(Int64.max))),
            count: nil,
            unit: nil,
            function: "ui.system_monitor",
            kind: "telemetry-disk",
            note: "on-disk",
            countsTowardTrackedMemory: false
        )
        MemoryLedger.set(
            tag: Self.memoryLedgerTallyFileTag,
            bytes: Int64(min(tallyFileSizeBytes, UInt64(Int64.max))),
            count: nil,
            unit: nil,
            function: "ui.system_monitor",
            kind: "telemetry-disk",
            note: "on-disk",
            countsTowardTrackedMemory: false
        )
        MemoryLedger.emitSummary(
            reason: "ui.system_monitor.memory",
            category: .ui,
            minIntervalSeconds: Self.memoryLedgerSummaryIntervalSeconds
        )

        maybeLogVMMapSummary(at: now)
    }

    private func maybeLogVMMapSummary(at now: Date) {
        guard Self.isVMMapSummaryLoggingEnabled() else { return }
        if let lastVMMapSummaryLogDate,
           now.timeIntervalSince(lastVMMapSummaryLogDate) < Self.vmmapSummaryLogInterval {
            return
        }
        lastVMMapSummaryLogDate = now

        guard let lines = Self.captureVMMapSummaryLines(
            pid: ProcessInfo.processInfo.processIdentifier
        ), !lines.isEmpty else {
            Log.warning("[ProcessMonitor-VMMap] vmmap summary unavailable", category: .ui)
            return
        }

        Log.info("[ProcessMonitor-VMMap] \(lines.joined(separator: " | "))", category: .ui)
    }

    private func maybeCompactLog(at now: Date) {
        if let lastCompactionDate, now.timeIntervalSince(lastCompactionDate) < Self.logCompactionInterval {
            return
        }

        let started = Date()
        let retentionCutoff = now.addingTimeInterval(-Self.logRetentionDuration).timeIntervalSince1970
        var retainedEntries: [CPULogEntry] = []
        streamLogEntries { entry in
            if entry.timestamp >= retentionCutoff {
                retainedEntries.append(compactEntryForStorage(entry))
            }
        }
        rewriteLog(with: retainedEntries)
        lastCompactionDate = now
        let elapsedMs = Date().timeIntervalSince(started) * 1000
        Log.info(
            "[ProcessMonitor] Log compaction completed in \(String(format: "%.0f", elapsedMs))ms (retainedEntries=\(retainedEntries.count), logSize=\(Self.formatBytes(Self.fileSizeBytes(at: logFileURL))))",
            category: .ui
        )
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
        clearTallyStateFile()
        tallyState = nil
        lastTallyPersistDate = nil
        lastSampleDate = nil
        lastCPUByPID = [:]
        lastEnergyByPID = [:]
        identityByPID = [:]
        groupDisplayNameByKey = Self.readGroupDisplayNameMap(from: displayNamesFileURL)
        updateGroupDisplayNameIfNeeded(forKey: "bundle:\(retraceBundleID)", name: retraceDisplayName)
        displayNameMapDirty = false
        lastDisplayNamePersistDate = nil
        bundleMetadataByCanonicalPath = [:]
        loadedWindowDuration = nil
        windowStateNeedsReload = true
        clearWindowState(keepingCapacity: false)
        lastWindowDownsampleDate = nil
        lastTallyDownsampleDate = nil
        latestResidentBytesByGroup = [:]
        latestTallySampleTimestamp = nil
        retraceGroupKey = nil
        lastCompactionDate = nil
        lastMemoryCompositionLogDate = nil
        lastVMMapSummaryLogDate = nil
    }

    private func clearTallyStateFile() {
        do {
            Self.ensureLogFileExists(at: tallyFileURL)
            try Data().write(to: tallyFileURL, options: .atomic)
            MemoryLedger.set(
                tag: Self.memoryLedgerTallyFileTag,
                bytes: 0,
                count: nil,
                unit: nil,
                function: "ui.system_monitor",
                kind: "telemetry-disk",
                note: "on-disk",
                countsTowardTrackedMemory: false
            )
        } catch {
            Log.warning("[ProcessMonitor] Failed to clear CPU tally state: \(error)", category: .ui)
        }
    }

    private static func isMemoryCompositionLoggingEnabled(
        defaults: UserDefaults = .standard
    ) -> Bool {
        if defaults.object(forKey: memoryCompositionLoggingDefaultsKey) == nil {
            return true
        }
        return defaults.bool(forKey: memoryCompositionLoggingDefaultsKey)
    }

    private static func isVMMapSummaryLoggingEnabled(
        defaults: UserDefaults = .standard
    ) -> Bool {
        defaults.bool(forKey: vmmapSummaryLoggingDefaultsKey)
    }

    private func compactEntryForStorage(_ entry: CPULogEntry) -> CPULogEntry {
        Self.cappedEntry(
            entry,
            maxGroupsPerSample: Self.maxGroupsPerSample(),
            fallbackRetraceGroupKey: entry.retraceGroupKey ?? retraceGroupKey
        )
    }

    private static func maxGroupsPerSample(defaults: UserDefaults = .standard) -> Int {
        let configuredValue: Int
        if let rawNumber = defaults.object(forKey: maxGroupsPerSampleDefaultsKey) as? NSNumber {
            configuredValue = rawNumber.intValue
        } else if let rawString = defaults.string(forKey: maxGroupsPerSampleDefaultsKey),
                  let parsedValue = Int(rawString) {
            configuredValue = parsedValue
        } else {
            configuredValue = defaultMaxGroupsPerSample
        }

        return min(max(configuredValue, minMaxGroupsPerSample), maxMaxGroupsPerSample)
    }

    private static func cappedEntry(
        _ entry: CPULogEntry,
        maxGroupsPerSample: Int,
        fallbackRetraceGroupKey: String?
    ) -> CPULogEntry {
        let normalizedCap = max(1, maxGroupsPerSample)
        var allMetricKeys = Set(entry.groupDeltaNanoseconds.keys)
        if let energyByGroup = entry.groupDeltaEnergyNanojoules {
            allMetricKeys.formUnion(energyByGroup.keys)
        }
        if let residentByGroup = entry.groupResidentBytes {
            allMetricKeys.formUnion(residentByGroup.keys)
        }
        guard allMetricKeys.count > normalizedCap else { return entry }

        let deltaByGroup = entry.groupDeltaNanoseconds
        let energyByGroup = entry.groupDeltaEnergyNanojoules ?? [:]
        let residentByGroup = entry.groupResidentBytes ?? [:]
        let totalDelta = Double(deltaByGroup.values.reduce(UInt64(0), saturatingAdd))
        let totalEnergy = Double(energyByGroup.values.reduce(UInt64(0), saturatingAdd))
        let totalResident = Double(residentByGroup.values.reduce(UInt64(0), saturatingAdd))

        func share(_ value: UInt64, total: Double) -> Double {
            guard total > 0 else { return 0 }
            return Double(value) / total
        }

        let rankedKeys = allMetricKeys
            .map { key -> (key: String, primary: Double, cpu: Double, resident: Double, energy: Double) in
                let cpuShare = share(deltaByGroup[key] ?? 0, total: totalDelta)
                let residentShare = share(residentByGroup[key] ?? 0, total: totalResident)
                let energyShare = share(energyByGroup[key] ?? 0, total: totalEnergy)
                return (
                    key: key,
                    primary: max(cpuShare, residentShare, energyShare),
                    cpu: cpuShare,
                    resident: residentShare,
                    energy: energyShare
                )
            }
            .sorted { lhs, rhs in
                if lhs.primary != rhs.primary {
                    return lhs.primary > rhs.primary
                }
                if lhs.cpu != rhs.cpu {
                    return lhs.cpu > rhs.cpu
                }
                if lhs.resident != rhs.resident {
                    return lhs.resident > rhs.resident
                }
                if lhs.energy != rhs.energy {
                    return lhs.energy > rhs.energy
                }
                return lhs.key < rhs.key
            }

        var keptKeys = Array(rankedKeys.prefix(normalizedCap).map(\.key))
        let effectiveRetraceGroupKey = entry.retraceGroupKey ?? fallbackRetraceGroupKey
        if let effectiveRetraceGroupKey,
           allMetricKeys.contains(effectiveRetraceGroupKey),
           !keptKeys.contains(effectiveRetraceGroupKey) {
            if keptKeys.count < normalizedCap {
                keptKeys.append(effectiveRetraceGroupKey)
            } else if let replaceIndex = keptKeys.indices.last(where: { keptKeys[$0] != effectiveRetraceGroupKey }) {
                keptKeys[replaceIndex] = effectiveRetraceGroupKey
            }
        }

        let keepSet = Set(keptKeys)
        return CPULogEntry(
            timestamp: entry.timestamp,
            durationSeconds: entry.durationSeconds,
            retraceGroupKey: effectiveRetraceGroupKey,
            groupDeltaNanoseconds: filteredUInt64Dictionary(deltaByGroup, keepSet: keepSet),
            groupDeltaEnergyNanojoules: {
                let filtered = filteredUInt64Dictionary(energyByGroup, keepSet: keepSet)
                return filtered.isEmpty ? nil : filtered
            }(),
            groupDeltaUnit: entry.groupDeltaUnit,
            groupResidentBytes: {
                let filtered = filteredUInt64Dictionary(residentByGroup, keepSet: keepSet)
                return filtered.isEmpty ? nil : filtered
            }(),
            groupDisplayNames: {
                let filtered = filteredStringDictionary(entry.groupDisplayNames ?? [:], keepSet: keepSet)
                return filtered.isEmpty ? nil : filtered
            }()
        )
    }

    private static func cappedLatestResidentBytesByGroup(
        _ residentBytesByGroup: [String: UInt64],
        maxGroupsPerSample: Int,
        retraceGroupKey: String?
    ) -> [String: UInt64] {
        let normalizedCap = max(1, maxGroupsPerSample)
        guard residentBytesByGroup.count > normalizedCap else { return residentBytesByGroup }

        var rankedKeys = residentBytesByGroup.keys.sorted { lhs, rhs in
            let lhsValue = residentBytesByGroup[lhs] ?? 0
            let rhsValue = residentBytesByGroup[rhs] ?? 0
            if lhsValue != rhsValue {
                return lhsValue > rhsValue
            }
            return lhs < rhs
        }
        rankedKeys = Array(rankedKeys.prefix(normalizedCap))

        if let retraceGroupKey,
           residentBytesByGroup[retraceGroupKey] != nil,
           !rankedKeys.contains(retraceGroupKey) {
            if rankedKeys.count < normalizedCap {
                rankedKeys.append(retraceGroupKey)
            } else if let replaceIndex = rankedKeys.indices.last(where: { rankedKeys[$0] != retraceGroupKey }) {
                rankedKeys[replaceIndex] = retraceGroupKey
            }
        }

        return filteredUInt64Dictionary(residentBytesByGroup, keepSet: Set(rankedKeys))
    }

    private static func cappedLatestDeltaNanosecondsByGroup(
        _ deltaNanosecondsByGroup: [String: UInt64],
        maxGroupsPerSample: Int,
        retraceGroupKey: String?
    ) -> [String: UInt64] {
        let normalizedCap = max(1, maxGroupsPerSample)
        guard deltaNanosecondsByGroup.count > normalizedCap else { return deltaNanosecondsByGroup }

        var rankedKeys = deltaNanosecondsByGroup.keys.sorted { lhs, rhs in
            let lhsValue = deltaNanosecondsByGroup[lhs] ?? 0
            let rhsValue = deltaNanosecondsByGroup[rhs] ?? 0
            if lhsValue != rhsValue {
                return lhsValue > rhsValue
            }
            return lhs < rhs
        }
        rankedKeys = Array(rankedKeys.prefix(normalizedCap))

        if let retraceGroupKey,
           deltaNanosecondsByGroup[retraceGroupKey] != nil,
           !rankedKeys.contains(retraceGroupKey) {
            if rankedKeys.count < normalizedCap {
                rankedKeys.append(retraceGroupKey)
            } else if let replaceIndex = rankedKeys.indices.last(where: { rankedKeys[$0] != retraceGroupKey }) {
                rankedKeys[replaceIndex] = retraceGroupKey
            }
        }

        return filteredUInt64Dictionary(deltaNanosecondsByGroup, keepSet: Set(rankedKeys))
    }

    private static func cappedTallyBucket(
        _ bucket: ProcessTallyBucket,
        maxGroupsPerSample: Int,
        retraceGroupKey: String?
    ) -> ProcessTallyBucket {
        let normalizedCap = max(1, maxGroupsPerSample)
        var allKeys = Set(bucket.deltaNanosecondsByGroup.keys)
        allKeys.formUnion(bucket.energyNanojoulesByGroup.keys)
        allKeys.formUnion(bucket.memoryByteSecondsByGroup.keys)
        allKeys.formUnion(bucket.peakPercentByGroup.keys)
        allKeys.formUnion(bucket.peakPowerByGroup.keys)
        allKeys.formUnion(bucket.peakResidentBytesByGroup.keys)
        guard allKeys.count > normalizedCap else { return bucket }

        let totalDelta = Double(bucket.deltaNanosecondsByGroup.values.reduce(UInt64(0), saturatingAdd))
        let totalEnergy = Double(bucket.energyNanojoulesByGroup.values.reduce(UInt64(0), saturatingAdd))
        let totalMemory = bucket.memoryByteSecondsByGroup.values.reduce(0, +)

        func share(_ value: UInt64, total: Double) -> Double {
            guard total > 0 else { return 0 }
            return Double(value) / total
        }

        func share(_ value: Double, total: Double) -> Double {
            guard total > 0 else { return 0 }
            return value / total
        }

        let rankedKeys = allKeys
            .map { key -> (key: String, primary: Double, cpu: Double, memory: Double, energy: Double) in
                let cpuShare = share(bucket.deltaNanosecondsByGroup[key] ?? 0, total: totalDelta)
                let memoryShare = share(bucket.memoryByteSecondsByGroup[key] ?? 0, total: totalMemory)
                let energyShare = share(bucket.energyNanojoulesByGroup[key] ?? 0, total: totalEnergy)
                return (
                    key: key,
                    primary: max(cpuShare, memoryShare, energyShare),
                    cpu: cpuShare,
                    memory: memoryShare,
                    energy: energyShare
                )
            }
            .sorted { lhs, rhs in
                if lhs.primary != rhs.primary {
                    return lhs.primary > rhs.primary
                }
                if lhs.cpu != rhs.cpu {
                    return lhs.cpu > rhs.cpu
                }
                if lhs.memory != rhs.memory {
                    return lhs.memory > rhs.memory
                }
                if lhs.energy != rhs.energy {
                    return lhs.energy > rhs.energy
                }
                return lhs.key < rhs.key
            }

        var keptKeys = Array(rankedKeys.prefix(normalizedCap).map(\.key))
        if let retraceGroupKey,
           allKeys.contains(retraceGroupKey),
           !keptKeys.contains(retraceGroupKey) {
            if keptKeys.count < normalizedCap {
                keptKeys.append(retraceGroupKey)
            } else if let replaceIndex = keptKeys.indices.last(where: { keptKeys[$0] != retraceGroupKey }) {
                keptKeys[replaceIndex] = retraceGroupKey
            }
        }

        let keepSet = Set(keptKeys)
        return ProcessTallyBucket(
            startTimestamp: bucket.startTimestamp,
            durationSeconds: bucket.durationSeconds,
            deltaNanosecondsByGroup: filteredUInt64Dictionary(bucket.deltaNanosecondsByGroup, keepSet: keepSet),
            energyNanojoulesByGroup: filteredUInt64Dictionary(bucket.energyNanojoulesByGroup, keepSet: keepSet),
            memoryByteSecondsByGroup: filteredDoubleDictionary(bucket.memoryByteSecondsByGroup, keepSet: keepSet),
            peakPercentByGroup: filteredDoubleDictionary(bucket.peakPercentByGroup, keepSet: keepSet),
            peakPowerByGroup: filteredDoubleDictionary(bucket.peakPowerByGroup, keepSet: keepSet),
            peakResidentBytesByGroup: filteredUInt64Dictionary(bucket.peakResidentBytesByGroup, keepSet: keepSet)
        )
    }

    private static func downsampledTallyBuckets(
        _ buckets: [ProcessTallyBucket],
        nowTimestamp: TimeInterval,
        maxGroupsPerSample: Int,
        retraceGroupKey: String?
    ) -> [ProcessTallyBucket] {
        guard !buckets.isEmpty else { return [] }

        let sortedBuckets = buckets.sorted { $0.startTimestamp < $1.startTimestamp }
        var downsampled: [ProcessTallyBucket] = []
        downsampled.reserveCapacity(sortedBuckets.count)
        var currentBucket: ProcessTallyBucket?
        var currentBucketIndex: Int64?
        var currentBucketSize: TimeInterval?

        func flushCurrentBucket() {
            guard let currentBucket else { return }
            downsampled.append(
                cappedTallyBucket(
                    currentBucket,
                    maxGroupsPerSample: maxGroupsPerSample,
                    retraceGroupKey: retraceGroupKey
                )
            )
        }

        for rawBucket in sortedBuckets {
            let cappedBucket = cappedTallyBucket(
                rawBucket,
                maxGroupsPerSample: maxGroupsPerSample,
                retraceGroupKey: retraceGroupKey
            )
            let ageSeconds = max(0, nowTimestamp - cappedBucket.startTimestamp)
            let bucketSize = tallyBucketDurationSeconds(forAge: ageSeconds)
            let bucketIndex = Int64(floor(cappedBucket.startTimestamp / bucketSize))
            let bucketStartTimestamp = Double(bucketIndex) * bucketSize
            let normalizedBucket = ProcessTallyBucket(
                startTimestamp: bucketStartTimestamp,
                durationSeconds: cappedBucket.durationSeconds,
                deltaNanosecondsByGroup: cappedBucket.deltaNanosecondsByGroup,
                energyNanojoulesByGroup: cappedBucket.energyNanojoulesByGroup,
                memoryByteSecondsByGroup: cappedBucket.memoryByteSecondsByGroup,
                peakPercentByGroup: cappedBucket.peakPercentByGroup,
                peakPowerByGroup: cappedBucket.peakPowerByGroup,
                peakResidentBytesByGroup: cappedBucket.peakResidentBytesByGroup
            )

            if let existingBucket = currentBucket,
               let existingBucketIndex = currentBucketIndex,
               let existingBucketSize = currentBucketSize,
               existingBucketIndex == bucketIndex,
               existingBucketSize == bucketSize {
                currentBucket = mergeTallyBuckets(
                    existingBucket,
                    normalizedBucket,
                    startTimestamp: bucketStartTimestamp
                )
            } else {
                flushCurrentBucket()
                currentBucket = normalizedBucket
                currentBucketIndex = bucketIndex
                currentBucketSize = bucketSize
            }
        }

        flushCurrentBucket()
        return downsampled
    }

    private static func mergeTallyBuckets(
        _ lhs: ProcessTallyBucket,
        _ rhs: ProcessTallyBucket,
        startTimestamp: TimeInterval
    ) -> ProcessTallyBucket {
        var mergedDeltaByGroup = lhs.deltaNanosecondsByGroup
        for (key, value) in rhs.deltaNanosecondsByGroup {
            mergedDeltaByGroup[key] = saturatingAdd(mergedDeltaByGroup[key] ?? 0, value)
        }

        var mergedEnergyByGroup = lhs.energyNanojoulesByGroup
        for (key, value) in rhs.energyNanojoulesByGroup {
            mergedEnergyByGroup[key] = saturatingAdd(mergedEnergyByGroup[key] ?? 0, value)
        }

        var mergedMemoryByteSecondsByGroup = lhs.memoryByteSecondsByGroup
        for (key, value) in rhs.memoryByteSecondsByGroup {
            mergedMemoryByteSecondsByGroup[key, default: 0] += value
        }

        var mergedPeakPercentByGroup = lhs.peakPercentByGroup
        for (key, value) in rhs.peakPercentByGroup {
            if value > (mergedPeakPercentByGroup[key] ?? 0) {
                mergedPeakPercentByGroup[key] = value
            }
        }

        var mergedPeakPowerByGroup = lhs.peakPowerByGroup
        for (key, value) in rhs.peakPowerByGroup {
            if value > (mergedPeakPowerByGroup[key] ?? 0) {
                mergedPeakPowerByGroup[key] = value
            }
        }

        var mergedPeakResidentBytesByGroup = lhs.peakResidentBytesByGroup
        for (key, value) in rhs.peakResidentBytesByGroup {
            if value > (mergedPeakResidentBytesByGroup[key] ?? 0) {
                mergedPeakResidentBytesByGroup[key] = value
            }
        }

        return ProcessTallyBucket(
            startTimestamp: startTimestamp,
            durationSeconds: lhs.durationSeconds + rhs.durationSeconds,
            deltaNanosecondsByGroup: mergedDeltaByGroup,
            energyNanojoulesByGroup: mergedEnergyByGroup,
            memoryByteSecondsByGroup: mergedMemoryByteSecondsByGroup,
            peakPercentByGroup: mergedPeakPercentByGroup,
            peakPowerByGroup: mergedPeakPowerByGroup,
            peakResidentBytesByGroup: mergedPeakResidentBytesByGroup
        )
    }

    private static func tallyBucketDurationSeconds(forAge ageSeconds: TimeInterval) -> TimeInterval {
        if ageSeconds <= downsampleMediumResolutionAgeSeconds {
            return tallyBucketDurationSeconds
        }
        if ageSeconds <= downsampleCoarseResolutionAgeSeconds {
            return tallyMediumBucketSeconds
        }
        return tallyCoarseBucketSeconds
    }

    private static func totalTallyPairCount(_ buckets: [ProcessTallyBucket]) -> Int {
        var total = 0
        for bucket in buckets {
            total += bucket.deltaNanosecondsByGroup.count
            total += bucket.energyNanojoulesByGroup.count
            total += bucket.memoryByteSecondsByGroup.count
            total += bucket.peakPercentByGroup.count
            total += bucket.peakPowerByGroup.count
            total += bucket.peakResidentBytesByGroup.count
        }
        return total
    }

    private static func downsampleBucketSeconds(forAge ageSeconds: TimeInterval) -> TimeInterval? {
        if ageSeconds <= downsampleKeepFullResolutionAgeSeconds {
            return nil
        }
        if ageSeconds <= downsampleMediumResolutionAgeSeconds {
            return downsampleMediumBucketSeconds
        }
        if ageSeconds <= downsampleCoarseResolutionAgeSeconds {
            return downsampleCoarseBucketSeconds
        }
        return downsampleVeryCoarseBucketSeconds
    }

    private static func downsampledEntries(
        _ entries: [CPULogEntry],
        nowTimestamp: TimeInterval,
        maxGroupsPerSample: Int,
        fallbackRetraceGroupKey: String?
    ) -> [CPULogEntry] {
        guard !entries.isEmpty else { return [] }

        var downsampled: [CPULogEntry] = []
        downsampled.reserveCapacity(entries.count)
        var accumulator: DownsampleBucketAccumulator?

        func flushAccumulator() {
            guard let accumulator else { return }
            downsampled.append(
                cappedEntry(
                    accumulator.makeEntry(fallbackRetraceGroupKey: fallbackRetraceGroupKey),
                    maxGroupsPerSample: maxGroupsPerSample,
                    fallbackRetraceGroupKey: fallbackRetraceGroupKey
                )
            )
        }

        for rawEntry in entries {
            let entry = cappedEntry(
                rawEntry,
                maxGroupsPerSample: maxGroupsPerSample,
                fallbackRetraceGroupKey: fallbackRetraceGroupKey
            )
            let ageSeconds = max(0, nowTimestamp - entry.timestamp)
            guard let bucketSizeSeconds = downsampleBucketSeconds(forAge: ageSeconds) else {
                flushAccumulator()
                accumulator = nil
                downsampled.append(entry)
                continue
            }

            let bucketIndex = Int64(floor(entry.timestamp / bucketSizeSeconds))
            if let existingAccumulator = accumulator,
               existingAccumulator.bucketIndex == bucketIndex,
               existingAccumulator.bucketSizeSeconds == bucketSizeSeconds {
                var updatedAccumulator = existingAccumulator
                updatedAccumulator.append(entry)
                accumulator = updatedAccumulator
            } else {
                flushAccumulator()
                accumulator = DownsampleBucketAccumulator(
                    entry: entry,
                    bucketIndex: bucketIndex,
                    bucketSizeSeconds: bucketSizeSeconds
                )
            }
        }

        flushAccumulator()
        return downsampled
    }

    private static func totalPairCount(for entries: [CPULogEntry]) -> Int {
        var total = 0
        for entry in entries {
            total += entry.groupDeltaNanoseconds.count
            total += entry.groupDeltaEnergyNanojoules?.count ?? 0
            total += entry.groupResidentBytes?.count ?? 0
        }
        return total
    }

    private static func filteredUInt64Dictionary(
        _ source: [String: UInt64],
        keepSet: Set<String>
    ) -> [String: UInt64] {
        guard !source.isEmpty, !keepSet.isEmpty else { return [:] }
        var filtered: [String: UInt64] = [:]
        filtered.reserveCapacity(min(source.count, keepSet.count))
        for (key, value) in source where keepSet.contains(key) {
            filtered[key] = value
        }
        return filtered
    }

    private static func normalizedDeltaNanosecondsByGroup(
        _ source: [String: UInt64],
        unit: String?
    ) -> [String: UInt64] {
        guard !source.isEmpty else { return [:] }
        var normalized: [String: UInt64] = [:]
        normalized.reserveCapacity(source.count)
        for (key, value) in source {
            normalized[key] = normalizedDeltaNanoseconds(rawDelta: value, unit: unit)
        }
        return normalized
    }

    private static func filteredDoubleDictionary(
        _ source: [String: Double],
        keepSet: Set<String>
    ) -> [String: Double] {
        guard !source.isEmpty, !keepSet.isEmpty else { return [:] }
        var filtered: [String: Double] = [:]
        filtered.reserveCapacity(min(source.count, keepSet.count))
        for (key, value) in source where keepSet.contains(key) {
            filtered[key] = value
        }
        return filtered
    }

    private static func filteredStringDictionary(
        _ source: [String: String],
        keepSet: Set<String>
    ) -> [String: String] {
        guard !source.isEmpty, !keepSet.isEmpty else { return [:] }
        var filtered: [String: String] = [:]
        filtered.reserveCapacity(min(source.count, keepSet.count))
        for (key, value) in source where keepSet.contains(key) {
            filtered[key] = value
        }
        return filtered
    }

    private static func fileSizeBytes(at fileURL: URL) -> UInt64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let fileSize = attrs[.size] as? NSNumber else {
            return 0
        }
        return fileSize.uint64Value
    }

    private static func formatBytes(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: Int64(min(bytes, UInt64(Int64.max))))
    }

    private static func estimatedSamplerStateBytes(
        windowEntryCount: Int,
        deltaPairs: Int,
        energyPairs: Int,
        residentPairs: Int,
        cpuGroupCount: Int,
        peakCPUGroupCount: Int,
        energyGroupCount: Int,
        peakPowerGroupCount: Int,
        memoryGroupCount: Int,
        peakMemoryGroupCount: Int,
        displayNameMapCount: Int
    ) -> Int64 {
        let entryBytes = UInt64(max(windowEntryCount, 0)) * 192
        let pairCount = max(0, deltaPairs) + max(0, energyPairs) + max(0, residentPairs)
        let pairBytes = UInt64(pairCount) * 80
        let groupCount = max(0, cpuGroupCount)
            + max(0, peakCPUGroupCount)
            + max(0, energyGroupCount)
            + max(0, peakPowerGroupCount)
            + max(0, memoryGroupCount)
            + max(0, peakMemoryGroupCount)
        let groupBytes = UInt64(groupCount) * 88
        let displayNameBytes = UInt64(max(displayNameMapCount, 0)) * 96
        let combined = saturatingAdd(
            saturatingAdd(entryBytes, pairBytes),
            saturatingAdd(groupBytes, displayNameBytes)
        )
        let total = min(
            combined,
            UInt64(Int64.max)
        )
        return Int64(total)
    }

    private static func currentProcessMemorySnapshot() -> ProcessMemorySnapshot? {
        let usage = processRusageCurrent(for: ProcessInfo.processInfo.processIdentifier)
        let taskInfo = currentTaskVMInfo()
        guard usage != nil || taskInfo != nil else { return nil }

        return ProcessMemorySnapshot(
            physFootprintBytes: usage?.ri_phys_footprint ?? taskInfo?.phys_footprint ?? 0,
            residentBytes: taskInfo?.resident_size ?? 0,
            internalBytes: taskInfo?.internal ?? 0,
            compressedBytes: taskInfo?.compressed ?? 0
        )
    }

    private static func currentTaskVMInfo() -> task_vm_info_data_t? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )

        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(
                    mach_task_self_,
                    task_flavor_t(TASK_VM_INFO),
                    rebound,
                    &count
                )
            }
        }

        guard result == KERN_SUCCESS else { return nil }
        return info
    }

    private static let vmmapSummaryInterestingPrefixes: [String] = [
        "Physical footprint:",
        "Physical footprint (peak):",
        "IOSurface",
        "CG image",
        "CoreUI image data",
        "CoreAnimation",
        "MALLOC_SMALL",
        "MALLOC_SMALL (empty)",
        "MALLOC_LARGE",
        "MALLOC_LARGE (empty)",
        "mapped file",
        "TOTAL, minus reserved VM space",
        "TOTAL"
    ]

    private static func captureVMMapSummaryLines(pid: pid_t) -> [String]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/vmmap")
        process.arguments = ["-summary", String(pid)]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0,
              let data = try? outputPipe.fileHandleForReading.readToEnd(),
              let output = String(data: data, encoding: .utf8) else {
            return nil
        }

        var selected: [String] = []
        selected.reserveCapacity(16)

        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            guard vmmapSummaryInterestingPrefixes.contains(where: { line.hasPrefix($0) }) else {
                continue
            }
            selected.append(line)
        }

        return selected.isEmpty ? nil : selected
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
        let rootURL = URL(fileURLWithPath: AppPaths.expandedAppSupportRoot, isDirectory: true)
        return rootURL
            .appendingPathComponent("logs", isDirectory: true)
            .appendingPathComponent("cpu_process_usage.jsonl", isDirectory: false)
    }

    private static func makeTallyFileURL() -> URL {
        let rootURL = URL(fileURLWithPath: AppPaths.expandedAppSupportRoot, isDirectory: true)
        return rootURL
            .appendingPathComponent("logs", isDirectory: true)
            .appendingPathComponent("cpu_process_usage_tally.json", isDirectory: false)
    }

    private static func makeDisplayNamesFileURL() -> URL {
        let rootURL = URL(fileURLWithPath: AppPaths.expandedAppSupportRoot, isDirectory: true)
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
        let usage = processRusageCurrent(for: pid)
        let memoryBytes = usage?.ri_phys_footprint ?? info.pti_resident_size
        let energyNanojoules = usage?.ri_energy_nj
        return ProcessTaskMetrics(
            cpuAbsoluteUnits: info.pti_total_user + info.pti_total_system,
            residentBytes: memoryBytes,
            energyNanojoules: energyNanojoules
        )
    }

    private static func processRusageCurrent(for pid: pid_t) -> rusage_info_current? {
        guard let procPidRusageFunction else { return nil }

        var usage = rusage_info_current()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            procPidRusageFunction(pid, RUSAGE_INFO_CURRENT, UnsafeMutableRawPointer(pointer))
        }
        guard result == 0 else { return nil }
        return usage
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
