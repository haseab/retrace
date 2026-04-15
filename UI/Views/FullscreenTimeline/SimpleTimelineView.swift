import Foundation
import SwiftUI
import AVKit
import Shared
import App
import UniformTypeIdentifiers

let fullscreenTimelineSettingsStore: UserDefaults = UserDefaults(suiteName: "io.retrace.app") ?? .standard
private let timelineTopHintTransition: AnyTransition = .asymmetric(
    insertion: .move(edge: .top).combined(with: .opacity),
    removal: .opacity
)

/// Redesigned fullscreen timeline view with scrolling tape and fixed playhead
/// The timeline tape moves left/right while the playhead stays fixed in center
public struct SimpleTimelineView: View {
    private struct TimelineRootRenderContext {
        let containerSize: CGSize
        let actualFrameRect: CGRect
        let topSafeAreaInset: CGFloat
        let shouldShowSearchHighlightControlsHint: Bool

        var shouldRenderSearchHighlightControlsHint: Bool
    }

    // MARK: - Properties

    @ObservedObject private var viewModel: SimpleTimelineViewModel
    @State private var hasInitialized = false
    /// Forces a SwiftUI refresh when global appearance preferences change.
    @State private var appearanceRefreshTick = 0
    /// Tracks whether the live screenshot has been displayed, allowing AVPlayer to pre-mount underneath
    @State private var liveScreenshotHasAppeared = false
    /// Keep comment submenu mounted during fade-out so dismissal is visibly animated.
    @State private var isCommentSubmenuMounted = false
    @State private var commentSubmenuVisibility: Double = 0
    @State private var isSearchHighlightControlsHintDismissed = false
    @State private var browserURLDebugWindowPosition = CGSize(width: 320, height: 16)
    @State private var isInFrameSearchFieldFocused = false
    @AppStorage("showFrameIDs", store: fullscreenTimelineSettingsStore) private var showFrameCard = SettingsDefaults.showFrameIDs

    let coordinator: AppCoordinator
    let onClose: () -> Void

    // MARK: - Initialization

    /// Initialize with an external view model (scroll events handled by TimelineWindowController)
    public init(coordinator: AppCoordinator, viewModel: SimpleTimelineViewModel, onClose: @escaping () -> Void) {
        self.coordinator = coordinator
        self.viewModel = viewModel
        self.onClose = onClose
    }

    nonisolated static func shouldLoadMostRecentFrameOnAppear(hasInitialized: Bool, frameCount: Int) -> Bool {
        !hasInitialized && frameCount == 0
    }

    private var currentBrowserURLForDebugWindow: String? {
        guard let rawURL = viewModel.currentFrame?.metadata.browserURL?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !rawURL.isEmpty else {
            return nil
        }
        return rawURL
    }

    private var timelineControlsOffsetY: CGFloat {
        viewModel.areControlsHidden
            ? TimelineScaleFactor.hiddenControlsOffset
            : (viewModel.isTapeHidden ? TimelineScaleFactor.hiddenControlsOffset : 0)
    }

    @ViewBuilder
    private var transientDismissLayers: some View {
        if viewModel.isDateSearchActive && !viewModel.isCalendarPickerVisible {
            Color.clear
                .contentShape(Rectangle())
                .ignoresSafeArea()
                .onTapGesture {
                    viewModel.closeDateSearch()
                }
        }

        if viewModel.isCalendarPickerVisible {
            Color.clear
                .contentShape(Rectangle())
                .ignoresSafeArea()
                .onTapGesture {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                        viewModel.closeCalendarPicker()
                    }
                }
        }

