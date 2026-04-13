import Foundation
import Shared

private struct ProcessingExtractResidualRepublishSpec {
    let tag: String
    let function: String
    let kind: String
    let note: String
    let delay: TimeInterval
}

struct ProcessingExtractBuildStageInstrumentation {
    private let baselineSnapshot: MemoryLedger.Snapshot

    static func begin() async -> ProcessingExtractBuildStageInstrumentation {
        let baselineSnapshot = await ProcessingExtractMemoryLedger.synchronizedLedgerSnapshot()
        return ProcessingExtractBuildStageInstrumentation(
            baselineSnapshot: baselineSnapshot
        )
    }

    func recordOutputPayload(_ extractedText: ExtractedText) -> Int64 {
        let outputPayloadBytes = ProcessingExtractMemoryLedger.estimatedExtractedTextBytes(extractedText)
        ProcessingExtractMemoryLedger.setResidual(
            tag: "processing.extract.outputPayload",
            function: "processing.extract_text.output_payload",
            kind: "extract-output-payload",
            note: "estimated-result-graph",
            bytes: outputPayloadBytes,
            reason: "processing.extract_text.finalize"
        )
        return outputPayloadBytes
    }

    func recordBuildResidual(outputPayloadBytes: Int64) async -> Int64 {
        let currentSnapshot = await ProcessingExtractMemoryLedger.synchronizedLedgerSnapshot()
        let buildResidualBytes = ProcessingExtractMemoryLedger.measuredResidualBytes(
            before: baselineSnapshot,
            after: currentSnapshot,
            subtractingBytes: outputPayloadBytes
        )
        ProcessingExtractMemoryLedger.setResidual(
            tag: "processing.extract.buildResidual",
            function: "processing.extract_text.build_residual",
            kind: "extract-build-residual",
            note: "observed-build-residual-net-output-payload",
            bytes: buildResidualBytes,
            reason: "processing.extract_text"
        )
        return buildResidualBytes
    }
}

struct ProcessingExtractOCRStageResult: Sendable {
    let ocrRegionPayloadBytes: Int64
    let ocrCallResidualBytes: Int64
    let ocrCallObservedResidualClaim: MemoryLedger.ResidualClaim
}

struct ProcessingExtractRequestInstrumentation: Sendable {
    private let residualEpoch: MemoryLedger.ResidualEpoch
    private let extractBaselineSnapshot: MemoryLedger.Snapshot

    static func begin() async -> ProcessingExtractRequestInstrumentation {
        let residualEpoch = await ProcessingExtractMemoryLedger.beginExtractResidualEpoch()
        ProcessingExtractMemoryLedger.beginExtractCycle()
        let extractBaselineSnapshot = await ProcessingExtractMemoryLedger.synchronizedLedgerSnapshot()
        return ProcessingExtractRequestInstrumentation(
            residualEpoch: residualEpoch,
            extractBaselineSnapshot: extractBaselineSnapshot
        )
    }

    func finish() async {
        await MemoryLedger.endResidualEpoch(residualEpoch)
    }

    func prepareForOCR(reason: String) async {
        await ProcessingExtractMemoryLedger.reconcileHandoffObservedResidualToCurrentFootprint(
            reason: reason
        )
    }

    func beginBuildStage() async -> ProcessingExtractBuildStageInstrumentation {
        await ProcessingExtractBuildStageInstrumentation.begin()
    }

    func absorbFullFrameBlindResidual(reason: String) {
        VisionOCR.handoffCurrentFullFrameBlindResidualToExtract(reason: reason)
    }

    func finalizeFullFrameResiduals(
        reason: String,
        blindResidualClaimBytes: Int64,
        callResidualBytes: Int64
    ) async {
        await Self.reconcileFullFrameResiduals(
            reason: reason,
            blindResidualClaimBytes: blindResidualClaimBytes,
            callResidualBytes: callResidualBytes
        )
        absorbFullFrameBlindResidual(reason: reason)
        Self.scheduleFullFrameBlindResidualClear(reason: reason)
    }

