import Foundation
import SwiftUI
import AppKit
import Shared
import App
import Processing

/// Shared timeline configuration
public enum TimelineZoomSettings {
    /// Fit-to-screen baseline expressed as a percentage.
    public static let resetPercent: CGFloat = 100.0
    /// Historical maximum detail stop for the tape zoom curve.
    public static let legacyTimelineDetailPercent: CGFloat = 1000.0
    /// Single source of truth for the configured maximum zoom ceiling.
    public static let maxPercent: CGFloat = 3000.0
    /// Minimum in-frame zoom scale.
    public static let minFrameScale: CGFloat = 0.25
    /// Maximum in-frame zoom scale derived from the configured ceiling.
    public static let maxFrameScale: CGFloat = maxPercent / resetPercent
    /// Slider max preserving the old tape curve up to the legacy detail stop.
    public static let maxTimelineZoomLevel: CGFloat = maxFrameScale / (legacyTimelineDetailPercent / resetPercent)

    public static var resetLabel: String {
        "\(Int(resetPercent))%"
    }

    public static func percentLabel(forScale scale: CGFloat) -> String {
        "\(Int(scale * resetPercent))%"
    }
}

public enum TimelineConfig {
    /// Minimum pixels per frame at 0% zoom (most zoomed out)
    public static let minPixelsPerFrame: CGFloat = 8.0
    /// Pixels per frame at the legacy max-detail stop (1.0 zoom level).
    public static let basePixelsPerFrame: CGFloat = 75.0
    /// Extended max-detail density derived from the shared zoom ceiling.
    public static let maxPixelsPerFrame: CGFloat = minPixelsPerFrame * TimelineZoomSettings.maxFrameScale
    /// Maximum timeline zoom level exposed by the slider.
    public static let maxZoomLevel: CGFloat = TimelineZoomSettings.maxTimelineZoomLevel
    /// Default zoom level, preserving the existing initial tape density.
    public static let defaultZoomLevel: CGFloat = 0.6
}

/// Configuration for infinite scroll rolling window
enum WindowConfig {
    static let maxFrames = 100            // Maximum frames in memory
    static let loadThreshold = 20       // Start loading when within N frames of edge
    static let loadBatchSize = 35        // Frames to load per batch
    static let loadWindowSpanSeconds: TimeInterval = 24 * 60 * 60 // Bounded window for load-more queries
    static let nearestFallbackBatchSize = 35 // Frames to fetch when fallback nearest probe is needed
    static let olderSparseRetryThreshold = loadBatchSize // Retry with nearest fallback when bounded probe under-fills the batch
    static let newerSparseRetryThreshold = loadBatchSize // Retry with nearest fallback when bounded probe under-fills the batch
    static let presentationOverlayIdleDelayNanoseconds: Int64 = 150_000_000
}

struct TimelineMediaPresentationState {
    var currentImage: NSImage?
    var currentImageFrameID: FrameID?
    var waitingFallbackImage: NSImage?
    var waitingFallbackImageFrameID: FrameID?
    var pendingVideoPresentationFrameID: FrameID?
    var isPendingVideoPresentationReady = false
    var isInLiveMode = false
    var liveScreenshot: NSImage?
    var frameNotReady = false
    var frameLoadError = false
    var isLoading = false
    var error: String?
    var isLiveOCRProcessing = false
    var isTapeHidden = false
    var forceVideoReload = false
}

struct TimelineOverlayPresentationState {
    var urlBoundingBox: URLBoundingBox?
    var hyperlinkMatches: [OCRHyperlinkMatch] = []
    var frameMousePosition: CGPoint?
    var ocrStatus: OCRProcessingStatus = .unknown
    var selectionStart: (nodeID: Int, charIndex: Int)?
    var selectionEnd: (nodeID: Int, charIndex: Int)?
    var isHoveringURL = false
}

public enum TimelineCalendarKeyboardFocus: Sendable {
    case dateGrid
    case timeGrid
}

struct TimelineDateSearchUIState {
    var isDateSearchActive = false
    var dateSearchText = ""
    var isCalendarPickerVisible = false
    var datesWithFrames: Set<Date> = []
    var hoursWithFrames: [Date] = []
    var selectedCalendarDate: Date?
    var calendarKeyboardFocus: TimelineCalendarKeyboardFocus = .dateGrid
    var selectedCalendarHour: Int?
}