        if viewModel.isZoomSliderExpanded {
            Color.clear
                .contentShape(Rectangle())
                .ignoresSafeArea()
                .onTapGesture {
                    withAnimation(.easeOut(duration: 0.12)) {
                        viewModel.setZoomSliderExpanded(false)
                    }
                }
        }
    }

    private var bottomBackdropLayer: some View {
        VStack {
            Spacer()
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
        .offset(y: timelineControlsOffsetY)
        .opacity(viewModel.areControlsHidden || viewModel.isDraggingZoomRegion ? 0 : 1)
    }

    private func bottomTapeLayer(width: CGFloat) -> some View {
        VStack {
            Spacer()
            TimelineTapeView(
                viewModel: viewModel,
                width: width,
                coordinator: coordinator
            )
            .padding(.bottom, TimelineScaleFactor.tapeBottomPadding)
        }
        .offset(y: timelineControlsOffsetY)
        .opacity(viewModel.areControlsHidden || viewModel.isDraggingZoomRegion ? 0 : 1)
    }

    // MARK: - Body

    public var body: some View {
        GeometryReader { geometry in
            let context = makeTimelineRootRenderContext(for: geometry)
            configuredTimelineRoot(timelineRootContent(context: context), context: context)
        }
    }

    private func makeTimelineRootRenderContext(for geometry: GeometryProxy) -> TimelineRootRenderContext {
        let actualFrameRect = calculateActualDisplayedFrameRectForView(
            containerSize: geometry.size
        )
        let shouldShowHint = shouldShowSearchHighlightControlsHint(
            containerSize: geometry.size,
            actualFrameRect: actualFrameRect
        )
        return TimelineRootRenderContext(
            containerSize: geometry.size,
            actualFrameRect: actualFrameRect,
            topSafeAreaInset: geometry.safeAreaInsets.top,
            shouldShowSearchHighlightControlsHint: shouldShowHint,
            shouldRenderSearchHighlightControlsHint: shouldShowHint && !isSearchHighlightControlsHintDismissed
        )
    }

    @ViewBuilder
    private func timelineRootContent(context: TimelineRootRenderContext) -> some View {
        ZStack {
            TimelineFrameCanvasLayer(
                viewModel: viewModel,
                onClose: onClose,
                containerSize: context.containerSize,
                actualFrameRect: context.actualFrameRect,
                isAwaitingLiveScreenshot: isAwaitingLiveScreenshot,
                liveScreenshotHasAppeared: $liveScreenshotHasAppeared
            )

            bottomBackdropLayer
            transientDismissLayers
            bottomTapeLayer(width: context.containerSize.width)

            TimelineChromeOverlay(
                viewModel: viewModel,
                onClose: onClose,
                showFrameCard: showFrameCard,
                currentBrowserURLForDebugWindow: currentBrowserURLForDebugWindow,
                browserURLDebugWindowPosition: $browserURLDebugWindowPosition,
                redactionReason: currentRedactionContext?.reason,
                redactionAppBundleID: currentRedactionContext?.appBundleID,
                redactionTopPadding: redactionBannerTopPadding(topSafeAreaInset: context.topSafeAreaInset),
                shouldRenderSearchHighlightControlsHint: context.shouldRenderSearchHighlightControlsHint,
                isSearchHighlightControlsHintDismissed: $isSearchHighlightControlsHintDismissed,
                isInFrameSearchFieldFocused: $isInFrameSearchFieldFocused
            )

            TimelineSurfaceOverlayLayer(
                coordinator: coordinator,
                viewModel: viewModel,
                onClose: onClose,
                containerSize: context.containerSize,
                actualFrameRect: context.actualFrameRect,
                isCommentSubmenuMounted: isCommentSubmenuMounted,
                commentSubmenuVisibility: commentSubmenuVisibility
            )

            TimelineFeedbackOverlay(
                viewModel: viewModel,
                topSafeAreaInset: context.topSafeAreaInset
            )
        }
    }

    private func configuredTimelineRoot<Content: View>(
        _ content: Content,
        context: TimelineRootRenderContext
    ) -> some View {
        content
            .coordinateSpace(name: "timelineContent")
            .background(frameCanvasBackgroundColor)
            .ignoresSafeArea()
            .onAppear {
                handleTimelineAppear()
            }
            .onDisappear {
                handleTimelineDisappear()
            }
            .onReceive(NotificationCenter.default.publisher(for: .colorThemeDidChange)) { _ in
                handleAppearancePreferenceChange()
            }
            .onReceive(NotificationCenter.default.publisher(for: .fontStyleDidChange)) { _ in
                handleAppearancePreferenceChange()
            }
            .onChange(of: viewModel.showCommentSubmenu) { isVisible in
                handleCommentSubmenuVisibilityChange(isVisible)
            }
            .animation(
                .easeOut(duration: TimelineCommentSubmenuPresentationSupport.animationDuration),
                value: viewModel.showCommentSubmenu
            )
            .onChange(of: viewModel.focusInFrameSearchFieldSignal) { _ in
                handleInFrameSearchFocusSignal()
            }
            .onChange(of: viewModel.isInFrameSearchVisible) { isVisible in
                handleInFrameSearchVisibilityChange(isVisible)
            }
            .onChange(of: context.shouldShowSearchHighlightControlsHint) { isVisible in
                handleSearchHighlightControlsHintVisibilityChange(isVisible)
            }
            .onChange(of: viewModel.searchHighlightQuery) { _ in
                handleSearchHighlightQueryChange()
            }
        // Note: Keyboard shortcuts (Cmd+F, Option+F, Cmd+Shift+F, Escape) are handled by TimelineWindowController
        // at the window level for more reliable event handling
    }

    private func handleTimelineAppear() {
        if Self.shouldLoadMostRecentFrameOnAppear(
            hasInitialized: hasInitialized,
            frameCount: viewModel.frames.count
        ) {
            hasInitialized = true
            Task {
                await viewModel.loadMostRecentFrame()
            }
        } else {
            hasInitialized = true
        }

        let submenuState = TimelineCommentSubmenuPresentationSupport.initialState(
            isVisible: viewModel.showCommentSubmenu
        )
        isCommentSubmenuMounted = submenuState.isMounted
        commentSubmenuVisibility = submenuState.visibility
        viewModel.handleTimelineOpened()
        viewModel.startPeriodicStatusRefresh()
    }

    private func handleTimelineDisappear() {
        viewModel.stopPeriodicStatusRefresh()
        viewModel.stopPlayback()
        viewModel.handleTimelineClosed()
    }

    private func handleAppearancePreferenceChange() {
        appearanceRefreshTick &+= 1
    }

    private func handleCommentSubmenuVisibilityChange(_ isVisible: Bool) {
        switch TimelineCommentSubmenuPresentationSupport.transition(
            isVisible: isVisible,
            isMounted: isCommentSubmenuMounted
        ) {
        case let .show(shouldPrimeMount):
            if shouldPrimeMount {
                isCommentSubmenuMounted = true
                commentSubmenuVisibility = 0
            }
            withAnimation(.easeOut(duration: TimelineCommentSubmenuPresentationSupport.animationDuration)) {
                commentSubmenuVisibility = 1
            }
        case let .hide(shouldScheduleUnmount):
            withAnimation(.easeOut(duration: TimelineCommentSubmenuPresentationSupport.animationDuration)) {
                commentSubmenuVisibility = 0
            }
            guard shouldScheduleUnmount else { return }
            DispatchQueue.main.asyncAfter(
                deadline: .now() + TimelineCommentSubmenuPresentationSupport.animationDuration
            ) {
                guard TimelineCommentSubmenuPresentationSupport.shouldFinalizeUnmount(
                    isStillVisible: viewModel.showCommentSubmenu
                ) else { return }
                isCommentSubmenuMounted = false
            }
        case .none:
            break
        }
    }

    private func handleInFrameSearchFocusSignal() {
        guard viewModel.isInFrameSearchVisible else { return }
        DispatchQueue.main.async {
            isInFrameSearchFieldFocused = true
        }
    }

    private func handleInFrameSearchVisibilityChange(_ isVisible: Bool) {
        guard !isVisible else { return }
        isInFrameSearchFieldFocused = false
    }

    private func handleSearchHighlightControlsHintVisibilityChange(_ isVisible: Bool) {
        guard !isVisible else { return }
        isSearchHighlightControlsHintDismissed = false
    }

    private func handleSearchHighlightQueryChange() {
        isSearchHighlightControlsHintDismissed = false
    }

    private var isAwaitingLiveScreenshot: Bool {
        viewModel.isInLiveMode && viewModel.liveScreenshot == nil
    }

    private struct RedactionBannerContext {
        let reason: String
        let appBundleID: String?
    }

    private var currentRedactionContext: RedactionBannerContext? {
        guard let reason = viewModel.currentFrame?.metadata.redactionReason?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !reason.isEmpty else {
            return nil
        }

        let fallbackBundleID = viewModel.currentFrame?.metadata.appBundleID
        let (baseReason, suffix) = splitRedactionReasonSuffix(reason)

        if let excludedBundleID = extractQuotedValue(
            from: baseReason,
            prefix: "excludedApp contains '"
        ) {
            let appName = appDisplayName(forBundleID: excludedBundleID)
            return RedactionBannerContext(
                reason: "Excluded app: \(appName)\(suffix)",
                appBundleID: excludedBundleID
            )
        }

        if let pattern = extractQuotedValue(
            from: baseReason,
            prefix: "windowTitle contains '"
        ) {
            return RedactionBannerContext(
                reason: "Window title matches '\(pattern)'\(suffix)",
                appBundleID: fallbackBundleID
            )
        }

        if let pattern = extractQuotedValue(
            from: baseReason,
            prefix: "browserURL contains '"
        ) {
            return RedactionBannerContext(
                reason: "Browser URL matches '\(pattern)'\(suffix)",
                appBundleID: fallbackBundleID
            )
        }

        return RedactionBannerContext(
            reason: reason,
            appBundleID: fallbackBundleID
        )
    }

    private func splitRedactionReasonSuffix(_ reason: String) -> (base: String, suffix: String) {
        guard let suffixStart = reason.range(of: " (+", options: .backwards),
              reason.hasSuffix(")") else {
            return (reason, "")
        }

        return (
            String(reason[..<suffixStart.lowerBound]),
            String(reason[suffixStart.lowerBound...])
        )
    }

    private func extractQuotedValue(from text: String, prefix: String) -> String? {
        guard text.hasPrefix(prefix), text.hasSuffix("'") else { return nil }
        let valueStart = text.index(text.startIndex, offsetBy: prefix.count)
        let valueEnd = text.index(before: text.endIndex)
        guard valueStart <= valueEnd else { return nil }
        let value = text[valueStart..<valueEnd].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func appDisplayName(forBundleID bundleID: String) -> String {
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let appName = appURL.deletingPathExtension().lastPathComponent
            if !appName.isEmpty {
                return appName
            }
        }

        if let fallbackName = bundleID.split(separator: ".").last, !fallbackName.isEmpty {
            return String(fallbackName)
        }

        return "this app"
    }

    private func redactionBannerTopPadding(topSafeAreaInset: CGFloat) -> CGFloat {
        // Keep redaction UI below the notch/menu bar even when we ignore safe areas.
        let baseTopPadding = max(44, topSafeAreaInset + 12)

        if viewModel.isPeeking {
            return viewModel.isFrameZoomed ? baseTopPadding + 94 : baseTopPadding + 46
        }
        return viewModel.isFrameZoomed ? baseTopPadding + 48 : baseTopPadding
    }

    private var frameCanvasBackgroundColor: Color {
        isAwaitingLiveScreenshot ? .clear : .black
    }

    private func shouldShowSearchHighlightControlsHint(
        containerSize: CGSize,
        actualFrameRect: CGRect
    ) -> Bool {
        guard viewModel.isShowingSearchHighlight else { return false }
        guard !viewModel.areControlsHidden else { return false }
        guard !viewModel.isInFrameSearchVisible else { return false }

        let highlightCutoffY = containerSize.height * 0.88
        var seenNodeIDs = Set<Int>()
        for match in viewModel.searchHighlightNodes {
            guard seenNodeIDs.insert(match.node.id).inserted else { continue }

            let rect = CGRect(
                x: actualFrameRect.origin.x + (match.node.x * actualFrameRect.width),
                y: actualFrameRect.origin.y + (match.node.y * actualFrameRect.height),
                width: match.node.width * actualFrameRect.width,
                height: match.node.height * actualFrameRect.height
            )

            guard !rect.isEmpty else { continue }
            if rect.maxY >= highlightCutoffY {
                return true
            }
        }

        return false
    }
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

}

// MARK: - Reset Zoom Button

/// Floating button that appears when the frame is zoomed, allowing quick reset to fit-to-screen.

// MARK: - Frame Zoom Indicator

/// Shows the current zoom level when frame is zoomed

// MARK: - Zoomed Text Selection Overlay

/// Text selection overlay that appears on top of the zoomed region
/// Handles mouse events and transforms coordinates appropriately
// MARK: - Preview

#if DEBUG
struct SimpleTimelineView_Previews: PreviewProvider {
    static var previews: some View {
        let coordinator = AppCoordinator()
        let wrapper = AppCoordinatorWrapper(coordinator: coordinator)
        SimpleTimelineView(
            coordinator: coordinator,
            viewModel: SimpleTimelineViewModel(coordinator: coordinator),
            onClose: {}
        )
        .environmentObject(wrapper)
        .frame(width: 1920, height: 1080)
    }
}
#endif
