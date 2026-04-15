import Foundation
import SwiftUI
import AVKit
import Shared
import App

struct TimelineFrameCanvasLayer: View {
    @ObservedObject var viewModel: SimpleTimelineViewModel
    let onClose: () -> Void
    let containerSize: CGSize
    let actualFrameRect: CGRect
    let isAwaitingLiveScreenshot: Bool
    @Binding var liveScreenshotHasAppeared: Bool

    var body: some View {
        ZStack {
            frameCanvasContent

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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var frameCanvasContent: some View {
        if isAwaitingLiveScreenshot {
            Color.clear
        } else {
            ZStack {
                if liveScreenshotHasAppeared || !viewModel.isInLiveMode {
                    TimelineHistoricalFramePresentation(
                        viewModel: viewModel,
                        onClose: onClose
                    )
                }

                if viewModel.isInLiveMode, let liveImage = viewModel.liveScreenshot {
                    TimelineFrameSurface(viewModel: viewModel, onURLClicked: onClose) {
                        Image(nsImage: liveImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    }
                    .onAppear {
                        liveScreenshotHasAppeared = true
                    }
                }
            }
        }
    }
}

struct TimelineHistoricalFramePresentation: View {
    @ObservedObject var viewModel: SimpleTimelineViewModel
    let onClose: () -> Void

    var body: some View {
        if viewModel.frameLoadError {
            frameStatusPlaceholder(
                icon: "clock",
                title: "Come back in a few frames",
                subtitle: "This frame is still being processed"
            )
        } else if viewModel.frameNotReady,
                  viewModel.displayableCurrentImage == nil,
                  viewModel.waitingVideoFallbackImage == nil {
            frameStatusPlaceholder(
                icon: "clock",
                title: "Frame not ready yet",
                subtitle: "Still encoding..."
            )
        } else if let videoInfo = viewModel.currentVideoInfo {
            timelineVideoFramePresentation(videoInfo)
        } else if let image = viewModel.displayableCurrentImage {
            frameStillContent(image, interactive: true)
        } else if !viewModel.isLoading {
            emptyState
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        let isFilteredEmptyState = viewModel.frames.isEmpty && viewModel.filterCriteria.hasActiveFilters
        VStack(spacing: .spacingM) {
            Image(systemName: isFilteredEmptyState ? "line.3.horizontal.decrease.circle" : (viewModel.frames.isEmpty ? "photo.on.rectangle.angled" : "clock"))
                .font(.retraceDisplay)
                .foregroundColor(.white.opacity(0.3))
            Text(isFilteredEmptyState ? "No results for current filters" : (viewModel.frames.isEmpty ? "No frames recorded" : "Frame not ready yet"))
                .font(.retraceBody)
                .foregroundColor(.white.opacity(0.5))
            if isFilteredEmptyState {
                Text("Adjust or clear filters to view timeline frames.")
                    .font(.retraceCaption)
                    .foregroundColor(.white.opacity(0.3))
            } else if !viewModel.frames.isEmpty {
                Text("Relaunch timeline in a few seconds")
                    .font(.retraceCaption)
                    .foregroundColor(.white.opacity(0.3))
            }
        }
    }

    private func frameStatusPlaceholder(
        icon: String,
        title: String,
        subtitle: String
    ) -> some View {
        VStack(spacing: .spacingM) {
            Image(systemName: icon)
                .font(.retraceDisplay)
                .foregroundColor(.white.opacity(0.3))
            Text(title)
                .font(.retraceBody)
                .foregroundColor(.white.opacity(0.5))
            Text(subtitle)
                .font(.retraceCaption)
                .foregroundColor(.white.opacity(0.3))
        }
    }

    private func fittedStillImage(_ image: NSImage) -> some View {
        Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: .fit)
    }

    @ViewBuilder
    private func frameStillContent(_ image: NSImage, interactive: Bool) -> some View {
        if interactive {
            TimelineFrameSurface(viewModel: viewModel, onURLClicked: onClose) {
                fittedStillImage(image)
            }
        } else {
            fittedStillImage(image)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .scaleEffect(viewModel.frameZoomScale)
                .offset(viewModel.frameZoomOffset)
        }
    }

    @ViewBuilder
    private func timelineVideoFramePresentation(_ videoInfo: FrameVideoInfo) -> some View {
        let path = videoInfo.videoPath
        let pathWithExt = path + ".mp4"
        let hasActiveFilters = viewModel.filterCriteria.hasActiveFilters
        let selectedApps = (viewModel.filterCriteria.selectedApps ?? []).sorted()
        let filteredFrameIndicesForVideo: Set<Int> = hasActiveFilters
            ? Set(viewModel.frames.compactMap { entry in
                guard let info = entry.videoInfo, info.videoPath == videoInfo.videoPath else { return nil }
                return info.frameIndex
            })
            : []
        let debugContext = viewModel.currentTimelineFrame.map {
            VideoSeekDebugContext(
                frameID: $0.frame.id.value,
                timestamp: $0.frame.timestamp,
                currentIndex: viewModel.currentIndex,
                frameBundleID: $0.frame.metadata.appBundleID,
                hasActiveFilters: hasActiveFilters,
                selectedApps: selectedApps,
                filteredFrameIndicesForVideo: filteredFrameIndicesForVideo
            )
        }

        let fileExists = FileManager.default.fileExists(atPath: path) || FileManager.default.fileExists(atPath: pathWithExt)

        if !fileExists {
            frameStatusPlaceholder(
                icon: "exclamationmark.triangle",
                title: "Could not find frame",
                subtitle: "Video file missing: \(path.suffix(50))"
            )
        } else {
            let fileSize = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ??
                (try? FileManager.default.attributesOfItem(atPath: pathWithExt)[.size] as? Int64) ?? 0
            let minFragmentSize: Int64 = 200_000
            let fileReady = videoInfo.isVideoFinalized || fileSize >= minFragmentSize
            let frameID = viewModel.currentTimelineFrame?.frame.id
            let processingStatus = viewModel.currentTimelineFrame?.processingStatus
            let isDecodedVideoInteractable =
                viewModel.currentFrameMediaDisplayMode == .decodedVideo &&
                viewModel.currentFrameStillDisplayMode == .none

            if fileReady && !viewModel.frameLoadError {
                ZStack {
                    TimelineFrameSurface(viewModel: viewModel, onURLClicked: onClose) {
                        SimpleVideoFrameView(
                            videoInfo: videoInfo,
                            debugContext: debugContext,
                            forceReload: .init(
                                get: { viewModel.forceVideoReload },
                                set: { viewModel.forceVideoReload = $0 }
                            ),
                            onLoadFailed: {
                                guard viewModel.currentTimelineFrame?.frame.id == frameID else { return }
                                if processingStatus != 2 && processingStatus != 7 && processingStatus != -1 {
                                    viewModel.setFramePresentationState(isNotReady: true, hasLoadError: false)
                                } else {
                                    viewModel.setFramePresentationState(isNotReady: false, hasLoadError: true)
                                }
                            },
                            onLoadSuccess: {
                                guard let frameID else { return }
                                viewModel.markVideoPresentationReady(frameID: frameID)
                                guard viewModel.currentTimelineFrame?.frame.id == frameID else { return }
                                viewModel.setFramePresentationState(isNotReady: false, hasLoadError: false)
                            }
                        )
                    }
                    .opacity(viewModel.currentFrameMediaDisplayMode == .decodedVideo ? 1 : 0.001)
                    .allowsHitTesting(isDecodedVideoInteractable)

                    if let image = viewModel.displayableCurrentImage {
                        frameStillContent(image, interactive: true)
                    } else if let fallbackImage = viewModel.waitingVideoFallbackImage {
                        frameStillContent(fallbackImage, interactive: false)
                    }
                }
            } else {
                let _ = Log.warning(
                    "[FrameDisplay] Video file too small (no fragments yet) and not finalized, showing placeholder. Size=\(fileSize), isFinalized=\(videoInfo.isVideoFinalized)",
                    category: .ui
                )
                frameStatusPlaceholder(
                    icon: "clock",
                    title: "Frame not ready yet",
                    subtitle: "Relaunch timeline in a few seconds"
                )
            }
        }
    }
}

private let timelineTopHintTransition: AnyTransition = .asymmetric(
    insertion: .move(edge: .top).combined(with: .opacity),
    removal: .opacity
)

struct TimelineChromeOverlay: View {
    @ObservedObject var viewModel: SimpleTimelineViewModel
    let onClose: () -> Void
    let showFrameCard: Bool
    let currentBrowserURLForDebugWindow: String?
    @Binding var browserURLDebugWindowPosition: CGSize
    let redactionReason: String?
    let redactionAppBundleID: String?
    let redactionTopPadding: CGFloat
    let shouldRenderSearchHighlightControlsHint: Bool
    @Binding var isSearchHighlightControlsHintDismissed: Bool
    @Binding var isInFrameSearchFieldFocused: Bool

    private var chromeOpacity: Double {
        viewModel.areControlsHidden || viewModel.isDraggingZoomRegion ? 0 : 1
    }

    private var chromeOffsetY: CGFloat {
        viewModel.areControlsHidden ? TimelineScaleFactor.closeButtonHiddenYOffset : 0
    }

    var body: some View {
        Group {
            if viewModel.areControlsHidden {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        ControlsToggleButton(viewModel: viewModel)
                    }
                    .padding(.trailing, 24)
                    .padding(.bottom, 24)
                }
                .transition(.opacity.animation(.easeInOut(duration: 0.2).delay(0.1)))
            }

            VStack {
                HStack(spacing: 8) {
                    if showFrameCard {
                        DebugFrameIDBadge(viewModel: viewModel)
                    }
                    OCRStatusIndicator(viewModel: viewModel)
                    #if DEBUG
                    DeveloperActionsMenu(viewModel: viewModel, onClose: onClose)
                    #endif
                    Spacer()
                        .allowsHitTesting(false)
                }
                Spacer()
                    .allowsHitTesting(false)
            }
            .padding(.spacingL)
            .offset(y: chromeOffsetY)
            .opacity(chromeOpacity)

            #if DEBUG
            if viewModel.showBrowserURLDebugWindow {
                let browserURLDebugWindowBinding = Binding(
                    get: { viewModel.showBrowserURLDebugWindow },
                    set: { viewModel.setBrowserURLDebugWindowVisible($0) }
                )
                DebugBrowserURLWindow(
                    browserURL: currentBrowserURLForDebugWindow,
                    panelPosition: $browserURLDebugWindowPosition,
                    isPresented: browserURLDebugWindowBinding
                )
                .offset(y: chromeOffsetY)
                .opacity(chromeOpacity)
                .zIndex(110)
            }
            #endif

            if viewModel.isFrameZoomed {
                VStack {
                    ResetZoomButton(viewModel: viewModel)
                        .padding(.top, 12)
                    Spacer()
                        .allowsHitTesting(false)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.spacingL)
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
                .animation(.easeInOut(duration: 0.2), value: viewModel.isFrameZoomed)
            }

            if viewModel.isPeeking {
                VStack {
                    PeekModeBanner(viewModel: viewModel)
                        .padding(.top, viewModel.isFrameZoomed ? 60 : 12)
                    Spacer()
                        .allowsHitTesting(false)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.spacingL)
                .transition(.opacity.combined(with: .move(edge: .top)))
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: viewModel.isPeeking)
            }

            if let redactionReason {
                VStack {
                    RedactionReasonBanner(
                        reason: redactionReason,
                        appBundleID: redactionAppBundleID
                    )
                    .padding(.top, redactionTopPadding)
                    .padding(.horizontal, .spacingL)
                    Spacer()
                        .allowsHitTesting(false)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .transition(.asymmetric(
                    insertion: .move(edge: .top).combined(with: .opacity),
                    removal: .opacity
                ))
                .animation(.spring(response: 0.28, dampingFraction: 0.82), value: redactionReason)
            }

            VStack {
                HStack {
                    Spacer()
                        .allowsHitTesting(false)
                    TimelineTopRightControlsView(
                        viewModel: viewModel,
                        onClose: onClose,
                        isInFrameSearchFieldFocused: $isInFrameSearchFieldFocused
                    )
                }
                Spacer()
                    .allowsHitTesting(false)
            }
            .padding(.spacingL)
            .padding(.top, 12)
            .zIndex(100)

            TimelineTopHintOverlay(
                viewModel: viewModel,
                shouldRenderSearchHighlightControlsHint: shouldRenderSearchHighlightControlsHint,
                isSearchHighlightControlsHintDismissed: $isSearchHighlightControlsHintDismissed
            )
        }
    }
}

struct TimelineTopRightControlsView: View {
    @ObservedObject var viewModel: SimpleTimelineViewModel
    let onClose: () -> Void
    @Binding var isInFrameSearchFieldFocused: Bool

