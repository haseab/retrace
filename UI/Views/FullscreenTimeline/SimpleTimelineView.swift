import SwiftUI
import AVKit
import Shared
import App
import UniformTypeIdentifiers

private let timelineSettingsStore: UserDefaults = UserDefaults(suiteName: "io.retrace.app") ?? .standard

/// Redesigned fullscreen timeline view with scrolling tape and fixed playhead
/// The timeline tape moves left/right while the playhead stays fixed in center
public struct SimpleTimelineView: View {

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
    @FocusState private var isInFrameSearchFieldFocused: Bool
    @AppStorage("showFrameIDs", store: timelineSettingsStore) private var showFrameIDs = SettingsDefaults.showFrameIDs

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

    // MARK: - Body

    public var body: some View {
        GeometryReader { geometry in
            // Calculate actual frame rect for coordinate transformations
            let actualFrameRect = calculateActualDisplayedFrameRectForView(
                containerSize: geometry.size
            )
            let shouldShowSearchHighlightControlsHint = shouldShowSearchHighlightControlsHint(
                containerSize: geometry.size,
                actualFrameRect: actualFrameRect
            )
            let shouldRenderSearchHighlightControlsHint =
                shouldShowSearchHighlightControlsHint && !isSearchHighlightControlsHintDismissed

            ZStack {
                // Full screen frame display
                frameDisplay
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Search-result highlights should sit above the frame, but below timeline controls/tape.
                searchHighlightOverlay(containerSize: geometry.size, actualFrameRect: actualFrameRect)

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
                .offset(y: viewModel.areControlsHidden ? TimelineScaleFactor.hiddenControlsOffset : (viewModel.isTapeHidden ? TimelineScaleFactor.hiddenControlsOffset : 0))
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
                                viewModel.calendarKeyboardFocus = .dateGrid
                                viewModel.selectedCalendarHour = nil
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
                        width: geometry.size.width,
                        coordinator: coordinator
                    )
                    .padding(.bottom, TimelineScaleFactor.tapeBottomPadding)
                }
                .offset(y: viewModel.areControlsHidden ? TimelineScaleFactor.hiddenControlsOffset : (viewModel.isTapeHidden ? TimelineScaleFactor.hiddenControlsOffset : 0))
                .opacity(viewModel.areControlsHidden || viewModel.isDraggingZoomRegion ? 0 : 1)

                // Persistent controls toggle button (stays visible when controls are hidden)
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

                // Debug frame ID badge, OCR status indicator, and developer actions menu (top-left)
                VStack {
                    HStack(spacing: 8) {
                        if showFrameIDs {
                            DebugFrameIDBadge(viewModel: viewModel)
                        }
                        // OCR status indicator (only visible when OCR is in progress)
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
                .offset(y: viewModel.areControlsHidden ? TimelineScaleFactor.closeButtonHiddenYOffset : 0)
                .opacity(viewModel.areControlsHidden || viewModel.isDraggingZoomRegion ? 0 : 1)

                #if DEBUG
                if viewModel.showBrowserURLDebugWindow {
                    DebugBrowserURLWindow(
                        browserURL: currentBrowserURLForDebugWindow,
                        panelPosition: $browserURLDebugWindowPosition,
                        isPresented: $viewModel.showBrowserURLDebugWindow
                    )
                    .offset(y: viewModel.areControlsHidden ? TimelineScaleFactor.closeButtonHiddenYOffset : 0)
                    .opacity(viewModel.areControlsHidden || viewModel.isDraggingZoomRegion ? 0 : 1)
                    .zIndex(110)
                }
                #endif

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

                // Persistent redaction reason banner (top center)
                if let redactionContext = currentRedactionContext {
                    VStack {
                        RedactionReasonBanner(
                            reason: redactionContext.reason,
                            appBundleID: redactionContext.appBundleID
                        )
                            .padding(.top, redactionBannerTopPadding(topSafeAreaInset: geometry.safeAreaInsets.top))
                            .padding(.horizontal, .spacingL)
                        Spacer()
                            .allowsHitTesting(false)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .transition(.asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity),
                        removal: .opacity
                    ))
                    .animation(.spring(response: 0.28, dampingFraction: 0.82), value: redactionContext.reason)
                }

                // Top-right controls (in-frame search + close)
                VStack {
                    HStack {
                        Spacer()
                            .allowsHitTesting(false)
                        topRightControls
                    }
                    Spacer()
                        .allowsHitTesting(false)
                }
                .padding(.spacingL)
                .padding(.top, 12) // Match ResetZoomButton vertical row alignment
                .zIndex(100)


                // Loading overlay
                if viewModel.isLoading {
                    loadingOverlay
                }

                // Error overlay
                if let error = viewModel.error {
                    errorOverlay(error)
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: viewModel.error)
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

                // OCR debug overlay (dev setting)
                ocrDebugOverlay(containerSize: geometry.size, actualFrameRect: actualFrameRect)

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

                // Search-highlight/timeline-controls hint toast (top center)
                if shouldRenderSearchHighlightControlsHint {
                    VStack {
                        SearchHighlightControlsHintBanner(
                            onDismiss: {
                                isSearchHighlightControlsHintDismissed = true
                            }
                        )
                            .fixedSize()
                            .padding(.top, viewModel.showTextSelectionHint ? 118 : 60)
                            .transition(.asymmetric(
                                insertion: .move(edge: .top).combined(with: .opacity),
                                removal: .opacity
                            ))
                        Spacer()
                    }
                    .animation(.spring(response: 0.3, dampingFraction: 0.8), value: shouldRenderSearchHighlightControlsHint)
                }

                // Scroll orientation hint toast (top center)
                if viewModel.showScrollOrientationHintBanner {
                    VStack {
                        ScrollOrientationHintBanner(
                            currentOrientation: viewModel.scrollOrientationHintCurrentOrientation,
                            onSwitch: { viewModel.openTimelineScrollOrientationSettings() },
                            onDismiss: { viewModel.dismissScrollOrientationHint() }
                        )
                        .fixedSize()
                        .padding(
                            .top,
                            60 + (viewModel.showTextSelectionHint ? 58 : 0) + (shouldRenderSearchHighlightControlsHint ? 58 : 0)
                        )
                        .transition(.asymmetric(
                            insertion: .move(edge: .top).combined(with: .opacity),
                            removal: .opacity
                        ))
                        Spacer()
                    }
                    .animation(.spring(response: 0.3, dampingFraction: 0.8), value: viewModel.showScrollOrientationHintBanner)
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
                                .fixedSize()
                        }
                    }
                    .padding(.trailing, geometry.size.width / 2 + TimelineScaleFactor.controlSpacing + 60)
                    .padding(.bottom, TimelineScaleFactor.tapeBottomPadding + TimelineScaleFactor.tapeHeight + 75)
                    .transition(.opacity.combined(with: .offset(y: 10)))

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

                if isCommentSubmenuMounted {
                    Color.black.opacity(0.35)
                        .opacity(commentSubmenuVisibility)
                        .ignoresSafeArea()
                        .allowsHitTesting(viewModel.showCommentSubmenu)
                        .onTapGesture {
                            viewModel.dismissCommentSubmenu()
                        }

                    VStack {
                        CommentSubmenu(viewModel: viewModel) {
                            viewModel.dismissCommentSubmenu()
                        }
                        .frame(maxWidth: min(geometry.size.width - 40, 560))
                    }
                    .padding(.horizontal, 20)
                    .opacity(commentSubmenuVisibility)
                    .scaleEffect(0.98 + (0.02 * commentSubmenuVisibility))
                    .allowsHitTesting(viewModel.showCommentSubmenu)
                }

                // Toast feedback overlay (centered, larger for errors)
                if viewModel.toastMessage != nil {
                    let isErrorToast = viewModel.toastTone == .error
                    let toastAccentColor = isErrorToast ? Color.red : Color.green

                    VStack {
                        Spacer()
                        HStack(spacing: 12) {
                            if let icon = viewModel.toastIcon {
                                Image(systemName: icon)
                                    .font(.system(size: 22, weight: .semibold))
                                    .foregroundColor(toastAccentColor)
                            }
                            if let message = viewModel.toastMessage {
                                Text(message)
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundColor(.white)
                            }
                        }
                        .padding(.horizontal, 28)
                        .padding(.vertical, 18)
                        .background(
                            ZStack {
                                RoundedRectangle(cornerRadius: 16)
                                    .fill(.ultraThinMaterial)
                                    .environment(\.colorScheme, .dark)
                                RoundedRectangle(cornerRadius: 16)
                                    .fill(Color.black.opacity(0.5))
                                RoundedRectangle(cornerRadius: 16)
                                    .stroke(toastAccentColor.opacity(0.35), lineWidth: 1)
                            }
                        )
                        .shadow(color: .black.opacity(0.4), radius: 20, y: 8)
                        .scaleEffect(viewModel.toastVisible ? 1.0 : 0.85)
                        .opacity(viewModel.toastVisible ? 1.0 : 0.0)
                        Spacer()
                    }
                        .allowsHitTesting(false)
                }

                // Delete undo action banner (interactive)
                if let undoMessage = viewModel.pendingDeleteUndoMessage {
                    VStack {
                        HStack(spacing: 10) {
                            Image(systemName: "trash.fill")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.orange.opacity(0.95))

                            Text(undoMessage)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.white.opacity(0.92))
                                .lineLimit(1)

                            Button("Undo") {
                                viewModel.undoPendingDelete()
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                Capsule()
                                    .fill(Color.white.opacity(0.18))
                            )
                            .overlay(
                                Capsule()
                                    .stroke(Color.white.opacity(0.26), lineWidth: 1)
                            )

                            Button(action: {
                                viewModel.dismissPendingDeleteUndo()
                            }) {
                                Image(systemName: "xmark")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundColor(.white.opacity(0.7))
                                    .padding(6)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.black.opacity(0.68))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(Color.white.opacity(0.18), lineWidth: 1)
                                )
                        )
                        .shadow(color: .black.opacity(0.4), radius: 14, y: 6)
                        .padding(.top, max(geometry.safeAreaInsets.top + 18, 56))
                        Spacer()
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .animation(.spring(response: 0.3, dampingFraction: 0.8), value: undoMessage)
                }

            }
            .coordinateSpace(name: "timelineContent")
            .background(frameCanvasBackgroundColor)
            .ignoresSafeArea()
            .onAppear {
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
                if viewModel.showCommentSubmenu {
                    isCommentSubmenuMounted = true
                    commentSubmenuVisibility = 1
                }
                viewModel.handleTimelineOpened()
                // Start periodic refresh of processing statuses
                viewModel.startPeriodicStatusRefresh()
            }
            .onDisappear {
                // Stop periodic refresh when timeline is closed
                viewModel.stopPeriodicStatusRefresh()
                // Stop video playback when timeline is closed
                viewModel.stopPlayback()
                viewModel.handleTimelineClosed()
            }
            .onReceive(NotificationCenter.default.publisher(for: .colorThemeDidChange)) { _ in
                appearanceRefreshTick &+= 1
            }
            .onReceive(NotificationCenter.default.publisher(for: .fontStyleDidChange)) { _ in
                appearanceRefreshTick &+= 1
            }
            .onChange(of: viewModel.showCommentSubmenu) { isVisible in
                let animationDuration = 0.16
                if isVisible {
                    if !isCommentSubmenuMounted {
                        isCommentSubmenuMounted = true
                        commentSubmenuVisibility = 0
                    }
                    withAnimation(.easeOut(duration: animationDuration)) {
                        commentSubmenuVisibility = 1
                    }
                } else if isCommentSubmenuMounted {
                    withAnimation(.easeOut(duration: animationDuration)) {
                        commentSubmenuVisibility = 0
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + animationDuration) {
                        guard !viewModel.showCommentSubmenu else { return }
                        isCommentSubmenuMounted = false
                    }
                }
            }
            .animation(.easeOut(duration: 0.16), value: viewModel.showCommentSubmenu)
            .onChange(of: viewModel.focusInFrameSearchFieldSignal) { _ in
                guard viewModel.isInFrameSearchVisible else { return }
                DispatchQueue.main.async {
                    isInFrameSearchFieldFocused = true
                }
            }
            .onChange(of: viewModel.isInFrameSearchVisible) { isVisible in
                if !isVisible {
                    isInFrameSearchFieldFocused = false
                }
            }
            .onChange(of: shouldShowSearchHighlightControlsHint) { isVisible in
                if !isVisible {
                    isSearchHighlightControlsHintDismissed = false
                }
            }
            .onChange(of: viewModel.searchHighlightQuery) { _ in
                isSearchHighlightControlsHintDismissed = false
            }
            // Note: Keyboard shortcuts (Cmd+F, Option+F, Cmd+Shift+F, Escape) are handled by TimelineWindowController
            // at the window level for more reliable event handling
        }
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

        let highlightCutoffY = containerSize.height * 0.75
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

    @ViewBuilder
    private func ocrDebugOverlay(containerSize: CGSize, actualFrameRect: CGRect) -> some View {
        if viewModel.showOCRDebugOverlay {
            OCRDebugOverlay(
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
            if isAwaitingLiveScreenshot {
                // Live-mode launch: hide the frame canvas until live screenshot arrives.
                // The tape and controls still render above this.
                Color.clear
            } else {
                // Main content with live mode overlay using ZStack.
                // Live screenshot always overlays historical/error content when available.
                ZStack {
                    // Base layer: historical frame/error content.
                    // Only mount after live screenshot has appeared to prevent initial black flash.
                    if liveScreenshotHasAppeared || !viewModel.isInLiveMode {
                        historicalFrameContent
                    }

                    // Overlay layer: Live screenshot with text selection.
                    if viewModel.isInLiveMode, let liveImage = viewModel.liveScreenshot {
                        FrameWithURLOverlay(viewModel: viewModel, onURLClicked: onClose) {
                            Image(nsImage: liveImage)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                        }
                        .onAppear {
                            // Mark that live screenshot has appeared, allowing AVPlayer to mount.
                            liveScreenshotHasAppeared = true
                        }
                    }
                }
            }
	    }

    @ViewBuilder
    private var historicalFrameContent: some View {
        if viewModel.frameLoadError {
            // Frame failed to load.
            VStack(spacing: .spacingM) {
                Image(systemName: "clock")
                    .font(.retraceDisplay)
                    .foregroundColor(.white.opacity(0.3))
                Text("Come back in a few frames")
                    .font(.retraceBody)
                    .foregroundColor(.white.opacity(0.5))
                Text("This frame is still being processed")
                    .font(.retraceCaption)
                    .foregroundColor(.white.opacity(0.3))
            }
        } else if viewModel.frameNotReady {
            // Frame not yet written to video file.
            VStack(spacing: .spacingM) {
                Image(systemName: "clock")
                    .font(.retraceDisplay)
                    .foregroundColor(.white.opacity(0.3))
                Text("Frame not ready yet")
                    .font(.retraceBody)
                    .foregroundColor(.white.opacity(0.5))
                Text("Still encoding...")
                    .font(.retraceCaption)
                    .foregroundColor(.white.opacity(0.3))
            }
        } else if let videoInfo = viewModel.currentVideoInfo {
            let isDecodedVideoInteractable =
                viewModel.currentFrameMediaDisplayMode == .decodedVideo &&
                viewModel.currentFrameStillDisplayMode == .none

            ZStack {
                // Keep the video view mounted behind still overlays so AVPlayer can preload
                // and preserve its last rendered frame across still -> video handoffs.
                videoFrameContent(videoInfo: videoInfo)
                    .opacity(viewModel.currentFrameMediaDisplayMode == .decodedVideo ? 1 : 0.001)
                    .allowsHitTesting(isDecodedVideoInteractable)

                if let image = viewModel.displayableCurrentImage {
                    FrameWithURLOverlay(viewModel: viewModel, onURLClicked: onClose) {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    }
                } else if let fallbackImage = viewModel.waitingVideoFallbackImage {
                    Image(nsImage: fallbackImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                }
            }
        } else if let image = viewModel.displayableCurrentImage {
            // Static image (Retrace) with URL overlay.
            FrameWithURLOverlay(viewModel: viewModel, onURLClicked: onClose) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }
        } else if !viewModel.isLoading {
            // Empty state - no video or image available.
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
    }

	    /// Video frame content extracted to separate view builder for cleaner code
	    @ViewBuilder
	    private func videoFrameContent(videoInfo: FrameVideoInfo) -> some View {
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

	        // Check if file exists FIRST - before trying to load it
	        let fileExists = FileManager.default.fileExists(atPath: path) || FileManager.default.fileExists(atPath: pathWithExt)

	        if !fileExists {
	            // Video file is missing - show error message
	            VStack(spacing: .spacingM) {
	                Image(systemName: "exclamationmark.triangle")
	                    .font(.retraceDisplay)
	                    .foregroundColor(.white.opacity(0.3))
	                Text("Could not find frame")
	                    .font(.retraceBody)
	                    .foregroundColor(.white.opacity(0.5))
	                Text("Video file missing: \(path.suffix(50))")
	                    .font(.retraceCaption)
	                    .foregroundColor(.white.opacity(0.3))
	            }
	        } else {
	            let fileSize = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ??
	                           (try? FileManager.default.attributesOfItem(atPath: pathWithExt)[.size] as? Int64) ?? 0

	            // If video is finalized (processingState = 0), trust it's readable regardless of size.
	            // Otherwise, require minimum file size to ensure fragments are written.
	            // With movieFragmentInterval = 0.1s and ~3 frames needed before first fragment is written,
	            // a typical fragment with 1920x1080 HEVC frames is ~40-50KB minimum per fragment.
	            // However, to avoid corrupted/incomplete fragments, require at least 2 fragments written.
	            // Observed: Fragment 2 written at ~280KB total. Use 200KB threshold for safety.
	            let minFragmentSize: Int64 = 200_000  // 200KB threshold (~2 fragments)
	            let fileReady = videoInfo.isVideoFinalized || fileSize >= minFragmentSize

            let frameID = viewModel.currentTimelineFrame?.frame.id
            let processingStatus = viewModel.currentTimelineFrame?.processingStatus

            // Don't render video if we already know it will fail to load
            if fileReady && !viewModel.frameLoadError {
                FrameWithURLOverlay(viewModel: viewModel, onURLClicked: onClose) {
                    SimpleVideoFrameView(videoInfo: videoInfo, debugContext: debugContext, forceReload: .init(
                        get: { viewModel.forceVideoReload },
                        set: { viewModel.forceVideoReload = $0 }
                    ), onLoadFailed: {
                        guard viewModel.currentTimelineFrame?.frame.id == frameID else { return }
                        // Don't set frameNotReady=true for completed frames (processingStatus=2) or Rewind frames (-1)
                        // Temporary video reload issues shouldn't show "Still encoding..." for ready frames
                        if processingStatus != 2 && processingStatus != -1 {
                            viewModel.frameNotReady = true
                            viewModel.frameLoadError = false
                        } else {
                            // For completed frames or Rewind frames, this is a real error
                            viewModel.frameNotReady = false
                            viewModel.frameLoadError = true
                        }
                    }, onLoadSuccess: {
                        guard let frameID else { return }
                        viewModel.markVideoPresentationReady(frameID: frameID)
                        guard viewModel.currentTimelineFrame?.frame.id == frameID else { return }
                        viewModel.frameNotReady = false
                        viewModel.frameLoadError = false
                    })
                }
	            } else {
	                let _ = Log.warning("[FrameDisplay] Video file too small (no fragments yet) and not finalized, showing placeholder. Size=\(fileSize), isFinalized=\(videoInfo.isVideoFinalized)", category: .ui)
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
	        }
	    }

    // MARK: - Top Right Controls

    @State private var isCloseButtonHovering = false

    private var topRightControls: some View {
        let scale = TimelineScaleFactor.current
        return HStack(spacing: 10 * scale) {
            if viewModel.isInFrameSearchVisible {
                inFrameSearchBar
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
            closeButton
        }
        .animation(.easeOut(duration: 0.15), value: viewModel.isInFrameSearchVisible)
    }

    private var inFrameSearchBinding: Binding<String> {
        Binding(
            get: { viewModel.inFrameSearchQuery },
            set: { viewModel.setInFrameSearchQuery($0) }
        )
    }

    private var isInFrameSearchGlowActive: Bool {
        isInFrameSearchFieldFocused || !viewModel.inFrameSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var inFrameSearchBar: some View {
        let scale = TimelineScaleFactor.current
        let height = 44 * scale

        return HStack(spacing: 8 * scale) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13 * scale, weight: .semibold))
                .foregroundColor(.white.opacity(0.72))

            TextField("Search this frame", text: inFrameSearchBinding)
                .textFieldStyle(.plain)
                .font(.system(size: 14 * scale, weight: .medium))
                .foregroundColor(.white)
                .focused($isInFrameSearchFieldFocused)
                .submitLabel(.search)

            if !viewModel.inFrameSearchQuery.isEmpty {
                Button {
                    viewModel.setInFrameSearchQuery("")
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12 * scale, weight: .medium))
                        .foregroundColor(.white.opacity(0.6))
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }

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

    // MARK: - Close Button

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
        let accentColor = Color.orange

        return HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(accentColor)
            Text(message)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .lineLimit(3)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
        .fixedSize(horizontal: true, vertical: false)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(.ultraThinMaterial)
                    .environment(\.colorScheme, .dark)
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.black.opacity(0.5))
                RoundedRectangle(cornerRadius: 16)
                    .stroke(accentColor.opacity(0.35), lineWidth: 1)
            }
        )
        .shadow(color: .black.opacity(0.4), radius: 20, y: 8)
        .padding(.horizontal, 24)
        .allowsHitTesting(false)
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

struct VideoSeekDebugContext {
    let frameID: Int64
    let timestamp: Date
    let currentIndex: Int
    let frameBundleID: String?
    let hasActiveFilters: Bool
    let selectedApps: [String]
    let filteredFrameIndicesForVideo: Set<Int>

    var selectedAppsLabel: String {
        selectedApps.isEmpty ? "none" : selectedApps.joined(separator: ",")
    }

    func containsFilteredFrameIndex(_ frameIndex: Int) -> Bool {
        guard frameIndex >= 0 else { return false }
        return filteredFrameIndicesForVideo.contains(frameIndex)
    }

    func nearestFilteredFrameIndices(around frameIndex: Int, limit: Int = 6) -> String {
        guard !filteredFrameIndicesForVideo.isEmpty else { return "none" }
        let nearest = filteredFrameIndicesForVideo
            .sorted { lhs, rhs in
                abs(lhs - frameIndex) < abs(rhs - frameIndex)
            }
            .prefix(limit)
            .sorted()
        return nearest.map(String.init).joined(separator: ",")
    }
}

// MARK: - Simple Video Frame View

/// Double-buffered video frame view using two AVPlayers
/// Eliminates black flash when crossing video boundaries by preloading the next video
/// in a hidden player and swapping visibility once ready
struct SimpleVideoFrameView: NSViewRepresentable {
    let videoInfo: FrameVideoInfo
    let debugContext: VideoSeekDebugContext?
    @Binding var forceReload: Bool
    var onLoadFailed: (() -> Void)?
    var onLoadSuccess: (() -> Void)?

    func makeNSView(context: Context) -> DoubleBufferedVideoView {
        let containerView = DoubleBufferedVideoView()
        containerView.onLoadFailed = onLoadFailed
        containerView.onLoadSuccess = onLoadSuccess
        return containerView
    }

    func updateNSView(_ containerView: DoubleBufferedVideoView, context: Context) {
        // Update callbacks in case they changed
        containerView.onLoadFailed = onLoadFailed
        containerView.onLoadSuccess = onLoadSuccess

        if let debugContext, debugContext.hasActiveFilters {
            Log.debug(
                "[FILTER-VIDEO] renderRequest frameID=\(debugContext.frameID) idx=\(debugContext.currentIndex) ts=\(debugContext.timestamp) bundle=\(debugContext.frameBundleID ?? "nil") selectedApps=[\(debugContext.selectedAppsLabel)] targetVideoFrame=\(videoInfo.frameIndex) videoPathSuffix=\(videoInfo.videoPath.suffix(40))",
                category: .ui
            )
        }

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
            DispatchQueue.main.async {
                self.onLoadSuccess?()
            }
            return
        }

        // Only update coordinator state if window is visible
        if isWindowVisible {
            context.coordinator.currentFrameIndex = videoInfo.frameIndex
        }

        // If same video, just seek on the active player (fast path)
        if effectivePath == videoInfo.videoPath {
            let time = videoInfo.frameTimeCMTime
            containerView.seekActivePlayer(
                to: time,
                expectedFrameIndex: videoInfo.frameIndex,
                frameRate: videoInfo.frameRate,
                debugContext: debugContext
            )
            return
        }

        // Different video - update coordinator state and load
        context.coordinator.currentVideoPath = videoInfo.videoPath

        // Resolve actual video path (file existence already checked in frameDisplay)
        var actualVideoPath = videoInfo.videoPath

        if !FileManager.default.fileExists(atPath: actualVideoPath) {
            let pathWithExtension = actualVideoPath + ".mp4"
            if FileManager.default.fileExists(atPath: pathWithExtension) {
                actualVideoPath = pathWithExtension
            } else {
                // This shouldn't happen since we check in frameDisplay, but handle gracefully
                return
            }
        }

        // Get URL (with symlink if needed for extensionless files)
        let url: URL
        if actualVideoPath.hasSuffix(".mp4") {
            url = URL(fileURLWithPath: actualVideoPath)
        } else {
            // Use UUID to avoid conflicts when multiple views create symlinks for same video
            let tempDir = FileManager.default.temporaryDirectory
            let symlinkPath = tempDir.appendingPathComponent("\(UUID().uuidString).mp4").path

            do {
                try FileManager.default.createSymbolicLink(atPath: symlinkPath, withDestinationPath: actualVideoPath)
                context.coordinator.trackSymlink(symlinkPath)
            } catch {
                Log.error("[SimpleVideoFrameView] Failed to create symlink: \(error)", category: .app)
                return
            }
            url = URL(fileURLWithPath: symlinkPath)
        }

        // Load video into buffer player and swap when ready
        let targetTime = videoInfo.frameTimeCMTime
        let targetFrameIndex = videoInfo.frameIndex
        containerView.loadVideoIntoBuffer(
            url: url,
            seekTime: targetTime,
            frameIndex: targetFrameIndex,
            frameRate: videoInfo.frameRate,
            debugContext: debugContext
        )
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    static func dismantleNSView(_ nsView: DoubleBufferedVideoView, coordinator: Coordinator) {
        nsView.releaseDecoderResources(reason: "SimpleVideoFrameView dismantled")
        coordinator.cleanupSymlinks()
    }

    class Coordinator {
        var currentVideoPath: String?
        var currentFrameIndex: Int?
        private var symlinkPaths: Set<String> = []

        func trackSymlink(_ path: String) {
            symlinkPaths.insert(path)
        }

        func cleanupSymlinks() {
            for path in symlinkPaths {
                try? FileManager.default.removeItem(atPath: path)
            }
            symlinkPaths.removeAll()
        }
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

    /// Generation counter for same-video seeks (used to detect stale completion callbacks).
    private var seekGeneration: UInt64 = 0

    /// Enable detailed seek diagnostics in release builds with:
    /// `defaults write io.retrace.app retrace.debug.filteredSeekDiagnostics -bool YES`
    private static let isFilteredSeekDiagnosticsEnabled: Bool = {
        #if DEBUG
        return true
        #else
        return (UserDefaults(suiteName: "io.retrace.app") ?? .standard)
            .bool(forKey: "retrace.debug.filteredSeekDiagnostics")
        #endif
    }()

    /// Callback when video loading fails (e.g., frame not yet in video file)
    var onLoadFailed: (() -> Void)?

    /// Callback when video loading succeeds
    var onLoadSuccess: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupPlayers()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupPlayers()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            releaseDecoderResources(reason: "view removed from window")
        }
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

    private func ensurePlayersReady() {
        if playerViewA == nil || playerViewB == nil {
            setupPlayers()
            return
        }

        if playerA == nil {
            let player = AVPlayer()
            player.actionAtItemEnd = .pause
            playerA = player
            playerViewA.player = player
        } else if playerViewA.player == nil {
            playerViewA.player = playerA
        }

        if playerB == nil {
            let player = AVPlayer()
            player.actionAtItemEnd = .pause
            playerB = player
            playerViewB.player = player
        } else if playerViewB.player == nil {
            playerViewB.player = playerB
        }

        playerViewA.isHidden = !isPlayerAActive
        playerViewB.isHidden = isPlayerAActive
    }

    /// Seek the currently active player to a specific time.
    func seekActivePlayer(
        to time: CMTime,
        expectedFrameIndex: Int,
        frameRate: Double,
        debugContext: VideoSeekDebugContext?
    ) {
        ensurePlayersReady()
        seekGeneration &+= 1
        let currentSeekGeneration = seekGeneration
        let tolerance = seekTolerance(for: frameRate)
        let toleranceFrames = configuredSeekToleranceFrames()
        let activePlayer = isPlayerAActive ? playerA : playerB

        activePlayer?.seek(to: time, toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self, weak activePlayer] finished in
            guard let self = self else { return }

            guard finished else {
                if self.shouldLogSeekDiagnostics(for: debugContext) {
                    Log.debug(
                        "[FILTER-VIDEO] seekCancelled path=same-video expectedFrame=\(expectedFrameIndex) toleranceFrames=\(toleranceFrames)",
                        category: .ui
                    )
                }
                return
            }

            guard currentSeekGeneration == self.seekGeneration else {
                if self.shouldLogSeekDiagnostics(for: debugContext) {
                    Log.debug(
                        "[FILTER-VIDEO] seekStale path=same-video expectedFrame=\(expectedFrameIndex) finishedGeneration=\(currentSeekGeneration) currentGeneration=\(self.seekGeneration)",
                        category: .ui
                    )
                }
                return
            }

            let actualTime = activePlayer?.currentTime() ?? .zero
            let actualFrameIndex = Self.frameIndex(for: actualTime, frameRate: frameRate)
            self.logSeekResult(
                phase: "same-video",
                expectedFrameIndex: expectedFrameIndex,
                actualFrameIndex: actualFrameIndex,
                frameRate: frameRate,
                toleranceFrames: toleranceFrames,
                debugContext: debugContext
            )

            DispatchQueue.main.async {
                self.onLoadSuccess?()
            }
        }
    }

    /// Load a video into the buffer player and swap when ready
    func loadVideoIntoBuffer(
        url: URL,
        seekTime: CMTime,
        frameIndex: Int,
        frameRate: Double,
        debugContext: VideoSeekDebugContext?
    ) {
        ensurePlayersReady()

        // Increment generation to invalidate any pending async callbacks
        loadGeneration &+= 1
        let currentGeneration = loadGeneration

        // Keep the active player visible until the buffer is ready
        // This prevents black flicker during video transitions

        let bufferPlayer = isPlayerAActive ? playerB : playerA
        let bufferObserver = isPlayerAActive ? observerB : observerA

        // Capture which player should become active after this load completes
        let expectedActiveAfterSwap = !isPlayerAActive

        // Clear previous observer
        bufferObserver?.invalidate()

        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let playerItem = AVPlayerItem(asset: asset)

        bufferPlayer?.replaceCurrentItem(with: playerItem)
        let tolerance = seekTolerance(for: frameRate)
        let toleranceFrames = configuredSeekToleranceFrames()

        // Observe when buffer player is ready
        let observer = playerItem.observe(\.status, options: [.new, .initial]) { [weak self] item, _ in
            guard let self = self else { return }

            // Check if this load is still valid (no newer load has started)
            guard currentGeneration == self.loadGeneration else {
                Log.debug("[VideoView] Ignoring stale status callback gen=\(currentGeneration), current=\(self.loadGeneration)", category: .ui)
                return
            }

            if item.status == .failed {
                if self.shouldLogSeekDiagnostics(for: debugContext) {
                    Log.warning(
                        "[FILTER-VIDEO] bufferLoadFailed expectedFrame=\(frameIndex) toleranceFrames=\(toleranceFrames)",
                        category: .ui
                    )
                }
                DispatchQueue.main.async {
                    self.onLoadFailed?()
                }
                return
            }

            guard item.status == .readyToPlay else { return }

            // Seek to target frame
            bufferPlayer?.seek(to: seekTime, toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] finished in
                guard let self = self else { return }

                guard finished else {
                    if self.shouldLogSeekDiagnostics(for: debugContext) {
                        Log.debug(
                            "[FILTER-VIDEO] seekCancelled path=buffer expectedFrame=\(frameIndex) toleranceFrames=\(toleranceFrames)",
                            category: .ui
                        )
                    }
                    return
                }

                // Re-check generation after async seek completes
                guard currentGeneration == self.loadGeneration else { return }

                let actualTime = bufferPlayer?.currentTime() ?? .zero
                let actualFrameIndex = Self.frameIndex(for: actualTime, frameRate: frameRate)
                self.logSeekResult(
                    phase: "buffer",
                    expectedFrameIndex: frameIndex,
                    actualFrameIndex: actualFrameIndex,
                    frameRate: frameRate,
                    toleranceFrames: toleranceFrames,
                    debugContext: debugContext
                )

                DispatchQueue.main.async {
                    // Final generation check on main thread before swap
                    guard currentGeneration == self.loadGeneration else { return }

                    // Verify we're swapping to the expected player
                    // If state drifted (shouldn't happen with generation check, but safety first)
                    guard self.isPlayerAActive != expectedActiveAfterSwap else { return }

                    bufferPlayer?.pause()
                    self.swapPlayers()
                    self.onLoadSuccess?()
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

    func releaseDecoderResources(reason: String) {
        loadGeneration &+= 1
        seekGeneration &+= 1

        observerA?.invalidate()
        observerA = nil
        observerB?.invalidate()
        observerB = nil

        release(player: playerA, playerView: playerViewA)
        release(player: playerB, playerView: playerViewB)
        playerA = nil
        playerB = nil

        isPlayerAActive = true
        playerViewA?.isHidden = false
        playerViewB?.isHidden = true

        Log.debug("[VideoView] Released decoder resources (\(reason))", category: .ui)
    }

    private func release(player: AVPlayer?, playerView: AVPlayerView?) {
        guard let player else {
            playerView?.player = nil
            return
        }

        player.pause()
        player.cancelPendingPrerolls()
        if let item = player.currentItem {
            item.cancelPendingSeeks()
            item.asset.cancelLoading()
        }
        player.replaceCurrentItem(with: nil)
        playerView?.player = nil
    }

    private func configuredSeekToleranceFrames() -> Int {
        let defaults = UserDefaults(suiteName: "io.retrace.app") ?? .standard
        let value = defaults.integer(forKey: "retrace.debug.timelineSeekToleranceFrames")
        return max(0, value)
    }

    private func seekTolerance(for frameRate: Double) -> CMTime {
        let toleranceFrames = configuredSeekToleranceFrames()
        guard toleranceFrames > 0 else { return .zero }
        let fps = frameRate > 0 ? frameRate : 30.0
        return CMTime(seconds: Double(toleranceFrames) / fps, preferredTimescale: 600)
    }

    private static func frameIndex(for time: CMTime, frameRate: Double) -> Int {
        let seconds = CMTimeGetSeconds(time)
        guard seconds.isFinite else { return -1 }
        let fps = frameRate > 0 ? frameRate : 30.0
        return Int((seconds * fps).rounded())
    }

    private func shouldLogSeekDiagnostics(for debugContext: VideoSeekDebugContext?) -> Bool {
        Self.isFilteredSeekDiagnosticsEnabled && (debugContext?.hasActiveFilters ?? false)
    }

    private func logSeekResult(
        phase: String,
        expectedFrameIndex: Int,
        actualFrameIndex: Int,
        frameRate: Double,
        toleranceFrames: Int,
        debugContext: VideoSeekDebugContext?
    ) {
        guard shouldLogSeekDiagnostics(for: debugContext), let debugContext else { return }

        let expectedInFilteredSet = debugContext.containsFilteredFrameIndex(expectedFrameIndex)
        let actualInFilteredSet = debugContext.containsFilteredFrameIndex(actualFrameIndex)
        let mismatch = actualFrameIndex != expectedFrameIndex
        let unexpectedFilteredFrame = !actualInFilteredSet
        let nearestFiltered = debugContext.nearestFilteredFrameIndices(around: actualFrameIndex)
        let level = (mismatch || unexpectedFilteredFrame) ? "warning" : "debug"

        let message =
            "[FILTER-VIDEO] seekResult phase=\(phase) level=\(level) frameID=\(debugContext.frameID) idx=\(debugContext.currentIndex) ts=\(debugContext.timestamp) " +
            "bundle=\(debugContext.frameBundleID ?? "nil") selectedApps=[\(debugContext.selectedAppsLabel)] " +
            "expectedFrame=\(expectedFrameIndex) actualFrame=\(actualFrameIndex) expectedInFilteredSet=\(expectedInFilteredSet) actualInFilteredSet=\(actualInFilteredSet) " +
            "nearestFiltered=[\(nearestFiltered)] frameRate=\(String(format: "%.3f", frameRate)) toleranceFrames=\(toleranceFrames)"

        if mismatch || unexpectedFilteredFrame {
            Log.warning(message, category: .ui)
        } else {
            Log.debug(message, category: .ui)
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
    }

    deinit {
        releaseDecoderResources(reason: "DoubleBufferedVideoView deinit")
    }
}

// MARK: - Frame With URL Overlay

/// Wraps a frame display with an interactive URL bounding box overlay
/// Shows a dotted rectangle when hovering over a detected URL, with click-to-open functionality
/// When zoom region is active, shows enlarged region centered with darkened/blurred background
/// Supports trackpad pinch-to-zoom for zooming in/out of the frame
struct FrameWithURLOverlay<Content: View>: View {
    @ObservedObject var viewModel: SimpleTimelineViewModel
    @EnvironmentObject var coordinatorWrapper: AppCoordinatorWrapper
    let onURLClicked: () -> Void
    let content: () -> Content

    var body: some View {
        GeometryReader { geometry in
            let showFinal = viewModel.isZoomRegionActive && viewModel.zoomRegion != nil
            let showTransition = viewModel.isZoomTransitioning && viewModel.zoomRegion != nil
            let showExitTransition = viewModel.isZoomExitTransitioning && viewModel.zoomRegion != nil
            let showNormal = !viewModel.isZoomRegionActive && !viewModel.isZoomTransitioning && !viewModel.isZoomExitTransitioning

            // Calculate actual frame rect for coordinate transformations
            let actualFrameRect = calculateActualDisplayedFrameRect(
                containerSize: geometry.size,
                viewModel: viewModel
            )
            let shouldGuideHideControlsInContextMenu = shouldGuideHideControlsRow(
                containerSize: geometry.size,
                actualFrameRect: actualFrameRect
            )
            let showsHyperlinkVisualOverlays = !viewModel.isInLiveMode
            let openHyperlink: (OCRHyperlinkMatch) -> Void = { match in
                let didOpen = viewModel.openHyperlinkMatch(match)
                if didOpen {
                    // Keep browser frontmost after opening external link.
                    TimelineWindowController.shared.hide(restorePreviousFocus: false)
                }
            }
            let hyperlinkContextMenuEntries = (showsHyperlinkVisualOverlays ? viewModel.hyperlinkMatches : []).compactMap { match -> HyperlinkContextMenuEntry? in
                let rect = transformedHyperlinkContextMenuRect(
                    for: match,
                    actualFrameRect: actualFrameRect,
                    containerSize: geometry.size,
                    scale: viewModel.frameZoomScale,
                    offset: viewModel.frameZoomOffset
                )
                guard rect.width > 1, rect.height > 1 else { return nil }
                return HyperlinkContextMenuEntry(match: match, rect: rect)
            }

            ZStack {
                // The actual frame content (always present as base layer)
                // Apply frame zoom transformations (magnification handled at window level)
                content()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .scaleEffect(viewModel.frameZoomScale)
                    .offset(viewModel.frameZoomOffset)

                // Unified zoom overlay - handles transition, final state, AND exit animation
                // Uses the same view instance throughout to avoid VideoView reload flicker
                if (showFinal || showTransition || showExitTransition), let region = viewModel.zoomRegion {
                    ZoomUnifiedOverlay(
                        viewModel: viewModel,
                        zoomRegion: region,
                        containerSize: geometry.size,
                        actualFrameRect: actualFrameRect,
                        isTransitioning: showTransition,
                        isExitTransitioning: showExitTransition
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
                    // Always render to allow shift-drag zoom region even when OCR nodes are empty (e.g., during/after scrolling)
                    TextSelectionOverlay(
                        viewModel: viewModel,
                        containerSize: geometry.size,
                        actualFrameRect: actualFrameRect,
                        hyperlinkMatches: viewModel.hyperlinkMatches,
                        onHyperlinkOpen: openHyperlink,
                        isInteractionDisabled: viewModel.isInLiveMode && viewModel.ocrNodes.isEmpty,
                        onDragStart: { point, isCommandDrag in
                            viewModel.startDragSelection(
                                at: point,
                                mode: isCommandDrag ? .box : .character
                            )
                        },
                        onDragUpdate: { point, isCommandDrag in
                            viewModel.updateDragSelection(
                                to: point,
                                mode: isCommandDrag ? .box : .character
                            )
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

                    // URL bounding box overlay (if URL detected)
                    if showsHyperlinkVisualOverlays, let box = viewModel.urlBoundingBox {
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
                                // Keep browser frontmost after opening external link.
                                TimelineWindowController.shared.hide(restorePreviousFocus: false)
                            }
                        )
                        // Apply the same zoom transformations as the frame content
                        .scaleEffect(viewModel.frameZoomScale)
                        .offset(viewModel.frameZoomOffset)
                    }

                    if showsHyperlinkVisualOverlays, !viewModel.hyperlinkMatches.isEmpty {
                        OCRHyperlinkOverlay(
                            matches: viewModel.hyperlinkMatches,
                            actualFrameRect: actualFrameRect,
                            onHoverChanged: { match in
                                viewModel.updateInPageURLHoverState(match)
                            },
                            onOpen: openHyperlink
                        )
                        .scaleEffect(viewModel.frameZoomScale)
                        .offset(viewModel.frameZoomOffset)
                    }
                }

            }
            .onRightClick(
                hyperlinkEntries: hyperlinkContextMenuEntries,
                onHyperlinkRightClick: { match in
                    viewModel.recordInPageURLRightClick(for: match)
                },
                onHyperlinkCopy: { match in
                    _ = viewModel.copyHyperlinkMatch(match)
                }
            ) { location in
                // Keep right-clicks on the floating filter card from opening the frame menu behind it.
                guard !viewModel.isFilterPanelVisible else { return }
                viewModel.contextMenuLocation = location
                withAnimation(.easeOut(duration: 0.16)) {
                    viewModel.showContextMenu = true
                }
            }
            .overlay(
                // Floating context menu at click location
                Group {
                    if viewModel.showContextMenu {
                        FloatingContextMenu(
                            viewModel: viewModel,
                            isPresented: $viewModel.showContextMenu,
                            location: viewModel.contextMenuLocation,
                            containerSize: geometry.size,
                            highlightHideControlsRow: shouldGuideHideControlsInContextMenu
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
        if viewModel.isInLiveMode, let liveImage = viewModel.liveScreenshot {
            // Live mode: use screenshot dimensions (must check BEFORE videoInfo,
            // since videoInfo may still be set from the last recorded frame with a different aspect ratio)
            frameSize = CGSize(
                width: liveImage.representations.first?.pixelsWide ?? Int(liveImage.size.width),
                height: liveImage.representations.first?.pixelsHigh ?? Int(liveImage.size.height)
            )
        } else if let videoInfo = viewModel.currentVideoInfo,
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

    /// Keep menu guidance behavior aligned with the top hint shown when highlighted OCR sits near the tape.
    private func shouldGuideHideControlsRow(containerSize: CGSize, actualFrameRect: CGRect) -> Bool {
        guard viewModel.isShowingSearchHighlight else { return false }
        guard !viewModel.areControlsHidden else { return false }
        guard !viewModel.isInFrameSearchVisible else { return false }

        let highlightCutoffY = containerSize.height * 0.75
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
}

private func transformedHyperlinkContextMenuRect(
    for match: OCRHyperlinkMatch,
    actualFrameRect: CGRect,
    containerSize: CGSize,
    scale: CGFloat,
    offset: CGSize
) -> CGRect {
    let rect = CGRect(
        x: actualFrameRect.origin.x + (match.highlightX * actualFrameRect.width),
        y: actualFrameRect.origin.y + (match.y * actualFrameRect.height),
        width: match.highlightWidth * actualFrameRect.width,
        height: match.height * actualFrameRect.height
    )

    guard scale != 1 else {
        return rect.offsetBy(dx: offset.width, dy: offset.height)
    }

    let center = CGPoint(x: containerSize.width / 2, y: containerSize.height / 2)
    let scaledOrigin = CGPoint(
        x: center.x + ((rect.origin.x - center.x) * scale) + offset.width,
        y: center.y + ((rect.origin.y - center.y) * scale) + offset.height
    )

    return CGRect(
        origin: scaledOrigin,
        size: CGSize(width: rect.width * scale, height: rect.height * scale)
    )
}

struct HyperlinkContextMenuEntry {
    let match: OCRHyperlinkMatch
    let rect: CGRect
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

/// Shape that fills the entire available rect, with a rounded-rect "cutout" using even-odd fill.
/// This avoids reliance on `.reverseMask` (destinationOut) which can produce one-frame flashes
/// during fast state swaps and also ensures the cutout is animatable.
struct InverseRoundedRectCutout: Shape {
    var cutoutRect: CGRect
    var cornerRadius: CGFloat

    var animatableData: AnimatablePair<
        AnimatablePair<CGFloat, CGFloat>,
        AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGFloat>
    > {
        get {
            .init(
                .init(cutoutRect.origin.x, cutoutRect.origin.y),
                .init(.init(cutoutRect.size.width, cutoutRect.size.height), cornerRadius)
            )
        }
        set {
            cutoutRect.origin.x = newValue.first.first
            cutoutRect.origin.y = newValue.first.second
            cutoutRect.size.width = newValue.second.first.first
            cutoutRect.size.height = newValue.second.first.second
            cornerRadius = newValue.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRect(rect)
        path.addRoundedRect(
            in: cutoutRect,
            cornerSize: CGSize(width: cornerRadius, height: cornerRadius)
        )
        return path
    }
}

/// Unified overlay that handles BOTH the transition animation AND the final zoom state
/// Uses a single view instance throughout to avoid VideoView reload flicker during handoff
/// When isTransitioning=true, animates based on progress; when false, shows final state with text selection
struct ZoomUnifiedOverlay<Content: View>: View {
    @ObservedObject var viewModel: SimpleTimelineViewModel
    let zoomRegion: CGRect
    let containerSize: CGSize
    let actualFrameRect: CGRect
    let isTransitioning: Bool
    let isExitTransitioning: Bool
    let content: () -> Content

    // Local state for animation - this allows SwiftUI to interpolate
    @State private var animationProgress: CGFloat = 0
    // Freeze a snapshot for the zoom overlay so we don't instantiate a second AVPlayer-backed view.
    @State private var frozenZoomSnapshot: NSImage?

    @MainActor
    private func startLocalTransitionAnimation() {
        animationProgress = 0
        // Kick to next run loop so the 0 state is committed before we animate to 1.
        DispatchQueue.main.async {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                animationProgress = 1.0
            }
        }
    }

    @MainActor
    private func startExitAnimation() {
        // Animate from 1 back to 0
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            animationProgress = 0.0
        }
    }

    @ViewBuilder
    private func zoomedContentView() -> some View {
        if viewModel.isInLiveMode {
            ZStack {
                Color.black
                if let snapshot = frozenZoomSnapshot {
                    Image(nsImage: snapshot)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .transition(.identity)
                } else {
                    content()
                        .transition(.identity)
                }
            }
        } else {
            // Historical mode prefers extractor-backed snapshots for frame accuracy.
            // Fall back to content() when extraction misses so we don't render a black pane.
            ZStack {
                Color.black
                if let snapshot = frozenZoomSnapshot {
                    Image(nsImage: snapshot)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .transition(.identity)
                } else {
                    content()
                        .transition(.identity)
                }
            }
        }
    }

    var body: some View {
        // Use local animationProgress for smooth interpolation
        // For exit transition, we animate from 1 to 0
        // For enter transition, we animate from 0 to 1
        // For final state, progress is 1.0
        let progress: CGFloat = (isTransitioning || isExitTransitioning) ? animationProgress : 1.0

        let _ = Log.debug("[ZoomDismiss] ZoomUnifiedOverlay rendered - isTransitioning: \(isTransitioning), isExitTransitioning: \(isExitTransitioning), progress: \(progress)", category: .ui)

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

        // Calculate end position (offset left to make room for action menu on right)
        let menuWidth: CGFloat = 180
        let menuGap: CGFloat = 30  // Gap between zoomed region and menu
        let maxWidth = containerSize.width * 0.70  // More space for the zoomed image
        let maxHeight = containerSize.height * 0.75
        let regionWidth = zoomRegion.width * actualFrameRect.width
        let regionHeight = zoomRegion.height * actualFrameRect.height
        let scaleToFit = min(maxWidth / regionWidth, maxHeight / regionHeight)
        let enlargedWidth = regionWidth * scaleToFit
        let enlargedHeight = regionHeight * scaleToFit

        // Offset to the left: center of (available space minus menu area)
        let availableWidth = containerSize.width - menuWidth - menuGap
        let endRect = CGRect(
            x: (availableWidth - enlargedWidth) / 2,
            y: (containerSize.height - enlargedHeight) / 2,
            width: enlargedWidth,
            height: enlargedHeight
        )

        // Menu position (to the right of the zoomed region)
        let menuX = endRect.maxX + menuGap
        let menuY = endRect.midY

        // Interpolate all values based on progress (0 = start, 1 = end)
        // This ensures smooth animation without discrete jumps
        let targetRect = CGRect(
            x: lerp(startRect.origin.x, endRect.origin.x, progress),
            y: lerp(startRect.origin.y, endRect.origin.y, progress),
            width: lerp(startRect.width, endRect.width, progress),
            height: lerp(startRect.height, endRect.height, progress)
        )
        let targetScale = lerp(1.0, scaleToFit, progress)
        let targetBlur = progress  // 0 to 1 directly

        // Center of zoom region in original content (screen coords)
        // Y is already in top-down space, so no flip needed
        let zoomCenterX = actualFrameRect.origin.x + (zoomRegion.origin.x + zoomRegion.width / 2) * actualFrameRect.width
        let zoomCenterY = actualFrameRect.origin.y + (zoomRegion.origin.y + zoomRegion.height / 2) * actualFrameRect.height

        // Calculate final offset to position the zoom region center at the endRect center
        // After scaling, the zoom region center moves. We need to offset so it lands at endRect.midX/Y
        // The content is centered at containerSize/2 before offset
        // After scaleEffect, the zoomCenter is at: containerSize/2 + (zoomCenterX - containerSize.width/2) * scaleToFit
        // We want it at endRect.midX, so offset = endRect.midX - (containerSize.width/2 + (zoomCenterX - containerSize.width/2) * scaleToFit)
        let scaledZoomCenterX = containerSize.width / 2 + (zoomCenterX - containerSize.width / 2) * scaleToFit
        let scaledZoomCenterY = containerSize.height / 2 + (zoomCenterY - containerSize.height / 2) * scaleToFit
        let finalOffsetX = endRect.midX - scaledZoomCenterX
        let finalOffsetY = endRect.midY - scaledZoomCenterY
        let targetOffsetX = lerp(0.0, finalOffsetX, progress)
        let targetOffsetY = lerp(0.0, finalOffsetY, progress)

        // Content and border animate together from start position
        // Dimming stays constant throughout - no fade, just like during drag
        ZStack {
            // LAYER 1: Dismiss overlay - full screen, tappable to exit zoom
            // Bottom layer to catch clicks that pass through all other layers
            if !isTransitioning && !isExitTransitioning {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        Log.debug("[ZoomDismiss] Dismiss overlay tapped - exiting zoom region", category: .ui)
                        viewModel.exitZoomRegion()
                    }
            }

            // LAYER 2: Light blur on the background - visual only, no interaction
            Rectangle()
                .fill(.regularMaterial)
                .opacity(targetBlur * 0.3)
                .allowsHitTesting(false)

            // LAYER 3: Darken outside the rectangle - visual only, no interaction
            InverseRoundedRectCutout(
                cutoutRect: targetRect,
                cornerRadius: 12
            )
            .fill(Color.black.opacity(0.6), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)

            // LAYER 4: The zoomed content - visual only (interaction handled by overlay on top)
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.black)
                .frame(width: targetRect.width, height: targetRect.height)
                .position(x: targetRect.midX, y: targetRect.midY)
                .allowsHitTesting(false)

            // LAYER 5: The zoomed content - visual only (interaction handled by overlay on top)
            zoomedContentView()
                .frame(width: containerSize.width, height: containerSize.height)
                .scaleEffect(targetScale, anchor: .center)
                .offset(x: targetOffsetX, y: targetOffsetY)
                .compositingGroup()
                .mask {
                    RoundedRectangle(cornerRadius: 12)
                        .frame(width: targetRect.width, height: targetRect.height)
                        .position(x: targetRect.midX, y: targetRect.midY)
                }
                .allowsHitTesting(false)

            // LAYER 6: White border - visual only, no interaction
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.9), lineWidth: lerp(2, 3, progress))
                .frame(width: targetRect.width, height: targetRect.height)
                .position(x: targetRect.midX, y: targetRect.midY)
                .allowsHitTesting(false)

            // LAYER 7: Text selection overlay - interactive within zoomed region only
            if !isTransitioning && !isExitTransitioning && !viewModel.ocrNodes.isEmpty {
                ZoomedTextSelectionOverlay(
                    viewModel: viewModel,
                    zoomRegion: zoomRegion,
                    containerSize: containerSize,
                    zoomedRect: endRect
                )
                // This layer handles text selection - allows hit testing only within its bounds
            }

            // LAYER 8: Action menu - interactive, should receive clicks
            ZoomActionMenu(
                viewModel: viewModel,
                zoomRegion: zoomRegion
            )
            .frame(width: menuWidth)
            .position(x: menuX + menuWidth / 2, y: menuY)
            .opacity(progress)
            .offset(x: lerp(30, 0, progress))
            .onTapGesture {
                // This catches clicks on the menu background to prevent dismissal
                Log.debug("[ZoomDismiss] Menu area tapped - ignoring", category: .ui)
            }
        }
        .allowsHitTesting(!isTransitioning && !isExitTransitioning)
        // Animate all interpolated values together
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: animationProgress)
        // Never fade/cross-dissolve when snapshot is swapped mid-transition.
        .animation(nil, value: viewModel.shiftDragDisplaySnapshotFrameID)
        .onAppear {
            // Always capture fresh snapshot when appearing - don't reuse stale snapshots
            // from previous zoom sessions that may have persisted in @State
            frozenZoomSnapshot = (viewModel.isInLiveMode ? viewModel.liveScreenshot : nil) ?? viewModel.shiftDragDisplaySnapshot

            // Start at 0 when appearing during enter transition
            if isTransitioning {
                startLocalTransitionAnimation()
            } else if isExitTransitioning {
                // Start at 1 when appearing during exit (shouldn't normally happen)
                animationProgress = 1.0
                startExitAnimation()
            } else {
                animationProgress = 1.0
            }
        }
        .onChange(of: isTransitioning) { newValue in
            if newValue {
                frozenZoomSnapshot = (viewModel.isInLiveMode ? viewModel.liveScreenshot : nil) ?? viewModel.shiftDragDisplaySnapshot
                startLocalTransitionAnimation()
            }
        }
        .onChange(of: isExitTransitioning) { newValue in
            if newValue {
                startExitAnimation()
            }
        }
        .onChange(of: viewModel.shiftDragDisplaySnapshot) { newValue in
            // If the extractor snapshot arrives after transition start, adopt it immediately.
            if (isTransitioning || !viewModel.isInLiveMode), let image = newValue {
                var noAnimationTransaction = Transaction()
                noAnimationTransaction.animation = nil
                withTransaction(noAnimationTransaction) {
                    frozenZoomSnapshot = image
                }
            }
        }
    }

    /// Linear interpolation helper
    private func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat {
        a + (b - a) * t
    }
}

// MARK: - Zoom Action Menu

/// Action menu that appears on the right side of the zoomed region
struct ZoomActionMenu: View {
    @ObservedObject var viewModel: SimpleTimelineViewModel
    let zoomRegion: CGRect

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Share
            ZoomActionMenuRow(title: "Share", icon: "square.and.arrow.up") {
                shareZoomedImage()
            }

            // Copy Image
            ZoomActionMenuRow(title: "Copy Image", icon: "doc.on.doc") {
                copyZoomedImageToClipboard()
            }

            // Copy Text (only if text is selected or OCR nodes exist in region)
            if hasTextInZoomRegion {
                ZoomActionMenuRow(title: "Copy Text", icon: "doc.on.clipboard") {
                    copyTextFromZoomRegion()
                }
            }

            Divider()
                .background(Color.white.opacity(0.1))
                .padding(.vertical, 4)

            // Save Image
            ZoomActionMenuRow(title: "Save Image", icon: "square.and.arrow.down") {
                saveZoomedImage()
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: RetraceMenuStyle.cornerRadius)
                .fill(RetraceMenuStyle.backgroundColor)
                .shadow(
                    color: RetraceMenuStyle.shadowColor,
                    radius: RetraceMenuStyle.shadowRadius,
                    y: RetraceMenuStyle.shadowY
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: RetraceMenuStyle.cornerRadius)
                .stroke(Color.white.opacity(0.9), lineWidth: 2)
        )
    }

    private var hasTextInZoomRegion: Bool {
        // Check if there are any OCR nodes within the zoom region
        !viewModel.ocrNodes.isEmpty && viewModel.ocrNodes.contains { node in
            let nodeRight = node.x + node.width
            let nodeBottom = node.y + node.height
            let regionRight = zoomRegion.origin.x + zoomRegion.width
            let regionBottom = zoomRegion.origin.y + zoomRegion.height

            return nodeRight > zoomRegion.origin.x &&
                   node.x < regionRight &&
                   nodeBottom > zoomRegion.origin.y &&
                   node.y < regionBottom
        }
    }

    private func shareZoomedImage() {
        getZoomedImage { image in
            guard let image = image else {
                return
            }

            let picker = NSSharingServicePicker(items: [image])
            if let window = NSApp.keyWindow,
               let contentView = window.contentView {
                // Show share picker near the right side of the window where the action menu is
                // Position it roughly where the Share button would be (right side, upper-middle area)
                let menuRect = CGRect(
                    x: contentView.bounds.width - 200,
                    y: contentView.bounds.height / 2,
                    width: 180,
                    height: 40
                )
                picker.show(relativeTo: menuRect, of: contentView, preferredEdge: .minX)

                // Check multiple times for the picker window to appear
                for delay in [0.05, 0.1, 0.2, 0.5] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        for appWindow in NSApp.windows {
                            let className = String(describing: type(of: appWindow))

                            // Raise any window that's not our main windows and is below screenSaver level
                            // Exclude: status bar, timeline (KeyableWindow), and dashboard (NSWindow at level 0)
                            let isStatusBar = className == "NSStatusBarWindow"
                            let isTimeline = className == "KeyableWindow"
                            let isDashboard = className == "NSWindow" && appWindow.level.rawValue == 0

                            if appWindow.level.rawValue < NSWindow.Level.screenSaver.rawValue &&
                               appWindow.isVisible &&
                               !isStatusBar &&
                               !isTimeline &&
                               !isDashboard {
                                appWindow.level = .screenSaver + 1
                            }
                        }
                    }
                }
            }
        }
    }

    private func copyZoomedImageToClipboard() {
        getZoomedImage { image in
            guard let image = image else { return }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.writeObjects([image])
        }
        viewModel.exitZoomRegion()
    }

    private func copyTextFromZoomRegion() {
        // Get text from OCR nodes within the zoom region
        let textInRegion = viewModel.ocrNodes
            .filter { node in
                let nodeRight = node.x + node.width
                let nodeBottom = node.y + node.height
                let regionRight = zoomRegion.origin.x + zoomRegion.width
                let regionBottom = zoomRegion.origin.y + zoomRegion.height

                return nodeRight > zoomRegion.origin.x &&
                       node.x < regionRight &&
                       nodeBottom > zoomRegion.origin.y &&
                       node.y < regionBottom
            }
            .sorted { ($0.y, $0.x) < ($1.y, $1.x) }  // Sort top-to-bottom, left-to-right
            .map { $0.text }
            .joined(separator: " ")

        if !textInRegion.isEmpty {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(textInRegion, forType: .string)
        }
        viewModel.exitZoomRegion()
    }

    private func saveZoomedImage() {
        getZoomedImage { image in
            guard let image = image else { return }

            let savePanel = NSSavePanel()
            savePanel.allowedContentTypes = [.png]
            savePanel.nameFieldStringValue = "retrace-zoom-\(formattedTimestamp()).png"
            savePanel.level = .screenSaver + 1

            savePanel.begin { response in
                if response == .OK, let url = savePanel.url {
                    if let tiffData = image.tiffRepresentation,
                       let bitmap = NSBitmapImageRep(data: tiffData),
                       let pngData = bitmap.representation(using: .png, properties: [:]) {
                        try? pngData.write(to: url)
                    }
                }
            }
        }
    }

    private func getZoomedImage(completion: @escaping (NSImage?) -> Void) {
        guard let fullImage = (viewModel.isInLiveMode ? viewModel.liveScreenshot : nil) ?? viewModel.displayableCurrentImage else {
            completion(nil)
            return
        }

        // Crop the full image to the zoom region
        // zoomRegion coordinates are normalized (0-1) relative to actualFrameRect
        // Both zoomRegion.origin.y and CGImage use bottom-up coordinate space (0=bottom)
        // so no Y-flip is needed
        let imageSize = fullImage.size
        let cropRect = CGRect(
            x: zoomRegion.origin.x * imageSize.width,
            y: zoomRegion.origin.y * imageSize.height,
            width: zoomRegion.width * imageSize.width,
            height: zoomRegion.height * imageSize.height
        )

        guard let cgImage = fullImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            completion(nil)
            return
        }

        guard let croppedCGImage = cgImage.cropping(to: cropRect) else {
            completion(nil)
            return
        }

        let croppedImage = NSImage(cgImage: croppedCGImage, size: NSSize(width: cropRect.width, height: cropRect.height))
        completion(croppedImage)
    }

    private func formattedTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter.string(from: viewModel.currentTimestamp ?? Date())
    }
}

/// Styled menu row for zoom action menu
struct ZoomActionMenuRow: View {
    let title: String
    let icon: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: RetraceMenuStyle.iconTextSpacing) {
                Image(systemName: icon)
                    .font(.system(size: RetraceMenuStyle.iconSize, weight: RetraceMenuStyle.fontWeight))
                    .foregroundColor(isHovering ? RetraceMenuStyle.textColor : RetraceMenuStyle.textColorMuted)
                    .frame(width: RetraceMenuStyle.iconFrameWidth)

                Text(title)
                    .font(RetraceMenuStyle.font)
                    .foregroundColor(isHovering ? RetraceMenuStyle.textColor : RetraceMenuStyle.textColorMuted)

                Spacer()
            }
            .padding(.horizontal, RetraceMenuStyle.itemPaddingH)
            .padding(.vertical, RetraceMenuStyle.itemPaddingV)
            .background(
                RoundedRectangle(cornerRadius: RetraceMenuStyle.itemCornerRadius)
                    .fill(isHovering ? RetraceMenuStyle.itemHoverColor : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: RetraceMenuStyle.hoverAnimationDuration)) {
                isHovering = hovering
            }
            if hovering { NSCursor.pointingHand.push() }
            else { NSCursor.pop() }
        }
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
struct ZoomBackgroundOverlay: View {
    var body: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            .overlay(Color.black.opacity(0.45))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                    containerSize: containerSize,
                    zoomedRect: finalRect
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
    let zoomedRect: CGRect  // The actual position and size of the zoomed region