public enum TimelineToastTone: Sendable {
    case success
    case error
}

struct TimelineChromeUIState {
    var isZoomSliderExpanded = false
    var isMoreOptionsMenuVisible = false
    var showTextSelectionHint = false
    var showControlsHiddenRestoreHintBanner = false
    var highlightShowControlsContextMenuRow = false
    var showPositionRecoveryHintBanner = false
    var showScrollOrientationHintBanner = false
    var areControlsHidden = false
    var showVideoBoundaries = false
    var showSegmentBoundaries = false
    var showBrowserURLDebugWindow = false
    var toastMessage: String?
    var toastIcon: String?
    var toastTone: TimelineToastTone = .success
    var toastVisible = false
    var isPlaying = false
    var playbackSpeed = 2.0
}

struct TimelineViewportUIState {
    var zoomLevel: CGFloat = TimelineConfig.defaultZoomLevel
    var isActivelyScrolling = false
}

struct TimelineSelectionUIState {
    var ocrNodes: [OCRNodeWithText] = []
    var revealedRedactedNodePatches: [Int: NSImage] = [:]
    var hidingRedactedNodePatches: [Int: NSImage] = [:]
    var activeRedactionTooltipNodeID: Int?
    var previousOcrNodes: [OCRNodeWithText] = []
    var isAllTextSelected = false
    var dragStartPoint: CGPoint?
    var dragEndPoint: CGPoint?
    var boxSelectedNodeIDs: Set<Int> = []
}

struct TimelineZoomInteractionUIState {
    var isZoomRegionActive = false
    var zoomRegion: CGRect?
    var isDraggingZoomRegion = false
    var zoomRegionDragStart: CGPoint?
    var zoomRegionDragEnd: CGPoint?
    var shiftDragDisplaySnapshot: NSImage?
    var shiftDragDisplaySnapshotFrameID: Int64?
    var isZoomTransitioning = false
    var isZoomExitTransitioning = false
    var zoomTransitionStartRect: CGRect?
    var zoomTransitionProgress: CGFloat = 0
    var zoomTransitionBlurOpacity: CGFloat = 0
    var frameZoomScale: CGFloat = 1.0
    var frameZoomOffset: CGSize = .zero
}

struct TimelineShellUIState {
    var selectedFrameIndex: Int?
    var showDeleteConfirmation = false
    var isDeleteSegmentMode = false
    var deletedFrameIDs: Set<FrameID> = []
    var pendingDeleteUndoMessage: String?
    var showContextMenu = false
    var contextMenuLocation: CGPoint = .zero
    var showTimelineContextMenu = false
    var timelineContextMenuLocation: CGPoint = .zero
    var timelineContextMenuSegmentIndex: Int?
    var showTimelineTapeRightClickHintBanner = false
    var hidingSegmentBlockRange: ClosedRange<Int>?
}

/// Memory tracking for debugging frame accumulation issues
enum MemoryTracker {
    /// Log memory state for debugging
    static func logMemoryState(
        context: String,
        frameCount: Int,
        frameBufferCount: Int,
        oldestTimestamp: Date?,
        newestTimestamp: Date?
    ) {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "HH:mm:ss"

        let oldest = oldestTimestamp.map { dateFormatter.string(from: $0) } ?? "nil"
        let newest = newestTimestamp.map { dateFormatter.string(from: $0) } ?? "nil"

        Log.debug(
            "[Memory] \(context) | frames=\(frameCount)/\(WindowConfig.maxFrames) | frameBuffer=\(frameBufferCount) | window=[\(oldest) → \(newest)]",
            category: .ui
        )
    }
}

/// Represents a block of consecutive frames from the same app
public struct AppBlock: Identifiable, Sendable {
    // Use stable ID based on content to prevent unnecessary view recreation during infinite scroll
    public var id: String {
        "\(bundleID ?? "nil")_\(startIndex)_\(endIndex)"
    }
    public let bundleID: String?
    public let appName: String?
    public let startIndex: Int
    public let endIndex: Int
    public let frameCount: Int
    /// Unique tag IDs applied anywhere in this block (excluding hidden tag)
    public let tagIDs: [Int64]
    /// Whether any segment in this block has one or more linked comments.
    public let hasComments: Bool

