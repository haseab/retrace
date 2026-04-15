import SwiftUI
import Combine
import AVFoundation
import AppKit
import Shared
import App
import Database
import Processing
import UniformTypeIdentifiers
import ImageIO

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

/// Simple ViewModel for the redesigned fullscreen timeline view
/// All state derives from currentIndex - this is the SINGLE source of truth
@MainActor
public class SimpleTimelineViewModel: ObservableObject {

    // MARK: - Private Properties

    /// Cancellables for Combine subscriptions
    var cancellables = Set<AnyCancellable>()

    /// Timestamp formatter used by comment helper actions.
    static let commentTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()

    static let pendingDeleteCompensatedFetchLimitCap = 2_000

    nonisolated private static let inPageURLCollectionExperimentalKey = "collectInPageURLsExperimental"
    nonisolated private static let captureMousePositionKey = "captureMousePosition"

    static func isInPageURLCollectionEnabled() -> Bool {
        let defaults = UserDefaults(suiteName: "io.retrace.app") ?? .standard
        guard defaults.object(forKey: inPageURLCollectionExperimentalKey) != nil else {
            return false
        }
        return defaults.bool(forKey: inPageURLCollectionExperimentalKey)
    }

    static func isMousePositionCaptureEnabled() -> Bool {
        let defaults = UserDefaults(suiteName: "io.retrace.app") ?? .standard
        guard defaults.object(forKey: captureMousePositionKey) != nil else {
            return true
        }
        return defaults.bool(forKey: captureMousePositionKey)
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

            let pendingPreferredIndex = frameWindowStore.consumePendingCurrentIndexAfterFrameReplacement()

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

            applyAppBlockSnapshotUpdate(.invalidate, reason: .framesDidSet)

            let isPureAppend = didChangeIdentity && Self.isPureAppend(oldFrames: oldValue, newFrames: frames)
            let isPurePrepend = didChangeIdentity && Self.isPurePrepend(oldFrames: oldValue, newFrames: frames)
            let isWindowReplacement = didChangeIdentity && !isPureAppend && !isPurePrepend

            if isWindowReplacement {
                applyAppBlockSnapshotUpdate(.refreshImmediately, reason: .framesDidSetWindowReplaced)
            } else if isPurePrepend {
                // Keep tape geometry in sync during boundary loads to avoid stale-viewport jumps.
                applyAppBlockSnapshotUpdate(.refreshImmediately, reason: .framesDidSetPrepended)
            } else if isPureAppend {
                applyAppBlockSnapshotUpdate(.refreshImmediately, reason: .framesDidSetAppended)
            }
        }
    }

    /// Current index in the frames array - THE SINGLE SOURCE OF TRUTH
    /// Everything else (currentFrame, currentVideoInfo, currentTimestamp) derives from this
    @Published public var currentIndex: Int = 0 {
        didSet {
            if currentIndex != oldValue {
                endInPageURLHoverTracking()
                cancelPresentationOverlayTasks()
                clearCurrentFrameOverlayPresentation()
                if Self.isVerboseTimelineLoggingEnabled {
                    Log.debug("[SimpleTimelineViewModel] currentIndex changed: \(oldValue) -> \(currentIndex)", category: .ui)
                    if let frame = currentTimelineFrame {
                        Log.debug("[SimpleTimelineViewModel] New frame: timestamp=\(frame.frame.timestamp), frameIndex=\(frame.videoInfo?.frameIndex ?? -1)", category: .ui)
                    }
                }

                let previousTimelineFrame: TimelineFrame?
                if oldValue >= 0 && oldValue < frames.count {
                    previousTimelineFrame = frames[oldValue]
                } else {
                    previousTimelineFrame = nil
                }

                // CRITICAL: Clear previous frame state IMMEDIATELY to prevent old frame from showing.
                // Preserve the last visible frame only as a temporary overlay while video catches up.
                prepareCurrentFramePresentationState(
                    for: currentTimelineFrame,
                    previousTimelineFrame: previousTimelineFrame
                )

                // Pre-check if frame will have loading issues (synchronous check)
                // This prevents showing a fallback frame before the async error is detected
                if let timelineFrame = currentTimelineFrame {
                    if timelineFrame.processingStatus == 4 {
                        // Frame not yet readable
                        setFramePresentationState(isNotReady: true, hasLoadError: false)
                    } else {
                        // Reset states - actual load will set them if needed
                        setFramePresentationState(isNotReady: false, hasLoadError: false)
                    }
                }

                frameWindowStore.updateDeferredTrimAnchorIfNeeded(
                    isActivelyScrolling: isActivelyScrolling,
                    currentFrame: currentTimelineFrame
                )
            }
        }
    }

    @Published var mediaPresentationState = TimelineMediaPresentationState()
    @Published var overlayPresentationState = TimelineOverlayPresentationState()
    @Published var viewportUIState = TimelineViewportUIState()
    @Published var selectionUIState = TimelineSelectionUIState()
    @Published var zoomInteractionUIState = TimelineZoomInteractionUIState()
    @Published var dateSearchUIState = TimelineDateSearchUIState()
    @Published var chromeUIState = TimelineChromeUIState()
    @Published var shellUIState = TimelineShellUIState()

    /// Whether the user is actively scrolling (disables tape animation during rapid scrolling)
    public var isActivelyScrolling: Bool {
        get { viewportUIState.isActivelyScrolling }
        set { setActivelyScrolling(newValue) }
    }

    private func setActivelyScrolling(_ isScrolling: Bool) {
        let previousValue = viewportUIState.isActivelyScrolling
        guard previousValue != isScrolling else { return }

        viewportUIState.isActivelyScrolling = isScrolling

        let coordinator = self.coordinator
        Task(priority: .utility) {
            await coordinator.setTimelineScrubbing(isScrolling)
        }

        // Apply deferred rolling-window trims only after scrub interaction settles.
        guard previousValue, !isScrolling else { return }
        if let trimOutcome = frameWindowStore.handleDeferredTrimIfNeeded(
            trigger: "scroll-ended",
            frames: frames,
            currentIndex: currentIndex,
            maxFrames: WindowConfig.maxFrames,
            currentFrame: currentTimelineFrame
        ) {
            frames = trimOutcome.applying(
                to: frames,
                frameBufferCount: diskFrameBufferIndex.count,
                memoryLogger: { context, frameCount, frameBufferCount, oldestTimestamp, newestTimestamp in
                    MemoryTracker.logMemoryState(
                        context: context,
                        frameCount: frameCount,
                        frameBufferCount: frameBufferCount,
                        oldestTimestamp: oldestTimestamp,
                        newestTimestamp: newestTimestamp
                    )
                }
            )
        }
    }

    // MARK: - Text Selection State

    var revealedRedactedFrameID: FrameID?
    var pendingRedactedNodeHideRemovalTasks: [Int: Task<Void, Never>] = [:]
    static let phraseLevelRedactionHideAnimationDuration: Duration = .milliseconds(520)

    /// Active drag selection mode for the current drag gesture.
    var activeDragSelectionMode: DragSelectionMode = .character

    // MARK: - Selection Range Cache (performance optimization for Cmd+A)

    /// Cached sorted OCR nodes for selection range calculation
    /// Invalidated when ocrNodes changes
    var cachedSortedNodes: [OCRNodeWithText]?

    /// Cached node ID to index lookup for O(1) access
    var cachedNodeIndexMap: [Int: Int]?

    /// The ocrNodes array that the cache was built from (for invalidation check)
    var cachedNodesVersion: Int = 0

    /// Current version of ocrNodes (incremented on change)
    var currentNodesVersion: Int = 0

    /// Deduplicates a single continuous hover even if AppKit/SwiftUI replays hover callbacks.
    var activeInPageURLHoverMetricKey: String?

    // MARK: - Zoom Region State (Shift+Drag focus rectangle)

    /// Shift+drag snapshot/session state for extractor-backed zoom display.
    var shiftDragSessionCounter = 0
    var activeShiftDragSessionID = 0
    var shiftDragStartFrameID: Int64?
    var shiftDragStartVideoInfo: FrameVideoInfo?
    var dragStartStillOCRTask: Task<Void, Never>?
    var dragStartStillOCRRequestID = 0
    var dragStartStillOCRInFlightFrameID: FrameID?
    var dragStartStillOCRCompletedFrameID: FrameID?
    var zoomUpdateCount = 0
    /// Snapshot image used by zoom overlay after Shift+Drag (sourced from AVAssetImageGenerator).
    var shiftDragDisplayRequestID: Int = 0
    var shiftDragDisplayGenerator: AVAssetImageGenerator?
    var zoomCopyRequestID: Int = 0
    var zoomCopyGenerator: AVAssetImageGenerator?

    // MARK: - Text Selection Hint Banner State

    /// Timer to auto-dismiss the text selection hint
    var textSelectionHintTimer: Timer?

    /// Whether the hint banner has already been shown for the current drag session
    var hasShownHintThisDrag: Bool = false

    // MARK: - Controls Hidden Restore Guidance State

    // MARK: - Timeline Position Recovery Hint State

    /// Auto-dismiss task for the position recovery hint banner.
    var positionRecoveryHintDismissTask: Task<Void, Never>?

    // MARK: - Scroll Orientation Hint Banner State

    /// The current orientation when the hint was triggered ("horizontal" or "vertical")
    public var scrollOrientationHintCurrentOrientation: String = "horizontal"

    /// Timer to auto-dismiss the scroll orientation hint
    var scrollOrientationHintTimer: Timer?

    // MARK: - Zoom Transition Animation State

    // MARK: - Frame Zoom State (Trackpad pinch-to-zoom)

    // MARK: - Search State

    /// Whether the search overlay is visible
    @Published public var isSearchOverlayVisible: Bool = false

    /// Whether the in-frame search bar is visible.
    @Published public var isInFrameSearchVisible: Bool = false

    /// Current in-frame search query for highlighting OCR nodes on the active frame.
    @Published public var inFrameSearchQuery: String = ""

    /// Incremented to request keyboard focus for the in-frame search field.
    @Published public var focusInFrameSearchFieldSignal: Int = 0

    // Keep a tiny debounce so rapid typing coalesces, but the highlight still feels immediate.
    static let inFrameSearchDebounceNanoseconds: UInt64 = 20_000_000
    var inFrameSearchDebounceTask: Task<Void, Never>?

    /// Persistent SearchViewModel that survives overlay open/close
    /// This allows search results to be preserved when clicking on a result
    public lazy var searchViewModel: SearchViewModel = {
        SearchViewModel(coordinator: coordinator)
    }()

    // MARK: - Toast Feedback State

    var toastDismissTask: Task<Void, Never>?
    static var positionRecoveryHintDismissedForSession = false