    var body: some View {
        ZoomedTextSelectionNSView(
            viewModel: viewModel,
            zoomRegion: zoomRegion,
            enlargedSize: CGSize(width: zoomedRect.width, height: zoomedRect.height),
            containerSize: containerSize
        )
        .frame(width: zoomedRect.width, height: zoomedRect.height)
        .position(x: zoomedRect.midX, y: zoomedRect.midY)
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
        view.onDragStart = { point, isCommandDrag in
            viewModel.startDragSelection(
                at: point,
                mode: isCommandDrag ? .box : .character
            )
        }
        view.onDragUpdate = { point, isCommandDrag in
            viewModel.updateDragSelection(
                to: point,
                mode: isCommandDrag ? .box : .character
            )
        }
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

        // Keep cursor state in sync when node geometry changes while hovering.
        nsView.refreshCursorForCurrentMouseLocation()
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

    var onDragStart: ((CGPoint, Bool) -> Void)?
    var onDragUpdate: ((CGPoint, Bool) -> Void)?
    var onDragEnd: (() -> Void)?
    var onClearSelection: (() -> Void)?
    var onCopyImage: (() -> Void)?
    var onDoubleClick: ((CGPoint) -> Void)?
    var onTripleClick: ((CGPoint) -> Void)?

    private var isDragging = false
    private var isCommandDragging = false
    private var hasMoved = false
    private var mouseDownPoint: CGPoint = .zero
    private var commandDragStartPoint: CGPoint?
    private var commandDragCurrentPoint: CGPoint?
    private var trackingArea: NSTrackingArea?
    private var isShowingIBeamCursor = false
    private let boundingBoxPadding: CGFloat = 8.0

    override var acceptsFirstResponder: Bool { true }

    deinit {
        if isShowingIBeamCursor {
            NSCursor.pop()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let options: NSTrackingArea.Options = [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited]
        trackingArea = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
        addTrackingArea(trackingArea!)
        refreshCursorForCurrentMouseLocation()
    }

    func refreshCursorForCurrentMouseLocation() {
        guard let window else { return }
        let location = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        updateCursorForLocation(location)
    }

    override func mouseMoved(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        updateCursorForLocation(location)
    }

    override func mouseExited(with event: NSEvent) {
        if isShowingIBeamCursor {
            NSCursor.pop()
            isShowingIBeamCursor = false
        }
    }

    private func isNearAnyNode(screenPoint: CGPoint) -> Bool {
        nodeData.contains { node in
            node.rect.insetBy(dx: -boundingBoxPadding, dy: -boundingBoxPadding).contains(screenPoint)
        }
    }

    private func updateCursorForLocation(_ location: CGPoint) {
        let isNearNode = isNearAnyNode(screenPoint: location)

        if isNearNode && !isShowingIBeamCursor {
            NSCursor.iBeam.push()
            isShowingIBeamCursor = true
        } else if !isNearNode && isShowingIBeamCursor {
            NSCursor.pop()
            isShowingIBeamCursor = false
        }
    }

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        mouseDownPoint = location
        hasMoved = false
        commandDragStartPoint = nil
        commandDragCurrentPoint = nil

        // Convert to original frame coordinates
        let normalizedPoint = screenToOriginalCoords(location)
        let isCommandDrag = event.modifierFlags.contains(.command)

        // Handle multi-click (double-click = word, triple-click = line)
        let clickCount = event.clickCount
        Log.debug("[ZoomedSelectionView] mouseDown clickCount=\(clickCount) isDragging=\(isDragging)", category: .ui)
        if clickCount == 2, !isCommandDrag {
            Log.debug("[ZoomedSelectionView] Double-click detected, calling onDoubleClick", category: .ui)
            onDoubleClick?(normalizedPoint)
            isDragging = false
            isCommandDragging = false
        } else if clickCount >= 3, !isCommandDrag {
            Log.debug("[ZoomedSelectionView] Triple-click detected, calling onTripleClick", category: .ui)
            onTripleClick?(normalizedPoint)
            isDragging = false
            isCommandDragging = false
        } else {
            isDragging = true
            isCommandDragging = isCommandDrag
            if isCommandDragging {
                commandDragStartPoint = location
                commandDragCurrentPoint = location
            }
            onDragStart?(normalizedPoint, isCommandDragging)
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
        if isCommandDragging {
            commandDragCurrentPoint = CGPoint(x: clampedX, y: clampedY)
        }
        onDragUpdate?(normalizedPoint, isCommandDragging)
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
        isCommandDragging = false
        commandDragStartPoint = nil
        commandDragCurrentPoint = nil
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

        // Show marquee preview while Cmd+dragging.
        if isDragging,
           isCommandDragging,
           let start = commandDragStartPoint,
           let end = commandDragCurrentPoint {
            let marqueeRect = NSRect(
                x: min(start.x, end.x),
                y: min(start.y, end.y),
                width: abs(end.x - start.x),
                height: abs(end.y - start.y)
            )

            let fillColor = NSColor(red: 100/255, green: 160/255, blue: 230/255, alpha: 0.15)
            fillColor.setFill()
            let fillPath = NSBezierPath(roundedRect: marqueeRect, xRadius: 4, yRadius: 4)
            fillPath.fill()

            let borderPath = NSBezierPath(roundedRect: marqueeRect, xRadius: 4, yRadius: 4)
            borderPath.lineWidth = 1.5
            borderPath.setLineDash([6, 4], count: 2, phase: 0)
            NSColor(red: 100/255, green: 160/255, blue: 230/255, alpha: 0.95).setStroke()
            borderPath.stroke()
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
                    RoundedRectangle(cornerRadius: 12)
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                }

            // White border around selection
            RoundedRectangle(cornerRadius: 12)
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

struct OCRHyperlinkOverlay: NSViewRepresentable {
    let matches: [OCRHyperlinkMatch]
    let actualFrameRect: CGRect
    let onHoverChanged: (OCRHyperlinkMatch?) -> Void
    let onOpen: (OCRHyperlinkMatch) -> Void

    func makeNSView(context: Context) -> OCRHyperlinkOverlayView {
        let view = OCRHyperlinkOverlayView()
        view.onHoverChanged = onHoverChanged
        view.onOpen = onOpen
        return view
    }

    func updateNSView(_ nsView: OCRHyperlinkOverlayView, context: Context) {
        nsView.onHoverChanged = onHoverChanged
        nsView.onOpen = onOpen
        nsView.entries = matches.compactMap { match in
            let rect = CGRect(
                x: actualFrameRect.origin.x + (match.highlightX * actualFrameRect.width),
                y: actualFrameRect.origin.y + (match.y * actualFrameRect.height),
                width: match.highlightWidth * actualFrameRect.width,
                height: match.height * actualFrameRect.height
            )
            guard rect.width > 1, rect.height > 1 else { return nil }
            return OCRHyperlinkOverlayView.Entry(match: match, rect: rect)
        }
    }
}

final class OCRHyperlinkOverlayView: NSView {
    struct Entry {
        let match: OCRHyperlinkMatch
        let rect: CGRect

        // Ignore transient row order so the same logical link stays hovered across remaps.
        var hoverKey: String {
            "\(match.nodeID)|\(match.url)"
        }
    }

    var entries: [Entry] = [] {
        didSet {
            if hoveredMatchKey.flatMap({ key in entries.first(where: { $0.hoverKey == key }) }) == nil {
                hoveredMatchKey = nil
            }
            needsDisplay = true
            needsLayout = true
            window?.invalidateCursorRects(for: self)
        }
    }

    var onHoverChanged: ((OCRHyperlinkMatch?) -> Void)?
    var onOpen: ((OCRHyperlinkMatch) -> Void)?

    private var trackingArea: NSTrackingArea?
    private var hoveredMatchKey: String?
    private let idleBorderOffset: CGFloat = 2.5
    private let idleBorderThickness: CGFloat = 1.25
    private let borderCornerRadius: CGFloat = 6
    private let interactionPadding: CGFloat = 3

    override var isFlipped: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let trackingArea {
            removeTrackingArea(trackingArea)
        }

        let options: NSTrackingArea.Options = [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect]
        let newTrackingArea = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
        addTrackingArea(newTrackingArea)
        trackingArea = newTrackingArea
    }

    override func resetCursorRects() {
        discardCursorRects()
        for entry in entries {
            addCursorRect(interactionRect(for: entry), cursor: .pointingHand)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard match(at: point) != nil else { return nil }
        return self
    }

    override func mouseEntered(with event: NSEvent) {
        updateHoverState(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        updateHoverState(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        setHoveredMatch(nil)
    }

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        guard let match = match(at: location) else {
            super.mouseDown(with: event)
            return
        }

        onOpen?(match)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        for entry in entries {
            guard entry.hoverKey != hoveredMatchKey else { continue }
            drawIdleBorder(for: entry)
        }

        if let hoveredEntry {
            let hoverRect = outlineRect(for: hoveredEntry)
            let path = NSBezierPath(
                roundedRect: hoverRect,
                xRadius: borderCornerRadius,
                yRadius: borderCornerRadius
            )
            path.lineWidth = 2
            path.setLineDash([5, 3], count: 2, phase: 0)

            NSColor.systemBlue.withAlphaComponent(0.20).setFill()
            path.fill()

            NSColor.systemBlue.withAlphaComponent(0.95).setStroke()
            path.stroke()
        }
    }

    private func match(at point: CGPoint) -> OCRHyperlinkMatch? {
        entries.first(where: { interactionRect(for: $0).contains(point) })?.match
    }

    private func updateHoverState(at point: CGPoint) {
        setHoveredMatch(
            entries.first(where: { interactionRect(for: $0).contains(point) })?.hoverKey
        )
    }

    private func setHoveredMatch(_ hoverKey: String?) {
        guard hoveredMatchKey != hoverKey else { return }
        hoveredMatchKey = hoverKey
        onHoverChanged?(hoveredEntry?.match)
        needsDisplay = true
    }

    private var hoveredEntry: Entry? {
        guard let hoveredMatchKey else { return nil }
        return entries.first(where: { $0.hoverKey == hoveredMatchKey })
    }

    private func drawIdleBorder(for entry: Entry) {
        let borderPath = NSBezierPath(
            roundedRect: outlineRect(for: entry),
            xRadius: borderCornerRadius,
            yRadius: borderCornerRadius
        )
        borderPath.lineWidth = idleBorderThickness
        NSColor.systemBlue.withAlphaComponent(0.58).setStroke()
        borderPath.stroke()
    }

    private func outlineRect(for entry: Entry) -> CGRect {
        entry.rect.insetBy(dx: -idleBorderOffset, dy: -idleBorderOffset)
    }

    private func interactionRect(for entry: Entry) -> CGRect {
        entry.rect.insetBy(dx: -interactionPadding, dy: -interactionPadding)
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
    let hyperlinkMatches: [OCRHyperlinkMatch]
    let onHyperlinkOpen: (OCRHyperlinkMatch) -> Void
    var isInteractionDisabled: Bool = false
    let onDragStart: (CGPoint, Bool) -> Void
    let onDragUpdate: (CGPoint, Bool) -> Void
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
        view.onHyperlinkOpen = onHyperlinkOpen
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
        nsView.onHyperlinkOpen = onHyperlinkOpen
        nsView.hyperlinkEntries = hyperlinkMatches.compactMap { match in
            let rect = NSRect(
                x: actualFrameRect.origin.x + (match.highlightX * actualFrameRect.width),
                y: actualFrameRect.origin.y + ((1.0 - match.y - match.height) * actualFrameRect.height),
                width: match.highlightWidth * actualFrameRect.width,
                height: match.height * actualFrameRect.height
            )
            guard rect.width > 1, rect.height > 1 else { return nil }
            return TextSelectionView.HyperlinkEntry(match: match, rect: rect)
        }
        nsView.isDraggingSelection = viewModel.dragStartPoint != nil
        nsView.isDraggingZoomRegion = viewModel.isDraggingZoomRegion
        nsView.isInteractionDisabled = isInteractionDisabled
        nsView.refreshCursorForCurrentMouseLocation()

        nsView.needsDisplay = true
    }
}

/// Custom NSView for text selection with mouse tracking
/// Supports both text selection (normal drag) and zoom region (Shift+Drag)
class TextSelectionView: NSView {
    private enum CursorMode {
        case none
        case iBeam
        case pointingHand
    }

    /// Data for each OCR node including selection state
    struct NodeData {
        let id: Int
        let rect: NSRect
        let text: String
        let selectionRange: (start: Int, end: Int)?  // Character range selected within this node
    }

    struct HyperlinkEntry {
        let match: OCRHyperlinkMatch
        let rect: NSRect
    }

    var nodeData: [NodeData] = []
    var containerSize: CGSize = .zero
    var actualFrameRect: CGRect = .zero
    var hyperlinkEntries: [HyperlinkEntry] = []
    var isDraggingSelection: Bool = false
    var isDraggingZoomRegion: Bool = false
    var isInteractionDisabled: Bool = false

    // Text selection callbacks
    var onDragStart: ((CGPoint, Bool) -> Void)?
    var onDragUpdate: ((CGPoint, Bool) -> Void)?
    var onDragEnd: (() -> Void)?
    var onClearSelection: (() -> Void)?

    // Zoom region callbacks
    var onZoomRegionStart: ((CGPoint) -> Void)?
    var onZoomRegionUpdate: ((CGPoint) -> Void)?
    var onZoomRegionEnd: (() -> Void)?

    // Multi-click callbacks
    var onDoubleClick: ((CGPoint) -> Void)?
    var onTripleClick: ((CGPoint) -> Void)?
    var onHyperlinkOpen: ((OCRHyperlinkMatch) -> Void)?

    private var isDragging = false
    private var isCommandDragging = false
    private var isZoomDragging = false  // Shift+Drag mode
    private var hasMoved = false  // Track if mouse moved during drag
    private var mouseDownPoint: CGPoint = .zero
    private var commandDragStartPoint: CGPoint?
    private var commandDragCurrentPoint: CGPoint?
    private var trackingArea: NSTrackingArea?
    private var cursorMode: CursorMode = .none

    /// Padding in screen points to expand hit area around OCR bounding boxes
    /// This makes it easier to start selection from slightly outside the text
    private let boundingBoxPadding: CGFloat = 8.0
    private let hyperlinkPadding: CGFloat = 3.0

    deinit {
        if cursorMode != .none {
            NSCursor.pop()
        }
    }

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        return super.hitTest(point)
    }

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
        applyCursorMode(.none)
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

    /// Returns the hyperlink entry near the point, if any.
    private func hyperlinkEntryContaining(screenPoint: CGPoint) -> HyperlinkEntry? {
        for entry in hyperlinkEntries {
            let expandedRect = entry.rect.insetBy(dx: -hyperlinkPadding, dy: -hyperlinkPadding)
            if expandedRect.contains(screenPoint) {
                return entry
            }
        }
        return nil
    }

    private func applyCursorMode(_ mode: CursorMode) {
        guard mode != cursorMode else { return }

        if cursorMode != .none {
            NSCursor.pop()
        }

        switch mode {
        case .none:
            break
        case .iBeam:
            NSCursor.iBeam.push()
        case .pointingHand:
            NSCursor.pointingHand.push()
        }

        cursorMode = mode
    }

    /// Re-evaluate cursor using the current pointer location when overlays/data update
    /// without a fresh mouse-move event.
    func refreshCursorForCurrentMouseLocation() {
        guard let window else {
            applyCursorMode(.none)
            return
        }

        let location = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        guard bounds.contains(location) else {
            applyCursorMode(.none)
            return
        }

        updateCursorForLocation(location)
    }

    /// Update cursor based on whether we're near an OCR bounding box
    private func updateCursorForLocation(_ location: CGPoint) {
        let hyperlinkEntry = hyperlinkEntryContaining(screenPoint: location)
        let isNearNode = isNearAnyNode(screenPoint: location)
        let targetMode: CursorMode = if hyperlinkEntry != nil {
            .pointingHand
        } else if isNearNode {
            .iBeam
        } else {
            .none
        }

        applyCursorMode(targetMode)
    }

    override func mouseDown(with event: NSEvent) {
        guard !isInteractionDisabled else { return }

        let location = convert(event.locationInWindow, from: nil)
        mouseDownPoint = location
        hasMoved = false
        commandDragStartPoint = nil
        commandDragCurrentPoint = nil
        let hyperlinkModifierFlags: NSEvent.ModifierFlags = [.shift, .command, .control, .option]
        let hasHyperlinkOverrideModifiers = !event.modifierFlags.intersection(hyperlinkModifierFlags).isEmpty

        if event.clickCount == 1,
           !hasHyperlinkOverrideModifiers,
           let hyperlinkEntry = hyperlinkEntryContaining(screenPoint: location)
        {
            onHyperlinkOpen?(hyperlinkEntry.match)
            return
        }

        // Convert screen coordinates to normalized frame coordinates
        let normalizedPoint = screenToNormalizedCoords(location)
        let isCommandDrag = event.modifierFlags.contains(.command)

        // Check if Shift is held - start zoom region mode
        if event.modifierFlags.contains(.shift) {
            isZoomDragging = true
            isDragging = false
            isCommandDragging = false
            onZoomRegionStart?(normalizedPoint)
        } else {
            // Handle multi-click (double-click = word, triple-click = line)
            let clickCount = event.clickCount
            if clickCount == 2, !isCommandDrag {
                onDoubleClick?(normalizedPoint)
                isDragging = false
                isZoomDragging = false
                isCommandDragging = false
            } else if clickCount >= 3, !isCommandDrag {
                onTripleClick?(normalizedPoint)
                isDragging = false
                isZoomDragging = false
                isCommandDragging = false
            } else {
                isDragging = true
                isZoomDragging = false
                isCommandDragging = isCommandDrag
                if isCommandDragging {
                    commandDragStartPoint = location
                    commandDragCurrentPoint = location
                }
                onDragStart?(normalizedPoint, isCommandDragging)
            }
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard !isInteractionDisabled else { return }

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
            if isCommandDragging {
                commandDragCurrentPoint = CGPoint(x: clampedX, y: clampedY)
            }
            onDragUpdate?(normalizedPoint, isCommandDragging)
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
        isCommandDragging = false
        commandDragStartPoint = nil
        commandDragCurrentPoint = nil
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

        // Collect highlight rects for selected nodes
        var highlightRects: [NSRect] = []
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
            highlightRects.append(highlightRect)
        }

        if !highlightRects.isEmpty {
            // Use transparency layer to prevent opacity stacking when rects overlap
            // All rects are composited together first, then the alpha is applied once to the result
            guard let context = NSGraphicsContext.current?.cgContext else { return }

            context.saveGState()
            context.setAlpha(0.4)  // Apply alpha to the entire layer, not per-rect
            context.beginTransparencyLayer(auxiliaryInfo: nil)

            // Draw all rects with solid color (alpha will be applied to the layer)
            let selectionColor = NSColor(red: 100/255, green: 160/255, blue: 230/255, alpha: 1.0)
            selectionColor.setFill()

            for rect in highlightRects {
                let path = NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2)
                path.fill()
            }

            context.endTransparencyLayer()
            context.restoreGState()
        }

        // Show marquee preview while Cmd+dragging.
        if isDragging,
           isCommandDragging,
           let start = commandDragStartPoint,
           let end = commandDragCurrentPoint {
            let marqueeRect = NSRect(
                x: min(start.x, end.x),
                y: min(start.y, end.y),
                width: abs(end.x - start.x),
                height: abs(end.y - start.y)
            )

            let fillColor = NSColor(red: 100/255, green: 160/255, blue: 230/255, alpha: 0.15)
            fillColor.setFill()
            let fillPath = NSBezierPath(roundedRect: marqueeRect, xRadius: 4, yRadius: 4)
            fillPath.fill()

            let borderPath = NSBezierPath(roundedRect: marqueeRect, xRadius: 4, yRadius: 4)
            borderPath.lineWidth = 1.5
            borderPath.setLineDash([6, 4], count: 2, phase: 0)
            NSColor(red: 100/255, green: 160/255, blue: 230/255, alpha: 0.95).setStroke()
            borderPath.stroke()
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
/// Darkens everything except the matched nodes for a spotlight effect
struct SearchHighlightOverlay: View {
    @ObservedObject var viewModel: SimpleTimelineViewModel
    let containerSize: CGSize
    let actualFrameRect: CGRect

    @State private var highlightScale: CGFloat = 0.3

    @State private var tooltipAnchorPoint: CGPoint?
    @State private var tooltipSourceRect: CGRect?
    @State private var isHoveringHighlightedNode = false
    @State private var isHoveringTooltipButton = false
    @State private var hasPushedTooltipCursor = false
    @State private var tooltipHideWorkItem: DispatchWorkItem?

    private let tooltipSize = CGSize(width: 210, height: 34)
    private let tooltipInset: CGFloat = 12
    private let tooltipGap: CGFloat = 8
    private let highlightHorizontalPaddingFraction: CGFloat = 0.12
    private let highlightVerticalPaddingFraction: CGFloat = 0.14
    private let tooltipHideDelay: TimeInterval = 0.18
    private let tooltipHoverExitDelay: TimeInterval = 0.12

    private var liveMatches: [(node: OCRNodeWithText, ranges: [Range<String.Index>])] {
        viewModel.searchHighlightNodes
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            highlightLayer
                .allowsHitTesting(false)

            SearchHighlightHoverTracker(
                highlightedRects: highlightedRects,
                onHoverLocationChanged: handleHoverLocationChanged,
                onInteractionLocationChanged: handleInteractionLocationChanged
            )
            .frame(width: containerSize.width, height: containerSize.height)

            if let tooltipPosition = tooltipPosition {
                Button {
                    viewModel.copySearchHighlightedTextByLine(from: liveMatches)
                    dismissTooltip()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "doc.on.doc.fill")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Copy ALL highlighted text")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .frame(width: tooltipSize.width, height: tooltipSize.height)
                    .background(
                        Capsule()
                            .fill(isHoveringTooltipButton ? Color.blue.opacity(0.90) : Color.black.opacity(0.72))
                            .overlay(
                                Capsule()
                                    .stroke(isHoveringTooltipButton ? Color.white.opacity(0.55) : Color.white.opacity(0.25), lineWidth: 1)
                            )
                    )
                    .shadow(color: .black.opacity(isHoveringTooltipButton ? 0.45 : 0.35), radius: isHoveringTooltipButton ? 14 : 10, y: 6)
                    .scaleEffect(isHoveringTooltipButton ? 1.03 : 1.0)
                    .animation(.easeOut(duration: 0.12), value: isHoveringTooltipButton)
                }
                .buttonStyle(.plain)
                .help("Copy ALL highlighted text")
                .offset(x: tooltipPosition.x, y: tooltipPosition.y)
                .onHover { isHovering in
                    isHoveringTooltipButton = isHovering
                    updateTooltipCursor(isHovering: isHovering)
                    if isHovering {
                        cancelTooltipHide()
                    } else if !isHoveringHighlightedNode {
                        scheduleTooltipHide(after: tooltipHoverExitDelay)
                    }
                }
            }
        }
        .onAppear {
            tooltipAnchorPoint = nil
            tooltipSourceRect = nil
            isHoveringHighlightedNode = false
            isHoveringTooltipButton = false
            updateTooltipCursor(isHovering: false)
            cancelTooltipHide()

            // Animate the scale from 0.3 to 1.0 with spring
            withAnimation(.spring(response: 0.4, dampingFraction: 0.7, blendDuration: 0)) {
                highlightScale = 1.0
            }
        }
        .onDisappear {
            cancelTooltipHide()
            tooltipAnchorPoint = nil
            tooltipSourceRect = nil
            isHoveringHighlightedNode = false
            isHoveringTooltipButton = false
            updateTooltipCursor(isHovering: false)
        }
    }

    private var highlightLayer: some View {
        Group {
            if highlightedRects.isEmpty {
                Color.clear
            } else {
                ZStack {
                    // Dark overlay
                    Color.black.opacity(0.25)

                    // Cutout holes for highlights - use compositingGroup for blend mode to work
                    ForEach(Array(highlightedRects.enumerated()), id: \.offset) { _, rect in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.white)
                            .frame(width: rect.width, height: rect.height)
                            .scaleEffect(highlightScale)
                            .position(x: rect.midX, y: rect.midY)
                            .blendMode(.destinationOut)
                    }
                }
                .compositingGroup()
                // Yellow borders drawn on top (outside the compositing group)
                .overlay(
                    ZStack {
                        ForEach(Array(highlightedRects.enumerated()), id: \.offset) { _, rect in
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(Color.yellow.opacity(0.9), lineWidth: 2)
                                .frame(width: rect.width, height: rect.height)
                                .scaleEffect(highlightScale)
                                .position(x: rect.midX, y: rect.midY)
                        }
                    }
                )
            }
        }
    }

    private var tooltipPosition: CGPoint? {
        guard let anchor = tooltipAnchorPoint else { return nil }

        let maxX = max(tooltipInset, containerSize.width - tooltipSize.width - tooltipInset)
        let preferredX = anchor.x - (tooltipSize.width / 2)
        let clampedX = min(max(preferredX, tooltipInset), maxX)

        let preferredAboveY = anchor.y - tooltipSize.height - tooltipGap
        let maxY = max(tooltipInset, containerSize.height - tooltipSize.height - tooltipInset)
        let y: CGFloat
        if preferredAboveY >= tooltipInset {
            y = preferredAboveY
        } else {
            y = min(maxY, anchor.y + tooltipGap)
        }

        return CGPoint(x: clampedX, y: y)
    }

    private var highlightedRects: [CGRect] {
        liveMatches.flatMap { match in
            let rects = match.ranges.compactMap { range -> CGRect? in
                let rect = screenRect(for: match.node, range: range)
                return rect.isEmpty ? nil : rect
            }

            if rects.isEmpty {
                let fallbackRect = screenRect(for: match.node)
                return fallbackRect.isEmpty ? [] : [fallbackRect]
            }

            return rects
        }
    }

    private var tooltipFrame: CGRect? {
        guard let tooltipPosition else { return nil }
        return CGRect(origin: tooltipPosition, size: tooltipSize)
    }

    private var tooltipInteractionSafeZone: CGRect? {
        guard let tooltipFrame else { return nil }
        return Self.tooltipInteractionSafeZone(
            tooltipFrame: tooltipFrame,
            sourceRect: tooltipSourceRect
        )
    }

    private func handleHoverLocationChanged(_ location: CGPoint?) {
        guard let location else {
            isHoveringHighlightedNode = false
            if !isHoveringTooltipButton {
                scheduleTooltipHide(after: tooltipHideDelay)
            }
            return
        }

        if let hoveredRect = highlightedRects.first(where: { $0.contains(location) }) {
            isHoveringHighlightedNode = true
            cancelTooltipHide()
            tooltipAnchorPoint = CGPoint(x: hoveredRect.midX, y: hoveredRect.minY)
            tooltipSourceRect = hoveredRect
            return
        }

        isHoveringHighlightedNode = false

        if let tooltipInteractionSafeZone,
           tooltipInteractionSafeZone.contains(location) {
            cancelTooltipHide()
            return
        }

        if !isHoveringTooltipButton {
            scheduleTooltipHide(after: tooltipHideDelay)
        }
    }

    private func handleInteractionLocationChanged(_ location: CGPoint) {
        guard Self.shouldDismissTooltip(
            for: location,
            highlightedRects: highlightedRects,
            tooltipFrame: tooltipFrame
        ) else {
            return
        }

        dismissTooltip()
    }

    private func scheduleTooltipHide(after delay: TimeInterval) {
        cancelTooltipHide()
        let workItem = DispatchWorkItem {
            dismissTooltip()
        }
        tooltipHideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func cancelTooltipHide() {
        tooltipHideWorkItem?.cancel()
        tooltipHideWorkItem = nil
    }

    private func dismissTooltip() {
        cancelTooltipHide()
        tooltipAnchorPoint = nil
        tooltipSourceRect = nil
        isHoveringHighlightedNode = false
        isHoveringTooltipButton = false
        updateTooltipCursor(isHovering: false)
    }

    private func updateTooltipCursor(isHovering: Bool) {
        if isHovering {
            guard !hasPushedTooltipCursor else { return }
            NSCursor.pointingHand.push()
            hasPushedTooltipCursor = true
        } else {
            guard hasPushedTooltipCursor else { return }
            NSCursor.pop()
            hasPushedTooltipCursor = false
        }
    }

    static func tooltipInteractionSafeZone(
        tooltipFrame: CGRect,
        sourceRect: CGRect?
    ) -> CGRect {
        var safeZone = tooltipFrame.insetBy(dx: -10, dy: -8)
        guard let sourceRect else { return safeZone }

        let sourceConnectionY = tooltipFrame.midY < sourceRect.midY ? sourceRect.minY : sourceRect.maxY
        let sourceAnchorRect = CGRect(
            x: sourceRect.midX - 12,
            y: sourceConnectionY - 12,
            width: 24,
            height: 24
        )
        let bridgeCenterX = (sourceRect.midX + tooltipFrame.midX) / 2
        let bridgeWidth = abs(sourceRect.midX - tooltipFrame.midX) + 24
        let bridgeMinY = min(sourceConnectionY, tooltipFrame.minY) - 8
        let bridgeMaxY = max(sourceConnectionY, tooltipFrame.maxY) + 8
        let bridgeRect = CGRect(
            x: bridgeCenterX - (bridgeWidth / 2),
            y: bridgeMinY,
            width: max(bridgeWidth, 1),
            height: max(bridgeMaxY - bridgeMinY, 1)
        )

        safeZone = safeZone.union(sourceAnchorRect)
        safeZone = safeZone.union(bridgeRect)
        return safeZone
    }

    static func shouldDismissTooltip(
        for location: CGPoint,
        highlightedRects: [CGRect],
        tooltipFrame: CGRect?
    ) -> Bool {
        if highlightedRects.contains(where: { $0.contains(location) }) {
            return false
        }
        if let tooltipFrame, tooltipFrame.contains(location) {
            return false
        }
        return true
    }

    private func screenRect(for node: OCRNodeWithText) -> CGRect {
        CGRect(
            x: actualFrameRect.origin.x + (node.x * actualFrameRect.width),
            y: actualFrameRect.origin.y + (node.y * actualFrameRect.height),
            width: node.width * actualFrameRect.width,
            height: node.height * actualFrameRect.height
        )
    }

    private func screenRect(
        for node: OCRNodeWithText,
        range: Range<String.Index>
    ) -> CGRect {
        let textCount = node.text.count
        guard textCount > 0 else { return screenRect(for: node) }

        let lowerBound = node.text.distance(from: node.text.startIndex, to: range.lowerBound)
        let upperBound = node.text.distance(from: node.text.startIndex, to: range.upperBound)
        let clampedLowerBound = min(max(lowerBound, 0), textCount - 1)
        let clampedUpperBound = min(max(upperBound, clampedLowerBound + 1), textCount)

        let startFraction = CGFloat(clampedLowerBound) / CGFloat(textCount)
        let endFraction = CGFloat(clampedUpperBound) / CGFloat(textCount)
        let horizontalPadding = min(
            highlightHorizontalPaddingFraction / CGFloat(textCount),
            startFraction
        )
        let trailingPadding = min(
            highlightHorizontalPaddingFraction / CGFloat(textCount),
            max(0, 1.0 - endFraction)
        )
        let paddedStartFraction = max(0, startFraction - horizontalPadding)
        let paddedEndFraction = min(1.0, endFraction + trailingPadding)
        let widthFraction = max(
            paddedEndFraction - paddedStartFraction,
            1.0 / CGFloat(textCount)
        )
        let verticalPadding = node.height * highlightVerticalPaddingFraction

        return CGRect(
            x: actualFrameRect.origin.x + ((node.x + (node.width * paddedStartFraction)) * actualFrameRect.width),
            y: actualFrameRect.origin.y + ((node.y - verticalPadding) * actualFrameRect.height),
            width: node.width * min(widthFraction, 1.0) * actualFrameRect.width,
            height: min(node.height + (verticalPadding * 2), max(0, 1.0 - max(0, node.y - verticalPadding))) * actualFrameRect.height
        )
    }
}

private struct SearchHighlightHoverTracker: NSViewRepresentable {
    let highlightedRects: [CGRect]
    let onHoverLocationChanged: (CGPoint?) -> Void
    let onInteractionLocationChanged: (CGPoint) -> Void

    func makeNSView(context: Context) -> SearchHighlightHoverTrackingView {
        let view = SearchHighlightHoverTrackingView()
        view.onHoverLocationChanged = onHoverLocationChanged
        view.onInteractionLocationChanged = onInteractionLocationChanged
        return view
    }

    func updateNSView(_ nsView: SearchHighlightHoverTrackingView, context: Context) {
        let didRectsChange = nsView.highlightedRects != highlightedRects
        nsView.highlightedRects = highlightedRects
        nsView.onHoverLocationChanged = onHoverLocationChanged
        nsView.onInteractionLocationChanged = onInteractionLocationChanged
        if didRectsChange || !nsView.hasPerformedInitialHoverSync {
            nsView.refreshHoverStateForCurrentMouseLocation()
            nsView.hasPerformedInitialHoverSync = true
        }
    }
}

private final class SearchHighlightHoverTrackingView: NSView {
    var highlightedRects: [CGRect] = []
    var onHoverLocationChanged: ((CGPoint?) -> Void)?
    var onInteractionLocationChanged: ((CGPoint) -> Void)?
    var hasPerformedInitialHoverSync = false

    private var trackingArea: NSTrackingArea?
    private var localMouseDownMonitor: Any?

    override var isFlipped: Bool {
        true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        hasPerformedInitialHoverSync = false
        if window == nil {
            removeLocalMouseDownMonitor()
        } else {
            installLocalMouseDownMonitorIfNeeded()
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            removeLocalMouseDownMonitor()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    deinit {
        removeLocalMouseDownMonitor()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }

        let options: NSTrackingArea.Options = [
            .activeInKeyWindow,
            .mouseEnteredAndExited,
            .mouseMoved,
            .inVisibleRect
        ]
        let trackingArea = NSTrackingArea(rect: .zero, options: options, owner: self, userInfo: nil)
        self.trackingArea = trackingArea
        addTrackingArea(trackingArea)
    }

    override func mouseMoved(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        onHoverLocationChanged?(location)
    }

    override func mouseEntered(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        onHoverLocationChanged?(location)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverLocationChanged?(nil)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func refreshHoverStateForCurrentMouseLocation() {
        guard let window else { return }
        let location = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        onHoverLocationChanged?(location)
    }

    private func installLocalMouseDownMonitorIfNeeded() {
        guard localMouseDownMonitor == nil else { return }

        localMouseDownMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            guard let self, let eventWindow = event.window, eventWindow == self.window else {
                return event
            }

            let location = self.convert(event.locationInWindow, from: nil)
            self.onInteractionLocationChanged?(location)
            return event
        }
    }

    private func removeLocalMouseDownMonitor() {
        if let localMouseDownMonitor {
            NSEvent.removeMonitor(localMouseDownMonitor)
            self.localMouseDownMonitor = nil
        }
    }
}

// MARK: - OCR Debug Overlay

/// Developer overlay that displays OCR bounding boxes and tile grid for debugging
/// Shows diff between current and previous frame:
/// - Green: New nodes (not in previous frame)
/// - Red: Removed nodes (were in previous frame, not in current)
/// - Gray: Unchanged nodes (present in both frames)
/// Only visible when "Show OCR debug overlay" is enabled in Settings > Advanced > Developer
struct OCRDebugOverlay: View {
    @ObservedObject var viewModel: SimpleTimelineViewModel
    let containerSize: CGSize
    let actualFrameRect: CGRect

    /// Tile size in pixels (matches TileGridConfig.default.tileSize)
    private let tileSize: CGFloat = 64

    /// Threshold for considering two nodes as "the same" (normalized coordinate tolerance)
    private let matchTolerance: CGFloat = 0.01

    /// Categorized nodes for diff visualization
    private var categorizedNodes: (new: [OCRNodeWithText], removed: [OCRNodeWithText], unchanged: [OCRNodeWithText]) {
        let current = viewModel.ocrNodes
        let previous = viewModel.previousOcrNodes

        // If no previous nodes, all current are "new" (first frame or debug just enabled)
        guard !previous.isEmpty else {
            return (new: current, removed: [], unchanged: [])
        }

        var newNodes: [OCRNodeWithText] = []
        var unchangedNodes: [OCRNodeWithText] = []
        var matchedPreviousIndices = Set<Int>()

        // Find matches between current and previous
        for currentNode in current {
            var foundMatch = false
            for (prevIndex, prevNode) in previous.enumerated() {
                if nodesMatch(currentNode, prevNode) {
                    unchangedNodes.append(currentNode)
                    matchedPreviousIndices.insert(prevIndex)
                    foundMatch = true
                    break
                }
            }
            if !foundMatch {
                newNodes.append(currentNode)
            }
        }

        // Removed nodes are previous nodes that weren't matched
        let removedNodes = previous.enumerated()
            .filter { !matchedPreviousIndices.contains($0.offset) }
            .map { $0.element }

        return (new: newNodes, removed: removedNodes, unchanged: unchangedNodes)
    }

    /// Check if two nodes are approximately the same (by position and size)
    private func nodesMatch(_ a: OCRNodeWithText, _ b: OCRNodeWithText) -> Bool {
        abs(a.x - b.x) < matchTolerance &&
        abs(a.y - b.y) < matchTolerance &&
        abs(a.width - b.width) < matchTolerance &&
        abs(a.height - b.height) < matchTolerance
    }

    var body: some View {
        ZStack {
            // 1. Draw tile grid (semi-transparent grid lines)
            tileGridOverlay

            // 2. Draw OCR bounding boxes with diff colors
            ocrDiffOverlay
        }
        .allowsHitTesting(false)
    }

    /// Draws a grid showing the tile layout used for change detection
    private var tileGridOverlay: some View {
        Canvas { context, size in
            let frameWidth = actualFrameRect.width
            let frameHeight = actualFrameRect.height

            guard frameWidth > 0, frameHeight > 0 else { return }

            // Estimate original pixel dimensions from frame aspect ratio
            let estimatedPixelWidth: CGFloat = 2560  // Common MacBook Pro resolution
            let estimatedPixelHeight = estimatedPixelWidth * (frameHeight / frameWidth)

            // Number of tiles in each dimension
            let tilesX = Int(ceil(estimatedPixelWidth / tileSize))
            let tilesY = Int(ceil(estimatedPixelHeight / tileSize))

            // Normalized tile size
            let normalizedTileWidth = tileSize / estimatedPixelWidth
            let normalizedTileHeight = tileSize / estimatedPixelHeight

            // Draw vertical lines
            for col in 0...tilesX {
                let normalizedX = CGFloat(col) * normalizedTileWidth
                let screenX = actualFrameRect.origin.x + (normalizedX * frameWidth)

                guard screenX <= actualFrameRect.maxX else { break }

                var path = Path()
                path.move(to: CGPoint(x: screenX, y: actualFrameRect.origin.y))
                path.addLine(to: CGPoint(x: screenX, y: actualFrameRect.maxY))

                context.stroke(path, with: .color(.cyan.opacity(0.3)), lineWidth: 0.5)
            }

            // Draw horizontal lines
            for row in 0...tilesY {
                let normalizedY = CGFloat(row) * normalizedTileHeight
                let screenY = actualFrameRect.origin.y + (normalizedY * frameHeight)

                guard screenY <= actualFrameRect.maxY else { break }

                var path = Path()
                path.move(to: CGPoint(x: actualFrameRect.origin.x, y: screenY))
                path.addLine(to: CGPoint(x: actualFrameRect.maxX, y: screenY))

                context.stroke(path, with: .color(.cyan.opacity(0.3)), lineWidth: 0.5)
            }
        }
    }

    /// Draws bounding boxes with diff coloring
    private var ocrDiffOverlay: some View {
        let nodes = categorizedNodes

        return ZStack {
            // Draw removed nodes first (red, dashed) - these are from previous frame
            ForEach(Array(nodes.removed.enumerated()), id: \.offset) { _, node in
                nodeBox(node: node, color: .red, isDashed: true, label: "−")
            }

            // Draw unchanged nodes (gray, solid)
            ForEach(Array(nodes.unchanged.enumerated()), id: \.offset) { _, node in
                nodeBox(node: node, color: .gray, isDashed: false, label: nil)
            }

            // Draw new nodes on top (green, solid)
            ForEach(Array(nodes.new.enumerated()), id: \.offset) { _, node in
                nodeBox(node: node, color: .green, isDashed: false, label: "+")
            }

            // Stats badge in top-right of frame area
            statsBadge(new: nodes.new.count, removed: nodes.removed.count, unchanged: nodes.unchanged.count)
        }
    }

    /// Draw a single node bounding box
    @ViewBuilder
    private func nodeBox(node: OCRNodeWithText, color: Color, isDashed: Bool, label: String?) -> some View {
        let screenX = actualFrameRect.origin.x + (node.x * actualFrameRect.width)
        let screenY = actualFrameRect.origin.y + (node.y * actualFrameRect.height)
        let screenWidth = node.width * actualFrameRect.width
        let screenHeight = node.height * actualFrameRect.height

        // Bounding box rectangle
        RoundedRectangle(cornerRadius: 2)
            .stroke(color.opacity(0.8), style: StrokeStyle(lineWidth: isDashed ? 1.5 : 1, dash: isDashed ? [4, 2] : []))
            .frame(width: screenWidth, height: screenHeight)
            .position(x: screenX + screenWidth / 2, y: screenY + screenHeight / 2)

        // Label badge for new/removed nodes
        if let label = label {
            Text(label)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(.white)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(color.opacity(0.9))
                .cornerRadius(3)
                .position(x: screenX + 10, y: screenY + 10)
        }
    }

    /// Stats badge showing counts
    @ViewBuilder
    private func statsBadge(new: Int, removed: Int, unchanged: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Circle().fill(Color.green).frame(width: 8, height: 8)
                Text("New: \(new)").font(.system(size: 10, weight: .medium, design: .monospaced))
            }
            HStack(spacing: 4) {
                Circle().fill(Color.red).frame(width: 8, height: 8)
                Text("Removed: \(removed)").font(.system(size: 10, weight: .medium, design: .monospaced))
            }
            HStack(spacing: 4) {
                Circle().fill(Color.gray).frame(width: 8, height: 8)
                Text("Unchanged: \(unchanged)").font(.system(size: 10, weight: .medium, design: .monospaced))
            }
        }
        .foregroundColor(.white)
        .padding(8)
        .background(Color.black.opacity(0.7))
        .cornerRadius(6)
        .position(x: actualFrameRect.maxX - 70, y: actualFrameRect.origin.y + 50)
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

                    // Debug: Show processing status
                    if let timelineFrame = viewModel.currentTimelineFrame {
                        let status = timelineFrame.processingStatus
                        let statusText = switch status {
                            case -1: "N/A (Rewind)"
                            case 0: "pending"
                            case 1: "processing"
                            case 2: "completed"
                            case 3: "failed"
                            case 4: "not readable"
                            default: "unknown"
                        }
                        Text("p=\(status) (\(statusText))")
                            .font(.retraceMonoSmall)
                            .foregroundColor(status == -1 ? .blue.opacity(0.8) : status == 4 ? .red.opacity(0.8) : status == 2 ? .green.opacity(0.8) : .yellow.opacity(0.8))
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

// MARK: - Debug Browser URL Window

/// Draggable debug panel for inspecting full browser URLs while scrubbing.
/// Wraps URL text every 100 characters to keep very long URLs readable.
struct DebugBrowserURLWindow: View {
    let browserURL: String?
    @Binding var panelPosition: CGSize
    @Binding var isPresented: Bool

    @GestureState private var dragOffset: CGSize = .zero
    @State private var isDraggingHeader = false
    @State private var isCloseHovered = false

    private var wrappedURLText: String {
        guard let browserURL else {
            return "No browser URL on this frame"
        }
        return Self.wrapText(browserURL, maxCharactersPerLine: 100)
    }

    private var hasURL: Bool {
        browserURL != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "link")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.cyan.opacity(0.9))

                Text("Browser URL")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.88))

                Spacer()

                Button(action: {
                    withAnimation(.easeOut(duration: 0.15)) {
                        isPresented = false
                    }
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(isCloseHovered ? .white.opacity(0.9) : .white.opacity(0.55))
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    isCloseHovered = hovering
                    if hovering {
                        NSCursor.pointingHand.push()
                    } else {
                        NSCursor.pop()
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Color.white.opacity(0.06))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .updating($dragOffset) { value, state, _ in
                        state = value.translation
                    }
                    .onChanged { _ in
                        if !isDraggingHeader {
                            isDraggingHeader = true
                        }
                    }
                    .onEnded { value in
                        panelPosition.width += value.translation.width
                        panelPosition.height += value.translation.height
                        isDraggingHeader = false
                    }
            )
            .onHover { hovering in
                if hovering && !isDraggingHeader {
                    NSCursor.openHand.push()
                } else if !hovering {
                    NSCursor.pop()
                }
            }

            Divider()
                .overlay(Color.white.opacity(0.08))

            ScrollView(.vertical, showsIndicators: true) {
                Text(wrappedURLText)
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .foregroundColor(hasURL ? .cyan.opacity(0.95) : .white.opacity(0.6))
                    .lineSpacing(2)
                    .multilineTextAlignment(.leading)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .frame(maxHeight: 170)
        }
        .frame(width: 720, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(white: 0.1).opacity(0.95))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.white.opacity(0.2), lineWidth: 0.8)
        )
        .shadow(color: .black.opacity(0.4), radius: 20, y: 8)
        .offset(
            x: panelPosition.width + dragOffset.width,
            y: panelPosition.height + dragOffset.height
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.spacingL)
    }

    private static func wrapText(_ text: String, maxCharactersPerLine: Int) -> String {
        guard maxCharactersPerLine > 0, !text.isEmpty else { return text }

        var lines: [String] = []
        var currentStart = text.startIndex

        while currentStart < text.endIndex {
            let nextEnd = text.index(currentStart, offsetBy: maxCharactersPerLine, limitedBy: text.endIndex) ?? text.endIndex
            lines.append(String(text[currentStart..<nextEnd]))
            currentStart = nextEnd
        }

        return lines.joined(separator: "\n")
    }
}

// MARK: - OCR Status Indicator

/// Shows the OCR processing status for the current frame
/// Displays when OCR is pending, queued, or processing (not shown when completed)
struct OCRStatusIndicator: View {
    @ObservedObject var viewModel: SimpleTimelineViewModel

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
                // Static icon - no animation to avoid idle wakeups
                // The status text already indicates processing state
                Image(systemName: statusIcon)
                    .font(.retraceTinyMedium)
                    .foregroundColor(statusColor)

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
/// Developer actions menu with OCR refresh and timeline debug visualization options
/// Only visible in DEBUG builds, positioned in top-left corner beside the frame ID badge
struct DeveloperActionsMenu: View {
    @ObservedObject var viewModel: SimpleTimelineViewModel
    let onClose: () -> Void
    @State private var isHovering = false
    @State private var showReprocessFeedback = false
    @AppStorage("showFrameIDs", store: timelineSettingsStore) private var showFrameIDs = SettingsDefaults.showFrameIDs

