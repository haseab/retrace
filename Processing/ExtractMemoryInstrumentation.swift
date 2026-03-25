import Foundation
import Shared

enum ProcessingExtractMemoryLedger {
    private static let tracker = Tracker()
    private static let summaryIntervalSeconds: TimeInterval = 30
    private static let deferredProbeLock = NSLock()
    private static var deferredProbeGenerationByTag: [String: UInt64] = [:]
    private static let processSnapshotOverrideLock = NSLock()
    private static var processSnapshotOverrideForTesting: ProcessingProcessMemorySnapshot?
    private static let stageResidualExclusionLock = NSLock()
    private static var hiddenStageResidualExclusionBytesByTag: [String: Int64] = [:]
    static let observedResidualHandoffSeconds: TimeInterval = 0.8
    private static let settledObservedResidualDelaySeconds: TimeInterval = 0.75
    private static let settledObservedResidualHoldSeconds: TimeInterval = 1.5
    private static let extractResidualEpochConcurrentFunctions = [
        "capture.screen_capture",
        "processing.ocr.region_reocr",
        "processing.ocr.full_frame"
    ]
    private struct ResetSpec {
        let tag: String
        let function: String
        let kind: String
        let note: String
    }

    private static let requestScopedResetSpecs: [ResetSpec] = [
        ResetSpec(
            tag: "processing.extract.ocrRegionPayload",
            function: "processing.extract_text.ocr_payload",
            kind: "extract-ocr-region-payload",
            note: "estimated-result-graph"
        ),
        ResetSpec(
            tag: "processing.extract.ocrCallResidual",
            function: "processing.extract_text.ocr_call",
            kind: "extract-ocr-call-residual",
            note: "observed-footprint-delta-minus-payload"
        ),
        ResetSpec(
            tag: "processing.extract.ocrCallObservedResidual",
            function: "processing.extract_text.ocr_call",
            kind: "extract-ocr-call-observed-residual",
            note: "epoch-arbited-current-unattributed-after-ocr-call"
        ),
        ResetSpec(
            tag: "processing.extract.ocrReturnResidual",
            function: "processing.extract_text.ocr_tail",
            kind: "extract-ocr-return-residual",
            note: "observed-delayed-residual-after-ocr-call"
        ),
        ResetSpec(
            tag: "processing.extract.outputPayload",
            function: "processing.extract_text.output_payload",
            kind: "extract-output-payload",
            note: "estimated-result-graph"
        ),
        ResetSpec(
            tag: "processing.extract.buildResidual",
            function: "processing.extract_text.build_residual",
            kind: "extract-build-residual",
            note: "observed-build-residual-net-output-payload"
        ),
        ResetSpec(
            tag: "processing.extract.totalResidual",
            function: "processing.extract_text.residual",
            kind: "extract-total-residual",
            note: "observed-extract-remainder"
        ),
        ResetSpec(
            tag: "processing.extract.totalObservedResidual",
            function: "processing.extract_text.residual",
            kind: "extract-total-observed-residual",
            note: "epoch-arbited-current-unattributed-after-extract"
        )
    ]

    static func beginExtractCycle() {
        tracker.reset(tags: requestScopedResetSpecs)
        clearHiddenStageResidualExclusionBytes()
    }

