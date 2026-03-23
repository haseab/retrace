import Foundation
import Shared

struct VisionOCRResetSpec {
    let tag: String
    let function: String
    let kind: String
    let note: String
    let unit: String
}

extension VisionOCR {
    static let concurrentCaptureResidualTag = "concurrent.captureProcessing.observedResidual"
    static let concurrentCaptureResidualFunction = "concurrent.capture_processing"
    static let blindResidualHoldSeconds: TimeInterval = 0.8
    static let transientPhaseResidualHoldSeconds: TimeInterval = 0.8
    static let fullFrameBlindResidualHandoffSeconds: TimeInterval = 0.25

    static let fullFrameResetSpecs: [VisionOCRResetSpec] = [
        VisionOCRResetSpec(tag: "processing.ocr.fullFrameImageBridge", function: "processing.ocr.full_frame", kind: "cgimage-bridge", note: "observed-footprint-delta", unit: "requests"),
        VisionOCRResetSpec(tag: "processing.ocr.fullFrameOuterResidual", function: "processing.ocr.full_frame", kind: "ocr-blind-residual", note: "epoch-arbited-current-unattributed", unit: "requests"),
        VisionOCRResetSpec(tag: "processing.ocr.fullFrameRequestSetup", function: "processing.ocr.full_frame", kind: "vision-request-setup", note: "observed-footprint-delta", unit: "requests"),
        VisionOCRResetSpec(tag: "processing.ocr.fullFrameObservationBridge", function: "processing.ocr.full_frame", kind: "vision-observation-bridge", note: "observed-footprint-delta", unit: "requests"),
        VisionOCRResetSpec(tag: "processing.ocr.fullFrameRuntimeResidual", function: "processing.ocr.full_frame", kind: "vision-runtime-residual", note: "observed-footprint-delta", unit: "requests"),
        VisionOCRResetSpec(tag: "processing.ocr.fullFrameResultsGraph", function: "processing.ocr.full_frame", kind: "ocr-results-graph", note: "estimated-results", unit: "requests"),
        VisionOCRResetSpec(tag: "processing.ocr.fullFrameOCRResultRetention", function: "processing.ocr.full_frame", kind: "full-frame-ocr-results", note: "estimated-results-payload", unit: "requests"),
        VisionOCRResetSpec(tag: "processing.ocr.fullFrameOCRCallResidual", function: "processing.ocr.full_frame", kind: "full-frame-ocr-call-residual", note: "observed-minus-results-payload-net-blind-residual", unit: "requests"),
        VisionOCRResetSpec(tag: "processing.ocr.fullFrameMaterializationResidual", function: "processing.ocr.full_frame", kind: "ocr-materialization-residual", note: "observed-footprint-delta", unit: "requests"),
        VisionOCRResetSpec(tag: "processing.ocr.fullFrameRetainedHeap", function: "processing.ocr.full_frame", kind: "vision-retained-heap", note: "observed-footprint-delta", unit: "requests"),
        VisionOCRResetSpec(tag: "processing.ocr.fullFrameVisionRequest", function: "processing.ocr.full_frame", kind: "vision-request", note: "estimated-native", unit: "requests"),
        VisionOCRResetSpec(tag: "processing.ocr.fullFramePrivateHeap", function: "processing.ocr.full_frame", kind: "vision-private-heap", note: "proxy-native", unit: "requests")
    ]

