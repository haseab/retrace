import SwiftUI
import AVKit
import Shared
import App
import UniformTypeIdentifiers

/// Redesigned fullscreen timeline view with scrolling tape and fixed playhead
/// The timeline tape moves left/right while the playhead stays fixed in center
public struct SimpleTimelineView: View {

    // MARK: - Properties

    @ObservedObject private var viewModel: SimpleTimelineViewModel
    @State private var hasInitialized = false

    let coordinator: AppCoordinator
    let onClose: () -> Void

    // MARK: - Initialization

    /// Initialize with an external view model (scroll events handled by TimelineWindowController)
    public init(coordinator: AppCoordinator, viewModel: SimpleTimelineViewModel, onClose: @escaping () -> Void) {
        self.coordinator = coordinator
        self.viewModel = viewModel
        self.onClose = onClose
    }

    // MARK: - Body

    public var body: some View {
        GeometryReader { geometry in
            // Calculate actual frame rect for coordinate transformations
            let actualFrameRect = calculateActualDisplayedFrameRectForView(
                containerSize: geometry.size
            )

            ZStack {
                // Full screen frame display
                frameDisplay
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Bottom blur + gradient backdrop (behind timeline controls)
                VStack {
                    Spacer()
                    // Blur with built-in tint (NSVisualEffectView needs content to blur)
                    PureBlurView(radius: 50)
                        .frame(height: TimelineScaleFactor.blurBackdropHeight)
                        .mask(
                            LinearGradient(
                                stops: [
                                    .init(color: Color.white.opacity(0.0), location: 0.0),
                                    .init(color: Color.white.opacity(0.03), location: 0.1),
                                    .init(color: Color.white.opacity(0.08), location: 0.2),
                                    .init(color: Color.white.opacity(0.15), location: 0.3),
                                    .init(color: Color.white.opacity(0.35), location: 0.4),
                                    .init(color: Color.white.opacity(0.6), location: 0.5),
                                    .init(color: Color.white.opacity(0.85), location: 0.6),
                                    .init(color: Color.white.opacity(0.95), location: 0.7),
                                    .init(color: Color.white.opacity(1.0), location: 0.8),
                                    .init(color: Color.white.opacity(0.85), location: 1.0)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                }
                .allowsHitTesting(false)
                .offset(y: viewModel.areControlsHidden ? TimelineScaleFactor.hiddenControlsOffset : 0)
                .opacity(viewModel.areControlsHidden || viewModel.isDraggingZoomRegion ? 0 : 1)

                // Dismiss overlay for date search panel (Cmd+G) - clicking outside closes it
                // Must be BEFORE TimelineTapeView in ZStack so it's behind the panel
                if viewModel.isDateSearchActive && !viewModel.isCalendarPickerVisible {
                    Color.clear
                        .contentShape(Rectangle())
                        .ignoresSafeArea()
                        .onTapGesture {
                            viewModel.closeDateSearch()
                        }
                }

                // Dismiss overlay for calendar picker - clicking outside closes it
                // Must be BEFORE TimelineTapeView in ZStack so it's behind the picker
                if viewModel.isCalendarPickerVisible {
                    Color.clear
                        .contentShape(Rectangle())
                        .ignoresSafeArea()
                        .onTapGesture {
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                                viewModel.isCalendarPickerVisible = false
                                viewModel.hoursWithFrames = []
                                viewModel.selectedCalendarDate = nil
                            }
                        }
                }

                // Dismiss overlay for zoom slider - clicking outside closes it
                if viewModel.isZoomSliderExpanded {
                    Color.clear
                        .contentShape(Rectangle())
                        .ignoresSafeArea()
                        .onTapGesture {
                            withAnimation(.easeOut(duration: 0.12)) {
                                viewModel.isZoomSliderExpanded = false
                            }
                        }
                }

                // Timeline tape overlay at bottom
                VStack {
                    Spacer()
                    TimelineTapeView(
                        viewModel: viewModel,
                        width: geometry.size.width
                    )
                    .padding(.bottom, TimelineScaleFactor.tapeBottomPadding)
                }
                .offset(y: viewModel.areControlsHidden ? TimelineScaleFactor.hiddenControlsOffset : 0)
                .opacity(viewModel.areControlsHidden || viewModel.isDraggingZoomRegion ? 0 : 1)

                // Persistent controls toggle button (stays visible when controls are hidden)
                if viewModel.areControlsHidden {
                    VStack {
                        Spacer()
                        HStack {
                            ControlsToggleButton(viewModel: viewModel)
                            Spacer()
                        }
                        .padding(.leading, 24)
                        .padding(.bottom, 24)
                    }
                    .transition(.opacity.animation(.easeInOut(duration: 0.2).delay(0.1)))
                }

                // Debug frame ID badge (top-left)
                VStack {
                    HStack {
                        if viewModel.showFrameIDs {
                            DebugFrameIDBadge(viewModel: viewModel)
                        }
                        Spacer()
                            .allowsHitTesting(false)
                    }
                    Spacer()
                        .allowsHitTesting(false)
                }
                .padding(.spacingL)
                .offset(y: viewModel.areControlsHidden ? TimelineScaleFactor.closeButtonHiddenYOffset : 0)
                .opacity(viewModel.areControlsHidden || viewModel.isDraggingZoomRegion ? 0 : 1)

                // Reset zoom button (top center)
                if viewModel.isFrameZoomed {
                    VStack {
                        ResetZoomButton(viewModel: viewModel)
                            .padding(.top, 12) // Extra margin for MacBook notch
                        Spacer()
                            .allowsHitTesting(false)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.spacingL)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    .animation(.easeInOut(duration: 0.2), value: viewModel.isFrameZoomed)
                }

                // Close button (top-right) - always visible
                VStack {
                    HStack {
                        Spacer()
                            .allowsHitTesting(false)
                        closeButton
                    }
                    Spacer()
                        .allowsHitTesting(false)
                }
                .padding(.spacingL)
                .zIndex(100)


                // Loading overlay
                if viewModel.isLoading {
                    loadingOverlay
                }

                // Error overlay
                if let error = viewModel.error {
                    errorOverlay(error)
                }

                // Delete confirmation dialog
                if viewModel.showDeleteConfirmation {
                    DeleteConfirmationDialog(
                        segmentFrameCount: viewModel.selectedSegmentFrameCount,
                        onDeleteFrame: {
                            viewModel.confirmDeleteSelectedFrame()
                        },
                        onDeleteSegment: {
                            viewModel.confirmDeleteSegment()
                        },
                        onCancel: {
                            viewModel.cancelDelete()
                        }
                    )
                }

                // Search overlay (Cmd+F) - uses persistent searchViewModel to preserve results
                if viewModel.isSearchOverlayVisible {
                    SpotlightSearchOverlay(
                        coordinator: coordinator,
                        viewModel: viewModel.searchViewModel,
                        onResultSelected: { result, query in
                            Task {
                                await viewModel.navigateToSearchResult(
                                    frameID: result.id,
                                    timestamp: result.timestamp,
                                    highlightQuery: query
                                )
                            }
                        },
                        onDismiss: {
                            viewModel.isSearchOverlayVisible = false
                        }
                    )
                }

                // Search highlight overlay
                if viewModel.isShowingSearchHighlight {
                    SearchHighlightOverlay(
                        viewModel: viewModel,
                        containerSize: geometry.size,
                        actualFrameRect: actualFrameRect
                    )
                    // Apply the same zoom transformations as the frame content
                    .scaleEffect(viewModel.frameZoomScale)
                    .offset(viewModel.frameZoomOffset)
                }

                // Text selection hint toast (top center)
                if viewModel.showTextSelectionHint {
                    VStack {
                        TextSelectionHintBanner(
                            onDismiss: {
                                viewModel.dismissTextSelectionHint()
                            }
                        )
                        .fixedSize()
                        .padding(.top, 60)
                        .transition(.asymmetric(
                            insertion: .move(edge: .top).combined(with: .opacity),
                            removal: .opacity
                        ))
                        Spacer()
                    }
                    .animation(.spring(response: 0.3, dampingFraction: 0.8), value: viewModel.showTextSelectionHint)
                }

                // Filter panel (floating, anchored to filter button position)
                Group {
                    if viewModel.isFilterPanelVisible {
                        // Dismiss overlay for filter panel and any open dropdown
                        Color.black.opacity(0.001)
                            .ignoresSafeArea()
                            .onTapGesture {
                                if viewModel.activeFilterDropdown != .none {
                                    withAnimation(.easeOut(duration: 0.15)) {
                                        viewModel.dismissFilterDropdown()
                                    }
                                } else {
                                    viewModel.dismissFilterPanel()
                                }
                            }

                        FilterPanel(viewModel: viewModel)
                            .position(
                                x: geometry.size.width - TimelineScaleFactor.rightControlsXOffset - 100,
                                y: geometry.size.height - TimelineScaleFactor.tapeBottomPadding - TimelineScaleFactor.tapeHeight + TimelineScaleFactor.controlsYOffset - 300
                            )
                            .transition(.opacity.combined(with: .offset(y: 15)))

                        // Filter dropdowns - rendered at top level to avoid clipping issues
                        FilterDropdownOverlay(viewModel: viewModel)
                    }
                }
                .animation(.easeOut(duration: 0.15), value: viewModel.isFilterPanelVisible)

                // Timeline segment context menu (for right-click on timeline tape)
                // Placed at the end of ZStack to ensure it renders above all other content
                if viewModel.showTimelineContextMenu {
                    TimelineSegmentContextMenu(
                        viewModel: viewModel,
                        isPresented: $viewModel.showTimelineContextMenu,
                        location: viewModel.timelineContextMenuLocation,
                        containerSize: geometry.size
                    )
                }

            }
            .coordinateSpace(name: "timelineContent")
            .background(Color.black)
            .ignoresSafeArea()
            .onAppear {
                if !hasInitialized {
                    hasInitialized = true
                    Task {
                        await viewModel.loadMostRecentFrame()
                    }
                }
            }
            // Note: Keyboard shortcuts (Cmd+F, Escape) are handled by TimelineWindowController
            // at the window level for more reliable event handling
        }
    }

    // MARK: - Frame Display

    @ViewBuilder
    private var frameDisplay: some View {
        // Debug logging for frame display state
        let _ = Log.debug("[FrameDisplay] videoInfo=\(viewModel.currentVideoInfo != nil), currentImage=\(viewModel.currentImage != nil), isLoading=\(viewModel.isLoading), framesCount=\(viewModel.frames.count), currentIndex=\(viewModel.currentIndex)", category: .ui)
        if let videoInfo = viewModel.currentVideoInfo {
            // Video-based frame (Rewind) with URL overlay
            // Check if video file exists AND has playable content (not still buffering initial fragments)
            let path = videoInfo.videoPath
            let pathWithExt = path + ".mp4"
            let fileSize = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ??
                           (try? FileManager.default.attributesOfItem(atPath: pathWithExt)[.size] as? Int64) ?? 0

            // With movieFragmentInterval = 0.1s and ~3 frames needed before first fragment is written,
            // a typical fragment with 1920x1080 HEVC frames is ~40-50KB minimum per fragment.
            // However, to avoid corrupted/incomplete fragments, require at least 2 fragments written.
            // Observed: Fragment 2 written at ~280KB total. Use 200KB threshold for safety.
            let minFragmentSize: Int64 = 200_000  // 200KB threshold (~2 fragments)
            let fileReady = fileSize >= minFragmentSize

            let _ = Log.debug("[FrameDisplay] Video path: \(path.suffix(50)), size: \(fileSize) bytes, ready: \(fileReady), frameIndex: \(videoInfo.frameIndex)", category: .ui)
            if fileReady {
                FrameWithURLOverlay(viewModel: viewModel, onURLClicked: onClose) {
                    SimpleVideoFrameView(videoInfo: videoInfo)
                }
            } else {
                let _ = Log.warning("[FrameDisplay] Video file too small (no fragments yet), showing placeholder", category: .ui)
                // Video file not ready - show friendly message
                VStack(spacing: .spacingM) {
                    Image(systemName: "clock")
                        .font(.retraceDisplay)
                        .foregroundColor(.white.opacity(0.3))
                    Text("Frame not ready yet")
                        .font(.retraceBody)
                        .foregroundColor(.white.opacity(0.5))
                    Text("Relaunch timeline in a few seconds")
                        .font(.retraceCaption)
                        .foregroundColor(.white.opacity(0.3))
                }
            }
        } else if let image = viewModel.currentImage {
            // Static image (Retrace) with URL overlay
            // let _ = print("[SimpleTimelineView] Showing static image")
            FrameWithURLOverlay(viewModel: viewModel, onURLClicked: onClose) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }
        } else if !viewModel.isLoading {
            // Empty state - no video or image available
            // let _ = print("[SimpleTimelineView] Empty state - no video or image, frames.isEmpty=\(viewModel.frames.isEmpty)")
            VStack(spacing: .spacingM) {
                Image(systemName: viewModel.frames.isEmpty ? "photo.on.rectangle.angled" : "clock")
                    .font(.retraceDisplay)
                    .foregroundColor(.white.opacity(0.3))
                Text(viewModel.frames.isEmpty ? "No frames recorded" : "Frame not ready yet")
                    .font(.retraceBody)
                    .foregroundColor(.white.opacity(0.5))
                if !viewModel.frames.isEmpty {
                    Text("Relaunch timeline in a few seconds")
                        .font(.retraceCaption)
                        .foregroundColor(.white.opacity(0.3))
                }
            }
        }
    }

    // MARK: - Close Button

    @State private var isCloseButtonHovering = false

    private var closeButton: some View {
        let scale = TimelineScaleFactor.current
        let buttonSize = 44 * scale
        let expandedWidth = 120 * scale
        return Button(action: {
            viewModel.dismissContextMenu()
            onClose()
        }) {
            // Fixed-size container prevents hover flicker
            ZStack(alignment: .trailing) {
                // Invisible spacer to maintain hit area
                Color.clear
                    .frame(width: expandedWidth, height: buttonSize)

                // Animated button content
                HStack(spacing: 10 * scale) {
                    Image(systemName: "xmark")
                        .font(.system(size: 18 * scale, weight: .semibold))
                    if isCloseButtonHovering {
                        Text("Close")
                            .font(.system(size: 17 * scale, weight: .medium))
                    }
                }
                .foregroundColor(isCloseButtonHovering ? .white : .white.opacity(0.8))
                .frame(width: isCloseButtonHovering ? nil : buttonSize, height: buttonSize)
                .padding(.horizontal, isCloseButtonHovering ? 20 * scale : 0)
                .background(
                    Capsule()
                        .fill(Color.black.opacity(isCloseButtonHovering ? 0.7 : 0.5))
                )
                .overlay(
                    Capsule()
                        .stroke(Color.white.opacity(0.2), lineWidth: 0.5)
                )
                .animation(.easeOut(duration: 0.15), value: isCloseButtonHovering)
            }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .onHover { hovering in
            isCloseButtonHovering = hovering
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }

    // MARK: - Loading Overlay

    private var loadingOverlay: some View {
        VStack(spacing: .spacingM) {
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                .scaleEffect(1.5)
            Text("Loading...")
                .font(.retraceBody)
                .foregroundColor(.white.opacity(0.7))
        }
    }

    // MARK: - Helper Methods

    /// Calculate the actual displayed frame rect within the container for the main view
    private func calculateActualDisplayedFrameRectForView(containerSize: CGSize) -> CGRect {
        // Get the actual frame dimensions from videoInfo (database)
        // Don't use NSImage.size as that requires extracting the frame from video first
        let frameSize: CGSize
        if let videoInfo = viewModel.currentVideoInfo,
           let width = videoInfo.width,
           let height = videoInfo.height {
            frameSize = CGSize(width: width, height: height)
        } else {
            // Fallback to standard macOS screen dimensions (should rarely be needed)
            frameSize = CGSize(width: 1920, height: 1080)
        }

        // Calculate aspect-fit dimensions
        let containerAspect = containerSize.width / containerSize.height
        let frameAspect = frameSize.width / frameSize.height

        let displayedSize: CGSize
        let offset: CGPoint

        if frameAspect > containerAspect {
            // Frame is wider - fit to width, letterbox top/bottom
            displayedSize = CGSize(
                width: containerSize.width,
                height: containerSize.width / frameAspect
            )
            offset = CGPoint(
                x: 0,
                y: (containerSize.height - displayedSize.height) / 2
            )
        } else {
            // Frame is taller - fit to height, pillarbox left/right
            displayedSize = CGSize(
                width: containerSize.height * frameAspect,
                height: containerSize.height
            )
            offset = CGPoint(
                x: (containerSize.width - displayedSize.width) / 2,
                y: 0
            )
        }

        return CGRect(origin: offset, size: displayedSize)
    }

    // MARK: - Error Overlay

    private func errorOverlay(_ message: String) -> some View {
        VStack(spacing: .spacingM) {
            Image(systemName: "exclamationmark.triangle")
                .font(.retraceDisplay3)
                .foregroundColor(.retraceWarning)
            Text(message)
                .font(.retraceBody)
                .foregroundColor(.white.opacity(0.7))
                .multilineTextAlignment(.center)
        }
        .padding(.spacingL)
        .background(
            RoundedRectangle(cornerRadius: .cornerRadiusM)
                .fill(Color.black.opacity(0.8))
        )
    }
}

// MARK: - Reset Zoom Button

/// Floating button that appears when the frame is zoomed, allowing quick reset to 100%
struct ResetZoomButton: View {
    @ObservedObject var viewModel: SimpleTimelineViewModel
    @State private var isHovering = false

    private var scale: CGFloat { TimelineScaleFactor.current }

    var body: some View {
        Button(action: {
            viewModel.resetFrameZoom()
        }) {
            HStack(spacing: 10 * scale) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 18 * scale, weight: .semibold))
                Text("Reset Zoom")
                    .font(.system(size: 17 * scale, weight: .medium))
            }
            .foregroundColor(isHovering ? .white : .white.opacity(0.8))
            .padding(.horizontal, 20 * scale)
            .padding(.vertical, 12 * scale)
            .background(
                Capsule()
                    .fill(Color.black.opacity(isHovering ? 0.7 : 0.5))
            )
            .overlay(
                Capsule()
                    .stroke(Color.white.opacity(0.2), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = hovering
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
        .help("Reset zoom to 100% (Cmd+0)")
    }
}

// MARK: - Simple Video Frame View

/// Simplified video frame view using AVPlayer
/// Optimized to only reload video when path changes, just seek when frame changes
struct SimpleVideoFrameView: NSViewRepresentable {
    let videoInfo: FrameVideoInfo

    func makeNSView(context: Context) -> AVPlayerView {
        let playerView = AVPlayerView()
        playerView.controlsStyle = .none
        playerView.showsFrameSteppingButtons = false
        playerView.showsSharingServiceButton = false
        playerView.showsFullScreenToggleButton = false

        // Set black background to hide default AVPlayer placeholder icon
        playerView.wantsLayer = true
        playerView.layer?.backgroundColor = NSColor.black.cgColor

        // Disable Live Text analysis to prevent VKImageAnalysisButton crashes
        // when the window is in an inconsistent state during display cycles
        if #available(macOS 13.0, *) {
            playerView.allowsVideoFrameAnalysis = false
        }

        // Create player immediately
        let player = AVPlayer()
        player.actionAtItemEnd = .pause
        playerView.player = player

        return playerView
    }

    func updateNSView(_ playerView: AVPlayerView, context: Context) {
        guard let player = playerView.player else { return }

        let currentPath = context.coordinator.currentVideoPath
        let currentFrameIdx = context.coordinator.currentFrameIndex

        Log.debug("[VideoView] updateNSView: frameIndex=\(videoInfo.frameIndex), coordFrameIdx=\(currentFrameIdx ?? -1)", category: .ui)

        // If same video and same frame, nothing to do
        if currentPath == videoInfo.videoPath && currentFrameIdx == videoInfo.frameIndex {
            Log.debug("[VideoView] Same video and frame, skipping", category: .ui)
            return
        }

        // Update coordinator state
        context.coordinator.currentFrameIndex = videoInfo.frameIndex

        // If same video, just seek (fast path - no flickering)
        if currentPath == videoInfo.videoPath {
            Log.debug("[VideoView] Same video, SEEKING to frame \(videoInfo.frameIndex)", category: .ui)
            // Use integer arithmetic to avoid floating point precision issues
            let time = videoInfo.frameTimeCMTime
            player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { finished in
                let actualTime = player.currentTime().seconds
                let actualFrame = Int(actualTime * 30.0)
                Log.debug("[VideoView] Seek completed: finished=\(finished), targetFrame=\(self.videoInfo.frameIndex), actualTime=\(actualTime)s, actualFrame=\(actualFrame)", category: .ui)
            }
            return
        }

        Log.debug("[VideoView] LOADING NEW VIDEO: \(videoInfo.videoPath.suffix(30))", category: .ui)

        // Different video - need to load new player item
        context.coordinator.currentVideoPath = videoInfo.videoPath

        // Check if file exists (try both with and without .mp4 extension)
        var actualVideoPath = videoInfo.videoPath
        if !FileManager.default.fileExists(atPath: actualVideoPath) {
            let pathWithExtension = actualVideoPath + ".mp4"
            if FileManager.default.fileExists(atPath: pathWithExtension) {
                actualVideoPath = pathWithExtension
            } else {
                Log.error("[SimpleVideoFrameView] Video file not found: \(videoInfo.videoPath)", category: .app)
                return
            }
        }

        // Determine the URL to use - if file already has .mp4 extension, use directly
        // Otherwise create symlink with .mp4 extension for AVFoundation
        let url: URL
        if actualVideoPath.hasSuffix(".mp4") {
            url = URL(fileURLWithPath: actualVideoPath)
        } else {
            // Create symlink with .mp4 extension (Rewind videos don't have extensions)
            let tempDir = FileManager.default.temporaryDirectory
            let fileName = (actualVideoPath as NSString).lastPathComponent
            let symlinkPath = tempDir.appendingPathComponent("\(fileName).mp4").path

            // Only create symlink if it doesn't exist
            if !FileManager.default.fileExists(atPath: symlinkPath) {
                do {
                    try FileManager.default.createSymbolicLink(atPath: symlinkPath, withDestinationPath: actualVideoPath)
                } catch {
                    Log.error("[SimpleVideoFrameView] Failed to create symlink: \(error)", category: .app)
                    return
                }
            }
            url = URL(fileURLWithPath: symlinkPath)
        }
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let playerItem = AVPlayerItem(asset: asset)

        // Clear old observers
        context.coordinator.observers.forEach { $0.invalidate() }
        context.coordinator.observers.removeAll()

        player.replaceCurrentItem(with: playerItem)

        // Seek to frame when ready - use integer arithmetic to avoid floating point precision issues
        let targetTime = videoInfo.frameTimeCMTime
        let targetFrameIndex = videoInfo.frameIndex
        let videoPath = videoInfo.videoPath
        let observer = playerItem.observe(\.status, options: [.new, .initial]) { item, _ in
            Log.debug("[VideoView] PlayerItem status changed: \(item.status.rawValue) (0=unknown, 1=ready, 2=failed) for frame \(targetFrameIndex)", category: .ui)

            if item.status == .failed {
                Log.error("[VideoView] PlayerItem FAILED to load video: \(videoPath.suffix(50)), error: \(item.error?.localizedDescription ?? "unknown")", category: .ui)
                return
            }

            guard item.status == .readyToPlay else { return }

            Log.debug("[VideoView] PlayerItem ready, seeking to frame \(targetFrameIndex)", category: .ui)
            player.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero) { finished in
                Log.debug("[VideoView] Seek to frame \(targetFrameIndex) finished: \(finished)", category: .ui)
                player.pause()
            }
        }

        context.coordinator.observers.append(observer)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator {
        var observers: [NSKeyValueObservation] = []
        var currentVideoPath: String?
        var currentFrameIndex: Int?

        deinit {
            observers.forEach { $0.invalidate() }
        }
    }
}

// MARK: - Frame With URL Overlay

/// Wraps a frame display with an interactive URL bounding box overlay
/// Shows a dotted rectangle when hovering over a detected URL, with click-to-open functionality
/// When zoom region is active, shows enlarged region centered with darkened/blurred background
/// Supports trackpad pinch-to-zoom for zooming in/out of the frame
struct FrameWithURLOverlay<Content: View>: View {
    @ObservedObject var viewModel: SimpleTimelineViewModel
    let onURLClicked: () -> Void
    let content: () -> Content

    var body: some View {
        GeometryReader { geometry in
            let showFinal = viewModel.isZoomRegionActive && viewModel.zoomRegion != nil
            let showTransition = viewModel.isZoomTransitioning && viewModel.zoomRegion != nil
            let showNormal = !viewModel.isZoomRegionActive && !viewModel.isZoomTransitioning

            // Calculate actual frame rect for coordinate transformations
            let actualFrameRect = calculateActualDisplayedFrameRect(
                containerSize: geometry.size,
                viewModel: viewModel
            )

            ZStack {
                // The actual frame content (always present as base layer)
                // Apply frame zoom transformations (magnification handled at window level)
                content()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .scaleEffect(viewModel.frameZoomScale)
                    .offset(viewModel.frameZoomOffset)

                // Unified zoom overlay - handles BOTH transition AND final state
                // Uses the same view instance throughout to avoid VideoView reload flicker
                if (showFinal || showTransition), let region = viewModel.zoomRegion {
                    ZoomUnifiedOverlay(
                        viewModel: viewModel,
                        zoomRegion: region,
                        containerSize: geometry.size,
                        actualFrameRect: actualFrameRect,
                        isTransitioning: showTransition
                    ) {
                        content()
                    }
                }

                // Normal mode overlays (when not zooming or transitioning)
                if showNormal {
                    // Normal mode overlays

                    // Zoom region drag preview (shown while Shift+dragging)
                    if viewModel.isDraggingZoomRegion,
                       let start = viewModel.zoomRegionDragStart,
                       let end = viewModel.zoomRegionDragEnd {
                        ZoomRegionDragPreview(
                            start: start,
                            end: end,
                            containerSize: geometry.size,
                            actualFrameRect: actualFrameRect
                        )
                        // Apply the same zoom transformations as the frame content
                        .scaleEffect(viewModel.frameZoomScale)
                        .offset(viewModel.frameZoomOffset)
                    }

                    // Text selection overlay (for drag selection and zoom region creation)
                    if !viewModel.ocrNodes.isEmpty {
                        TextSelectionOverlay(
                            viewModel: viewModel,
                            containerSize: geometry.size,
                            actualFrameRect: actualFrameRect,
                            onDragStart: { point in
                                viewModel.startDragSelection(at: point)
                            },
                            onDragUpdate: { point in
                                viewModel.updateDragSelection(to: point)
                                // Show hint banner when user drags through the screen
                                viewModel.showTextSelectionHintBannerOnce()
                            },
                            onDragEnd: {
                                viewModel.endDragSelection()
                                viewModel.resetTextSelectionHintState()
                            },
                            onClearSelection: {
                                viewModel.clearTextSelection()
                            },
                            onZoomRegionStart: { point in
                                viewModel.startZoomRegion(at: point)
                            },
                            onZoomRegionUpdate: { point in
                                viewModel.updateZoomRegion(to: point)
                            },
                            onZoomRegionEnd: {
                                viewModel.endZoomRegion()
                            },
                            onDoubleClick: { point in
                                viewModel.selectWordAt(point: point)
                            },
                            onTripleClick: { point in
                                viewModel.selectNodeAt(point: point)
                            }
                        )
                        // Apply the same zoom transformations as the frame content
                        .scaleEffect(viewModel.frameZoomScale)
                        .offset(viewModel.frameZoomOffset)
                    }

                    // URL bounding box overlay (if URL detected)
                    if let box = viewModel.urlBoundingBox {
                        URLBoundingBoxOverlay(
                            boundingBox: box,
                            containerSize: geometry.size,
                            actualFrameRect: actualFrameRect,
                            isHovering: viewModel.isHoveringURL,
                            onHoverChanged: { hovering in
                                viewModel.isHoveringURL = hovering
                            },
                            onClick: {
                                viewModel.openURLInBrowser()
                                // Close the timeline view after opening URL
                                onURLClicked()
                            }
                        )
                        // Apply the same zoom transformations as the frame content
                        .scaleEffect(viewModel.frameZoomScale)
                        .offset(viewModel.frameZoomOffset)
                    }
                }

            }
            .onRightClick { location in
                viewModel.contextMenuLocation = location
                viewModel.showContextMenu = true
            }
            .overlay(
                // Floating context menu at click location
                Group {
                    if viewModel.showContextMenu {
                        FloatingContextMenu(
                            viewModel: viewModel,
                            isPresented: $viewModel.showContextMenu,
                            location: viewModel.contextMenuLocation,
                            containerSize: geometry.size
                        )
                    }
                }
            )
            // Zoom indicator overlay (shows current zoom level when zoomed)
            // Note: Magnification gesture is handled at window level in TimelineWindowController
            .overlay(alignment: .topLeading) {
                if viewModel.isFrameZoomed {
                    FrameZoomIndicator(zoomScale: viewModel.frameZoomScale)
                        .padding(.spacingL)
                        .padding(.top, 40) // Below close button
                }
            }
        }
    }

    /// Calculate the actual displayed frame rect within the container
    /// Takes into account aspect ratio fitting
    private func calculateActualDisplayedFrameRect(containerSize: CGSize, viewModel: SimpleTimelineViewModel) -> CGRect {
        // Get the actual frame dimensions from videoInfo (database)
        // Don't use NSImage.size as that requires extracting the frame from video first
        let frameSize: CGSize
        if let videoInfo = viewModel.currentVideoInfo,
           let width = videoInfo.width,
           let height = videoInfo.height {
            frameSize = CGSize(width: width, height: height)
        } else {
            // Fallback to standard macOS screen dimensions (should rarely be needed)
            frameSize = CGSize(width: 1920, height: 1080)
        }

        // Calculate aspect-fit dimensions
        let containerAspect = containerSize.width / containerSize.height
        let frameAspect = frameSize.width / frameSize.height

        let displayedSize: CGSize
        let offset: CGPoint

        if frameAspect > containerAspect {
            // Frame is wider - fit to width, letterbox top/bottom
            displayedSize = CGSize(
                width: containerSize.width,
                height: containerSize.width / frameAspect
            )
            offset = CGPoint(
                x: 0,
                y: (containerSize.height - displayedSize.height) / 2
            )
        } else {
            // Frame is taller - fit to height, pillarbox left/right
            displayedSize = CGSize(
                width: containerSize.height * frameAspect,
                height: containerSize.height
            )
            offset = CGPoint(
                x: (containerSize.width - displayedSize.width) / 2,
                y: 0
            )
        }

        return CGRect(origin: offset, size: displayedSize)
    }
}

// MARK: - Frame Zoom Indicator

/// Shows the current zoom level when frame is zoomed
struct FrameZoomIndicator: View {
    let zoomScale: CGFloat

    var body: some View {
        HStack(spacing: .spacingS) {
            Image(systemName: zoomScale > 1.0 ? "plus.magnifyingglass" : "minus.magnifyingglass")
                .font(.retraceCaption)
            Text("\(Int(zoomScale * 100))%")
                .font(.retraceCaption.monospacedDigit())
        }
        .foregroundColor(.white)
        .padding(.horizontal, .spacingM)
        .padding(.vertical, .spacingS)
        .background(
            Capsule()
                .fill(Color.black.opacity(0.6))
        )
        .transition(.opacity.combined(with: .scale))
    }
}

// MARK: - Zoom Transition Overlay

/// Animated overlay that transitions from the drag rectangle to the centered zoomed view
/// Shows the rectangle moving from its original position to the center while blur fades in
struct ZoomTransitionOverlay<Content: View>: View {
    @ObservedObject var viewModel: SimpleTimelineViewModel
    let zoomRegion: CGRect
    let containerSize: CGSize
    let content: () -> Content

    var body: some View {
        let progress = viewModel.zoomTransitionProgress
        let blurOpacity = viewModel.zoomTransitionBlurOpacity

        // Calculate start position (original drag rectangle)
        let startRect = CGRect(
            x: zoomRegion.origin.x * containerSize.width,
            y: zoomRegion.origin.y * containerSize.height,
            width: zoomRegion.width * containerSize.width,
            height: zoomRegion.height * containerSize.height
        )

        // Calculate end position (centered enlarged rectangle)
        let maxWidth = containerSize.width * 0.75
        let maxHeight = containerSize.height * 0.75
        let regionWidth = zoomRegion.width * containerSize.width
        let regionHeight = zoomRegion.height * containerSize.height
        let scaleToFit = min(maxWidth / regionWidth, maxHeight / regionHeight)
        let enlargedWidth = regionWidth * scaleToFit
        let enlargedHeight = regionHeight * scaleToFit
        let endRect = CGRect(
            x: (containerSize.width - enlargedWidth) / 2,
            y: (containerSize.height - enlargedHeight) / 2,
            width: enlargedWidth,
            height: enlargedHeight
        )

        // Interpolate between start and end
        let currentRect = CGRect(
            x: lerp(startRect.origin.x, endRect.origin.x, progress),
            y: lerp(startRect.origin.y, endRect.origin.y, progress),
            width: lerp(startRect.width, endRect.width, progress),
            height: lerp(startRect.height, endRect.height, progress)
        )

        // Current scale factor (1.0 at start, scaleToFit at end)
        let currentScale = lerp(1.0, scaleToFit, progress)

        // Center of zoom region in original content
        let zoomCenterX = (zoomRegion.origin.x + zoomRegion.width / 2) * containerSize.width
        let zoomCenterY = (zoomRegion.origin.y + zoomRegion.height / 2) * containerSize.height

        ZStack {
            // Blur overlay that fades in
            if blurOpacity > 0 {
                ZoomBackgroundOverlay()
                    .opacity(blurOpacity)
            }

            // Darkened area outside the rectangle (darken fades in with blur)
            Color.black.opacity(0.6 * blurOpacity)
                .reverseMask {
                    Rectangle()
                        .frame(width: currentRect.width, height: currentRect.height)
                        .position(x: currentRect.midX, y: currentRect.midY)
                }

            // The zoomed content that animates from original position to center
            content()
                .frame(width: containerSize.width, height: containerSize.height)
                .scaleEffect(currentScale, anchor: .center)
                .offset(
                    x: lerp(0, (containerSize.width / 2 - zoomCenterX) * scaleToFit, progress),
                    y: lerp(0, (containerSize.height / 2 - zoomCenterY) * scaleToFit, progress)
                )
                .frame(width: currentRect.width, height: currentRect.height)
                .clipped()
                .position(x: currentRect.midX, y: currentRect.midY)

            // White border around the rectangle
            RoundedRectangle(cornerRadius: lerp(0, 8, progress))
                .stroke(Color.white.opacity(0.9), lineWidth: lerp(2, 3, progress))
                .frame(width: currentRect.width, height: currentRect.height)
                .position(x: currentRect.midX, y: currentRect.midY)
        }
        .allowsHitTesting(false)
    }

    /// Linear interpolation helper
    private func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat {
        a + (b - a) * t
    }
}

// MARK: - Zoom Unified Overlay

/// Unified overlay that handles BOTH the transition animation AND the final zoom state
/// Uses a single view instance throughout to avoid VideoView reload flicker during handoff
/// When isTransitioning=true, animates based on progress; when false, shows final state with text selection
struct ZoomUnifiedOverlay<Content: View>: View {
    @ObservedObject var viewModel: SimpleTimelineViewModel
    let zoomRegion: CGRect
    let containerSize: CGSize
    let actualFrameRect: CGRect
    let isTransitioning: Bool
    let content: () -> Content

    var body: some View {
        // Use progress for animation, or 1.0 for final state
        let progress = isTransitioning ? viewModel.zoomTransitionProgress : 1.0
        let blurOpacity = isTransitioning ? viewModel.zoomTransitionBlurOpacity : 1.0

        // Convert zoomRegion from actualFrameRect-normalized coords to screen coords
        // The normalized Y from screenToNormalizedCoords is already in "top-down" space (0=top, 1=bottom)
        // So we just multiply directly without flipping again
        let regionMinX = zoomRegion.origin.x
        let regionMinY = zoomRegion.origin.y

        // Calculate start position (original drag rectangle) in screen coords
        let startRect = CGRect(
            x: actualFrameRect.origin.x + regionMinX * actualFrameRect.width,
            y: actualFrameRect.origin.y + regionMinY * actualFrameRect.height,
            width: zoomRegion.width * actualFrameRect.width,
            height: zoomRegion.height * actualFrameRect.height
        )

        // Calculate end position (centered enlarged rectangle)
        let maxWidth = containerSize.width * 0.75
        let maxHeight = containerSize.height * 0.75
        let regionWidth = zoomRegion.width * actualFrameRect.width
        let regionHeight = zoomRegion.height * actualFrameRect.height
        let scaleToFit = min(maxWidth / regionWidth, maxHeight / regionHeight)
        let enlargedWidth = regionWidth * scaleToFit
        let enlargedHeight = regionHeight * scaleToFit
        let endRect = CGRect(
            x: (containerSize.width - enlargedWidth) / 2,
            y: (containerSize.height - enlargedHeight) / 2,
            width: enlargedWidth,
            height: enlargedHeight
        )

        // Interpolate between start and end (or use end values directly if not transitioning)
        let currentRect = CGRect(
            x: lerp(startRect.origin.x, endRect.origin.x, progress),
            y: lerp(startRect.origin.y, endRect.origin.y, progress),
            width: lerp(startRect.width, endRect.width, progress),
            height: lerp(startRect.height, endRect.height, progress)
        )

        // Current scale factor (1.0 at start, scaleToFit at end)
        let currentScale = lerp(1.0, scaleToFit, progress)

        // Center of zoom region in original content (screen coords)
        // Y is already in top-down space, so no flip needed
        let zoomCenterX = actualFrameRect.origin.x + (zoomRegion.origin.x + zoomRegion.width / 2) * actualFrameRect.width
        let zoomCenterY = actualFrameRect.origin.y + (zoomRegion.origin.y + zoomRegion.height / 2) * actualFrameRect.height

        ZStack {
            // Blur overlay that fades in
            if blurOpacity > 0 {
                ZoomBackgroundOverlay()
                    .opacity(blurOpacity)
            }

            // Darkened area outside the rectangle (darken fades in with blur)
            Color.black.opacity(0.6 * blurOpacity)
                .reverseMask {
                    Rectangle()
                        .frame(width: currentRect.width, height: currentRect.height)
                        .position(x: currentRect.midX, y: currentRect.midY)
                }

            // The zoomed content that animates from original position to center
            content()
                .frame(width: containerSize.width, height: containerSize.height)
                .scaleEffect(currentScale, anchor: .center)
                .offset(
                    x: lerp(0, (containerSize.width / 2 - zoomCenterX) * scaleToFit, progress),
                    y: lerp(0, (containerSize.height / 2 - zoomCenterY) * scaleToFit, progress)
                )
                .frame(width: currentRect.width, height: currentRect.height)
                .clipped()
                .position(x: currentRect.midX, y: currentRect.midY)

            // White border around the rectangle
            RoundedRectangle(cornerRadius: lerp(0, 8, progress))
                .stroke(Color.white.opacity(0.9), lineWidth: lerp(2, 3, progress))
                .frame(width: currentRect.width, height: currentRect.height)
                .position(x: currentRect.midX, y: currentRect.midY)

            // Text selection overlay - only show when NOT transitioning (final state)
            if !isTransitioning && !viewModel.ocrNodes.isEmpty {
                ZoomedTextSelectionOverlay(
                    viewModel: viewModel,
                    zoomRegion: zoomRegion,
                    containerSize: containerSize
                )
            }
        }
        .allowsHitTesting(!isTransitioning) // Only allow interaction in final state
    }

    /// Linear interpolation helper
    private func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat {
        a + (b - a) * t
    }
}

// MARK: - Pure Blur View

/// A pure blur view that blurs content behind it using withinWindow blending
struct PureBlurView: NSViewRepresentable {
    let radius: CGFloat

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .withinWindow
        view.material = .hudWindow
        view.state = .active
        view.wantsLayer = true
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// MARK: - Zoom Background Overlay

/// Darkened and blurred overlay for the background when zoom is active
struct ZoomBackgroundOverlay: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let blurView = NSVisualEffectView()
        blurView.blendingMode = .withinWindow
        blurView.material = .hudWindow
        blurView.state = .active
        blurView.wantsLayer = true

        // Add dark tint on top of blur
        let darkLayer = CALayer()
        darkLayer.backgroundColor = NSColor.black.withAlphaComponent(0.5).cgColor
        blurView.layer?.addSublayer(darkLayer)

        return blurView
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        // Update dark layer frame
        if let darkLayer = nsView.layer?.sublayers?.first {
            darkLayer.frame = nsView.bounds
        }
    }
}

// MARK: - Zoom Final State Overlay

/// Final state overlay that exactly matches the transition's end state
/// Uses the same reverseMask approach for visual consistency during handoff
struct ZoomFinalStateOverlay<Content: View>: View {
    let zoomRegion: CGRect
    let containerSize: CGSize
    @ObservedObject var viewModel: SimpleTimelineViewModel
    let content: () -> Content