    @State private var isCloseButtonHovering = false

    private var inFrameSearchBinding: Binding<String> {
        Binding(
            get: { viewModel.inFrameSearchQuery },
            set: { viewModel.setInFrameSearchQuery($0) }
        )
    }

    private var isInFrameSearchGlowActive: Bool {
        isInFrameSearchFieldFocused || !viewModel.inFrameSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        let scale = TimelineScaleFactor.current
        let searchResultNavigationState = viewModel.searchResultHighlightNavigationState

        return VStack(alignment: .trailing, spacing: 10 * scale) {
            HStack(spacing: 10 * scale) {
                if viewModel.isInFrameSearchVisible {
                    inFrameSearchBar
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
                closeButton(scale: scale)
            }

            if let searchResultNavigationState {
                SearchResultNavigationToast(
                    state: searchResultNavigationState,
                    onNavigatePrevious: {
                        Task {
                            await viewModel.navigateToAdjacentSearchResult(
                                offset: -1,
                                trigger: .button
                            )
                        }
                    },
                    onNavigateNext: {
                        Task {
                            await viewModel.navigateToAdjacentSearchResult(
                                offset: 1,
                                trigger: .button
                            )
                        }
                    }
                )
                .fixedSize()
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.15), value: viewModel.isInFrameSearchVisible)
        .animation(.spring(response: 0.24, dampingFraction: 0.84), value: searchResultNavigationState)
    }

    private var inFrameSearchBar: some View {
        let scale = TimelineScaleFactor.current
        let height = 44 * scale

        return HStack(spacing: 8 * scale) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13 * scale, weight: .semibold))
                .foregroundColor(.white.opacity(0.72))

