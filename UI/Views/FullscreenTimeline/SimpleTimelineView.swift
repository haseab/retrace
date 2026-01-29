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

                // Debug frame ID badge, OCR status indicator, and developer actions menu (top-left)
                VStack {
                    HStack(spacing: 8) {
                        if viewModel.showFrameIDs {
                            DebugFrameIDBadge(viewModel: viewModel)
                        }
                        // OCR status indicator (only visible when OCR is in progress)
                        OCRStatusIndicator(viewModel: viewModel)
                        #if DEBUG
                        DeveloperActionsMenu(viewModel: viewModel)
                        #endif
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

                // Peek mode banner (top center, below reset zoom if both visible)
                if viewModel.isPeeking {
                    VStack {
                        PeekModeBanner(viewModel: viewModel)
                            .padding(.top, viewModel.isFrameZoomed ? 60 : 12) // Below reset zoom button if visible
                        Spacer()
                            .allowsHitTesting(false)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.spacingL)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .animation(.spring(response: 0.3, dampingFraction: 0.8), value: viewModel.isPeeking)
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

                // Search overlay (Cmd+K) - uses persistent searchViewModel to preserve results
                searchOverlay

                // Search highlight overlay
                searchHighlightOverlay(containerSize: geometry.size, actualFrameRect: actualFrameRect)

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
                                withAnimation(.easeOut(duration: 0.15)) {
                                    viewModel.dismissFilterPanel()
                                }
                            }
                        }

                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            FilterPanel(viewModel: viewModel)
                        }

                    }
                    .padding(.trailing, TimelineScaleFactor.rightControlsXOffset + 20)
                    .padding(.bottom, TimelineScaleFactor.tapeBottomPadding + TimelineScaleFactor.tapeHeight + 75)
                    .transition(.opacity.combined(with: .offset(y: 15)))

                    // Filter dropdowns - rendered at top level to avoid clipping issues
                    FilterDropdownOverlay(viewModel: viewModel)
                }

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

    // MARK: - Search Overlay

    @ViewBuilder
    private var searchOverlay: some View {
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
    }

    @ViewBuilder
    private func searchHighlightOverlay(containerSize: CGSize, actualFrameRect: CGRect) -> some View {
        if viewModel.isShowingSearchHighlight {
            SearchHighlightOverlay(
                viewModel: viewModel,
                containerSize: containerSize,
                actualFrameRect: actualFrameRect
            )
            .scaleEffect(viewModel.frameZoomScale)
            .offset(viewModel.frameZoomOffset)
        }
    }

    // MARK: - Frame Display

    @ViewBuilder
    private var frameDisplay: some View {
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

            if fileReady {
                FrameWithURLOverlay(viewModel: viewModel, onURLClicked: onClose) {
                    SimpleVideoFrameView(videoInfo: videoInfo, forceReload: .init(
                        get: { viewModel.forceVideoReload },
                        set: { viewModel.forceVideoReload = $0 }
                    ))
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
            SpinnerView(size: 32, lineWidth: 3, color: .white)
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

// MARK: - Peek Mode Banner

/// Banner shown when viewing full timeline context (peek mode)
/// Indicates filters are temporarily suspended and provides quick return action
struct PeekModeBanner: View {
    @ObservedObject var viewModel: SimpleTimelineViewModel
    @State private var isHovering = false

    private var scale: CGFloat { TimelineScaleFactor.current }

    var body: some View {
        HStack(spacing: 12 * scale) {
            // Eye icon to indicate "viewing"
            Image(systemName: "eye.fill")
                .font(.system(size: 16 * scale, weight: .medium))
                .foregroundColor(.white.opacity(0.9))

            // Message
            Text("Viewing full timeline")
                .font(.system(size: 15 * scale, weight: .medium))
                .foregroundColor(.white.opacity(0.9))

            // Separator
            Rectangle()
                .fill(Color.white.opacity(0.3))
                .frame(width: 1, height: 16 * scale)

            // Return button
            Button(action: {
                viewModel.exitPeek()
            }) {
                HStack(spacing: 6 * scale) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 13 * scale, weight: .semibold))
                    Text("Return to filtered view")
                        .font(.system(size: 14 * scale, weight: .medium))
                }
                .foregroundColor(isHovering ? .white : .white.opacity(0.85))
                .padding(.horizontal, 12 * scale)
                .padding(.vertical, 6 * scale)
                .background(
                    Capsule()
                        .fill(Color.white.opacity(isHovering ? 0.25 : 0.15))
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

            // Keyboard hint
            Text("Esc")
                .font(.system(size: 11 * scale, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.5))
                .padding(.horizontal, 6 * scale)
                .padding(.vertical, 3 * scale)
                .background(
                    RoundedRectangle(cornerRadius: 4 * scale)
                        .fill(Color.white.opacity(0.1))
                )
        }
        .padding(.horizontal, 16 * scale)
        .padding(.vertical, 10 * scale)
        .background(
            Capsule()
                .fill(Color.black.opacity(0.6))
                .background(
                    Capsule()
                        .fill(.ultraThinMaterial)
                )
                .clipShape(Capsule())
        )
        .overlay(
            Capsule()
                .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
        )
    }
}

// MARK: - Simple Video Frame View

/// Double-buffered video frame view using two AVPlayers
/// Eliminates black flash when crossing video boundaries by preloading the next video
/// in a hidden player and swapping visibility once ready
struct SimpleVideoFrameView: NSViewRepresentable {
    let videoInfo: FrameVideoInfo
    @Binding var forceReload: Bool

    func makeNSView(context: Context) -> DoubleBufferedVideoView {
        let containerView = DoubleBufferedVideoView()
        return containerView
    }

    func updateNSView(_ containerView: DoubleBufferedVideoView, context: Context) {
        let isWindowVisible = containerView.window?.isVisible ?? false
        let needsForceReload = forceReload

        // If forceReload is set, clear the cached path to trigger a full video reload
        if needsForceReload {
            context.coordinator.currentVideoPath = nil
            context.coordinator.currentFrameIndex = nil
            DispatchQueue.main.async {
                self.forceReload = false
            }
        }

        let effectivePath = context.coordinator.currentVideoPath
        let effectiveFrameIdx = context.coordinator.currentFrameIndex

        // If same video and same frame, nothing to do
        if effectivePath == videoInfo.videoPath && effectiveFrameIdx == videoInfo.frameIndex {
            return
        }

        // Only update coordinator state if window is visible
        if isWindowVisible {
            context.coordinator.currentFrameIndex = videoInfo.frameIndex
        }

        // If same video, just seek on the active player (fast path)
        if effectivePath == videoInfo.videoPath {
            let time = videoInfo.frameTimeCMTime
            containerView.seekActivePlayer(to: time)
            return
        }

        Log.debug("[VideoView] Loading new video: \(videoInfo.videoPath.suffix(30))", category: .ui)

        // Different video - use double-buffering
        context.coordinator.currentVideoPath = videoInfo.videoPath

        // Resolve actual video path
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

        // Get URL (with symlink if needed for extensionless files)
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
                    Log.error("[SimpleVideoFrameView] Failed to create symlink: \(error)", category: .app)
                    return
                }
            }
            url = URL(fileURLWithPath: symlinkPath)
        }

        // Load video into buffer player and swap when ready
        let targetTime = videoInfo.frameTimeCMTime
        let targetFrameIndex = videoInfo.frameIndex
        containerView.loadVideoIntoBuffer(url: url, seekTime: targetTime, frameIndex: targetFrameIndex)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator {
        var currentVideoPath: String?
        var currentFrameIndex: Int?
    }
}