    /// Whether the current frame can be reprocessed (only Retrace frames)
    private var canReprocess: Bool {
        viewModel.currentFrame?.source == .native
    }

    var body: some View {
        Menu {
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    viewModel.toggleFrameIDBadgeVisibilityFromDevMenu()
                }
            }) {
                Label(
                    showFrameIDs ? "Hide Frame ID" : "Show Frame ID",
                    systemImage: "number.circle"
                )
            }

            Divider()

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

            // Show/Hide Video Placements toggle
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    viewModel.showVideoBoundaries.toggle()
                }
            }) {
                Label(
                    viewModel.showVideoBoundaries ? "Hide Video Placements" : "Show Video Placements",
                    systemImage: "film"
                )
            }

            // Show/Hide Segment Placements toggle
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    viewModel.showSegmentBoundaries.toggle()
                }
            }) {
                Label(
                    viewModel.showSegmentBoundaries ? "Hide Segment Placements" : "Show Segment Placements",
                    systemImage: "square.stack.3d.down.forward"
                )
            }

            // Show/Hide Browser URL debug window toggle
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    viewModel.showBrowserURLDebugWindow.toggle()
                }
            }) {
                Label(
                    viewModel.showBrowserURLDebugWindow ? "Hide Browser URL Window" : "Show Browser URL Window",
                    systemImage: "link"
                )
            }

            Divider()

            // Open Video File button - opens in QuickTime at the current frame's timestamp
            Button(action: {
                guard let videoInfo = viewModel.currentVideoInfo else { return }
                let originalPath = videoInfo.videoPath
                let timeInSeconds = videoInfo.timeInSeconds

                // Close the timeline before opening the video
                onClose()

                Task.detached(priority: .userInitiated) {
                    // Give the timeline a moment to close before starting QuickTime.
                    try? await Task.sleep(for: .milliseconds(200), clock: .continuous)

                    // Create a hard link with .mp4 extension so QuickTime recognizes the format
                    // (files are stored without extension but are valid MP4 containers).
                    let tempDir = FileManager.default.temporaryDirectory
                    let filename = (originalPath as NSString).lastPathComponent
                    let tempURL = tempDir.appendingPathComponent("\(filename).mp4")

                    do {
                        if FileManager.default.fileExists(atPath: tempURL.path) {
                            try FileManager.default.removeItem(at: tempURL)
                        }
                        try FileManager.default.linkItem(atPath: originalPath, toPath: tempURL.path)
                    } catch {
                        Log.error("[Dev] Failed to create hard link for video: \(error)", category: .ui)
                        return
                    }

                    do {
                        let process = Process()
                        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                        process.arguments = DeveloperActionsMenu.quickTimeOpenScriptLines(path: tempURL.path, timeInSeconds: timeInSeconds)
                            .flatMap { ["-e", $0] }
                        try process.run()
                        process.waitUntilExit()

                        if process.terminationStatus != 0 {
                            Log.error("[Dev] osascript exited with status \(process.terminationStatus) while opening video", category: .ui)
                        }
                    } catch {
                        Log.error("[Dev] Failed to run osascript for video open: \(error)", category: .ui)
                    }
                }
            }) {
                Label("Open Video File", systemImage: "play.rectangle")
            }
            .disabled(viewModel.currentVideoInfo == nil)

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

    nonisolated private static func quickTimeOpenScriptLines(path: String, timeInSeconds: Double) -> [String] {
        let escapedPath = escapeAppleScriptString(path)
        let safeTime = max(0, timeInSeconds)
        return [
            "tell application \"QuickTime Player\"",
            "activate",
            "open POSIX file \"\(escapedPath)\"",
            "delay 0.5",
            "tell front document",
            "set current time to \(safeTime)",
            "end tell",
            "end tell"
        ]
    }

    nonisolated private static func escapeAppleScriptString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
