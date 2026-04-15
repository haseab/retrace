import Foundation
import Shared
import App

extension SimpleTimelineViewModel {
    static var pendingDeleteUndoWindowSeconds: TimeInterval { 8 }

    enum PendingDeletePayload {
        case frame(FrameReference)
        case frames([FrameReference])
    }

    struct PendingDeleteOperation {
        let id: UUID
        let payload: PendingDeletePayload
        let removedFrames: [TimelineFrame]
        let removedFrameIDs: [FrameID]
        let restoreStartIndex: Int
        let previousCurrentIndex: Int
        let previousSelectedFrameIndex: Int?
        let undoMessage: String
    }
}

extension SimpleTimelineViewModel {
    // MARK: - Frame Selection & Deletion

    public func selectFrame(at index: Int) {
        guard index >= 0 && index < frames.count else { return }
        navigateToFrame(index)
        selectedFrameIndex = index
    }

    public func clearSelection() {
        selectedFrameIndex = nil
    }

    public func requestDeleteSelectedFrame() {
        guard selectedFrameIndex != nil else { return }
        showDeleteConfirmation = true
    }

    public func confirmDeleteSelectedFrame() {
        guard let index = selectedFrameIndex, index >= 0 && index < frames.count else {
            showDeleteConfirmation = false
            return
        }

        let frameToDelete = frames[index]
        let frameID = frameToDelete.frame.id
        let frameRef = frameToDelete.frame
        let previousCurrentIndex = currentIndex
        let previousSelectedFrameIndex = selectedFrameIndex

        let mutation = frameWindowStore.removeFrame(
            at: index,
            from: frames,
            currentIndex: currentIndex
        )
        mutateFramesOptimistically(reason: .confirmDeleteSelectedFrame) {
            deletedFrameIDs.insert(frameID)
            frames = mutation.frames
        }
        currentIndex = mutation.resultingCurrentIndex
        selectedFrameIndex = mutation.resultingSelectedFrameIndex
        showDeleteConfirmation = false

        refreshCurrentFramePresentation()
        scheduleWindowRefillAfterOptimisticDelete(reason: "confirmDeleteSelectedFrame")

        Log.debug("[Delete] Frame \(frameID) removed from UI (optimistic deletion)", category: .ui)

        stagePendingDelete(
            PendingDeleteOperation(
                id: UUID(),
                payload: .frame(frameRef),
                removedFrames: [frameToDelete],
                removedFrameIDs: [frameID],
                restoreStartIndex: index,
                previousCurrentIndex: previousCurrentIndex,
                previousSelectedFrameIndex: previousSelectedFrameIndex,
                undoMessage: "Frame deleted"
            )
        )
    }

    public func cancelDelete() {
        showDeleteConfirmation = false
        isDeleteSegmentMode = false
    }

    public func undoPendingDelete() {
        guard let operation = pendingDeleteOperation else { return }
        clearPendingDeleteState()
        restoreDeletedOperation(operation, reason: "undo")
        showToast("Deletion undone", icon: "arrow.uturn.backward.circle.fill")
    }

    public func dismissPendingDeleteUndo() {
        guard let operation = pendingDeleteOperation else { return }
        clearPendingDeleteState()
        Task { [weak self] in
            await self?.commitDeleteOperation(operation, reason: "dismiss-undo", restoreOnFailure: true)
        }
    }

