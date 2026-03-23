import Foundation
import Shared

enum VisionOCRMemoryLedger {
    private static let tracker = Tracker()
    private static let summaryIntervalSeconds: TimeInterval = 30
    private static let deferredProbeLock = NSLock()
    private static var deferredProbeGenerationByTag: [String: UInt64] = [:]

    struct RequestLease {
        let requestTag: String
        let requestBytes: Int64
        let privateHeapTag: String
        let privateHeapBytes: Int64
        let retainedHeapTag: String?
        let retainedHeapFunction: String?
        let retainedHeapFallbackBytes: Int64
        let retainedHeapDuration: TimeInterval
        let baselineFootprintBytes: UInt64?
    }

    static func begin(
        tag: String,
        function: String,
        reason: String,
        width: Int,
        height: Int,
        privateHeapTag: String,
        privateHeapFunction: String,
        retainedHeapTag: String? = nil,
        retainedHeapFunction: String? = nil,
        retainedHeapDuration: TimeInterval = 0
    ) -> RequestLease? {
        let requestBytes = estimatedRequestBytes(width: width, height: height)
        guard requestBytes > 0 else { return nil }
        let privateHeapBytes = estimatedPrivateHeapBytes(width: width, height: height)
        let retainedHeapFallbackBytes = estimatedRetainedHeapBytes(
            width: width,
            height: height,
            retainedHeapTag: retainedHeapTag
        )
        let baselineFootprintBytes = currentFootprintBytes()

        tracker.begin(
            tag: tag,
            function: function,
            reason: reason,
            bytes: requestBytes,
            kind: "vision-request",
            note: "estimated-native",
            emitSummary: false
        )
        tracker.begin(
            tag: privateHeapTag,
            function: privateHeapFunction,
            reason: reason,
            bytes: privateHeapBytes,
            kind: "vision-private-heap",
            note: "proxy-native"
        )

        return RequestLease(
            requestTag: tag,
            requestBytes: requestBytes,
            privateHeapTag: privateHeapTag,
            privateHeapBytes: privateHeapBytes,
            retainedHeapTag: retainedHeapTag,
            retainedHeapFunction: retainedHeapFunction,
            retainedHeapFallbackBytes: retainedHeapFallbackBytes,
            retainedHeapDuration: retainedHeapDuration,
            baselineFootprintBytes: baselineFootprintBytes
        )
    }

    static func end(lease: RequestLease?, reason: String) {
        end(lease: lease, reason: reason, retainedAdjustmentBytes: 0)
    }

    static func end(
        lease: RequestLease?,
        reason: String,
        retainedAdjustmentBytes: Int64,
        retainedMeasurementOverride: (bytes: Int64, note: String)? = nil
    ) {
        guard let lease else { return }

        tracker.end(
            tag: lease.requestTag,
            reason: reason,
            bytes: lease.requestBytes,
            emitSummary: false
        )
        tracker.end(
            tag: lease.privateHeapTag,
            reason: reason,
            bytes: lease.privateHeapBytes,
            emitSummary: false
        )

        if let retainedHeapTag = lease.retainedHeapTag,
           let retainedHeapFunction = lease.retainedHeapFunction,
           let retainedHeapMeasurement = retainedMeasurementOverride ?? retainedMeasurement(
                lease: lease,
                subtractingBytes: retainedAdjustmentBytes
           ) {
            tracker.setRetained(
                tag: retainedHeapTag,
                function: retainedHeapFunction,
                reason: reason,
                bytes: retainedHeapMeasurement.bytes,
                kind: "vision-retained-heap",
                note: retainedHeapMeasurement.note,
                delay: lease.retainedHeapDuration
            )
            return
        }

        tracker.emitSummary(reason: reason)
    }

    static func retainedMeasurement(
        lease: RequestLease?,
        subtractingBytes: Int64
    ) -> (bytes: Int64, note: String)? {
        guard let lease, lease.retainedHeapTag != nil else { return nil }
        return measuredRetainedHeap(
            baselineFootprintBytes: lease.baselineFootprintBytes,
            fallbackBytes: lease.retainedHeapFallbackBytes,
            subtractingBytes: subtractingBytes
        )
    }

    static func setObservedResidual(
        tag: String?,
        function: String?,
        reason: String,
        bytes: Int64,
        kind: String,
        note: String,
        delay: TimeInterval,
        autoClear: Bool = true,
        forceSummary: Bool = false,
        emitSummary: Bool = true
    ) {
        guard let tag, let function else { return }
        tracker.setRetained(
            tag: tag,
            function: function,
            reason: reason,
            bytes: max(0, bytes),
            kind: kind,
            note: note,
            delay: delay,
            autoClear: autoClear,
            forceSummary: forceSummary,
            emitSummary: emitSummary
        )
    }

    static func currentTrackedBytes(tag: String) -> Int64 {
        tracker.currentBytes(tag: tag)
    }