    var body: some View {
        // Calculate end position (centered enlarged rectangle) - same as transition
        let maxWidth = containerSize.width * 0.75
        let maxHeight = containerSize.height * 0.75
        let regionWidth = zoomRegion.width * containerSize.width
        let regionHeight = zoomRegion.height * containerSize.height
        let scaleToFit = min(maxWidth / regionWidth, maxHeight / regionHeight)
        let enlargedWidth = regionWidth * scaleToFit
        let enlargedHeight = regionHeight * scaleToFit
        let finalRect = CGRect(
            x: (containerSize.width - enlargedWidth) / 2,
            y: (containerSize.height - enlargedHeight) / 2,
            width: enlargedWidth,
            height: enlargedHeight
        )

        // Center of zoom region in original content
        let zoomCenterX = (zoomRegion.origin.x + zoomRegion.width / 2) * containerSize.width
        let zoomCenterY = (zoomRegion.origin.y + zoomRegion.height / 2) * containerSize.height

        ZStack {
            // Blur overlay (same as transition end state)
            ZoomBackgroundOverlay()

            // Darkened area outside the rectangle using reverseMask (same as transition)
            Color.black.opacity(0.6)
                .reverseMask {
                    Rectangle()
                        .frame(width: finalRect.width, height: finalRect.height)
                        .position(x: finalRect.midX, y: finalRect.midY)
                }

            // The zoomed content at final position (same as transition end state)
            content()
                .frame(width: containerSize.width, height: containerSize.height)
                .scaleEffect(scaleToFit, anchor: .center)
                .offset(
                    x: (containerSize.width / 2 - zoomCenterX) * scaleToFit,
                    y: (containerSize.height / 2 - zoomCenterY) * scaleToFit
                )
                .frame(width: finalRect.width, height: finalRect.height)
                .clipped()
                .position(x: finalRect.midX, y: finalRect.midY)

            // White border around the rectangle (same as transition end state)
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.9), lineWidth: 3)
                .frame(width: finalRect.width, height: finalRect.height)
                .position(x: finalRect.midX, y: finalRect.midY)

