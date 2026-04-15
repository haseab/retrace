import App
import AppKit
import Combine
import Shared

extension SimpleTimelineViewModel {
    // MARK: - Media Presentation State

    /// Static image for displaying the current frame (for image-based sources like Retrace)
    public var currentImage: NSImage? {
        get { mediaPresentationState.currentImage }
        set { mediaPresentationState.currentImage = newValue }
    }

    var currentImageFrameID: FrameID? {
        mediaPresentationState.currentImageFrameID
    }

    var waitingFallbackImage: NSImage? {
        mediaPresentationState.waitingFallbackImage
    }

    var waitingFallbackImageFrameID: FrameID? {
        mediaPresentationState.waitingFallbackImageFrameID
    }

    var pendingVideoPresentationFrameID: FrameID? {
        mediaPresentationState.pendingVideoPresentationFrameID
    }

    var isPendingVideoPresentationReady: Bool {
        mediaPresentationState.isPendingVideoPresentationReady
    }

    /// Whether the timeline is in "live mode" showing a live screenshot
    /// When true, the liveScreenshot is displayed instead of historical frames
    /// Exits to historical frames on first scroll/navigation
    public var isInLiveMode: Bool {
        mediaPresentationState.isInLiveMode
    }

    /// The live screenshot captured at timeline launch (only used when isInLiveMode == true)
    public var liveScreenshot: NSImage? {
        mediaPresentationState.liveScreenshot
    }

    /// Whether live OCR is currently being processed on the live screenshot
    public var isLiveOCRProcessing: Bool {
        get { mediaPresentationState.isLiveOCRProcessing }
        set { mediaPresentationState.isLiveOCRProcessing = newValue }
    }

    /// Whether the tape is hidden (off-screen below) - used for slide-up animation in live mode
    public var isTapeHidden: Bool {
        get { mediaPresentationState.isTapeHidden }
        set { mediaPresentationState.isTapeHidden = newValue }
    }

    /// Whether the current frame is not yet available in the video file (still encoding)
    public var frameNotReady: Bool {
        mediaPresentationState.frameNotReady
    }

    /// Whether the current frame failed to load (e.g., index out of range, file read error)
    public var frameLoadError: Bool {
        mediaPresentationState.frameLoadError
    }

    /// Loading state
    public var isLoading: Bool {
        mediaPresentationState.isLoading
    }

    /// Error message if something goes wrong
    public var error: String? {
        mediaPresentationState.error
    }