    func stagePendingDelete(_ operation: PendingDeleteOperation) {
        commitPendingDeleteIfNeeded(reason: "superseded")

        pendingDeleteOperation = operation
        pendingDeleteUndoMessage = operation.undoMessage

        pendingDeleteCommitTask?.cancel()
        pendingDeleteCommitTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.pendingDeleteUndoWindowSeconds), clock: .continuous)
            guard !Task.isCancelled else { return }
            await self?.commitPendingDeleteAfterUndoWindow()
        }
    }

    func commitPendingDeleteAfterUndoWindow() async {
        guard let operation = pendingDeleteOperation else { return }
        clearPendingDeleteState()
        await commitDeleteOperation(operation, reason: "undo-window-expired", restoreOnFailure: true)
    }

    func commitPendingDeleteIfNeeded(reason: String) {
        guard let operation = pendingDeleteOperation else { return }
        clearPendingDeleteState()
        Task { [weak self] in
            await self?.commitDeleteOperation(operation, reason: reason, restoreOnFailure: false)
        }
    }

    func clearPendingDeleteState() {
        pendingDeleteCommitTask?.cancel()
        pendingDeleteCommitTask = nil
        pendingDeleteOperation = nil
        pendingDeleteUndoMessage = nil
    }

    func commitDeleteOperation(
        _ operation: PendingDeleteOperation,
        reason: String,
        restoreOnFailure: Bool
    ) async {
        do {
            let result: FrameDeletionResult
            switch operation.payload {
            case .frame(let frameRef):
                result = try await coordinator.deleteFrame(
                    frameID: frameRef.id,
                    timestamp: frameRef.timestamp,
                    source: frameRef.source,
                    metricSource: "timeline_delete"
                )
                Log.debug("[Delete] Committed frame deletion frameID=\(frameRef.id.value) reason=\(reason)", category: .ui)
            case .frames(let frameRefs):
                result = try await coordinator.deleteFrames(
                    frameRefs,
                    metricSource: "timeline_delete"
                )
                Log.debug("[Delete] Committed segment deletion frames=\(frameRefs.count) reason=\(reason)", category: .ui)
            }
            clearPendingDeletedFrameIDs(operation.removedFrameIDs, reason: "commit-success.\(reason)")
            if result.hasQueuedFrames {
                showToast(queuedDeletionToastMessage(for: result), icon: "clock.badge.exclamationmark.fill")
            }
        } catch {
            Log.error("[Delete] Failed to persist deletion reason=\(reason): \(error)", category: .ui)
            if restoreOnFailure {
                restoreDeletedOperation(operation, reason: "commit-failed")
                showToast("Delete failed. Restored.", icon: "xmark.circle.fill")
            } else {
                clearPendingDeletedFrameIDs(operation.removedFrameIDs, reason: "commit-failed-no-restore.\(reason)")
                showToast("Delete may not have persisted", icon: "exclamationmark.triangle.fill")
            }
        }
    }

    func queuedDeletionToastMessage(for result: FrameDeletionResult) -> String {
        if result.completedFrames > 0 {
            return "Deleted \(result.completedFrames) frame\(result.completedFrames == 1 ? "" : "s"); queued \(result.queuedFrames) for disk rewrite"
        }
        return "Deletion queued for \(result.queuedFrames) frame\(result.queuedFrames == 1 ? "" : "s")"
    }

    func clearPendingDeletedFrameIDs(_ frameIDs: [FrameID], reason: String) {
        guard !frameIDs.isEmpty else { return }
        let beforeCount = deletedFrameIDs.count
        for frameID in frameIDs {
            deletedFrameIDs.remove(frameID)
        }
        let removedCount = beforeCount - deletedFrameIDs.count
        if removedCount > 0 {
            Log.debug(
                "[Delete] Cleared \(removedCount) pending-deleted frame IDs reason=\(reason) remaining=\(deletedFrameIDs.count)",
                category: .ui
            )
        }
    }

    func scheduleWindowRefillAfterOptimisticDelete(reason: String) {
        _ = checkAndLoadMoreFrames(reason: reason)
    }

    func restoreDeletedOperation(_ operation: PendingDeleteOperation, reason: String) {
        let mutation = frameWindowStore.restoreFrames(
            operation.removedFrames,
            at: operation.restoreStartIndex,
            into: frames,
            previousCurrentIndex: operation.previousCurrentIndex,
            previousSelectedFrameIndex: operation.previousSelectedFrameIndex
        )
        mutateFramesOptimistically(reason: .restoreDeletedOperation(reason)) {
            frames = mutation.frames
            for frameID in operation.removedFrameIDs {
                deletedFrameIDs.remove(frameID)
            }
        }
        currentIndex = mutation.resultingCurrentIndex
        selectedFrameIndex = mutation.resultingSelectedFrameIndex

        refreshCurrentFramePresentation()
    }

    public var selectedFrame: TimelineFrame? {
        guard let index = selectedFrameIndex, index >= 0 && index < frames.count else { return nil }
        return frames[index]
    }

    public var selectedBlock: AppBlock? {
        guard let index = selectedFrameIndex else { return nil }
        return getBlock(forFrameAt: index)
    }

    public func getBlock(forFrameAt index: Int) -> AppBlock? {
        guard let blockIndex = blockIndexForFrame(index) else { return nil }
        let blocks = appBlockSnapshot.blocks
        guard blockIndex >= 0 && blockIndex < blocks.count else { return nil }
        return blocks[blockIndex]
    }

    func blockIndexForFrame(_ index: Int) -> Int? {
        let mapping = appBlockSnapshot.frameToBlockIndex
        guard index >= 0 && index < mapping.count else { return nil }
        return mapping[index]
    }

    public func getOrderedSegmentIds(inBlock block: AppBlock) -> [SegmentID] {
        var seen = Set<Int64>()
        var orderedSegmentIDs: [SegmentID] = []
        for index in block.startIndex...block.endIndex {
            if index < frames.count {
                let segmentIDValue = frames[index].frame.segmentID.value
                guard seen.insert(segmentIDValue).inserted else { continue }
                orderedSegmentIDs.append(SegmentID(value: segmentIDValue))
            }
        }
        return orderedSegmentIDs
    }

    public func getSegmentIds(inBlock block: AppBlock) -> Set<SegmentID> {
        Set(getOrderedSegmentIds(inBlock: block))
    }

    public var selectedSegmentFrameCount: Int {
        selectedBlock?.frameCount ?? 0
    }

    public func confirmDeleteSegment() {
        guard let block = selectedBlock else {
            showDeleteConfirmation = false
            isDeleteSegmentMode = false
            return
        }

        let previousCurrentIndex = currentIndex
        let previousSelectedFrameIndex = selectedFrameIndex
        let removedFrames = Array(frames[block.startIndex...min(block.endIndex, frames.count - 1)])

        var framesToDelete: [FrameReference] = []
        for index in block.startIndex...block.endIndex {
            if index < frames.count {
                let frameRef = frames[index].frame
                deletedFrameIDs.insert(frameRef.id)
                framesToDelete.append(frameRef)
            }
        }

        let mutation = frameWindowStore.removeFrames(
            matching: Set(getOrderedSegmentIds(inBlock: block)),
            from: frames,
            currentIndex: currentIndex,
            preserveCurrentFrameID: currentTimelineFrame?.frame.id
        )
        mutateFramesOptimistically(reason: .confirmDeleteSegment) {
            frames = mutation.frames
        }
        currentIndex = mutation.resultingCurrentIndex
        selectedFrameIndex = mutation.resultingSelectedFrameIndex
        showDeleteConfirmation = false
        isDeleteSegmentMode = false

        refreshCurrentFramePresentation()
        scheduleWindowRefillAfterOptimisticDelete(reason: "confirmDeleteSegment")

        Log.debug("[Delete] Segment with \(block.frameCount) frames removed from UI (optimistic deletion)", category: .ui)

        stagePendingDelete(
            PendingDeleteOperation(
                id: UUID(),
                payload: .frames(framesToDelete),
                removedFrames: removedFrames,
                removedFrameIDs: framesToDelete.map(\.id),
                restoreStartIndex: block.startIndex,
                previousCurrentIndex: previousCurrentIndex,
                previousSelectedFrameIndex: previousSelectedFrameIndex,
                undoMessage: "Segment deleted (\(block.frameCount) frames)"
            )
        )
    }
}