            // Text selection overlay ON TOP of the zoomed region
            if !viewModel.ocrNodes.isEmpty {
                ZoomedTextSelectionOverlay(
                    viewModel: viewModel,
                    zoomRegion: zoomRegion,
                    containerSize: containerSize
                )
            }
        }
    }
}

// MARK: - Zoomed Region View

/// Displays the selected region enlarged and centered on screen
/// The region is scaled up and positioned in the center with a border
struct ZoomedRegionView<Content: View>: View {
    let zoomRegion: CGRect
    let containerSize: CGSize
    let content: () -> Content

    var body: some View {
        // Calculate the enlarged size - scale up to ~70% of screen while maintaining aspect ratio
        let maxWidth = containerSize.width * 0.75
        let maxHeight = containerSize.height * 0.75

        let regionWidth = zoomRegion.width * containerSize.width
        let regionHeight = zoomRegion.height * containerSize.height

        let scaleToFit = min(maxWidth / regionWidth, maxHeight / regionHeight)
        let enlargedWidth = regionWidth * scaleToFit
        let enlargedHeight = regionHeight * scaleToFit

        // Scale factor from original content to enlarged view
        let contentScale = scaleToFit

        // The center of the zoom region in the original content
        let zoomCenterX = (zoomRegion.origin.x + zoomRegion.width / 2) * containerSize.width
        let zoomCenterY = (zoomRegion.origin.y + zoomRegion.height / 2) * containerSize.height

        ZStack {
            // Clipped and scaled content showing only the zoom region
            content()
                .frame(width: containerSize.width, height: containerSize.height)
                .scaleEffect(contentScale, anchor: .center)
                .offset(
                    x: (containerSize.width / 2 - zoomCenterX) * contentScale,
                    y: (containerSize.height / 2 - zoomCenterY) * contentScale
                )
                .frame(width: enlargedWidth, height: enlargedHeight)
                .clipped()

            // White border around the zoomed region
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.9), lineWidth: 3)
                .frame(width: enlargedWidth, height: enlargedHeight)
        }
    }
}

