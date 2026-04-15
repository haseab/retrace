import Foundation
import Shared

enum TimelineTrimDirection {
    case older
    case newer
}

enum TimelineBoundaryLoadDirection {
    case older
    case newer

    var label: String {
        switch self {
        case .older:
            return "BoundaryOlder"
        case .newer:
            return "BoundaryNewer"
        }
    }
}

struct TimelineBoundaryLoadContext: Equatable {
    let generation: UInt64
    let filters: FilterCriteria
    let boundaryFrameID: FrameID
}

struct TimelinePreparedFrameWindowReplacement {
    let frames: [TimelineFrame]
    let resultingCurrentIndex: Int
}

struct TimelineOptimisticFrameWindowMutationResult {
    let frames: [TimelineFrame]
    let resultingCurrentIndex: Int
    let resultingSelectedFrameIndex: Int?
}

struct TimelineDeferredTrimRequest {
    let direction: TimelineTrimDirection
    var anchorFrameID: FrameID?
    var anchorTimestamp: Date?
}

struct TimelineBoundaryLoadTrigger: Sendable {
    let older: Bool
    let newer: Bool

    var any: Bool {
        older || newer
    }
}

struct TimelineEdgeBlockSummary {
    let bundleID: String?
    let startIndex: Int
    let endIndex: Int
    let frameCount: Int
    let startTimestamp: Date
    let endTimestamp: Date
}

struct TimelineFrameWindowTrimResult {
    let frames: [TimelineFrame]
    let targetIndexAfterTrim: Int?
    let excessCount: Int
}

struct TimelineFrameWindowMutationResult {
    let frames: [TimelineFrame]
    let currentIndex: Int
    let oldestTimestamp: Date?
    let newestTimestamp: Date?
    let shouldResetSubFrameOffset: Bool
}

enum TimelineOlderBoundaryPageQueryOutcome: Sendable {
    case skippedNoOverlap(rangeStart: Date, rangeEnd: Date)
    case loaded(TimelineOlderBoundaryPageQueryResult)
}

struct TimelineOlderBoundaryPageQueryResult: Sendable {
    let framesDescending: [FrameWithVideoInfo]
    let queryElapsedMs: Double
}

struct TimelineNewerBoundaryPageQueryResult: Sendable {
    let frames: [FrameWithVideoInfo]
    let queryElapsedMs: Double
}

struct TimelineOlderBoundaryApplyPlan {
    let addedFrames: [TimelineFrame]
    let clampedPreviousIndex: Int
    let resultingCurrentIndex: Int
    let previousFrameTimestamp: Date?
}

struct TimelineOlderBoundaryPreparedLoad {
    let queryElapsedMs: Double
    let applyPlan: TimelineOlderBoundaryApplyPlan
}

enum TimelineOlderBoundaryPreparedOutcome {
    case reachedStart(skippedDueToNoOverlap: Bool, queryElapsedMs: Double?)
    case apply(TimelineOlderBoundaryPreparedLoad)
}

struct TimelineNewerBoundaryDuplicateOnlyResult {
    let attemptedFrameCount: Int
    let newestFrameID: Int64
    let duplicateFrameID: Int64
}

struct TimelineNewerBoundaryApplyPlan {
    let addedFrames: [TimelineFrame]
    let duplicateCount: Int
    let wasAtNewestBeforeAppend: Bool
    let didPinToNewest: Bool
    let resultingCurrentIndex: Int
}

struct TimelineNewerBoundaryPreparedLoad {
    let queryElapsedMs: Double
    let requestedFrameCount: Int
    let applyPlan: TimelineNewerBoundaryApplyPlan
}

enum TimelineNewerBoundaryApplyPlanOutcome {
    case duplicateOnly(TimelineNewerBoundaryDuplicateOnlyResult)
    case append(TimelineNewerBoundaryApplyPlan)
}

enum TimelineNewerBoundaryPreparedOutcome {
    case reachedEndEmpty(queryElapsedMs: Double)
    case reachedEndDuplicateOnly(TimelineNewerBoundaryDuplicateOnlyResult, queryElapsedMs: Double)
    case apply(TimelineNewerBoundaryPreparedLoad)
}

struct TimelineBoundaryLoadTiming {
    let loadElapsedMs: Double
    let totalFromTraceMs: Double?
}

