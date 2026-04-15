import App
import AppKit
import AVFoundation
import Database
import Foundation
import ImageIO
import Processing
import Shared
import SwiftUI

extension SimpleTimelineViewModel {
    // MARK: - OCR Node Loading and Text Selection

    func fetchURLBoundingBoxForPresentation(
        timestamp: Date,
        source: FrameSource
    ) async throws -> URLBoundingBox? {
#if DEBUG
        if let override = test_frameOverlayLoadHooks.getURLBoundingBox {
            return try await override(timestamp, source)
        }
#endif
        return try await coordinator.getURLBoundingBox(timestamp: timestamp, source: source)
    }

    func fetchOCRStatusForPresentation(frameID: FrameID) async throws -> OCRProcessingStatus {
#if DEBUG
        if let override = test_frameOverlayLoadHooks.getOCRStatus {
            return try await override(frameID)
        }
#endif
        return try await coordinator.getOCRStatus(frameID: frameID)
    }

    func fetchAllOCRNodesForPresentation(
        frameID: FrameID,
        source: FrameSource
    ) async throws -> [OCRNodeWithText] {
#if DEBUG
        if let override = test_frameOverlayLoadHooks.getAllOCRNodes {
            return try await override(frameID, source)
        }
#endif
        return try await coordinator.getAllOCRNodes(frameID: frameID, source: source)
    }

    static func filteredPresentationOCRNodes(_ nodes: [OCRNodeWithText]) -> [OCRNodeWithText] {
        nodes.filter { node in
            node.x >= 0.0 && node.x <= 1.0 &&
            node.y >= 0.0 && node.y <= 1.0 &&
            (node.x + node.width) <= 1.0 &&
            (node.y + node.height) <= 1.0
        }
    }

    /// Set OCR nodes and invalidate the selection cache
    func setOCRNodes(_ nodes: [OCRNodeWithText]) {
        // Capture previous nodes for diff visualization (only when debug overlay is enabled)
        if showOCRDebugOverlay {
            previousOcrNodes = ocrNodes
        }
        if let activeRedactionTooltipNodeID,
           !nodes.contains(where: { $0.id == activeRedactionTooltipNodeID }) {
            dismissRedactionTooltip()
        }

        ocrNodes = nodes
    }

    public func clearTemporaryRedactionReveals() {
        for task in pendingRedactedNodeHideRemovalTasks.values {
            task.cancel()
        }
        pendingRedactedNodeHideRemovalTasks.removeAll()

        let revealedNodeIDs = Set(revealedRedactedNodePatches.keys)
        if !revealedNodeIDs.isEmpty {
            var updatedNodes = ocrNodes
            var didRestoreMaskedText = false

            for index in updatedNodes.indices where revealedNodeIDs.contains(updatedNodes[index].id) {
                guard updatedNodes[index].encryptedText != nil else { continue }
                updatedNodes[index] = updatedNodes[index].replacingText(maskedOCRText(for: updatedNodes[index]))
                didRestoreMaskedText = true
            }

            if didRestoreMaskedText {
                ocrNodes = updatedNodes
            }
        }

        revealedRedactedNodePatches.removeAll()
        hidingRedactedNodePatches.removeAll()
        revealedRedactedFrameID = nil
        dismissRedactionTooltip()
    }

    public func showRedactionTooltip(for nodeID: Int) {
        guard activeRedactionTooltipNodeID != nodeID else { return }
        withAnimation(.easeOut(duration: 0.14)) {
            activeRedactionTooltipNodeID = nodeID
        }
    }

    func showRedactionTooltip(
        for nodeID: Int,
        state: PhraseLevelRedactionTooltipState
    ) {
        guard state == .queued else { return }
        UIMetricsRecorder.recordDictionary(
            coordinator: coordinator,
            type: .phraseLevelRedactionQueuedHover,
            payload: [
                "nodeID": nodeID,
                "frameID": currentTimelineFrame?.frame.id.value ?? -1,
                "processingStatus": currentTimelineFrame?.processingStatus ?? -1
            ]
        )
    }