// MARK: - Zoomed Text Selection Overlay

/// Text selection overlay that appears on top of the zoomed region
/// Handles mouse events and transforms coordinates appropriately
struct ZoomedTextSelectionOverlay: View {
    @ObservedObject var viewModel: SimpleTimelineViewModel
    let zoomRegion: CGRect
    let containerSize: CGSize

    var body: some View {
        // Calculate the same dimensions as ZoomedRegionView
        let maxWidth = containerSize.width * 0.75
        let maxHeight = containerSize.height * 0.75

        let regionWidth = zoomRegion.width * containerSize.width
        let regionHeight = zoomRegion.height * containerSize.height

        let scaleToFit = min(maxWidth / regionWidth, maxHeight / regionHeight)
        let enlargedWidth = regionWidth * scaleToFit
        let enlargedHeight = regionHeight * scaleToFit

        ZoomedTextSelectionNSView(
            viewModel: viewModel,
            zoomRegion: zoomRegion,
            enlargedSize: CGSize(width: enlargedWidth, height: enlargedHeight),
            containerSize: containerSize
        )
        .frame(width: enlargedWidth, height: enlargedHeight)
    }
}

/// NSViewRepresentable for handling text selection in zoomed view
struct ZoomedTextSelectionNSView: NSViewRepresentable {
    @ObservedObject var viewModel: SimpleTimelineViewModel
    let zoomRegion: CGRect
    let enlargedSize: CGSize
    let containerSize: CGSize

    func makeNSView(context: Context) -> ZoomedSelectionView {
        Log.debug("[ZoomedTextSelectionNSView] makeNSView - creating new ZoomedSelectionView", category: .ui)
        let view = ZoomedSelectionView()
        view.onDragStart = { point in viewModel.startDragSelection(at: point) }
        view.onDragUpdate = { point in viewModel.updateDragSelection(to: point) }
        view.onDragEnd = { viewModel.endDragSelection() }
        view.onClearSelection = {
            Log.debug("[ZoomedTextSelectionNSView] onClearSelection callback triggered", category: .ui)
            viewModel.clearTextSelection()
        }
        view.onCopyImage = { [weak viewModel] in viewModel?.copyZoomedRegionImage() }
        view.onDoubleClick = { point in viewModel.selectWordAt(point: point) }
        view.onTripleClick = { point in viewModel.selectNodeAt(point: point) }
        return view
    }

    func updateNSView(_ nsView: ZoomedSelectionView, context: Context) {
        Log.debug("[ZoomedTextSelectionNSView] updateNSView called, selectionStart=\(viewModel.selectionStart != nil)", category: .ui)
        nsView.zoomRegion = zoomRegion
        nsView.enlargedSize = enlargedSize

        // Transform OCR nodes to zoomed view coordinates
        // IMPORTANT: Clip nodes to zoom region boundaries so only visible text is selectable
        nsView.nodeData = viewModel.ocrNodes.compactMap { node -> ZoomedSelectionView.NodeData? in
            // Check if node is within zoom region
            let nodeRight = node.x + node.width
            let nodeBottom = node.y + node.height
            let regionRight = zoomRegion.origin.x + zoomRegion.width
            let regionBottom = zoomRegion.origin.y + zoomRegion.height

            // Skip nodes completely outside the zoom region
            if nodeRight < zoomRegion.origin.x || node.x > regionRight ||
               nodeBottom < zoomRegion.origin.y || node.y > regionBottom {
                return nil
            }

            // Clip node to zoom region boundaries
            let clippedX = max(node.x, zoomRegion.origin.x)
            let clippedY = max(node.y, zoomRegion.origin.y)
            let clippedRight = min(nodeRight, regionRight)
            let clippedBottom = min(nodeBottom, regionBottom)
            let clippedWidth = clippedRight - clippedX
            let clippedHeight = clippedBottom - clippedY

            // Calculate which portion of the text is visible (for horizontal clipping)
            // Text flows left-to-right, so we calculate character range based on X clipping
            let textLength = node.text.count
            let visibleStartFraction = (clippedX - node.x) / node.width
            let visibleEndFraction = (clippedRight - node.x) / node.width
            let visibleStartChar = Int(visibleStartFraction * CGFloat(textLength))
            let visibleEndChar = Int(visibleEndFraction * CGFloat(textLength))

            // Extract only the visible portion of text
            let visibleText: String
            if visibleStartChar < visibleEndChar && visibleStartChar >= 0 && visibleEndChar <= textLength {
                let startIdx = node.text.index(node.text.startIndex, offsetBy: visibleStartChar)
                let endIdx = node.text.index(node.text.startIndex, offsetBy: visibleEndChar)
                visibleText = String(node.text[startIdx..<endIdx])
            } else {
                visibleText = node.text
            }

            // Transform CLIPPED coordinates to zoomed coordinate space (0-1 within the enlarged view)
            let transformedX = (clippedX - zoomRegion.origin.x) / zoomRegion.width
            let transformedY = (clippedY - zoomRegion.origin.y) / zoomRegion.height
            let transformedW = clippedWidth / zoomRegion.width
            let transformedH = clippedHeight / zoomRegion.height

            // Convert to screen coordinates within the enlarged view
            // Note: NSView has Y=0 at bottom, but our normalized coords have Y=0 at top
            // So we flip: screenY = (1.0 - normalizedY - normalizedH) * height
            let rect = NSRect(
                x: transformedX * enlargedSize.width,
                y: (1.0 - transformedY - transformedH) * enlargedSize.height,
                width: transformedW * enlargedSize.width,
                height: transformedH * enlargedSize.height
            )

            // Get selection range and adjust for clipped text
            var adjustedSelectionRange: (start: Int, end: Int)? = nil
            if let selectionRange = viewModel.getSelectionRange(for: node.id) {
                // Adjust selection range to account for clipped characters
                let adjustedStart = max(0, selectionRange.start - visibleStartChar)
                let adjustedEnd = min(visibleText.count, selectionRange.end - visibleStartChar)
                if adjustedEnd > adjustedStart {
                    adjustedSelectionRange = (start: adjustedStart, end: adjustedEnd)
                }
            }

            return ZoomedSelectionView.NodeData(
                id: node.id,
                rect: rect,
                text: visibleText,
                selectionRange: adjustedSelectionRange,
                visibleCharOffset: visibleStartChar,
                originalX: node.x,
                originalY: node.y,
                originalW: node.width,
                originalH: node.height
            )
        }

        nsView.needsDisplay = true
    }
}

/// Custom NSView for text selection within the zoomed region
class ZoomedSelectionView: NSView {
    struct NodeData {
        let id: Int
        let rect: NSRect
        let text: String
        let selectionRange: (start: Int, end: Int)?
        /// Offset of the first visible character (for clipped nodes)
        let visibleCharOffset: Int
        /// Original normalized coordinates (for debugging hit-testing)
        let originalX: CGFloat
        let originalY: CGFloat
        let originalW: CGFloat
        let originalH: CGFloat
    }

    var nodeData: [NodeData] = []
    var zoomRegion: CGRect = .zero
    var enlargedSize: CGSize = .zero

    var onDragStart: ((CGPoint) -> Void)?
    var onDragUpdate: ((CGPoint) -> Void)?
    var onDragEnd: (() -> Void)?
    var onClearSelection: (() -> Void)?
    var onCopyImage: (() -> Void)?
    var onDoubleClick: ((CGPoint) -> Void)?
    var onTripleClick: ((CGPoint) -> Void)?