#endif

// MARK: - Text Selection Hint Banner

/// Banner displayed at the top of the screen when user attempts text selection
/// Suggests available drag-selection shortcuts.
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

            // Keyboard shortcut guidance
            HStack(spacing: 4) {
                Text("Try Area Selection")
                    .font(.retraceCaption)
                    .foregroundColor(.white.opacity(0.75))
                KeyboardBadge(symbol: "⇧ Shift")
                Text("+")
                    .font(.retraceCaption2Medium)
                    .foregroundColor(.white.opacity(0.5))
                KeyboardBadge(symbol: "⊹ Drag")
                Text("OR")
                    .font(.retraceCaption2Bold)
                    .foregroundColor(.white.opacity(0.55))
                    .padding(.horizontal, 2)
                Text("Box Selection")
                    .font(.retraceCaption)
                    .foregroundColor(.white.opacity(0.75))
                KeyboardBadge(symbol: "⌘ Cmd")
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

/// Banner shown when highlighted OCR text is near the timeline tape region.
/// Suggests hiding controls or opening the context menu for better visibility/actions.
struct SearchHighlightControlsHintBanner: View {
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "lightbulb.fill")
                .font(.retraceHeadline)
                .foregroundColor(.white.opacity(0.9))

            Text("Highlighted text is under timeline controls.")
                .font(.retraceCaptionMedium)
                .foregroundColor(.white.opacity(0.9))

            Text("Press")
                .font(.retraceCaption)
                .foregroundColor(.white.opacity(0.7))

            KeyboardBadge(symbol: "⌘ H")

            Text("to hide/show controls, or right-click.")
                .font(.retraceCaption)
                .foregroundColor(.white.opacity(0.7))

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

/// Banner suggesting the user switch scroll orientation when scrolling the wrong axis.
struct ScrollOrientationHintBanner: View {
    let currentOrientation: String
    let onSwitch: () -> Void
    let onDismiss: () -> Void

    private var isHorizontal: Bool { currentOrientation == "horizontal" }
    @State private var isSwitchHovered = false

    var body: some View {
        HStack(spacing: 12) {
            // Direction icon
            Image(systemName: isHorizontal ? "arrow.up.arrow.down" : "arrow.left.arrow.right")
                .font(.retraceHeadline)
                .foregroundColor(.white.opacity(0.9))

            // Message
            Text(isHorizontal ? "Vertical scrolling detected." : "Horizontal scrolling detected.")
                .font(.retraceCaptionMedium)
                .foregroundColor(.white.opacity(0.9))

            Text(isHorizontal ? "Timeline is currently set to Left/Right." : "Timeline is currently set to Up/Down.")
                .font(.retraceCaption)
                .foregroundColor(.white.opacity(0.7))

            // Switch action button
            Button(action: onSwitch) {
                Text(isHorizontal ? "Switch to Up/Down" : "Switch to Left/Right")
                    .font(.retraceCaptionMedium)
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        Capsule()
                            .fill(Color.retraceSubmitAccent.opacity(isSwitchHovered ? 0.42 : 0.32))
                            .overlay(
                                Capsule()
                                    .stroke(Color.white.opacity(isSwitchHovered ? 0.45 : 0.3), lineWidth: 1)
                            )
                    )
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                isSwitchHovered = hovering
                if hovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
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

/// Persistent banner that explains why the current frame is redacted.
private struct RedactionReasonBanner: View {
    let reason: String
    let appBundleID: String?

    var body: some View {
        HStack(spacing: 10) {
            if let appBundleID, !appBundleID.isEmpty {
                AppIconView(bundleID: appBundleID, size: 18)
                    .frame(width: 18, height: 18)
            } else {
                Image(systemName: "eye.slash.fill")
                    .font(.retraceCaptionMedium)
                    .foregroundColor(Color.orange.opacity(0.95))
            }

            Text("Redacted")
                .font(.retraceCaptionMedium)
                .foregroundColor(.white.opacity(0.95))

            Rectangle()
                .fill(Color.white.opacity(0.22))
                .frame(width: 1, height: 14)

            Text(reason)
                .font(.retraceCaption)
                .foregroundColor(.white.opacity(0.8))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: 680)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(white: 0.13).opacity(0.94))
                .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.orange.opacity(0.35), lineWidth: 1)
        )
        .allowsHitTesting(false)
        .help("Current frame is redacted")
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
    final class HyperlinkMenuTarget: NSObject {
        var match: OCRHyperlinkMatch?
        var onCopyHyperlink: (OCRHyperlinkMatch) -> Void = { _ in }

        @objc func copyLinkAction(_ sender: Any?) {
            guard let match else { return }
            onCopyHyperlink(match)
        }
    }

    final class MonitorState: ObservableObject {
        var hyperlinkEntries: [HyperlinkContextMenuEntry] = []
        var onHyperlinkRightClick: (OCRHyperlinkMatch) -> Void = { _ in }
        var onCopyHyperlink: (OCRHyperlinkMatch) -> Void = { _ in }
        var onRightClick: (CGPoint) -> Void = { _ in }
        var viewBounds: CGRect = .zero
        let hyperlinkMenuTarget = HyperlinkMenuTarget()
    }

    struct MonitorStateSyncView: NSViewRepresentable {
        let monitorState: MonitorState
        let hyperlinkEntries: [HyperlinkContextMenuEntry]
        let onHyperlinkRightClick: (OCRHyperlinkMatch) -> Void
        let onHyperlinkCopy: (OCRHyperlinkMatch) -> Void
        let onRightClick: (CGPoint) -> Void
        let viewBounds: CGRect

        func makeNSView(context: Context) -> NSView {
            NSView(frame: .zero)
        }

        func updateNSView(_ nsView: NSView, context: Context) {
            monitorState.hyperlinkEntries = hyperlinkEntries
            monitorState.onHyperlinkRightClick = onHyperlinkRightClick
            monitorState.onCopyHyperlink = onHyperlinkCopy
            monitorState.onRightClick = onRightClick
            monitorState.viewBounds = viewBounds
        }
    }

    let hyperlinkEntries: [HyperlinkContextMenuEntry]
    let onHyperlinkRightClick: (OCRHyperlinkMatch) -> Void
    let onHyperlinkCopy: (OCRHyperlinkMatch) -> Void
    let onRightClick: (CGPoint) -> Void
    @State private var eventMonitor: Any?
    @State private var viewBounds: CGRect = .zero
    @StateObject private var monitorState = MonitorState()

    /// Height of the timeline tape area at the bottom (tape height + bottom padding)
    /// Clicks in this area are passed through to SwiftUI's native contextMenu
    private var timelineExclusionHeight: CGFloat {
        TimelineScaleFactor.tapeHeight + TimelineScaleFactor.tapeBottomPadding + 20 // Extra buffer for the playhead
    }

    func body(content: Content) -> some View {
        content
            .background(
                MonitorStateSyncView(
                    monitorState: monitorState,
                    hyperlinkEntries: hyperlinkEntries,
                    onHyperlinkRightClick: onHyperlinkRightClick,
                    onHyperlinkCopy: onHyperlinkCopy,
                    onRightClick: onRightClick,
                    viewBounds: viewBounds
                )
            )
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear {
                            updateViewBoundsIfNeeded(geo.frame(in: .global))
                        }
                        .onChange(of: geo.frame(in: .global)) { newFrame in
                            updateViewBoundsIfNeeded(newFrame)
                        }
                }
            )
            .onAppear {
                syncMonitorState()
                setupEventMonitor()
            }
            .onDisappear {
                removeEventMonitor()
            }
    }

    private func updateViewBoundsIfNeeded(_ newFrame: CGRect) {
        let epsilon: CGFloat = 0.5
        let hasMeaningfulDelta =
            abs(viewBounds.minX - newFrame.minX) > epsilon ||
            abs(viewBounds.minY - newFrame.minY) > epsilon ||
            abs(viewBounds.width - newFrame.width) > epsilon ||
            abs(viewBounds.height - newFrame.height) > epsilon

        if hasMeaningfulDelta || viewBounds == .zero {
            viewBounds = newFrame
            monitorState.viewBounds = newFrame
        }
    }

    private func syncMonitorState() {
        monitorState.hyperlinkEntries = hyperlinkEntries
        monitorState.onHyperlinkRightClick = onHyperlinkRightClick
        monitorState.onCopyHyperlink = onHyperlinkCopy
        monitorState.onRightClick = onRightClick
        monitorState.viewBounds = viewBounds
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
            let currentViewBounds = monitorState.viewBounds
            if currentViewBounds.contains(swiftUILocation) {
                // Convert to view-local coordinates
                let localX = swiftUILocation.x - currentViewBounds.minX
                let localY = swiftUILocation.y - currentViewBounds.minY
                let localPoint = CGPoint(x: localX, y: localY)
                let hyperlinkEntries = monitorState.hyperlinkEntries
                let matchedHyperlink = hyperlinkEntries.first(where: { $0.rect.contains(localPoint) })

                // Check if click is in the timeline tape area at the bottom
                // If so, let the event pass through to SwiftUI's native contextMenu
                let distanceFromBottom = currentViewBounds.height - localY

                if let matchedHyperlink, let contentView = window.contentView {
                    let target = monitorState.hyperlinkMenuTarget
                    target.match = matchedHyperlink.match
                    monitorState.onHyperlinkRightClick(matchedHyperlink.match)
                    target.onCopyHyperlink = monitorState.onCopyHyperlink

                    let menu = NSMenu()
                    let copyItem = NSMenuItem(title: "Copy Link", action: #selector(HyperlinkMenuTarget.copyLinkAction(_:)), keyEquivalent: "")
                    copyItem.target = target
                    menu.addItem(copyItem)
                    NSMenu.popUpContextMenu(menu, with: event, for: contentView)
                    return nil
                }

                if distanceFromBottom < timelineExclusionHeight {
                    // Pass through to SwiftUI for timeline tape context menu
                    return event
                }

                DispatchQueue.main.async {
                    monitorState.onRightClick(localPoint)
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
    func onRightClick(
        hyperlinkEntries: [HyperlinkContextMenuEntry] = [],
        onHyperlinkRightClick: @escaping (OCRHyperlinkMatch) -> Void = { _ in },
        onHyperlinkCopy: @escaping (OCRHyperlinkMatch) -> Void = { _ in },
        perform action: @escaping (CGPoint) -> Void
    ) -> some View {
        modifier(
            RightClickOverlay(
                hyperlinkEntries: hyperlinkEntries,
                onHyperlinkRightClick: onHyperlinkRightClick,
                onHyperlinkCopy: onHyperlinkCopy,
                onRightClick: action
            )
        )
    }
}

// MARK: - Floating Context Menu

/// Floating context menu that appears at click location with smart edge detection
struct FloatingContextMenu: View {
    @ObservedObject var viewModel: SimpleTimelineViewModel
    @EnvironmentObject var coordinatorWrapper: AppCoordinatorWrapper
    @Binding var isPresented: Bool
    let location: CGPoint
    let containerSize: CGSize
    let highlightHideControlsRow: Bool

    // Menu dimensions (approximate)
    private let menuWidth: CGFloat = 272
    private let menuHeight: CGFloat = 252
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
            ContextMenuContent(
                viewModel: viewModel,
                showMenu: $isPresented,
                highlightHideControlsRow: highlightHideControlsRow
            )
                .retraceMenuContainer()
                .fixedSize()
                .position(adjustedPosition)
        }
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.16), value: isPresented)
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
            viewModel.dismissTimelineContextMenu()
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

/// Context menu for right-clicking on timeline segments (Add Tag, Add Comment, Hide, Delete)
struct TimelineSegmentContextMenu: View {
    @ObservedObject var viewModel: SimpleTimelineViewModel
    @Binding var isPresented: Bool
    let location: CGPoint
    let containerSize: CGSize

    // Menu dimensions
    private let menuWidth: CGFloat = 208
    private let menuHeight: CGFloat = 172
    private let tagSubmenuWidth: CGFloat = 188
    private let edgePadding: CGFloat = 16

    private var selectedTagsForContextMenu: [Tag] {
        viewModel.availableTags
            .filter { !($0.isHidden) && viewModel.selectedSegmentTags.contains($0.id) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        ZStack {
            // Dismiss overlay - handles left-click to dismiss, passes right-click through
            ContextMenuDismissOverlay(viewModel: viewModel)

            // Main menu content
            VStack(alignment: .leading, spacing: 0) {
                // Add Tag button (with submenu that opens on hover)
                TimelineTagMenuButton(
                    selectedTags: selectedTagsForContextMenu,
                    onHoverChanged: { isHovering in
                        viewModel.isHoveringAddTagButton = isHovering
                        if isHovering && !viewModel.showTagSubmenu {
                            viewModel.recordTagSubmenuOpen(source: "context_menu_hover")
                            withAnimation(.easeOut(duration: 0.15)) {
                                viewModel.showCommentSubmenu = false
                                viewModel.showTagSubmenu = true
                            }
                        }
                    }
                ) {
                    // Toggle on click as well
                    if !viewModel.showTagSubmenu {
                        viewModel.recordTagSubmenuOpen(source: "context_menu_click")
                    }
                    withAnimation(.easeOut(duration: 0.15)) {
                        viewModel.showCommentSubmenu = false
                        viewModel.showTagSubmenu.toggle()
                    }
                }

                // Add Comment button (opens a dedicated comment overlay)
                TimelineMenuButton(
                    icon: "text.bubble",
                    title: "Add Comment",
                    shortcut: "⌥C",
                    onHoverChanged: { isHovering in
                        // Close tag submenu when hovering over other items
                        if isHovering && viewModel.showTagSubmenu {
                            withAnimation(.easeOut(duration: 0.15)) {
                                viewModel.showTagSubmenu = false
                            }
                        }
                    }
                ) {
                    withAnimation(.easeOut(duration: 0.15)) {
                        viewModel.showTagSubmenu = false
                        viewModel.showTimelineContextMenu = false
                        viewModel.showCommentSubmenu = true
                    }
                    viewModel.recordCommentSubmenuOpen(source: "context_menu_click")
                    Task { await viewModel.loadCommentsForSelectedTimelineBlock() }
                }

                // Filter button
                TimelineMenuButton(
                    icon: "line.3.horizontal.decrease",
                    title: "Filter App",
                    shortcut: "⌥F",
                    onHoverChanged: { isHovering in
                        // Close submenus when hovering over other items
                        if isHovering && (viewModel.showTagSubmenu || viewModel.showCommentSubmenu) {
                            withAnimation(.easeOut(duration: 0.15)) {
                                viewModel.showTagSubmenu = false
                                viewModel.showCommentSubmenu = false
                                viewModel.showNewTagInput = false
                                viewModel.newTagName = ""
                            }
                        }
                    }
                ) {
                    viewModel.toggleQuickAppFilterForSelectedTimelineSegment()
                }

                // Hide button
                TimelineMenuButton(
                    icon: "eye.slash",
                    title: "Hide",
                    shortcut: "⌥H",
                    onHoverChanged: { isHovering in
                        // Close submenus when hovering over other items
                        if isHovering && (viewModel.showTagSubmenu || viewModel.showCommentSubmenu) {
                            withAnimation(.easeOut(duration: 0.15)) {
                                viewModel.showTagSubmenu = false
                                viewModel.showCommentSubmenu = false
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
                    shortcut: "⌫",
                    isDestructive: true,
                    onHoverChanged: { isHovering in
                        // Close submenus when hovering over other items
                        if isHovering && (viewModel.showTagSubmenu || viewModel.showCommentSubmenu) {
                            withAnimation(.easeOut(duration: 0.15)) {
                                viewModel.showTagSubmenu = false
                                viewModel.showCommentSubmenu = false
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
                    .position(tagSubmenuPosition)
                    .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .leading)))
            }

        }
        .transition(
            .asymmetric(
                insertion: .opacity.combined(with: .scale(scale: 0.95, anchor: anchorPoint)),
                removal: .opacity.combined(with: .scale(scale: 0.98, anchor: anchorPoint))
            )
        )
        .animation(.easeOut(duration: 0.15), value: isPresented)
        .animation(.spring(response: 0.2, dampingFraction: 0.8), value: viewModel.showTagSubmenu)
        .animation(.spring(response: 0.2, dampingFraction: 0.8), value: viewModel.showCommentSubmenu)
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
    private func submenuPosition(rowOffset: CGFloat, submenuWidth: CGFloat) -> CGPoint {
        var x = adjustedPosition.x + menuWidth / 2 + submenuWidth / 2 + 4
        let y = adjustedPosition.y - menuHeight / 2 + rowOffset

        // If submenu would go off right edge, show on left side instead
        if x + submenuWidth / 2 > containerSize.width - edgePadding {
            x = adjustedPosition.x - menuWidth / 2 - submenuWidth / 2 - 4
        }

        return CGPoint(x: x, y: y)
    }

    /// Submenu position aligned with the "Add Tag" row
    private var tagSubmenuPosition: CGPoint {
        submenuPosition(rowOffset: 40, submenuWidth: tagSubmenuWidth)
    }

    private var anchorPoint: UnitPoint {
        shouldShowAbove ? .bottomLeading : .topLeading
    }
}

// MARK: - Timeline Menu Button

/// A button in the timeline context menu
// TimelineMenuButton: now uses the unified RetraceMenuButton from AppTheme
typealias TimelineMenuButton = RetraceMenuButton

/// Specialized tag row for the timeline context menu.
/// Shows compact selected-tag badges, and only shows the shortcut hint in the neutral "Add Tag" state.
struct TimelineTagMenuButton: View {
    let selectedTags: [Tag]
    var onHoverChanged: ((Bool) -> Void)? = nil
    let action: () -> Void

    @State private var isHovering = false

    private var isTagged: Bool { !selectedTags.isEmpty }
    private var icon: String { "tag" }
    private var visibleTags: [Tag] { Array(selectedTags.prefix(2)) }
    private var overflowCount: Int { max(0, selectedTags.count - visibleTags.count) }

    var body: some View {
        Button(action: action) {
            HStack(spacing: RetraceMenuStyle.iconTextSpacing) {
                Image(systemName: icon)
                    .font(.system(size: RetraceMenuStyle.iconSize, weight: RetraceMenuStyle.fontWeight))
                    .foregroundColor(foregroundColor)
                    .frame(width: RetraceMenuStyle.iconFrameWidth)

                if isTagged {
                    HStack(spacing: 4) {
                        ForEach(visibleTags) { tag in
                            tagBadge(tag)
                        }

                        if overflowCount > 0 {
                            Text("+\(overflowCount)")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(.white.opacity(isHovering ? 0.9 : 0.75))
                                .padding(.horizontal, 4)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("Add Tag")
                        .font(RetraceMenuStyle.font)
                        .foregroundColor(foregroundColor)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(1)

                    Spacer(minLength: 0)

                    Text("⌥T")
                        .font(RetraceMenuStyle.shortcutFont)
                        .foregroundColor(shortcutColor)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .frame(minWidth: RetraceMenuStyle.shortcutColumnMinWidth, alignment: .trailing)
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: RetraceMenuStyle.chevronSize, weight: .bold))
                    .foregroundColor(RetraceMenuStyle.chevronColor)
            }
            .padding(.horizontal, RetraceMenuStyle.itemPaddingH)
            .padding(.vertical, RetraceMenuStyle.itemPaddingV)
            .background(
                RoundedRectangle(cornerRadius: RetraceMenuStyle.itemCornerRadius)
                    .fill(isHovering ? RetraceMenuStyle.itemHoverColor : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: RetraceMenuStyle.hoverAnimationDuration)) {
                isHovering = hovering
            }
            if hovering { NSCursor.pointingHand.push() }
            else { NSCursor.pop() }
            onHoverChanged?(hovering)
        }
    }

    private var foregroundColor: Color {
        isHovering ? RetraceMenuStyle.textColor : RetraceMenuStyle.textColorMuted
    }

    private var shortcutColor: Color {
        RetraceMenuStyle.textColorMuted.opacity(isHovering ? 0.95 : 0.7)
    }

    @ViewBuilder
    private func tagBadge(_ tag: Tag) -> some View {
        let tint = TagColorStore.color(for: tag)
        HStack(spacing: 4) {
            Circle()
                .fill(tint.opacity(0.95))
                .frame(width: 5, height: 5)

            Text(tag.name)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.white.opacity(isHovering ? 0.95 : 0.85))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .frame(maxWidth: 62)
        .background(
            Capsule()
                .fill(tint.opacity(isHovering ? 0.26 : 0.18))
        )
        .overlay(
            Capsule()
                .stroke(tint.opacity(isHovering ? 0.45 : 0.32), lineWidth: 0.8)
        )
    }
}

// MARK: - Tag Submenu

/// Submenu showing available tags with search/create functionality
struct TagSubmenu: View {
    @ObservedObject var viewModel: SimpleTimelineViewModel
    @State private var isHoveringSubmenu = false
    @State private var closeTask: Task<Void, Never>?
    @State private var searchText = ""
    @State private var highlightedTagID: Int64?
    @State private var isHoveringSettingsButton = false
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

    private var visibleTagIDs: [Int64] {
        visibleTags.map { $0.id.value }
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
                        } else if let highlightedTagID,
                           let highlightedTag = visibleTags.first(where: { $0.id.value == highlightedTagID }) {
                            viewModel.toggleTagOnSelectedSegment(tag: highlightedTag)
                        }
                    }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.white.opacity(0.08))
            )
            .contentShape(Rectangle())
            .onTapGesture {
                isSearchFocused = true
            }
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
                                isSelected: viewModel.selectedSegmentTags.contains(tag.id),
                                isKeyboardHighlighted: highlightedTagID == tag.id.value,
                                onHoverChanged: { hovering in
                                    if hovering {
                                        highlightedTagID = tag.id.value
                                    }
                                }
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

            Divider()
                .background(Color.white.opacity(0.1))
                .padding(.horizontal, 8)
                .padding(.top, 6)

            Button(action: openTagSettings) {
                HStack(spacing: 10) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.72))

                    Text("Tag Settings")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white.opacity(0.9))

                    Spacer()
                }
                .padding(.leading, 0)
                .padding(.trailing, 12)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isHoveringSettingsButton ? Color.white.opacity(0.1) : Color.clear)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)
            .padding(.top, 4)
            .padding(.bottom, 6)
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.1)) {
                    isHoveringSettingsButton = hovering
                }
                if hovering { NSCursor.pointingHand.push() }
                else { NSCursor.pop() }
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
            syncHighlightedTagToFirstVisibleResult()
        }
        .onChange(of: searchText) { _ in
            syncHighlightedTagToFirstVisibleResult()
        }
        .onChange(of: visibleTagIDs) { _ in
            syncHighlightedTagToFirstVisibleResult()
        }
        .onHover { hovering in
            isHoveringSubmenu = hovering
            if !hovering {
                // Small delay before closing to allow mouse to move back to main menu or Add Tag button
                closeTask?.cancel()
                closeTask = Task {
                    try? await Task.sleep(for: .nanoseconds(Int64(150_000_000)), clock: .continuous) // 150ms delay
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

    private func syncHighlightedTagToFirstVisibleResult() {
        if let highlightedTagID, visibleTagIDs.contains(highlightedTagID) {
            return
        }
        highlightedTagID = visibleTagIDs.first
    }

    private func createTagFromSearch() {
        let tagName = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tagName.isEmpty else { return }

        viewModel.newTagName = tagName
        viewModel.createAndAddTag()
        searchText = ""
    }

    private func openTagSettings() {
        closeTask?.cancel()
        withAnimation(.easeOut(duration: 0.12)) {
            viewModel.showTagSubmenu = false
            viewModel.showTimelineContextMenu = false
            searchText = ""
        }

        TimelineWindowController.shared.hideToShowDashboard()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            DashboardWindowController.shared.show()
            NotificationCenter.default.post(name: .openSettingsTags, object: nil)
        }
    }
}

// MARK: - Comment Overlay

/// Dedicated overlay for creating rich comments and browsing the existing thread for the selected block.
struct CommentSubmenu: View {
    @ObservedObject var viewModel: SimpleTimelineViewModel
    let onClose: () -> Void
    @State private var commentKeyboardMonitor: Any?
    @State private var isCommentFocused = false
    @State private var editorCommand: CommentEditorCommand = .bold
    @State private var editorCommandNonce: Int = 0
    @State private var isLinkPopoverPresented = false
    @State private var pendingLinkURL = "https://"
    @State private var hoveredCommentID: SegmentCommentID?
    @State private var hoveredAllCommentsRowID: SegmentCommentID?
    @State private var highlightedCommentSearchResultID: SegmentCommentID?
    @State private var pendingDeleteComment: SegmentComment?
    @State private var isDeletingComment: Bool = false
    @State private var commentBrowserMode: CommentBrowserMode = .thread
    @State private var allCommentsAnchorID: SegmentCommentID?
    @State private var allCommentsVisibleBeforeCount: Int = 0
    @State private var allCommentsVisibleAfterCount: Int = 0
    @State private var hasPerformedAllCommentsInitialScroll = false
    @State private var isRequestingOlderCommentPage = false
    @State private var isRequestingNewerCommentPage = false
    @State private var pendingAnchorPinnedCommentID: SegmentCommentID?
    @State private var isNavigatingLinkedCommentFrame = false
    @FocusState private var isAllCommentsSearchFieldFocused: Bool
    @FocusState private var isLinkFieldFocused: Bool
    private let submenuWidth: CGFloat = 420
    private let submenuHeight: CGFloat = 560
    private let sectionCornerRadius: CGFloat = 14
    private let allCommentsPageSize: Int = 10

    private enum CommentBrowserMode {
        case thread
        case allComments
    }

    private static let threadDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private var trimmedComment: String {
        viewModel.newCommentText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSubmit: Bool {
        !trimmedComment.isEmpty && !viewModel.isAddingComment
    }

    private var hasActiveCommentSearch: Bool {
        !viewModel.commentSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var commentSearchBinding: Binding<String> {
        Binding(
            get: { viewModel.commentSearchText },
            set: { viewModel.updateCommentSearchQuery($0) }
        )
    }

    private var normalizedPendingLinkURL: URL? {
        Self.normalizedURL(from: pendingLinkURL)
    }

    private var isDeleteConfirmationPresented: Binding<Bool> {
        Binding(
            get: { pendingDeleteComment != nil },
            set: { shouldShow in
                if !shouldShow {
                    pendingDeleteComment = nil
                    isDeletingComment = false
                }
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            commentHeader
            if commentBrowserMode == .thread {
                commentThreadSection
                    .frame(maxHeight: .infinity)
                    .layoutPriority(1)
                commentComposerSection
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                allCommentsSection
                    .frame(maxHeight: .infinity)
                    .layoutPriority(1)
            }
        }
        .frame(width: submenuWidth)
        .frame(height: submenuHeight, alignment: .top)
        .padding(.horizontal, 16)
        .padding(.vertical, 15)
        .retraceMenuContainer(addPadding: false)
        .onAppear {
            installCommentKeyboardMonitor()
            commentBrowserMode = .thread
            allCommentsAnchorID = nil
            allCommentsVisibleBeforeCount = 0
            allCommentsVisibleAfterCount = 0
            hasPerformedAllCommentsInitialScroll = false
            isRequestingOlderCommentPage = false
            isRequestingNewerCommentPage = false
            pendingAnchorPinnedCommentID = nil
            highlightedCommentSearchResultID = nil
            isAllCommentsSearchFieldFocused = false
            viewModel.isAllCommentsBrowserActive = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isCommentFocused = true
            }
            if viewModel.selectedBlockComments.isEmpty && !viewModel.isLoadingBlockComments {
                Task { await viewModel.loadCommentsForSelectedTimelineBlock() }
            }
        }
        .onChange(of: commentBrowserMode) { mode in
            viewModel.isAllCommentsBrowserActive = (mode == .allComments)
            if mode == .allComments {
                syncHighlightedCommentSearchSelection()
                DispatchQueue.main.async {
                    isAllCommentsSearchFieldFocused = true
                }
            } else {
                highlightedCommentSearchResultID = nil
                isAllCommentsSearchFieldFocused = false
            }
        }
        .onChange(of: viewModel.returnToThreadCommentsSignal) { _ in
            guard commentBrowserMode == .allComments else { return }
            withAnimation(.easeOut(duration: 0.14)) {
                exitAllCommentsView()
            }
        }
        .onChange(of: viewModel.commentSearchText) { _ in
            syncHighlightedCommentSearchSelection()
        }
        .onChange(of: viewModel.commentSearchResults.map { $0.id.value }) { _ in
            syncHighlightedCommentSearchSelection()
        }
        .onChange(of: isLinkPopoverPresented) { isPresented in
            viewModel.isCommentLinkPopoverPresented = isPresented
        }
        .onChange(of: viewModel.closeCommentLinkPopoverSignal) { _ in
            guard isLinkPopoverPresented else { return }
            isLinkPopoverPresented = false
            isCommentFocused = true
        }
        .onDisappear {
            removeCommentKeyboardMonitor()
            viewModel.isCommentLinkPopoverPresented = false
            viewModel.isAllCommentsBrowserActive = false
            isAllCommentsSearchFieldFocused = false
            viewModel.resetCommentTimelineState()
        }
        .alert(
            "Delete comment?",
            isPresented: isDeleteConfirmationPresented,
            presenting: pendingDeleteComment
        ) { comment in
            Button("Cancel", role: .cancel) {
                pendingDeleteComment = nil
            }
            Button(isDeletingComment ? "Deleting..." : "Delete", role: .destructive) {
                confirmDelete(comment)
            }
            .disabled(isDeletingComment)
        } message: { _ in
            Text("This removes the comment from all segments in this selected block. If it has no remaining links, it will be deleted permanently.")
        }
    }

    private var commentHeader: some View {
        HStack(spacing: 12) {
            if commentBrowserMode == .allComments {
                Button(action: exitAllCommentsView) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.retracePrimary.opacity(0.9))
                        .frame(width: 24, height: 24)
                        .background(
                            Circle()
                                .fill(Color.white.opacity(0.08))
                        )
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    if hovering { NSCursor.pointingHand.push() }
                    else { NSCursor.pop() }
                }
            }

            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(0.08))
                .frame(width: 34, height: 34)
                .overlay(
                    Image(systemName: "text.bubble.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.retracePrimary.opacity(0.92))
                )

            VStack(alignment: .leading, spacing: 0) {
                Text(commentBrowserMode == .allComments ? "All Comments" : "Comments")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.retracePrimary)
            }

            Spacer()

            if commentBrowserMode == .thread {
                Button(action: { openAllComments(anchoredAt: allCommentsLaunchAnchorComment) }) {
                    HStack(spacing: 6) {
                        Image(systemName: "list.bullet")
                            .font(.system(size: 10, weight: .semibold))
                        Text("All Comments")
                            .font(.system(size: 11, weight: .semibold))
                        Text("⌥A")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.retraceSecondary.opacity(0.85))
                            .padding(.leading, 2)
                    }
                    .foregroundColor(.retracePrimary.opacity(0.9))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(
                        Capsule()
                            .fill(Color.white.opacity(0.08))
                    )
                    .overlay(
                        Capsule()
                            .stroke(Color.white.opacity(0.14), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .help("Open All Comments (Option+A)")
                .onHover { hovering in
                    if hovering { NSCursor.pointingHand.push() }
                    else { NSCursor.pop() }
                }
            }

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.retraceSecondary)
                    .frame(width: 24, height: 24)
                    .background(
                        Circle()
                            .fill(Color.white.opacity(0.08))
                    )
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                if hovering { NSCursor.pointingHand.push() }
                else { NSCursor.pop() }
            }
        }
    }

    private var commentThreadSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(threadCountLabel)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.retraceSecondary)
            }

            if viewModel.isLoadingBlockComments {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading thread...")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.retraceSecondary)
                }
                .frame(maxWidth: .infinity, minHeight: 58, alignment: .center)
            } else if let loadError = viewModel.blockCommentsLoadError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.retraceDanger.opacity(0.9))
                    Text(loadError)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.retraceSecondary)
                }
                .frame(maxWidth: .infinity, minHeight: 58, alignment: .center)
            } else if viewModel.selectedBlockComments.isEmpty {
                Text("No comments yet. Start the thread below.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.retraceSecondary)
                    .frame(maxWidth: .infinity, minHeight: 58, alignment: .center)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(viewModel.selectedBlockComments) { comment in
                            commentThreadCard(comment)
                        }
                    }
                    .padding(.vertical, 3)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: sectionCornerRadius)
                .fill(Color.white.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: sectionCornerRadius)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
    }

    private var allCommentsAnchorIndex: Int? {
        let rows = viewModel.commentTimelineRows
        guard !rows.isEmpty else { return nil }

        if let explicitAnchor = allCommentsAnchorID,
           let index = rows.firstIndex(where: { $0.id == explicitAnchor }) {
            return index
        }

        if let vmAnchor = viewModel.commentTimelineAnchorCommentID,
           let index = rows.firstIndex(where: { $0.id == vmAnchor }) {
            return index
        }

        return rows.count / 2
    }

    private var allCommentsAvailableBeforeCount: Int {
        allCommentsAnchorIndex ?? 0
    }

    private var allCommentsAvailableAfterCount: Int {
        guard let anchorIndex = allCommentsAnchorIndex else { return 0 }
        return max(0, viewModel.commentTimelineRows.count - anchorIndex - 1)
    }

    private var allCommentsVisibleRows: [CommentTimelineRow] {
        let rows = viewModel.commentTimelineRows
        guard let anchorIndex = allCommentsAnchorIndex, !rows.isEmpty else { return [] }

        let clampedBefore = min(allCommentsVisibleBeforeCount, allCommentsAvailableBeforeCount)
        let clampedAfter = min(allCommentsVisibleAfterCount, allCommentsAvailableAfterCount)
        let startIndex = max(0, anchorIndex - clampedBefore)
        let endIndex = min(rows.count - 1, anchorIndex + clampedAfter)
        guard startIndex <= endIndex else { return [] }
        return Array(rows[startIndex...endIndex])
    }

    private var allCommentsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(hasActiveCommentSearch ? "Search Results (\(viewModel.commentSearchResults.count))" : allCommentsCountLabel)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.retraceSecondary)

            allCommentsSearchField

            if hasActiveCommentSearch {
                allCommentsSearchResultsSection
            } else if viewModel.isLoadingCommentTimeline {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading all comments...")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.retraceSecondary)
                }
                .frame(maxWidth: .infinity, minHeight: 80, alignment: .center)
            } else if let loadError = viewModel.commentTimelineLoadError,
                      viewModel.commentTimelineRows.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.retraceDanger.opacity(0.9))
                    Text(loadError)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.retraceSecondary)
                }
                .frame(maxWidth: .infinity, minHeight: 80, alignment: .center)
            } else if viewModel.commentTimelineRows.isEmpty {
                Text("No related comments found.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.retraceSecondary)
                    .frame(maxWidth: .infinity, minHeight: 80, alignment: .center)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            if viewModel.isLoadingOlderCommentTimeline {
                                HStack(spacing: 8) {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text("Loading older...")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundColor(.retraceSecondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.vertical, 2)
                            }

                            ForEach(allCommentsVisibleRows) { row in
                                allCommentsTimelineCard(row)
                                    .id(row.id)
                                    .onAppear {
                                        handleAllCommentsRowAppear(row)
                                    }
                            }

                            if viewModel.isLoadingNewerCommentTimeline {
                                HStack(spacing: 8) {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text("Loading newer...")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundColor(.retraceSecondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.vertical, 2)
                            }
                        }
                        .padding(.vertical, 3)
                    }
                    .onAppear {
                        syncAllCommentsVisibleWindow(forceReset: true)
                        scrollToAllCommentsAnchorIfNeeded(proxy: proxy)
                        restorePinnedAllCommentsAnchorIfNeeded(proxy: proxy)
                    }
                    .onChange(of: viewModel.commentTimelineRows.count) { _ in
                        syncAllCommentsVisibleWindow(forceReset: false)
                        if viewModel.isLoadingCommentTimeline
                            || viewModel.isLoadingOlderCommentTimeline
                            || viewModel.isLoadingNewerCommentTimeline {
                            pinAllCommentsAnchorForNextViewportUpdate()
                        }
                        scrollToAllCommentsAnchorIfNeeded(proxy: proxy)
                        restorePinnedAllCommentsAnchorIfNeeded(proxy: proxy)
                    }
                    .onChange(of: allCommentsVisibleBeforeCount) { _ in
                        restorePinnedAllCommentsAnchorIfNeeded(proxy: proxy)
                    }
                    .onChange(of: allCommentsVisibleAfterCount) { _ in
                        restorePinnedAllCommentsAnchorIfNeeded(proxy: proxy)
                    }
                    .onChange(of: pendingAnchorPinnedCommentID) { _ in
                        restorePinnedAllCommentsAnchorIfNeeded(proxy: proxy)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: sectionCornerRadius)
                .fill(Color.white.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: sectionCornerRadius)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
    }

    private var allCommentsSearchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.retraceSecondary.opacity(0.85))

            TextField("Search comments", text: commentSearchBinding)
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.retracePrimary)
                .focused($isAllCommentsSearchFieldFocused)
                .onSubmit {
                    _ = openHighlightedCommentSearchResultIfPossible()
                }

            if !viewModel.commentSearchText.isEmpty {
                Button(action: { viewModel.updateCommentSearchQuery("") }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.retraceSecondary.opacity(0.85))
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    if hovering { NSCursor.pointingHand.push() }
                    else { NSCursor.pop() }
                }
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            isAllCommentsSearchFieldFocused = true
        }
    }

    @ViewBuilder
    private var allCommentsSearchResultsSection: some View {
        if viewModel.isSearchingComments && viewModel.commentSearchResults.isEmpty {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Searching comments...")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.retraceSecondary)
            }
            .frame(maxWidth: .infinity, minHeight: 80, alignment: .center)
        } else if let searchError = viewModel.commentSearchError,
                  viewModel.commentSearchResults.isEmpty {
            VStack(alignment: .center, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.retraceDanger.opacity(0.9))
                    Text(searchError)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.retraceSecondary)
                }

                Button("Retry") {
                    viewModel.retryCommentSearch()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.retracePrimary.opacity(0.9))
            }
            .frame(maxWidth: .infinity, minHeight: 80, alignment: .center)
        } else if viewModel.commentSearchResults.isEmpty {
            Text("No matching comments.")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.retraceSecondary)
                .frame(maxWidth: .infinity, minHeight: 80, alignment: .center)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(viewModel.commentSearchResults) { row in
                            allCommentsTimelineCard(row)
                                .id(row.id)
                                .onAppear {
                                    viewModel.loadMoreCommentSearchResultsIfNeeded(currentCommentID: row.id)
                                }
                        }

                        if viewModel.isSearchingComments && !viewModel.commentSearchResults.isEmpty {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Loading more...")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(.retraceSecondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 2)
                        }
                    }
                    .padding(.vertical, 3)
                }
                .onChange(of: highlightedCommentSearchResultID) { selectedID in
                    guard let selectedID else { return }
                    DispatchQueue.main.async {
                        withAnimation(.easeOut(duration: 0.14)) {
                            proxy.scrollTo(selectedID, anchor: .center)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
    }

    private var commentComposerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                formattingButton(icon: "bold") { sendEditorCommand(.bold) }
                formattingButton(icon: "italic") { sendEditorCommand(.italic) }
                linkFormattingButton
                formattingButton(icon: "clock") { viewModel.insertCommentTimestampMarkup() }
                formattingButton(icon: "paperclip") { viewModel.selectCommentAttachmentFiles() }
                Spacer()
                Button(action: {
                    viewModel.addCommentToSelectedSegment()
                }) {
                    HStack(spacing: 5) {
                        if viewModel.isAddingComment {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(viewModel.isAddingComment ? "Adding..." : "Add Comment")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundColor(canSubmit ? .white : .retraceSecondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(
                        Capsule()
                            .fill(canSubmit ? Color.retraceSubmitAccent.opacity(0.92) : Color.white.opacity(0.08))
                    )
                    .overlay(
                        Capsule()
                            .stroke(canSubmit ? Color.retraceSubmitAccent.opacity(0.35) : Color.white.opacity(0.12), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .disabled(!canSubmit)
                .onHover { hovering in
                    if hovering && canSubmit { NSCursor.pointingHand.push() }
                    else { NSCursor.pop() }
                }
            }

            ZStack(alignment: .topLeading) {
                CommentMarkdownEditor(
                    text: $viewModel.newCommentText,
                    isFocused: $isCommentFocused,
                    command: editorCommand,
                    commandNonce: editorCommandNonce,
                    onSubmit: submitCommentFromKeyboard,
                    onRequestLink: presentLinkPopover
                )
                    .frame(minHeight: 78, maxHeight: 78)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)

                if viewModel.newCommentText.isEmpty {
                    Text("Write a comment... Markdown supported.")
                        .font(.system(size: 12))
                        .foregroundColor(.retraceSecondary.opacity(0.75))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .allowsHitTesting(false)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.white.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(
                        isCommentFocused ? Color.white.opacity(0.22) : Color.white.opacity(0.1),
                        lineWidth: 1
                    )
            )
            .animation(.easeOut(duration: 0.12), value: isCommentFocused)

            if !viewModel.newCommentAttachmentDrafts.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(viewModel.newCommentAttachmentDrafts) { draft in
                            draftAttachmentChip(draft)
                        }
                    }
                    .padding(.vertical, 1)
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: sectionCornerRadius)
                .fill(Color.white.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: sectionCornerRadius)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
    }

    private func sendEditorCommand(_ command: CommentEditorCommand) {
        editorCommand = command
        editorCommandNonce += 1
    }

    private func submitCommentFromKeyboard() {
        guard canSubmit else { return }
        viewModel.addCommentToSelectedSegment()
    }

    private func confirmDelete(_ comment: SegmentComment) {
        guard !isDeletingComment else { return }
        isDeletingComment = true

        Task { @MainActor in
            let wasDeleted = await viewModel.removeCommentFromSelectedTimelineBlock(comment: comment)
            isDeletingComment = false
            if wasDeleted {
                pendingDeleteComment = nil
                if hoveredCommentID == comment.id {
                    hoveredCommentID = nil
                }
            }
        }
    }

    private var threadCountLabel: String {
        "Thread (\(viewModel.selectedBlockComments.count))"
    }

    private var allCommentsCountLabel: String {
        "All Comments (\(viewModel.commentTimelineRows.count))"
    }

    private var allCommentsLaunchAnchorComment: SegmentComment? {
        let sorted = viewModel.selectedBlockComments.sorted {
            if $0.createdAt == $1.createdAt {
                return $0.id.value < $1.id.value
            }
            return $0.createdAt < $1.createdAt
        }
        guard !sorted.isEmpty else { return nil }
        return sorted[sorted.count / 2]
    }

    private func openAllComments(anchoredAt comment: SegmentComment?) {
        pendingDeleteComment = nil
        isDeletingComment = false
        viewModel.resetCommentSearchState()
        highlightedCommentSearchResultID = nil
        isAllCommentsSearchFieldFocused = false
        allCommentsAnchorID = comment?.id
        allCommentsVisibleBeforeCount = 0
        allCommentsVisibleAfterCount = 0
        hasPerformedAllCommentsInitialScroll = false
        isRequestingOlderCommentPage = false
        isRequestingNewerCommentPage = false
        pendingAnchorPinnedCommentID = nil
        withAnimation(.easeOut(duration: 0.14)) {
            commentBrowserMode = .allComments
        }

        Task { @MainActor in
            await viewModel.loadCommentTimeline(anchoredAt: comment)
            syncAllCommentsVisibleWindow(forceReset: true)
        }
    }

    private func exitAllCommentsView() {
        commentBrowserMode = .thread
        highlightedCommentSearchResultID = nil
        isAllCommentsSearchFieldFocused = false
        allCommentsAnchorID = nil
        allCommentsVisibleBeforeCount = 0
        allCommentsVisibleAfterCount = 0
        hasPerformedAllCommentsInitialScroll = false
        isRequestingOlderCommentPage = false
        isRequestingNewerCommentPage = false
        pendingAnchorPinnedCommentID = nil
        viewModel.resetCommentTimelineState()
    }

    private func syncAllCommentsVisibleWindow(forceReset: Bool) {
        guard commentBrowserMode == .allComments,
              let anchorIndex = allCommentsAnchorIndex else {
            return
        }

        let availableBefore = anchorIndex
        let availableAfter = max(0, viewModel.commentTimelineRows.count - anchorIndex - 1)

        if forceReset || (allCommentsVisibleBeforeCount == 0 && allCommentsVisibleAfterCount == 0) {
            var before = min(allCommentsPageSize / 2, availableBefore)
            var after = min(max(0, allCommentsPageSize - before - 1), availableAfter)

            let selectedCommentIDs = Set(viewModel.selectedBlockComments.map(\.id))
            if !selectedCommentIDs.isEmpty {
                let selectedIndexes = viewModel.commentTimelineRows.enumerated().compactMap { index, row in
                    selectedCommentIDs.contains(row.id) ? index : nil
                }
                if let minSelectedIndex = selectedIndexes.min(),
                   let maxSelectedIndex = selectedIndexes.max() {
                    before = max(before, anchorIndex - minSelectedIndex)
                    after = max(after, maxSelectedIndex - anchorIndex)
                }
            }

            before = min(before, availableBefore)
            after = min(after, availableAfter)

            let visibleCount = before + after + 1
            if visibleCount < allCommentsPageSize {
                let remaining = allCommentsPageSize - visibleCount
                let extraBefore = min(remaining, max(0, availableBefore - before))
                before += extraBefore
                let extraAfter = min(
                    allCommentsPageSize - (before + after + 1),
                    max(0, availableAfter - after)
                )
                after += extraAfter
            }
            allCommentsVisibleBeforeCount = before
            allCommentsVisibleAfterCount = after
            return
        }

        allCommentsVisibleBeforeCount = min(allCommentsVisibleBeforeCount, availableBefore)
        allCommentsVisibleAfterCount = min(allCommentsVisibleAfterCount, availableAfter)
    }

    private func scrollToAllCommentsAnchorIfNeeded(proxy: ScrollViewProxy) {
        guard commentBrowserMode == .allComments,
              !hasPerformedAllCommentsInitialScroll else {
            return
        }

        let anchorID = allCommentsAnchorID ?? viewModel.commentTimelineAnchorCommentID
        guard let anchorID else { return }
        guard allCommentsVisibleRows.contains(where: { $0.id == anchorID }) else { return }

        hasPerformedAllCommentsInitialScroll = true
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.18)) {
                proxy.scrollTo(anchorID, anchor: .center)
            }
        }
    }

    private func restorePinnedAllCommentsAnchorIfNeeded(proxy: ScrollViewProxy) {
        guard commentBrowserMode == .allComments,
              let pinnedID = pendingAnchorPinnedCommentID,
              allCommentsVisibleRows.contains(where: { $0.id == pinnedID }) else {
            return
        }

        pendingAnchorPinnedCommentID = nil
        DispatchQueue.main.async {
            proxy.scrollTo(pinnedID, anchor: .center)
        }
    }

    private func pinAllCommentsAnchorForNextViewportUpdate() {
        guard commentBrowserMode == .allComments else { return }
        if let anchorID = allCommentsAnchorID ?? viewModel.commentTimelineAnchorCommentID {
            pendingAnchorPinnedCommentID = anchorID
        }
    }

    private func handleAllCommentsRowAppear(_ row: CommentTimelineRow) {
        guard commentBrowserMode == .allComments else { return }
        guard !allCommentsVisibleRows.isEmpty else { return }

        if let firstID = allCommentsVisibleRows.first?.id, row.id == firstID {
            requestOlderCommentRowsIfNeeded()
        }

        if let lastID = allCommentsVisibleRows.last?.id, row.id == lastID {
            requestNewerCommentRowsIfNeeded()
        }
    }

    private func requestOlderCommentRowsIfNeeded() {
        let availableBefore = allCommentsAvailableBeforeCount
        if allCommentsVisibleBeforeCount < availableBefore {
            pinAllCommentsAnchorForNextViewportUpdate()
            allCommentsVisibleBeforeCount = min(
                availableBefore,
                allCommentsVisibleBeforeCount + allCommentsPageSize
            )
            return
        }

        guard viewModel.commentTimelineHasOlder,
              !viewModel.isLoadingOlderCommentTimeline,
              !isRequestingOlderCommentPage else {
            return
        }

        isRequestingOlderCommentPage = true
        Task { @MainActor in
            defer { isRequestingOlderCommentPage = false }
            pinAllCommentsAnchorForNextViewportUpdate()
            await viewModel.loadOlderCommentTimelinePage()
            syncAllCommentsVisibleWindow(forceReset: false)
            let refreshedBefore = allCommentsAvailableBeforeCount
            if allCommentsVisibleBeforeCount < refreshedBefore {
                pinAllCommentsAnchorForNextViewportUpdate()
                allCommentsVisibleBeforeCount = min(
                    refreshedBefore,
                    allCommentsVisibleBeforeCount + allCommentsPageSize
                )
            }
        }
    }

    private func requestNewerCommentRowsIfNeeded() {
        let availableAfter = allCommentsAvailableAfterCount
        if allCommentsVisibleAfterCount < availableAfter {
            pinAllCommentsAnchorForNextViewportUpdate()
            allCommentsVisibleAfterCount = min(
                availableAfter,
                allCommentsVisibleAfterCount + allCommentsPageSize
            )
            return
        }

        guard viewModel.commentTimelineHasNewer,
              !viewModel.isLoadingNewerCommentTimeline,
              !isRequestingNewerCommentPage else {
            return
        }

        isRequestingNewerCommentPage = true
        Task { @MainActor in
            defer { isRequestingNewerCommentPage = false }
            pinAllCommentsAnchorForNextViewportUpdate()
            await viewModel.loadNewerCommentTimelinePage()
            syncAllCommentsVisibleWindow(forceReset: false)
            let refreshedAfter = allCommentsAvailableAfterCount
            if allCommentsVisibleAfterCount < refreshedAfter {
                pinAllCommentsAnchorForNextViewportUpdate()
                allCommentsVisibleAfterCount = min(
                    refreshedAfter,
                    allCommentsVisibleAfterCount + allCommentsPageSize
                )
            }
        }
    }

    private func allCommentsTimelineCard(_ row: CommentTimelineRow) -> some View {
        let anchorID = allCommentsAnchorID ?? viewModel.commentTimelineAnchorCommentID
        let isAnchor = row.id == anchorID &&
            (highlightedCommentSearchResultID == nil || highlightedCommentSearchResultID == anchorID)
        let isNavigable = true
        let isSearchHighlighted = row.id == highlightedCommentSearchResultID
        let isHoveringInteractiveRow = isNavigable && hoveredAllCommentsRowID == row.id
        let rowHeaderLabel = row.context?.appBundleID ?? row.comment.author

        return VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(rowHeaderLabel)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.retracePrimary.opacity(0.9))
                    .lineLimit(1)

                if let tagName = row.primaryTagName {
                    Text(tagName)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.retracePrimary.opacity(0.88))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            Capsule()
                                .fill(Color.white.opacity(0.08))
                        )
                        .overlay(
                            Capsule()
                                .stroke(Color.white.opacity(0.13), lineWidth: 1)
                        )
                        .lineLimit(1)
                }

                Spacer()

                Text(Self.threadDateFormatter.string(from: row.comment.createdAt))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.retraceSecondary.opacity(0.85))
                    .lineLimit(1)
            }

            Text(commentPreviewText(from: row.comment.body))
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.retracePrimary.opacity(0.95))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let browserURL = row.context?.browserURL {
                Text(browserURL)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.retraceSecondary.opacity(0.88))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(
                    isAnchor
                    ? Color.retraceSubmitAccent.opacity(0.16)
                    : (isSearchHighlighted ? Color.retraceSubmitAccent.opacity(0.12) : Color.white.opacity(0.05))
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(
                    isAnchor
                    ? Color.retraceSubmitAccent.opacity(0.42)
                    : (isSearchHighlighted ? Color.retraceSubmitAccent.opacity(0.34) : Color.white.opacity(0.1)),
                    lineWidth: 1
                )
        )
        .scaleEffect(isHoveringInteractiveRow ? 1.01 : 1.0)
        .animation(.easeOut(duration: 0.12), value: isHoveringInteractiveRow)
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture {
            guard isNavigable else { return }
            openLinkedComment(row.comment, preferredSegmentID: row.context?.segmentID)
        }
        .onHover { hovering in
            if hovering {
                hoveredAllCommentsRowID = row.id
                highlightedCommentSearchResultID = row.id
                if isNavigable {
                    NSCursor.pointingHand.push()
                }
            } else if hoveredAllCommentsRowID == row.id {
                hoveredAllCommentsRowID = nil
                if isNavigable {
                    NSCursor.pop()
                }
            }
        }
    }

    private func commentPreviewText(from body: String) -> String {
        let normalized = body
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let candidate = normalized
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? "No preview"

        if candidate.count <= 180 {
            return candidate
        }
        let index = candidate.index(candidate.startIndex, offsetBy: 180)
        return "\(candidate[..<index])..."
    }

    private var linkFormattingButton: some View {
        formattingButton(icon: "link") { presentLinkPopover() }
            .popover(
                isPresented: $isLinkPopoverPresented,
                attachmentAnchor: .point(.bottom),
                arrowEdge: .top
            ) {
                linkPopoverContent
            }
    }

    private var linkPopoverContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Insert Link")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.retracePrimary)

            TextField("https://example.com", text: $pendingLinkURL)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(.retracePrimary)
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.white.opacity(0.07))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
                .focused($isLinkFieldFocused)
                .contentShape(Rectangle())
                .onTapGesture {
                    isLinkFieldFocused = true
                }
                .onSubmit { insertLinkFromPopover() }

            HStack(spacing: 8) {
                Spacer()

                Button("Cancel") {
                    isLinkPopoverPresented = false
                    isCommentFocused = true
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.retraceSecondary)

                Button("Insert") {
                    insertLinkFromPopover()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(normalizedPendingLinkURL == nil ? .retraceSecondary : .white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule()
                        .fill(
                            normalizedPendingLinkURL == nil
                            ? Color.white.opacity(0.08)
                            : Color.retraceSubmitAccent.opacity(0.9)
                        )
                )
                .overlay(
                    Capsule()
                        .stroke(
                            normalizedPendingLinkURL == nil
                            ? Color.white.opacity(0.12)
                            : Color.retraceSubmitAccent.opacity(0.35),
                            lineWidth: 1
                        )
                )
                .disabled(normalizedPendingLinkURL == nil)
            }
        }
        .padding(12)
        .frame(width: 280)
        .background(Color.clear)
        .onAppear {
            DispatchQueue.main.async {
                isLinkFieldFocused = true
            }
        }
        .onDisappear {
            isLinkFieldFocused = false
            DispatchQueue.main.async {
                isCommentFocused = true
            }
        }
    }

    private func formattingButton(icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.retracePrimary.opacity(0.9))
                .frame(width: 26, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.white.opacity(0.07))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.white.opacity(0.11), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering { NSCursor.pointingHand.push() }
            else { NSCursor.pop() }
        }
    }

    private func presentLinkPopover() {
        if pendingLinkURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            pendingLinkURL = "https://"
        }
        // Prevent the NSTextView wrapper from re-claiming first responder while popover input is active.
        isCommentFocused = false
        isLinkPopoverPresented = true
        DispatchQueue.main.async {
            isLinkFieldFocused = true
        }
    }

    private func insertLinkFromPopover() {
        guard let url = normalizedPendingLinkURL else { return }
        isLinkPopoverPresented = false
        sendEditorCommand(.link(url: url.absoluteString))
        DispatchQueue.main.async {
            isCommentFocused = true
        }
    }

    private static func normalizedURL(from rawValue: String) -> URL? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let direct = URL(string: trimmed), direct.scheme != nil {
            return direct
        }
        return URL(string: "https://\(trimmed)")
    }

    private func draftAttachmentChip(_ draft: CommentAttachmentDraft) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "doc.fill")
                .font(.system(size: 10))
                .foregroundColor(.retraceSecondary.opacity(0.9))
            VStack(alignment: .leading, spacing: 1) {
                Text(draft.fileName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.retracePrimary.opacity(0.95))
                    .lineLimit(1)
                if let sizeBytes = draft.sizeBytes {
                    Text(ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.retraceSecondary)
                }
            }
            Button(action: { viewModel.removeCommentAttachmentDraft(draft) }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.retraceSecondary.opacity(0.9))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(Color.white.opacity(0.06))
        )
        .overlay(
            Capsule()
                .stroke(Color.white.opacity(0.11), lineWidth: 1)
        )
    }

    private func commentThreadCard(_ comment: SegmentComment) -> some View {
        let isHoveringCard = hoveredCommentID == comment.id
        let isNavigable = true
        let isHoveringInteractiveCard = isNavigable && isHoveringCard

        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(comment.author)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.retracePrimary)

                Text(Self.threadDateFormatter.string(from: comment.createdAt))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.retraceSecondary.opacity(0.85))

                Spacer()

                Button(role: .destructive) {
                    pendingDeleteComment = comment
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.retraceDanger.opacity(0.95))
                        .frame(width: 20, height: 20)
                        .background(
                            Circle()
                                .fill(Color.retraceDanger.opacity(0.14))
                        )
                        .overlay(
                            Circle()
                                .stroke(Color.retraceDanger.opacity(0.28), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .frame(width: 20, height: 20)
                .opacity(isHoveringCard ? 1 : 0)
                .allowsHitTesting(isHoveringCard)
                .animation(.easeOut(duration: 0.12), value: isHoveringCard)
                .onHover { hovering in
                    if hovering { NSCursor.pointingHand.push() }
                    else { NSCursor.pop() }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                renderedMarkdownView(from: comment.body)
                    .foregroundColor(.retracePrimary.opacity(0.95))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .environment(\.openURL, OpenURLAction { url in
                        NSWorkspace.shared.open(url)
                        return .handled
                    })

                if !comment.attachments.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(comment.attachments) { attachment in
                            Button(action: { viewModel.openCommentAttachment(attachment) }) {
                                HStack(spacing: 8) {
                                    Image(systemName: "paperclip")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundColor(.retraceSecondary.opacity(0.9))
                                    Text(attachment.fileName)
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundColor(.retracePrimary.opacity(0.95))
                                        .lineLimit(1)
                                    Spacer()
                                    if let sizeBytes = attachment.sizeBytes {
                                        Text(ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file))
                                            .font(.system(size: 10, weight: .medium))
                                            .foregroundColor(.retraceSecondary)
                                    }
                                }
                                .padding(.horizontal, 9)
                                .padding(.vertical, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Color.white.opacity(0.05))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Color.white.opacity(0.09), lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.white.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.white.opacity(0.1), lineWidth: 1)
            )
            .scaleEffect(isHoveringInteractiveCard ? 1.01 : 1.0)
            .animation(.easeOut(duration: 0.12), value: isHoveringInteractiveCard)
        }
        .padding(.trailing, 26)
        .contentShape(Rectangle())
        .onTapGesture {
            guard isNavigable else { return }
            openLinkedComment(
                comment,
                preferredSegmentID: viewModel.preferredSegmentIDForSelectedBlockComment(comment.id)
            )
        }
        .onHover { hovering in
            if hovering {
                hoveredCommentID = comment.id
                if isNavigable {
                    NSCursor.pointingHand.push()
                }
            } else if hoveredCommentID == comment.id {
                hoveredCommentID = nil
                if isNavigable {
                    NSCursor.pop()
                }
            }
        }
    }

    private func openLinkedComment(_ comment: SegmentComment, preferredSegmentID: SegmentID? = nil) {
        guard !isNavigatingLinkedCommentFrame else { return }
        isNavigatingLinkedCommentFrame = true
        Task { @MainActor in
            defer { isNavigatingLinkedCommentFrame = false }
            let didNavigate = await viewModel.navigateToComment(
                comment: comment,
                preferredSegmentID: preferredSegmentID
            )
            if didNavigate {
                onClose()
            }
        }
    }

    private func installCommentKeyboardMonitor() {
        guard commentKeyboardMonitor == nil else { return }
        commentKeyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if handleCommentSubmenuKeyEvent(event) {
                return nil
            }
            return event
        }
    }

    private func removeCommentKeyboardMonitor() {
        if let monitor = commentKeyboardMonitor {
            NSEvent.removeMonitor(monitor)
            commentKeyboardMonitor = nil
        }
    }

    private func handleCommentSubmenuKeyEvent(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])

        // Option+A opens all-comments when currently in thread mode.
        if modifiers == [.option], event.keyCode == 0, commentBrowserMode == .thread {
            openAllComments(anchoredAt: allCommentsLaunchAnchorComment)
            return true
        }

        guard commentBrowserMode == .allComments else { return false }

        // Cmd+[ and Escape should return to the local thread comments when browsing all comments.
        let isCommandBack = modifiers == [.command] &&
            (event.keyCode == 33 || event.charactersIgnoringModifiers == "[")
        if isCommandBack || (modifiers.isEmpty && event.keyCode == 53) {
            withAnimation(.easeOut(duration: 0.14)) {
                exitAllCommentsView()
            }
            return true
        }

        guard pendingDeleteComment == nil else { return false }
        guard !isLinkPopoverPresented else { return false }

        // Tab focuses the all-comments search bar. If already focused, seed
        // keyboard highlight to the first eligible result.
        if modifiers.isEmpty, event.keyCode == 48 {
            if isAllCommentsSearchFieldFocused {
                seedHighlightedCommentSearchSelectionIfNeeded()
            } else {
                isAllCommentsSearchFieldFocused = true
            }
            return true
        }

        guard modifiers.isEmpty else { return false }

        switch event.keyCode {
        case 125: // Down arrow
            moveCommentSearchHighlight(by: 1)
            return true
        case 126: // Up arrow
            moveCommentSearchHighlight(by: -1)
            return true
        case 36, 76: // Return / Enter
            return openHighlightedCommentSearchResultIfPossible()
        default:
            return false
        }
    }

    private var keyboardNavigableCommentRows: [CommentTimelineRow] {
        hasActiveCommentSearch ? viewModel.commentSearchResults : allCommentsVisibleRows
    }

    private func syncHighlightedCommentSearchSelection() {
        guard commentBrowserMode == .allComments else {
            highlightedCommentSearchResultID = nil
            return
        }

        let results = keyboardNavigableCommentRows
        guard !results.isEmpty else {
            highlightedCommentSearchResultID = nil
            return
        }

        if let current = highlightedCommentSearchResultID,
           results.contains(where: { $0.id == current }) {
            return
        }

        if let preferredIndex = preferredCommentKeyboardStartIndex(in: results) {
            highlightedCommentSearchResultID = results[preferredIndex].id
        } else {
            highlightedCommentSearchResultID = results.first?.id
        }
    }

    private func moveCommentSearchHighlight(by delta: Int) {
        let results = keyboardNavigableCommentRows
        guard !results.isEmpty else {
            highlightedCommentSearchResultID = nil
            return
        }

        let nextIndex: Int
        if let highlightedID = highlightedCommentSearchResultID,
           let index = results.firstIndex(where: { $0.id == highlightedID }) {
            nextIndex = min(max(index + delta, 0), results.count - 1)
        } else if let preferredIndex = preferredCommentKeyboardStartIndex(in: results) {
            // When opened from a thread anchor, arrow navigation should move relative to that anchor.
            nextIndex = min(max(preferredIndex + delta, 0), results.count - 1)
        } else {
            // No anchor context (e.g. opened without a thread): start at first result.
            nextIndex = 0
        }

        highlightedCommentSearchResultID = results[nextIndex].id
    }

    private func seedHighlightedCommentSearchSelectionIfNeeded() {
        guard commentBrowserMode == .allComments else { return }
        guard highlightedCommentSearchResultID == nil else { return }
        let results = keyboardNavigableCommentRows
        guard !results.isEmpty else { return }

        if let preferredIndex = preferredCommentKeyboardStartIndex(in: results) {
            highlightedCommentSearchResultID = results[preferredIndex].id
        } else {
            highlightedCommentSearchResultID = results.first?.id
        }
    }

    private func preferredCommentKeyboardStartIndex(in results: [CommentTimelineRow]) -> Int? {
        let anchorID = allCommentsAnchorID ?? viewModel.commentTimelineAnchorCommentID
        guard let anchorID else { return nil }
        return results.firstIndex(where: { $0.id == anchorID })
    }

    private func openHighlightedCommentSearchResultIfPossible() -> Bool {
        guard commentBrowserMode == .allComments else { return false }
        let rows = keyboardNavigableCommentRows
        guard !rows.isEmpty else { return false }

        let targetRow: CommentTimelineRow
        if let highlightedID = highlightedCommentSearchResultID,
           let row = rows.first(where: { $0.id == highlightedID }) {
            targetRow = row
        } else if let first = rows.first {
            targetRow = first
            highlightedCommentSearchResultID = first.id
        } else {
            return false
        }

        openLinkedComment(targetRow.comment, preferredSegmentID: targetRow.context?.segmentID)
        return true
    }

    @ViewBuilder
    private func renderedMarkdownView(from source: String) -> some View {
        let normalized = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")

        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                if line.isEmpty {
                    Text(" ")
                } else if let headingLevel = markdownHeadingLevel(in: line) {
                    Text(renderedMarkdownLine(from: line))
                        .font(markdownHeadingFont(for: headingLevel))
                } else {
                    Text(renderedMarkdownLine(from: line))
                }
            }
        }
    }

    private func renderedMarkdownLine(from source: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        if let parsed = try? AttributedString(markdown: source, options: options) {
            return parsed
        }
        return AttributedString(source)
    }

    private func markdownHeadingLevel(in line: String) -> Int? {
        let trimmedLeading = line.drop { $0 == " " || $0 == "\t" }
        guard !trimmedLeading.isEmpty else { return nil }

        var index = trimmedLeading.startIndex
        var level = 0
        while index < trimmedLeading.endIndex,
              trimmedLeading[index] == "#",
              level < 6 {
            level += 1
            index = trimmedLeading.index(after: index)
        }

        guard level > 0, index < trimmedLeading.endIndex else { return nil }
        guard trimmedLeading[index].isWhitespace else { return nil }
        return level
    }

    private func markdownHeadingFont(for level: Int) -> Font {
        let size = max(13.0, 20.0 - (Double(level - 1) * 1.8))
        return .system(size: size, weight: .semibold)
    }
}