// MARK: - Double Buffered Video View

/// Container view with two AVPlayerViews for seamless video transitions
/// One player is always visible (active), the other loads in the background (buffer)
/// When the buffer is ready, they swap roles
class DoubleBufferedVideoView: NSView {
    private var playerViewA: AVPlayerView!
    private var playerViewB: AVPlayerView!
    private var playerA: AVPlayer!
    private var playerB: AVPlayer!

    /// Which player is currently visible (true = A, false = B)
    private var isPlayerAActive = true

    /// Observers for player item status
    private var observerA: NSKeyValueObservation?
    private var observerB: NSKeyValueObservation?

    /// Generation counter to invalidate stale async callbacks
    /// Incremented each time a new load is initiated
    private var loadGeneration: UInt64 = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupPlayers()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupPlayers()
    }

    private func setupPlayers() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        // Create player A
        playerViewA = createPlayerView()
        playerA = AVPlayer()
        playerA.actionAtItemEnd = .pause
        playerViewA.player = playerA

        // Create player B
        playerViewB = createPlayerView()
        playerB = AVPlayer()
        playerB.actionAtItemEnd = .pause
        playerViewB.player = playerB

        // Add both to view hierarchy
        addSubview(playerViewA)
        addSubview(playerViewB)

        // Initially A is visible, B is hidden
        playerViewA.isHidden = false
        playerViewB.isHidden = true

        // Setup constraints for both
        setupConstraints(for: playerViewA)
        setupConstraints(for: playerViewB)
    }

    private func createPlayerView() -> AVPlayerView {
        let playerView = AVPlayerView()
        playerView.controlsStyle = .none
        playerView.showsFrameSteppingButtons = false
        playerView.showsSharingServiceButton = false
        playerView.showsFullScreenToggleButton = false
        playerView.wantsLayer = true
        playerView.layer?.backgroundColor = NSColor.black.cgColor

        if #available(macOS 13.0, *) {
            playerView.allowsVideoFrameAnalysis = false
        }

        return playerView
    }

    private func setupConstraints(for playerView: AVPlayerView) {
        playerView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            playerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            playerView.topAnchor.constraint(equalTo: topAnchor),
            playerView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    /// Seek the currently active player to a specific time
    func seekActivePlayer(to time: CMTime) {
        let activePlayer = isPlayerAActive ? playerA : playerB
        activePlayer?.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Load a video into the buffer player and swap when ready
    func loadVideoIntoBuffer(url: URL, seekTime: CMTime, frameIndex: Int) {
        // Increment generation to invalidate any pending async callbacks
        loadGeneration &+= 1
        let currentGeneration = loadGeneration

        let bufferPlayer = isPlayerAActive ? playerB : playerA
        let bufferObserver = isPlayerAActive ? observerB : observerA

        // Capture which player should become active after this load completes
        let expectedActiveAfterSwap = !isPlayerAActive

        // Clear previous observer
        bufferObserver?.invalidate()

        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let playerItem = AVPlayerItem(asset: asset)

        bufferPlayer?.replaceCurrentItem(with: playerItem)

        Log.debug("[VideoView] Starting load gen=\(currentGeneration) for frame \(frameIndex), buffer=\(isPlayerAActive ? "B" : "A")", category: .ui)

        // Observe when buffer player is ready
        let observer = playerItem.observe(\.status, options: [.new, .initial]) { [weak self] item, _ in
            guard let self = self else { return }

            // Check if this load is still valid (no newer load has started)
            guard currentGeneration == self.loadGeneration else {
                Log.debug("[VideoView] Ignoring stale status callback gen=\(currentGeneration), current=\(self.loadGeneration)", category: .ui)
                return
            }

            Log.debug("[VideoView] Buffer player status: \(item.status.rawValue) for frame \(frameIndex) gen=\(currentGeneration)", category: .ui)

            if item.status == .failed {
                Log.error("[VideoView] Buffer player FAILED: \(item.error?.localizedDescription ?? "unknown")", category: .ui)
                return
            }

            guard item.status == .readyToPlay else { return }

            // Seek to target frame
            bufferPlayer?.seek(to: seekTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
                guard let self = self, finished else { return }

                // Re-check generation after async seek completes
                guard currentGeneration == self.loadGeneration else {
                    Log.debug("[VideoView] Ignoring stale seek callback gen=\(currentGeneration), current=\(self.loadGeneration)", category: .ui)
                    return
                }

                Log.debug("[VideoView] Buffer ready, swapping players for frame \(frameIndex) gen=\(currentGeneration)", category: .ui)

                DispatchQueue.main.async {
                    // Final generation check on main thread before swap
                    guard currentGeneration == self.loadGeneration else {
                        Log.debug("[VideoView] Ignoring stale swap gen=\(currentGeneration), current=\(self.loadGeneration)", category: .ui)
                        return
                    }

                    // Verify we're swapping to the expected player
                    // If state drifted (shouldn't happen with generation check, but safety first)
                    guard self.isPlayerAActive != expectedActiveAfterSwap else {
                        Log.debug("[VideoView] Player already in expected state, skipping swap", category: .ui)
                        return
                    }

                    bufferPlayer?.pause()
                    self.swapPlayers()
                }
            }
        }

        // Store observer
        if isPlayerAActive {
            observerB = observer
        } else {
            observerA = observer
        }
    }

    /// Swap which player is visible
    private func swapPlayers() {
        let activePlayerView = isPlayerAActive ? playerViewA : playerViewB
        let bufferPlayerView = isPlayerAActive ? playerViewB : playerViewA
        let oldActivePlayer = isPlayerAActive ? playerA : playerB

        // Show buffer (now becomes active)
        bufferPlayerView?.isHidden = false

        // Hide old active (now becomes buffer)
        activePlayerView?.isHidden = true

        // Clear the old active player's item to free memory
        oldActivePlayer?.replaceCurrentItem(with: nil)

        // Swap roles
        isPlayerAActive.toggle()

        Log.debug("[VideoView] Players swapped, now active: \(isPlayerAActive ? "A" : "B")", category: .ui)
    }

    deinit {
        observerA?.invalidate()
        observerB?.invalidate()
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

/// A pure blur view that blurs content behind it using behindWindow blending
struct PureBlurView: NSViewRepresentable {
    let radius: CGFloat

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
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
        blurView.blendingMode = .behindWindow
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

        // Lighter blue for text selection highlight
        let selectionColor = NSColor(red: 100/255, green: 160/255, blue: 230/255, alpha: 0.4)

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
/// Highlights selected text character-by-character using Retrace brand color
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
    private var isShowingIBeamCursor = false  // Track cursor state to avoid redundant push/pop

    /// Padding in screen points to expand hit area around OCR bounding boxes
    /// This makes it easier to start selection from slightly outside the text
    private let boundingBoxPadding: CGFloat = 8.0

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

    override func mouseMoved(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        updateCursorForLocation(location)
    }

    override func mouseExited(with event: NSEvent) {
        // Reset cursor when leaving the view
        if isShowingIBeamCursor {
            NSCursor.pop()
            isShowingIBeamCursor = false
        }
    }

    /// Check if a screen point is near any OCR bounding box (within padding tolerance)
    private func isNearAnyNode(screenPoint: CGPoint) -> Bool {
        for node in nodeData {
            // Expand the rect by padding on all sides
            let expandedRect = node.rect.insetBy(dx: -boundingBoxPadding, dy: -boundingBoxPadding)
            if expandedRect.contains(screenPoint) {
                return true
            }
        }
        return false
    }

    /// Update cursor based on whether we're near an OCR bounding box
    private func updateCursorForLocation(_ location: CGPoint) {
        let isNearNode = isNearAnyNode(screenPoint: location)

        if isNearNode && !isShowingIBeamCursor {
            // Entering text area - show IBeam cursor
            NSCursor.iBeam.push()
            isShowingIBeamCursor = true
        } else if !isNearNode && isShowingIBeamCursor {
            // Leaving text area - restore normal cursor
            NSCursor.pop()
            isShowingIBeamCursor = false
        }
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

        // Lighter blue for text selection highlight
        let selectionColor = NSColor(red: 100/255, green: 160/255, blue: 230/255, alpha: 0.4)

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
/// Only visible when "Show frame IDs in UI" is enabled in Settings > Advanced
struct DebugFrameIDBadge: View {
    @ObservedObject var viewModel: SimpleTimelineViewModel
    @State private var showCopiedFeedback = false
    @State private var isHovering = false

    var body: some View {
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
    }
}

// MARK: - OCR Status Indicator

/// Shows the OCR processing status for the current frame
/// Displays when OCR is pending, queued, or processing (not shown when completed)
struct OCRStatusIndicator: View {
    @ObservedObject var viewModel: SimpleTimelineViewModel
    @State private var rotationAngle: Double = 0

    /// Whether the indicator should be visible
    /// Only shows for in-progress states (pending, queued, processing)
    private var shouldShow: Bool {
        viewModel.ocrStatus.isInProgress
    }

    /// Icon for the current status
    private var statusIcon: String {
        switch viewModel.ocrStatus.state {
        case .pending:
            return "clock"
        case .queued:
            return "tray.and.arrow.down"
        case .processing:
            return "gearshape.2"
        default:
            return "doc.text"
        }
    }

    /// Color for the current status
    private var statusColor: Color {
        switch viewModel.ocrStatus.state {
        case .pending:
            return .gray
        case .queued:
            return .orange
        case .processing:
            return .blue
        case .failed:
            return .red
        default:
            return .gray
        }
    }

    var body: some View {
        if shouldShow {
            HStack(spacing: 6) {
                // Icon with rotation animation for processing state
                Image(systemName: statusIcon)
                    .font(.retraceTinyMedium)
                    .foregroundColor(statusColor)
                    .rotationEffect(.degrees(viewModel.ocrStatus.state == .processing ? rotationAngle : 0))
                    .onAppear {
                        if viewModel.ocrStatus.state == .processing {
                            withAnimation(.linear(duration: 2).repeatForever(autoreverses: false)) {
                                rotationAngle = 360
                            }
                        }
                    }
                    .onChange(of: viewModel.ocrStatus) { newStatus in
                        if newStatus.state == .processing {
                            rotationAngle = 0
                            withAnimation(.linear(duration: 2).repeatForever(autoreverses: false)) {
                                rotationAngle = 360
                            }
                        } else {
                            rotationAngle = 0
                        }
                    }

                Text(viewModel.ocrStatus.displayText)
                    .font(.retraceTinyMedium)
                    .foregroundColor(.white.opacity(0.8))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(white: 0.15).opacity(0.9))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(statusColor.opacity(0.4), lineWidth: 0.5)
            )
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
            .animation(.easeInOut(duration: 0.2), value: viewModel.ocrStatus)
        }
    }
}

// MARK: - Developer Actions Menu

#if DEBUG
/// Developer actions menu with OCR refresh and video boundary visualization options
/// Only visible in DEBUG builds, positioned in top-left corner beside the frame ID badge
struct DeveloperActionsMenu: View {
    @ObservedObject var viewModel: SimpleTimelineViewModel
    @State private var isHovering = false
    @State private var showReprocessFeedback = false

    /// Whether the current frame can be reprocessed (only Retrace frames)
    private var canReprocess: Bool {
        viewModel.currentFrame?.source == .native
    }

    var body: some View {
        Menu {
            // Refresh OCR button
            Button(action: {
                Task {
                    do {
                        try await viewModel.reprocessCurrentFrameOCR()
                        showReprocessFeedback = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            showReprocessFeedback = false
                        }
                    } catch {
                        Log.error("[OCR] Failed to reprocess OCR: \(error)", category: .ui)
                    }
                }
            }) {
                Label(
                    showReprocessFeedback ? "Queued" : "Refresh OCR",
                    systemImage: showReprocessFeedback ? "checkmark" : "arrow.clockwise"
                )
            }
            .disabled(!canReprocess)

            Divider()

            // Show Video Placements toggle
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    viewModel.showVideoBoundaries.toggle()
                }
            }) {
                HStack {
                    Label("Show Video Placements", systemImage: "film")
                    if viewModel.showVideoBoundaries {
                        Spacer()
                        Image(systemName: "checkmark")
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "ant.fill")
                    .font(.retraceTinyMedium)
                    .foregroundColor(.orange)
                Text("Dev")
                    .font(.retraceTinyMedium)
                    .foregroundColor(.orange)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(white: 0.15).opacity(0.9))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isHovering ? Color.orange.opacity(0.5) : Color.white.opacity(0.15), lineWidth: 0.5)
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .onHover { hovering in
            isHovering = hovering
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}
#endif

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
            guard let window = event.window else { return event }

            // Get click location in window coordinates (origin at bottom-left of window)
            let windowLocation = event.locationInWindow

            // Convert to SwiftUI's global coordinate space (origin at top-left of window)
            // SwiftUI's global Y increases downward, NSWindow's Y increases upward
            let swiftUILocation = CGPoint(
                x: windowLocation.x,
                y: window.frame.height - windowLocation.y
            )

            // Check if click is within our view bounds (in SwiftUI global coordinates)
            if viewBounds.contains(swiftUILocation) {
                // Convert to view-local coordinates
                let localX = swiftUILocation.x - viewBounds.minX
                let localY = swiftUILocation.y - viewBounds.minY

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
                                        .foregroundStyle(LinearGradient.retraceAccentGradient)

                                    Text("Create \"\(searchText.trimmingCharacters(in: .whitespacesAndNewlines))\"")
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(LinearGradient.retraceAccentGradient)

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
                        .foregroundColor(.white)
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
/// Shared UserDefaults store for accessing settings
private let filterPanelSettingsStore = UserDefaults(suiteName: "io.retrace.app")

struct FilterPanel: View {
    @ObservedObject var viewModel: SimpleTimelineViewModel
    @GestureState private var dragOffset: CGSize = .zero
    @State private var panelPosition: CGSize = .zero
    @State private var escapeMonitor: Any?

    /// Whether colored borders are enabled
    private var showColoredBorders: Bool {
        filterPanelSettingsStore?.bool(forKey: "timelineColoredBorders") ?? true
    }

    /// Border color based on user's color theme (or neutral if disabled)
    private var themeBorderColor: Color {
        showColoredBorders ? MilestoneCelebrationManager.getCurrentTheme().controlBorderColor : Color.white.opacity(0.15)
    }

    /// Label for apps filter chip (uses pending criteria)
    private var appsLabel: String {
        guard let selected = viewModel.pendingFilterCriteria.selectedApps, !selected.isEmpty else {
            return "All Apps"
        }
        let isExclude = viewModel.pendingFilterCriteria.appFilterMode == .exclude
        let prefix = isExclude ? "Exclude: " : ""

        if selected.count == 1, let bundleID = selected.first,
           let app = viewModel.availableAppsForFilter.first(where: { $0.bundleID == bundleID }) {
            return prefix + app.name
        }
        return prefix + "\(selected.count) Apps"
    }

    /// Whether apps filter is in exclude mode
    private var isAppsExcludeMode: Bool {
        viewModel.pendingFilterCriteria.appFilterMode == .exclude &&
        viewModel.pendingFilterCriteria.selectedApps != nil &&
        !viewModel.pendingFilterCriteria.selectedApps!.isEmpty
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

    /// Label for date range filter
    private var dateRangeLabel: String {
        let startDate = viewModel.pendingFilterCriteria.startDate
        let endDate = viewModel.pendingFilterCriteria.endDate
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"

        if let start = startDate, let end = endDate {
            return "\(formatter.string(from: start)) - \(formatter.string(from: end))"
        } else if let start = startDate {
            return "From \(formatter.string(from: start))"
        } else if let end = endDate {
            return "Until \(formatter.string(from: end))"
        }
        return "Any Time"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("Filter Timeline")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)

                Spacer()

                Button(action: {
                    withAnimation(.easeOut(duration: 0.15)) {
                        viewModel.dismissFilterPanel()
                    }
                }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white.opacity(0.4))
                        .frame(width: 22, height: 22)
                        .background(Color.white.opacity(0.1))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 12)
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

            // Source section (compact)
            VStack(alignment: .leading, spacing: 8) {
                Text("SOURCE")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.4))
                    .tracking(0.5)

                HStack(spacing: 8) {
                    let sources = viewModel.pendingFilterCriteria.selectedSources
                    // Default to only Retrace selected (nil means only native)
                    let retraceSelected = sources == nil || sources!.contains(.native)
                    let rewindSelected = sources != nil && sources!.contains(.rewind)

                    SourceFilterChip(
                        label: "Retrace",
                        isRetrace: true,
                        isSelected: retraceSelected
                    ) {
                        viewModel.toggleSourceFilter(.native)
                    }

                    SourceFilterChip(
                        label: "Rewind",
                        isRetrace: false,
                        isSelected: rewindSelected
                    ) {
                        viewModel.toggleSourceFilter(.rewind)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)

            // Divider
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)
                .padding(.horizontal, 16)

            // Two-column grid for Apps, Tags, Visibility, Date Range
            HStack(alignment: .top, spacing: 12) {
                // Left column: Apps and Visibility
                VStack(alignment: .leading, spacing: 12) {
                    // Apps
                    CompactAppsFilterDropdown(
                        label: "APPS",
                        selectedApps: viewModel.pendingFilterCriteria.selectedApps,
                        isExcludeMode: viewModel.pendingFilterCriteria.appFilterMode == .exclude
                    ) { frame in
                        withAnimation(.easeOut(duration: 0.15)) {
                            if viewModel.activeFilterDropdown == .apps {
                                viewModel.dismissFilterDropdown()
                            } else {
                                viewModel.showFilterDropdown(.apps, anchorFrame: frame)
                            }
                        }
                    }

                    // Visibility
                    CompactFilterDropdown(
                        label: "VISIBILITY",
                        value: hiddenFilterLabel,
                        icon: "eye",
                        isActive: viewModel.pendingFilterCriteria.hiddenFilter != .hide
                    ) { frame in
                        withAnimation(.easeOut(duration: 0.15)) {
                            if viewModel.activeFilterDropdown == .visibility {
                                viewModel.dismissFilterDropdown()
                            } else {
                                viewModel.showFilterDropdown(.visibility, anchorFrame: frame)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity)

                // Right column: Tags and Date Range
                VStack(alignment: .leading, spacing: 12) {
                    // Tags
                    CompactFilterDropdown(
                        label: "TAGS",
                        value: tagsLabel,
                        icon: "tag",
                        isActive: viewModel.pendingFilterCriteria.selectedTags != nil && !viewModel.pendingFilterCriteria.selectedTags!.isEmpty
                    ) { frame in
                        withAnimation(.easeOut(duration: 0.15)) {
                            if viewModel.activeFilterDropdown == .tags {
                                viewModel.dismissFilterDropdown()
                            } else {
                                viewModel.showFilterDropdown(.tags, anchorFrame: frame)
                            }
                        }
                    }

                    // Date Range
                    CompactFilterDropdown(
                        label: "DATE",
                        value: dateRangeLabel,
                        icon: "calendar",
                        isActive: viewModel.pendingFilterCriteria.startDate != nil || viewModel.pendingFilterCriteria.endDate != nil
                    ) { frame in
                        withAnimation(.easeOut(duration: 0.15)) {
                            if viewModel.activeFilterDropdown == .dateRange {
                                viewModel.dismissFilterDropdown()
                            } else {
                                viewModel.showFilterDropdown(.dateRange, anchorFrame: frame)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 12)

            // Divider
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)
                .padding(.horizontal, 16)

            // Advanced filters section (collapsible)
            AdvancedFiltersSection(viewModel: viewModel)

            // Divider before apply button
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)
                .padding(.horizontal, 16)

            // Action buttons
            HStack(spacing: 10) {
                // Clear button (only when pending filters are active)
                if viewModel.pendingFilterCriteria.hasActiveFilters {
                    Button(action: { viewModel.clearPendingFilters() }) {
                        Text("Clear")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white.opacity(0.7))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.white.opacity(0.1))
                            )
                    }
                    .buttonStyle(.plain)
                }

                // Apply button
                Button(action: {
                    withAnimation(.easeOut(duration: 0.15)) {
                        viewModel.applyFilters()
                    }
                }) {
                    Text("Apply Filters")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(RetraceMenuStyle.actionBlue.opacity(0.8))
                        )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 14)
        }
        .frame(width: 360)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(white: 0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(themeBorderColor, lineWidth: 1)
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
                    withAnimation(.easeOut(duration: 0.15)) {
                        viewModel.dismissFilterPanel()
                    }
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

// MARK: - Advanced Filters Section

/// Collapsible section for advanced text filters (Window Name and Browser URL)
struct AdvancedFiltersSection: View {
    @ObservedObject var viewModel: SimpleTimelineViewModel
    @State private var isExpanded: Bool = false

    /// Whether any advanced filter is active
    private var hasActiveAdvancedFilters: Bool {
        viewModel.pendingFilterCriteria.hasAdvancedFilters
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Toggle header
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            }) {
                HStack {
                    Text("ADVANCED")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white.opacity(0.4))
                        .tracking(0.5)

                    if hasActiveAdvancedFilters {
                        Circle()
                            .fill(RetraceMenuStyle.actionBlue)
                            .frame(width: 6, height: 6)
                    }

                    Spacer()

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white.opacity(0.4))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, isExpanded ? 8 : 12)

            if isExpanded {
                VStack(alignment: .leading, spacing: 12) {
                    // Window Name filter
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Window Name")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white.opacity(0.6))

                        TextField("Search titles...", text: Binding(
                            get: { viewModel.pendingFilterCriteria.windowNameFilter ?? "" },
                            set: { viewModel.pendingFilterCriteria.windowNameFilter = $0.isEmpty ? nil : $0 }
                        ))
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundColor(.white)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 9)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.white.opacity(0.08))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(
                                    viewModel.pendingFilterCriteria.windowNameFilter != nil && !viewModel.pendingFilterCriteria.windowNameFilter!.isEmpty
                                        ? RetraceMenuStyle.actionBlue.opacity(0.5)
                                        : Color.white.opacity(0.1),
                                    lineWidth: 1
                                )
                        )
                        .onSubmit {
                            viewModel.applyFilters()
                        }
                    }

                    // Browser URL filter
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Browser URL")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white.opacity(0.6))

                        TextField("Search URLs...", text: Binding(
                            get: { viewModel.pendingFilterCriteria.browserUrlFilter ?? "" },
                            set: { viewModel.pendingFilterCriteria.browserUrlFilter = $0.isEmpty ? nil : $0 }
                        ))
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundColor(.white)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 9)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.white.opacity(0.08))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(
                                    viewModel.pendingFilterCriteria.browserUrlFilter != nil && !viewModel.pendingFilterCriteria.browserUrlFilter!.isEmpty
                                        ? RetraceMenuStyle.actionBlue.opacity(0.5)
                                        : Color.white.opacity(0.1),
                                    lineWidth: 1
                                )
                        )
                        .onSubmit {
                            viewModel.applyFilters()
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
            }
        }
        .onAppear {
            // Auto-expand if there are active advanced filters
            if hasActiveAdvancedFilters {
                isExpanded = true
            }
        }
    }
}