    private var isDragging = false
    private var hasMoved = false
    private var mouseDownPoint: CGPoint = .zero
    private var trackingArea: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let options: NSTrackingArea.Options = [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited]
        trackingArea = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
        addTrackingArea(trackingArea!)
    }

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        mouseDownPoint = location
        hasMoved = false

        // Convert to original frame coordinates
        let normalizedPoint = screenToOriginalCoords(location)

        // Handle multi-click (double-click = word, triple-click = line)
        let clickCount = event.clickCount
        Log.debug("[ZoomedSelectionView] mouseDown clickCount=\(clickCount) isDragging=\(isDragging)", category: .ui)
        if clickCount == 2 {
            Log.debug("[ZoomedSelectionView] Double-click detected, calling onDoubleClick", category: .ui)
            onDoubleClick?(normalizedPoint)
            isDragging = false
        } else if clickCount >= 3 {
            Log.debug("[ZoomedSelectionView] Triple-click detected, calling onTripleClick", category: .ui)
            onTripleClick?(normalizedPoint)
            isDragging = false
        } else {
            isDragging = true
            onDragStart?(normalizedPoint)
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)

        let distance = hypot(location.x - mouseDownPoint.x, location.y - mouseDownPoint.y)
        if distance > 3 {
            hasMoved = true
        }

        // Clamp to bounds
        let clampedX = max(0, min(bounds.width, location.x))
        let clampedY = max(0, min(bounds.height, location.y))

        let normalizedPoint = screenToOriginalCoords(CGPoint(x: clampedX, y: clampedY))
        onDragUpdate?(normalizedPoint)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        Log.debug("[ZoomedSelectionView] mouseUp isDragging=\(isDragging) hasMoved=\(hasMoved)", category: .ui)
        // Only process mouseUp for drag operations (single-click starts drag)
        // Double/triple clicks set isDragging=false in mouseDown, so we skip clearing selection for them
        if isDragging {
            isDragging = false
            if !hasMoved {
                // Single click without drag = clear selection
                Log.debug("[ZoomedSelectionView] Single click without drag, clearing selection", category: .ui)
                onClearSelection?()
            } else {
                onDragEnd?()
            }
        }
        needsDisplay = true
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()

        let copyItem = NSMenuItem(title: "Copy Image", action: #selector(copyImageAction), keyEquivalent: "")
        copyItem.target = self
        menu.addItem(copyItem)

        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func copyImageAction() {
        onCopyImage?()
    }

    /// Convert screen coordinates within the zoomed view to original frame coordinates
    private func screenToOriginalCoords(_ point: CGPoint) -> CGPoint {
        guard enlargedSize.width > 0, enlargedSize.height > 0 else { return .zero }

        // Convert to 0-1 within the zoomed view
        let normalizedInZoom = CGPoint(
            x: point.x / enlargedSize.width,
            y: 1.0 - (point.y / enlargedSize.height)  // Flip Y
        )

        // Transform back to original frame coordinates
        let original = CGPoint(
            x: normalizedInZoom.x * zoomRegion.width + zoomRegion.origin.x,
            y: normalizedInZoom.y * zoomRegion.height + zoomRegion.origin.y
        )

        return original
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        // Light purple color for selection highlight
        let selectionColor = NSColor(red: 0.7, green: 0.5, blue: 0.9, alpha: 0.4)

        // Draw character-level selections
        for node in nodeData {
            guard let range = node.selectionRange, range.end > range.start else { continue }

            let textLength = node.text.count
            guard textLength > 0 else { continue }

            let startFraction = CGFloat(range.start) / CGFloat(textLength)
            let endFraction = CGFloat(range.end) / CGFloat(textLength)

            let highlightRect = NSRect(
                x: node.rect.origin.x + node.rect.width * startFraction,
                y: node.rect.origin.y,
                width: node.rect.width * (endFraction - startFraction),
                height: node.rect.height
            )

            selectionColor.setFill()
            let path = NSBezierPath(roundedRect: highlightRect, xRadius: 2, yRadius: 2)
            path.fill()
        }
    }
}

// MARK: - Zoom Region Drag Preview

/// Shows a preview rectangle while Shift+dragging to create a zoom region
/// Darkens the area outside the selection
struct ZoomRegionDragPreview: View {
    let start: CGPoint
    let end: CGPoint
    let containerSize: CGSize
    let actualFrameRect: CGRect

    var body: some View {
        let minX = min(start.x, end.x)
        let maxX = max(start.x, end.x)
        let minY = min(start.y, end.y)
        let maxY = max(start.y, end.y)

        // Convert from actualFrameRect-normalized coords back to SwiftUI screen coords
        // The normalized Y from screenToNormalizedCoords is already flipped to "top-down" space (0=top, 1=bottom)
        // So we just multiply directly without flipping again
        let rect = CGRect(
            x: actualFrameRect.origin.x + minX * actualFrameRect.width,
            y: actualFrameRect.origin.y + minY * actualFrameRect.height,
            width: (maxX - minX) * actualFrameRect.width,
            height: (maxY - minY) * actualFrameRect.height
        )

        ZStack {
            // Darken outside the selection
            Color.black.opacity(0.6)
                .reverseMask {
                    Rectangle()
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                }

            // White border around selection
            Rectangle()
                .stroke(Color.white.opacity(0.9), lineWidth: 2)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
        }
        .allowsHitTesting(false)
    }
}

/// View modifier extension for reverse masking
extension View {
    @ViewBuilder
    func reverseMask<Mask: View>(@ViewBuilder _ mask: () -> Mask) -> some View {
        self.mask(
            ZStack {
                Rectangle()
                mask()
                    .blendMode(.destinationOut)
            }
            .compositingGroup()
        )
    }
}

// MARK: - URL Bounding Box Overlay

/// Interactive overlay that shows a dotted rectangle around a detected URL
/// Changes cursor to pointer on hover and opens URL on click
struct URLBoundingBoxOverlay: NSViewRepresentable {
    let boundingBox: URLBoundingBox
    let containerSize: CGSize
    let actualFrameRect: CGRect
    let isHovering: Bool
    let onHoverChanged: (Bool) -> Void
    let onClick: () -> Void

    func makeNSView(context: Context) -> URLOverlayView {
        let view = URLOverlayView()
        view.onHoverChanged = onHoverChanged
        view.onClick = onClick
        return view
    }

    func updateNSView(_ nsView: URLOverlayView, context: Context) {
        // Calculate the actual frame rect from normalized coordinates
        // Note: The bounding box coordinates are normalized (0.0-1.0)
        let rect = NSRect(
            x: actualFrameRect.origin.x + (boundingBox.x * actualFrameRect.width),
            y: actualFrameRect.origin.y + ((1.0 - boundingBox.y - boundingBox.height) * actualFrameRect.height), // Flip Y
            width: boundingBox.width * actualFrameRect.width,
            height: boundingBox.height * actualFrameRect.height
        )

        nsView.boundingRect = rect
        nsView.isHoveringURL = isHovering
        nsView.url = boundingBox.url
        nsView.needsDisplay = true
    }
}

/// Custom NSView for URL overlay with mouse tracking
/// Only intercepts mouse events inside the bounding rect, passes through events outside
class URLOverlayView: NSView {
    var boundingRect: NSRect = .zero
    var isHoveringURL: Bool = false
    var url: String = ""
    var onHoverChanged: ((Bool) -> Void)?
    var onClick: (() -> Void)?

    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        // Remove old tracking area
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }

        // Add new tracking area for the bounding box
        guard !boundingRect.isEmpty else { return }

        let options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeInKeyWindow, .mouseMoved]
        trackingArea = NSTrackingArea(rect: boundingRect, options: options, owner: self, userInfo: nil)
        addTrackingArea(trackingArea!)
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChanged?(true)
        NSCursor.pointingHand.push()
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChanged?(false)
        NSCursor.pop()
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        if boundingRect.contains(location) {
            onClick?()
        } else {
            // Pass event to next responder (TextSelectionView)
            super.mouseDown(with: event)
        }
    }

    /// Only accept events inside the bounding rect - pass through elsewhere
    override func hitTest(_ point: NSPoint) -> NSView? {
        if boundingRect.contains(point) {
            return super.hitTest(point)
        }
        // Return nil to let the event pass through to views below
        return nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        // Only draw when hovering and we have a valid bounding rect
        guard isHoveringURL, !boundingRect.isEmpty else { return }

        // Draw dotted rectangle around URL
        let path = NSBezierPath(roundedRect: boundingRect, xRadius: 4, yRadius: 4)
        path.lineWidth = 2.0

        // Set up dotted line pattern
        let dashPattern: [CGFloat] = [6, 4]
        path.setLineDash(dashPattern, count: 2, phase: 0)

        // Green highlight when hovering
        NSColor(red: 0.4, green: 0.9, blue: 0.4, alpha: 0.9).setStroke()
        NSColor(red: 0.4, green: 0.9, blue: 0.4, alpha: 0.15).setFill()
        path.stroke()
        path.fill()
    }
}

// MARK: - Text Selection Overlay

/// Overlay for selecting text from OCR nodes via click-drag or Cmd+A
/// Also handles Shift+Drag for zoom region creation
/// Highlights selected text character-by-character in light purple
struct TextSelectionOverlay: NSViewRepresentable {
    @ObservedObject var viewModel: SimpleTimelineViewModel
    let containerSize: CGSize
    let actualFrameRect: CGRect
    let onDragStart: (CGPoint) -> Void
    let onDragUpdate: (CGPoint) -> Void
    let onDragEnd: () -> Void
    let onClearSelection: () -> Void
    // Zoom region callbacks
    let onZoomRegionStart: (CGPoint) -> Void
    let onZoomRegionUpdate: (CGPoint) -> Void
    let onZoomRegionEnd: () -> Void
    // Multi-click callbacks
    let onDoubleClick: (CGPoint) -> Void
    let onTripleClick: (CGPoint) -> Void

    func makeNSView(context: Context) -> TextSelectionView {
        let view = TextSelectionView()
        view.onDragStart = onDragStart
        view.onDragUpdate = onDragUpdate
        view.onDragEnd = onDragEnd
        view.onClearSelection = onClearSelection
        view.onZoomRegionStart = onZoomRegionStart
        view.onZoomRegionUpdate = onZoomRegionUpdate
        view.onZoomRegionEnd = onZoomRegionEnd
        view.onDoubleClick = onDoubleClick
        view.onTripleClick = onTripleClick
        return view
    }

    func updateNSView(_ nsView: TextSelectionView, context: Context) {
        // Build node data with selection ranges (normal mode - no zoom transformation)
        nsView.nodeData = viewModel.ocrNodes.map { node in
            let rect = NSRect(
                x: actualFrameRect.origin.x + (node.x * actualFrameRect.width),
                y: actualFrameRect.origin.y + ((1.0 - node.y - node.height) * actualFrameRect.height), // Flip Y
                width: node.width * actualFrameRect.width,
                height: node.height * actualFrameRect.height
            )
            let selectionRange = viewModel.getSelectionRange(for: node.id)
            return TextSelectionView.NodeData(
                id: node.id,
                rect: rect,
                text: node.text,
                selectionRange: selectionRange
            )
        }

        nsView.containerSize = containerSize
        nsView.actualFrameRect = actualFrameRect
        nsView.isDraggingSelection = viewModel.dragStartPoint != nil
        nsView.isDraggingZoomRegion = viewModel.isDraggingZoomRegion

        nsView.needsDisplay = true
    }
}

/// Custom NSView for text selection with mouse tracking
/// Supports both text selection (normal drag) and zoom region (Shift+Drag)
class TextSelectionView: NSView {
    /// Data for each OCR node including selection state
    struct NodeData {
        let id: Int
        let rect: NSRect
        let text: String
        let selectionRange: (start: Int, end: Int)?  // Character range selected within this node
    }

    var nodeData: [NodeData] = []
    var containerSize: CGSize = .zero
    var actualFrameRect: CGRect = .zero
    var isDraggingSelection: Bool = false
    var isDraggingZoomRegion: Bool = false

    // Text selection callbacks
    var onDragStart: ((CGPoint) -> Void)?
    var onDragUpdate: ((CGPoint) -> Void)?
    var onDragEnd: (() -> Void)?
    var onClearSelection: (() -> Void)?

    // Zoom region callbacks
    var onZoomRegionStart: ((CGPoint) -> Void)?
    var onZoomRegionUpdate: ((CGPoint) -> Void)?
    var onZoomRegionEnd: (() -> Void)?

    // Multi-click callbacks
    var onDoubleClick: ((CGPoint) -> Void)?
    var onTripleClick: ((CGPoint) -> Void)?

    private var isDragging = false
    private var isZoomDragging = false  // Shift+Drag mode
    private var hasMoved = false  // Track if mouse moved during drag
    private var mouseDownPoint: CGPoint = .zero
    private var trackingArea: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let existing = trackingArea {
            removeTrackingArea(existing)
        }

        let options: NSTrackingArea.Options = [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited]
        trackingArea = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
        addTrackingArea(trackingArea!)
    }

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        mouseDownPoint = location
        hasMoved = false

        // Convert screen coordinates to normalized frame coordinates
        let normalizedPoint = screenToNormalizedCoords(location)

        // Check if Shift is held - start zoom region mode
        if event.modifierFlags.contains(.shift) {
            isZoomDragging = true
            isDragging = false
            onZoomRegionStart?(normalizedPoint)
        } else {
            // Handle multi-click (double-click = word, triple-click = line)
            let clickCount = event.clickCount
            if clickCount == 2 {
                onDoubleClick?(normalizedPoint)
                isDragging = false
                isZoomDragging = false
            } else if clickCount >= 3 {
                onTripleClick?(normalizedPoint)
                isDragging = false
                isZoomDragging = false
            } else {
                isDragging = true
                isZoomDragging = false
                onDragStart?(normalizedPoint)
            }
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)

        // Check if mouse actually moved (more than 3 pixels to avoid micro-movements)
        let distance = hypot(location.x - mouseDownPoint.x, location.y - mouseDownPoint.y)
        if distance > 3 {
            hasMoved = true
        }

        // Clamp to bounds
        let clampedX = max(0, min(bounds.width, location.x))
        let clampedY = max(0, min(bounds.height, location.y))

        // Convert screen coordinates to normalized frame coordinates
        let normalizedPoint = screenToNormalizedCoords(CGPoint(x: clampedX, y: clampedY))

        if isZoomDragging {
            onZoomRegionUpdate?(normalizedPoint)
        } else if isDragging {
            onDragUpdate?(normalizedPoint)
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if isZoomDragging {
            isZoomDragging = false
            if hasMoved {
                onZoomRegionEnd?()
            }
        } else if isDragging {
            isDragging = false
            // If mouse didn't move, this was a click - clear selection
            if !hasMoved {
                onClearSelection?()
            } else {
                onDragEnd?()
            }
        }
        needsDisplay = true
    }

    /// Convert screen coordinates to normalized frame coordinates (0.0-1.0)
    /// Takes into account the actual displayed frame rect (aspect ratio fitting)
    private func screenToNormalizedCoords(_ screenPoint: CGPoint) -> CGPoint {
        guard actualFrameRect.width > 0 && actualFrameRect.height > 0 else {
            // Fallback to old behavior if actualFrameRect not set
            guard containerSize.width > 0 && containerSize.height > 0 else { return .zero }
            return CGPoint(
                x: screenPoint.x / containerSize.width,
                y: 1.0 - (screenPoint.y / containerSize.height)
            )
        }

        // Convert from screen coordinates to frame-relative coordinates
        let frameRelativeX = screenPoint.x - actualFrameRect.origin.x
        let frameRelativeY = screenPoint.y - actualFrameRect.origin.y

        // Normalize to 0.0-1.0 range
        let normalizedX = frameRelativeX / actualFrameRect.width
        let normalizedY = 1.0 - (frameRelativeY / actualFrameRect.height) // Flip Y (NSView origin at bottom)

        return CGPoint(x: normalizedX, y: normalizedY)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        // Note: Zoom region drag preview is now handled by ZoomRegionDragPreview in SwiftUI

        // Light purple color for selection highlight
        let selectionColor = NSColor(red: 0.7, green: 0.5, blue: 0.9, alpha: 0.4)

        // Draw character-level selections
        for node in nodeData {
            guard let range = node.selectionRange, range.end > range.start else { continue }

            let textLength = node.text.count
            guard textLength > 0 else { continue }

            // Calculate the portion of the node rect to highlight
            let startFraction = CGFloat(range.start) / CGFloat(textLength)
            let endFraction = CGFloat(range.end) / CGFloat(textLength)

            let highlightRect = NSRect(
                x: node.rect.origin.x + node.rect.width * startFraction,
                y: node.rect.origin.y,
                width: node.rect.width * (endFraction - startFraction),
                height: node.rect.height
            )

            selectionColor.setFill()
            let path = NSBezierPath(roundedRect: highlightRect, xRadius: 2, yRadius: 2)
            path.fill()
        }
    }
}