private enum CommentEditorCommand: Equatable {
    case bold
    case italic
    case link(url: String)
}

private struct CommentMarkdownEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let command: CommentEditorCommand
    let commandNonce: Int
    let onSubmit: (() -> Void)?
    let onRequestLink: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let textStorage = NSTextStorage(
            attributedString: Coordinator.attributedString(fromMarkdown: text)
        )
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)

        let textContainer = NSTextContainer(containerSize: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        textContainer.widthTracksTextView = true
        layoutManager.addTextContainer(textContainer)

        let textView = CommentMarkdownTextView(frame: .zero, textContainer: textContainer)
        textView.delegate = context.coordinator
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = true
        textView.importsGraphics = false
        textView.allowsImageEditing = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.backgroundColor = NSColor.clear
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 0, height: 4)
        textView.textContainer?.lineFragmentPadding = 0
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.commandHandler = { command in
            context.coordinator.apply(command: command, in: textView)
        }
        textView.requestLinkHandler = {
            context.coordinator.parent.onRequestLink?()
        }
        textView.submitHandler = {
            context.coordinator.parent.onSubmit?()
        }

        scrollView.documentView = textView
        context.coordinator.normalizeEditorAttributes(in: textView)
        textView.typingAttributes = Coordinator.baseTypingAttributes
        context.coordinator.lastSerializedMarkdown = text
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? CommentMarkdownTextView else { return }
        context.coordinator.parent = self

        if context.coordinator.lastSerializedMarkdown != text {
            context.coordinator.isApplyingProgrammaticUpdate = true
            context.coordinator.replaceContents(of: textView, withMarkdown: text)
            context.coordinator.isApplyingProgrammaticUpdate = false
            context.coordinator.lastSerializedMarkdown = text
        }

        if context.coordinator.lastHandledCommandNonce != commandNonce {
            context.coordinator.lastHandledCommandNonce = commandNonce
            context.coordinator.apply(command: command, in: textView)
        }

        textView.submitHandler = {
            context.coordinator.parent.onSubmit?()
        }
        textView.requestLinkHandler = {
            context.coordinator.parent.onRequestLink?()
        }

        if isFocused, let window = textView.window, window.firstResponder !== textView {
            window.makeFirstResponder(textView)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CommentMarkdownEditor
        var isApplyingProgrammaticUpdate = false
        var lastHandledCommandNonce: Int = -1
        var lastSerializedMarkdown: String = ""

        private static let baseFont = NSFont.systemFont(ofSize: 12, weight: .regular)
        private static let baseColor = NSColor(white: 0.95, alpha: 1.0)
        private static let linkColor = NSColor(red: 0.56, green: 0.76, blue: 0.98, alpha: 1.0)
        private static let inlinePresentationIntentKey = NSAttributedString.Key("NSInlinePresentationIntent")
        private static let headingLevelAttributeKey = NSAttributedString.Key("RetraceHeadingLevel")
        private static let markdownParsingOptions = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )

        static let baseTypingAttributes: [NSAttributedString.Key: Any] = [
            .font: baseFont,
            .foregroundColor: baseColor
        ]

        private enum InlineStyle {
            case bold
            case italic
        }

        private struct HeadingShortcut {
            let level: Int
            let markerLength: Int
        }

        init(parent: CommentMarkdownEditor) {
            self.parent = parent
            self.lastHandledCommandNonce = parent.commandNonce
            self.lastSerializedMarkdown = parent.text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            guard !isApplyingProgrammaticUpdate else { return }

            isApplyingProgrammaticUpdate = true
            applyHeadingShortcutIfNeeded(in: textView)
            normalizeEditorAttributes(in: textView)
            syncMarkdownBinding(from: textView)
            isApplyingProgrammaticUpdate = false
        }

        func apply(command: CommentEditorCommand, in textView: NSTextView) {
            isApplyingProgrammaticUpdate = true
            switch command {
            case .bold:
                toggle(style: .bold, in: textView)
            case .italic:
                toggle(style: .italic, in: textView)
            case .link(let urlString):
                insertLink(in: textView, urlString: urlString)
            }
            normalizeEditorAttributes(in: textView)
            syncMarkdownBinding(from: textView)
            isApplyingProgrammaticUpdate = false
        }

        private func insertLink(in textView: NSTextView, urlString: String) {
            let selectedRange = textView.selectedRange()
            guard selectedRange.location != NSNotFound else { return }
            guard let storage = textView.textStorage else { return }
            guard let url = Self.normalizeLink(urlString) else { return }

            if selectedRange.length == 0 {
                let placeholder = "link text"
                textView.insertText(placeholder, replacementRange: selectedRange)
                let insertedRange = NSRange(location: selectedRange.location, length: (placeholder as NSString).length)
                applyLinkAttributes(in: insertedRange, storage: storage, url: url)
                textView.setSelectedRange(insertedRange)
                return
            }

            applyLinkAttributes(in: selectedRange, storage: storage, url: url)
            textView.setSelectedRange(selectedRange)
        }

        private func applyLinkAttributes(in range: NSRange, storage: NSTextStorage, url: URL?) {
            var attributes: [NSAttributedString.Key: Any] = [
                .foregroundColor: Self.linkColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue
            ]
            if let url {
                attributes[.link] = url
            }
            storage.addAttributes(attributes, range: range)
        }

        private func toggle(style: InlineStyle, in textView: NSTextView) {
            let selectedRange = textView.selectedRange()
            guard selectedRange.location != NSNotFound else { return }

            if selectedRange.length == 0 {
                var typingAttributes = textView.typingAttributes
                let currentFont = normalizeFont(typingAttributes[.font] as? NSFont)
                let shouldEnable = !font(currentFont, contains: style)
                typingAttributes[.font] = font(currentFont, setting: style, enabled: shouldEnable)
                typingAttributes[.foregroundColor] = Self.baseColor
                textView.typingAttributes = typingAttributes
                return
            }

            guard let storage = textView.textStorage else { return }
            let shouldEnable = !selectionFullyContains(style: style, range: selectedRange, storage: storage)
            storage.beginEditing()
            storage.enumerateAttribute(.font, in: selectedRange, options: []) { value, range, _ in
                let currentFont = normalizeFont(value as? NSFont)
                let updatedFont = font(currentFont, setting: style, enabled: shouldEnable)
                storage.addAttribute(.font, value: updatedFont, range: range)
            }
            storage.endEditing()
            textView.setSelectedRange(selectedRange)
        }

        private func selectionFullyContains(style: InlineStyle, range: NSRange, storage: NSTextStorage) -> Bool {
            var allStyled = true
            storage.enumerateAttribute(.font, in: range, options: []) { value, _, stop in
                let currentFont = normalizeFont(value as? NSFont)
                if !self.font(currentFont, contains: style) {
                    allStyled = false
                    stop.pointee = true
                }
            }
            return allStyled
        }

        func replaceContents(of textView: NSTextView, withMarkdown markdown: String) {
            guard let storage = textView.textStorage else { return }
            let attributed = Self.attributedString(fromMarkdown: markdown)
            storage.setAttributedString(attributed)
            normalizeEditorAttributes(in: textView)
            let insertionPoint = NSRange(location: storage.length, length: 0)
            textView.setSelectedRange(insertionPoint)
            textView.typingAttributes = Self.baseTypingAttributes
        }

        private func syncMarkdownBinding(from textView: NSTextView) {
            let markdown = Self.markdownString(from: textView.attributedString())
            lastSerializedMarkdown = markdown
            parent.text = markdown
        }

        private func applyHeadingShortcutIfNeeded(in textView: NSTextView) {
            guard let storage = textView.textStorage else { return }
            let source = storage.string as NSString
            guard source.length > 0 else { return }

            let selection = textView.selectedRange()
            guard selection.location != NSNotFound else { return }

            let lineLookupLocation = min(max(selection.location, 0), max(source.length - 1, 0))
            let lineRange = source.lineRange(for: NSRange(location: lineLookupLocation, length: 0))
            let contentRange = Self.lineContentRange(from: lineRange, in: source)
            guard contentRange.length > 0 else { return }

            let lineText = source.substring(with: contentRange)
            guard let shortcut = Self.parseHeadingShortcut(in: lineText) else { return }
            guard shortcut.markerLength > 0, shortcut.markerLength <= contentRange.length else { return }

            let markerRange = NSRange(location: contentRange.location, length: shortcut.markerLength)
            storage.replaceCharacters(in: markerRange, with: "")

            let updatedLineRange = NSRange(
                location: contentRange.location,
                length: max(0, contentRange.length - shortcut.markerLength)
            )
            if updatedLineRange.length > 0 {
                storage.addAttribute(Self.headingLevelAttributeKey, value: shortcut.level, range: updatedLineRange)
            }

            var adjustedSelection = selection
            let markerUpperBound = markerRange.location + markerRange.length
            if adjustedSelection.location >= markerUpperBound {
                adjustedSelection.location -= markerRange.length
            } else if adjustedSelection.location > markerRange.location {
                adjustedSelection.location = markerRange.location
            }
            if adjustedSelection.length > 0 {
                let selectionEnd = selection.location + selection.length
                let overlapStart = max(selection.location, markerRange.location)
                let overlapEnd = min(selectionEnd, markerUpperBound)
                if overlapEnd > overlapStart {
                    adjustedSelection.length = max(0, adjustedSelection.length - (overlapEnd - overlapStart))
                }
            }
            adjustedSelection.location = min(adjustedSelection.location, storage.length)
            textView.setSelectedRange(adjustedSelection)

            var typing = textView.typingAttributes
            typing[.font] = Self.headingBaseFont(for: shortcut.level)
            typing[.foregroundColor] = Self.baseColor
            typing[Self.headingLevelAttributeKey] = shortcut.level
            textView.typingAttributes = typing
        }

        private func normalizeHeadingAttributes(in storage: NSTextStorage) {
            let source = storage.string as NSString
            guard source.length > 0 else { return }

            var lineStart = 0
            while lineStart < source.length {
                let lineRange = source.lineRange(for: NSRange(location: lineStart, length: 0))
                let contentRange = Self.lineContentRange(from: lineRange, in: source)

                if contentRange.length > 0 {
                    if let level = Self.headingLevel(in: storage, range: contentRange) {
                        storage.addAttribute(Self.headingLevelAttributeKey, value: level, range: contentRange)
                    } else {
                        storage.removeAttribute(Self.headingLevelAttributeKey, range: contentRange)
                    }
                }

                let newlineLength = lineRange.length - contentRange.length
                if newlineLength > 0 {
                    let newlineRange = NSRange(location: contentRange.location + contentRange.length, length: newlineLength)
                    storage.removeAttribute(Self.headingLevelAttributeKey, range: newlineRange)
                }

                lineStart = lineRange.location + lineRange.length
            }
        }

        func normalizeEditorAttributes(in textView: NSTextView) {
            guard let storage = textView.textStorage else { return }
            let fullRange = NSRange(location: 0, length: storage.length)
            guard fullRange.length > 0 else {
                textView.typingAttributes = Self.baseTypingAttributes
                return
            }

            let selectedRanges = textView.selectedRanges

            storage.beginEditing()
            normalizeHeadingAttributes(in: storage)
            storage.addAttribute(.foregroundColor, value: Self.baseColor, range: fullRange)
            storage.addAttribute(.underlineStyle, value: 0, range: fullRange)

            storage.enumerateAttributes(in: fullRange, options: []) { attributes, range, _ in
                let currentFont = normalizeFont(attributes[.font] as? NSFont)
                let headingLevel = Self.headingLevelValue(from: attributes[Self.headingLevelAttributeKey])

                var targetFont = headingLevel.map(Self.headingBaseFont(for:)) ?? Self.baseFont
                let traits = currentFont.fontDescriptor.symbolicTraits
                if traits.contains(.bold) {
                    targetFont = NSFontManager.shared.convert(targetFont, toHaveTrait: .boldFontMask)
                }
                if traits.contains(.italic) {
                    targetFont = NSFontManager.shared.convert(targetFont, toHaveTrait: .italicFontMask)
                }
                storage.addAttribute(.font, value: targetFont, range: range)
            }

            storage.enumerateAttribute(.link, in: fullRange, options: []) { value, range, _ in
                guard Self.normalizeLink(value) != nil else { return }
                storage.addAttributes(
                    [
                        .foregroundColor: Self.linkColor,
                        .underlineStyle: NSUnderlineStyle.single.rawValue
                    ],
                    range: range
                )
            }

            storage.endEditing()
            textView.setSelectedRanges(selectedRanges, affinity: .downstream, stillSelecting: false)
            textView.typingAttributes = typingAttributes(for: textView)
        }

        private func typingAttributes(for textView: NSTextView) -> [NSAttributedString.Key: Any] {
            let currentFont = normalizeFont(textView.typingAttributes[.font] as? NSFont)

            var headingLevel: Int?
            if let storage = textView.textStorage, storage.length > 0 {
                let source = storage.string as NSString
                let selection = textView.selectedRange()
                let location = min(max(selection.location, 0), max(source.length - 1, 0))
                let lineRange = source.lineRange(for: NSRange(location: location, length: 0))
                let contentRange = Self.lineContentRange(from: lineRange, in: source)
                headingLevel = Self.headingLevel(in: storage, range: contentRange)
            }

            var targetFont = headingLevel.map(Self.headingBaseFont(for:)) ?? Self.baseFont
            let traits = currentFont.fontDescriptor.symbolicTraits
            if traits.contains(.bold) {
                targetFont = NSFontManager.shared.convert(targetFont, toHaveTrait: .boldFontMask)
            }
            if traits.contains(.italic) {
                targetFont = NSFontManager.shared.convert(targetFont, toHaveTrait: .italicFontMask)
            }

            var result: [NSAttributedString.Key: Any] = [
                .font: targetFont,
                .foregroundColor: Self.baseColor
            ]
            if let headingLevel {
                result[Self.headingLevelAttributeKey] = headingLevel
            }
            return result
        }

        private func normalizeFont(_ font: NSFont?) -> NSFont {
            let source = font ?? Self.baseFont
            let descriptor = source.fontDescriptor.symbolicTraits
            var normalized = Self.baseFont
            if descriptor.contains(.bold) {
                normalized = NSFontManager.shared.convert(normalized, toHaveTrait: .boldFontMask)
            }
            if descriptor.contains(.italic) {
                normalized = NSFontManager.shared.convert(normalized, toHaveTrait: .italicFontMask)
            }
            return normalized
        }

        private func font(_ font: NSFont, contains style: InlineStyle) -> Bool {
            let traits = font.fontDescriptor.symbolicTraits
            switch style {
            case .bold:
                return traits.contains(.bold)
            case .italic:
                return traits.contains(.italic)
            }
        }

        private func font(_ base: NSFont, setting style: InlineStyle, enabled: Bool) -> NSFont {
            let trait: NSFontTraitMask = {
                switch style {
                case .bold:
                    return .boldFontMask
                case .italic:
                    return .italicFontMask
                }
            }()

            if enabled {
                return NSFontManager.shared.convert(base, toHaveTrait: trait)
            }
            return NSFontManager.shared.convert(base, toNotHaveTrait: trait)
        }

        static func attributedString(fromMarkdown markdown: String) -> NSAttributedString {
            let normalized = markdown
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
            guard !normalized.isEmpty else {
                return NSAttributedString(string: "", attributes: baseTypingAttributes)
            }

            let output = NSMutableAttributedString()
            let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

            for (index, line) in lines.enumerated() {
                if let shortcut = parseHeadingShortcut(in: line) {
                    let contentStart = line.index(line.startIndex, offsetBy: min(shortcut.markerLength, line.count))
                    let content = String(line[contentStart...])
                    let attributedLine = attributedInlineString(fromInlineMarkdown: content)
                    if attributedLine.length > 0 {
                        attributedLine.addAttribute(headingLevelAttributeKey, value: shortcut.level, range: NSRange(location: 0, length: attributedLine.length))
                    }
                    output.append(attributedLine)
                } else {
                    output.append(attributedInlineString(fromInlineMarkdown: line))
                }

                if index < lines.count - 1 {
                    output.append(NSAttributedString(string: "\n", attributes: baseTypingAttributes))
                }
            }

            return output
        }

        private static func attributedInlineString(fromInlineMarkdown markdown: String) -> NSMutableAttributedString {
            guard let parsed = try? AttributedString(markdown: markdown, options: markdownParsingOptions) else {
                return NSMutableAttributedString(string: markdown, attributes: baseTypingAttributes)
            }

            let source = NSAttributedString(parsed)
            let output = NSMutableAttributedString(string: source.string, attributes: baseTypingAttributes)
            let fullRange = NSRange(location: 0, length: output.length)
            guard fullRange.length > 0 else { return output }

            source.enumerateAttribute(inlinePresentationIntentKey, in: fullRange, options: []) { value, range, _ in
                guard let intent = inlineIntent(from: value) else { return }
                var font = baseFont
                if intent.contains(.stronglyEmphasized) {
                    font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
                }
                if intent.contains(.emphasized) {
                    font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
                }
                output.addAttribute(.font, value: font, range: range)
            }

            source.enumerateAttribute(.link, in: fullRange, options: []) { value, range, _ in
                guard let link = normalizeLink(value) else { return }
                output.addAttributes(
                    [
                        .link: link,
                        .foregroundColor: linkColor,
                        .underlineStyle: NSUnderlineStyle.single.rawValue
                    ],
                    range: range
                )
            }

            return output
        }

        static func markdownString(from attributedText: NSAttributedString) -> String {
            guard attributedText.length > 0 else { return "" }

            let source = attributedText.string as NSString
            var lineStart = 0
            var lines: [String] = []

            while lineStart < source.length {
                let lineRange = source.lineRange(for: NSRange(location: lineStart, length: 0))
                let contentRange = lineContentRange(from: lineRange, in: source)
                let headingLevel = headingLevel(in: attributedText, range: contentRange)

                var lineMarkdown = markdownInlineString(
                    from: attributedText,
                    range: contentRange,
                    suppressBoldFromHeading: headingLevel != nil
                )
                if let headingLevel {
                    lineMarkdown = "\(String(repeating: "#", count: headingLevel)) \(lineMarkdown)"
                }
                lines.append(lineMarkdown)
                lineStart = lineRange.location + lineRange.length
            }

            var markdown = lines.joined(separator: "\n")
            if source.character(at: source.length - 1) == 10 {
                markdown += "\n"
            }
            return markdown
        }

        private static func markdownInlineString(
            from attributedText: NSAttributedString,
            range: NSRange,
            suppressBoldFromHeading: Bool
        ) -> String {
            guard range.length > 0 else { return "" }

            let source = attributedText.string as NSString
            var markdown = ""
            var index = range.location
            let end = range.location + range.length

            while index < end {
                var effectiveRange = NSRange(location: 0, length: 0)
                let attributes = attributedText.attributes(
                    at: index,
                    longestEffectiveRange: &effectiveRange,
                    in: range
                )
                let segment = source.substring(with: effectiveRange)
                markdown += markdownFragment(
                    for: segment,
                    attributes: attributes,
                    suppressBoldFromHeading: suppressBoldFromHeading
                )
                index = effectiveRange.location + effectiveRange.length
            }

            return markdown
        }

        private static func headingLevel(in attributedText: NSAttributedString, range: NSRange) -> Int? {
            guard range.length > 0 else { return nil }
            var foundLevel: Int?
            attributedText.enumerateAttribute(
                headingLevelAttributeKey,
                in: range,
                options: [.longestEffectiveRangeNotRequired]
            ) { value, _, stop in
                if let level = headingLevelValue(from: value) {
                    foundLevel = level
                    stop.pointee = true
                }
            }
            return foundLevel
        }

        private static func headingLevelValue(from value: Any?) -> Int? {
            let level: Int?
            if let intValue = value as? Int {
                level = intValue
            } else if let numberValue = value as? NSNumber {
                level = numberValue.intValue
            } else {
                level = nil
            }
            guard let level, (1...6).contains(level) else { return nil }
            return level
        }

        private static func lineContentRange(from lineRange: NSRange, in source: NSString) -> NSRange {
            guard lineRange.length > 0 else { return lineRange }
            let lineEnd = lineRange.location + lineRange.length
            if lineEnd > 0, lineEnd <= source.length, source.character(at: lineEnd - 1) == 10 {
                return NSRange(location: lineRange.location, length: lineRange.length - 1)
            }
            return lineRange
        }

        private static func headingBaseFont(for level: Int) -> NSFont {
            let size = headingPointSize(for: level)
            return NSFont.systemFont(ofSize: size, weight: .regular)
        }

        private static func headingPointSize(for level: Int) -> CGFloat {
            max(13.0, 20.0 - (CGFloat(level - 1) * 1.8))
        }

        private static func parseHeadingShortcut(in line: String) -> HeadingShortcut? {
            let source = line as NSString
            guard source.length > 1 else { return nil }

            var index = 0
            var level = 0
            while index < source.length, source.character(at: index) == 35, level < 6 {
                level += 1
                index += 1
            }

            guard level > 0, index < source.length else { return nil }
            guard let firstWhitespaceScalar = UnicodeScalar(Int(source.character(at: index))),
                  CharacterSet.whitespaces.contains(firstWhitespaceScalar) else {
                return nil
            }

            while index < source.length,
                  let scalar = UnicodeScalar(Int(source.character(at: index))),
                  CharacterSet.whitespaces.contains(scalar) {
                index += 1
            }

            return HeadingShortcut(level: level, markerLength: index)
        }

        private static func markdownFragment(
            for segment: String,
            attributes: [NSAttributedString.Key: Any],
            suppressBoldFromHeading: Bool
        ) -> String {
            guard !segment.isEmpty else { return "" }

            if let link = normalizeLink(attributes[.link]) {
                let text = escapeMarkdownText(segment)
                let destination = link.absoluteString.replacingOccurrences(of: ")", with: "%29")
                return "[\(text)](\(destination))"
            }

            let font = attributes[.font] as? NSFont ?? baseFont
            let traits = font.fontDescriptor.symbolicTraits
            let isBold = traits.contains(.bold) && !suppressBoldFromHeading
            let isItalic = traits.contains(.italic)

            let escaped = escapeMarkdownText(segment)
            guard !segment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return escaped
            }

            if isBold && isItalic {
                return "***\(escaped)***"
            }
            if isBold {
                return "**\(escaped)**"
            }
            if isItalic {
                return "*\(escaped)*"
            }
            return escaped
        }

        private static func escapeMarkdownText(_ text: String) -> String {
            var escaped = ""
            escaped.reserveCapacity(text.count)

            for character in text {
                switch character {
                case "\\", "*", "_", "[", "]", "(", ")":
                    escaped.append("\\")
                    escaped.append(character)
                default:
                    escaped.append(character)
                }
            }
            return escaped
        }

        private static func inlineIntent(from value: Any?) -> InlinePresentationIntent? {
            if let intent = value as? InlinePresentationIntent {
                return intent
            }
            if let number = value as? NSNumber {
                return InlinePresentationIntent(rawValue: number.uintValue)
            }
            return nil
        }

        private static func normalizeLink(_ value: Any?) -> URL? {
            if let url = value as? URL {
                return url
            }
            if let string = value as? String {
                return URL(string: string)
            }
            if let string = value as? NSString {
                return URL(string: string as String)
            }
            return nil
        }
    }
}