    public func dismissRedactionTooltip() {
        guard activeRedactionTooltipNodeID != nil else { return }
        withAnimation(.easeOut(duration: 0.14)) {
            activeRedactionTooltipNodeID = nil
        }
    }

    private func updateOCRNode(
        nodeID: Int,
        transform: (OCRNodeWithText) -> OCRNodeWithText
    ) {
        guard let index = ocrNodes.firstIndex(where: { $0.id == nodeID }) else { return }
        var updatedNodes = ocrNodes
        updatedNodes[index] = transform(updatedNodes[index])
        ocrNodes = updatedNodes
    }

    private func decryptedOCRText(for node: OCRNodeWithText, secret: String) -> String? {
        guard let encryptedText = node.encryptedText else { return nil }
        return ReversibleOCRScrambler.decryptOCRText(
            encryptedText,
            frameID: node.frameId,
            nodeOrder: node.nodeOrder,
            secret: secret
        )
    }

    private func maskedOCRText(for node: OCRNodeWithText) -> String {
        String(repeating: " ", count: node.text.count)
    }

    private func cancelPendingRedactedNodeHideRemoval(for nodeID: Int) {
        pendingRedactedNodeHideRemovalTasks.removeValue(forKey: nodeID)?.cancel()
    }

    private func scheduleRedactedNodeHideRemoval(for nodeID: Int) {
        cancelPendingRedactedNodeHideRemoval(for: nodeID)
        pendingRedactedNodeHideRemovalTasks[nodeID] = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(
                    for: Self.phraseLevelRedactionHideAnimationDuration,
                    clock: .continuous
                )
            } catch {
                return
            }