#if DEBUG
    static func resetPositionRecoveryHintDismissalForTesting() {
        positionRecoveryHintDismissedForSession = false
    }
#endif

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

    /// The search query to highlight on the current frame (set when navigating from search)
    @Published public var searchHighlightQuery: String?

    /// Controls whether search highlights draw matched substrings or whole OCR nodes.
    enum SearchHighlightMode: Equatable {
        case matchedTextRanges
        case matchedNodes
    }

    /// The current highlight mode for the active search highlight.
    @Published var searchHighlightMode: SearchHighlightMode = .matchedTextRanges

    /// Whether search highlight is currently being displayed
    @Published public var isShowingSearchHighlight: Bool = false

    public var isSearchResultNavigationModeActive: Bool {
        searchHighlightMode == .matchedNodes &&
        normalizedRestorableSearchHighlightQuery(searchHighlightQuery) != nil
    }

    var pendingSearchHighlightRevealTask: Task<Void, Never>?
    var pendingSearchHighlightResetTask: Task<Void, Never>?
    var searchResultNavigationGeneration: UInt64 = 0

    var hasActiveInFrameSearchQuery: Bool {
        !inFrameSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Timer for periodic processing status refresh while timeline is open
    var statusRefreshTimer: Timer?

    // MARK: - Comment Stores

    let commentsStore = TimelineCommentsStore()
    var currentCommentMetricsSource = "timeline_comment_submenu"
    static let timelineMenuDismissAnimationDuration: TimeInterval = 0.15
    var timelineContextMenuPresentationSource: TimelineContextMenuPresentationSource?
    var timelineTapeRightClickHintDismissTask: Task<Void, Never>?

    // MARK: - Filter State

    let filterStore = TimelineFilterStore()

    /// Current applied filter criteria
    public var filterCriteria: FilterCriteria { filterStore.sessionState.filterCriteria }

    /// Pending filter criteria (edited in panel, applied on submit)
    public var pendingFilterCriteria: FilterCriteria { filterStore.sessionState.pendingFilterCriteria }

    /// Whether the filter panel is visible
    public var isFilterPanelVisible: Bool { filterStore.sessionState.isFilterPanelVisible }

    /// Whether any popover filter dropdown (apps, tags, visibility, date) is open in the filter panel
    /// Note: `.advanced` is inline, not a popover dropdown.
    /// Set by FilterPanel view to allow TimelineWindowController to skip escape handling
    public var isFilterDropdownOpen: Bool { filterStore.sessionState.isFilterDropdownOpen }


    /// Apps available for filtering (installed apps only)
    public var availableAppsForFilter: [(bundleID: String, name: String)] { filterStore.supportDataState.availableAppsForFilter }

    /// Other apps for filtering (apps from DB history that aren't currently installed)
    public var otherAppsForFilter: [(bundleID: String, name: String)] { filterStore.supportDataState.otherAppsForFilter }

    /// Whether apps for filter are currently being loaded
    public var isLoadingAppsForFilter: Bool { filterStore.supportDataState.isLoadingAppsForFilter }

    /// Whether the timeline app filter is waiting on a live Rewind refresh.
    public var isRefreshingRewindAppsForFilter: Bool { filterStore.supportDataState.isRefreshingRewindAppsForFilter }

    /// Map of segment IDs to their tag IDs (for efficient tag filtering)
    public var segmentTagsMap: [Int64: Set<Int64>] { commentsStore.tagIndicatorState.segmentTagsMap }

    /// Map of segment ID to linked comment count (used for comment tape indicators).
    public var segmentCommentCountsMap: [Int64: Int] { commentsStore.tagIndicatorState.segmentCommentCountsMap }

    /// In-flight debounced comment search task.
    /// Page size for server-side comment search.
    static let commentSearchPageSize = 10
    /// Debounce delay for comment search input.
    static let commentSearchDebounceNanoseconds: UInt64 = 250_000_000

    /// Number of active filters (for badge display)
    public var activeFilterCount: Int {
        filterCriteria.activeFilterCount
    }

    /// Whether pending filters differ from applied filters
    public var hasPendingFilterChanges: Bool {
        pendingFilterCriteria != filterCriteria
    }

    var hiddenSegmentIds: Set<SegmentID> {
        filterStore.hiddenSegmentIDs
    }

    // MARK: - Peek Mode State (view full timeline context while filtered)

    /// Cached filtered view state (saved when entering peek mode, restored on exit)
    var cachedFilteredState: TimelineStateSnapshot?

    /// Whether we're currently in peek mode (viewing full context)
    @Published public var isPeeking: Bool = false

    typealias SnapshotFrameInput = TimelineSnapshotFrameInput
    let blockSnapshotController = TimelineBlockSnapshotController()

    deinit {
        commentsStore.cancelPendingWork()
        diskFrameBufferMemoryLogTask?.cancel()
        diskFrameBufferInactivityCleanupTask?.cancel()
        foregroundPresentationWorkState.loadTask?.cancel()
        foregroundPresentationWorkState.unavailableFrameLookupTask?.cancel()
        overlayRefreshWorkState.idleTask?.cancel()
        overlayRefreshWorkState.refreshTask?.cancel()
        overlayRefreshWorkState.ocrStatusPollingTask?.cancel()
        cacheExpansionTask?.cancel()
        blockSnapshotController.cancelPendingWork()
        filterStore.cancelPendingWork()
        pendingDeleteCommitTask?.cancel()
        positionRecoveryHintDismissTask?.cancel()
        Self.clearTimelineMemoryLedger()
    }

    // MARK: - Private State

    /// Sub-frame pixel offset for continuous tape scrolling.
    /// Represents how far the tape has moved beyond the current frame center.
    @Published public internal(set) var subFrameOffset: CGFloat = 0

    /// Task for debouncing scroll end detection
    var scrollDebounceTask: Task<Void, Never>?

    /// Once the user scrubs during a visible timeline session, background refreshes should stop
    /// auto-advancing the playhead until the next show cycle.
    var hasStartedScrubbingThisVisibleSession = false

    /// Task for tape drag momentum animation
    var tapeDragMomentumTask: Task<Void, Never>?

    /// Timer that drives frame auto-advance during playback
    var playbackTimer: Timer?
    var overlayRefreshWorkState = TimelineOverlayRefreshWorkState()

    /// Task for auto-dismissing error messages after a delay
    var errorDismissTask: Task<Void, Never>?

    /// Pending optimistic delete operation that can still be undone.
    var pendingDeleteOperation: PendingDeleteOperation?
    var pendingDeleteCommitTask: Task<Void, Never>?

    enum DiskFrameBufferEntryOrigin: String, Sendable {
        case timelineManaged
        case externalCapture
    }

    struct DiskFrameBufferEntry: Sendable {
        let fileURL: URL
        let sizeBytes: Int64
        var lastAccessSequence: UInt64
        let origin: DiskFrameBufferEntryOrigin
    }

    /// Disk-backed timeline frame buffer metadata (payload bytes are stored in Library/Caches).
    var diskFrameBufferIndex: [FrameID: DiskFrameBufferEntry] = [:] {
        didSet {
            let oldCount = oldValue.count
            let newCount = diskFrameBufferIndex.count
            diskFrameBufferBytes = diskFrameBufferIndex.values.reduce(into: Int64(0)) { total, entry in
                total += entry.sizeBytes
            }
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
    var diskFrameBufferBytes: Int64 = 0
    var diskFrameBufferAccessSequence: UInt64 = 0
    let diskFrameBufferDirectoryURL: URL
    var diskFrameBufferFrameCount: Int { diskFrameBufferIndex.count }
    var diskFrameBufferByteCount: Int64 { diskFrameBufferBytes }
    var pendingCacheExpansionVideoPaths: [String] { pendingCacheExpansionQueue.map(\.videoPath) }
    var queuedOrInFlightCacheExpansionFrameCount: Int { queuedOrInFlightCacheExpansionFrameIDs.count }

    /// Disk buffer hot window policy: keep requests centered around the playhead.
    static let hotWindowFrameCount = 50
    static let cacheMoreBatchSize = 50
    static let cacheMoreEdgeThreshold = 8
    static let cacheMoreEdgeRetriggerDistance = 16
    static let hardSeekResetThreshold = 200
    static let unavailableFrameFallbackSearchRadius = 120
    static let diskFrameBufferInactivityTTLSeconds: TimeInterval = 60
    static let diskFrameBufferUnindexedPruneAgeSeconds: TimeInterval = 20 * 60
    nonisolated static let diskFrameBufferFilenameExtension = "jpg"
    var diskFrameBufferInitializationTask: Task<Void, Never>?
    nonisolated static let appLaunchDate = Date(timeIntervalSinceNow: -ProcessInfo.processInfo.systemUptime)
    var diskFrameBufferMemoryLogTask: Task<Void, Never>?
    var diskFrameBufferTelemetry = DiskFrameBufferTelemetry()
    var foregroundPresentationWorkState = TimelineForegroundPresentationWorkState()
    var cacheExpansionTask: Task<Void, Never>?
    var pendingCacheExpansionQueue: [CacheMoreFrameDescriptor] = []
    var pendingCacheExpansionReadIndex = 0
    var queuedOrInFlightCacheExpansionFrameIDs: Set<FrameID> = []
    var cacheMoreOlderEdgeArmed = true
    var cacheMoreNewerEdgeArmed = true
    var diskFrameBufferInactivityCleanupTask: Task<Void, Never>?
    var hotWindowRange: ClosedRange<Int>?

    enum CacheExpansionDirection: String, Sendable {
        case centered
        case older
        case newer
    }

    struct CacheMoreFrameDescriptor: Sendable {
        let frameID: FrameID
        let videoPath: String
        let frameIndex: Int
    }

    struct ForegroundPresentationRequest {
        let timelineFrame: TimelineFrame
        let presentationGeneration: UInt64
    }

    struct TimelineForegroundPresentationWorkState {
        var loadTask: Task<Void, Never>?
        var pendingRequest: ForegroundPresentationRequest?
        var unavailableFrameLookupTask: Task<Void, Never>?
        var activeFrameID: FrameID?
    }

    struct TimelineOverlayRefreshWorkState {
        var idleTask: Task<Void, Never>?
        var refreshTask: Task<Void, Never>?
        var ocrStatusPollingTask: Task<Void, Never>?
        var deferredRefreshNeeded = false
    }

    struct OverlayPresentationRequest {
        let frame: FrameReference
        let generation: UInt64
    }

    struct OverlayPresentationOCRFetchResult {
        let status: OCRProcessingStatus
        let nodes: [OCRNodeWithText]
    }

    struct OverlayPresentationFetchResult {
        let urlBoundingBox: URLBoundingBox?
        let ocrStatus: OCRProcessingStatus
        let nodes: [OCRNodeWithText]
        let hyperlinkMatches: [OCRHyperlinkMatch]
    }

    struct ForegroundPresentationLoadResult {
        let image: NSImage
        let loadedFromDiskBuffer: Bool
    }

    struct UnavailableFrameFallbackCandidate: Sendable {
        let frameID: FrameID
        let index: Int
    }

    enum CurrentFramePresentationAction {
        case clearForLiveMode
        case clearForMissingFrame
        case showUnavailablePlaceholder(frameID: FrameID, generation: UInt64)
        case enqueueForegroundLoad(TimelineFrame, generation: UInt64)
        case skipDuplicateForegroundLoad(frameID: FrameID)
    }

    enum UnavailableFrameLookupResult {
        case exactImage(NSImage)
        case fallbackImage(image: NSImage, sourceFrameID: FrameID, sourceIndex: Int)
        case miss
    }

    struct ForegroundPresentationFailureOutcome {
        let isNotReady: Bool
        let hasLoadError: Bool
        let logMessage: String?
    }

    /// Pending app quick-filter trace, consumed by the next filter-triggered reload call.
    var pendingCmdFQuickFilterLatencyTrace: CmdFQuickFilterLatencyTrace?

    typealias TrimDirection = TimelineTrimDirection
    typealias BoundaryLoadTrigger = TimelineBoundaryLoadTrigger
    typealias BoundaryLoadContext = TimelineBoundaryLoadContext
    typealias BoundaryLoadDirection = TimelineBoundaryLoadDirection

    let frameWindowStore = TimelineFrameWindowStore()

    /// Monotonic ID for loading state transitions in logs.
    var loadingTransitionID: UInt64 = 0
    /// Start time of the currently active loading state.
    var loadingStateStartedAt: CFAbsoluteTime?
    /// Reason associated with the currently active loading state.
    var activeLoadingReason: String = "idle"
    var criticalTimelineFetchDepth = 0
    var criticalTimelineFetchWaiters: [CheckedContinuation<Void, Never>] = []
    /// Whether async image/OCR/URL presentation work is allowed to publish results.
    var presentationWorkEnabled = false
    /// Monotonic generation used to invalidate stale presentation tasks across hide/show.
    var presentationWorkGeneration: UInt64 = 0

    /// Monotonic ID for timeline fetch traces.
    var fetchTraceID: UInt64 = 0
    /// Monotonic ID for Cmd+G/date-jump traces.
    var dateJumpTraceID: UInt64 = 0

    // MARK: - Infinite Scroll Window State

    /// Flag to prevent duplicate initial frame loading (set synchronously to avoid race conditions)
    var isInitialLoadInProgress = false
    /// Waiters for the current initial most-recent load. Overlapping callers await completion
    /// instead of being dropped, preventing missed-load races between multiple launch paths.
    var initialMostRecentLoadWaiters: [CheckedContinuation<Void, Never>] = []

    /// Counter for periodic memory logging (log every N navigations)
    var navigationCounter: Int = 0
    static let memoryLogInterval = 50  // Log memory state every 50 navigations

    // MARK: - Background Refresh Throttling

    /// Threshold: if user is within this many frames of newest, near-live reopen policy can apply.
    /// This is only considered when the newest loaded frame is still recent.
    static let nearLiveEdgeFrameThreshold: Int = 50

    // MARK: - Playhead Position History (for Cmd+Z undo / Cmd+Shift+Z redo)

    /// Stack of positions where the playhead was stopped for at least 350 ms
    /// Most recent position is at the end of the array
    /// Stores frame ID (unique identifier) and timestamp (for reloading frames if needed)
    var stoppedPositionHistory: [StoppedPosition] = []

    /// Stack of positions that were undone and can be restored via redo.
    /// Most recently undone position is at the end of the array.
    var undonePositionHistory: [StoppedPosition] = []

    /// Work item for detecting when playhead has been stationary for at least 350 ms
    /// Using DispatchWorkItem instead of Task for lower overhead during rapid navigation
    var playheadStoppedDetectionWorkItem: DispatchWorkItem?

    /// The frame ID that was last recorded as a stopped position (to avoid duplicates)
    var lastRecordedStoppedFrameID: FrameID?

    /// Time threshold (in seconds) for considering playhead as "stopped"
    static let stoppedThresholdSeconds: TimeInterval = 0.35

    // MARK: - Dependencies

    let coordinator: AppCoordinator

#if DEBUG
    var test_refreshProcessingStatusesHooks = TimelineRefreshProcessingStatusesTestHooks()
    var test_refreshFrameDataHooks = TimelineRefreshFrameDataTestHooks()
    var test_windowFetchHooks = TimelineWindowFetchTestHooks()
    var test_foregroundFrameLoadHooks = TimelineForegroundFrameLoadTestHooks()
    var test_frameLookupHooks = TimelineFrameLookupTestHooks()
    var test_frameOverlayLoadHooks = TimelineFrameOverlayLoadTestHooks()
    var test_dragStartStillOCRHooks = TimelineDragStartStillOCRTestHooks()
    var test_blockCommentsHooks = TimelineBlockCommentsTestHooks()
    var test_tapeIndicatorRefreshHooks = TimelineTapeIndicatorRefreshTestHooks()
    var test_availableAppsForFilterHooks = TimelineAvailableAppsForFilterTestHooks()
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

    // MARK: - Live OCR

    /// Task for the debounced live OCR - cancelled and re-created on each call
    var liveOCRDebounceTask: Task<Void, Never>?

    /// Wrapper for safely passing CGImage into detached tasks.
    struct LiveOCRCGImage: @unchecked Sendable {
        let image: CGImage
    }

    // MARK: - Infinite Scroll
}