// MARK: - Compact Filter Components

/// Compact filter dropdown for two-column layout
struct CompactFilterDropdown: View {
    let label: String
    let value: String
    let icon: String
    let isActive: Bool
    let onTap: (CGRect) -> Void

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white.opacity(0.4))
                .tracking(0.5)

            GeometryReader { geo in
                let localFrame = geo.frame(in: .named("timelineContent"))
                Button(action: { onTap(localFrame) }) {
                    HStack(spacing: 7) {
                        Image(systemName: icon)
                            .font(.system(size: 11))
                            .foregroundColor(isActive ? .white : .white.opacity(0.5))

                        Text(value)
                            .font(.system(size: 12))
                            .foregroundColor(isActive ? .white : .white.opacity(0.9))
                            .lineLimit(1)

                        Spacer(minLength: 2)

                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(.white.opacity(0.4))
                    }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(isActive ? Color.white.opacity(0.15) : (isHovered ? Color.white.opacity(0.12) : Color.white.opacity(0.08)))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.white.opacity(isActive ? 0.25 : 0.1), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    withAnimation(.easeInOut(duration: 0.1)) {
                        isHovered = hovering
                    }
                }
            }
            .frame(height: 38)
        }
    }
}

/// Compact apps filter dropdown with app icons (matches search dialog behavior)
struct CompactAppsFilterDropdown: View {
    let label: String
    let selectedApps: Set<String>?
    let isExcludeMode: Bool
    let onTap: (CGRect) -> Void