    func settleRegionResidualClaims(
        reason: String,
        blindResidualBytes: Int64,
        regionReturnResidualClaim: MemoryLedger.ResidualClaim
    ) {
        VisionOCR.handoffRegionBlindResidualToExtract(
            reason: reason,
            blindResidualBytes: blindResidualBytes,
            subtractingReturnResidualBytes: max(0, regionReturnResidualClaim.bytes)
        )

        switch regionReturnResidualClaim.target {
        case .owner:
            ProcessingExtractMemoryLedger.absorbRegionReturnResidualBytesIntoHandoff(
                reason: reason,
                regionReturnResidualBytes: max(0, regionReturnResidualClaim.bytes)
            )
            VisionOCR.clearRegionReturnResidualForHandoff(reason: reason)
        case .concurrent:
            VisionOCR.publishArbitedResidualClaim(
                claim: regionReturnResidualClaim,
                ownerTag: "processing.ocr.regionReturnResidual",
                ownerFunction: "processing.ocr.region_reocr",
                ownerKind: "region-return-residual",
                ownerNote: "epoch-arbited-current-unattributed-after-cache-refresh",
                delay: VisionOCR.blindResidualHoldSeconds,
                reason: reason
            )
        case .none:
            break
        }
    }

    func finalizeRegionResiduals(
        reason: String,
        blindResidualBytes: Int64,
        regionReturnResidualClaim: MemoryLedger.ResidualClaim,
        callResidualBytes: Int64,
        requestBaselineSnapshot: MemoryLedger.Snapshot,
        requestPayloadBytes: Int64,
        cacheBaselineSnapshot: MemoryLedger.Snapshot
    ) async {
        settleRegionResidualClaims(
            reason: reason,
            blindResidualBytes: blindResidualBytes,
            regionReturnResidualClaim: regionReturnResidualClaim
        )

        let returnResidualClaimBytes = max(0, regionReturnResidualClaim.bytes)
        await Self.reconcileRegionResiduals(
            reason: reason,
            blindResidualClaimBytes: blindResidualBytes,
            returnResidualClaimBytes: returnResidualClaimBytes,
            callResidualBytes: callResidualBytes
        )
        Self.scheduleRegionSettledReconciliation(
            reason: reason,
            blindResidualClaimBytes: blindResidualBytes,
            returnResidualClaimBytes: returnResidualClaimBytes,
            callResidualBytes: callResidualBytes
        )
        Self.scheduleRegionTailResidual(
            reason: reason,
            requestBaselineSnapshot: requestBaselineSnapshot,
            requestPayloadBytes: requestPayloadBytes,
            cacheBaselineSnapshot: cacheBaselineSnapshot
        )
    }