// MARK: - Delete Confirmation Dialog

/// Modal dialog for confirming frame or segment deletion
struct DeleteConfirmationDialog: View {
    let segmentFrameCount: Int
    let onDeleteFrame: () -> Void
    let onDeleteSegment: () -> Void
    let onCancel: () -> Void

    @State private var isHoveringDeleteFrame = false
    @State private var isHoveringDeleteSegment = false
    @State private var isHoveringCancel = false

    var body: some View {
        ZStack {
            // Dimmed background
            Color.black.opacity(0.6)
                .ignoresSafeArea()
                .onTapGesture {
                    onCancel()
                }

            // Dialog card
            VStack(spacing: 20) {
                // Icon
                Image(systemName: "trash.fill")
                    .font(.retraceDisplay3)
                    .foregroundColor(.red.opacity(0.8))

                // Title
                Text("Delete Frame?")
                    .font(.retraceHeadline)
                    .foregroundColor(.white)

                // Description
                VStack(spacing: 8) {
                    Text("Choose to delete this frame or the entire segment.")
                        .font(.retraceCallout)
                        .foregroundColor(.white.opacity(0.6))

                    Text("Note: Removes from database only. Video files remain on disk.")
                        .font(.retraceCaption2)
                        .foregroundColor(.white.opacity(0.4))
                        .italic()
                }
                .multilineTextAlignment(.center)

                // Buttons
                VStack(spacing: 10) {
                    // Delete Frame button
                    Button(action: onDeleteFrame) {
                        HStack(spacing: 10) {
                            Image(systemName: "square")
                                .font(.retraceCallout)
                            Text("Delete Frame")
                                .font(.retraceCalloutMedium)
                        }
                        .foregroundColor(.white)
                        .frame(width: 240, height: 40)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(isHoveringDeleteFrame ? Color.red.opacity(0.7) : Color.red.opacity(0.5))
                        )
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        isHoveringDeleteFrame = hovering
                        if hovering { NSCursor.pointingHand.push() }
                        else { NSCursor.pop() }
                    }

                    // Delete Segment button
                    Button(action: onDeleteSegment) {
                        HStack(spacing: 10) {
                            Image(systemName: "rectangle.stack")
                                .font(.retraceCallout)
                            Text("Delete Segment (\(segmentFrameCount) frames)")
                                .font(.retraceCalloutBold)
                        }
                        .foregroundColor(.white)
                        .frame(width: 240, height: 44)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(isHoveringDeleteSegment ? Color.red.opacity(0.9) : Color.red.opacity(0.7))
                        )
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        isHoveringDeleteSegment = hovering
                        if hovering { NSCursor.pointingHand.push() }
                        else { NSCursor.pop() }
                    }

                    // Cancel button
                    Button(action: onCancel) {
                        Text("Cancel")
                            .font(.retraceCalloutMedium)
                            .foregroundColor(.white.opacity(0.8))
                            .frame(width: 240, height: 40)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(isHoveringCancel ? Color.white.opacity(0.15) : Color.white.opacity(0.08))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.white.opacity(0.2), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        isHoveringCancel = hovering
                        if hovering { NSCursor.pointingHand.push() }
                        else { NSCursor.pop() }
                    }
                }
                .padding(.top, 8)
            }
            .padding(32)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(white: 0.15))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(Color.white.opacity(0.1), lineWidth: 1)
                    )
            )
            .shadow(color: .black.opacity(0.5), radius: 30, y: 10)
        }
        .transition(.opacity.combined(with: .scale(scale: 0.95)))
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: true)
    }
}

// MARK: - Search Highlight Overlay

/// Overlay that highlights search matches on the current frame
/// Darkens everything except the matched lines for a spotlight effect
struct SearchHighlightOverlay: View {
    @ObservedObject var viewModel: SimpleTimelineViewModel
    let containerSize: CGSize
    let actualFrameRect: CGRect

    @State private var highlightScale: CGFloat = 0.3

    // Cache the highlight nodes on appear to prevent re-renders from changing them
    @State private var cachedNodes: [(node: OCRNodeWithText, ranges: [Range<String.Index>])] = []

    var body: some View {
        ZStack {
            // Dark overlay
            Color.black.opacity(0.25)

            // Cutout holes for highlights - use compositingGroup for blend mode to work
            ForEach(Array(cachedNodes.enumerated()), id: \.offset) { _, match in
                let node = match.node
                let screenX = actualFrameRect.origin.x + (node.x * actualFrameRect.width)
                let screenY = actualFrameRect.origin.y + (node.y * actualFrameRect.height)
                let screenWidth = node.width * actualFrameRect.width
                let screenHeight = node.height * actualFrameRect.height

                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.white)
                    .frame(width: screenWidth, height: screenHeight)
                    .scaleEffect(highlightScale)
                    .position(x: screenX + screenWidth / 2, y: screenY + screenHeight / 2)
                    .blendMode(.destinationOut)
            }
        }
        .compositingGroup()
        // Yellow borders drawn on top (outside the compositing group)
        .overlay(
            ZStack {
                ForEach(Array(cachedNodes.enumerated()), id: \.offset) { _, match in
                    let node = match.node
                    let screenX = actualFrameRect.origin.x + (node.x * actualFrameRect.width)
                    let screenY = actualFrameRect.origin.y + (node.y * actualFrameRect.height)
                    let screenWidth = node.width * actualFrameRect.width
                    let screenHeight = node.height * actualFrameRect.height

                    RoundedRectangle(cornerRadius: 3)
                        .stroke(Color.yellow.opacity(0.9), lineWidth: 2)
                        .frame(width: screenWidth, height: screenHeight)
                        .scaleEffect(highlightScale)
                        .position(x: screenX + screenWidth / 2, y: screenY + screenHeight / 2)
                }
            }
        )
        .allowsHitTesting(false)
        .onAppear {
            // Cache the nodes immediately to prevent re-render issues
            cachedNodes = viewModel.searchHighlightNodes

            // Animate the scale from 0.3 to 1.0 with spring
            withAnimation(.spring(response: 0.4, dampingFraction: 0.7, blendDuration: 0)) {
                highlightScale = 1.0
            }
        }
    }
}

// MARK: - Debug Frame ID Badge

/// Debug badge showing the current frame ID with click-to-copy functionality
/// and reprocess OCR button that appears on hover
/// Only visible when "Show frame IDs in UI" is enabled in Settings > Advanced
struct DebugFrameIDBadge: View {
    @ObservedObject var viewModel: SimpleTimelineViewModel
    @State private var showCopiedFeedback = false
    @State private var showReprocessFeedback = false
    @State private var isHovering = false
    @State private var isHoveringReprocess = false

    /// Whether the current frame can be reprocessed (only Retrace frames)
    private var canReprocess: Bool {
        viewModel.currentFrame?.source == .native
    }

    var body: some View {
        HStack(spacing: 8) {
            // Frame ID copy button
            Button(action: {
                viewModel.copyCurrentFrameID()
                showCopiedFeedback = true

                // Reset feedback after 1.5 seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    showCopiedFeedback = false
                }
            }) {
                HStack(spacing: 6) {
                    Image(systemName: showCopiedFeedback ? "checkmark" : "doc.on.doc")
                        .font(.retraceTinyMedium)
                        .foregroundColor(showCopiedFeedback ? .green : .white.opacity(0.7))

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Frame ID")
                            .font(.retraceTinyMedium)
                            .foregroundColor(.white.opacity(0.5))

                        if let frame = viewModel.currentFrame {
                            Text(showCopiedFeedback ? "Copied!" : String(frame.id.value))
                                .font(.retraceMonoSmall)
                                .foregroundColor(showCopiedFeedback ? .green : .white)
                        } else {
                            Text("--")
                                .font(.retraceMonoSmall)
                                .foregroundColor(.white.opacity(0.5))
                        }

                        // Debug: Show video frame index being requested
                        if let videoInfo = viewModel.currentVideoInfo {
                            Text("VidIdx: \(videoInfo.frameIndex)")
                                .font(.retraceMonoSmall)
                                .foregroundColor(.orange.opacity(0.8))
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(white: 0.15).opacity(0.9))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isHovering ? Color.white.opacity(0.3) : Color.white.opacity(0.15), lineWidth: 0.5)
                )
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                isHovering = hovering
                if hovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
            .help("Click to copy frame ID")

            // Reprocess OCR button (only shown on hover and for Retrace frames)
            if canReprocess {
                Button(action: {
                    Task {
                        do {
                            try await viewModel.reprocessCurrentFrameOCR()
                            showReprocessFeedback = true
                            // Reset feedback after 1.5 seconds
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                showReprocessFeedback = false
                            }
                        } catch {
                            Log.error("[OCR] Failed to reprocess OCR: \(error)", category: .ui)
                        }
                    }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: showReprocessFeedback ? "checkmark" : "arrow.clockwise")
                            .font(.retraceTinyMedium)
                            .foregroundColor(showReprocessFeedback ? .green : .white.opacity(0.7))

                        Text(showReprocessFeedback ? "Queued" : "OCR")
                            .font(.retraceTinyMedium)
                            .foregroundColor(showReprocessFeedback ? .green : .white.opacity(0.7))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(white: 0.15).opacity(0.9))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(isHoveringReprocess ? Color.white.opacity(0.3) : Color.white.opacity(0.15), lineWidth: 0.5)
                    )
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    isHoveringReprocess = hovering
                    if hovering {
                        NSCursor.pointingHand.push()
                    } else {
                        NSCursor.pop()
                    }
                }
                .help("Reprocess OCR for this frame")
            }
        }
    }
}

// MARK: - Text Selection Hint Banner

/// Banner displayed at the top of the screen when user attempts text selection
/// Suggests using Shift + Drag for area selection mode (like Rewind)
struct TextSelectionHintBanner: View {
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Info icon
            Image(systemName: "info.circle.fill")
                .font(.retraceHeadline)
                .foregroundColor(.white.opacity(0.9))

            // Message
            Text("Selecting text?")
                .font(.retraceCaptionMedium)
                .foregroundColor(.white.opacity(0.9))

            Text("Try area selection mode:")
                .font(.retraceCaption)
                .foregroundColor(.white.opacity(0.7))

            // Keyboard shortcut badges
            HStack(spacing: 4) {
                KeyboardBadge(symbol: "⇧ Shift")
                Text("+")
                    .font(.retraceCaption2Medium)
                    .foregroundColor(.white.opacity(0.5))
                KeyboardBadge(symbol: "⊹ Drag")
            }

            // Dismiss button
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.retraceCaption2Bold)
                    .foregroundColor(.white.opacity(0.6))
                    .frame(width: 24, height: 24)
                    .background(Color.white.opacity(0.1))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(white: 0.2).opacity(0.95))
                .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.white.opacity(0.15), lineWidth: 1)
        )
    }
}

/// Small keyboard shortcut badge
private struct KeyboardBadge: View {
    let symbol: String

    var body: some View {
        Text(symbol)
            .font(.retraceCaption2Medium)
            .foregroundColor(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.white.opacity(0.15))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.white.opacity(0.2), lineWidth: 1)
            )
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let showFrameContextMenu = Notification.Name("showFrameContextMenu")
}

// MARK: - Right Click Handler

/// NSViewRepresentable that detects right-clicks and reports the location
/// View modifier that monitors for right-clicks using a local event monitor
struct RightClickOverlay: ViewModifier {
    let onRightClick: (CGPoint) -> Void
    @State private var eventMonitor: Any?
    @State private var viewBounds: CGRect = .zero

    /// Height of the timeline tape area at the bottom (tape height + bottom padding)
    /// Clicks in this area are passed through to SwiftUI's native contextMenu
    private var timelineExclusionHeight: CGFloat {
        TimelineScaleFactor.tapeHeight + TimelineScaleFactor.tapeBottomPadding + 20 // Extra buffer for the playhead
    }