    static func scheduleObservedResidualProbe(
        tag: String?,
        function: String?,
        reason: String,
        baselineSnapshot: MemoryLedger.Snapshot,
        kind: String,
        note: String,
        delaySeconds: TimeInterval,
        holdSeconds: TimeInterval = 4,
        subtractingBytes: Int64 = 0,
        minimumBytes: Int64 = 0
    ) {
        guard let tag, let function, let generation = beginDeferredProbe(tag: tag) else { return }

        Task.detached(priority: .utility) {
            if delaySeconds > 0 {
                try? await Task.sleep(for: .seconds(delaySeconds))
            }

            let delayedSnapshot = await VisionOCR.synchronizedLedgerSnapshot()
            let observedBytes = measuredLedgerResidualBytes(
                before: baselineSnapshot,
                after: delayedSnapshot,
                subtractingBytes: subtractingBytes
            )
            let publishedBytes = max(observedBytes, minimumBytes)
            guard isCurrentDeferredProbe(tag: tag, generation: generation) else { return }

            setObservedResidual(
                tag: tag,
                function: function,
                reason: reason,
                bytes: publishedBytes,
                kind: kind,
                note: note,
                delay: holdSeconds,
                forceSummary: true
            )
        }
    }

    static func beginDeferredProbe(tag: String?) -> UInt64? {
        guard let tag else { return nil }
        deferredProbeLock.lock()
        let generation = (deferredProbeGenerationByTag[tag] ?? 0) + 1
        deferredProbeGenerationByTag[tag] = generation
        deferredProbeLock.unlock()
        return generation
    }

    static func isCurrentDeferredProbe(tag: String, generation: UInt64) -> Bool {
        deferredProbeLock.lock()
        let isCurrent = deferredProbeGenerationByTag[tag] == generation
        deferredProbeLock.unlock()
        return isCurrent
    }

    private static func measuredLedgerResidualBytes(
        before: MemoryLedger.Snapshot,
        after: MemoryLedger.Snapshot,
        subtractingBytes: Int64 = 0
    ) -> Int64 {
        let processDelta = after.footprintBytes > before.footprintBytes
            ? after.footprintBytes - before.footprintBytes
            : 0
        let trackedDelta = after.trackedMemoryBytes > before.trackedMemoryBytes
            ? after.trackedMemoryBytes - before.trackedMemoryBytes
            : 0
        let clampedTrackedDelta = UInt64(max(0, trackedDelta))

        guard processDelta > clampedTrackedDelta else { return 0 }
        let residualBytes = processDelta - clampedTrackedDelta
        let observedBytes = Int64(min(residualBytes, UInt64(Int64.max)))
        return max(0, observedBytes - max(0, subtractingBytes))
    }

    private static func estimatedRequestBytes(width: Int, height: Int) -> Int64 {
        guard width > 0, height > 0 else { return 0 }
        let frameBytes = Int64(width) * Int64(height) * 4
        return max(frameBytes * 2, 8 * 1_024 * 1_024)
    }

    private static func estimatedPrivateHeapBytes(width: Int, height: Int) -> Int64 {
        guard width > 0, height > 0 else { return 0 }
        let frameBytes = Int64(width) * Int64(height) * 4
        return max(frameBytes / 2, 16 * 1_024 * 1_024)
    }

    private static func estimatedRetainedHeapBytes(
        width: Int,
        height: Int,
        retainedHeapTag: String?
    ) -> Int64 {
        guard retainedHeapTag != nil, width > 0, height > 0 else { return 0 }
        let frameBytes = Int64(width) * Int64(height) * 4
        return max(frameBytes * 4, 96 * 1_024 * 1_024)
    }

    static func currentFootprintBytes() -> UInt64? {
        ProcessingMemoryDiagnostics.currentProcessMemorySnapshot()?.physFootprintBytes
    }

    private static func measuredRetainedHeap(
        baselineFootprintBytes: UInt64?,
        fallbackBytes: Int64,
        subtractingBytes: Int64
    ) -> (bytes: Int64, note: String) {
        guard let baselineFootprintBytes,
              let currentFootprintBytes = currentFootprintBytes() else {
            return (subtractKnownBytes(max(0, fallbackBytes), subtractingBytes), "estimated-fallback")
        }

        guard currentFootprintBytes > baselineFootprintBytes else {
            return (0, "observed-footprint-delta")
        }

        let deltaBytes = min(
            currentFootprintBytes - baselineFootprintBytes,
            UInt64(Int64.max)
        )
        return (
            subtractKnownBytes(Int64(deltaBytes), subtractingBytes),
            "observed-footprint-delta"
        )
    }

    static func measuredPhaseResidualBytes(
        baselineFootprintBytes: UInt64?,
        currentFootprintBytes: UInt64?,
        subtractingBytes: Int64 = 0
    ) -> Int64 {
        guard let baselineFootprintBytes,
              let currentFootprintBytes,
              currentFootprintBytes > baselineFootprintBytes else {
            return 0
        }

        let deltaBytes = min(
            currentFootprintBytes - baselineFootprintBytes,
            UInt64(Int64.max)
        )
        return subtractKnownBytes(Int64(deltaBytes), subtractingBytes)
    }