    func recordOCRStage(
        ocrRegions: [TextRegion],
        schedulesReturnResidualProbes: Bool
    ) async -> ProcessingExtractOCRStageResult {
        let postOCRSnapshot = await ProcessingExtractMemoryLedger.synchronizedLedgerSnapshot()
        let ocrRegionPayloadBytes = ProcessingExtractMemoryLedger.estimatedTextRegionPayloadBytes(ocrRegions)
        ProcessingExtractMemoryLedger.setResidual(
            tag: "processing.extract.ocrRegionPayload",
            function: "processing.extract_text.ocr_payload",
            kind: "extract-ocr-region-payload",
            note: "estimated-result-graph",
            bytes: ocrRegionPayloadBytes,
            reason: "processing.extract_text.ocr_call"
        )
        let ocrResidualExclusionBytes = VisionOCR.currentExtractResidualExclusionBytes()
        let ocrCallResidualBytes = max(
            0,
            ProcessingExtractMemoryLedger.measuredResidualBytes(
                before: extractBaselineSnapshot,
                after: postOCRSnapshot,
                subtractingBytes: ocrRegionPayloadBytes
            ) - ocrResidualExclusionBytes
        )
        ProcessingExtractMemoryLedger.setResidual(
            tag: "processing.extract.ocrCallResidual",
            function: "processing.extract_text.ocr_call",
            kind: "extract-ocr-call-residual",
            note: "observed-footprint-delta-minus-payload-net-ocr-local-residuals",
            bytes: ocrCallResidualBytes,
            reason: "processing.extract_text.ocr_call",
            emitSummary: false
        )
        let ocrCallObservedResidualRequestBytes = max(
            0,
            ProcessingExtractMemoryLedger.currentUnattributedBytes(postOCRSnapshot) -
                ocrRegionPayloadBytes -
                ocrCallResidualBytes
        )
        await MemoryLedger.flushPendingUpdates()
        let ocrCallObservedResidualClaim = await MemoryLedger.claimCurrentUnattributed(
            epoch: residualEpoch,
            requestedBytes: ocrCallObservedResidualRequestBytes
        )
        ProcessingExtractMemoryLedger.setObservedResidualFromClaim(
            claim: ocrCallObservedResidualClaim,
            tag: "processing.extract.ocrCallObservedResidual",
            function: "processing.extract_text.ocr_call",
            kind: "extract-ocr-call-observed-residual",
            note: "epoch-arbited-current-unattributed-after-ocr-call",
            reason: "processing.extract_text.ocr_call"
        )
        ProcessingExtractMemoryLedger.absorbCurrentOCRCallObservedResidualIntoHandoff(
            reason: "processing.extract_text.ocr_call"
        )
        ProcessingExtractMemoryLedger.absorbCurrentOCRBlindResidualsIntoHandoff(
            reason: "processing.extract_text.ocr_call"
        )
        ProcessingExtractMemoryLedger.absorbCurrentRegionReturnResidualIntoHandoff(
            reason: "processing.extract_text.ocr_call"
        )
        await ProcessingExtractMemoryLedger.reconcileHandoffObservedResidualToCurrentFootprint(
            reason: "processing.extract_text.ocr_call"
        )
        ProcessingExtractMemoryLedger.emitSummaryReconcilingHandoffIfNeeded(
            reason: "processing.extract_text.ocr_call"
        )
        ProcessingExtractMemoryLedger.clearOCRCallMeasuredResidual(
            reason: "processing.extract_text.ocr_call"
        )

        if schedulesReturnResidualProbes {
            Self.scheduleOCRReturnResidual(
                reason: "processing.extract_text.ocr_call",
                baselineSnapshot: extractBaselineSnapshot,
                outputPayloadBytes: ocrRegionPayloadBytes
            )
        }

        return ProcessingExtractOCRStageResult(
            ocrRegionPayloadBytes: ocrRegionPayloadBytes,
            ocrCallResidualBytes: ocrCallResidualBytes,
            ocrCallObservedResidualClaim: ocrCallObservedResidualClaim
        )
    }