    @State private var isHovered = false

    private let maxVisibleIcons = 5
    private let iconSize: CGFloat = 18

    private var sortedApps: [String] {
        guard let apps = selectedApps else { return [] }
        return apps.sorted()
    }

    private var isActive: Bool {
        selectedApps != nil && !selectedApps!.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white.opacity(0.4))
                .tracking(0.5)

            GeometryReader { geo in
                let localFrame = geo.frame(in: .named("timelineContent"))
                Button(action: { onTap(localFrame) }) {
                    HStack(spacing: 7) {
                        // Show exclude indicator
                        if isExcludeMode && isActive {
                            Image(systemName: "minus.circle.fill")
                                .font(.system(size: 11))
                                .foregroundColor(.orange)
                        }

                        if sortedApps.count == 1 {
                            // Single app: show icon + name
                            let bundleID = sortedApps[0]
                            appIcon(for: bundleID)
                                .frame(width: iconSize, height: iconSize)
                                .clipShape(RoundedRectangle(cornerRadius: 3))

                            Text(appName(for: bundleID))
                                .font(.system(size: 12))
                                .foregroundColor(.white)
                                .lineLimit(1)
                                .strikethrough(isExcludeMode, color: .orange)
                        } else if sortedApps.count > 1 {
                            // Multiple apps: show icons stacked
                            HStack(spacing: -4) {
                                ForEach(Array(sortedApps.prefix(maxVisibleIcons)), id: \.self) { bundleID in
                                    appIcon(for: bundleID)
                                        .frame(width: iconSize, height: iconSize)
                                        .clipShape(RoundedRectangle(cornerRadius: 3))
                                        .opacity(isExcludeMode ? 0.6 : 1.0)
                                }
                            }

                            // Show "+X" if more than maxVisibleIcons
                            if sortedApps.count > maxVisibleIcons {
                                Text("+\(sortedApps.count - maxVisibleIcons)")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(.white.opacity(0.8))
                            }
                        } else {
                            // Default state - no apps selected
                            Image(systemName: "square.grid.2x2")
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.5))

                            Text("All Apps")
                                .font(.system(size: 12))
                                .foregroundColor(.white.opacity(0.9))
                        }

                        Spacer(minLength: 2)

                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(.white.opacity(0.4))
                    }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(isActive ? Color.white.opacity(0.15) : (isHovered ? Color.white.opacity(0.12) : Color.white.opacity(0.08)))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.white.opacity(isActive ? 0.25 : 0.1), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    withAnimation(.easeInOut(duration: 0.1)) {
                        isHovered = hovering
                    }
                }
            }
            .frame(height: 38)
        }
    }

    @ViewBuilder
    private func appIcon(for bundleID: String) -> some View {
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: appURL.path))
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: "app.fill")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .foregroundColor(.white.opacity(0.6))
        }
    }

    private func appName(for bundleID: String) -> String {
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: appURL.path)
        }
        // Fallback: extract last component of bundle ID
        return bundleID.components(separatedBy: ".").last ?? bundleID
    }
}