            guard let self else { return }
            self.hidingRedactedNodePatches.removeValue(forKey: nodeID)
            self.pendingRedactedNodeHideRemovalTasks.removeValue(forKey: nodeID)
        }
    }

    public func togglePhraseLevelRedactionReveal(for node: OCRNodeWithText) {
        guard node.isRedacted else { return }
        guard let frame = currentTimelineFrame?.frame else { return }
        guard Self.isSuccessfulProcessingStatus(currentTimelineFrame?.processingStatus ?? -1) else { return }
        guard let secret = ReversibleOCRScrambler.currentAppWideSecret() else { return }

        if let revealedPatch = revealedRedactedNodePatches.removeValue(forKey: node.id) {
            hidingRedactedNodePatches[node.id] = revealedPatch
            scheduleRedactedNodeHideRemoval(for: node.id)
            if node.encryptedText != nil {
                updateOCRNode(nodeID: node.id) { currentNode in
                    currentNode.replacingText(maskedOCRText(for: currentNode))
                }
            }
            dismissRedactionTooltip()
            return
        }

        revealedRedactedFrameID = frame.id
        Task { [weak self] in
            guard let self else { return }
            do {
                let sourceImage = try await self.sourceCGImageForCurrentFrame(frame: frame)
                guard let patch = self.buildDescrambledPatchImage(
                    node: node,
                    sourceImage: sourceImage,
                    secret: secret
                ) else {
                    return
                }
                let revealedText = self.decryptedOCRText(for: node, secret: secret)

                await MainActor.run {
                    guard self.currentTimelineFrame?.frame.id == frame.id else { return }
                    self.cancelPendingRedactedNodeHideRemoval(for: node.id)
                    self.hidingRedactedNodePatches.removeValue(forKey: node.id)
                    self.revealedRedactedFrameID = frame.id
                    self.revealedRedactedNodePatches[node.id] = patch
                    if let revealedText {
                        self.updateOCRNode(nodeID: node.id) { $0.replacingText(revealedText) }
                    }
                    self.dismissRedactionTooltip()
                }

                UIMetricsRecorder.recordDictionary(
                    coordinator: self.coordinator,
                    type: .phraseLevelRedactionReveal,
                    payload: [
                        "nodeID": node.id,
                        "frameID": node.frameId
                    ]
                )
            } catch {
                Log.warning("[PhraseRedaction] Failed to reveal node \(node.id): \(error.localizedDescription)", category: .ui)
            }
        }
    }

    private func sourceCGImageForCurrentFrame(frame: FrameReference) async throws -> CGImage {
        if isInLiveMode, let liveScreenshot {
            if let cgImage = liveScreenshot.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                return cgImage
            }
        }

        if let videoInfo = currentVideoInfo {
            let data = try await coordinator.getFrameImageFromPath(
                videoPath: videoInfo.videoPath,
                frameIndex: videoInfo.frameIndex,
                enforceTimestampMatch: false
            )
            if let image = cgImage(fromJPEGData: data) {
                return image
            }
        }

        let data = try await coordinator.getFrameImage(
            segmentID: frame.videoID,
            timestamp: frame.timestamp
        )
        guard let image = cgImage(fromJPEGData: data) else {
            throw NSError(
                domain: "SimpleTimelineViewModel",
                code: -8901,
                userInfo: [NSLocalizedDescriptionKey: "Failed to decode frame image for redaction reveal"]
            )
        }
        return image
    }

    private func cgImage(fromJPEGData data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private func buildDescrambledPatchImage(
        node: OCRNodeWithText,
        sourceImage: CGImage,
        secret: String
    ) -> NSImage? {
        let width = sourceImage.width
        let height = sourceImage.height
        guard width > 0, height > 0 else { return nil }

        guard let frameData = try? BGRAImageUtilities.makeData(from: sourceImage) else { return nil }
        let bytesPerRow = width * 4

        let patchRect = BGRAImageUtilities.pixelRect(
            from: CGRect(x: node.x, y: node.y, width: node.width, height: node.height),
            imageWidth: width,
            imageHeight: height
        )
        guard patchRect.width > 1, patchRect.height > 1 else { return nil }

        guard let patch = BGRAImageUtilities.extractPatch(
            from: frameData,
            frameBytesPerRow: bytesPerRow,
            rect: patchRect
        ) else { return nil }

        var descrambledPatch = patch.data
        ReversibleOCRScrambler.descramblePatchBGRA(
            &descrambledPatch,
            width: patch.width,
            height: patch.height,
            bytesPerRow: patch.bytesPerRow,
            frameID: node.frameId,
            nodeID: node.id,
            secret: secret
        )

        guard let patchImage = nsImageFromBGRA(
            data: descrambledPatch,
            width: patch.width,
            height: patch.height,
            bytesPerRow: patch.bytesPerRow
        ) else { return nil }

        return patchImage
    }

    private func nsImageFromBGRA(data: Data, width: Int, height: Int, bytesPerRow: Int) -> NSImage? {
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        let bitmapInfo = CGBitmapInfo(
            rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        )
        guard let cgImage = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
    }

    /// Start polling for OCR status updates
    /// Polls every 500ms until OCR completes or frame changes
    func startOCRStatusPolling(
        for frameID: FrameID,
        expectedGeneration: UInt64 = 0
    ) {
        let generation = expectedGeneration == 0
            ? currentPresentationWorkGeneration()
            : expectedGeneration
        guard canPublishPresentationResult(
            frameID: frameID,
            expectedGeneration: generation
        ) else { return }
        overlayRefreshWorkState.ocrStatusPollingTask?.cancel()

        overlayRefreshWorkState.ocrStatusPollingTask = Task { [weak self] in
            guard let self = self else { return }

            while !Task.isCancelled {
                // Wait 2000ms between polls (coalesces with other 2s timers for power efficiency)
                try? await Task.sleep(for: .nanoseconds(Int64(2_000_000_000)), clock: .continuous)

                guard !Task.isCancelled else { return }

                let canContinue = await MainActor.run {
                    self.canPublishPresentationResult(
                        frameID: frameID,
                        expectedGeneration: generation
                    )
                }
                guard canContinue,
                      let currentFrame = await MainActor.run(body: { self.currentTimelineFrame?.frame }),
                      currentFrame.id == frameID else {
                    return
                }

                // Fetch updated status
                do {
                    let status = try await self.fetchOCRStatusForPresentation(frameID: frameID)

                    await MainActor.run {
                        // Only update if still on the same frame
                        guard self.canPublishPresentationResult(
                            frameID: frameID,
                            expectedGeneration: generation
                        ) else { return }

                        self.setOCRStatus(status)

                        // If completed, also reload the OCR nodes
                        if !status.isInProgress {
                            self.startPresentationOverlayRefresh(
                                expectedGeneration: generation,
                                resetSelection: false,
                                deferIfCriticalFetchActive: false
                            )
                        }
                    }

                    // Stop polling if OCR is no longer in progress
                    if !status.isInProgress {
                        return
                    }
                } catch {
                    Log.error("[OCR-POLL] Failed to poll OCR status: \(error)", category: .ui)
                }
            }
        }
    }

    // MARK: - Live OCR

    func cancelDragStartStillFrameOCR(reason: String) {
        dragStartStillOCRTask?.cancel()
        dragStartStillOCRTask = nil
        dragStartStillOCRInFlightFrameID = nil
        if Self.isTimelineStillLoggingEnabled {
            Log.debug("[Timeline-Still-OCR] CANCEL reason=\(reason)", category: .ui)
        }
    }

    private func recognizeTextFromCGImageForDragStartStillOCR(_ cgImage: CGImage) async throws -> [TextRegion] {
#if DEBUG
        if let override = test_dragStartStillOCRHooks.recognizeTextFromCGImage {
            return try await override(cgImage)
        }
#endif

        let detachedImage = LiveOCRCGImage(image: cgImage)
        return try await Task.detached(priority: .userInitiated) {
            let ocr = VisionOCR()
            return try await ocr.recognizeTextFromCGImage(detachedImage.image)
        }.value
    }

    func triggerDragStartStillFrameOCRIfNeeded(gesture: String) {
        guard !isInLiveMode else { return }
        guard let timelineFrame = currentTimelineFrame else { return }
        guard timelineFrame.processingStatus == 4 else { return }
        let frameID = timelineFrame.frame.id

        guard let stillImage = currentImage,
              let cgImage = stillImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            if Self.isTimelineStillLoggingEnabled {
                Log.info(
                    "[Timeline-Still-OCR] SKIP frameID=\(frameID.value) gesture=\(gesture) processingStatus=\(timelineFrame.processingStatus) reason=no-still-image",
                    category: .ui
                )
            }
            return
        }

        if dragStartStillOCRInFlightFrameID == frameID { return }
        if dragStartStillOCRCompletedFrameID == frameID, !ocrNodes.isEmpty { return }

        dragStartStillOCRRequestID &+= 1
        let requestID = dragStartStillOCRRequestID
        cancelDragStartStillFrameOCR(reason: "new drag-start request")
        dragStartStillOCRInFlightFrameID = frameID
        setOCRStatus(.processing)
        let startedAt = CFAbsoluteTimeGetCurrent()

        if Self.isTimelineStillLoggingEnabled {
            Log.info(
                "[Timeline-Still-OCR] START frameID=\(frameID.value) gesture=\(gesture) processingStatus=\(timelineFrame.processingStatus)",
                category: .ui
            )
        }
        DashboardViewModel.recordStillFrameDragOCR(
            coordinator: coordinator,
            gesture: gesture,
            frameID: frameID.value
        )

        dragStartStillOCRTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.dragStartStillOCRInFlightFrameID == frameID {
                    self.dragStartStillOCRInFlightFrameID = nil
                }
                if requestID == self.dragStartStillOCRRequestID {
                    self.dragStartStillOCRTask = nil
                }
            }

            do {
                let textRegions = try await self.recognizeTextFromCGImageForDragStartStillOCR(cgImage)
                guard !Task.isCancelled else { return }
                guard let currentFrame = self.currentTimelineFrame,
                      currentFrame.frame.id == frameID,
                      currentFrame.processingStatus == 4 else {
                    return
                }

                let nodes = textRegions.enumerated().map { (index, region) in
                    OCRNodeWithText(
                        id: index,
                        frameId: frameID.value,
                        x: region.bounds.origin.x,
                        y: region.bounds.origin.y,
                        width: region.bounds.width,
                        height: region.bounds.height,
                        text: region.text
                    )
                }

                self.setOCRNodes(nodes)
                self.setOCRStatus(.completed)
                self.dragStartStillOCRCompletedFrameID = frameID

                if Self.isTimelineStillLoggingEnabled {
                    let elapsedMs = (CFAbsoluteTimeGetCurrent() - startedAt) * 1000
                    let elapsedSummary = String(format: "%.0f", elapsedMs)
                    Log.info(
                        "[Timeline-Still-OCR] DONE frameID=\(frameID.value) gesture=\(gesture) nodes=\(nodes.count) elapsedMs=\(elapsedSummary)",
                        category: .ui
                    )
                }
            } catch is CancellationError {
                // Intentionally ignored.
            } catch {
                guard !Task.isCancelled else { return }
                if self.currentTimelineFrame?.frame.id == frameID, self.ocrNodes.isEmpty {
                    self.setOCRStatus(.unknown)
                }
                self.dragStartStillOCRCompletedFrameID = nil
                if Self.isTimelineStillLoggingEnabled {
                    Log.warning(
                        "[Timeline-Still-OCR] FAIL frameID=\(frameID.value) gesture=\(gesture) error=\(error.localizedDescription)",
                        category: .ui
                    )
                }
            }
        }
    }

    /// Trigger live OCR with a 350ms debounce
    /// Each call resets the timer - OCR only fires after 350ms of no new calls
    public func performLiveOCR() {
        // Clear stale OCR nodes from previous frame immediately
        // This prevents interaction with old bounding boxes while debounce waits
        setOCRNodes([])
        clearTextSelection()

        liveOCRDebounceTask?.cancel()
        liveOCRDebounceTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .nanoseconds(Int64(350_000_000)), clock: .continuous) // 350ms
            } catch {
                return // Cancelled
            }
            await self?.executeLiveOCR()
        }
    }

    /// Actually perform OCR on the live screenshot
    /// Uses same .accurate pipeline as frame processing
    /// Results are ephemeral (not persisted to database)
    private func executeLiveOCR() async {
        guard isInLiveMode, let liveImage = liveScreenshot else {
            Log.debug("[LiveOCR] Skipped - not in live mode or no screenshot", category: .ui)
            return
        }

        guard !isLiveOCRProcessing else {
            Log.debug("[LiveOCR] Already processing, skipping", category: .ui)
            return
        }

        guard let cgImage = liveImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            Log.error("[LiveOCR] Failed to get CGImage from live screenshot", category: .ui)
            return
        }

        isLiveOCRProcessing = true
        let startTime = CFAbsoluteTimeGetCurrent()

        do {
            let detachedImage = LiveOCRCGImage(image: cgImage)
            let textRegions = try await Task.detached(priority: .userInitiated) {
                let ocr = VisionOCR()
                return try await ocr.recognizeTextFromCGImage(detachedImage.image)
            }.value

            // Only update if still in live mode (user may have scrolled away)
            guard isInLiveMode else {
                isLiveOCRProcessing = false
                return
            }

            let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            let elapsedSummary = String(format: "%.0f", elapsed)

            let nodes = textRegions.enumerated().map { (index, region) in
                OCRNodeWithText(
                    id: index,
                    frameId: -1,
                    x: region.bounds.origin.x,
                    y: region.bounds.origin.y,
                    width: region.bounds.width,
                    height: region.bounds.height,
                    text: region.text
                )
            }

            Log.info("[LiveOCR] Completed in \(elapsedSummary)ms, found \(nodes.count) text regions", category: .ui)
            Log.recordLatency(
                "timeline.live_ocr.total_ms",
                valueMs: elapsed,
                category: .ui,
                summaryEvery: 10,
                warningThresholdMs: 250,
                criticalThresholdMs: 500
            )

            setOCRNodes(nodes)
            setOCRStatus(.completed)
        } catch {
            Log.error("[LiveOCR] Failed: \(error)", category: .ui)
        }
        isLiveOCRProcessing = false
    }
}