private final class CommentMarkdownTextView: NSTextView {
    var commandHandler: ((CommentEditorCommand) -> Void)?
    var submitHandler: (() -> Void)?
    var requestLinkHandler: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if isSubmitKeyEquivalent(event), let submitHandler {
            submitHandler()
            return
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if isSubmitKeyEquivalent(event), let submitHandler {
            submitHandler()
            return true
        }

        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard modifiers == [.command],
              let key = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }

        switch key {
        case "b":
            commandHandler?(.bold)
            return true
        case "i":
            commandHandler?(.italic)
            return true
        case "k":
            requestLinkHandler?()
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    private func isSubmitKeyEquivalent(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard modifiers == [.command] else { return false }
        return event.keyCode == 36 || event.keyCode == 76
    }
}

// MARK: - Tag Submenu Row

/// A single tag row in the submenu
struct TagSubmenuRow: View {
    let tag: Tag
    let isSelected: Bool
    let isKeyboardHighlighted: Bool
    var onHoverChanged: ((Bool) -> Void)? = nil
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Circle()
                    .fill(TagColorStore.color(for: tag))
                    .frame(width: 8, height: 8)
                    .overlay(
                        Circle()
                            .stroke(Color.white.opacity(0.35), lineWidth: 0.5)
                    )

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
                    .fill((isHovering || isKeyboardHighlighted) ? Color.white.opacity(0.1) : Color.clear)
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
            onHoverChanged?(hovering)
        }
    }
}