    static func measuredResidualBytes(
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

    static func currentUnattributedBytes(_ snapshot: MemoryLedger.Snapshot) -> Int64 {
        Int64(min(snapshot.unattributedBytes, UInt64(Int64.max)))
    }

    static func currentTrackedBytes(tag: String) -> Int64 {
        tracker.currentBytes(tag: tag)
    }

    static func currentHandoffObservedResidualBytes() -> Int64 {
        max(0, tracker.currentBytes(tag: "processing.extract.handoffObservedResidual"))
    }

    static func beginExtractResidualEpoch() async -> MemoryLedger.ResidualEpoch {
        await MemoryLedger.beginResidualEpoch(
            ownerFunction: "processing.extract_text",
            candidateConcurrentFunctions: extractResidualEpochConcurrentFunctions
        )
    }

    static func ownedObservedResidualBytes(from claim: MemoryLedger.ResidualClaim) -> Int64 {
        guard claim.target == .owner else { return 0 }
        return max(0, claim.bytes)
    }

    static func shouldReconcileHandoffBeforeSummary(reason: String) -> Bool {
        reason.hasPrefix("processing.ocr.") || reason.hasPrefix("processing.extract_text.")
    }

    static func emitSummaryReconcilingHandoffIfNeeded(
        reason: String,
        force: Bool = false
    ) {
        guard shouldReconcileHandoffBeforeSummary(reason: reason) else {
            MemoryLedger.emitSummary(
                reason: reason,
                category: .processing,
                minIntervalSeconds: summaryIntervalSeconds,
                force: force
            )
            return
        }

        _ = Task(priority: .utility) {
            await reconcileHandoffObservedResidualToCurrentFootprint(reason: reason)
            MemoryLedger.emitSummary(
                reason: reason,
                category: .processing,
                minIntervalSeconds: summaryIntervalSeconds,
                force: force
            )
        }
    }

    static func cappedHandoffObservedResidualBytes(
        currentHandoffObservedBytes: Int64,
        settledTrackedBytes: Int64,
        settledFootprintBytes: Int64
    ) -> Int64 {
        guard currentHandoffObservedBytes > 0 else { return 0 }
        let otherTrackedBytes = max(0, settledTrackedBytes - currentHandoffObservedBytes)
        return max(
            0,
            min(currentHandoffObservedBytes, settledFootprintBytes - otherTrackedBytes)
        )
    }

    private static func sumPositiveBytes(_ values: Int64...) -> Int64 {
        values.reduce(into: Int64(0)) { total, value in
            let positiveValue = max(0, value)
            let (nextTotal, overflowed) = total.addingReportingOverflow(positiveValue)
            total = overflowed ? Int64.max : nextTotal
        }
    }

    static func mergedHandoffObservedResidualBytes(
        currentHandoffObservedBytes: Int64,
        incomingObservedResidualBytes: Int64,
        activeOCRFrameCount: Int
    ) -> Int64 {
        let currentHandoffObservedBytes = max(0, currentHandoffObservedBytes)
        let incomingObservedResidualBytes = max(0, incomingObservedResidualBytes)

        guard currentHandoffObservedBytes > 0 else { return incomingObservedResidualBytes }
        guard incomingObservedResidualBytes > 0 else { return currentHandoffObservedBytes }
        guard activeOCRFrameCount > 1 else {
            return sumPositiveBytes(currentHandoffObservedBytes, incomingObservedResidualBytes)
        }

        return max(currentHandoffObservedBytes, incomingObservedResidualBytes)
    }

    static func concurrentSafeHandoffNote(
        _ note: String,
        activeOCRFrameCount: Int
    ) -> String {
        guard activeOCRFrameCount > 1 else { return note }
        return note.replacingOccurrences(
            of: "prior-handoff-plus",
            with: "max-prior-handoff-or"
        )
    }

    private static func clearHandoffSourceTag(_ tag: String, reason: String) {
        switch tag {
        case "processing.extract.ocrCallResidual":
            tracker.clear(
                tag: tag,
                function: "processing.extract_text.ocr_call",
                kind: "extract-ocr-call-residual",
                note: "handoff-cleared",
                reason: reason,
                emitSummary: false
            )
        case "processing.extract.ocrCallObservedResidual":
            tracker.clear(
                tag: tag,
                function: "processing.extract_text.ocr_call",
                kind: "extract-ocr-call-observed-residual",
                note: "handoff-cleared",
                reason: reason,
                emitSummary: false
            )
        case "processing.extract.totalResidual":
            tracker.clear(
                tag: tag,
                function: "processing.extract_text.residual",
                kind: "extract-total-residual",
                note: "handoff-cleared",
                reason: reason,
                emitSummary: false
            )
        case "processing.extract.totalObservedResidual":
            tracker.clear(
                tag: tag,
                function: "processing.extract_text.residual",
                kind: "extract-total-observed-residual",
                note: "handoff-cleared",
                reason: reason,
                emitSummary: false
            )
        case "processing.extract.ocrReturnResidual":
            tracker.clear(
                tag: tag,
                function: "processing.extract_text.ocr_tail",
                kind: "extract-ocr-return-residual",
                note: "handoff-cleared",
                reason: reason,
                emitSummary: false
            )
        default:
            break
        }
    }

    static func setObservedResidualFromClaim(
        claim: MemoryLedger.ResidualClaim,
        tag: String,
        function: String,
        kind: String,
        note: String,
        reason: String
    ) {
        let ownedBytes = ownedObservedResidualBytes(from: claim)
        if ownedBytes > 0 {
            setResidual(
                tag: tag,
                function: function,
                kind: kind,
                note: note,
                bytes: ownedBytes,
                reason: reason,
                delay: observedResidualHandoffSeconds,
                emitSummary: false
            )
        } else {
            tracker.clear(
                tag: tag,
                function: function,
                kind: kind,
                note: claim.target == .concurrent
                    ? "concurrent-ocr-not-owned"
                    : "claim-cleared-before-publish",
                reason: reason,
                emitSummary: false
            )
        }
    }

    static func absorbCurrentExtractResidualsIntoHandoff(
        reason: String,
        sourceTags: [String],
        note: String
    ) {
        let currentHandoffObservedBytes = currentHandoffObservedResidualBytes()
        let activeOCRFrameCount = OCRStageMemoryLedger.currentActiveFrameCount()
        let absorbedResidualBytes = sourceTags.reduce(into: Int64(0)) { total, tag in
            total = sumPositiveBytes(total, max(0, tracker.currentBytes(tag: tag)))
        }

        guard absorbedResidualBytes > 0 else { return }

        tracker.setRetained(
            tag: "processing.extract.handoffObservedResidual",
            function: "processing.extract_text.handoff",
            kind: "extract-handoff-observed-residual",
            note: concurrentSafeHandoffNote(note, activeOCRFrameCount: activeOCRFrameCount),
            bytes: mergedHandoffObservedResidualBytes(
                currentHandoffObservedBytes: currentHandoffObservedBytes,
                incomingObservedResidualBytes: absorbedResidualBytes,
                activeOCRFrameCount: activeOCRFrameCount
            ),
            reason: reason,
            delay: settledObservedResidualHoldSeconds,
            forceSummary: false,
            emitSummary: false,
            autoClear: false
        )
        scheduleSettledHandoffObservedResidual(reason: reason)

        for tag in sourceTags {
            clearHandoffSourceTag(tag, reason: reason)
        }
    }

    static func sweepableUnattributedBytesForHandoff(
        currentUnattributedBytes: Int64,
        activeOCRFrameCount: Int,
        allowedActiveOCRFrameCount: Int
    ) -> Int64 {
        guard activeOCRFrameCount <= allowedActiveOCRFrameCount else { return 0 }
        return max(0, currentUnattributedBytes)
    }

    static func currentStageResidualExclusionBytes() -> Int64 {
        let exclusionTags = [
            "processing.extract.ocrCallResidual",
            "processing.extract.ocrCallObservedResidual",
            "processing.extract.totalResidual",
            "processing.extract.totalObservedResidual",
            "processing.extract.handoffObservedResidual"
        ]

        let publishedExclusionBytes = exclusionTags.reduce(into: Int64(0)) { total, tag in
            total += max(0, currentTrackedBytes(tag: tag))
        }

        return publishedExclusionBytes + currentHiddenStageResidualExclusionBytes()
    }

    static func synchronizedLedgerSnapshot() async -> MemoryLedger.Snapshot {
        let processSnapshot = currentProcessMemorySnapshotForLedger()
        MemoryLedger.setProcessSnapshot(
            footprintBytes: processSnapshot?.physFootprintBytes,
            residentBytes: processSnapshot?.residentBytes,
            internalBytes: processSnapshot?.internalBytes,
            compressedBytes: processSnapshot?.compressedBytes
        )
        return await MemoryLedger.snapshot(waitForPendingUpdates: true)
    }

    private static func currentProcessMemorySnapshotForLedger() -> ProcessingProcessMemorySnapshot? {
        processSnapshotOverrideLock.lock()
        let overrideSnapshot = processSnapshotOverrideForTesting
        processSnapshotOverrideLock.unlock()
        return overrideSnapshot ?? ProcessingMemoryDiagnostics.currentProcessMemorySnapshot()
    }

    static func setResidual(
        tag: String,
        function: String,
        kind: String,
        note: String,
        bytes: Int64,
        reason: String,
        delay: TimeInterval = 4,
        forceSummary: Bool = true,
        emitSummary: Bool = true,
        autoClear: Bool = true
    ) {
        tracker.setRetained(
            tag: tag,
            function: function,
            kind: kind,
            note: note,
            bytes: bytes,
            reason: reason,
            delay: delay,
            forceSummary: forceSummary,
            emitSummary: emitSummary,
            autoClear: autoClear
        )
    }

    static func clearOCRCallMeasuredResidual(reason: String) {
        let carriedBytes = max(0, tracker.currentBytes(tag: "processing.extract.ocrCallResidual"))
        setHiddenStageResidualExclusionBytes(
            tag: "processing.extract.ocrCallResidual",
            bytes: carriedBytes
        )
        tracker.clear(
            tag: "processing.extract.ocrCallResidual",
            function: "processing.extract_text.ocr_call",
            kind: "extract-ocr-call-residual",
            note: "cleared-after-ocr-call-summary",
            reason: reason,
            emitSummary: false
        )
    }

    static func clearTotalMeasuredResidual(reason: String) {
        let carriedBytes = max(0, tracker.currentBytes(tag: "processing.extract.totalResidual"))
        setHiddenStageResidualExclusionBytes(
            tag: "processing.extract.totalResidual",
            bytes: carriedBytes
        )
        tracker.clear(
            tag: "processing.extract.totalResidual",
            function: "processing.extract_text.residual",
            kind: "extract-total-residual",
            note: "cleared-before-extract-summary",
            reason: reason,
            emitSummary: false
        )
    }

    static func resetStageResidualExclusionCarryForTesting() {
        clearHiddenStageResidualExclusionBytes()
    }

    static func setProcessSnapshotOverrideForTesting(_ snapshot: ProcessingProcessMemorySnapshot?) {
        processSnapshotOverrideLock.lock()
        processSnapshotOverrideForTesting = snapshot
        processSnapshotOverrideLock.unlock()
    }

    static func settleObservedResidualAtStageRelease(
        snapshot: MemoryLedger.Snapshot,
        reason: String
    ) -> Int64 {
        let currentHandoffObservedBytes = currentHandoffObservedResidualBytes()
        let currentObservedResidualBytes = currentUnattributedBytes(snapshot)
        let activeOCRFrameCount = OCRStageMemoryLedger.currentActiveFrameCount()
        let sweepableObservedResidualBytes = sweepableUnattributedBytesForHandoff(
            currentUnattributedBytes: currentObservedResidualBytes,
            activeOCRFrameCount: activeOCRFrameCount,
            allowedActiveOCRFrameCount: 0
        )
        let settledObservedResidualBytes = mergedHandoffObservedResidualBytes(
            currentHandoffObservedBytes: currentHandoffObservedBytes,
            incomingObservedResidualBytes: sweepableObservedResidualBytes,
            activeOCRFrameCount: activeOCRFrameCount
        )
        let suppressedConcurrentObservedResidual =
            currentObservedResidualBytes > 0 &&
            sweepableObservedResidualBytes == 0 &&
            activeOCRFrameCount > 0

        if settledObservedResidualBytes > 0 {
            tracker.setRetained(
                tag: "processing.extract.handoffObservedResidual",
                function: "processing.extract_text.handoff",
                kind: "extract-handoff-observed-residual",
                note: concurrentSafeHandoffNote(
                    suppressedConcurrentObservedResidual
                    ? "prior-handoff-only-after-stage-release-concurrent-ocr-guard"
                    : "prior-handoff-plus-current-unattributed-after-stage-release",
                    activeOCRFrameCount: activeOCRFrameCount
                ),
                bytes: settledObservedResidualBytes,
                reason: reason,
                delay: settledObservedResidualHoldSeconds,
                forceSummary: false,
                emitSummary: false,
                autoClear: false
            )
        } else {
            tracker.clear(
                tag: "processing.extract.handoffObservedResidual",
                function: "processing.extract_text.handoff",
                kind: "extract-handoff-observed-residual",
                note: "cleared-after-stage-release",
                reason: reason,
                emitSummary: false
            )
        }

        scheduleSettledHandoffObservedResidual(reason: reason)
        return max(0, settledObservedResidualBytes - currentHandoffObservedBytes)
    }

    static func clearObservedResidualsForHandoff(reason: String) async {
        let regionReturnResidualBytes = VisionOCR.currentRegionReturnResidualBytes()
        let fullFrameBlindResidualBytes = VisionOCR.currentFullFrameBlindResidualBytes()
        let regionBlindResidualBytes = VisionOCR.currentRegionBlindResidualBytes()
        let currentHandoffObservedBytes = currentHandoffObservedResidualBytes()
        let activeObservedResidualBytes = sumPositiveBytes(
            max(0, fullFrameBlindResidualBytes),
            max(0, regionBlindResidualBytes),
            max(0, regionReturnResidualBytes),
            max(0, tracker.currentBytes(tag: "processing.extract.ocrCallObservedResidual")),
            max(0, tracker.currentBytes(tag: "processing.extract.totalObservedResidual")),
            max(0, tracker.currentBytes(tag: "processing.extract.ocrReturnResidual"))
        )
        let currentSnapshot = await synchronizedLedgerSnapshot()
        let currentObservedResidualBytes = currentUnattributedBytes(currentSnapshot)
        let activeOCRFrameCount = OCRStageMemoryLedger.currentActiveFrameCount()
        let sweepableObservedResidualBytes = sweepableUnattributedBytesForHandoff(
            currentUnattributedBytes: currentObservedResidualBytes,
            activeOCRFrameCount: activeOCRFrameCount,
            allowedActiveOCRFrameCount: 1
        )
        let incomingObservedResidualBytes = sumPositiveBytes(
            activeObservedResidualBytes,
            sweepableObservedResidualBytes
        )
        let settledObservedResidualBytes = mergedHandoffObservedResidualBytes(
            currentHandoffObservedBytes: currentHandoffObservedBytes,
            incomingObservedResidualBytes: incomingObservedResidualBytes,
            activeOCRFrameCount: activeOCRFrameCount
        )
        let suppressedConcurrentObservedResidual =
            currentObservedResidualBytes > 0 &&
            sweepableObservedResidualBytes == 0 &&
            activeOCRFrameCount > 1

        if settledObservedResidualBytes > 0 {
            tracker.setRetained(
                tag: "processing.extract.handoffObservedResidual",
                function: "processing.extract_text.handoff",
                kind: "extract-handoff-observed-residual",
                note: suppressedConcurrentObservedResidual
                    ? "max-prior-handoff-or-active-residuals-after-stage-handoff-concurrent-ocr-guard"
                    : concurrentSafeHandoffNote(
                        "prior-handoff-plus-active-or-current-unattributed-after-stage-handoff",
                        activeOCRFrameCount: activeOCRFrameCount
                    ),
                bytes: settledObservedResidualBytes,
                reason: reason,
                delay: settledObservedResidualHoldSeconds,
                forceSummary: false,
                emitSummary: false,
                autoClear: false
            )
        } else {
            tracker.clear(
                tag: "processing.extract.handoffObservedResidual",
                function: "processing.extract_text.handoff",
                kind: "extract-handoff-observed-residual",
                note: "handoff-cleared",
                reason: reason,
                emitSummary: false
            )
        }

        scheduleSettledHandoffObservedResidual(reason: reason)

        if regionReturnResidualBytes > 0 {
            VisionOCR.clearRegionReturnResidualForHandoff(reason: reason)
        }
        if fullFrameBlindResidualBytes > 0 {
            VisionOCR.clearFullFrameBlindResidualForHandoff(reason: reason)
        }
        if regionBlindResidualBytes > 0 {
            VisionOCR.clearRegionBlindResidualForHandoff(reason: reason)
        }

        tracker.clear(
            tag: "processing.extract.ocrCallResidual",
            function: "processing.extract_text.ocr_call",
            kind: "extract-ocr-call-residual",
            note: "handoff-cleared",
            reason: reason,
            emitSummary: false
        )
        clearHiddenStageResidualExclusionBytes(tag: "processing.extract.ocrCallResidual")
        tracker.clear(
            tag: "processing.extract.ocrCallObservedResidual",
            function: "processing.extract_text.ocr_call",
            kind: "extract-ocr-call-observed-residual",
            note: "handoff-cleared",
            reason: reason,
            emitSummary: false
        )
        tracker.clear(
            tag: "processing.extract.totalResidual",
            function: "processing.extract_text.residual",
            kind: "extract-total-residual",
            note: "handoff-cleared",
            reason: reason,
            emitSummary: false
        )
        clearHiddenStageResidualExclusionBytes(tag: "processing.extract.totalResidual")
        tracker.clear(
            tag: "processing.extract.totalObservedResidual",
            function: "processing.extract_text.residual",
            kind: "extract-total-observed-residual",
            note: "handoff-cleared",
            reason: reason,
            emitSummary: false
        )
        tracker.clear(
            tag: "processing.extract.ocrReturnResidual",
            function: "processing.extract_text.ocr_tail",
            kind: "extract-ocr-return-residual",
            note: "handoff-cleared",
            reason: reason,
            emitSummary: false
        )
    }

    static func absorbCurrentRegionReturnResidualIntoHandoff(reason: String) {
        let regionReturnResidualBytes = VisionOCR.currentRegionReturnResidualBytes()
        guard regionReturnResidualBytes > 0 else { return }

        absorbRegionReturnResidualBytesIntoHandoff(
            reason: reason,
            regionReturnResidualBytes: regionReturnResidualBytes
        )
        VisionOCR.clearRegionReturnResidualForHandoff(reason: reason)
    }

    static func absorbCurrentOCRCallObservedResidualIntoHandoff(reason: String) {
        let activeOCRFrameCount = OCRStageMemoryLedger.currentActiveFrameCount()
        guard activeOCRFrameCount <= 1 else { return }
        guard tracker.currentBytes(tag: "processing.extract.ocrCallObservedResidual") > 0 else {
            return
        }

        absorbCurrentExtractResidualsIntoHandoff(
            reason: reason,
            sourceTags: ["processing.extract.ocrCallObservedResidual"],
            note: "prior-handoff-plus-ocr-call-observed-residual"
        )
    }

    static func absorbCurrentOCRBlindResidualsIntoHandoff(reason: String) {
        let activeOCRFrameCount = OCRStageMemoryLedger.currentActiveFrameCount()
        guard activeOCRFrameCount <= 1 else { return }

        let fullFrameBlindResidualBytes = VisionOCR.currentFullFrameBlindResidualBytes()
        let regionBlindResidualBytes = VisionOCR.currentRegionBlindResidualBytes()
        let blindResidualBytes = sumPositiveBytes(
            max(0, fullFrameBlindResidualBytes),
            max(0, regionBlindResidualBytes)
        )
        guard blindResidualBytes > 0 else { return }

        absorbObservedResidualBytesIntoHandoff(
            reason: reason,
            observedResidualBytes: blindResidualBytes,
            note: "prior-handoff-plus-ocr-blind-residuals"
        )

        if fullFrameBlindResidualBytes > 0 {
            VisionOCR.clearFullFrameBlindResidualForHandoff(reason: reason)
        }
        if regionBlindResidualBytes > 0 {
            VisionOCR.clearRegionBlindResidualForHandoff(reason: reason)
        }
    }

    static func absorbObservedResidualBytesIntoHandoff(
        reason: String,
        observedResidualBytes: Int64,
        note: String
    ) {
        guard observedResidualBytes > 0 else { return }

        let currentHandoffObservedBytes = currentHandoffObservedResidualBytes()
        let activeOCRFrameCount = OCRStageMemoryLedger.currentActiveFrameCount()
        let settledObservedResidualBytes = mergedHandoffObservedResidualBytes(
            currentHandoffObservedBytes: currentHandoffObservedBytes,
            incomingObservedResidualBytes: observedResidualBytes,
            activeOCRFrameCount: activeOCRFrameCount
        )

        tracker.setRetained(
            tag: "processing.extract.handoffObservedResidual",
            function: "processing.extract_text.handoff",
            kind: "extract-handoff-observed-residual",
            note: concurrentSafeHandoffNote(note, activeOCRFrameCount: activeOCRFrameCount),
            bytes: settledObservedResidualBytes,
            reason: reason,
            delay: settledObservedResidualHoldSeconds,
            forceSummary: false,
            emitSummary: false,
            autoClear: false
        )

        scheduleSettledHandoffObservedResidual(reason: reason)
    }

    static func absorbRegionReturnResidualBytesIntoHandoff(
        reason: String,
        regionReturnResidualBytes: Int64
    ) {
        absorbObservedResidualBytesIntoHandoff(
            reason: reason,
            observedResidualBytes: regionReturnResidualBytes,
            note: "prior-handoff-plus-region-return-after-ocr-call"
        )
    }

    static func reconcileHandoffObservedResidualToCurrentFootprint(reason: String) async {
        let currentHandoffObservedBytes = currentHandoffObservedResidualBytes()
        guard currentHandoffObservedBytes > 0 else { return }

        let settledSnapshot = await synchronizedLedgerSnapshot()
        let settledTrackedBytes = settledSnapshot.trackedMemoryBytes > UInt64(Int64.max)
            ? Int64.max
            : Int64(settledSnapshot.trackedMemoryBytes)
        let settledFootprintBytes = settledSnapshot.footprintBytes > UInt64(Int64.max)
            ? Int64.max
            : Int64(settledSnapshot.footprintBytes)
        let settledHandoffObservedBytes = cappedHandoffObservedResidualBytes(
            currentHandoffObservedBytes: currentHandoffObservedBytes,
            settledTrackedBytes: settledTrackedBytes,
            settledFootprintBytes: settledFootprintBytes
        )

        if settledHandoffObservedBytes > 0 {
            setResidual(
                tag: "processing.extract.handoffObservedResidual",
                function: "processing.extract_text.handoff",
                kind: "extract-handoff-observed-residual",
                note: "capped-to-current-footprint-before-summary",
                bytes: settledHandoffObservedBytes,
                reason: reason,
                delay: settledObservedResidualHoldSeconds,
                emitSummary: false,
                autoClear: false
            )
        } else {
            tracker.clear(
                tag: "processing.extract.handoffObservedResidual",
                function: "processing.extract_text.handoff",
                kind: "extract-handoff-observed-residual",
                note: "current-footprint-drained-before-summary",
                reason: reason,
                emitSummary: false
            )
        }

        if settledHandoffObservedBytes > 0 {
            scheduleSettledHandoffObservedResidual(reason: reason)
        }
    }

    static func scheduleObservedResidualProbe(
        tag: String,
        function: String,
        kind: String,
        note: String,
        reason: String,
        baselineSnapshot: MemoryLedger.Snapshot,
        delay: TimeInterval = 1.5,
        holdDelay: TimeInterval = 4,
        subtractingBytes: Int64 = 0,
        liveSubtractiveBytes: @escaping @Sendable () -> Int64 = { 0 }
    ) {
        let generation: UInt64
        deferredProbeLock.lock()
        generation = (deferredProbeGenerationByTag[tag] ?? 0) + 1
        deferredProbeGenerationByTag[tag] = generation
        deferredProbeLock.unlock()

        Task.detached(priority: .utility) {
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
            }

            let delayedSnapshot = await synchronizedLedgerSnapshot()
            let residualBytes = measuredResidualBytes(
                before: baselineSnapshot,
                after: delayedSnapshot,
                subtractingBytes: subtractingBytes
            )
            let netResidualBytes = max(0, residualBytes - max(0, liveSubtractiveBytes()))
            let boundedResidualBytes = min(
                netResidualBytes,
                currentUnattributedBytes(delayedSnapshot)
            )
            guard isCurrentDeferredProbe(tag: tag, generation: generation) else { return }

            setResidual(
                tag: tag,
                function: function,
                kind: kind,
                note: note,
                bytes: boundedResidualBytes,
                reason: reason,
                delay: holdDelay
            )
        }
    }