struct TimelineOlderBoundaryLoadCompletionSummary {
    let beforeCount: Int
    let afterCount: Int
    let addedCount: Int
    let previousIndex: Int
    let currentIndex: Int
    let oldFirstTimestamp: Date
    let previousFrameTimestamp: Date?
    let bridgeTimestamp: Date?
    let bridgeGapSeconds: TimeInterval?
}

struct TimelineNewerBoundaryLoadCompletionSummary {
    let beforeCount: Int
    let afterCount: Int
    let addedCount: Int
    let previousIndex: Int
    let currentIndex: Int
    let oldLastTimestamp: Date?
    let wasAtNewestBeforeAppend: Bool
    let didPinToNewest: Bool
    let bridgeTimestamp: Date?
    let bridgeGapSeconds: TimeInterval?
}

struct TimelineOlderBoundaryApplyResult {
    let mutationResult: TimelineFrameWindowMutationResult
    let completionSummary: TimelineOlderBoundaryLoadCompletionSummary
}

struct TimelineNewerBoundaryApplyResult {
    let mutationResult: TimelineFrameWindowMutationResult
    let completionSummary: TimelineNewerBoundaryLoadCompletionSummary
}

struct TimelineBoundaryAppliedLoad {
    let frames: [TimelineFrame]
    let resultingSubFrameOffset: Double?
    let cmdFPlayheadEvent: String
    let cmdFPlayheadExtra: String

    func apply(to frames: inout [TimelineFrame], subFrameOffset: inout CGFloat) {
        frames = self.frames
        if let resultingSubFrameOffset {
            subFrameOffset = CGFloat(resultingSubFrameOffset)
        }
    }
}

enum TimelineRefreshExistingWindowAction: Equatable {
    case skipRefresh
    case refresh(shouldNavigateToNewest: Bool)
}

struct TimelineRefreshAppendMutationResult {
    let frames: [TimelineFrame]
    let resultingCurrentIndex: Int
    let appendedFrameCount: Int
    let oldestTimestamp: Date?
    let newestTimestamp: Date?
}

enum TimelineRefreshFetchAction {
    case noChange
    case pinToNewestExisting(resultingCurrentIndex: Int)
    case requireFullReloadToNewest
    case append(TimelineRefreshAppendMutationResult)
}

struct TimelineFrameWindowDeferredTrimDecision {
    let anchorFrameID: FrameID?
    let anchorTimestamp: Date?
}

struct TimelineFrameWindowDeferredTrimOutcome {
    let direction: TimelineTrimDirection
    let anchorFrameID: FrameID?
    let anchorTimestamp: Date?
    let logMessage: String
}

struct TimelineFrameWindowAppliedTrimOutcome {
    let mutation: TimelineFrameWindowTrimMutationResult
    let trimLogMessage: String
    let anchorLogMessage: String?
}

struct TimelineFrameWindowHandledAppliedTrim {
    let frames: [TimelineFrame]
    let beforeCount: Int
    let logMessages: [String]
    let oldestTimestamp: Date?
    let newestTimestamp: Date?
}

enum TimelineFrameWindowHandledTrimOutcome {
    case deferred(logMessages: [String])
    case applied(TimelineFrameWindowHandledAppliedTrim)

    func applying(
        to currentFrames: [TimelineFrame],
        frameBufferCount: Int,
        memoryLogger: (String, Int, Int, Date?, Date?) -> Void
    ) -> [TimelineFrame] {
        switch self {
        case let .deferred(logMessages):
            for message in logMessages {
                Log.info(message, category: .ui)
            }
            return currentFrames

        case let .applied(applied):
            for message in applied.logMessages {
                Log.info(message, category: .ui)
            }
            memoryLogger(
                "AFTER TRIM (\(applied.beforeCount)→\(applied.frames.count))",
                applied.frames.count,
                frameBufferCount,
                applied.oldestTimestamp,
                applied.newestTimestamp
            )
            return applied.frames
        }
    }
}

enum TimelineFrameWindowTrimOutcome {
    case deferred(TimelineFrameWindowDeferredTrimOutcome)
    case apply(TimelineFrameWindowAppliedTrimOutcome)
}

struct TimelineFrameWindowTrimMutationResult {
    let frames: [TimelineFrame]
    let pendingCurrentIndexAfterFrameReplacement: Int?
    let excessCount: Int
    let oldestTimestamp: Date?
    let newestTimestamp: Date?
    let boundaryToRestoreAfterTrim: TimelineTrimDirection
    let resolvedAnchorFrameID: FrameID?
    let resolvedAnchorTimestamp: Date?
}
