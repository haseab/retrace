import SwiftUI
import Combine
import AVFoundation
import AppKit
import Shared
import App
import Database
import Processing
import SwiftyChrono
import UniformTypeIdentifiers

/// Shared timeline configuration
public enum TimelineConfig {
    /// Base pixels per frame at 100% zoom (max detail)
    public static let basePixelsPerFrame: CGFloat = 75.0
    /// Minimum pixels per frame at 0% zoom (most zoomed out)
    public static let minPixelsPerFrame: CGFloat = 8.0
    /// Default zoom level (0.0 to 1.0, where 1.0 is max detail)
    public static let defaultZoomLevel: CGFloat = 0.6
}

/// Configuration for infinite scroll rolling window
private enum WindowConfig {
    static let maxFrames = 100            // Maximum frames in memory
    static let loadThreshold = 20       // Start loading when within N frames of edge
    static let loadBatchSize = 25        // Frames to load per batch
    static let loadWindowSpanSeconds: TimeInterval = 24 * 60 * 60 // Bounded window for load-more queries
    static let nearestFallbackBatchSize = 50 // Frames to fetch when a bounded older probe comes back empty
}

/// Memory tracking for debugging frame accumulation issues
private enum MemoryTracker {
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

/// A frame paired with its preloaded video info for instant access
public struct TimelineFrame: Identifiable, Equatable {
    public let frame: FrameReference
    public let videoInfo: FrameVideoInfo?
    /// Processing status: 0=pending, 1=processing, 2=completed, 3=failed, 4=not yet readable
    public let processingStatus: Int
    public let videoCurrentTime: Double?
    public let scrollY: Double?

    public init(
        frame: FrameReference,
        videoInfo: FrameVideoInfo?,
        processingStatus: Int,
        videoCurrentTime: Double? = nil,
        scrollY: Double? = nil
    ) {
        self.frame = frame
        self.videoInfo = videoInfo
        self.processingStatus = processingStatus
        self.videoCurrentTime = videoCurrentTime
        self.scrollY = scrollY
    }

    public init(frameWithVideoInfo: FrameWithVideoInfo) {
        self.init(
            frame: frameWithVideoInfo.frame,
            videoInfo: frameWithVideoInfo.videoInfo,
            processingStatus: frameWithVideoInfo.processingStatus,
            videoCurrentTime: frameWithVideoInfo.videoCurrentTime,
            scrollY: frameWithVideoInfo.scrollY
        )
    }

    public var id: FrameID { frame.id }

    public static func == (lhs: TimelineFrame, rhs: TimelineFrame) -> Bool {
        lhs.frame.id == rhs.frame.id
    }
}

enum CurrentFrameMediaDisplayMode: Equatable {
    case still
    case decodedVideo
    case noContent
}

enum CurrentFrameStillDisplayMode: Equatable {
    case currentImage
    case waitingFallback
    case none
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
        let textCount = max(nodeText.count, 1)
        let startFraction = CGFloat(range.start) / CGFloat(textCount)
        return x + (width * startFraction)
    }

    /// Normalized width for the linked word span (falls back to full node).
    public var highlightWidth: CGFloat {
        let range = clampedHighlightRange
        let textCount = max(nodeText.count, 1)
        let minimumFraction = 1.0 / CGFloat(textCount)
        let spanFraction = max(CGFloat(range.end - range.start) / CGFloat(textCount), minimumFraction)
        return width * min(spanFraction, 1.0)
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

/// Simple ViewModel for the redesigned fullscreen timeline view
/// All state derives from currentIndex - this is the SINGLE source of truth
@MainActor
public class SimpleTimelineViewModel: ObservableObject {

    // MARK: - Private Properties

    /// Cancellables for Combine subscriptions
    private var cancellables = Set<AnyCancellable>()

    /// Enables very verbose timeline logging (useful for debugging, expensive in production).
    /// Disabled by default in all builds; enable manually via:
    /// `defaults write io.retrace.app retrace.debug.timelineVerboseLogs -bool YES`
    private static let isVerboseTimelineLoggingEnabled: Bool = {
        return UserDefaults.standard.bool(forKey: "retrace.debug.timelineVerboseLogs")
    }()

    /// Enables expensive state-change tracing (stack traces).
    /// Enable only when actively debugging:
    /// `defaults write io.retrace.app retrace.debug.timelineStateTrace -bool YES`
    private static let isTimelineStateTraceEnabled: Bool =
        UserDefaults.standard.bool(forKey: "retrace.debug.timelineStateTrace")

    /// Enables filtered-timeline scrub diagnostics (tracks requested frame identities during fast scroll).
    /// Disabled by default in all builds; opt in with:
    /// `defaults write io.retrace.app retrace.debug.filteredScrubDiagnostics -bool YES`
    private static let isFilteredScrubDiagnosticsEnabled: Bool = {
        return UserDefaults.standard.bool(forKey: "retrace.debug.filteredScrubDiagnostics")
    }()

    /// Timestamp formatter used by comment helper actions.
    private static let commentTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()

    private static func frameIDsMatch(_ lhs: [TimelineFrame], _ rhs: [TimelineFrame]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for index in lhs.indices where lhs[index].frame.id != rhs[index].frame.id {
            return false
        }
        return true
    }

    private static func isPureAppend(oldFrames: [TimelineFrame], newFrames: [TimelineFrame]) -> Bool {
        guard !oldFrames.isEmpty, newFrames.count > oldFrames.count else { return false }
        let leadingWindow = Array(newFrames.prefix(oldFrames.count))
        return frameIDsMatch(oldFrames, leadingWindow)
    }

    private static func isPurePrepend(oldFrames: [TimelineFrame], newFrames: [TimelineFrame]) -> Bool {
        guard !oldFrames.isEmpty, newFrames.count > oldFrames.count else { return false }
        let trailingWindow = Array(newFrames.suffix(oldFrames.count))
        return frameIDsMatch(oldFrames, trailingWindow)
    }

    private static let pendingDeleteUndoWindowSeconds: TimeInterval = 8
    private enum PendingDeletePayload {
        case frame(FrameReference)
        case frames([FrameReference])
    }

    private struct PendingDeleteOperation {
        let id: UUID
        let payload: PendingDeletePayload
        let removedFrames: [TimelineFrame]
        let removedFrameIDs: [FrameID]
        let restoreStartIndex: Int
        let previousCurrentIndex: Int
        let previousSelectedFrameIndex: Int?
        let undoMessage: String
    }

    nonisolated private static let inPageURLCollectionExperimentalKey = "collectInPageURLsExperimental"

    private static func isInPageURLCollectionEnabled() -> Bool {
        let defaults = UserDefaults(suiteName: "io.retrace.app") ?? .standard
        guard defaults.object(forKey: inPageURLCollectionExperimentalKey) != nil else {
            return false
        }
        return defaults.bool(forKey: inPageURLCollectionExperimentalKey)
    }

    // MARK: - Published State

    /// All loaded frames with their preloaded video info
    @Published public var frames: [TimelineFrame] = [] {
        didSet {
            let didChangeIdentity = frames.count != oldValue.count
                || frames.first?.frame.id != oldValue.first?.frame.id
                || frames.last?.frame.id != oldValue.last?.frame.id
            if didChangeIdentity {
                hotWindowRange = nil
            }

            let pendingPreferredIndex = pendingCurrentIndexAfterFrameReplacement
            pendingCurrentIndexAfterFrameReplacement = nil

            if frames.isEmpty {
                if currentIndex != 0 {
                    currentIndex = 0
                }
            } else {
                let targetIndex = pendingPreferredIndex ?? currentIndex
                let clampedIndex = max(0, min(targetIndex, frames.count - 1))
                if clampedIndex != currentIndex {
                    currentIndex = clampedIndex
                }
            }

            invalidateAppBlockSnapshot(reason: "frames.didSet")

            let isPureAppend = didChangeIdentity && Self.isPureAppend(oldFrames: oldValue, newFrames: frames)
            let isPurePrepend = didChangeIdentity && Self.isPurePrepend(oldFrames: oldValue, newFrames: frames)
            let isWindowReplacement = didChangeIdentity && !isPureAppend && !isPurePrepend

            if isWindowReplacement {
                refreshAppBlockSnapshotImmediately(reason: "frames.didSet.windowReplaced")
            } else if isPurePrepend {
                // Keep tape geometry in sync during boundary loads to avoid stale-viewport jumps.
                refreshAppBlockSnapshotImmediately(reason: "frames.didSet.prepended")
            } else if isPureAppend {
                refreshAppBlockSnapshotImmediately(reason: "frames.didSet.appended")
            }
        }
    }

    /// Current index in the frames array - THE SINGLE SOURCE OF TRUTH
    /// Everything else (currentFrame, currentVideoInfo, currentTimestamp) derives from this
    @Published public var currentIndex: Int = 0 {
        didSet {
            if currentIndex != oldValue {
                endInPageURLHoverTracking()
                if Self.isVerboseTimelineLoggingEnabled {
                    Log.debug("[SimpleTimelineViewModel] currentIndex changed: \(oldValue) -> \(currentIndex)", category: .ui)
                    if let frame = currentTimelineFrame {
                        Log.debug("[SimpleTimelineViewModel] New frame: timestamp=\(frame.frame.timestamp), frameIndex=\(frame.videoInfo?.frameIndex ?? -1)", category: .ui)
                    }
                }

                // CRITICAL: Clear previous frame state IMMEDIATELY to prevent old frame from showing.
                // Preserve the last visible frame only as a temporary overlay while video catches up.
                prepareCurrentFramePresentationState(for: currentTimelineFrame)

                // Pre-check if frame will have loading issues (synchronous check)
                // This prevents showing a fallback frame before the async error is detected
                if let timelineFrame = currentTimelineFrame {
                    if timelineFrame.processingStatus == 4 {
                        // Frame not yet readable
                        frameNotReady = true
                        frameLoadError = false
                    } else {
                        // Reset states - actual load will set them if needed
                        frameNotReady = false
                        frameLoadError = false
                    }
                }

                updateDeferredTrimAnchorForCurrentSelectionIfNeeded()
            }
        }
    }

    /// Static image for displaying the current frame (for image-based sources like Retrace)
    @Published public var currentImage: NSImage?
    @Published private(set) var currentImageFrameID: FrameID?
    @Published private(set) var waitingFallbackImage: NSImage?
    @Published private(set) var pendingVideoPresentationFrameID: FrameID?
    @Published private(set) var isPendingVideoPresentationReady = false

    /// Whether the timeline is in "live mode" showing a live screenshot
    /// When true, the liveScreenshot is displayed instead of historical frames
    /// Exits to historical frames on first scroll/navigation
    @Published public var isInLiveMode: Bool = false

    /// The live screenshot captured at timeline launch (only used when isInLiveMode == true)
    @Published public var liveScreenshot: NSImage?

    /// Whether live OCR is currently being processed on the live screenshot
    @Published public var isLiveOCRProcessing: Bool = false

    /// Whether the tape is hidden (off-screen below) - used for slide-up animation in live mode
    @Published public var isTapeHidden: Bool = false

    /// Whether the current frame is not yet available in the video file (still encoding)
    @Published public var frameNotReady: Bool = false {
        willSet {
            guard Self.isTimelineStateTraceEnabled, newValue != frameNotReady else { return }

            let frameID = currentTimelineFrame?.frame.id.value ?? -1
            let status = currentTimelineFrame?.processingStatus ?? -1
            Log.info("[FRAME-READY-CHANGE] ⚠️ frameNotReady changing: \(frameNotReady) -> \(newValue) for frameID=\(frameID), processingStatus=\(status)", category: .ui)

            // Print stack trace to see where this is being called from
            let stackTrace = Thread.callStackSymbols.prefix(10).joined(separator: "\n")
            Log.info("[FRAME-READY-CHANGE] Stack trace:\n\(stackTrace)", category: .ui)
        }
    }

    /// Whether the current frame failed to load (e.g., index out of range, file read error)
    @Published public var frameLoadError: Bool = false

    /// Loading state
    @Published public var isLoading = false

    /// Error message if something goes wrong
    @Published public var error: String?

    /// Whether the date search input is shown
    @Published public var isDateSearchActive = false

    /// Date search text input
    @Published public var dateSearchText = ""

    /// Whether the calendar picker is shown
    @Published public var isCalendarPickerVisible = false

    /// Dates that have frames (for calendar highlighting)
    @Published public var datesWithFrames: Set<Date> = []

    /// Hours with frames for selected calendar date
    @Published public var hoursWithFrames: [Date] = []

    /// Currently selected date in calendar
    @Published public var selectedCalendarDate: Date? = nil

    /// Keyboard focus target inside calendar picker
    public enum CalendarKeyboardFocus: Sendable {
        case dateGrid
        case timeGrid
    }

    /// Which calendar picker section currently owns arrow-key navigation
    @Published public var calendarKeyboardFocus: CalendarKeyboardFocus = .dateGrid

    /// Selected hour (0-23) when keyboard focus is on the time grid
    @Published public var selectedCalendarHour: Int? = nil

    /// Zoom level (0.0 to 1.0, where 1.0 is max detail/zoomed in)
    @Published public var zoomLevel: CGFloat = TimelineConfig.defaultZoomLevel

    /// Whether the zoom slider is expanded/visible
    @Published public var isZoomSliderExpanded = false

    /// Whether the more options menu is visible
    @Published public var isMoreOptionsMenuVisible = false

    /// Whether the user is actively scrolling (disables tape animation during rapid scrolling)
    @Published public var isActivelyScrolling = false {
        didSet {
            // Apply deferred rolling-window trims only after scrub interaction settles.
            guard oldValue, !isActivelyScrolling else { return }
            applyDeferredTrimIfNeeded(trigger: "scroll-ended")
        }
    }

    /// Currently selected frame index (for deletion, etc.) - nil means no selection
    @Published public var selectedFrameIndex: Int? = nil

    /// Whether the delete confirmation dialog is shown
    @Published public var showDeleteConfirmation = false

    /// Whether we're deleting a single frame or an entire segment
    @Published public var isDeleteSegmentMode = false

    /// Frames that have been "deleted" (optimistically removed from UI)
    @Published public var deletedFrameIDs: Set<FrameID> = []

    /// Bottom action banner shown after a delete so the user can undo.
    @Published public var pendingDeleteUndoMessage: String?

    // MARK: - URL Bounding Box State

    /// Bounding box for a clickable URL found in the current frame (normalized 0.0-1.0 coordinates)
    @Published public var urlBoundingBox: URLBoundingBox?

    /// Whether the mouse is currently hovering over the URL bounding box
    @Published public var isHoveringURL: Bool = false

    /// Hyperlinks mapped from live DOM to OCR node bounds for the current frame.
    @Published public var hyperlinkMatches: [OCRHyperlinkMatch] = []


    /// Flag to force video reload on next updateNSView (clears AVPlayer's stale cache)
    /// Set this when window becomes visible after background refresh
    public var forceVideoReload: Bool = false

    // MARK: - Text Selection State

    /// All OCR nodes for the current frame (used for text selection)
    @Published public var ocrNodes: [OCRNodeWithText] = []

    /// Previous frame's OCR nodes (only populated when showOCRDebugOverlay is enabled, for diff visualization)
    @Published public var previousOcrNodes: [OCRNodeWithText] = []

    /// OCR processing status for the current frame
    @Published public var ocrStatus: OCRProcessingStatus = .unknown

    /// Character-level selection: start position (node ID, character index within node)
    @Published public var selectionStart: (nodeID: Int, charIndex: Int)?

    /// Character-level selection: end position (node ID, character index within node)
    @Published public var selectionEnd: (nodeID: Int, charIndex: Int)?

    /// Drag selection behavior mode.
    public enum DragSelectionMode: Sendable {
        /// Standard caret-like selection where drag start/end map to character positions.
        case character
        /// Command-drag selection where all nodes intersecting the drag box are fully selected.
        case box
    }

    /// Whether all text is selected (via Cmd+A)
    @Published public var isAllTextSelected: Bool = false

    /// Drag selection start point (in normalized coordinates 0.0-1.0)
    @Published public var dragStartPoint: CGPoint?

    /// Drag selection end point (in normalized coordinates 0.0-1.0)
    @Published public var dragEndPoint: CGPoint?

    /// Node IDs selected via Cmd+Drag box selection.
    @Published public var boxSelectedNodeIDs: Set<Int> = []

    /// Whether we have any text selected
    public var hasSelection: Bool {
        isAllTextSelected || !boxSelectedNodeIDs.isEmpty || (selectionStart != nil && selectionEnd != nil)
    }

    /// Active drag selection mode for the current drag gesture.
    private var activeDragSelectionMode: DragSelectionMode = .character

    // MARK: - Selection Range Cache (performance optimization for Cmd+A)

    /// Cached sorted OCR nodes for selection range calculation
    /// Invalidated when ocrNodes changes
    private var cachedSortedNodes: [OCRNodeWithText]?

    /// Cached node ID to index lookup for O(1) access
    private var cachedNodeIndexMap: [Int: Int]?

    /// The ocrNodes array that the cache was built from (for invalidation check)
    private var cachedNodesVersion: Int = 0

    /// Current version of ocrNodes (incremented on change)
    private var currentNodesVersion: Int = 0

    /// Current in-flight task for stored hyperlink row loading.
    private var hyperlinkMappingTask: Task<Void, Never>?

    /// Deduplicates a single continuous hover even if AppKit/SwiftUI replays hover callbacks.
    private var activeInPageURLHoverMetricKey: String?

    // MARK: - Zoom Region State (Shift+Drag focus rectangle)

    /// Whether zoom region mode is active
    @Published public var isZoomRegionActive: Bool = false

    /// Zoom region rectangle in normalized coordinates (0.0-1.0)
    /// nil when not zooming, set when Shift+Drag creates a focus region
    @Published public var zoomRegion: CGRect?

    /// Whether currently dragging to create a zoom region
    @Published public var isDraggingZoomRegion: Bool = false

    /// Start point of zoom region drag (normalized coordinates)
    @Published public var zoomRegionDragStart: CGPoint?

    /// Current end point of zoom region drag (normalized coordinates)
    @Published public var zoomRegionDragEnd: CGPoint?

    /// Shift+drag snapshot/session state for extractor-backed zoom display.
    private var shiftDragSessionCounter = 0
    private var activeShiftDragSessionID = 0
    private var shiftDragStartFrameID: Int64?
    private var shiftDragStartVideoInfo: FrameVideoInfo?
    /// Snapshot image used by zoom overlay after Shift+Drag (sourced from AVAssetImageGenerator).
    @Published public var shiftDragDisplaySnapshot: NSImage?
    @Published public var shiftDragDisplaySnapshotFrameID: Int64?
    private var shiftDragDisplayRequestID: Int = 0

    // MARK: - Text Selection Hint Banner State

    /// Whether to show the text selection hint banner ("Try area selection mode: Shift + Drag")
    @Published public var showTextSelectionHint: Bool = false

    /// Timer to auto-dismiss the text selection hint
    private var textSelectionHintTimer: Timer?

    /// Whether the hint banner has already been shown for the current drag session
    private var hasShownHintThisDrag: Bool = false

    // MARK: - Scroll Orientation Hint Banner State

    /// Whether to show the scroll orientation hint banner
    @Published public var showScrollOrientationHintBanner: Bool = false

    /// The current orientation when the hint was triggered ("horizontal" or "vertical")
    public var scrollOrientationHintCurrentOrientation: String = "horizontal"

    /// Timer to auto-dismiss the scroll orientation hint
    private var scrollOrientationHintTimer: Timer?

    // MARK: - Zoom Transition Animation State

    /// Whether we're currently animating the zoom transition
    @Published public var isZoomTransitioning: Bool = false

    /// Whether we're animating the exit (reverse) transition
    @Published public var isZoomExitTransitioning: Bool = false

    /// The original rect where the drag ended (for animation start)
    @Published public var zoomTransitionStartRect: CGRect?

    /// Animation progress (0.0 = drag position, 1.0 = centered position)
    @Published public var zoomTransitionProgress: CGFloat = 0

    /// Blur opacity during transition (0.0 = no blur, 1.0 = full blur)
    @Published public var zoomTransitionBlurOpacity: CGFloat = 0

    // MARK: - Frame Zoom State (Trackpad pinch-to-zoom)

    /// Current frame zoom scale (1.0 = 100%, fit to screen)
    /// Values > 1.0 zoom in, values < 1.0 zoom out (frame becomes smaller than display)
    @Published public var frameZoomScale: CGFloat = 1.0

    /// Pan offset when zoomed in (for navigating around the zoomed frame)
    @Published public var frameZoomOffset: CGSize = .zero

    /// Minimum zoom scale (frame smaller than display)
    public static let minFrameZoomScale: CGFloat = 0.25

    /// Maximum zoom scale (zoomed in)
    public static let maxFrameZoomScale: CGFloat = 10.0

    /// Whether the frame is currently zoomed (not at 100%)
    public var isFrameZoomed: Bool {
        abs(frameZoomScale - 1.0) > 0.001
    }

    /// Reset frame zoom to 100% (fit to screen)
    public func resetFrameZoom() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            frameZoomScale = 1.0
            frameZoomOffset = .zero
        }
    }

    /// Apply magnification gesture delta to zoom scale
    /// - Parameters:
    ///   - magnification: The magnification value from the gesture (1.0 = no change)
    ///   - anchor: The anchor point for zooming (in normalized coordinates 0.0-1.0, where 0.5,0.5 is center)
    ///   - frameSize: The size of the frame view in points (needed for anchor-based zoom calculations)
    ///   - animated: Whether to animate the zoom change (use true for keyboard shortcuts, false for trackpad gestures)
    public func applyMagnification(_ magnification: CGFloat, anchor: CGPoint = CGPoint(x: 0.5, y: 0.5), frameSize: CGSize? = nil, animated: Bool = false) {
        let newScale = (frameZoomScale * magnification).clamped(to: Self.minFrameZoomScale...Self.maxFrameZoomScale)

        // Calculate new offset to zoom toward the anchor point
        let newOffset: CGSize
        if newScale != frameZoomScale, let size = frameSize {
            // Convert anchor from normalized (0-1) to offset from center
            // anchor (0.5, 0.5) = center, (0,0) = top-left, (1,1) = bottom-right
            let anchorOffsetX = (anchor.x - 0.5) * size.width
            let anchorOffsetY = (anchor.y - 0.5) * size.height

            let scaleDelta = newScale / frameZoomScale

            // When zooming, the point under the cursor should stay stationary
            // newOffset = oldOffset * scaleDelta + anchorOffset * (1 - scaleDelta)
            newOffset = CGSize(
                width: frameZoomOffset.width * scaleDelta + anchorOffsetX * (1 - scaleDelta),
                height: frameZoomOffset.height * scaleDelta + anchorOffsetY * (1 - scaleDelta)
            )
        } else if newScale != frameZoomScale {
            // No frame size provided, just scale existing offset (zoom from center)
            let scaleDelta = newScale / frameZoomScale
            newOffset = CGSize(
                width: frameZoomOffset.width * scaleDelta,
                height: frameZoomOffset.height * scaleDelta
            )
        } else {
            newOffset = frameZoomOffset
        }

        if animated {
            withAnimation(.easeOut(duration: 0.15)) {
                frameZoomScale = newScale
                frameZoomOffset = newOffset
            }
        } else {
            frameZoomScale = newScale
            frameZoomOffset = newOffset
        }
    }

    /// Update pan offset when dragging while zoomed
    public func updateFrameZoomOffset(by delta: CGSize) {
        frameZoomOffset = CGSize(
            width: frameZoomOffset.width + delta.width,
            height: frameZoomOffset.height + delta.height
        )
    }

    // MARK: - Search State

    /// Whether the search overlay is visible
    @Published public var isSearchOverlayVisible: Bool = false

    /// Whether the in-frame search bar is visible.
    @Published public var isInFrameSearchVisible: Bool = false

    /// Current in-frame search query for highlighting OCR nodes on the active frame.
    @Published public var inFrameSearchQuery: String = ""

    /// Incremented to request keyboard focus for the in-frame search field.
    @Published public var focusInFrameSearchFieldSignal: Int = 0

    private static let inFrameSearchDebounceNanoseconds: UInt64 = 300_000_000
    private var inFrameSearchDebounceTask: Task<Void, Never>?

    /// Persistent SearchViewModel that survives overlay open/close
    /// This allows search results to be preserved when clicking on a result
    public lazy var searchViewModel: SearchViewModel = {
        SearchViewModel(coordinator: coordinator)
    }()

    /// Whether the timeline controls (tape, playhead, buttons) are hidden
    @Published public var areControlsHidden: Bool = false

    /// Whether to show frame IDs in debug mode (read from UserDefaults)
    public var showFrameIDs: Bool {
        let defaults = UserDefaults(suiteName: "io.retrace.app") ?? .standard
        return defaults.bool(forKey: "showFrameIDs")
    }

    /// Whether to show OCR debug overlay (bounding boxes and tile grid) in timeline (read from UserDefaults)
    public var showOCRDebugOverlay: Bool {
        let defaults = UserDefaults(suiteName: "io.retrace.app") ?? .standard
        return defaults.bool(forKey: "showOCRDebugOverlay")
    }

    /// Whether to show video segment boundaries on the timeline tape
    @Published public var showVideoBoundaries: Bool = false

    /// Whether to show segment boundaries on the timeline tape
    @Published public var showSegmentBoundaries: Bool = false

    /// Whether to show the floating browser URL debug window while scrubbing
    @Published public var showBrowserURLDebugWindow: Bool = false

    // MARK: - Toast Feedback
    public enum ToastTone: Sendable {
        case success
        case error
    }

    @Published public var toastMessage: String? = nil
    @Published public var toastIcon: String? = nil
    @Published public var toastTone: ToastTone = .success
    @Published public var toastVisible: Bool = false
    private var toastDismissTask: Task<Void, Never>?

    /// Show a brief toast notification overlay
    public func showToast(_ message: String, icon: String? = nil) {
        toastDismissTask?.cancel()
        let tone = classifyToastTone(message: message, icon: icon)
        let resolvedIcon = icon ?? (tone == .error ? "xmark.circle.fill" : "checkmark.circle.fill")

        // Set content first, then animate in
        toastMessage = message
        toastIcon = resolvedIcon
        toastTone = tone
        withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
            toastVisible = true
        }
        toastDismissTask = Task { @MainActor in
            try? await Task.sleep(for: .nanoseconds(Int64(1_500_000_000)), clock: .continuous) // 1.5s (longer for error messages)
            if !Task.isCancelled {
                withAnimation(.easeIn(duration: 0.3)) {
                    self.toastVisible = false
                }
                // Clear content after fade-out completes
                try? await Task.sleep(for: .nanoseconds(Int64(350_000_000)), clock: .continuous)
                if !Task.isCancelled {
                    self.toastMessage = nil
                    self.toastIcon = nil
                    self.toastTone = .success
                }
            }
        }
    }

    private func classifyToastTone(message: String, icon: String?) -> ToastTone {
        if let icon {
            if icon.contains("xmark") || icon.contains("exclamationmark") {
                return .error
            }
            if icon.contains("checkmark") {
                return .success
            }
        }

        let normalizedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let errorKeywords = [
            "cannot",
            "can't",
            "failed",
            "error",
            "unable",
            "invalid",
            "denied",
            "missing",
            "not found"
        ]

        if errorKeywords.contains(where: { normalizedMessage.contains($0) }) {
            return .error
        }

        return .success
    }

    /// Ordered frame indices where video boundaries occur (first frame of each new video)
    /// A boundary exists when the videoPath changes between consecutive frames.
    public var orderedVideoBoundaryIndices: [Int] {
        appBlockSnapshot.videoBoundaryIndices
    }

    /// Set form of video boundaries for existing call sites.
    public var videoBoundaryIndices: Set<Int> {
        Set(orderedVideoBoundaryIndices)
    }

    /// Ordered frame indices where segment boundaries occur (first frame of each new segment)
    public var orderedSegmentBoundaryIndices: [Int] {
        appBlockSnapshot.segmentBoundaryIndices
    }

    /// Set form of segment boundaries for existing call sites.
    public var segmentBoundaryIndices: Set<Int> {
        Set(orderedSegmentBoundaryIndices)
    }

    // MARK: - Video Playback State

    /// Whether video playback (auto-advance) is currently active
    @Published public var isPlaying: Bool = false

    /// Playback speed multiplier (frames per second)
    /// Available speeds: 1, 2, 4, 8
    @Published public var playbackSpeed: Double = 2.0

    /// Timer that drives frame auto-advance during playback
    private var playbackTimer: Timer?

    /// Whether video controls are enabled (read from UserDefaults)
    public var showVideoControls: Bool {
        let defaults = UserDefaults(suiteName: "io.retrace.app") ?? .standard
        return defaults.bool(forKey: "showVideoControls")
    }

    /// Start auto-advancing frames at the current playback speed
    public func startPlayback() {
        guard !isPlaying else { return }
        isPlaying = true
        schedulePlaybackTimer()
    }

    /// Stop auto-advancing frames
    public func stopPlayback() {
        isPlaying = false
        playbackTimer?.invalidate()
        playbackTimer = nil
    }

    /// Toggle between play and pause
    public func togglePlayback() {
        let wasPlaying = isPlaying
        if isPlaying {
            stopPlayback()
        } else {
            startPlayback()
        }
        DashboardViewModel.recordPlaybackToggled(
            coordinator: coordinator,
            source: "timeline",
            wasPlaying: wasPlaying,
            isPlaying: isPlaying,
            speed: playbackSpeed
        )
    }

    /// Update the playback speed and reschedule the timer if playing
    public func setPlaybackSpeed(_ speed: Double) {
        let previousSpeed = playbackSpeed
        guard previousSpeed != speed else { return }

        playbackSpeed = speed
        if isPlaying {
            // Reschedule timer with new interval
            playbackTimer?.invalidate()
            schedulePlaybackTimer()
        }

        DashboardViewModel.recordPlaybackSpeedChanged(
            coordinator: coordinator,
            source: "timeline",
            previousSpeed: previousSpeed,
            newSpeed: speed,
            isPlaying: isPlaying
        )
    }

    /// Schedule the playback timer at the current speed
    private func schedulePlaybackTimer() {
        let interval = 1.0 / playbackSpeed
        playbackTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            DispatchQueue.main.async {
                let nextIndex = self.currentIndex + 1
                if nextIndex < self.frames.count {
                    self.navigateToFrame(nextIndex)
                } else {
                    // Reached the end - stop playback
                    self.stopPlayback()
                }
            }
        }
    }

    /// Copy the current frame ID to clipboard
    public func copyCurrentFrameID() {
        guard let frame = currentFrame else { return }
        let frameIDString = String(frame.id.value)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(frameIDString, forType: .string)
    }

    public func toggleFrameIDBadgeVisibilityFromDevMenu() {
        let defaults = UserDefaults(suiteName: "io.retrace.app") ?? .standard
        let isEnabled = !defaults.bool(forKey: "showFrameIDs")
        defaults.set(isEnabled, forKey: "showFrameIDs")
        DashboardViewModel.recordDeveloperSettingToggle(
            coordinator: coordinator,
            source: "timeline_dev_menu",
            settingKey: "showFrameIDs",
            isEnabled: isEnabled
        )
    }

    /// Reprocess OCR for the current frame (developer tool)
    /// Clears existing OCR data and re-enqueues the frame for processing
    public func reprocessCurrentFrameOCR() async throws {
        guard let frame = currentFrame else { return }
        // Only allow reprocessing for Retrace frames (not imported Rewind videos)
        guard frame.source == .native else {
            Log.warning("[OCR] Cannot reprocess OCR for Rewind frames", category: .ui)
            return
        }
        try await coordinator.reprocessOCR(frameID: frame.id)
    }

    /// The search query to highlight on the current frame (set when navigating from search)
    @Published public var searchHighlightQuery: String?

    /// Controls whether search highlights draw matched substrings or whole OCR nodes.
    enum SearchHighlightMode: Equatable {
        case matchedTextRanges
        case matchedNodes
    }

    /// The current highlight mode for the active search highlight.
    @Published private(set) var searchHighlightMode: SearchHighlightMode = .matchedTextRanges

    /// Whether search highlight is currently being displayed
    @Published public var isShowingSearchHighlight: Bool = false

    /// Timer to auto-dismiss search highlight
    private var searchHighlightTimer: Timer?

    private var hasActiveInFrameSearchQuery: Bool {
        !inFrameSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Timer for periodic processing status refresh while timeline is open
    private var statusRefreshTimer: Timer?

    // MARK: - Context Menu State

    /// Whether the right-click context menu is visible
    @Published public var showContextMenu: Bool = false

    /// Location where the context menu should appear
    @Published public var contextMenuLocation: CGPoint = .zero

    /// Dismiss the context menu if it's visible
    public func dismissContextMenu() {
        if showContextMenu {
            withAnimation(.easeOut(duration: 0.16)) {
                showContextMenu = false
            }
        }
    }

    /// Toggle the top-right "more options" menu visibility
    public func toggleMoreOptionsMenu() {
        isMoreOptionsMenuVisible.toggle()
    }

    /// Dismiss the top-right "more options" menu if visible
    public func dismissMoreOptionsMenu() {
        isMoreOptionsMenuVisible = false
    }

    // MARK: - Timeline Context Menu State (for right-click on timeline tape)

    /// Whether the timeline context menu is visible
    @Published public var showTimelineContextMenu: Bool = false

    /// Location where the timeline context menu should appear
    @Published public var timelineContextMenuLocation: CGPoint = .zero

    /// The segment index that was right-clicked on the timeline
    @Published public var timelineContextMenuSegmentIndex: Int? = nil

    /// Whether the tag submenu is visible
    @Published public var showTagSubmenu: Bool = false

    /// Whether the comment submenu is visible
    @Published public var showCommentSubmenu: Bool = false

    /// Whether the comment link insert popover is currently visible.
    /// Used so Escape can dismiss the popover before dismissing the full comment submenu.
    @Published public var isCommentLinkPopoverPresented: Bool = false

    /// Signal to request that the comment link popover close.
    @Published public var closeCommentLinkPopoverSignal: Int = 0

    /// Whether the "create new tag" input is visible
    @Published public var showNewTagInput: Bool = false

    /// Text for the new tag name input
    @Published public var newTagName: String = ""

    /// Text for the new comment body
    @Published public var newCommentText: String = ""

    /// Draft file attachments for the pending comment
    @Published public var newCommentAttachmentDrafts: [CommentAttachmentDraft] = []

    /// Existing comments linked to the selected timeline block (deduplicated by comment ID)
    @Published public var selectedBlockComments: [SegmentComment] = []

    /// Preferred fallback segment context for each selected-block comment.
    private var selectedBlockCommentPreferredSegmentByID: [Int64: SegmentID] = [:]

    /// Whether existing comments are loading for the selected timeline block
    @Published public var isLoadingBlockComments: Bool = false

    /// Optional error surfaced when loading selected block comments fails
    @Published public var blockCommentsLoadError: String? = nil

    /// Flattened timeline rows for "All Comments" browsing.
    @Published public var commentTimelineRows: [CommentTimelineRow] = []

    /// Anchor comment for the all-comments timeline view.
    @Published public var commentTimelineAnchorCommentID: SegmentCommentID?

    /// Whether the all-comments timeline is currently loading its initial data.
    @Published public var isLoadingCommentTimeline: Bool = false

    /// Whether older all-comments pages are currently being fetched.
    @Published public var isLoadingOlderCommentTimeline: Bool = false

    /// Whether newer all-comments pages are currently being fetched.
    @Published public var isLoadingNewerCommentTimeline: Bool = false

    /// Optional error surfaced when loading all-comments timeline fails.
    @Published public var commentTimelineLoadError: String? = nil

    /// Whether older comment pages are still available.
    @Published public var commentTimelineHasOlder: Bool = false

    /// Whether newer comment pages are still available.
    @Published public var commentTimelineHasNewer: Bool = false

    /// Raw query text for comment search in the all-comments panel.
    @Published public var commentSearchText: String = ""

    /// Server-side search results (capped).
    @Published public var commentSearchResults: [CommentTimelineRow] = []

    /// Whether there are additional server-side comment search results to page in.
    @Published public var commentSearchHasMoreResults: Bool = false

    /// Whether a server-side comment search request is in flight.
    @Published public var isSearchingComments: Bool = false

    /// Optional error surfaced when searching comments fails.
    @Published public var commentSearchError: String? = nil

    /// Whether the comment submenu is currently showing the all-comments browser.
    /// Used by window-level keyboard handling (Escape/Cmd+[) to route back to thread mode.
    @Published public var isAllCommentsBrowserActive: Bool = false

    /// Signal to request return from all-comments browser back to local thread comments.
    @Published public var returnToThreadCommentsSignal: Int = 0

    /// Whether the mouse is hovering over the "Add Tag" button
    @Published public var isHoveringAddTagButton: Bool = false

    /// Whether the mouse is hovering over the "Add Comment" button
    @Published public var isHoveringAddCommentButton: Bool = false

    /// Whether a comment creation request is currently in flight
    @Published public var isAddingComment: Bool = false

    /// All available tags
    @Published public var availableTags: [Tag] = [] {
        didSet {
            hasLoadedAvailableTags = true
            refreshTagCachesAndInvalidateSnapshotIfNeeded(reason: "availableTags.didSet")
        }
    }

    /// Tags applied to the currently selected segment (for showing checkmarks)
    @Published public var selectedSegmentTags: Set<TagID> = []

    /// Set of segment IDs that are hidden
    @Published public var hiddenSegmentIds: Set<SegmentID> = []

    /// Range of frame indices for the segment block currently being hidden with squeeze animation
    @Published public var hidingSegmentBlockRange: ClosedRange<Int>? = nil

    private static let timelineMenuDismissAnimationDuration: TimeInterval = 0.15

    /// Dismiss the timeline context menu
    public func dismissTimelineContextMenu() {
        let resetMenuState = {
            self.showTimelineContextMenu = false
            self.showTagSubmenu = false
            self.showCommentSubmenu = false
            self.isCommentLinkPopoverPresented = false
            self.closeCommentLinkPopoverSignal = 0
            self.showNewTagInput = false
            self.newTagName = ""
            self.newCommentText = ""
            self.newCommentAttachmentDrafts = []
            self.selectedBlockComments = []
            self.selectedBlockCommentPreferredSegmentByID = [:]
            self.isLoadingBlockComments = false
            self.blockCommentsLoadError = nil
            self.isHoveringAddTagButton = false
            self.isHoveringAddCommentButton = false
            self.isAddingComment = false
            self.isAllCommentsBrowserActive = false
            self.returnToThreadCommentsSignal = 0
            self.selectedSegmentTags = []
            self.resetCommentTimelineState()
            self.resetCommentSearchState()
        }

        let shouldAnimate = showTimelineContextMenu || showTagSubmenu || showCommentSubmenu || showNewTagInput
        if shouldAnimate {
            withAnimation(.easeOut(duration: Self.timelineMenuDismissAnimationDuration)) {
                resetMenuState()
            }
        } else {
            resetMenuState()
        }
    }

    /// Dismiss only the comment submenu with an explicit fade-out phase.
    /// This avoids tearing down comment state in the same frame as the transition.
    public func dismissCommentSubmenu() {
        guard showCommentSubmenu else { return }

        withAnimation(.easeOut(duration: Self.timelineMenuDismissAnimationDuration)) {
            self.showCommentSubmenu = false
            self.isCommentLinkPopoverPresented = false
            self.showTagSubmenu = false
            self.showTimelineContextMenu = false
            self.showContextMenu = false
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.timelineMenuDismissAnimationDuration) { [weak self] in
            guard let self else { return }
            // If reopened during the fade-out window, preserve the new session state.
            guard !self.showCommentSubmenu else { return }

            self.closeCommentLinkPopoverSignal = 0
            self.newCommentText = ""
            self.newCommentAttachmentDrafts = []
            self.selectedBlockComments = []
            self.selectedBlockCommentPreferredSegmentByID = [:]
            self.isLoadingBlockComments = false
            self.blockCommentsLoadError = nil
            self.isHoveringAddCommentButton = false
            self.isAddingComment = false
            self.isAllCommentsBrowserActive = false
            self.returnToThreadCommentsSignal = 0
            self.resetCommentTimelineState()
            self.resetCommentSearchState()
        }
    }

    /// Request that the inline comment "Insert Link" popover close.
    public func requestCloseCommentLinkPopover() {
        closeCommentLinkPopoverSignal += 1
    }

    /// Request that the comment browser return to the local thread-comments view.
    public func requestReturnToThreadComments() {
        returnToThreadCommentsSignal += 1
    }

    // MARK: - Filter State

    /// Current applied filter criteria
    @Published public var filterCriteria: FilterCriteria = .none

    /// Pending filter criteria (edited in panel, applied on submit)
    @Published public var pendingFilterCriteria: FilterCriteria = .none

    /// Whether the filter panel is visible
    @Published public var isFilterPanelVisible: Bool = false

    /// Whether any popover filter dropdown (apps, tags, visibility, date) is open in the filter panel
    /// Note: `.advanced` is inline, not a popover dropdown.
    /// Set by FilterPanel view to allow TimelineWindowController to skip escape handling
    @Published public var isFilterDropdownOpen: Bool = false

    /// Whether the date range calendar grid is expanded inside the date dropdown.
    /// Used so Escape can close the calendar first instead of closing the full dropdown.
    @Published public var isDateRangeCalendarEditing: Bool = false

    /// Set when filters are cleared without an immediate reload so the next refresh
    /// rebuilds the window instead of merging unfiltered frames into stale filtered ones.
    private var requiresFullReloadOnNextRefresh = false

    // MARK: - Filter Dropdown State (lifted to ViewModel for proper rendering outside FilterPanel)

    /// Which filter dropdown is currently open (rendered at SimpleTimelineView level to avoid clipping)
    public enum FilterDropdownType: Equatable {
        case none
        case apps
        case tags
        case visibility
        case comments
        case dateRange
        case advanced
    }

    /// The currently active filter dropdown
    @Published public var activeFilterDropdown: FilterDropdownType = .none

    /// Position of the currently active dropdown button in "timelineContent" coordinate space (for positioning the dropdown)
    @Published public var filterDropdownAnchorFrame: CGRect = .zero

    /// Stored anchor frames for each filter type (for Tab key navigation)
    public var filterAnchorFrames: [FilterDropdownType: CGRect] = [:]

    /// Show a specific filter dropdown
    public func showFilterDropdown(_ type: FilterDropdownType, anchorFrame: CGRect) {
        if Self.isVerboseTimelineLoggingEnabled {
            Log.debug("[FilterDropdown] showFilterDropdown type=\(type), anchor=\(anchorFrame)", category: .ui)
        }
        filterDropdownAnchorFrame = anchorFrame
        filterAnchorFrames[type] = anchorFrame
        activeFilterDropdown = type
        // `.advanced` is rendered inline in the panel, not as a popover.
        isFilterDropdownOpen = type != .none && type != .advanced
        if type != .dateRange {
            isDateRangeCalendarEditing = false
        }
    }

    /// Dismiss any open filter dropdown
    public func dismissFilterDropdown() {
        if Self.isVerboseTimelineLoggingEnabled {
            Log.debug("[FilterDropdown] dismissFilterDropdown", category: .ui)
        }
        activeFilterDropdown = .none
        isFilterDropdownOpen = false
        isDateRangeCalendarEditing = false
    }

    /// Which advanced field is currently focused (0=none, 1=windowName, 2=browserUrl)
    /// Used by FilterPanel tab monitor to know when to cycle out of advanced
    @Published public var advancedFocusedFieldIndex: Int = 0

    /// Apps available for filtering (installed apps only)
    @Published public var availableAppsForFilter: [(bundleID: String, name: String)] = []

    /// Other apps for filtering (apps from DB history that aren't currently installed)
    @Published public var otherAppsForFilter: [(bundleID: String, name: String)] = []

    /// Whether apps for filter are currently being loaded
    @Published public var isLoadingAppsForFilter = false

    /// Map of segment IDs to their tag IDs (for efficient tag filtering)
    @Published public var segmentTagsMap: [Int64: Set<Int64>] = [:] {
        didSet {
            hasLoadedSegmentTagsMap = true
            invalidateAppBlockSnapshot(reason: "segmentTagsMap.didSet")
        }
    }

    /// Map of segment ID to linked comment count (used for comment tape indicators).
    @Published public var segmentCommentCountsMap: [Int64: Int] = [:] {
        didSet {
            hasLoadedSegmentCommentCountsMap = true
            invalidateAppBlockSnapshot(reason: "segmentCommentCountsMap.didSet")
        }
    }

    /// Background load guard for timeline tape tag indicators.
    private var isLoadingTapeTagIndicatorData = false
    /// Prevents repeatedly refetching empty tags.
    private var hasLoadedAvailableTags = false
    /// Prevents repeatedly refetching empty segment-tag maps.
    private var hasLoadedSegmentTagsMap = false
    /// Prevents repeatedly refetching empty comment-count maps.
    private var hasLoadedSegmentCommentCountsMap = false

    /// Cached comments keyed by comment ID for all-comments timeline browsing.
    private var commentTimelineCommentsByID: [Int64: SegmentComment] = [:]
    /// Best-known segment metadata for each comment ID.
    private var commentTimelineContextByCommentID: [Int64: CommentTimelineSegmentContext] = [:]
    /// Segment IDs already queried for comments while building the timeline.
    private var commentTimelineLoadedSegmentIDs: Set<Int64> = []
    /// Oldest frame timestamp seen in the all-comments data source.
    private var commentTimelineOldestFrameTimestamp: Date?
    /// Newest frame timestamp seen in the all-comments data source.
    private var commentTimelineNewestFrameTimestamp: Date?
    /// In-flight debounced comment search task.
    private var commentSearchTask: Task<Void, Never>?
    /// Current normalized query backing paginated comment search.
    private var activeCommentSearchQuery: String = ""
    /// Next pagination offset for server-side comment search.
    private var commentSearchNextOffset: Int = 0
    /// Page size for server-side comment search.
    private static let commentSearchPageSize = 10
    /// Debounce delay for comment search input.
    private static let commentSearchDebounceNanoseconds: UInt64 = 250_000_000

    /// Number of active filters (for badge display)
    public var activeFilterCount: Int {
        filterCriteria.activeFilterCount
    }

    /// Whether pending filters differ from applied filters
    public var hasPendingFilterChanges: Bool {
        pendingFilterCriteria != filterCriteria
    }

    // MARK: - Peek Mode State (view full timeline context while filtered)

    /// Complete timeline state snapshot for returning from peek mode
    public struct TimelineStateSnapshot {
        let filterCriteria: FilterCriteria
        let frames: [TimelineFrame]
        let currentIndex: Int
        let hasMoreOlder: Bool
        let hasMoreNewer: Bool
    }

    /// Cached filtered view state (saved when entering peek mode, restored on exit)
    private var cachedFilteredState: TimelineStateSnapshot?

    /// Whether we're currently in peek mode (viewing full context)
    @Published public var isPeeking: Bool = false

    // MARK: - Zoom Computed Properties

    /// Current pixels per frame based on zoom level
    public var pixelsPerFrame: CGFloat {
        let range = TimelineConfig.basePixelsPerFrame - TimelineConfig.minPixelsPerFrame
        return TimelineConfig.minPixelsPerFrame + (range * zoomLevel)
    }

    /// Frame skip factor - how many frames to skip when displaying
    /// At 50%+ zoom, show all frames (skip = 1)
    /// Below 50%, progressively skip more frames
    public var frameSkipFactor: Int {
        if zoomLevel >= 0.5 {
            return 1 // Show all frames
        }
        // Below 50% zoom, calculate skip factor
        // At 0% zoom: skip factor of ~5
        // At 25% zoom: skip factor of ~3
        // At 50% zoom: skip factor of 1
        let skipRange = zoomLevel / 0.5 // 0.0 to 1.0 within the 0-50% range
        let maxSkip = 5
        let skip = Int(round(CGFloat(maxSkip) - (skipRange * CGFloat(maxSkip - 1))))
        return max(1, skip)
    }

    /// Visible frames accounting for skip factor
    public var visibleFrameIndices: [Int] {
        let skip = frameSkipFactor
        if skip == 1 {
            return Array(0..<frames.count)
        }
        // Return every Nth frame index
        return stride(from: 0, to: frames.count, by: skip).map { $0 }
    }

    // MARK: - Derived Properties (computed from currentIndex)

    /// Current timeline frame (frame + video info) - derived from currentIndex
    public var currentTimelineFrame: TimelineFrame? {
        guard currentIndex >= 0 && currentIndex < frames.count else { return nil }
        return frames[currentIndex]
    }

    /// Current frame reference - derived from currentIndex
    public var currentFrame: FrameReference? {
        currentTimelineFrame?.frame
    }

    var displayableCurrentImage: NSImage? {
        switch currentFrameStillDisplayMode {
        case .currentImage:
            return currentImage
        case .waitingFallback, .none:
            return nil
        }
    }

    var waitingVideoFallbackImage: NSImage? {
        guard currentFrameStillDisplayMode == .waitingFallback else { return nil }
        return waitingFallbackImage
    }

    var currentFrameMediaDisplayMode: CurrentFrameMediaDisplayMode {
        Self.resolveCurrentFrameMediaDisplayMode(
            currentFrameID: currentTimelineFrame?.frame.id,
            currentImageFrameID: currentImageFrameID,
            hasCurrentImage: currentImage != nil,
            hasVideo: currentTimelineFrame?.videoInfo != nil
        )
    }

    static func resolveCurrentFrameMediaDisplayMode(
        currentFrameID: FrameID?,
        currentImageFrameID: FrameID?,
        hasCurrentImage: Bool,
        hasVideo: Bool
    ) -> CurrentFrameMediaDisplayMode {
        guard let currentFrameID else { return .noContent }

        if hasCurrentImage && currentImageFrameID == currentFrameID {
            return .still
        }

        return hasVideo ? .decodedVideo : .noContent
    }

    var currentFrameStillDisplayMode: CurrentFrameStillDisplayMode {
        Self.resolveCurrentFrameStillDisplayMode(
            currentFrameID: currentTimelineFrame?.frame.id,
            currentImageFrameID: currentImageFrameID,
            hasCurrentImage: currentImage != nil,
            hasVideo: currentTimelineFrame?.videoInfo != nil,
            hasWaitingFallbackImage: waitingFallbackImage != nil,
            pendingVideoPresentationFrameID: pendingVideoPresentationFrameID,
            isPendingVideoPresentationReady: isPendingVideoPresentationReady
        )
    }

    static func resolveCurrentFrameStillDisplayMode(
        currentFrameID: FrameID?,
        currentImageFrameID: FrameID?,
        hasCurrentImage: Bool,
        hasVideo: Bool,
        hasWaitingFallbackImage: Bool,
        pendingVideoPresentationFrameID: FrameID?,
        isPendingVideoPresentationReady: Bool
    ) -> CurrentFrameStillDisplayMode {
        guard let currentFrameID else { return .none }

        if hasCurrentImage && currentImageFrameID == currentFrameID {
            return .currentImage
        }

        if hasVideo,
           hasWaitingFallbackImage,
           pendingVideoPresentationFrameID == currentFrameID,
           !isPendingVideoPresentationReady {
            return .waitingFallback
        }

        return .none
    }

    /// Video info for displaying the current frame - derived from currentIndex
    public var currentVideoInfo: FrameVideoInfo? {
        guard let timelineFrame = currentTimelineFrame else {
            // Only log if we haven't logged this state recently
            if _lastLoggedVideoInfoFrameID != -1 {
                Log.debug("[SimpleTimelineViewModel] currentVideoInfo: no currentTimelineFrame at index \(currentIndex)", category: .ui)
                _lastLoggedVideoInfoFrameID = -1
            }
            return nil
        }
        guard let info = timelineFrame.videoInfo else {
            if _lastLoggedVideoInfoFrameID != -2 {
                Log.debug("[SimpleTimelineViewModel] currentVideoInfo: frame \(timelineFrame.frame.id.value) has nil videoInfo, source=\(timelineFrame.frame.source)", category: .ui)
                _lastLoggedVideoInfoFrameID = -2
            }
            return nil
        }
        guard info.frameIndex >= 0 else {
            if _lastLoggedVideoInfoFrameID != -3 {
                Log.debug("[SimpleTimelineViewModel] currentVideoInfo: frame \(timelineFrame.frame.id.value) has invalid frameIndex=\(info.frameIndex)", category: .ui)
                _lastLoggedVideoInfoFrameID = -3
            }
            return nil
        }
        // Only log when frame ID changes
        let frameID = timelineFrame.frame.id.value
        if _lastLoggedVideoInfoFrameID != frameID {
            Log.debug("[SimpleTimelineViewModel] currentVideoInfo: frame \(frameID) videoPath=\(info.videoPath), frameIndex=\(info.frameIndex)", category: .ui)
            _lastLoggedVideoInfoFrameID = frameID
        }
        return info
    }

    /// Current timestamp - ALWAYS derived from the current frame
    public var currentTimestamp: Date? {
        currentTimelineFrame?.frame.timestamp
    }

    // MARK: - Computed Properties for Timeline Tape

    private struct AppBlockSnapshot: Sendable {
        let blocks: [AppBlock]
        let frameToBlockIndex: [Int]
        let videoBoundaryIndices: [Int]
        let segmentBoundaryIndices: [Int]

        static let empty = AppBlockSnapshot(
            blocks: [],
            frameToBlockIndex: [],
            videoBoundaryIndices: [],
            segmentBoundaryIndices: []
        )
    }

    private struct SnapshotFrameInput: Sendable {
        let bundleID: String?
        let appName: String?
        let segmentIDValue: Int64
        let timestamp: Date
        let videoPath: String?
    }

    /// Cached block snapshot for timeline tape rendering and navigation.
    private var _cachedAppBlockSnapshot: AppBlockSnapshot?
    private var _cachedAppBlockSnapshotRevision: Int = 0
    private var appBlockSnapshotDirty = false
    private var appBlockSnapshotBuildGeneration: UInt64 = 0
    private var appBlockSnapshotBuildTask: Task<AppBlockSnapshot, Never>?
    private var appBlockSnapshotApplyTask: Task<Void, Never>?

    /// Cached derived tag metadata used by tape rendering.
    private var cachedHiddenTagIDValue: Int64? = nil
    private var cachedAvailableTagsByID: [Int64: Tag] = [:]
    private var _tagCatalogRevision: UInt64 = 0

    /// Read-only lookup map used by TimelineTapeView hot paths.
    public var availableTagsByID: [Int64: Tag] {
        cachedAvailableTagsByID
    }

    /// Increments whenever tag metadata changes so tag-indicator overlays can update cheaply.
    public var tagCatalogRevision: UInt64 {
        _tagCatalogRevision
    }

    /// Increments when a new block snapshot is built. Useful for view-level layout caching.
    public var appBlockSnapshotRevision: Int {
        _cachedAppBlockSnapshotRevision
    }

    private var appBlockSnapshot: AppBlockSnapshot {
        if appBlockSnapshotDirty {
            scheduleAppBlockSnapshotRebuild(reason: "appBlockSnapshot.read")
        }

        if let cached = _cachedAppBlockSnapshot {
            return cached
        }

        guard !frames.isEmpty else {
            return AppBlockSnapshot.empty
        }

        let snapshot = Self.buildAppBlockSnapshot(
            from: makeSnapshotFrameInputs(from: frames),
            segmentTagsMap: segmentTagsMap,
            segmentCommentCountsMap: segmentCommentCountsMap,
            hiddenTagID: cachedHiddenTagIDValue
        )
        _cachedAppBlockSnapshot = snapshot
        appBlockSnapshotDirty = false
        _cachedAppBlockSnapshotRevision &+= 1
        return snapshot
    }

    /// App blocks grouped by consecutive bundle IDs
    /// Note: Since we do server-side filtering, frames already contains only filtered results when filters are active
    public var appBlocks: [AppBlock] {
        appBlockSnapshot.blocks
    }

    private func makeSnapshotFrameInputs(from frameList: [TimelineFrame]) -> [SnapshotFrameInput] {
        frameList.map { timelineFrame in
            SnapshotFrameInput(
                bundleID: timelineFrame.frame.metadata.appBundleID,
                appName: timelineFrame.frame.metadata.appName,
                segmentIDValue: timelineFrame.frame.segmentID.value,
                timestamp: timelineFrame.frame.timestamp,
                videoPath: timelineFrame.videoInfo?.videoPath
            )
        }
    }

    private func refreshTagCachesAndInvalidateSnapshotIfNeeded(reason: String) {
        cachedAvailableTagsByID = Dictionary(
            uniqueKeysWithValues: availableTags.map { ($0.id.value, $0) }
        )
        _tagCatalogRevision &+= 1

        let previousHiddenTagID = cachedHiddenTagIDValue
        cachedHiddenTagIDValue = availableTags.first(where: { $0.isHidden })?.id.value

        if previousHiddenTagID != cachedHiddenTagIDValue {
            invalidateAppBlockSnapshot(reason: "\(reason).hiddenTagChanged")
        }
    }

    private func invalidateAppBlockSnapshot(reason: String) {
        appBlockSnapshotDirty = true
        scheduleAppBlockSnapshotRebuild(reason: reason)
    }

    /// Rebuild block snapshot immediately from current in-memory state.
    /// Use on optimistic local mutations to avoid transient stale tape/group mapping.
    /// The async reconciliation rebuild from didSet invalidation still applies afterward.
    private func refreshAppBlockSnapshotImmediately(reason: String) {
        let snapshot = Self.buildAppBlockSnapshot(
            from: makeSnapshotFrameInputs(from: frames),
            segmentTagsMap: segmentTagsMap,
            segmentCommentCountsMap: segmentCommentCountsMap,
            hiddenTagID: cachedHiddenTagIDValue
        )
        _cachedAppBlockSnapshot = snapshot
        appBlockSnapshotDirty = false
        _cachedAppBlockSnapshotRevision &+= 1

        if Self.isVerboseTimelineLoggingEnabled {
            Log.debug(
                "[TimelineBlocks] Applied immediate snapshot reason='\(reason)' blocks=\(snapshot.blocks.count)",
                category: .ui
            )
        }
    }

    private func scheduleAppBlockSnapshotRebuild(reason: String) {
        guard appBlockSnapshotDirty else { return }

        let frameInputs = makeSnapshotFrameInputs(from: frames)
        let segmentTagsMapSnapshot = segmentTagsMap
        let segmentCommentCountsSnapshot = segmentCommentCountsMap
        let hiddenTagID = cachedHiddenTagIDValue

        appBlockSnapshotDirty = false
        appBlockSnapshotBuildGeneration &+= 1
        let generation = appBlockSnapshotBuildGeneration
        appBlockSnapshotBuildTask?.cancel()
        appBlockSnapshotApplyTask?.cancel()

        let buildTask = Task.detached(priority: .userInitiated) {
            Self.buildAppBlockSnapshot(
                from: frameInputs,
                segmentTagsMap: segmentTagsMapSnapshot,
                segmentCommentCountsMap: segmentCommentCountsSnapshot,
                hiddenTagID: hiddenTagID
            )
        }
        appBlockSnapshotBuildTask = buildTask

        appBlockSnapshotApplyTask = Task { [weak self] in
            let snapshot = await buildTask.value

            guard !Task.isCancelled, let self else { return }
            guard generation == self.appBlockSnapshotBuildGeneration else { return }

            self._cachedAppBlockSnapshot = snapshot
            self._cachedAppBlockSnapshotRevision &+= 1

            if Self.isVerboseTimelineLoggingEnabled {
                Log.debug(
                    "[TimelineBlocks] Applied async snapshot reason='\(reason)' generation=\(generation) blocks=\(snapshot.blocks.count)",
                    category: .ui
                )
            }
        }
    }

    deinit {
        commentSearchTask?.cancel()
        diskFrameBufferMemoryLogTask?.cancel()
        diskFrameBufferInactivityCleanupTask?.cancel()
        foregroundFrameLoadTask?.cancel()
        cacheExpansionTask?.cancel()
        appBlockSnapshotBuildTask?.cancel()
        appBlockSnapshotApplyTask?.cancel()
        pendingDeleteCommitTask?.cancel()
    }

    // MARK: - Private State

    /// Last logged frame ID for currentVideoInfo (prevents duplicate logs from SwiftUI view updates)
    private var _lastLoggedVideoInfoFrameID: Int64?

    /// Sub-frame pixel offset for continuous tape scrolling.
    /// Represents how far the tape has moved beyond the current frame center.
    @Published public var subFrameOffset: CGFloat = 0

    /// Task for debouncing scroll end detection
    private var scrollDebounceTask: Task<Void, Never>?

    /// Task for tape drag momentum animation
    private var tapeDragMomentumTask: Task<Void, Never>?

    /// Task for polling OCR status when processing is in progress
    private var ocrStatusPollingTask: Task<Void, Never>?

    /// Task for auto-dismissing error messages after a delay
    private var errorDismissTask: Task<Void, Never>?

    /// Pending optimistic delete operation that can still be undone.
    private var pendingDeleteOperation: PendingDeleteOperation?
    private var pendingDeleteCommitTask: Task<Void, Never>?

    private struct DiskFrameBufferEntry: Sendable {
        let fileURL: URL
        let sizeBytes: Int64
        var lastAccessSequence: UInt64
    }

    private struct DiskFrameBufferTelemetry {
        var intervalStart = Date()
        var frameRequests = 0
        var diskHits = 0
        var diskMisses = 0
        var storageReads = 0
        var storageReadFailures = 0
        var decodeSuccesses = 0
        var decodeFailures = 0
        var foregroundLoadCancels = 0
        var cacheMoreRequests = 0
        var cacheMoreFramesQueued = 0
        var cacheMoreStored = 0
        var cacheMoreSkippedBuffered = 0
        var cacheMoreFailures = 0
        var cacheMoreCancelled = 0
    }

    /// Disk-backed timeline frame buffer metadata (payload bytes are stored in Library/Caches).
    private var diskFrameBufferIndex: [FrameID: DiskFrameBufferEntry] = [:] {
        didSet {
            let oldCount = oldValue.count
            let newCount = diskFrameBufferIndex.count
            diskFrameBufferBytes = Self.estimatedDiskFrameBufferBytes(diskFrameBufferIndex)
            if oldCount != newCount {
                if Self.isVerboseTimelineLoggingEnabled {
                    Log.debug(
                        "[Memory] diskFrameBuffer changed: \(oldCount) → \(newCount) frames (\(Self.formatBytes(diskFrameBufferBytes)))",
                        category: .ui
                    )
                }
            }
        }
    }
    private var diskFrameBufferBytes: Int64 = 0
    private var diskFrameBufferAccessSequence: UInt64 = 0
    private let diskFrameBufferDirectoryURL: URL

    /// Disk buffer hot window policy: keep requests centered around the playhead.
    private static let hotWindowFrameCount = 50
    private static let cacheMoreBatchSize = 50
    private static let cacheMoreEdgeThreshold = 8
    private static let cacheMoreEdgeRetriggerDistance = 16
    private static let hardSeekResetThreshold = 200
    private static let closeClearThreshold = 10
    private static let diskFrameBufferInactivityTTLSeconds: TimeInterval = 60
    private static let diskFrameBufferFilenameExtension = "jpg"
    private static let diskFrameBufferMemoryLogIntervalNs: UInt64 = 5_000_000_000

    private var diskFrameBufferMemoryLogTask: Task<Void, Never>?
    private var diskFrameBufferTelemetry = DiskFrameBufferTelemetry()
    private var foregroundFrameLoadTask: Task<Void, Never>?
    private var pendingForegroundFrameLoad: PendingForegroundFrameLoad?
    private var isForegroundFrameLoadInFlight = false
    private var activeForegroundFrameID: FrameID?
    private var cacheExpansionTask: Task<Void, Never>?
    private var pendingCacheExpansionQueue: [CacheMoreFrameDescriptor] = []
    private var pendingCacheExpansionReadIndex = 0
    private var queuedOrInFlightCacheExpansionFrameIDs: Set<FrameID> = []
    private var cacheMoreOlderEdgeArmed = true
    private var cacheMoreNewerEdgeArmed = true
    private var diskFrameBufferInactivityCleanupTask: Task<Void, Never>?
    private var hotWindowRange: ClosedRange<Int>?

    private enum CacheExpansionDirection: String, Sendable {
        case centered
        case older
        case newer
    }

    private struct CacheMoreFrameDescriptor: Sendable {
        let frameID: FrameID
        let videoPath: String
        let frameIndex: Int
    }

    private struct PendingForegroundFrameLoad {
        let timelineFrame: TimelineFrame
        let presentationGeneration: UInt64
    }

    /// App quick-filter latency trace payload carried across async reload/boundary paths.
    private struct CmdFQuickFilterLatencyTrace: Sendable {
        let id: String
        let startedAt: CFAbsoluteTime
        let trigger: String
        let action: String
        let bundleID: String
        let source: FrameSource
    }

    /// Pending app quick-filter trace, consumed by the next filter-triggered reload call.
    private var pendingCmdFQuickFilterLatencyTrace: CmdFQuickFilterLatencyTrace?

    /// Preferred index to apply atomically with the next full-frame-window replacement.
    /// Prevents transient edge snaps when `frames` changes before index selection finishes.
    private var pendingCurrentIndexAfterFrameReplacement: Int?
    /// Deferred rolling-window trim applied after scrubbing stops to avoid mid-scrub index jumps.
    private var deferredTrimDirection: TrimDirection?
    private var deferredTrimAnchorFrameID: FrameID?
    private var deferredTrimAnchorTimestamp: Date?

    /// Monotonic ID for loading state transitions in logs.
    private var loadingTransitionID: UInt64 = 0
    /// Start time of the currently active loading state.
    private var loadingStateStartedAt: CFAbsoluteTime?
    /// Reason associated with the currently active loading state.
    private var activeLoadingReason: String = "idle"
    /// Whether async image/OCR/URL presentation work is allowed to publish results.
    private var presentationWorkEnabled = false
    /// Monotonic generation used to invalidate stale presentation tasks across hide/show.
    private var presentationWorkGeneration: UInt64 = 0

    /// Monotonic ID for timeline fetch traces.
    private var fetchTraceID: UInt64 = 0
    /// Monotonic ID for Cmd+G/date-jump traces.
    private var dateJumpTraceID: UInt64 = 0

    // MARK: - Infinite Scroll Window State

    /// Timestamp of the oldest loaded frame (for loading older frames)
    private var oldestLoadedTimestamp: Date?

    /// Timestamp of the newest loaded frame (for loading newer frames)
    private var newestLoadedTimestamp: Date?

    /// Flag to prevent concurrent loads in the "older" direction
    private var isLoadingOlder = false

    /// Flag to prevent concurrent loads in the "newer" direction
    private var isLoadingNewer = false

    /// In-flight boundary load tasks. Cancel these when a jump/reload replaces the frame window.
    private var olderBoundaryLoadTask: Task<Void, Never>?
    private var newerBoundaryLoadTask: Task<Void, Never>?

    /// Flag to prevent duplicate initial frame loading (set synchronously to avoid race conditions)
    private var isInitialLoadInProgress = false
    /// Waiters for the current initial most-recent load. Overlapping callers await completion
    /// instead of being dropped, preventing missed-load races between multiple launch paths.
    private var initialMostRecentLoadWaiters: [CheckedContinuation<Void, Never>] = []

    /// Whether there's more data available in the older direction
    private var hasMoreOlder = true

    /// Whether there's more data available in the newer direction
    private var hasMoreNewer = true

    /// Whether we've hit the absolute end of available data (no more frames exist in DB)
    private var hasReachedAbsoluteEnd = false

    /// Whether we've hit the absolute start of available data (no more frames exist in DB)
    private var hasReachedAbsoluteStart = false

    /// Counter for periodic memory logging (log every N navigations)
    private var navigationCounter: Int = 0
    private static let memoryLogInterval = 50  // Log memory state every 50 navigations

    // MARK: - Filter Cache Keys

    /// Key for storing cached filter criteria
    private static let cachedFilterCriteriaKey = "timeline.cachedFilterCriteria"
    /// Key for storing when filter cache was saved
    private static let cachedFilterSavedAtKey = "timeline.cachedFilterSavedAt"
    /// How long the cached filter criteria remains valid (2 minutes)
    private static let filterCacheExpirationSeconds: TimeInterval = 120

    // MARK: - Background Refresh Throttling

    /// Threshold: if user is within this many frames of newest, near-live reopen policy can apply.
    /// This is only considered when the newest loaded frame is still recent.
    private static let nearLiveEdgeFrameThreshold: Int = 50

    // MARK: - Playhead Position History (for Cmd+Z undo / Cmd+Shift+Z redo)

    /// Stored position for undo history - contains both frame ID (for precision) and timestamp (for reloading)
    private struct StoppedPosition {
        let frameID: FrameID
        let timestamp: Date
        let searchHighlightQuery: String?
    }

    /// Stack of positions where the playhead was stopped for at least 350 ms
    /// Most recent position is at the end of the array
    /// Stores frame ID (unique identifier) and timestamp (for reloading frames if needed)
    private var stoppedPositionHistory: [StoppedPosition] = []

    /// Stack of positions that were undone and can be restored via redo.
    /// Most recently undone position is at the end of the array.
    private var undonePositionHistory: [StoppedPosition] = []

    /// Maximum number of stopped positions to remember
    private static let maxStoppedPositionHistory = 50

    /// Work item for detecting when playhead has been stationary for at least 350 ms
    /// Using DispatchWorkItem instead of Task for lower overhead during rapid navigation
    private var playheadStoppedDetectionWorkItem: DispatchWorkItem?

    /// The frame ID that was last recorded as a stopped position (to avoid duplicates)
    private var lastRecordedStoppedFrameID: FrameID?

    /// Time threshold (in seconds) for considering playhead as "stopped"
    private static let stoppedThresholdSeconds: TimeInterval = 0.35

    // MARK: - Dependencies

    private let coordinator: AppCoordinator

#if DEBUG
    // Test-only hooks for deterministic concurrency race coverage around refreshProcessingStatuses().
    struct RefreshProcessingStatusesTestHooks {
        var getFrameProcessingStatuses: (([Int64]) async throws -> [Int64: Int])?
        var getFrameWithVideoInfoByID: ((FrameID) async throws -> FrameWithVideoInfo?)?
    }

    // Test-only hooks for deterministic refreshFrameData coverage.
    struct RefreshFrameDataTestHooks {
        var getMostRecentFramesWithVideoInfo: ((Int, FilterCriteria) async throws -> [FrameWithVideoInfo])?
        var now: (() -> Date)?
    }

    // Test-only hooks for deterministic time-window fetch behavior.
    struct WindowFetchTestHooks {
        var getFramesWithVideoInfo: ((Date, Date, Int, FilterCriteria, String) async throws -> [FrameWithVideoInfo])?
        var getFramesWithVideoInfoBefore: ((Date, Int, FilterCriteria, String) async throws -> [FrameWithVideoInfo])?
        var getFramesWithVideoInfoAfter: ((Date, Int, FilterCriteria, String) async throws -> [FrameWithVideoInfo])?
    }

    struct ForegroundFrameLoadTestHooks {
        var loadFrameData: ((TimelineFrame) async throws -> Data)?
    }
    struct FrameLookupTestHooks {
        var getFrameWithVideoInfoByID: ((FrameID) async throws -> FrameWithVideoInfo?)?
    }
    struct FrameOverlayLoadTestHooks {
        var getURLBoundingBox: ((Date, FrameSource) async throws -> URLBoundingBox?)?
        var getOCRStatus: ((FrameID) async throws -> OCRProcessingStatus)?
        var getAllOCRNodes: ((FrameID, FrameSource) async throws -> [OCRNodeWithText])?
    }
    var test_refreshProcessingStatusesHooks = RefreshProcessingStatusesTestHooks()
    var test_refreshFrameDataHooks = RefreshFrameDataTestHooks()
    var test_windowFetchHooks = WindowFetchTestHooks()
    var test_foregroundFrameLoadHooks = ForegroundFrameLoadTestHooks()
    var test_frameLookupHooks = FrameLookupTestHooks()
    var test_frameOverlayLoadHooks = FrameOverlayLoadTestHooks()
#endif

    // MARK: - Initialization

    public init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        self.diskFrameBufferDirectoryURL = Self.defaultDiskFrameBufferDirectoryURL()

        // Restore search overlay visibility from last session
        // On first launch, default to showing the overlay (true)
        if UserDefaults.standard.object(forKey: "searchOverlayVisible") == nil {
            self.isSearchOverlayVisible = true
            UserDefaults.standard.set(true, forKey: "searchOverlayVisible")
        } else {
            self.isSearchOverlayVisible = UserDefaults.standard.bool(forKey: "searchOverlayVisible")
        }
        if isSearchOverlayVisible {
            // On startup with overlay already visible, keep the search bar front-and-center
            // without opening the recent-entries popover by default.
            searchViewModel.suppressRecentEntriesForNextOverlayOpen()
        }

        // Listen for data source changes (e.g., Rewind data toggled)
        Log.debug("[SimpleTimelineViewModel] Setting up dataSourceDidChange observer", category: .ui)
        NotificationCenter.default.addObserver(
            forName: .dataSourceDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Log.debug("[SimpleTimelineViewModel] Received dataSourceDidChange notification", category: .ui)
            Task { @MainActor in
                Log.debug("[SimpleTimelineViewModel] About to call invalidateCachesAndReload, self is nil: \(self == nil)", category: .ui)
                self?.invalidateCachesAndReload()
            }
        }

        // Persist search overlay visibility preference
        setupSearchOverlayPersistence()
        initializeDiskFrameBuffer()
        startDiskFrameBufferMemoryReporting()
    }

    /// Persist search overlay visibility state across app launches
    private func setupSearchOverlayPersistence() {
        $isSearchOverlayVisible
            .dropFirst() // Skip initial value from restoration
            .sink { isVisible in
                UserDefaults.standard.set(isVisible, forKey: "searchOverlayVisible")
            }
            .store(in: &cancellables)
    }

    private func startDiskFrameBufferMemoryReporting() {
        diskFrameBufferMemoryLogTask?.cancel()
        diskFrameBufferMemoryLogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .nanoseconds(Int64(Self.diskFrameBufferMemoryLogIntervalNs)), clock: .continuous)
                guard !Task.isCancelled, let self else { break }
                self.logDiskFrameBufferMemorySnapshot()
            }
        }
    }

    private func logDiskFrameBufferMemorySnapshot() {
        Log.info(
            "[Timeline-Memory] diskFrameBufferCount=\(diskFrameBufferIndex.count) diskFrameBufferBytes=\(Self.formatBytes(diskFrameBufferBytes)) frameWindowCount=\(frames.count)",
            category: .ui
        )
        logAndResetDiskFrameBufferTelemetry()
    }

    private func logAndResetDiskFrameBufferTelemetry() {
        let now = Date()
        let intervalSeconds = max(now.timeIntervalSince(diskFrameBufferTelemetry.intervalStart), 0.001)
        let hadSamples =
            diskFrameBufferTelemetry.frameRequests > 0
            || diskFrameBufferTelemetry.cacheMoreRequests > 0
            || diskFrameBufferTelemetry.cacheMoreFailures > 0
            || diskFrameBufferTelemetry.storageReadFailures > 0
            || diskFrameBufferTelemetry.decodeFailures > 0

        guard hadSamples else {
            diskFrameBufferTelemetry.intervalStart = now
            return
        }

        let requests = diskFrameBufferTelemetry.frameRequests
        let hits = diskFrameBufferTelemetry.diskHits
        let misses = diskFrameBufferTelemetry.diskMisses
        let hitRate = requests > 0 ? (Double(hits) / Double(requests)) * 100.0 : 0
        let requestRate = Double(requests) / intervalSeconds

        Log.info(
            "[Timeline-Perf] interval=\(String(format: "%.1f", intervalSeconds))s frameReq=\(requests) reqRate=\(String(format: "%.1f", requestRate))/s diskHit=\(hits) miss=\(misses) hitRate=\(String(format: "%.1f", hitRate))% storageReads=\(diskFrameBufferTelemetry.storageReads) storageReadFailures=\(diskFrameBufferTelemetry.storageReadFailures) decodeOK=\(diskFrameBufferTelemetry.decodeSuccesses) decodeFail=\(diskFrameBufferTelemetry.decodeFailures) fgCancels=\(diskFrameBufferTelemetry.foregroundLoadCancels) cacheMoreReq=\(diskFrameBufferTelemetry.cacheMoreRequests) cacheMoreQueued=\(diskFrameBufferTelemetry.cacheMoreFramesQueued) cacheMoreStored=\(diskFrameBufferTelemetry.cacheMoreStored) cacheMoreSkipBuffered=\(diskFrameBufferTelemetry.cacheMoreSkippedBuffered) cacheMoreFail=\(diskFrameBufferTelemetry.cacheMoreFailures) cacheMoreCancel=\(diskFrameBufferTelemetry.cacheMoreCancelled) hotWindow=\(describeHotWindowRange()) fgPressure=\(hasForegroundFrameLoadPressure) fgActive=\(hasForegroundFrameLoadActivity) cacheMoreActive=\(hasCacheExpansionActivity)",
            category: .ui
        )

        diskFrameBufferTelemetry = DiskFrameBufferTelemetry(intervalStart: now)
    }

    private static func estimatedDiskFrameBufferBytes(_ index: [FrameID: DiskFrameBufferEntry]) -> Int64 {
        index.values.reduce(into: Int64(0)) { total, entry in
            total += entry.sizeBytes
        }
    }

    private static func defaultDiskFrameBufferDirectoryURL() -> URL {
        let cachesDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return cachesDirectory
            .appendingPathComponent("io.retrace.app", isDirectory: true)
            .appendingPathComponent("TimelineFrameBuffer", isDirectory: true)
    }

    private static func frameID(fromDiskFrameFileURL url: URL) -> FrameID? {
        guard url.pathExtension.lowercased() == Self.diskFrameBufferFilenameExtension else { return nil }
        let frameIDString = url.deletingPathExtension().lastPathComponent
        guard let rawValue = Int64(frameIDString) else { return nil }
        return FrameID(value: rawValue)
    }

    private func diskFrameBufferURL(for frameID: FrameID) -> URL {
        diskFrameBufferDirectoryURL
            .appendingPathComponent("\(frameID.value)")
            .appendingPathExtension(Self.diskFrameBufferFilenameExtension)
    }

    private func initializeDiskFrameBuffer() {
        do {
            try FileManager.default.createDirectory(
                at: diskFrameBufferDirectoryURL,
                withIntermediateDirectories: true
            )
        } catch {
            Log.warning("[Timeline-DiskBuffer] Failed to create disk frame buffer directory: \(error)", category: .ui)
            return
        }

        do {
            let resourceKeys: Set<URLResourceKey> = [
                .isRegularFileKey
            ]
            let files = try FileManager.default.contentsOfDirectory(
                at: diskFrameBufferDirectoryURL,
                includingPropertiesForKeys: Array(resourceKeys),
                options: [.skipsHiddenFiles]
            )

            // Crash-safe cleanup: remove stale session cache files on app launch.
            var removedCount = 0
            for fileURL in files {
                let values = try? fileURL.resourceValues(forKeys: resourceKeys)
                guard values?.isRegularFile == true else { continue }
                guard Self.frameID(fromDiskFrameFileURL: fileURL) != nil else { continue }
                try? FileManager.default.removeItem(at: fileURL)
                removedCount += 1
            }

            if removedCount > 0 {
                Log.info(
                    "[Timeline-DiskBuffer] Cleared \(removedCount) stale disk-buffer files from previous session",
                    category: .ui
                )
            }
            diskFrameBufferAccessSequence = 0
            diskFrameBufferIndex = [:]
        } catch {
            Log.warning("[Timeline-DiskBuffer] Failed to initialize disk frame buffer index: \(error)", category: .ui)
        }
    }

    private func containsFrameInDiskFrameBuffer(_ frameID: FrameID) -> Bool {
        diskFrameBufferIndex[frameID] != nil
    }

    private func touchDiskFrameBufferEntry(_ frameID: FrameID) {
        guard var entry = diskFrameBufferIndex[frameID] else { return }
        diskFrameBufferAccessSequence &+= 1
        entry.lastAccessSequence = diskFrameBufferAccessSequence
        diskFrameBufferIndex[frameID] = entry
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: entry.fileURL.path)
    }

    private func removeDiskFrameBufferEntries(_ frameIDs: [FrameID], reason: String) {
        guard !frameIDs.isEmpty else { return }

        for frameID in frameIDs {
            if let entry = diskFrameBufferIndex.removeValue(forKey: frameID) {
                try? FileManager.default.removeItem(at: entry.fileURL)
            }
        }

        if Self.isVerboseTimelineLoggingEnabled {
            Log.info("[Memory] Removed \(frameIDs.count) frames from disk frame buffer (\(reason))", category: .ui)
        }
    }

    private func clearDiskFrameBuffer(reason: String) {
        cancelForegroundFrameLoad(reason: "clearDiskFrameBuffer.\(reason)")
        cancelCacheExpansion(reason: "clearDiskFrameBuffer.\(reason)")
        hotWindowRange = nil
        resetCacheMoreEdgeHysteresis()
        let oldCount = diskFrameBufferIndex.count
        guard oldCount > 0 else { return }

        let frameIDs = Array(diskFrameBufferIndex.keys)
        removeDiskFrameBufferEntries(frameIDs, reason: reason)
    }

    private func describeHotWindowRange() -> String {
        guard let hotWindowRange else { return "none" }
        return "\(hotWindowRange.lowerBound)...\(hotWindowRange.upperBound)"
    }

    private var hasCacheExpansionActivity: Bool {
        cacheExpansionTask != nil || !pendingCacheExpansionQueue.isEmpty
    }

    /// True only when foreground frame loading is actually competing for I/O.
    private var hasForegroundFrameLoadPressure: Bool {
        isForegroundFrameLoadInFlight || pendingForegroundFrameLoad != nil
    }

    private var hasForegroundFrameLoadActivity: Bool {
        hasForegroundFrameLoadPressure || foregroundFrameLoadTask != nil
    }

    private func cancelForegroundFrameLoad(reason: String) {
        guard hasForegroundFrameLoadActivity else { return }
        foregroundFrameLoadTask?.cancel()
        foregroundFrameLoadTask = nil
        pendingForegroundFrameLoad = nil
        isForegroundFrameLoadInFlight = false
        activeForegroundFrameID = nil
        diskFrameBufferTelemetry.foregroundLoadCancels += 1
        if Self.isVerboseTimelineLoggingEnabled {
            Log.debug("[Timeline-DiskBuffer] Cancelled foreground frame load (\(reason))", category: .ui)
        }
    }

    public func setPresentationWorkEnabled(_ enabled: Bool, reason: String) {
        let didChange = presentationWorkEnabled != enabled
        presentationWorkEnabled = enabled
        if didChange {
            presentationWorkGeneration &+= 1
        }
        if Self.isVerboseTimelineLoggingEnabled {
            Log.debug(
                "[TIMELINE-PRESENTATION] enabled=\(enabled) generation=\(presentationWorkGeneration) reason=\(reason)",
                category: .ui
            )
        }
    }

    private func currentPresentationWorkGeneration() -> UInt64 {
        presentationWorkGeneration
    }

    private func canPublishPresentationResult(
        frameID: FrameID? = nil,
        expectedGeneration: UInt64
    ) -> Bool {
        guard presentationWorkEnabled, expectedGeneration == presentationWorkGeneration else {
            return false
        }
        guard let frameID else { return true }
        return currentTimelineFrame?.frame.id == frameID
    }

    private func cancelCacheExpansion(reason: String) {
        guard hasCacheExpansionActivity else { return }
        cacheExpansionTask?.cancel()
        cacheExpansionTask = nil
        pendingCacheExpansionQueue.removeAll()
        pendingCacheExpansionReadIndex = 0
        queuedOrInFlightCacheExpansionFrameIDs.removeAll()
        diskFrameBufferTelemetry.cacheMoreCancelled += 1
        if Self.isVerboseTimelineLoggingEnabled {
            Log.debug("[Timeline-DiskBuffer] Cancelled cacheMore task (\(reason))", category: .ui)
        }
    }

    private func cancelDiskFrameBufferInactivityCleanup() {
        diskFrameBufferInactivityCleanupTask?.cancel()
        diskFrameBufferInactivityCleanupTask = nil
    }

    private func scheduleDiskFrameBufferInactivityCleanup() {
        cancelDiskFrameBufferInactivityCleanup()
        diskFrameBufferInactivityCleanupTask = Task { [weak self] in
            let ttlNanoseconds = UInt64(Self.diskFrameBufferInactivityTTLSeconds * 1_000_000_000)
            try? await Task.sleep(for: .nanoseconds(Int64(ttlNanoseconds)), clock: .continuous)
            guard !Task.isCancelled, let self else { return }
            guard !self.hasForegroundFrameLoadActivity, !self.hasCacheExpansionActivity else { return }
            self.clearDiskFrameBuffer(reason: "inactivity ttl")
            Log.info(
                "[Timeline-DiskBuffer] Cleared disk buffer after \(Int(Self.diskFrameBufferInactivityTTLSeconds))s inactivity",
                category: .ui
            )
            self.diskFrameBufferInactivityCleanupTask = nil
        }
    }

    private func shouldClearDiskFrameBufferOnTimelineClose() -> Bool {
        if isInLiveMode { return true }
        guard !frames.isEmpty else { return true }
        return currentIndex <= Self.closeClearThreshold
            || currentIndex >= (frames.count - 1 - Self.closeClearThreshold)
    }

    public func handleTimelineOpened() {
        setPresentationWorkEnabled(true, reason: "timeline opened")
        cancelDiskFrameBufferInactivityCleanup()
    }

    /// Call this when the timeline view disappears.
    public func handleTimelineClosed() {
        setPresentationWorkEnabled(false, reason: "timeline closed")
        cancelForegroundFrameLoad(reason: "timeline closed")
        cancelCacheExpansion(reason: "timeline closed")
        if shouldClearDiskFrameBufferOnTimelineClose() {
            clearDiskFrameBuffer(reason: "timeline close near boundary/live edge")
        } else {
            scheduleDiskFrameBufferInactivityCleanup()
        }
    }

    private func readFrameDataFromDiskFrameBuffer(frameID: FrameID) async -> Data? {
        guard let entry = diskFrameBufferIndex[frameID] else { return nil }

        do {
            let fileURL = entry.fileURL
            let data = try await Task.detached(priority: .userInitiated) {
                try Data(contentsOf: fileURL, options: [.mappedIfSafe])
            }.value
            touchDiskFrameBufferEntry(frameID)
            return data
        } catch {
            removeDiskFrameBufferEntries([frameID], reason: "read failure")
            return nil
        }
    }

    private func storeFrameDataInDiskFrameBuffer(frameID: FrameID, data: Data) async {
        let fileURL = diskFrameBufferURL(for: frameID)
        do {
            try await Task.detached(priority: .utility) {
                try FileManager.default.createDirectory(
                    at: fileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try data.write(to: fileURL, options: [.atomic])
            }.value

            diskFrameBufferAccessSequence &+= 1
            let entry = DiskFrameBufferEntry(
                fileURL: fileURL,
                sizeBytes: Int64(data.count),
                lastAccessSequence: diskFrameBufferAccessSequence
            )
            diskFrameBufferIndex[frameID] = entry
        } catch {
            Log.warning("[Timeline-DiskBuffer] Failed to write frame \(frameID.value) to disk buffer: \(error)", category: .ui)
        }
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: max(0, bytes))
    }

    private func summarizeFiltersForLog(_ filters: FilterCriteria) -> String {
        let appCount = filters.selectedApps?.count ?? 0
        let tagCount = filters.selectedTags?.count ?? 0
        let hasWindowFilter = !(filters.windowNameFilter?.isEmpty ?? true)
        let hasURLFilter = !(filters.browserUrlFilter?.isEmpty ?? true)
        let hasDateRange = !filters.effectiveDateRanges.isEmpty

        return "active=\(filters.hasActiveFilters) count=\(filters.activeFilterCount) apps=\(appCount) tags=\(tagCount) appMode=\(filters.appFilterMode.rawValue) hidden=\(filters.hiddenFilter.rawValue) comments=\(filters.commentFilter.rawValue) window=\(hasWindowFilter) url=\(hasURLFilter) date=\(hasDateRange)"
    }

    private func logCmdFPlayheadState(
        _ stage: String,
        trace: CmdFQuickFilterLatencyTrace?,
        targetTimestamp: Date? = nil,
        extra: String? = nil
    ) {
        _ = stage
        _ = trace
        _ = targetTimestamp
        _ = extra
    }

    private func setLoadingState(_ loading: Bool, reason: String) {
        if loading {
            if isLoading {
                let activeElapsedMs = loadingStateStartedAt.map { (CFAbsoluteTimeGetCurrent() - $0) * 1000 } ?? 0
                Log.warning(
                    "[TIMELINE-LOADING] START ignored reason='\(reason)' because already loading reason='\(activeLoadingReason)' elapsed=\(String(format: "%.1f", activeElapsedMs))ms",
                    category: .ui
                )
                return
            }

            loadingTransitionID &+= 1
            activeLoadingReason = reason
            loadingStateStartedAt = CFAbsoluteTimeGetCurrent()
            isLoading = true
            Log.info(
                "[TIMELINE-LOADING][\(loadingTransitionID)] START reason='\(reason)' frames=\(frames.count) index=\(currentIndex) filters={\(summarizeFiltersForLog(filterCriteria))}",
                category: .ui
            )
            return
        }

        guard isLoading else {
            Log.debug("[TIMELINE-LOADING] END ignored reason='\(reason)' (already idle)", category: .ui)
            return
        }

        let traceID = loadingTransitionID
        let startedReason = activeLoadingReason
        let elapsedMs = loadingStateStartedAt.map { (CFAbsoluteTimeGetCurrent() - $0) * 1000 } ?? 0

        isLoading = false
        loadingStateStartedAt = nil
        activeLoadingReason = "idle"

        Log.recordLatency(
            "timeline.loading.overlay_visible_ms",
            valueMs: elapsedMs,
            category: .ui,
            summaryEvery: 10,
            warningThresholdMs: 500,
            criticalThresholdMs: 2000
        )

        let message = "[TIMELINE-LOADING][\(traceID)] END reason='\(reason)' startedBy='\(startedReason)' elapsed=\(String(format: "%.1f", elapsedMs))ms frames=\(frames.count) index=\(currentIndex)"
        if elapsedMs >= 1500 {
            Log.warning(message, category: .ui)
        } else {
            Log.info(message, category: .ui)
        }
    }

    private func nextFetchTraceID(prefix: String) -> String {
        fetchTraceID &+= 1
        return "\(prefix)-\(fetchTraceID)"
    }

    private func fetchFramesWithVideoInfoLogged(
        from startDate: Date,
        to endDate: Date,
        limit: Int,
        filters: FilterCriteria,
        reason: String
    ) async throws -> [FrameWithVideoInfo] {
        let traceID = nextFetchTraceID(prefix: "window")
        let fetchStart = CFAbsoluteTimeGetCurrent()
        Log.info(
            "[TIMELINE-FETCH][\(traceID)] START reason='\(reason)' range=[\(Log.timestamp(from: startDate)) → \(Log.timestamp(from: endDate))] limit=\(limit) filters={\(summarizeFiltersForLog(filters))}",
            category: .ui
        )

        do {
            let framesWithVideoInfo: [FrameWithVideoInfo]
#if DEBUG
            if let override = test_windowFetchHooks.getFramesWithVideoInfo {
                framesWithVideoInfo = try await override(startDate, endDate, limit, filters, reason)
            } else {
                framesWithVideoInfo = try await coordinator.getFramesWithVideoInfo(
                    from: startDate,
                    to: endDate,
                    limit: limit,
                    filters: filters
                )
            }
#else
            framesWithVideoInfo = try await coordinator.getFramesWithVideoInfo(
                from: startDate,
                to: endDate,
                limit: limit,
                filters: filters
            )
#endif
            let elapsedMs = (CFAbsoluteTimeGetCurrent() - fetchStart) * 1000
            Log.recordLatency(
                "timeline.fetch.window_frames_ms",
                valueMs: elapsedMs,
                category: .ui,
                summaryEvery: 10,
                warningThresholdMs: 250,
                criticalThresholdMs: 750
            )
            let message = "[TIMELINE-FETCH][\(traceID)] END reason='\(reason)' count=\(framesWithVideoInfo.count) elapsed=\(String(format: "%.1f", elapsedMs))ms"
            if elapsedMs >= 750 {
                Log.warning(message, category: .ui)
            } else {
                Log.info(message, category: .ui)
            }
            return framesWithVideoInfo
        } catch {
            let elapsedMs = (CFAbsoluteTimeGetCurrent() - fetchStart) * 1000
            Log.error(
                "[TIMELINE-FETCH][\(traceID)] FAIL reason='\(reason)' after \(String(format: "%.1f", elapsedMs))ms: \(error)",
                category: .ui
            )
            throw error
        }
    }

    private func fetchFramesWithVideoInfoBeforeLogged(
        timestamp: Date,
        limit: Int,
        filters: FilterCriteria,
        reason: String
    ) async throws -> [FrameWithVideoInfo] {
        let traceID = nextFetchTraceID(prefix: "before")
        let fetchStart = CFAbsoluteTimeGetCurrent()
        let effectiveDateRanges = filters.effectiveDateRanges
        let boundedStart = effectiveDateRanges.first?.start.map { Log.timestamp(from: $0) } ?? "nil"
        let boundedEnd = effectiveDateRanges.first?.end.map { Log.timestamp(from: $0) } ?? "nil"
        Log.info(
            "[TIMELINE-FETCH][\(traceID)] START reason='\(reason)' before=\(Log.timestamp(from: timestamp)) limit=\(limit) boundedRange=[\(boundedStart) → \(boundedEnd)] filters={\(summarizeFiltersForLog(filters))}",
            category: .ui
        )

        do {
            let framesWithVideoInfo: [FrameWithVideoInfo]
#if DEBUG
            if let override = test_windowFetchHooks.getFramesWithVideoInfoBefore {
                framesWithVideoInfo = try await override(timestamp, limit, filters, reason)
            } else {
                framesWithVideoInfo = try await coordinator.getFramesWithVideoInfoBefore(
                    timestamp: timestamp,
                    limit: limit,
                    filters: filters
                )
            }
#else
            framesWithVideoInfo = try await coordinator.getFramesWithVideoInfoBefore(
                timestamp: timestamp,
                limit: limit,
                filters: filters
            )
#endif
            let elapsedMs = (CFAbsoluteTimeGetCurrent() - fetchStart) * 1000
            Log.recordLatency(
                "timeline.fetch.before_frames_ms",
                valueMs: elapsedMs,
                category: .ui,
                summaryEvery: 10,
                warningThresholdMs: 250,
                criticalThresholdMs: 750
            )
            let message = "[TIMELINE-FETCH][\(traceID)] END reason='\(reason)' count=\(framesWithVideoInfo.count) elapsed=\(String(format: "%.1f", elapsedMs))ms"
            if elapsedMs >= 750 {
                Log.warning(message, category: .ui)
            } else {
                Log.info(message, category: .ui)
            }
            return framesWithVideoInfo
        } catch {
            let elapsedMs = (CFAbsoluteTimeGetCurrent() - fetchStart) * 1000
            Log.error(
                "[TIMELINE-FETCH][\(traceID)] FAIL reason='\(reason)' after \(String(format: "%.1f", elapsedMs))ms: \(error)",
                category: .ui
            )
            throw error
        }
    }

    private func fetchFramesWithVideoInfoAfterLogged(
        timestamp: Date,
        limit: Int,
        filters: FilterCriteria,
        reason: String
    ) async throws -> [FrameWithVideoInfo] {
        let traceID = nextFetchTraceID(prefix: "after")
        let fetchStart = CFAbsoluteTimeGetCurrent()
        let effectiveDateRanges = filters.effectiveDateRanges
        let boundedStart = effectiveDateRanges.first?.start.map { Log.timestamp(from: $0) } ?? "nil"
        let boundedEnd = effectiveDateRanges.first?.end.map { Log.timestamp(from: $0) } ?? "nil"
        Log.info(
            "[TIMELINE-FETCH][\(traceID)] START reason='\(reason)' after=\(Log.timestamp(from: timestamp)) limit=\(limit) boundedRange=[\(boundedStart) → \(boundedEnd)] filters={\(summarizeFiltersForLog(filters))}",
            category: .ui
        )

        do {
            let framesWithVideoInfo: [FrameWithVideoInfo]
#if DEBUG
            if let override = test_windowFetchHooks.getFramesWithVideoInfoAfter {
                framesWithVideoInfo = try await override(timestamp, limit, filters, reason)
            } else {
                framesWithVideoInfo = try await coordinator.getFramesWithVideoInfoAfter(
                    timestamp: timestamp,
                    limit: limit,
                    filters: filters
                )
            }
#else
            framesWithVideoInfo = try await coordinator.getFramesWithVideoInfoAfter(
                timestamp: timestamp,
                limit: limit,
                filters: filters
            )
#endif
            let elapsedMs = (CFAbsoluteTimeGetCurrent() - fetchStart) * 1000
            Log.recordLatency(
                "timeline.fetch.after_frames_ms",
                valueMs: elapsedMs,
                category: .ui,
                summaryEvery: 10,
                warningThresholdMs: 250,
                criticalThresholdMs: 750
            )
            let message = "[TIMELINE-FETCH][\(traceID)] END reason='\(reason)' count=\(framesWithVideoInfo.count) elapsed=\(String(format: "%.1f", elapsedMs))ms"
            if elapsedMs >= 750 {
                Log.warning(message, category: .ui)
            } else {
                Log.info(message, category: .ui)
            }
            return framesWithVideoInfo
        } catch {
            let elapsedMs = (CFAbsoluteTimeGetCurrent() - fetchStart) * 1000
            Log.error(
                "[TIMELINE-FETCH][\(traceID)] FAIL reason='\(reason)' after \(String(format: "%.1f", elapsedMs))ms: \(error)",
                category: .ui
            )
            throw error
        }
    }

    private func fetchMostRecentFramesWithVideoInfoLogged(
        limit: Int,
        filters: FilterCriteria,
        reason: String
    ) async throws -> [FrameWithVideoInfo] {
        let traceID = nextFetchTraceID(prefix: "most-recent")
        let fetchStart = CFAbsoluteTimeGetCurrent()
        Log.info(
            "[TIMELINE-FETCH][\(traceID)] START reason='\(reason)' mostRecent limit=\(limit) filters={\(summarizeFiltersForLog(filters))}",
            category: .ui
        )

        do {
            let framesWithVideoInfo: [FrameWithVideoInfo]
#if DEBUG
            if let override = test_refreshFrameDataHooks.getMostRecentFramesWithVideoInfo {
                framesWithVideoInfo = try await override(limit, filters)
            } else {
                framesWithVideoInfo = try await coordinator.getMostRecentFramesWithVideoInfo(limit: limit, filters: filters)
            }
#else
            framesWithVideoInfo = try await coordinator.getMostRecentFramesWithVideoInfo(limit: limit, filters: filters)
#endif
            let elapsedMs = (CFAbsoluteTimeGetCurrent() - fetchStart) * 1000
            Log.recordLatency(
                "timeline.fetch.most_recent_frames_ms",
                valueMs: elapsedMs,
                category: .ui,
                summaryEvery: 10,
                warningThresholdMs: 220,
                criticalThresholdMs: 600
            )
            let message = "[TIMELINE-FETCH][\(traceID)] END reason='\(reason)' count=\(framesWithVideoInfo.count) elapsed=\(String(format: "%.1f", elapsedMs))ms"
            if elapsedMs >= 600 {
                Log.warning(message, category: .ui)
            } else {
                Log.info(message, category: .ui)
            }
            return framesWithVideoInfo
        } catch {
            let elapsedMs = (CFAbsoluteTimeGetCurrent() - fetchStart) * 1000
            Log.error(
                "[TIMELINE-FETCH][\(traceID)] FAIL reason='\(reason)' after \(String(format: "%.1f", elapsedMs))ms: \(error)",
                category: .ui
            )
            throw error
        }
    }

    private func refreshFrameDataCurrentDate() -> Date {
#if DEBUG
        if let override = test_refreshFrameDataHooks.now {
            return override()
        }
#endif
        return Date()
    }

    /// Invalidate all caches and reload frames from the current position
    /// Called when data sources change (e.g., Rewind toggled on/off)
    @MainActor
    public func invalidateCachesAndReload() {
        Log.info("[DataSourceChange] invalidateCachesAndReload() called", category: .ui)

        // Clear disk frame buffer metadata/files
        let oldImageCount = diskFrameBufferIndex.count
        Log.debug("[DataSourceChange] Clearing disk frame buffer with \(oldImageCount) entries", category: .ui)
        clearDiskFrameBuffer(reason: "data source reload")
        Log.debug("[DataSourceChange] Disk frame buffer cleared, new count: \(diskFrameBufferIndex.count)", category: .ui)

        // Clear app blocks cache
        let hadAppBlocks = _cachedAppBlockSnapshot != nil
        hasLoadedAvailableTags = false
        hasLoadedSegmentTagsMap = false
        hasLoadedSegmentCommentCountsMap = false
        invalidateAppBlockSnapshot(reason: "invalidateCachesAndReload")
        Log.debug("[DataSourceChange] Cleared app blocks cache (had cached: \(hadAppBlocks))", category: .ui)

        // Clear search results (data source changed, results may no longer be valid)
        Log.debug("[DataSourceChange] Clearing search results", category: .ui)
        searchViewModel.clearSearchResults()

        // Clear filter state and cache
        filterCriteria = .none
        clearCachedFilterCriteria()
        Log.debug("[DataSourceChange] Cleared filter state and cache", category: .ui)

        Log.info("[DataSourceChange] Cleared \(oldImageCount) buffered frames, search results, and filters, reloading from current position", category: .ui)
        Log.debug("[DataSourceChange] Current frames count: \(frames.count), currentIndex: \(currentIndex)", category: .ui)

        // Reload frames from the current timestamp
        if currentIndex >= 0 && currentIndex < frames.count {
            let currentTimestamp = frames[currentIndex].frame.timestamp
            Log.debug("[DataSourceChange] Will reload frames around timestamp: \(currentTimestamp)", category: .ui)
            Task {
                await reloadFramesAroundTimestamp(currentTimestamp)
            }
        } else {
            // No current position, load most recent
            Log.debug("[DataSourceChange] No valid current position, will load most recent frame", category: .ui)
            Task {
                await loadMostRecentFrame()
            }
        }
        Log.debug("[DataSourceChange] invalidateCachesAndReload() completed", category: .ui)
    }

    /// Reload frames around a specific timestamp (used after data source changes and app quick filter)
    private func reloadFramesAroundTimestamp(
        _ timestamp: Date,
        cmdFTrace: CmdFQuickFilterLatencyTrace? = nil,
        refreshPresentation: Bool = true
    ) async {
        let reloadStart = CFAbsoluteTimeGetCurrent()
        Log.debug("[DataSourceChange] reloadFramesAroundTimestamp() starting for timestamp: \(timestamp)", category: .ui)
        if let cmdFTrace {
            Log.debug(
                "[CmdFPerf][\(cmdFTrace.id)] Reload around timestamp started action=\(cmdFTrace.action) app=\(cmdFTrace.bundleID) source=\(cmdFTrace.source.rawValue)",
                category: .ui
            )
        }
        logCmdFPlayheadState("reload.start", trace: cmdFTrace, targetTimestamp: timestamp)
        setLoadingState(true, reason: "reloadFramesAroundTimestamp")
        clearError()
        cancelBoundaryLoadTasks(reason: "reloadFramesAroundTimestamp")

        do {
            let calendar = Calendar.current
            let startDate = calendar.date(byAdding: .minute, value: -10, to: timestamp) ?? timestamp
            let endDate = calendar.date(byAdding: .minute, value: 10, to: timestamp) ?? timestamp

            Log.debug("[DataSourceChange] Fetching frames from \(startDate) to \(endDate)", category: .ui)
            let queryStart = CFAbsoluteTimeGetCurrent()
            // Always pass filterCriteria to ensure hidden filter is applied (default: .hide)
            let framesWithVideoInfo = try await fetchFramesWithVideoInfoLogged(
                from: startDate,
                to: endDate,
                limit: 1000,
                filters: filterCriteria,
                reason: "reloadFramesAroundTimestamp"
            )
            let queryElapsedMs = (CFAbsoluteTimeGetCurrent() - queryStart) * 1000
            Log.debug("[DataSourceChange] Fetched \(framesWithVideoInfo.count) frames from data adapter", category: .ui)

            if !framesWithVideoInfo.isEmpty {
                let timelineFrames = framesWithVideoInfo.map {
                    TimelineFrame(frameWithVideoInfo: $0)
                }
                let closestIndex = Self.findClosestFrameIndex(in: timelineFrames, to: timestamp)
                pendingCurrentIndexAfterFrameReplacement = closestIndex
                frames = timelineFrames
                logCmdFPlayheadState("reload.framesReplaced", trace: cmdFTrace, targetTimestamp: timestamp)

                // Find the frame closest to the original timestamp
                if currentIndex != closestIndex {
                    currentIndex = closestIndex
                }
                logCmdFPlayheadState(
                    "reload.closestIndexSelected",
                    trace: cmdFTrace,
                    targetTimestamp: timestamp,
                    extra: "closestIndex=\(closestIndex)"
                )

                updateWindowBoundaries()
                resetBoundaryStateForReloadWindow()

                // Load tag metadata/map lazily so the tape can render subtle tag indicators.
                ensureTapeTagIndicatorDataLoadedIfNeeded()

                if refreshPresentation {
                    loadImageIfNeeded()
                }

                // Check if we need to pre-load more frames (near edge of loaded window)
                let boundaryLoad = checkAndLoadMoreFrames(reason: "reloadFramesAroundTimestamp", cmdFTrace: cmdFTrace)
                logCmdFPlayheadState(
                    "reload.boundaryCheck",
                    trace: cmdFTrace,
                    targetTimestamp: timestamp,
                    extra: "boundaryOlder=\(boundaryLoad.older) boundaryNewer=\(boundaryLoad.newer)"
                )

                Log.info("[DataSourceChange] Reloaded \(frames.count) frames around \(timestamp)", category: .ui)
                if let cmdFTrace {
                    let reloadElapsedMs = (CFAbsoluteTimeGetCurrent() - reloadStart) * 1000
                    let totalElapsedMs = (CFAbsoluteTimeGetCurrent() - cmdFTrace.startedAt) * 1000
                    Log.recordLatency(
                        "timeline.cmdf.quick_filter.reload_window_ms",
                        valueMs: totalElapsedMs,
                        category: .ui,
                        summaryEvery: 5,
                        warningThresholdMs: 220,
                        criticalThresholdMs: 500
                    )
                    Log.info(
                        "[CmdFPerf][\(cmdFTrace.id)] Reload complete trigger=\(cmdFTrace.trigger) action=\(cmdFTrace.action) query=\(String(format: "%.1f", queryElapsedMs))ms reload=\(String(format: "%.1f", reloadElapsedMs))ms total=\(String(format: "%.1f", totalElapsedMs))ms frames=\(frames.count) index=\(currentIndex) boundaryOlder=\(boundaryLoad.older) boundaryNewer=\(boundaryLoad.newer)",
                        category: .ui
                    )
                }
            } else {
                // No frames found, try loading most recent
                Log.info("[DataSourceChange] No frames found around timestamp, loading most recent", category: .ui)
                if let cmdFTrace {
                    let elapsedBeforeFallbackMs = (CFAbsoluteTimeGetCurrent() - cmdFTrace.startedAt) * 1000
                    Log.warning(
                        "[CmdFPerf][\(cmdFTrace.id)] Empty reload window after \(String(format: "%.1f", elapsedBeforeFallbackMs))ms (query \(String(format: "%.1f", queryElapsedMs))ms), falling back to loadMostRecentFrame()",
                        category: .ui
                    )
                }
                logCmdFPlayheadState("reload.emptyWindow", trace: cmdFTrace, targetTimestamp: timestamp)
                let fallbackStart = CFAbsoluteTimeGetCurrent()
                // Hand off loading ownership so fallback can run loadMostRecentFrame instead of being skipped.
                setLoadingState(false, reason: "reloadFramesAroundTimestamp.fallbackHandoff")
                await loadMostRecentFrame(refreshPresentation: refreshPresentation)
                logCmdFPlayheadState("reload.fallbackComplete", trace: cmdFTrace, targetTimestamp: timestamp)
                if let cmdFTrace {
                    let fallbackElapsedMs = (CFAbsoluteTimeGetCurrent() - fallbackStart) * 1000
                    let totalElapsedMs = (CFAbsoluteTimeGetCurrent() - cmdFTrace.startedAt) * 1000
                    Log.recordLatency(
                        "timeline.cmdf.quick_filter.fallback_total_ms",
                        valueMs: totalElapsedMs,
                        category: .ui,
                        summaryEvery: 5,
                        warningThresholdMs: 320,
                        criticalThresholdMs: 750
                    )
                    Log.info(
                        "[CmdFPerf][\(cmdFTrace.id)] Fallback loadMostRecentFrame() complete fallback=\(String(format: "%.1f", fallbackElapsedMs))ms total=\(String(format: "%.1f", totalElapsedMs))ms",
                        category: .ui
                    )
                }
                return
            }
        } catch {
            Log.error("[DataSourceChange] Failed to reload frames: \(error)", category: .ui)
            if let cmdFTrace {
                let totalElapsedMs = (CFAbsoluteTimeGetCurrent() - cmdFTrace.startedAt) * 1000
                Log.error(
                    "[CmdFPerf][\(cmdFTrace.id)] Reload failed after \(String(format: "%.1f", totalElapsedMs))ms action=\(cmdFTrace.action) app=\(cmdFTrace.bundleID): \(error)",
                    category: .ui
                )
            }
            self.error = error.localizedDescription
        }

        setLoadingState(false, reason: "reloadFramesAroundTimestamp.complete")
    }

    // MARK: - Frame Selection & Deletion

    /// Select a frame at the given index and move the playhead there
    public func selectFrame(at index: Int) {
        guard index >= 0 && index < frames.count else { return }

        // Move playhead to the selected frame
        navigateToFrame(index)

        // Set selection
        selectedFrameIndex = index
    }

    /// Clear the current selection
    public func clearSelection() {
        selectedFrameIndex = nil
    }

    /// Request deletion of the selected frame (shows confirmation dialog)
    public func requestDeleteSelectedFrame() {
        guard selectedFrameIndex != nil else { return }
        showDeleteConfirmation = true
    }

    /// Perform optimistic deletion of the selected frame and queue persistence with an undo window.
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

        // Optimistically mark/delete in UI immediately.
        deletedFrameIDs.insert(frameID)
        frames.remove(at: index)

        // Keep block grouping/navigation consistent immediately for optimistic UI.
        refreshAppBlockSnapshotImmediately(reason: "confirmDeleteSelectedFrame")

        // Adjust current index if needed
        if currentIndex >= frames.count {
            currentIndex = max(0, frames.count - 1)
        } else if currentIndex > index {
            currentIndex -= 1
        }

        // Clear selection
        selectedFrameIndex = nil
        showDeleteConfirmation = false

        // Load image if needed for new current frame
        loadImageIfNeeded()

        Log.debug("[Delete] Frame \(frameID) removed from UI (optimistic deletion)", category: .ui)

        DashboardViewModel.recordFrameDeleted(
            coordinator: coordinator,
            source: "timeline_delete",
            frameID: frameID.value
        )

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

    /// Cancel deletion
    public func cancelDelete() {
        showDeleteConfirmation = false
        isDeleteSegmentMode = false
    }

    /// Restore the most recently deleted frame/segment if still within the undo window.
    public func undoPendingDelete() {
        guard let operation = pendingDeleteOperation else { return }
        clearPendingDeleteState()
        restoreDeletedOperation(operation, reason: "undo")
        showToast("Deletion undone", icon: "arrow.uturn.backward.circle.fill")
    }

    /// Dismiss the undo banner and persist the pending deletion immediately.
    public func dismissPendingDeleteUndo() {
        guard let operation = pendingDeleteOperation else { return }
        clearPendingDeleteState()
        Task { [weak self] in
            await self?.commitDeleteOperation(operation, reason: "dismiss-undo", restoreOnFailure: true)
        }
    }

    private func stagePendingDelete(_ operation: PendingDeleteOperation) {
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

    private func commitPendingDeleteAfterUndoWindow() async {
        guard let operation = pendingDeleteOperation else { return }
        clearPendingDeleteState()
        await commitDeleteOperation(operation, reason: "undo-window-expired", restoreOnFailure: true)
    }

    private func commitPendingDeleteIfNeeded(reason: String) {
        guard let operation = pendingDeleteOperation else { return }
        clearPendingDeleteState()
        Task { [weak self] in
            await self?.commitDeleteOperation(operation, reason: reason, restoreOnFailure: false)
        }
    }

    private func clearPendingDeleteState() {
        pendingDeleteCommitTask?.cancel()
        pendingDeleteCommitTask = nil
        pendingDeleteOperation = nil
        pendingDeleteUndoMessage = nil
    }

    private func commitDeleteOperation(
        _ operation: PendingDeleteOperation,
        reason: String,
        restoreOnFailure: Bool
    ) async {
        do {
            switch operation.payload {
            case .frame(let frameRef):
                try await coordinator.deleteFrame(
                    frameID: frameRef.id,
                    timestamp: frameRef.timestamp,
                    source: frameRef.source
                )
                Log.debug("[Delete] Committed frame deletion frameID=\(frameRef.id.value) reason=\(reason)", category: .ui)
            case .frames(let frameRefs):
                try await coordinator.deleteFrames(frameRefs)
                Log.debug("[Delete] Committed segment deletion frames=\(frameRefs.count) reason=\(reason)", category: .ui)
            }
        } catch {
            Log.error("[Delete] Failed to persist deletion reason=\(reason): \(error)", category: .ui)
            if restoreOnFailure {
                restoreDeletedOperation(operation, reason: "commit-failed")
                showToast("Delete failed. Restored.", icon: "xmark.circle.fill")
            } else {
                showToast("Delete may not have persisted", icon: "exclamationmark.triangle.fill")
            }
        }
    }

    private func restoreDeletedOperation(_ operation: PendingDeleteOperation, reason: String) {
        let insertIndex = min(max(0, operation.restoreStartIndex), frames.count)
        frames.insert(contentsOf: operation.removedFrames, at: insertIndex)
        for frameID in operation.removedFrameIDs {
            deletedFrameIDs.remove(frameID)
        }

        refreshAppBlockSnapshotImmediately(reason: "restoreDeletedOperation.\(reason)")

        if frames.isEmpty {
            currentIndex = 0
            selectedFrameIndex = nil
        } else {
            currentIndex = min(max(0, operation.previousCurrentIndex), frames.count - 1)
            if let previousSelection = operation.previousSelectedFrameIndex,
               previousSelection >= 0,
               previousSelection < frames.count {
                selectedFrameIndex = previousSelection
            } else {
                selectedFrameIndex = nil
            }
        }

        loadImageIfNeeded()
    }

    /// Get the selected frame (if any)
    public var selectedFrame: TimelineFrame? {
        guard let index = selectedFrameIndex, index >= 0 && index < frames.count else { return nil }
        return frames[index]
    }

    /// Get the app block containing the selected frame
    public var selectedBlock: AppBlock? {
        guard let index = selectedFrameIndex else { return nil }
        return getBlock(forFrameAt: index)
    }

    /// Get the app block containing a frame at the given index
    public func getBlock(forFrameAt index: Int) -> AppBlock? {
        guard let blockIndex = blockIndexForFrame(index) else { return nil }
        let blocks = appBlockSnapshot.blocks
        guard blockIndex >= 0 && blockIndex < blocks.count else { return nil }
        return blocks[blockIndex]
    }

    private func blockIndexForFrame(_ index: Int) -> Int? {
        let mapping = appBlockSnapshot.frameToBlockIndex
        guard index >= 0 && index < mapping.count else { return nil }
        return mapping[index]
    }

    /// Jump to the start of the previous consecutive app block.
    /// Returns true when navigation occurred, false when already at the oldest block.
    @discardableResult
    public func navigateToPreviousBlockStart() -> Bool {
        guard !frames.isEmpty else { return false }
        let snapshot = appBlockSnapshot
        let blocks = snapshot.blocks
        guard !blocks.isEmpty else { return false }
        guard let currentBlockIndex = blockIndexForFrame(currentIndex),
              currentBlockIndex > 0 else {
            return false
        }

        navigateToFrame(blocks[currentBlockIndex - 1].startIndex)
        return true
    }

    /// Jump to the start of the next consecutive app block.
    /// Returns true when navigation occurred, false when already at the newest block.
    @discardableResult
    public func navigateToNextBlockStart() -> Bool {
        guard !frames.isEmpty else { return false }
        let snapshot = appBlockSnapshot
        let blocks = snapshot.blocks
        guard !blocks.isEmpty else { return false }
        guard let currentBlockIndex = blockIndexForFrame(currentIndex),
              currentBlockIndex < blocks.count - 1 else {
            return false
        }

        navigateToFrame(blocks[currentBlockIndex + 1].startIndex)
        return true
    }

    /// Jump to the start of the next consecutive app block.
    /// If already in the newest block, jump to the newest frame.
    /// Returns true when navigation occurred, false when already at the newest frame.
    @discardableResult
    public func navigateToNextBlockStartOrNewestFrame() -> Bool {
        guard !frames.isEmpty else { return false }
        let snapshot = appBlockSnapshot
        let blocks = snapshot.blocks
        guard !blocks.isEmpty else { return false }
        guard let currentBlockIndex = blockIndexForFrame(currentIndex) else {
            return false
        }

        if currentBlockIndex < blocks.count - 1 {
            navigateToFrame(blocks[currentBlockIndex + 1].startIndex)
            return true
        }

        let newestFrameIndex = frames.count - 1
        guard currentIndex < newestFrameIndex else { return false }
        navigateToFrame(newestFrameIndex)
        return true
    }

    /// Get all unique segment IDs within a visible block
    public func getSegmentIds(inBlock block: AppBlock) -> Set<SegmentID> {
        var segmentIds = Set<SegmentID>()
        for index in block.startIndex...block.endIndex {
            if index < frames.count {
                let segmentId = SegmentID(value: frames[index].frame.segmentID.value)
                segmentIds.insert(segmentId)
            }
        }
        return segmentIds
    }

    /// Get the number of frames in the selected segment
    public var selectedSegmentFrameCount: Int {
        selectedBlock?.frameCount ?? 0
    }

    /// Perform optimistic deletion of the entire segment and queue persistence with an undo window.
    public func confirmDeleteSegment() {
        guard let block = selectedBlock else {
            showDeleteConfirmation = false
            isDeleteSegmentMode = false
            return
        }

        let previousCurrentIndex = currentIndex
        let previousSelectedFrameIndex = selectedFrameIndex
        let removedFrames = Array(frames[block.startIndex...min(block.endIndex, frames.count - 1)])

        // Collect all frames to delete (need full FrameReference for deferred database deletion)
        var framesToDelete: [FrameReference] = []
        for index in block.startIndex...block.endIndex {
            if index < frames.count {
                let frameRef = frames[index].frame
                deletedFrameIDs.insert(frameRef.id)
                framesToDelete.append(frameRef)
            }
        }

        let deleteCount = block.frameCount
        let startIndex = block.startIndex

        // Remove frames from array (in reverse to maintain indices)
        frames.removeSubrange(block.startIndex...min(block.endIndex, frames.count - 1))

        // Keep block grouping/navigation consistent immediately for optimistic UI.
        refreshAppBlockSnapshotImmediately(reason: "confirmDeleteSegment")

        // Adjust current index
        if currentIndex >= startIndex + deleteCount {
            // Current was after deleted segment
            currentIndex -= deleteCount
        } else if currentIndex >= startIndex {
            // Current was within deleted segment - move to start of where segment was
            currentIndex = max(0, min(startIndex, frames.count - 1))
        }

        // Clear selection
        selectedFrameIndex = nil
        showDeleteConfirmation = false
        isDeleteSegmentMode = false

        // Load image if needed for new current frame
        loadImageIfNeeded()

        Log.debug("[Delete] Segment with \(deleteCount) frames removed from UI (optimistic deletion)", category: .ui)

        let uniqueSegmentCount = Set(framesToDelete.map { $0.segmentID.value }).count
        DashboardViewModel.recordSegmentDeleted(
            coordinator: coordinator,
            source: "timeline_delete",
            segmentCount: uniqueSegmentCount,
            frameCount: deleteCount
        )

        stagePendingDelete(
            PendingDeleteOperation(
                id: UUID(),
                payload: .frames(framesToDelete),
                removedFrames: removedFrames,
                removedFrameIDs: framesToDelete.map(\.id),
                restoreStartIndex: startIndex,
                previousCurrentIndex: previousCurrentIndex,
                previousSelectedFrameIndex: previousSelectedFrameIndex,
                undoMessage: "Segment deleted (\(deleteCount) frames)"
            )
        )
    }

    // MARK: - Tag Operations

    /// Load context-menu support data used by tag/comment submenus.
    public func loadTimelineContextMenuData() async {
        async let tagsTask: Void = loadTags()
        async let commentsTask: Void = loadCommentsForSelectedTimelineBlock()
        _ = await (tagsTask, commentsTask)
    }

    public func recordTagSubmenuOpen(source: String, block: AppBlock? = nil) {
        let resolvedBlock: AppBlock?
        if let block {
            resolvedBlock = block
        } else if let index = timelineContextMenuSegmentIndex {
            resolvedBlock = getBlock(forFrameAt: index)
        } else {
            resolvedBlock = nil
        }

        let segmentCount = resolvedBlock.map { getSegmentIds(inBlock: $0).count }
        let frameCount = resolvedBlock?.frameCount
        let selectedTagCount = resolvedBlock?.tagIDs.count ?? selectedSegmentTags.count

        DashboardViewModel.recordTagSubmenuOpen(
            coordinator: coordinator,
            source: source,
            segmentCount: segmentCount,
            frameCount: frameCount,
            selectedTagCount: selectedTagCount
        )
    }

    public func recordCommentSubmenuOpen(source: String, block: AppBlock? = nil) {
        let resolvedBlock: AppBlock?
        if let block {
            resolvedBlock = block
        } else if let index = timelineContextMenuSegmentIndex {
            resolvedBlock = getBlock(forFrameAt: index)
        } else {
            resolvedBlock = nil
        }

        DashboardViewModel.recordCommentSubmenuOpen(
            coordinator: coordinator,
            source: source,
            segmentCount: resolvedBlock.map { getSegmentIds(inBlock: $0).count },
            frameCount: resolvedBlock?.frameCount,
            existingCommentCount: selectedBlockComments.count
        )
    }

    /// Opens the timeline context menu directly into the tag submenu for a tape block.
    public func openTagSubmenuForTimelineBlock(_ block: AppBlock, source: String = "timeline_block") {
        guard block.frameCount > 0 else { return }

        timelineContextMenuSegmentIndex = block.startIndex
        selectedFrameIndex = block.startIndex
        newCommentText = ""
        newCommentAttachmentDrafts = []
        selectedBlockComments = []
        selectedBlockCommentPreferredSegmentByID = [:]
        blockCommentsLoadError = nil
        resetCommentTimelineState()
        showTagSubmenu = true
        showCommentSubmenu = false
        isHoveringAddTagButton = false
        isHoveringAddCommentButton = false

        if let pointerLocation = currentMouseLocationInContentCoordinates() {
            timelineContextMenuLocation = pointerLocation
        }

        showTimelineContextMenu = true
        recordTagSubmenuOpen(source: source, block: block)

        Task { await loadTags() }
    }

    /// Opens the timeline context menu directly into the comment submenu for a tape block.
    public func openCommentSubmenuForTimelineBlock(_ block: AppBlock, source: String = "timeline_block") {
        guard block.frameCount > 0 else { return }

        timelineContextMenuSegmentIndex = block.startIndex
        selectedFrameIndex = block.startIndex
        newCommentText = ""
        newCommentAttachmentDrafts = []
        selectedBlockComments = []
        selectedBlockCommentPreferredSegmentByID = [:]
        blockCommentsLoadError = nil
        resetCommentTimelineState()
        showTagSubmenu = false
        showCommentSubmenu = true
        isHoveringAddTagButton = false
        isHoveringAddCommentButton = false

        if let pointerLocation = currentMouseLocationInContentCoordinates() {
            timelineContextMenuLocation = pointerLocation
        }

        // Open only the dedicated comment overlay; do not present the right-click context menu.
        showTimelineContextMenu = false
        recordCommentSubmenuOpen(source: source, block: block)

        Task { await loadCommentsForSelectedTimelineBlock() }
    }

    /// Load existing comments linked anywhere in the currently selected timeline block.
    /// Results are deduplicated by comment ID and sorted oldest → newest.
    public func loadCommentsForSelectedTimelineBlock() async {
        guard let index = timelineContextMenuSegmentIndex,
              let block = getBlock(forFrameAt: index) else {
            selectedBlockComments = []
            selectedBlockCommentPreferredSegmentByID = [:]
            blockCommentsLoadError = nil
            isLoadingBlockComments = false
            return
        }

        let segmentIDs = getSegmentIds(inBlock: block).sorted { $0.value < $1.value }
        guard !segmentIDs.isEmpty else {
            selectedBlockComments = []
            selectedBlockCommentPreferredSegmentByID = [:]
            blockCommentsLoadError = nil
            isLoadingBlockComments = false
            return
        }

        isLoadingBlockComments = true
        blockCommentsLoadError = nil

        do {
            var commentsByID: [Int64: SegmentComment] = [:]
            var preferredSegmentByCommentID: [Int64: SegmentID] = [:]
            for segmentID in segmentIDs {
                let comments = try await coordinator.getCommentsForSegment(segmentId: segmentID)
                for comment in comments {
                    if preferredSegmentByCommentID[comment.id.value] == nil {
                        preferredSegmentByCommentID[comment.id.value] = segmentID
                    }
                    commentsByID[comment.id.value] = comment
                }
            }

            selectedBlockComments = commentsByID.values.sorted {
                if $0.createdAt == $1.createdAt {
                    return $0.id.value < $1.id.value
                }
                return $0.createdAt < $1.createdAt
            }
            selectedBlockCommentPreferredSegmentByID = preferredSegmentByCommentID
            isLoadingBlockComments = false
        } catch {
            isLoadingBlockComments = false
            selectedBlockComments = []
            selectedBlockCommentPreferredSegmentByID = [:]
            blockCommentsLoadError = "Could not load comments."
            Log.error("[Comments] Failed to load block comments: \(error)", category: .ui)
        }
    }

    /// Preferred segment context for a comment shown in the selected block thread.
    public func preferredSegmentIDForSelectedBlockComment(_ commentID: SegmentCommentID) -> SegmentID? {
        selectedBlockCommentPreferredSegmentByID[commentID.value]
    }

    private func currentMouseLocationInContentCoordinates() -> CGPoint? {
        guard let window = NSApp.keyWindow,
              let contentView = window.contentView else {
            return nil
        }

        let mouseOnScreen = NSEvent.mouseLocation
        let mouseInWindow = window.convertPoint(fromScreen: mouseOnScreen)
        return CGPoint(x: mouseInWindow.x, y: contentView.bounds.height - mouseInWindow.y)
    }

    /// Load all available tags from the database, and tags for the selected segment
    public func loadTags() async {
        do {
            availableTags = try await coordinator.getAllTags()
            Log.debug("[Tags] Loaded \(availableTags.count) tags: \(availableTags.map { $0.name })", category: .ui)

            // Also load tags for the currently selected segment
            Log.debug("[Tags] timelineContextMenuSegmentIndex = \(String(describing: timelineContextMenuSegmentIndex))", category: .ui)
            if let index = timelineContextMenuSegmentIndex,
               let segmentId = getSegmentId(forFrameAt: index) {
                Log.debug("[Tags] Loading tags for segment \(segmentId.value) at frame index \(index)", category: .ui)
                let segmentTags = try await coordinator.getTagsForSegment(segmentId: segmentId)
                await MainActor.run {
                    selectedSegmentTags = Set(segmentTags.map { $0.id })
                }
                Log.debug("[Tags] Segment \(segmentId.value) has \(segmentTags.count) tags: \(segmentTags.map { $0.name })", category: .ui)
            } else {
                Log.debug("[Tags] Could not get segment ID - index: \(String(describing: timelineContextMenuSegmentIndex)), frames.count: \(frames.count)", category: .ui)
            }
        } catch {
            Log.error("[Tags] Failed to load tags: \(error)", category: .ui)
        }
    }

    /// Load hidden segment IDs from the database
    public func loadHiddenSegments() async {
        do {
            hiddenSegmentIds = try await coordinator.getHiddenSegmentIds()
            Log.debug("[Tags] Loaded \(hiddenSegmentIds.count) hidden segments", category: .ui)
        } catch {
            Log.error("[Tags] Failed to load hidden segments: \(error)", category: .ui)
        }
    }

    /// Loads tag metadata needed for subtle tape indicators.
    /// Done lazily in the background so timeline open stays responsive.
    private func ensureTapeTagIndicatorDataLoadedIfNeeded() {
        guard !frames.isEmpty else { return }

        let needsTags = !hasLoadedAvailableTags
        let needsSegmentTagsMap = !hasLoadedSegmentTagsMap
        let needsSegmentCommentCountsMap = !hasLoadedSegmentCommentCountsMap
        guard needsTags || needsSegmentTagsMap || needsSegmentCommentCountsMap else { return }
        guard !isLoadingTapeTagIndicatorData else { return }

        isLoadingTapeTagIndicatorData = true

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isLoadingTapeTagIndicatorData = false }

            do {
                var didLoadCommentCounts = false
                if needsTags && needsSegmentTagsMap && needsSegmentCommentCountsMap {
                    async let tagsTask = coordinator.getAllTags()
                    async let segmentTagsTask = coordinator.getSegmentTagsMap()
                    async let commentCountsTask = coordinator.getSegmentCommentCountsMap()
                    let (tags, segmentTags, segmentCommentCounts) = try await (tagsTask, segmentTagsTask, commentCountsTask)
                    self.availableTags = tags
                    self.segmentTagsMap = segmentTags
                    self.segmentCommentCountsMap = segmentCommentCounts
                    didLoadCommentCounts = true
                } else if needsTags && needsSegmentTagsMap {
                    async let tagsTask = coordinator.getAllTags()
                    async let segmentTagsTask = coordinator.getSegmentTagsMap()
                    let (tags, segmentTags) = try await (tagsTask, segmentTagsTask)
                    self.availableTags = tags
                    self.segmentTagsMap = segmentTags
                } else if needsTags {
                    self.availableTags = try await coordinator.getAllTags()
                } else if needsSegmentTagsMap {
                    self.segmentTagsMap = try await coordinator.getSegmentTagsMap()
                }

                if needsSegmentCommentCountsMap && !didLoadCommentCounts {
                    self.segmentCommentCountsMap = try await coordinator.getSegmentCommentCountsMap()
                }
            } catch {
                Log.error("[Tags] Failed to load tape tag indicator data: \(error)", category: .ui)
            }
        }
    }

    private var hiddenTagIDValue: Int64? {
        cachedHiddenTagIDValue
    }

    private func addTagToSegmentTagsMap(tagID: TagID, segmentIDs: Set<SegmentID>) {
        guard !segmentIDs.isEmpty else { return }

        var updatedMap = segmentTagsMap
        for segmentID in segmentIDs {
            var tags = updatedMap[segmentID.value] ?? Set<Int64>()
            tags.insert(tagID.value)
            updatedMap[segmentID.value] = tags
        }
        segmentTagsMap = updatedMap
        refreshAppBlockSnapshotImmediately(reason: "addTagToSegmentTagsMap")
    }

    private func removeTagFromSegmentTagsMap(tagID: TagID, segmentIDs: Set<SegmentID>) {
        guard !segmentIDs.isEmpty else { return }

        var updatedMap = segmentTagsMap
        for segmentID in segmentIDs {
            guard var tags = updatedMap[segmentID.value] else { continue }
            tags.remove(tagID.value)
            if tags.isEmpty {
                updatedMap.removeValue(forKey: segmentID.value)
            } else {
                updatedMap[segmentID.value] = tags
            }
        }
        segmentTagsMap = updatedMap
        refreshAppBlockSnapshotImmediately(reason: "removeTagFromSegmentTagsMap")
    }

    private func incrementCommentCountsForSegments(_ segmentIDs: Set<SegmentID>) {
        guard !segmentIDs.isEmpty else { return }

        var updatedMap = segmentCommentCountsMap
        for segmentID in segmentIDs {
            updatedMap[segmentID.value, default: 0] += 1
        }
        segmentCommentCountsMap = updatedMap
        refreshAppBlockSnapshotImmediately(reason: "incrementCommentCountsForSegments")
    }

    private func decrementCommentCountsForSegments(_ segmentIDs: Set<SegmentID>) {
        guard !segmentIDs.isEmpty else { return }

        var updatedMap = segmentCommentCountsMap
        for segmentID in segmentIDs {
            let current = updatedMap[segmentID.value] ?? 0
            if current <= 1 {
                updatedMap.removeValue(forKey: segmentID.value)
            } else {
                updatedMap[segmentID.value] = current - 1
            }
        }
        segmentCommentCountsMap = updatedMap
        refreshAppBlockSnapshotImmediately(reason: "decrementCommentCountsForSegments")
    }

    /// Get the segment ID for a frame at the given index (as SegmentID for database operations)
    public func getSegmentId(forFrameAt index: Int) -> SegmentID? {
        guard index >= 0 && index < frames.count else { return nil }
        // Convert AppSegmentID to SegmentID (they have the same underlying value)
        return SegmentID(value: frames[index].frame.segmentID.value)
    }

    /// Get the app segment ID for a frame at the given index (for UI comparisons)
    private func getAppSegmentId(forFrameAt index: Int) -> AppSegmentID? {
        guard index >= 0 && index < frames.count else { return nil }
        return frames[index].frame.segmentID
    }

    /// Check if a frame is from Rewind data
    private func isFrameFromRewind(at index: Int) -> Bool {
        guard index >= 0 && index < frames.count else { return false }
        let frame = frames[index]

        // Check if frame source is Rewind
        return frame.frame.source == .rewind
    }

    /// Hide all segments in the visible block at the current timeline context menu selection
    /// This hides all consecutive frames with the same bundleID as shown in the UI
    public func hideSelectedTimelineSegment() {
        guard let index = timelineContextMenuSegmentIndex,
              let block = getBlock(forFrameAt: index) else {
            dismissTimelineContextMenu()
            return
        }

        if hidingSegmentBlockRange != nil {
            Log.debug("[Tags] Hide ignored - hide animation already in progress", category: .ui)
            dismissTimelineContextMenu()
            return
        }

        // Check if this is Rewind data before proceeding
        if isFrameFromRewind(at: index) {
            showToast("Cannot hide Rewind data")
            dismissTimelineContextMenu()
            return
        }

        // Get all unique segment IDs in this visible block
        let segmentIds = getSegmentIds(inBlock: block)

        performHideSegment(segmentIds: segmentIds, block: block)
    }

    /// Perform the hide operation (extracted for async flow)
    private func performHideSegment(segmentIds: Set<SegmentID>, block: AppBlock) {
        DashboardViewModel.recordSegmentHide(
            coordinator: coordinator,
            source: "timeline_context",
            segmentCount: segmentIds.count,
            frameCount: block.frameCount,
            hiddenFilter: filterCriteria.hiddenFilter.rawValue
        )

        // Add all to hidden set immediately (optimistic UI update)
        for segmentId in segmentIds {
            hiddenSegmentIds.insert(segmentId)
        }

        let removeCount = block.frameCount
        let startIndex = block.startIndex

        dismissTimelineContextMenu()

        // Animate a quick "squeeze" before removing the block from the tape.
        withAnimation(.easeInOut(duration: 0.16)) {
            hidingSegmentBlockRange = block.startIndex...block.endIndex
        }

        Task { @MainActor in
            try? await Task.sleep(for: .nanoseconds(Int64(160_000_000)), clock: .continuous)

            let previousCurrentFrameID = currentTimelineFrame?.frame.id
            let beforeCount = frames.count
            frames.removeAll { frame in
                let segmentID = SegmentID(value: frame.frame.segmentID.value)
                return segmentIds.contains(segmentID)
            }
            let removedCount = beforeCount - frames.count

            // Keep block grouping/navigation consistent immediately for optimistic UI.
            refreshAppBlockSnapshotImmediately(reason: "performHideSegment.removeFrames")

            // Preserve current frame if still present after removal; otherwise clamp safely.
            if let previousCurrentFrameID,
               let preservedIndex = frames.firstIndex(where: { $0.frame.id == previousCurrentFrameID }) {
                currentIndex = preservedIndex
            } else if frames.isEmpty {
                currentIndex = 0
            } else if currentIndex >= startIndex + removeCount {
                currentIndex = max(0, currentIndex - removedCount)
            } else if currentIndex >= startIndex {
                currentIndex = max(0, min(startIndex, frames.count - 1))
            } else {
                currentIndex = max(0, min(currentIndex, frames.count - 1))
            }

            updateWindowBoundaries()
            hidingSegmentBlockRange = nil

            // Load image for new current frame
            loadImageIfNeeded()
            checkAndLoadMoreFrames(reason: "performHideSegment.postRemoval")

            Log.debug("[Tags] Hidden \(segmentIds.count) segments in block, removed \(removedCount) frames from UI", category: .ui)
        }

        // Persist to database in background
        Task {
            do {
                try await coordinator.hideSegments(segmentIds: Array(segmentIds))
                Log.debug("[Tags] \(segmentIds.count) segments hidden in database", category: .ui)
            } catch {
                Log.error("[Tags] Failed to hide segments in database: \(error)", category: .ui)
            }
        }
    }

    /// Unhide all hidden segments in the visible block at the current timeline context menu selection.
    /// When filtering to only hidden segments, unhidden frames are removed from the current view.
    public func unhideSelectedTimelineSegment() {
        guard let index = timelineContextMenuSegmentIndex,
              let block = getBlock(forFrameAt: index) else {
            dismissTimelineContextMenu()
            return
        }

        if hidingSegmentBlockRange != nil {
            Log.debug("[Tags] Unhide ignored - hide/unhide animation already in progress", category: .ui)
            dismissTimelineContextMenu()
            return
        }

        // Check if this is Rewind data before proceeding
        if isFrameFromRewind(at: index) {
            showToast("Cannot modify Rewind data")
            dismissTimelineContextMenu()
            return
        }

        let segmentIds = getSegmentIds(inBlock: block)
        let segmentIdsToUnhide = Set(segmentIds.filter { hiddenSegmentIds.contains($0) })
        guard !segmentIdsToUnhide.isEmpty else {
            Log.debug("[Tags] Unhide ignored - no hidden segments found in selected block", category: .ui)
            dismissTimelineContextMenu()
            return
        }

        performUnhideSegment(segmentIdsToUnhide: segmentIdsToUnhide, block: block)
    }

    /// Perform the unhide operation (extracted for async flow)
    private func performUnhideSegment(segmentIdsToUnhide: Set<SegmentID>, block: AppBlock) {
        let shouldRemoveFromCurrentView = filterCriteria.hiddenFilter == .onlyHidden
        DashboardViewModel.recordSegmentUnhide(
            coordinator: coordinator,
            source: "timeline_context",
            segmentCount: segmentIdsToUnhide.count,
            frameCount: block.frameCount,
            hiddenFilter: filterCriteria.hiddenFilter.rawValue,
            removedFromCurrentView: shouldRemoveFromCurrentView
        )

        // Remove from hidden set immediately (optimistic UI update)
        for segmentId in segmentIdsToUnhide {
            hiddenSegmentIds.remove(segmentId)
        }

        let removeCount = block.frameCount
        let startIndex = block.startIndex

        dismissTimelineContextMenu()

        if shouldRemoveFromCurrentView {
            // In "Only Hidden" mode, unhidden segments should disappear from the timeline immediately.
            withAnimation(.easeInOut(duration: 0.16)) {
                hidingSegmentBlockRange = block.startIndex...block.endIndex
            }

            Task { @MainActor in
                try? await Task.sleep(for: .nanoseconds(Int64(160_000_000)), clock: .continuous)

                let previousCurrentFrameID = currentTimelineFrame?.frame.id
                let beforeCount = frames.count
                frames.removeAll { frame in
                    let segmentID = SegmentID(value: frame.frame.segmentID.value)
                    return segmentIdsToUnhide.contains(segmentID)
                }
                let removedCount = beforeCount - frames.count

                // Keep block grouping/navigation consistent immediately for optimistic UI.
                refreshAppBlockSnapshotImmediately(reason: "performUnhideSegment.removeFrames")

                // Preserve current frame if still present after removal; otherwise clamp safely.
                if let previousCurrentFrameID,
                   let preservedIndex = frames.firstIndex(where: { $0.frame.id == previousCurrentFrameID }) {
                    currentIndex = preservedIndex
                } else if frames.isEmpty {
                    currentIndex = 0
                } else if currentIndex >= startIndex + removeCount {
                    currentIndex = max(0, currentIndex - removedCount)
                } else if currentIndex >= startIndex {
                    currentIndex = max(0, min(startIndex, frames.count - 1))
                } else {
                    currentIndex = max(0, min(currentIndex, frames.count - 1))
                }

                updateWindowBoundaries()
                hidingSegmentBlockRange = nil

                // Load image for new current frame
                loadImageIfNeeded()
                checkAndLoadMoreFrames(reason: "performUnhideSegment.postRemoval")

                Log.debug("[Tags] Unhidden \(segmentIdsToUnhide.count) segments in block, removed \(removedCount) frames from Only Hidden view", category: .ui)
            }
        } else {
            Log.debug("[Tags] Unhidden \(segmentIdsToUnhide.count) segments in block (kept visible in current filter mode)", category: .ui)
        }

        // Persist to database in background
        Task {
            do {
                guard let hiddenTag = try await coordinator.getTag(name: Tag.hiddenTagName) else {
                    Log.debug("[Tags] Hidden tag missing during unhide; nothing to remove in database", category: .ui)
                    return
                }
                try await coordinator.removeTagFromSegments(segmentIds: Array(segmentIdsToUnhide), tagId: hiddenTag.id)
                Log.debug("[Tags] \(segmentIdsToUnhide.count) segments unhidden in database", category: .ui)
            } catch {
                Log.error("[Tags] Failed to unhide segments in database: \(error)", category: .ui)
            }
        }
    }

    /// Add a tag to all segments in the visible block
    /// This affects all consecutive frames with the same bundleID as shown in the UI
    public func addTagToSelectedSegment(tag: Tag) {
        guard let index = timelineContextMenuSegmentIndex,
              let block = getBlock(forFrameAt: index) else {
            dismissTimelineContextMenu()
            return
        }

        // Check if this is Rewind data before proceeding
        if isFrameFromRewind(at: index) {
            showToast("Cannot tag Rewind data")
            dismissTimelineContextMenu()
            return
        }

        // Get all unique segment IDs in this visible block
        let segmentIds = getSegmentIds(inBlock: block)

        // Optimistic in-memory update so tape indicators refresh immediately.
        addTagToSegmentTagsMap(tagID: tag.id, segmentIDs: segmentIds)

        dismissTimelineContextMenu()

        // Persist to database in background
        Task {
            do {
                try await coordinator.addTagToSegments(segmentIds: Array(segmentIds), tagId: tag.id)
                Log.debug("[Tags] Added tag '\(tag.name)' to \(segmentIds.count) segments in block", category: .ui)
            } catch {
                Log.error("[Tags] Failed to add tag to segments: \(error)", category: .ui)
            }
        }
    }

    /// Toggle a tag on all segments in the visible block (add if not present, remove if present)
    /// This affects all consecutive frames with the same bundleID as shown in the UI
    public func toggleTagOnSelectedSegment(tag: Tag) {
        guard let index = timelineContextMenuSegmentIndex,
              let block = getBlock(forFrameAt: index) else {
            return
        }

        // Check if this is Rewind data before proceeding
        if isFrameFromRewind(at: index) {
            showToast("Cannot tag Rewind data")
            return
        }

        // Get all unique segment IDs in this visible block
        let segmentIds = getSegmentIds(inBlock: block)

        let isCurrentlySelected = selectedSegmentTags.contains(tag.id)
        let action = isCurrentlySelected ? "remove" : "add"

        DashboardViewModel.recordTagToggleOnBlock(
            coordinator: coordinator,
            source: "timeline_tag_submenu",
            tagID: tag.id.value,
            tagName: tag.name,
            action: action,
            segmentCount: segmentIds.count
        )

        // Update UI immediately
        if isCurrentlySelected {
            selectedSegmentTags.remove(tag.id)
            removeTagFromSegmentTagsMap(tagID: tag.id, segmentIDs: segmentIds)
        } else {
            selectedSegmentTags.insert(tag.id)
            addTagToSegmentTagsMap(tagID: tag.id, segmentIDs: segmentIds)
        }

        // Persist to database in background
        Task {
            do {
                if isCurrentlySelected {
                    try await coordinator.removeTagFromSegments(segmentIds: Array(segmentIds), tagId: tag.id)
                    Log.debug("[Tags] Removed tag '\(tag.name)' from \(segmentIds.count) segments in block", category: .ui)
                } else {
                    try await coordinator.addTagToSegments(segmentIds: Array(segmentIds), tagId: tag.id)
                    Log.debug("[Tags] Added tag '\(tag.name)' to \(segmentIds.count) segments in block", category: .ui)
                }
            } catch {
                Log.error("[Tags] Failed to toggle tag on segments: \(error)", category: .ui)
                // Revert UI on error
                await MainActor.run {
                    if isCurrentlySelected {
                        selectedSegmentTags.insert(tag.id)
                        addTagToSegmentTagsMap(tagID: tag.id, segmentIDs: segmentIds)
                    } else {
                        selectedSegmentTags.remove(tag.id)
                        removeTagFromSegmentTagsMap(tagID: tag.id, segmentIDs: segmentIds)
                    }
                }
            }
        }
    }

    /// Create a new tag and add it to all segments in the visible block
    /// Keeps the menu open and shows optimistic UI update
    public func createAndAddTag() {
        let tagName = newTagName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tagName.isEmpty else {
            return
        }

        guard let index = timelineContextMenuSegmentIndex,
              let block = getBlock(forFrameAt: index) else {
            return
        }

        // Check if this is Rewind data before proceeding
        if isFrameFromRewind(at: index) {
            showToast("Cannot tag Rewind data")
            return
        }

        // Get all unique segment IDs in this visible block
        let segmentIds = getSegmentIds(inBlock: block)

        // Clear the input
        newTagName = ""

        // Create tag and add to all segments in background
        Task {
            do {
                let newTag = try await coordinator.createTag(name: tagName)
                try await coordinator.addTagToSegments(segmentIds: Array(segmentIds), tagId: newTag.id)

                // Optimistic UI update: add the new tag to availableTags and mark it as selected
                await MainActor.run {
                    // Add to available tags if not already present
                    if !availableTags.contains(where: { $0.id == newTag.id }) {
                        availableTags.append(newTag)
                        availableTags.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                    }
                    // Mark it as selected on the current segment
                    selectedSegmentTags.insert(newTag.id)
                    addTagToSegmentTagsMap(tagID: newTag.id, segmentIDs: segmentIds)
                }

                DashboardViewModel.recordTagCreateAndAddOnBlock(
                    coordinator: coordinator,
                    source: "timeline_tag_submenu",
                    tagID: newTag.id.value,
                    tagName: newTag.name,
                    segmentCount: segmentIds.count
                )

                Log.debug("[Tags] Created tag '\(tagName)' and added to \(segmentIds.count) segments in block", category: .ui)
            } catch {
                Log.error("[Tags] Failed to create tag: \(error)", category: .ui)
            }
        }
    }

    // MARK: - Comment Operations

    /// Insert markdown helpers into the comment draft.
    public func insertCommentBoldMarkup() {
        appendCommentSnippet("**bold text**")
    }

    public func insertCommentItalicMarkup() {
        appendCommentSnippet("*italic text*")
    }

    public func insertCommentLinkMarkup() {
        appendCommentSnippet("[link text](https://example.com)")
    }

    public func insertCommentTimestampMarkup() {
        guard currentIndex >= 0, currentIndex < frames.count else { return }
        let timestamp = frames[currentIndex].frame.timestamp
        let formatted = Self.commentTimestampFormatter.string(from: timestamp)
        appendCommentSnippet("[\(formatted)] ")
    }

    /// Open native file picker and add selected files as draft comment attachments.
    public func selectCommentAttachmentFiles() {
        DashboardViewModel.recordCommentAttachmentPickerOpened(
            coordinator: coordinator,
            source: "timeline_comment_submenu"
        )

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.message = "Select files to attach to this comment"
        panel.prompt = "Attach"

        // The timeline window runs at a very high level. Presenting as a sheet keeps the
        // picker reliably above the timeline instead of behind it.
        if let hostWindow = NSApp.keyWindow ?? NSApp.mainWindow {
            NSApp.activate(ignoringOtherApps: true)
            hostWindow.makeKeyAndOrderFront(nil)
            panel.beginSheetModal(for: hostWindow) { [weak self] response in
                guard response == .OK else { return }
                Task { @MainActor [weak self] in
                    self?.addCommentAttachmentDrafts(from: panel.urls)
                }
            }
            return
        }

        // Fallback when no host window is available.
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        addCommentAttachmentDrafts(from: panel.urls)
    }

    public func removeCommentAttachmentDraft(_ draft: CommentAttachmentDraft) {
        newCommentAttachmentDrafts.removeAll { $0.id == draft.id }
    }

    /// Open an attachment from an existing saved comment.
    public func openCommentAttachment(_ attachment: SegmentCommentAttachment) {
        let resolvedPath: String
        if attachment.filePath.hasPrefix("/") || attachment.filePath.hasPrefix("~") {
            resolvedPath = NSString(string: attachment.filePath).expandingTildeInPath
        } else {
            resolvedPath = (AppPaths.expandedStorageRoot as NSString).appendingPathComponent(attachment.filePath)
        }

        let url = URL(fileURLWithPath: resolvedPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            showToast("Attachment file is missing", icon: "exclamationmark.triangle.fill")
            return
        }
        NSWorkspace.shared.open(url)
        DashboardViewModel.recordCommentAttachmentOpened(
            coordinator: coordinator,
            source: "timeline_comment_submenu",
            fileExtension: url.pathExtension.lowercased()
        )
    }

    /// Remove a comment from the currently selected timeline block.
    /// This unlinks the comment from segments in this block (and orphan cleanup is automatic).
    @discardableResult
    public func removeCommentFromSelectedTimelineBlock(comment: SegmentComment) async -> Bool {
        guard let index = timelineContextMenuSegmentIndex,
              let block = getBlock(forFrameAt: index) else {
            showToast("Could not resolve selected segment block", icon: "exclamationmark.triangle.fill")
            return false
        }

        let segmentIDs = getSegmentIds(inBlock: block)
        guard !segmentIDs.isEmpty else {
            showToast("No segments selected", icon: "exclamationmark.circle.fill")
            return false
        }

        do {
            var linkedSegmentIDs: Set<SegmentID> = []
            for segmentID in segmentIDs {
                let comments = try await coordinator.getCommentsForSegment(segmentId: segmentID)
                if comments.contains(where: { $0.id == comment.id }) {
                    linkedSegmentIDs.insert(segmentID)
                }
            }

            if linkedSegmentIDs.isEmpty {
                selectedBlockComments.removeAll { $0.id == comment.id }
                selectedBlockCommentPreferredSegmentByID.removeValue(forKey: comment.id.value)
                if commentTimelineCommentsByID.removeValue(forKey: comment.id.value) != nil {
                    commentTimelineContextByCommentID.removeValue(forKey: comment.id.value)
                    rebuildCommentTimelineRows()
                }
                return true
            }

            try await coordinator.removeCommentFromSegments(
                segmentIds: Array(linkedSegmentIDs),
                commentId: comment.id
            )

            selectedBlockComments.removeAll { $0.id == comment.id }
            selectedBlockCommentPreferredSegmentByID.removeValue(forKey: comment.id.value)
            if commentTimelineCommentsByID.removeValue(forKey: comment.id.value) != nil {
                commentTimelineContextByCommentID.removeValue(forKey: comment.id.value)
                rebuildCommentTimelineRows()
            }
            decrementCommentCountsForSegments(linkedSegmentIDs)
            DashboardViewModel.recordCommentDeletedFromBlock(
                coordinator: coordinator,
                source: "timeline_comment_submenu",
                linkedSegmentCount: linkedSegmentIDs.count,
                hadFrameAnchor: comment.frameID != nil
            )
            showToast("Comment deleted", icon: "trash.fill")
            return true
        } catch {
            Log.error("[Comments] Failed to delete comment from block: \(error)", category: .ui)
            showToast("Failed to delete comment", icon: "xmark.circle.fill")
            return false
        }
    }

    public func addCommentToSelectedSegment() {
        let commentBody = newCommentText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !commentBody.isEmpty else {
            showToast("Comment cannot be empty", icon: "exclamationmark.circle.fill")
            return
        }
        guard !isAddingComment else { return }

        guard let index = timelineContextMenuSegmentIndex,
              let block = getBlock(forFrameAt: index) else {
            dismissTimelineContextMenu()
            return
        }

        if isFrameFromRewind(at: index) {
            showToast("Cannot comment on Rewind data")
            dismissTimelineContextMenu()
            return
        }

        let segmentIds = getSegmentIds(inBlock: block)
        guard !segmentIds.isEmpty else {
            showToast("No segments selected", icon: "exclamationmark.circle.fill")
            return
        }
        let selectedFrameID = (index >= 0 && index < frames.count) ? frames[index].frame.id : nil

        isAddingComment = true
        let attachmentDrafts = newCommentAttachmentDrafts

        Task {
            var persistedAttachments: [SegmentCommentAttachment] = []
            do {
                persistedAttachments = try await Task.detached(priority: .userInitiated) {
                    try Self.persistCommentAttachmentDrafts(attachmentDrafts)
                }.value

                let createResult = try await coordinator.createCommentForSegments(
                    body: commentBody,
                    segmentIds: Array(segmentIds),
                    attachments: persistedAttachments,
                    frameID: selectedFrameID,
                    author: nil
                )

                await MainActor.run {
                    newCommentText = ""
                    newCommentAttachmentDrafts = []
                    incrementCommentCountsForSegments(Set(createResult.linkedSegmentIDs))
                    isAddingComment = false
                }
                DashboardViewModel.recordCommentAdded(
                    coordinator: coordinator,
                    source: "timeline_comment_submenu",
                    requestedSegmentCount: segmentIds.count,
                    linkedSegmentCount: createResult.linkedSegmentIDs.count,
                    bodyLength: commentBody.count,
                    attachmentCount: persistedAttachments.count,
                    hasFrameAnchor: selectedFrameID != nil
                )
                await loadCommentsForSelectedTimelineBlock()
            } catch {
                Self.cleanupPersistedCommentAttachments(persistedAttachments)
                Log.error("[Comments] Failed to add comment: \(error)", category: .ui)
                await MainActor.run {
                    isAddingComment = false
                    showToast("Failed to add comment", icon: "xmark.circle.fill")
                }
            }
        }
    }

    /// Navigate to the frame linked on a saved comment card.
    /// Returns true if navigation succeeded.
    @discardableResult
    public func navigateToCommentFrame(frameID: FrameID) async -> Bool {
        setLoadingState(true, reason: "navigateToCommentFrame")
        clearError()

        let didNavigate = await searchForFrameID(frameID.value, includeHiddenSegments: true)
        if didNavigate {
            showToast("Opened linked frame", icon: "checkmark.circle.fill")
            return true
        }

        setLoadingState(false, reason: "navigateToCommentFrame.notFound")
        showToast("Linked frame could not be found", icon: "exclamationmark.triangle.fill")
        return false
    }

    /// Navigate to a comment's anchor frame, falling back to the first frame in a linked segment.
    /// Returns true if navigation succeeded.
    @discardableResult
    public func navigateToComment(
        comment: SegmentComment,
        preferredSegmentID: SegmentID? = nil
    ) async -> Bool {
        if let frameID = comment.frameID {
            let didNavigate = await navigateToCommentFrame(frameID: frameID)
            if didNavigate {
                return true
            }
        }

        do {
            let fallbackSegmentID: SegmentID?
            if let preferredSegmentID {
                fallbackSegmentID = preferredSegmentID
            } else {
                fallbackSegmentID = try await coordinator.getFirstLinkedSegmentForComment(commentId: comment.id)
            }
            guard let fallbackSegmentID,
                  let fallbackFrameID = try await coordinator.getFirstFrameForSegment(segmentId: fallbackSegmentID) else {
                showToast("Linked frame could not be found", icon: "exclamationmark.triangle.fill")
                return false
            }

            let didNavigate = await navigateToCommentFrame(frameID: fallbackFrameID)
            if !didNavigate {
                showToast("Linked frame could not be found", icon: "exclamationmark.triangle.fill")
            }
            return didNavigate
        } catch {
            Log.error("[Comments] Failed to resolve fallback frame for comment \(comment.id.value): \(error)", category: .ui)
            showToast("Linked frame could not be found", icon: "exclamationmark.triangle.fill")
            return false
        }
    }

    /// Update the all-comments search query and trigger a debounced server-side search.
    public func updateCommentSearchQuery(_ rawQuery: String) {
        commentSearchText = rawQuery
        scheduleCommentSearch()
    }

    /// Retry comment search immediately using the current query.
    public func retryCommentSearch() {
        scheduleCommentSearch(immediate: true)
    }

    /// Request the next search page when the user scrolls to the current tail item.
    public func loadMoreCommentSearchResultsIfNeeded(currentCommentID: SegmentCommentID?) {
        guard let currentCommentID,
              currentCommentID == commentSearchResults.last?.id,
              !activeCommentSearchQuery.isEmpty,
              commentSearchHasMoreResults,
              !isSearchingComments else {
            return
        }

        runCommentSearchPage(
            query: activeCommentSearchQuery,
            offset: commentSearchNextOffset,
            append: true,
            immediate: true
        )
    }

    /// Clear all in-memory comment search state and cancel in-flight requests.
    public func resetCommentSearchState() {
        commentSearchTask?.cancel()
        commentSearchTask = nil
        activeCommentSearchQuery = ""
        commentSearchNextOffset = 0
        commentSearchText = ""
        commentSearchResults = []
        commentSearchHasMoreResults = false
        commentSearchError = nil
        isSearchingComments = false
    }

    private func scheduleCommentSearch(immediate: Bool = false) {
        commentSearchTask?.cancel()
        commentSearchTask = nil

        let trimmed = commentSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            activeCommentSearchQuery = ""
            commentSearchNextOffset = 0
            commentSearchResults = []
            commentSearchHasMoreResults = false
            commentSearchError = nil
            isSearchingComments = false
            return
        }

        activeCommentSearchQuery = trimmed
        commentSearchNextOffset = 0
        commentSearchResults = []
        commentSearchHasMoreResults = false
        runCommentSearchPage(
            query: trimmed,
            offset: 0,
            append: false,
            immediate: immediate
        )
    }

    private func runCommentSearchPage(
        query: String,
        offset: Int,
        append: Bool,
        immediate: Bool
    ) {
        commentSearchTask?.cancel()
        commentSearchTask = nil
        isSearchingComments = true
        commentSearchError = nil

        commentSearchTask = Task { [weak self] in
            guard let self else { return }

            if !immediate {
                try? await Task.sleep(for: .nanoseconds(Int64(Self.commentSearchDebounceNanoseconds)), clock: .continuous)
            }

            guard !Task.isCancelled else { return }

            do {
                let entries = try await coordinator.searchCommentTimelineEntries(
                    query: query,
                    limit: Self.commentSearchPageSize,
                    offset: offset
                )
                let results = entries.map { entry in
                    commentTimelineRow(
                        comment: entry.comment,
                        context: CommentTimelineSegmentContext(
                            segmentID: entry.segmentID,
                            appBundleID: normalizedMetadataString(entry.appBundleID),
                            appName: normalizedMetadataString(entry.appName),
                            browserURL: normalizedMetadataString(entry.browserURL),
                            referenceTimestamp: entry.referenceTimestamp
                        )
                    )
                }

                guard !Task.isCancelled else { return }
                guard query == activeCommentSearchQuery else { return }
                if append {
                    commentSearchResults.append(contentsOf: results)
                } else {
                    commentSearchResults = results
                }
                commentSearchNextOffset = offset + results.count
                commentSearchHasMoreResults = results.count == Self.commentSearchPageSize
                commentSearchError = nil
                isSearchingComments = false
            } catch {
                guard !Task.isCancelled else { return }
                if !append {
                    commentSearchResults = []
                    commentSearchHasMoreResults = false
                }
                commentSearchError = append ? "Could not load more comments." : "Could not search comments."
                isSearchingComments = false
                Log.error("[Comments] Failed to search comments: \(error)", category: .ui)
            }
        }
    }

    // MARK: - All Comments Timeline

    private enum CommentTimelineDirection {
        case older
        case newer
    }

    /// Build the "All Comments" timeline, optionally anchored on a specific comment.
    public func loadCommentTimeline(anchoredAt anchorComment: SegmentComment?) async {
        guard !isLoadingCommentTimeline else { return }

        DashboardViewModel.recordAllCommentsOpened(
            coordinator: coordinator,
            source: "timeline_comment_submenu",
            anchorCommentID: anchorComment?.id.value
        )

        resetCommentTimelineState()
        isLoadingCommentTimeline = true
        commentTimelineAnchorCommentID = anchorComment?.id
        commentTimelineHasOlder = false
        commentTimelineHasNewer = false

        do {
            async let metadataLoad: Void = ensureCommentTimelineMetadataLoaded()
            async let entriesTask = coordinator.getAllCommentTimelineEntries()

            let entries = try await entriesTask
            await metadataLoad

            for entry in entries {
                let commentIDValue = entry.comment.id.value
                commentTimelineCommentsByID[commentIDValue] = entry.comment
                commentTimelineContextByCommentID[commentIDValue] = CommentTimelineSegmentContext(
                    segmentID: entry.segmentID,
                    appBundleID: normalizedMetadataString(entry.appBundleID),
                    appName: normalizedMetadataString(entry.appName),
                    browserURL: normalizedMetadataString(entry.browserURL),
                    referenceTimestamp: entry.referenceTimestamp
                )
            }

            if let anchorComment,
               commentTimelineCommentsByID[anchorComment.id.value] == nil {
                commentTimelineCommentsByID[anchorComment.id.value] = anchorComment
            }

            rebuildCommentTimelineRows()
        } catch {
            commentTimelineLoadError = "Could not load all comments."
            Log.error("[Comments] Failed to load all-comments timeline: \(error)", category: .ui)
        }

        isLoadingCommentTimeline = false
    }

    /// Load additional older comments for the all-comments timeline.
    public func loadOlderCommentTimelinePage() async {
        guard !isLoadingCommentTimeline,
              !isLoadingOlderCommentTimeline,
              commentTimelineHasOlder else {
            return
        }

        isLoadingOlderCommentTimeline = true
        defer { isLoadingOlderCommentTimeline = false }

        do {
            _ = try await fetchAndIngestCommentTimeline(direction: .older, maxBatches: 4)
        } catch {
            commentTimelineLoadError = "Could not load older comments."
            Log.error("[Comments] Failed loading older all-comments page: \(error)", category: .ui)
        }
    }

    /// Load additional newer comments for the all-comments timeline.
    public func loadNewerCommentTimelinePage() async {
        guard !isLoadingCommentTimeline,
              !isLoadingNewerCommentTimeline,
              commentTimelineHasNewer else {
            return
        }

        isLoadingNewerCommentTimeline = true
        defer { isLoadingNewerCommentTimeline = false }

        do {
            _ = try await fetchAndIngestCommentTimeline(direction: .newer, maxBatches: 4)
        } catch {
            commentTimelineLoadError = "Could not load newer comments."
            Log.error("[Comments] Failed loading newer all-comments page: \(error)", category: .ui)
        }
    }

    /// Reset all in-memory state for all-comments timeline browsing.
    public func resetCommentTimelineState() {
        commentSearchTask?.cancel()
        commentSearchTask = nil
        commentTimelineRows = []
        commentTimelineAnchorCommentID = nil
        isLoadingCommentTimeline = false
        isLoadingOlderCommentTimeline = false
        isLoadingNewerCommentTimeline = false
        commentTimelineLoadError = nil
        commentTimelineHasOlder = false
        commentTimelineHasNewer = false
        activeCommentSearchQuery = ""
        commentSearchNextOffset = 0
        commentSearchText = ""
        commentSearchResults = []
        commentSearchHasMoreResults = false
        commentSearchError = nil
        isSearchingComments = false

        commentTimelineCommentsByID.removeAll()
        commentTimelineContextByCommentID.removeAll()
        commentTimelineLoadedSegmentIDs.removeAll()
        commentTimelineOldestFrameTimestamp = nil
        commentTimelineNewestFrameTimestamp = nil
    }

    private func ensureCommentTimelineMetadataLoaded() async {
        if availableTags.isEmpty {
            do {
                availableTags = try await coordinator.getAllTags()
            } catch {
                Log.error("[Comments] Failed to load tags for all-comments timeline: \(error)", category: .ui)
            }
        }

        if segmentTagsMap.isEmpty {
            do {
                segmentTagsMap = try await coordinator.getSegmentTagsMap()
            } catch {
                Log.error("[Comments] Failed to load segment-tag map for all-comments timeline: \(error)", category: .ui)
            }
        }
    }

    private func fetchAndIngestCommentTimeline(
        direction: CommentTimelineDirection,
        maxBatches: Int
    ) async throws -> Int {
        var totalAdded = 0
        var completedBatches = 0
        var filters = filterCriteria
        filters.commentFilter = .commentsOnly

        while completedBatches < maxBatches {
            completedBatches += 1

            let batch: [FrameReference]
            switch direction {
            case .older:
                guard let oldest = commentTimelineOldestFrameTimestamp else {
                    commentTimelineHasOlder = false
                    return totalAdded
                }
                batch = try await coordinator.getFramesBefore(
                    timestamp: oldest,
                    limit: 240,
                    filters: filters
                )
            case .newer:
                guard let newest = commentTimelineNewestFrameTimestamp else {
                    commentTimelineHasNewer = false
                    return totalAdded
                }
                batch = try await coordinator.getFramesAfter(
                    timestamp: oneMillisecondAfter(newest),
                    limit: 240,
                    filters: filters
                )
            }

            if batch.isEmpty {
                switch direction {
                case .older:
                    commentTimelineHasOlder = false
                case .newer:
                    commentTimelineHasNewer = false
                }
                return totalAdded
            }

            let addedInBatch = try await ingestCommentTimelineFrames(batch)
            totalAdded += addedInBatch

            if addedInBatch > 0 {
                return totalAdded
            }
        }

        return totalAdded
    }

    private func ingestCommentTimelineFrames(_ frameRefs: [FrameReference]) async throws -> Int {
        guard !frameRefs.isEmpty else { return 0 }

        if let oldest = frameRefs.map(\.timestamp).min() {
            if let existing = commentTimelineOldestFrameTimestamp {
                commentTimelineOldestFrameTimestamp = min(existing, oldest)
            } else {
                commentTimelineOldestFrameTimestamp = oldest
            }
        }

        if let newest = frameRefs.map(\.timestamp).max() {
            if let existing = commentTimelineNewestFrameTimestamp {
                commentTimelineNewestFrameTimestamp = max(existing, newest)
            } else {
                commentTimelineNewestFrameTimestamp = newest
            }
        }

        var contextBySegmentID: [Int64: CommentTimelineSegmentContext] = [:]
        for frame in frameRefs {
            let segmentIDValue = frame.segmentID.value
            let candidate = CommentTimelineSegmentContext(
                segmentID: SegmentID(value: segmentIDValue),
                appBundleID: normalizedMetadataString(frame.metadata.appBundleID),
                appName: normalizedMetadataString(frame.metadata.appName),
                browserURL: normalizedMetadataString(frame.metadata.browserURL),
                referenceTimestamp: frame.timestamp
            )

            if let existing = contextBySegmentID[segmentIDValue] {
                contextBySegmentID[segmentIDValue] = preferredSegmentContext(existing, candidate)
            } else {
                contextBySegmentID[segmentIDValue] = candidate
            }
        }

        var newlyAddedComments = 0

        for (segmentIDValue, context) in contextBySegmentID.sorted(by: { $0.key < $1.key }) {
            guard !commentTimelineLoadedSegmentIDs.contains(segmentIDValue) else { continue }
            commentTimelineLoadedSegmentIDs.insert(segmentIDValue)

            let segmentComments = try await coordinator.getCommentsForSegment(
                segmentId: SegmentID(value: segmentIDValue)
            )

            guard !segmentComments.isEmpty else { continue }

            for comment in segmentComments {
                if commentTimelineCommentsByID[comment.id.value] == nil {
                    newlyAddedComments += 1
                }
                commentTimelineCommentsByID[comment.id.value] = comment

                let existingContext = commentTimelineContextByCommentID[comment.id.value]
                if shouldUseCommentTimelineContext(candidate: context, existing: existingContext, for: comment) {
                    commentTimelineContextByCommentID[comment.id.value] = context
                }
            }
        }

        if newlyAddedComments > 0 {
            rebuildCommentTimelineRows()
        }

        return newlyAddedComments
    }

    private func rebuildCommentTimelineRows() {
        let hiddenTagID = hiddenTagIDValue
        let tagsByID = availableTagsByID

        commentTimelineRows = commentTimelineCommentsByID.values
            .sorted {
                if $0.createdAt == $1.createdAt {
                    return $0.id.value < $1.id.value
                }
                return $0.createdAt < $1.createdAt
            }
            .map { comment in
                let context = commentTimelineContextByCommentID[comment.id.value]
                return commentTimelineRow(comment: comment, context: context, hiddenTagID: hiddenTagID, tagsByID: tagsByID)
            }
    }

    private func commentTimelineRow(
        comment: SegmentComment,
        context: CommentTimelineSegmentContext?,
        hiddenTagID: Int64? = nil,
        tagsByID: [Int64: Tag]? = nil
    ) -> CommentTimelineRow {
        let effectiveHiddenTagID = hiddenTagID ?? hiddenTagIDValue
        let effectiveTagsByID = tagsByID ?? availableTagsByID
        let primaryTagName: String? = context.flatMap { context in
            let segmentTagIDs = segmentTagsMap[context.segmentID.value] ?? []
            let visibleTagNames = segmentTagIDs
                .filter { tagID in
                    guard let effectiveHiddenTagID else { return true }
                    return tagID != effectiveHiddenTagID
                }
                .compactMap { effectiveTagsByID[$0]?.name }
                .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            return visibleTagNames.first
        }

        return CommentTimelineRow(
            comment: comment,
            context: context,
            primaryTagName: primaryTagName
        )
    }

    private func preferredSegmentContext(
        _ lhs: CommentTimelineSegmentContext,
        _ rhs: CommentTimelineSegmentContext
    ) -> CommentTimelineSegmentContext {
        let lhsHasBrowserURL = lhs.browserURL?.isEmpty == false
        let rhsHasBrowserURL = rhs.browserURL?.isEmpty == false
        if lhsHasBrowserURL != rhsHasBrowserURL {
            return lhsHasBrowserURL ? lhs : rhs
        }
        return lhs.referenceTimestamp <= rhs.referenceTimestamp ? lhs : rhs
    }

    private func shouldUseCommentTimelineContext(
        candidate: CommentTimelineSegmentContext,
        existing: CommentTimelineSegmentContext?,
        for comment: SegmentComment
    ) -> Bool {
        guard let existing else { return true }

        let candidateDistance = abs(candidate.referenceTimestamp.timeIntervalSince(comment.createdAt))
        let existingDistance = abs(existing.referenceTimestamp.timeIntervalSince(comment.createdAt))

        if candidateDistance == existingDistance {
            let candidateHasBundle = candidate.appBundleID?.isEmpty == false
            let existingHasBundle = existing.appBundleID?.isEmpty == false
            if candidateHasBundle != existingHasBundle {
                return candidateHasBundle
            }
            return candidate.segmentID.value < existing.segmentID.value
        }

        return candidateDistance < existingDistance
    }

    private func normalizedMetadataString(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func appendCommentSnippet(_ snippet: String) {
        let trimmedSnippet = snippet.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSnippet.isEmpty else { return }

        let current = newCommentText.trimmingCharacters(in: .whitespacesAndNewlines)
        if current.isEmpty {
            newCommentText = trimmedSnippet
            return
        }

        if newCommentText.hasSuffix("\n\n") || newCommentText.hasSuffix(" ") {
            newCommentText += trimmedSnippet
        } else if newCommentText.hasSuffix("\n") {
            newCommentText += "\(trimmedSnippet)"
        } else {
            newCommentText += "\n\(trimmedSnippet)"
        }
    }

    private func addCommentAttachmentDrafts(from urls: [URL]) {
        guard !urls.isEmpty else { return }

        var existingPaths = Set(
            newCommentAttachmentDrafts.map { $0.sourceURL.resolvingSymlinksInPath().path }
        )
        var appended = 0
        let fileManager = FileManager.default

        for rawURL in urls {
            let resolvedURL = rawURL.resolvingSymlinksInPath()
            guard !existingPaths.contains(resolvedURL.path) else { continue }

            let fileName = resolvedURL.lastPathComponent
            guard !fileName.isEmpty else { continue }

            let mimeType = UTType(filenameExtension: resolvedURL.pathExtension)?.preferredMIMEType
            let sizeBytes = (try? fileManager.attributesOfItem(atPath: resolvedURL.path)[.size] as? NSNumber)?.int64Value

            newCommentAttachmentDrafts.append(
                CommentAttachmentDraft(
                    sourceURL: resolvedURL,
                    fileName: fileName,
                    mimeType: mimeType,
                    sizeBytes: sizeBytes
                )
            )
            existingPaths.insert(resolvedURL.path)
            appended += 1
        }

        if appended > 0 {
            showToast("Attached \(appended) file\(appended == 1 ? "" : "s")", icon: "paperclip")
        }
    }

    private nonisolated static func persistCommentAttachmentDrafts(_ drafts: [CommentAttachmentDraft]) throws -> [SegmentCommentAttachment] {
        guard !drafts.isEmpty else { return [] }

        let fileManager = FileManager.default
        let baseDirectoryURL = URL(fileURLWithPath: AppPaths.expandedStorageRoot, isDirectory: true)
        let attachmentsDirectoryName = "comment_attachments"
        let attachmentsDirectoryURL = baseDirectoryURL.appendingPathComponent(attachmentsDirectoryName, isDirectory: true)
        try fileManager.createDirectory(at: attachmentsDirectoryURL, withIntermediateDirectories: true)

        var persisted: [SegmentCommentAttachment] = []

        do {
            for draft in drafts {
                let safeName = sanitizedAttachmentFileName(draft.fileName)
                let persistedName = "\(UUID().uuidString)_\(safeName)"
                let destinationURL = attachmentsDirectoryURL.appendingPathComponent(persistedName, isDirectory: false)

                try fileManager.copyItem(at: draft.sourceURL, to: destinationURL)

                let sizeBytes = (try? fileManager.attributesOfItem(atPath: destinationURL.path)[.size] as? NSNumber)?.int64Value ?? draft.sizeBytes
                let relativePath = "\(attachmentsDirectoryName)/\(persistedName)"

                persisted.append(
                    SegmentCommentAttachment(
                        filePath: relativePath,
                        fileName: draft.fileName,
                        mimeType: draft.mimeType,
                        sizeBytes: sizeBytes
                    )
                )
            }
        } catch {
            for attachment in persisted {
                let removeURL = baseDirectoryURL.appendingPathComponent(attachment.filePath, isDirectory: false)
                try? fileManager.removeItem(at: removeURL)
            }
            throw error
        }

        return persisted
    }

    private nonisolated static func cleanupPersistedCommentAttachments(_ attachments: [SegmentCommentAttachment]) {
        guard !attachments.isEmpty else { return }

        let fileManager = FileManager.default
        let baseDirectoryURL = URL(fileURLWithPath: AppPaths.expandedStorageRoot, isDirectory: true)

        for attachment in attachments {
            let path: String
            if attachment.filePath.hasPrefix("/") || attachment.filePath.hasPrefix("~") {
                path = NSString(string: attachment.filePath).expandingTildeInPath
            } else {
                path = baseDirectoryURL.appendingPathComponent(attachment.filePath, isDirectory: false).path
            }

            if fileManager.fileExists(atPath: path) {
                try? fileManager.removeItem(atPath: path)
            }
        }
    }

    private nonisolated static func sanitizedAttachmentFileName(_ fileName: String) -> String {
        let disallowed = CharacterSet(charactersIn: "/:\\")
        let sanitizedScalars = fileName.unicodeScalars.map { scalar in
            disallowed.contains(scalar) ? "_" : Character(scalar)
        }
        let sanitized = String(sanitizedScalars).trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized.isEmpty ? "attachment" : sanitized
    }

    /// Request deletion from timeline context menu (shows confirmation dialog)
    public func requestDeleteFromTimelineMenu() {
        guard let index = timelineContextMenuSegmentIndex else {
            dismissTimelineContextMenu()
            return
        }

        // Set the selected frame to the clicked one and show delete confirmation
        selectedFrameIndex = index
        dismissTimelineContextMenu()
        showDeleteConfirmation = true
    }

    // MARK: - Filter Operations

    /// Apply or clear a single-app quick filter for the app in the selected timeline context-menu segment.
    /// Mirrors app quick-filter behavior: first press applies app-only filter, second clears it.
    public func toggleQuickAppFilterForSelectedTimelineSegment() {
        guard let index = timelineContextMenuSegmentIndex,
              index >= 0,
              index < frames.count else {
            dismissTimelineContextMenu()
            return
        }

        dismissTimelineContextMenu()

        let bundleID = frames[index].frame.metadata.appBundleID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !bundleID.isEmpty else {
            return
        }

        if isSingleAppOnlyIncludeFilter(filterCriteria, matching: bundleID) {
            clearAllFilters()
            return
        }

        var criteria = FilterCriteria()
        criteria.selectedApps = Set([bundleID])
        criteria.appFilterMode = .include
        pendingFilterCriteria = criteria
        applyFilters()
    }

    private func isSingleAppOnlyIncludeFilter(_ criteria: FilterCriteria, matching bundleID: String) -> Bool {
        guard criteria.appFilterMode == .include,
              let selectedApps = criteria.selectedApps,
              selectedApps.count == 1,
              selectedApps.contains(bundleID) else {
            return false
        }

        let hasNoSources = criteria.selectedSources == nil || criteria.selectedSources?.isEmpty == true
        let hasNoTags = criteria.selectedTags == nil || criteria.selectedTags?.isEmpty == true
        let hasNoWindowFilter = criteria.windowNameFilter?.isEmpty ?? true
        let hasNoBrowserFilter = criteria.browserUrlFilter?.isEmpty ?? true

        return hasNoSources &&
            criteria.hiddenFilter == .hide &&
            criteria.commentFilter == .allFrames &&
            hasNoTags &&
            criteria.tagFilterMode == .include &&
            hasNoWindowFilter &&
            hasNoBrowserFilter &&
            criteria.effectiveDateRanges.isEmpty
    }

    /// Check if a frame at a given index is in a hidden segment
    public func isFrameHidden(at index: Int) -> Bool {
        guard index >= 0 && index < frames.count else { return false }
        let segmentId = SegmentID(value: frames[index].frame.segmentID.value)
        return hiddenSegmentIds.contains(segmentId)
    }

    /// Group frames into app blocks (parameterized version for filtered frames)
    /// Splits on app change OR time gaps ≥2 min
    private func groupFramesIntoBlocks(from frameList: [TimelineFrame]) -> [AppBlock] {
        Self.buildAppBlockSnapshot(
            from: makeSnapshotFrameInputs(from: frameList),
            segmentTagsMap: segmentTagsMap,
            segmentCommentCountsMap: segmentCommentCountsMap,
            hiddenTagID: cachedHiddenTagIDValue
        ).blocks
    }

    /// Build app blocks, frame->block index mapping, and boundary markers in one pass.
    private nonisolated static func buildAppBlockSnapshot(
        from frameList: [SnapshotFrameInput],
        segmentTagsMap: [Int64: Set<Int64>],
        segmentCommentCountsMap: [Int64: Int],
        hiddenTagID: Int64?
    ) -> AppBlockSnapshot {
        if Task.isCancelled {
            return AppBlockSnapshot.empty
        }

        guard !frameList.isEmpty else {
            return AppBlockSnapshot.empty
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
                return AppBlockSnapshot.empty
            }

            let timelineFrame = frameList[index]
            let frameBundleID = timelineFrame.bundleID

            // Track boundary when video path changes from previous frame.
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

            let hasSignificantGap = gapDuration >= Self.minimumGapThreshold
            let appChanged = frameBundleID != currentBundleID

            if (appChanged || hasSignificantGap) && index > 0 {
                let filteredTagIDs = currentBlockTagIDs
                    .filter { tagID in
                        guard let hiddenTagID else { return true }
                        return tagID != hiddenTagID
                    }
                    .sorted()

                blocks.append(AppBlock(
                    bundleID: currentBundleID,
                    appName: frameList[blockStartIndex].appName,
                    startIndex: blockStartIndex,
                    endIndex: index - 1,
                    frameCount: index - blockStartIndex,
                    tagIDs: filteredTagIDs,
                    hasComments: currentBlockHasComments,
                    gapBeforeSeconds: gapBeforeCurrentBlock
                ))

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

        let finalFilteredTagIDs = currentBlockTagIDs
            .filter { tagID in
                guard let hiddenTagID else { return true }
                return tagID != hiddenTagID
            }
            .sorted()

        blocks.append(AppBlock(
            bundleID: currentBundleID,
            appName: frameList[blockStartIndex].appName,
            startIndex: blockStartIndex,
            endIndex: frameList.count - 1,
            frameCount: frameList.count - blockStartIndex,
            tagIDs: finalFilteredTagIDs,
            hasComments: currentBlockHasComments,
            gapBeforeSeconds: gapBeforeCurrentBlock
        ))

        return AppBlockSnapshot(
            blocks: blocks,
            frameToBlockIndex: frameToBlockIndex,
            videoBoundaryIndices: videoBoundaries,
            segmentBoundaryIndices: segmentBoundaries
        )
    }

    /// Load apps available for filtering
    /// Phase 1: Instantly load installed apps from /Applications (synchronous)
    /// Phase 2: Merge with apps from DB history (async)
    public func loadAvailableAppsForFilter() async {
        guard !isLoadingAppsForFilter else {
            Log.debug("[Filter] loadAvailableAppsForFilter skipped - already loading", category: .ui)
            return
        }

        // Skip if already loaded
        guard availableAppsForFilter.isEmpty else {
            Log.debug("[Filter] loadAvailableAppsForFilter skipped - already have \(availableAppsForFilter.count) apps", category: .ui)
            return
        }

        isLoadingAppsForFilter = true
        let startTime = CFAbsoluteTimeGetCurrent()

        // Phase 1: Instant - get installed apps from /Applications folder
        let installed = AppNameResolver.shared.getInstalledApps()
        let installedBundleIDs = Set(installed.map { $0.bundleID })
        let allApps = installed.map { (bundleID: $0.bundleID, name: $0.name) }
        Log.info("[Filter] Phase 1: Loaded \(allApps.count) installed apps in \(Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000))ms", category: .ui)

        // Update UI immediately with installed apps
        availableAppsForFilter = allApps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        // Phase 2: Load apps from DB that aren't installed (historical apps)
        do {
            let bundleIDs = try await coordinator.getDistinctAppBundleIDs()
            let dbApps = AppNameResolver.shared.resolveAll(bundleIDs: bundleIDs)
            let historicalApps = dbApps
                .filter { !installedBundleIDs.contains($0.bundleID) }
                .map { (bundleID: $0.bundleID, name: $0.name) }

            if !historicalApps.isEmpty {
                otherAppsForFilter = historicalApps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                Log.info("[Filter] Phase 2: Added \(historicalApps.count) historical apps to otherAppsForFilter", category: .ui)
            }
        } catch {
            Log.error("[Filter] Failed to load apps from DB: \(error)", category: .ui)
        }

        let totalTime = CFAbsoluteTimeGetCurrent() - startTime
        Log.info("[Filter] Total: \(availableAppsForFilter.count) installed + \(otherAppsForFilter.count) other apps loaded in \(Int(totalTime * 1000))ms", category: .ui)
        isLoadingAppsForFilter = false
    }

    /// Load segment-to-tags mapping for efficient tag filtering
    public func loadSegmentTagsMap() async {
        do {
            segmentTagsMap = try await coordinator.getSegmentTagsMap()
            Log.debug("[Filter] Loaded tags for \(segmentTagsMap.count) segments", category: .ui)
        } catch {
            Log.error("[Filter] Failed to load segment tags map: \(error)", category: .ui)
        }
    }

    /// Source selection is no longer user-configurable in timeline filters.
    /// Always normalize to query across all available sources.
    private func normalizedTimelineFilterCriteria(_ criteria: FilterCriteria) -> FilterCriteria {
        var normalized = criteria
        normalized.selectedSources = nil
        return normalized
    }

    /// Toggle app filter selection (updates pending, not applied)
    public func toggleAppFilter(_ bundleID: String) {
        var apps = pendingFilterCriteria.selectedApps ?? []
        if apps.contains(bundleID) {
            apps.remove(bundleID)
        } else {
            apps.insert(bundleID)
        }
        pendingFilterCriteria.selectedApps = apps.isEmpty ? nil : apps
        Log.debug("[Filter] Toggled app filter for \(bundleID), now \(apps.count) apps selected (pending)", category: .ui)
    }

    /// Toggle tag filter selection (updates pending, not applied)
    public func toggleTagFilter(_ tagId: TagID) {
        var tags = pendingFilterCriteria.selectedTags ?? []
        if tags.contains(tagId.value) {
            tags.remove(tagId.value)
        } else {
            tags.insert(tagId.value)
        }
        pendingFilterCriteria.selectedTags = tags.isEmpty ? nil : tags
        Log.debug("[Filter] Toggled tag filter for \(tagId.value), now \(tags.count) tags selected (pending)", category: .ui)
    }

    /// Set hidden filter mode (updates pending, not applied)
    public func setHiddenFilter(_ mode: HiddenFilter) {
        pendingFilterCriteria.hiddenFilter = mode
        Log.debug("[Filter] Set hidden filter to \(mode.rawValue) (pending)", category: .ui)
    }

    /// Set comment presence filter mode (updates pending, not applied)
    public func setCommentFilter(_ mode: CommentFilter) {
        pendingFilterCriteria.commentFilter = mode
        Log.debug("[Filter] Set comment filter to \(mode.rawValue) (pending)", category: .ui)
    }

    /// Set app filter mode (include/exclude) (updates pending, not applied)
    public func setAppFilterMode(_ mode: AppFilterMode) {
        pendingFilterCriteria.appFilterMode = mode
        Log.debug("[Filter] Set app filter mode to \(mode.rawValue) (pending)", category: .ui)
    }

    /// Set tag filter mode (include/exclude) (updates pending, not applied)
    public func setTagFilterMode(_ mode: TagFilterMode) {
        pendingFilterCriteria.tagFilterMode = mode
        Log.debug("[Filter] Set tag filter mode to \(mode.rawValue) (pending)", category: .ui)
    }

    /// Set date range filters (updates pending, not applied)
    public func setDateRanges(_ ranges: [DateRangeCriterion]) {
        let sanitized = ranges.filter(\.hasBounds).prefix(5)
        pendingFilterCriteria.dateRanges = Array(sanitized)
        if let first = sanitized.first {
            pendingFilterCriteria.startDate = first.start
            pendingFilterCriteria.endDate = first.end
        } else {
            pendingFilterCriteria.startDate = nil
            pendingFilterCriteria.endDate = nil
        }
        Log.debug("[Filter] Set date ranges to \(pendingFilterCriteria.effectiveDateRanges) (pending)", category: .ui)
    }

    /// Legacy single-range setter.
    public func setDateRange(start: Date?, end: Date?) {
        if start == nil && end == nil {
            setDateRanges([])
        } else {
            setDateRanges([DateRangeCriterion(start: start, end: end)])
        }
    }

    /// Starts a latency trace for app quick-filter execution.
    /// The trace is consumed by the next filter reload path.
    public func beginCmdFQuickFilterLatencyTrace(
        bundleID: String,
        action: String,
        trigger: String,
        source: FrameSource
    ) {
        _ = bundleID
        _ = action
        _ = trigger
        _ = source
        pendingCmdFQuickFilterLatencyTrace = nil
    }

    /// Apply pending filters.
    /// - Parameter dismissPanel: Whether to close the filter panel after applying.
    public func applyFilters(dismissPanel: Bool = true) {
        Log.debug("[Filter] applyFilters() called - pending.selectedApps=\(String(describing: pendingFilterCriteria.selectedApps)), current.selectedApps=\(String(describing: filterCriteria.selectedApps))", category: .ui)

        let normalizedCurrentCriteria = normalizedTimelineFilterCriteria(filterCriteria)
        let normalizedPendingCriteria = normalizedTimelineFilterCriteria(pendingFilterCriteria)
        if normalizedCurrentCriteria != filterCriteria {
            filterCriteria = normalizedCurrentCriteria
        }
        if normalizedPendingCriteria != pendingFilterCriteria {
            pendingFilterCriteria = normalizedPendingCriteria
        }

        if normalizedPendingCriteria == normalizedCurrentCriteria {
            if dismissPanel {
                dismissFilterPanel()
            }
            return
        }

        // Invalidate peek cache since filters are changing
        invalidatePeekCache()

        // Capture current timestamp before applying filters to preserve position
        let timestampToPreserve = currentTimestamp
        let cmdFTrace = pendingCmdFQuickFilterLatencyTrace
        pendingCmdFQuickFilterLatencyTrace = nil
        logCmdFPlayheadState(
            "applyFilters.capture",
            trace: cmdFTrace,
            targetTimestamp: timestampToPreserve,
            extra: "pending={\(summarizeFiltersForLog(normalizedPendingCriteria))} current={\(summarizeFiltersForLog(normalizedCurrentCriteria))}"
        )

        filterCriteria = normalizedPendingCriteria
        pendingFilterCriteria = normalizedPendingCriteria
        Log.debug("[Filter] Applied filters - filterCriteria.selectedApps=\(String(describing: filterCriteria.selectedApps))", category: .ui)
        logCmdFPlayheadState(
            "applyFilters.applied",
            trace: cmdFTrace,
            targetTimestamp: timestampToPreserve,
            extra: "applied={\(summarizeFiltersForLog(filterCriteria))}"
        )

        // Record timeline filter metric with JSON of applied filters
        let filterJson = buildTimelineFilterJson()
        DashboardViewModel.recordTimelineFilter(coordinator: coordinator, filterJson: filterJson)

        if dismissPanel {
            dismissFilterPanel()
        }

        // Save filter criteria to cache immediately
        saveFilterCriteria()

        // Reload timeline with filters, preserving current position if possible
        Task {
            if let timestamp = timestampToPreserve {
                // Try to reload frames around the same timestamp (with new filters)
                // If no frames match, reloadFramesAroundTimestamp will fall back to loadMostRecentFrame
                logCmdFPlayheadState("applyFilters.reloadDispatch", trace: cmdFTrace, targetTimestamp: timestamp)
                await reloadFramesAroundTimestamp(timestamp, cmdFTrace: cmdFTrace)
            } else {
                // No current position, fall back to most recent
                if let cmdFTrace {
                    Log.warning("[CmdFPerf][\(cmdFTrace.id)] No current timestamp available after action=\(cmdFTrace.action), falling back to loadMostRecentFrame()", category: .ui)
                }
                await loadMostRecentFrame()
                logCmdFPlayheadState("applyFilters.fallbackComplete", trace: cmdFTrace)
                if let cmdFTrace {
                    let totalElapsedMs = (CFAbsoluteTimeGetCurrent() - cmdFTrace.startedAt) * 1000
                    Log.recordLatency(
                        "timeline.cmdf.quick_filter.fallback_total_ms",
                        valueMs: totalElapsedMs,
                        category: .ui,
                        summaryEvery: 5,
                        warningThresholdMs: 300,
                        criticalThresholdMs: 700
                    )
                    Log.info("[CmdFPerf][\(cmdFTrace.id)] Fallback loadMostRecentFrame() complete total=\(String(format: "%.1f", totalElapsedMs))ms", category: .ui)
                }
            }
        }
    }

    /// Clear all pending filters
    public func clearPendingFilters() {
        pendingFilterCriteria = .none
        Log.debug("[Filter] Cleared pending filters", category: .ui)
    }

    /// Clear all applied filters and reset pending
    public func clearAllFilters() {
        // Invalidate peek cache since filters are changing
        invalidatePeekCache()

        // Capture current timestamp before clearing filters to preserve position
        let timestampToPreserve = currentTimestamp
        let cmdFTrace = pendingCmdFQuickFilterLatencyTrace
        pendingCmdFQuickFilterLatencyTrace = nil
        logCmdFPlayheadState(
            "clearFilters.capture",
            trace: cmdFTrace,
            targetTimestamp: timestampToPreserve,
            extra: "current={\(summarizeFiltersForLog(filterCriteria))}"
        )

        clearFilterState()
        logCmdFPlayheadState("clearFilters.cleared", trace: cmdFTrace, targetTimestamp: timestampToPreserve)

        // Reload timeline without filters, preserving current position
        Task {
            if let timestamp = timestampToPreserve {
                // Reload frames around the same timestamp (without filters)
                logCmdFPlayheadState("clearFilters.reloadDispatch", trace: cmdFTrace, targetTimestamp: timestamp)
                await reloadFramesAroundTimestamp(timestamp, cmdFTrace: cmdFTrace)
            } else {
                // No current position, fall back to most recent
                if let cmdFTrace {
                    Log.warning("[CmdFPerf][\(cmdFTrace.id)] No current timestamp available after action=\(cmdFTrace.action), falling back to loadMostRecentFrame()", category: .ui)
                }
                await loadMostRecentFrame()
                logCmdFPlayheadState("clearFilters.fallbackComplete", trace: cmdFTrace)
                if let cmdFTrace {
                    let totalElapsedMs = (CFAbsoluteTimeGetCurrent() - cmdFTrace.startedAt) * 1000
                    Log.recordLatency(
                        "timeline.cmdf.quick_filter.fallback_total_ms",
                        valueMs: totalElapsedMs,
                        category: .ui,
                        summaryEvery: 5,
                        warningThresholdMs: 300,
                        criticalThresholdMs: 700
                    )
                    Log.info("[CmdFPerf][\(cmdFTrace.id)] Fallback loadMostRecentFrame() complete total=\(String(format: "%.1f", totalElapsedMs))ms", category: .ui)
                }
            }
        }
    }

    /// Clear all applied/pending filters without triggering a reload.
    /// Used by hidden-cache expiration so the next refresh runs unfiltered.
    public func clearFiltersWithoutReload() {
        guard filterCriteria.hasActiveFilters || pendingFilterCriteria.hasActiveFilters else { return }

        // Invalidate peek cache since filters are changing.
        invalidatePeekCache()
        requiresFullReloadOnNextRefresh = true
        clearFilterState()

        if isFilterPanelVisible {
            dismissFilterPanel()
        } else {
            dismissFilterDropdown()
        }

        Log.info("[Filter] Cleared filters without immediate reload", category: .ui)
    }

    /// Clear filter state without triggering a reload
    /// Used by goToNow() which handles its own reload
    private func clearFilterState() {
        filterCriteria = .none
        pendingFilterCriteria = .none
        Log.debug("[Filter] Cleared all filters", category: .ui)

        // Save (clear) filter criteria cache immediately
        saveFilterCriteria()
    }

    /// Clear active filters before a date/frame jump so the jump operates on full timeline data.
    private func clearActiveFiltersBeforeJumpIfNeeded(trigger: String) {
        guard activeFilterCount > 0 else { return }
        Log.info("[DateJump] Clearing \(activeFilterCount) active filters before \(trigger)", category: .ui)
        clearFilterState()
    }


    /// Build JSON representation of active timeline filters for metrics
    private func buildTimelineFilterJson() -> String {
        var components: [String] = []

        if let apps = filterCriteria.selectedApps, !apps.isEmpty {
            let appsArray = apps.map { "\"\($0)\"" }.joined(separator: ",")
            components.append("\"bundleIDs\":[\(appsArray)]")
        }

        if let windowName = filterCriteria.windowNameFilter {
            let escaped = windowName.replacingOccurrences(of: "\"", with: "\\\"")
            components.append("\"windowName\":\"\(escaped)\"")
        }

        if let browserUrl = filterCriteria.browserUrlFilter {
            let escaped = browserUrl.replacingOccurrences(of: "\"", with: "\\\"")
            components.append("\"browserUrl\":\"\(escaped)\"")
        }

        let effectiveDateRanges = filterCriteria.effectiveDateRanges
        if effectiveDateRanges.count == 1 {
            if let startDate = effectiveDateRanges[0].start {
                components.append("\"startDate\":\"\(Log.timestamp(from: startDate))\"")
            }
            if let endDate = effectiveDateRanges[0].end {
                components.append("\"endDate\":\"\(Log.timestamp(from: endDate))\"")
            }
        } else if !effectiveDateRanges.isEmpty {
            let encodedRanges = effectiveDateRanges.map { range in
                let start = range.start.map { "\"\(Log.timestamp(from: $0))\"" } ?? "null"
                let end = range.end.map { "\"\(Log.timestamp(from: $0))\"" } ?? "null"
                return "{\"start\":\(start),\"end\":\(end)}"
            }.joined(separator: ",")
            components.append("\"dateRanges\":[\(encodedRanges)]")
        }

        return "{\(components.joined(separator: ","))}"
    }

    // MARK: - Peek Mode (View Full Context)

    /// Enter peek mode - temporarily clear filters to see full timeline context
    /// Caches the current filtered state for instant restoration on exit
    public func peekContext() {
        guard filterCriteria.hasActiveFilters else {
            Log.debug("[Peek] peekContext() called but no active filters - ignoring", category: .ui)
            return
        }

        guard !frames.isEmpty else {
            Log.debug("[Peek] peekContext() called but no frames loaded - ignoring", category: .ui)
            return
        }

        let timestampToPreserve = currentTimestamp

        // Cache current filtered state (so we can return to EXACT position later)
        cachedFilteredState = TimelineStateSnapshot(
            filterCriteria: filterCriteria,
            frames: frames,
            currentIndex: currentIndex,
            hasMoreOlder: hasMoreOlder,
            hasMoreNewer: hasMoreNewer
        )
        Log.info("[Peek] Cached filtered state: \(frames.count) frames, index=\(currentIndex)", category: .ui)

        // Clear filters and load unfiltered timeline centered on current timestamp
        filterCriteria = .none
        pendingFilterCriteria = .none
        isPeeking = true

        Task {
            if let timestamp = timestampToPreserve {
                await reloadFramesAroundTimestamp(timestamp)
            } else {
                await loadMostRecentFrame()
            }
        }
    }

    /// Exit peek mode - restore previous filtered state instantly
    public func exitPeek() {
        guard isPeeking else {
            Log.debug("[Peek] exitPeek() called but not in peek mode - ignoring", category: .ui)
            return
        }

        guard let filteredState = cachedFilteredState else {
            Log.warning("[Peek] exitPeek() called but no cached filtered state - clearing peek mode", category: .ui)
            isPeeking = false
            return
        }

        // Restore filtered state instantly - this restores the EXACT frame position
        Log.info("[Peek] Restoring filtered state: \(filteredState.frames.count) frames, returning to index=\(filteredState.currentIndex)", category: .ui)
        restoreTimelineState(filteredState)
        isPeeking = false

        // Clear cached filtered state since we've restored it
        cachedFilteredState = nil
    }

    /// Toggle peek mode - enter if filtered, exit if peeking
    public func togglePeek() {
        if isPeeking {
            exitPeek()
        } else {
            peekContext()
        }
    }

    /// Restore timeline state from a snapshot
    private func restoreTimelineState(_ snapshot: TimelineStateSnapshot) {
        let normalized = normalizedTimelineFilterCriteria(snapshot.filterCriteria)
        filterCriteria = normalized
        pendingFilterCriteria = normalized
        frames = snapshot.frames
        currentIndex = snapshot.currentIndex
        hasMoreOlder = snapshot.hasMoreOlder
        hasMoreNewer = snapshot.hasMoreNewer
        loadImageIfNeeded()
    }

    /// Invalidate peek cache (call when filters change or timeline reloads significantly)
    public func invalidatePeekCache() {
        cachedFilteredState = nil
        if isPeeking {
            isPeeking = false
            Log.debug("[Peek] Peek cache invalidated, exiting peek mode", category: .ui)
        }
    }

    /// Clear error message and cancel any auto-dismiss task
    private func clearError() {
        errorDismissTask?.cancel()
        error = nil
    }

    private func clearCurrentImagePresentation() {
        currentImage = nil
        currentImageFrameID = nil
    }

    private func clearWaitingFallbackImage() {
        waitingFallbackImage = nil
    }

    private func clearPendingVideoPresentationState() {
        pendingVideoPresentationFrameID = nil
        isPendingVideoPresentationReady = false
    }

    private func preserveWaitingFallbackImage(for timelineFrame: TimelineFrame?) {
        guard let timelineFrame, timelineFrame.videoInfo != nil else {
            clearWaitingFallbackImage()
            return
        }

        waitingFallbackImage = currentImage ?? waitingFallbackImage
    }

    private func configurePendingVideoPresentationState(for timelineFrame: TimelineFrame?) {
        guard let timelineFrame, timelineFrame.videoInfo != nil else {
            clearPendingVideoPresentationState()
            clearWaitingFallbackImage()
            return
        }

        pendingVideoPresentationFrameID = timelineFrame.frame.id
        isPendingVideoPresentationReady = false
    }

    private func prepareCurrentFramePresentationState(for timelineFrame: TimelineFrame?) {
        preserveWaitingFallbackImage(for: timelineFrame)
        clearCurrentImagePresentation()
        configurePendingVideoPresentationState(for: timelineFrame)
    }

    private func setCurrentImagePresentation(
        _ image: NSImage,
        frameID: FrameID
    ) {
        currentImage = image
        currentImageFrameID = frameID
        clearWaitingFallbackImage()
    }

    func markVideoPresentationReady(frameID: FrameID) {
        guard pendingVideoPresentationFrameID == frameID else { return }
        guard currentTimelineFrame?.frame.id == frameID else { return }
        isPendingVideoPresentationReady = true
        clearWaitingFallbackImage()
    }

    /// Clear stale timeline content when active filters yield zero matches.
    private func applyFilteredEmptyTimelineState(context: String) {
        let clearedFrameCount = frames.count
        cancelBoundaryLoadTasks(reason: "filteredEmpty.\(context)")
        pendingCurrentIndexAfterFrameReplacement = nil
        selectedFrameIndex = nil
        frames = []
        clearCurrentImagePresentation()
        clearWaitingFallbackImage()
        clearPendingVideoPresentationState()
        frameNotReady = false
        frameLoadError = false
        hasMoreOlder = false
        hasMoreNewer = false
        hasReachedAbsoluteStart = true
        hasReachedAbsoluteEnd = true
        Log.info(
            "[Filter] Entered filtered empty state context=\(context) clearedFrames=\(clearedFrameCount)",
            category: .ui
        )
    }

    /// Show "no results" message and provide option to clear filters
    private func showNoResultsMessage() {
        showErrorWithAutoDismiss("No frames found matching the current filters. Clear filters to see all frames.")
    }

    private func cancelBoundaryLoadTasks(reason: String) {
        let hadOlder = olderBoundaryLoadTask != nil
        let hadNewer = newerBoundaryLoadTask != nil

        olderBoundaryLoadTask?.cancel()
        newerBoundaryLoadTask?.cancel()
        olderBoundaryLoadTask = nil
        newerBoundaryLoadTask = nil

        isLoadingOlder = false
        isLoadingNewer = false

        if hadOlder || hadNewer {
            Log.debug("[InfiniteScroll] Cancelled boundary tasks (\(reason)) older=\(hadOlder) newer=\(hadNewer)", category: .ui)
        }
    }

    private func resetBoundaryStateForReloadWindow() {
        hasMoreOlder = true
        hasMoreNewer = true
        hasReachedAbsoluteStart = false
        hasReachedAbsoluteEnd = false
    }

    private func logFrameWindowSummary(context: String, traceID: UInt64? = nil) {
        let trace = traceID.map { "[DateJump:\($0)] " } ?? ""

        let firstFrame = frames.first
        let lastFrame = frames.last
        let currentFrame = (currentIndex >= 0 && currentIndex < frames.count) ? frames[currentIndex] : nil
        let prevFrame = (currentIndex > 0 && currentIndex - 1 < frames.count) ? frames[currentIndex - 1] : nil
        let nextFrame = (currentIndex + 1 >= 0 && currentIndex + 1 < frames.count) ? frames[currentIndex + 1] : nil

        let firstTS = firstFrame.map { Log.timestamp(from: $0.frame.timestamp) } ?? "nil"
        let lastTS = lastFrame.map { Log.timestamp(from: $0.frame.timestamp) } ?? "nil"
        let currentTS = currentFrame.map { Log.timestamp(from: $0.frame.timestamp) } ?? "nil"

        let gapToPrev = prevFrame.flatMap { prev in
            currentFrame.map { max(0, $0.frame.timestamp.timeIntervalSince(prev.frame.timestamp)) }
        }
        let gapToNext = nextFrame.flatMap { next in
            currentFrame.map { max(0, next.frame.timestamp.timeIntervalSince($0.frame.timestamp)) }
        }

        let gapPrevText = gapToPrev.map { String(format: "%.1fs", $0) } ?? "nil"
        let gapNextText = gapToNext.map { String(format: "%.1fs", $0) } ?? "nil"

        Log.info(
            "\(trace)\(context) window count=\(frames.count) index=\(currentIndex) first=\(firstTS) last=\(lastTS) current=\(currentTS) gapPrev=\(gapPrevText) gapNext=\(gapNextText)",
            category: .ui
        )
    }

    /// Show an error message that auto-dismisses after a delay
    /// - Parameters:
    ///   - message: The error message to display
    ///   - seconds: Time in seconds before auto-dismissing (default: 5)
    private func showErrorWithAutoDismiss(_ message: String, seconds: UInt64 = 5) {
        error = message

        // Cancel any existing dismiss task
        errorDismissTask?.cancel()

        // Auto-dismiss after specified seconds
        errorDismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(Double(seconds)), clock: .continuous)
            if !Task.isCancelled {
                error = nil
            }
        }
    }

    private func formatLocalDateForError(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "MMM d, yyyy h:mm:ss a z"
        return formatter.string(from: date)
    }

    /// Dismiss all dialogs except the specified one
    /// - Parameter except: The dialog type to keep open (nil to dismiss all)
    public func dismissOtherDialogs(except: DialogType? = nil) {
        // Dismiss filter panel
        if except != .filter && isFilterPanelVisible {
            let normalized = normalizedTimelineFilterCriteria(filterCriteria)
            if normalized != filterCriteria {
                filterCriteria = normalized
            }
            pendingFilterCriteria = normalized
            dismissFilterDropdown()
            isFilterPanelVisible = false
        }

        // Dismiss date search (Cmd+G)
        if except != .dateSearch && isDateSearchActive {
            isDateSearchActive = false
            dateSearchText = ""
        }

        // Dismiss search overlay (Cmd+K)
        if except != .search && isSearchOverlayVisible {
            isSearchOverlayVisible = false
        }

        // Dismiss in-frame search
        if except != .inFrameSearch && isInFrameSearchVisible {
            closeInFrameSearch(clearQuery: true)
        }

        // Always dismiss context menus
        dismissContextMenu()
        dismissTimelineContextMenu()
    }

    /// Dialog types for mutual exclusion
    public enum DialogType {
        case filter      // Cmd+Shift+F - Filter panel
        case dateSearch  // Cmd+G - Date search
        case search      // Cmd+K - Search overlay
        case inFrameSearch // Cmd+F - In-frame OCR search
    }

    /// Dismiss filter panel (resets pending to match applied)
    public func dismissFilterPanel() {
        // Reset pending first - animation is handled by the View
        let normalized = normalizedTimelineFilterCriteria(filterCriteria)
        if normalized != filterCriteria {
            filterCriteria = normalized
        }
        pendingFilterCriteria = normalized
        dismissFilterDropdown()
        isFilterPanelVisible = false
    }

    /// Open filter panel and load necessary data
    public func openFilterPanel() {
        // Dismiss other dialogs first
        dismissOtherDialogs(except: .filter)
        // Always reset dropdown/popover state when opening the panel
        dismissFilterDropdown()
        // Show controls if hidden (user expects to see the filter panel)
        if areControlsHidden {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                areControlsHidden = false
            }
        }
        // Initialize pending with current applied filters
        let normalized = normalizedTimelineFilterCriteria(filterCriteria)
        if normalized != filterCriteria {
            filterCriteria = normalized
        }
        pendingFilterCriteria = normalized
        // Set visible immediately - animation is handled by the View
        isFilterPanelVisible = true
        // Load data asynchronously - delay slightly to let animation complete first
        Task {
            // Small delay to let the panel animation complete before loading data
            try? await Task.sleep(for: .nanoseconds(Int64(200_000_000)), clock: .continuous) // 200ms
            await loadFilterPanelDataBatched()
        }
    }

    /// Load all filter panel data in a single batch to minimize re-renders
    private func loadFilterPanelDataBatched() async {
        // Skip if already loaded
        let needsApps = availableAppsForFilter.isEmpty
        let needsTags = !hasLoadedAvailableTags
        let needsHidden = hiddenSegmentIds.isEmpty
        let needsTagsMap = !hasLoadedSegmentTagsMap

        guard needsApps || needsTags || needsHidden || needsTagsMap else {
            return
        }

        // Collect all data first without updating @Published properties
        var newApps: [(bundleID: String, name: String)] = []
        var newOtherApps: [(bundleID: String, name: String)] = []
        var newTags: [Tag] = []
        var newHiddenSegmentIds: Set<SegmentID> = []
        var newSegmentTagsMap: [Int64: Set<Int64>] = [:]
        var loadedTags = false
        var loadedHiddenSegmentIDs = false
        var loadedSegmentTagsMap = false

        // Load apps
        if needsApps {
            let installed = AppNameResolver.shared.getInstalledApps()
            let installedBundleIDs = Set(installed.map { $0.bundleID })
            newApps = installed.map { (bundleID: $0.bundleID, name: $0.name) }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

            // Load historical apps from DB
            do {
                let bundleIDs = try await coordinator.getDistinctAppBundleIDs()
                let dbApps = AppNameResolver.shared.resolveAll(bundleIDs: bundleIDs)
                newOtherApps = dbApps
                    .filter { !installedBundleIDs.contains($0.bundleID) }
                    .map { (bundleID: $0.bundleID, name: $0.name) }
                    .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            } catch {
                Log.error("[Filter] Failed to load apps from DB: \(error)", category: .ui)
            }
        }

        // Load tags
        if needsTags {
            do {
                newTags = try await coordinator.getAllTags()
                loadedTags = true
            } catch {
                Log.error("[Filter] Failed to load tags: \(error)", category: .ui)
            }
        }

        // Load hidden segments
        if needsHidden {
            do {
                newHiddenSegmentIds = try await coordinator.getHiddenSegmentIds()
                loadedHiddenSegmentIDs = true
            } catch {
                Log.error("[Filter] Failed to load hidden segments: \(error)", category: .ui)
            }
        }

        // Load segment tags map
        if needsTagsMap {
            do {
                newSegmentTagsMap = try await coordinator.getSegmentTagsMap()
                loadedSegmentTagsMap = true
            } catch {
                Log.error("[Filter] Failed to load segment tags map: \(error)", category: .ui)
            }
        }

        // Now update all @Published properties in one batch
        if needsApps {
            availableAppsForFilter = newApps
            otherAppsForFilter = newOtherApps
        }
        if needsTags && loadedTags {
            availableTags = newTags
        }
        if needsHidden && loadedHiddenSegmentIDs {
            hiddenSegmentIds = newHiddenSegmentIds
        }
        if needsTagsMap && loadedSegmentTagsMap {
            segmentTagsMap = newSegmentTagsMap
        }
    }

    // MARK: - Date Search Panel

    /// Open the date search panel with animation
    public func openDateSearch() {
        // Dismiss other dialogs first
        dismissOtherDialogs(except: .dateSearch)
        // Show controls if hidden (user expects to see the date search panel)
        if areControlsHidden {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                areControlsHidden = false
            }
        }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            isDateSearchActive = true
        }
    }

    /// Close the date search panel with animation
    public func closeDateSearch() {
        withAnimation(.easeOut(duration: 0.15)) {
            isDateSearchActive = false
        }
        dateSearchText = ""
        // Clear any date search errors when closing
        error = nil
        errorDismissTask?.cancel()
    }

    /// Toggle the date search panel with animation
    public func toggleDateSearch() {
        if isDateSearchActive {
            closeDateSearch()
        } else {
            openDateSearch()
        }
    }

    // MARK: - In-Frame Search

    /// Toggle in-frame OCR search visibility.
    /// When active, toggling closes and clears the in-frame query.
    public func toggleInFrameSearch(clearQueryOnClose: Bool = true) {
        let hasQuery = !inFrameSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if isInFrameSearchVisible || hasQuery {
            closeInFrameSearch(clearQuery: clearQueryOnClose)
        } else {
            openInFrameSearch()
        }
    }

    /// Open in-frame OCR search and focus the top-right search field.
    public func openInFrameSearch() {
        dismissOtherDialogs(except: .inFrameSearch)
        if areControlsHidden {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                areControlsHidden = false
            }
        }
        inFrameSearchDebounceTask?.cancel()
        inFrameSearchDebounceTask = nil
        isInFrameSearchVisible = true
        focusInFrameSearchFieldSignal &+= 1
        applyInFrameSearchHighlighting()
    }

    /// Close in-frame search. Optionally clears the query and highlight state.
    public func closeInFrameSearch(clearQuery: Bool) {
        isInFrameSearchVisible = false
        inFrameSearchDebounceTask?.cancel()
        inFrameSearchDebounceTask = nil
        if clearQuery {
            inFrameSearchQuery = ""
            clearSearchHighlightImmediately()
        }
    }

    /// Update in-frame query and refresh highlight state with a short debounce.
    public func setInFrameSearchQuery(_ query: String) {
        inFrameSearchQuery = query
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        inFrameSearchDebounceTask?.cancel()

        guard !normalizedQuery.isEmpty else {
            inFrameSearchDebounceTask = nil
            clearSearchHighlightImmediately()
            return
        }

        inFrameSearchDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(
                for: .nanoseconds(Int64(Self.inFrameSearchDebounceNanoseconds)),
                clock: .continuous
            )
            guard !Task.isCancelled, let self else { return }
            guard self.inFrameSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines) == normalizedQuery else {
                return
            }
            self.applyInFrameSearchHighlighting()
        }
    }

    private func applyInFrameSearchHighlighting() {
        let normalizedQuery = inFrameSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else {
            clearSearchHighlightImmediately()
            return
        }

        searchHighlightTimer?.invalidate()
        searchHighlightTimer = nil
        searchHighlightMode = .matchedTextRanges
        searchHighlightQuery = normalizedQuery
        isShowingSearchHighlight = true
    }

    // MARK: - Search Overlay

    /// Open the search overlay and dismiss other dialogs.
    /// - Parameter recentEntriesRevealDelay: One-shot delay before showing recent entries popover.
    public func openSearchOverlay(recentEntriesRevealDelay: TimeInterval = 0) {
        // Dismiss other dialogs first
        dismissOtherDialogs(except: .search)
        // Show controls if hidden (user expects to see the search overlay)
        if areControlsHidden {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                areControlsHidden = false
            }
        }
        searchViewModel.setNextRecentEntriesRevealDelay(recentEntriesRevealDelay)
        isSearchOverlayVisible = true
        // Clear any existing search highlight
        Task { @MainActor in
            clearSearchHighlight()
        }
    }

    /// Close the search overlay
    public func closeSearchOverlay() {
        searchViewModel.setNextRecentEntriesRevealDelay(0)
        isSearchOverlayVisible = false
    }

    /// Toggle the search overlay.
    /// - Parameter recentEntriesRevealDelayOnOpen: One-shot delay applied only when opening.
    public func toggleSearchOverlay(recentEntriesRevealDelayOnOpen: TimeInterval = 0) {
        if isSearchOverlayVisible {
            closeSearchOverlay()
        } else {
            openSearchOverlay(recentEntriesRevealDelay: recentEntriesRevealDelayOnOpen)
        }
    }

    /// Apply deeplink search state from `retrace://search`.
    /// This resets stale query/filter state first, then applies deeplink values.
    public func applySearchDeeplink(query: String?, appBundleID: String?, source: String = "unknown") {
        let deeplinkID = String(UUID().uuidString.prefix(8))
        let normalizedQuery: String? = {
            guard let query else { return nil }
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }()
        let normalizedAppBundleID: String? = {
            guard let appBundleID else { return nil }
            let trimmed = appBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }()

        Log.info(
            "[SearchDeeplink][\(deeplinkID)] begin source=\(source), query=\(normalizedQuery ?? "nil"), app=\(normalizedAppBundleID ?? "nil")",
            category: .ui
        )
        openSearchOverlay()

        // Reset prior transient search state so deeplinks are deterministic.
        searchViewModel.cancelSearch()
        searchViewModel.searchQuery = ""
        searchViewModel.clearAllFilters()

        if let normalizedAppBundleID {
            searchViewModel.setAppFilter(normalizedAppBundleID)
        }

        guard let normalizedQuery else {
            Log.info("[SearchDeeplink][\(deeplinkID)] completed with no query (app=\(normalizedAppBundleID ?? "nil"))", category: .ui)
            return
        }

        searchViewModel.searchQuery = normalizedQuery
        searchViewModel.submitSearch(trigger: "deeplink:\(source)")
        Log.info("[SearchDeeplink][\(deeplinkID)] submitted query='\(normalizedQuery)' app=\(normalizedAppBundleID ?? "nil")", category: .ui)
    }

    // MARK: - State Cache Methods

    /// Save search and filter state for app termination
    public func saveState() {
        Log.debug("[StateCache] saveState() called", category: .ui)

        // Save search results
        searchViewModel.saveSearchResults()

        // Save filter criteria
        saveFilterCriteria()
    }

    /// Save filter criteria to cache
    /// Saves pendingFilterCriteria so that in-progress filter changes are preserved
    private func saveFilterCriteria() {
        let normalizedPendingCriteria = normalizedTimelineFilterCriteria(pendingFilterCriteria)
        if normalizedPendingCriteria != pendingFilterCriteria {
            pendingFilterCriteria = normalizedPendingCriteria
        }

        Log.debug("[FilterCache] saveFilterCriteria() called - pending.selectedApps=\(String(describing: normalizedPendingCriteria.selectedApps)), pending.hasActiveFilters=\(normalizedPendingCriteria.hasActiveFilters)", category: .ui)
        // If no filters are active in pending, clear any cached filters to avoid restoring stale state
        guard normalizedPendingCriteria.hasActiveFilters else {
            Log.debug("[FilterCache] No active pending filters, clearing cache", category: .ui)
            clearCachedFilterCriteria()
            return
        }

        do {
            let data = try JSONEncoder().encode(normalizedPendingCriteria)
            UserDefaults.standard.set(data, forKey: Self.cachedFilterCriteriaKey)
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.cachedFilterSavedAtKey)
            Log.debug("[FilterCache] Saved pending filter criteria with selectedApps=\(String(describing: normalizedPendingCriteria.selectedApps))", category: .ui)
        } catch {
            Log.warning("[FilterCache] Failed to save filter criteria: \(error)", category: .ui)
        }
    }

    /// Restore filter criteria from cache
    /// Restores to both filterCriteria and pendingFilterCriteria so UI and applied state are in sync
    private func restoreCachedFilterCriteria() {
        let savedAt = UserDefaults.standard.double(forKey: Self.cachedFilterSavedAtKey)
        guard savedAt > 0 else {
            Log.debug("[FilterCache] No saved filter cache found", category: .ui)
            return
        }

        let elapsed = Date().timeIntervalSince(Date(timeIntervalSince1970: savedAt))
        guard elapsed < Self.filterCacheExpirationSeconds else {
            Log.info("[FilterCache] Cache expired (elapsed: \(Int(elapsed))s, threshold: \(Int(Self.filterCacheExpirationSeconds))s), clearing", category: .ui)
            clearCachedFilterCriteria()
            return
        }

        guard let data = UserDefaults.standard.data(forKey: Self.cachedFilterCriteriaKey) else {
            Log.debug("[FilterCache] No filter data in cache", category: .ui)
            return
        }

        do {
            let restored = try JSONDecoder().decode(FilterCriteria.self, from: data)
            let normalized = normalizedTimelineFilterCriteria(restored)
            filterCriteria = normalized
            pendingFilterCriteria = normalized
            Log.debug("[FilterCache] Restored filter criteria (saved \(Int(elapsed))s ago) - selectedApps=\(String(describing: filterCriteria.selectedApps))", category: .ui)
        } catch {
            Log.warning("[FilterCache] Failed to restore filter criteria: \(error)", category: .ui)
        }
    }

    /// Clear cached filter criteria
    private func clearCachedFilterCriteria() {
        UserDefaults.standard.removeObject(forKey: Self.cachedFilterCriteriaKey)
        UserDefaults.standard.removeObject(forKey: Self.cachedFilterSavedAtKey)
    }

    // MARK: - Initial Load

    private func waitForInFlightMostRecentLoad() async {
        await withCheckedContinuation { continuation in
            initialMostRecentLoadWaiters.append(continuation)
        }
    }

    private func completeMostRecentLoadWaiters() {
        guard !initialMostRecentLoadWaiters.isEmpty else { return }
        let waiters = initialMostRecentLoadWaiters
        initialMostRecentLoadWaiters.removeAll(keepingCapacity: false)
        waiters.forEach { $0.resume() }
    }

    /// Load the most recent frame on startup
    /// - Parameter clickStartTime: Optional start time from dashboard tab click for end-to-end timing
    public func loadMostRecentFrame(
        clickStartTime: CFAbsoluteTime? = nil,
        refreshPresentation: Bool = true
    ) async {
        // Coalesce concurrent startup loads (e.g., TimelineWindowController.prepareWindow + SimpleTimelineView.onAppear).
        // Joining avoids skipping a caller and makes the load semantics deterministic.
        if isInitialLoadInProgress {
            Log.debug("[SimpleTimelineViewModel] loadMostRecentFrame joining in-flight initial load", category: .ui)
            await waitForInFlightMostRecentLoad()
            return
        }

        // If some other non-initial load is in progress, preserve existing behavior and skip.
        guard !isLoading else {
            let activeElapsedMs = loadingStateStartedAt.map { (CFAbsoluteTimeGetCurrent() - $0) * 1000 } ?? 0
            Log.warning(
                "[SimpleTimelineViewModel] loadMostRecentFrame skipped - already loading reason='\(activeLoadingReason)' elapsed=\(String(format: "%.1f", activeElapsedMs))ms",
                category: .ui
            )
            return
        }

        isInitialLoadInProgress = true
        defer {
            isInitialLoadInProgress = false
            completeMostRecentLoadWaiters()
        }
        _ = clickStartTime

        setLoadingState(true, reason: "loadMostRecentFrame")
        clearError()

        do {
            // Load most recent frames
            // Uses optimized query that JOINs on video table - no N+1 queries!
            // Always pass filterCriteria to ensure hidden filter is applied (default: .hide)
            Log.debug("[SimpleTimelineViewModel] Loading frames with filters - hasActiveFilters: \(filterCriteria.hasActiveFilters), apps: \(String(describing: filterCriteria.selectedApps)), mode: \(filterCriteria.appFilterMode.rawValue)", category: .ui)
            let framesWithVideoInfo = try await fetchMostRecentFramesWithVideoInfoLogged(
                limit: WindowConfig.maxFrames,
                filters: filterCriteria,
                reason: "loadMostRecentFrame"
            )

            guard !framesWithVideoInfo.isEmpty else {
                // No frames found - check if filters are active
                if filterCriteria.hasActiveFilters {
                    applyFilteredEmptyTimelineState(context: "loadMostRecentFrame.noFrames")
                    showNoResultsMessage()
                } else {
                    showErrorWithAutoDismiss("No frames found in any database")
                }
                setLoadingState(false, reason: "loadMostRecentFrame.noFrames")
                return
            }

            // Convert to TimelineFrame - video info is already included from the JOIN
            // Reverse so oldest is first (index 0), newest is last
            // This matches the timeline UI which displays left-to-right as past-to-future
            frames = framesWithVideoInfo.reversed().map { TimelineFrame(frameWithVideoInfo: $0) }

            // Initialize window boundary timestamps for infinite scroll
            updateWindowBoundaries()

            // Log the first and last few frames to verify ordering
            Log.debug("[SimpleTimelineViewModel] Loaded \(frames.count) frames", category: .ui)

            // Log initial memory state
            MemoryTracker.logMemoryState(
                context: "INITIAL LOAD",
                frameCount: frames.count,
                frameBufferCount: diskFrameBufferIndex.count,
                oldestTimestamp: oldestLoadedTimestamp,
                newestTimestamp: newestLoadedTimestamp
            )
            if frames.count > 0 {
                Log.debug("[SimpleTimelineViewModel] First 3 frames (should be oldest):", category: .ui)
                for i in 0..<min(3, frames.count) {
                    let f = frames[i].frame
                    Log.debug("  [\(i)] \(f.timestamp) - \(f.metadata.appBundleID ?? "nil")", category: .ui)
                }
                Log.debug("[SimpleTimelineViewModel] Last 3 frames (should be newest):", category: .ui)
                for i in max(0, frames.count - 3)..<frames.count {
                    let f = frames[i].frame
                    Log.debug("  [\(i)] \(f.timestamp) - \(f.metadata.appBundleID ?? "nil")", category: .ui)
                }
            }

            // Start at the most recent frame (last in array since sorted ascending, oldest first)
            currentIndex = frames.count - 1

            let newestBlock = newestEdgeBlockSummary(in: frames)
            Log.info(
                "[TIMELINE-BLOCK] initial-load reason=loadMostRecentFrame newest={\(summarizeEdgeBlock(newestBlock))}",
                category: .ui
            )

            // Record initial position for undo history
            scheduleStoppedPositionRecording()

            // Check if we need to pre-load more frames (e.g., if loaded window is small)
            checkAndLoadMoreFrames()

            // Restore cached search results if any
            searchViewModel.restoreCachedSearchResults()

            // NOTE: We skip loading hiddenSegmentIds here because:
            // 1. Hidden segments are already EXCLUDED from the query (via NOT EXISTS clause)
            // 2. The hatch marks only matter when viewing hidden segments via filter
            // 3. loadHiddenSegments will be called lazily when filter panel opens

            // Load tag metadata/map lazily so the tape can render subtle tag indicators.
            ensureTapeTagIndicatorDataLoadedIfNeeded()

            if refreshPresentation {
                // Skip presentation refresh for hidden metadata-only updates.
                loadImageIfNeeded()
            }

            setLoadingState(false, reason: "loadMostRecentFrame.success")

        } catch {
            self.error = "Failed to load frames: \(error.localizedDescription)"
            setLoadingState(false, reason: "loadMostRecentFrame.error")
        }
    }

    /// Load pre-fetched frames directly (used when query runs in parallel with show())
    /// - Parameters:
    ///   - framesWithVideoInfo: Pre-fetched frames from parallel query
    ///   - clickStartTime: Start time for end-to-end timing
    public func loadFramesDirectly(_ framesWithVideoInfo: [FrameWithVideoInfo], clickStartTime: CFAbsoluteTime? = nil) async {
        // Guard against concurrent calls - use dedicated flag to avoid race conditions
        guard !isInitialLoadInProgress && !isLoading else {
            Log.debug("[SimpleTimelineViewModel] loadFramesDirectly skipped - already loading", category: .ui)
            return
        }
        isInitialLoadInProgress = true
        defer { isInitialLoadInProgress = false }
        _ = clickStartTime

        setLoadingState(true, reason: "loadFramesDirectly")
        clearError()

        guard !framesWithVideoInfo.isEmpty else {
            if filterCriteria.hasActiveFilters {
                applyFilteredEmptyTimelineState(context: "loadFramesDirectly.noFrames")
                showNoResultsMessage()
            } else {
                showErrorWithAutoDismiss("No frames found in any database")
            }
            setLoadingState(false, reason: "loadFramesDirectly.noFrames")
            return
        }

        // Convert to TimelineFrame - reverse so oldest is first (index 0), newest is last
        frames = framesWithVideoInfo.reversed().map { TimelineFrame(frameWithVideoInfo: $0) }

        // Initialize window boundary timestamps for infinite scroll
        updateWindowBoundaries()

        Log.debug("[SimpleTimelineViewModel] Loaded \(frames.count) frames directly", category: .ui)

        // Start at the most recent frame
        currentIndex = frames.count - 1

        // Record initial position for undo history
        scheduleStoppedPositionRecording()

        // Check if we need to pre-load more frames (e.g., if loaded window is small)
        checkAndLoadMoreFrames()

        // Restore cached search results if any
        searchViewModel.restoreCachedSearchResults()

        // Load tag metadata/map lazily so the tape can render subtle tag indicators.
        ensureTapeTagIndicatorDataLoadedIfNeeded()

        // Load image if needed for current frame
        loadImageIfNeeded()

        setLoadingState(false, reason: "loadFramesDirectly.success")
    }

    /// Refresh frame data when showing the pre-rendered timeline
    /// This is a lightweight refresh that only loads the most recent frame if needed,
    /// rather than doing a full reload. The goal is to show fresh data quickly.
    /// - Parameter navigateToNewest: If true, automatically navigate to the newest frame when new frames are found.
    ///                               If false, preserve the current position (useful for background refresh).
    /// - Parameter allowNearLiveAutoAdvance: When `navigateToNewest` is false, allows near-live (<50 frames away)
    ///                                       positions to auto-advance to newest. Callers can gate this by expiry.
    /// - Parameter refreshPresentation: When false, updates frame/window metadata without decoding the current frame
    ///                                  or touching presentation state. Use this for hidden timeline refreshes.
    public func refreshFrameData(
        navigateToNewest: Bool = true,
        allowNearLiveAutoAdvance: Bool = true,
        refreshPresentation: Bool = true
    ) async {
        // If we have frames and a current position, just refresh the current image
        if !frames.isEmpty {
            // Background refresh rules:
            // - With filters active: always respect 1-minute cache expiry (no 50-frame optimization)
            // - Hidden > 1 minute (navigateToNewest=true): always refresh and navigate to newest
            // - Hidden < 1 minute AND < 50 frames away: only auto-advance when caller allows it
            // - Hidden < 1 minute AND >= 50 frames away: skip refresh entirely
            let framesFromNewest = frames.count - 1 - currentIndex
            let shouldNavigateToNewest: Bool
            let hasActiveFilters = filterCriteria.hasActiveFilters
            let newestLoadedFrameIsRecent = isNewestLoadedFrameRecent(now: refreshFrameDataCurrentDate())

            if !navigateToNewest, currentIndex < frames.count, !hasActiveFilters {
                let isNearLive = newestLoadedFrameIsRecent &&
                    framesFromNewest < Self.nearLiveEdgeFrameThreshold
                if !isNearLive || !allowNearLiveAutoAdvance {
                    if refreshPresentation {
                        loadImageIfNeeded()
                    }
                    return
                }
                // Near-live and caller-authorized: refresh AND navigate to newest.
                shouldNavigateToNewest = true
            } else if hasActiveFilters {
                // With filters active, always use navigateToNewest (respects 1-minute cache expiry)
                shouldNavigateToNewest = navigateToNewest
            } else {
                shouldNavigateToNewest = navigateToNewest
            }

            if requiresFullReloadOnNextRefresh {
                requiresFullReloadOnNextRefresh = false
                Log.info(
                    "[TIMELINE-REOPEN] forcing full reload after filter expiry navigateToNewest=\(shouldNavigateToNewest) frames=\(frames.count) index=\(currentIndex)",
                    category: .ui
                )

                if shouldNavigateToNewest {
                    await loadMostRecentFrame(refreshPresentation: refreshPresentation)
                } else if let timestamp = currentTimestamp {
                    await reloadFramesAroundTimestamp(timestamp, refreshPresentation: refreshPresentation)
                } else {
                    await loadMostRecentFrame(refreshPresentation: refreshPresentation)
                }
                return
            }

            // Check if there are newer frames available
            if let newestCachedTimestamp = frames.last?.frame.timestamp {
                do {
                    // Query for frames newer than our newest cached frame
                    let refreshLimit = 50
                    let newerFrames = try await fetchMostRecentFramesWithVideoInfoLogged(
                        limit: refreshLimit,
                        filters: filterCriteria,
                        reason: "refreshFrameData.navigateToNewest=\(shouldNavigateToNewest)"
                    )

                    // Filter to only truly new frames
                    let newFrames = newerFrames.filter { $0.frame.timestamp > newestCachedTimestamp }

                    if !newFrames.isEmpty {
                        // If ALL fetched frames are new, we likely missed frames in between
                        // (e.g., timeline was hidden for a long time). Do a full reload to avoid
                        // creating a phantom gap in the timeline.
                        if newFrames.count >= refreshLimit {
                            // Preserve historical playhead when caller explicitly opted out of
                            // auto-advancing (timeline hide/reopen while scrubbing older frames).
                            // A full reload here would hard-reset to newest and break continuity.
                            if shouldNavigateToNewest {
                                await loadMostRecentFrame(refreshPresentation: refreshPresentation)
                            }
                            return
                        }

                        // Add new frames to the end (they're newer, so they go at the end)
                        let newTimelineFrames = newFrames.reversed().map { TimelineFrame(frameWithVideoInfo: $0) }

                        frames.append(contentsOf: newTimelineFrames)

                        // Update boundaries
                        updateWindowBoundaries()

                        // Navigate to newest frame
                        if shouldNavigateToNewest {
                            let oldIndex = currentIndex
                            currentIndex = frames.count - 1
                            if oldIndex != currentIndex {
                                Log.info(
                                    "[TIMELINE-REOPEN] refreshSnap source=newFrames oldIndex=\(oldIndex) newIndex=\(currentIndex) appended=\(newTimelineFrames.count) total=\(frames.count)",
                                    category: .ui
                                )
                            }
                        }

                        // Trim if we've exceeded max frames (preserve newer since we just added new frames)
                        trimWindowIfNeeded(preserveDirection: .newer)
                    } else if shouldNavigateToNewest {
                        // Reopen policy requested newest even if no fresh frame was appended.
                        // Without this, users can remain a few frames behind indefinitely on static screens.
                        let newestIndex = max(0, frames.count - 1)
                        if currentIndex != newestIndex {
                            let oldIndex = currentIndex
                            currentIndex = newestIndex
                            Log.info(
                                "[TIMELINE-REOPEN] refreshSnap source=noNewFrames oldIndex=\(oldIndex) newIndex=\(newestIndex) total=\(frames.count)",
                                category: .ui
                            )
                        }
                    }
                } catch {
                    Log.error("[TIMELINE-REFRESH] Failed to check for new frames: \(error)", category: .ui)
                }
            }

            if refreshPresentation {
                loadImageIfNeeded()
            }
            return
        }

        // No cached frames - do a full load
        await loadMostRecentFrame(refreshPresentation: refreshPresentation)
    }

    /// Refresh image-backed presentation state when the timeline becomes visible again.
    /// Video-backed frames still need OCR/URL overlays reloaded even though AVPlayer
    /// owns the visible frame pixels.
    public func refreshStaticPresentationIfNeeded() {
        guard presentationWorkEnabled, !isInLiveMode else { return }

        if currentVideoInfo != nil {
            let generation = currentPresentationWorkGeneration()
            guard canPublishPresentationResult(expectedGeneration: generation) else { return }
            loadURLBoundingBox(expectedGeneration: generation)
            loadOCRNodes(expectedGeneration: generation)
            return
        }

        guard currentImage == nil else { return }
        loadImageIfNeeded()
    }

    /// Release image/video-adjacent state while preserving the warmed metadata window.
    /// Use this when the timeline is hidden but we want fast reopen semantics without
    /// retaining decoded images, live screenshots, or disk-backed frame payloads.
    public func compactPresentationState(
        reason: String,
        purgeDiskFrameBuffer: Bool = true
    ) {
        setPresentationWorkEnabled(false, reason: "compactPresentationState.\(reason)")
        stopPeriodicStatusRefresh()
        stopPlayback()
        cancelDiskFrameBufferInactivityCleanup()
        cancelForegroundFrameLoad(reason: "compactPresentationState.\(reason)")
        cancelCacheExpansion(reason: "compactPresentationState.\(reason)")

        isInLiveMode = false
        liveScreenshot = nil
        currentImage = nil
        shiftDragDisplaySnapshot = nil
        shiftDragDisplaySnapshotFrameID = nil
        shiftDragDisplayRequestID &+= 1
        activeShiftDragSessionID = 0
        shiftDragStartFrameID = nil
        shiftDragStartVideoInfo = nil
        frameNotReady = false
        frameLoadError = false
        forceVideoReload = false
        urlBoundingBox = nil
        isHoveringURL = false
        clearHyperlinkMatches()
        clearTextSelection()
        setOCRNodes([])
        previousOcrNodes = []
        ocrStatus = .unknown
        ocrStatusPollingTask?.cancel()
        ocrStatusPollingTask = nil

        if purgeDiskFrameBuffer {
            clearDiskFrameBuffer(reason: "compactPresentationState.\(reason)")
        }
    }

    /// Refresh processing status for all cached frames that aren't completed (status != 2)
    /// This updates stale processingStatus values (e.g., p=4 frames that are now readable)
    /// and also refreshes videoInfo for frames whose status changed
    public func refreshProcessingStatuses() async {
        // Find all frames that aren't completed (status != 2)
        let framesToRefresh = Array(frames.enumerated()) // .filter { $0.element.processingStatus != 2 }

        guard !framesToRefresh.isEmpty else {
            return
        }

        let frameIDs = framesToRefresh.map { $0.element.frame.id.value }

        do {
            let updatedStatuses = try await fetchFrameProcessingStatusesForRefresh(frameIDs: frameIDs)

            var updatedCount = 0
            var currentFrameUpdated = false

            for (_, snapshotFrame) in framesToRefresh {
                let frameID = snapshotFrame.frame.id
                guard let newStatus = updatedStatuses[frameID.value] else {
                    continue
                }

                // Resolve index by ID against the live array (never trust enumerated snapshot indices).
                guard let liveIndex = frames.firstIndex(where: { $0.frame.id == frameID }) else {
                    continue
                }

                guard frames[liveIndex].processingStatus != newStatus else {
                    continue
                }

                // Re-fetch the full frame with updated videoInfo.
                if let updatedFrame = try await fetchFrameWithVideoInfoByIDForRefresh(id: frameID) {
                    // Array may have changed while awaiting; resolve again before writing.
                    guard let liveIndexAfterAwait = frames.firstIndex(where: { $0.frame.id == frameID }) else {
                        continue
                    }

                    frames[liveIndexAfterAwait] = TimelineFrame(frameWithVideoInfo: updatedFrame)
                } else {
                    // Array may have changed while awaiting; resolve again before writing.
                    guard let liveIndexAfterAwait = frames.firstIndex(where: { $0.frame.id == frameID }) else {
                        continue
                    }

                    // Fallback: update only the status on the latest in-memory frame snapshot.
                    let existingFrame = frames[liveIndexAfterAwait]
                    frames[liveIndexAfterAwait] = TimelineFrame(
                        frame: existingFrame.frame,
                        videoInfo: existingFrame.videoInfo,
                        processingStatus: newStatus,
                        videoCurrentTime: existingFrame.videoCurrentTime,
                        scrollY: existingFrame.scrollY
                    )
                }

                // Check if this is the current frame.
                if let currentFrame = currentTimelineFrame,
                   currentFrame.frame.id.value == frameID.value {
                    currentFrameUpdated = true
                }

                updatedCount += 1
            }

            if updatedCount > 0 {
                // If current frame was updated, reload its image
                if currentFrameUpdated {
                    loadImageIfNeeded()
                }
            }
        } catch {
            Log.error("[TIMELINE-REFRESH] Failed to refresh processing statuses: \(error)", category: .ui)
        }
    }

    private func fetchFrameProcessingStatusesForRefresh(frameIDs: [Int64]) async throws -> [Int64: Int] {
#if DEBUG
        if let override = test_refreshProcessingStatusesHooks.getFrameProcessingStatuses {
            return try await override(frameIDs)
        }
#endif
        return try await coordinator.getFrameProcessingStatuses(frameIDs: frameIDs)
    }

    private func fetchFrameWithVideoInfoByIDForRefresh(id: FrameID) async throws -> FrameWithVideoInfo? {
#if DEBUG
        if let override = test_refreshProcessingStatusesHooks.getFrameWithVideoInfoByID {
            return try await override(id)
        }
#endif
        return try await coordinator.getFrameWithVideoInfoByID(id: id)
    }

    /// Start periodic processing status refresh (every 10 seconds)
    /// Call this when the timeline becomes visible
    public func startPeriodicStatusRefresh() {
        // Cancel any existing timer
        stopPeriodicStatusRefresh()

        // Run on main thread since Timer needs RunLoop
        statusRefreshTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refreshProcessingStatuses()
            }
        }
    }

    /// Stop periodic processing status refresh
    /// Call this when the timeline is closed
    public func stopPeriodicStatusRefresh() {
        statusRefreshTimer?.invalidate()
        statusRefreshTimer = nil
    }

    // MARK: - Frame Navigation

    /// Navigate to a specific index in the frames array
    public func navigateToFrame(_ index: Int, fromScroll: Bool = false) {
        // Exit live mode on explicit navigation
        if isInLiveMode {
            exitLiveMode()
        }

        // Reset sub-frame offset for non-scroll navigation (click, keyboard, etc.)
        if !fromScroll {
            subFrameOffset = 0
        }

        // Clamp to valid range
        let clampedIndex = max(0, min(frames.count - 1, index))
        guard clampedIndex != currentIndex else { return }
        let previousIndex = currentIndex

        if !undonePositionHistory.isEmpty {
            undonePositionHistory.removeAll()
        }

        // Clear transient search-result highlight when manually navigating.
        if isShowingSearchHighlight && !hasActiveInFrameSearchQuery {
            clearSearchHighlight()
        }
        // Only dismiss search overlay if there's no active search query
        if isSearchOverlayVisible && searchViewModel.searchQuery.isEmpty {
            isSearchOverlayVisible = false
        }

        // Track scrub distance for metrics
        let distance = abs(clampedIndex - currentIndex)
        TimelineWindowController.shared.accumulateScrubDistance(Double(distance))

        // Hard seek to a distant window: drop disk buffer so old-region cache doesn't pollute reads.
        if !fromScroll, distance >= Self.hardSeekResetThreshold {
            clearDiskFrameBuffer(reason: "hard seek to distant window")
        }

        currentIndex = clampedIndex

        if Self.isFilteredScrubDiagnosticsEnabled,
           filterCriteria.hasActiveFilters,
           let timelineFrame = currentTimelineFrame {
            let selectedApps = (filterCriteria.selectedApps ?? []).sorted().joined(separator: ",")
            let videoFrameIndex = timelineFrame.videoInfo?.frameIndex ?? -1
            let videoSuffix = timelineFrame.videoInfo.map { String($0.videoPath.suffix(32)) } ?? "nil"
            Log.debug(
                "[FILTER-SCRUB] fromScroll=\(fromScroll) index=\(previousIndex)->\(clampedIndex) frameID=\(timelineFrame.frame.id.value) ts=\(timelineFrame.frame.timestamp) bundle=\(timelineFrame.frame.metadata.appBundleID ?? "nil") selectedApps=[\(selectedApps)] videoFrameIndex=\(videoFrameIndex) videoPathSuffix=\(videoSuffix)",
                category: .ui
            )
        }

        // Clear selection when scrolling - highlight follows the playhead
        selectedFrameIndex = nil

        // Keep zoom level consistent across frames (don't reset on navigation)
        // User can reset with Cmd+0 if needed

        // Load image if this is an image-based frame
        loadImageIfNeeded()

        // Check if we need to load more frames (infinite scroll)
        checkAndLoadMoreFrames()

        // Periodic memory state logging
        navigationCounter += 1
        if navigationCounter % Self.memoryLogInterval == 0 {
            MemoryTracker.logMemoryState(
                context: "PERIODIC (nav #\(navigationCounter))",
                frameCount: frames.count,
                frameBufferCount: diskFrameBufferIndex.count,
                oldestTimestamp: oldestLoadedTimestamp,
                newestTimestamp: newestLoadedTimestamp
            )
        }

        // Track stopped positions for Cmd+Z undo
        scheduleStoppedPositionRecording()
    }

    /// Schedule recording the current position as a "stopped" position after 350 ms of inactivity
    private func scheduleStoppedPositionRecording() {
        // Cancel any previous work item
        cancelPendingStoppedPositionRecording()

        let indexToRecord = currentIndex

        // Create new work item (lighter weight than Task)
        let workItem = DispatchWorkItem { [weak self] in
            self?.recordStoppedPosition(indexToRecord)
        }
        playheadStoppedDetectionWorkItem = workItem

        // Schedule after the threshold duration
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.stoppedThresholdSeconds, execute: workItem)
    }

    private func cancelPendingStoppedPositionRecording() {
        playheadStoppedDetectionWorkItem?.cancel()
        playheadStoppedDetectionWorkItem = nil
    }

    @discardableResult
    private func recordCurrentPositionImmediatelyForUndo(
        reason: String,
        highlightQueryOverride: String? = nil
    ) -> Bool {
        let historyCountBefore = stoppedPositionHistory.count
        recordStoppedPosition(currentIndex, highlightQueryOverride: highlightQueryOverride)
        let didRecord = stoppedPositionHistory.count != historyCountBefore
        if didRecord {
            Log.debug(
                "[PlayheadUndo] Recorded immediate jump snapshot for \(reason) (history size=\(stoppedPositionHistory.count))",
                category: .ui
            )
        }
        return didRecord
    }

    /// Record a position as a "stopped" position for undo history
    private func recordStoppedPosition(_ index: Int, highlightQueryOverride: String? = nil) {
        // Don't record invalid indices
        guard index >= 0 && index < frames.count else { return }

        let frame = frames[index].frame
        let frameID = frame.id
        let timestamp = frame.timestamp
        let preservedHighlightQuery = normalizedRestorableSearchHighlightQuery(
            highlightQueryOverride ?? currentRestorableSearchHighlightQuery()
        )

        // Don't record if it's the same as the last recorded frame
        guard frameID != lastRecordedStoppedFrameID else { return }

        // New user navigation invalidates redo history.
        if !undonePositionHistory.isEmpty {
            undonePositionHistory.removeAll()
        }

        // Add to history
        stoppedPositionHistory.append(
            StoppedPosition(
                frameID: frameID,
                timestamp: timestamp,
                searchHighlightQuery: preservedHighlightQuery
            )
        )
        lastRecordedStoppedFrameID = frameID

        // Trim history if it exceeds max size
        if stoppedPositionHistory.count > Self.maxStoppedPositionHistory {
            stoppedPositionHistory.removeFirst(stoppedPositionHistory.count - Self.maxStoppedPositionHistory)
        }

        Log.debug("[PlayheadUndo] Recorded stopped position: frameID=\(frameID.stringValue), timestamp=\(timestamp), history size=\(stoppedPositionHistory.count)", category: .ui)
    }

    private func normalizedRestorableSearchHighlightQuery(_ query: String?) -> String? {
        guard let normalizedQuery = query?.trimmingCharacters(in: .whitespacesAndNewlines),
              !normalizedQuery.isEmpty else {
            return nil
        }
        return normalizedQuery
    }

    private func currentRestorableSearchHighlightQuery() -> String? {
        guard !hasActiveInFrameSearchQuery, isShowingSearchHighlight else {
            return nil
        }
        return normalizedRestorableSearchHighlightQuery(searchHighlightQuery)
    }

    private func restoreSearchHighlightIfNeeded(from position: StoppedPosition) {
        guard let query = position.searchHighlightQuery else { return }
        showSearchHighlight(query: query)
    }

    /// Undo to the last stopped playhead position (Cmd+Z)
    /// Returns true if there was a position to undo to, false otherwise
    @discardableResult
    public func undoToLastStoppedPosition() -> Bool {
        // Need at least 2 positions: current (most recent) and one to go back to
        guard stoppedPositionHistory.count >= 2 else {
            Log.debug("[PlayheadUndo] No position to undo to (history size: \(stoppedPositionHistory.count))", category: .ui)
            return false
        }

        // Remove the current position (most recent) and move it to redo history.
        let currentPosition = stoppedPositionHistory.removeLast()
        undonePositionHistory.append(currentPosition)
        if undonePositionHistory.count > Self.maxStoppedPositionHistory {
            undonePositionHistory.removeFirst(undonePositionHistory.count - Self.maxStoppedPositionHistory)
        }

        // Get the previous position
        guard let previousPosition = stoppedPositionHistory.last else {
            return false
        }

        // Update lastRecordedStoppedFrameID to prevent re-recording the same position
        lastRecordedStoppedFrameID = previousPosition.frameID

        // Cancel any pending stopped position recording
        cancelPendingStoppedPositionRecording()

        // Undo is an explicit timeline navigation action; clear transient search-result highlight.
        resetSearchHighlightState()

        // Fast path: check if frame exists in current frames array
        if let index = frames.firstIndex(where: { $0.frame.id == previousPosition.frameID }) {
            Log.debug("[PlayheadUndo] Fast path: found frame in current array at index \(index)", category: .ui)
            if index != currentIndex {
                currentIndex = index
                loadImageIfNeeded()
                checkAndLoadMoreFrames()
            }
            restoreSearchHighlightIfNeeded(from: previousPosition)
            return true
        }

        // Slow path: frame not in current array, need to reload frames around the timestamp
        Log.debug("[PlayheadUndo] Slow path: frame not in current array, reloading around timestamp \(previousPosition.timestamp)", category: .ui)

        Task { @MainActor in
            await navigateToUndoPosition(previousPosition)
        }

        return true
    }

    /// Redo to the last undone playhead position (Cmd+Shift+Z).
    /// Returns true if there was a position to redo to, false otherwise.
    @discardableResult
    public func redoLastUndonePosition() -> Bool {
        guard let nextPosition = undonePositionHistory.popLast() else {
            return false
        }

        // Cancel pending stop-detection work to avoid stale position snapshots during redo.
        cancelPendingStoppedPositionRecording()

        // Redo is explicit timeline navigation; clear transient search-result highlight.
        resetSearchHighlightState()

        // Keep undo history in sync with the redone position.
        if stoppedPositionHistory.last?.frameID != nextPosition.frameID {
            stoppedPositionHistory.append(nextPosition)
            if stoppedPositionHistory.count > Self.maxStoppedPositionHistory {
                stoppedPositionHistory.removeFirst(stoppedPositionHistory.count - Self.maxStoppedPositionHistory)
            }
        }
        lastRecordedStoppedFrameID = nextPosition.frameID

        // Fast path: frame already in loaded window.
        if let index = frames.firstIndex(where: { $0.frame.id == nextPosition.frameID }) {
            if index != currentIndex {
                currentIndex = index
                loadImageIfNeeded()
                checkAndLoadMoreFrames()
            }
            restoreSearchHighlightIfNeeded(from: nextPosition)
            return true
        }

        // Slow path: frame outside current window.
        Task { @MainActor in
            await navigateToUndoPosition(nextPosition)
        }
        return true
    }

    /// Navigate to an undo position by reloading frames around the timestamp
    /// Similar to navigateToSearchResult but without search highlighting
    @MainActor
    private func navigateToUndoPosition(_ position: StoppedPosition) async {
        // Exit live mode - we're navigating to a historical frame
        if isInLiveMode {
            exitLiveMode()
        }

        // Reuse the shared reload path so boundary-state reset/load-more behavior stays consistent.
        clearDiskFrameBuffer(reason: "undo navigation")
        await reloadFramesAroundTimestamp(position.timestamp)

        guard !frames.isEmpty else {
            Log.warning("[PlayheadUndo] Reload window empty after undo navigation", category: .ui)
            return
        }

        // Ensure undo lands on the exact frame when available.
        if let index = frames.firstIndex(where: { $0.frame.id == position.frameID }) {
            if index != currentIndex {
                currentIndex = index
                loadImageIfNeeded()
                _ = checkAndLoadMoreFrames(reason: "navigateToUndoPosition.postReloadFramePin")
            }
        } else {
            Log.warning("[PlayheadUndo] Frame ID not found after reload, keeping closest timestamp frame", category: .ui)
        }

        restoreSearchHighlightIfNeeded(from: position)

        Log.info("[PlayheadUndo] Navigation complete, now at index \(currentIndex)", category: .ui)
    }

    /// Navigate to a specific frame by ID and highlight the search query
    /// Used when selecting a search result
    public func navigateToSearchResult(frameID: FrameID, timestamp: Date, highlightQuery: String) async {
        cancelPendingStoppedPositionRecording()
        _ = recordCurrentPositionImmediatelyForUndo(reason: "navigateToSearchResult.source")

        // Exit live mode immediately - we're navigating to a specific historical frame
        if isInLiveMode {
            exitLiveMode()
        }

        // Clear any active filters so the target frame is guaranteed to be found
        if filterCriteria.hasActiveFilters {
            Log.info("[SearchNavigation] Clearing active filters before navigating to search result", category: .ui)
            clearFilterState()
            isFilterPanelVisible = false
        }

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        df.timeZone = .current
        Log.info("[SearchNavigation] Navigating to search result: frameID=\(frameID.stringValue), timestamp=\(df.string(from: timestamp)) (epoch: \(timestamp.timeIntervalSince1970)), query='\(highlightQuery)'", category: .ui)

        // Log current frames window for debugging
        if let first = frames.first, let last = frames.last {
        } else {
        }

        // First, try to find a frame with this ID in our current data
        if let index = frames.firstIndex(where: { $0.frame.id == frameID }) {
            navigateToFrame(index)
            _ = recordCurrentPositionImmediatelyForUndo(
                reason: "navigateToSearchResult.destination",
                highlightQueryOverride: highlightQuery
            )
            showSearchHighlight(query: highlightQuery, mode: .matchedNodes)
            return
        }


        // If not found, load frames in a ±10 minute window around the target timestamp
        // This approach (same as Cmd+G date search) guarantees the target frame is included
        do {
            setLoadingState(true, reason: "navigateToSearchResult")

            // Calculate ±10 minute window around target timestamp
            let calendar = Calendar.current
            let startDate = calendar.date(byAdding: .minute, value: -10, to: timestamp) ?? timestamp
            let endDate = calendar.date(byAdding: .minute, value: 10, to: timestamp) ?? timestamp


            // Fetch all frames in the 20-minute window with video info (single optimized query)
            // Always pass filterCriteria to ensure hidden filter is applied (default: .hide)
            let framesWithVideoInfo = try await fetchFramesWithVideoInfoLogged(
                from: startDate,
                to: endDate,
                limit: 1000,
                filters: filterCriteria,
                reason: "navigateToSearchResult"
            )

            guard !framesWithVideoInfo.isEmpty else {
                Log.warning("[SearchNavigation] No frames found in time range", category: .ui)
                setLoadingState(false, reason: "navigateToSearchResult.noFrames")
                return
            }

            // Clear disk frame buffer since we're jumping to a new time window
            let oldCacheCount = diskFrameBufferIndex.count
            clearDiskFrameBuffer(reason: "search navigation")
            if oldCacheCount > 0 {
            }

            // Convert to TimelineFrame - video info is already included from the JOIN
            let timelineFrames = framesWithVideoInfo.map { TimelineFrame(frameWithVideoInfo: $0) }

            // Replace current frames with new window
            frames = timelineFrames

            // Update window boundaries
            if let firstFrame = frames.first, let lastFrame = frames.last {
                oldestLoadedTimestamp = firstFrame.frame.timestamp
                newestLoadedTimestamp = lastFrame.frame.timestamp
            }

            // Find and navigate to the target frame by ID
            if let index = frames.firstIndex(where: { $0.frame.id == frameID }) {
                currentIndex = index
            } else {
                // Fallback: find closest frame by timestamp if ID not found
                let closest = frames.enumerated().min(by: {
                    abs($0.element.frame.timestamp.timeIntervalSince(timestamp)) <
                    abs($1.element.frame.timestamp.timeIntervalSince(timestamp))
                })
                currentIndex = closest?.offset ?? 0
                if let closestFrame = closest {
                    let diff = abs(closestFrame.element.frame.timestamp.timeIntervalSince(timestamp))
                    Log.warning("[SearchNavigation] Frame ID not found in loaded frames, using closest by timestamp at index \(closestFrame.offset), \(diff)s from target", category: .ui)
                }
            }
            _ = recordCurrentPositionImmediatelyForUndo(
                reason: "navigateToSearchResult.destination",
                highlightQueryOverride: highlightQuery
            )

            loadImageIfNeeded()

            // Check if we need to pre-load more frames (near edge of loaded window)
            checkAndLoadMoreFrames()

            // Wait for OCR nodes to load before showing highlight
            // (loadImageIfNeeded calls loadOCRNodes but doesn't await it)
            await loadOCRNodesAsync()
            showSearchHighlight(query: highlightQuery, mode: .matchedNodes)
            setLoadingState(false, reason: "navigateToSearchResult.success")
            Log.info("[SearchNavigation] Navigation complete, now at index \(currentIndex)", category: .ui)

        } catch {
            Log.error("[SearchNavigation] Failed to navigate to search result: \(error)", category: .ui)
            setLoadingState(false, reason: "navigateToSearchResult.error")
        }
    }

    /// Show search highlight for the given query after a 0.5-second delay
    public func showSearchHighlight(query: String) {
        showSearchHighlight(query: query, mode: .matchedTextRanges)
    }

    func showSearchHighlight(
        query: String,
        mode: SearchHighlightMode
    ) {

        // Clear any existing highlight first (so the view is removed and onAppear will fire again)
        isShowingSearchHighlight = false
        searchHighlightQuery = query
        searchHighlightMode = mode

        // Show highlight after 0.5 second delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }
            // Only show if the query and highlight mode haven't changed
            if self.searchHighlightQuery == query && self.searchHighlightMode == mode {
                self.isShowingSearchHighlight = true
            }
        }
    }

    /// Clear the search highlight
    public func clearSearchHighlight() {
        searchHighlightTimer?.invalidate()
        searchHighlightTimer = nil

        let previousQuery = searchHighlightQuery
        let previousMode = searchHighlightMode
        withAnimation(.easeOut(duration: 0.3)) {
            isShowingSearchHighlight = false
        }

        // Clear the query after animation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            guard !self.isShowingSearchHighlight else { return }
            guard self.searchHighlightQuery == previousQuery else { return }
            guard self.searchHighlightMode == previousMode else { return }
            self.searchHighlightQuery = nil
            self.searchHighlightMode = .matchedTextRanges
        }
    }

    /// Reset transient search-highlight state immediately when switching timeline contexts.
    public func resetSearchHighlightState() {
        clearSearchHighlightImmediately()
    }

    private func clearSearchHighlightImmediately() {
        searchHighlightTimer?.invalidate()
        searchHighlightTimer = nil
        isShowingSearchHighlight = false
        searchHighlightQuery = nil
        searchHighlightMode = .matchedTextRanges
    }

    /// Toggle visibility of timeline controls (tape, playhead, buttons)
    public func toggleControlsVisibility() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            areControlsHidden.toggle()
            // Dismiss filter panel when hiding controls
            if areControlsHidden && isFilterPanelVisible {
                dismissFilterPanel()
            }
        }
    }

    /// Get OCR nodes that match the search query (for highlighting).
    /// Each comma-separated entry is treated as its own exact phrase match.
    public var searchHighlightNodes: [(node: OCRNodeWithText, ranges: [Range<String.Index>])] {
        guard let query = searchHighlightQuery, !query.isEmpty, isShowingSearchHighlight else {
            return []
        }

        return Self.searchHighlightMatches(
            in: ocrNodes,
            query: query,
            mode: searchHighlightMode
        )
    }

    private static let searchHighlightLineTolerance: CGFloat = 0.02

    /// Build line-based text from highlighted OCR matches.
    /// Nodes are grouped by vertical proximity and joined left-to-right per line.
    func highlightedSearchTextLines(
        from matches: [(node: OCRNodeWithText, ranges: [Range<String.Index>])]? = nil
    ) -> [String] {
        let sourceMatches = matches ?? searchHighlightNodes
        guard !sourceMatches.isEmpty else { return [] }

        var seenNodeIDs = Set<Int>()
        let uniqueNodes = sourceMatches.compactMap { match -> OCRNodeWithText? in
            guard seenNodeIDs.insert(match.node.id).inserted else { return nil }
            return match.node
        }
        guard !uniqueNodes.isEmpty else { return [] }

        let sortedNodes = uniqueNodes.sorted { lhs, rhs in
            if abs(lhs.y - rhs.y) > Self.searchHighlightLineTolerance {
                return lhs.y < rhs.y
            }
            return lhs.x < rhs.x
        }

        var groupedLines: [[OCRNodeWithText]] = []
        var currentLine: [OCRNodeWithText] = []
        var currentLineAverageY: CGFloat?

        for node in sortedNodes {
            if let lineY = currentLineAverageY,
               abs(node.y - lineY) <= Self.searchHighlightLineTolerance {
                currentLine.append(node)
                let lineCount = CGFloat(currentLine.count)
                currentLineAverageY = ((lineY * (lineCount - 1)) + node.y) / lineCount
            } else {
                if !currentLine.isEmpty {
                    groupedLines.append(currentLine)
                }
                currentLine = [node]
                currentLineAverageY = node.y
            }
        }

        if !currentLine.isEmpty {
            groupedLines.append(currentLine)
        }

        return groupedLines.compactMap { lineNodes in
            let lineText = lineNodes
                .sorted { $0.x < $1.x }
                .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            return lineText.isEmpty ? nil : lineText
        }
    }

    /// Copy highlighted search text to clipboard, grouped by highlighted line.
    func copySearchHighlightedTextByLine(
        from matches: [(node: OCRNodeWithText, ranges: [Range<String.Index>])]? = nil
    ) {
        let lines = highlightedSearchTextLines(from: matches)
        guard !lines.isEmpty else {
            showToast("No highlighted text to copy", icon: "exclamationmark.circle.fill")
            return
        }

        let textToCopy = lines.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(textToCopy, forType: .string)
        showToast("Highlighted text copied", icon: "doc.on.doc.fill")
        DashboardViewModel.recordTextCopy(coordinator: coordinator, text: textToCopy)
    }

    private enum SearchHighlightToken {
        case phrase(String)
    }

    static func searchHighlightMatches(
        in nodes: [OCRNodeWithText],
        query: String,
        mode: SearchHighlightMode
    ) -> [(node: OCRNodeWithText, ranges: [Range<String.Index>])] {
        let queryTokens = tokenizeSearchHighlightQuery(query)
        guard !queryTokens.isEmpty else { return [] }

        var matchingNodes: [(node: OCRNodeWithText, ranges: [Range<String.Index>])] = []

        for node in nodes {
            let nodeText = node.text.lowercased()
            var ranges: [Range<String.Index>] = []

            for token in queryTokens {
                ranges.append(contentsOf: rangesForSearchHighlightToken(token, in: nodeText))
            }

            if !ranges.isEmpty {
                matchingNodes.append((
                    node: node,
                    ranges: mode == .matchedNodes ? [] : ranges
                ))
            }
        }

        return matchingNodes
    }

    private static func tokenizeSearchHighlightQuery(_ query: String) -> [SearchHighlightToken] {
        let normalizedQuery = query
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else { return [] }

        return normalizedQuery
            .split(separator: ",", omittingEmptySubsequences: false)
            .compactMap { rawComponent in
                let value = rawComponent
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                guard !value.isEmpty else { return nil }
                return .phrase(value)
            }
    }

    private static func rangesForSearchHighlightToken(
        _ token: SearchHighlightToken,
        in text: String
    ) -> [Range<String.Index>] {
        switch token {
        case .phrase(let phrase):
            return allRanges(of: phrase, in: text)
        }
    }

    private static func allRanges(of needle: String, in haystack: String) -> [Range<String.Index>] {
        guard !needle.isEmpty else { return [] }

        var ranges: [Range<String.Index>] = []
        var searchStartIndex = haystack.startIndex

        while searchStartIndex < haystack.endIndex,
              let range = haystack.range(of: needle, range: searchStartIndex..<haystack.endIndex) {
            ranges.append(range)
            searchStartIndex = range.upperBound
        }

        return ranges
    }

    /// Exit live mode and transition to historical frames
    /// Called on first scroll/navigation after timeline launch
    private func exitLiveMode() {
        guard isInLiveMode else { return }

        Log.info("[TIMELINE-LIVE] Exiting live mode, transitioning to historical frames", category: .ui)
        isInLiveMode = false
        liveScreenshot = nil
        isLiveOCRProcessing = false
        liveOCRDebounceTask?.cancel()
        liveOCRDebounceTask = nil
        isTapeHidden = false  // Reset animation state

        // If frames are already loaded, show the most recent
        if !frames.isEmpty {
            currentIndex = frames.count - 1
            loadImageIfNeeded()
        }
        // If frames are still loading, they'll be displayed when ready
    }

    // MARK: - Live OCR

    /// Task for the debounced live OCR - cancelled and re-created on each call
    private var liveOCRDebounceTask: Task<Void, Never>?

    /// Wrapper for safely passing CGImage into detached tasks.
    private struct LiveOCRCGImage: @unchecked Sendable {
        let image: CGImage
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

            // Convert TextRegion (normalized coords) to OCRNodeWithText
            let nodes = textRegions.enumerated().map { (index, region) in
                OCRNodeWithText(
                    id: index,
                    frameId: -1,  // Marker for live OCR (not from database)
                    x: region.bounds.origin.x,
                    y: region.bounds.origin.y,
                    width: region.bounds.width,
                    height: region.bounds.height,
                    text: region.text
                )
            }

            let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            Log.info("[LiveOCR] Completed in \(String(format: "%.0f", elapsed))ms, found \(nodes.count) text regions", category: .ui)
            Log.recordLatency(
                "timeline.live_ocr.total_ms",
                valueMs: elapsed,
                category: .ui,
                summaryEvery: 10,
                warningThresholdMs: 250,
                criticalThresholdMs: 500
            )

            setOCRNodes(nodes)
            ocrStatus = .completed
        } catch {
            Log.error("[LiveOCR] Failed: \(error)", category: .ui)
        }

        isLiveOCRProcessing = false
    }

    /// Load image for image-based frames (Retrace) if needed
    private func loadImageIfNeeded() {
        // Skip during live mode - live screenshot is already displayed and OCR is handled separately
        guard !isInLiveMode else {
            clearHyperlinkMatches()
            return
        }
        guard presentationWorkEnabled else { return }
        cancelDiskFrameBufferInactivityCleanup()

        guard let timelineFrame = currentTimelineFrame else {
            if Self.isVerboseTimelineLoggingEnabled {
                Log.debug("[TIMELINE-LOAD] loadImageIfNeeded() called but currentTimelineFrame is nil", category: .ui)
            }
            clearHyperlinkMatches()
            return
        }

        if Self.isVerboseTimelineLoggingEnabled {
            Log.debug("[TIMELINE-LOAD] loadImageIfNeeded() START for frame \(timelineFrame.frame.id.value), currentFrameNotReady=\(frameNotReady), processingStatus=\(timelineFrame.processingStatus)", category: .ui)
        }

        let presentationGeneration = currentPresentationWorkGeneration()

        // Defer heavy OCR/URL loading until scrolling stops for smoother scrubbing
        if !isActivelyScrolling {
            loadURLBoundingBox(expectedGeneration: presentationGeneration)
            loadOCRNodes(expectedGeneration: presentationGeneration)
        } else {
            // Clear stale OCR/URL data during scrolling so old bounding boxes don't persist
            setOCRNodes([])
            ocrStatus = .unknown
            ocrStatusPollingTask?.cancel()
            ocrStatusPollingTask = nil
            urlBoundingBox = nil
            clearHyperlinkMatches()
            clearTextSelection()
        }

        let frame = timelineFrame.frame

        // Check if frame is not yet readable (processingStatus = 4)
        // This provides instant feedback instead of waiting for async load to fail
        if timelineFrame.processingStatus == 4 {
            if Self.isVerboseTimelineLoggingEnabled {
                Log.info("[TIMELINE-LOAD] Frame \(frame.id.value) has processingStatus=4 (NOT_YET_READABLE), setting frameNotReady=true", category: .ui)
            }
            clearCurrentImagePresentation()
            frameNotReady = true
            frameLoadError = false
            ensureDiskHotWindowCoverage(reason: "frame-not-yet-readable")
            return
        }

        // Reset frameNotReady immediately when status != 4
        // This prevents stale "still encoding" state from persisting when scrolling
        // from a processingStatus=4 frame to an earlier ready frame
        if Self.isVerboseTimelineLoggingEnabled {
            Log.debug("[TIMELINE-LOAD] Frame \(frame.id.value) has processingStatus=\(timelineFrame.processingStatus) (!= 4), setting frameNotReady=false", category: .ui)
        }
        frameNotReady = false
        frameLoadError = false

        diskFrameBufferTelemetry.frameRequests += 1

        // Skip duplicate requests for the currently active/pending frame.
        guard activeForegroundFrameID != frame.id,
              pendingForegroundFrameLoad?.timelineFrame.frame.id != frame.id else {
            if Self.isVerboseTimelineLoggingEnabled {
                Log.debug("[TIMELINE-LOAD] Frame \(frame.id.value) foreground load already in-flight/pending; skipping duplicate request", category: .ui)
            }
            ensureDiskHotWindowCoverage(reason: "duplicate foreground request")
            return
        }
        enqueueForegroundFrameLoad(
            timelineFrame,
            presentationGeneration: presentationGeneration
        )

        ensureDiskHotWindowCoverage(reason: "foreground request")
    }

    private func enqueueForegroundFrameLoad(
        _ timelineFrame: TimelineFrame,
        presentationGeneration: UInt64
    ) {
        if pendingForegroundFrameLoad != nil {
            // Coalesce bursty scrub requests into latest-only foreground work.
            diskFrameBufferTelemetry.foregroundLoadCancels += 1
        }
        pendingForegroundFrameLoad = PendingForegroundFrameLoad(
            timelineFrame: timelineFrame,
            presentationGeneration: presentationGeneration
        )

        guard foregroundFrameLoadTask == nil else { return }

        foregroundFrameLoadTask = Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await self.runForegroundFrameLoadLoop()
        }
    }

    private func runForegroundFrameLoadLoop() async {
        while !Task.isCancelled {
            guard let request = pendingForegroundFrameLoad else { break }
            pendingForegroundFrameLoad = nil
            isForegroundFrameLoadInFlight = true
            activeForegroundFrameID = request.timelineFrame.frame.id
            await performForegroundFrameLoad(
                request.timelineFrame,
                expectedGeneration: request.presentationGeneration
            )
            isForegroundFrameLoadInFlight = false
            activeForegroundFrameID = nil
        }

        foregroundFrameLoadTask = nil
    }

    private func loadFrameData(_ timelineFrame: TimelineFrame) async throws -> Data {
#if DEBUG
        if let override = test_foregroundFrameLoadHooks.loadFrameData {
            return try await override(timelineFrame)
        }
#endif

        let frame = timelineFrame.frame
        if let videoInfo = timelineFrame.videoInfo {
            return try await coordinator.getFrameImageFromPath(
                videoPath: videoInfo.videoPath,
                frameIndex: videoInfo.frameIndex
            )
        }

        return try await coordinator.getFrameImage(
            segmentID: frame.videoID,
            timestamp: frame.timestamp
        )
    }

#if DEBUG
    func test_loadForegroundPresentationImage(_ timelineFrame: TimelineFrame) async throws -> NSImage {
        let (image, _) = try await loadForegroundPresentationImage(timelineFrame)
        return image
    }
#endif

    private func loadForegroundPresentationImage(_ timelineFrame: TimelineFrame) async throws -> (image: NSImage, loadedFromDiskBuffer: Bool) {
        let frameID = timelineFrame.frame.id

        if let bufferedData = await readFrameDataFromDiskFrameBuffer(frameID: frameID) {
            diskFrameBufferTelemetry.diskHits += 1
            guard let image = NSImage(data: bufferedData) else {
                diskFrameBufferTelemetry.decodeFailures += 1
                removeDiskFrameBufferEntries([frameID], reason: "decode failure")
                throw NSError(
                    domain: "SimpleTimelineViewModel",
                    code: -2,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to decode buffered frame image"]
                )
            }
            diskFrameBufferTelemetry.decodeSuccesses += 1
            return (image, true)
        }

        diskFrameBufferTelemetry.diskMisses += 1
        diskFrameBufferTelemetry.storageReads += 1
        let imageData = try await loadFrameData(timelineFrame)
        await storeFrameDataInDiskFrameBuffer(frameID: frameID, data: imageData)
        guard let image = NSImage(data: imageData) else {
            diskFrameBufferTelemetry.decodeFailures += 1
            removeDiskFrameBufferEntries([frameID], reason: "decode failure")
            throw NSError(
                domain: "SimpleTimelineViewModel",
                code: -3,
                userInfo: [NSLocalizedDescriptionKey: "Failed to decode loaded frame image"]
            )
        }
        diskFrameBufferTelemetry.decodeSuccesses += 1
        return (image, false)
    }

    private func performForegroundFrameLoad(
        _ timelineFrame: TimelineFrame,
        expectedGeneration: UInt64
    ) async {
        let frame = timelineFrame.frame
        guard canPublishPresentationResult(
            frameID: frame.id,
            expectedGeneration: expectedGeneration
        ) else { return }
        // Hidden timeline refresh/pre-render loads are best-effort and should not page
        // attention with interactive-path slow-sample warnings/criticals.
        let shouldEmitInteractiveSlowSampleAlerts = TimelineWindowController.shared.isVisible

        do {
            let loadStart = CFAbsoluteTimeGetCurrent()
            let storageReadStart = CFAbsoluteTimeGetCurrent()
            let (image, loadedFromDiskBuffer) = try await loadForegroundPresentationImage(timelineFrame)
            let storageReadMs = (CFAbsoluteTimeGetCurrent() - storageReadStart) * 1000
            Log.recordLatency(
                loadedFromDiskBuffer ? "timeline.disk_buffer.read_ms" : "timeline.frame.storage_read_ms",
                valueMs: storageReadMs,
                category: .ui,
                summaryEvery: 25,
                warningThresholdMs: loadedFromDiskBuffer ? 25 : (shouldEmitInteractiveSlowSampleAlerts ? 45 : nil),
                criticalThresholdMs: loadedFromDiskBuffer ? 80 : (shouldEmitInteractiveSlowSampleAlerts ? 150 : nil)
            )

            try Task.checkCancellation()
            guard canPublishPresentationResult(
                frameID: frame.id,
                expectedGeneration: expectedGeneration
            ) else { return }

            let totalMs = (CFAbsoluteTimeGetCurrent() - loadStart) * 1000
            Log.recordLatency(
                "timeline.frame.present_ms",
                valueMs: totalMs,
                category: .ui,
                summaryEvery: 20,
                warningThresholdMs: shouldEmitInteractiveSlowSampleAlerts ? 80 : nil,
                criticalThresholdMs: shouldEmitInteractiveSlowSampleAlerts ? 220 : nil
            )
            Log.recordLatency(
                loadedFromDiskBuffer
                    ? "timeline.frame.present.disk_ms"
                    : "timeline.frame.present.storage_ms",
                valueMs: totalMs,
                category: .ui,
                summaryEvery: 20,
                warningThresholdMs: shouldEmitInteractiveSlowSampleAlerts ? (loadedFromDiskBuffer ? 45 : 100) : nil,
                criticalThresholdMs: shouldEmitInteractiveSlowSampleAlerts ? (loadedFromDiskBuffer ? 120 : 260) : nil
            )

            if canPublishPresentationResult(
                frameID: frame.id,
                expectedGeneration: expectedGeneration
            ) {
                setCurrentImagePresentation(
                    image,
                    frameID: frame.id
                )
                frameNotReady = false
                frameLoadError = false
                if Self.isVerboseTimelineLoggingEnabled {
                    Log.debug(
                        "[TIMELINE-LOAD] Successfully loaded image for frame \(frame.id.value) source=\(loadedFromDiskBuffer ? "disk-buffer" : "storage-read")",
                        category: .ui
                    )
                }
            }
        } catch is CancellationError {
            // Replaced by a newer foreground frame request.
        } catch StorageError.fileReadFailed(_, let underlying) where underlying.contains("still being written") {
            diskFrameBufferTelemetry.storageReadFailures += 1
            if Self.isVerboseTimelineLoggingEnabled {
                Log.info("[TIMELINE-LOAD] Frame \(frame.id.value) video still being written (processingStatus=\(timelineFrame.processingStatus))", category: .app)
            }
            if canPublishPresentationResult(
                frameID: frame.id,
                expectedGeneration: expectedGeneration
            ) {
                clearCurrentImagePresentation()
                frameLoadError = false
                if timelineFrame.processingStatus != 2 {
                    frameNotReady = true
                }
            }
        } catch StorageError.fileReadFailed(_, let underlying) where underlying.contains("out of range") {
            diskFrameBufferTelemetry.storageReadFailures += 1
            if Self.isVerboseTimelineLoggingEnabled {
                Log.info("[TIMELINE-LOAD] Frame \(frame.id.value) not yet in video file (still encoding, processingStatus=\(timelineFrame.processingStatus))", category: .app)
            }
            if canPublishPresentationResult(
                frameID: frame.id,
                expectedGeneration: expectedGeneration
            ) {
                clearCurrentImagePresentation()
                if timelineFrame.processingStatus != 2 {
                    frameNotReady = true
                    frameLoadError = false
                } else {
                    frameNotReady = false
                    frameLoadError = true
                }
            }
        } catch let error as NSError where error.domain == "AVFoundationErrorDomain" && error.code == -11829 {
            diskFrameBufferTelemetry.storageReadFailures += 1
            if Self.isVerboseTimelineLoggingEnabled {
                Log.info("[TIMELINE-LOAD] Frame \(frame.id.value) video not ready yet (no fragments, processingStatus=\(timelineFrame.processingStatus))", category: .app)
            }
            if canPublishPresentationResult(
                frameID: frame.id,
                expectedGeneration: expectedGeneration
            ) {
                clearCurrentImagePresentation()
                if timelineFrame.processingStatus != 2 {
                    frameNotReady = true
                    frameLoadError = false
                } else {
                    frameNotReady = false
                    frameLoadError = false
                }
            }
        } catch {
            diskFrameBufferTelemetry.storageReadFailures += 1
            Log.error("[SimpleTimelineViewModel] Failed to load image: \(error)", category: .app)
            if canPublishPresentationResult(
                frameID: frame.id,
                expectedGeneration: expectedGeneration
            ) {
                clearCurrentImagePresentation()
                frameNotReady = false
                frameLoadError = timelineFrame.videoInfo == nil
            }
        }
    }

    private func makeCenteredHotWindow(around index: Int) -> ClosedRange<Int> {
        let totalFrames = frames.count
        let targetCount = min(Self.hotWindowFrameCount, totalFrames)
        guard targetCount > 0 else { return 0...0 }

        var lowerBound = max(0, index - (targetCount / 2))
        var upperBound = lowerBound + targetCount - 1
        if upperBound >= totalFrames {
            upperBound = totalFrames - 1
            lowerBound = max(0, upperBound - targetCount + 1)
        }
        return lowerBound...upperBound
    }

    private func ensureDiskHotWindowCoverage(reason: String) {
        guard !frames.isEmpty else { return }
        guard currentIndex >= 0 && currentIndex < frames.count else { return }

        guard let existingRange = hotWindowRange, existingRange.contains(currentIndex) else {
            let centeredRange = makeCenteredHotWindow(around: currentIndex)
            resetCacheMoreEdgeHysteresis()
            hotWindowRange = centeredRange
            queueCacheMoreFrames(
                for: centeredRange,
                direction: .centered,
                reason: "hot-window-reset.\(reason)"
            )
            return
        }

        let distanceToLower = currentIndex - existingRange.lowerBound
        let distanceToUpper = existingRange.upperBound - currentIndex
        if distanceToLower > Self.cacheMoreEdgeRetriggerDistance {
            cacheMoreOlderEdgeArmed = true
        }
        if distanceToUpper > Self.cacheMoreEdgeRetriggerDistance {
            cacheMoreNewerEdgeArmed = true
        }

        let shouldExpandOlder = distanceToLower <= Self.cacheMoreEdgeThreshold && cacheMoreOlderEdgeArmed
        let shouldExpandNewer = distanceToUpper <= Self.cacheMoreEdgeThreshold && cacheMoreNewerEdgeArmed

        if shouldExpandOlder && shouldExpandNewer {
            if distanceToLower <= distanceToUpper {
                cacheMoreOlderEdgeArmed = false
                expandHotWindowOlder(reason: reason)
            } else {
                cacheMoreNewerEdgeArmed = false
                expandHotWindowNewer(reason: reason)
            }
            return
        }

        if shouldExpandOlder {
            cacheMoreOlderEdgeArmed = false
            expandHotWindowOlder(reason: reason)
        } else if shouldExpandNewer {
            cacheMoreNewerEdgeArmed = false
            expandHotWindowNewer(reason: reason)
        }
    }

    private func expandHotWindowOlder(reason: String) {
        guard let currentRange = hotWindowRange else { return }
        let newLowerBound = max(0, currentRange.lowerBound - Self.cacheMoreBatchSize)
        guard newLowerBound < currentRange.lowerBound else { return }
        let expansionRange = newLowerBound...(currentRange.lowerBound - 1)
        hotWindowRange = newLowerBound...currentRange.upperBound
        queueCacheMoreFrames(for: expansionRange, direction: .older, reason: reason)
    }

    private func expandHotWindowNewer(reason: String) {
        guard let currentRange = hotWindowRange else { return }
        let newUpperBound = min(frames.count - 1, currentRange.upperBound + Self.cacheMoreBatchSize)
        guard newUpperBound > currentRange.upperBound else { return }
        let expansionRange = (currentRange.upperBound + 1)...newUpperBound
        hotWindowRange = currentRange.lowerBound...newUpperBound
        queueCacheMoreFrames(for: expansionRange, direction: .newer, reason: reason)
    }

    private func queueCacheMoreFrames(
        for indexRange: ClosedRange<Int>,
        direction: CacheExpansionDirection,
        reason: String
    ) {
        guard !frames.isEmpty else { return }
        guard indexRange.lowerBound >= 0, indexRange.upperBound < frames.count else { return }

        let orderedIndices = makeCacheMoreOrderedIndices(for: indexRange, direction: direction)
        var queuedCount = 0

        for index in orderedIndices {
            guard index >= 0 && index < frames.count else { continue }
            let timelineFrame = frames[index]
            guard let videoInfo = timelineFrame.videoInfo else { continue }
            let descriptor = CacheMoreFrameDescriptor(
                frameID: timelineFrame.frame.id,
                videoPath: videoInfo.videoPath,
                frameIndex: videoInfo.frameIndex
            )

            if containsFrameInDiskFrameBuffer(descriptor.frameID)
                || queuedOrInFlightCacheExpansionFrameIDs.contains(descriptor.frameID) {
                diskFrameBufferTelemetry.cacheMoreSkippedBuffered += 1
                continue
            }

            pendingCacheExpansionQueue.append(descriptor)
            queuedOrInFlightCacheExpansionFrameIDs.insert(descriptor.frameID)
            queuedCount += 1
        }

        guard queuedCount > 0 else { return }

        diskFrameBufferTelemetry.cacheMoreRequests += 1
        diskFrameBufferTelemetry.cacheMoreFramesQueued += queuedCount

        if Self.isVerboseTimelineLoggingEnabled {
            let pendingCount = pendingCacheExpansionQueue.count - pendingCacheExpansionReadIndex
            Log.debug(
                "[Timeline-DiskBuffer] cacheMore queued direction=\(direction.rawValue) added=\(queuedCount) pending=\(max(pendingCount, 0)) reason=\(reason)",
                category: .ui
            )
        }

        guard cacheExpansionTask == nil else { return }
        cacheExpansionTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            await self.runCacheMoreWorker()
        }
    }

    private func runCacheMoreWorker() async {
        defer {
            cacheExpansionTask = nil
            pendingCacheExpansionQueue.removeAll()
            pendingCacheExpansionReadIndex = 0
            queuedOrInFlightCacheExpansionFrameIDs.removeAll()
        }

        if Self.isVerboseTimelineLoggingEnabled {
            Log.debug(
                "[Timeline-DiskBuffer] cacheMore worker started",
                category: .ui
            )
        }

        while let descriptor = dequeueNextPendingCacheExpansionDescriptor() {
            defer { queuedOrInFlightCacheExpansionFrameIDs.remove(descriptor.frameID) }

            if Task.isCancelled {
                diskFrameBufferTelemetry.cacheMoreCancelled += 1
                return
            }

            if containsFrameInDiskFrameBuffer(descriptor.frameID) {
                diskFrameBufferTelemetry.cacheMoreSkippedBuffered += 1
                continue
            }

            while hasForegroundFrameLoadPressure {
                if Task.isCancelled {
                    diskFrameBufferTelemetry.cacheMoreCancelled += 1
                    return
                }
                try? await Task.sleep(for: .milliseconds(20), clock: .continuous)
            }

            do {
                let storageReadStart = CFAbsoluteTimeGetCurrent()
                let imageData = try await coordinator.getFrameImageFromPath(
                    videoPath: descriptor.videoPath,
                    frameIndex: descriptor.frameIndex
                )
                let storageReadMs = (CFAbsoluteTimeGetCurrent() - storageReadStart) * 1000
                let shouldEmitInteractiveSlowSampleAlerts = TimelineWindowController.shared.isVisible
                Log.recordLatency(
                    "timeline.cache_more.storage_read_ms",
                    valueMs: storageReadMs,
                    category: .ui,
                    summaryEvery: 25,
                    warningThresholdMs: shouldEmitInteractiveSlowSampleAlerts ? 55 : nil,
                    criticalThresholdMs: shouldEmitInteractiveSlowSampleAlerts ? 180 : nil
                )

                if Task.isCancelled {
                    diskFrameBufferTelemetry.cacheMoreCancelled += 1
                    return
                }

                await storeFrameDataInDiskFrameBuffer(frameID: descriptor.frameID, data: imageData)
                diskFrameBufferTelemetry.cacheMoreStored += 1
            } catch is CancellationError {
                diskFrameBufferTelemetry.cacheMoreCancelled += 1
                return
            } catch {
                diskFrameBufferTelemetry.cacheMoreFailures += 1
            }
        }

        if Self.isVerboseTimelineLoggingEnabled {
            Log.debug("[Timeline-DiskBuffer] cacheMore worker drained queue", category: .ui)
        }
    }

    private func dequeueNextPendingCacheExpansionDescriptor() -> CacheMoreFrameDescriptor? {
        guard pendingCacheExpansionReadIndex < pendingCacheExpansionQueue.count else {
            pendingCacheExpansionQueue.removeAll(keepingCapacity: true)
            pendingCacheExpansionReadIndex = 0
            return nil
        }

        let descriptor = pendingCacheExpansionQueue[pendingCacheExpansionReadIndex]
        pendingCacheExpansionReadIndex += 1

        // Compact consumed prefix periodically to avoid unbounded array growth during long sessions.
        if pendingCacheExpansionReadIndex >= 128
            && pendingCacheExpansionReadIndex * 2 >= pendingCacheExpansionQueue.count {
            pendingCacheExpansionQueue.removeFirst(pendingCacheExpansionReadIndex)
            pendingCacheExpansionReadIndex = 0
        }

        return descriptor
    }

    private func makeCacheMoreOrderedIndices(
        for indexRange: ClosedRange<Int>,
        direction: CacheExpansionDirection
    ) -> [Int] {
        var ordered = Array(indexRange)
        switch direction {
        case .older:
            ordered.reverse()
        case .newer:
            break
        case .centered:
            ordered.sort { lhs, rhs in
                let lhsDistance = abs(lhs - currentIndex)
                let rhsDistance = abs(rhs - currentIndex)
                if lhsDistance == rhsDistance {
                    return lhs < rhs
                }
                return lhsDistance < rhsDistance
            }
        }
        return ordered
    }

    private func resetCacheMoreEdgeHysteresis() {
        cacheMoreOlderEdgeArmed = true
        cacheMoreNewerEdgeArmed = true
    }

    /// Load URL bounding box for the current frame (if it's a browser URL)
    private func loadURLBoundingBox(expectedGeneration: UInt64 = 0) {
        guard let timelineFrame = currentTimelineFrame else {
            urlBoundingBox = nil
            return
        }
        let generation = expectedGeneration == 0
            ? currentPresentationWorkGeneration()
            : expectedGeneration

        let frame = timelineFrame.frame
        guard canPublishPresentationResult(
            frameID: frame.id,
            expectedGeneration: generation
        ) else { return }

        // Reset hover state when frame changes
        isHoveringURL = false

        // Load URL bounding box asynchronously
        Task {
            do {
                let boundingBox = try await fetchURLBoundingBoxForPresentation(
                    timestamp: frame.timestamp,
                    source: frame.source
                )
                if canPublishPresentationResult(
                    frameID: frame.id,
                    expectedGeneration: generation
                ) {
                    urlBoundingBox = boundingBox
                    if let box = boundingBox {
                        Log.debug("[URLBoundingBox] Found URL '\(box.url)' at (\(box.x), \(box.y), \(box.width), \(box.height))", category: .ui)
                    }
                }
            } catch {
                Log.error("[SimpleTimelineViewModel] Failed to load URL bounding box: \(error)", category: .app)
                if canPublishPresentationResult(
                    frameID: frame.id,
                    expectedGeneration: generation
                ) {
                    urlBoundingBox = nil
                }
            }
        }
    }

    /// Open the URL in the default browser
    public func openURLInBrowser() {
        guard let box = urlBoundingBox,
              let url = URL(string: box.url) else {
            return
        }

        NSWorkspace.shared.open(url)
        Log.info("[URLBoundingBox] Opened URL in browser: \(box.url)", category: .ui)
    }

    /// Open the current frame's browser URL in the default browser.
    /// - Returns: `true` if a valid URL was opened.
    @discardableResult
    public func openCurrentBrowserURL() -> Bool {
        guard let timelineFrame = currentTimelineFrame,
              let urlString = timelineFrame.frame.metadata.browserURL,
              !urlString.isEmpty else {
            return false
        }

        Log.debug(
            "[BrowserLinkOpen] start frameId=\(timelineFrame.frame.id.value) baseURL=\(urlString) scrollY=\(String(describing: timelineFrame.scrollY)) videoCurrentTime=\(String(describing: timelineFrame.videoCurrentTime))",
            category: .ui
        )
        let finalURLString = currentBrowserOpenURLString(
            baseURLString: urlString,
            videoCurrentTime: timelineFrame.videoCurrentTime,
            scrollY: timelineFrame.scrollY
        )
        Log.debug(
            "[BrowserLinkOpen] resolved frameId=\(timelineFrame.frame.id.value) finalURL=\(finalURLString)",
            category: .ui
        )
        guard let finalURL = URL(string: finalURLString) else {
            Log.warning(
                "[BrowserLinkOpen] invalid final URL frameId=\(timelineFrame.frame.id.value) finalURL=\(finalURLString)",
                category: .ui
            )
            return false
        }

        let usedTextFragment = Self.urlContainsTextFragment(finalURLString)
        let usedYouTubeTimestamp = Self.urlContainsYouTubeTimestamp(finalURLString)

        guard let browserApplicationURL = Self.hyperlinkBrowserApplicationURL(for: finalURL) else {
            let opened = NSWorkspace.shared.open(finalURL)
            if opened {
                Log.info("[Timeline] Opened current browser URL via fallback dispatch: \(finalURLString)", category: .ui)
                DashboardViewModel.recordBrowserLinkOpened(
                    coordinator: coordinator,
                    source: "current_browser_url",
                    url: finalURLString,
                    usedTextFragment: usedTextFragment,
                    usedYouTubeTimestamp: usedYouTubeTimestamp
                )
            } else {
                Log.warning("[Timeline] Failed to open current browser URL: \(finalURLString)", category: .ui)
            }
            return true
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false

        NSWorkspace.shared.open([finalURL], withApplicationAt: browserApplicationURL, configuration: configuration) { [weak self] _, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let error {
                    Log.warning(
                        "[Timeline] Failed to open current browser URL in explicit browser \(browserApplicationURL.path): \(finalURLString) | \(error.localizedDescription)",
                        category: .ui
                    )
                } else {
                    Log.info(
                        "[Timeline] Opened current browser URL in explicit browser \(browserApplicationURL.path): \(finalURLString)",
                        category: .ui
                    )
                    DashboardViewModel.recordBrowserLinkOpened(
                        coordinator: self.coordinator,
                        source: "current_browser_url",
                        url: finalURLString,
                        usedTextFragment: usedTextFragment,
                        usedYouTubeTimestamp: usedYouTubeTimestamp
                    )
                }
            }
        }
        return true
    }

    /// Copy the current frame's browser URL to the clipboard.
    /// - Returns: `true` if a valid URL was copied.
    @discardableResult
    public func copyCurrentBrowserURL() -> Bool {
        guard let timelineFrame = currentTimelineFrame,
              let urlString = timelineFrame.frame.metadata.browserURL,
              !urlString.isEmpty else {
            return false
        }

        let finalURLString = timestampedCurrentBrowserURLString(
            baseURLString: urlString,
            videoCurrentTime: timelineFrame.videoCurrentTime
        )
        guard URL(string: finalURLString) != nil else {
            return false
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(finalURLString, forType: .string)
        showToast("Link copied")
        Log.info("[Timeline] Copied current browser URL: \(finalURLString)", category: .ui)
        return true
    }

    private func timestampedCurrentBrowserURLString(
        baseURLString: String,
        videoCurrentTime: Double?
    ) -> String {
        Self.youtubeTimestampedBrowserURLString(
            baseURLString,
            videoCurrentTime: videoCurrentTime
        )
    }

    private func currentBrowserOpenURLString(
        baseURLString: String,
        videoCurrentTime: Double?,
        scrollY: Double?
    ) -> String {
        _ = scrollY
        return timestampedCurrentBrowserURLString(
            baseURLString: baseURLString,
            videoCurrentTime: videoCurrentTime
        )
    }

    static func youtubeTimestampedBrowserURLString(
        _ urlString: String,
        videoCurrentTime: Double?
    ) -> String {
        guard let videoCurrentTime,
              videoCurrentTime.isFinite,
              videoCurrentTime >= 0,
              let url = URL(string: urlString),
              Self.isYouTubeWatchURL(url),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return urlString
        }

        let seconds = Int(floor(videoCurrentTime))
        var queryItems = components.queryItems ?? []
        queryItems.removeAll { $0.name.caseInsensitiveCompare("t") == .orderedSame }
        queryItems.append(URLQueryItem(name: "t", value: "\(seconds)"))
        components.queryItems = queryItems
        return components.url?.absoluteString ?? urlString
    }

    private static func isYouTubeWatchURL(_ url: URL) -> Bool {
        normalizedHost(url.host) == "youtube.com" && url.path.lowercased() == "/watch"
    }

    private func hasScrolledPastFirstViewport(scrollY: Double?) -> Bool {
        guard let scrollY,
              scrollY.isFinite,
              scrollY > 0 else {
            return false
        }

        guard let estimatedViewportHeight = estimatedViewportHeightForCurrentFrame() else {
            return true
        }
        return scrollY >= estimatedViewportHeight
    }

    private func estimatedViewportHeightForCurrentFrame() -> Double? {
        if let imageHeight = displayableCurrentImage?.size.height,
           imageHeight > 1 {
            return Double(imageHeight)
        }

        if let videoHeight = currentTimelineFrame?.videoInfo?.height,
           videoHeight > 1 {
            let scale = max(NSScreen.main?.backingScaleFactor ?? 2.0, 1.0)
            return Double(videoHeight) / scale
        }

        return nil
    }

    private static func shouldUseSmartTextFragment(for url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return false
        }

        let host = normalizedHost(url.host)
        guard !host.isEmpty else {
            return false
        }

        return !textFragmentExcludedDomains.contains { blocked in
            host == blocked || host.hasSuffix(".\(blocked)")
        }
    }

    private struct BrowserTextFragmentNodeCandidate {
        let startText: String
        let endText: String?
        let centerY: CGFloat
        let isolationScore: CGFloat
    }

    private func smartTextFragmentDirectiveForCurrentFrame() -> String? {
        if let selectedDirective = Self.smartTextFragmentDirective(startText: selectedText, endText: nil) {
            Log.debug(
                "[BrowserLinkOpen] fragment candidate selectedText length=\(selectedText.count) directive=\(selectedDirective)",
                category: .ui
            )
            return selectedDirective
        }

        let candidates = visibleOCRTextFragmentNodeCandidates()
        guard let bestCandidateIndex = Self.bestTextFragmentNodeCandidateIndex(candidates) else {
            Log.debug(
                "[BrowserLinkOpen] fragment candidates empty count=\(candidates.count)",
                category: .ui
            )
            return nil
        }

        let candidate = candidates[bestCandidateIndex]
        let directive = Self.smartTextFragmentDirective(
            startText: candidate.startText,
            endText: candidate.endText
        )
        Log.debug(
            "[BrowserLinkOpen] fragment candidate chosen start=\(candidate.startText) end=\(candidate.endText ?? "<none>") centerY=\(candidate.centerY) isolation=\(candidate.isolationScore) directive=\(String(describing: directive)) candidates=\(candidates.count)",
            category: .ui
        )
        return directive
    }

    private func visibleOCRTextFragmentNodeCandidates() -> [BrowserTextFragmentNodeCandidate] {
        let nodes = isZoomRegionActive ? ocrNodesInZoomRegion : ocrNodes
        guard !nodes.isEmpty else { return [] }

        let orderedNodes = nodes.sorted {
            if abs($0.y - $1.y) > Self.searchHighlightLineTolerance {
                return $0.y < $1.y
            }
            return $0.x < $1.x
        }

        let nodeWords: [(node: OCRNodeWithText, words: [String])] = orderedNodes.compactMap { node in
            guard let visibleText = visibleTextFragmentText(for: node) else {
                return nil
            }

            let words = Self.cleanTextFragmentWords(from: visibleText)
            guard words.count >= 3 else {
                return nil
            }

            return (node: node, words: words)
        }

        guard !nodeWords.isEmpty else { return [] }

        return nodeWords.enumerated().compactMap { index, entry in
            let startText = Self.textFragmentWordSlice(from: entry.words)
            guard !startText.isEmpty else {
                return nil
            }

            let endText = Self.nextTextFragmentEndText(after: index, in: nodeWords)
            return BrowserTextFragmentNodeCandidate(
                startText: startText,
                endText: endText,
                centerY: entry.node.y + (entry.node.height / 2.0),
                isolationScore: isolationScore(for: entry.node, among: orderedNodes)
            )
        }
    }

    private func visibleTextFragmentText(for node: OCRNodeWithText) -> String? {
        let rawText = node.text
        let trimmedFullText = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedFullText.isEmpty else { return nil }

        guard let range = getVisibleCharacterRange(for: node) else {
            return trimmedFullText
        }

        let clampedStart = min(max(range.start, 0), rawText.count)
        let clampedEnd = min(max(range.end, clampedStart), rawText.count)
        guard clampedStart < clampedEnd else { return nil }

        let startIndex = rawText.index(rawText.startIndex, offsetBy: clampedStart)
        let endIndex = rawText.index(rawText.startIndex, offsetBy: clampedEnd)
        let clippedText = String(rawText[startIndex..<endIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
        return clippedText.isEmpty ? nil : clippedText
    }

    private func isolationScore(for target: OCRNodeWithText, among nodes: [OCRNodeWithText]) -> CGFloat {
        let targetCenterY = target.y + (target.height / 2.0)
        let targetMinX = target.x
        let targetMaxX = target.x + target.width

        var nearestGap: CGFloat = 1.0

        for node in nodes where node.id != target.id {
            let nodeCenterY = node.y + (node.height / 2.0)
            guard abs(nodeCenterY - targetCenterY) <= Self.searchHighlightLineTolerance else {
                continue
            }

            let nodeMinX = node.x
            let nodeMaxX = node.x + node.width
            let gap: CGFloat
            if nodeMaxX <= targetMinX {
                gap = targetMinX - nodeMaxX
            } else if nodeMinX >= targetMaxX {
                gap = nodeMinX - targetMaxX
            } else {
                gap = 0
            }

            nearestGap = min(nearestGap, gap)
        }

        return nearestGap
    }

    private static func bestTextFragmentNodeCandidateIndex(_ candidates: [BrowserTextFragmentNodeCandidate]) -> Int? {
        guard !candidates.isEmpty else { return nil }

        var bestIndex: Int?
        var bestScore = -Double.greatestFiniteMagnitude

        for (index, candidate) in candidates.enumerated() {
            let centerPenalty = Double(abs(candidate.centerY - 0.5)) * 120.0
            let combinedText = candidate.startText + (candidate.endText.map { " " + $0 } ?? "")
            let usefulLength = min(Double(combinedText.count), 96.0)
            let shortPenalty = candidate.endText == nil ? 20.0 : 0.0
            let isolationBonus = Double(min(candidate.isolationScore, 0.12)) * 320.0
            let score = usefulLength + isolationBonus - centerPenalty - shortPenalty
            if score > bestScore {
                bestScore = score
                bestIndex = index
            }
        }

        return bestIndex
    }

    private static func smartTextFragmentDirective(startText: String, endText: String?) -> String? {
        guard let normalizedStartText = normalizedTextFragmentComponent(
            startText,
            maxLength: 48,
            minimumLength: 8
        ) else {
            return nil
        }

        let encodedStartText = encodedTextFragmentComponent(normalizedStartText)

        guard let endText,
              let normalizedEndText = normalizedTextFragmentComponent(
                endText,
                maxLength: 48,
                minimumLength: 8
              ) else {
            return ":~:text=" + encodedStartText
        }

        return ":~:text=" + encodedStartText + "," + encodedTextFragmentComponent(normalizedEndText)
    }

    static func appendingSmartTextFragment(to urlString: String, directive: String?) -> String {
        guard let directive,
              !directive.isEmpty,
              var components = URLComponents(string: urlString) else {
            return urlString
        }

        let existingFragment = components.percentEncodedFragment ?? ""
        guard !existingFragment.contains(":~:text=") else {
            return urlString
        }

        components.percentEncodedFragment = existingFragment.isEmpty
            ? directive
            : existingFragment + directive
        return components.string ?? urlString
    }

    private static func normalizedTextFragmentComponent(
        _ text: String?,
        maxLength: Int,
        minimumLength: Int
    ) -> String? {
        guard let text else { return nil }
        let collapsed = text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed.count >= minimumLength else { return nil }
        if collapsed.count <= maxLength {
            return collapsed
        }

        let truncated = String(collapsed.prefix(maxLength))
        let whitespace = CharacterSet.whitespacesAndNewlines

        if let lastWhitespaceIndex = truncated.lastIndex(where: {
            $0.unicodeScalars.allSatisfy(whitespace.contains)
        }) {
            let wordSafe = truncated[..<lastWhitespaceIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            if wordSafe.count >= minimumLength {
                return wordSafe
            }
        }

        return truncated.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func cleanTextFragmentWords(from text: String) -> [String] {
        let collapsed = text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !collapsed.isEmpty else { return [] }

        return collapsed
            .components(separatedBy: .whitespacesAndNewlines)
            .map { token in
                token.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
            }
            .filter { $0.count >= 2 }
    }

    private static func textFragmentWordSlice(from words: [String], count: Int = 3) -> String {
        Array(words.prefix(count)).joined(separator: " ")
    }

    private static func nextTextFragmentEndText(
        after index: Int,
        in entries: [(node: OCRNodeWithText, words: [String])]
    ) -> String? {
        guard index + 1 < entries.count else {
            return nil
        }

        for nextIndex in (index + 1)..<entries.count {
            let endText = textFragmentWordSlice(from: entries[nextIndex].words)
            if !endText.isEmpty {
                return endText
            }
        }

        return nil
    }

    private static func encodedTextFragmentComponent(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: textFragmentAllowedCharacters) ?? text
    }

    private static let textFragmentAllowedCharacters: CharacterSet = {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "#&?=,+-")
        return allowed
    }()

    private static let textFragmentExcludedDomains: [String] = [
        "youtube.com",
        "youtu.be",
        "x.com",
        "twitter.com",
        "facebook.com",
        "instagram.com",
        "tiktok.com"
    ]

    private static func urlContainsTextFragment(_ urlString: String) -> Bool {
        urlString.contains(":~:text=")
    }

    private static func urlContainsYouTubeTimestamp(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString),
              isYouTubeWatchURL(url),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return false
        }
        return components.queryItems?.contains(where: { $0.name.caseInsensitiveCompare("t") == .orderedSame }) == true
    }

    static func inPageURLLinkMetricMetadata(
        url: String,
        linkText: String,
        nodeID: Int
    ) -> String? {
        let payload: [String: Any] = [
            "url": url,
            "linkText": linkText,
            "nodeID": nodeID
        ]

        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let json = String(data: data, encoding: .utf8) else {
            return nil
        }
        return json
    }

    private static func inPageURLLinkText(for match: OCRHyperlinkMatch) -> String {
        let domText = match.domText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !domText.isEmpty {
            return domText
        }
        return match.nodeText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func recordInPageURLLinkMetric(
        metricType: DailyMetricsQueries.MetricType,
        url: String,
        linkText: String,
        nodeID: Int
    ) {
        let metadata = Self.inPageURLLinkMetricMetadata(
            url: url,
            linkText: linkText,
            nodeID: nodeID
        )

        Task {
            try? await coordinator.recordMetricEvent(
                metricType: metricType,
                metadata: metadata
            )
        }
    }

    static func inPageURLHoverMetricKey(
        frameID: FrameID?,
        url: String,
        nodeID: Int
    ) -> String {
        let frameToken = frameID.map { String($0.value) } ?? "none"
        return "\(frameToken)|\(nodeID)|\(url)"
    }

    @discardableResult
    func beginInPageURLHoverTracking(
        url: String,
        nodeID: Int,
        frameID: FrameID?
    ) -> Bool {
        let key = Self.inPageURLHoverMetricKey(
            frameID: frameID,
            url: url,
            nodeID: nodeID
        )
        guard activeInPageURLHoverMetricKey != key else {
            return false
        }
        activeInPageURLHoverMetricKey = key
        return true
    }

    func endInPageURLHoverTracking() {
        activeInPageURLHoverMetricKey = nil
    }

    func updateInPageURLHoverState(_ match: OCRHyperlinkMatch?) {
        guard let match else {
            endInPageURLHoverTracking()
            return
        }

        let resolvedURLString = resolvedHyperlinkURLString(for: match) ?? match.url
        guard beginInPageURLHoverTracking(
            url: resolvedURLString,
            nodeID: match.nodeID,
            frameID: currentFrame?.id
        ) else {
            return
        }

        recordInPageURLLinkMetric(
            metricType: .inPageURLHover,
            url: resolvedURLString,
            linkText: Self.inPageURLLinkText(for: match),
            nodeID: match.nodeID
        )
    }

    func recordInPageURLRightClick(for match: OCRHyperlinkMatch) {
        let resolvedURLString = resolvedHyperlinkURLString(for: match) ?? match.url
        recordInPageURLLinkMetric(
            metricType: .inPageURLRightClick,
            url: resolvedURLString,
            linkText: Self.inPageURLLinkText(for: match),
            nodeID: match.nodeID
        )
    }

    @discardableResult
    public func openHyperlinkMatch(_ match: OCRHyperlinkMatch) -> Bool {
        guard let resolvedURLString = resolvedHyperlinkURLString(for: match),
              let url = URL(string: resolvedURLString) else {
            return false
        }
        let coordinator = self.coordinator

        recordInPageURLLinkMetric(
            metricType: .inPageURLClick,
            url: resolvedURLString,
            linkText: Self.inPageURLLinkText(for: match),
            nodeID: match.nodeID
        )

        guard let browserApplicationURL = Self.hyperlinkBrowserApplicationURL(for: url) else {
            let opened = NSWorkspace.shared.open(url)
            if opened {
                Log.info("[HyperlinkMap] Opened mapped hyperlink via fallback dispatch: \(resolvedURLString)", category: .ui)
                DashboardViewModel.recordBrowserLinkOpened(
                    coordinator: coordinator,
                    source: "in_page_url_hyperlink",
                    url: resolvedURLString,
                    usedTextFragment: false,
                    usedYouTubeTimestamp: false
                )
            } else {
                Log.warning("[HyperlinkMap] Failed to open mapped hyperlink: \(resolvedURLString)", category: .ui)
            }
            return opened
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false

        NSWorkspace.shared.open([url], withApplicationAt: browserApplicationURL, configuration: configuration) { _, error in
            if let error {
                Log.warning(
                    "[HyperlinkMap] Failed to open mapped hyperlink in explicit browser \(browserApplicationURL.path): \(resolvedURLString) | \(error.localizedDescription)",
                    category: .ui
                )
            } else {
                Log.info(
                    "[HyperlinkMap] Opened mapped hyperlink in explicit browser \(browserApplicationURL.path): \(resolvedURLString)",
                    category: .ui
                )
                Task { @MainActor in
                    DashboardViewModel.recordBrowserLinkOpened(
                        coordinator: coordinator,
                        source: "in_page_url_hyperlink",
                        url: resolvedURLString,
                        usedTextFragment: false,
                        usedYouTubeTimestamp: false
                    )
                }
            }
        }
        return true
    }

    public func resolvedHyperlinkURLString(for match: OCRHyperlinkMatch) -> String? {
        let resolvedURLString = Self.resolveStoredHyperlinkURL(
            match.url,
            baseURL: currentFrame?.metadata.browserURL
        )
        guard URL(string: resolvedURLString) != nil else {
            return nil
        }
        return resolvedURLString
    }

    /// Copy a mapped hyperlink to the clipboard using the same URL resolution path as open.
    @discardableResult
    public func copyHyperlinkMatch(_ match: OCRHyperlinkMatch) -> Bool {
        guard let resolvedURLString = resolvedHyperlinkURLString(for: match) else {
            return false
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(resolvedURLString, forType: .string)
        recordInPageURLLinkMetric(
            metricType: .inPageURLCopyLink,
            url: resolvedURLString,
            linkText: Self.inPageURLLinkText(for: match),
            nodeID: match.nodeID
        )
        showToast("Link copied")
        Log.info("[HyperlinkMap] Copied mapped hyperlink: \(resolvedURLString)", category: .ui)
        return true
    }

    private func clearHyperlinkMatches() {
        hyperlinkMappingTask?.cancel()
        hyperlinkMappingTask = nil
        endInPageURLHoverTracking()
        hyperlinkMatches = []
    }

    private func startHyperlinkMapping(
        frame: FrameReference,
        nodes: [OCRNodeWithText],
        expectedGeneration: UInt64 = 0
    ) {
        guard !isInLiveMode else {
            clearHyperlinkMatches()
            return
        }
        let generation = expectedGeneration == 0
            ? currentPresentationWorkGeneration()
            : expectedGeneration
        guard canPublishPresentationResult(
            frameID: frame.id,
            expectedGeneration: generation
        ) else { return }

        guard Self.isInPageURLCollectionEnabled() else {
            clearHyperlinkMatches()
            return
        }

        guard !nodes.isEmpty else {
            clearHyperlinkMatches()
            return
        }

        hyperlinkMappingTask?.cancel()
        hyperlinkMatches = []
        hyperlinkMappingTask = Task { [weak self] in
            guard let self else { return }

            do {
                let storedRows = try await self.coordinator.getFrameInPageURLRows(frameID: frame.id)
                let storedMatches = Self.hyperlinkMatchesFromStoredRows(
                    storedRows,
                    nodes: nodes
                )

                guard !Task.isCancelled else { return }

                await MainActor.run {
                    guard self.canPublishPresentationResult(
                        frameID: frame.id,
                        expectedGeneration: generation
                    ) else { return }
                    self.hyperlinkMatches = storedMatches
                }
            } catch {
                await MainActor.run {
                    guard self.canPublishPresentationResult(
                        frameID: frame.id,
                        expectedGeneration: generation
                    ) else { return }
                    self.hyperlinkMatches = []
                }
                Log.warning("[HyperlinkMap] DOM extraction failed: \(error)", category: .ui)
            }
        }
    }

    nonisolated static func hyperlinkMatchesFromStoredRows(
        _ rows: [AppCoordinator.FrameInPageURLRow],
        nodes: [OCRNodeWithText]
    ) -> [OCRHyperlinkMatch] {
        guard !rows.isEmpty else { return [] }
        var nodesByID: [Int: OCRNodeWithText] = [:]
        nodesByID.reserveCapacity(nodes.count)
        var nodesByNodeOrder: [Int: OCRNodeWithText] = [:]
        nodesByNodeOrder.reserveCapacity(nodes.count)
        var duplicateNodeIDs: [Int] = []
        var loggedDuplicateNodeIDs: Set<Int> = []
        loggedDuplicateNodeIDs.reserveCapacity(min(nodes.count, 8))

        for node in nodes {
            if nodesByID[node.id] == nil {
                nodesByID[node.id] = node
            } else if loggedDuplicateNodeIDs.insert(node.id).inserted {
                duplicateNodeIDs.append(node.id)
            }

            if nodesByNodeOrder[node.nodeOrder] == nil {
                nodesByNodeOrder[node.nodeOrder] = node
            }
        }

        if !duplicateNodeIDs.isEmpty {
            let sampleIDs = duplicateNodeIDs.prefix(3).map(String.init).joined(separator: ", ")
            let frameIDDescription = nodes.first.map { String($0.frameId) } ?? "unknown"
            Log.warning(
                "[HyperlinkMap] Duplicate OCR node IDs for frame \(frameIDDescription); duplicates=\(duplicateNodeIDs.count); sampleIDs=[\(sampleIDs)]. Using first occurrence.",
                category: .ui
            )
        }

        var parsedMatches: [OCRHyperlinkMatch] = []
        parsedMatches.reserveCapacity(rows.count)
        var seenKeys: Set<String> = []
        seenKeys.reserveCapacity(rows.count)

        for row in rows {
            guard let resolvedNode = nodesByID[row.nodeID] ?? nodesByNodeOrder[row.nodeID] else {
                continue
            }
            let x = resolvedNode.x
            let y = resolvedNode.y
            let width = resolvedNode.width
            let height = resolvedNode.height
            guard width > 0, height > 0 else { continue }

            let nodeText = resolvedNode.text
            let highlightEndIndex = max(nodeText.count, 1)
            let key = "\(row.order)|\(row.nodeID)|\(row.url)"
            guard seenKeys.insert(key).inserted else { continue }

            parsedMatches.append(
                OCRHyperlinkMatch(
                    id: key,
                    nodeID: row.nodeID,
                    x: x,
                    y: y,
                    width: width,
                    height: height,
                    url: row.url,
                    nodeText: nodeText,
                    domText: nodeText,
                    highlightStartIndex: 0,
                    highlightEndIndex: highlightEndIndex,
                    confidence: 1.0
                )
            )
        }

        return parsedMatches
    }

    static func resolveStoredHyperlinkURL(_ storedURL: String, baseURL: String?) -> String {
        if let parsed = URL(string: storedURL),
           parsed.scheme != nil {
            return storedURL
        }

        guard let baseURL,
              let base = hostRootURL(from: baseURL),
              let resolved = URL(string: storedURL, relativeTo: base)?.absoluteURL else {
            return storedURL
        }
        return resolved.absoluteString
    }

    static func hyperlinkBrowserApplicationURL(
        for url: URL,
        browserResolver: (URL) -> URL? = { NSWorkspace.shared.urlForApplication(toOpen: $0) }
    ) -> URL? {
        browserResolver(url)
    }

    private static func hostRootURL(from rawURL: String) -> URL? {
        guard let parsed = URL(string: rawURL),
              var components = URLComponents(url: parsed, resolvingAgainstBaseURL: false),
              components.scheme != nil,
              components.host != nil else {
            return nil
        }
        components.percentEncodedPath = "/"
        components.percentEncodedQuery = nil
        components.percentEncodedFragment = nil
        return components.url
    }

    private static func normalizedHost(_ host: String?) -> String {
        guard var host else { return "" }
        host = host.lowercased()
        if host.hasPrefix("www.") {
            return String(host.dropFirst(4))
        }
        return host
    }

    // MARK: - OCR Node Loading and Text Selection

    private func fetchURLBoundingBoxForPresentation(
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

    private func fetchOCRStatusForPresentation(frameID: FrameID) async throws -> OCRProcessingStatus {
#if DEBUG
        if let override = test_frameOverlayLoadHooks.getOCRStatus {
            return try await override(frameID)
        }
#endif
        return try await coordinator.getOCRStatus(frameID: frameID)
    }

    private func fetchAllOCRNodesForPresentation(
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

    /// Set OCR nodes and invalidate the selection cache
    private func setOCRNodes(_ nodes: [OCRNodeWithText]) {
        // Capture previous nodes for diff visualization (only when debug overlay is enabled)
        if showOCRDebugOverlay {
            previousOcrNodes = ocrNodes
        }
        ocrNodes = nodes
        currentNodesVersion += 1
    }

    /// Load all OCR nodes for the current frame
    private func loadOCRNodes(expectedGeneration: UInt64 = 0) {
        // Don't overwrite live OCR results with database results
        guard !isInLiveMode else { return }
        let generation = expectedGeneration == 0
            ? currentPresentationWorkGeneration()
            : expectedGeneration
        guard canPublishPresentationResult(expectedGeneration: generation) else { return }

        guard currentTimelineFrame != nil else {
            setOCRNodes([])
            ocrStatus = .unknown
            ocrStatusPollingTask?.cancel()
            ocrStatusPollingTask = nil
            clearHyperlinkMatches()
            clearTextSelection()
            return
        }

        // Clear previous selection when frame changes
        clearTextSelection()

        // Load OCR nodes asynchronously
        Task {
            await loadOCRNodesAsync(expectedGeneration: generation)
        }
    }

    /// Load OCR nodes and wait for completion (used when we need to await the result)
    private func loadOCRNodesAsync(expectedGeneration: UInt64 = 0) async {
        let generation = expectedGeneration == 0
            ? currentPresentationWorkGeneration()
            : expectedGeneration
        guard canPublishPresentationResult(expectedGeneration: generation) else { return }
        // Cancel any existing polling task
        ocrStatusPollingTask?.cancel()
        ocrStatusPollingTask = nil

        guard let timelineFrame = currentTimelineFrame else {
            setOCRNodes([])
            ocrStatus = .unknown
            clearHyperlinkMatches()
            return
        }

        let frame = timelineFrame.frame

        do {
            // Fetch OCR status and nodes concurrently
            async let statusTask = fetchOCRStatusForPresentation(frameID: frame.id)
            async let nodesTask = fetchAllOCRNodesForPresentation(
                frameID: frame.id,
                source: frame.source
            )

            let (status, nodes) = try await (statusTask, nodesTask)

            if canPublishPresentationResult(
                frameID: frame.id,
                expectedGeneration: generation
            ) {
                // Update OCR status
                ocrStatus = status

                // Start polling if OCR is in progress
                if status.isInProgress {
                    startOCRStatusPolling(for: frame.id, expectedGeneration: generation)
                }

                // Filter out nodes with invalid coordinates (multi-monitor captures)
                // Valid normalized coordinates should be in range [0.0, 1.0]
                let filteredNodes = nodes.filter { node in
                    node.x >= 0.0 && node.x <= 1.0 &&
                    node.y >= 0.0 && node.y <= 1.0 &&
                    (node.x + node.width) <= 1.0 &&
                    (node.y + node.height) <= 1.0
                }

                setOCRNodes(filteredNodes)
                startHyperlinkMapping(
                    frame: frame,
                    nodes: filteredNodes,
                    expectedGeneration: generation
                )
            }
        } catch {
            Log.error("[SimpleTimelineViewModel] Failed to load OCR nodes: \(error)", category: .app)
            if canPublishPresentationResult(
                frameID: frame.id,
                expectedGeneration: generation
            ) {
                setOCRNodes([])
                ocrStatus = .unknown
                clearHyperlinkMatches()
            }
        }
    }

    /// Start polling for OCR status updates
    /// Polls every 500ms until OCR completes or frame changes
    private func startOCRStatusPolling(
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
        ocrStatusPollingTask?.cancel()

        ocrStatusPollingTask = Task { [weak self] in
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

                        self.ocrStatus = status

                        // If completed, also reload the OCR nodes
                        if !status.isInProgress {
                            Task {
                                await self.reloadOCRNodesOnly(
                                    for: frameID,
                                    expectedGeneration: generation
                                )
                            }
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

    /// Reload only OCR nodes without fetching status (used after OCR completes)
    private func reloadOCRNodesOnly(
        for frameID: FrameID,
        expectedGeneration: UInt64 = 0
    ) async {
        let generation = expectedGeneration == 0
            ? currentPresentationWorkGeneration()
            : expectedGeneration
        guard let frame = currentTimelineFrame?.frame,
              frame.id == frameID,
              canPublishPresentationResult(
                frameID: frameID,
                expectedGeneration: generation
              ) else { return }

        do {
            let nodes = try await fetchAllOCRNodesForPresentation(
                frameID: frame.id,
                source: frame.source
            )

            // Only update if still on the same frame
            guard canPublishPresentationResult(
                frameID: frameID,
                expectedGeneration: generation
            ) else { return }

            let filteredNodes = nodes.filter { node in
                node.x >= 0.0 && node.x <= 1.0 &&
                node.y >= 0.0 && node.y <= 1.0 &&
                (node.x + node.width) <= 1.0 &&
                (node.y + node.height) <= 1.0
            }

            setOCRNodes(filteredNodes)
            startHyperlinkMapping(
                frame: frame,
                nodes: filteredNodes,
                expectedGeneration: generation
            )
        } catch {
            Log.error("[OCR-POLL] Failed to reload OCR nodes: \(error)", category: .ui)
            guard canPublishPresentationResult(
                frameID: frameID,
                expectedGeneration: generation
            ) else { return }
            clearHyperlinkMatches()
        }
    }

    /// Select all text (Cmd+A) - respects zoom region if active
    public func selectAllText() {
        // Use nodes in zoom region if active, otherwise all nodes
        let nodesToSelect = isZoomRegionActive ? ocrNodesInZoomRegion : ocrNodes
        guard !nodesToSelect.isEmpty else { return }

        activeDragSelectionMode = .character
        boxSelectedNodeIDs.removeAll()
        isAllTextSelected = true
        // Set selection to span all nodes - use same sorting as getSelectionRange (reading order)
        let sortedNodes = nodesToSelect.sorted { node1, node2 in
            let yTolerance: CGFloat = 0.02
            if abs(node1.y - node2.y) > yTolerance {
                return node1.y < node2.y
            }
            return node1.x < node2.x
        }
        if let first = sortedNodes.first, let last = sortedNodes.last {
            selectionStart = (nodeID: first.id, charIndex: 0)
            selectionEnd = (nodeID: last.id, charIndex: last.text.count)
        }
    }

    /// Clear text selection
    public func clearTextSelection() {
        selectionStart = nil
        selectionEnd = nil
        isAllTextSelected = false
        boxSelectedNodeIDs.removeAll()
        activeDragSelectionMode = .character
        dragStartPoint = nil
        dragEndPoint = nil
    }

    /// Start drag selection at a point (normalized coordinates)
    public func startDragSelection(at point: CGPoint, mode: DragSelectionMode = .character) {
        dragStartPoint = point
        dragEndPoint = point
        isAllTextSelected = false
        activeDragSelectionMode = mode

        switch mode {
        case .character:
            boxSelectedNodeIDs.removeAll()
            // Find the character position at this point.
            if let position = findCharacterPosition(at: point) {
                selectionStart = position
                selectionEnd = position
            } else {
                selectionStart = nil
                selectionEnd = nil
            }
        case .box:
            selectionStart = nil
            selectionEnd = nil
            updateBoxSelectionFromDragRect()
        }
    }

    /// Update drag selection to a point (normalized coordinates)
    public func updateDragSelection(to point: CGPoint, mode: DragSelectionMode? = nil) {
        if let mode {
            activeDragSelectionMode = mode
        }
        dragEndPoint = point

        switch activeDragSelectionMode {
        case .character:
            // Find the character position at the current point.
            if let position = findCharacterPosition(at: point) {
                selectionEnd = position
            }
        case .box:
            updateBoxSelectionFromDragRect()
        }
    }

    /// End drag selection
    public func endDragSelection() {
        // Keep selection but clear drag points
        // Keep drag points - they're used for rectangle-based column filtering
        // They will be cleared when clearTextSelection() is called
    }

    /// Select the word at the given point (for double-click)
    public func selectWordAt(point: CGPoint) {
        guard let (nodeID, charIndex) = findCharacterPosition(at: point) else { return }
        guard let node = ocrNodes.first(where: { $0.id == nodeID }) else { return }

        let text = node.text
        guard !text.isEmpty else { return }

        // Clamp charIndex to valid range
        let clampedIndex = max(0, min(charIndex, text.count - 1))

        // Find word boundaries
        let (wordStart, wordEnd) = findWordBoundaries(in: text, around: clampedIndex)

        activeDragSelectionMode = .character
        boxSelectedNodeIDs.removeAll()
        isAllTextSelected = false
        selectionStart = (nodeID: nodeID, charIndex: wordStart)
        selectionEnd = (nodeID: nodeID, charIndex: wordEnd)
    }

    /// Select all text in the node at the given point (for triple-click)
    public func selectNodeAt(point: CGPoint) {
        guard let (nodeID, _) = findCharacterPosition(at: point) else { return }
        guard let node = ocrNodes.first(where: { $0.id == nodeID }) else { return }

        // Select the entire node's text
        activeDragSelectionMode = .character
        boxSelectedNodeIDs.removeAll()
        isAllTextSelected = false
        selectionStart = (nodeID: nodeID, charIndex: 0)
        selectionEnd = (nodeID: nodeID, charIndex: node.text.count)
    }

    /// Update Cmd+drag selection to include every node intersecting the current drag box.
    private func updateBoxSelectionFromDragRect() {
        guard let start = dragStartPoint, let end = dragEndPoint else {
            boxSelectedNodeIDs.removeAll()
            return
        }

        let rectMinX = min(start.x, end.x)
        let rectMaxX = max(start.x, end.x)
        let rectMinY = min(start.y, end.y)
        let rectMaxY = max(start.y, end.y)
        let dragRect = CGRect(
            x: rectMinX,
            y: rectMinY,
            width: rectMaxX - rectMinX,
            height: rectMaxY - rectMinY
        )

        let nodesToCheck = isZoomRegionActive ? ocrNodesInZoomRegion : ocrNodes
        boxSelectedNodeIDs = Set(
            nodesToCheck.compactMap { node in
                let nodeRect = CGRect(x: node.x, y: node.y, width: node.width, height: node.height)
                // Inclusive overlap check so edge-touching nodes are selected.
                let intersects =
                    nodeRect.maxX >= dragRect.minX &&
                    nodeRect.minX <= dragRect.maxX &&
                    nodeRect.maxY >= dragRect.minY &&
                    nodeRect.minY <= dragRect.maxY
                return intersects ? node.id : nil
            }
        )
    }

    /// Find word boundaries around a character index
    private func findWordBoundaries(in text: String, around index: Int) -> (start: Int, end: Int) {
        guard !text.isEmpty else { return (0, 0) }

        let chars = Array(text)
        let clampedIndex = max(0, min(index, chars.count - 1))

        // Define word characters (alphanumeric and some punctuation that's part of words)
        func isWordChar(_ char: Character) -> Bool {
            char.isLetter || char.isNumber || char == "_" || char == "-"
        }

        // Find start of word (scan backwards)
        var wordStart = clampedIndex
        while wordStart > 0 && isWordChar(chars[wordStart - 1]) {
            wordStart -= 1
        }

        // Find end of word (scan forwards)
        var wordEnd = clampedIndex
        while wordEnd < chars.count && isWordChar(chars[wordEnd]) {
            wordEnd += 1
        }

        // If we didn't find a word (clicked on whitespace/punctuation), select just that character
        if wordStart == wordEnd {
            wordEnd = min(wordStart + 1, chars.count)
        }

        return (start: wordStart, end: wordEnd)
    }

    // MARK: - Text Selection Hint Banner Methods

    /// Show the text selection hint banner once per drag session
    /// Call this during drag updates - it will only show the banner the first time per drag
    public func showTextSelectionHintBannerOnce() {
        guard !hasShownHintThisDrag else { return }
        hasShownHintThisDrag = true
        showTextSelectionHintBanner()
    }

    /// Reset the hint banner state (call when drag ends)
    public func resetTextSelectionHintState() {
        hasShownHintThisDrag = false
    }

    /// Show the text selection hint banner with auto-dismiss after 5 seconds
    public func showTextSelectionHintBanner() {
        // Cancel any existing timer
        textSelectionHintTimer?.invalidate()

        // Show the banner
        showTextSelectionHint = true

        // Auto-dismiss after 5 seconds
        textSelectionHintTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                self?.dismissTextSelectionHint()
            }
        }
    }

    /// Dismiss the text selection hint banner
    public func dismissTextSelectionHint() {
        textSelectionHintTimer?.invalidate()
        textSelectionHintTimer = nil
        withAnimation(.easeOut(duration: 0.2)) {
            showTextSelectionHint = false
        }
    }

    // MARK: - Scroll Orientation Hint Methods

    /// Show the scroll orientation hint banner with auto-dismiss after 8 seconds
    public func showScrollOrientationHint(current: String) {
        scrollOrientationHintCurrentOrientation = current
        scrollOrientationHintTimer?.invalidate()

        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            showScrollOrientationHintBanner = true
        }

        scrollOrientationHintTimer = Timer.scheduledTimer(withTimeInterval: 8.0, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                self?.dismissScrollOrientationHint()
            }
        }
    }

    /// Dismiss the scroll orientation hint banner
    public func dismissScrollOrientationHint() {
        scrollOrientationHintTimer?.invalidate()
        scrollOrientationHintTimer = nil
        withAnimation(.easeOut(duration: 0.2)) {
            showScrollOrientationHintBanner = false
        }
    }

    /// Open settings and guide the user to timeline scroll orientation controls.
    public func openTimelineScrollOrientationSettings() {
        NotificationCenter.default.post(name: .openSettings, object: nil)
        NotificationCenter.default.post(name: .openSettingsTimelineScrollOrientation, object: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            NotificationCenter.default.post(name: .openSettingsTimelineScrollOrientation, object: nil)
        }
        dismissScrollOrientationHint()
    }

    // MARK: - Zoom Region Methods (Shift+Drag)

    private var zoomUpdateCount = 0

    private func startZoomEntryTransition(for sessionID: Int) {
        // Ignore stale callbacks from older drag sessions.
        guard sessionID == activeShiftDragSessionID else { return }

        // Keep the drag preview visible until we can start transition,
        // then clear drag state at the exact handoff moment.
        isDraggingZoomRegion = false
        zoomRegionDragStart = nil
        zoomRegionDragEnd = nil

        isZoomTransitioning = true
        zoomTransitionProgress = 0
        zoomTransitionBlurOpacity = 0

        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            zoomTransitionProgress = 1.0
            zoomTransitionBlurOpacity = 1.0
        }

        // After animation completes, switch to final zoom state
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            guard let self else { return }
            guard sessionID == self.activeShiftDragSessionID else { return }
            self.isZoomRegionActive = true
            self.zoomTransitionStartRect = nil
            // Disable transition on next run loop to ensure smooth handoff
            DispatchQueue.main.async {
                guard sessionID == self.activeShiftDragSessionID else { return }
                self.isZoomTransitioning = false
            }
        }
    }

    /// Start creating a zoom region (Shift+Drag)
    public func startZoomRegion(at point: CGPoint) {
        zoomUpdateCount = 0
        isDraggingZoomRegion = true
        zoomRegionDragStart = point
        zoomRegionDragEnd = point
        shiftDragDisplaySnapshot = nil
        shiftDragDisplaySnapshotFrameID = nil

        shiftDragSessionCounter += 1
        activeShiftDragSessionID = shiftDragSessionCounter
        shiftDragStartFrameID = currentFrame?.id.value
        shiftDragStartVideoInfo = currentVideoInfo

        // Clear any existing text selection when starting zoom
        clearTextSelection()
    }

    /// Update zoom region drag
    public func updateZoomRegion(to point: CGPoint) {
        zoomUpdateCount += 1
        zoomRegionDragEnd = point
    }

    /// Finalize zoom region from drag - triggers animation to centered view
    public func endZoomRegion() {

        guard let start = zoomRegionDragStart, let end = zoomRegionDragEnd else {
            isDraggingZoomRegion = false
            return
        }

        // Calculate the rectangle from drag points
        let minX = min(start.x, end.x)
        let minY = min(start.y, end.y)
        let maxX = max(start.x, end.x)
        let maxY = max(start.y, end.y)

        let width = maxX - minX
        let height = maxY - minY

        let sessionID = activeShiftDragSessionID
        let startFrameIDValue = shiftDragStartFrameID
        let startVideoInfoValue = shiftDragStartVideoInfo
        let endFrameIDValue = currentFrame?.id.value
        let endVideoInfoValue = currentVideoInfo

        // Only create zoom region if it's large enough (at least 1% of screen)
        guard width > 0.01 && height > 0.01 else {
            isDraggingZoomRegion = false
            zoomRegionDragStart = nil
            zoomRegionDragEnd = nil
            shiftDragStartFrameID = nil
            shiftDragStartVideoInfo = nil
            return
        }

        let finalRect = CGRect(x: minX, y: minY, width: width, height: height)

        // Record shift+drag zoom region metric
        if let screenSize = NSScreen.main?.frame.size {
            let absoluteRect = CGRect(
                x: finalRect.origin.x * screenSize.width,
                y: finalRect.origin.y * screenSize.height,
                width: finalRect.width * screenSize.width,
                height: finalRect.height * screenSize.height
            )
            DashboardViewModel.recordShiftDragZoom(coordinator: coordinator, region: absoluteRect, screenSize: screenSize)
        }

        // Store the starting rect for animation
        zoomTransitionStartRect = finalRect
        zoomRegion = finalRect

        let probeVideoInfo = endVideoInfoValue ?? startVideoInfoValue
        let probeFrameID = endFrameIDValue ?? startFrameIDValue
        loadShiftDragDisplaySnapshot(
            frameID: probeFrameID,
            videoInfo: probeVideoInfo
        ) { [weak self] in
            self?.startZoomEntryTransition(for: sessionID)
        }
        shiftDragStartFrameID = nil
        shiftDragStartVideoInfo = nil
    }

    /// Loads a snapshot for the Shift+Drag zoom display from AVAssetImageGenerator.
    private func loadShiftDragDisplaySnapshot(
        frameID: Int64?,
        videoInfo: FrameVideoInfo?,
        completion: (() -> Void)? = nil
    ) {
        shiftDragDisplayRequestID += 1
        let requestID = shiftDragDisplayRequestID

        if isInLiveMode {
            shiftDragDisplaySnapshot = liveScreenshot
            shiftDragDisplaySnapshotFrameID = frameID
            completion?()
            return
        }

        guard let videoInfo else {
            completion?()
            return
        }

        guard let url = resolveVideoURLForShiftDragProbe(videoInfo: videoInfo) else {
            completion?()
            return
        }

        let requestedTime = videoInfo.frameTimeCMTime

        let asset = AVURLAsset(url: url)
        let imageGenerator = AVAssetImageGenerator(asset: asset)
        imageGenerator.appliesPreferredTrackTransform = true
        imageGenerator.requestedTimeToleranceBefore = .zero
        imageGenerator.requestedTimeToleranceAfter = .zero

        imageGenerator.generateCGImagesAsynchronously(forTimes: [NSValue(time: requestedTime)]) { _, cgImage, _, _, _ in
            DispatchQueue.main.async {
                guard requestID == self.shiftDragDisplayRequestID else {
                    return
                }

                if let cgImage = cgImage {
                    self.shiftDragDisplaySnapshot = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                    self.shiftDragDisplaySnapshotFrameID = frameID
                } else {
                    self.shiftDragDisplaySnapshot = nil
                    self.shiftDragDisplaySnapshotFrameID = nil
                }
                completion?()
            }
        }
    }

    private func resolveVideoURLForShiftDragProbe(videoInfo: FrameVideoInfo) -> URL? {
        var actualVideoPath = videoInfo.videoPath
        if !FileManager.default.fileExists(atPath: actualVideoPath) {
            let pathWithExtension = actualVideoPath + ".mp4"
            if FileManager.default.fileExists(atPath: pathWithExtension) {
                actualVideoPath = pathWithExtension
            } else {
                return nil
            }
        }

        if actualVideoPath.hasSuffix(".mp4") {
            return URL(fileURLWithPath: actualVideoPath)
        }

        let tempDir = FileManager.default.temporaryDirectory
        let fileName = (actualVideoPath as NSString).lastPathComponent
        let symlinkPath = tempDir.appendingPathComponent("\(fileName).mp4").path

        if !FileManager.default.fileExists(atPath: symlinkPath) {
            do {
                try FileManager.default.createSymbolicLink(atPath: symlinkPath, withDestinationPath: actualVideoPath)
            } catch {
                return nil
            }
        }

        return URL(fileURLWithPath: symlinkPath)
    }

    /// Exit zoom region mode with reverse animation
    public func exitZoomRegion() {
        // If already exiting or no zoom region, just clear state
        guard !isZoomExitTransitioning, zoomRegion != nil else {
            clearZoomRegionState()
            return
        }


        // Clear text selection highlight before starting animation
        clearTextSelection()

        // Start exit transition
        isZoomExitTransitioning = true
        isZoomRegionActive = false

        // After animation completes, clear all zoom state
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.clearZoomRegionState()
        }
    }

    /// Clear all zoom region state (called after exit animation completes)
    private func clearZoomRegionState() {
        isZoomRegionActive = false
        isZoomExitTransitioning = false
        isZoomTransitioning = false
        zoomRegion = nil
        zoomTransitionStartRect = nil
        isDraggingZoomRegion = false
        zoomRegionDragStart = nil
        zoomRegionDragEnd = nil
        shiftDragDisplaySnapshot = nil
        shiftDragDisplaySnapshotFrameID = nil
        // Also clear text selection
        clearTextSelection()
    }

    /// Cancel an in-progress zoom region drag (e.g., when user presses Escape while dragging)
    public func cancelZoomRegionDrag() {
        isDraggingZoomRegion = false
        zoomRegionDragStart = nil
        zoomRegionDragEnd = nil
    }

    /// Get OCR nodes filtered to zoom region (for Cmd+A within zoom)
    public var ocrNodesInZoomRegion: [OCRNodeWithText] {
        guard let region = zoomRegion, isZoomRegionActive else {
            return ocrNodes
        }

        return ocrNodes.filter { node in
            // Check if node overlaps with the zoom region (at least partially visible)
            let nodeRight = node.x + node.width
            let nodeBottom = node.y + node.height
            let regionRight = region.origin.x + region.width
            let regionBottom = region.origin.y + region.height

            return !(nodeRight < region.origin.x || node.x > regionRight ||
                     nodeBottom < region.origin.y || node.y > regionBottom)
        }
    }

    /// Get the visible character range for a node within the current zoom region
    /// Returns the start and end character indices that are visible, or nil if fully visible
    public func getVisibleCharacterRange(for node: OCRNodeWithText) -> (start: Int, end: Int)? {
        guard let region = zoomRegion, isZoomRegionActive else {
            return nil // No clipping needed
        }

        let nodeRight = node.x + node.width
        let regionRight = region.origin.x + region.width

        // Check if node needs horizontal clipping
        let needsLeftClip = node.x < region.origin.x
        let needsRightClip = nodeRight > regionRight

        guard needsLeftClip || needsRightClip else {
            return nil // Fully visible
        }

        let textLength = node.text.count
        guard textLength > 0, node.width > 0 else { return nil }

        // Calculate visible portion based on horizontal clipping
        let clippedX = max(node.x, region.origin.x)
        let clippedRight = min(nodeRight, regionRight)

        let visibleStartFraction = (clippedX - node.x) / node.width
        let visibleEndFraction = (clippedRight - node.x) / node.width

        let visibleStartChar = Int(visibleStartFraction * CGFloat(textLength))
        let visibleEndChar = Int(visibleEndFraction * CGFloat(textLength))

        return (start: max(0, visibleStartChar), end: min(textLength, visibleEndChar))
    }

    /// Find the character position within zoom region only
    /// Uses the same reading-order-aware selection and padding tolerance as normal text selection
    private func findCharacterPositionInZoomRegion(at point: CGPoint) -> (nodeID: Int, charIndex: Int)? {
        let nodesInRegion = ocrNodesInZoomRegion
        let yTolerance: CGFloat = 0.02  // ~2% of screen height for same-line detection
        // Padding in normalized coordinates (~1% of screen) to make selection easier
        let hitPadding: CGFloat = 0.01

        // Sort nodes by reading order (top to bottom, left to right)
        let sortedNodes = nodesInRegion.sorted { node1, node2 in
            if abs(node1.y - node2.y) > yTolerance {
                return node1.y < node2.y
            }
            return node1.x < node2.x
        }

        // First, check if point is inside any node (exact hit)
        for node in sortedNodes {
            if point.x >= node.x && point.x <= node.x + node.width &&
               point.y >= node.y && point.y <= node.y + node.height {
                // Point is inside this node - calculate character position
                let relativeX = (point.x - node.x) / node.width
                let charIndex = Int(relativeX * CGFloat(node.text.count))
                let clampedIndex = max(0, min(node.text.count, charIndex))
                return (nodeID: node.id, charIndex: clampedIndex)
            }
        }

        // Second, check if point is within padding distance of any node (expanded hit area)
        for node in sortedNodes {
            let paddedMinX = node.x - hitPadding
            let paddedMaxX = node.x + node.width + hitPadding
            let paddedMinY = node.y - hitPadding
            let paddedMaxY = node.y + node.height + hitPadding

            if point.x >= paddedMinX && point.x <= paddedMaxX &&
               point.y >= paddedMinY && point.y <= paddedMaxY {
                // Point is near this node - calculate character position
                let clampedX = max(node.x, min(node.x + node.width, point.x))
                let relativeX = (clampedX - node.x) / node.width
                let charIndex = Int(relativeX * CGFloat(node.text.count))
                let clampedIndex = max(0, min(node.text.count, charIndex))
                return (nodeID: node.id, charIndex: clampedIndex)
            }
        }

        // Point is not inside or near any node - find the best node for reading order selection
        // Group nodes by row (using Y tolerance)
        var rows: [[OCRNodeWithText]] = []
        var currentRow: [OCRNodeWithText] = []
        var currentRowY: CGFloat?

        for node in sortedNodes {
            if let rowY = currentRowY, abs(node.y - rowY) <= yTolerance {
                currentRow.append(node)
            } else {
                if !currentRow.isEmpty {
                    rows.append(currentRow)
                }
                currentRow = [node]
                currentRowY = node.y
            }
        }
        if !currentRow.isEmpty {
            rows.append(currentRow)
        }

        guard !rows.isEmpty else { return nil }

        // Find which row the point is closest to (by Y)
        var bestRowIndex = 0
        var bestRowDistance: CGFloat = .infinity

        for (index, row) in rows.enumerated() {
            guard let firstNode = row.first else { continue }
            let rowMinY = row.map { $0.y }.min() ?? firstNode.y
            let rowMaxY = row.map { $0.y + $0.height }.max() ?? (firstNode.y + firstNode.height)
            let rowCenterY = (rowMinY + rowMaxY) / 2

            let distance = abs(point.y - rowCenterY)
            if distance < bestRowDistance {
                bestRowDistance = distance
                bestRowIndex = index
            }
        }

        let targetRow = rows[bestRowIndex]

        // Within this row, find the node based on X position
        let rowMinX = targetRow.map { $0.x }.min() ?? 0
        let rowMaxX = targetRow.map { $0.x + $0.width }.max() ?? 1

        if point.x <= rowMinX {
            // Point is to the left - select start of first node in row
            if let firstNode = targetRow.first {
                return (nodeID: firstNode.id, charIndex: 0)
            }
        } else if point.x >= rowMaxX {
            // Point is to the right - select end of last node in row
            if let lastNode = targetRow.last {
                return (nodeID: lastNode.id, charIndex: lastNode.text.count)
            }
        } else {
            // Point is within the row's X range - find closest node edge
            var bestNode: OCRNodeWithText?
            var bestCharIndex = 0
            var bestDistance: CGFloat = .infinity

            for node in targetRow {
                let nodeStart = node.x
                let nodeEnd = node.x + node.width

                let distToStart = abs(point.x - nodeStart)
                if distToStart < bestDistance {
                    bestDistance = distToStart
                    bestNode = node
                    bestCharIndex = 0
                }

                let distToEnd = abs(point.x - nodeEnd)
                if distToEnd < bestDistance {
                    bestDistance = distToEnd
                    bestNode = node
                    bestCharIndex = node.text.count
                }

                // If point is within node bounds, calculate precise character
                if point.x >= nodeStart && point.x <= nodeEnd {
                    let relativeX = (point.x - node.x) / node.width
                    let charIndex = Int(relativeX * CGFloat(node.text.count))
                    return (nodeID: node.id, charIndex: max(0, min(node.text.count, charIndex)))
                }
            }

            if let node = bestNode {
                return (nodeID: node.id, charIndex: bestCharIndex)
            }
        }

        // Fallback: return first node
        if let firstNode = sortedNodes.first {
            return (nodeID: firstNode.id, charIndex: 0)
        }

        return nil
    }

    /// Find the character position (node ID, char index) closest to a normalized point
    /// Uses reading-order-aware selection: when point is not inside any node,
    /// finds the best node based on reading position (row then column).
    /// Includes padding tolerance to make selection easier when starting slightly outside nodes.
    private func findCharacterPosition(at point: CGPoint) -> (nodeID: Int, charIndex: Int)? {
        let yTolerance: CGFloat = 0.02  // ~2% of screen height for same-line detection
        // Padding in normalized coordinates (~1% of screen) to make selection easier
        let hitPadding: CGFloat = 0.01

        // Sort nodes by reading order (top to bottom, left to right)
        let sortedNodes = ocrNodes.sorted { node1, node2 in
            if abs(node1.y - node2.y) > yTolerance {
                return node1.y < node2.y
            }
            return node1.x < node2.x
        }

        // First, check if point is inside any node (exact hit)
        for node in sortedNodes {
            if point.x >= node.x && point.x <= node.x + node.width &&
               point.y >= node.y && point.y <= node.y + node.height {
                // Point is inside this node - calculate character position
                let relativeX = (point.x - node.x) / node.width
                let charIndex = Int(relativeX * CGFloat(node.text.count))
                let clampedIndex = max(0, min(node.text.count, charIndex))
                return (nodeID: node.id, charIndex: clampedIndex)
            }
        }

        // Second, check if point is within padding distance of any node (expanded hit area)
        for node in sortedNodes {
            let paddedMinX = node.x - hitPadding
            let paddedMaxX = node.x + node.width + hitPadding
            let paddedMinY = node.y - hitPadding
            let paddedMaxY = node.y + node.height + hitPadding

            if point.x >= paddedMinX && point.x <= paddedMaxX &&
               point.y >= paddedMinY && point.y <= paddedMaxY {
                // Point is near this node - calculate character position
                // Clamp the relative X to the actual node bounds
                let clampedX = max(node.x, min(node.x + node.width, point.x))
                let relativeX = (clampedX - node.x) / node.width
                let charIndex = Int(relativeX * CGFloat(node.text.count))
                let clampedIndex = max(0, min(node.text.count, charIndex))
                return (nodeID: node.id, charIndex: clampedIndex)
            }
        }

        // Point is not inside or near any node - find the best node for reading order selection
        // Strategy: Find which "row" the point is on, then find the appropriate node

        // Group nodes by row (using Y tolerance)
        var rows: [[OCRNodeWithText]] = []
        var currentRow: [OCRNodeWithText] = []
        var currentRowY: CGFloat?

        for node in sortedNodes {
            if let rowY = currentRowY, abs(node.y - rowY) <= yTolerance {
                // Same row
                currentRow.append(node)
            } else {
                // New row
                if !currentRow.isEmpty {
                    rows.append(currentRow)
                }
                currentRow = [node]
                currentRowY = node.y
            }
        }
        if !currentRow.isEmpty {
            rows.append(currentRow)
        }

        guard !rows.isEmpty else { return nil }

        // Find which row the point is closest to (by Y)
        var bestRowIndex = 0
        var bestRowDistance: CGFloat = .infinity

        for (index, row) in rows.enumerated() {
            guard let firstNode = row.first else { continue }
            // Use the Y center of the row
            let rowMinY = row.map { $0.y }.min() ?? firstNode.y
            let rowMaxY = row.map { $0.y + $0.height }.max() ?? (firstNode.y + firstNode.height)
            let rowCenterY = (rowMinY + rowMaxY) / 2

            let distance = abs(point.y - rowCenterY)
            if distance < bestRowDistance {
                bestRowDistance = distance
                bestRowIndex = index
            }
        }

        let targetRow = rows[bestRowIndex]

        // Within this row, find the node based on X position
        // If point is to the left of all nodes, select start of first node
        // If point is to the right of all nodes, select end of last node
        // If point is between nodes, select the closer edge

        let rowMinX = targetRow.map { $0.x }.min() ?? 0
        let rowMaxX = targetRow.map { $0.x + $0.width }.max() ?? 1

        if point.x <= rowMinX {
            // Point is to the left - select start of first node in row
            if let firstNode = targetRow.first {
                return (nodeID: firstNode.id, charIndex: 0)
            }
        } else if point.x >= rowMaxX {
            // Point is to the right - select end of last node in row
            if let lastNode = targetRow.last {
                return (nodeID: lastNode.id, charIndex: lastNode.text.count)
            }
        } else {
            // Point is within the row's X range - find closest node edge
            var bestNode: OCRNodeWithText?
            var bestCharIndex = 0
            var bestDistance: CGFloat = .infinity

            for node in targetRow {
                let nodeStart = node.x
                let nodeEnd = node.x + node.width

                // Distance to start of node
                let distToStart = abs(point.x - nodeStart)
                if distToStart < bestDistance {
                    bestDistance = distToStart
                    bestNode = node
                    bestCharIndex = 0
                }

                // Distance to end of node
                let distToEnd = abs(point.x - nodeEnd)
                if distToEnd < bestDistance {
                    bestDistance = distToEnd
                    bestNode = node
                    bestCharIndex = node.text.count
                }

                // If point is within node bounds, calculate precise character
                if point.x >= nodeStart && point.x <= nodeEnd {
                    let relativeX = (point.x - node.x) / node.width
                    let charIndex = Int(relativeX * CGFloat(node.text.count))
                    return (nodeID: node.id, charIndex: max(0, min(node.text.count, charIndex)))
                }
            }

            if let node = bestNode {
                return (nodeID: node.id, charIndex: bestCharIndex)
            }
        }

        // Fallback: return first node
        if let firstNode = sortedNodes.first {
            return (nodeID: firstNode.id, charIndex: 0)
        }

        return nil
    }

    /// Get the selection range for a specific node (returns nil if node not in selection)
    /// Uses reading order within the drag rectangle's X bounds - only nodes that overlap
    /// horizontally with the selection area are considered for reading order.
    public func getSelectionRange(for nodeID: Int) -> (start: Int, end: Int)? {
        if !boxSelectedNodeIDs.isEmpty {
            guard boxSelectedNodeIDs.contains(nodeID),
                  let node = ocrNodes.first(where: { $0.id == nodeID }) else {
                return nil
            }

            var rangeStart = 0
            var rangeEnd = node.text.count

            if let visibleRange = getVisibleCharacterRange(for: node) {
                rangeStart = max(rangeStart, visibleRange.start)
                rangeEnd = min(rangeEnd, visibleRange.end)
                if rangeEnd <= rangeStart {
                    return nil
                }
            }

            return (start: rangeStart, end: rangeEnd)
        }

        guard let start = selectionStart, let end = selectionEnd else { return nil }
        guard let dragStart = dragStartPoint, let dragEnd = dragEndPoint else {
            // Fallback for programmatic selection (Cmd+A, double-click, triple-click)
            return getSelectionRangeFullScreen(for: nodeID)
        }

        // Build the drag rectangle's X bounds
        let rectMinX = min(dragStart.x, dragEnd.x)
        let rectMaxX = max(dragStart.x, dragEnd.x)

        // Filter nodes to only those that overlap with the drag rectangle's X range
        let nodesInRect = ocrNodes.filter { node in
            let nodeMinX = node.x
            let nodeMaxX = node.x + node.width
            return nodeMaxX > rectMinX && nodeMinX < rectMaxX
        }

        // Sort filtered nodes by reading order (top to bottom, left to right)
        let sortedNodes = nodesInRect.sorted { node1, node2 in
            let yTolerance: CGFloat = 0.02
            if abs(node1.y - node2.y) > yTolerance {
                return node1.y < node2.y
            }
            return node1.x < node2.x
        }

        // Find indices of start and end nodes in sorted order
        guard let startNodeIndex = sortedNodes.firstIndex(where: { $0.id == start.nodeID }),
              let endNodeIndex = sortedNodes.firstIndex(where: { $0.id == end.nodeID }),
              let thisNodeIndex = sortedNodes.firstIndex(where: { $0.id == nodeID }) else {
            return nil
        }

        // Normalize so startIndex <= endIndex
        let (normalizedStartNodeIndex, normalizedEndNodeIndex, normalizedStartChar, normalizedEndChar): (Int, Int, Int, Int)
        if startNodeIndex <= endNodeIndex {
            normalizedStartNodeIndex = startNodeIndex
            normalizedEndNodeIndex = endNodeIndex
            normalizedStartChar = start.charIndex
            normalizedEndChar = end.charIndex
        } else {
            normalizedStartNodeIndex = endNodeIndex
            normalizedEndNodeIndex = startNodeIndex
            normalizedStartChar = end.charIndex
            normalizedEndChar = start.charIndex
        }

        // Check if this node is within the selection range
        guard thisNodeIndex >= normalizedStartNodeIndex && thisNodeIndex <= normalizedEndNodeIndex else {
            return nil
        }

        let node = sortedNodes[thisNodeIndex]
        let textLength = node.text.count

        var rangeStart: Int
        var rangeEnd: Int

        if thisNodeIndex == normalizedStartNodeIndex && thisNodeIndex == normalizedEndNodeIndex {
            // Selection is entirely within this node
            rangeStart = min(normalizedStartChar, normalizedEndChar)
            rangeEnd = max(normalizedStartChar, normalizedEndChar)
        } else if thisNodeIndex == normalizedStartNodeIndex {
            // This is the start node - select from start char to end
            rangeStart = normalizedStartChar
            rangeEnd = textLength
        } else if thisNodeIndex == normalizedEndNodeIndex {
            // This is the end node - select from beginning to end char
            rangeStart = 0
            rangeEnd = normalizedEndChar
        } else {
            // This node is in the middle - select entire node
            rangeStart = 0
            rangeEnd = textLength
        }

        // When zoom region is active, constrain selection to visible characters only
        if let visibleRange = getVisibleCharacterRange(for: node) {
            rangeStart = max(rangeStart, visibleRange.start)
            rangeEnd = min(rangeEnd, visibleRange.end)
            // Return nil if there's no overlap between selection and visible range
            if rangeEnd <= rangeStart {
                return nil
            }
        }

        return (start: rangeStart, end: rangeEnd)
    }

    /// Build or retrieve cached sorted nodes and index map for O(1) lookups
    /// This dramatically improves Cmd+A performance from O(n² log n) to O(n log n)
    private func getCachedSortedNodesAndIndexMap() -> (sortedNodes: [OCRNodeWithText], indexMap: [Int: Int]) {
        // Check if cache is valid
        if cachedNodesVersion == currentNodesVersion,
           let sortedNodes = cachedSortedNodes,
           let indexMap = cachedNodeIndexMap {
            return (sortedNodes, indexMap)
        }

        // Build cache: sort nodes by reading order (top to bottom, left to right)
        let sortedNodes = ocrNodes.sorted { node1, node2 in
            let yTolerance: CGFloat = 0.02
            if abs(node1.y - node2.y) > yTolerance {
                return node1.y < node2.y
            }
            return node1.x < node2.x
        }

        // Build index map for O(1) lookup by node ID
        var indexMap: [Int: Int] = [:]
        indexMap.reserveCapacity(sortedNodes.count)
        for (index, node) in sortedNodes.enumerated() {
            indexMap[node.id] = index
        }

        // Store in cache
        cachedSortedNodes = sortedNodes
        cachedNodeIndexMap = indexMap
        cachedNodesVersion = currentNodesVersion

        return (sortedNodes, indexMap)
    }

    /// Fallback selection for programmatic selection (Cmd+A, double-click, triple-click)
    /// Uses full-screen reading order without rectangle filtering
    /// Optimized to use cached sorted nodes and O(1) index lookup
    private func getSelectionRangeFullScreen(for nodeID: Int) -> (start: Int, end: Int)? {
        guard let start = selectionStart, let end = selectionEnd else { return nil }

        // Use cached sorted nodes and index map for O(1) lookups instead of O(n) firstIndex calls
        let (sortedNodes, indexMap) = getCachedSortedNodesAndIndexMap()

        guard let startNodeIndex = indexMap[start.nodeID],
              let endNodeIndex = indexMap[end.nodeID],
              let thisNodeIndex = indexMap[nodeID] else {
            return nil
        }

        let (normalizedStartNodeIndex, normalizedEndNodeIndex, normalizedStartChar, normalizedEndChar): (Int, Int, Int, Int)
        if startNodeIndex <= endNodeIndex {
            normalizedStartNodeIndex = startNodeIndex
            normalizedEndNodeIndex = endNodeIndex
            normalizedStartChar = start.charIndex
            normalizedEndChar = end.charIndex
        } else {
            normalizedStartNodeIndex = endNodeIndex
            normalizedEndNodeIndex = startNodeIndex
            normalizedStartChar = end.charIndex
            normalizedEndChar = start.charIndex
        }

        guard thisNodeIndex >= normalizedStartNodeIndex && thisNodeIndex <= normalizedEndNodeIndex else {
            return nil
        }

        let node = sortedNodes[thisNodeIndex]
        let textLength = node.text.count

        var rangeStart: Int
        var rangeEnd: Int

        if thisNodeIndex == normalizedStartNodeIndex && thisNodeIndex == normalizedEndNodeIndex {
            rangeStart = min(normalizedStartChar, normalizedEndChar)
            rangeEnd = max(normalizedStartChar, normalizedEndChar)
        } else if thisNodeIndex == normalizedStartNodeIndex {
            rangeStart = normalizedStartChar
            rangeEnd = textLength
        } else if thisNodeIndex == normalizedEndNodeIndex {
            rangeStart = 0
            rangeEnd = normalizedEndChar
        } else {
            rangeStart = 0
            rangeEnd = textLength
        }

        if let visibleRange = getVisibleCharacterRange(for: node) {
            rangeStart = max(rangeStart, visibleRange.start)
            rangeEnd = min(rangeEnd, visibleRange.end)
            if rangeEnd <= rangeStart {
                return nil
            }
        }

        return (start: rangeStart, end: rangeEnd)
    }

    /// Get the selected text (character-level)
    /// When zoom region is active, only includes text visible within the region
    public var selectedText: String {
        guard hasSelection else { return "" }

        var result = ""
        // Use nodes in zoom region if active, otherwise all nodes
        let nodesToCheck = isZoomRegionActive ? ocrNodesInZoomRegion : ocrNodes

        let sortedNodes = nodesToCheck.sorted { node1, node2 in
            let yTolerance: CGFloat = 0.02
            if abs(node1.y - node2.y) > yTolerance {
                return node1.y < node2.y
            }
            return node1.x < node2.x
        }

        for node in sortedNodes {
            if let range = getSelectionRange(for: node.id) {
                let text = node.text
                let startIdx = text.index(text.startIndex, offsetBy: min(range.start, text.count))
                let endIdx = text.index(text.startIndex, offsetBy: min(range.end, text.count))
                if startIdx < endIdx {
                    result += String(text[startIdx..<endIdx])
                    result += " "  // Add space between nodes
                }
            }
        }

        return result.trimmingCharacters(in: .whitespaces)
    }

    /// Copy selected text to clipboard
    public func copySelectedText() {
        let text = selectedText
        guard !text.isEmpty else { return }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)

        // Track text copy event with the copied text
        // Track text copy event with the copied text
        DashboardViewModel.recordTextCopy(coordinator: coordinator, text: text)
        
        // Track shift+drag text copy if this was from a manual selection
        if hasSelection {
            DashboardViewModel.recordShiftDragTextCopy(coordinator: coordinator, copiedText: text)
        }
    }

    /// Copy the zoomed region as an image to clipboard
    public func copyZoomedRegionImage() {
        guard let region = zoomRegion, isZoomRegionActive else {
            Log.warning("[ZoomCopy] Ignored copy: no active zoom region", category: .ui)
            return
        }

        // Get the current frame image (either from cache or from video)
        getCurrentFrameImage { image in
            guard let image = image else {
                Log.warning("[ZoomCopy] Failed: current frame image unavailable", category: .ui)
                self.showToast("Failed to copy image", icon: "exclamationmark.triangle.fill")
                return
            }

            guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                Log.warning("[ZoomCopy] Failed: could not get CGImage from frame image", category: .ui)
                self.showToast("Failed to copy image", icon: "exclamationmark.triangle.fill")
                return
            }

            let pixelBounds = CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height)

            // Calculate crop rect based on zoom region (normalized 0-1 coordinates).
            // Both zoom region and CGImage crop coordinates are treated in the same orientation here.
            let rawCropRect = CGRect(
                x: region.origin.x * CGFloat(cgImage.width),
                y: region.origin.y * CGFloat(cgImage.height),
                width: region.width * CGFloat(cgImage.width),
                height: region.height * CGFloat(cgImage.height)
            )
            let cropRect = rawCropRect.intersection(pixelBounds).integral

            guard !cropRect.isEmpty, let croppedCGImage = cgImage.cropping(to: cropRect) else {
                Log.warning("[ZoomCopy] Failed: crop rect invalid raw=\(rawCropRect), clipped=\(cropRect), image=\(cgImage.width)x\(cgImage.height)", category: .ui)
                self.showToast("Failed to copy image", icon: "exclamationmark.triangle.fill")
                return
            }

            let croppedImage = NSImage(
                cgImage: croppedCGImage,
                size: NSSize(width: croppedCGImage.width, height: croppedCGImage.height)
            )

            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            let didWrite = pasteboard.writeObjects([croppedImage])

            guard didWrite else {
                Log.warning("[ZoomCopy] Failed: pasteboard.writeObjects returned false", category: .ui)
                self.showToast("Failed to copy image", icon: "exclamationmark.triangle.fill")
                return
            }

            self.showToast("Image copied")
            DashboardViewModel.recordImageCopy(coordinator: self.coordinator, frameID: self.currentFrame?.id.value)
        }
    }

    /// Get the current frame as an image (handles both static images and video frames)
    private func getCurrentFrameImage(completion: @escaping (NSImage?) -> Void) {
        // Live mode uses the latest screenshot buffer, not timeline video/currentImage.
        if isInLiveMode {
            if let liveScreenshot {
                completion(liveScreenshot)
            } else {
                Log.warning("[ZoomCopy] Live mode active but liveScreenshot is nil", category: .ui)
                completion(nil)
            }
            return
        }

        // Always extract historical images from video to avoid stale in-memory snapshots.

        // Fall back to extracting from video
        guard let videoInfo = currentVideoInfo else {
            Log.warning("[ZoomCopy] No currentVideoInfo for historical frame image extraction", category: .ui)
            completion(nil)
            return
        }

        // Check if file exists (try both with and without .mp4 extension)
        var actualVideoPath = videoInfo.videoPath
        if !FileManager.default.fileExists(atPath: actualVideoPath) {
            let pathWithExtension = actualVideoPath + ".mp4"
            if FileManager.default.fileExists(atPath: pathWithExtension) {
                actualVideoPath = pathWithExtension
            } else {
                Log.warning("[ZoomCopy] Video file missing at both paths: \(actualVideoPath) and \(pathWithExtension)", category: .ui)
                completion(nil)
                return
            }
        }

        // Determine the URL to use - if file already has .mp4 extension, use directly
        let url: URL
        if actualVideoPath.hasSuffix(".mp4") {
            url = URL(fileURLWithPath: actualVideoPath)
        } else {
            let tempDir = FileManager.default.temporaryDirectory
            let fileName = (actualVideoPath as NSString).lastPathComponent
            let symlinkPath = tempDir.appendingPathComponent("\(fileName).mp4").path

            if !FileManager.default.fileExists(atPath: symlinkPath) {
                do {
                    try FileManager.default.createSymbolicLink(atPath: symlinkPath, withDestinationPath: actualVideoPath)
                } catch {
                    Log.warning("[ZoomCopy] Failed to create symlink at \(symlinkPath): \(error)", category: .ui)
                    completion(nil)
                    return
                }
            }
            url = URL(fileURLWithPath: symlinkPath)
        }
        let asset = AVURLAsset(url: url)
        let imageGenerator = AVAssetImageGenerator(asset: asset)
        imageGenerator.appliesPreferredTrackTransform = true
        imageGenerator.requestedTimeToleranceBefore = .zero
        imageGenerator.requestedTimeToleranceAfter = .zero

        // Use integer arithmetic to avoid floating point precision issues
        let time = videoInfo.frameTimeCMTime
        imageGenerator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { _, cgImage, _, _, _ in
            DispatchQueue.main.async {
                if let cgImage = cgImage {
                    let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                    completion(nsImage)
                } else {
                    Log.warning("[ZoomCopy] AVAssetImageGenerator returned nil image for url=\(url.path), frameIndex=\(videoInfo.frameIndex)", category: .ui)
                    completion(nil)
                }
            }
        }
    }

    /// Handle scroll delta to navigate frames
    /// - Parameters:
    ///   - delta: The scroll delta value
    ///   - isTrackpad: Whether the scroll came from a trackpad (precise scrolling) vs mouse wheel
    public func handleScroll(delta: CGFloat, isTrackpad: Bool = true) async {
        // Stop playback on manual scroll
        if isPlaying {
            stopPlayback()
        }

        // Exit live mode on first scroll
        if isInLiveMode {
            exitLiveMode()
            return // First scroll exits live mode, don't navigate yet
        }

        guard !frames.isEmpty else { return }

        // Read user sensitivity setting (0.1–1.0, default 0.50)
        let store = UserDefaults(suiteName: "io.retrace.app") ?? .standard
        let userSensitivity = store.object(forKey: "scrollSensitivity") != nil ? store.double(forKey: "scrollSensitivity") : 0.50
        let sensitivityMultiplier = CGFloat(userSensitivity / 0.50) // Normalize so 0.50 = current behavior

        // Mark as actively scrolling
        if !isActivelyScrolling {
            isActivelyScrolling = true
            dismissContextMenu()
            dismissTimelineContextMenu()
        }

        // Cancel previous debounce task
        scrollDebounceTask?.cancel()

        if isTrackpad {
            // Continuous scrolling: convert delta to pixel displacement
            // Scale so trackpad movement maps ~1:1 to tape pixel movement
            let pixelDelta = delta * sensitivityMultiplier
            subFrameOffset += pixelDelta

            // Check if we've crossed frame boundaries
            let ppf = pixelsPerFrame
            if abs(subFrameOffset) >= ppf / 2 {
                let framesToCross = Int(round(subFrameOffset / ppf))
                if framesToCross != 0 {
                    let prevIndex = currentIndex
                    let targetIndex = currentIndex + framesToCross
                    let clampedTarget = max(0, min(frames.count - 1, targetIndex))
                    let actualFramesMoved = clampedTarget - prevIndex

                    if actualFramesMoved != 0 {
                        // Only subtract the frames we actually moved
                        subFrameOffset -= CGFloat(actualFramesMoved) * ppf
                        navigateToFrame(clampedTarget, fromScroll: true)
                    }

                    // At boundary: clamp offset so it doesn't accumulate past the edge
                    if clampedTarget != targetIndex {
                        subFrameOffset = 0
                    }
                }
            }

            // Safety clamp: prevent any residual offset past boundaries
            if currentIndex == 0 && subFrameOffset < 0 {
                subFrameOffset = 0
            } else if currentIndex >= frames.count - 1 && subFrameOffset > 0 {
                subFrameOffset = 0
            }
        } else {
            // Mouse wheel: discrete frame steps (no sub-frame movement)
            let baseSensitivity: CGFloat = 0.5 * sensitivityMultiplier
            let referencePixelsPerFrame: CGFloat = TimelineConfig.basePixelsPerFrame * TimelineConfig.defaultZoomLevel + TimelineConfig.minPixelsPerFrame * (1 - TimelineConfig.defaultZoomLevel)
            let zoomAdjustedSensitivity = baseSensitivity * (referencePixelsPerFrame / pixelsPerFrame)

            // Accumulate in subFrameOffset temporarily for mouse wheel
            let mouseAccum = delta * zoomAdjustedSensitivity
            var frameStep = Int(mouseAccum)
            if frameStep == 0 && abs(delta) > 0.001 {
                frameStep = delta > 0 ? 1 : -1
            }
            if frameStep != 0 {
                subFrameOffset = 0
                navigateToFrame(currentIndex + frameStep, fromScroll: true)
            }
        }

        // Clear transient search-result highlight when user manually scrolls.
        if isShowingSearchHighlight && !hasActiveInFrameSearchQuery {
            clearSearchHighlight()
        }

        // Debounce: settle tape to frame center and load OCR/URL after 100ms of no scroll
        scrollDebounceTask = Task {
            try? await Task.sleep(for: .nanoseconds(Int64(100_000_000)), clock: .continuous) // 100ms
            if !Task.isCancelled {
                await MainActor.run {
                    self.isActivelyScrolling = false
                    // Now load OCR/URL data that was deferred during scrubbing
                    self.loadURLBoundingBox()
                    self.loadOCRNodes()
                }
            }
        }
    }

    /// Cancel any in-progress tape drag momentum (e.g., user clicked again to stop)
    public func cancelTapeDragMomentum() {
        tapeDragMomentumTask?.cancel()
        tapeDragMomentumTask = nil
    }

    /// End a tape click-drag scrub session, optionally with momentum
    /// - Parameter velocity: Release velocity in pixels/second (in scroll convention, negated from screen delta)
    public func endTapeDrag(withVelocity velocity: CGFloat = 0) {
        // Cancel any existing momentum
        tapeDragMomentumTask?.cancel()

        let minVelocity: CGFloat = 50 // px/s threshold to trigger momentum
        if abs(velocity) > minVelocity {
            // Start momentum animation
            tapeDragMomentumTask = Task { @MainActor [weak self] in
                guard let self = self else { return }

                let friction: CGFloat = 0.95 // Per-tick decay factor
                let tickInterval: UInt64 = 16_000_000 // ~60fps (16ms)
                var currentVelocity = velocity
                let stopThreshold: CGFloat = 20 // px/s to stop

                while abs(currentVelocity) > stopThreshold && !Task.isCancelled {
                    // Convert velocity (px/s) to per-tick delta (px)
                    let dt: CGFloat = 0.016 // 16ms
                    let delta = currentVelocity * dt

                    await self.handleScroll(delta: delta, isTrackpad: true)

                    // Apply friction
                    currentVelocity *= friction

                    try? await Task.sleep(for: .nanoseconds(Int64(tickInterval)), clock: .continuous)
                }

                if !Task.isCancelled {
                    self.isActivelyScrolling = false
                    self.loadURLBoundingBox()
                    self.loadOCRNodes()
                }
            }
        } else {
            // No meaningful velocity — just re-enable deferred operations
            isActivelyScrolling = false
            loadURLBoundingBox()
            loadOCRNodes()
        }
    }

    // MARK: - Computed Properties

    /// Get the playhead position as a percentage (0.0 to 1.0)
    public var playheadPosition: CGFloat {
        guard frames.count > 1 else { return 0.5 }
        return CGFloat(currentIndex) / CGFloat(frames.count - 1)
    }

    /// Get formatted time string for current frame - derived from currentTimestamp
    public var currentTimeString: String {
        guard let timestamp = currentTimestamp else { return "--:--:--" }

        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm:ss a"
        formatter.timeZone = .current
        return formatter.string(from: timestamp)
    }

    /// Get formatted date string for current frame - derived from currentTimestamp
    public var currentDateString: String {
        guard let timestamp = currentTimestamp else { return "" }

        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        formatter.timeZone = .current
        return formatter.string(from: timestamp)
    }

    /// Total number of frames (for tape view)
    public var frameCount: Int {
        frames.count
    }

    /// Whether the timeline is currently showing the most recent frame
    /// Returns true only when at the last frame and no newer frames exist
    public var isAtMostRecentFrame: Bool {
        return isNearMostRecentFrame(within: 1)
    }

    /// Whether the timeline is within N frames of the most recent
    /// - Parameter within: Number of frames from the end to consider "near" (1 = last frame only, 2 = last 2 frames, etc.)
    public func isNearMostRecentFrame(within count: Int) -> Bool {
        guard !frames.isEmpty else { return true }
        return currentIndex >= frames.count - count && !hasMoreNewer
    }

    nonisolated static func isNewestLoadedTimestampRecent(
        _ newestLoadedTimestamp: Date?,
        now: Date,
        threshold: TimeInterval = 5 * 60
    ) -> Bool {
        guard let newestLoadedTimestamp else { return true }
        return abs(now.timeIntervalSince(newestLoadedTimestamp)) <= threshold
    }

    func isNewestLoadedFrameRecent(now: Date = Date()) -> Bool {
        Self.isNewestLoadedTimestampRecent(frames.last?.frame.timestamp, now: now)
    }

    /// Whether the timeline is within N frames of the latest loaded frame.
    /// Unlike `isNearMostRecentFrame`, this intentionally ignores `hasMoreNewer`.
    /// Useful for UI decisions where stale boundary flags should not block "near-now" behavior.
    public func isNearLatestLoadedFrame(within count: Int) -> Bool {
        guard !frames.isEmpty else { return true }
        return currentIndex >= frames.count - count
    }

    /// Whether to show the "Go to Now" button
    /// Shows when not viewing the most recent available frame
    public var shouldShowGoToNow: Bool {
        guard !frames.isEmpty else { return false }
        // Show if not at the end of loaded frames, or if there are newer frames to load
        return currentIndex < frames.count - 1 || hasMoreNewer
    }

    /// Navigate to the most recent frame — jumps to end of tape if already loaded, otherwise reloads from DB
    public func goToNow() {
        // Cmd+J should snap to an exact frame center, not preserve partial scrub offset.
        cancelTapeDragMomentum()
        scrollDebounceTask?.cancel()
        scrollDebounceTask = nil
        isActivelyScrolling = false
        subFrameOffset = 0
        cancelBoundaryLoadTasks(reason: "goToNow")

        // Clear filters without triggering reload (we'll handle that ourselves)
        if activeFilterCount > 0 {
            clearFilterState()
        }

        // Always reload from DB to get the true most recent frame (unfiltered)
        Task {
            await loadMostRecentFrame()
            await refreshProcessingStatuses()
        }
    }

    // MARK: - Date Search

    /// Lower bound for Cmd+G frame-ID interpretation.
    /// Real frame IDs are much larger, so small numeric input should stay in time/date parsing.
    private static let minimumFrameIDSearchValue: Int64 = 10_000

    /// Whether frame ID search is enabled (read from UserDefaults)
    public var enableFrameIDSearch: Bool {
        let defaults = UserDefaults(suiteName: "io.retrace.app") ?? .standard
        return defaults.bool(forKey: "enableFrameIDSearch")
    }

    // MARK: - Calendar Picker

    /// Set keyboard navigation focus to the date grid.
    public func focusCalendarDateGrid() {
        calendarKeyboardFocus = .dateGrid
        selectedCalendarHour = nil
    }

    /// Handle arrow keys while the calendar picker is visible.
    /// - Parameter keyCode: Arrow key code (123 left, 124 right, 125 down, 126 up)
    /// - Returns: `true` when the event is consumed.
    public func handleCalendarPickerArrowKey(_ keyCode: UInt16) -> Bool {
        switch calendarKeyboardFocus {
        case .dateGrid:
            let dayOffset: Int
            switch keyCode {
            case 123: dayOffset = -1
            case 124: dayOffset = 1
            case 125: dayOffset = 7
            case 126: dayOffset = -7
            default: return false
            }

            moveCalendarDateSelection(byDayOffset: dayOffset)
            return true

        case .timeGrid:
            let hourStep: Int
            switch keyCode {
            case 123: hourStep = -1
            case 124: hourStep = 1
            case 125: hourStep = 3
            case 126: hourStep = -3
            default: return false
            }

            moveCalendarHourSelection(byHourOffset: hourStep)
            return true
        }
    }

    /// Handle Enter/Return while the calendar picker is visible.
    /// - Returns: `true` when the event is consumed.
    public func handleCalendarPickerEnterKey() -> Bool {
        switch calendarKeyboardFocus {
        case .dateGrid:
            guard let selectedDay = selectedCalendarDate else { return true }
            let normalizedDay = Calendar.current.startOfDay(for: selectedDay)

            if hoursWithFrames.isEmpty {
                Task {
                    await loadHoursForDate(normalizedDay)
                    await MainActor.run {
                        focusFirstAvailableCalendarHour()
                    }
                }
            } else {
                focusFirstAvailableCalendarHour()
            }
            return true

        case .timeGrid:
            guard let selectedHour = selectedCalendarHour,
                  let timestamp = firstFrameTimestamp(forHour: selectedHour) else {
                return true
            }

            Task {
                await navigateToHour(timestamp)
            }
            return true
        }
    }

    /// Load dates that have frames for calendar display
    /// Also auto-loads hours for today if today has frames
    public func loadDatesWithFrames() async {
        do {
            let dates = try await coordinator.getDistinctDates()
            await MainActor.run {
                self.datesWithFrames = Set(dates)
            }

            // Auto-load hours for today if available, otherwise the most recent date
            let calendar = Calendar.current
            let today = calendar.startOfDay(for: Date())

            if dates.contains(today) {
                await loadHoursForDate(today)
            } else if let mostRecent = dates.first {
                await loadHoursForDate(mostRecent)
            }
        } catch {
            Log.error("Failed to load dates with frames: \(error)", category: .ui)
        }
    }

    /// Load hours with frames for a specific date (displays available hours in the picker)
    public func loadHoursForDate(_ date: Date) async {
        do {
            let hours = try await coordinator.getDistinctHoursForDate(date)
            await MainActor.run {
                self.selectedCalendarDate = date
                self.hoursWithFrames = hours
                if self.calendarKeyboardFocus == .timeGrid {
                    let validHours = self.availableCalendarHoursSorted()
                    if let selected = self.selectedCalendarHour, validHours.contains(selected) {
                        // Keep existing keyboard hour selection when still valid.
                    } else {
                        self.selectedCalendarHour = validHours.first
                    }
                } else {
                    self.selectedCalendarHour = nil
                }
            }
        } catch {
            Log.error("Failed to load hours for date: \(error)", category: .ui)
        }
    }

    /// Navigate to a specific hour from the calendar picker
    public func navigateToHour(_ hour: Date) async {
        clearActiveFiltersBeforeJumpIfNeeded(trigger: "calendar jump")
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            isCalendarPickerVisible = false
            isDateSearchActive = false
        }
        calendarKeyboardFocus = .dateGrid
        selectedCalendarHour = nil
        await navigateToDate(hour)
    }

    private func moveCalendarDateSelection(byDayOffset offset: Int) {
        guard let targetDate = nextCalendarDate(byDayOffset: offset) else { return }

        calendarKeyboardFocus = .dateGrid
        selectedCalendarHour = nil
        selectedCalendarDate = targetDate
        hoursWithFrames = []

        Task {
            await loadHoursForDate(targetDate)
        }
    }

    private func moveCalendarHourSelection(byHourOffset offset: Int) {
        let validHours = Set(availableCalendarHoursSorted())
        guard !validHours.isEmpty else { return }

        if selectedCalendarHour == nil {
            selectedCalendarHour = availableCalendarHoursSorted().first
            return
        }

        guard let currentHour = selectedCalendarHour else { return }

        var candidate = currentHour + offset
        while (0...23).contains(candidate) {
            if validHours.contains(candidate) {
                selectedCalendarHour = candidate
                return
            }
            candidate += offset
        }
    }

    private func nextCalendarDate(byDayOffset offset: Int) -> Date? {
        let sortedDates = availableCalendarDatesSorted()
        guard !sortedDates.isEmpty else { return nil }

        let calendar = Calendar.current
        let baseDate = calendar.startOfDay(for: selectedCalendarDate ?? sortedDates.last!)
        guard let rawTarget = calendar.date(byAdding: .day, value: offset, to: baseDate) else {
            return baseDate
        }
        let targetDate = calendar.startOfDay(for: rawTarget)

        if offset > 0 {
            return sortedDates.first(where: { $0 >= targetDate }) ?? sortedDates.last
        } else {
            return sortedDates.last(where: { $0 <= targetDate }) ?? sortedDates.first
        }
    }

    private func focusFirstAvailableCalendarHour() {
        guard let firstHour = availableCalendarHoursSorted().first else { return }
        calendarKeyboardFocus = .timeGrid
        selectedCalendarHour = firstHour
    }

    private func firstFrameTimestamp(forHour hour: Int) -> Date? {
        let calendar = Calendar.current
        return hoursWithFrames.sorted().first { date in
            calendar.component(.hour, from: date) == hour
        }
    }

    private func availableCalendarDatesSorted() -> [Date] {
        datesWithFrames.sorted()
    }

    private func availableCalendarHoursSorted() -> [Int] {
        let calendar = Calendar.current
        let uniqueHours = Set(hoursWithFrames.map { calendar.component(.hour, from: $0) })
        return uniqueHours.sorted()
    }

    /// Navigate to a specific date (start of day or specific time)
    private func navigateToDate(_ targetDate: Date) async {
        setLoadingState(true, reason: "navigateToDate")
        clearError()
        cancelBoundaryLoadTasks(reason: "navigateToDate")
        cancelPendingStoppedPositionRecording()
        _ = recordCurrentPositionImmediatelyForUndo(reason: "navigateToDate.source")

        // Exit live mode if active (we're navigating to a specific time, not "now")
        if isInLiveMode {
            isInLiveMode = false
            liveScreenshot = nil
            isTapeHidden = false
        }

        do {
            let calendar = Calendar.current
            let startDate = calendar.date(byAdding: .minute, value: -10, to: targetDate) ?? targetDate
            let endDate = calendar.date(byAdding: .minute, value: 10, to: targetDate) ?? targetDate

            // Always pass filterCriteria to ensure hidden filter is applied (default: .hide)
            let framesWithVideoInfo = try await fetchFramesWithVideoInfoLogged(
                from: startDate,
                to: endDate,
                limit: 1000,
                filters: filterCriteria,
                reason: "navigateToDate"
            )

            guard !framesWithVideoInfo.isEmpty else {
                showErrorWithAutoDismiss("No frames found around \(formatLocalDateForError(targetDate))")
                setLoadingState(false, reason: "navigateToDate.noFrames")
                return
            }

            // Clear disk frame buffer
            let oldCacheCount = diskFrameBufferIndex.count
            clearDiskFrameBuffer(reason: "calendar navigation")
            if oldCacheCount > 0 {
                Log.info("[Memory] Cleared disk frame buffer on calendar navigation (\(oldCacheCount) frames removed)", category: .ui)
            }

            frames = framesWithVideoInfo.map { TimelineFrame(frameWithVideoInfo: $0) }

            updateWindowBoundaries()
            resetBoundaryStateForReloadWindow()

            let closestIndex = findClosestFrameIndex(to: targetDate)
            currentIndex = closestIndex
            _ = recordCurrentPositionImmediatelyForUndo(reason: "navigateToDate.destination")

            loadImageIfNeeded()
            _ = checkAndLoadMoreFrames(reason: "navigateToDate")
            setLoadingState(false, reason: "navigateToDate.success")
        } catch {
            self.error = "Failed to navigate: \(error.localizedDescription)"
            setLoadingState(false, reason: "navigateToDate.error")
        }
    }

    /// Search for frames around a natural language date string, or by frame ID if enabled
    public func searchForDate(_ searchText: String, source: String = "timeline_date_search") async {
        let trimmedSearchText = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSearchText.isEmpty else { return }
        let numericFrameID = Int64(trimmedSearchText)
        let qualifiesForFrameIDSearch = numericFrameID.map { $0 >= Self.minimumFrameIDSearchValue } ?? false
        var frameIDLookupAttempted = false

        DashboardViewModel.recordDateSearchSubmitted(
            coordinator: coordinator,
            source: source,
            query: trimmedSearchText,
            queryLength: trimmedSearchText.count,
            frameIDSearchEnabled: enableFrameIDSearch,
            lookedLikeFrameID: qualifiesForFrameIDSearch
        )

        setLoadingState(true, reason: "searchForDate")
        clearError()
        cancelBoundaryLoadTasks(reason: "searchForDate")
        dateJumpTraceID += 1
        let jumpTraceID = dateJumpTraceID
        cancelPendingStoppedPositionRecording()
        _ = recordCurrentPositionImmediatelyForUndo(reason: "searchForDate.source")

        // Exit live mode if active (we're navigating away from "now")
        if isInLiveMode {
            isInLiveMode = false
            liveScreenshot = nil
            isTapeHidden = false
        }

        do {
            // If frame ID search is enabled and input looks like a frame ID (pure number), try that first
            if enableFrameIDSearch,
               qualifiesForFrameIDSearch,
               let frameID = numericFrameID {
                frameIDLookupAttempted = true
                if await searchForFrameID(frameID, showFailureUI: false) {
                    DashboardViewModel.recordDateSearchOutcome(
                        coordinator: coordinator,
                        source: source,
                        query: trimmedSearchText,
                        outcome: "frame_id_success",
                        queryLength: trimmedSearchText.count,
                        frameIDLookupAttempted: frameIDLookupAttempted
                    )
                    return // Successfully jumped to frame
                }
                // If frame ID search fails, fall through to date search
            }

            // Parse natural language date.
            // "X minutes/hours earlier|later" is interpreted relative to the current playhead timestamp.
            let targetDate: Date
            if let playheadRelativeDate = parsePlayheadRelativeDateIfNeeded(searchText) {
                targetDate = playheadRelativeDate
            } else {
                guard let parsedDate = parseNaturalLanguageDate(trimmedSearchText) else {
                    let parseFailedReason: String
                    let outcome: String
                    if frameIDLookupAttempted, let frameID = numericFrameID {
                        showErrorWithAutoDismiss("Frame #\(frameID) not found")
                        parseFailedReason = "searchForDate.frameIDNotFoundAfterParseFailed"
                        outcome = "frame_id_not_found"
                    } else {
                        showErrorWithAutoDismiss("Could not understand: \(searchText)")
                        parseFailedReason = "searchForDate.parseFailed"
                        outcome = "parse_failed"
                    }
                    setLoadingState(false, reason: parseFailedReason)
                    DashboardViewModel.recordDateSearchOutcome(
                        coordinator: coordinator,
                        source: source,
                        query: trimmedSearchText,
                        outcome: outcome,
                        queryLength: trimmedSearchText.count,
                        frameIDLookupAttempted: frameIDLookupAttempted
                    )
                    return
                }
                targetDate = parsedDate
            }

            clearActiveFiltersBeforeJumpIfNeeded(trigger: "date input jump")

            let anchoredTargetDate = try await resolveDateSearchAnchorDate(
                parsedDate: targetDate,
                input: trimmedSearchText
            )

            // Load frames around the target date (±10 minutes window)
            let calendar = Calendar.current
            let startDate = calendar.date(byAdding: .minute, value: -10, to: anchoredTargetDate) ?? anchoredTargetDate
            let endDate = calendar.date(byAdding: .minute, value: 10, to: anchoredTargetDate) ?? anchoredTargetDate

            // Fetch all frames in the 20-minute window
            // Uses optimized query that JOINs on video table - no N+1 queries!
            // Always pass filterCriteria to ensure hidden filter is applied (default: .hide)
            let framesWithVideoInfo = try await fetchFramesWithVideoInfoLogged(
                from: startDate,
                to: endDate,
                limit: 1000,
                filters: filterCriteria,
                reason: "searchForDate"
            )

            guard !framesWithVideoInfo.isEmpty else {
                showErrorWithAutoDismiss("No frames found around \(formatLocalDateForError(targetDate))")
                setLoadingState(false, reason: "searchForDate.noFrames")
                DashboardViewModel.recordDateSearchOutcome(
                    coordinator: coordinator,
                    source: source,
                    query: trimmedSearchText,
                    outcome: "no_frames",
                    queryLength: trimmedSearchText.count,
                    frameIDLookupAttempted: frameIDLookupAttempted
                )
                return
            }

            // Clear disk frame buffer since we're jumping to a new time window
            let oldCacheCount = diskFrameBufferIndex.count
            clearDiskFrameBuffer(reason: "date search")
            if oldCacheCount > 0 {
                Log.info("[Memory] Cleared disk frame buffer on date search (\(oldCacheCount) frames removed)", category: .ui)
            }

            // Convert to TimelineFrame - video info is already included from the JOIN
            frames = framesWithVideoInfo.map { TimelineFrame(frameWithVideoInfo: $0) }

            // Reset infinite scroll state for new window
            updateWindowBoundaries()
            resetBoundaryStateForReloadWindow()

            // Find the frame closest to the target date in our centered set
            let closestIndex = findClosestFrameIndex(to: anchoredTargetDate)
            currentIndex = closestIndex
            _ = recordCurrentPositionImmediatelyForUndo(reason: "searchForDate.destination")
            logFrameWindowSummary(context: "POST searchForDate", traceID: jumpTraceID)

            // Load image if needed
            loadImageIfNeeded()
            _ = checkAndLoadMoreFrames(reason: "searchForDate")

            // Log memory state after date search
            MemoryTracker.logMemoryState(
                context: "DATE SEARCH COMPLETE",
                frameCount: frames.count,
                frameBufferCount: diskFrameBufferIndex.count,
                oldestTimestamp: oldestLoadedTimestamp,
                newestTimestamp: newestLoadedTimestamp
            )

            setLoadingState(false, reason: "searchForDate.success")
            DashboardViewModel.recordDateSearchOutcome(
                coordinator: coordinator,
                source: source,
                query: trimmedSearchText,
                outcome: "success",
                queryLength: trimmedSearchText.count,
                frameIDLookupAttempted: frameIDLookupAttempted,
                frameCount: framesWithVideoInfo.count
            )
            closeDateSearch()

        } catch {
            self.error = "Failed to search for date: \(error.localizedDescription)"
            Log.error("[DateJump:\(jumpTraceID)] FAILED: \(error)", category: .ui)
            setLoadingState(false, reason: "searchForDate.error")
            DashboardViewModel.recordDateSearchOutcome(
                coordinator: coordinator,
                source: source,
                query: trimmedSearchText,
                outcome: "error",
                queryLength: trimmedSearchText.count,
                frameIDLookupAttempted: frameIDLookupAttempted
            )
        }
    }

    /// Search for a frame by its ID and navigate to it
    /// Returns true if frame was found and navigation succeeded
    private func searchForFrameID(
        _ frameID: Int64,
        includeHiddenSegments: Bool = false,
        showFailureUI: Bool = true
    ) async -> Bool {
        cancelBoundaryLoadTasks(reason: "searchForFrameID")
        cancelPendingStoppedPositionRecording()
        _ = recordCurrentPositionImmediatelyForUndo(reason: "searchForFrameID.source")

        do {
            // Try to get the frame by ID
            guard let frameWithVideo = try await fetchFrameWithVideoInfoByIDForLookup(id: FrameID(value: frameID)) else {
                if showFailureUI {
                    error = "Frame #\(frameID) not found"
                    setLoadingState(false, reason: "searchForFrameID.notFound")
                }
                return false
            }

            let targetFrame = frameWithVideo.frame
            let targetDate = targetFrame.timestamp

            clearActiveFiltersBeforeJumpIfNeeded(trigger: "frame ID jump")

            // Load frames around the target frame's timestamp (±10 minutes window)
            let calendar = Calendar.current
            let startDate = calendar.date(byAdding: .minute, value: -10, to: targetDate) ?? targetDate
            let endDate = calendar.date(byAdding: .minute, value: 10, to: targetDate) ?? targetDate

            // Fetch all frames in the window.
            // Linked-comment jumps intentionally ignore hidden filtering so anchored frames remain reachable.
            var jumpFilters = filterCriteria
            if includeHiddenSegments {
                jumpFilters.hiddenFilter = .showAll
            }
            let framesWithVideoInfo = try await fetchFramesWithVideoInfoLogged(
                from: startDate,
                to: endDate,
                limit: 1000,
                filters: jumpFilters,
                reason: "searchForFrameID"
            )

            guard !framesWithVideoInfo.isEmpty else {
                if showFailureUI {
                    showErrorWithAutoDismiss("No frames found around frame #\(frameID)")
                    setLoadingState(false, reason: "searchForFrameID.noFramesInWindow")
                }
                return false
            }

            // Clear disk frame buffer since we're jumping to a new time window
            let oldCacheCount = diskFrameBufferIndex.count
            clearDiskFrameBuffer(reason: "frame ID search")
            if oldCacheCount > 0 {
                Log.info("[Memory] Cleared disk frame buffer on frame ID search (\(oldCacheCount) frames removed)", category: .ui)
            }

            // Convert to TimelineFrame
            frames = framesWithVideoInfo.map { TimelineFrame(frameWithVideoInfo: $0) }

            // Reset infinite scroll state for new window
            updateWindowBoundaries()
            resetBoundaryStateForReloadWindow()

            // Find the exact frame by ID in our loaded frames
            if let exactIndex = frames.firstIndex(where: { $0.frame.id.value == frameID }) {
                currentIndex = exactIndex
            } else {
                // Fallback to closest by timestamp
                let closestIndex = findClosestFrameIndex(to: targetDate)
                currentIndex = closestIndex
            }
            _ = recordCurrentPositionImmediatelyForUndo(reason: "searchForFrameID.destination")

            // Keep comment/tag context anchored to the jumped-to frame.
            // Without this, reopening the comment panel can resolve against a stale block index
            // from the pre-jump frame window.
            timelineContextMenuSegmentIndex = currentIndex
            selectedFrameIndex = currentIndex

            // Load image if needed
            loadImageIfNeeded()
            _ = checkAndLoadMoreFrames(reason: "searchForFrameID")

            // Log memory state after frame ID search
            MemoryTracker.logMemoryState(
                context: "FRAME ID SEARCH COMPLETE",
                frameCount: frames.count,
                frameBufferCount: diskFrameBufferIndex.count,
                oldestTimestamp: oldestLoadedTimestamp,
                newestTimestamp: newestLoadedTimestamp
            )

            setLoadingState(false, reason: "searchForFrameID.success")
            closeDateSearch()

            return true

        } catch {
            Log.error("[FrameIDSearch] Error: \(error)", category: .ui)
            // Don't set error here - let date search try as fallback
            return false
        }
    }

    private func fetchFrameWithVideoInfoByIDForLookup(id: FrameID) async throws -> FrameWithVideoInfo? {
#if DEBUG
        if let override = test_frameLookupHooks.getFrameWithVideoInfoByID {
            return try await override(id)
        }
#endif
        return try await coordinator.getFrameWithVideoInfoByID(id: id)
    }

    /// Parse relative offsets like "3 hours later" / "10 minutes earlier" / "1 hour before"
    /// using the current playhead timestamp.
    /// This path is intentionally limited to "earlier|later|before|after" so "... ago" continues
    /// to use bucket anchoring logic.
    private func parsePlayheadRelativeDateIfNeeded(_ text: String) -> Date? {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        let baseTimestamp: Date
        if let currentTimestamp {
            baseTimestamp = currentTimestamp
        } else {
            baseTimestamp = Date()
            Log.warning("[DateSearch] Relative '\(normalized)' had no playhead timestamp; falling back to now", category: .ui)
        }

        guard let resolvedDate = parsePlayheadRelativeDate(normalized, relativeTo: baseTimestamp) else {
            return nil
        }

        return resolvedDate
    }

    private func parsePlayheadRelativeDate(_ normalizedText: String, relativeTo baseTimestamp: Date) -> Date? {
        guard let regex = try? NSRegularExpression(
            pattern: #"^\s*(\d+)\s*(minute|minutes|min|mins|hour|hours|hr|hrs|h|day|days|week|weeks|wk|wks|month|months|mo|mos|year|years|yr|yrs)\s*(earlier|later|before|after)\s*$"#,
            options: [.caseInsensitive]
        ) else {
            return nil
        }

        let range = NSRange(normalizedText.startIndex..., in: normalizedText)
        guard let match = regex.firstMatch(in: normalizedText, options: [], range: range),
              let amountRange = Range(match.range(at: 1), in: normalizedText),
              let unitRange = Range(match.range(at: 2), in: normalizedText),
              let directionRange = Range(match.range(at: 3), in: normalizedText),
              let amount = Int(normalizedText[amountRange]),
              amount > 0 else {
            return nil
        }

        let unitToken = String(normalizedText[unitRange])
        let directionToken = String(normalizedText[directionRange])
        let directionSign: Int
        switch directionToken {
        case "later", "after":
            directionSign = 1
        case "earlier", "before":
            directionSign = -1
        default:
            return nil
        }
        let calendar = Calendar.current

        switch unitToken {
        case "minute", "minutes", "min", "mins":
            return calendar.date(byAdding: .minute, value: directionSign * amount, to: baseTimestamp)
        case "hour", "hours", "hr", "hrs", "h":
            return calendar.date(byAdding: .minute, value: directionSign * amount * 60, to: baseTimestamp)
        case "day", "days":
            return calendar.date(byAdding: .minute, value: directionSign * amount * 24 * 60, to: baseTimestamp)
        case "week", "weeks", "wk", "wks":
            return calendar.date(byAdding: .minute, value: directionSign * amount * 7 * 24 * 60, to: baseTimestamp)
        case "month", "months", "mo", "mos":
            return calendar.date(byAdding: .month, value: directionSign * amount, to: baseTimestamp)
        case "year", "years", "yr", "yrs":
            return calendar.date(byAdding: .year, value: directionSign * amount, to: baseTimestamp)
        default:
            return nil
        }
    }

    /// Parse natural language date strings
    private func parseNaturalLanguageDate(_ text: String, now: Date = Date()) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let calendar = Calendar.current
        let normalizedInput = trimmed.lowercased()
        let collapsedInput = normalizedInput.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
        let normalizedWithCompactTimes = normalizeCompactTimeFormat(collapsedInput)

        if collapsedInput.range(of: #"^start of (the )?day$"#, options: .regularExpression) != nil {
            return calendar.startOfDay(for: now)
        }

        func finalizeParsedDate(_ parsedDate: Date) -> Date {
            let anchorMode = inferDateSearchAnchorMode(for: normalizedWithCompactTimes)
            let dateForYearAdjustment: Date

            // For date-only input ("Feb 23"), normalize to start-of-day before
            // yearless-future coercion so "today" isn't treated as future.
            if anchorMode == .firstFrameInDay {
                dateForYearAdjustment = calendar.startOfDay(for: parsedDate)
            } else {
                dateForYearAdjustment = parsedDate
            }

            var normalized = adjustYearlessAbsoluteFutureDateToRecentPastIfNeeded(
                dateForYearAdjustment,
                input: normalizedInput,
                now: now,
                calendar: calendar
            )
            normalized = adjustTimeOnlyFutureDateToRecentPastIfNeeded(
                normalized,
                input: normalizedInput,
                now: now,
                calendar: calendar
            )
            if anchorMode == .firstFrameInDay {
                return calendar.startOfDay(for: normalized)
            }
            return normalized
        }

        // === PRIMARY: SwiftyChrono NLP Parser ===
        // Try SwiftyChrono first for comprehensive natural language parsing
        // Handles: "next Friday", "3 days from now", "last Monday", "in 2 weeks", etc.
        let chrono = Chrono()
        let chronoInputs = normalizedWithCompactTimes == collapsedInput
            ? [trimmed]
            : [normalizedWithCompactTimes, trimmed]
        for chronoInput in chronoInputs {
            if let result = chrono.parse(text: chronoInput, refDate: now, opt: [:]).first?.start.date {
                let normalized = finalizeParsedDate(result)
                return normalized
            }
        }

        // === FALLBACK: Time-only and absolute date parsing ===
        // SwiftyChrono handles all relative dates (X days/weeks/months/years ago, yesterday, etc.)
        // We only need fallback for compact time formats and explicit date strings
        let trimmedLower = normalizedInput

        // === TIME-ONLY INPUT ===

        // Try parsing time-only input (assumes "today" if just time is given)
        // Handles: "938pm", "9:38pm", "938 pm", "9:38 pm", "938", "9:38", "21:38"
        if let timeOnlyDate = parseTimeOnly(trimmedLower, relativeTo: now) {
            return finalizeParsedDate(timeOnlyDate)
        }

        // Normalize compact time formats before passing to NSDataDetector.
        // Examples:
        // - "827am yesterday" -> "8:27am yesterday"
        // - "feb 28 1417" -> "feb 28 14:17"
        let normalizedText = normalizedWithCompactTimes

        // Try macOS's built-in natural language date parser (handles "dec 15 3pm", "tomorrow at 5", etc.)
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
        if let detector = detector {
            let range = NSRange(normalizedText.startIndex..., in: normalizedText)
            if let match = detector.firstMatch(in: normalizedText, options: [], range: range),
               let date = match.date {
                return finalizeParsedDate(date)
            }
        }

        // Try various explicit date formatters as fallback
        let formatStrings = [
            "MMM d yyyy h:mm a",      // "Dec 16 2024 6:05 PM"
            "MMM d yyyy h:mma",       // "Dec 16 2024 6:05PM"
            "MMM d yyyy ha",          // "Dec 16 2024 6PM"
            "MMM d h:mm a",           // "Dec 16 6:05 PM"
            "MMM d h:mma",            // "Dec 16 6:05PM"
            "MMM d ha",               // "Dec 16 6PM"
            "MMM d h a",              // "Dec 16 6 PM"
            "MM/dd/yyyy h:mm a",      // "12/16/2024 6:05 PM"
            "MM/dd h:mm a",           // "12/16 6:05 PM"
            "yyyy-MM-dd HH:mm",       // "2024-12-16 18:05"
            "yyyy-MM-dd'T'HH:mm:ss",  // ISO 8601
            "MMM d",                  // "Dec 16" (assumes current year, noon)
            "MMMM d",                 // "December 16"
        ]

        for formatString in formatStrings {
            let df = DateFormatter()
            df.dateFormat = formatString
            df.timeZone = .current
            df.defaultDate = now  // Use current date for missing components

            // Try original text first
            if let date = df.date(from: text) {
                return finalizeParsedDate(date)
            }
            // Try lowercased
            if let date = df.date(from: trimmedLower) {
                return finalizeParsedDate(date)
            }
            // Try with first letter capitalized (for month names)
            let capitalized = trimmedLower.prefix(1).uppercased() + trimmedLower.dropFirst()
            if let date = df.date(from: capitalized) {
                return finalizeParsedDate(date)
            }
        }

        return nil
    }

#if DEBUG
    func test_parseNaturalLanguageDateForDateSearch(_ text: String, now: Date) -> Date? {
        parseNaturalLanguageDate(text, now: now)
    }

    func test_parsePlayheadRelativeDateForDateSearch(_ text: String, baseTimestamp: Date) -> Date? {
        parsePlayheadRelativeDate(
            text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            relativeTo: baseTimestamp
        )
    }

    func test_setBoundaryPaginationState(hasMoreOlder: Bool, hasMoreNewer: Bool) {
        self.hasMoreOlder = hasMoreOlder
        self.hasMoreNewer = hasMoreNewer
    }

    func test_loadOlderFrames(reason: String = "test") async {
        await loadOlderFrames(reason: reason, cmdFTrace: nil)
    }

    func test_loadNewerFrames(reason: String = "test") async {
        await loadNewerFrames(reason: reason, cmdFTrace: nil)
    }

    func test_boundaryPaginationState() -> (
        hasMoreOlder: Bool,
        hasMoreNewer: Bool,
        hasReachedAbsoluteStart: Bool,
        hasReachedAbsoluteEnd: Bool
    ) {
        (hasMoreOlder, hasMoreNewer, hasReachedAbsoluteStart, hasReachedAbsoluteEnd)
    }

    func test_updateWindowBoundaries() {
        updateWindowBoundaries()
    }
#endif

    private enum DateSearchAnchorMode: String {
        case exact
        case firstFrameInMinute
        case firstFrameInHour
        case firstFrameInDay
    }

    /// Resolve a parsed date into an anchor timestamp that is better suited for timeline data.
    /// For coarse inputs (e.g. "8 hours ago", "10 minutes ago", "Feb 12"), use the first frame
    /// in that bucket instead of targeting an exact parsed timestamp.
    private func resolveDateSearchAnchorDate(parsedDate: Date, input: String) async throws -> Date {
        let mode = inferDateSearchAnchorMode(for: input)
        guard mode != .exact else { return parsedDate }
        guard let bucket = bucketRange(for: parsedDate, mode: mode) else { return parsedDate }
        Log.info(
            "[DateSearchAnchor] mode=\(mode.rawValue) parsed=\(Log.timestamp(from: parsedDate)) bucket=\(Log.timestamp(from: bucket.start))->\(Log.timestamp(from: bucket.end))",
            category: .ui
        )

        let firstFrame = try await fetchFramesWithVideoInfoLogged(
            from: bucket.start,
            to: bucket.end,
            limit: 1,
            filters: filterCriteria,
            reason: "searchForDate.anchor.\(mode.rawValue)"
        ).first

        guard let anchoredTimestamp = firstFrame?.frame.timestamp else {
            return parsedDate
        }

        return anchoredTimestamp
    }

    private func inferDateSearchAnchorMode(for input: String) -> DateSearchAnchorMode {
        let normalized = input
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let normalizedWithCompactTimes = normalizeCompactTimeFormat(normalized)

        if normalized.range(
            of: #"\b\d+\s*(minute|minutes|min|mins)\s+ago\b"#,
            options: .regularExpression
        ) != nil {
            return .firstFrameInMinute
        }

        if normalized.range(
            of: #"\b\d+\s*(hour|hours|hr|hrs|h)\s+ago\b"#,
            options: .regularExpression
        ) != nil {
            return .firstFrameInHour
        }

        let hasCalendarDateToken = normalized.range(
            of: #"\b(?:jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|jun(?:e)?|jul(?:y)?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)\b|\b\d{1,2}[/-]\d{1,2}(?:[/-]\d{2,4})?\b"#,
            options: .regularExpression
        ) != nil
        let hasDayLevelNaturalLanguageToken = normalized.range(
            of: #"\b(?:today|tomorrow|yesterday|(?:next|last|this)\s+(?:mon(?:day)?|tue(?:s|sday)?|wed(?:nesday)?|thu(?:rs|rsday)?|fri(?:day)?|sat(?:urday)?|sun(?:day)?)|mon(?:day)?|tue(?:s|sday)?|wed(?:nesday)?|thu(?:rs|rsday)?|fri(?:day)?|sat(?:urday)?|sun(?:day)?)\b"#,
            options: .regularExpression
        ) != nil
        let hasDayLevelRelativeOffsetToken = normalized.range(
            of: #"\b(?:in\s+\d+\s*(?:day|days|week|weeks|wk|wks|month|months|mo|mos|year|years|yr|yrs)|\d+\s*(?:day|days|week|weeks|wk|wks|month|months|mo|mos|year|years|yr|yrs)\s*(?:ago|from now))\b"#,
            options: .regularExpression
        ) != nil
        let hasDateLikeToken = hasCalendarDateToken
            || hasDayLevelNaturalLanguageToken
            || hasDayLevelRelativeOffsetToken
        let hasExplicitTime = normalizedWithCompactTimes.range(
            of: #"\b\d{1,2}:\d{2}\b|\b\d{1,2}\s*(am|pm)\b|\b\d{3,4}\s*(am|pm)\b|\bnoon\b|\bmidnight\b"#,
            options: .regularExpression
        ) != nil

        if hasDateLikeToken && !hasExplicitTime {
            return .firstFrameInDay
        }

        return .exact
    }

    private func bucketRange(for date: Date, mode: DateSearchAnchorMode) -> (start: Date, end: Date)? {
        let calendar = Calendar.current
        let interval: DateInterval?

        switch mode {
        case .exact:
            return nil
        case .firstFrameInMinute:
            interval = calendar.dateInterval(of: .minute, for: date)
        case .firstFrameInHour:
            interval = calendar.dateInterval(of: .hour, for: date)
        case .firstFrameInDay:
            interval = calendar.dateInterval(of: .day, for: date)
        }

        guard let interval else { return nil }
        let inclusiveEnd = interval.end.addingTimeInterval(-Self.boundedLoadBoundaryEpsilonSeconds)
        guard inclusiveEnd >= interval.start else { return nil }
        return (start: interval.start, end: inclusiveEnd)
    }

    /// Yearless absolute inputs (e.g. "dec 18 2pm") should prefer recent history for timeline jumps.
    /// If such input parses to a future date, shift it back one year so it lands in the last ~365 days.
    private func adjustYearlessAbsoluteFutureDateToRecentPastIfNeeded(
        _ parsedDate: Date,
        input: String,
        now: Date,
        calendar: Calendar
    ) -> Date {
        guard parsedDate > now else { return parsedDate }
        guard shouldCoerceYearlessAbsoluteDateToPast(input) else { return parsedDate }
        guard let priorYearDate = calendar.date(byAdding: .year, value: -1, to: parsedDate) else {
            return parsedDate
        }
        guard priorYearDate <= now else { return parsedDate }

        let maxRecentWindow: TimeInterval = 366 * 24 * 60 * 60
        guard now.timeIntervalSince(priorYearDate) <= maxRecentWindow else { return parsedDate }

        return priorYearDate
    }

    /// Time-only inputs (e.g. "4pm") should target historical timeline data.
    /// If the parsed time has not happened yet today, shift to the previous day.
    private func adjustTimeOnlyFutureDateToRecentPastIfNeeded(
        _ parsedDate: Date,
        input: String,
        now: Date,
        calendar: Calendar
    ) -> Date {
        guard parsedDate > now else { return parsedDate }
        guard shouldCoerceTimeOnlyDateToPast(input) else { return parsedDate }
        guard let priorDayDate = calendar.date(byAdding: .day, value: -1, to: parsedDate) else {
            return parsedDate
        }
        guard priorDayDate <= now else { return parsedDate }

        return priorDayDate
    }

    private func shouldCoerceYearlessAbsoluteDateToPast(_ input: String) -> Bool {
        // Keep relative expressions as-is (tomorrow/next/last/etc).
        if input.range(
            of: #"\b(today|tomorrow|yesterday|next|last|ago|this|now|tonight)\b|from now"#,
            options: .regularExpression
        ) != nil {
            return false
        }

        // Only coerce yearless month/day style inputs.
        let hasMonthDay = input.range(
            of: #"\b(?:jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|jun(?:e)?|jul(?:y)?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)\b|\b\d{1,2}[/-]\d{1,2}\b"#,
            options: .regularExpression
        ) != nil

        guard hasMonthDay else { return false }

        // If user explicitly gave a year, respect it.
        if input.range(
            of: #"\b\d{4}\b|\b\d{1,2}[/-]\d{1,2}[/-]\d{2,4}\b|\b\d{2,4}[/-]\d{1,2}[/-]\d{1,2}\b"#,
            options: .regularExpression
        ) != nil {
            return false
        }

        return true
    }

    private func shouldCoerceTimeOnlyDateToPast(_ input: String) -> Bool {
        // Keep explicit relative expressions as-is (tomorrow/next/in 2 hours/etc).
        if input.range(
            of: #"\b(today|tomorrow|yesterday|next|last|ago|this|now|tonight|earlier|later|before|after)\b|from now|\bin\s+\d+"#,
            options: .regularExpression
        ) != nil {
            return false
        }

        // If the input includes any explicit calendar date token, this is not a time-only query.
        if input.range(
            of: #"\b(?:jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|jun(?:e)?|jul(?:y)?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)\b|\b\d{1,2}[/-]\d{1,2}(?:[/-]\d{2,4})?\b|\b\d{4}-\d{1,2}-\d{1,2}\b"#,
            options: .regularExpression
        ) != nil {
            return false
        }

        let normalized = input
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"^\s*at\s+"#, with: "", options: .regularExpression)

        return normalized.range(
            of: #"^(?:\d{1,2}(?::\d{2})?\s*(?:am|pm|a|p)?|\d{3,4}\s*(?:am|pm|a|p)?|noon|midnight)$"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    /// Extract first number from a string
    private func extractNumber(from text: String) -> Int? {
        let pattern = "\\d+"
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let range = Range(match.range, in: text) {
            return Int(text[range])
        }
        return nil
    }

    /// Parse time-only input and return a Date for today at that time.
    /// Handles formats like: "938pm", "9:38pm", "938 pm", "9:38 pm", "938", "9:38", "21:38", "2138"
    private func parseTimeOnly(_ text: String, relativeTo now: Date) -> Date? {
        let calendar = Calendar.current
        var input = text.trimmingCharacters(in: .whitespaces)

        // Check for am/pm suffix
        var isPM = false
        var isAM = false
        if input.hasSuffix("pm") || input.hasSuffix("p") {
            isPM = true
            input = input.replacingOccurrences(of: "pm", with: "").replacingOccurrences(of: "p", with: "").trimmingCharacters(in: .whitespaces)
        } else if input.hasSuffix("am") || input.hasSuffix("a") {
            isAM = true
            input = input.replacingOccurrences(of: "am", with: "").replacingOccurrences(of: "a", with: "").trimmingCharacters(in: .whitespaces)
        }

        var hour: Int?
        var minute: Int = 0

        // Try parsing with colon first (e.g., "9:38", "21:38")
        if input.contains(":") {
            let parts = input.split(separator: ":")
            if parts.count == 2,
               let h = Int(parts[0]),
               let m = Int(parts[1]),
               h >= 0 && h <= 23 && m >= 0 && m <= 59 {
                hour = h
                minute = m
            }
        } else if let numericValue = Int(input) {
            // Parse compact format (e.g., "938", "1430", "9")
            if numericValue >= 0 && numericValue <= 23 {
                // Single or double digit hour (e.g., "9" or "21")
                hour = numericValue
                minute = 0
            } else if numericValue >= 100 && numericValue <= 2359 {
                // 3-4 digit time (e.g., "938" -> 9:38, "1430" -> 14:30)
                hour = numericValue / 100
                minute = numericValue % 100
                // Validate
                if hour! > 23 || minute > 59 {
                    return nil
                }
            } else {
                return nil
            }
        }

        guard var finalHour = hour else { return nil }

        // Apply AM/PM conversion
        if isPM && finalHour < 12 {
            finalHour += 12
        } else if isAM && finalHour == 12 {
            finalHour = 0
        }

        // If no AM/PM specified and hour is small, could be either - assume as-is
        // (e.g., "9" without am/pm stays as 9:00 AM, "21" stays as 21:00)

        // Build the date for today at that time
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = finalHour
        components.minute = minute
        components.second = 0

        return calendar.date(from: components)
    }

    /// Normalize compact time formats in a string to colon format for NSDataDetector
    /// Converts:
    /// - "827am" -> "8:27am", "1130pm" -> "11:30pm"
    /// - "feb 28 1417" -> "feb 28 14:17" (for date-jump compact 24-hour time)
    private func normalizeCompactTimeFormat(_ text: String) -> String {
        // Pattern matches 3-4 digit numbers followed immediately by am/pm (with optional space)
        // Examples: "827am", "827 am", "1130pm", "1130 pm"
        let pattern = #"(\d{3,4})\s*(am|pm)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return text
        }

        var result = text
        let range = NSRange(text.startIndex..., in: text)

        // Find all matches and replace from end to start to preserve indices
        let matches = regex.matches(in: text, options: [], range: range)
        for match in matches.reversed() {
            guard let numberRange = Range(match.range(at: 1), in: result),
                  let suffixRange = Range(match.range(at: 2), in: result) else {
                continue
            }

            let numberStr = String(result[numberRange])
            let suffix = String(result[suffixRange])

            guard let numericValue = Int(numberStr) else { continue }

            // Extract hour and minute from compact format
            let hour: Int
            let minute: Int
            if numericValue >= 100 && numericValue <= 1259 {
                // 3-4 digit time (e.g., 827 -> 8:27, 1130 -> 11:30)
                hour = numericValue / 100
                minute = numericValue % 100
            } else {
                continue // Invalid format
            }

            // Validate
            guard hour >= 1 && hour <= 12 && minute >= 0 && minute <= 59 else {
                continue
            }

            // Build normalized time string
            let normalizedTime = "\(hour):\(String(format: "%02d", minute))\(suffix)"

            // Replace in result
            let fullMatchRange = Range(match.range, in: result)!
            result.replaceSubrange(fullMatchRange, with: normalizedTime)
        }

        // Support compact 24-hour time token in date context:
        // "feb 28 1417" -> "feb 28 14:17"
        if let trailingCompactRange = result.range(
            of: #"\b\d{3,4}\b$"#,
            options: [.regularExpression, .caseInsensitive]
        ) {
            let token = String(result[trailingCompactRange])
            if let numericValue = Int(token), numericValue >= 100, numericValue <= 2359 {
                let hour = numericValue / 100
                let minute = numericValue % 100
                let isPlausibleModernYear = (1900...2100).contains(numericValue)
                if hour <= 23 && minute <= 59 && !isPlausibleModernYear {
                    let prefix = String(result[..<trailingCompactRange.lowerBound])
                    let hasDateContext = prefix.range(
                        of: #"\b(?:jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|jun(?:e)?|jul(?:y)?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?|today|tomorrow|yesterday|(?:next|last|this)\s+(?:mon(?:day)?|tue(?:s|sday)?|wed(?:nesday)?|thu(?:rs|rsday)?|fri(?:day)?|sat(?:urday)?|sun(?:day)?))\b|\b\d{1,2}[/-]\d{1,2}(?:[/-]\d{2,4})?\b|\b\d{4}-\d{1,2}-\d{1,2}\b"#,
                        options: [.regularExpression, .caseInsensitive]
                    ) != nil
                    if hasDateContext {
                        let normalizedTime = "\(hour):\(String(format: "%02d", minute))"
                        result = prefix + normalizedTime
                    }
                }
            }
        }

        return result
    }

    /// Find the frame index closest to a target date
    private func findClosestFrameIndex(to targetDate: Date) -> Int {
        Self.findClosestFrameIndex(in: frames, to: targetDate)
    }

    /// Find the closest frame index in an arbitrary timeline frame window.
    private static func findClosestFrameIndex(in timelineFrames: [TimelineFrame], to targetDate: Date) -> Int {
        guard !timelineFrames.isEmpty else { return 0 }

        var closestIndex = 0
        var smallestDiff = abs(timelineFrames[0].frame.timestamp.timeIntervalSince(targetDate))

        for (index, timelineFrame) in timelineFrames.enumerated() {
            let diff = abs(timelineFrame.frame.timestamp.timeIntervalSince(targetDate))
            if diff < smallestDiff {
                smallestDiff = diff
                closestIndex = index
            }
        }

        return closestIndex
    }

    // MARK: - Private Helpers

    /// Minimum gap in seconds to show a gap indicator (2 minutes)
    private nonisolated static let minimumGapThreshold: TimeInterval = 120
    /// Small epsilon to avoid re-fetching the boundary frame in bounded load-more queries.
    private static let boundedLoadBoundaryEpsilonSeconds: TimeInterval = 0.001

    /// Convert Date to truncated millisecond epoch, matching DB binding semantics.
    private func timestampMilliseconds(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970 * 1000)
    }

    /// Create Date from millisecond epoch exactly (avoids floating-point drift around boundaries).
    private func dateFromMilliseconds(_ milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000.0)
    }

    private func oneMillisecondAfter(_ date: Date) -> Date {
        dateFromMilliseconds(timestampMilliseconds(date) + 1)
    }

    private func oneMillisecondBefore(_ date: Date) -> Date {
        dateFromMilliseconds(timestampMilliseconds(date) - 1)
    }

    /// Group consecutive frames into blocks, splitting on app change OR time gaps ≥2 min
    private func groupFramesIntoBlocks() -> [AppBlock] {
        Self.buildAppBlockSnapshot(
            from: makeSnapshotFrameInputs(from: frames),
            segmentTagsMap: segmentTagsMap,
            segmentCommentCountsMap: segmentCommentCountsMap,
            hiddenTagID: cachedHiddenTagIDValue
        ).blocks
    }

    // MARK: - Infinite Scroll

    /// Update window boundary timestamps from current frames
    private func updateWindowBoundaries() {
        oldestLoadedTimestamp = frames.first?.frame.timestamp
        newestLoadedTimestamp = frames.last?.frame.timestamp

        if let oldest = oldestLoadedTimestamp, let newest = newestLoadedTimestamp {
            Log.debug("[InfiniteScroll] Window boundaries: \(oldest) to \(newest)", category: .ui)
        }
    }

    private struct EdgeBlockSummary {
        let bundleID: String?
        let startIndex: Int
        let endIndex: Int
        let frameCount: Int
        let startTimestamp: Date
        let endTimestamp: Date
    }

    /// Summarize the newest (right-edge) app block using the same split rules as tape blocks:
    /// app change OR significant gap.
    private func newestEdgeBlockSummary(in frameList: [TimelineFrame]) -> EdgeBlockSummary? {
        guard !frameList.isEmpty else { return nil }

        let endIndex = frameList.count - 1
        let bundleID = frameList[endIndex].frame.metadata.appBundleID
        var startIndex = endIndex

        while startIndex > 0 {
            let current = frameList[startIndex]
            let previous = frameList[startIndex - 1]
            let appChanged = previous.frame.metadata.appBundleID != bundleID
            let hasSignificantGap = current.frame.timestamp.timeIntervalSince(previous.frame.timestamp) >= Self.minimumGapThreshold
            if appChanged || hasSignificantGap {
                break
            }
            startIndex -= 1
        }

        return EdgeBlockSummary(
            bundleID: bundleID,
            startIndex: startIndex,
            endIndex: endIndex,
            frameCount: endIndex - startIndex + 1,
            startTimestamp: frameList[startIndex].frame.timestamp,
            endTimestamp: frameList[endIndex].frame.timestamp
        )
    }

    private func summarizeEdgeBlock(_ block: EdgeBlockSummary?) -> String {
        guard let block else { return "none" }
        let bundle = block.bundleID ?? "nil"
        let start = Log.timestamp(from: block.startTimestamp)
        let end = Log.timestamp(from: block.endTimestamp)
        return "bundle=\(bundle) range=\(block.startIndex)-\(block.endIndex) frames=\(block.frameCount) ts=\(start)->\(end)"
    }

    private func logNewestEdgeBlockTransition(
        context: String,
        reason: String,
        before: EdgeBlockSummary?,
        after: EdgeBlockSummary?,
        appendedCount: Int
    ) {
        guard let after else { return }

        if let before,
           before.bundleID == after.bundleID,
           after.frameCount > before.frameCount {
            let growth = after.frameCount - before.frameCount
            Log.info(
                "[TIMELINE-BLOCK] \(context) reason=\(reason) newestBlockGrewBy=\(growth) appended=\(appendedCount) before={\(summarizeEdgeBlock(before))} after={\(summarizeEdgeBlock(after))}",
                category: .ui
            )
            return
        }

        Log.info(
            "[TIMELINE-BLOCK] \(context) reason=\(reason) newestBlockChanged appended=\(appendedCount) before={\(summarizeEdgeBlock(before))} after={\(summarizeEdgeBlock(after))}",
            category: .ui
        )
    }

    private struct BoundaryLoadTrigger: Sendable {
        let older: Bool
        let newer: Bool

        var any: Bool {
            older || newer
        }
    }

    private func makeBoundedBoundaryFilters(rangeStart: Date, rangeEnd: Date) -> FilterCriteria? {
        var boundedFilters = filterCriteria
        let effectiveStart = max(rangeStart, boundedFilters.startDate ?? rangeStart)
        let effectiveEnd = min(rangeEnd, boundedFilters.endDate ?? rangeEnd)

        guard effectiveStart <= effectiveEnd else {
            return nil
        }

        boundedFilters.startDate = effectiveStart
        boundedFilters.endDate = effectiveEnd
        return boundedFilters
    }

    /// Check if we need to load more frames based on current position.
    /// Returns which boundary loads were triggered.
    @discardableResult
    private func checkAndLoadMoreFrames(
        reason: String = "unspecified",
        cmdFTrace: CmdFQuickFilterLatencyTrace? = nil
    ) -> BoundaryLoadTrigger {
        let shouldLoadOlder = currentIndex < WindowConfig.loadThreshold && hasMoreOlder && !isLoadingOlder
        let shouldLoadNewer = currentIndex > frames.count - WindowConfig.loadThreshold && hasMoreNewer && !isLoadingNewer

        if let cmdFTrace {
            let maxIndex = max(frames.count - 1, 0)
            Log.info(
                "[CmdFPerf][\(cmdFTrace.id)] Boundary check reason=\(reason) index=\(currentIndex)/\(maxIndex) threshold=\(WindowConfig.loadThreshold) loadOlder=\(shouldLoadOlder) loadNewer=\(shouldLoadNewer)",
                category: .ui
            )
        }

        if shouldLoadOlder {
            olderBoundaryLoadTask?.cancel()
            olderBoundaryLoadTask = Task { [weak self] in
                guard let self else { return }
                await self.loadOlderFrames(reason: reason, cmdFTrace: cmdFTrace)
            }
        }

        if shouldLoadNewer {
            newerBoundaryLoadTask?.cancel()
            newerBoundaryLoadTask = Task { [weak self] in
                guard let self else { return }
                await self.loadNewerFrames(reason: reason, cmdFTrace: cmdFTrace)
            }
        }

        return BoundaryLoadTrigger(older: shouldLoadOlder, newer: shouldLoadNewer)
    }

    /// Load older frames (before the oldest loaded timestamp).
    private func loadOlderFrames(
        reason: String = "unspecified",
        cmdFTrace: CmdFQuickFilterLatencyTrace? = nil
    ) async {
        guard let oldestTimestamp = oldestLoadedTimestamp else { return }
        guard !isLoadingOlder else { return }
        guard !Task.isCancelled else { return }

        let loadStart = CFAbsoluteTimeGetCurrent()
        isLoadingOlder = true
        defer { olderBoundaryLoadTask = nil }
        Log.debug("[InfiniteScroll] Loading older frames before \(oldestTimestamp)...", category: .ui)
        if let cmdFTrace {
            Log.info("[CmdFPerf][\(cmdFTrace.id)] Boundary older load started reason=\(reason) oldest=\(oldestTimestamp)", category: .ui)
        }

        do {
            // Query frames before the oldest timestamp
            // Use a bounded window to avoid expensive full-history scans.
            // Always pass filterCriteria to ensure hidden filter is applied (default: .hide)
            let rangeEnd = oneMillisecondBefore(oldestTimestamp)
            let hasMetadataFilter = filterCriteria.windowNameFilter?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                || filterCriteria.browserUrlFilter?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false

            let queryFilters: FilterCriteria
            if hasMetadataFilter {
                // Metadata filters can be very sparse; avoid a narrow one-day probe so we can jump large gaps.
                var metadataFilters = filterCriteria
                if let explicitEnd = metadataFilters.endDate {
                    metadataFilters.endDate = min(explicitEnd, rangeEnd)
                } else {
                    metadataFilters.endDate = rangeEnd
                }
                queryFilters = metadataFilters
                let effectiveStart = queryFilters.startDate.map { Log.timestamp(from: $0) } ?? "unbounded"
                let effectiveEnd = queryFilters.endDate.map { Log.timestamp(from: $0) } ?? Log.timestamp(from: rangeEnd)
                Log.info(
                    "[BoundaryOlder] START reason=\(reason) strategy=metadata-unbounded effectiveWindow=\(effectiveStart)->\(effectiveEnd) currentOldest=\(Log.timestamp(from: oldestTimestamp))",
                    category: .ui
                )
            } else {
                let rangeStart = rangeEnd.addingTimeInterval(-WindowConfig.loadWindowSpanSeconds)
                guard let boundedFilters = makeBoundedBoundaryFilters(rangeStart: rangeStart, rangeEnd: rangeEnd) else {
                    Log.info(
                        "[BoundaryOlder] SKIP reason=\(reason) window=\(Log.timestamp(from: rangeStart))->\(Log.timestamp(from: rangeEnd)) no-overlap-with-filters",
                        category: .ui
                    )
                    hasMoreOlder = false
                    hasReachedAbsoluteStart = true
                    isLoadingOlder = false
                    return
                }
                queryFilters = boundedFilters
                Log.info(
                    "[BoundaryOlder] START reason=\(reason) strategy=windowed window=\(Log.timestamp(from: rangeStart))->\(Log.timestamp(from: rangeEnd)) effectiveWindow=\(Log.timestamp(from: boundedFilters.startDate ?? rangeStart))->\(Log.timestamp(from: boundedFilters.endDate ?? rangeEnd)) currentOldest=\(Log.timestamp(from: oldestTimestamp))",
                    category: .ui
                )
            }
            let queryStart = CFAbsoluteTimeGetCurrent()
            var framesWithVideoInfoDescending = try await fetchFramesWithVideoInfoBeforeLogged(
                timestamp: oldestTimestamp,
                limit: WindowConfig.loadBatchSize,
                filters: queryFilters,
                reason: "loadOlderFrames.reason=\(reason)"
            )
            let queryElapsedMs = (CFAbsoluteTimeGetCurrent() - queryStart) * 1000

            if Task.isCancelled {
                isLoadingOlder = false
                return
            }

            if let nearest = framesWithVideoInfoDescending.first, let farthest = framesWithVideoInfoDescending.last {
                Log.info(
                    "[BoundaryOlder] RESULT reason=\(reason) count=\(framesWithVideoInfoDescending.count) nearest=\(Log.timestamp(from: nearest.frame.timestamp)) farthest=\(Log.timestamp(from: farthest.frame.timestamp)) query=\(String(format: "%.1f", queryElapsedMs))ms",
                    category: .ui
                )
            } else {
                Log.info(
                    "[BoundaryOlder] RESULT reason=\(reason) count=0 query=\(String(format: "%.1f", queryElapsedMs))ms",
                    category: .ui
                )
            }

            if framesWithVideoInfoDescending.isEmpty, !hasMetadataFilter {
                Log.info(
                    "[BoundaryOlder] FALLBACK_START reason=\(reason) strategy=nearest before=\(Log.timestamp(from: oldestTimestamp)) limit=\(WindowConfig.nearestFallbackBatchSize)",
                    category: .ui
                )
                let fallbackStart = CFAbsoluteTimeGetCurrent()
                framesWithVideoInfoDescending = try await fetchFramesWithVideoInfoBeforeLogged(
                    timestamp: oldestTimestamp,
                    limit: WindowConfig.nearestFallbackBatchSize,
                    filters: filterCriteria,
                    reason: "loadOlderFrames.reason=\(reason).nearestFallback"
                )
                let fallbackElapsedMs = (CFAbsoluteTimeGetCurrent() - fallbackStart) * 1000

                if let nearest = framesWithVideoInfoDescending.first, let farthest = framesWithVideoInfoDescending.last {
                    Log.info(
                        "[BoundaryOlder] FALLBACK_RESULT reason=\(reason) count=\(framesWithVideoInfoDescending.count) nearest=\(Log.timestamp(from: nearest.frame.timestamp)) farthest=\(Log.timestamp(from: farthest.frame.timestamp)) query=\(String(format: "%.1f", fallbackElapsedMs))ms",
                        category: .ui
                    )
                } else {
                    Log.info(
                        "[BoundaryOlder] FALLBACK_RESULT reason=\(reason) count=0 query=\(String(format: "%.1f", fallbackElapsedMs))ms",
                        category: .ui
                    )
                }
            }

            guard !framesWithVideoInfoDescending.isEmpty else {
                Log.debug("[InfiniteScroll] No more older frames available - reached absolute start", category: .ui)
                hasMoreOlder = false
                hasReachedAbsoluteStart = true  // Mark that we've hit the absolute start
                isLoadingOlder = false

                if let cmdFTrace {
                    let loadElapsedMs = (CFAbsoluteTimeGetCurrent() - loadStart) * 1000
                    let totalFromShortcutMs = (CFAbsoluteTimeGetCurrent() - cmdFTrace.startedAt) * 1000
                    Log.recordLatency(
                        "timeline.cmdf.quick_filter.boundary.older_ms",
                        valueMs: loadElapsedMs,
                        category: .ui,
                        summaryEvery: 5,
                        warningThresholdMs: 220,
                        criticalThresholdMs: 500
                    )
                    Log.info(
                        "[CmdFPerf][\(cmdFTrace.id)] Boundary older load complete (empty) reason=\(reason) query=\(String(format: "%.1f", queryElapsedMs))ms load=\(String(format: "%.1f", loadElapsedMs))ms total=\(String(format: "%.1f", totalFromShortcutMs))ms",
                        category: .ui
                    )
                }
                return
            }

            Log.debug("[InfiniteScroll] Got \(framesWithVideoInfoDescending.count) older frames", category: .ui)

            // getFramesWithVideoInfoBefore returns DESC (nearest older first). Reverse to ASC before prepending.
            let newTimelineFrames = framesWithVideoInfoDescending.reversed().map {
                TimelineFrame(frameWithVideoInfo: $0)
            }

            // If timeline state changed while the query was in-flight (filter/apply/reload), drop stale results.
            guard let currentOldest = frames.first?.frame.timestamp else {
                Log.warning(
                    "[BoundaryOlder] ABORT reason=\(reason) staleResult=frameBufferClearedWhileLoading",
                    category: .ui
                )
                isLoadingOlder = false
                return
            }
            let oldestDriftMs = abs(currentOldest.timeIntervalSince(oldestTimestamp) * 1000)
            if oldestDriftMs > 1 {
                Log.info(
                    "[BoundaryOlder] ABORT reason=\(reason) staleResult=oldestChanged old=\(Log.timestamp(from: oldestTimestamp)) current=\(Log.timestamp(from: currentOldest)) driftMs=\(String(format: "%.1f", oldestDriftMs))",
                    category: .ui
                )
                isLoadingOlder = false
                return
            }

            // Prepend to existing frames
            // Use insert(contentsOf:) to avoid unnecessary @Published triggers
            let beforeCount = frames.count
            let clampedCurrentIndex = min(max(currentIndex, 0), max(0, beforeCount - 1))
            if clampedCurrentIndex != currentIndex {
                Log.warning(
                    "[BoundaryOlder] Clamping invalid currentIndex reason=\(reason) oldIndex=\(currentIndex) frameCount=\(beforeCount) clamped=\(clampedCurrentIndex)",
                    category: .ui
                )
                currentIndex = clampedCurrentIndex
            }
            let oldCurrentIndex = currentIndex
            let oldTimestamp = frames[oldCurrentIndex].frame.timestamp
            let oldFirstTimestamp = currentOldest

            frames.insert(contentsOf: newTimelineFrames, at: 0)

            // Adjust currentIndex to maintain position
            currentIndex = oldCurrentIndex + newTimelineFrames.count
            logCmdFPlayheadState(
                "boundary.older.indexAdjusted",
                trace: cmdFTrace,
                extra: "reason=\(reason) oldIndex=\(oldCurrentIndex) added=\(newTimelineFrames.count)"
            )

            Log.info("[Memory] LOADED OLDER: +\(newTimelineFrames.count) frames (\(beforeCount)→\(frames.count)), index adjusted from \(oldCurrentIndex) to \(currentIndex), maintaining timestamp=\(oldTimestamp)", category: .ui)
            Log.info("[INFINITE-SCROLL] After load older: new first frame=\(frames.first?.frame.timestamp.description ?? "nil"), new last frame=\(frames.last?.frame.timestamp.description ?? "nil")", category: .ui)
            if let bridge = newTimelineFrames.last?.frame.timestamp {
                let bridgeGap = max(0, oldFirstTimestamp.timeIntervalSince(bridge))
                Log.info(
                    "[BoundaryOlder] MERGE reason=\(reason) bridgeGap=\(String(format: "%.1fs", bridgeGap)) oldFirst=\(Log.timestamp(from: oldFirstTimestamp)) insertedLast=\(Log.timestamp(from: bridge))",
                    category: .ui
                )
            }
            MemoryTracker.logMemoryState(
                context: "AFTER LOAD OLDER",
                frameCount: frames.count,
                frameBufferCount: diskFrameBufferIndex.count,
                oldestTimestamp: oldestLoadedTimestamp,
                newestTimestamp: newestLoadedTimestamp
            )

            // Update window boundaries
            updateWindowBoundaries()

            // Trim if we've exceeded max frames
            trimWindowIfNeeded(preserveDirection: .older)

            isLoadingOlder = false

            if let cmdFTrace {
                let loadElapsedMs = (CFAbsoluteTimeGetCurrent() - loadStart) * 1000
                let totalFromShortcutMs = (CFAbsoluteTimeGetCurrent() - cmdFTrace.startedAt) * 1000
                Log.recordLatency(
                    "timeline.cmdf.quick_filter.boundary.older_ms",
                    valueMs: loadElapsedMs,
                    category: .ui,
                    summaryEvery: 5,
                    warningThresholdMs: 220,
                    criticalThresholdMs: 500
                )
                Log.info(
                    "[CmdFPerf][\(cmdFTrace.id)] Boundary older load complete reason=\(reason) query=\(String(format: "%.1f", queryElapsedMs))ms load=\(String(format: "%.1f", loadElapsedMs))ms added=\(newTimelineFrames.count) total=\(String(format: "%.1f", totalFromShortcutMs))ms",
                    category: .ui
                )
            }

        } catch {
            Log.error("[InfiniteScroll] Error loading older frames: \(error)", category: .ui)
            if let cmdFTrace {
                let loadElapsedMs = (CFAbsoluteTimeGetCurrent() - loadStart) * 1000
                Log.error(
                    "[CmdFPerf][\(cmdFTrace.id)] Boundary older load failed reason=\(reason) after \(String(format: "%.1f", loadElapsedMs))ms: \(error)",
                    category: .ui
                )
            }
            isLoadingOlder = false
        }
    }

    /// Load newer frames (after the newest loaded timestamp).
    private func loadNewerFrames(
        reason: String = "unspecified",
        cmdFTrace: CmdFQuickFilterLatencyTrace? = nil
    ) async {
        guard let newestTimestamp = newestLoadedTimestamp else { return }
        guard !isLoadingNewer else { return }
        guard !Task.isCancelled else { return }

        let loadStart = CFAbsoluteTimeGetCurrent()
        isLoadingNewer = true
        defer { newerBoundaryLoadTask = nil }
        Log.debug("[InfiniteScroll] Loading newer frames after \(newestTimestamp)...", category: .ui)
        if let cmdFTrace {
            Log.info("[CmdFPerf][\(cmdFTrace.id)] Boundary newer load started reason=\(reason) newest=\(newestTimestamp)", category: .ui)
        }

        do {
            // Query frames after the newest timestamp
            // Use a bounded window to avoid expensive full-future scans.
            // Always pass filterCriteria to ensure hidden filter is applied (default: .hide)
            let rangeStart = oneMillisecondAfter(newestTimestamp)
            let rangeEnd = rangeStart.addingTimeInterval(WindowConfig.loadWindowSpanSeconds)
            Log.info(
                "[BoundaryNewer] START reason=\(reason) window=\(Log.timestamp(from: rangeStart))->\(Log.timestamp(from: rangeEnd)) currentNewest=\(Log.timestamp(from: newestTimestamp))",
                category: .ui
            )
            let queryStart = CFAbsoluteTimeGetCurrent()
            var framesWithVideoInfo = try await fetchFramesWithVideoInfoLogged(
                from: rangeStart,
                to: rangeEnd,
                limit: WindowConfig.loadBatchSize,
                filters: filterCriteria,
                reason: "loadNewerFrames.reason=\(reason)"
            )
            let queryElapsedMs = (CFAbsoluteTimeGetCurrent() - queryStart) * 1000

            if Task.isCancelled {
                isLoadingNewer = false
                return
            }

            if let first = framesWithVideoInfo.first, let last = framesWithVideoInfo.last {
                Log.info(
                    "[BoundaryNewer] RESULT reason=\(reason) count=\(framesWithVideoInfo.count) first=\(Log.timestamp(from: first.frame.timestamp)) last=\(Log.timestamp(from: last.frame.timestamp)) query=\(String(format: "%.1f", queryElapsedMs))ms",
                    category: .ui
                )
            } else {
                Log.info(
                    "[BoundaryNewer] RESULT reason=\(reason) count=0 query=\(String(format: "%.1f", queryElapsedMs))ms",
                    category: .ui
                )
            }

            if framesWithVideoInfo.isEmpty {
                Log.info(
                    "[BoundaryNewer] FALLBACK_START reason=\(reason) strategy=nearest after=\(Log.timestamp(from: newestTimestamp)) limit=\(WindowConfig.nearestFallbackBatchSize)",
                    category: .ui
                )
                let fallbackStart = CFAbsoluteTimeGetCurrent()
                framesWithVideoInfo = try await fetchFramesWithVideoInfoAfterLogged(
                    timestamp: newestTimestamp,
                    limit: WindowConfig.nearestFallbackBatchSize,
                    filters: filterCriteria,
                    reason: "loadNewerFrames.reason=\(reason).nearestFallback"
                )
                let fallbackElapsedMs = (CFAbsoluteTimeGetCurrent() - fallbackStart) * 1000

                if let first = framesWithVideoInfo.first, let last = framesWithVideoInfo.last {
                    Log.info(
                        "[BoundaryNewer] FALLBACK_RESULT reason=\(reason) count=\(framesWithVideoInfo.count) first=\(Log.timestamp(from: first.frame.timestamp)) last=\(Log.timestamp(from: last.frame.timestamp)) query=\(String(format: "%.1f", fallbackElapsedMs))ms",
                        category: .ui
                    )
                } else {
                    Log.info(
                        "[BoundaryNewer] FALLBACK_RESULT reason=\(reason) count=0 query=\(String(format: "%.1f", fallbackElapsedMs))ms",
                        category: .ui
                    )
                }
            }

            guard !framesWithVideoInfo.isEmpty else {
                Log.debug("[InfiniteScroll] No more newer frames available - reached absolute end", category: .ui)
                hasMoreNewer = false
                hasReachedAbsoluteEnd = true  // Mark that we've hit the absolute end
                isLoadingNewer = false

                if let cmdFTrace {
                    let loadElapsedMs = (CFAbsoluteTimeGetCurrent() - loadStart) * 1000
                    let totalFromShortcutMs = (CFAbsoluteTimeGetCurrent() - cmdFTrace.startedAt) * 1000
                    Log.recordLatency(
                        "timeline.cmdf.quick_filter.boundary.newer_ms",
                        valueMs: loadElapsedMs,
                        category: .ui,
                        summaryEvery: 5,
                        warningThresholdMs: 220,
                        criticalThresholdMs: 500
                    )
                    Log.info(
                        "[CmdFPerf][\(cmdFTrace.id)] Boundary newer load complete (empty) reason=\(reason) query=\(String(format: "%.1f", queryElapsedMs))ms load=\(String(format: "%.1f", loadElapsedMs))ms total=\(String(format: "%.1f", totalFromShortcutMs))ms",
                        category: .ui
                    )
                }
                return
            }

            Log.debug("[InfiniteScroll] Got \(framesWithVideoInfo.count) newer frames", category: .ui)

            // Convert to TimelineFrame - video info is already included from the JOIN
            // framesWithVideoInfo are returned ASC (oldest first), which is correct for appending
            let newTimelineFrames = framesWithVideoInfo.map { TimelineFrame(frameWithVideoInfo: $0) }

            let existingFrameIDs = Set(frames.map { $0.frame.id })
            let uniqueTimelineFrames = newTimelineFrames.filter { !existingFrameIDs.contains($0.frame.id) }
            let duplicateCount = newTimelineFrames.count - uniqueTimelineFrames.count

            if uniqueTimelineFrames.isEmpty {
                let newestFrameID = frames.last?.frame.id.value ?? -1
                let duplicateFrameID = newTimelineFrames.first?.frame.id.value ?? -1
                Log.warning(
                    "[BoundaryNewer] Duplicate-only result reason=\(reason) count=\(newTimelineFrames.count) newestFrameID=\(newestFrameID) duplicateFrameID=\(duplicateFrameID) newestTs=\(Log.timestamp(from: newestTimestamp)); marking end to stop retry loop",
                    category: .ui
                )
                hasMoreNewer = false
                hasReachedAbsoluteEnd = true
                isLoadingNewer = false
                return
            }

            if duplicateCount > 0 {
                Log.warning(
                    "[BoundaryNewer] Dropping \(duplicateCount)/\(newTimelineFrames.count) duplicate frame(s) reason=\(reason)",
                    category: .ui
                )
            }

            // Append to existing frames
            // Use append(contentsOf:) to avoid unnecessary @Published triggers
            let beforeCount = frames.count
            let wasAtNewestBeforeAppend = currentIndex >= beforeCount - 1
            let oldLastTimestamp = frames.last?.frame.timestamp
            let previousNewestBlock = newestEdgeBlockSummary(in: frames)
            frames.append(contentsOf: uniqueTimelineFrames)

            // Keep playhead pinned to "now" when the user was already at the live edge.
            if wasAtNewestBeforeAppend {
                currentIndex = frames.count - 1
                subFrameOffset = 0
            }
            logCmdFPlayheadState(
                "boundary.newer.appended",
                trace: cmdFTrace,
                extra: "reason=\(reason) added=\(uniqueTimelineFrames.count) pinnedToNewest=\(wasAtNewestBeforeAppend)"
            )

            let currentNewestBlock = newestEdgeBlockSummary(in: frames)
            logNewestEdgeBlockTransition(
                context: "boundary-newer",
                reason: reason,
                before: previousNewestBlock,
                after: currentNewestBlock,
                appendedCount: uniqueTimelineFrames.count
            )

            Log.info("[Memory] LOADED NEWER: +\(uniqueTimelineFrames.count) frames (\(beforeCount)→\(frames.count))", category: .ui)
            if let oldLastTimestamp, let bridge = uniqueTimelineFrames.first?.frame.timestamp {
                let bridgeGap = max(0, bridge.timeIntervalSince(oldLastTimestamp))
                Log.info(
                    "[BoundaryNewer] MERGE reason=\(reason) bridgeGap=\(String(format: "%.1fs", bridgeGap)) oldLast=\(Log.timestamp(from: oldLastTimestamp)) insertedFirst=\(Log.timestamp(from: bridge))",
                    category: .ui
                )
            }
            MemoryTracker.logMemoryState(
                context: "AFTER LOAD NEWER",
                frameCount: frames.count,
                frameBufferCount: diskFrameBufferIndex.count,
                oldestTimestamp: oldestLoadedTimestamp,
                newestTimestamp: newestLoadedTimestamp
            )

            // Update window boundaries
            updateWindowBoundaries()

            // Trim if we've exceeded max frames
            trimWindowIfNeeded(preserveDirection: .newer)

            isLoadingNewer = false

            if let cmdFTrace {
                let loadElapsedMs = (CFAbsoluteTimeGetCurrent() - loadStart) * 1000
                let totalFromShortcutMs = (CFAbsoluteTimeGetCurrent() - cmdFTrace.startedAt) * 1000
                Log.recordLatency(
                    "timeline.cmdf.quick_filter.boundary.newer_ms",
                    valueMs: loadElapsedMs,
                    category: .ui,
                    summaryEvery: 5,
                    warningThresholdMs: 220,
                    criticalThresholdMs: 500
                )
                Log.info(
                    "[CmdFPerf][\(cmdFTrace.id)] Boundary newer load complete reason=\(reason) query=\(String(format: "%.1f", queryElapsedMs))ms load=\(String(format: "%.1f", loadElapsedMs))ms added=\(uniqueTimelineFrames.count) total=\(String(format: "%.1f", totalFromShortcutMs))ms",
                    category: .ui
                )
            }

        } catch {
            Log.error("[InfiniteScroll] Error loading newer frames: \(error)", category: .ui)
            if let cmdFTrace {
                let loadElapsedMs = (CFAbsoluteTimeGetCurrent() - loadStart) * 1000
                Log.error(
                    "[CmdFPerf][\(cmdFTrace.id)] Boundary newer load failed reason=\(reason) after \(String(format: "%.1f", loadElapsedMs))ms: \(error)",
                    category: .ui
                )
            }
            isLoadingNewer = false
        }
    }

    /// Direction to preserve when trimming
    private enum TrimDirection {
        case older  // Preserve older frames, trim newer
        case newer  // Preserve newer frames, trim older
    }

    private func trimDirectionLabel(_ direction: TrimDirection) -> String {
        switch direction {
        case .older:
            return "older"
        case .newer:
            return "newer"
        }
    }

    private func applyDeferredTrimIfNeeded(trigger: String) {
        guard let deferredDirection = deferredTrimDirection else { return }

        let anchorFrameID = deferredTrimAnchorFrameID
        let anchorTimestamp = deferredTrimAnchorTimestamp
        deferredTrimDirection = nil
        deferredTrimAnchorFrameID = nil
        deferredTrimAnchorTimestamp = nil

        guard frames.count > WindowConfig.maxFrames else { return }

        Log.info(
            "[Memory] APPLYING deferred trim trigger=\(trigger) direction=\(trimDirectionLabel(deferredDirection)) frames=\(frames.count)",
            category: .ui
        )
        trimWindowIfNeeded(
            preserveDirection: deferredDirection,
            anchorFrameID: anchorFrameID,
            anchorTimestamp: anchorTimestamp,
            reason: "deferred.\(trigger)",
            allowDeferral: false
        )
    }

    private func updateDeferredTrimAnchorForCurrentSelectionIfNeeded() {
        guard isActivelyScrolling, deferredTrimDirection == .newer else { return }
        guard let currentFrame = currentTimelineFrame?.frame else { return }

        deferredTrimAnchorFrameID = currentFrame.id
        deferredTrimAnchorTimestamp = currentFrame.timestamp
    }

    /// Trim the window if it exceeds max frames
    private func trimWindowIfNeeded(
        preserveDirection: TrimDirection,
        anchorFrameID: FrameID? = nil,
        anchorTimestamp: Date? = nil,
        reason: String = "unspecified",
        allowDeferral: Bool = true
    ) {
        guard frames.count > WindowConfig.maxFrames else { return }

        if allowDeferral, preserveDirection == .newer, isActivelyScrolling {
            deferredTrimDirection = preserveDirection
            deferredTrimAnchorFrameID = anchorFrameID ?? currentTimelineFrame?.frame.id
            deferredTrimAnchorTimestamp = anchorTimestamp ?? currentTimelineFrame?.frame.timestamp
            let anchorIDValue = deferredTrimAnchorFrameID?.value ?? -1
            let anchorTS = deferredTrimAnchorTimestamp.map { Log.timestamp(from: $0) } ?? "nil"
            Log.info(
                "[Memory] DEFERRING trim direction=\(trimDirectionLabel(preserveDirection)) reason=\(reason) frames=\(frames.count) anchorFrameID=\(anchorIDValue) anchorTs=\(anchorTS)",
                category: .ui
            )
            return
        }

        let excessCount = frames.count - WindowConfig.maxFrames
        let beforeCount = frames.count

        switch preserveDirection {
        case .older:
            // User is scrolling toward older, trim newer frames from end
            Log.info("[Memory] TRIMMING \(excessCount) newer frames from END (preserving older) reason=\(reason)", category: .ui)
            frames = Array(frames.dropLast(excessCount))
            // We just discarded newer frames from memory, so forward pagination is available again
            // regardless of whether we previously observed the absolute end.
            hasMoreNewer = true
            hasReachedAbsoluteEnd = false

        case .newer:
            // User is scrolling toward newer, trim older frames from start
            Log.info("[Memory] TRIMMING \(excessCount) older frames from START (preserving newer) reason=\(reason)", category: .ui)
            let oldIndex = currentIndex
            let resolvedAnchorFrameID = anchorFrameID ?? currentTimelineFrame?.frame.id
            let resolvedAnchorTimestamp = anchorTimestamp ?? currentTimelineFrame?.frame.timestamp
            let trimmedFrames = Array(frames.dropFirst(excessCount))

            let targetIndexAfterTrim: Int
            if let resolvedAnchorFrameID,
               let anchoredIndex = trimmedFrames.firstIndex(where: { $0.frame.id == resolvedAnchorFrameID }) {
                targetIndexAfterTrim = anchoredIndex
            } else if let resolvedAnchorTimestamp {
                targetIndexAfterTrim = trimmedFrames.enumerated().min {
                    abs($0.element.frame.timestamp.timeIntervalSince(resolvedAnchorTimestamp))
                        < abs($1.element.frame.timestamp.timeIntervalSince(resolvedAnchorTimestamp))
                }?.offset ?? max(0, oldIndex - excessCount)
            } else {
                targetIndexAfterTrim = max(0, oldIndex - excessCount)
            }

            pendingCurrentIndexAfterFrameReplacement = targetIndexAfterTrim
            frames = trimmedFrames
            let anchorIDValue = resolvedAnchorFrameID?.value ?? -1
            let anchorTS = resolvedAnchorTimestamp.map { Log.timestamp(from: $0) } ?? "nil"
            Log.info(
                "[Memory] TRIM anchor result reason=\(reason) oldIndex=\(oldIndex) newIndex=\(targetIndexAfterTrim) anchorFrameID=\(anchorIDValue) anchorTs=\(anchorTS)",
                category: .ui
            )
            // We just discarded older frames from memory, so backward pagination is available again.
            hasMoreOlder = true
            hasReachedAbsoluteStart = false
        }

        // Update boundaries after trimming
        updateWindowBoundaries()

        // Log the memory state after trimming
        MemoryTracker.logMemoryState(
            context: "AFTER TRIM (\(beforeCount)→\(frames.count))",
            frameCount: frames.count,
            frameBufferCount: diskFrameBufferIndex.count,
            oldestTimestamp: oldestLoadedTimestamp,
            newestTimestamp: newestLoadedTimestamp
        )
    }
}