    func recordExtractCompletion(
        ocrStage: ProcessingExtractOCRStageResult,
        attributedResidualBytes: Int64,
        outputPayloadBytes: Int64
    ) async {
        let postExtractSnapshot = await ProcessingExtractMemoryLedger.synchronizedLedgerSnapshot()
        let totalExtractResidualBytes = ProcessingExtractMemoryLedger.measuredResidualBytes(
            before: extractBaselineSnapshot,
            after: postExtractSnapshot
        )
        let totalObservedResidualRequestBytes = ProcessingExtractMemoryLedger.currentUnattributedBytes(postExtractSnapshot)
        await MemoryLedger.flushPendingUpdates()
        let totalObservedResidualClaim = await MemoryLedger.claimCurrentUnattributed(
            epoch: residualEpoch,
            requestedBytes: totalObservedResidualRequestBytes
        )
        ProcessingExtractMemoryLedger.setObservedResidualFromClaim(
            claim: totalObservedResidualClaim,
            tag: "processing.extract.totalObservedResidual",
            function: "processing.extract_text.residual",
            kind: "extract-total-observed-residual",
            note: "epoch-arbited-current-unattributed-after-extract",
            reason: "processing.extract_text"
        )
        let extractFallbackResidualBytes = max(
            0,
            totalExtractResidualBytes -
                ocrStage.ocrRegionPayloadBytes -
                ocrStage.ocrCallResidualBytes -
                max(0, ocrStage.ocrCallObservedResidualClaim.bytes) -
                max(0, totalObservedResidualClaim.bytes) -
                attributedResidualBytes -
                outputPayloadBytes
        )
        ProcessingExtractMemoryLedger.setResidual(
            tag: "processing.extract.totalResidual",
            function: "processing.extract_text.residual",
            kind: "extract-total-residual",
            note: "observed-extract-remainder",
            bytes: extractFallbackResidualBytes,
            reason: "processing.extract_text",
            delay: ProcessingExtractMemoryLedger.observedResidualHandoffSeconds,
            emitSummary: false
        )
        ProcessingExtractMemoryLedger.clearTotalMeasuredResidual(
            reason: "processing.extract_text"
        )
        await ProcessingExtractMemoryLedger.reconcileHandoffObservedResidualToCurrentFootprint(
            reason: "processing.extract_text"
        )
        ProcessingExtractMemoryLedger.emitSummaryReconcilingHandoffIfNeeded(
            reason: "processing.extract_text"
        )
    }

    private static func republishResidual(
        spec: ProcessingExtractResidualRepublishSpec,
        reason: String,
        bytes: Int64
    ) {
        VisionOCRMemoryLedger.setObservedResidual(
            tag: spec.tag,
            function: spec.function,
            reason: reason,
            bytes: bytes,
            kind: spec.kind,
            note: spec.note,
            delay: spec.delay,
            forceSummary: true
        )
    }

    private static func currentOCRReturnResidualExclusionBytes() -> Int64 {
        VisionOCR.currentExtractResidualExclusionBytes() +
            ProcessingExtractMemoryLedger.currentTrackedBytes(tag: "processing.extract.ocrCallObservedResidual") +
            ProcessingExtractMemoryLedger.currentTrackedBytes(tag: "processing.extract.totalObservedResidual") +
            ProcessingExtractMemoryLedger.currentTrackedBytes(tag: "processing.extract.handoffObservedResidual")
    }

    static func scheduleOCRReturnResidual(
        reason: String,
        baselineSnapshot: MemoryLedger.Snapshot,
        outputPayloadBytes: Int64,
        delaySeconds: TimeInterval = 1.5,
        holdDelaySeconds: TimeInterval = 1.5
    ) {
        ProcessingExtractMemoryLedger.scheduleObservedResidualProbe(
            tag: "processing.extract.ocrReturnResidual",
            function: "processing.extract_text.ocr_tail",
            kind: "extract-ocr-return-residual",
            note: "observed-delayed-residual-after-ocr-call-net-ocr-local-residuals",
            reason: reason,
            baselineSnapshot: baselineSnapshot,
            delay: delaySeconds,
            holdDelay: holdDelaySeconds,
            subtractingBytes: outputPayloadBytes,
            liveSubtractiveBytes: { Self.currentOCRReturnResidualExclusionBytes() }
        )
    }

