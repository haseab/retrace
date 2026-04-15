import Foundation
import Shared

extension TimelineFrameWindowStateController {
    func deferTrim(
        direction: TimelineTrimDirection,
        anchorFrameID: FrameID?,
        anchorTimestamp: Date?
    ) {
        deferredTrimRequest = TimelineDeferredTrimRequest(
            direction: direction,
            anchorFrameID: anchorFrameID,
            anchorTimestamp: anchorTimestamp
        )
    }

    func consumeDeferredTrimRequest() -> TimelineDeferredTrimRequest? {
        let request = deferredTrimRequest
        deferredTrimRequest = nil
        return request
    }

    func updateDeferredTrimAnchor(frameID: FrameID, timestamp: Date) {
        guard var deferredTrimRequest, deferredTrimRequest.direction == .newer else { return }
        deferredTrimRequest.anchorFrameID = frameID
        deferredTrimRequest.anchorTimestamp = timestamp
        self.deferredTrimRequest = deferredTrimRequest
    }

    func updateDeferredTrimAnchorIfNeeded(
        isActivelyScrolling: Bool,
        currentFrame: TimelineFrame?
    ) {
        guard isActivelyScrolling,
              deferredTrimDirection == .newer,
              let currentFrame else { return }
        updateDeferredTrimAnchor(
            frameID: currentFrame.frame.id,
            timestamp: currentFrame.frame.timestamp
        )
    }

    func handleDeferredTrimIfNeeded(
        trigger: String,
        frames: [TimelineFrame],
        currentIndex: Int,
        maxFrames: Int,
        currentFrame: TimelineFrame?
    ) -> TimelineFrameWindowHandledTrimOutcome? {
        guard let deferredTrimRequest = consumeDeferredTrimRequest() else { return nil }
        guard frames.count > maxFrames else { return nil }

        let applyLogMessage =
            "[Memory] APPLYING deferred trim trigger=\(trigger) direction=\(TimelineFrameWindowTrimSupport.directionLabel(deferredTrimRequest.direction)) frames=\(frames.count)"

        guard let outcome = handleTrimIfNeeded(
            frames: frames,
            preserveDirection: deferredTrimRequest.direction,
            currentIndex: currentIndex,
            maxFrames: maxFrames,
            allowDeferral: false,
            isActivelyScrolling: false,
            currentFrame: currentFrame,
            anchorFrameID: deferredTrimRequest.anchorFrameID,
            anchorTimestamp: deferredTrimRequest.anchorTimestamp,
            reason: "deferred.\(trigger)"
        ) else {
            return nil
        }

        switch outcome {
        case let .deferred(logMessages):
            return .deferred(logMessages: [applyLogMessage] + logMessages)
        case let .applied(applied):
            return .applied(
                TimelineFrameWindowHandledAppliedTrim(
                    frames: applied.frames,
                    beforeCount: applied.beforeCount,
                    logMessages: [applyLogMessage] + applied.logMessages,
                    oldestTimestamp: applied.oldestTimestamp,
                    newestTimestamp: applied.newestTimestamp
                )
            )
        }
    }

    func handleTrimIfNeeded(
        frames: [TimelineFrame],
        preserveDirection: TimelineTrimDirection,
        currentIndex: Int,
        maxFrames: Int,
        allowDeferral: Bool,
        isActivelyScrolling: Bool,
        currentFrame: TimelineFrame?,
        anchorFrameID: FrameID?,
        anchorTimestamp: Date?,
        reason: String
    ) -> TimelineFrameWindowHandledTrimOutcome? {
        guard frames.count > maxFrames else { return nil }

        let beforeCount = frames.count
        guard let trimOutcome = TimelineFrameWindowTrimSupport.prepareTrimOutcome(
            frames: frames,
            preserveDirection: preserveDirection,
            currentIndex: currentIndex,
            maxFrames: maxFrames,
            allowDeferral: allowDeferral,
            isActivelyScrolling: isActivelyScrolling,
            currentFrame: currentFrame,
            anchorFrameID: anchorFrameID,
            anchorTimestamp: anchorTimestamp,
            reason: reason
        ) else {
            return nil
        }

        switch trimOutcome {
        case let .deferred(deferredOutcome):
            deferTrim(
                direction: deferredOutcome.direction,
                anchorFrameID: deferredOutcome.anchorFrameID,
                anchorTimestamp: deferredOutcome.anchorTimestamp
            )
            return .deferred(logMessages: [deferredOutcome.logMessage])

        case let .apply(appliedOutcome):
            let trimMutation = appliedOutcome.mutation
            applyTrimMutation(trimMutation)
            var logMessages = [appliedOutcome.trimLogMessage]
            if let anchorLogMessage = appliedOutcome.anchorLogMessage {
                logMessages.append(anchorLogMessage)
            }
            return .applied(
                TimelineFrameWindowHandledAppliedTrim(
                    frames: trimMutation.frames,
                    beforeCount: beforeCount,
                    logMessages: logMessages,
                    oldestTimestamp: trimMutation.oldestTimestamp,
                    newestTimestamp: trimMutation.newestTimestamp
                )
            )
        }
    }

    func finalizeBoundaryFramesAfterTrimIfNeeded(
        frames: [TimelineFrame],
        preserveDirection: TimelineTrimDirection,
        currentIndex: Int,
        maxFrames: Int,
        isActivelyScrolling: Bool,
        currentFrame: TimelineFrame?,
        reason: String,
        frameBufferCount: Int,
        memoryLogger: (String, Int, Int, Date?, Date?) -> Void
    ) -> [TimelineFrame] {
        guard let outcome = handleTrimIfNeeded(
            frames: frames,
            preserveDirection: preserveDirection,
            currentIndex: currentIndex,
            maxFrames: maxFrames,
            allowDeferral: true,
            isActivelyScrolling: isActivelyScrolling,
            currentFrame: currentFrame,
            anchorFrameID: nil,
            anchorTimestamp: nil,
            reason: reason
        ) else {
            return frames
        }
        return outcome.applying(
            to: frames,
            frameBufferCount: frameBufferCount,
            memoryLogger: memoryLogger
        )
    }
}