    static let regionResetSpecs: [VisionOCRResetSpec] = [
        VisionOCRResetSpec(tag: "processing.ocr.regionImageBridge", function: "processing.ocr.region_reocr", kind: "cgimage-bridge", note: "observed-footprint-delta", unit: "requests"),
        VisionOCRResetSpec(tag: "processing.ocr.regionBlindResidual", function: "processing.ocr.region_reocr", kind: "ocr-blind-residual", note: "epoch-arbited-current-unattributed", unit: "requests"),
        VisionOCRResetSpec(tag: "processing.ocr.regionRequestSetup", function: "processing.ocr.region_reocr", kind: "vision-request-setup", note: "observed-footprint-delta", unit: "requests"),
        VisionOCRResetSpec(tag: "processing.ocr.regionObservationBridge", function: "processing.ocr.region_reocr", kind: "vision-observation-bridge", note: "observed-footprint-delta", unit: "requests"),
        VisionOCRResetSpec(tag: "processing.ocr.regionRuntimeResidual", function: "processing.ocr.region_reocr", kind: "vision-runtime-residual", note: "observed-footprint-delta", unit: "requests"),
        VisionOCRResetSpec(tag: "processing.ocr.regionResultsGraph", function: "processing.ocr.region_reocr", kind: "ocr-results-graph", note: "estimated-results", unit: "requests"),
        VisionOCRResetSpec(tag: "processing.ocr.regionMaterializationResidual", function: "processing.ocr.region_reocr", kind: "ocr-materialization-residual", note: "observed-footprint-delta", unit: "requests"),
        VisionOCRResetSpec(tag: "processing.ocr.regionRetainedHeap", function: "processing.ocr.region_reocr", kind: "vision-retained-heap", note: "observed-footprint-delta", unit: "requests"),
        VisionOCRResetSpec(tag: "processing.ocr.regionVisionRequest", function: "processing.ocr.region_reocr", kind: "vision-request", note: "estimated-native", unit: "requests"),
        VisionOCRResetSpec(tag: "processing.ocr.regionPrivateHeap", function: "processing.ocr.region_reocr", kind: "vision-private-heap", note: "proxy-native", unit: "requests"),
        VisionOCRResetSpec(tag: "processing.ocr.regionChangeDetection", function: "processing.ocr.region_reocr", kind: "region-change-detection", note: "observed-plus-buffer", unit: "requests"),
        VisionOCRResetSpec(tag: "processing.ocr.regionCachePartition", function: "processing.ocr.region_reocr", kind: "region-cache-partition", note: "observed-plus-buffer", unit: "requests"),
        VisionOCRResetSpec(tag: "processing.ocr.regionTileExpansion", function: "processing.ocr.region_reocr", kind: "region-tile-expansion", note: "observed-plus-buffer", unit: "requests"),
        VisionOCRResetSpec(tag: "processing.ocr.regionOCRResultRetention", function: "processing.ocr.region_reocr", kind: "region-ocr-results", note: "estimated-results-payload", unit: "requests"),
        VisionOCRResetSpec(tag: "processing.ocr.regionOCRCallResidual", function: "processing.ocr.region_reocr", kind: "region-ocr-call-residual", note: "observed-minus-results-payload-net-blind-residual", unit: "requests"),
        VisionOCRResetSpec(tag: "processing.ocr.regionReturnResidual", function: "processing.ocr.region_reocr", kind: "region-return-residual", note: "epoch-arbited-current-unattributed-after-cache-refresh", unit: "requests"),
        VisionOCRResetSpec(tag: "processing.ocr.regionMergeScratch", function: "processing.ocr.region_reocr", kind: "region-merge-scratch", note: "observed-plus-buffer", unit: "requests"),
        VisionOCRResetSpec(tag: "processing.ocr.regionCacheRefresh", function: "processing.ocr.region_reocr", kind: "region-cache-refresh", note: "observed-plus-buffer", unit: "requests"),
        VisionOCRResetSpec(tag: "processing.ocr.regionRequestShortTail", function: "processing.ocr.region_reocr", kind: "region-request-short-tail", note: "observed-short-tail-residual", unit: "requests"),
        VisionOCRResetSpec(tag: "processing.ocr.regionRequestTail", function: "processing.ocr.region_reocr", kind: "region-request-tail", note: "observed-long-tail-residual", unit: "requests"),
        VisionOCRResetSpec(tag: "processing.ocr.regionCacheShortTail", function: "processing.ocr.region_reocr", kind: "region-cache-short-tail", note: "observed-short-tail-residual-net-request-tail", unit: "requests"),
        VisionOCRResetSpec(tag: "processing.ocr.regionCacheTail", function: "processing.ocr.region_reocr", kind: "region-cache-tail", note: "observed-long-tail-residual-net-request-tail", unit: "requests")
    ]