    /// Time gap in seconds BEFORE this block (if > 2 minutes, a gap indicator should be shown)
    public let gapBeforeSeconds: TimeInterval?

    /// Calculate width based on current pixels per frame
    public func width(pixelsPerFrame: CGFloat) -> CGFloat {
        CGFloat(frameCount) * pixelsPerFrame
    }

    /// Format the gap duration for display (e.g., "5m", "2h 15m", "3d 5h")
    public var formattedGapBefore: String? {
        guard let gap = gapBeforeSeconds, gap >= 120 else { return nil }

        let totalMinutes = Int(gap) / 60
        let totalHours = totalMinutes / 60
        let days = totalHours / 24
        let remainingHours = totalHours % 24
        let remainingMinutes = totalMinutes % 60

        if days > 0 {
            // Show days and hours (skip minutes for large gaps)
            if remainingHours > 0 {
                return "\(days)d \(remainingHours)h"
            } else {
                return "\(days)d"
            }
        } else if totalHours > 0 {
            // Show hours and minutes
            if remainingMinutes > 0 {
                return "\(totalHours)h \(remainingMinutes)m"
            } else {
                return "\(totalHours)h"
            }
        } else {
            return "\(totalMinutes)m"
        }
    }
}

/// Local draft attachment selected in the timeline comment composer.
public struct CommentAttachmentDraft: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let sourceURL: URL
    public let fileName: String
    public let mimeType: String?
    public let sizeBytes: Int64?

    public init(
        id: UUID = UUID(),
        sourceURL: URL,
        fileName: String,
        mimeType: String?,
        sizeBytes: Int64?
    ) {
        self.id = id
        self.sourceURL = sourceURL
        self.fileName = fileName
        self.mimeType = mimeType
        self.sizeBytes = sizeBytes
    }
}

/// Segment metadata shown in the "All Comments" timeline rows.
public struct CommentTimelineSegmentContext: Sendable, Equatable {
    public let segmentID: SegmentID
    public let appBundleID: String?
    public let appName: String?
    public let browserURL: String?
    public let referenceTimestamp: Date

    public init(
        segmentID: SegmentID,
        appBundleID: String?,
        appName: String?,
        browserURL: String?,
        referenceTimestamp: Date
    ) {
        self.segmentID = segmentID
        self.appBundleID = appBundleID
        self.appName = appName
        self.browserURL = browserURL
        self.referenceTimestamp = referenceTimestamp
    }
}

/// Flattened row model for browsing comments around an anchor comment.
public struct CommentTimelineRow: Identifiable, Sendable, Equatable {
    public let comment: SegmentComment
    public let context: CommentTimelineSegmentContext?
    public let primaryTagName: String?

    public var id: SegmentCommentID { comment.id }

    public init(
        comment: SegmentComment,
        context: CommentTimelineSegmentContext?,
        primaryTagName: String?
    ) {
        self.comment = comment
        self.context = context
        self.primaryTagName = primaryTagName
    }
}

/// OCR node mapped to a browser hyperlink extracted from live DOM.
/// Coordinates are normalized (0.0-1.0) in the same space as OCR nodes.
public struct OCRHyperlinkMatch: Identifiable, Equatable, Sendable {
    public let id: String
    public let nodeID: Int
    public let x: CGFloat
    public let y: CGFloat
    public let width: CGFloat
    public let height: CGFloat
    public let url: String
    public let nodeText: String
    public let domText: String
    public let highlightStartIndex: Int
    public let highlightEndIndex: Int
    public let confidence: Double

    public init(
        id: String,
        nodeID: Int,
        x: CGFloat,
        y: CGFloat,
        width: CGFloat,
        height: CGFloat,
        url: String,
        nodeText: String,
        domText: String,
        highlightStartIndex: Int,
        highlightEndIndex: Int,
        confidence: Double
    ) {
        self.id = id
        self.nodeID = nodeID
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.url = url
        self.nodeText = nodeText
        self.domText = domText
        self.highlightStartIndex = highlightStartIndex
        self.highlightEndIndex = highlightEndIndex
        self.confidence = confidence
    }