    static func estimatedTextRegionBytes(_ region: TextRegion) -> Int64 {
        Int64(MemoryLayout<TextRegion>.stride) + estimatedStringStorageBytes(region.text)
    }

    static func estimatedTextRegionPayloadBytes(_ regions: [TextRegion]) -> Int64 {
        regions.reduce(into: Int64(0)) { total, region in
            total += estimatedTextRegionBytes(region)
        }
    }

    static func estimatedFrameMetadataBytes(_ metadata: FrameMetadata) -> Int64 {
        Int64(MemoryLayout<FrameMetadata>.stride) +
            estimatedOptionalStringBytes(metadata.appBundleID) +
            estimatedOptionalStringBytes(metadata.appName) +
            estimatedOptionalStringBytes(metadata.windowName) +
            estimatedOptionalStringBytes(metadata.browserURL) +
            estimatedOptionalStringBytes(metadata.redactionReason)
    }

    static func estimatedExtractedTextBytes(_ extractedText: ExtractedText) -> Int64 {
        Int64(MemoryLayout<ExtractedText>.stride) +
            estimatedTextRegionPayloadBytes(extractedText.regions) +
            estimatedTextRegionPayloadBytes(extractedText.chromeRegions) +
            estimatedStringBytes(extractedText.fullText) +
            estimatedStringBytes(extractedText.chromeText) +
            estimatedFrameMetadataBytes(extractedText.metadata)
    }

