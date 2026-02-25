import SwiftUI
import Combine
import AVFoundation
import AppKit
import Shared
import App
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
    static let maxFrames = 500           // Maximum frames in memory
    static let loadThreshold = 100       // Start loading when within N frames of edge
    static let loadBatchSize = 200       // Frames to load per batch
    static let loadWindowSpanSeconds: TimeInterval = 24 * 60 * 60 // Bounded window for load-more queries
}

/// Memory tracking for debugging frame accumulation issues
private enum MemoryTracker {
    /// Log memory state for debugging
    static func logMemoryState(
        context: String,
        frameCount: Int,
        imageCacheCount: Int,
        oldestTimestamp: Date?,
        newestTimestamp: Date?
    ) {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "HH:mm:ss"

        let oldest = oldestTimestamp.map { dateFormatter.string(from: $0) } ?? "nil"
        let newest = newestTimestamp.map { dateFormatter.string(from: $0) } ?? "nil"

        Log.debug(
            "[Memory] \(context) | frames=\(frameCount)/\(WindowConfig.maxFrames) | imageCache=\(imageCacheCount) | window=[\(oldest) → \(newest)]",
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

    public var id: FrameID { frame.id }

    public static func == (lhs: TimelineFrame, rhs: TimelineFrame) -> Bool {
        lhs.frame.id == rhs.frame.id
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

/// Simple ViewModel for the redesigned fullscreen timeline view
/// All state derives from currentIndex - this is the SINGLE source of truth
@MainActor
public class SimpleTimelineViewModel: ObservableObject {

    // MARK: - Private Properties

    /// Cancellables for Combine subscriptions
    private var cancellables = Set<AnyCancellable>()

    /// Enables very verbose timeline logging (useful for debugging, expensive in production).
    /// In release builds, this is disabled by default and can be enabled via:
    /// `defaults write io.retrace.app retrace.debug.timelineVerboseLogs -bool YES`
    private static let isVerboseTimelineLoggingEnabled: Bool = {
        #if DEBUG
        return true
        #else
        return UserDefaults.standard.bool(forKey: "retrace.debug.timelineVerboseLogs")
        #endif
    }()

    /// Enables expensive state-change tracing (stack traces).
    /// Enable only when actively debugging:
    /// `defaults write io.retrace.app retrace.debug.timelineStateTrace -bool YES`
    private static let isTimelineStateTraceEnabled: Bool =
        UserDefaults.standard.bool(forKey: "retrace.debug.timelineStateTrace")

    /// Enables filtered-timeline scrub diagnostics (tracks requested frame identities during fast scroll).
    /// In release builds, opt in with:
    /// `defaults write io.retrace.app retrace.debug.filteredScrubDiagnostics -bool YES`
    private static let isFilteredScrubDiagnosticsEnabled: Bool = {
        #if DEBUG
        return true
        #else
        return UserDefaults.standard.bool(forKey: "retrace.debug.filteredScrubDiagnostics")
        #endif
    }()

    /// Timestamp formatter used by comment helper actions.
    private static let commentTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()

    // MARK: - Published State

    /// All loaded frames with their preloaded video info
    @Published public var frames: [TimelineFrame] = [] {
        didSet {
            invalidateAppBlockSnapshot(reason: "frames.didSet")
        }
    }

    /// Current index in the frames array - THE SINGLE SOURCE OF TRUTH
    /// Everything else (currentFrame, currentVideoInfo, currentTimestamp) derives from this
    @Published public var currentIndex: Int = 0 {
        didSet {
            if currentIndex != oldValue {
                if Self.isVerboseTimelineLoggingEnabled {
                    Log.debug("[SimpleTimelineViewModel] currentIndex changed: \(oldValue) -> \(currentIndex)", category: .ui)
                    if let frame = currentTimelineFrame {
                        Log.debug("[SimpleTimelineViewModel] New frame: timestamp=\(frame.frame.timestamp), frameIndex=\(frame.videoInfo?.frameIndex ?? -1)", category: .ui)
                    }
                }

                // CRITICAL: Clear previous frame state IMMEDIATELY to prevent old frame from showing
                // This runs synchronously before SwiftUI re-renders
                currentImage = nil

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
            }
        }
    }

    /// Static image for displaying the current frame (for image-based sources like Retrace)
    @Published public var currentImage: NSImage?

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
    @Published public var isActivelyScrolling = false

    /// Currently selected frame index (for deletion, etc.) - nil means no selection
    @Published public var selectedFrameIndex: Int? = nil

    /// Whether the delete confirmation dialog is shown
    @Published public var showDeleteConfirmation = false

    /// Whether we're deleting a single frame or an entire segment
    @Published public var isDeleteSegmentMode = false

    /// Frames that have been "deleted" (optimistically removed from UI)
    @Published public var deletedFrameIDs: Set<FrameID> = []

    // MARK: - URL Bounding Box State

    /// Bounding box for a clickable URL found in the current frame (normalized 0.0-1.0 coordinates)
    @Published public var urlBoundingBox: URLBoundingBox?

    /// Whether the mouse is currently hovering over the URL bounding box
    @Published public var isHoveringURL: Bool = false

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

    /// Whether all text is selected (via Cmd+A)
    @Published public var isAllTextSelected: Bool = false

    /// Drag selection start point (in normalized coordinates 0.0-1.0)
    @Published public var dragStartPoint: CGPoint?

    /// Drag selection end point (in normalized coordinates 0.0-1.0)
    @Published public var dragEndPoint: CGPoint?

    /// Whether we have any text selected
    public var hasSelection: Bool {
        isAllTextSelected || (selectionStart != nil && selectionEnd != nil)
    }

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

    // MARK: - Text Selection Hint Banner State

    /// Whether to show the text selection hint banner ("Try area selection mode: Shift + Drag")
    @Published public var showTextSelectionHint: Bool = false

    /// Timer to auto-dismiss the text selection hint
    private var textSelectionHintTimer: Timer?

    /// Whether the hint banner has already been shown for the current drag session
    private var hasShownHintThisDrag: Bool = false

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
        if isPlaying {
            stopPlayback()
        } else {
            startPlayback()
        }
    }

    /// Update the playback speed and reschedule the timer if playing
    public func setPlaybackSpeed(_ speed: Double) {
        playbackSpeed = speed
        if isPlaying {
            // Reschedule timer with new interval
            playbackTimer?.invalidate()
            schedulePlaybackTimer()
        }
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

    /// Whether search highlight is currently being displayed
    @Published public var isShowingSearchHighlight: Bool = false

    /// Timer to auto-dismiss search highlight
    private var searchHighlightTimer: Timer?

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

    /// Whether existing comments are loading for the selected timeline block
    @Published public var isLoadingBlockComments: Bool = false

    /// Optional error surfaced when loading selected block comments fails
    @Published public var blockCommentsLoadError: String? = nil

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
            self.showNewTagInput = false
            self.newTagName = ""
            self.newCommentText = ""
            self.newCommentAttachmentDrafts = []
            self.selectedBlockComments = []
            self.isLoadingBlockComments = false
            self.blockCommentsLoadError = nil
            self.isHoveringAddTagButton = false
            self.isHoveringAddCommentButton = false
            self.isAddingComment = false
            self.selectedSegmentTags = []
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

    // MARK: - Filter Dropdown State (lifted to ViewModel for proper rendering outside FilterPanel)

    /// Which filter dropdown is currently open (rendered at SimpleTimelineView level to avoid clipping)
    public enum FilterDropdownType: Equatable {
        case none
        case apps
        case tags
        case visibility
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

        static let empty = AppBlockSnapshot(blocks: [], frameToBlockIndex: [], videoBoundaryIndices: [])
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
        appBlockSnapshotBuildTask?.cancel()
        appBlockSnapshotApplyTask?.cancel()
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

    /// Cache for Retrace images (loaded on demand since they're from disk)
    private var imageCache: [FrameID: NSImage] = [:] {
        didSet {
            let oldCount = oldValue.count
            let newCount = imageCache.count
            if oldCount != newCount {
                if Self.isVerboseTimelineLoggingEnabled {
                    Log.debug("[Memory] imageCache changed: \(oldCount) → \(newCount) images", category: .ui)
                }
            }
        }
    }

    /// Maximum images to keep in cache (prevents unbounded memory growth)
    private static let maxImageCacheSize = 50

    /// Number of frames to preload ahead and behind current position
    private static let preloadRadius = 5

    /// Task for preloading nearby frames (cancelled when index changes rapidly)
    private var preloadTask: Task<Void, Never>?

    /// Track frames currently being decoded to prevent duplicate decode operations
    private var inFlightDecodes: Set<FrameID> = []

    /// Cmd+F quick-filter latency trace payload carried across async reload/boundary paths.
    private struct CmdFQuickFilterLatencyTrace: Sendable {
        let id: String
        let startedAt: CFAbsoluteTime
        let trigger: String
        let action: String
        let bundleID: String
        let source: FrameSource
    }

    /// Pending Cmd+F trace, consumed by the next filter-triggered reload call.
    private var pendingCmdFQuickFilterLatencyTrace: CmdFQuickFilterLatencyTrace?

    /// Monotonic ID for loading state transitions in logs.
    private var loadingTransitionID: UInt64 = 0
    /// Start time of the currently active loading state.
    private var loadingStateStartedAt: CFAbsoluteTime?
    /// Reason associated with the currently active loading state.
    private var activeLoadingReason: String = "idle"

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

    /// Threshold: if user is within this many frames of newest, allow background refresh
    private static let nearLiveEdgeFrameThreshold: Int = 50

    // MARK: - Playhead Position History (for Cmd+Z undo)

    /// Stored position for undo history - contains both frame ID (for precision) and timestamp (for reloading)
    private struct StoppedPosition {
        let frameID: FrameID
        let timestamp: Date
    }

    /// Stack of positions where the playhead was stopped for 1+ second
    /// Most recent position is at the end of the array
    /// Stores frame ID (unique identifier) and timestamp (for reloading frames if needed)
    private var stoppedPositionHistory: [StoppedPosition] = []

    /// Maximum number of stopped positions to remember
    private static let maxStoppedPositionHistory = 50

    /// Work item for detecting when playhead has been stationary for 1+ second
    /// Using DispatchWorkItem instead of Task for lower overhead during rapid navigation
    private var playheadStoppedDetectionWorkItem: DispatchWorkItem?

    /// The frame ID that was last recorded as a stopped position (to avoid duplicates)
    private var lastRecordedStoppedFrameID: FrameID?

    /// Time threshold (in seconds) for considering playhead as "stopped"
    private static let stoppedThresholdSeconds: TimeInterval = 1.0

    // MARK: - Dependencies

    private let coordinator: AppCoordinator

    // MARK: - Initialization

    public init(coordinator: AppCoordinator) {
        self.coordinator = coordinator

        // Restore search overlay visibility from last session
        // On first launch, default to showing the overlay (true)
        if UserDefaults.standard.object(forKey: "searchOverlayVisible") == nil {
            self.isSearchOverlayVisible = true
            UserDefaults.standard.set(true, forKey: "searchOverlayVisible")
        } else {
            self.isSearchOverlayVisible = UserDefaults.standard.bool(forKey: "searchOverlayVisible")
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

        // Observe dialog states to update emergency escape tracking
        // This prevents triple-escape from triggering while dialogs are open
        setupDialogStateObserver()

        // Persist search overlay visibility preference
        setupSearchOverlayPersistence()
    }

    /// Set up Combine observer to track when any dialog/overlay is open
    private func setupDialogStateObserver() {
        Publishers.CombineLatest4(
            $isSearchOverlayVisible,
            $isFilterDropdownOpen,
            $showTagSubmenu,
            $isDateSearchActive
        )
        .combineLatest($isCalendarPickerVisible)
        .sink { combined, isCalendarVisible in
            let (isSearch, isFilter, isTag, isDateSearch) = combined
            let isAnyDialogOpen = isSearch || isFilter || isTag || isDateSearch || isCalendarVisible
            TimelineWindowController.shared.setDialogOpen(isAnyDialogOpen)
        }
        .store(in: &cancellables)
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

    private func summarizeFiltersForLog(_ filters: FilterCriteria) -> String {
        let appCount = filters.selectedApps?.count ?? 0
        let tagCount = filters.selectedTags?.count ?? 0
        let hasWindowFilter = !(filters.windowNameFilter?.isEmpty ?? true)
        let hasURLFilter = !(filters.browserUrlFilter?.isEmpty ?? true)
        let hasDateRange = filters.startDate != nil || filters.endDate != nil

        return "active=\(filters.hasActiveFilters) count=\(filters.activeFilterCount) apps=\(appCount) tags=\(tagCount) appMode=\(filters.appFilterMode.rawValue) hidden=\(filters.hiddenFilter.rawValue) window=\(hasWindowFilter) url=\(hasURLFilter) date=\(hasDateRange)"
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
            let framesWithVideoInfo = try await coordinator.getFramesWithVideoInfo(
                from: startDate,
                to: endDate,
                limit: limit,
                filters: filters
            )
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
        let boundedStart = filters.startDate.map { Log.timestamp(from: $0) } ?? "nil"
        let boundedEnd = filters.endDate.map { Log.timestamp(from: $0) } ?? "nil"
        Log.info(
            "[TIMELINE-FETCH][\(traceID)] START reason='\(reason)' before=\(Log.timestamp(from: timestamp)) limit=\(limit) boundedRange=[\(boundedStart) → \(boundedEnd)] filters={\(summarizeFiltersForLog(filters))}",
            category: .ui
        )

        do {
            let framesWithVideoInfo = try await coordinator.getFramesWithVideoInfoBefore(
                timestamp: timestamp,
                limit: limit,
                filters: filters
            )
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
            let framesWithVideoInfo = try await coordinator.getMostRecentFramesWithVideoInfo(limit: limit, filters: filters)
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

    /// Invalidate all caches and reload frames from the current position
    /// Called when data sources change (e.g., Rewind toggled on/off)
    @MainActor
    public func invalidateCachesAndReload() {
        Log.info("[DataSourceChange] invalidateCachesAndReload() called", category: .ui)

        // Clear image cache
        let oldImageCount = imageCache.count
        Log.debug("[DataSourceChange] Clearing image cache with \(oldImageCount) entries", category: .ui)
        imageCache.removeAll()
        Log.debug("[DataSourceChange] Image cache cleared, new count: \(imageCache.count)", category: .ui)

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

        Log.info("[DataSourceChange] Cleared \(oldImageCount) cached images, search results, and filters, reloading from current position", category: .ui)
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

    /// Reload frames around a specific timestamp (used after data source changes and Cmd+F quick filter)
    private func reloadFramesAroundTimestamp(_ timestamp: Date, cmdFTrace: CmdFQuickFilterLatencyTrace? = nil) async {
        let reloadStart = CFAbsoluteTimeGetCurrent()
        Log.debug("[DataSourceChange] reloadFramesAroundTimestamp() starting for timestamp: \(timestamp)", category: .ui)
        if let cmdFTrace {
            Log.debug(
                "[CmdFPerf][\(cmdFTrace.id)] Reload around timestamp started action=\(cmdFTrace.action) app=\(cmdFTrace.bundleID) source=\(cmdFTrace.source.rawValue)",
                category: .ui
            )
        }
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
                frames = framesWithVideoInfo.map { TimelineFrame(frame: $0.frame, videoInfo: $0.videoInfo, processingStatus: $0.processingStatus) }

                // Find the frame closest to the original timestamp
                let closestIndex = findClosestFrameIndex(to: timestamp)
                currentIndex = closestIndex

                updateWindowBoundaries()
                resetBoundaryStateForReloadWindow()

                // Load tag metadata/map lazily so the tape can render subtle tag indicators.
                ensureTapeTagIndicatorDataLoadedIfNeeded()

                loadImageIfNeeded()

                // Check if we need to pre-load more frames (near edge of loaded window)
                let boundaryLoad = checkAndLoadMoreFrames(reason: "reloadFramesAroundTimestamp", cmdFTrace: cmdFTrace)

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
                let fallbackStart = CFAbsoluteTimeGetCurrent()
                // Hand off loading ownership so fallback can run loadMostRecentFrame instead of being skipped.
                setLoadingState(false, reason: "reloadFramesAroundTimestamp.fallbackHandoff")
                await loadMostRecentFrame()
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

    /// Perform optimistic deletion of the selected frame and persist to database
    public func confirmDeleteSelectedFrame() {
        guard let index = selectedFrameIndex, index >= 0 && index < frames.count else {
            showDeleteConfirmation = false
            return
        }

        let frameToDelete = frames[index]
        let frameID = frameToDelete.frame.id
        let frameRef = frameToDelete.frame

        // Add to deleted set for potential undo
        deletedFrameIDs.insert(frameID)

        // Remove from frames array (optimistic deletion)
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

        // Persist deletion to database in background
        Task {
            do {
                try await coordinator.deleteFrame(
                    frameID: frameRef.id,
                    timestamp: frameRef.timestamp,
                    source: frameRef.source
                )
                Log.debug("[Delete] Frame \(frameID) deleted from database", category: .ui)
            } catch {
                // Log error but don't restore UI - user already saw it deleted
                Log.error("[Delete] Failed to delete frame from database: \(error)", category: .ui)
            }
        }
    }

    /// Cancel deletion
    public func cancelDelete() {
        showDeleteConfirmation = false
        isDeleteSegmentMode = false
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

    /// Perform optimistic deletion of the entire segment containing the selected frame and persist to database
    public func confirmDeleteSegment() {
        guard let block = selectedBlock else {
            showDeleteConfirmation = false
            isDeleteSegmentMode = false
            return
        }

        // Collect all frames to delete (need full FrameReference for database deletion)
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

        // Persist deletion to database in background
        Task {
            do {
                try await coordinator.deleteFrames(framesToDelete)
                Log.debug("[Delete] Segment with \(deleteCount) frames deleted from database", category: .ui)
            } catch {
                // Log error but don't restore UI - user already saw it deleted
                Log.error("[Delete] Failed to delete segment from database: \(error)", category: .ui)
            }
        }
    }

    // MARK: - Tag Operations

    /// Load context-menu support data used by tag/comment submenus.
    public func loadTimelineContextMenuData() async {
        async let tagsTask: Void = loadTags()
        async let commentsTask: Void = loadCommentsForSelectedTimelineBlock()
        _ = await (tagsTask, commentsTask)
    }

    /// Opens the timeline context menu directly into the tag submenu for a tape block.
    public func openTagSubmenuForTimelineBlock(_ block: AppBlock) {
        guard block.frameCount > 0 else { return }

        timelineContextMenuSegmentIndex = block.startIndex
        selectedFrameIndex = block.startIndex
        newCommentText = ""
        newCommentAttachmentDrafts = []
        selectedBlockComments = []
        blockCommentsLoadError = nil
        showTagSubmenu = true
        showCommentSubmenu = false
        isHoveringAddTagButton = false
        isHoveringAddCommentButton = false

        if let pointerLocation = currentMouseLocationInContentCoordinates() {
            timelineContextMenuLocation = pointerLocation
        }

        showTimelineContextMenu = true

        Task { await loadTags() }
    }

    /// Opens the timeline context menu directly into the comment submenu for a tape block.
    public func openCommentSubmenuForTimelineBlock(_ block: AppBlock) {
        guard block.frameCount > 0 else { return }

        timelineContextMenuSegmentIndex = block.startIndex
        selectedFrameIndex = block.startIndex
        newCommentText = ""
        newCommentAttachmentDrafts = []
        selectedBlockComments = []
        blockCommentsLoadError = nil
        showTagSubmenu = false
        showCommentSubmenu = true
        isHoveringAddTagButton = false
        isHoveringAddCommentButton = false

        if let pointerLocation = currentMouseLocationInContentCoordinates() {
            timelineContextMenuLocation = pointerLocation
        }

        // Open only the dedicated comment overlay; do not present the right-click context menu.
        showTimelineContextMenu = false

        Task { await loadCommentsForSelectedTimelineBlock() }
    }

    /// Load existing comments linked anywhere in the currently selected timeline block.
    /// Results are deduplicated by comment ID and sorted oldest → newest.
    public func loadCommentsForSelectedTimelineBlock() async {
        guard let index = timelineContextMenuSegmentIndex,
              let block = getBlock(forFrameAt: index) else {
            selectedBlockComments = []
            blockCommentsLoadError = nil
            isLoadingBlockComments = false
            return
        }

        let segmentIDs = getSegmentIds(inBlock: block).sorted { $0.value < $1.value }
        guard !segmentIDs.isEmpty else {
            selectedBlockComments = []
            blockCommentsLoadError = nil
            isLoadingBlockComments = false
            return
        }

        isLoadingBlockComments = true
        blockCommentsLoadError = nil

        do {
            var commentsByID: [Int64: SegmentComment] = [:]
            for segmentID in segmentIDs {
                let comments = try await coordinator.getCommentsForSegment(segmentId: segmentID)
                for comment in comments {
                    commentsByID[comment.id.value] = comment
                }
            }

            selectedBlockComments = commentsByID.values.sorted {
                if $0.createdAt == $1.createdAt {
                    return $0.id.value < $1.id.value
                }
                return $0.createdAt < $1.createdAt
            }
            isLoadingBlockComments = false
        } catch {
            isLoadingBlockComments = false
            selectedBlockComments = []
            blockCommentsLoadError = "Could not load comments."
            Log.error("[Comments] Failed to load block comments: \(error)", category: .ui)
        }
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

            hidingSegmentBlockRange = nil

            // Load image for new current frame
            loadImageIfNeeded()

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
        // Remove from hidden set immediately (optimistic UI update)
        for segmentId in segmentIdsToUnhide {
            hiddenSegmentIds.remove(segmentId)
        }

        let shouldRemoveFromCurrentView = filterCriteria.hiddenFilter == .onlyHidden
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

                hidingSegmentBlockRange = nil

                // Load image for new current frame
                loadImageIfNeeded()

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
                return true
            }

            try await coordinator.removeCommentFromSegments(
                segmentIds: Array(linkedSegmentIDs),
                commentId: comment.id
            )

            selectedBlockComments.removeAll { $0.id == comment.id }
            decrementCommentCountsForSegments(linkedSegmentIDs)
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
                    author: nil
                )

                await MainActor.run {
                    newCommentText = ""
                    newCommentAttachmentDrafts = []
                    incrementCommentCountsForSegments(Set(createResult.linkedSegmentIDs))
                    isAddingComment = false
                    let requestedCount = segmentIds.count
                    let linkedCount = createResult.linkedSegmentIDs.count

                    if linkedCount == requestedCount {
                        showToast("Comment added", icon: "checkmark.circle.fill")
                    } else {
                        showToast(
                            "Comment added to \(linkedCount)/\(requestedCount) segments",
                            icon: "exclamationmark.triangle.fill"
                        )
                    }
                }
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
    /// Mirrors the Cmd+F quick-filter behavior: first press applies app-only filter, second clears it.
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
            hasNoTags &&
            criteria.tagFilterMode == .include &&
            hasNoWindowFilter &&
            hasNoBrowserFilter &&
            criteria.startDate == nil &&
            criteria.endDate == nil
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

    /// Build app blocks, frame->block index mapping, and video boundaries in one pass.
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
        var boundaries: [Int] = []

        var currentBundleID: String? = frameList[0].bundleID
        var blockStartIndex = 0
        var currentBlockIndex = 0
        var gapBeforeCurrentBlock: TimeInterval? = nil
        var previousVideoPath = frameList[0].videoPath
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
                    boundaries.append(index)
                }
                previousVideoPath = currentVideoPath
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
            videoBoundaryIndices: boundaries
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

    /// Toggle source filter selection (updates pending, not applied)
    /// Toggle source filter - nil means only Retrace (native)
    /// Clicking Rewind toggles it on/off while keeping Retrace always on
    /// Clicking Retrace when only Retrace is selected does nothing (must have at least one)
    public func toggleSourceFilter(_ source: FrameSource) {
        // nil means only native (Retrace) selected
        var sources = pendingFilterCriteria.selectedSources ?? Set([.native])

        if sources.contains(source) {
            // Don't allow removing the last source
            if sources.count > 1 {
                sources.remove(source)
                pendingFilterCriteria.selectedSources = sources
            }
        } else {
            // Add the source
            sources.insert(source)
            pendingFilterCriteria.selectedSources = sources
        }
        Log.debug("[Filter] Toggled source filter for \(source.rawValue), now: \(pendingFilterCriteria.selectedSources?.map { $0.rawValue } ?? ["native only"])", category: .ui)
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

    /// Set date range filter (updates pending, not applied)
    public func setDateRange(start: Date?, end: Date?) {
        pendingFilterCriteria.startDate = start
        pendingFilterCriteria.endDate = end
        Log.debug("[Filter] Set date range to \(String(describing: start)) - \(String(describing: end)) (pending)", category: .ui)
    }

    /// Starts a latency trace for Cmd+F quick-filter execution.
    /// The trace is consumed by the next filter reload path.
    public func beginCmdFQuickFilterLatencyTrace(
        bundleID: String,
        action: String,
        trigger: String,
        source: FrameSource
    ) {
        if let existing = pendingCmdFQuickFilterLatencyTrace {
            Log.warning("[CmdFPerf][\(existing.id)] Replaced by a newer Cmd+F request before execution", category: .ui)
        }

        let trace = CmdFQuickFilterLatencyTrace(
            id: String(UUID().uuidString.prefix(8)),
            startedAt: CFAbsoluteTimeGetCurrent(),
            trigger: trigger,
            action: action,
            bundleID: bundleID,
            source: source
        )
        pendingCmdFQuickFilterLatencyTrace = trace

        Log.info(
            "[CmdFPerf][\(trace.id)] Start action=\(action) trigger=\(trigger) app=\(bundleID) source=\(source.rawValue) index=\(currentIndex) frameCount=\(frames.count)",
            category: .ui
        )
    }

    /// Apply pending filters
    public func applyFilters() {
        Log.debug("[Filter] applyFilters() called - pending.selectedApps=\(String(describing: pendingFilterCriteria.selectedApps)), current.selectedApps=\(String(describing: filterCriteria.selectedApps))", category: .ui)

        // Invalidate peek cache since filters are changing
        invalidatePeekCache()

        // Capture current timestamp before applying filters to preserve position
        let timestampToPreserve = currentTimestamp
        let cmdFTrace = pendingCmdFQuickFilterLatencyTrace
        pendingCmdFQuickFilterLatencyTrace = nil

        filterCriteria = pendingFilterCriteria
        Log.debug("[Filter] Applied filters - filterCriteria.selectedApps=\(String(describing: filterCriteria.selectedApps))", category: .ui)

        // Record timeline filter metric with JSON of applied filters
        let filterJson = buildTimelineFilterJson()
        DashboardViewModel.recordTimelineFilter(coordinator: coordinator, filterJson: filterJson)

        dismissFilterPanel()

        // Save filter criteria to cache immediately
        saveFilterCriteria()

        // Reload timeline with filters, preserving current position if possible
        Task {
            if let timestamp = timestampToPreserve {
                // Try to reload frames around the same timestamp (with new filters)
                // If no frames match, reloadFramesAroundTimestamp will fall back to loadMostRecentFrame
                await reloadFramesAroundTimestamp(timestamp, cmdFTrace: cmdFTrace)
            } else {
                // No current position, fall back to most recent
                if let cmdFTrace {
                    Log.warning("[CmdFPerf][\(cmdFTrace.id)] No current timestamp available after action=\(cmdFTrace.action), falling back to loadMostRecentFrame()", category: .ui)
                }
                await loadMostRecentFrame()
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

        clearFilterState()

        // Reload timeline without filters, preserving current position
        Task {
            if let timestamp = timestampToPreserve {
                // Reload frames around the same timestamp (without filters)
                await reloadFramesAroundTimestamp(timestamp, cmdFTrace: cmdFTrace)
            } else {
                // No current position, fall back to most recent
                if let cmdFTrace {
                    Log.warning("[CmdFPerf][\(cmdFTrace.id)] No current timestamp available after action=\(cmdFTrace.action), falling back to loadMostRecentFrame()", category: .ui)
                }
                await loadMostRecentFrame()
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

        if let startDate = filterCriteria.startDate {
            components.append("\"startDate\":\"\(Log.timestamp(from: startDate))\"")
        }

        if let endDate = filterCriteria.endDate {
            components.append("\"endDate\":\"\(Log.timestamp(from: endDate))\"")
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
        filterCriteria = snapshot.filterCriteria
        pendingFilterCriteria = snapshot.filterCriteria
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
            pendingFilterCriteria = filterCriteria
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

        // Always dismiss context menus
        dismissContextMenu()
        dismissTimelineContextMenu()
    }

    /// Dialog types for mutual exclusion
    public enum DialogType {
        case filter      // Option+F - Filter panel
        case dateSearch  // Cmd+G - Date search
        case search      // Cmd+K - Search overlay
    }

    /// Dismiss filter panel (resets pending to match applied)
    public func dismissFilterPanel() {
        // Reset pending first - animation is handled by the View
        pendingFilterCriteria = filterCriteria
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
        pendingFilterCriteria = filterCriteria
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

    // MARK: - Search Overlay

    /// Open the search overlay and dismiss other dialogs
    public func openSearchOverlay() {
        // Dismiss other dialogs first
        dismissOtherDialogs(except: .search)
        // Show controls if hidden (user expects to see the search overlay)
        if areControlsHidden {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                areControlsHidden = false
            }
        }
        isSearchOverlayVisible = true
        // Clear any existing search highlight
        Task { @MainActor in
            clearSearchHighlight()
        }
    }

    /// Close the search overlay
    public func closeSearchOverlay() {
        isSearchOverlayVisible = false
    }

    /// Toggle the search overlay
    public func toggleSearchOverlay() {
        if isSearchOverlayVisible {
            closeSearchOverlay()
        } else {
            openSearchOverlay()
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
        Log.debug("[SearchDeeplink][\(deeplinkID)] overlay opened", category: .ui)

        // Reset prior transient search state so deeplinks are deterministic.
        searchViewModel.cancelSearch()
        searchViewModel.searchQuery = ""
        searchViewModel.clearAllFilters()
        Log.debug("[SearchDeeplink][\(deeplinkID)] reset search query + filters", category: .ui)

        if let normalizedAppBundleID {
            searchViewModel.setAppFilter(normalizedAppBundleID)
            Log.debug("[SearchDeeplink][\(deeplinkID)] set app filter: \(normalizedAppBundleID)", category: .ui)
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
        Log.debug("[FilterCache] saveFilterCriteria() called - pending.selectedApps=\(String(describing: pendingFilterCriteria.selectedApps)), pending.hasActiveFilters=\(pendingFilterCriteria.hasActiveFilters)", category: .ui)
        // If no filters are active in pending, clear any cached filters to avoid restoring stale state
        guard pendingFilterCriteria.hasActiveFilters else {
            Log.debug("[FilterCache] No active pending filters, clearing cache", category: .ui)
            clearCachedFilterCriteria()
            return
        }

        do {
            let data = try JSONEncoder().encode(pendingFilterCriteria)
            UserDefaults.standard.set(data, forKey: Self.cachedFilterCriteriaKey)
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.cachedFilterSavedAtKey)
            Log.debug("[FilterCache] Saved pending filter criteria with selectedApps=\(String(describing: pendingFilterCriteria.selectedApps))", category: .ui)
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
            filterCriteria = restored
            pendingFilterCriteria = restored
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
    public func loadMostRecentFrame(clickStartTime: CFAbsoluteTime? = nil) async {
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
                limit: 500,
                filters: filterCriteria,
                reason: "loadMostRecentFrame"
            )

            guard !framesWithVideoInfo.isEmpty else {
                // No frames found - check if filters are active
                if filterCriteria.hasActiveFilters {
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
            frames = framesWithVideoInfo.reversed().map { TimelineFrame(frame: $0.frame, videoInfo: $0.videoInfo, processingStatus: $0.processingStatus) }

            // Initialize window boundary timestamps for infinite scroll
            updateWindowBoundaries()

            // Log the first and last few frames to verify ordering
            Log.debug("[SimpleTimelineViewModel] Loaded \(frames.count) frames", category: .ui)

            // Log initial memory state
            MemoryTracker.logMemoryState(
                context: "INITIAL LOAD",
                frameCount: frames.count,
                imageCacheCount: imageCache.count,
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

            // Load image if needed for current frame
            loadImageIfNeeded()

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
                showNoResultsMessage()
            } else {
                showErrorWithAutoDismiss("No frames found in any database")
            }
            setLoadingState(false, reason: "loadFramesDirectly.noFrames")
            return
        }

        // Convert to TimelineFrame - reverse so oldest is first (index 0), newest is last
        frames = framesWithVideoInfo.reversed().map { TimelineFrame(frame: $0.frame, videoInfo: $0.videoInfo, processingStatus: $0.processingStatus) }

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
    public func refreshFrameData(navigateToNewest: Bool = true) async {
        let refreshStartTime = CFAbsoluteTimeGetCurrent()
        Log.info("[TIMELINE-REFRESH] 🔄 refreshFrameData(navigateToNewest: \(navigateToNewest)) started", category: .ui)

        // If we have frames and a current position, just refresh the current image
        if !frames.isEmpty {
            Log.info("[TIMELINE-REFRESH] 🔄 Have \(frames.count) cached frames, refreshing current image", category: .ui)

            // Background refresh rules:
            // - With filters active: always respect 1-minute cache expiry (no 50-frame optimization)
            // - Hidden > 1 minute (navigateToNewest=true): always refresh and navigate to newest
            // - Hidden < 1 minute AND within 50 frames: refresh and navigate to newest
            // - Hidden < 1 minute AND > 50 frames away: skip refresh entirely
            let framesFromNewest = frames.count - 1 - currentIndex
            let shouldNavigateToNewest: Bool
            let hasActiveFilters = filterCriteria.hasActiveFilters

            if !navigateToNewest, currentIndex < frames.count, !hasActiveFilters {
                if framesFromNewest > Self.nearLiveEdgeFrameThreshold {
                    Log.info("[TIMELINE-REFRESH] 🔄 Skipping background refresh — user is \(framesFromNewest) frames from newest (threshold: \(Self.nearLiveEdgeFrameThreshold))", category: .ui)
                    loadImageIfNeeded()
                    return
                }
                // Within 50 frames - allow refresh AND navigate to newest
                shouldNavigateToNewest = true
                Log.info("[TIMELINE-REFRESH] 🔄 Within \(Self.nearLiveEdgeFrameThreshold) frames of newest (\(framesFromNewest)), will navigate to newest", category: .ui)
            } else if hasActiveFilters {
                // With filters active, always use navigateToNewest (respects 1-minute cache expiry)
                shouldNavigateToNewest = navigateToNewest
                Log.info("[TIMELINE-REFRESH] 🔄 Filters active - using 1-minute cache expiry rule (navigateToNewest: \(navigateToNewest))", category: .ui)
            } else {
                shouldNavigateToNewest = navigateToNewest
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
                            Log.info("[TIMELINE-REFRESH] 🔄 Too many new frames (\(newFrames.count) >= \(refreshLimit)) — doing full reload to avoid gap", category: .ui)
                            await loadMostRecentFrame()
                            Log.info("[TIMELINE-REFRESH] 🔄 Full reload completed, elapsed=\(String(format: "%.3f", (CFAbsoluteTimeGetCurrent() - refreshStartTime) * 1000))ms", category: .ui)
                            return
                        }

                        Log.info("[TIMELINE-REFRESH] 🔄 Found \(newFrames.count) new frames since last view", category: .ui)

                        // Add new frames to the end (they're newer, so they go at the end)
                        let newTimelineFrames = newFrames.reversed().map { TimelineFrame(frame: $0.frame, videoInfo: $0.videoInfo, processingStatus: $0.processingStatus) }

                        // Log processing statuses of new frames
                        let statusSummary = newTimelineFrames.map { "[\($0.frame.id.value):p=\($0.processingStatus)]" }.joined(separator: ", ")
                        Log.info("[TIMELINE-REFRESH] 🔄 New frames processing statuses: \(statusSummary)", category: .ui)

                        frames.append(contentsOf: newTimelineFrames)

                        // Update boundaries
                        updateWindowBoundaries()

                        // Navigate to newest frame
                        if shouldNavigateToNewest {
                            let oldIndex = currentIndex
                            currentIndex = frames.count - 1

                            // Log the new video info for debugging
                            if let newVideoInfo = frames.last?.videoInfo {
                                Log.info("[TIMELINE-REFRESH] 🔄 Updated currentIndex: \(oldIndex) -> \(currentIndex), frames.count=\(frames.count), newVideoPath=\(newVideoInfo.videoPath.suffix(30)), newFrameIndex=\(newVideoInfo.frameIndex)", category: .ui)
                            } else {
                                Log.info("[TIMELINE-REFRESH] 🔄 Updated currentIndex: \(oldIndex) -> \(currentIndex), frames.count=\(frames.count), NO VIDEO INFO", category: .ui)
                            }
                        }

                        // Trim if we've exceeded max frames (preserve newer since we just added new frames)
                        trimWindowIfNeeded(preserveDirection: .newer)
                    } else {
                        Log.info("[TIMELINE-REFRESH] 🔄 No new frames found (all \(refreshLimit) queried frames already cached)", category: .ui)
                    }
                } catch {
                    Log.error("[TIMELINE-REFRESH] Failed to check for new frames: \(error)", category: .ui)
                }
            }

            // Load the current image
            Log.info("[TIMELINE-REFRESH] 🔄 Calling loadImageIfNeeded() for currentIndex=\(currentIndex)", category: .ui)
            loadImageIfNeeded()
            Log.info("[TIMELINE-REFRESH] 🔄 refreshFrameData() completed, elapsed=\(String(format: "%.3f", (CFAbsoluteTimeGetCurrent() - refreshStartTime) * 1000))ms", category: .ui)
            return
        }

        // No cached frames - do a full load
        Log.info("[TIMELINE-REFRESH] 🔄 No cached frames, doing full load", category: .ui)
        await loadMostRecentFrame()
        Log.info("[TIMELINE-REFRESH] 🔄 Full load completed, elapsed=\(String(format: "%.3f", (CFAbsoluteTimeGetCurrent() - refreshStartTime) * 1000))ms", category: .ui)
    }

    /// Refresh processing status for all cached frames that aren't completed (status != 2)
    /// This updates stale processingStatus values (e.g., p=4 frames that are now readable)
    /// and also refreshes videoInfo for frames whose status changed
    public func refreshProcessingStatuses() async {
        // Find all frames that aren't completed (status != 2)
        let framesToRefresh = Array(frames.enumerated()) // .filter { $0.element.processingStatus != 2 }

        guard !framesToRefresh.isEmpty else {
            Log.debug("[TIMELINE-REFRESH] No frames need status refresh (all completed)", category: .ui)
            return
        }

        let frameIDs = framesToRefresh.map { $0.element.frame.id.value }

        do {
            let updatedStatuses = try await coordinator.getFrameProcessingStatuses(frameIDs: frameIDs)

            var updatedCount = 0
            var currentFrameUpdated = false

            for (index, frame) in framesToRefresh {
                // Validate index is still valid (frames array may have changed)
                guard index < frames.count else {
                    Log.debug("[TIMELINE-REFRESH] Skipping frame at index \(index) - frames array changed (now \(frames.count) frames)", category: .ui)
                    continue
                }

                // Also verify the frame ID still matches (defensive check)
                guard frames[index].frame.id == frame.frame.id else {
                    Log.debug("[TIMELINE-REFRESH] Skipping frame - ID mismatch at index \(index)", category: .ui)
                    continue
                }

                if let newStatus = updatedStatuses[frame.frame.id.value],
                   newStatus != frame.processingStatus {
                    // Re-fetch the full frame with updated videoInfo
                    if let updatedFrame = try await coordinator.getFrameWithVideoInfoByID(id: frame.frame.id) {
                        // Create updated TimelineFrame with new status AND updated videoInfo
                        frames[index] = TimelineFrame(
                            frame: updatedFrame.frame,
                            videoInfo: updatedFrame.videoInfo,
                            processingStatus: updatedFrame.processingStatus
                        )

                        // Check if this is the current frame
                        if let currentFrame = currentTimelineFrame,
                           currentFrame.frame.id.value == frame.frame.id.value {
                            currentFrameUpdated = true
                        }
                    } else {
                        // Still update the status even if we can't get videoInfo
                        frames[index] = TimelineFrame(
                            frame: frame.frame,
                            videoInfo: frame.videoInfo,
                            processingStatus: newStatus
                        )
                    }
                    updatedCount += 1
                }
            }

            if updatedCount > 0 {
                Log.info("[TIMELINE-REFRESH] Updated processingStatus for \(updatedCount) frames", category: .ui)
                // If current frame was updated, reload its image
                if currentFrameUpdated {
                    loadImageIfNeeded()
                }
            }
        } catch {
            Log.error("[TIMELINE-REFRESH] Failed to refresh processing statuses: \(error)", category: .ui)
        }
    }

    /// Start periodic processing status refresh (every 10 seconds)
    /// Call this when the timeline becomes visible
    public func startPeriodicStatusRefresh() {
        // Cancel any existing timer
        stopPeriodicStatusRefresh()

        Log.info("[TIMELINE-REFRESH] Starting periodic status refresh (10s interval)", category: .ui)

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

        // Clear search highlight when manually navigating
        if isShowingSearchHighlight {
            clearSearchHighlight()
        }
        // Only dismiss search overlay if there's no active search query
        if isSearchOverlayVisible && searchViewModel.searchQuery.isEmpty {
            isSearchOverlayVisible = false
        }

        // Track scrub distance for metrics
        let distance = abs(clampedIndex - currentIndex)
        TimelineWindowController.shared.accumulateScrubDistance(Double(distance))

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
                imageCacheCount: imageCache.count,
                oldestTimestamp: oldestLoadedTimestamp,
                newestTimestamp: newestLoadedTimestamp
            )
        }

        // Track stopped positions for Cmd+Z undo
        scheduleStoppedPositionRecording()
    }

    /// Schedule recording the current position as a "stopped" position after 1 second of inactivity
    private func scheduleStoppedPositionRecording() {
        // Cancel any previous work item
        playheadStoppedDetectionWorkItem?.cancel()

        let indexToRecord = currentIndex

        // Create new work item (lighter weight than Task)
        let workItem = DispatchWorkItem { [weak self] in
            self?.recordStoppedPosition(indexToRecord)
        }
        playheadStoppedDetectionWorkItem = workItem

        // Schedule after the threshold duration
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.stoppedThresholdSeconds, execute: workItem)
    }

    /// Record a position as a "stopped" position for undo history
    private func recordStoppedPosition(_ index: Int) {
        // Don't record invalid indices
        guard index >= 0 && index < frames.count else { return }

        let frame = frames[index].frame
        let frameID = frame.id
        let timestamp = frame.timestamp

        // Don't record if it's the same as the last recorded frame
        guard frameID != lastRecordedStoppedFrameID else { return }

        // Add to history
        stoppedPositionHistory.append(StoppedPosition(frameID: frameID, timestamp: timestamp))
        lastRecordedStoppedFrameID = frameID

        // Trim history if it exceeds max size
        if stoppedPositionHistory.count > Self.maxStoppedPositionHistory {
            stoppedPositionHistory.removeFirst(stoppedPositionHistory.count - Self.maxStoppedPositionHistory)
        }

        Log.debug("[PlayheadUndo] Recorded stopped position: frameID=\(frameID.stringValue), timestamp=\(timestamp), history size=\(stoppedPositionHistory.count)", category: .ui)
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

        // Remove the current position (most recent)
        stoppedPositionHistory.removeLast()

        // Get the previous position
        guard let previousPosition = stoppedPositionHistory.last else {
            return false
        }

        // Update lastRecordedStoppedFrameID to prevent re-recording the same position
        lastRecordedStoppedFrameID = previousPosition.frameID

        // Cancel any pending stopped position recording
        playheadStoppedDetectionWorkItem?.cancel()

        // Fast path: check if frame exists in current frames array
        if let index = frames.firstIndex(where: { $0.frame.id == previousPosition.frameID }) {
            Log.debug("[PlayheadUndo] Fast path: found frame in current array at index \(index)", category: .ui)
            if index != currentIndex {
                currentIndex = index
                loadImageIfNeeded()
                checkAndLoadMoreFrames()
            }
            return true
        }

        // Slow path: frame not in current array, need to reload frames around the timestamp
        Log.debug("[PlayheadUndo] Slow path: frame not in current array, reloading around timestamp \(previousPosition.timestamp)", category: .ui)

        Task { @MainActor in
            await navigateToUndoPosition(previousPosition)
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

        do {
            setLoadingState(true, reason: "navigateToUndoPosition")

            // Calculate ±10 minute window around target timestamp
            let calendar = Calendar.current
            let startDate = calendar.date(byAdding: .minute, value: -10, to: position.timestamp) ?? position.timestamp
            let endDate = calendar.date(byAdding: .minute, value: 10, to: position.timestamp) ?? position.timestamp

            Log.debug("[PlayheadUndo] Loading frames from \(startDate) to \(endDate)", category: .ui)

            // Fetch frames in the window with current filters applied
            let framesWithVideoInfo = try await fetchFramesWithVideoInfoLogged(
                from: startDate,
                to: endDate,
                limit: 1000,
                filters: filterCriteria,
                reason: "navigateToUndoPosition"
            )

            guard !framesWithVideoInfo.isEmpty else {
                Log.warning("[PlayheadUndo] No frames found in time range", category: .ui)
                setLoadingState(false, reason: "navigateToUndoPosition.noFrames")
                return
            }

            // Clear old image cache
            imageCache.removeAll()

            // Convert to TimelineFrame
            let timelineFrames = framesWithVideoInfo.map { TimelineFrame(frame: $0.frame, videoInfo: $0.videoInfo, processingStatus: $0.processingStatus) }

            // Replace current frames
            frames = timelineFrames

            // Update window boundaries
            if let firstFrame = frames.first, let lastFrame = frames.last {
                oldestLoadedTimestamp = firstFrame.frame.timestamp
                newestLoadedTimestamp = lastFrame.frame.timestamp
            }

            // Find and navigate to the target frame by ID
            if let index = frames.firstIndex(where: { $0.frame.id == position.frameID }) {
                currentIndex = index
            } else {
                // Fallback: find closest frame by timestamp if ID not found (edge case: frame deleted)
                let closest = frames.enumerated().min(by: {
                    abs($0.element.frame.timestamp.timeIntervalSince(position.timestamp)) <
                    abs($1.element.frame.timestamp.timeIntervalSince(position.timestamp))
                })
                currentIndex = closest?.offset ?? 0
                Log.warning("[PlayheadUndo] Frame ID not found, using closest by timestamp", category: .ui)
            }

            loadImageIfNeeded()
            checkAndLoadMoreFrames()
            setLoadingState(false, reason: "navigateToUndoPosition.success")

            Log.info("[PlayheadUndo] Navigation complete, now at index \(currentIndex)", category: .ui)

        } catch {
            Log.error("[PlayheadUndo] Failed to navigate: \(error)", category: .ui)
            setLoadingState(false, reason: "navigateToUndoPosition.error")
        }
    }

    /// Navigate to a specific frame by ID and highlight the search query
    /// Used when selecting a search result
    public func navigateToSearchResult(frameID: FrameID, timestamp: Date, highlightQuery: String) async {
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
            Log.debug("[SearchNavigation] Current frames window: \(df.string(from: first.frame.timestamp)) to \(df.string(from: last.frame.timestamp)) (\(frames.count) frames)", category: .ui)
        } else {
            Log.debug("[SearchNavigation] Current frames window: EMPTY", category: .ui)
        }

        // First, try to find a frame with this ID in our current data
        if let index = frames.firstIndex(where: { $0.frame.id == frameID }) {
            Log.debug("[SearchNavigation] Found frame by ID in current data at index \(index)", category: .ui)
            navigateToFrame(index)
            showSearchHighlight(query: highlightQuery)
            return
        }

        Log.debug("[SearchNavigation] Frame not in current data by ID, loading frames in ±10 min window...", category: .ui)

        // If not found, load frames in a ±10 minute window around the target timestamp
        // This approach (same as Cmd+G date search) guarantees the target frame is included
        do {
            setLoadingState(true, reason: "navigateToSearchResult")

            // Calculate ±10 minute window around target timestamp
            let calendar = Calendar.current
            let startDate = calendar.date(byAdding: .minute, value: -10, to: timestamp) ?? timestamp
            let endDate = calendar.date(byAdding: .minute, value: 10, to: timestamp) ?? timestamp

            Log.debug("[SearchNavigation] Query range: \(df.string(from: startDate)) to \(df.string(from: endDate))", category: .ui)

            // Fetch all frames in the 20-minute window with video info (single optimized query)
            // Always pass filterCriteria to ensure hidden filter is applied (default: .hide)
            let framesWithVideoInfo = try await fetchFramesWithVideoInfoLogged(
                from: startDate,
                to: endDate,
                limit: 1000,
                filters: filterCriteria,
                reason: "navigateToSearchResult"
            )
            Log.debug("[SearchNavigation] Loaded \(framesWithVideoInfo.count) frames in time range", category: .ui)

            guard !framesWithVideoInfo.isEmpty else {
                Log.warning("[SearchNavigation] No frames found in time range", category: .ui)
                setLoadingState(false, reason: "navigateToSearchResult.noFrames")
                return
            }

            // Clear old image cache since we're jumping to a new time window
            let oldCacheCount = imageCache.count
            imageCache.removeAll()
            if oldCacheCount > 0 {
                Log.debug("[SearchNavigation] Cleared image cache (\(oldCacheCount) images removed)", category: .ui)
            }

            // Convert to TimelineFrame - video info is already included from the JOIN
            let timelineFrames = framesWithVideoInfo.map { TimelineFrame(frame: $0.frame, videoInfo: $0.videoInfo, processingStatus: $0.processingStatus) }
            Log.debug("[SearchNavigation] Converted to \(timelineFrames.count) timeline frames", category: .ui)

            // Replace current frames with new window
            frames = timelineFrames

            // Update window boundaries
            if let firstFrame = frames.first, let lastFrame = frames.last {
                oldestLoadedTimestamp = firstFrame.frame.timestamp
                newestLoadedTimestamp = lastFrame.frame.timestamp
                Log.debug("[SearchNavigation] Window: \(oldestLoadedTimestamp!) to \(newestLoadedTimestamp!)", category: .ui)
            }

            // Find and navigate to the target frame by ID
            if let index = frames.firstIndex(where: { $0.frame.id == frameID }) {
                Log.debug("[SearchNavigation] Found frame by ID at index \(index)", category: .ui)
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

            loadImageIfNeeded()

            // Check if we need to pre-load more frames (near edge of loaded window)
            checkAndLoadMoreFrames()

            // Wait for OCR nodes to load before showing highlight
            // (loadImageIfNeeded calls loadOCRNodes but doesn't await it)
            await loadOCRNodesAsync()
            showSearchHighlight(query: highlightQuery)
            setLoadingState(false, reason: "navigateToSearchResult.success")
            Log.info("[SearchNavigation] Navigation complete, now at index \(currentIndex)", category: .ui)

        } catch {
            Log.error("[SearchNavigation] Failed to navigate to search result: \(error)", category: .ui)
            setLoadingState(false, reason: "navigateToSearchResult.error")
        }
    }

    /// Show search highlight for the given query after a 0.5-second delay
    public func showSearchHighlight(query: String) {
        Log.debug("[SearchHighlight] Will show highlight for query: '\(query)' after delay", category: .ui)

        // Clear any existing highlight first (so the view is removed and onAppear will fire again)
        isShowingSearchHighlight = false
        searchHighlightQuery = query

        // Show highlight after 0.5 second delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }
            // Only show if the query hasn't changed
            if self.searchHighlightQuery == query {
                self.isShowingSearchHighlight = true
                Log.debug("[SearchHighlight] Now showing highlight, OCR nodes available: \(self.ocrNodes.count)", category: .ui)
            }
        }
    }

    /// Clear the search highlight
    public func clearSearchHighlight() {
        Log.debug("[SearchHighlight] Clearing search highlight", category: .ui)
        searchHighlightTimer?.invalidate()
        searchHighlightTimer = nil

        withAnimation(.easeOut(duration: 0.3)) {
            isShowingSearchHighlight = false
        }

        // Clear the query after animation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.searchHighlightQuery = nil
        }
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

    /// Get OCR nodes that match the search query (for highlighting)
    /// Supports exact matches and stem-based matches for nominalized words (e.g., "calling" matches "call")
    public var searchHighlightNodes: [(node: OCRNodeWithText, ranges: [Range<String.Index>])] {
        guard let query = searchHighlightQuery, !query.isEmpty, isShowingSearchHighlight else {
            return []
        }

        // Strip quotes and normalize query for highlighting
        let cleanedQuery = query.lowercased()
            .replacingOccurrences(of: "\"", with: "")
        // Split query into individual search terms
        let queryTerms = cleanedQuery.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        Log.debug("[SearchHighlight] Query: '\(query)', cleaned: '\(cleanedQuery)', terms: \(queryTerms)", category: .ui)
        var matchingNodes: [(node: OCRNodeWithText, ranges: [Range<String.Index>])] = []

        for node in ocrNodes {
            let nodeText = node.text.lowercased()
            var ranges: [Range<String.Index>] = []

            // For each query term, find exact matches in this node
            for term in queryTerms {
                var searchStartIndex = nodeText.startIndex

                while let range = nodeText.range(of: term, range: searchStartIndex..<nodeText.endIndex) {
                    ranges.append(range)
                    searchStartIndex = range.upperBound
                }
            }

            if !ranges.isEmpty {
                matchingNodes.append((node: node, ranges: ranges))
                Log.debug("[SearchHighlight] MATCH: node.id=\(node.id), text='\(node.text.prefix(50))', ranges=\(ranges.count)", category: .ui)
            }
        }

        if !matchingNodes.isEmpty {
            let totalMatches = matchingNodes.reduce(0) { $0 + $1.ranges.count }
            Log.debug("[SearchHighlight] Found \(totalMatches) matches in \(matchingNodes.count) nodes for '\(query)'", category: .ui)
        } else {
            Log.debug("[SearchHighlight] NO MATCHES for '\(query)' in \(ocrNodes.count) nodes", category: .ui)
            // Log first few nodes to see what text they contain
            for (i, node) in ocrNodes.prefix(10).enumerated() {
                Log.debug("[SearchHighlight] Node[\(i)] id=\(node.id), text='\(node.text.prefix(30))', y=\(node.y)", category: .ui)
            }
        }

        return matchingNodes
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
        guard !isInLiveMode else { return }

        guard let timelineFrame = currentTimelineFrame else {
            if Self.isVerboseTimelineLoggingEnabled {
                Log.debug("[TIMELINE-LOAD] loadImageIfNeeded() called but currentTimelineFrame is nil", category: .ui)
            }
            return
        }

        if Self.isVerboseTimelineLoggingEnabled {
            Log.debug("[TIMELINE-LOAD] loadImageIfNeeded() START for frame \(timelineFrame.frame.id.value), currentFrameNotReady=\(frameNotReady), processingStatus=\(timelineFrame.processingStatus)", category: .ui)
        }

        // Defer heavy OCR/URL loading until scrolling stops for smoother scrubbing
        if !isActivelyScrolling {
            loadURLBoundingBox()
            loadOCRNodes()
        } else {
            // Clear stale OCR/URL data during scrolling so old bounding boxes don't persist
            setOCRNodes([])
            ocrStatus = .unknown
            ocrStatusPollingTask?.cancel()
            ocrStatusPollingTask = nil
            urlBoundingBox = nil
            clearTextSelection()
        }

        let frame = timelineFrame.frame

        // Check if frame is not yet readable (processingStatus = 4)
        // This provides instant feedback instead of waiting for async load to fail
        if timelineFrame.processingStatus == 4 {
            if Self.isVerboseTimelineLoggingEnabled {
                Log.info("[TIMELINE-LOAD] Frame \(frame.id.value) has processingStatus=4 (NOT_YET_READABLE), setting frameNotReady=true", category: .ui)
            }
            currentImage = nil
            frameNotReady = true
            frameLoadError = false
            // Still preload nearby frames
            preloadNearbyFrames()
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

        // Check cache first
        if let cached = imageCache[frame.id] {
            currentImage = cached
            frameNotReady = false
            frameLoadError = false
            return
        }

        // Skip if already being decoded (prevents duplicate work)
        guard !inFlightDecodes.contains(frame.id) else {
            if Self.isVerboseTimelineLoggingEnabled {
                Log.debug("[TIMELINE-LOAD] Frame \(frame.id.value) decode already in-flight; skipping duplicate request", category: .ui)
            }
            return
        }
        inFlightDecodes.insert(frame.id)

        // Load from disk
        let frameID = frame.id

        Task {
            defer { inFlightDecodes.remove(frameID) }

            do {
                let imageData: Data

                // If we have videoInfo (optimized JOIN query result), use it directly
                // This avoids expensive database lookups for video path resolution
                if let videoInfo = timelineFrame.videoInfo {
                    // Read directly from the full video path (works for both Retrace and Rewind)
                    imageData = try await coordinator.getFrameImageFromPath(
                        videoPath: videoInfo.videoPath,
                        frameIndex: videoInfo.frameIndex
                    )
                } else {
                    // Fallback: use timestamp-based lookup (does database query)
                    // This path is only for frames without videoInfo (shouldn't happen for native frames)
                    imageData = try await coordinator.getFrameImage(
                        segmentID: frame.videoID,
                        timestamp: frame.timestamp
                    )
                }

                if let image = NSImage(data: imageData) {
                    // Prune cache if it's getting too large
                    pruneImageCacheIfNeeded()

                    imageCache[frameID] = image

                    // Only update if we're still on the same frame
                    if currentTimelineFrame?.frame.id == frame.id {
                        currentImage = image
                        frameNotReady = false
                        frameLoadError = false
                        if Self.isVerboseTimelineLoggingEnabled {
                            Log.debug("[TIMELINE-LOAD] Successfully loaded image for frame \(frame.id.value)", category: .ui)
                        }
                    }
                }
            } catch StorageError.fileReadFailed(_, let underlying) where underlying.contains("still being written") {
                // Expected during recording - file not ready yet
                if Self.isVerboseTimelineLoggingEnabled {
                    Log.info("[TIMELINE-LOAD] Frame \(frame.id.value) video still being written (processingStatus=\(timelineFrame.processingStatus))", category: .app)
                }
                if currentTimelineFrame?.frame.id == frame.id {
                    currentImage = nil
                    frameLoadError = false
                    // Don't set frameNotReady=true for completed frames (processingStatus=2)
                    if timelineFrame.processingStatus != 2 {
                        if Self.isVerboseTimelineLoggingEnabled {
                            Log.info("[TIMELINE-LOAD] Setting frameNotReady=true (processingStatus != 2)", category: .app)
                        }
                        frameNotReady = true
                    } else {
                        if Self.isVerboseTimelineLoggingEnabled {
                            Log.info("[TIMELINE-LOAD] NOT setting frameNotReady=true because processingStatus=2 (completed)", category: .app)
                        }
                    }
                }
            } catch StorageError.fileReadFailed(_, let underlying) where underlying.contains("out of range") {
                // Frame not yet written to video file - this is expected for recently captured frames
                // The frame record exists in DB but the video encoder hasn't flushed it yet
                if Self.isVerboseTimelineLoggingEnabled {
                    Log.info("[TIMELINE-LOAD] Frame \(frame.id.value) not yet in video file (still encoding, processingStatus=\(timelineFrame.processingStatus))", category: .app)
                }

                if currentTimelineFrame?.frame.id == frame.id {
                    currentImage = nil
                    // Don't set frameNotReady=true for completed frames (processingStatus=2)
                    if timelineFrame.processingStatus != 2 {
                        frameNotReady = true
                        frameLoadError = false
                    } else {
                        // For completed frames that can't be loaded, this is an actual error
                        Log.error("[TIMELINE-LOAD] Frame marked as completed (processingStatus=2) but failed to load", category: .app)
                        frameNotReady = false
                        frameLoadError = true
                    }
                }
            } catch let error as NSError where error.domain == "AVFoundationErrorDomain" && error.code == -11829 {
                // Video file too small / no fragments yet - expected for very recent frames
                if Self.isVerboseTimelineLoggingEnabled {
                    Log.info("[TIMELINE-LOAD] Frame \(frame.id.value) video not ready yet (no fragments, processingStatus=\(timelineFrame.processingStatus))", category: .app)
                }
                if currentTimelineFrame?.frame.id == frame.id {
                    currentImage = nil
                    // Don't set frameNotReady=true for completed frames (processingStatus=2)
                    if timelineFrame.processingStatus != 2 {
                        if Self.isVerboseTimelineLoggingEnabled {
                            Log.info("[TIMELINE-LOAD] Setting frameNotReady=true (processingStatus != 2)", category: .app)
                        }
                        frameNotReady = true
                        frameLoadError = false
                    } else {
                        if Self.isVerboseTimelineLoggingEnabled {
                            Log.info("[TIMELINE-LOAD] NOT setting frameNotReady=true because processingStatus=2 (completed)", category: .app)
                        }
                        frameNotReady = false
                        frameLoadError = false
                    }
                }
            } catch {
                Log.error("[SimpleTimelineViewModel] Failed to load image: \(error)", category: .app)

                // Clear the image so we don't show the previous frame
                if currentTimelineFrame?.frame.id == frame.id {
                    currentImage = nil
                    frameNotReady = false
                    // Show error screen for unexpected failures
                    frameLoadError = true
                }
            }
        }

        // Preload nearby frames in background
        preloadNearbyFrames()
    }

    /// Preload images for frames ahead and behind current position for smoother scrubbing
    private func preloadNearbyFrames() {
        // Cancel any existing preload task
        preloadTask?.cancel()

        let centerIndex = currentIndex
        let frameCount = frames.count

        // Calculate indices to preload (within bounds)
        let startIndex = max(0, centerIndex - Self.preloadRadius)
        let endIndex = min(frameCount - 1, centerIndex + Self.preloadRadius)

        guard startIndex <= endIndex else { return }

        // Capture frame data needed for preloading (avoid accessing frames array in async context)
        var framesToPreload: [(frameID: FrameID, videoPath: String, frameIndex: Int)] = []
        for index in startIndex...endIndex {
            // Skip current frame (already loading)
            if index == centerIndex { continue }

            let timelineFrame = frames[index]
            let frame = timelineFrame.frame

            // Skip if already cached
            if imageCache[frame.id] != nil { continue }

            // Skip if no video info
            guard let videoInfo = timelineFrame.videoInfo else { continue }

            framesToPreload.append((frameID: frame.id, videoPath: videoInfo.videoPath, frameIndex: videoInfo.frameIndex))
        }

        guard !framesToPreload.isEmpty else { return }

        preloadTask = Task {
            for frameData in framesToPreload {
                // Check for cancellation
                if Task.isCancelled { return }

                // Skip if already cached or being decoded
                if imageCache[frameData.frameID] != nil { continue }
                if inFlightDecodes.contains(frameData.frameID) { continue }

                // Mark as in-flight
                inFlightDecodes.insert(frameData.frameID)

                do {
                    let filename = (frameData.videoPath as NSString).lastPathComponent
                    guard let filenameID = Int64(filename) else {
                        inFlightDecodes.remove(frameData.frameID)
                        continue
                    }

                    let imageData = try await coordinator.getFrameImageDirect(
                        filenameID: filenameID,
                        frameIndex: frameData.frameIndex
                    )

                    inFlightDecodes.remove(frameData.frameID)

                    if Task.isCancelled { return }

                    if let image = NSImage(data: imageData) {
                        pruneImageCacheIfNeeded()
                        imageCache[frameData.frameID] = image
                    }
                } catch {
                    inFlightDecodes.remove(frameData.frameID)
                    // Silently ignore preload errors - frame might not be ready yet
                    // This is expected for frames near the end that are still encoding
                }
            }
        }
    }

    /// Load URL bounding box for the current frame (if it's a browser URL)
    private func loadURLBoundingBox() {
        guard let timelineFrame = currentTimelineFrame else {
            urlBoundingBox = nil
            return
        }

        let frame = timelineFrame.frame

        // Reset hover state when frame changes
        isHoveringURL = false

        // Load URL bounding box asynchronously
        Task {
            do {
                let boundingBox = try await coordinator.getURLBoundingBox(
                    timestamp: frame.timestamp,
                    source: frame.source
                )
                // Only update if we're still on the same frame
                if currentTimelineFrame?.frame.id == frame.id {
                    urlBoundingBox = boundingBox
                    if let box = boundingBox {
                        Log.debug("[URLBoundingBox] Found URL '\(box.url)' at (\(box.x), \(box.y), \(box.width), \(box.height))", category: .ui)
                    }
                }
            } catch {
                Log.error("[SimpleTimelineViewModel] Failed to load URL bounding box: \(error)", category: .app)
                urlBoundingBox = nil
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
        guard let urlString = currentFrame?.metadata.browserURL,
              !urlString.isEmpty,
              let url = URL(string: urlString) else {
            return false
        }

        NSWorkspace.shared.open(url)
        Log.info("[Timeline] Opened current browser URL: \(urlString)", category: .ui)
        return true
    }

    // MARK: - OCR Node Loading and Text Selection

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
    private func loadOCRNodes() {
        // Don't overwrite live OCR results with database results
        guard !isInLiveMode else { return }

        guard currentTimelineFrame != nil else {
            setOCRNodes([])
            ocrStatus = .unknown
            ocrStatusPollingTask?.cancel()
            ocrStatusPollingTask = nil
            clearTextSelection()
            return
        }

        // Clear previous selection when frame changes
        clearTextSelection()

        // Load OCR nodes asynchronously
        Task {
            await loadOCRNodesAsync()
        }
    }

    /// Load OCR nodes and wait for completion (used when we need to await the result)
    private func loadOCRNodesAsync() async {
        // Cancel any existing polling task
        ocrStatusPollingTask?.cancel()
        ocrStatusPollingTask = nil

        guard let timelineFrame = currentTimelineFrame else {
            setOCRNodes([])
            ocrStatus = .unknown
            return
        }

        let frame = timelineFrame.frame
        let videoInfo = timelineFrame.videoInfo

        // DEBUG: Log which frame we're loading OCR for
        Log.debug("[OCR-LOAD-DEBUG] Loading OCR nodes for frameID=\(frame.id.value), videoFrameIndex=\(videoInfo?.frameIndex ?? -1), source=\(frame.source)", category: .ui)

        do {
            // Fetch OCR status and nodes concurrently
            async let statusTask = coordinator.getOCRStatus(frameID: frame.id)
            async let nodesTask = coordinator.getAllOCRNodes(
                frameID: frame.id,
                source: frame.source
            )

            let (status, nodes) = try await (statusTask, nodesTask)

            // DEBUG: Log what we got back
            Log.debug("[OCR-LOAD-DEBUG] Got \(nodes.count) nodes for frameID=\(frame.id.value), status=\(status.displayText)", category: .ui)
            if let firstNode = nodes.first {
                Log.debug("[OCR-LOAD-DEBUG] First node text: '\(firstNode.text.prefix(50))...'", category: .ui)
            }

            Log.debug("[SimpleTimelineViewModel] Loaded \(nodes.count) OCR nodes for frame \(frame.id.value) source=\(frame.source)", category: .ui)

            // Only update if we're still on the same frame
            if currentTimelineFrame?.frame.id == frame.id {
                // Update OCR status
                ocrStatus = status

                // Start polling if OCR is in progress
                if status.isInProgress {
                    startOCRStatusPolling(for: frame.id)
                }

                // Filter out nodes with invalid coordinates (multi-monitor captures)
                // Valid normalized coordinates should be in range [0.0, 1.0]
                let filteredNodes = nodes.filter { node in
                    node.x >= 0.0 && node.x <= 1.0 &&
                    node.y >= 0.0 && node.y <= 1.0 &&
                    (node.x + node.width) <= 1.0 &&
                    (node.y + node.height) <= 1.0
                }

                let filteredOut = nodes.count - filteredNodes.count
                if filteredOut > 0 {
                    Log.debug("[SimpleTimelineViewModel] Filtered out \(filteredOut) nodes with invalid coordinates", category: .ui)
                }

                setOCRNodes(filteredNodes)
                Log.debug("[SimpleTimelineViewModel] Set ocrNodes to \(ocrNodes.count) nodes", category: .ui)
            }
        } catch {
            Log.error("[SimpleTimelineViewModel] Failed to load OCR nodes: \(error)", category: .app)
            setOCRNodes([])
            ocrStatus = .unknown
        }
    }

    /// Start polling for OCR status updates
    /// Polls every 500ms until OCR completes or frame changes
    private func startOCRStatusPolling(for frameID: FrameID) {
        ocrStatusPollingTask?.cancel()

        ocrStatusPollingTask = Task { [weak self] in
            guard let self = self else { return }

            while !Task.isCancelled {
                // Wait 2000ms between polls (coalesces with other 2s timers for power efficiency)
                try? await Task.sleep(for: .nanoseconds(Int64(2_000_000_000)), clock: .continuous)

                guard !Task.isCancelled else { return }

                // Check if we're still on the same frame
                guard let currentFrame = await MainActor.run(body: { self.currentTimelineFrame?.frame }),
                      currentFrame.id == frameID else {
                    return
                }

                // Fetch updated status
                do {
                    let status = try await self.coordinator.getOCRStatus(frameID: frameID)

                    await MainActor.run {
                        // Only update if still on the same frame
                        guard self.currentTimelineFrame?.frame.id == frameID else { return }

                        self.ocrStatus = status

                        // If completed, also reload the OCR nodes
                        if !status.isInProgress {
                            Task {
                                await self.reloadOCRNodesOnly(for: frameID)
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
    private func reloadOCRNodesOnly(for frameID: FrameID) async {
        guard let frame = currentTimelineFrame?.frame, frame.id == frameID else { return }

        do {
            let nodes = try await coordinator.getAllOCRNodes(
                frameID: frame.id,
                source: frame.source
            )

            // Only update if still on the same frame
            guard currentTimelineFrame?.frame.id == frameID else { return }

            let filteredNodes = nodes.filter { node in
                node.x >= 0.0 && node.x <= 1.0 &&
                node.y >= 0.0 && node.y <= 1.0 &&
                (node.x + node.width) <= 1.0 &&
                (node.y + node.height) <= 1.0
            }

            setOCRNodes(filteredNodes)
            Log.debug("[OCR-POLL] Reloaded \(filteredNodes.count) OCR nodes for frame \(frameID.value)", category: .ui)
        } catch {
            Log.error("[OCR-POLL] Failed to reload OCR nodes: \(error)", category: .ui)
        }
    }

    /// Select all text (Cmd+A) - respects zoom region if active
    public func selectAllText() {
        // Use nodes in zoom region if active, otherwise all nodes
        let nodesToSelect = isZoomRegionActive ? ocrNodesInZoomRegion : ocrNodes
        guard !nodesToSelect.isEmpty else { return }

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
        Log.debug("[Selection] clearTextSelection called (had selection: \(selectionStart != nil))", category: .ui)
        selectionStart = nil
        selectionEnd = nil
        isAllTextSelected = false
        dragStartPoint = nil
        dragEndPoint = nil
    }

    /// Start drag selection at a point (normalized coordinates)
    public func startDragSelection(at point: CGPoint) {
        dragStartPoint = point
        dragEndPoint = point
        isAllTextSelected = false

        // Find the character position at this point
        if let position = findCharacterPosition(at: point) {
            selectionStart = position
            selectionEnd = position
        } else {
            selectionStart = nil
            selectionEnd = nil
        }
    }

    /// Update drag selection to a point (normalized coordinates)
    public func updateDragSelection(to point: CGPoint) {
        dragEndPoint = point

        // Find the character position at the current point
        if let position = findCharacterPosition(at: point) {
            selectionEnd = position
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

        isAllTextSelected = false
        selectionStart = (nodeID: nodeID, charIndex: wordStart)
        selectionEnd = (nodeID: nodeID, charIndex: wordEnd)
    }

    /// Select all text in the node at the given point (for triple-click)
    public func selectNodeAt(point: CGPoint) {
        guard let (nodeID, _) = findCharacterPosition(at: point) else {
            Log.debug("[Selection] selectNodeAt: no node found at point \(point)", category: .ui)
            return
        }
        guard let node = ocrNodes.first(where: { $0.id == nodeID }) else {
            Log.debug("[Selection] selectNodeAt: node with ID \(nodeID) not in ocrNodes", category: .ui)
            return
        }

        // Select the entire node's text
        isAllTextSelected = false
        selectionStart = (nodeID: nodeID, charIndex: 0)
        selectionEnd = (nodeID: nodeID, charIndex: node.text.count)
        Log.debug("[Selection] selectNodeAt: selected node \(nodeID) with \(node.text.count) chars", category: .ui)
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

    // MARK: - Zoom Region Methods (Shift+Drag)

    private var zoomUpdateCount = 0

    /// Start creating a zoom region (Shift+Drag)
    public func startZoomRegion(at point: CGPoint) {
        zoomUpdateCount = 0
        isDraggingZoomRegion = true
        zoomRegionDragStart = point
        zoomRegionDragEnd = point
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


        // Only create zoom region if it's large enough (at least 1% of screen)
        guard width > 0.01 && height > 0.01 else {
            isDraggingZoomRegion = false
            zoomRegionDragStart = nil
            zoomRegionDragEnd = nil
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

        // Clear drag state
        isDraggingZoomRegion = false
        zoomRegionDragStart = nil
        zoomRegionDragEnd = nil

        // Start the transition animation
        isZoomTransitioning = true
        zoomTransitionProgress = 0
        zoomTransitionBlurOpacity = 0

        // Animate to final state
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            zoomTransitionProgress = 1.0
            zoomTransitionBlurOpacity = 1.0
        }

        // After animation completes, switch to final zoom state
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            self?.isZoomRegionActive = true
            self?.zoomTransitionStartRect = nil
            // Disable transition on next run loop to ensure smooth handoff
            DispatchQueue.main.async {
                self?.isZoomTransitioning = false
            }
        }
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
        guard selectionStart != nil && selectionEnd != nil else { return "" }

        var result = ""
        // Use nodes in zoom region if active, otherwise all nodes
        let nodesToCheck = isZoomRegionActive ? ocrNodesInZoomRegion : ocrNodes

        // DEBUG: Log what nodes we're using for selection
        Log.debug("[SELECT-DEBUG] ocrNodes count: \(ocrNodes.count), isZoomRegionActive: \(isZoomRegionActive)", category: .ui)
        if let firstNode = nodesToCheck.first {
            Log.debug("[SELECT-DEBUG] First node in selection: id=\(firstNode.id), frameId=\(firstNode.frameId), text='\(firstNode.text.prefix(30))...'", category: .ui)
        }

        let sortedNodes = nodesToCheck.sorted { node1, node2 in
            let yTolerance: CGFloat = 0.02
            if abs(node1.y - node2.y) > yTolerance {
                return node1.y < node2.y
            }
            return node1.x < node2.x
        }

        var nodeCount = 0
        for node in sortedNodes {
            if let range = getSelectionRange(for: node.id) {
                let text = node.text
                let startIdx = text.index(text.startIndex, offsetBy: min(range.start, text.count))
                let endIdx = text.index(text.startIndex, offsetBy: min(range.end, text.count))
                if startIdx < endIdx {
                    let extractedText = String(text[startIdx..<endIdx])
                    // DEBUG: Log first 3 nodes being added to result
                    nodeCount += 1
                    if nodeCount <= 3 {
                        Log.debug("[SELECT-DEBUG] Adding node \(nodeCount): id=\(node.id), y=\(String(format: "%.3f", node.y)), range=\(range.start)-\(range.end), text='\(extractedText.prefix(40))...'", category: .ui)
                    }
                    result += extractedText
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

        // DEBUG: Dump ALL nodes for this frame
        if let frame = currentFrame, let videoInfo = currentVideoInfo {
            Log.debug("[COPY-DEBUG] ========== FRAME \(frame.id.value) (videoIndex=\(videoInfo.frameIndex)) ==========", category: .ui)
            Log.debug("[COPY-DEBUG] Total ocrNodes: \(ocrNodes.count)", category: .ui)
            Log.debug("[COPY-DEBUG] Selection: start=\(selectionStart?.nodeID ?? -1), end=\(selectionEnd?.nodeID ?? -1)", category: .ui)
            Log.debug("[COPY-DEBUG] --- ALL NODES (sorted by y, x) ---", category: .ui)
            let sorted = ocrNodes.sorted { n1, n2 in
                if abs(n1.y - n2.y) > 0.02 { return n1.y < n2.y }
                return n1.x < n2.x
            }
            for (i, node) in sorted.enumerated() {
                let selected = (selectionStart != nil && selectionEnd != nil) ? (getSelectionRange(for: node.id) != nil ? "✓" : " ") : " "
                Log.debug("[COPY-DEBUG] [\(selected)] \(i): id=\(node.id) y=\(String(format: "%.3f", node.y)) x=\(String(format: "%.3f", node.x)) text='\(node.text.prefix(50))...'", category: .ui)
            }
            Log.debug("[COPY-DEBUG] --- COPIED TEXT ---", category: .ui)
            Log.debug("[COPY-DEBUG] '\(text.prefix(200))...'", category: .ui)
            Log.debug("[COPY-DEBUG] ==========================================", category: .ui)
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)

        // Track text copy event with the copied text
        // Track text copy event with the copied text
        DashboardViewModel.recordTextCopy(coordinator: coordinator, text: text)
        
        // Track shift+drag text copy if this was from a manual selection
        if selectionStart != nil && selectionEnd != nil {
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

        // Try static image first
        if let image = currentImage {
            completion(image)
            return
        }

        // Fall back to extracting from video
        guard let videoInfo = currentVideoInfo else {
            Log.warning("[ZoomCopy] No currentImage and no currentVideoInfo", category: .ui)
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

    /// Prune image cache if it exceeds maximum size
    private func pruneImageCacheIfNeeded() {
        guard imageCache.count >= Self.maxImageCacheSize else { return }

        // Get valid frame IDs (frames currently in the window)
        let validFrameIDs = Set(frames.map { $0.frame.id })

        // Remove images for frames that are no longer in the window
        let oldCount = imageCache.count
        imageCache = imageCache.filter { validFrameIDs.contains($0.key) }

        let removedCount = oldCount - imageCache.count
        if removedCount > 0 {
            if Self.isVerboseTimelineLoggingEnabled {
                Log.info("[Memory] Pruned \(removedCount) images from cache (frames no longer in window)", category: .ui)
            }
        }

        // If still too large, remove oldest entries (keep half)
        if imageCache.count >= Self.maxImageCacheSize {
            let toRemove = imageCache.count - (Self.maxImageCacheSize / 2)
            let keysToRemove = Array(imageCache.keys.prefix(toRemove))
            keysToRemove.forEach { imageCache.removeValue(forKey: $0) }
            if Self.isVerboseTimelineLoggingEnabled {
                Log.info("[Memory] Force-pruned \(toRemove) images from cache (cache overflow)", category: .ui)
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

        // Clear search highlight when user manually scrolls
        if isShowingSearchHighlight {
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

            // Clear old image cache
            let oldCacheCount = imageCache.count
            imageCache.removeAll()
            if oldCacheCount > 0 {
                Log.info("[Memory] Cleared image cache on calendar navigation (\(oldCacheCount) images removed)", category: .ui)
            }

            frames = framesWithVideoInfo.map { TimelineFrame(frame: $0.frame, videoInfo: $0.videoInfo, processingStatus: $0.processingStatus) }

            updateWindowBoundaries()
            resetBoundaryStateForReloadWindow()

            let closestIndex = findClosestFrameIndex(to: targetDate)
            currentIndex = closestIndex

            loadImageIfNeeded()
            _ = checkAndLoadMoreFrames(reason: "navigateToDate")
            setLoadingState(false, reason: "navigateToDate.success")
        } catch {
            self.error = "Failed to navigate: \(error.localizedDescription)"
            setLoadingState(false, reason: "navigateToDate.error")
        }
    }

    /// Search for frames around a natural language date string, or by frame ID if enabled
    public func searchForDate(_ searchText: String) async {
        guard !searchText.isEmpty else { return }

        setLoadingState(true, reason: "searchForDate")
        clearError()
        cancelBoundaryLoadTasks(reason: "searchForDate")
        dateJumpTraceID += 1
        let jumpTraceID = dateJumpTraceID
        Log.info("[DateJump:\(jumpTraceID)] START input='\(searchText)' current=\(currentTimestamp.map { Log.timestamp(from: $0) } ?? "nil")", category: .ui)

        // Exit live mode if active (we're navigating away from "now")
        if isInLiveMode {
            isInLiveMode = false
            liveScreenshot = nil
            isTapeHidden = false
        }

        do {
            // If frame ID search is enabled and input looks like a frame ID (pure number), try that first
            if enableFrameIDSearch, let frameID = Int64(searchText.trimmingCharacters(in: .whitespaces)) {
                if await searchForFrameID(frameID) {
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
                guard let parsedDate = parseNaturalLanguageDate(searchText) else {
                    showErrorWithAutoDismiss("Could not understand: \(searchText)")
                    setLoadingState(false, reason: "searchForDate.parseFailed")
                    return
                }
                targetDate = parsedDate
            }

            clearActiveFiltersBeforeJumpIfNeeded(trigger: "date input jump")

            let anchoredTargetDate = try await resolveDateSearchAnchorDate(
                parsedDate: targetDate,
                input: searchText
            )
            Log.info(
                "[DateJump:\(jumpTraceID)] target parsed=\(Log.timestamp(from: targetDate)) anchored=\(Log.timestamp(from: anchoredTargetDate))",
                category: .ui
            )

            // Load frames around the target date (±10 minutes window)
            let calendar = Calendar.current
            let startDate = calendar.date(byAdding: .minute, value: -10, to: anchoredTargetDate) ?? anchoredTargetDate
            let endDate = calendar.date(byAdding: .minute, value: 10, to: anchoredTargetDate) ?? anchoredTargetDate
            Log.info(
                "[DateJump:\(jumpTraceID)] query range=\(Log.timestamp(from: startDate)) -> \(Log.timestamp(from: endDate))",
                category: .ui
            )

            // Debug logging
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
            df.timeZone = .current
            Log.debug("[DateSearch] Input: '\(searchText)'", category: .ui)
            Log.debug("[DateSearch] Parsed targetDate (local): \(df.string(from: targetDate))", category: .ui)
            Log.debug("[DateSearch] Anchored targetDate (local): \(df.string(from: anchoredTargetDate))", category: .ui)
            df.timeZone = TimeZone(identifier: "UTC")
            Log.debug("[DateSearch] Parsed targetDate (UTC): \(df.string(from: targetDate))", category: .ui)
            Log.debug("[DateSearch] Anchored targetDate (UTC): \(df.string(from: anchoredTargetDate))", category: .ui)
            df.timeZone = .current
            Log.debug("[DateSearch] Query range: \(df.string(from: startDate)) to \(df.string(from: endDate))", category: .ui)

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
            Log.debug("[DateSearch] Got \(framesWithVideoInfo.count) frames", category: .ui)
            if let first = framesWithVideoInfo.first, let last = framesWithVideoInfo.last {
                Log.info(
                    "[DateJump:\(jumpTraceID)] result count=\(framesWithVideoInfo.count) first=\(Log.timestamp(from: first.frame.timestamp)) last=\(Log.timestamp(from: last.frame.timestamp))",
                    category: .ui
                )
            } else {
                Log.info("[DateJump:\(jumpTraceID)] result count=0", category: .ui)
            }

            guard !framesWithVideoInfo.isEmpty else {
                showErrorWithAutoDismiss("No frames found around \(formatLocalDateForError(targetDate))")
                setLoadingState(false, reason: "searchForDate.noFrames")
                return
            }

            // Clear old image cache since we're jumping to a new time window
            let oldCacheCount = imageCache.count
            imageCache.removeAll()
            if oldCacheCount > 0 {
                Log.info("[Memory] Cleared image cache on date search (\(oldCacheCount) images removed)", category: .ui)
            }

            // Convert to TimelineFrame - video info is already included from the JOIN
            frames = framesWithVideoInfo.map { TimelineFrame(frame: $0.frame, videoInfo: $0.videoInfo, processingStatus: $0.processingStatus) }

            // Reset infinite scroll state for new window
            updateWindowBoundaries()
            resetBoundaryStateForReloadWindow()

            // Find the frame closest to the target date in our centered set
            let closestIndex = findClosestFrameIndex(to: anchoredTargetDate)
            currentIndex = closestIndex
            logFrameWindowSummary(context: "POST searchForDate", traceID: jumpTraceID)

            // Load image if needed
            loadImageIfNeeded()
            _ = checkAndLoadMoreFrames(reason: "searchForDate")

            // Log memory state after date search
            MemoryTracker.logMemoryState(
                context: "DATE SEARCH COMPLETE",
                frameCount: frames.count,
                imageCacheCount: imageCache.count,
                oldestTimestamp: oldestLoadedTimestamp,
                newestTimestamp: newestLoadedTimestamp
            )

            setLoadingState(false, reason: "searchForDate.success")
            closeDateSearch()

        } catch {
            self.error = "Failed to search for date: \(error.localizedDescription)"
            Log.error("[DateJump:\(jumpTraceID)] FAILED: \(error)", category: .ui)
            setLoadingState(false, reason: "searchForDate.error")
        }
    }

    /// Search for a frame by its ID and navigate to it
    /// Returns true if frame was found and navigation succeeded
    private func searchForFrameID(_ frameID: Int64) async -> Bool {
        Log.debug("[FrameIDSearch] Looking for frame ID: \(frameID)", category: .ui)
        cancelBoundaryLoadTasks(reason: "searchForFrameID")

        do {
            // Try to get the frame by ID
            guard let frameWithVideo = try await coordinator.getFrameWithVideoInfoByID(id: FrameID(value: frameID)) else {
                Log.debug("[FrameIDSearch] Frame not found: \(frameID)", category: .ui)
                error = "Frame #\(frameID) not found"
                setLoadingState(false, reason: "searchForFrameID.notFound")
                return false
            }

            let targetFrame = frameWithVideo.frame
            let targetDate = targetFrame.timestamp
            Log.debug("[FrameIDSearch] Found frame \(frameID) at \(targetDate)", category: .ui)

            clearActiveFiltersBeforeJumpIfNeeded(trigger: "frame ID jump")

            // Load frames around the target frame's timestamp (±10 minutes window)
            let calendar = Calendar.current
            let startDate = calendar.date(byAdding: .minute, value: -10, to: targetDate) ?? targetDate
            let endDate = calendar.date(byAdding: .minute, value: 10, to: targetDate) ?? targetDate

            // Fetch all frames in the window
            // Always pass filterCriteria to ensure hidden filter is applied (default: .hide)
            let framesWithVideoInfo = try await fetchFramesWithVideoInfoLogged(
                from: startDate,
                to: endDate,
                limit: 1000,
                filters: filterCriteria,
                reason: "searchForFrameID"
            )
            Log.debug("[FrameIDSearch] Got \(framesWithVideoInfo.count) frames in window", category: .ui)

            guard !framesWithVideoInfo.isEmpty else {
                showErrorWithAutoDismiss("No frames found around frame #\(frameID)")
                setLoadingState(false, reason: "searchForFrameID.noFramesInWindow")
                return false
            }

            // Clear old image cache since we're jumping to a new time window
            let oldCacheCount = imageCache.count
            imageCache.removeAll()
            if oldCacheCount > 0 {
                Log.info("[Memory] Cleared image cache on frame ID search (\(oldCacheCount) images removed)", category: .ui)
            }

            // Convert to TimelineFrame
            frames = framesWithVideoInfo.map { TimelineFrame(frame: $0.frame, videoInfo: $0.videoInfo, processingStatus: $0.processingStatus) }

            // Reset infinite scroll state for new window
            updateWindowBoundaries()
            resetBoundaryStateForReloadWindow()

            // Find the exact frame by ID in our loaded frames
            if let exactIndex = frames.firstIndex(where: { $0.frame.id.value == frameID }) {
                currentIndex = exactIndex
                Log.debug("[FrameIDSearch] Navigated to exact frame at index \(exactIndex)", category: .ui)
            } else {
                // Fallback to closest by timestamp
                let closestIndex = findClosestFrameIndex(to: targetDate)
                currentIndex = closestIndex
                Log.debug("[FrameIDSearch] Frame not in window, using closest at index \(closestIndex)", category: .ui)
            }

            // Load image if needed
            loadImageIfNeeded()
            _ = checkAndLoadMoreFrames(reason: "searchForFrameID")

            // Log memory state after frame ID search
            MemoryTracker.logMemoryState(
                context: "FRAME ID SEARCH COMPLETE",
                frameCount: frames.count,
                imageCacheCount: imageCache.count,
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

        Log.debug(
            "[DateSearch] Relative '\(normalized)' resolved from base=\(baseTimestamp) to target=\(resolvedDate)",
            category: .ui
        )
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

        if collapsedInput.range(of: #"^start of (the )?day$"#, options: .regularExpression) != nil {
            return calendar.startOfDay(for: now)
        }

        func finalizeParsedDate(_ parsedDate: Date) -> Date {
            let anchorMode = inferDateSearchAnchorMode(for: normalizedInput)
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
        if let result = chrono.parse(text: trimmed, refDate: now, opt: [:]).first?.start.date {
            let normalized = finalizeParsedDate(result)
            Log.debug("[DateSearch] SwiftyChrono parsed '\(trimmed)' as \(normalized)", category: .ui)
            return normalized
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

        // Normalize compact time formats (e.g., "827am" -> "8:27am") before passing to NSDataDetector
        // This allows "827am yesterday" to work the same as "8:27am yesterday"
        let normalizedText = normalizeCompactTimeFormat(trimmedLower)

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
            Log.debug("[DateSearch] Anchor mode=\(mode.rawValue) found no frames in bucket; falling back to parsed date", category: .ui)
            return parsedDate
        }

        Log.debug(
            "[DateSearch] Anchor mode=\(mode.rawValue) resolved first frame at \(anchoredTimestamp)",
            category: .ui
        )
        return anchoredTimestamp
    }

    private func inferDateSearchAnchorMode(for input: String) -> DateSearchAnchorMode {
        let normalized = input
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

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
        let hasDateLikeToken = hasCalendarDateToken || hasDayLevelNaturalLanguageToken
        let hasExplicitTime = normalized.range(
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

        Log.debug(
            "[DateSearch] Adjusted yearless future date '\(input)' from \(parsedDate) to \(priorYearDate)",
            category: .ui
        )
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

        Log.debug(
            "[DateSearch] Adjusted future time-only input '\(input)' from \(parsedDate) to \(priorDayDate)",
            category: .ui
        )
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
    /// Converts "827am" -> "8:27am", "1130pm" -> "11:30pm", etc.
    /// This allows inputs like "827am yesterday" to work the same as "8:27am yesterday"
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

        return result
    }

    /// Find the frame index closest to a target date
    private func findClosestFrameIndex(to targetDate: Date) -> Int {
        guard !frames.isEmpty else { return 0 }

        var closestIndex = 0
        var smallestDiff = abs(frames[0].frame.timestamp.timeIntervalSince(targetDate))

        for (index, timelineFrame) in frames.enumerated() {
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
            Log.info(
                "[BoundaryOlder] START reason=\(reason) window=\(Log.timestamp(from: rangeStart))->\(Log.timestamp(from: rangeEnd)) effectiveWindow=\(Log.timestamp(from: boundedFilters.startDate ?? rangeStart))->\(Log.timestamp(from: boundedFilters.endDate ?? rangeEnd)) currentOldest=\(Log.timestamp(from: oldestTimestamp))",
                category: .ui
            )
            let queryStart = CFAbsoluteTimeGetCurrent()
            let framesWithVideoInfoDescending = try await fetchFramesWithVideoInfoBeforeLogged(
                timestamp: oldestTimestamp,
                limit: WindowConfig.loadBatchSize,
                filters: boundedFilters,
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
                TimelineFrame(frame: $0.frame, videoInfo: $0.videoInfo, processingStatus: $0.processingStatus)
            }

            // Prepend to existing frames
            // Use insert(contentsOf:) to avoid unnecessary @Published triggers
            let beforeCount = frames.count
            let oldCurrentIndex = currentIndex
            let oldTimestamp = frames[currentIndex].frame.timestamp
            let oldFirstTimestamp = frames.first?.frame.timestamp

            frames.insert(contentsOf: newTimelineFrames, at: 0)

            // Adjust currentIndex to maintain position
            currentIndex += newTimelineFrames.count

            Log.info("[Memory] LOADED OLDER: +\(newTimelineFrames.count) frames (\(beforeCount)→\(frames.count)), index adjusted from \(oldCurrentIndex) to \(currentIndex), maintaining timestamp=\(oldTimestamp)", category: .ui)
            Log.info("[INFINITE-SCROLL] After load older: new first frame=\(frames.first?.frame.timestamp.description ?? "nil"), new last frame=\(frames.last?.frame.timestamp.description ?? "nil")", category: .ui)
            if let oldFirstTimestamp, let bridge = newTimelineFrames.last?.frame.timestamp {
                let bridgeGap = max(0, oldFirstTimestamp.timeIntervalSince(bridge))
                Log.info(
                    "[BoundaryOlder] MERGE reason=\(reason) bridgeGap=\(String(format: "%.1fs", bridgeGap)) oldFirst=\(Log.timestamp(from: oldFirstTimestamp)) insertedLast=\(Log.timestamp(from: bridge))",
                    category: .ui
                )
            }
            MemoryTracker.logMemoryState(
                context: "AFTER LOAD OLDER",
                frameCount: frames.count,
                imageCacheCount: imageCache.count,
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
            let framesWithVideoInfo = try await fetchFramesWithVideoInfoLogged(
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
            let newTimelineFrames = framesWithVideoInfo.map { TimelineFrame(frame: $0.frame, videoInfo: $0.videoInfo, processingStatus: $0.processingStatus) }

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
                imageCacheCount: imageCache.count,
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

    /// Trim the window if it exceeds max frames
    private func trimWindowIfNeeded(preserveDirection: TrimDirection) {
        guard frames.count > WindowConfig.maxFrames else { return }

        let excessCount = frames.count - WindowConfig.maxFrames
        let beforeCount = frames.count

        switch preserveDirection {
        case .older:
            // User is scrolling toward older, trim newer frames from end
            Log.info("[Memory] TRIMMING \(excessCount) newer frames from END (preserving older)", category: .ui)
            frames = Array(frames.dropLast(excessCount))
            // Only mark that there might be more newer frames if we haven't hit the absolute end
            if !hasReachedAbsoluteEnd {
                hasMoreNewer = true
            }

        case .newer:
            // User is scrolling toward newer, trim older frames from start
            Log.info("[Memory] TRIMMING \(excessCount) older frames from START (preserving newer)", category: .ui)
            frames = Array(frames.dropFirst(excessCount))
            // Adjust currentIndex
            currentIndex = max(0, currentIndex - excessCount)
            // Only mark that there might be more older frames if we haven't hit the absolute start
            if !hasReachedAbsoluteStart {
                hasMoreOlder = true
            }
        }

        // Update boundaries after trimming
        updateWindowBoundaries()

        // Log the memory state after trimming
        MemoryTracker.logMemoryState(
            context: "AFTER TRIM (\(beforeCount)→\(frames.count))",
            frameCount: frames.count,
            imageCacheCount: imageCache.count,
            oldestTimestamp: oldestLoadedTimestamp,
            newestTimestamp: newestLoadedTimestamp
        )
    }
}