    static func reconcileFullFrameResiduals(
        reason: String,
        blindResidualClaimBytes: Int64,
        callResidualBytes: Int64
    ) async {
        let republishSpecs: [String: ProcessingExtractResidualRepublishSpec] = [
            "processing.ocr.fullFrameRetainedHeap": ProcessingExtractResidualRepublishSpec(
                tag: "processing.ocr.fullFrameRetainedHeap",
                function: "processing.ocr.full_frame",
                kind: "vision-retained-heap",
                note: "observed-footprint-delta-net-later-full-frame-residuals",
                delay: 4
            ),
            "processing.ocr.fullFrameRuntimeResidual": ProcessingExtractResidualRepublishSpec(
                tag: "processing.ocr.fullFrameRuntimeResidual",
                function: "processing.ocr.full_frame",
                kind: "vision-runtime-residual",
                note: "observed-footprint-delta-capped-to-synchronized-snapshot",
                delay: 4
            ),
            "processing.ocr.fullFrameOuterResidual": ProcessingExtractResidualRepublishSpec(
                tag: "processing.ocr.fullFrameOuterResidual",
                function: "processing.ocr.full_frame",
                kind: "ocr-blind-residual",
                note: "epoch-arbited-current-unattributed-capped-to-synchronized-snapshot",
                delay: VisionOCR.fullFrameBlindResidualHandoffSeconds
            ),
            "processing.ocr.fullFrameOCRCallResidual": ProcessingExtractResidualRepublishSpec(
                tag: "processing.ocr.fullFrameOCRCallResidual",
                function: "processing.ocr.full_frame",
                kind: "full-frame-ocr-call-residual",
                note: "observed-minus-results-payload-net-blind-residual-capped-to-synchronized-snapshot",
                delay: 4
            )
        ]

        if let retainedSpec = republishSpecs["processing.ocr.fullFrameRetainedHeap"] {
            let currentRetainedBytes = VisionOCRMemoryLedger.currentTrackedBytes(tag: retainedSpec.tag)
            let netRetainedBytes = max(
                0,
                currentRetainedBytes - max(0, blindResidualClaimBytes) - max(0, callResidualBytes)
            )
            if netRetainedBytes != currentRetainedBytes {
                republishResidual(spec: retainedSpec, reason: reason, bytes: netRetainedBytes)
            }
        }

        let synchronizedSnapshot = await VisionOCR.synchronizedLedgerSnapshot()
        let footprintBytes = Int64(min(synchronizedSnapshot.footprintBytes, UInt64(Int64.max)))
        var remainingOverage = max(0, synchronizedSnapshot.trackedMemoryBytes - footprintBytes)
        guard remainingOverage > 0 else { return }

        let trimOrder = [
            "processing.ocr.fullFrameRetainedHeap",
            "processing.ocr.fullFrameRuntimeResidual",
            "processing.ocr.fullFrameOuterResidual",
            "processing.ocr.fullFrameOCRCallResidual"
        ]

        for tag in trimOrder {
            guard remainingOverage > 0, let spec = republishSpecs[tag] else { continue }
            let currentBytes = VisionOCRMemoryLedger.currentTrackedBytes(tag: tag)
            guard currentBytes > 0 else { continue }

            let bytesToTrim = min(currentBytes, remainingOverage)
            let trimmedBytes = max(0, currentBytes - bytesToTrim)
            if trimmedBytes != currentBytes {
                republishResidual(spec: spec, reason: reason, bytes: trimmedBytes)
            }
            remainingOverage = max(0, remainingOverage - bytesToTrim)
        }
    }