// MARK: - Filter Panel

/// Floating vertical card panel for timeline filtering
/// Shared UserDefaults store for accessing settings
private let filterPanelSettingsStore = UserDefaults(suiteName: "io.retrace.app") ?? .standard

struct FilterPanel: View {
    @ObservedObject var viewModel: SimpleTimelineViewModel
    @GestureState private var dragOffset: CGSize = .zero
    @State private var panelPosition: CGSize = .zero
    @State private var escapeMonitor: Any?
    @State private var tabKeyMonitor: Any?
    @State private var isCloseHovered = false
    @State private var isClearHovered = false
    @State private var isApplyHovered = false
    @State private var focusedActionButton: ActionButtonFocus?

    private enum ActionButtonFocus: Hashable {
        case clear
        case apply
    }

    /// Filter order for Tab navigation:
    /// Apps(1) → Tags(2) → Visibility(3) → Comments(4) → Date(5) → Advanced(6) → Action buttons → back to Apps
    private let filterOrder: [SimpleTimelineViewModel.FilterDropdownType] = [.apps, .tags, .visibility, .comments, .dateRange, .advanced]

    /// Border color for filter panel
    private var themeBorderColor: Color {
        Color.white.opacity(0.15)
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

    /// Label for comment filter dropdown
    private var commentFilterLabel: String {
        switch viewModel.pendingFilterCriteria.commentFilter {
        case .allFrames:
            return "All Frames"
        case .commentsOnly:
            return "Comments Only"
        case .noComments:
            return "No Comments"
        }
    }

    /// Label for date range filter
    private var dateRangeLabel: String {
        let ranges = viewModel.pendingFilterCriteria.effectiveDateRanges
        if ranges.count > 1 {
            return "\(ranges.count) date ranges"
        }

        let startDate = ranges.first?.start ?? viewModel.pendingFilterCriteria.startDate
        let endDate = ranges.first?.end ?? viewModel.pendingFilterCriteria.endDate
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

    /// Auto-apply mode starts after at least one filter is applied.
    private var isAutoApplyMode: Bool {
        viewModel.filterCriteria.hasActiveFilters
    }

    /// Clear button is visible when pending OR applied filters are active.
    private var hasClearButton: Bool {
        viewModel.pendingFilterCriteria.hasActiveFilters || viewModel.filterCriteria.hasActiveFilters
    }

    /// Apply button is shown only before the first filter is applied.
    private var hasApplyButton: Bool {
        !isAutoApplyMode
    }

    /// First action button in keyboard order.
    private var leadingActionButtonFocus: ActionButtonFocus? {
        if hasClearButton { return .clear }
        if hasApplyButton { return .apply }
        return nil
    }

    /// Last action button in keyboard order.
    private var trailingActionButtonFocus: ActionButtonFocus? {
        if hasApplyButton { return .apply }
        if hasClearButton { return .clear }
        return nil
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
                        .background(
                            Circle()
                                .fill(Color.white.opacity(0.1))
                        )
                        .overlay(
                            Circle()
                                .stroke(
                                    isCloseHovered ? RetraceMenuStyle.filterStrokeStrong : Color.clear,
                                    lineWidth: 1.2
                                )
                        )
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    isCloseHovered = hovering
                }
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

            // Divider
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)
                .padding(.horizontal, 16)

            // Two-column grid plus dedicated date row
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    // Left column: Apps and Visibility
                    VStack(alignment: .leading, spacing: 12) {
                        // Apps
                        CompactAppsFilterDropdown(
                            label: "APPS",
                            selectedApps: viewModel.pendingFilterCriteria.selectedApps,
                            isExcludeMode: viewModel.pendingFilterCriteria.appFilterMode == .exclude,
                            isOpen: viewModel.activeFilterDropdown == .apps,
                            onTap: { frame in
                                withAnimation(.easeOut(duration: 0.15)) {
                                    if viewModel.activeFilterDropdown == .apps {
                                        viewModel.dismissFilterDropdown()
                                    } else {
                                        viewModel.showFilterDropdown(.apps, anchorFrame: frame)
                                    }
                                }
                            },
                            onFrameAvailable: { frame in
                                viewModel.filterAnchorFrames[.apps] = frame
                            }
                        )

                        // Visibility
                        CompactFilterDropdown(
                            label: "VISIBILITY",
                            value: hiddenFilterLabel,
                            icon: "eye",
                            isActive: viewModel.pendingFilterCriteria.hiddenFilter != .hide,
                            isOpen: viewModel.activeFilterDropdown == .visibility,
                            onTap: { frame in
                                withAnimation(.easeOut(duration: 0.15)) {
                                    if viewModel.activeFilterDropdown == .visibility {
                                        viewModel.dismissFilterDropdown()
                                    } else {
                                        viewModel.showFilterDropdown(.visibility, anchorFrame: frame)
                                    }
                                }
                            },
                            onFrameAvailable: { frame in
                                viewModel.filterAnchorFrames[.visibility] = frame
                            }
                        )
                    }
                    .frame(maxWidth: .infinity)

                    // Right column: Tags and Comments
                    VStack(alignment: .leading, spacing: 12) {
                        // Tags
                        CompactFilterDropdown(
                            label: "TAGS",
                            value: tagsLabel,
                            icon: "tag",
                            isActive: viewModel.pendingFilterCriteria.selectedTags != nil && !viewModel.pendingFilterCriteria.selectedTags!.isEmpty,
                            isOpen: viewModel.activeFilterDropdown == .tags,
                            onTap: { frame in
                                withAnimation(.easeOut(duration: 0.15)) {
                                    if viewModel.activeFilterDropdown == .tags {
                                        viewModel.dismissFilterDropdown()
                                    } else {
                                        viewModel.showFilterDropdown(.tags, anchorFrame: frame)
                                    }
                                }
                            },
                            onFrameAvailable: { frame in
                                viewModel.filterAnchorFrames[.tags] = frame
                            }
                        )

                        // Comments
                        CompactFilterDropdown(
                            label: "COMMENTS",
                            value: commentFilterLabel,
                            icon: "text.bubble",
                            isActive: viewModel.pendingFilterCriteria.commentFilter != .allFrames,
                            isOpen: viewModel.activeFilterDropdown == .comments,
                            onTap: { frame in
                                withAnimation(.easeOut(duration: 0.15)) {
                                    if viewModel.activeFilterDropdown == .comments {
                                        viewModel.dismissFilterDropdown()
                                    } else {
                                        viewModel.showFilterDropdown(.comments, anchorFrame: frame)
                                    }
                                }
                            },
                            onFrameAvailable: { frame in
                                viewModel.filterAnchorFrames[.comments] = frame
                            }
                        )
                    }
                    .frame(maxWidth: .infinity)
                }

                // Date row (full width)
                CompactFilterDropdown(
                    label: "DATE",
                    value: dateRangeLabel,
                    icon: "calendar",
                    isActive: !viewModel.pendingFilterCriteria.effectiveDateRanges.isEmpty,
                    isOpen: viewModel.activeFilterDropdown == .dateRange,
                    onTap: { frame in
                        withAnimation(.easeOut(duration: 0.15)) {
                            if viewModel.activeFilterDropdown == .dateRange {
                                viewModel.dismissFilterDropdown()
                            } else {
                                viewModel.showFilterDropdown(.dateRange, anchorFrame: frame)
                            }
                        }
                    },
                    onFrameAvailable: { frame in
                        viewModel.filterAnchorFrames[.dateRange] = frame
                    }
                )
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
                // Clear button
                if hasClearButton {
                    Button(action: {
                        focusedActionButton = nil
                        viewModel.clearPendingFilters()
                        withAnimation(.easeOut(duration: 0.15)) {
                            viewModel.applyFilters(dismissPanel: false)
                        }
                    }) {
                        Text("Clear")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white.opacity(0.7))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(
                                        (focusedActionButton == .clear || isClearHovered)
                                            ? Color.white.opacity(0.16)
                                            : Color.white.opacity(0.1)
                                    )
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(
                                        (focusedActionButton == .clear || isClearHovered)
                                            ? RetraceMenuStyle.filterStrokeStrong
                                            : Color.clear,
                                        lineWidth: 1.4
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        isClearHovered = hovering
                    }
                }

                // Apply button
                if hasApplyButton {
                    Button(action: {
                        focusedActionButton = nil
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
                                    .fill(
                                        (focusedActionButton == .apply || isApplyHovered)
                                            ? RetraceMenuStyle.actionBlue
                                            : RetraceMenuStyle.actionBlue.opacity(0.8)
                                    )
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(
                                        (focusedActionButton == .apply || isApplyHovered)
                                            ? RetraceMenuStyle.filterStrokeStrong
                                            : Color.clear,
                                        lineWidth: 2.25
                                    )
                            )
                            .shadow(
                                color: (focusedActionButton == .apply || isApplyHovered)
                                    ? RetraceMenuStyle.actionBlue.opacity(0.65)
                                    : .clear,
                                radius: 8
                            )
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        isApplyHovered = hovering
                    }
                }
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
                    // While date-range calendar is open, Escape should dismiss the date dropdown.
                    if viewModel.activeFilterDropdown == .dateRange && viewModel.isDateRangeCalendarEditing {
                        withAnimation(.easeOut(duration: 0.15)) {
                            viewModel.dismissFilterDropdown()
                        }
                        return nil // Consume the event
                    }

                    // Close any open dropdown
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

            // Set up keyboard monitor for cycling through filters
            tabKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                // Let comment submenu own keyboard navigation while it's open.
                if viewModel.showCommentSubmenu {
                    return event
                }

                let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])

                // Cmd+Enter applies filters from anywhere in the filter panel.
                if (event.keyCode == 36 || event.keyCode == 76) && modifiers == [.command] {
                    focusedActionButton = nil
                    withAnimation(.easeOut(duration: 0.15)) {
                        viewModel.applyFilters(dismissPanel: hasApplyButton)
                    }
                    return nil
                }

                // Handle Enter on Advanced highlight (expand and focus Window Name)
                if (event.keyCode == 36 || event.keyCode == 76) &&
                    viewModel.activeFilterDropdown == .advanced &&
                    viewModel.advancedFocusedFieldIndex == 0 {
                    // Enter on highlighted Advanced header → signal expand
                    viewModel.advancedFocusedFieldIndex = -1  // Signal to expand
                    return nil
                }

                // Handle Enter while action buttons are keyboard-highlighted.
                if (event.keyCode == 36 || event.keyCode == 76), let focusedButton = focusedActionButton {
                    if focusedButton == .clear {
                        focusedActionButton = nil
                        viewModel.clearPendingFilters()
                        withAnimation(.easeOut(duration: 0.15)) {
                            viewModel.applyFilters(dismissPanel: false)
                        }
                    } else {
                        focusedActionButton = nil
                        withAnimation(.easeOut(duration: 0.15)) {
                            viewModel.applyFilters()
                        }
                    }
                    return nil
                }

                // Left/Right arrows navigate between filter fields while panel is open.
                // Keep native caret movement when an advanced text field is focused.
                if modifiers.isEmpty && (event.keyCode == 123 || event.keyCode == 124) {
                    let isAdvancedTextFieldFocused =
                        viewModel.activeFilterDropdown == .advanced &&
                        (viewModel.advancedFocusedFieldIndex == 1 || viewModel.advancedFocusedFieldIndex == 2)
                    if isAdvancedTextFieldFocused {
                        return event
                    }

                    // Date-range calendar uses arrow keys for day navigation.
                    if viewModel.activeFilterDropdown == .dateRange && viewModel.isDateRangeCalendarEditing {
                        return event
                    }

                    // If action buttons are focused, Left/Right toggles within those buttons.
                    if focusedActionButton != nil {
                        if hasClearButton && hasApplyButton {
                            focusedActionButton = event.keyCode == 123 ? .clear : .apply
                        } else if hasClearButton {
                            focusedActionButton = .clear
                        } else if hasApplyButton {
                            focusedActionButton = .apply
                        } else {
                            focusedActionButton = nil
                        }
                        return nil
                    }

                    let moveBackward = event.keyCode == 123
                    let currentDropdown = viewModel.activeFilterDropdown
                    let nextDropdown: SimpleTimelineViewModel.FilterDropdownType

                    if currentDropdown == .none {
                        nextDropdown = moveBackward ? filterOrder[filterOrder.count - 1] : filterOrder[0]
                    } else {
                        guard let currentIndex = filterOrder.firstIndex(of: currentDropdown) else { return event }
                        let delta = moveBackward ? -1 : 1
                        let nextIndex = (currentIndex + delta + filterOrder.count) % filterOrder.count
                        nextDropdown = filterOrder[nextIndex]
                    }

                    if nextDropdown == .advanced {
                        // Keep keyboard highlight on Advanced header when entering via arrows.
                        viewModel.advancedFocusedFieldIndex = 0
                    }

                    let nextAnchorFrame = viewModel.filterAnchorFrames[nextDropdown] ?? .zero
                    withAnimation(.easeOut(duration: 0.15)) {
                        viewModel.showFilterDropdown(nextDropdown, anchorFrame: nextAnchorFrame)
                    }
                    return nil
                }

                // Up/Down arrows switch between Advanced text fields.
                // Window Name (1) <-> Browser URL (2)
                if modifiers.isEmpty && (event.keyCode == 125 || event.keyCode == 126) {
                    if focusedActionButton != nil,
                       event.keyCode == 126,
                       viewModel.activeFilterDropdown == .advanced {
                        // Up from action buttons returns to Browser URL.
                        focusedActionButton = nil
                        viewModel.advancedFocusedFieldIndex = 2
                        return nil
                    }

                    let fieldIndex = viewModel.advancedFocusedFieldIndex
                    if event.keyCode == 125, fieldIndex == 1 { // Down from Window Name
                        viewModel.advancedFocusedFieldIndex = 2
                        return nil
                    }
                    if event.keyCode == 125, fieldIndex == 2 { // Down from Browser URL -> Apply
                        viewModel.advancedFocusedFieldIndex = -4
                        focusedActionButton = hasApplyButton ? .apply : .clear
                        return nil
                    }
                    if event.keyCode == 126, fieldIndex == 2 { // Up from Browser URL
                        viewModel.advancedFocusedFieldIndex = 1
                        return nil
                    }
                    if event.keyCode == 126, fieldIndex == 1 { // Up from Window Name -> Date
                        focusedActionButton = nil
                        viewModel.advancedFocusedFieldIndex = 0
                        let nextAnchorFrame = viewModel.filterAnchorFrames[.dateRange] ?? .zero
                        withAnimation(.easeOut(duration: 0.15)) {
                            viewModel.showFilterDropdown(.dateRange, anchorFrame: nextAnchorFrame)
                        }
                        return nil
                    }
                }

                // Only handle Tab key (keycode 48)
                guard event.keyCode == 48 else { return event }

                // Check if Shift is held for reverse direction
                let isShiftHeld = modifiers.contains(.shift)

                // Handle Tab while action buttons are focused
                if let focusedButton = focusedActionButton {
                    if isShiftHeld {
                        if focusedButton == .apply && hasClearButton {
                            focusedActionButton = .clear
                            return nil
                        }
                        // Shift+Tab from Clear (or Apply when Clear is hidden) -> Browser URL field
                        // (Advanced section will focus Browser URL on this sentinel value).
                        focusedActionButton = nil
                        if viewModel.activeFilterDropdown == .advanced {
                            viewModel.advancedFocusedFieldIndex = -2
                            return nil
                        }
                    } else {
                        if focusedButton == .clear {
                            if hasApplyButton {
                                focusedActionButton = .apply
                                return nil
                            }
                            // Tab on Clear (only action button) -> cycle to Apps dropdown
                            focusedActionButton = nil
                            viewModel.advancedFocusedFieldIndex = 0
                            let nextAnchorFrame = viewModel.filterAnchorFrames[.apps] ?? .zero
                            withAnimation(.easeOut(duration: 0.15)) {
                                viewModel.showFilterDropdown(.apps, anchorFrame: nextAnchorFrame)
                            }
                            return nil
                        }
                        // Tab on Apply -> cycle to Apps dropdown
                        focusedActionButton = nil
                        viewModel.advancedFocusedFieldIndex = 0
                        let nextAnchorFrame = viewModel.filterAnchorFrames[.apps] ?? .zero
                        withAnimation(.easeOut(duration: 0.15)) {
                            viewModel.showFilterDropdown(.apps, anchorFrame: nextAnchorFrame)
                        }
                        return nil
                    }
                }

                // Handle Tab within advanced fields (Window Name / Browser URL)
                if viewModel.activeFilterDropdown == .advanced {
                    let fieldIndex = viewModel.advancedFocusedFieldIndex
                    if fieldIndex == 0 {
                        // Advanced header is highlighted: Tab goes to action buttons first.
                        if !isShiftHeld {
                            viewModel.advancedFocusedFieldIndex = -4
                            focusedActionButton = leadingActionButtonFocus
                            return nil
                        }
                    } else if !isShiftHeld && fieldIndex == 1 {
                        // Tab on Window Name → let SwiftUI move focus to Browser URL
                        return event
                    } else if !isShiftHeld && fieldIndex == 2 {
                        // Tab on Browser URL -> action buttons first (Clear, then Apply).
                        viewModel.advancedFocusedFieldIndex = -4
                        focusedActionButton = leadingActionButtonFocus
                        return nil
                    } else if isShiftHeld && fieldIndex == 2 {
                        // Shift+Tab on Browser URL -> explicitly focus Window Name.
                        viewModel.advancedFocusedFieldIndex = -3
                        return nil
                    } else if isShiftHeld && fieldIndex == 1 {
                        // Shift+Tab on Window Name → cycle to Date Range
                        let nextAnchorFrame = viewModel.filterAnchorFrames[.dateRange] ?? .zero
                        withAnimation(.easeOut(duration: 0.15)) {
                            viewModel.showFilterDropdown(.dateRange, anchorFrame: nextAnchorFrame)
                        }
                        return nil
                    }
                }

                // Shift+Tab on Apps dropdown should go to Submit (Apply button), not Advanced.
                if isShiftHeld && viewModel.activeFilterDropdown == .apps {
                    withAnimation(.easeOut(duration: 0.15)) {
                        viewModel.dismissFilterDropdown()
                    }
                    focusedActionButton = trailingActionButtonFocus
                    return nil
                }

                // Determine current and next dropdown
                let nextDropdown: SimpleTimelineViewModel.FilterDropdownType
                let nextIndex: Int

                if viewModel.activeFilterDropdown == .none {
                    // No dropdown open - start with first (Tab) or last (Shift+Tab)
                    nextIndex = isShiftHeld ? filterOrder.count - 1 : 0
                    nextDropdown = filterOrder[nextIndex]
                } else {
                    // Find current index and cycle forward or backward
                    let currentDropdown = viewModel.activeFilterDropdown
                    guard let currentIndex = filterOrder.firstIndex(of: currentDropdown) else { return event }
                    if isShiftHeld {
                        // Shift+Tab: go backward (wrap to end if at start)
                        nextIndex = (currentIndex - 1 + filterOrder.count) % filterOrder.count
                    } else {
                        // Tab: go forward (wrap to start if at end)
                        nextIndex = (currentIndex + 1) % filterOrder.count
                    }
                    nextDropdown = filterOrder[nextIndex]
                }

                // Get the anchor frame for the next dropdown (use stored frame if available)
                // If no frame is stored, the dropdown won't position correctly, but will still open
                let nextAnchorFrame = viewModel.filterAnchorFrames[nextDropdown] ?? .zero

                // Open the next dropdown at its correct position
                withAnimation(.easeOut(duration: 0.15)) {
                    viewModel.showFilterDropdown(nextDropdown, anchorFrame: nextAnchorFrame)
                }

                return nil // Consume the event
            }
        }
        .onChange(of: viewModel.pendingFilterCriteria) { newCriteria in
            // Once filters are active, additional panel changes apply immediately.
            guard isAutoApplyMode else { return }
            guard newCriteria != viewModel.filterCriteria else { return }
            focusedActionButton = nil
            withAnimation(.easeOut(duration: 0.15)) {
                viewModel.applyFilters(dismissPanel: false)
            }
        }
        .onChange(of: viewModel.pendingFilterCriteria.hasActiveFilters) { _ in
            if focusedActionButton == .clear && !hasClearButton {
                focusedActionButton = hasApplyButton ? .apply : nil
            } else if focusedActionButton == .apply && !hasApplyButton {
                focusedActionButton = hasClearButton ? .clear : nil
            }
        }
        .onChange(of: viewModel.filterCriteria.hasActiveFilters) { _ in
            if focusedActionButton == .apply && !hasApplyButton {
                focusedActionButton = hasClearButton ? .clear : nil
            } else if focusedActionButton == .clear && !hasClearButton {
                focusedActionButton = hasApplyButton ? .apply : nil
            }
        }
        .onDisappear {
            // Clean up escape key monitor
            if let monitor = escapeMonitor {
                NSEvent.removeMonitor(monitor)
                escapeMonitor = nil
            }
            // Clean up tab key monitor
            if let monitor = tabKeyMonitor {
                NSEvent.removeMonitor(monitor)
                tabKeyMonitor = nil
            }
            focusedActionButton = nil
        }
    }
}

