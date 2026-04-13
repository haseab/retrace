import Foundation

/// Shared eviction policy for AVAsset-backed generator caches in Storage.
enum GeneratorCachePolicy {
    static let defaultCountLimit = 2
    static let idleRetentionSeconds: TimeInterval = 15

    static func keysToEvict(
        lastAccessByKey: [String: Date],
        referenceTime: Date,
        countLimit: Int = defaultCountLimit,
        idleRetentionSeconds: TimeInterval = idleRetentionSeconds
    ) -> Set<String> {
        let boundedCountLimit = max(1, countLimit)
        let idleCutoff = referenceTime.addingTimeInterval(-idleRetentionSeconds)

        let idleKeys = Set(
            lastAccessByKey
                .filter { $0.value < idleCutoff }
                .map(\.key)
        )

        let activeEntries = lastAccessByKey.filter { !idleKeys.contains($0.key) }
        guard activeEntries.count > boundedCountLimit else {
            return idleKeys
        }

        let overflowKeys = activeEntries
            .sorted { $0.value < $1.value }
            .prefix(activeEntries.count - boundedCountLimit)
            .map(\.key)

        return idleKeys.union(overflowKeys)
    }
}