/// Compact toggle chip for source filters
struct FilterToggleChipCompact: View {
    let label: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                Text(label)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(isSelected ? .white : .white.opacity(0.5))
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.white.opacity(0.15) : Color.white.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.white.opacity(0.2) : Color.white.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

/// Source filter chip with app logo (Retrace or Rewind)
struct SourceFilterChip: View {
    let label: String
    let isRetrace: Bool
    let isSelected: Bool
    let action: () -> Void

    private var retraceIcon: NSImage {
        // Load Retrace app icon from /Applications
        NSWorkspace.shared.icon(forFile: "/Applications/Retrace.app")
    }

    private var rewindIcon: NSImage? {
        // Load Rewind app icon from /Applications, fallback to nil (will use system icon)
        let rewindPath = "/Applications/Rewind.app"
        if FileManager.default.fileExists(atPath: rewindPath) {
            return NSWorkspace.shared.icon(forFile: rewindPath)
        }
        return nil
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if isRetrace {
                    // Retrace app icon from /Applications
                    Image(nsImage: retraceIcon)
                        .resizable()
                        .frame(width: 16, height: 16)
                } else {
                    // Rewind app icon - load from /Applications
                    if let icon = rewindIcon {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 16, height: 16)
                    } else {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 11))
                    }
                }
                Text(label)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(isSelected ? .white : .white.opacity(0.5))
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.white.opacity(0.15) : Color.white.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.white.opacity(0.2) : Color.white.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
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

                    // Date range dropdown opens upward, others open downward
                    if viewModel.activeFilterDropdown == .dateRange {
                        // Position dropdown above the anchor (opens upward)
                        VStack(spacing: 0) {
                            Spacer()

                            HStack(spacing: 0) {
                                Spacer()
                                    .frame(width: anchor.minX)

                                dropdownContent
                                    .background(
                                        RoundedRectangle(cornerRadius: 10)
                                            .fill(Color(white: 0.12))
                                    )
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                    .shadow(color: .black.opacity(0.5), radius: 15, y: -8)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10)
                                            .stroke(Color.white.opacity(0.15), lineWidth: 1)
                                    )
                                    .fixedSize()

                                Spacer()
                            }

                            // Bottom spacer to push content up above the anchor
                            Spacer()
                                .frame(height: max(0, NSScreen.main?.frame.height ?? 800) - anchor.minY + 8)
                        }
                    } else {
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
                filterMode: viewModel.pendingFilterCriteria.appFilterMode,
                allowMultiSelect: true,
                onSelectApp: { bundleID in
                    if let bundleID = bundleID {
                        viewModel.toggleAppFilter(bundleID)
                    } else {
                        print("[Filter] All Apps selected - clearing pendingFilterCriteria.selectedApps (was: \(String(describing: viewModel.pendingFilterCriteria.selectedApps)))")
                        viewModel.pendingFilterCriteria.selectedApps = nil
                        print("[Filter] After clearing: pendingFilterCriteria.selectedApps = \(String(describing: viewModel.pendingFilterCriteria.selectedApps))")
                    }
                },
                onFilterModeChange: { mode in
                    viewModel.setAppFilterMode(mode)
                }
            )
        case .tags:
            TagsFilterPopover(
                tags: viewModel.availableTags,
                selectedTags: viewModel.pendingFilterCriteria.selectedTags,
                filterMode: viewModel.pendingFilterCriteria.tagFilterMode,
                allowMultiSelect: true,
                onSelectTag: { tagId in
                    if let tagId = tagId {
                        viewModel.toggleTagFilter(tagId)
                    } else {
                        viewModel.pendingFilterCriteria.selectedTags = nil
                    }
                },
                onFilterModeChange: { mode in
                    viewModel.setTagFilterMode(mode)
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
        case .dateRange:
            DateRangeFilterPopover(
                startDate: viewModel.pendingFilterCriteria.startDate,
                endDate: viewModel.pendingFilterCriteria.endDate,
                onApply: { start, end in
                    viewModel.setDateRange(start: start, end: end)
                },
                onClear: {
                    viewModel.setDateRange(start: nil, end: nil)
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
