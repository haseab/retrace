import Foundation
import Shared

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

enum RetraceMemoryAttributionCategory: String, CaseIterable {
    case explicit
    case inferred
    case unattributed

    var displayName: String {
        rawValue
    }
}

struct RetraceMemoryAttributionTree {
    static let empty = RetraceMemoryAttributionTree(
        categories: [],
        familiesByCategory: [:],
        componentsByCategoryFamily: [:]
    )

    let categories: [ProcessMemoryRow]
    let familiesByCategory: [String: [ProcessMemoryRow]]
    let componentsByCategoryFamily: [String: [ProcessMemoryRow]]
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
        retraceMemoryAttributionTree: .empty,
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
    let retraceMemoryAttributionTree: RetraceMemoryAttributionTree
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

    static func retraceMemoryAttributionFamilyExpansionKey(
        categoryID: String,
        familyID: String
    ) -> String {
        "\(categoryID)|\(familyID)"
    }

    static func buildCategorizedRetraceMemoryAttributionTree(
        currentBytesByComponent: [String: UInt64],
        componentCategoriesByKey: [String: MemoryLedger.ComponentCategory],
        memoryByteSecondsByComponent: [String: Double],
        peakBytesByComponent: [String: UInt64],
        componentSamples: [[String: UInt64]],
        totalDuration: TimeInterval
    ) -> RetraceMemoryAttributionTree {
        let componentKeys = Set(currentBytesByComponent.keys)
            .union(memoryByteSecondsByComponent.keys)
            .union(peakBytesByComponent.keys)

        var currentBytesByCategory: [String: UInt64] = [:]
        var averageByteSecondsByCategory: [String: Double] = [:]
        var peakBytesByCategory: [String: UInt64] = [:]

        var currentBytesByCategoryFamily: [String: UInt64] = [:]
        var averageByteSecondsByCategoryFamily: [String: Double] = [:]
        var peakBytesByCategoryFamily: [String: UInt64] = [:]

        var componentDisplayNames: [String: String] = [:]
        var familyIDsByCategory: [String: Set<String>] = [:]
        var componentKeysByCategoryFamily: [String: [String]] = [:]
        var familyDisplayNamesByCategoryFamily: [String: String] = [:]

        for componentKey in componentKeys {
            let category = retraceMemoryAttributionCategory(
                for: componentKey,
                componentCategoriesByKey: componentCategoriesByKey
            )
            let categoryID = category.rawValue
            let familyKey = memoryLedgerFamilyKey(for: componentKey)
            let categoryFamilyKey = retraceMemoryAttributionFamilyExpansionKey(
                categoryID: categoryID,
                familyID: familyKey
            )

            let currentBytes = currentBytesByComponent[componentKey] ?? 0
            if currentBytes > 0 {
                currentBytesByCategory[categoryID] = saturatingAdd(
                    currentBytesByCategory[categoryID] ?? 0,
                    currentBytes
                )
                currentBytesByCategoryFamily[categoryFamilyKey] = saturatingAdd(
                    currentBytesByCategoryFamily[categoryFamilyKey] ?? 0,
                    currentBytes
                )
            }

            let byteSeconds = memoryByteSecondsByComponent[componentKey] ?? 0
            if byteSeconds > 0 {
                averageByteSecondsByCategory[categoryID, default: 0] += byteSeconds
                averageByteSecondsByCategoryFamily[categoryFamilyKey, default: 0] += byteSeconds
            }

            componentDisplayNames[componentKey] = memoryLedgerComponentDisplayName(
                for: componentKey,
                familyKey: familyKey
            )
            familyIDsByCategory[categoryID, default: []].insert(familyKey)
            componentKeysByCategoryFamily[categoryFamilyKey, default: []].append(componentKey)
            familyDisplayNamesByCategoryFamily[categoryFamilyKey] = memoryLedgerFamilyDisplayName(
                for: familyKey
            )
        }

        for sample in componentSamples {
            var sampleBytesByCategory: [String: UInt64] = [:]
            var sampleBytesByCategoryFamily: [String: UInt64] = [:]

            for (componentKey, bytes) in sample where bytes > 0 {
                let category = retraceMemoryAttributionCategory(
                    for: componentKey,
                    componentCategoriesByKey: componentCategoriesByKey
                )
                let categoryID = category.rawValue
                let familyKey = memoryLedgerFamilyKey(for: componentKey)
                let categoryFamilyKey = retraceMemoryAttributionFamilyExpansionKey(
                    categoryID: categoryID,
                    familyID: familyKey
                )

                sampleBytesByCategory[categoryID] = saturatingAdd(
                    sampleBytesByCategory[categoryID] ?? 0,
                    bytes
                )
                sampleBytesByCategoryFamily[categoryFamilyKey] = saturatingAdd(
                    sampleBytesByCategoryFamily[categoryFamilyKey] ?? 0,
                    bytes
                )
            }

            for (categoryID, bytes) in sampleBytesByCategory {
                peakBytesByCategory[categoryID] = max(peakBytesByCategory[categoryID] ?? 0, bytes)
            }
            for (categoryFamilyKey, bytes) in sampleBytesByCategoryFamily {
                peakBytesByCategoryFamily[categoryFamilyKey] = max(
                    peakBytesByCategoryFamily[categoryFamilyKey] ?? 0,
                    bytes
                )
            }
        }

        for (categoryID, currentBytes) in currentBytesByCategory {
            peakBytesByCategory[categoryID] = max(peakBytesByCategory[categoryID] ?? 0, currentBytes)
        }
        for (categoryFamilyKey, currentBytes) in currentBytesByCategoryFamily {
            peakBytesByCategoryFamily[categoryFamilyKey] = max(
                peakBytesByCategoryFamily[categoryFamilyKey] ?? 0,
                currentBytes
            )
        }

        let totalCurrentCategoryBytes = currentBytesByCategory.values.reduce(UInt64(0), saturatingAdd)
        let safeTotalDuration = max(totalDuration, 0)
        let totalAverageCategoryBytesDouble = safeTotalDuration > 0
            ? averageByteSecondsByCategory.values.reduce(0, +) / totalDuration
            : 0

        let categoryRows = RetraceMemoryAttributionCategory.allCases.map { category in
            let categoryID = category.rawValue
            let averageBytesDouble = safeTotalDuration > 0
                ? (averageByteSecondsByCategory[categoryID] ?? 0) / totalDuration
                : Double(currentBytesByCategory[categoryID] ?? 0)
            let currentBytes = currentBytesByCategory[categoryID] ?? 0
            let averageBytes = doubleToUInt64(averageBytesDouble)
            let peakBytes = max(
                peakBytesByCategory[categoryID] ?? 0,
                currentBytes,
                averageBytes
            )
            let currentSharePercent = totalCurrentCategoryBytes > 0
                ? (Double(currentBytes) / Double(totalCurrentCategoryBytes)) * 100.0
                : 0
            let averageSharePercent = totalAverageCategoryBytesDouble > 0
                ? (averageBytesDouble / totalAverageCategoryBytesDouble) * 100.0
                : 0
            return ProcessMemoryRow(
                id: categoryID,
                name: category.displayName,
                currentBytes: currentBytes,
                averageBytes: averageBytes,
                peakBytes: peakBytes,
                currentSharePercent: currentSharePercent,
                averageSharePercent: averageSharePercent
            )
        }

        var categoryFamilies: [String: [ProcessMemoryRow]] = [:]
        var categoryFamilyComponents: [String: [ProcessMemoryRow]] = [:]

        for category in RetraceMemoryAttributionCategory.allCases {
            let categoryID = category.rawValue
            let familyIDs = familyIDsByCategory[categoryID] ?? []
            guard !familyIDs.isEmpty else {
                categoryFamilies[categoryID] = []
                continue
            }

            var familyCurrentBytes: [String: UInt64] = [:]
            var familyByteSeconds: [String: Double] = [:]
            var familyPeakBytes: [String: UInt64] = [:]
            var familyDisplayNames: [String: String] = [:]

            for familyID in familyIDs {
                let categoryFamilyKey = retraceMemoryAttributionFamilyExpansionKey(
                    categoryID: categoryID,
                    familyID: familyID
                )
                familyCurrentBytes[familyID] = currentBytesByCategoryFamily[categoryFamilyKey] ?? 0
                familyByteSeconds[familyID] = averageByteSecondsByCategoryFamily[categoryFamilyKey] ?? 0
                familyPeakBytes[familyID] = peakBytesByCategoryFamily[categoryFamilyKey] ?? 0
                familyDisplayNames[familyID] = familyDisplayNamesByCategoryFamily[categoryFamilyKey] ?? familyID
            }

            let familyRows = buildMemoryRows(
                currentBytesByKey: familyCurrentBytes,
                memoryByteSecondsByKey: familyByteSeconds,
                peakBytesByKey: familyPeakBytes,
                displayNamesByKey: familyDisplayNames,
                totalDuration: totalDuration
            )
            categoryFamilies[categoryID] = familyRows

            for familyRow in familyRows {
                let familyID = familyRow.id
                let categoryFamilyKey = retraceMemoryAttributionFamilyExpansionKey(
                    categoryID: categoryID,
                    familyID: familyID
                )
                let componentKeysForFamily = componentKeysByCategoryFamily[categoryFamilyKey] ?? []
                let familyComponentRows = buildMemoryRows(
                    currentBytesByKey: Dictionary(
                        uniqueKeysWithValues: componentKeysForFamily.map {
                            ($0, currentBytesByComponent[$0] ?? 0)
                        }
                    ),
                    memoryByteSecondsByKey: Dictionary(
                        uniqueKeysWithValues: componentKeysForFamily.map {
                            ($0, memoryByteSecondsByComponent[$0] ?? 0)
                        }
                    ),
                    peakBytesByKey: Dictionary(
                        uniqueKeysWithValues: componentKeysForFamily.map {
                            ($0, peakBytesByComponent[$0] ?? 0)
                        }
                    ),
                    displayNamesByKey: Dictionary(
                        uniqueKeysWithValues: componentKeysForFamily.map {
                            ($0, componentDisplayNames[$0] ?? $0)
                        }
                    ),
                    totalDuration: totalDuration
                )
                categoryFamilyComponents[categoryFamilyKey] = familyComponentRows
            }
        }

        return RetraceMemoryAttributionTree(
            categories: categoryRows,
            familiesByCategory: categoryFamilies,
            componentsByCategoryFamily: categoryFamilyComponents
        )
    }

    private static func retraceMemoryAttributionCategory(
        for componentKey: String,
        componentCategoriesByKey: [String: MemoryLedger.ComponentCategory]
    ) -> RetraceMemoryAttributionCategory {
        guard let category = componentCategoriesByKey[componentKey] else {
            return componentKey == unattributedMemoryComponentKey ? .unattributed : .explicit
        }
        switch category {
        case .explicit:
            return .explicit
        case .inferred:
            return .inferred
        case .unattributed:
            return .unattributed
        }
    }

    private static func doubleToUInt64(_ value: Double) -> UInt64 {
        guard value.isFinite else { return 0 }
        if value <= 0 { return 0 }
        if value >= Double(UInt64.max) { return UInt64.max }
        return UInt64(value.rounded())
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