    /// Normalized X origin for the linked word span (falls back to full node).
    public var highlightX: CGFloat {
        let range = clampedHighlightRange
        let fractions = OCRTextLayoutEstimator.spanFractions(
            in: nodeText,
            start: range.start,
            end: range.end
        )
        return x + (width * fractions.start)
    }

    /// Normalized width for the linked word span (falls back to full node).
    public var highlightWidth: CGFloat {
        let range = clampedHighlightRange
        let fractions = OCRTextLayoutEstimator.spanFractions(
            in: nodeText,
            start: range.start,
            end: range.end
        )
        return width * max(fractions.end - fractions.start, 0)
    }

    private var clampedHighlightRange: (start: Int, end: Int) {
        let textCount = nodeText.count
        guard textCount > 0 else { return (start: 0, end: 1) }

        var start = min(max(highlightStartIndex, 0), textCount - 1)
        var end = min(max(highlightEndIndex, start + 1), textCount)
        if end <= start {
            start = 0
            end = textCount
        }
        return (start, end)
    }
}

struct TimelineSnapshotFrameInput: Sendable {
    let bundleID: String?
    let appName: String?
    let segmentIDValue: Int64
    let timestamp: Date
    let videoPath: String?
}

struct TimelineAppBlockSnapshot: Sendable {
    let blocks: [AppBlock]
    let frameToBlockIndex: [Int]
    let videoBoundaryIndices: [Int]
    let segmentBoundaryIndices: [Int]

    static let empty = TimelineAppBlockSnapshot(
        blocks: [],
        frameToBlockIndex: [],
        videoBoundaryIndices: [],
        segmentBoundaryIndices: []
    )
}

enum TimelineAppBlockBuilder {
    static let minimumGapThreshold: TimeInterval = 120

    static func buildSnapshot(
        from frameList: [TimelineSnapshotFrameInput],
        segmentTagsMap: [Int64: Set<Int64>],
        segmentCommentCountsMap: [Int64: Int],
        hiddenTagID: Int64?
    ) -> TimelineAppBlockSnapshot {
        if Task.isCancelled {
            return .empty
        }

        guard !frameList.isEmpty else {
            return .empty
        }

        var blocks: [AppBlock] = []
        var frameToBlockIndex = Array(repeating: 0, count: frameList.count)
        var videoBoundaries: [Int] = []
        var segmentBoundaries: [Int] = []

        var currentBundleID: String? = frameList[0].bundleID
        var blockStartIndex = 0
        var currentBlockIndex = 0
        var gapBeforeCurrentBlock: TimeInterval? = nil
        var previousVideoPath = frameList[0].videoPath
        var previousSegmentID = frameList[0].segmentIDValue
        var currentBlockTagIDs = Set<Int64>()
        var currentBlockHasComments = false

        for index in frameList.indices {
            if Task.isCancelled {
                return .empty
            }

            let timelineFrame = frameList[index]
            let frameBundleID = timelineFrame.bundleID

            if index > 0 {
                let currentVideoPath = timelineFrame.videoPath
                if let previousVideoPath,
                   let currentVideoPath,
                   previousVideoPath != currentVideoPath {
                    videoBoundaries.append(index)
                }
                previousVideoPath = currentVideoPath

                if timelineFrame.segmentIDValue != previousSegmentID {
                    segmentBoundaries.append(index)
                }
                previousSegmentID = timelineFrame.segmentIDValue
            }

            var gapDuration: TimeInterval = 0
            if index > 0 {
                let previousTimestamp = frameList[index - 1].timestamp
                let currentTimestamp = timelineFrame.timestamp
                gapDuration = currentTimestamp.timeIntervalSince(previousTimestamp)
            }

            let hasSignificantGap = gapDuration >= minimumGapThreshold
            let appChanged = frameBundleID != currentBundleID

            if (appChanged || hasSignificantGap) && index > 0 {
                blocks.append(
                    AppBlock(
                        bundleID: currentBundleID,
                        appName: frameList[blockStartIndex].appName,
                        startIndex: blockStartIndex,
                        endIndex: index - 1,
                        frameCount: index - blockStartIndex,
                        tagIDs: filteredTagIDs(from: currentBlockTagIDs, hiddenTagID: hiddenTagID),
                        hasComments: currentBlockHasComments,
                        gapBeforeSeconds: gapBeforeCurrentBlock
                    )
                )

                currentBlockIndex += 1
                currentBundleID = frameBundleID
                blockStartIndex = index
                gapBeforeCurrentBlock = hasSignificantGap ? gapDuration : nil
                currentBlockTagIDs.removeAll(keepingCapacity: true)
                currentBlockHasComments = false
            }

            if let segmentTagIDs = segmentTagsMap[timelineFrame.segmentIDValue] {
                currentBlockTagIDs.formUnion(segmentTagIDs)
            }

            if let commentCount = segmentCommentCountsMap[timelineFrame.segmentIDValue], commentCount > 0 {
                currentBlockHasComments = true
            }

            frameToBlockIndex[index] = currentBlockIndex
        }

        blocks.append(
            AppBlock(
                bundleID: currentBundleID,
                appName: frameList[blockStartIndex].appName,
                startIndex: blockStartIndex,
                endIndex: frameList.count - 1,
                frameCount: frameList.count - blockStartIndex,
                tagIDs: filteredTagIDs(from: currentBlockTagIDs, hiddenTagID: hiddenTagID),
                hasComments: currentBlockHasComments,
                gapBeforeSeconds: gapBeforeCurrentBlock
            )
        )

        return TimelineAppBlockSnapshot(
            blocks: blocks,
            frameToBlockIndex: frameToBlockIndex,
            videoBoundaryIndices: videoBoundaries,
            segmentBoundaryIndices: segmentBoundaries
        )
    }

