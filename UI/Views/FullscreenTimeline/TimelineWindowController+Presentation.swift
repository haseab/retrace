import AppKit
import SwiftUI
import App
import Shared
import CoreGraphics
import AVFoundation
import UniformTypeIdentifiers

@MainActor
extension TimelineWindowController {

    // MARK: - Show/Hide

    /// Show the timeline overlay on the current screen
    public func show() {
        reconcileVisibilityState(reason: "show")
        cancelDeferredHostingViewDetach()
        cancelWindowFadeIn(reason: "show")
        cancelDeferredSearchOverlayRestore()

        // If we're in the middle of hiding, cancel the animation and snap back to visible
        if isHiding, let window = window {
            isHiding = false
            presentationState = .visible
            // Cancel any running animation by setting duration to 0
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0
                window.animator().alphaValue = 1
            })
            Self.setEmergencyTimelineVisible(true)
            hideCompletionCoordinator.resumeAll(hidden: false)
            startObservingApplicationActivation()
            return
        }

        guard !isVisible, let coordinator = coordinator else {
            return
        }
        let showStartTime = CFAbsoluteTimeGetCurrent()
        liveModeCaptureTask?.cancel()
        liveModeCaptureTask = nil
        captureFocusRestoreTarget()
        // Only capture/use live screenshot if playhead is at or near the latest frame (last 3 frames)
        // Otherwise, user was viewing a historical frame and should see that instead
        var shouldUseLiveMode = true
        var shouldRefreshPreparedMetadataOnShow = false
        var navigateToNewestOnShowRefresh = true
        var allowNearLiveAutoAdvanceOnShowRefresh = true
        var shouldShowPositionRecoveryHintOnShow = false
        var positionRecoveryHintHiddenElapsedSeconds: TimeInterval?

        if let viewModel = timelineViewModel {
            let framesFromNewestBefore = max(0, viewModel.frames.count - 1 - viewModel.currentIndex)
            let hiddenElapsedSeconds = lastHiddenAt.map { Date().timeIntervalSince($0) } ?? .infinity
            let loadedTapeIsRecent = viewModel.isNewestLoadedFrameRecent()
            let instantEligible = loadedTapeIsRecent &&
                framesFromNewestBefore < Self.instantLiveReopenFrameThreshold
            let nearEligible = loadedTapeIsRecent &&
                framesFromNewestBefore < Self.nearLiveReopenFrameThreshold
            let instantLiveExpiryElapsed = hiddenElapsedSeconds >= Self.instantLiveReopenExpirationSeconds
            let nearLiveExpiryElapsed = hiddenElapsedSeconds >= Self.nearLiveReopenExpirationSeconds
            let cacheExpired = hiddenElapsedSeconds > Self.hiddenStateCacheExpirationSeconds
            var hasActiveFilters = viewModel.filterCriteria.hasActiveFilters

            // Hidden-state cache expiry invalidates filters so reopen uses fresh unfiltered metadata.
            if cacheExpired, hasActiveFilters {
                viewModel.clearFiltersWithoutReload()
                hasActiveFilters = false
            }

            let shouldAutoAdvanceNearLive = !hasActiveFilters &&
                ((instantEligible && instantLiveExpiryElapsed) || (nearEligible && nearLiveExpiryElapsed))
            let shouldSnapToNewestOnShow = cacheExpired || shouldAutoAdvanceNearLive
            let shouldClearSearchForReopenPolicy = shouldSnapToNewestOnShow

            if shouldClearSearchForReopenPolicy {
                let searchViewModel = viewModel.searchViewModel
                if searchViewModel.hasResults || !searchViewModel.searchQuery.isEmpty {
                    searchViewModel.clearSearchResults()
                }
            }

            if shouldSnapToNewestOnShow, !viewModel.frames.isEmpty {
                let newestIndex = max(0, viewModel.frames.count - 1)
                let didSnapToNewest: Bool
                if cacheExpired {
                    didSnapToNewest = viewModel.applyCacheBustReopenSnapToNewest(newestIndex: newestIndex)
                } else {
                    if viewModel.currentIndex != newestIndex {
                        viewModel.currentIndex = newestIndex
                        didSnapToNewest = true
                    } else {
                        didSnapToNewest = false
                    }
                }

                shouldShowPositionRecoveryHintOnShow = Self.shouldShowPositionRecoveryHintOnReopen(
                    hiddenElapsedSeconds: hiddenElapsedSeconds,
                    didSnapToNewest: didSnapToNewest && cacheExpired
                )
                if shouldShowPositionRecoveryHintOnShow {
                    positionRecoveryHintHiddenElapsedSeconds = hiddenElapsedSeconds
                }
            }

            shouldRefreshPreparedMetadataOnShow = true
            navigateToNewestOnShowRefresh = shouldSnapToNewestOnShow
            allowNearLiveAutoAdvanceOnShowRefresh = shouldAutoAdvanceNearLive || cacheExpired

            shouldUseLiveMode = loadedTapeIsRecent &&
                viewModel.isNearLatestLoadedFrame(within: Self.instantLiveReopenFrameThreshold)
        }

        // Remember if dashboard was the key window before we take over
        dashboardWasKeyWindow = DashboardWindowController.shared.isVisible &&
            NSApp.keyWindow == DashboardWindowController.shared.window

        // Get the screen where the mouse cursor is located
        let mouseLocation = NSEvent.mouseLocation
        guard let targetScreen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) }) ?? NSScreen.main else {
            return
        }

        // Reset scale factor cache so it recalculates for the current display
        TimelineScaleFactor.resetCache()

        // Check if we have a prepared metadata state ready
        if isPrepared, let viewModel = timelineViewModel {
            mountPresentationIfNeeded(
                on: targetScreen,
                coordinator: coordinator,
                viewModel: viewModel
            )
            prepareLiveModeState(shouldUseLiveMode: shouldUseLiveMode, viewModel: viewModel)
            viewModel.setTapeHidden(true)
            tapeShowAnimationTask?.cancel()

            showPreparedWindow(
                coordinator: coordinator,
                openPath: "prepared_headless",
                showStartTime: showStartTime
            )
            if shouldShowPositionRecoveryHintOnShow,
               let hiddenElapsedSeconds = positionRecoveryHintHiddenElapsedSeconds {
                viewModel.showPositionRecoveryHint(hiddenElapsedSeconds: hiddenElapsedSeconds)
            }
            startLiveModeCaptureIfNeeded(shouldUseLiveMode: shouldUseLiveMode, viewModel: viewModel)
            if shouldRefreshPreparedMetadataOnShow {
                refreshTimelineMetadataOnShow(
                    viewModel: viewModel,
                    navigateToNewest: navigateToNewestOnShowRefresh,
                    allowNearLiveAutoAdvance: allowNearLiveAutoAdvanceOnShowRefresh
                )
            }
            return
        }

        // Fallback: Create presentation and view model from scratch (prerender disabled or unavailable).
        let viewModel = SimpleTimelineViewModel(coordinator: coordinator)
        setTimelineViewModel(viewModel)
        prepareLiveModeState(shouldUseLiveMode: shouldUseLiveMode, viewModel: viewModel)
        viewModel.setTapeHidden(true)
        tapeShowAnimationTask?.cancel()
        mountPresentationIfNeeded(
            on: targetScreen,
            coordinator: coordinator,
            viewModel: viewModel
        )
        self.isPrepared = true

        // Show the window
        showPreparedWindow(
            coordinator: coordinator,
            openPath: "fallback",
            showStartTime: showStartTime
        )
        startLiveModeCaptureIfNeeded(shouldUseLiveMode: shouldUseLiveMode, viewModel: viewModel)
        refreshTimelineMetadataOnShow(
            viewModel: viewModel,
            navigateToNewest: true,
            allowNearLiveAutoAdvance: true
        )
    }

    /// Show the prepared window with animation and setup event monitors
    func showPreparedWindow(
        coordinator: AppCoordinator,
        openPath: String,
        showStartTime: CFAbsoluteTime
    ) {
        guard let window = window else { return }

        timelineViewModel?.setTapeHidden(true)
        tapeShowAnimationTask?.cancel()

        // Force video reload BEFORE showing window to avoid flicker
        // This ensures AVPlayer loads fresh video data with any new frames
        // Skip this when in live mode since we're showing a live screenshot instead
        if let viewModel = timelineViewModel, !viewModel.isInLiveMode, viewModel.frames.count > 1 {
            viewModel.forceVideoReload = true
            let original = viewModel.currentIndex
            viewModel.currentIndex = max(0, original - 1)
            viewModel.currentIndex = original
        }
        timelineViewModel?.setPresentationWorkEnabled(true, reason: "showPreparedWindow")
        timelineViewModel?.refreshStaticPresentationIfNeeded()

        let isLive = timelineViewModel?.isInLiveMode ?? false
        if isLive {
            suppressLiveScrollUntil = CFAbsoluteTimeGetCurrent() + Self.liveScrollSuppressDuration
        } else {
            suppressLiveScrollUntil = 0
        }
        window.alphaValue = isLive ? 1 : 0

        // Re-enable mouse events before showing (was disabled while hidden to prevent blocking clicks)
        window.ignoresMouseEvents = false

        // Always start visible sessions with context menus closed.
        if let viewModel = timelineViewModel {
            viewModel.dismissContextMenu()
            viewModel.dismissTimelineContextMenu()
        }

        // Re-assert Space behavior before each open so cached windows always
        // materialize on the currently active Desktop.
        window.collectionBehavior.remove(.canJoinAllSpaces)
        window.collectionBehavior.insert(.moveToActiveSpace)
        // Mark visible before activation to avoid activation-time dashboard reveal
        // races that can switch Spaces on some machines.
        presentationState = .showing
        Self.setEmergencyTimelineVisible(true)  // For emergency escape tap
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        presentationState = .visible
        startObservingApplicationActivation()
        if let hostingView = hostingView {
            DispatchQueue.main.async { [weak hostingView] in
                hostingView?.layoutSubtreeIfNeeded()
            }
        }
        let openElapsedMs = (CFAbsoluteTimeGetCurrent() - showStartTime) * 1000
        Log.recordLatency(
            "timeline.open.window_visible_ms",
            valueMs: openElapsedMs,
            category: .ui,
            summaryEvery: 5,
            warningThresholdMs: 250,
            criticalThresholdMs: 600
        )
        Log.recordLatency(
            "timeline.open.\(openPath).window_visible_ms",
            valueMs: openElapsedMs,
            category: .ui,
            summaryEvery: 5,
            warningThresholdMs: 250,
            criticalThresholdMs: 600
        )

        // Fade in only for non-live opens (prevents the live screenshot "zoom" feel)
        if !isLive, let viewModel = timelineViewModel {
            scheduleHistoricalFadeIn(window: window, viewModel: viewModel)
        }

        if isLive, let viewModel = timelineViewModel {
            scheduleDeferredSearchOverlayRestoreIfNeeded(
                viewModel: viewModel,
                isLiveMode: isLive
            )
        }

        // Trigger tape slide-up animation (Cmd+H style)
        tapeShowAnimationTask = Task { @MainActor in
            await Task.yield()
            guard let viewModel = self.timelineViewModel, !Task.isCancelled else { return }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                viewModel.setTapeHidden(false)
            }
        }

        // Track timeline open event
        DashboardViewModel.recordTimelineOpen(coordinator: coordinator)

        // Setup keyboard monitoring
        setupEventMonitors()

        // Notify coordinator to pause frame processing while timeline is visible
        Task {
            await coordinator.setTimelineVisible(true)
        }

        // Track session start time for duration metrics
        sessionStartTime = Date()
        sessionScrubDistance = 0  // Reset scrub distance for new session
        timelineViewModel?.resetVisibleSessionScrubTracking()

        // Post notification so menu bar can hide recording indicator
        NotificationCenter.default.post(name: .timelineDidOpen, object: nil)

    }

    func cancelDeferredSearchOverlayRestore() {
        deferredSearchOverlayRestoreTask?.cancel()
        deferredSearchOverlayRestoreTask = nil
    }

    static func preservedSearchOverlayRestoreDelayMs(isLiveMode: Bool) -> Int {
        isLiveMode ? liveSearchOverlayRestoreDelayMs : historicalSearchOverlayRestoreDelayMs
    }

    func scheduleDeferredSearchOverlayRestoreIfNeeded(
        viewModel: SimpleTimelineViewModel,
        isLiveMode: Bool
    ) {
        guard shouldRestoreSearchOverlayAfterNextShow else {
            return
        }

        shouldRestoreSearchOverlayAfterNextShow = false
        cancelDeferredSearchOverlayRestore()
        let delayMs = Self.preservedSearchOverlayRestoreDelayMs(isLiveMode: isLiveMode)
        Log.info(
            "[TimelineSearchOverlay] queued preserved overlay restore delayMs=\(delayMs) isLiveMode=\(isLiveMode)",
            category: .ui
        )

        deferredSearchOverlayRestoreTask = Task { @MainActor [weak self, weak viewModel] in
            try? await Task.sleep(for: .milliseconds(delayMs), clock: .continuous)
            guard let self, let viewModel else { return }
            defer { self.deferredSearchOverlayRestoreTask = nil }
            guard !Task.isCancelled,
                  self.isVisible,
                  !self.isHiding,
                  self.timelineViewModel === viewModel else {
                return
            }

            Log.info(
                "[TimelineSearchOverlay] restoring preserved overlay after timeline reveal delayMs=\(delayMs)",
                category: .ui
            )
            viewModel.openSearchOverlay()
        }
    }

    /// Hide the timeline overlay
    public func hide(restorePreviousFocus: Bool = true) {
        reconcileVisibilityState(reason: "hide")
        guard isVisible, let window = window, !isHiding else { return }
        let hideRequestStartedAt = CFAbsoluteTimeGetCurrent()
        isHiding = true
        presentationState = .hiding
        prepareForHiddenStateTransition(reason: "hide")

        // Don't save position on hide - window stays in memory
        // Position is only saved on app termination (see savePositionForTermination)

        // Cancel any running fade-in animation before starting fade-out
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0
            window.animator().alphaValue = window.alphaValue  // Snap to current value
        })

        // Animate out
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.applyHiddenState(
                    restorePreviousFocus: restorePreviousFocus,
                    hideRequestedAt: hideRequestStartedAt,
                    reason: "hide"
                )
                await self.finishHideTransitionCleanup()
            }
        })
    }

    /// Toggle timeline visibility
    public func toggle() {
        reconcileVisibilityState(reason: "toggle")
        let actualVisible = isActuallyVisible
        let action = Self.toggleAction(
            presentationState: presentationState,
            isActuallyVisible: actualVisible
        )
        if action == .hide {
            hide()
        } else {
            show()
        }
    }

    /// Hide the timeline to show dashboard or settings
    /// This prevents the dashboard from being auto-hidden when the timeline closes
    public func hideToShowDashboard() {
        isHidingToShowDashboard = true
        hide(restorePreviousFocus: false)
    }

    /// Show the timeline and navigate to a specific date
    public func showAndNavigate(to date: Date) {
        show()

        // Navigate after a brief delay to allow the view to initialize
        Task { @MainActor in
            try? await Task.sleep(for: .nanoseconds(Int64(300_000_000)), clock: .continuous) // 0.3 seconds
            await timelineViewModel?.navigateToHour(date)
        }
    }

    /// Show timeline and apply deeplink search state (`q`, `app`, `t`/`timestamp`).
    public func showSearch(query: String?, timestamp: Date?, appBundleID: String?, source: String = "unknown") {
        deeplinkSearchInvocationCounter += 1
        let invocationID = deeplinkSearchInvocationCounter
        Log.info(
            "[DeeplinkSearch] Invocation #\(invocationID) source=\(source), query=\(query ?? "nil"), timestamp=\(String(describing: timestamp)), app=\(appBundleID ?? "nil")",
            category: .ui
        )

        if let timestamp {
            showAndNavigate(to: timestamp)
        } else {
            show()
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.coordinator != nil else {
                Log.warning("[DeeplinkSearch] Invocation #\(invocationID) failed - timeline coordinator unavailable", category: .ui)
                return
            }
            let viewModel = await self.awaitTimelineViewModelReady()

            Log.info("[DeeplinkSearch] Invocation #\(invocationID) applying deeplink payload", category: .ui)
            viewModel.applySearchDeeplink(query: query, appBundleID: appBundleID, source: source)
        }
    }

    /// Show the timeline and open the spotlight search overlay, preserving any existing search state.
    public func showSearchOverlay(
        source: String = "unknown",
        recentEntriesRevealDelay: TimeInterval = 0.3
    ) {
        Log.info(
            "[TimelineSearchOverlay] showSearchOverlay source=\(source) isVisible=\(isVisible) searchOverlayVisible=\(timelineViewModel?.isSearchOverlayVisible ?? false)",
            category: .ui
        )
        show()

        Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.coordinator != nil else {
                Log.warning(
                    "[TimelineSearchOverlay] Failed to open search overlay because the timeline coordinator is unavailable source=\(source)",
                    category: .ui
                )
                return
            }
            let viewModel = await self.awaitTimelineViewModelReady()

            _ = Self.presentSearchOverlay(
                on: viewModel,
                coordinator: self.coordinator,
                recentEntriesRevealDelay: recentEntriesRevealDelay
            )
        }
    }

    @discardableResult
    static func presentSearchOverlay(
        on viewModel: SimpleTimelineViewModel,
        coordinator: AppCoordinator?,
        recentEntriesRevealDelay: TimeInterval = 0.3
    ) -> Bool {
        let wasVisible = viewModel.isSearchOverlayVisible
        viewModel.openSearchOverlay(recentEntriesRevealDelay: recentEntriesRevealDelay)

        if !wasVisible, let coordinator {
            DashboardViewModel.recordSearchDialogOpen(coordinator: coordinator)
        }

        return !wasVisible
    }

    /// Show the timeline with a pre-applied filter for an app and window name
    /// This instantly opens a filtered timeline view without showing a dialog
    /// - Parameters:
    ///   - startDate: Optional start date for filtering (e.g., week start)
    ///   - endDate: Optional end date for filtering (e.g., now)
    ///   - clickStartTime: Optional start time from when the tab was clicked (for end-to-end timing)
    public func showWithFilter(bundleID: String, windowName: String?, browserUrl: String? = nil, startDate: Date? = nil, endDate: Date? = nil, clickStartTime: CFAbsoluteTime? = nil) {
        let startTime = clickStartTime ?? CFAbsoluteTimeGetCurrent()

        // Build the filter criteria upfront
        var criteria = FilterCriteria()
        criteria.selectedApps = Set([bundleID])
        criteria.appFilterMode = .include
        if let url = browserUrl, !url.isEmpty {
            criteria.browserUrlFilter = url
        } else if let window = windowName, !window.isEmpty {
            criteria.windowNameFilter = window
        }
        // Add date range filter
        criteria.startDate = startDate
        criteria.endDate = endDate

        // Prepare window invisibly first (don't show yet)
        prepareWindowInvisibly()

        // Load data, then fade in once ready
        Task { @MainActor in
            guard let viewModel = timelineViewModel, let coordinator = coordinator else { return }

            // Dashboard-driven timeline opens should not carry stale search highlight overlays.
            viewModel.resetSearchHighlightState()

            // Apply the filter criteria to viewModel
            viewModel.replaceAppliedAndPendingFilterCriteria(criteria)

            // Query and load frames
            let frames = try? await coordinator.getMostRecentFramesWithVideoInfo(limit: 50, filters: criteria)

            // Load frames directly into viewModel
            await viewModel.loadFramesDirectly(frames ?? [], clickStartTime: startTime)

            // Small delay to let the view settle before fade-in
            try? await Task.sleep(for: .nanoseconds(Int64(100_000_000)), clock: .continuous) // 0.1 seconds

            // Now fade in the window with data already loaded
            fadeInPreparedWindow()

        }
    }

    /// Prepare the window invisibly without showing it yet
    /// Used by showWithFilter to load data before revealing
    func prepareWindowInvisibly() {
        reconcileVisibilityState(reason: "prepareWindowInvisibly")
        guard !isVisible, let coordinator = coordinator else { return }
        captureFocusRestoreTarget()

        // Remember if dashboard was the key window before we take over
        dashboardWasKeyWindow = DashboardWindowController.shared.isVisible &&
            NSApp.keyWindow == DashboardWindowController.shared.window

        // Get the screen where the mouse cursor is located
        let mouseLocation = NSEvent.mouseLocation
        guard let targetScreen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) }) ?? NSScreen.main else {
            return
        }

        let viewModel = ensurePreparedViewModel(coordinator: coordinator)

        mountPresentationIfNeeded(
            on: targetScreen,
            coordinator: coordinator,
            viewModel: viewModel
        )

        // Ensure tape starts hidden for slide-up animation
        viewModel.setTapeHidden(true)
    }

    /// Fade in the prepared window (called after data is loaded)
    func fadeInPreparedWindow() {
        guard let window = window, let coordinator = coordinator else { return }
        cancelWindowFadeIn(reason: "fadeInPreparedWindow")

        // Reattach SwiftUI view if it was detached (on hide, we remove it from superview to stop display cycle)
        if let hostingView = hostingView, hostingView.superview == nil {
            hostingView.frame = window.contentView?.bounds ?? .zero
            window.contentView?.addSubview(hostingView)
            hostingView.needsLayout = true
            window.contentView?.needsLayout = true
        }

        // Ensure tape starts hidden and cancel any pending animation
        timelineViewModel?.setTapeHidden(true)
        tapeShowAnimationTask?.cancel()

        // Force video reload before showing
        if let viewModel = timelineViewModel, viewModel.frames.count > 1 {
            viewModel.forceVideoReload = true
            let original = viewModel.currentIndex
            viewModel.currentIndex = max(0, original - 1)
            viewModel.currentIndex = original
        }

        // Fade in for filter/historical path (data already loaded)
        window.alphaValue = 0
        // Re-enable mouse events before showing (was disabled while hidden to prevent blocking clicks)
        window.ignoresMouseEvents = false
        window.collectionBehavior.remove(.canJoinAllSpaces)
        window.collectionBehavior.insert(.moveToActiveSpace)
        // Mark visible before activation to avoid activation-time dashboard reveal
        // races that can switch Spaces on some machines.
        presentationState = .showing
        Self.setEmergencyTimelineVisible(true)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        presentationState = .visible
        startObservingApplicationActivation()
        if let hostingView = hostingView {
            DispatchQueue.main.async { [weak hostingView] in
                hostingView?.layoutSubtreeIfNeeded()
            }
        }

        if let viewModel = timelineViewModel {
            scheduleHistoricalFadeIn(window: window, viewModel: viewModel)
        }

        // Trigger tape slide-up animation
        tapeShowAnimationTask = Task { @MainActor in
            await Task.yield()
            guard let viewModel = self.timelineViewModel, !Task.isCancelled else { return }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                viewModel.setTapeHidden(false)
            }
        }

        // Track timeline open event
        DashboardViewModel.recordTimelineOpen(coordinator: coordinator)

        // Setup keyboard monitoring
        setupEventMonitors()

        // Notify coordinator to pause frame processing
        Task {
            await coordinator.setTimelineVisible(true)
        }

        // Post notification so menu bar can hide recording indicator
        NotificationCenter.default.post(name: .timelineDidOpen, object: nil)
    }

    func cancelWindowFadeIn(reason _: String) {
        windowFadeInTask?.cancel()
        windowFadeInTask = nil
        windowFadeInGeneration &+= 1
    }

    func scheduleHistoricalFadeIn(window: NSWindow, viewModel: SimpleTimelineViewModel) {
        cancelWindowFadeIn(reason: "scheduleHistoricalFadeIn")
        windowFadeInGeneration &+= 1
        let generation = windowFadeInGeneration
        windowFadeInTask = Task { @MainActor [weak self, weak viewModel] in
            guard let self, let viewModel else { return }

            _ = await viewModel.prepareHistoricalOpenStillFallbackIfNeeded()

            guard !Task.isCancelled,
                  self.windowFadeInGeneration == generation,
                  self.isVisible,
                  !self.isHiding,
                  self.window === window,
                  self.timelineViewModel === viewModel else {
                return
            }

            await NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.35
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                window.animator().alphaValue = 1
            })

            self.scheduleDeferredSearchOverlayRestoreIfNeeded(
                viewModel: viewModel,
                isLiveMode: false
            )

            if self.windowFadeInGeneration == generation {
                self.windowFadeInTask = nil
            }
        }
    }
}
