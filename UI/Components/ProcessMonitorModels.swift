import Foundation

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
        topRetraceChildMemoryProcesses: [],
        topRetraceMemoryAttributionFamilies: [],
        retraceMemoryAttributionChildrenByFamily: [:],
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
    let topRetraceChildMemoryProcesses: [ProcessMemoryRow]
    let topRetraceMemoryAttributionFamilies: [ProcessMemoryRow]
    let retraceMemoryAttributionChildrenByFamily: [String: [ProcessMemoryRow]]
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
    private static let unattributedMemoryFamilyKey = "memory.unattributed"
    private static let unattributedMemoryComponentKey = "memory.unattributed.total"

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

    static func buildMemoryRows(
        currentBytesByKey: [String: UInt64],
        memoryByteSecondsByKey: [String: Double],
        peakBytesByKey: [String: UInt64],
        displayNamesByKey: [String: String],
        totalDuration: TimeInterval
    ) -> [ProcessMemoryRow] {
        func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
            let (result, overflow) = lhs.addingReportingOverflow(rhs)
            return overflow ? UInt64.max : result
        }

        func doubleToUInt64(_ value: Double) -> UInt64 {
            guard value.isFinite else { return 0 }
            if value <= 0 { return 0 }
            if value >= Double(UInt64.max) { return UInt64.max }
            return UInt64(value.rounded())
        }

        let safeTotalDuration = max(totalDuration, 0)
        let totalCurrentResidentBytes = currentBytesByKey.values.reduce(UInt64(0), saturatingAdd)
        let totalAverageResidentBytesDouble = safeTotalDuration > 0
            ? memoryByteSecondsByKey.values.reduce(0, +) / safeTotalDuration
            : 0

        let memoryKeys = Set(memoryByteSecondsByKey.keys)
            .union(currentBytesByKey.keys)
            .union(peakBytesByKey.keys)

        return memoryKeys
            .map { key -> ProcessMemoryRow in
                let currentBytes = currentBytesByKey[key] ?? 0
                let averageBytesDouble = safeTotalDuration > 0
                    ? (memoryByteSecondsByKey[key] ?? 0) / safeTotalDuration
                    : Double(currentBytes)
                let averageBytes = doubleToUInt64(averageBytesDouble)
                let peakBytes = max(
                    peakBytesByKey[key] ?? 0,
                    currentBytes,
                    averageBytes
                )
                let currentSharePercent = totalCurrentResidentBytes > 0
                    ? (Double(currentBytes) / Double(totalCurrentResidentBytes)) * 100.0
                    : 0
                let averageSharePercent = totalAverageResidentBytesDouble > 0
                    ? (averageBytesDouble / totalAverageResidentBytesDouble) * 100.0
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
                if lhs.peakBytes != rhs.peakBytes {
                    return lhs.peakBytes > rhs.peakBytes
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    static func memoryLedgerFamilyKey(for componentKey: String) -> String {
        let parts = componentKey.split(separator: ".", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return componentKey }
        return parts.prefix(2).joined(separator: ".")
    }

    static func memoryLedgerFamilyBytes(from componentBytes: [String: UInt64]) -> [String: UInt64] {
        var familyBytes: [String: UInt64] = [:]
        familyBytes.reserveCapacity(componentBytes.count)

        for (componentKey, bytes) in componentBytes {
            let familyKey = memoryLedgerFamilyKey(for: componentKey)
            familyBytes[familyKey] = saturatingAdd(familyBytes[familyKey] ?? 0, bytes)
        }

        return familyBytes
    }

    static func memoryLedgerComponentDisplayName(
        for componentKey: String,
        familyKey: String
    ) -> String {
        if componentKey == unattributedMemoryComponentKey {
            return "unattributed"
        }
        let prefix = familyKey + "."
        guard componentKey.hasPrefix(prefix) else { return componentKey }
        let suffix = String(componentKey.dropFirst(prefix.count))
        return suffix.isEmpty ? componentKey : suffix
    }

    static func memoryLedgerFamilyDisplayName(for familyKey: String) -> String {
        if familyKey == unattributedMemoryFamilyKey {
            return "unattributed"
        }
        return familyKey
    }

    static func buildRetraceMemoryAttributionRows(
        currentBytesByComponent: [String: UInt64],
        memoryByteSecondsByComponent: [String: Double],
        peakBytesByComponent: [String: UInt64],
        peakBytesByFamily: [String: UInt64],
        totalDuration: TimeInterval
    ) -> (families: [ProcessMemoryRow], childrenByFamily: [String: [ProcessMemoryRow]]) {
        let componentDisplayNames = currentBytesByComponent.keys.reduce(into: [String: String]()) { result, key in
            let familyKey = memoryLedgerFamilyKey(for: key)
            result[key] = memoryLedgerComponentDisplayName(for: key, familyKey: familyKey)
        }

        let currentBytesByFamily = memoryLedgerFamilyBytes(from: currentBytesByComponent)
        let memoryByteSecondsByFamily = memoryByteSecondsByComponent.reduce(into: [String: Double]()) { result, element in
            let (componentKey, byteSeconds) = element
            let familyKey = memoryLedgerFamilyKey(for: componentKey)
            result[familyKey, default: 0] += byteSeconds
        }
        let fallbackPeakBytesByFamily = peakBytesByComponent.reduce(into: [String: UInt64]()) { result, element in
            let (componentKey, peakBytes) = element
            let familyKey = memoryLedgerFamilyKey(for: componentKey)
            result[familyKey] = max(result[familyKey] ?? 0, peakBytes)
        }

        let familyRows = buildMemoryRows(
            currentBytesByKey: currentBytesByFamily,
            memoryByteSecondsByKey: memoryByteSecondsByFamily,
            peakBytesByKey: peakBytesByFamily.isEmpty ? fallbackPeakBytesByFamily : peakBytesByFamily,
            displayNamesByKey: Dictionary(
                uniqueKeysWithValues: currentBytesByFamily.keys.map { ($0, memoryLedgerFamilyDisplayName(for: $0)) }
            ),
            totalDuration: totalDuration
        )

        let componentRows = buildMemoryRows(
            currentBytesByKey: currentBytesByComponent,
            memoryByteSecondsByKey: memoryByteSecondsByComponent,
            peakBytesByKey: peakBytesByComponent,
            displayNamesByKey: componentDisplayNames,
            totalDuration: totalDuration
        )

        var childrenByFamily: [String: [ProcessMemoryRow]] = [:]
        childrenByFamily.reserveCapacity(familyRows.count)
        for componentRow in componentRows {
            let familyKey = memoryLedgerFamilyKey(for: componentRow.id)
            childrenByFamily[familyKey, default: []].append(componentRow)
        }

        return (families: familyRows, childrenByFamily: childrenByFamily)
    }

    private static func cumulativeSharePercent(valueSeconds: Double, totalSeconds: Double) -> Double {
        guard totalSeconds > 0 else { return 0 }
        return (valueSeconds / totalSeconds) * 100.0
    }

    private static func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? UInt64.max : result
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
