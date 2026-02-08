import SwiftUI
import Combine
import AVFoundation
import Shared
import App
import Processing

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
    /// Secondary display payloads associated with this frame's timestamp.
    public let secondaryFrames: [SecondaryDisplayFrameInfo]

    public var id: FrameID { frame.id }

    public init(
        frame: FrameReference,
        videoInfo: FrameVideoInfo?,
        processingStatus: Int,
        secondaryFrames: [SecondaryDisplayFrameInfo] = []
    ) {
        self.frame = frame
        self.videoInfo = videoInfo
        self.processingStatus = processingStatus
        self.secondaryFrames = secondaryFrames
    }

    public static func == (lhs: TimelineFrame, rhs: TimelineFrame) -> Bool {
        lhs.frame.id == rhs.frame.id
    }
}

/// Represents a block of consecutive frames from the same app
public struct AppBlock: Identifiable {
    // Use stable ID based on content to prevent unnecessary view recreation during infinite scroll
    public var id: String {
        "\(bundleID ?? "nil")_\(startIndex)_\(endIndex)"
    }
    public let bundleID: String?
    public let appName: String?
    public let startIndex: Int
    public let endIndex: Int
    public let frameCount: Int

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

    // MARK: - Published State

    /// All loaded frames with their preloaded video info
    @Published public var frames: [TimelineFrame] = [] {
        didSet {
            // Clear cached blocks when frames change
            // Note: This is necessary because blocks depend on frame ranges
            // The slight performance hit is acceptable for correctness
            _cachedAppBlocks = nil
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

                // Keep primary display selection aligned with segment boundaries
                // for all index changes (including direct index assignment paths).
                syncPrimaryDisplaySelection()
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

    // MARK: - Timeline HUD Toast State

    /// Global top-center HUD toast message (shared feedback channel).
    @Published public var timelineHUDToastMessage: String?

    /// Controls visibility of the global top-center HUD toast.
    @Published public var showTimelineHUDToast: Bool = false

    /// Auto-dismiss task for global HUD toast.
    private var timelineHUDToastDismissTask: Task<Void, Never>?

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

    /// Frame indices where video boundaries occur (first frame of each new video)
    /// A boundary exists when the videoPath changes between consecutive frames
    public var videoBoundaryIndices: Set<Int> {
        guard frames.count > 1 else { return [] }

        var boundaries = Set<Int>()
        var previousVideoPath: String? = nil

        for (index, frame) in frames.enumerated() {
            let currentVideoPath = frame.videoInfo?.videoPath
            if let prev = previousVideoPath, let curr = currentVideoPath, prev != curr {
                // Video changed - this frame is a boundary (first frame of new video)
                boundaries.insert(index)
            }
            previousVideoPath = currentVideoPath
        }

        return boundaries
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
        presentTimelineHUDToast(message: "Speed \(speed == 1 ? "1x" : "\(Int(speed))x")")
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
            showContextMenu = false
        }
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

    /// Whether the "create new tag" input is visible
    @Published public var showNewTagInput: Bool = false

    /// Text for the new tag name input
    @Published public var newTagName: String = ""

    /// Whether the mouse is hovering over the "Add Tag" button
    @Published public var isHoveringAddTagButton: Bool = false

    /// All available tags
    @Published public var availableTags: [Tag] = []

    /// Tags applied to the currently selected segment (for showing checkmarks)
    @Published public var selectedSegmentTags: Set<TagID> = []

    /// Set of segment IDs that are hidden
    @Published public var hiddenSegmentIds: Set<SegmentID> = []

    /// Dismiss the timeline context menu
    public func dismissTimelineContextMenu() {
        showTimelineContextMenu = false
        showTagSubmenu = false
        showNewTagInput = false
        newTagName = ""
        isHoveringAddTagButton = false
        selectedSegmentTags = []
    }

    // MARK: - Filter State

    /// Current applied filter criteria
    @Published public var filterCriteria: FilterCriteria = .none

    /// Pending filter criteria (edited in panel, applied on submit)
    @Published public var pendingFilterCriteria: FilterCriteria = .none

    /// Whether the filter panel is visible
    @Published public var isFilterPanelVisible: Bool = false

    /// Whether any filter dropdown (apps, tags, visibility) is open in the filter panel
    /// Set by FilterPanel view to allow TimelineWindowController to skip escape handling
    @Published public var isFilterDropdownOpen: Bool = false

    // MARK: - Filter Dropdown State (lifted to ViewModel for proper rendering outside FilterPanel)

    /// Which filter dropdown is currently open (rendered at SimpleTimelineView level to avoid clipping)
    public enum FilterDropdownType: Equatable {
        case none
        case apps
        case tags
        case visibility
        case dateRange
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
        isFilterDropdownOpen = type != .none
    }

    /// Dismiss any open filter dropdown
    public func dismissFilterDropdown() {
        if Self.isVerboseTimelineLoggingEnabled {
            Log.debug("[FilterDropdown] dismissFilterDropdown", category: .ui)
        }
        activeFilterDropdown = .none
        isFilterDropdownOpen = false
    }

    /// Apps available for filtering (installed apps only)
    @Published public var availableAppsForFilter: [(bundleID: String, name: String)] = []

    /// Other apps for filtering (apps from DB history that aren't currently installed)
    @Published public var otherAppsForFilter: [(bundleID: String, name: String)] = []

    /// Whether apps for filter are currently being loaded
    @Published public var isLoadingAppsForFilter = false

    /// Map of segment IDs to their tag IDs (for efficient tag filtering)
    @Published public var segmentTagsMap: [Int64: Set<Int64>] = [:]

    /// Number of active filters (for badge display)
    public var activeFilterCount: Int {
        filterCriteria.activeFilterCount
    }

    /// Whether pending filters differ from applied filters
    public var hasPendingFilterChanges: Bool {
        pendingFilterCriteria != filterCriteria
    }

    /// Timeline loads should default to focused stream in native multi-display mode.
    /// Rewind remains visible because it aliases frames as focused.
    private var effectiveTimelineFilters: FilterCriteria {
        var effective = filterCriteria
        if isMultiDisplayEnabled {
            if isPrimaryDisplayPinned, primaryDisplayID != 0 {
                // Pinned mode rewrites the timeline tape to the pinned display stream.
                effective.displayID = primaryDisplayID
                // Show full stream for pinned display (not only globally-focused frames).
                effective.focusedOnly = nil
            } else if effective.focusedOnly == nil {
                // Default tape remains focused stream only.
                effective.focusedOnly = true
            }
        }
        return effective
    }

    // MARK: - Multi-Display State (PIP for secondary displays)

    /// Display IDs that have frames in the current time range
    @Published public var availableDisplayIDs: [UInt32] = []

    /// The display ID currently shown fullscreen.
    /// Default: follows active display for current segment.
    /// Override: per-segment swap or global pin.
    @Published public var primaryDisplayID: UInt32 = 0

    /// Whether primary display selection is pinned by user swap (persistent until changed).
    @Published public var isPrimaryDisplayPinned: Bool = false

    /// Override video info for the pinned primary display when it differs from timeline focus.
    @Published public var primaryDisplayVideoInfoOverride: FrameVideoInfo?

    /// Secondary display frames for PIP overlay (one per non-primary display)
    @Published public var secondaryDisplayFrames: [(displayID: UInt32, videoInfo: FrameVideoInfo?)] = []

    /// Persisted display names loaded from database (fallback when display is currently disconnected).
    private var persistedDisplayNames: [UInt32: String] = [:]

    /// Signature for the in-memory PIP cache over the current loaded timeline window.
    private struct PIPDisplayCacheSignature: Equatable {
        let rangeStartMs: Int64
        let rangeEndMs: Int64
        let displayIDs: [UInt32]
    }

    /// Cached per-display frame stream for PIP carry-forward.
    private struct PIPDisplayCacheEntry {
        /// Frames inside the current loaded window, sorted ascending by timestamp.
        let frames: [FrameWithVideoInfo]
        /// Seed frame before window start for carry-forward.
        let frameBeforeWindow: FrameWithVideoInfo?
        /// True when the range query hit the configured limit.
        let isTruncated: Bool
        /// True when the build failed and runtime fallback should be used.
        let buildFailed: Bool
    }

    /// Full in-memory cache for all active displays over the loaded window.
    private struct PIPDisplayFrameCache {
        let signature: PIPDisplayCacheSignature
        let rangeStart: Date
        let rangeEnd: Date
        let entriesByDisplay: [UInt32: PIPDisplayCacheEntry]
    }

    /// Result of resolving a display frame from cache.
    private struct PIPDisplayResolution {
        let videoInfo: FrameVideoInfo?
        /// If true, caller should fallback to DB nearest-frame query for correctness.
        let needsFallbackQuery: Bool
    }

    /// Whether multi-display recording is enabled (read from settings)
    private var isMultiDisplayEnabled: Bool {
        UserDefaults(suiteName: "io.retrace.app")?.bool(forKey: "recordAllDisplays") ?? false
    }

    /// Last observed multi-display setting value. Used to detect runtime flips while timeline is cached.
    private var lastKnownMultiDisplayEnabled: Bool

    /// Lower bound for per-display cache build query size.
    private static let pipPerDisplayQueryMinLimit = WindowConfig.maxFrames

    /// Upper bound for per-display cache build query size.
    private static let pipPerDisplayQueryMaxLimit = 5_000

    /// Capture cadence estimate used to size cache build queries.
    private static let pipCaptureIntervalEstimateSeconds: TimeInterval = 2.0

    /// Safety buffer appended to estimated per-display query size.
    private static let pipPerDisplayQuerySafetyBuffer = 120

    /// A frame is display-identifiable when native multi-display metadata resolved a non-zero display ID.
    /// Rewind frames are exempt because that source does not carry per-display metadata.
    private func hasIdentifiableDisplay(_ frame: FrameReference) -> Bool {
        guard isMultiDisplayEnabled, frame.source == .native else { return true }
        return frame.metadata.displayID != 0
    }

    /// Drop native payload rows that do not map to a concrete display in multi-display mode.
    private func filterTimelinePayloadsWithoutIdentifiableDisplay(
        _ payloads: [TimelineFramePayload],
        context: String
    ) -> [TimelineFramePayload] {
        let filtered = payloads.filter { hasIdentifiableDisplay($0.frame) }
        let droppedCount = payloads.count - filtered.count
        if droppedCount > 0 {
            Log.warning(
                "[MultiDisplay] Dropped \(droppedCount) timeline payload(s) without identifiable display in \(context)",
                category: .ui
            )
        }
        return filtered
    }

    /// Convert one-query timeline payloads into view-model timeline frames.
    /// Secondary display payloads are already attached in each payload row.
    private func makeTimelineFrames(
        from payloads: [TimelineFramePayload],
        reverseOrder: Bool = false,
        context: String
    ) async -> [TimelineFrame] {
        let filtered = filterTimelinePayloadsWithoutIdentifiableDisplay(payloads, context: context)
        let ordered = reverseOrder ? Array(filtered.reversed()) : filtered

        guard !ordered.isEmpty else { return [] }

        return ordered.map {
            TimelineFrame(
                frame: $0.frame,
                videoInfo: $0.videoInfo,
                processingStatus: $0.processingStatus,
                secondaryFrames: $0.secondaryFrames
            )
        }
    }

    /// Remove unknown/null display IDs from multi-display UI state.
    private func filterIdentifiableDisplayIDs(_ displayIDs: [UInt32], context: String) -> [UInt32] {
        let filtered = displayIDs.filter { $0 != 0 }
        let droppedCount = displayIDs.count - filtered.count
        if droppedCount > 0 {
            Log.warning(
                "[MultiDisplay] Dropped \(droppedCount) unknown display ID(s) in \(context)",
                category: .ui
            )
        }
        return filtered
    }

    /// Current primary display label for UI badges/buttons.
    public var primaryDisplayLabel: String {
        displayLabel(for: primaryDisplayID)
    }

    /// Resolve which display should be shown in the primary area.
    /// Priority:
    /// 1) pinned display (global)
    /// 2) active display from current frame segment
    /// 3) first available display fallback
    private func resolvePrimaryDisplayID(for frame: FrameReference?, displayIDs: [UInt32]? = nil) -> UInt32? {
        let available = displayIDs ?? availableDisplayIDs

        func isAvailable(_ id: UInt32) -> Bool {
            available.isEmpty || available.contains(id)
        }

        if isPrimaryDisplayPinned, primaryDisplayID != 0, isAvailable(primaryDisplayID) {
            return primaryDisplayID
        }

        if let activeDisplay = frame?.metadata.displayID, activeDisplay != 0, isAvailable(activeDisplay) {
            return activeDisplay
        }

        if let first = available.first {
            return first
        }

        return primaryDisplayID != 0 ? primaryDisplayID : nil
    }

    /// Apply resolved primary display selection for current timeline position.
    private func syncPrimaryDisplaySelection() {
        guard let resolved = resolvePrimaryDisplayID(for: currentFrame) else { return }
        if primaryDisplayID != resolved {
            primaryDisplayID = resolved
        }
    }

    /// Reload the timeline tape after display policy changes (pin/unpin).
    /// Keeps user near current context when possible.
    private func reloadTimelineForDisplayPolicyChange() {
        let anchorTimestamp = currentTimestamp
        Task { @MainActor in
            if let anchorTimestamp {
                await reloadFramesAroundTimestamp(anchorTimestamp)
            } else {
                await loadMostRecentFrame()
            }
            await updateMultiDisplayState()
        }
    }

    /// Pin a specific display globally across the timeline.
    public func swapToDisplay(_ displayID: UInt32, preferredVideoInfo: FrameVideoInfo? = nil) {
        guard displayID != 0 else { return }
        let oldPrimary = primaryDisplayID
        let wasPinned = isPrimaryDisplayPinned
        primaryDisplayID = displayID
        isPrimaryDisplayPinned = true
        presentTimelineHUDToast(message: "Pinned \(displayLabel(for: displayID))")

        if let timelineDisplayID = currentFrame?.metadata.displayID {
            if timelineDisplayID != primaryDisplayID {
                primaryDisplayVideoInfoOverride = preferredVideoInfo
            } else {
                primaryDisplayVideoInfoOverride = nil
            }
        } else {
            primaryDisplayVideoInfoOverride = preferredVideoInfo
        }

        Log.info(
            "[MultiDisplay] Pinned display globally: \(oldPrimary) -> \(displayID), wasPinned=\(wasPinned)",
            category: .ui
        )
        reloadTimelineForDisplayPolicyChange()
    }

    /// Pin the currently shown display globally.
    /// Kept as a compatibility wrapper for existing UI call sites.
    public func pinCurrentDisplayAcrossSegments() {
        guard primaryDisplayID != 0 else { return }
        swapToDisplay(primaryDisplayID, preferredVideoInfo: currentVideoInfo)
    }

    /// Pin a specific display globally.
    /// Kept as a compatibility wrapper for existing UI call sites.
    public func pinDisplayAcrossSegments(_ displayID: UInt32) {
        swapToDisplay(displayID)
    }

    /// Remove global pin and return to active display mode.
    public func unpinPrimaryDisplay() {
        guard isPrimaryDisplayPinned else { return }
        isPrimaryDisplayPinned = false
        primaryDisplayVideoInfoOverride = nil
        syncPrimaryDisplaySelection()
        presentTimelineHUDToast(message: "Showing Active Display")
        Log.info("[MultiDisplay] Unpinned primary display; returning to active display mode", category: .ui)
        reloadTimelineForDisplayPolicyChange()
    }

    /// Show a global top-center HUD toast and auto-dismiss shortly after.
    public func presentTimelineHUDToast(message: String, duration: TimeInterval = 1.4) {
        timelineHUDToastDismissTask?.cancel()

        timelineHUDToastMessage = message
        withAnimation(.easeInOut(duration: 0.35)) {
            showTimelineHUDToast = true
        }

        timelineHUDToastDismissTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let nanos = UInt64(max(duration, 0) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanos)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.45)) {
                self.showTimelineHUDToast = false
            }
            // Keep the view mounted through fade-out, then clear message.
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            if !self.showTimelineHUDToast {
                self.timelineHUDToastMessage = nil
            }
        }
    }

    /// Update primary override + secondary display frames for the current timestamp (PIP carry-forward).
    func updateSecondaryDisplayFrames() async {
        guard availableDisplayIDs.count > 1 else {
            secondaryDisplayFrames = []
            primaryDisplayVideoInfoOverride = nil
            clearPIPDisplayFrameCache()
            return
        }

        guard let timestamp = currentFrame?.timestamp else {
            secondaryDisplayFrames = []
            primaryDisplayVideoInfoOverride = nil
            return
        }

        if let timelineFrame = currentTimelineFrame,
           !timelineFrame.secondaryFrames.isEmpty {
            syncPrimaryDisplaySelection()

            let timelineDisplayID = timelineFrame.frame.metadata.displayID
            let effectivePrimaryDisplayID = primaryDisplayID
            var secondaryByDisplayID: [UInt32: FrameVideoInfo?] = [:]
            for secondary in timelineFrame.secondaryFrames {
                secondaryByDisplayID[secondary.displayID] = secondary.videoInfo
            }

            var displayIDs = Set(timelineFrame.secondaryFrames.map(\.displayID))
            if timelineDisplayID != 0 {
                displayIDs.insert(timelineDisplayID)
            }
            let orderedDisplayIDs = Array(displayIDs).sorted()

            if orderedDisplayIDs.count <= 1 {
                secondaryDisplayFrames = []
                primaryDisplayVideoInfoOverride = nil
                return
            }

            // If the pinned/selected primary is not in this payload, fall back to dynamic resolution.
            if orderedDisplayIDs.contains(effectivePrimaryDisplayID) {
                var newPrimaryOverride: FrameVideoInfo?
                var newSecondaryFrames: [(displayID: UInt32, videoInfo: FrameVideoInfo?)] = []

                if effectivePrimaryDisplayID != timelineDisplayID {
                    newPrimaryOverride = secondaryByDisplayID[effectivePrimaryDisplayID] ?? nil
                }

                for displayID in orderedDisplayIDs where displayID != effectivePrimaryDisplayID {
                    if displayID == timelineDisplayID {
                        newSecondaryFrames.append((displayID: displayID, videoInfo: currentVideoInfo))
                    } else {
                        newSecondaryFrames.append(
                            (displayID: displayID, videoInfo: secondaryByDisplayID[displayID] ?? nil)
                        )
                    }
                }

                primaryDisplayVideoInfoOverride = newPrimaryOverride
                secondaryDisplayFrames = newSecondaryFrames
                return
            }
        }

        syncPrimaryDisplaySelection()
        let effectivePrimaryDisplayID = primaryDisplayID
        let allDisplayIDs = availableDisplayIDs.sorted()
        let connectedDisplayIDs: Set<UInt32>
        do {
            connectedDisplayIDs = Set(try await coordinator.getConnectedDisplayIDs(at: timestamp))
        } catch {
            Log.error("[MultiDisplay] Failed to resolve connected displays at \(timestamp): \(error)", category: .ui)
            connectedDisplayIDs = Set(allDisplayIDs)
        }

        let displayIDs = allDisplayIDs.filter { displayID in
            // Fallback behavior: if no display segments exist yet, use all displays found in frame data.
            if connectedDisplayIDs.isEmpty {
                return true
            }
            // Always keep the effective primary display to avoid blank primary playback if metadata lags.
            return connectedDisplayIDs.contains(displayID) || displayID == effectivePrimaryDisplayID
        }

        if displayIDs.count <= 1 {
            secondaryDisplayFrames = []
            if displayIDs.first != effectivePrimaryDisplayID {
                primaryDisplayVideoInfoOverride = nil
            }
            clearPIPDisplayFrameCache()
            return
        }

        let timelineDisplayID = currentFrame?.metadata.displayID
        let cacheSignature = makePIPDisplayCacheSignature(displayIDs: displayIDs)

        if let signature = cacheSignature {
            schedulePIPDisplayFrameCacheBuildIfNeeded(signature: signature)
        }

        var resolvedByDisplay: [UInt32: PIPDisplayResolution] = [:]
        var displaysNeedingDBLookup = Set(displayIDs)

        if let signature = cacheSignature,
           let cache = pipDisplayFrameCache,
           cache.signature == signature {
            for displayID in displayIDs {
                let resolution = resolvePIPDisplayVideoInfo(
                    displayID: displayID,
                    at: timestamp,
                    cache: cache
                )
                if resolution.needsFallbackQuery {
                    continue
                }
                resolvedByDisplay[displayID] = resolution
                displaysNeedingDBLookup.remove(displayID)
            }
        }

        if !displaysNeedingDBLookup.isEmpty {
            let fallbackOrder = displayIDs.filter { displaysNeedingDBLookup.contains($0) }
            let fallbackResults = await fetchNearestVideoInfoForDisplays(
                fallbackOrder,
                before: timestamp
            )
            for displayID in fallbackOrder {
                resolvedByDisplay[displayID] = fallbackResults[displayID] ??
                    PIPDisplayResolution(videoInfo: nil, needsFallbackQuery: false)
            }
        }

        var newPrimaryOverride: FrameVideoInfo?
        var newSecondaryFrames: [(displayID: UInt32, videoInfo: FrameVideoInfo?)] = []

        for displayID in displayIDs {
            let videoInfo = resolvedByDisplay[displayID]?.videoInfo

            if displayID == effectivePrimaryDisplayID {
                if timelineDisplayID != effectivePrimaryDisplayID {
                    newPrimaryOverride = videoInfo
                } else {
                    newPrimaryOverride = nil
                }
            } else {
                newSecondaryFrames.append((displayID: displayID, videoInfo: videoInfo))
            }
        }

        primaryDisplayVideoInfoOverride = newPrimaryOverride
        secondaryDisplayFrames = newSecondaryFrames
    }

    /// Build a compact signature for the currently loaded timeline window + active displays.
    private func makePIPDisplayCacheSignature(displayIDs: [UInt32]) -> PIPDisplayCacheSignature? {
        guard let rangeStart = oldestLoadedTimestamp, let rangeEnd = newestLoadedTimestamp else {
            return nil
        }

        return PIPDisplayCacheSignature(
            rangeStartMs: Int64((rangeStart.timeIntervalSince1970 * 1000).rounded()),
            rangeEndMs: Int64((rangeEnd.timeIntervalSince1970 * 1000).rounded()),
            displayIDs: displayIDs.sorted()
        )
    }

    /// Estimate a per-display query limit for building the in-memory PIP cache.
    private func estimatePIPPerDisplayQueryLimit(rangeStart: Date, rangeEnd: Date) -> Int {
        let durationSeconds = max(0, rangeEnd.timeIntervalSince(rangeStart))
        let estimatedFrames = Int(ceil(durationSeconds / Self.pipCaptureIntervalEstimateSeconds))
        let baseLimit = max(
            Self.pipPerDisplayQueryMinLimit,
            estimatedFrames + Self.pipPerDisplayQuerySafetyBuffer
        )
        return min(baseLimit, Self.pipPerDisplayQueryMaxLimit)
    }

    /// Start a background cache build if we don't already have a valid one for this signature.
    private func schedulePIPDisplayFrameCacheBuildIfNeeded(signature: PIPDisplayCacheSignature) {
        if pipDisplayFrameCache?.signature == signature {
            return
        }

        if pipDisplayFrameCacheBuildSignature == signature {
            return
        }

        pipDisplayFrameCacheBuildTask?.cancel()
        pipDisplayFrameCacheBuildSignature = signature

        pipDisplayFrameCacheBuildTask = Task { [weak self] in
            guard let self else { return }

            let cache = await self.buildPIPDisplayFrameCache(for: signature)
            guard !Task.isCancelled else { return }

            guard self.pipDisplayFrameCacheBuildSignature == signature else { return }

            self.pipDisplayFrameCache = cache
            self.pipDisplayFrameCacheBuildTask = nil
            self.pipDisplayFrameCacheBuildSignature = nil

            // Apply freshly built cache on the next coalesced update.
            self.schedulePIPUpdate()
        }
    }

    /// Build per-display frame streams for the loaded window so scrubbing can resolve in-memory.
    private func buildPIPDisplayFrameCache(for signature: PIPDisplayCacheSignature) async -> PIPDisplayFrameCache {
        let rangeStart = Date(timeIntervalSince1970: Double(signature.rangeStartMs) / 1000.0)
        let rangeEnd = Date(timeIntervalSince1970: Double(signature.rangeEndMs) / 1000.0)
        let perDisplayLimit = estimatePIPPerDisplayQueryLimit(rangeStart: rangeStart, rangeEnd: rangeEnd)

        typealias BuildResult = (
            displayID: UInt32,
            frames: [FrameWithVideoInfo],
            frameBeforeWindow: FrameWithVideoInfo?,
            isTruncated: Bool,
            buildFailed: Bool,
            errorDescription: String?
        )

        let coordinator = self.coordinator
        let buildResults = await withTaskGroup(
            of: BuildResult.self,
            returning: [UInt32: BuildResult].self
        ) { group in
            for displayID in signature.displayIDs {
                group.addTask { [coordinator] in
                    do {
                        let displayFilter = FilterCriteria(
                            selectedApps: nil,
                            appFilterMode: .include,
                            selectedSources: Set([.native]),
                            hiddenFilter: .showAll,
                            selectedTags: nil,
                            tagFilterMode: .include,
                            windowNameFilter: nil,
                            browserUrlFilter: nil,
                            startDate: nil,
                            endDate: nil,
                            displayID: displayID,
                            focusedOnly: nil
                        )

                        let framesInRange = try await coordinator.getFramesWithVideoInfo(
                            from: rangeStart,
                            to: rangeEnd,
                            limit: perDisplayLimit,
                            filters: displayFilter
                        ).sorted { $0.frame.timestamp < $1.frame.timestamp }

                        let frameBeforeWindow = try? await coordinator.getNearestFrame(
                            displayID: displayID,
                            before: rangeStart
                        )

                        return (
                            displayID: displayID,
                            frames: framesInRange,
                            frameBeforeWindow: frameBeforeWindow,
                            isTruncated: framesInRange.count >= perDisplayLimit,
                            buildFailed: false,
                            errorDescription: nil
                        )
                    } catch {
                        return (
                            displayID: displayID,
                            frames: [],
                            frameBeforeWindow: nil,
                            isTruncated: false,
                            buildFailed: true,
                            errorDescription: String(describing: error)
                        )
                    }
                }
            }

            var results: [UInt32: BuildResult] = [:]
            for await result in group {
                results[result.displayID] = result
            }
            return results
        }

        var entriesByDisplay: [UInt32: PIPDisplayCacheEntry] = [:]
        for displayID in signature.displayIDs {
            if let result = buildResults[displayID] {
                if let errorDescription = result.errorDescription {
                    Log.error(
                        "[MultiDisplay] Failed to build PIP cache for display \(displayID): \(errorDescription)",
                        category: .ui
                    )
                }

                entriesByDisplay[displayID] = PIPDisplayCacheEntry(
                    frames: result.frames,
                    frameBeforeWindow: result.frameBeforeWindow,
                    isTruncated: result.isTruncated,
                    buildFailed: result.buildFailed
                )
            } else {
                entriesByDisplay[displayID] = PIPDisplayCacheEntry(
                    frames: [],
                    frameBeforeWindow: nil,
                    isTruncated: false,
                    buildFailed: true
                )
            }
        }

        if Self.isVerboseTimelineLoggingEnabled {
            let totalCachedFrames = entriesByDisplay.values.reduce(0) { $0 + $1.frames.count }
            Log.debug(
                "[MultiDisplay] Built PIP cache: displays=\(signature.displayIDs.count), totalFrames=\(totalCachedFrames), range=\(rangeStart)→\(rangeEnd)",
                category: .ui
            )
        }

        return PIPDisplayFrameCache(
            signature: signature,
            rangeStart: rangeStart,
            rangeEnd: rangeEnd,
            entriesByDisplay: entriesByDisplay
        )
    }

    /// Resolve a display's carry-forward frame from the in-memory cache.
    private func resolvePIPDisplayVideoInfo(
        displayID: UInt32,
        at timestamp: Date,
        cache: PIPDisplayFrameCache
    ) -> PIPDisplayResolution {
        guard let entry = cache.entriesByDisplay[displayID] else {
            return PIPDisplayResolution(videoInfo: nil, needsFallbackQuery: true)
        }

        if entry.buildFailed {
            return PIPDisplayResolution(videoInfo: nil, needsFallbackQuery: true)
        }

        let frames = entry.frames
        guard !frames.isEmpty else {
            return PIPDisplayResolution(
                videoInfo: entry.frameBeforeWindow?.videoInfo,
                needsFallbackQuery: false
            )
        }

        if timestamp < frames[0].frame.timestamp {
            return PIPDisplayResolution(
                videoInfo: entry.frameBeforeWindow?.videoInfo,
                needsFallbackQuery: false
            )
        }

        // Upper-bound binary search for the last frame with timestamp <= current timestamp.
        var low = 0
        var high = frames.count
        while low < high {
            let mid = (low + high) / 2
            if frames[mid].frame.timestamp <= timestamp {
                low = mid + 1
            } else {
                high = mid
            }
        }

        let resolvedIndex = max(0, low - 1)
        let resolvedVideoInfo = frames[resolvedIndex].videoInfo
        let isAtTail = resolvedIndex == frames.count - 1
        let needsFallbackQuery = isAtTail && entry.isTruncated && timestamp < cache.rangeEnd

        return PIPDisplayResolution(
            videoInfo: resolvedVideoInfo,
            needsFallbackQuery: needsFallbackQuery
        )
    }

    /// Fallback path: fetch nearest frame per display directly from the DB.
    private func fetchNearestVideoInfoForDisplays(
        _ displayIDs: [UInt32],
        before timestamp: Date
    ) async -> [UInt32: PIPDisplayResolution] {
        typealias SecondaryFetchResult = (displayID: UInt32, videoInfo: FrameVideoInfo?, errorDescription: String?)
        let coordinator = self.coordinator
        let fetchResults = await withTaskGroup(
            of: SecondaryFetchResult.self,
            returning: [UInt32: SecondaryFetchResult].self
        ) { group in
            for displayID in displayIDs {
                group.addTask { [coordinator] in
                    do {
                        let nearestFrame = try await coordinator.getNearestFrame(
                            displayID: displayID,
                            before: timestamp
                        )
                        return (displayID: displayID, videoInfo: nearestFrame?.videoInfo, errorDescription: nil)
                    } catch {
                        return (
                            displayID: displayID,
                            videoInfo: nil,
                            errorDescription: String(describing: error)
                        )
                    }
                }
            }

            var results: [UInt32: SecondaryFetchResult] = [:]
            for await result in group {
                results[result.displayID] = result
            }
            return results
        }

        var resolved: [UInt32: PIPDisplayResolution] = [:]
        for displayID in displayIDs {
            guard let result = fetchResults[displayID] else {
                resolved[displayID] = PIPDisplayResolution(videoInfo: nil, needsFallbackQuery: false)
                continue
            }

            if let errorDescription = result.errorDescription {
                Log.error(
                    "[MultiDisplay] Failed to get nearest frame for display \(displayID): \(errorDescription)",
                    category: .ui
                )
            }

            resolved[displayID] = PIPDisplayResolution(
                videoInfo: result.videoInfo,
                needsFallbackQuery: false
            )
        }

        return resolved
    }

    /// Clear PIP cache state (called when multi-display mode/window state changes).
    private func clearPIPDisplayFrameCache() {
        pipDisplayFrameCacheBuildTask?.cancel()
        pipDisplayFrameCacheBuildTask = nil
        pipDisplayFrameCacheBuildSignature = nil
        pipDisplayFrameCache = nil
    }

    /// Discover which displays are active in the loaded timeline range and auto-set primary.
    /// This is data-driven from stored frames and should not depend on current capture settings.
    func updateMultiDisplayState() async {
        guard let oldest = oldestLoadedTimestamp, let newest = newestLoadedTimestamp else {
            return
        }

        do {
            let displays = try await coordinator.getDistinctDisplaysWithNames(from: oldest, to: newest)
            let rawDisplayIDs = displays.map(\.displayID)
            let displayIDs = filterIdentifiableDisplayIDs(rawDisplayIDs, context: "updateMultiDisplayState")
            availableDisplayIDs = displayIDs
            persistedDisplayNames = Dictionary(
                uniqueKeysWithValues: displays.compactMap { entry in
                    guard displayIDs.contains(entry.displayID),
                          let name = entry.displayName,
                          !name.isEmpty else { return nil }
                    return (entry.displayID, name)
                }
            )

            if displayIDs.count <= 1 {
                isPrimaryDisplayPinned = false
                primaryDisplayVideoInfoOverride = nil
                secondaryDisplayFrames = []
                clearPIPDisplayFrameCache()
                if let onlyDisplay = displayIDs.first {
                    primaryDisplayID = onlyDisplay
                } else {
                    primaryDisplayID = 0
                }
                return
            }

            // If pinned display disappeared, drop pin and resume active display mode.
            if isPrimaryDisplayPinned && !displayIDs.contains(primaryDisplayID) {
                isPrimaryDisplayPinned = false
            }

            syncPrimaryDisplaySelection()
            await updateSecondaryDisplayFrames()
        } catch {
            Log.error("[MultiDisplay] Failed to update display state: \(error)", category: .ui)
        }
    }

    /// User-facing display label with stable ordinal ordering.
    public func displayLabel(for displayID: UInt32) -> String {
        if let namedLabel = resolvedDisplayName(for: displayID) {
            return namedLabel
        }
        if let persisted = persistedDisplayNames[displayID], !persisted.isEmpty {
            return persisted
        }

        let sortedDisplays = availableDisplayIDs.sorted()
        if let index = sortedDisplays.firstIndex(of: displayID) {
            return "Display \(index + 1)"
        }
        return "Display"
    }

    /// Resolve a display label from NSScreen metadata, disambiguating duplicate monitor names.
    private func resolvedDisplayName(for displayID: UInt32) -> String? {
        let namedDisplays: [(displayID: UInt32, name: String)] = availableDisplayIDs.compactMap { id in
            guard let name = systemDisplayName(for: id) else { return nil }
            return (displayID: id, name: name)
        }

        guard !namedDisplays.isEmpty else { return nil }

        let groupedByName = Dictionary(grouping: namedDisplays, by: { $0.name })
        guard let entry = namedDisplays.first(where: { $0.displayID == displayID }) else {
            return nil
        }

        guard let group = groupedByName[entry.name], group.count > 1 else {
            return entry.name
        }

        let sortedIDs = group.map(\.displayID).sorted()
        guard let duplicateIndex = sortedIDs.firstIndex(of: displayID) else {
            return entry.name
        }

        return "\(entry.name) \(duplicateIndex + 1)"
    }

    /// System-provided display name for a CGDirectDisplayID when available.
    private func systemDisplayName(for displayID: UInt32) -> String? {
        for screen in NSScreen.screens {
            guard
                let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                screenNumber.uint32Value == displayID
            else {
                continue
            }

            let trimmed = screen.localizedName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }

            // For built-in displays, prefer the user's computer name (e.g., "haseab's MacBook Pro")
            if CGDisplayIsBuiltin(CGDirectDisplayID(displayID)) != 0 {
                return computerDisplayName() ?? trimmed
            }

            return trimmed
        }

        return nil
    }

    /// User-assigned Mac name from system settings (used for the built-in display label).
    private func computerDisplayName() -> String? {
        guard
            let rawName = Host.current().localizedName?.trimmingCharacters(in: .whitespacesAndNewlines),
            !rawName.isEmpty
        else {
            return nil
        }
        return rawName
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

    /// Video info currently shown in the primary/fullscreen area.
    /// Uses pinned override when display is pinned; otherwise follows active timeline frame.
    public var displayedPrimaryVideoInfo: FrameVideoInfo? {
        if isPrimaryDisplayPinned, let override = primaryDisplayVideoInfoOverride {
            return override
        }
        return currentVideoInfo
    }

    /// Current timestamp - ALWAYS derived from the current frame
    public var currentTimestamp: Date? {
        currentTimelineFrame?.frame.timestamp
    }

    // MARK: - Computed Properties for Timeline Tape

    /// Cached app blocks - only recomputed when frames change
    private var _cachedAppBlocks: [AppBlock]?

    /// App blocks grouped by consecutive bundle IDs
    /// Note: Since we do server-side filtering, frames already contains only filtered results when filters are active
    public var appBlocks: [AppBlock] {
        if let cached = _cachedAppBlocks {
            return cached
        }

        let blocks = groupFramesIntoBlocks()
        _cachedAppBlocks = blocks

        return blocks
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

    // MARK: - Infinite Scroll Window State

    /// Timestamp of the oldest loaded frame (for loading older frames)
    private var oldestLoadedTimestamp: Date?

    /// Timestamp of the newest loaded frame (for loading newer frames)
    private var newestLoadedTimestamp: Date?

    /// Flag to prevent concurrent loads in the "older" direction
    private var isLoadingOlder = false

    /// Flag to prevent concurrent loads in the "newer" direction
    private var isLoadingNewer = false

    /// Flag to prevent duplicate initial frame loading (set synchronously to avoid race conditions)
    private var isInitialLoadInProgress = false

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

    /// Debounce task for PIP secondary display frame updates
    private var pipUpdateTask: Task<Void, Never>?

    /// In-memory carry-forward cache for secondary display PIP frames.
    private var pipDisplayFrameCache: PIPDisplayFrameCache?

    /// Cache build task (kept separate from scrub update task so it can complete).
    private var pipDisplayFrameCacheBuildTask: Task<Void, Never>?

    /// Signature currently being built for the PIP cache.
    private var pipDisplayFrameCacheBuildSignature: PIPDisplayCacheSignature?

    /// Coalesce rapid navigation into latest-only PIP refresh (no artificial delay).
    private func schedulePIPUpdate() {
        pipUpdateTask?.cancel()
        pipUpdateTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            await self?.updateSecondaryDisplayFrames()
        }
    }

    // MARK: - Dependencies

    private let coordinator: AppCoordinator

    // MARK: - Initialization

    public init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        self.lastKnownMultiDisplayEnabled = UserDefaults(suiteName: "io.retrace.app")?.bool(forKey: "recordAllDisplays") ?? false

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
        .sink { [weak self] combined, isCalendarVisible in
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
        let hadAppBlocks = _cachedAppBlocks != nil
        _cachedAppBlocks = nil
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

    /// Reload frames around a specific timestamp (used after data source changes)
    private func reloadFramesAroundTimestamp(_ timestamp: Date) async {
        Log.debug("[DataSourceChange] reloadFramesAroundTimestamp() starting for timestamp: \(timestamp)", category: .ui)
        isLoading = true
        clearError()

        do {
            let calendar = Calendar.current
            let startDate = calendar.date(byAdding: .minute, value: -10, to: timestamp) ?? timestamp
            let endDate = calendar.date(byAdding: .minute, value: 10, to: timestamp) ?? timestamp

            Log.debug("[DataSourceChange] Fetching frames from \(startDate) to \(endDate)", category: .ui)
            // Always pass filterCriteria to ensure hidden filter is applied (default: .hide)
            let timelinePayloads = try await coordinator.getTimelineFramesWithSecondaries(
                from: startDate,
                to: endDate,
                limit: 1000,
                filters: effectiveTimelineFilters
            )
            Log.debug("[DataSourceChange] Fetched \(timelinePayloads.count) timeline payloads from data adapter", category: .ui)
            let timelineFrames = await makeTimelineFrames(
                from: timelinePayloads,
                context: "reloadFramesAroundTimestamp"
            )

            if !timelineFrames.isEmpty {
                frames = timelineFrames

                // Find the frame closest to the original timestamp
                let closestIndex = findClosestFrameIndex(to: timestamp)
                currentIndex = closestIndex

                updateWindowBoundaries()
                hasMoreOlder = true
                hasMoreNewer = true

                loadImageIfNeeded()

                // Check if we need to pre-load more frames (near edge of loaded window)
                checkAndLoadMoreFrames()

                Log.info("[DataSourceChange] Reloaded \(frames.count) frames around \(timestamp)", category: .ui)
            } else {
                // No frames found, try loading most recent
                Log.info("[DataSourceChange] No frames found around timestamp, loading most recent", category: .ui)
                await loadMostRecentFrame()
                return
            }
        } catch {
            Log.error("[DataSourceChange] Failed to reload frames: \(error)", category: .ui)
            self.error = error.localizedDescription
        }

        isLoading = false
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

        // Clear cached blocks since frames changed
        _cachedAppBlocks = nil

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
        return appBlocks.first { index >= $0.startIndex && index <= $0.endIndex }
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

        // Clear cached blocks since frames changed
        _cachedAppBlocks = nil

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

    /// Hide all segments in the visible block at the current timeline context menu selection
    /// This hides all consecutive frames with the same bundleID as shown in the UI
    public func hideSelectedTimelineSegment() {
        guard let index = timelineContextMenuSegmentIndex,
              let block = getBlock(forFrameAt: index) else {
            dismissTimelineContextMenu()
            return
        }

        // Get all unique segment IDs in this visible block
        let segmentIds = getSegmentIds(inBlock: block)

        // Add all to hidden set immediately (optimistic UI update)
        for segmentId in segmentIds {
            hiddenSegmentIds.insert(segmentId)
        }

        let removeCount = block.frameCount
        let startIndex = block.startIndex

        // Remove all frames in the block from the array
        if block.endIndex < frames.count {
            frames.removeSubrange(block.startIndex...block.endIndex)
        }

        // Clear cached blocks since frames changed
        _cachedAppBlocks = nil

        // Adjust current index
        if currentIndex >= startIndex + removeCount {
            // Current was after deleted block
            currentIndex -= removeCount
        } else if currentIndex >= startIndex {
            // Current was within deleted block - move to start of where block was
            currentIndex = max(0, min(startIndex, frames.count - 1))
        }

        // Load image for new current frame
        loadImageIfNeeded()

        dismissTimelineContextMenu()

        Log.debug("[Tags] Hidden \(segmentIds.count) segments in block, removed \(removeCount) frames from UI", category: .ui)

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

    /// Add a tag to all segments in the visible block
    /// This affects all consecutive frames with the same bundleID as shown in the UI
    public func addTagToSelectedSegment(tag: Tag) {
        guard let index = timelineContextMenuSegmentIndex,
              let block = getBlock(forFrameAt: index) else {
            dismissTimelineContextMenu()
            return
        }

        // Get all unique segment IDs in this visible block
        let segmentIds = getSegmentIds(inBlock: block)

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

        // Get all unique segment IDs in this visible block
        let segmentIds = getSegmentIds(inBlock: block)

        let isCurrentlySelected = selectedSegmentTags.contains(tag.id)

        // Update UI immediately
        if isCurrentlySelected {
            selectedSegmentTags.remove(tag.id)
        } else {
            selectedSegmentTags.insert(tag.id)
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
                    } else {
                        selectedSegmentTags.remove(tag.id)
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
                }

                Log.debug("[Tags] Created tag '\(tagName)' and added to \(segmentIds.count) segments in block", category: .ui)
            } catch {
                Log.error("[Tags] Failed to create tag: \(error)", category: .ui)
            }
        }
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

    /// Check if a frame at a given index is in a hidden segment
    public func isFrameHidden(at index: Int) -> Bool {
        guard index >= 0 && index < frames.count else { return false }
        let segmentId = SegmentID(value: frames[index].frame.segmentID.value)
        return hiddenSegmentIds.contains(segmentId)
    }

    /// Group frames into app blocks (parameterized version for filtered frames)
    /// Splits on app change OR time gaps ≥2 min
    private func groupFramesIntoBlocks(from frameList: [TimelineFrame]) -> [AppBlock] {
        guard !frameList.isEmpty else { return [] }

        var blocks: [AppBlock] = []
        var currentBundleID: String? = frameList[0].frame.metadata.appBundleID
        var blockStartIndex = 0
        var gapBeforeCurrentBlock: TimeInterval? = nil

        for (index, timelineFrame) in frameList.enumerated() {
            let frameBundleID = timelineFrame.frame.metadata.appBundleID

            // Check for time gap between this frame and the previous one
            var gapDuration: TimeInterval = 0
            if index > 0 {
                let previousTimestamp = frameList[index - 1].frame.timestamp
                let currentTimestamp = timelineFrame.frame.timestamp
                gapDuration = currentTimestamp.timeIntervalSince(previousTimestamp)
            }

            let hasSignificantGap = gapDuration >= Self.minimumGapThreshold
            let appChanged = frameBundleID != currentBundleID

            // Start a new block if: app changed OR significant time gap
            if (appChanged || hasSignificantGap) && index > 0 {
                // Close previous block
                blocks.append(AppBlock(
                    bundleID: currentBundleID,
                    appName: frameList[blockStartIndex].frame.metadata.appName,
                    startIndex: blockStartIndex,
                    endIndex: index - 1,
                    frameCount: index - blockStartIndex,
                    gapBeforeSeconds: gapBeforeCurrentBlock
                ))

                // Start new block
                currentBundleID = frameBundleID
                blockStartIndex = index
                gapBeforeCurrentBlock = hasSignificantGap ? gapDuration : nil
            }
        }

        // Add final block
        blocks.append(AppBlock(
            bundleID: currentBundleID,
            appName: frameList[blockStartIndex].frame.metadata.appName,
            startIndex: blockStartIndex,
            endIndex: frameList.count - 1,
            frameCount: frameList.count - blockStartIndex,
            gapBeforeSeconds: gapBeforeCurrentBlock
        ))

        return blocks
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

    /// Apply pending filters
    public func applyFilters() {
        Log.debug("[Filter] applyFilters() called - pending.selectedApps=\(String(describing: pendingFilterCriteria.selectedApps)), current.selectedApps=\(String(describing: filterCriteria.selectedApps))", category: .ui)

        // Invalidate peek cache since filters are changing
        invalidatePeekCache()

        // Capture current timestamp before applying filters to preserve position
        let timestampToPreserve = currentTimestamp

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
                await reloadFramesAroundTimestamp(timestamp)
            } else {
                // No current position, fall back to most recent
                await loadMostRecentFrame()
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

        clearFilterState()

        // Reload timeline without filters, preserving current position
        Task {
            if let timestamp = timestampToPreserve {
                // Reload frames around the same timestamp (without filters)
                await reloadFramesAroundTimestamp(timestamp)
            } else {
                // No current position, fall back to most recent
                await loadMostRecentFrame()
            }
        }
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
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            if !Task.isCancelled {
                error = nil
            }
        }
    }

    /// Dismiss all dialogs except the specified one
    /// - Parameter except: The dialog type to keep open (nil to dismiss all)
    public func dismissOtherDialogs(except: DialogType? = nil) {
        // Dismiss filter panel
        if except != .filter && isFilterPanelVisible {
            pendingFilterCriteria = filterCriteria
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
        case filter      // Cmd+F - Filter panel
        case dateSearch  // Cmd+G - Date search
        case search      // Cmd+K - Search overlay
    }

    /// Dismiss filter panel (resets pending to match applied)
    public func dismissFilterPanel() {
        // Reset pending first - animation is handled by the View
        pendingFilterCriteria = filterCriteria
        isFilterPanelVisible = false
    }

    /// Open filter panel and load necessary data
    public func openFilterPanel() {
        // Dismiss other dialogs first
        dismissOtherDialogs(except: .filter)
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
            try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
            await loadFilterPanelDataBatched()
        }
    }

    /// Load all filter panel data in a single batch to minimize re-renders
    private func loadFilterPanelDataBatched() async {
        // Skip if already loaded
        let needsApps = availableAppsForFilter.isEmpty
        let needsTags = availableTags.isEmpty
        let needsHidden = hiddenSegmentIds.isEmpty
        let needsTagsMap = segmentTagsMap.isEmpty

        guard needsApps || needsTags || needsHidden || needsTagsMap else {
            return
        }

        // Collect all data first without updating @Published properties
        var newApps: [(bundleID: String, name: String)] = []
        var newOtherApps: [(bundleID: String, name: String)] = []
        var newTags: [Tag] = []
        var newHiddenSegmentIds: Set<SegmentID> = []
        var newSegmentTagsMap: [Int64: Set<Int64>] = [:]

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
            } catch {
                Log.error("[Filter] Failed to load tags: \(error)", category: .ui)
            }
        }

        // Load hidden segments
        if needsHidden {
            do {
                newHiddenSegmentIds = try await coordinator.getHiddenSegmentIds()
            } catch {
                Log.error("[Filter] Failed to load hidden segments: \(error)", category: .ui)
            }
        }

        // Load segment tags map
        if needsTagsMap {
            do {
                newSegmentTagsMap = try await coordinator.getSegmentTagsMap()
            } catch {
                Log.error("[Filter] Failed to load segment tags map: \(error)", category: .ui)
            }
        }

        // Now update all @Published properties in one batch
        if needsApps {
            availableAppsForFilter = newApps
            otherAppsForFilter = newOtherApps
        }
        if needsTags {
            availableTags = newTags
        }
        if needsHidden {
            hiddenSegmentIds = newHiddenSegmentIds
        }
        if needsTagsMap {
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

    /// Load the most recent frame on startup
    /// - Parameter clickStartTime: Optional start time from dashboard tab click for end-to-end timing
    public func loadMostRecentFrame(clickStartTime: CFAbsoluteTime? = nil) async {
        // Guard against concurrent calls (e.g., from both TimelineWindowController.prepareWindow and SimpleTimelineView.onAppear)
        // Use dedicated flag to avoid race conditions with @Published isLoading
        guard !isInitialLoadInProgress && !isLoading else {
            Log.debug("[SimpleTimelineViewModel] loadMostRecentFrame skipped - already loading", category: .ui)
            return
        }
        isInitialLoadInProgress = true
        defer { isInitialLoadInProgress = false }

        let startTime = clickStartTime ?? CFAbsoluteTimeGetCurrent()
        logTabClickTiming("VM_LOAD_START", startTime: startTime)

        isLoading = true
        clearError()

        do {
            // Load most recent frames
            // Uses optimized query that JOINs on video table - no N+1 queries!
            // Always pass filterCriteria to ensure hidden filter is applied (default: .hide)
            Log.debug("[SimpleTimelineViewModel] Loading frames with filters - hasActiveFilters: \(filterCriteria.hasActiveFilters), apps: \(String(describing: filterCriteria.selectedApps)), mode: \(filterCriteria.appFilterMode.rawValue)", category: .ui)
            logTabClickTiming("VM_BEFORE_QUERY", startTime: startTime)
            let timelinePayloads = try await coordinator.getMostRecentTimelineFramesWithSecondaries(
                limit: 500,
                filters: effectiveTimelineFilters
            )
            logTabClickTiming("VM_AFTER_QUERY (count=\(timelinePayloads.count))", startTime: startTime)
            let timelineFrames = await makeTimelineFrames(
                from: timelinePayloads,
                reverseOrder: true,
                context: "loadMostRecentFrame"
            )

            guard !timelineFrames.isEmpty else {
                // No frames found - check if filters are active
                if filterCriteria.hasActiveFilters {
                    showNoResultsMessage()
                } else {
                    showErrorWithAutoDismiss("No frames found in any database")
                }
                isLoading = false
                logTabClickTiming("VM_NO_FRAMES", startTime: startTime)
                return
            }

            // Convert to TimelineFrame - video info is already included from the JOIN
            // Reverse so oldest is first (index 0), newest is last
            // This matches the timeline UI which displays left-to-right as past-to-future
            frames = timelineFrames
            logTabClickTiming("VM_FRAMES_MAPPED", startTime: startTime)

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

            // Load image if needed for current frame
            loadImageIfNeeded()
            logTabClickTiming("VM_IMAGE_LOADED", startTime: startTime)

            // Discover multi-display state (non-blocking)
            Task { await updateMultiDisplayState() }

            isLoading = false
            logTabClickTiming("VM_LOAD_COMPLETE", startTime: startTime)

        } catch {
            self.error = "Failed to load frames: \(error.localizedDescription)"
            isLoading = false
            logTabClickTiming("VM_LOAD_ERROR: \(error.localizedDescription)", startTime: startTime)
        }
    }

    /// Load pre-fetched frames directly (used when query runs in parallel with show())
    /// - Parameters:
    ///   - timelinePayloads: Pre-fetched timeline payloads from a single query
    ///   - clickStartTime: Start time for end-to-end timing
    public func loadFramesDirectly(_ timelinePayloads: [TimelineFramePayload], clickStartTime: CFAbsoluteTime? = nil) async {
        // Guard against concurrent calls - use dedicated flag to avoid race conditions
        guard !isInitialLoadInProgress && !isLoading else {
            Log.debug("[SimpleTimelineViewModel] loadFramesDirectly skipped - already loading", category: .ui)
            return
        }
        isInitialLoadInProgress = true
        defer { isInitialLoadInProgress = false }

        let startTime = clickStartTime ?? CFAbsoluteTimeGetCurrent()
        logTabClickTiming("VM_LOAD_DIRECT_START", startTime: startTime)

        isLoading = true
        clearError()

        let timelineFrames = await makeTimelineFrames(
            from: timelinePayloads,
            reverseOrder: true,
            context: "loadFramesDirectly"
        )

        guard !timelineFrames.isEmpty else {
            if filterCriteria.hasActiveFilters {
                showNoResultsMessage()
            } else {
                showErrorWithAutoDismiss("No frames found in any database")
            }
            isLoading = false
            logTabClickTiming("VM_LOAD_DIRECT_NO_FRAMES", startTime: startTime)
            return
        }

        // Convert to TimelineFrame - reverse so oldest is first (index 0), newest is last
        frames = timelineFrames
        logTabClickTiming("VM_LOAD_DIRECT_MAPPED (count=\(frames.count))", startTime: startTime)

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

        // Load image if needed for current frame
        loadImageIfNeeded()
        logTabClickTiming("VM_LOAD_DIRECT_IMAGE", startTime: startTime)

        // Discover multi-display state (non-blocking)
        Task { await updateMultiDisplayState() }

        isLoading = false
        logTabClickTiming("VM_LOAD_DIRECT_COMPLETE", startTime: startTime)
    }

    // MARK: - Tab Click Timing

    private static let tabClickLogPath = URL(fileURLWithPath: "/tmp/retrace_debug.log")

    /// Log timing for tab click filter queries
    private func logTabClickTiming(_ checkpoint: String, startTime: CFAbsoluteTime) {
        let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        let filterInfo = filterCriteria.browserUrlFilter ?? filterCriteria.selectedApps?.first ?? "no-filter"
        let line = "[\(Log.timestamp())] [TAB_CLICK] \(checkpoint): \(String(format: "%.1f", elapsed))ms (filter: \(filterInfo))\n"

        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: Self.tabClickLogPath.path) {
                if let handle = try? FileHandle(forWritingTo: Self.tabClickLogPath) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                try? data.write(to: Self.tabClickLogPath)
            }
        }
    }

    /// Refresh frame data when showing the pre-rendered timeline
    /// This is a lightweight refresh that only loads the most recent frame if needed,
    /// rather than doing a full reload. The goal is to show fresh data quickly.
    /// - Parameter navigateToNewest: If true, automatically navigate to the newest frame when new frames are found.
    ///                               If false, preserve the current position (useful for background refresh).
    public func refreshFrameData(navigateToNewest: Bool = true) async {
        let refreshStartTime = CFAbsoluteTimeGetCurrent()
        Log.info("[TIMELINE-REFRESH] 🔄 refreshFrameData(navigateToNewest: \(navigateToNewest)) started", category: .ui)

        let currentMultiDisplayEnabled = isMultiDisplayEnabled
        if currentMultiDisplayEnabled != lastKnownMultiDisplayEnabled {
            Log.info(
                "[TIMELINE-REFRESH] 🔄 Multi-display setting changed (\(lastKnownMultiDisplayEnabled) -> \(currentMultiDisplayEnabled)); rebuilding timeline state",
                category: .ui
            )
            lastKnownMultiDisplayEnabled = currentMultiDisplayEnabled
            clearPIPDisplayFrameCache()
            availableDisplayIDs = []
            secondaryDisplayFrames = []
            primaryDisplayVideoInfoOverride = nil
            isPrimaryDisplayPinned = false
            await loadMostRecentFrame()
            return
        }

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
                    // Query for timeline payloads newer than our newest cached frame.
                    let newerPayloads = try await coordinator.getMostRecentTimelineFramesWithSecondaries(
                        limit: 50,
                        filters: effectiveTimelineFilters
                    )

                    // Filter to only truly new frames
                    let newPayloads = newerPayloads.filter { $0.frame.timestamp > newestCachedTimestamp }

                    if !newPayloads.isEmpty {
                        Log.info("[TIMELINE-REFRESH] 🔄 Found \(newPayloads.count) new frames since last view", category: .ui)

                        // Add new frames to the end (they're newer, so they go at the end)
                        let newTimelineFrames = await makeTimelineFrames(
                            from: newPayloads,
                            reverseOrder: true,
                            context: "refreshIfStale-newFrames"
                        )

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
                        Log.info("[TIMELINE-REFRESH] 🔄 No new frames found (all 50 queried frames already cached)", category: .ui)
                    }
                } catch {
                    Log.error("[TIMELINE-REFRESH] Failed to check for new frames: \(error)", category: .ui)
                }
            }

            // Load the current image
            Log.info("[TIMELINE-REFRESH] 🔄 Calling loadImageIfNeeded() for currentIndex=\(currentIndex)", category: .ui)
            loadImageIfNeeded()
            await updateMultiDisplayState()
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
        // Snapshot by frame ID to avoid stale index writes if `frames` is replaced while awaiting.
        let snapshotFrames = frames
        let snapshotByID = Dictionary(uniqueKeysWithValues: snapshotFrames.map { ($0.frame.id.value, $0) })

        guard !snapshotFrames.isEmpty else {
            Log.debug("[TIMELINE-REFRESH] No frames need status refresh (all completed)", category: .ui)
            return
        }

        let frameIDs = snapshotFrames.map { $0.frame.id.value }

        do {
            let updatedStatuses = try await coordinator.getFrameProcessingStatuses(frameIDs: frameIDs)

            var updatedCount = 0
            var currentFrameUpdated = false

            for frameID in frameIDs {
                guard let snapshotFrame = snapshotByID[frameID],
                      let newStatus = updatedStatuses[frameID],
                      newStatus != snapshotFrame.processingStatus else {
                    continue
                }

                // Resolve the current location by ID right before mutation (array may have changed).
                guard let currentIndex = frames.firstIndex(where: { $0.frame.id.value == frameID }) else {
                    continue
                }

                let currentEntry = frames[currentIndex]

                // Re-fetch the full frame with updated videoInfo
                if let updatedFrame = try await coordinator.getFrameWithVideoInfoByID(id: snapshotFrame.frame.id) {
                    // Re-fetch the full frame with updated videoInfo
                    frames[currentIndex] = TimelineFrame(
                        frame: updatedFrame.frame,
                        videoInfo: updatedFrame.videoInfo,
                        processingStatus: updatedFrame.processingStatus,
                        secondaryFrames: currentEntry.secondaryFrames
                    )
                } else {
                    // Still update the status even if we can't get fresh videoInfo.
                    frames[currentIndex] = TimelineFrame(
                        frame: currentEntry.frame,
                        videoInfo: currentEntry.videoInfo,
                        processingStatus: newStatus,
                        secondaryFrames: currentEntry.secondaryFrames
                    )
                }

                // Check if this is the current frame
                if let currentFrame = currentTimelineFrame,
                   currentFrame.frame.id.value == frameID {
                    currentFrameUpdated = true
                }
                updatedCount += 1
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

        // Clear selection when scrolling - highlight follows the playhead
        selectedFrameIndex = nil

        // Keep zoom level consistent across frames (don't reset on navigation)
        // User can reset with Cmd+0 if needed

        // Load image if this is an image-based frame
        loadImageIfNeeded()

        // Update PIP secondary display frames (latest-only coalescing during scrubbing).
        if !secondaryDisplayFrames.isEmpty || availableDisplayIDs.count > 1 {
            schedulePIPUpdate()
        }

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
            isLoading = true

            // Calculate ±10 minute window around target timestamp
            let calendar = Calendar.current
            let startDate = calendar.date(byAdding: .minute, value: -10, to: position.timestamp) ?? position.timestamp
            let endDate = calendar.date(byAdding: .minute, value: 10, to: position.timestamp) ?? position.timestamp

            Log.debug("[PlayheadUndo] Loading frames from \(startDate) to \(endDate)", category: .ui)

            // Fetch timeline payloads in the window with current filters applied.
            let timelinePayloads = try await coordinator.getTimelineFramesWithSecondaries(
                from: startDate,
                to: endDate,
                limit: 1000,
                filters: effectiveTimelineFilters
            )
            let timelineFrames = await makeTimelineFrames(from: timelinePayloads, context: "navigateToUndoPosition")

            guard !timelineFrames.isEmpty else {
                Log.warning("[PlayheadUndo] No frames found in time range", category: .ui)
                isLoading = false
                return
            }

            // Clear old image cache
            imageCache.removeAll()

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
            isLoading = false

            Log.info("[PlayheadUndo] Navigation complete, now at index \(currentIndex)", category: .ui)

        } catch {
            Log.error("[PlayheadUndo] Failed to navigate: \(error)", category: .ui)
            isLoading = false
        }
    }

    /// Navigate to a specific frame by ID and highlight the search query
    /// Used when selecting a search result
    public func navigateToSearchResult(frameID: FrameID, timestamp: Date, highlightQuery: String) async {
        // Exit live mode immediately - we're navigating to a specific historical frame
        if isInLiveMode {
            exitLiveMode()
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
            isLoading = true

            // Calculate ±10 minute window around target timestamp
            let calendar = Calendar.current
            let startDate = calendar.date(byAdding: .minute, value: -10, to: timestamp) ?? timestamp
            let endDate = calendar.date(byAdding: .minute, value: 10, to: timestamp) ?? timestamp

            Log.debug("[SearchNavigation] Query range: \(df.string(from: startDate)) to \(df.string(from: endDate))", category: .ui)

            // Fetch all timeline payloads in the 20-minute window (single optimized query).
            // Always pass filterCriteria to ensure hidden filter is applied (default: .hide)
            let timelinePayloads = try await coordinator.getTimelineFramesWithSecondaries(
                from: startDate,
                to: endDate,
                limit: 1000,
                filters: effectiveTimelineFilters
            )
            Log.debug("[SearchNavigation] Loaded \(timelinePayloads.count) timeline payloads in time range", category: .ui)
            let timelineFrames = await makeTimelineFrames(from: timelinePayloads, context: "navigateToSearchResult")

            guard !timelineFrames.isEmpty else {
                Log.warning("[SearchNavigation] No frames found in time range", category: .ui)
                isLoading = false
                return
            }

            // Clear old image cache since we're jumping to a new time window
            let oldCacheCount = imageCache.count
            imageCache.removeAll()
            if oldCacheCount > 0 {
                Log.debug("[SearchNavigation] Cleared image cache (\(oldCacheCount) images removed)", category: .ui)
            }

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
            isLoading = false
            Log.info("[SearchNavigation] Navigation complete, now at index \(currentIndex)", category: .ui)

        } catch {
            Log.error("[SearchNavigation] Failed to navigate to search result: \(error)", category: .ui)
            isLoading = false
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

    /// Trigger live OCR with a 1-second debounce
    /// Each call resets the timer - OCR only fires after 1 second of no new calls
    public func performLiveOCR() {
        // Clear stale OCR nodes from previous frame immediately
        // This prevents interaction with old bounding boxes while debounce waits
        setOCRNodes([])
        clearTextSelection()

        liveOCRDebounceTask?.cancel()
        liveOCRDebounceTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
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
            let ocr = VisionOCR()
            let textRegions = try await ocr.recognizeTextFromCGImage(cgImage)

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
                try? await Task.sleep(nanoseconds: 2_000_000_000)

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
        zoomDebugLog("startZoomRegion at \(point)")
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
        if zoomUpdateCount % 10 == 1 {
            zoomDebugLog("updateZoomRegion #\(zoomUpdateCount) to \(point)")
        }
        zoomRegionDragEnd = point
    }

    /// Finalize zoom region from drag - triggers animation to centered view
    /// Debug log to /tmp/retrace_debug.log for zoom animation investigation
    private func zoomDebugLog(_ message: String) {
        let timestamp = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let line = "[\(formatter.string(from: timestamp))] [ZOOM] \(message)\n"
        if let data = line.data(using: .utf8) {
            let path = "/tmp/retrace_debug.log"
            if FileManager.default.fileExists(atPath: path) {
                if let handle = FileHandle(forWritingAtPath: path) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                FileManager.default.createFile(atPath: path, contents: data)
            }
        }
    }

    public func endZoomRegion() {
        zoomDebugLog("endZoomRegion() called - mouseUp received")

        guard let start = zoomRegionDragStart, let end = zoomRegionDragEnd else {
            zoomDebugLog("endZoomRegion() - no start/end points, aborting")
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

        zoomDebugLog("endZoomRegion() - calculated rect: width=\(width), height=\(height)")

        // Only create zoom region if it's large enough (at least 5% of screen)
        guard width > 0.05 && height > 0.05 else {
            zoomDebugLog("endZoomRegion() - rect too small (<5%), aborting")
            isDraggingZoomRegion = false
            zoomRegionDragStart = nil
            zoomRegionDragEnd = nil
            return
        }

        let finalRect = CGRect(x: minX, y: minY, width: width, height: height)

        // DEBUG: Log the zoom region coordinates
        Log.info("[ZoomRegion] endZoomRegion: start=\(start), end=\(end)", category: .ui)
        Log.info("[ZoomRegion] endZoomRegion: finalRect=\(finalRect) (normalized coords, Y=0 at top)", category: .ui)
        zoomDebugLog("endZoomRegion() - finalRect=\(finalRect)")

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
        zoomDebugLog("endZoomRegion() - set zoomRegion and zoomTransitionStartRect")

        // Clear drag state
        isDraggingZoomRegion = false
        zoomRegionDragStart = nil
        zoomRegionDragEnd = nil

        // Start the transition animation
        isZoomTransitioning = true
        zoomTransitionProgress = 0
        zoomTransitionBlurOpacity = 0
        zoomDebugLog("endZoomRegion() - starting transition animation (isZoomTransitioning=true)")

        // Animate to final state
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            zoomTransitionProgress = 1.0
            zoomTransitionBlurOpacity = 1.0
        }
        zoomDebugLog("endZoomRegion() - withAnimation started (progress -> 1.0)")

        // After animation completes, switch to final zoom state
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            self?.zoomDebugLog("endZoomRegion() - 0.45s timer fired, setting isZoomRegionActive=true")
            self?.isZoomRegionActive = true
            self?.zoomTransitionStartRect = nil
            // Disable transition on next run loop to ensure smooth handoff
            DispatchQueue.main.async {
                self?.zoomDebugLog("endZoomRegion() - final state: isZoomTransitioning=false")
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

        zoomDebugLog("exitZoomRegion() - starting exit animation")

        // Clear text selection highlight before starting animation
        clearTextSelection()

        // Start exit transition
        isZoomExitTransitioning = true
        isZoomRegionActive = false

        // After animation completes, clear all zoom state
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.zoomDebugLog("exitZoomRegion() - animation complete, clearing state")
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
        guard let region = zoomRegion, isZoomRegionActive else { return }

        // Get the current frame image (either from cache or from video)
        getCurrentFrameImage { image in
            guard let image = image else { return }

            let imageSize = image.size

            // Calculate crop rect based on zoom region (normalized 0-1 coordinates)
            // Both zoom region and CGImage use Y=0 at top, so no flip needed
            let cropRect = CGRect(
                x: region.origin.x * imageSize.width,
                y: region.origin.y * imageSize.height,
                width: region.width * imageSize.width,
                height: region.height * imageSize.height
            )

            guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
                  let croppedCGImage = cgImage.cropping(to: cropRect) else { return }

            let croppedImage = NSImage(cgImage: croppedCGImage, size: NSSize(width: croppedCGImage.width, height: croppedCGImage.height))

            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([croppedImage])
        }
    }

    /// Get the current frame as an image (handles both static images and video frames)
    private func getCurrentFrameImage(completion: @escaping (NSImage?) -> Void) {
        // Try static image first
        if let image = currentImage {
            completion(image)
            return
        }

        // Fall back to extracting from video
        guard let videoInfo = currentVideoInfo else {
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
                        Log.debug("[Scroll] Hit boundary: target=\(targetIndex) clamped=\(clampedTarget) offset=\(String(format: "%.1f", subFrameOffset)) delta=\(String(format: "%.1f", delta))", category: .ui)
                        subFrameOffset = 0
                    }
                }
            }

            // Safety clamp: prevent any residual offset past boundaries
            if currentIndex == 0 && subFrameOffset < 0 {
                Log.debug("[Scroll] Safety clamp at start: offset was \(String(format: "%.1f", subFrameOffset))", category: .ui)
                subFrameOffset = 0
            } else if currentIndex >= frames.count - 1 && subFrameOffset > 0 {
                Log.debug("[Scroll] Safety clamp at end: offset was \(String(format: "%.1f", subFrameOffset))", category: .ui)
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
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
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

                    try? await Task.sleep(nanoseconds: tickInterval)
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

    /// Whether to show the "Go to Now" button
    /// Shows when not viewing the most recent available frame
    public var shouldShowGoToNow: Bool {
        guard !frames.isEmpty else { return false }
        // Show if not at the end of loaded frames, or if there are newer frames to load
        return currentIndex < frames.count - 1 || hasMoreNewer
    }

    /// Navigate to the most recent frame — jumps to end of tape if already loaded, otherwise reloads from DB
    public func goToNow() {
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
            }
        } catch {
            Log.error("Failed to load hours for date: \(error)", category: .ui)
        }
    }

    /// Navigate to a specific hour from the calendar picker
    public func navigateToHour(_ hour: Date) async {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            isCalendarPickerVisible = false
            isDateSearchActive = false
        }
        await navigateToDate(hour)
    }

    /// Navigate to a specific date (start of day or specific time)
    private func navigateToDate(_ targetDate: Date) async {
        isLoading = true
        clearError()

        do {
            let calendar = Calendar.current
            let startDate = calendar.date(byAdding: .minute, value: -10, to: targetDate) ?? targetDate
            let endDate = calendar.date(byAdding: .minute, value: 10, to: targetDate) ?? targetDate

            // Always pass filterCriteria to ensure hidden filter is applied (default: .hide)
            let timelinePayloads = try await coordinator.getTimelineFramesWithSecondaries(
                from: startDate,
                to: endDate,
                limit: 1000,
                filters: effectiveTimelineFilters
            )
            let timelineFrames = await makeTimelineFrames(from: timelinePayloads, context: "navigateToDate")

            guard !timelineFrames.isEmpty else {
                showErrorWithAutoDismiss("No frames found around \(targetDate)")
                isLoading = false
                return
            }

            // Clear old image cache
            let oldCacheCount = imageCache.count
            imageCache.removeAll()
            if oldCacheCount > 0 {
                Log.info("[Memory] Cleared image cache on calendar navigation (\(oldCacheCount) images removed)", category: .ui)
            }

            frames = timelineFrames

            updateWindowBoundaries()
            hasMoreOlder = true
            hasMoreNewer = true

            let closestIndex = findClosestFrameIndex(to: targetDate)
            currentIndex = closestIndex

            loadImageIfNeeded()
            isLoading = false
        } catch {
            self.error = "Failed to navigate: \(error.localizedDescription)"
            isLoading = false
        }
    }

    /// Search for frames around a natural language date string, or by frame ID if enabled
    public func searchForDate(_ searchText: String) async {
        guard !searchText.isEmpty else { return }

        isLoading = true
        clearError()

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

            // Parse natural language date
            guard let targetDate = parseNaturalLanguageDate(searchText) else {
                error = "Could not understand: \(searchText)"
                isLoading = false
                return
            }

            // Load frames around the target date (±10 minutes window)
            let calendar = Calendar.current
            let startDate = calendar.date(byAdding: .minute, value: -10, to: targetDate) ?? targetDate
            let endDate = calendar.date(byAdding: .minute, value: 10, to: targetDate) ?? targetDate

            // Debug logging
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
            df.timeZone = .current
            Log.debug("[DateSearch] Input: '\(searchText)'", category: .ui)
            Log.debug("[DateSearch] Parsed targetDate (local): \(df.string(from: targetDate))", category: .ui)
            df.timeZone = TimeZone(identifier: "UTC")
            Log.debug("[DateSearch] Parsed targetDate (UTC): \(df.string(from: targetDate))", category: .ui)
            df.timeZone = .current
            Log.debug("[DateSearch] Query range: \(df.string(from: startDate)) to \(df.string(from: endDate))", category: .ui)

            // Fetch all timeline payloads in the 20-minute window.
            // Always pass filterCriteria to ensure hidden filter is applied (default: .hide)
            let timelinePayloads = try await coordinator.getTimelineFramesWithSecondaries(
                from: startDate,
                to: endDate,
                limit: 1000,
                filters: effectiveTimelineFilters
            )
            Log.debug("[DateSearch] Got \(timelinePayloads.count) timeline payloads", category: .ui)
            let timelineFrames = await makeTimelineFrames(from: timelinePayloads, context: "searchForDate")

            guard !timelineFrames.isEmpty else {
                showErrorWithAutoDismiss("No frames found around \(targetDate)")
                isLoading = false
                return
            }

            // Clear old image cache since we're jumping to a new time window
            let oldCacheCount = imageCache.count
            imageCache.removeAll()
            if oldCacheCount > 0 {
                Log.info("[Memory] Cleared image cache on date search (\(oldCacheCount) images removed)", category: .ui)
            }

            // Convert to TimelineFrame - video info is already included from the JOIN
            frames = timelineFrames

            // Reset infinite scroll state for new window
            updateWindowBoundaries()
            hasMoreOlder = true
            hasMoreNewer = true

            // Find the frame closest to the target date in our centered set
            let closestIndex = findClosestFrameIndex(to: targetDate)
            currentIndex = closestIndex

            // Load image if needed
            loadImageIfNeeded()

            // Check if we need to pre-load more frames (near edge of loaded window)
            checkAndLoadMoreFrames()

            // Log memory state after date search
            MemoryTracker.logMemoryState(
                context: "DATE SEARCH COMPLETE",
                frameCount: frames.count,
                imageCacheCount: imageCache.count,
                oldestTimestamp: oldestLoadedTimestamp,
                newestTimestamp: newestLoadedTimestamp
            )

            isLoading = false
            closeDateSearch()

        } catch {
            self.error = "Failed to search for date: \(error.localizedDescription)"
            isLoading = false
        }
    }

    /// Search for a frame by its ID and navigate to it
    /// Returns true if frame was found and navigation succeeded
    private func searchForFrameID(_ frameID: Int64) async -> Bool {
        Log.debug("[FrameIDSearch] Looking for frame ID: \(frameID)", category: .ui)

        do {
            // Try to get the frame by ID
            guard let frameWithVideo = try await coordinator.getFrameWithVideoInfoByID(id: FrameID(value: frameID)) else {
                Log.debug("[FrameIDSearch] Frame not found: \(frameID)", category: .ui)
                error = "Frame #\(frameID) not found"
                isLoading = false
                return false
            }

            let targetFrame = frameWithVideo.frame
            let targetDate = targetFrame.timestamp
            Log.debug("[FrameIDSearch] Found frame \(frameID) at \(targetDate)", category: .ui)

            // Load frames around the target frame's timestamp (±10 minutes window)
            let calendar = Calendar.current
            let startDate = calendar.date(byAdding: .minute, value: -10, to: targetDate) ?? targetDate
            let endDate = calendar.date(byAdding: .minute, value: 10, to: targetDate) ?? targetDate

            // Fetch all timeline payloads in the window.
            // Always pass filterCriteria to ensure hidden filter is applied (default: .hide)
            let timelinePayloads = try await coordinator.getTimelineFramesWithSecondaries(
                from: startDate,
                to: endDate,
                limit: 1000,
                filters: effectiveTimelineFilters
            )
            Log.debug("[FrameIDSearch] Got \(timelinePayloads.count) timeline payloads in window", category: .ui)
            let timelineFrames = await makeTimelineFrames(from: timelinePayloads, context: "searchForFrameID")

            guard !timelineFrames.isEmpty else {
                showErrorWithAutoDismiss("No frames found around frame #\(frameID)")
                isLoading = false
                return false
            }

            // Clear old image cache since we're jumping to a new time window
            let oldCacheCount = imageCache.count
            imageCache.removeAll()
            if oldCacheCount > 0 {
                Log.info("[Memory] Cleared image cache on frame ID search (\(oldCacheCount) images removed)", category: .ui)
            }

            // Convert to TimelineFrame
            frames = timelineFrames

            // Reset infinite scroll state for new window
            updateWindowBoundaries()
            hasMoreOlder = true
            hasMoreNewer = true

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

            // Check if we need to pre-load more frames (near edge of loaded window)
            checkAndLoadMoreFrames()

            // Log memory state after frame ID search
            MemoryTracker.logMemoryState(
                context: "FRAME ID SEARCH COMPLETE",
                frameCount: frames.count,
                imageCacheCount: imageCache.count,
                oldestTimestamp: oldestLoadedTimestamp,
                newestTimestamp: newestLoadedTimestamp
            )

            isLoading = false
            closeDateSearch()

            return true

        } catch {
            Log.error("[FrameIDSearch] Error: \(error)", category: .ui)
            // Don't set error here - let date search try as fallback
            return false
        }
    }

    /// Parse natural language date strings
    private func parseNaturalLanguageDate(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let calendar = Calendar.current
        let now = Date()

        // === RELATIVE DATES ===

        if trimmed == "now" || trimmed == "today" {
            return now
        }
        if trimmed == "yesterday" {
            if let targetDate = calendar.date(byAdding: .day, value: -1, to: now) {
                return calendar.startOfDay(for: targetDate)
            }
            return nil
        }
        if trimmed == "last week" {
            if let targetDate = calendar.date(byAdding: .day, value: -7, to: now) {
                return calendar.startOfDay(for: targetDate)
            }
            return nil
        }
        if trimmed == "last month" {
            if let targetDate = calendar.date(byAdding: .month, value: -1, to: now) {
                return calendar.startOfDay(for: targetDate)
            }
            return nil
        }

        // "X hours ago", "X hour ago", "an hour ago"
        // Returns the START of that hour (e.g., "2 hours ago" at 3:45pm returns 1:00pm)
        if trimmed.contains("hour") {
            let hours = extractNumber(from: trimmed) ?? 1
            if let targetTime = calendar.date(byAdding: .hour, value: -hours, to: now) {
                // Return start of that hour
                return calendar.date(bySetting: .minute, value: 0, of: targetTime).flatMap {
                    calendar.date(bySetting: .second, value: 0, of: $0)
                }
            }
            return nil
        }

        // "X minutes ago", "X min ago", "30 min ago"
        if trimmed.contains("minute") || trimmed.contains("min") {
            if let minutes = extractNumber(from: trimmed) {
                return calendar.date(byAdding: .minute, value: -minutes, to: now)
            }
            return calendar.date(byAdding: .minute, value: -1, to: now)
        }

        // "X days ago"
        // Returns the START of that day (midnight)
        if trimmed.contains("day") && trimmed.contains("ago") {
            if let days = extractNumber(from: trimmed) {
                if let targetDate = calendar.date(byAdding: .day, value: -days, to: now) {
                    // Return start of that day (midnight)
                    return calendar.startOfDay(for: targetDate)
                }
            }
            return nil
        }

        // "X weeks ago"
        // Returns the START of that day (midnight)
        if trimmed.contains("week") {
            let weeks = extractNumber(from: trimmed) ?? 1
            if let targetDate = calendar.date(byAdding: .day, value: -weeks * 7, to: now) {
                // Return start of that day (midnight)
                return calendar.startOfDay(for: targetDate)
            }
            return nil
        }

        // === ABSOLUTE DATES ===

        // Try parsing time-only input (assumes "today" if just time is given)
        // Handles: "938pm", "9:38pm", "938 pm", "9:38 pm", "938", "9:38", "21:38"
        if let timeOnlyDate = parseTimeOnly(trimmed, relativeTo: now) {
            return timeOnlyDate
        }

        // Normalize compact time formats (e.g., "827am" -> "8:27am") before passing to NSDataDetector
        // This allows "827am yesterday" to work the same as "8:27am yesterday"
        let normalizedText = normalizeCompactTimeFormat(trimmed)

        // Try macOS's built-in natural language date parser (handles "dec 15 3pm", "tomorrow at 5", etc.)
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
        if let detector = detector {
            let range = NSRange(normalizedText.startIndex..., in: normalizedText)
            if let match = detector.firstMatch(in: normalizedText, options: [], range: range),
               let date = match.date {
                return date
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
                return date
            }
            // Try lowercased
            if let date = df.date(from: trimmed) {
                return date
            }
            // Try with first letter capitalized (for month names)
            let capitalized = trimmed.prefix(1).uppercased() + trimmed.dropFirst()
            if let date = df.date(from: capitalized) {
                return date
            }
        }

        return nil
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

    /// Parse time-only input and return a Date for today at that time
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
    private static let minimumGapThreshold: TimeInterval = 120

    /// Group consecutive frames into blocks, splitting on app change OR time gaps ≥2 min
    private func groupFramesIntoBlocks() -> [AppBlock] {
        guard !frames.isEmpty else { return [] }

        var blocks: [AppBlock] = []
        var currentBundleID: String? = frames[0].frame.metadata.appBundleID
        var blockStartIndex = 0
        var gapBeforeCurrentBlock: TimeInterval? = nil

        for (index, timelineFrame) in frames.enumerated() {
            let frameBundleID = timelineFrame.frame.metadata.appBundleID

            // Check for time gap between this frame and the previous one
            var gapDuration: TimeInterval = 0
            if index > 0 {
                let previousTimestamp = frames[index - 1].frame.timestamp
                let currentTimestamp = timelineFrame.frame.timestamp
                gapDuration = currentTimestamp.timeIntervalSince(previousTimestamp)
            }

            let hasSignificantGap = gapDuration >= Self.minimumGapThreshold
            let appChanged = frameBundleID != currentBundleID

            // Start a new block if: app changed OR significant time gap
            if (appChanged || hasSignificantGap) && index > 0 {
                // Close previous block
                blocks.append(AppBlock(
                    bundleID: currentBundleID,
                    appName: frames[blockStartIndex].frame.metadata.appName,
                    startIndex: blockStartIndex,
                    endIndex: index - 1,
                    frameCount: index - blockStartIndex,
                    gapBeforeSeconds: gapBeforeCurrentBlock
                ))

                // Start new block
                currentBundleID = frameBundleID
                blockStartIndex = index
                gapBeforeCurrentBlock = hasSignificantGap ? gapDuration : nil
            }
        }

        // Add final block
        blocks.append(AppBlock(
            bundleID: currentBundleID,
            appName: frames[blockStartIndex].frame.metadata.appName,
            startIndex: blockStartIndex,
            endIndex: frames.count - 1,
            frameCount: frames.count - blockStartIndex,
            gapBeforeSeconds: gapBeforeCurrentBlock
        ))

        return blocks
    }

    // MARK: - Infinite Scroll

    /// Update window boundary timestamps from current frames
    private func updateWindowBoundaries() {
        let previousOldest = oldestLoadedTimestamp
        let previousNewest = newestLoadedTimestamp

        oldestLoadedTimestamp = frames.first?.frame.timestamp
        newestLoadedTimestamp = frames.last?.frame.timestamp

        if previousOldest != oldestLoadedTimestamp || previousNewest != newestLoadedTimestamp {
            clearPIPDisplayFrameCache()
        }

        if let oldest = oldestLoadedTimestamp, let newest = newestLoadedTimestamp {
            Log.debug("[InfiniteScroll] Window boundaries: \(oldest) to \(newest)", category: .ui)
        }
    }

    /// Check if we need to load more frames based on current position
    private func checkAndLoadMoreFrames() {
        // Check if approaching the older end (left side of timeline)
        if currentIndex < WindowConfig.loadThreshold && hasMoreOlder && !isLoadingOlder {
            Task {
                await loadOlderFrames()
            }
        }

        // Check if approaching the newer end (right side of timeline)
        if currentIndex > frames.count - WindowConfig.loadThreshold && hasMoreNewer && !isLoadingNewer {
            Task {
                await loadNewerFrames()
            }
        }
    }

    /// Load older frames (before the oldest loaded timestamp)
    private func loadOlderFrames() async {
        guard let oldestTimestamp = oldestLoadedTimestamp else { return }
        guard !isLoadingOlder else { return }

        isLoadingOlder = true
        Log.debug("[InfiniteScroll] Loading older frames before \(oldestTimestamp)...", category: .ui)

        do {
            var cursorTimestamp = oldestTimestamp
            var newTimelineFrames: [TimelineFrame] = []
            var skippedUnknownOnlyBatches = 0

            while newTimelineFrames.isEmpty {
                // Query timeline payloads before the cursor timestamp.
                // Always pass filterCriteria to ensure hidden filter is applied (default: .hide)
                let timelinePayloads = try await coordinator.getTimelineFramesWithSecondariesBefore(
                    timestamp: cursorTimestamp,
                    limit: WindowConfig.loadBatchSize,
                    filters: effectiveTimelineFilters
                )

                guard !timelinePayloads.isEmpty else {
                    Log.debug("[InfiniteScroll] No more older frames available - reached absolute start", category: .ui)
                    hasMoreOlder = false
                    hasReachedAbsoluteStart = true  // Mark that we've hit the absolute start
                    isLoadingOlder = false
                    return
                }

                Log.debug("[InfiniteScroll] Got \(timelinePayloads.count) older timeline payloads", category: .ui)

                // Payloads are returned DESC (newest first), reverse to get ASC (oldest first).
                newTimelineFrames = await makeTimelineFrames(
                    from: timelinePayloads,
                    reverseOrder: true,
                    context: "loadOlderFrames"
                )

                if newTimelineFrames.isEmpty {
                    skippedUnknownOnlyBatches += 1
                    guard skippedUnknownOnlyBatches <= 5 else {
                        Log.warning("[InfiniteScroll] Stopped loading older frames after skipping 5 unknown-only batches", category: .ui)
                        hasMoreOlder = false
                        isLoadingOlder = false
                        return
                    }

                    guard let oldestRawFrame = timelinePayloads.last?.frame.timestamp,
                          oldestRawFrame < cursorTimestamp else {
                        Log.warning("[InfiniteScroll] Could not advance older-frame cursor while skipping unknown-display frames", category: .ui)
                        hasMoreOlder = false
                        isLoadingOlder = false
                        return
                    }

                    cursorTimestamp = oldestRawFrame
                    Log.debug(
                        "[InfiniteScroll] Skipping unknown-display-only older batch (\(skippedUnknownOnlyBatches)); advancing cursor to \(cursorTimestamp)",
                        category: .ui
                    )
                }
            }

            // Prepend to existing frames
            // Use insert(contentsOf:) to avoid unnecessary @Published triggers
            let beforeCount = frames.count
            frames.insert(contentsOf: newTimelineFrames, at: 0)

            // Adjust currentIndex to maintain position
            currentIndex += newTimelineFrames.count

            Log.info("[Memory] LOADED OLDER: +\(newTimelineFrames.count) frames (\(beforeCount)→\(frames.count)), index adjusted to \(currentIndex)", category: .ui)
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

        } catch {
            Log.error("[InfiniteScroll] Error loading older frames: \(error)", category: .ui)
            isLoadingOlder = false
        }
    }

    /// Load newer frames (after the newest loaded timestamp)
    private func loadNewerFrames() async {
        guard let newestTimestamp = newestLoadedTimestamp else { return }
        guard !isLoadingNewer else { return }

        isLoadingNewer = true
        Log.debug("[InfiniteScroll] Loading newer frames after \(newestTimestamp)...", category: .ui)

        do {
            var cursorTimestamp = newestTimestamp
            var newTimelineFrames: [TimelineFrame] = []
            var skippedUnknownOnlyBatches = 0

            while newTimelineFrames.isEmpty {
                // Query timeline payloads after the cursor timestamp.
                // Always pass filterCriteria to ensure hidden filter is applied (default: .hide)
                let timelinePayloads = try await coordinator.getTimelineFramesWithSecondariesAfter(
                    timestamp: cursorTimestamp,
                    limit: WindowConfig.loadBatchSize,
                    filters: effectiveTimelineFilters
                )

                guard !timelinePayloads.isEmpty else {
                    Log.debug("[InfiniteScroll] No more newer frames available - reached absolute end", category: .ui)
                    hasMoreNewer = false
                    hasReachedAbsoluteEnd = true  // Mark that we've hit the absolute end
                    isLoadingNewer = false
                    return
                }

                Log.debug("[InfiniteScroll] Got \(timelinePayloads.count) newer timeline payloads", category: .ui)

                // Payloads are returned ASC (oldest first), which is correct for appending.
                newTimelineFrames = await makeTimelineFrames(from: timelinePayloads, context: "loadNewerFrames")

                if newTimelineFrames.isEmpty {
                    skippedUnknownOnlyBatches += 1
                    guard skippedUnknownOnlyBatches <= 5 else {
                        Log.warning("[InfiniteScroll] Stopped loading newer frames after skipping 5 unknown-only batches", category: .ui)
                        hasMoreNewer = false
                        isLoadingNewer = false
                        return
                    }

                    guard let newestRawFrame = timelinePayloads.last?.frame.timestamp,
                          newestRawFrame > cursorTimestamp else {
                        Log.warning("[InfiniteScroll] Could not advance newer-frame cursor while skipping unknown-display frames", category: .ui)
                        hasMoreNewer = false
                        isLoadingNewer = false
                        return
                    }

                    cursorTimestamp = newestRawFrame
                    Log.debug(
                        "[InfiniteScroll] Skipping unknown-display-only newer batch (\(skippedUnknownOnlyBatches)); advancing cursor to \(cursorTimestamp)",
                        category: .ui
                    )
                }
            }

            // Append to existing frames
            // Use append(contentsOf:) to avoid unnecessary @Published triggers
            let beforeCount = frames.count
            frames.append(contentsOf: newTimelineFrames)

            Log.info("[Memory] LOADED NEWER: +\(newTimelineFrames.count) frames (\(beforeCount)→\(frames.count))", category: .ui)
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

        } catch {
            Log.error("[InfiniteScroll] Error loading newer frames: \(error)", category: .ui)
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