    static func reconcileRegionResiduals(
        reason: String,
        blindResidualClaimBytes: Int64,
        returnResidualClaimBytes: Int64,
        callResidualBytes: Int64
    ) async {
        let republishSpecs: [String: ProcessingExtractResidualRepublishSpec] = [
            "processing.ocr.regionRetainedHeap": ProcessingExtractResidualRepublishSpec(
                tag: "processing.ocr.regionRetainedHeap",
                function: "processing.ocr.region_reocr",
                kind: "vision-retained-heap",
                note: "observed-footprint-delta-net-later-region-residuals",
                delay: 4
            ),
            "processing.ocr.regionRuntimeResidual": ProcessingExtractResidualRepublishSpec(
                tag: "processing.ocr.regionRuntimeResidual",
                function: "processing.ocr.region_reocr",
                kind: "vision-runtime-residual",
                note: "observed-footprint-delta-capped-to-synchronized-snapshot",
                delay: 4
            ),
            "processing.ocr.regionBlindResidual": ProcessingExtractResidualRepublishSpec(
                tag: "processing.ocr.regionBlindResidual",
                function: "processing.ocr.region_reocr",
                kind: "ocr-blind-residual",
                note: "epoch-arbited-current-unattributed-net-region-return",
                delay: VisionOCR.blindResidualHoldSeconds
            ),
            "processing.ocr.regionReturnResidual": ProcessingExtractResidualRepublishSpec(
                tag: "processing.ocr.regionReturnResidual",
                function: "processing.ocr.region_reocr",
                kind: "region-return-residual",
                note: "epoch-arbited-current-unattributed-after-cache-refresh-capped-to-synchronized-snapshot",
                delay: VisionOCR.blindResidualHoldSeconds
            ),
            "processing.ocr.regionOCRCallResidual": ProcessingExtractResidualRepublishSpec(
                tag: "processing.ocr.regionOCRCallResidual",
                function: "processing.ocr.region_reocr",
                kind: "region-ocr-call-residual",
                note: "observed-minus-results-payload-net-blind-residual-capped-to-synchronized-snapshot",
                delay: 4
            )
        ]

        if let blindSpec = republishSpecs["processing.ocr.regionBlindResidual"] {
            let currentBlindBytes = VisionOCRMemoryLedger.currentTrackedBytes(tag: blindSpec.tag)
            let netBlindBytes = max(0, currentBlindBytes - max(0, returnResidualClaimBytes))
            if netBlindBytes != currentBlindBytes {
                republishResidual(spec: blindSpec, reason: reason, bytes: netBlindBytes)
            }
        }

        if let retainedSpec = republishSpecs["processing.ocr.regionRetainedHeap"] {
            let currentRetainedBytes = VisionOCRMemoryLedger.currentTrackedBytes(tag: retainedSpec.tag)
            let netRetainedBytes = max(
                0,
                currentRetainedBytes -
                    max(0, blindResidualClaimBytes) -
                    max(0, returnResidualClaimBytes) -
                    max(0, callResidualBytes)
            )
            if netRetainedBytes != currentRetainedBytes {
                republishResidual(spec: retainedSpec, reason: reason, bytes: netRetainedBytes)
            }
        }

        let synchronizedSnapshot = await VisionOCR.synchronizedLedgerSnapshot()
        let footprintBytes = Int64(min(synchronizedSnapshot.footprintBytes, UInt64(Int64.max)))
        var remainingOverage = max(0, synchronizedSnapshot.trackedMemoryBytes - footprintBytes)
        guard remainingOverage > 0 else { return }

        let trimOrder = [
            "processing.ocr.regionRetainedHeap",
            "processing.ocr.regionRuntimeResidual",
            "processing.ocr.regionBlindResidual",
            "processing.ocr.regionReturnResidual",
            "processing.ocr.regionOCRCallResidual"
        ]

        for tag in trimOrder {
            guard remainingOverage > 0, let spec = republishSpecs[tag] else { continue }
            let currentBytes = VisionOCRMemoryLedger.currentTrackedBytes(tag: tag)
            guard currentBytes > 0 else { continue }

            let bytesToTrim = min(currentBytes, remainingOverage)
            let trimmedBytes = max(0, currentBytes - bytesToTrim)
            if trimmedBytes != currentBytes {
                republishResidual(spec: spec, reason: reason, bytes: trimmedBytes)
            }
            remainingOverage = max(0, remainingOverage - bytesToTrim)
        }
    }