    static func estimatedResultsGraphBytes(
        observationCount: Int,
        retainedUTF16Units: Int,
        regionCount: Int
    ) -> Int64 {
        guard observationCount > 0 || retainedUTF16Units > 0 || regionCount > 0 else { return 0 }

        let observationBytes = Int64(max(0, observationCount)) * 384
        let stringBytes = Int64(max(0, retainedUTF16Units)) * 2
        let regionBytes = Int64(max(0, regionCount)) * 160
        return observationBytes + stringBytes + regionBytes
    }

    private static func subtractKnownBytes(_ totalBytes: Int64, _ subtractingBytes: Int64) -> Int64 {
        max(0, totalBytes - max(0, subtractingBytes))
    }

    private final class Tracker: @unchecked Sendable {
        private struct Entry {
            var bytes: Int64
            var count: Int
            var function: String
            var kind: String
            var note: String?
        }

        private let lock = NSLock()
        private var entriesByTag: [String: Entry] = [:]
        private var retainedGenerationByTag: [String: UInt64] = [:]

        func begin(
            tag: String,
            function: String,
            reason: String,
            bytes: Int64,
            kind: String,
            note: String?,
            emitSummary: Bool = true
        ) {
            lock.lock()
            var entry = entriesByTag[tag] ?? Entry(
                bytes: 0,
                count: 0,
                function: function,
                kind: kind,
                note: note
            )
            entry.bytes += max(0, bytes)
            entry.count += 1
            entry.function = function
            entry.kind = kind
            entry.note = note
            entriesByTag[tag] = entry
            lock.unlock()

            publish(tag: tag, entry: entry)
            if emitSummary {
                self.emitSummary(reason: reason)
            }
        }

        func end(tag: String, reason: String, bytes: Int64, emitSummary: Bool = true) {
            lock.lock()
            var entry = entriesByTag[tag] ?? Entry(
                bytes: 0,
                count: 0,
                function: "processing.ocr.full_frame",
                kind: "vision-request",
                note: "estimated-native"
            )
            entry.bytes = max(0, entry.bytes - max(0, bytes))
            entry.count = max(0, entry.count - 1)
            entriesByTag[tag] = entry
            lock.unlock()

            publish(tag: tag, entry: entry)
            if emitSummary {
                self.emitSummary(reason: reason)
            }
        }

        func setRetained(
            tag: String,
            function: String,
            reason: String,
            bytes: Int64,
            kind: String,
            note: String?,
            delay: TimeInterval,
            autoClear: Bool = true,
            forceSummary: Bool = false,
            emitSummary: Bool = true
        ) {
            let generation: UInt64

            lock.lock()
            var entry = entriesByTag[tag] ?? Entry(
                bytes: 0,
                count: 0,
                function: function,
                kind: kind,
                note: note
            )
            entry.bytes = max(0, bytes)
            entry.count = bytes > 0 ? 1 : 0
            entry.function = function
            entry.kind = kind
            entry.note = note
            entriesByTag[tag] = entry
            generation = (retainedGenerationByTag[tag] ?? 0) + 1
            retainedGenerationByTag[tag] = generation
            lock.unlock()

            publish(tag: tag, entry: entry)
            if emitSummary {
                self.emitSummary(reason: reason)
            }

            guard autoClear, bytes > 0 else { return }
            let boundedDelay = max(delay, 0)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + boundedDelay) { [self] in
                clearRetainedIfCurrent(tag: tag, generation: generation, reason: reason)
            }
        }

        private func clearRetainedIfCurrent(tag: String, generation: UInt64, reason: String) {
            lock.lock()
            guard retainedGenerationByTag[tag] == generation else {
                lock.unlock()
                return
            }

            var entry = entriesByTag[tag] ?? Entry(
                bytes: 0,
                count: 0,
                function: "processing.ocr.full_frame",
                kind: "vision-retained-heap",
                note: "proxy-retained"
            )
            entry.bytes = 0
            entry.count = 0
            entriesByTag[tag] = entry
            lock.unlock()

            publish(tag: tag, entry: entry)
            ProcessingExtractMemoryLedger.emitSummaryReconcilingHandoffIfNeeded(reason: reason)
        }

        func currentBytes(tag: String) -> Int64 {
            lock.lock()
            let bytes = entriesByTag[tag]?.bytes ?? 0
            lock.unlock()
            return bytes
        }

        func emitSummary(reason: String) {
            MemoryLedger.emitSummary(
                reason: reason,
                category: .processing,
                minIntervalSeconds: VisionOCRMemoryLedger.summaryIntervalSeconds
            )
        }

        private func publish(tag: String, entry: Entry) {
            MemoryLedger.set(
                tag: tag,
                bytes: entry.bytes,
                count: entry.count,
                unit: "requests",
                function: entry.function,
                kind: entry.kind,
                note: entry.note
            )
        }
    }
}