    private static func filteredTagIDs(from tagIDs: Set<Int64>, hiddenTagID: Int64?) -> [Int64] {
        tagIDs
            .filter { tagID in
                guard let hiddenTagID else { return true }
                return tagID != hiddenTagID
            }
            .sorted()
    }
}

final class TimelineBlockSnapshotController {
    private var cachedSnapshot: TimelineAppBlockSnapshot?
    private var snapshotRevisionValue: Int = 0
    private var snapshotDirty = false
    private var snapshotBuildGeneration: UInt64 = 0
    private var snapshotBuildTask: Task<TimelineAppBlockSnapshot, Never>?
    private var snapshotApplyTask: Task<Void, Never>?

    private var cachedHiddenTagIDValue: Int64?
    private var cachedAvailableTagsByID: [Int64: Tag] = [:]
    private var tagCatalogRevisionValue: UInt64 = 0

    var availableTagsByID: [Int64: Tag] {
        cachedAvailableTagsByID
    }

    var tagCatalogRevision: UInt64 {
        tagCatalogRevisionValue
    }

    var appBlockSnapshotRevision: Int {
        snapshotRevisionValue
    }

    var hiddenTagIDValue: Int64? {
        cachedHiddenTagIDValue
    }

    var latestCachedSnapshot: TimelineAppBlockSnapshot? {
        cachedSnapshot
    }

    var hasCachedSnapshot: Bool {
        cachedSnapshot != nil
    }

    func snapshot(
        frameInputs: [TimelineSnapshotFrameInput],
        segmentTagsMap: [Int64: Set<Int64>],
        segmentCommentCountsMap: [Int64: Int]
    ) -> TimelineAppBlockSnapshot {
        if snapshotDirty {
            scheduleSnapshotRebuild(
                reason: "appBlockSnapshot.read",
                frameInputs: frameInputs,
                segmentTagsMap: segmentTagsMap,
                segmentCommentCountsMap: segmentCommentCountsMap,
                isVerboseLoggingEnabled: false
            )
        }

        if let cachedSnapshot {
            return cachedSnapshot
        }

        let builtSnapshot = TimelineAppBlockBuilder.buildSnapshot(
            from: frameInputs,
            segmentTagsMap: segmentTagsMap,
            segmentCommentCountsMap: segmentCommentCountsMap,
            hiddenTagID: cachedHiddenTagIDValue
        )
        cachedSnapshot = builtSnapshot
        snapshotDirty = false
        snapshotRevisionValue &+= 1
        return builtSnapshot
    }