    static func scheduleFullFrameBlindResidualClear(reason: String) {
        let spec = ProcessingExtractResidualRepublishSpec(
            tag: "processing.ocr.fullFrameOuterResidual",
            function: "processing.ocr.full_frame",
            kind: "ocr-blind-residual",
            note: "epoch-arbited-current-unattributed-handoff-cleared",
            delay: 0
        )

        Task.detached(priority: .utility) {
            try? await Task.sleep(for: .seconds(VisionOCR.fullFrameBlindResidualHandoffSeconds))
            republishResidual(spec: spec, reason: reason, bytes: 0)
        }
    }

    static func combinedRegionTailResidualBytes(
        requestTailBytes: Int64,
        cacheTailTotalBytes: Int64,
        availableUnattributedBytes: Int64
    ) -> Int64 {
        let boundedRequestTailBytes = max(0, requestTailBytes)
        let boundedCacheTailTotalBytes = max(0, cacheTailTotalBytes)
        let boundedAvailableUnattributedBytes = max(0, availableUnattributedBytes)
        return min(
            max(boundedRequestTailBytes, boundedCacheTailTotalBytes),
            boundedAvailableUnattributedBytes
        )
    }

    static func scheduleRegionTailResidual(
        reason: String,
        requestBaselineSnapshot: MemoryLedger.Snapshot,
        requestPayloadBytes: Int64,
        cacheBaselineSnapshot: MemoryLedger.Snapshot,
        delaySeconds: TimeInterval = 1.5,
        holdSeconds: TimeInterval = 1.5
    ) {
        guard let generation = VisionOCRMemoryLedger.beginDeferredProbe(tag: "processing.ocr.regionTailResidual") else {
            return
        }

        Task.detached(priority: .utility) {
            if delaySeconds > 0 {
                try? await Task.sleep(for: .seconds(delaySeconds))
            }

            let delayedSnapshot = await VisionOCR.synchronizedLedgerSnapshot()
            guard VisionOCRMemoryLedger.isCurrentDeferredProbe(
                tag: "processing.ocr.regionTailResidual",
                generation: generation
            ) else {
                return
            }

            let requestTailBytes = VisionOCR.measuredLedgerResidualBytes(
                before: requestBaselineSnapshot,
                after: delayedSnapshot,
                subtractingBytes: requestPayloadBytes
            )
            let cacheTailTotalBytes = VisionOCR.measuredLedgerResidualBytes(
                before: cacheBaselineSnapshot,
                after: delayedSnapshot
            )
            let availableUnattributedBytes = VisionOCR.currentUnattributedBytes(delayedSnapshot)
            let combinedTailBytes = combinedRegionTailResidualBytes(
                requestTailBytes: requestTailBytes,
                cacheTailTotalBytes: cacheTailTotalBytes,
                availableUnattributedBytes: availableUnattributedBytes
            )

            VisionOCRMemoryLedger.setObservedResidual(
                tag: "processing.ocr.regionTailResidual",
                function: "processing.ocr.region_reocr",
                reason: reason,
                bytes: combinedTailBytes,
                kind: "region-tail-residual",
                note: "observed-delayed-tail-residual",
                delay: holdSeconds,
                forceSummary: true
            )
        }
    }

    static func scheduleRegionSettledReconciliation(
        reason: String,
        blindResidualClaimBytes: Int64,
        returnResidualClaimBytes: Int64,
        callResidualBytes: Int64,
        delaySeconds: TimeInterval = 1.5
    ) {
        guard let generation = VisionOCRMemoryLedger.beginDeferredProbe(tag: "processing.ocr.regionSettledReconcile") else {
            return
        }

        Task.detached(priority: .utility) {
            try? await Task.sleep(for: .seconds(delaySeconds))
            guard VisionOCRMemoryLedger.isCurrentDeferredProbe(
                tag: "processing.ocr.regionSettledReconcile",
                generation: generation
            ) else {
                return
            }

            await reconcileRegionResiduals(
                reason: reason,
                blindResidualClaimBytes: blindResidualClaimBytes,
                returnResidualClaimBytes: returnResidualClaimBytes,
                callResidualBytes: callResidualBytes
            )
        }
    }
}