    func body(content: Content) -> some View {
        content
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear {
                            viewBounds = geo.frame(in: .global)
                        }
                        .onChange(of: geo.frame(in: .global)) { newFrame in
                            viewBounds = newFrame
                        }
                }
            )
            .onAppear {
                setupEventMonitor()
            }
            .onDisappear {
                removeEventMonitor()
            }
    }

    private func setupEventMonitor() {
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { event in
            // Get the click location in screen coordinates
            let screenLocation = NSEvent.mouseLocation

            // Check if click is within our view bounds (approximately)
            // Note: viewBounds is in SwiftUI global coordinates
            if viewBounds.contains(CGPoint(x: screenLocation.x, y: screenLocation.y)) {
                // Convert to view-local coordinates
                let localX = screenLocation.x - viewBounds.minX
                let localY = viewBounds.height - (screenLocation.y - viewBounds.minY)

                // Check if click is in the timeline tape area at the bottom
                // If so, let the event pass through to SwiftUI's native contextMenu
                let distanceFromBottom = viewBounds.height - localY
                if distanceFromBottom < timelineExclusionHeight {
                    // Pass through to SwiftUI for timeline tape context menu
                    return event
                }

                DispatchQueue.main.async {
                    onRightClick(CGPoint(x: localX, y: localY))
                }
                return nil // Consume the event
            }
            return event
        }
    }

    private func removeEventMonitor() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }
}

extension View {
    func onRightClick(perform action: @escaping (CGPoint) -> Void) -> some View {
        modifier(RightClickOverlay(onRightClick: action))
    }
}

// MARK: - Floating Context Menu

/// Floating context menu that appears at click location with smart edge detection
struct FloatingContextMenu: View {
    @ObservedObject var viewModel: SimpleTimelineViewModel
    @Binding var isPresented: Bool
    let location: CGPoint
    let containerSize: CGSize

    // Menu dimensions (approximate)
    private let menuWidth: CGFloat = 200
    private let menuHeight: CGFloat = 220
    private let edgePadding: CGFloat = 16

    var body: some View {
        ZStack {
            // Dismiss overlay
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeOut(duration: 0.15)) {
                        isPresented = false
                    }
                }

            // Menu content - uses shared ContextMenuContent from UI/Components
            ContextMenuContent(viewModel: viewModel, showMenu: $isPresented)
                .retraceMenuContainer()
                .fixedSize()
                .position(adjustedPosition)
        }
        .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: anchorPoint)))
        .animation(.spring(response: 0.2, dampingFraction: 0.8), value: isPresented)
    }

    /// Whether menu should appear above the click (bottom-left at cursor) vs below (top-left at cursor)
    private var shouldShowAbove: Bool {
        // Show above if not enough room below
        location.y + menuHeight > containerSize.height - edgePadding
    }

    /// Calculate position so corner is at mouse location
    private var adjustedPosition: CGPoint {
        // Top-left corner at cursor (default), or bottom-left corner at cursor if near bottom edge
        var x = location.x + menuWidth / 2
        var y = shouldShowAbove ? (location.y - menuHeight / 2) : (location.y + menuHeight / 2)

        // Clamp X to keep menu on screen
        if x + menuWidth / 2 > containerSize.width - edgePadding {
            x = containerSize.width - menuWidth / 2 - edgePadding
        }
        if x - menuWidth / 2 < edgePadding {
            x = menuWidth / 2 + edgePadding
        }

        // Clamp Y to keep menu on screen
        if y - menuHeight / 2 < edgePadding {
            y = menuHeight / 2 + edgePadding
        }
        if y + menuHeight / 2 > containerSize.height - edgePadding {
            y = containerSize.height - menuHeight / 2 - edgePadding
        }

        return CGPoint(x: x, y: y)
    }

    /// Determine anchor point for animation based on position
    private var anchorPoint: UnitPoint {
        shouldShowAbove ? .bottomLeading : .topLeading
    }
}

// MARK: - Context Menu Dismiss Overlay

/// Overlay that dismisses the context menu on left-click, lets right-clicks pass through
struct ContextMenuDismissOverlay: NSViewRepresentable {
    @ObservedObject var viewModel: SimpleTimelineViewModel

    func makeNSView(context: Context) -> ContextMenuDismissNSView {
        let view = ContextMenuDismissNSView()
        view.viewModel = viewModel
        return view
    }

    func updateNSView(_ nsView: ContextMenuDismissNSView, context: Context) {
        nsView.viewModel = viewModel
    }
}

/// NSView that handles left-clicks to dismiss, passes right-clicks through
class ContextMenuDismissNSView: NSView {
    weak var viewModel: SimpleTimelineViewModel?

    override func mouseDown(with event: NSEvent) {
        // Left-click dismisses the menu
        guard let viewModel = viewModel else { return }
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.15)) {
                viewModel.dismissTimelineContextMenu()
            }
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Only capture left-clicks, let right-clicks pass through to frame handlers
        guard let event = NSApp.currentEvent else {
            return self
        }

        if event.type == .rightMouseDown {
            // Dismiss the menu, then return nil to let the click pass through
            DispatchQueue.main.async { [weak self] in
                self?.viewModel?.dismissTimelineContextMenu()
            }
            return nil
        }

        // Capture all other clicks (left-click to dismiss)
        return self
    }
}

// MARK: - Timeline Segment Context Menu

/// Context menu for right-clicking on timeline segments (Add Tag, Hide, Delete)
struct TimelineSegmentContextMenu: View {
    @ObservedObject var viewModel: SimpleTimelineViewModel
    @Binding var isPresented: Bool
    let location: CGPoint
    let containerSize: CGSize

    // Menu dimensions
    private let menuWidth: CGFloat = 180
    private let menuHeight: CGFloat = 140
    private let submenuWidth: CGFloat = 160
    private let edgePadding: CGFloat = 16

    var body: some View {
        ZStack {
            // Dismiss overlay - handles left-click to dismiss, passes right-click through
            ContextMenuDismissOverlay(viewModel: viewModel)

            // Main menu content
            VStack(alignment: .leading, spacing: 0) {
                // Add Tag button (with submenu that opens on hover)
                TimelineMenuButton(
                    icon: "tag",
                    title: "Add Tag",
                    showChevron: true,
                    onHoverChanged: { isHovering in
                        viewModel.isHoveringAddTagButton = isHovering
                        if isHovering && !viewModel.showTagSubmenu {
                            withAnimation(.easeOut(duration: 0.15)) {
                                viewModel.showTagSubmenu = true
                            }
                        }
                    }
                ) {
                    // Toggle on click as well
                    withAnimation(.easeOut(duration: 0.15)) {
                        viewModel.showTagSubmenu.toggle()
                    }
                }

                // Filter button
                TimelineMenuButton(
                    icon: "line.3.horizontal.decrease",
                    title: "Filter",
                    onHoverChanged: { isHovering in
                        // Close tag submenu when hovering over other items
                        if isHovering && viewModel.showTagSubmenu {
                            withAnimation(.easeOut(duration: 0.15)) {
                                viewModel.showTagSubmenu = false
                                viewModel.showNewTagInput = false
                                viewModel.newTagName = ""
                            }
                        }
                    }
                ) {
                    viewModel.dismissTimelineContextMenu()
                    viewModel.openFilterPanel()
                }

                // Hide button
                TimelineMenuButton(
                    icon: "eye.slash",
                    title: "Hide",
                    onHoverChanged: { isHovering in
                        // Close tag submenu when hovering over other items
                        if isHovering && viewModel.showTagSubmenu {
                            withAnimation(.easeOut(duration: 0.15)) {
                                viewModel.showTagSubmenu = false
                                viewModel.showNewTagInput = false
                                viewModel.newTagName = ""
                            }
                        }
                    }
                ) {
                    viewModel.hideSelectedTimelineSegment()
                }

                Divider()
                    .background(Color.white.opacity(0.1))
                    .padding(.vertical, 4)

                // Delete button
                TimelineMenuButton(
                    icon: "trash",
                    title: "Delete",
                    isDestructive: true,
                    onHoverChanged: { isHovering in
                        // Close tag submenu when hovering over other items
                        if isHovering && viewModel.showTagSubmenu {
                            withAnimation(.easeOut(duration: 0.15)) {
                                viewModel.showTagSubmenu = false
                                viewModel.showNewTagInput = false
                                viewModel.newTagName = ""
                            }
                        }
                    }
                ) {
                    viewModel.requestDeleteFromTimelineMenu()
                }
            }
            .padding(.vertical, 8)
            .frame(width: menuWidth)
            .retraceMenuContainer()
            .position(adjustedPosition)

            // Tag submenu (appears when "Add Tag" is hovered/clicked)
            if viewModel.showTagSubmenu {
                TagSubmenu(viewModel: viewModel)
                    .position(submenuPosition)
                    .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .leading)))
            }
        }
        .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: anchorPoint)))
        .animation(.spring(response: 0.2, dampingFraction: 0.8), value: isPresented)
        .animation(.spring(response: 0.2, dampingFraction: 0.8), value: viewModel.showTagSubmenu)
    }

    /// Whether menu should appear above the click
    private var shouldShowAbove: Bool {
        location.y + menuHeight > containerSize.height - edgePadding
    }

    /// Calculate main menu position
    private var adjustedPosition: CGPoint {
        var x = location.x + menuWidth / 2
        var y = shouldShowAbove ? (location.y - menuHeight / 2) : (location.y + menuHeight / 2)

        // Clamp X
        if x + menuWidth / 2 > containerSize.width - edgePadding {
            x = containerSize.width - menuWidth / 2 - edgePadding
        }
        if x - menuWidth / 2 < edgePadding {
            x = menuWidth / 2 + edgePadding
        }

        // Clamp Y
        if y - menuHeight / 2 < edgePadding {
            y = menuHeight / 2 + edgePadding
        }
        if y + menuHeight / 2 > containerSize.height - edgePadding {
            y = containerSize.height - menuHeight / 2 - edgePadding
        }

        return CGPoint(x: x, y: y)
    }

    /// Calculate submenu position (to the right of main menu)
    private var submenuPosition: CGPoint {
        var x = adjustedPosition.x + menuWidth / 2 + submenuWidth / 2 + 4
        let y = adjustedPosition.y - menuHeight / 2 + 40 // Align with "Add Tag" row

        // If submenu would go off right edge, show on left side instead
        if x + submenuWidth / 2 > containerSize.width - edgePadding {
            x = adjustedPosition.x - menuWidth / 2 - submenuWidth / 2 - 4
        }

        return CGPoint(x: x, y: y)
    }

    private var anchorPoint: UnitPoint {
        shouldShowAbove ? .bottomLeading : .topLeading
    }
}

// MARK: - Timeline Menu Button

/// A button in the timeline context menu
// TimelineMenuButton: now uses the unified RetraceMenuButton from AppTheme
typealias TimelineMenuButton = RetraceMenuButton

// MARK: - Tag Submenu

/// Submenu showing available tags with search/create functionality
struct TagSubmenu: View {
    @ObservedObject var viewModel: SimpleTimelineViewModel
    @State private var isHoveringSubmenu = false
    @State private var closeTask: Task<Void, Never>?
    @State private var searchText = ""
    @FocusState private var isSearchFocused: Bool

    // Filter out the "hidden" tag, apply search filter, and sort with selected tags first
    private var visibleTags: [Tag] {
        let nonHidden = viewModel.availableTags.filter { !$0.isHidden }
        let filtered = searchText.isEmpty
            ? nonHidden
            : nonHidden.filter { $0.name.localizedCaseInsensitiveContains(searchText) }

        // Sort: selected tags first, then alphabetically within each group
        return filtered.sorted { tag1, tag2 in
            let tag1Selected = viewModel.selectedSegmentTags.contains(tag1.id)
            let tag2Selected = viewModel.selectedSegmentTags.contains(tag2.id)

            if tag1Selected != tag2Selected {
                return tag1Selected // Selected tags come first
            }
            return tag1.name.localizedCaseInsensitiveCompare(tag2.name) == .orderedAscending
        }
    }

    // Check if search text matches an existing tag exactly
    private var exactTagMatch: Bool {
        viewModel.availableTags.contains { $0.name.lowercased() == searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
    }

    // Show "Create" option if there's search text that doesn't match an existing tag
    private var showCreateOption: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !exactTagMatch
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Search/Create input field - always visible
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.5))

                TextField("Search or create...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundColor(.white)
                    .focused($isSearchFocused)
                    .onSubmit {
                        if showCreateOption {
                            createTagFromSearch()
                        } else if visibleTags.count == 1 {
                            // If only one result, toggle it
                            viewModel.toggleTagOnSelectedSegment(tag: visibleTags[0])
                        }
                    }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.white.opacity(0.08))
            )
            .padding(.horizontal, 8)
            .padding(.top, 4)
            .padding(.bottom, 6)

            Divider()
                .background(Color.white.opacity(0.1))
                .padding(.horizontal, 8)

            // Tag list
            if visibleTags.isEmpty && !showCreateOption {
                Text("No tags found")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.5))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        // Existing tags that match search
                        ForEach(visibleTags) { tag in
                            TagSubmenuRow(
                                tag: tag,
                                isSelected: viewModel.selectedSegmentTags.contains(tag.id)
                            ) {
                                viewModel.toggleTagOnSelectedSegment(tag: tag)
                            }
                        }

                        // "Create [searchtext]" option if search text doesn't match existing tag
                        if showCreateOption {
                            Button(action: createTagFromSearch) {
                                HStack(spacing: 10) {
                                    Image(systemName: "plus")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundColor(.retraceAccent)

                                    Text("Create \"\(searchText.trimmingCharacters(in: .whitespacesAndNewlines))\"")
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundColor(.retraceAccent)

                                    Spacer()
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .onHover { hovering in
                                if hovering { NSCursor.pointingHand.push() }
                                else { NSCursor.pop() }
                            }
                        }
                    }
                }
                .frame(maxHeight: 120) // Limit height for scrolling
            }
        }
        .padding(.vertical, 2)
        .frame(width: 180)
        .retraceMenuContainer()
        .onAppear {
            // Delay focus slightly to ensure the view is in the responder chain
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isSearchFocused = true
            }
        }
        .onHover { hovering in
            isHoveringSubmenu = hovering
            if !hovering {
                // Small delay before closing to allow mouse to move back to main menu or Add Tag button
                closeTask?.cancel()
                closeTask = Task {
                    try? await Task.sleep(nanoseconds: 150_000_000) // 150ms delay
                    if !Task.isCancelled && !isHoveringSubmenu && !viewModel.isHoveringAddTagButton {
                        await MainActor.run {
                            withAnimation(.easeOut(duration: 0.15)) {
                                viewModel.showTagSubmenu = false
                                searchText = ""
                            }
                        }
                    }
                }
            } else {
                // Cancel any pending close
                closeTask?.cancel()
            }
        }
    }

    private func createTagFromSearch() {
        let tagName = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tagName.isEmpty else { return }

        viewModel.newTagName = tagName
        viewModel.createAndAddTag()
        searchText = ""
    }
}