    var errorPublisher: AnyPublisher<String?, Never> {
        $mediaPresentationState
            .map(\.error)
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    /// Flag to force video reload on next updateNSView (clears AVPlayer's stale cache)
    /// Set this when window becomes visible after a metadata refresh
    public var forceVideoReload: Bool {
        get { mediaPresentationState.forceVideoReload }
        set { mediaPresentationState.forceVideoReload = newValue }
    }

    // MARK: - Date Search UI State

    /// Whether the date search input is shown
    public var isDateSearchActive: Bool {
        get { dateSearchUIState.isDateSearchActive }
        set { dateSearchUIState.isDateSearchActive = newValue }
    }

    /// Date search text input
    public var dateSearchText: String {
        get { dateSearchUIState.dateSearchText }
        set { dateSearchUIState.dateSearchText = newValue }
    }

    /// Whether the calendar picker is shown
    public var isCalendarPickerVisible: Bool {
        get { dateSearchUIState.isCalendarPickerVisible }
        set { dateSearchUIState.isCalendarPickerVisible = newValue }
    }

    /// Dates that have frames (for calendar highlighting)
    public var datesWithFrames: Set<Date> {
        get { dateSearchUIState.datesWithFrames }
        set { dateSearchUIState.datesWithFrames = newValue }
    }

    /// Hours with frames for selected calendar date
    public var hoursWithFrames: [Date] {
        get { dateSearchUIState.hoursWithFrames }
        set { dateSearchUIState.hoursWithFrames = newValue }
    }

    /// Currently selected date in calendar
    public var selectedCalendarDate: Date? {
        get { dateSearchUIState.selectedCalendarDate }
        set { dateSearchUIState.selectedCalendarDate = newValue }
    }

    /// Which calendar picker section currently owns arrow-key navigation
    public var calendarKeyboardFocus: TimelineCalendarKeyboardFocus {
        get { dateSearchUIState.calendarKeyboardFocus }
        set { dateSearchUIState.calendarKeyboardFocus = newValue }
    }

    /// Selected hour (0-23) when keyboard focus is on the time grid
    public var selectedCalendarHour: Int? {
        get { dateSearchUIState.selectedCalendarHour }
        set { dateSearchUIState.selectedCalendarHour = newValue }
    }

    // MARK: - Viewport & Chrome State

    /// Zoom level (0.0 to TimelineConfig.maxZoomLevel).
    /// 1.0 preserves the legacy max-detail stop; the upper bound is derived from TimelineZoomSettings.maxPercent.
    public var zoomLevel: CGFloat {
        get { viewportUIState.zoomLevel }
        set { viewportUIState.zoomLevel = newValue }
    }

    /// Whether the zoom slider is expanded/visible
    public var isZoomSliderExpanded: Bool {
        get { chromeUIState.isZoomSliderExpanded }
        set { chromeUIState.isZoomSliderExpanded = newValue }
    }

    /// Whether the more options menu is visible
    public var isMoreOptionsMenuVisible: Bool {
        get { chromeUIState.isMoreOptionsMenuVisible }
        set { chromeUIState.isMoreOptionsMenuVisible = newValue }
    }

    // MARK: - Shell State

    /// Currently selected frame index (for deletion, etc.) - nil means no selection
    public var selectedFrameIndex: Int? {
        get { shellUIState.selectedFrameIndex }
        set { shellUIState.selectedFrameIndex = newValue }
    }

    /// Whether the delete confirmation dialog is shown
    public var showDeleteConfirmation: Bool {
        get { shellUIState.showDeleteConfirmation }
        set { shellUIState.showDeleteConfirmation = newValue }
    }

    /// Whether we're deleting a single frame or an entire segment
    public var isDeleteSegmentMode: Bool {
        get { shellUIState.isDeleteSegmentMode }
        set { shellUIState.isDeleteSegmentMode = newValue }
    }

    /// Frames that have been "deleted" (optimistically removed from UI)
    public var deletedFrameIDs: Set<FrameID> {
        get { shellUIState.deletedFrameIDs }
        set { shellUIState.deletedFrameIDs = newValue }
    }

    /// Bottom action banner shown after a delete so the user can undo.
    public var pendingDeleteUndoMessage: String? {
        get { shellUIState.pendingDeleteUndoMessage }
        set { shellUIState.pendingDeleteUndoMessage = newValue }
    }

    // MARK: - URL Bounding Box State

    /// Bounding box for a clickable URL found in the current frame (normalized 0.0-1.0 coordinates)
    public var urlBoundingBox: URLBoundingBox? {
        overlayPresentationState.urlBoundingBox
    }

    /// Whether the mouse is currently hovering over the URL bounding box
    public var isHoveringURL: Bool {
        get { overlayPresentationState.isHoveringURL }
        set { overlayPresentationState.isHoveringURL = newValue }
    }

    /// Hyperlinks mapped from live DOM to OCR node bounds for the current frame.
    public var hyperlinkMatches: [OCRHyperlinkMatch] {
        overlayPresentationState.hyperlinkMatches
    }

    /// Global mouse position for the current frame in captured-frame pixel coordinates.
    public var frameMousePosition: CGPoint? {
        overlayPresentationState.frameMousePosition
    }

    // MARK: - Text Selection State

    /// All OCR nodes for the current frame (used for text selection)
    public var ocrNodes: [OCRNodeWithText] {
        get { selectionUIState.ocrNodes }
        set {
            selectionUIState.ocrNodes = newValue
            cachedSortedNodes = nil
            cachedNodeIndexMap = nil
            currentNodesVersion &+= 1
        }
    }

    /// Temporary in-memory overlays for revealed redacted OCR nodes (keyed by node ID).
    public var revealedRedactedNodePatches: [Int: NSImage] {
        get { selectionUIState.revealedRedactedNodePatches }
        set { selectionUIState.revealedRedactedNodePatches = newValue }
    }

    public var hidingRedactedNodePatches: [Int: NSImage] {
        get { selectionUIState.hidingRedactedNodePatches }
        set { selectionUIState.hidingRedactedNodePatches = newValue }
    }

    public var activeRedactionTooltipNodeID: Int? {
        get { selectionUIState.activeRedactionTooltipNodeID }
        set { selectionUIState.activeRedactionTooltipNodeID = newValue }
    }

    /// Previous frame's OCR nodes (only populated when showOCRDebugOverlay is enabled, for diff visualization)
    public var previousOcrNodes: [OCRNodeWithText] {
        get { selectionUIState.previousOcrNodes }
        set { selectionUIState.previousOcrNodes = newValue }
    }

    /// OCR processing status for the current frame
    public var ocrStatus: OCRProcessingStatus {
        overlayPresentationState.ocrStatus
    }

    /// Character-level selection: start position (node ID, character index within node)
    public var selectionStart: (nodeID: Int, charIndex: Int)? {
        overlayPresentationState.selectionStart
    }

    /// Character-level selection: end position (node ID, character index within node)
    public var selectionEnd: (nodeID: Int, charIndex: Int)? {
        overlayPresentationState.selectionEnd
    }

    /// Whether all text is selected (via Cmd+A)
    public var isAllTextSelected: Bool {
        get { selectionUIState.isAllTextSelected }
        set { selectionUIState.isAllTextSelected = newValue }
    }

    /// Drag selection start point (in normalized coordinates 0.0-1.0)
    public var dragStartPoint: CGPoint? {
        get { selectionUIState.dragStartPoint }
        set { selectionUIState.dragStartPoint = newValue }
    }

    /// Drag selection end point (in normalized coordinates 0.0-1.0)
    public var dragEndPoint: CGPoint? {
        get { selectionUIState.dragEndPoint }
        set { selectionUIState.dragEndPoint = newValue }
    }

    /// Node IDs selected via Cmd+Drag box selection.
    public var boxSelectedNodeIDs: Set<Int> {
        get { selectionUIState.boxSelectedNodeIDs }
        set { selectionUIState.boxSelectedNodeIDs = newValue }
    }

    /// Whether we have any text selected
    public var hasSelection: Bool {
        isAllTextSelected || !boxSelectedNodeIDs.isEmpty || (selectionStart != nil && selectionEnd != nil)
    }

    // MARK: - Zoom Region State (Shift+Drag focus rectangle)

    /// Whether zoom region mode is active
    public var isZoomRegionActive: Bool {
        get { zoomInteractionUIState.isZoomRegionActive }
        set { zoomInteractionUIState.isZoomRegionActive = newValue }
    }

    /// Zoom region rectangle in normalized coordinates (0.0-1.0)
    /// nil when not zooming, set when Shift+Drag creates a focus region
    public var zoomRegion: CGRect? {
        get { zoomInteractionUIState.zoomRegion }
        set { zoomInteractionUIState.zoomRegion = newValue }
    }

    /// Whether currently dragging to create a zoom region
    public var isDraggingZoomRegion: Bool {
        get { zoomInteractionUIState.isDraggingZoomRegion }
        set { zoomInteractionUIState.isDraggingZoomRegion = newValue }
    }

    /// Start point of zoom region drag (normalized coordinates)
    public var zoomRegionDragStart: CGPoint? {
        get { zoomInteractionUIState.zoomRegionDragStart }
        set { zoomInteractionUIState.zoomRegionDragStart = newValue }
    }

    /// Current end point of zoom region drag (normalized coordinates)
    public var zoomRegionDragEnd: CGPoint? {
        get { zoomInteractionUIState.zoomRegionDragEnd }
        set { zoomInteractionUIState.zoomRegionDragEnd = newValue }
    }

    /// Snapshot image used by zoom overlay after Shift+Drag (sourced from AVAssetImageGenerator).
    public var shiftDragDisplaySnapshot: NSImage? {
        get { zoomInteractionUIState.shiftDragDisplaySnapshot }
        set { zoomInteractionUIState.shiftDragDisplaySnapshot = newValue }
    }

    public var shiftDragDisplaySnapshotFrameID: Int64? {
        get { zoomInteractionUIState.shiftDragDisplaySnapshotFrameID }
        set { zoomInteractionUIState.shiftDragDisplaySnapshotFrameID = newValue }
    }

    // MARK: - Text Selection Hint Banner State

    /// Whether to show the text selection hint banner ("Try area selection mode: Shift + Drag")
    public var showTextSelectionHint: Bool {
        get { chromeUIState.showTextSelectionHint }
        set { chromeUIState.showTextSelectionHint = newValue }
    }

    // MARK: - Controls Hidden Restore Guidance State

    /// Whether to show the top-center restore guidance after hiding controls with Cmd+H.
    public var showControlsHiddenRestoreHintBanner: Bool {
        get { chromeUIState.showControlsHiddenRestoreHintBanner }
        set { chromeUIState.showControlsHiddenRestoreHintBanner = newValue }
    }

    /// Whether the frame context menu should guide the user to the Show Controls row.
    public var highlightShowControlsContextMenuRow: Bool {
        get { chromeUIState.highlightShowControlsContextMenuRow }
        set { chromeUIState.highlightShowControlsContextMenuRow = newValue }
    }

    // MARK: - Timeline Position Recovery Hint State

    /// Whether to show the top-center hint for returning to the pre-cache-bust playhead position.
    public var showPositionRecoveryHintBanner: Bool {
        get { chromeUIState.showPositionRecoveryHintBanner }
        set { chromeUIState.showPositionRecoveryHintBanner = newValue }
    }

    // MARK: - Scroll Orientation Hint Banner State

    /// Whether to show the scroll orientation hint banner
    public var showScrollOrientationHintBanner: Bool {
        get { chromeUIState.showScrollOrientationHintBanner }
        set { chromeUIState.showScrollOrientationHintBanner = newValue }
    }

    // MARK: - Zoom Transition Animation State

    /// Whether we're currently animating the zoom transition
    public var isZoomTransitioning: Bool {
        get { zoomInteractionUIState.isZoomTransitioning }
        set { zoomInteractionUIState.isZoomTransitioning = newValue }
    }

    /// Whether we're animating the exit (reverse) transition
    public var isZoomExitTransitioning: Bool {
        get { zoomInteractionUIState.isZoomExitTransitioning }
        set { zoomInteractionUIState.isZoomExitTransitioning = newValue }
    }

    /// The original rect where the drag ended (for animation start)
    public var zoomTransitionStartRect: CGRect? {
        get { zoomInteractionUIState.zoomTransitionStartRect }
        set { zoomInteractionUIState.zoomTransitionStartRect = newValue }
    }

    /// Animation progress (0.0 = drag position, 1.0 = centered position)
    public var zoomTransitionProgress: CGFloat {
        get { zoomInteractionUIState.zoomTransitionProgress }
        set { zoomInteractionUIState.zoomTransitionProgress = newValue }
    }

    /// Blur opacity during transition (0.0 = no blur, 1.0 = full blur)
    public var zoomTransitionBlurOpacity: CGFloat {
        get { zoomInteractionUIState.zoomTransitionBlurOpacity }
        set { zoomInteractionUIState.zoomTransitionBlurOpacity = newValue }
    }

    // MARK: - Frame Zoom State (Trackpad pinch-to-zoom)

    /// Current frame zoom scale (1.0 = 100%, fit to screen)
    /// Values > 1.0 zoom in, values < 1.0 zoom out (frame becomes smaller than display)
    public var frameZoomScale: CGFloat {
        get { zoomInteractionUIState.frameZoomScale }
        set { zoomInteractionUIState.frameZoomScale = newValue }
    }

    /// Pan offset when zoomed in (for navigating around the zoomed frame)
    public var frameZoomOffset: CGSize {
        get { zoomInteractionUIState.frameZoomOffset }
        set { zoomInteractionUIState.frameZoomOffset = newValue }
    }

    /// Minimum zoom scale (frame smaller than display)
    public static let minFrameZoomScale: CGFloat = TimelineZoomSettings.minFrameScale

    /// Maximum zoom scale (zoomed in)
    public static let maxFrameZoomScale: CGFloat = TimelineZoomSettings.maxFrameScale

    /// Whether the frame is currently zoomed (not at 100%)
    public var isFrameZoomed: Bool {
        abs(frameZoomScale - 1.0) > 0.001
    }

    // MARK: - Chrome State

    /// Whether the timeline controls (tape, playhead, buttons) are hidden
    public var areControlsHidden: Bool {
        get { chromeUIState.areControlsHidden }
        set { chromeUIState.areControlsHidden = newValue }
    }

    /// Whether to show video segment boundaries on the timeline tape
    public var showVideoBoundaries: Bool {
        get { chromeUIState.showVideoBoundaries }
        set { chromeUIState.showVideoBoundaries = newValue }
    }

    /// Whether to show segment boundaries on the timeline tape
    public var showSegmentBoundaries: Bool {
        get { chromeUIState.showSegmentBoundaries }
        set { chromeUIState.showSegmentBoundaries = newValue }
    }

    /// Whether to show the floating browser URL debug window while scrubbing
    public var showBrowserURLDebugWindow: Bool {
        get { chromeUIState.showBrowserURLDebugWindow }
        set { chromeUIState.showBrowserURLDebugWindow = newValue }
    }

    // MARK: - Toast Feedback

    public var toastMessage: String? {
        get { chromeUIState.toastMessage }
        set { chromeUIState.toastMessage = newValue }
    }

    public var toastIcon: String? {
        get { chromeUIState.toastIcon }
        set { chromeUIState.toastIcon = newValue }
    }

    public var toastTone: TimelineToastTone {
        get { chromeUIState.toastTone }
        set { chromeUIState.toastTone = newValue }
    }

    public var toastVisible: Bool {
        get { chromeUIState.toastVisible }
        set { chromeUIState.toastVisible = newValue }
    }

    // MARK: - Video Playback State

    /// Whether video playback (auto-advance) is currently active
    public var isPlaying: Bool {
        get { chromeUIState.isPlaying }
        set { chromeUIState.isPlaying = newValue }
    }

    /// Playback speed multiplier (frames per second)
    /// Available speeds: 1, 2, 4, 8
    public var playbackSpeed: Double {
        get { chromeUIState.playbackSpeed }
        set { chromeUIState.playbackSpeed = newValue }
    }
}