    private static func estimatedOptionalStringBytes(_ value: String?) -> Int64 {
        guard let value else { return 0 }
        return estimatedStringBytes(value)
    }

    private static func estimatedStringBytes(_ value: String) -> Int64 {
        Int64(MemoryLayout<String>.stride) + estimatedStringStorageBytes(value)
    }

    private static func estimatedStringStorageBytes(_ value: String) -> Int64 {
        Int64(value.utf16.count * 2 + 24)
    }

    private static func scheduleSettledHandoffObservedResidual(reason: String) {
        let deferredTag = "processing.extract.handoffObservedResidual.settled"
        let generation: UInt64

        deferredProbeLock.lock()
        generation = (deferredProbeGenerationByTag[deferredTag] ?? 0) + 1
        deferredProbeGenerationByTag[deferredTag] = generation
        deferredProbeLock.unlock()

        let deadline = DispatchTime.now() + settledObservedResidualDelaySeconds
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: deadline) {
            launchSettledHandoffObservedResidualProbe(
                deferredTag: deferredTag,
                generation: generation,
                reason: reason
            )
        }
    }

    private static func launchSettledHandoffObservedResidualProbe(
        deferredTag: String,
        generation: UInt64,
        reason: String
    ) {
        _ = Task {
            await runSettledHandoffObservedResidualProbe(
                deferredTag: deferredTag,
                generation: generation,
                reason: reason
            )
        }
    }

    private static func runSettledHandoffObservedResidualProbe(
        deferredTag: String,
        generation: UInt64,
        reason: String
    ) async {
        guard isCurrentDeferredProbe(tag: deferredTag, generation: generation) else { return }

        let currentHandoffObservedBytes = currentHandoffObservedResidualBytes()
        guard currentHandoffObservedBytes > 0 else { return }

        let settledSnapshot = await synchronizedLedgerSnapshot()
        let settledTrackedBytes = settledSnapshot.trackedMemoryBytes > UInt64(Int64.max)
            ? Int64.max
            : Int64(settledSnapshot.trackedMemoryBytes)
        let settledFootprintBytes = settledSnapshot.footprintBytes > UInt64(Int64.max)
            ? Int64.max
            : Int64(settledSnapshot.footprintBytes)
        let settledHandoffObservedBytes = cappedHandoffObservedResidualBytes(
            currentHandoffObservedBytes: currentHandoffObservedBytes,
            settledTrackedBytes: settledTrackedBytes,
            settledFootprintBytes: settledFootprintBytes
        )

        if settledHandoffObservedBytes > 0 {
            setResidual(
                tag: "processing.extract.handoffObservedResidual",
                function: "processing.extract_text.handoff",
                kind: "extract-handoff-observed-residual",
                note: "capped-to-settled-footprint-after-stage-handoff",
                bytes: settledHandoffObservedBytes,
                reason: reason,
                delay: settledObservedResidualHoldSeconds,
                emitSummary: false,
                autoClear: false
            )
        } else {
            tracker.clear(
                tag: "processing.extract.handoffObservedResidual",
                function: "processing.extract_text.handoff",
                kind: "extract-handoff-observed-residual",
                note: "settled-footprint-drained-after-stage-handoff",
                reason: reason,
                emitSummary: false
            )
        }

        if settledHandoffObservedBytes > 0 {
            scheduleSettledHandoffObservedResidual(reason: reason)
        }
    }

    private static func isCurrentDeferredProbe(tag: String, generation: UInt64) -> Bool {
        deferredProbeLock.lock()
        let isCurrent = deferredProbeGenerationByTag[tag] == generation
        deferredProbeLock.unlock()
        return isCurrent
    }

    private static func setHiddenStageResidualExclusionBytes(tag: String, bytes: Int64) {
        stageResidualExclusionLock.lock()
        if bytes > 0 {
            hiddenStageResidualExclusionBytesByTag[tag] = bytes
        } else {
            hiddenStageResidualExclusionBytesByTag.removeValue(forKey: tag)
        }
        stageResidualExclusionLock.unlock()
    }

    private static func clearHiddenStageResidualExclusionBytes(tag: String? = nil) {
        stageResidualExclusionLock.lock()
        if let tag {
            hiddenStageResidualExclusionBytesByTag.removeValue(forKey: tag)
        } else {
            hiddenStageResidualExclusionBytesByTag.removeAll()
        }
        stageResidualExclusionLock.unlock()
    }

    private static func currentHiddenStageResidualExclusionBytes() -> Int64 {
        stageResidualExclusionLock.lock()
        let total = hiddenStageResidualExclusionBytesByTag.values.reduce(into: Int64(0)) { partial, bytes in
            partial += max(0, bytes)
        }
        stageResidualExclusionLock.unlock()
        return total
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

        func reset(tags: [ResetSpec]) {
            guard !tags.isEmpty else { return }

            lock.lock()
            for spec in tags {
                var entry = entriesByTag[spec.tag] ?? Entry(
                    bytes: 0,
                    count: 0,
                    function: spec.function,
                    kind: spec.kind,
                    note: spec.note
                )
                entry.bytes = 0
                entry.count = 0
                entry.function = spec.function
                entry.kind = spec.kind
                entry.note = spec.note
                entriesByTag[spec.tag] = entry
                retainedGenerationByTag[spec.tag] = (retainedGenerationByTag[spec.tag] ?? 0) + 1
            }
            let publishedEntries = tags.compactMap { spec in
                entriesByTag[spec.tag].map { (spec.tag, $0) }
            }
            lock.unlock()

            for (tag, entry) in publishedEntries {
                publish(tag: tag, entry: entry)
            }
        }

        func setRetained(
            tag: String,
            function: String,
            kind: String,
            note: String?,
            bytes: Int64,
            reason: String,
            delay: TimeInterval,
            forceSummary: Bool = false,
            emitSummary: Bool = true,
            autoClear: Bool = true
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
            entry.count = entry.bytes > 0 ? 1 : 0
            entry.function = function
            entry.kind = kind
            entry.note = note
            entriesByTag[tag] = entry
            generation = (retainedGenerationByTag[tag] ?? 0) + 1
            retainedGenerationByTag[tag] = generation
            lock.unlock()

            publish(tag: tag, entry: entry)
            if emitSummary {
                MemoryLedger.emitSummary(
                    reason: reason,
                    category: .processing,
                    minIntervalSeconds: summaryIntervalSeconds
                )
            }

            guard autoClear else { return }

            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + max(delay, 0)) { [self] in
                clearRetainedIfCurrent(tag: tag, generation: generation, reason: reason)
            }
        }

        func clear(
            tag: String,
            function: String,
            kind: String,
            note: String?,
            reason: String,
            emitSummary: Bool
        ) {
            lock.lock()
            var entry = entriesByTag[tag] ?? Entry(
                bytes: 0,
                count: 0,
                function: function,
                kind: kind,
                note: note
            )
            entry.bytes = 0
            entry.count = 0
            entry.function = function
            entry.kind = kind
            entry.note = note
            entriesByTag[tag] = entry
            retainedGenerationByTag[tag] = (retainedGenerationByTag[tag] ?? 0) + 1
            lock.unlock()

            publish(tag: tag, entry: entry)
            if emitSummary {
                emitSummaryReconcilingHandoffIfNeeded(reason: reason)
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
                function: "processing.extract_text",
                kind: "extract-residual",
                note: "observed-footprint-delta"
            )
            entry.bytes = 0
            entry.count = 0
            entriesByTag[tag] = entry
            lock.unlock()

            publish(tag: tag, entry: entry)
            emitSummaryReconcilingHandoffIfNeeded(reason: reason)
        }

        func currentBytes(tag: String) -> Int64 {
            lock.lock()
            let bytes = entriesByTag[tag]?.bytes ?? 0
            lock.unlock()
            return bytes
        }

        private func publish(tag: String, entry: Entry) {
            MemoryLedger.set(
                tag: tag,
                bytes: entry.bytes,
                count: entry.count,
                unit: "samples",
                function: entry.function,
                kind: entry.kind,
                note: entry.note
            )
        }
    }
}