// MARK: - Tag Submenu Row

/// A single tag row in the submenu
struct TagSubmenuRow: View {
    let tag: Tag
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                // TODO: Add color picker/editing for tags later
                // Circle()
                //     .fill(Color.segmentColor(for: tag.name))
                //     .frame(width: 8, height: 8)

                Text(tag.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.retraceAccent)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovering ? Color.white.opacity(0.1) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.1)) {
                isHovering = hovering
            }
            if hovering { NSCursor.pointingHand.push() }
            else { NSCursor.pop() }
        }
    }
}

// MARK: - Filter Panel

/// Floating vertical card panel for timeline filtering
struct FilterPanel: View {
    @ObservedObject var viewModel: SimpleTimelineViewModel
    @GestureState private var dragOffset: CGSize = .zero
    @State private var panelPosition: CGSize = .zero
    @State private var escapeMonitor: Any?

    /// Label for apps filter chip (uses pending criteria)
    private var appsLabel: String {
        guard let selected = viewModel.pendingFilterCriteria.selectedApps, !selected.isEmpty else {
            return "All Apps"
        }
        if selected.count == 1, let bundleID = selected.first,
           let app = viewModel.availableAppsForFilter.first(where: { $0.bundleID == bundleID }) {
            return app.name
        }
        return "\(selected.count) Apps"
    }

    /// Label for tags filter chip (uses pending criteria)
    private var tagsLabel: String {
        guard let selected = viewModel.pendingFilterCriteria.selectedTags, !selected.isEmpty else {
            return "All Tags"
        }
        if selected.count == 1, let tagId = selected.first,
           let tag = viewModel.availableTags.first(where: { $0.id.value == tagId }) {
            return tag.name
        }
        return "\(selected.count) Tags"
    }

    /// Label for hidden filter dropdown
    private var hiddenFilterLabel: String {
        switch viewModel.pendingFilterCriteria.hiddenFilter {
        case .hide:
            return "Visible Only"
        case .onlyHidden:
            return "Hidden Only"
        case .showAll:
            return "All Segments"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("Filter Timeline")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)

                Spacer()

                // Clear button (only when pending filters are active)
                if viewModel.pendingFilterCriteria.hasActiveFilters {
                    Button(action: { viewModel.clearPendingFilters() }) {
                        Text("Clear")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                }

                Button(action: { viewModel.dismissFilterPanel() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white.opacity(0.4))
                        .frame(width: 22, height: 22)
                        .background(Color.white.opacity(0.1))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 16)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .updating($dragOffset) { value, state, _ in
                        state = value.translation
                    }
                    .onEnded { value in
                        panelPosition.width += value.translation.width
                        panelPosition.height += value.translation.height
                    }
            )
            .onHover { hovering in
                if hovering { NSCursor.openHand.push() }
                else { NSCursor.pop() }
            }

            // Source section
            VStack(alignment: .leading, spacing: 12) {
                Text("SOURCE")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.4))
                    .tracking(0.5)

                HStack(spacing: 10) {
                    // When selectedSources is nil, show both as selected (all sources)
                    // When it's set, only show selected ones
                    let sources = viewModel.pendingFilterCriteria.selectedSources
                    let retraceSelected = sources == nil || sources!.contains(.native)
                    let rewindSelected = sources == nil || sources!.contains(.rewind)

                    FilterToggleChip(
                        label: "Retrace",
                        icon: "desktopcomputer",
                        isSelected: retraceSelected
                    ) {
                        viewModel.toggleSourceFilter(.native)
                    }

                    FilterToggleChip(
                        label: "Rewind",
                        icon: "arrow.counterclockwise",
                        isSelected: rewindSelected
                    ) {
                        viewModel.toggleSourceFilter(.rewind)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)

            // Divider
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)
                .padding(.horizontal, 20)

            // Apps section
            VStack(alignment: .leading, spacing: 12) {
                Text("APPS")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.4))
                    .tracking(0.5)

                GeometryReader { geo in
                    let localFrame = geo.frame(in: .named("timelineContent"))
                    FilterDropdownButton(
                        label: appsLabel,
                        icon: "square.grid.2x2",
                        isActive: viewModel.pendingFilterCriteria.selectedApps != nil && !viewModel.pendingFilterCriteria.selectedApps!.isEmpty
                    ) {
                        withAnimation(.easeOut(duration: 0.15)) {
                            if viewModel.activeFilterDropdown == .apps {
                                viewModel.dismissFilterDropdown()
                            } else {
                                viewModel.showFilterDropdown(.apps, anchorFrame: localFrame)
                            }
                        }
                    }
                }
                .frame(height: 40)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 20)

            // Divider
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)
                .padding(.horizontal, 20)

            // Tags section
            VStack(alignment: .leading, spacing: 12) {
                Text("TAGS")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.4))
                    .tracking(0.5)

                GeometryReader { geo in
                    let localFrame = geo.frame(in: .named("timelineContent"))
                    FilterDropdownButton(
                        label: tagsLabel,
                        icon: "tag",
                        isActive: viewModel.pendingFilterCriteria.selectedTags != nil && !viewModel.pendingFilterCriteria.selectedTags!.isEmpty
                    ) {
                        withAnimation(.easeOut(duration: 0.15)) {
                            if viewModel.activeFilterDropdown == .tags {
                                viewModel.dismissFilterDropdown()
                            } else {
                                viewModel.showFilterDropdown(.tags, anchorFrame: localFrame)
                            }
                        }
                    }
                }
                .frame(height: 40)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 20)

            // Divider
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)
                .padding(.horizontal, 20)

            // Hidden segments section with dropdown
            VStack(alignment: .leading, spacing: 12) {
                Text("VISIBILITY")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.4))
                    .tracking(0.5)

                GeometryReader { geo in
                    let localFrame = geo.frame(in: .named("timelineContent"))
                    FilterDropdownButton(
                        label: hiddenFilterLabel,
                        icon: "eye",
                        isActive: viewModel.pendingFilterCriteria.hiddenFilter != .hide
                    ) {
                        withAnimation(.easeOut(duration: 0.15)) {
                            if viewModel.activeFilterDropdown == .visibility {
                                viewModel.dismissFilterDropdown()
                            } else {
                                viewModel.showFilterDropdown(.visibility, anchorFrame: localFrame)
                            }
                        }
                    }
                }
                .frame(height: 40)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 20)

            // Divider before apply button
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)
                .padding(.horizontal, 20)

            // Apply button
            Button(action: { viewModel.applyFilters() }) {
                Text("Apply Filters")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(RetraceMenuStyle.actionBlue.opacity(0.8))
                    )
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 20)
        }
        .frame(width: 280)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(white: 0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                )
        )
        .shadow(color: .black.opacity(0.4), radius: 30, y: 15)
        .offset(
            x: panelPosition.width + dragOffset.width,
            y: panelPosition.height + dragOffset.height
        )
        .onAppear {
            // Set up escape key monitor
            escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                if event.keyCode == 53 { // Escape key
                    // Close any open dropdown first
                    if viewModel.activeFilterDropdown != .none {
                        withAnimation(.easeOut(duration: 0.15)) {
                            viewModel.dismissFilterDropdown()
                        }
                        return nil // Consume the event
                    }
                    // No dropdowns open - close the filter panel and consume event
                    viewModel.dismissFilterPanel()
                    return nil
                }
                return event
            }
        }
        .onDisappear {
            // Clean up escape key monitor
            if let monitor = escapeMonitor {
                NSEvent.removeMonitor(monitor)
                escapeMonitor = nil
            }
        }
    }
}

// MARK: - Filter Dropdown Overlay

/// Renders filter dropdowns at the top level of SimpleTimelineView to avoid clipping issues
/// The dropdowns are positioned absolutely based on the anchor frame from the ViewModel
/// Using the "timelineContent" coordinate space for proper alignment
struct FilterDropdownOverlay: View {
    @ObservedObject var viewModel: SimpleTimelineViewModel

    var body: some View {
        Group {
            if viewModel.activeFilterDropdown != .none {
                let anchor = viewModel.filterDropdownAnchorFrame
                let _ = print("[FilterDropdownOverlay] Rendering dropdown=\(viewModel.activeFilterDropdown), anchor=\(anchor)")

                ZStack {
                    // Full-screen dismiss layer (below dropdown)
                    Color.black.opacity(0.001)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(.easeOut(duration: 0.15)) {
                                viewModel.dismissFilterDropdown()
                            }
                        }

                    // Use VStack with Spacer to position dropdown at the correct Y
                    // Then use HStack with Spacer to position at the correct X
                    VStack(spacing: 0) {
                        // Top spacer to push content down to anchor.maxY + gap
                        Spacer()
                            .frame(height: anchor.maxY + 8)

                        HStack(spacing: 0) {
                            // Left spacer to push content to anchor.minX
                            Spacer()
                                .frame(width: anchor.minX)

                            // The actual dropdown content
                            // Scroll events are handled at TimelineWindowController level
                            dropdownContent
                                .background(
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(Color(white: 0.12))
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .shadow(color: .black.opacity(0.5), radius: 15, y: 8)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(Color.white.opacity(0.15), lineWidth: 1)
                                )
                                .fixedSize()

                            Spacer()
                        }

                        Spacer()
                    }
                }
                .transition(.opacity)
                .zIndex(2000)
            }
        }
        .animation(.easeOut(duration: 0.15), value: viewModel.activeFilterDropdown)
    }

    @ViewBuilder
    private var dropdownContent: some View {
        switch viewModel.activeFilterDropdown {
        case .apps:
            AppsFilterPopover(
                apps: viewModel.availableAppsForFilter,
                otherApps: viewModel.otherAppsForFilter,
                selectedApps: viewModel.pendingFilterCriteria.selectedApps,
                allowMultiSelect: true,
                onSelectApp: { bundleID in
                    if let bundleID = bundleID {
                        viewModel.toggleAppFilter(bundleID)
                    } else {
                        viewModel.pendingFilterCriteria.selectedApps = nil
                    }
                }
            )
        case .tags:
            TagsFilterPopover(
                tags: viewModel.availableTags,
                selectedTags: viewModel.pendingFilterCriteria.selectedTags,
                allowMultiSelect: true,
                onSelectTag: { tagId in
                    if let tagId = tagId {
                        viewModel.toggleTagFilter(tagId)
                    } else {
                        viewModel.pendingFilterCriteria.selectedTags = nil
                    }
                }
            )
        case .visibility:
            VisibilityFilterPopover(
                currentFilter: viewModel.pendingFilterCriteria.hiddenFilter,
                onSelect: { filter in
                    viewModel.setHiddenFilter(filter)
                },
                onDismiss: {
                    withAnimation(.easeOut(duration: 0.15)) {
                        viewModel.dismissFilterDropdown()
                    }
                }
            )
        case .none:
            EmptyView()
        }
    }
}

// MARK: - Filter Toggle Chip

/// Toggle chip for source filters (Retrace/Rewind)
/// Styled similar to Relevant/All tabs in search dialog - white accent instead of blue
struct FilterToggleChip: View {
    let label: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12))

                Text(label)
                    .font(.system(size: 13, weight: isSelected ? .bold : .medium))
            }
            .foregroundColor(isSelected ? .white : .white.opacity(0.6))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? Color.white.opacity(0.2) : (isHovered ? Color.white.opacity(0.1) : Color.clear))
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovered = hovering
            }
            if hovering { NSCursor.pointingHand.push() }
            else { NSCursor.pop() }
        }
    }
}

// MARK: - Filter Dropdown Button

/// Dropdown button for Apps/Tags selection
struct FilterDropdownButton: View {
    let label: String
    let icon: String
    let isActive: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: icon)
                        .font(.system(size: 13))
                        .foregroundColor(isActive ? .white : .white.opacity(0.5))

                    Text(label)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(isActive ? .white : .white.opacity(0.7))
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.3))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isActive ? RetraceMenuStyle.actionBlue.opacity(0.15) : Color.white.opacity(isHovered ? 0.1 : 0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isActive ? RetraceMenuStyle.actionBlue.opacity(0.3) : Color.white.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovered = hovering
            }
            if hovering { NSCursor.pointingHand.push() }
            else { NSCursor.pop() }
        }
    }
}

// MARK: - Preview

#if DEBUG
struct SimpleTimelineView_Previews: PreviewProvider {
    static var previews: some View {
        let coordinator = AppCoordinator()
        SimpleTimelineView(
            coordinator: coordinator,
            viewModel: SimpleTimelineViewModel(coordinator: coordinator),
            onClose: {}
        )
        .frame(width: 1920, height: 1080)
    }
}
#endif