    func refreshTagCachesAndInvalidateSnapshotIfNeeded(
        availableTags: [Tag],
        reason: String,
        frameInputs: [TimelineSnapshotFrameInput],
        segmentTagsMap: [Int64: Set<Int64>],
        segmentCommentCountsMap: [Int64: Int],
        isVerboseLoggingEnabled: Bool
    ) {
        cachedAvailableTagsByID = Dictionary(
            uniqueKeysWithValues: availableTags.map { ($0.id.value, $0) }
        )
        tagCatalogRevisionValue &+= 1

        let previousHiddenTagID = cachedHiddenTagIDValue
        cachedHiddenTagIDValue = availableTags.first(where: { $0.isHidden })?.id.value

        if previousHiddenTagID != cachedHiddenTagIDValue {
            invalidateSnapshot(
                reason: "\(reason).hiddenTagChanged",
                frameInputs: frameInputs,
                segmentTagsMap: segmentTagsMap,
                segmentCommentCountsMap: segmentCommentCountsMap,
                isVerboseLoggingEnabled: isVerboseLoggingEnabled
            )
        }
    }

    func invalidateSnapshot(
        reason: String,
        frameInputs: [TimelineSnapshotFrameInput],
        segmentTagsMap: [Int64: Set<Int64>],
        segmentCommentCountsMap: [Int64: Int],
        isVerboseLoggingEnabled: Bool
    ) {
        snapshotDirty = true
        scheduleSnapshotRebuild(
            reason: reason,
            frameInputs: frameInputs,
            segmentTagsMap: segmentTagsMap,
            segmentCommentCountsMap: segmentCommentCountsMap,
            isVerboseLoggingEnabled: isVerboseLoggingEnabled
        )
    }

    func refreshSnapshotImmediately(
        reason: String,
        frameInputs: [TimelineSnapshotFrameInput],
        segmentTagsMap: [Int64: Set<Int64>],
        segmentCommentCountsMap: [Int64: Int],
        isVerboseLoggingEnabled: Bool
    ) {
        let builtSnapshot = TimelineAppBlockBuilder.buildSnapshot(
            from: frameInputs,
            segmentTagsMap: segmentTagsMap,
            segmentCommentCountsMap: segmentCommentCountsMap,
            hiddenTagID: cachedHiddenTagIDValue
        )
        cachedSnapshot = builtSnapshot
        snapshotDirty = false
        snapshotRevisionValue &+= 1

        if isVerboseLoggingEnabled {
            Log.debug(
                "[TimelineBlocks] Applied immediate snapshot reason='\(reason)' blocks=\(builtSnapshot.blocks.count)",
                category: .ui
            )
        }
    }

    func cancelPendingWork() {
        snapshotBuildTask?.cancel()
        snapshotApplyTask?.cancel()
    }

    private func scheduleSnapshotRebuild(
        reason: String,
        frameInputs: [TimelineSnapshotFrameInput],
        segmentTagsMap: [Int64: Set<Int64>],
        segmentCommentCountsMap: [Int64: Int],
        isVerboseLoggingEnabled: Bool
    ) {
        guard snapshotDirty else { return }

        let hiddenTagID = cachedHiddenTagIDValue

        snapshotDirty = false
        snapshotBuildGeneration &+= 1
        let generation = snapshotBuildGeneration
        snapshotBuildTask?.cancel()
        snapshotApplyTask?.cancel()

        let buildTask = Task.detached(priority: .userInitiated) {
            TimelineAppBlockBuilder.buildSnapshot(
                from: frameInputs,
                segmentTagsMap: segmentTagsMap,
                segmentCommentCountsMap: segmentCommentCountsMap,
                hiddenTagID: hiddenTagID
            )
        }
        snapshotBuildTask = buildTask

        snapshotApplyTask = Task { [weak self] in
            let builtSnapshot = await buildTask.value

            guard !Task.isCancelled, let self else { return }
            guard generation == self.snapshotBuildGeneration else { return }

            self.cachedSnapshot = builtSnapshot
            self.snapshotRevisionValue &+= 1

            if isVerboseLoggingEnabled {
                Log.debug(
                    "[TimelineBlocks] Applied async snapshot reason='\(reason)' generation=\(generation) blocks=\(builtSnapshot.blocks.count)",
                    category: .ui
                )
            }
        }
    }
}