    static func measuredLedgerResidualBytes(
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

    static func estimatedTextRegionBufferBytes(_ regions: [TextRegion]) -> Int64 {
        guard !regions.isEmpty else { return 0 }
        return regions.reduce(into: Int64(0)) { runningTotal, region in
            runningTotal += Int64(MemoryLayout<TextRegion>.stride)
            runningTotal += estimatedStringStorageBytes(region.text)
        }
    }

    static func estimatedTileBufferBytes(_ tiles: [TileInfo]) -> Int64 {
        Int64(tiles.count) * Int64(MemoryLayout<TileInfo>.stride)
    }

    static func publishPhaseResidual(
        tag: String,
        function: String,
        reason: String,
        kind: String,
        note: String,
        before: MemoryLedger.Snapshot,
        after: MemoryLedger.Snapshot,
        structuralBytes: Int64 = 0,
        delay: TimeInterval = 4
    ) {
        let observedBytes = measuredLedgerResidualBytes(before: before, after: after)
        VisionOCRMemoryLedger.setObservedResidual(
            tag: tag,
            function: function,
            reason: reason,
            bytes: max(observedBytes, max(0, structuralBytes)),
            kind: kind,
            note: note,
            delay: delay,
            forceSummary: true
        )
    }

    static func estimatedStringStorageBytes(_ value: String) -> Int64 {
        Int64(value.utf16.count * 2 + 24)
    }

    static func currentUnattributedBytes(_ snapshot: MemoryLedger.Snapshot) -> Int64 {
        Int64(min(snapshot.unattributedBytes, UInt64(Int64.max)))
    }

    static func netNewUnattributedBytes(
        baselineUnattributedBytes: Int64,
        currentUnattributedBytes: Int64
    ) -> Int64 {
        max(0, max(0, currentUnattributedBytes) - max(0, baselineUnattributedBytes))
    }

    static func netNewUnattributedBytes(
        baselineSnapshot: MemoryLedger.Snapshot,
        currentSnapshot: MemoryLedger.Snapshot
    ) -> Int64 {
        netNewUnattributedBytes(
            baselineUnattributedBytes: currentUnattributedBytes(baselineSnapshot),
            currentUnattributedBytes: currentUnattributedBytes(currentSnapshot)
        )
    }

    static func synchronizedLedgerSnapshot() async -> MemoryLedger.Snapshot {
        let processSnapshot = ProcessingMemoryDiagnostics.currentProcessMemorySnapshot()
        MemoryLedger.setProcessSnapshot(
            footprintBytes: processSnapshot?.physFootprintBytes,
            residentBytes: processSnapshot?.residentBytes,
            internalBytes: processSnapshot?.internalBytes,
            compressedBytes: processSnapshot?.compressedBytes
        )
        return await MemoryLedger.snapshot(waitForPendingUpdates: true)
    }

    static func resetRequestScopedTags(_ specs: [VisionOCRResetSpec]) {
        for spec in specs {
            MemoryLedger.set(
                tag: spec.tag,
                bytes: 0,
                count: 0,
                unit: spec.unit,
                function: spec.function,
                kind: spec.kind,
                note: spec.note
            )
        }
    }

    static func clearFullFrameBlindResidualForHandoff(reason: String) {
        VisionOCRMemoryLedger.setObservedResidual(
            tag: "processing.ocr.fullFrameOuterResidual",
            function: "processing.ocr.full_frame",
            reason: reason,
            bytes: 0,
            kind: "ocr-blind-residual",
            note: "epoch-arbited-current-unattributed-handoff-cleared",
            delay: 0,
            autoClear: false,
            emitSummary: false
        )
    }

    static func clearRegionBlindResidualForHandoff(reason: String) {
        VisionOCRMemoryLedger.setObservedResidual(
            tag: "processing.ocr.regionBlindResidual",
            function: "processing.ocr.region_reocr",
            reason: reason,
            bytes: 0,
            kind: "ocr-blind-residual",
            note: "epoch-arbited-current-unattributed-handoff-cleared",
            delay: 0,
            autoClear: false,
            emitSummary: false
        )
    }

    static func currentFullFrameBlindResidualBytes() -> Int64 {
        max(0, VisionOCRMemoryLedger.currentTrackedBytes(tag: "processing.ocr.fullFrameOuterResidual"))
    }

    static func currentRegionBlindResidualBytes() -> Int64 {
        max(0, VisionOCRMemoryLedger.currentTrackedBytes(tag: "processing.ocr.regionBlindResidual"))
    }

    static func currentRegionReturnResidualBytes() -> Int64 {
        max(0, VisionOCRMemoryLedger.currentTrackedBytes(tag: "processing.ocr.regionReturnResidual"))
    }

    static func clearRegionReturnResidualForHandoff(reason: String) {
        VisionOCRMemoryLedger.setObservedResidual(
            tag: "processing.ocr.regionReturnResidual",
            function: "processing.ocr.region_reocr",
            reason: reason,
            bytes: 0,
            kind: "region-return-residual",
            note: "epoch-arbited-current-unattributed-after-cache-refresh-handoff-cleared",
            delay: 0,
            autoClear: false,
            emitSummary: false
        )
    }

    static func currentExtractResidualExclusionBytes() -> Int64 {
        let exclusionTags = [
            "processing.ocr.fullFrameOuterResidual",
            "processing.ocr.fullFrameOCRCallResidual",
            "processing.ocr.regionBlindResidual",
            "processing.ocr.regionOCRCallResidual",
            "processing.ocr.regionReturnResidual",
            "processing.ocr.regionRequestShortTail",
            "processing.ocr.regionRequestTail",
            "processing.ocr.regionCacheShortTail",
            "processing.ocr.regionCacheTail",
            Self.concurrentCaptureResidualTag
        ]

        return exclusionTags.reduce(into: Int64(0)) { total, tag in
            total += max(0, VisionOCRMemoryLedger.currentTrackedBytes(tag: tag))
        }
    }

    static func seedFullFrameBlindResidualForTesting(bytes: Int64, reason: String) {
        VisionOCRMemoryLedger.setObservedResidual(
            tag: "processing.ocr.fullFrameOuterResidual",
            function: "processing.ocr.full_frame",
            reason: reason,
            bytes: bytes,
            kind: "ocr-blind-residual",
            note: "test-seed",
            delay: 0,
            autoClear: false,
            emitSummary: false
        )
    }

    static func seedRegionBlindResidualForTesting(bytes: Int64, reason: String) {
        VisionOCRMemoryLedger.setObservedResidual(
            tag: "processing.ocr.regionBlindResidual",
            function: "processing.ocr.region_reocr",
            reason: reason,
            bytes: bytes,
            kind: "ocr-blind-residual",
            note: "test-seed",
            delay: 0,
            autoClear: false,
            emitSummary: false
        )
    }

    static func handoffCurrentFullFrameBlindResidualToExtract(reason: String) {
        let fullFrameBlindResidualBytes = currentFullFrameBlindResidualBytes()
        guard fullFrameBlindResidualBytes > 0 else { return }

        ProcessingExtractMemoryLedger.absorbObservedResidualBytesIntoHandoff(
            reason: reason,
            observedResidualBytes: fullFrameBlindResidualBytes,
            note: "prior-handoff-plus-full-frame-blind-residual"
        )
        clearFullFrameBlindResidualForHandoff(reason: reason)
    }

    static func handoffRegionBlindResidualToExtract(
        reason: String,
        blindResidualBytes: Int64,
        subtractingReturnResidualBytes: Int64
    ) {
        let netBlindResidualBytes = max(
            0,
            max(0, blindResidualBytes) - max(0, subtractingReturnResidualBytes)
        )
        if netBlindResidualBytes > 0 {
            ProcessingExtractMemoryLedger.absorbObservedResidualBytesIntoHandoff(
                reason: reason,
                observedResidualBytes: netBlindResidualBytes,
                note: "prior-handoff-plus-region-blind-residual"
            )
        }
        clearRegionBlindResidualForHandoff(reason: reason)
    }

    static func publishArbitedResidualClaim(
        claim: MemoryLedger.ResidualClaim,
        ownerTag: String?,
        ownerFunction: String?,
        ownerKind: String,
        ownerNote: String,
        delay: TimeInterval,
        reason: String
    ) {
        switch claim.target {
        case .owner:
            guard let ownerTag, let ownerFunction else { return }
            VisionOCRMemoryLedger.setObservedResidual(
                tag: ownerTag,
                function: ownerFunction,
                reason: reason,
                bytes: claim.bytes,
                kind: ownerKind,
                note: ownerNote,
                delay: delay,
                forceSummary: true
            )
        case .concurrent:
            VisionOCRMemoryLedger.setObservedResidual(
                tag: Self.concurrentCaptureResidualTag,
                function: Self.concurrentCaptureResidualFunction,
                reason: reason,
                bytes: claim.bytes,
                kind: "concurrent-capture-processing-residual",
                note: "epoch-arbited-current-unattributed",
                delay: delay,
                forceSummary: true
            )
        case .none:
            break
        }
    }

    static func publishBlindResidualClaim(
        claim: MemoryLedger.ResidualClaim,
        ownerTag: String?,
        ownerFunction: String?,
        reason: String
    ) {
        publishArbitedResidualClaim(
            claim: claim,
            ownerTag: ownerTag,
            ownerFunction: ownerFunction,
            ownerKind: "ocr-blind-residual",
            ownerNote: "epoch-arbited-current-unattributed",
            delay: Self.blindResidualHoldSeconds,
            reason: reason
        )
    }
}