// MARK: - Advanced Filters Section

/// Collapsible section for advanced text filters (Window Name and Browser URL)
struct AdvancedFiltersSection: View {
    @ObservedObject var viewModel: SimpleTimelineViewModel
    @State private var isExpanded: Bool = false
    @State private var isHeaderHovered = false
    @State private var isWindowHovered = false
    @State private var isBrowserHovered = false
    @State private var windowInputText = ""
    @State private var browserInputText = ""
    @State private var windowNameIncludeTerms: [String] = []
    @State private var windowNameExcludeTerms: [String] = []
    @State private var windowNameFilterMode: AppFilterMode = .include
    @State private var browserUrlIncludeTerms: [String] = []
    @State private var browserUrlExcludeTerms: [String] = []
    @State private var browserUrlFilterMode: AppFilterMode = .include

    private enum AdvancedField: Hashable {
        case windowName
        case browserUrl
    }
    @FocusState private var focusedField: AdvancedField?

    private static let metadataFilterPrefix = "__retrace_meta_filter_v1__"

    private struct EncodedMetadataFilterPayload: Codable {
        let includeTerms: [String]?
        let excludeTerms: [String]?
        // Legacy fields for backward compatibility.
        let mode: AppFilterMode?
        let terms: [String]?
    }

    private struct DecodedMetadataFilter: Equatable {
        let includeTerms: [String]
        let excludeTerms: [String]
        let mode: AppFilterMode

        static let empty = DecodedMetadataFilter(includeTerms: [], excludeTerms: [], mode: .include)

        var hasActiveFilters: Bool {
            !includeTerms.isEmpty || !excludeTerms.isEmpty
        }
    }

    private struct MetadataChipTerm: Identifiable {
        let term: String
        let mode: AppFilterMode
        var id: String { "\(mode.rawValue):\(term.lowercased())" }
    }

    /// Whether any advanced filter is active
    private var hasActiveAdvancedFilters: Bool {
        viewModel.pendingFilterCriteria.hasAdvancedFilters
    }

    /// Whether the advanced dropdown is active (for highlight)
    private var isAdvancedActive: Bool {
        viewModel.activeFilterDropdown == .advanced
    }

    /// Keyboard highlight when tab focus is on the Advanced header row.
    private var isHeaderKeyboardHighlighted: Bool {
        isAdvancedActive && viewModel.advancedFocusedFieldIndex == 0
    }

    private func addWindowNameTermFromInput() {
        let candidate = windowInputText
        windowInputText = ""
        guard let normalized = Self.normalizedTerm(candidate) else { return }
        if windowNameFilterMode == .include {
            windowNameIncludeTerms = Self.deduplicatedTerms(windowNameIncludeTerms + [normalized])
            windowNameExcludeTerms.removeAll { $0.caseInsensitiveCompare(normalized) == .orderedSame }
        } else {
            windowNameExcludeTerms = Self.deduplicatedTerms(windowNameExcludeTerms + [normalized])
            windowNameIncludeTerms.removeAll { $0.caseInsensitiveCompare(normalized) == .orderedSame }
        }
    }

    private func addBrowserUrlTermFromInput() {
        let candidate = browserInputText
        browserInputText = ""
        guard let normalized = Self.normalizedTerm(candidate) else { return }
        if browserUrlFilterMode == .include {
            browserUrlIncludeTerms = Self.deduplicatedTerms(browserUrlIncludeTerms + [normalized])
            browserUrlExcludeTerms.removeAll { $0.caseInsensitiveCompare(normalized) == .orderedSame }
        } else {
            browserUrlExcludeTerms = Self.deduplicatedTerms(browserUrlExcludeTerms + [normalized])
            browserUrlIncludeTerms.removeAll { $0.caseInsensitiveCompare(normalized) == .orderedSame }
        }
    }

    private func removeWindowNameTerm(_ term: String, mode: AppFilterMode) {
        let needle = term.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return }
        if mode == .include {
            windowNameIncludeTerms.removeAll { existing in
                existing.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == needle
            }
        } else {
            windowNameExcludeTerms.removeAll { existing in
                existing.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == needle
            }
        }
    }

    private func removeBrowserUrlTerm(_ term: String, mode: AppFilterMode) {
        let needle = term.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return }
        if mode == .include {
            browserUrlIncludeTerms.removeAll { existing in
                existing.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == needle
            }
        } else {
            browserUrlExcludeTerms.removeAll { existing in
                existing.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == needle
            }
        }
    }

    private var windowNameChips: [MetadataChipTerm] {
        Self.deduplicatedTerms(windowNameIncludeTerms).map { MetadataChipTerm(term: $0, mode: .include) } +
        Self.deduplicatedTerms(windowNameExcludeTerms).map { MetadataChipTerm(term: $0, mode: .exclude) }
    }

    private var browserUrlChips: [MetadataChipTerm] {
        Self.deduplicatedTerms(browserUrlIncludeTerms).map { MetadataChipTerm(term: $0, mode: .include) } +
        Self.deduplicatedTerms(browserUrlExcludeTerms).map { MetadataChipTerm(term: $0, mode: .exclude) }
    }

    private func syncStateFromPendingFilters() {
        let decodedWindowFilter = Self.decodeMetadataFilter(viewModel.pendingFilterCriteria.windowNameFilter)
        if windowNameIncludeTerms != decodedWindowFilter.includeTerms {
            windowNameIncludeTerms = decodedWindowFilter.includeTerms
        }
        if windowNameExcludeTerms != decodedWindowFilter.excludeTerms {
            windowNameExcludeTerms = decodedWindowFilter.excludeTerms
        }
        if windowNameFilterMode != decodedWindowFilter.mode {
            windowNameFilterMode = decodedWindowFilter.mode
        }

        let decodedBrowserFilter = Self.decodeMetadataFilter(viewModel.pendingFilterCriteria.browserUrlFilter)
        if browserUrlIncludeTerms != decodedBrowserFilter.includeTerms {
            browserUrlIncludeTerms = decodedBrowserFilter.includeTerms
        }
        if browserUrlExcludeTerms != decodedBrowserFilter.excludeTerms {
            browserUrlExcludeTerms = decodedBrowserFilter.excludeTerms
        }
        if browserUrlFilterMode != decodedBrowserFilter.mode {
            browserUrlFilterMode = decodedBrowserFilter.mode
        }
    }

    private func updatePendingWindowFilter() {
        let encoded = Self.encodedMetadataFilter(includeTerms: windowNameIncludeTerms, excludeTerms: windowNameExcludeTerms)
        if viewModel.pendingFilterCriteria.windowNameFilter != encoded {
            viewModel.pendingFilterCriteria.windowNameFilter = encoded
        }
    }

    private func updatePendingBrowserFilter() {
        let encoded = Self.encodedMetadataFilter(includeTerms: browserUrlIncludeTerms, excludeTerms: browserUrlExcludeTerms)
        if viewModel.pendingFilterCriteria.browserUrlFilter != encoded {
            viewModel.pendingFilterCriteria.browserUrlFilter = encoded
        }
    }

    private static func encodedMetadataFilter(includeTerms: [String], excludeTerms: [String]) -> String? {
        let normalizedIncludeTerms = deduplicatedTerms(includeTerms)
        let includeKeys = Set(normalizedIncludeTerms.map { $0.lowercased() })
        let normalizedExcludeTerms = deduplicatedTerms(excludeTerms).filter { !includeKeys.contains($0.lowercased()) }
        guard !normalizedIncludeTerms.isEmpty || !normalizedExcludeTerms.isEmpty else { return nil }

        let payload = EncodedMetadataFilterPayload(
            includeTerms: normalizedIncludeTerms,
            excludeTerms: normalizedExcludeTerms,
            mode: nil,
            terms: nil
        )
        guard let data = try? JSONEncoder().encode(payload) else { return nil }
        return metadataFilterPrefix + data.base64EncodedString()
    }

    private static func decodeMetadataFilter(_ rawValue: String?) -> DecodedMetadataFilter {
        guard let rawValue else { return .empty }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }

        guard trimmed.hasPrefix(metadataFilterPrefix) else {
            let normalizedTerms = deduplicatedTerms([trimmed])
            return DecodedMetadataFilter(includeTerms: normalizedTerms, excludeTerms: [], mode: .include)
        }

        let encodedPayload = String(trimmed.dropFirst(metadataFilterPrefix.count))
        guard let data = Data(base64Encoded: encodedPayload),
              let payload = try? JSONDecoder().decode(EncodedMetadataFilterPayload.self, from: data) else {
            return .empty
        }

        let normalizedIncludeTerms = deduplicatedTerms(payload.includeTerms ?? [])
        let includeKeys = Set(normalizedIncludeTerms.map { $0.lowercased() })
        let normalizedExcludeTerms = deduplicatedTerms(payload.excludeTerms ?? []).filter { !includeKeys.contains($0.lowercased()) }
        if !normalizedIncludeTerms.isEmpty || !normalizedExcludeTerms.isEmpty {
            let preferredMode: AppFilterMode = normalizedIncludeTerms.isEmpty && !normalizedExcludeTerms.isEmpty ? .exclude : .include
            return DecodedMetadataFilter(
                includeTerms: normalizedIncludeTerms,
                excludeTerms: normalizedExcludeTerms,
                mode: preferredMode
            )
        }

        let normalizedLegacyTerms = deduplicatedTerms(payload.terms ?? [])
        if payload.mode == .exclude {
            return DecodedMetadataFilter(includeTerms: [], excludeTerms: normalizedLegacyTerms, mode: .exclude)
        }
        return DecodedMetadataFilter(includeTerms: normalizedLegacyTerms, excludeTerms: [], mode: .include)
    }

    private static func deduplicatedTerms(_ terms: [String]) -> [String] {
        var seen = Set<String>()
        var normalizedTerms: [String] = []

        for term in terms {
            guard let normalized = normalizedTerm(term) else { continue }
            let key = normalized.lowercased()
            if seen.insert(key).inserted {
                normalizedTerms.append(normalized)
            }
        }

        return normalizedTerms
    }

    private static func normalizedTerm(_ term: String) -> String? {
        let collapsed = term
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.isEmpty ? nil : collapsed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Toggle header
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
                if isExpanded {
                    // Focus window name field when manually expanding
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        focusedField = .windowName
                    }
                }
            }) {
                HStack {
                    Text("ADVANCED")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(isAdvancedActive ? .white.opacity(0.8) : .white.opacity(0.4))
                        .tracking(0.5)

                    if hasActiveAdvancedFilters {
                        Circle()
                            .fill(RetraceMenuStyle.actionBlue)
                            .frame(width: 6, height: 6)
                    }

                    Spacer()

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(isAdvancedActive ? .white.opacity(0.6) : .white.opacity(0.4))
                }
                .padding(.horizontal, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, isExpanded ? 8 : 12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isAdvancedActive && !isExpanded ? Color.white.opacity(0.08) : Color.clear)
                    .padding(.horizontal, 16)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(
                        (isHeaderHovered || isHeaderKeyboardHighlighted)
                            ? RetraceMenuStyle.filterStrokeStrong
                            : Color.clear,
                        lineWidth: 1.2
                    )
                    .padding(.horizontal, 16)
            )
            .onHover { hovering in
                isHeaderHovered = hovering
                if hovering { NSCursor.pointingHand.push() }
                else { NSCursor.pop() }
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 12) {
                    // Window Name filter
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Window Name")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white.opacity(0.6))

                        HStack(spacing: 10) {
                            TextField("Search titles...", text: $windowInputText)
                                .focused($focusedField, equals: .windowName)
                                .textFieldStyle(.plain)
                                .font(.system(size: 13))
                                .foregroundColor(.white)
                                .onSubmit {
                                    addWindowNameTermFromInput()
                                }

                            IncludeExcludeModeToggle(mode: $windowNameFilterMode)
                                .frame(width: 138)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.white.opacity(0.08))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(
                                    focusedField == .windowName
                                        ? RetraceMenuStyle.filterStrokeStrong
                                        : (!windowNameChips.isEmpty
                                            ? RetraceMenuStyle.filterStrokeMedium
                                            : (isWindowHovered ? Color.white.opacity(0.65) : RetraceMenuStyle.filterStrokeSubtle)),
                                    lineWidth: 1
                                )
                        )
                        .onHover { hovering in
                            isWindowHovered = hovering
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            focusedField = .windowName
                        }

                        if !windowNameChips.isEmpty {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(windowNameChips) { chip in
                                        TimelineMetadataTermChip(term: chip.term, mode: chip.mode) {
                                            removeWindowNameTerm(chip.term, mode: chip.mode)
                                        }
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }

                    // Browser URL filter
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Browser URL")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white.opacity(0.6))

                        HStack(spacing: 10) {
                            TextField("Search URLs...", text: $browserInputText)
                                .focused($focusedField, equals: .browserUrl)
                                .textFieldStyle(.plain)
                                .font(.system(size: 13))
                                .foregroundColor(.white)
                                .onSubmit {
                                    addBrowserUrlTermFromInput()
                                }

                            IncludeExcludeModeToggle(mode: $browserUrlFilterMode)
                                .frame(width: 138)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.white.opacity(0.08))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(
                                    focusedField == .browserUrl
                                        ? RetraceMenuStyle.filterStrokeStrong
                                        : (!browserUrlChips.isEmpty
                                            ? RetraceMenuStyle.filterStrokeMedium
                                            : (isBrowserHovered ? Color.white.opacity(0.65) : RetraceMenuStyle.filterStrokeSubtle)),
                                    lineWidth: 1
                                )
                        )
                        .onHover { hovering in
                            isBrowserHovered = hovering
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            focusedField = .browserUrl
                        }

                        if !browserUrlChips.isEmpty {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(browserUrlChips) { chip in
                                        TimelineMetadataTermChip(term: chip.term, mode: chip.mode) {
                                            removeBrowserUrlTerm(chip.term, mode: chip.mode)
                                        }
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
            }
        }
        .onAppear {
            syncStateFromPendingFilters()
            // Auto-expand if there are active advanced filters
            if hasActiveAdvancedFilters {
                isExpanded = true
            }
        }
        .onChange(of: windowNameIncludeTerms) { _ in
            updatePendingWindowFilter()
        }
        .onChange(of: windowNameExcludeTerms) { _ in
            updatePendingWindowFilter()
        }
        .onChange(of: browserUrlIncludeTerms) { _ in
            updatePendingBrowserFilter()
        }
        .onChange(of: browserUrlExcludeTerms) { _ in
            updatePendingBrowserFilter()
        }
        .onChange(of: viewModel.pendingFilterCriteria.windowNameFilter) { _ in
            syncStateFromPendingFilters()
        }
        .onChange(of: viewModel.pendingFilterCriteria.browserUrlFilter) { _ in
            syncStateFromPendingFilters()
        }
        .onChange(of: viewModel.activeFilterDropdown) { newValue in
            if newValue != .advanced {
                // Leaving advanced: collapse section and unfocus fields
                focusedField = nil
                if newValue != .none {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isExpanded = false
                    }
                }
            }
        }
        .onChange(of: viewModel.advancedFocusedFieldIndex) { newValue in
            if newValue == 1 {
                focusedField = .windowName
            } else if newValue == 2 {
                focusedField = .browserUrl
            } else if newValue == -1 && viewModel.activeFilterDropdown == .advanced {
                // Enter was pressed on the Advanced header — expand and focus Window Name
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded = true
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    focusedField = .windowName
                }
            } else if (newValue == 0 || newValue == -4) && viewModel.activeFilterDropdown == .advanced {
                // Advanced header (0) or action-button sentinel (-4): clear text-field focus/caret.
                focusedField = nil
            } else if newValue == -2 && viewModel.activeFilterDropdown == .advanced {
                // Shift+Tab from filter action buttons -> focus Browser URL.
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded = true
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    focusedField = .browserUrl
                }
            } else if newValue == -3 && viewModel.activeFilterDropdown == .advanced {
                // Shift+Tab from Browser URL -> focus Window Name.
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded = true
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    focusedField = .windowName
                }
            }
        }
        .onChange(of: focusedField) { newValue in
            // Sync focus state to viewModel for tab monitor
            switch newValue {
            case .windowName: viewModel.advancedFocusedFieldIndex = 1
            case .browserUrl: viewModel.advancedFocusedFieldIndex = 2
            case nil:
                // Preserve the "action buttons focused" sentinel so the Advanced header
                // does not also appear keyboard-highlighted.
                if viewModel.advancedFocusedFieldIndex != -4 {
                    viewModel.advancedFocusedFieldIndex = 0
                }
            }
        }
    }
}

private struct TimelineMetadataTermChip: View {
    let term: String
    let mode: AppFilterMode
    let onRemove: () -> Void

    @State private var isHovered = false

    private var iconName: String {
        mode == .include ? "plus.circle.fill" : "minus.circle.fill"
    }

    private var iconTint: Color {
        mode == .include ? .blue.opacity(0.88) : .orange.opacity(0.9)
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: iconName)
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(iconTint)

            Text(term)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white)
                .lineLimit(1)

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white.opacity(0.7))
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(Color.white.opacity(isHovered ? 0.2 : 0.14))
        )
        .overlay(
            Capsule()
                .stroke(Color.white.opacity(isHovered ? 0.35 : 0.2), lineWidth: 0.8)
        )
        .onHover { hovering in
            isHovered = hovering
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
    let isOpen: Bool
    let onTap: (CGRect) -> Void
    var onFrameAvailable: ((CGRect) -> Void)? = nil

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
                            .fill(isActive ? Color.white.opacity(0.15) : ((isHovered || isOpen) ? Color.white.opacity(0.12) : Color.white.opacity(0.08)))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(
                                (isHovered || isOpen)
                                    ? RetraceMenuStyle.filterStrokeStrong
                                    : (isActive ? RetraceMenuStyle.filterStrokeMedium : RetraceMenuStyle.filterStrokeSubtle),
                                lineWidth: (isHovered || isOpen) ? 1.2 : 1
                            )
                    )
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    withAnimation(.easeInOut(duration: 0.1)) {
                        isHovered = hovering
                    }
                }
                .onAppear {
                    // Delay slightly to ensure geometry is calculated
                    DispatchQueue.main.async {
                        onFrameAvailable?(localFrame)
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
    let isOpen: Bool
    let onTap: (CGRect) -> Void
    var onFrameAvailable: ((CGRect) -> Void)? = nil

    @StateObject private var appMetadata = AppMetadataCache.shared
    @State private var isHovered = false

    private let maxVisibleIcons = 5
    private let iconSize: CGFloat = 13

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
                                .font(.system(size: 10))
                                .frame(width: iconSize, height: iconSize)
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
                                .frame(width: iconSize, height: iconSize)
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
                    .frame(height: iconSize)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(isActive ? Color.white.opacity(0.15) : ((isHovered || isOpen) ? Color.white.opacity(0.12) : Color.white.opacity(0.08)))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(
                                (isHovered || isOpen)
                                    ? RetraceMenuStyle.filterStrokeStrong
                                    : (isActive ? RetraceMenuStyle.filterStrokeMedium : RetraceMenuStyle.filterStrokeSubtle),
                                lineWidth: (isHovered || isOpen) ? 1.2 : 1
                            )
                    )
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    withAnimation(.easeInOut(duration: 0.1)) {
                        isHovered = hovering
                    }
                }
                .onAppear {
                    // Delay slightly to ensure geometry is calculated
                    DispatchQueue.main.async {
                        onFrameAvailable?(localFrame)
                    }
                }
            }
            .frame(height: 38)
        }
        .onAppear {
            appMetadata.prefetch(bundleIDs: sortedApps)
        }
        .onChange(of: sortedApps) { bundleIDs in
            appMetadata.prefetch(bundleIDs: bundleIDs)
        }
    }

    private func appIcon(for bundleID: String) -> some View {
        AppIconView(bundleID: bundleID, size: iconSize)
    }

    private func appName(for bundleID: String) -> String {
        appMetadata.name(for: bundleID) ?? fallbackName(for: bundleID)
    }

    private func fallbackName(for bundleID: String) -> String {
        bundleID.components(separatedBy: ".").last ?? bundleID
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
                    .stroke(
                        isHovered
                            ? RetraceMenuStyle.filterStrokeStrong
                            : (isSelected ? RetraceMenuStyle.filterStrokeMedium : RetraceMenuStyle.filterStrokeSubtle),
                        lineWidth: isHovered ? 1.2 : 1
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

// MARK: - Filter Dropdown Overlay

/// Renders filter dropdowns at the top level of SimpleTimelineView to avoid clipping issues
/// The dropdowns are positioned absolutely based on the anchor frame from the ViewModel
/// Using the "timelineContent" coordinate space for proper alignment
private struct FilterDropdownSizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero

    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

struct FilterDropdownOverlay: View {
    @ObservedObject var viewModel: SimpleTimelineViewModel
    @State private var measuredDropdownSize: CGSize = .zero

    var body: some View {
        GeometryReader { proxy in
            Group {
                if viewModel.activeFilterDropdown != .none && viewModel.activeFilterDropdown != .advanced {
                    let anchor = viewModel.filterDropdownAnchorFrame
                    let fallbackSize = estimatedDropdownSize(for: viewModel.activeFilterDropdown)
                    let dropdownSize = resolvedDropdownSize(fallback: fallbackSize)
                    let origin = dropdownOrigin(containerSize: proxy.size, anchor: anchor, dropdownSize: dropdownSize)

                    ZStack(alignment: .topLeading) {
                        // Full-screen dismiss layer (below dropdown)
                        Color.black.opacity(0.001)
                            .ignoresSafeArea()
                            .contentShape(Rectangle())
                            .onTapGesture {
                                withAnimation(.easeOut(duration: 0.15)) {
                                    viewModel.dismissFilterDropdown()
                                }
                            }

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
                            .background(
                                GeometryReader { geo in
                                    Color.clear
                                        .preference(key: FilterDropdownSizePreferenceKey.self, value: geo.size)
                                }
                            )
                            .offset(x: origin.x, y: origin.y)
                    }
                    .onPreferenceChange(FilterDropdownSizePreferenceKey.self) { size in
                        guard size.width > 0, size.height > 0 else { return }
                        let normalizedSize = normalizedDropdownSize(size)
                        guard shouldUpdateMeasuredDropdownSize(to: normalizedSize) else { return }
                        measuredDropdownSize = normalizedSize
                    }
                    .transition(.opacity)
                    .zIndex(2000)
                }
            }
        }
        .animation(.easeOut(duration: 0.15), value: viewModel.activeFilterDropdown)
        .animation(.easeOut(duration: 0.15), value: viewModel.isDateRangeCalendarEditing)
        .onChange(of: viewModel.activeFilterDropdown) { _ in
            if measuredDropdownSize != .zero {
                measuredDropdownSize = .zero
            }
        }
        .onChange(of: viewModel.isDateRangeCalendarEditing) { _ in
            if viewModel.activeFilterDropdown == .dateRange, measuredDropdownSize != .zero {
                measuredDropdownSize = .zero
            }
        }
    }

    private func normalizedDropdownSize(_ size: CGSize) -> CGSize {
        // Round to half-points so tiny float jitter does not churn layout.
        let width = (size.width * 2).rounded() / 2
        let height = (size.height * 2).rounded() / 2
        return CGSize(width: width, height: height)
    }

    private func shouldUpdateMeasuredDropdownSize(to newSize: CGSize) -> Bool {
        let epsilon: CGFloat = 0.5
        return
            abs(measuredDropdownSize.width - newSize.width) > epsilon ||
            abs(measuredDropdownSize.height - newSize.height) > epsilon ||
            measuredDropdownSize == .zero
    }

    private func resolvedDropdownSize(fallback: CGSize) -> CGSize {
        if measuredDropdownSize.width > 0, measuredDropdownSize.height > 0 {
            return measuredDropdownSize
        }
        return fallback
    }

    private func estimatedDropdownSize(for type: SimpleTimelineViewModel.FilterDropdownType) -> CGSize {
        switch type {
        case .apps:
            return CGSize(width: 220, height: 320)
        case .tags:
            return CGSize(width: 220, height: 320)
        case .visibility:
            return CGSize(width: 240, height: 180)
        case .comments:
            return CGSize(width: 240, height: 160)
        case .dateRange:
            let height: CGFloat = viewModel.isDateRangeCalendarEditing ? 430 : 250
            return CGSize(width: 300, height: height)
        case .advanced, .none:
            return CGSize(width: 260, height: 200)
        }
    }

    private func dropdownOrigin(containerSize: CGSize, anchor: CGRect, dropdownSize: CGSize) -> CGPoint {
        // Keep the date popover's bottom edge stable while the inline calendar expands/collapses.
        // This prevents visual jumping when height changes.
        if viewModel.activeFilterDropdown == .dateRange, viewModel.isDateRangeCalendarEditing {
            let collapsedHeight: CGFloat = 250
            let collapsedSize = CGSize(width: dropdownSize.width, height: collapsedHeight)
            let baseOrigin = defaultDropdownOrigin(containerSize: containerSize, anchor: anchor, dropdownSize: collapsedSize)
            let baseBottomY = baseOrigin.y + collapsedHeight

            let margin: CGFloat = 8
            let maxY = max(margin, containerSize.height - dropdownSize.height - margin)
            let anchoredY = baseBottomY - dropdownSize.height
            let clampedY = min(max(anchoredY, margin), maxY)

            return CGPoint(x: baseOrigin.x, y: clampedY)
        }

        return defaultDropdownOrigin(containerSize: containerSize, anchor: anchor, dropdownSize: dropdownSize)
    }

    private func defaultDropdownOrigin(containerSize: CGSize, anchor: CGRect, dropdownSize: CGSize) -> CGPoint {
        let margin: CGFloat = 8
        let gap: CGFloat = 8

        let availableBelow = containerSize.height - anchor.maxY - margin
        let availableAbove = anchor.minY - margin
        let openUpward = availableBelow < (dropdownSize.height + gap) && availableAbove > availableBelow

        let rawY = openUpward
            ? (anchor.minY - gap - dropdownSize.height)
            : (anchor.maxY + gap)
        let maxY = max(margin, containerSize.height - dropdownSize.height - margin)
        let clampedY = min(max(rawY, margin), maxY)

        let rawX = anchor.minX
        let maxX = max(margin, containerSize.width - dropdownSize.width - margin)
        let clampedX = min(max(rawX, margin), maxX)

        return CGPoint(x: clampedX, y: clampedY)
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
                        viewModel.pendingFilterCriteria.selectedApps = nil
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
                },
                onKeyboardSelect: {
                    let nextAnchorFrame = viewModel.filterAnchorFrames[.comments] ?? .zero
                    withAnimation(.easeOut(duration: 0.15)) {
                        viewModel.showFilterDropdown(.comments, anchorFrame: nextAnchorFrame)
                    }
                }
            )
        case .comments:
            CommentFilterPopover(
                currentFilter: viewModel.pendingFilterCriteria.commentFilter,
                onSelect: { filter in
                    viewModel.setCommentFilter(filter)
                },
                onDismiss: {
                    withAnimation(.easeOut(duration: 0.15)) {
                        viewModel.dismissFilterDropdown()
                    }
                },
                onKeyboardSelect: {
                    let nextAnchorFrame = viewModel.filterAnchorFrames[.dateRange] ?? .zero
                    withAnimation(.easeOut(duration: 0.15)) {
                        viewModel.showFilterDropdown(.dateRange, anchorFrame: nextAnchorFrame)
                    }
                }
            )
        case .dateRange:
            DateRangeFilterPopover(
                dateRanges: viewModel.pendingFilterCriteria.effectiveDateRanges,
                onApply: { ranges in
                    viewModel.setDateRanges(ranges)
                },
                onClear: {
                    viewModel.setDateRanges([])
                },
                enableKeyboardNavigation: true,
                onMoveToNextFilter: {
                    let nextAnchorFrame = viewModel.filterAnchorFrames[.advanced] ?? .zero
                    withAnimation(.easeOut(duration: 0.15)) {
                        viewModel.showFilterDropdown(.advanced, anchorFrame: nextAnchorFrame)
                    }
                },
                onCalendarEditingChange: { isEditing in
                    viewModel.isDateRangeCalendarEditing = isEditing
                },
                onDismiss: {
                    withAnimation(.easeOut(duration: 0.15)) {
                        viewModel.dismissFilterDropdown()
                    }
                }
            )
        case .advanced:
            // Advanced filters are inline in the FilterPanel, not a dropdown popover
            EmptyView()
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
