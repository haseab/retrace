import Foundation
import Shared

extension TimelineFrameWindowStateController {
    func applyRefreshAppendMutation(
        _ result: TimelineRefreshAppendMutationResult,
        maxFrames: Int,
        isActivelyScrolling: Bool,
        frameBufferCount: Int,
        memoryLogger: (String, Int, Int, Date?, Date?) -> Void
    ) -> TimelinePreparedFrameWindowReplacement {
        prepareFrameReplacement(
            currentIndex: result.resultingCurrentIndex,
            oldest: result.oldestTimestamp,
            newest: result.newestTimestamp
        )

        let currentFrameAfterAppend: TimelineFrame?
        if result.resultingCurrentIndex >= 0, result.resultingCurrentIndex < result.frames.count {
            currentFrameAfterAppend = result.frames[result.resultingCurrentIndex]
        } else {
            currentFrameAfterAppend = nil
        }

        let finalFrames = finalizeBoundaryFramesAfterTrimIfNeeded(
            frames: result.frames,
            preserveDirection: .newer,
            currentIndex: result.resultingCurrentIndex,
            maxFrames: maxFrames,
            isActivelyScrolling: isActivelyScrolling,
            currentFrame: currentFrameAfterAppend,
            reason: "refreshFrameData.append",
            frameBufferCount: frameBufferCount,
            memoryLogger: memoryLogger
        )

        return TimelinePreparedFrameWindowReplacement(
            frames: finalFrames,
            resultingCurrentIndex: result.resultingCurrentIndex
        )
    }

    func removeFrame(
        at index: Int,
        from existingFrames: [TimelineFrame],
        currentIndex: Int
    ) -> TimelineOptimisticFrameWindowMutationResult {
        var updatedFrames = existingFrames
        updatedFrames.remove(at: index)

        let resultingCurrentIndex: Int
        if updatedFrames.isEmpty {
            resultingCurrentIndex = 0
        } else if currentIndex >= updatedFrames.count {
            resultingCurrentIndex = max(0, updatedFrames.count - 1)
        } else if currentIndex > index {
            resultingCurrentIndex = currentIndex - 1
        } else {
            resultingCurrentIndex = currentIndex
        }

        updateWindowBoundariesAfterOptimisticRemoval(
            updatedFrames: updatedFrames,
            removedFrames: [existingFrames[index]]
        )

        return TimelineOptimisticFrameWindowMutationResult(
            frames: updatedFrames,
            resultingCurrentIndex: resultingCurrentIndex,
            resultingSelectedFrameIndex: nil
        )
    }

    func removeFrames(
        matching segmentIDs: Set<SegmentID>,
        from existingFrames: [TimelineFrame],
        currentIndex: Int,
        preserveCurrentFrameID: FrameID?
    ) -> TimelineOptimisticFrameWindowMutationResult {
        var updatedFrames: [TimelineFrame] = []
        updatedFrames.reserveCapacity(existingFrames.count)

        var firstRemovedIndex: Int?
        var removedCount = 0

        for (index, frame) in existingFrames.enumerated() {
            let segmentID = SegmentID(value: frame.frame.segmentID.value)
            if segmentIDs.contains(segmentID) {
                firstRemovedIndex = firstRemovedIndex ?? index
                removedCount += 1
            } else {
                updatedFrames.append(frame)
            }
        }

        let removalStartIndex = firstRemovedIndex ?? max(0, min(currentIndex, existingFrames.count))
        let resultingCurrentIndex: Int
        if let preserveCurrentFrameID,
           let preservedIndex = updatedFrames.firstIndex(where: { $0.frame.id == preserveCurrentFrameID }) {
            resultingCurrentIndex = preservedIndex
        } else if updatedFrames.isEmpty {
            resultingCurrentIndex = 0
        } else if currentIndex >= removalStartIndex + removedCount {
            resultingCurrentIndex = max(0, currentIndex - removedCount)
        } else if currentIndex >= removalStartIndex {
            resultingCurrentIndex = max(0, min(removalStartIndex, updatedFrames.count - 1))
        } else {
            resultingCurrentIndex = max(0, min(currentIndex, updatedFrames.count - 1))
        }

        let removedFrames = existingFrames.filter { frame in
            segmentIDs.contains(SegmentID(value: frame.frame.segmentID.value))
        }
        updateWindowBoundariesAfterOptimisticRemoval(
            updatedFrames: updatedFrames,
            removedFrames: removedFrames
        )

        return TimelineOptimisticFrameWindowMutationResult(
            frames: updatedFrames,
            resultingCurrentIndex: resultingCurrentIndex,
            resultingSelectedFrameIndex: nil
        )
    }

    func restoreFrames(
        _ restoredFrames: [TimelineFrame],
        at insertIndex: Int,
        into existingFrames: [TimelineFrame],
        previousCurrentIndex: Int,
        previousSelectedFrameIndex: Int?
    ) -> TimelineOptimisticFrameWindowMutationResult {
        var updatedFrames = existingFrames
        let clampedInsertIndex = min(max(0, insertIndex), updatedFrames.count)
        updatedFrames.insert(contentsOf: restoredFrames, at: clampedInsertIndex)
        updateWindowBoundaries(frames: updatedFrames)

        let resultingCurrentIndex: Int
        let resultingSelectedFrameIndex: Int?
        if updatedFrames.isEmpty {
            resultingCurrentIndex = 0
            resultingSelectedFrameIndex = nil
        } else {
            resultingCurrentIndex = min(max(0, previousCurrentIndex), updatedFrames.count - 1)
            if let previousSelectedFrameIndex,
               previousSelectedFrameIndex >= 0,
               previousSelectedFrameIndex < updatedFrames.count {
                resultingSelectedFrameIndex = previousSelectedFrameIndex
            } else {
                resultingSelectedFrameIndex = nil
            }
        }

        return TimelineOptimisticFrameWindowMutationResult(
            frames: updatedFrames,
            resultingCurrentIndex: resultingCurrentIndex,
            resultingSelectedFrameIndex: resultingSelectedFrameIndex
        )
    }

    private func updateWindowBoundariesAfterOptimisticRemoval(
        updatedFrames: [TimelineFrame],
        removedFrames: [TimelineFrame]
    ) {
        if updatedFrames.isEmpty {
            setWindowBoundaries(
                oldest: removedFrames.first?.frame.timestamp,
                newest: removedFrames.last?.frame.timestamp
            )
            resetBoundaryStateForReloadWindow()
        } else {
            updateWindowBoundaries(frames: updatedFrames)
        }
    }
}