            FocusableTextInput(
                text: inFrameSearchBinding,
                placeholder: "Search this frame",
                font: .systemFont(ofSize: 14 * scale, weight: .medium),
                isFocused: { isInFrameSearchFieldFocused },
                setFocused: { isFocused in
                    isInFrameSearchFieldFocused = isFocused
                }
            )
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                viewModel.setInFrameSearchQuery("")
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12 * scale, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))
            }
            .buttonStyle(.plain)
            .disabled(viewModel.inFrameSearchQuery.isEmpty)
            .opacity(viewModel.inFrameSearchQuery.isEmpty ? 0 : 1)
            .allowsHitTesting(!viewModel.inFrameSearchQuery.isEmpty)
            .help("Clear search")

            Button {
                viewModel.closeInFrameSearch(clearQuery: true)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12 * scale, weight: .semibold))
                    .foregroundColor(.white.opacity(0.78))
            }
            .buttonStyle(.plain)
            .help("Close in-frame search (Esc)")
        }
        .padding(.leading, 14 * scale)
        .padding(.trailing, 12 * scale)
        .frame(width: 340 * scale, height: height)
        .retraceMenuContainer(addPadding: false)
        .overlay(
            RoundedRectangle(cornerRadius: 14 * scale)
                .stroke(
                    Color.white.opacity(isInFrameSearchGlowActive ? 0.46 : 0.24),
                    lineWidth: isInFrameSearchGlowActive ? 1.2 : 0.8
                )
        )
        .shadow(
            color: Color.white.opacity(isInFrameSearchGlowActive ? 0.20 : 0.08),
            radius: (isInFrameSearchGlowActive ? 9 : 5) * scale,
            x: 0,
            y: 0
        )
        .shadow(
            color: Color.black.opacity(isInFrameSearchGlowActive ? 0.20 : 0.10),
            radius: (isInFrameSearchGlowActive ? 15 : 8) * scale,
            x: 0,
            y: 0
        )
        .contentShape(Rectangle())
        .onTapGesture {
            isInFrameSearchFieldFocused = true
        }
        .animation(.easeOut(duration: 0.18), value: isInFrameSearchGlowActive)
        .onAppear {
            DispatchQueue.main.async {
                isInFrameSearchFieldFocused = true
            }
        }
    }

    private func closeButton(scale: CGFloat) -> some View {
        let buttonSize = 44 * scale
        let expandedWidth = 120 * scale

        return Button(action: {
            viewModel.dismissContextMenu()
            onClose()
        }) {
            ZStack(alignment: .trailing) {
                Color.clear
                    .frame(width: expandedWidth, height: buttonSize)

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
}

struct TimelineTopHintOverlay: View {
    @ObservedObject var viewModel: SimpleTimelineViewModel
    let shouldRenderSearchHighlightControlsHint: Bool
    @Binding var isSearchHighlightControlsHintDismissed: Bool

    private var hasVisibleHints: Bool {
        viewModel.showControlsHiddenRestoreHintBanner ||
        viewModel.showPositionRecoveryHintBanner ||
        viewModel.showTextSelectionHint ||
        shouldRenderSearchHighlightControlsHint ||
        viewModel.showTimelineTapeRightClickHintBanner ||
        viewModel.showScrollOrientationHintBanner
    }

    var body: some View {
        if hasVisibleHints {
            TimelineHintOverlayStack {
                if viewModel.showControlsHiddenRestoreHintBanner {
                    ControlsHiddenRestoreHintBanner(
                        onDismiss: { viewModel.dismissControlsHiddenRestoreHint() }
                    )
                    .fixedSize()
                    .transition(timelineTopHintTransition)
                }

                if viewModel.showPositionRecoveryHintBanner {
                    PositionRecoveryHintBanner(
                        onDismiss: { viewModel.dismissPositionRecoveryHint() }
                    )
                    .fixedSize()
                    .transition(timelineTopHintTransition)
                }

                if viewModel.showTextSelectionHint {
                    TextSelectionHintBanner(
                        onDismiss: { viewModel.dismissTextSelectionHint() }
                    )
                    .fixedSize()
                    .transition(timelineTopHintTransition)
                }

                if shouldRenderSearchHighlightControlsHint {
                    SearchHighlightControlsHintBanner(
                        onDismiss: {
                            withAnimation(.easeOut(duration: 0.2)) {
                                isSearchHighlightControlsHintDismissed = true
                            }
                        }
                    )
                    .fixedSize()
                    .transition(timelineTopHintTransition)
                }

                if viewModel.showTimelineTapeRightClickHintBanner {
                    TimelineTapeRightClickHintBanner(
                        onDismiss: { viewModel.dismissTimelineTapeRightClickHint() }
                    )
                    .fixedSize()
                    .transition(timelineTopHintTransition)
                }

                if viewModel.showScrollOrientationHintBanner {
                    ScrollOrientationHintBanner(
                        currentOrientation: viewModel.scrollOrientationHintCurrentOrientation,
                        onSwitch: { viewModel.openTimelineScrollOrientationSettings() },
                        onDismiss: { viewModel.dismissScrollOrientationHint() }
                    )
                    .fixedSize()
                    .transition(timelineTopHintTransition)
                }
            }
        }
    }
}
