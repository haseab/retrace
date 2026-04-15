import AppKit
import SwiftUI
import App
import Shared
import CoreGraphics
import AVFoundation
import UniformTypeIdentifiers

@MainActor
extension TimelineWindowController {
    enum MonitoredEventSource {
        case global
        case local
    }

    enum LocalKeyDownDecision {
        case passThrough
        case handleAndConsume
        case handleWithFallback
    }

    struct KeyboardShortcutContext {
        let modifiers: NSEvent.ModifierFlags
        let isTextFieldActive: Bool
        let openLinkTrigger: String?
        let copyLinkTrigger: String?
        let copyYouTubeMarkdownLinkTrigger: String?
        let copyMomentLinkTrigger: String?
        let addCommentTrigger: String?
        let addTagTrigger: String?
        let quickAppFilterTrigger: String?
        let isInFrameSearchFieldActive: Bool
    }

    func setupEventMonitors() {
        mouseEventMonitor = installTapeMouseMonitor()
        eventMonitor = installGlobalInputMonitor()
        localEventMonitor = installLocalInputMonitor()
    }

    func installTapeMouseMonitor() -> Any? {
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .leftMouseDragged, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            return self.handleTapeMouseMonitorEvent(event)
        }
    }

    func installGlobalInputMonitor() -> Any? {
        NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .scrollWheel, .magnify]) { [weak self] event in
            self?.handleGlobalMonitoredEvent(event)
        }
    }

    func installLocalInputMonitor() -> Any? {
        NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .scrollWheel, .magnify]) { [weak self] event in
            self?.handleLocalMonitoredEvent(event) ?? event
        }
    }

    func handleTapeMouseMonitorEvent(_ event: NSEvent) -> NSEvent? {
        guard isVisible else { return event }

        switch event.type {
        case .leftMouseDown:
            return beginTapeDragIfPossible(with: event)
        case .leftMouseDragged:
            return updateTapeDrag(with: event)
        case .leftMouseUp:
            return finishTapeDrag(with: event)
        case .flagsChanged:
            return event
        default:
            return event
        }
    }

    func beginTapeDragIfPossible(with event: NSEvent) -> NSEvent? {
        guard !event.modifierFlags.contains(.shift) else { return event }

        let clickPoint = event.locationInWindow
        let startedNearPlaybackControls = isPointNearPlaybackControls(clickPoint)
        guard !startedNearPlaybackControls else { return event }
        guard isPointInTapeArea(clickPoint) else { return event }
        guard let viewModel = timelineViewModel,
              !viewModel.isSearchOverlayVisible,
              !viewModel.isFilterDropdownOpen,
              !viewModel.isDateSearchActive,
              !viewModel.showTagSubmenu,
              !viewModel.isCalendarPickerVisible else {
            return event
        }

        viewModel.cancelTapeDragMomentum()
        tapeDragStartX = clickPoint.x
        tapeDragLastX = clickPoint.x
        tapeDragStartPoint = clickPoint
        tapeDragStartedNearPlaybackControls = startedNearPlaybackControls
        isTapeDragging = true
        tapeDragDidExceedThreshold = false
        tapeDragVelocitySamples.removeAll()
        return event
    }

    func updateTapeDrag(with event: NSEvent) -> NSEvent? {
        guard isTapeDragging else { return event }

        let currentX = event.locationInWindow.x
        let totalDistance = abs(currentX - tapeDragStartX)
        if !tapeDragDidExceedThreshold {
            guard totalDistance >= Self.tapeDragMinDistance else {
                return event
            }
            tapeDragDidExceedThreshold = true
            NSCursor.closedHand.push()
            if let viewModel = timelineViewModel {
                Task { @MainActor in
                    if !viewModel.isActivelyScrolling {
                        viewModel.isActivelyScrolling = true
                        viewModel.dismissContextMenu()
                        viewModel.dismissTimelineContextMenu(reason: .scroll)
                    }
                }
            }
        }

        let deltaX = currentX - tapeDragLastX
        tapeDragLastX = currentX
        recordTapeDragVelocitySample(deltaX)
        if abs(deltaX) > 0.001, let viewModel = timelineViewModel {
            Task { @MainActor in
                await viewModel.handleScroll(delta: -deltaX, isTrackpad: true)
            }
        }
        return nil
    }

    func finishTapeDrag(with event: NSEvent) -> NSEvent? {
        guard isTapeDragging else { return event }

        let wasDragging = tapeDragDidExceedThreshold
        isTapeDragging = false
        tapeDragDidExceedThreshold = false

        defer {
            tapeDragStartedNearPlaybackControls = false
            tapeDragStartPoint = .zero
        }

        guard wasDragging else {
            return event
        }

        NSCursor.pop()
        let velocity = tapeDragReleaseVelocity()
        if let viewModel = timelineViewModel {
            Task { @MainActor in
                viewModel.endTapeDrag(withVelocity: -velocity)
            }
        }
        return nil
    }

    func recordTapeDragVelocitySample(_ deltaX: CGFloat) {
        let now = CFAbsoluteTimeGetCurrent()
        tapeDragVelocitySamples.append((time: now, delta: deltaX))
        tapeDragVelocitySamples.removeAll { now - $0.time > Self.velocitySampleWindow }
    }

    func tapeDragReleaseVelocity() -> CGFloat {
        let now = CFAbsoluteTimeGetCurrent()
        let recentSamples = tapeDragVelocitySamples.filter { now - $0.time <= Self.velocitySampleWindow }
        tapeDragVelocitySamples.removeAll()
        guard recentSamples.count >= 2,
              let first = recentSamples.first,
              let last = recentSamples.last else {
            return 0
        }
        let dt = last.time - first.time
        guard dt > 0.001 else { return 0 }
        let totalDelta = recentSamples.reduce(0) { $0 + $1.delta }
        return totalDelta / CGFloat(dt)
    }

    func handleGlobalMonitoredEvent(_ event: NSEvent) {
        _ = handleMonitoredEvent(event, source: .global)
    }

    func handleLocalMonitoredEvent(_ event: NSEvent) -> NSEvent? {
        handleMonitoredEvent(event, source: .local)
    }

    func handleMonitoredEvent(_ event: NSEvent, source: MonitoredEventSource) -> NSEvent? {
        switch event.type {
        case .keyDown:
            return handleMonitoredKeyDown(event, source: source)
        case .scrollWheel:
            return handleMonitoredScroll(event, source: source)
        case .magnify:
            return handleMonitoredMagnify(event, source: source)
        default:
            return source == .local ? event : nil
        }
    }

    func handleMonitoredKeyDown(_ event: NSEvent, source: MonitoredEventSource) -> NSEvent? {
        switch source {
        case .global:
            handleGlobalMonitoredKeyDown(event)
            return nil
        case .local:
            return handleLocalKeyDownEvent(event)
        }
    }

    func handleGlobalMonitoredKeyDown(_ event: NSEvent) {
        guard shouldHandleTimelineKeyboardShortcuts() else { return }
        let context = keyboardShortcutContext(for: event)
        guard context.addCommentTrigger == nil else { return }
        _ = handleKeyEvent(event)
    }

    func handleLocalKeyDownEvent(_ event: NSEvent) -> NSEvent? {
        let context = keyboardShortcutContext(for: event)
        switch localKeyDownDecision(for: event, context: context) {
        case .passThrough:
            return event
        case .handleAndConsume:
            _ = handleKeyEvent(event)
            return nil
        case .handleWithFallback:
            return handleKeyEvent(event) ? nil : event
        }
    }

    func keyboardShortcutContext(for event: NSEvent) -> KeyboardShortcutContext {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let isTextFieldActive = isTimelineTextFieldActive()
        let openLinkTrigger = openLinkShortcutTrigger(for: event, modifiers: modifiers)
        let copyLinkTrigger = copyLinkShortcutTrigger(for: event, modifiers: modifiers)
        let copyYouTubeMarkdownLinkTrigger = copyYouTubeMarkdownLinkShortcutTrigger(for: event, modifiers: modifiers)
        let copyMomentLinkTrigger = copyMomentLinkShortcutTrigger(for: event, modifiers: modifiers)

        return KeyboardShortcutContext(
            modifiers: modifiers,
            isTextFieldActive: isTextFieldActive,
            openLinkTrigger: openLinkTrigger,
            copyLinkTrigger: copyLinkTrigger,
            copyYouTubeMarkdownLinkTrigger: copyYouTubeMarkdownLinkTrigger,
            copyMomentLinkTrigger: copyMomentLinkTrigger,
            addCommentTrigger: addCommentShortcutTrigger(for: event, modifiers: modifiers),
            addTagTrigger: addTagShortcutTrigger(for: event, modifiers: modifiers),
            quickAppFilterTrigger: quickAppFilterTrigger(for: event, modifiers: modifiers),
            isInFrameSearchFieldActive: isTextFieldActive &&
                (timelineViewModel?.isInFrameSearchVisible ?? false)
        )
    }

    func localKeyDownDecision(
        for event: NSEvent,
        context: KeyboardShortcutContext
    ) -> LocalKeyDownDecision {
        if event.keyCode == 53 {
            return .handleWithFallback
        }

        if event.keyCode == 3 && context.modifiers == [.command] {
            return .handleAndConsume
        }

        if Self.shouldDismissTimelineWithCommandW(
            keyCode: event.keyCode,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            modifiers: context.modifiers
        ) {
            return .handleWithFallback
        }

        if context.isInFrameSearchFieldActive,
           context.openLinkTrigger == nil,
           context.copyLinkTrigger == nil,
           context.copyYouTubeMarkdownLinkTrigger == nil {
            return .passThrough
        }

        if event.keyCode == 40 && context.modifiers == [.command] {
            if let viewModel = timelineViewModel,
               viewModel.showCommentSubmenu,
               context.isTextFieldActive {
                return .passThrough
            }
            return .handleAndConsume
        }

        if shouldForceHandleLocalKeyDown(
            event,
            context: context
        ) {
            return .handleAndConsume
        }

        return context.isTextFieldActive ? .passThrough : .handleWithFallback
    }

    func shouldForceHandleLocalKeyDown(
        _ event: NSEvent,
        context: KeyboardShortcutContext
    ) -> Bool {
        let modifiers = context.modifiers
        if event.keyCode == 4 && modifiers == [.option] {
            return true
        }
        if context.addTagTrigger != nil {
            return true
        }
        if context.quickAppFilterTrigger != nil {
            return true
        }
        if event.keyCode == 3 && modifiers == [.command, .shift] {
            return true
        }
        if event.keyCode == 5 && modifiers == [.command] {
            return true
        }
        if (event.keyCode == 24 || event.keyCode == 69)
            && (modifiers == [.command] || modifiers == [.command, .shift]) {
            return true
        }
        if (event.keyCode == 27 || event.keyCode == 78) && modifiers == [.command] {
            return true
        }
        if event.keyCode == 29 && (modifiers == [.command] || modifiers == [.control]) {
            return true
        }
        if event.keyCode == 0 && modifiers == [.command] {
            return !Self.shouldDeferCommandAToTextInput(
                isTextFieldActive: context.isTextFieldActive,
                isSearchOverlayVisible: timelineViewModel?.isSearchOverlayVisible ?? false,
                isFilterPanelVisible: timelineViewModel?.isFilterPanelVisible ?? false,
                isDateSearchActive: timelineViewModel?.isDateSearchActive ?? false,
                isCommentSubmenuVisible: timelineViewModel?.showCommentSubmenu ?? false
            )
        }
        if event.charactersIgnoringModifiers == "c" && modifiers == [.command] {
            return !context.isTextFieldActive
        }
        if event.charactersIgnoringModifiers == "s" && modifiers == [.command] {
            return true
        }
        if context.openLinkTrigger != nil
            || context.copyLinkTrigger != nil
            || context.copyYouTubeMarkdownLinkTrigger != nil
            || context.copyMomentLinkTrigger != nil {
            return true
        }
        if event.charactersIgnoringModifiers == ";" && modifiers == [.command] {
            return true
        }
        if event.keyCode == 4 && modifiers == [.command] {
            return true
        }
        if event.keyCode == 38 && modifiers == [.command] {
            return true
        }
        if event.keyCode == 35 && modifiers == [.command] {
            return true
        }

        return false
    }

    func handleMonitoredScroll(_ event: NSEvent, source: MonitoredEventSource) -> NSEvent? {
        if let viewModel = timelineViewModel, shouldLetOverlayOwnScroll(on: viewModel) {
            return source == .local ? event : nil
        }
        handleScrollEvent(event, source: source == .global ? "GLOBAL" : "LOCAL")
        return source == .local ? nil : nil
    }

    func handleMonitoredMagnify(_ event: NSEvent, source: MonitoredEventSource) -> NSEvent? {
        handleMagnifyEvent(event)
        return source == .local ? nil : nil
    }

    func shouldLetOverlayOwnScroll(on viewModel: SimpleTimelineViewModel) -> Bool {
        if viewModel.showCommentSubmenu {
            return true
        }
        if viewModel.isFilterDropdownOpen {
            return true
        }
        if viewModel.showTagSubmenu {
            return true
        }
        if viewModel.searchViewModel.isRecentEntriesPopoverVisible {
            return true
        }
        if viewModel.isSearchOverlayVisible &&
            (viewModel.searchViewModel.isDropdownOpen ||
             viewModel.searchViewModel.isSearchOverlayExpanded) {
            return true
        }
        return false
    }

    func isTimelineTextFieldActive() -> Bool {
        guard let window,
              let firstResponder = window.firstResponder else {
            return false
        }
        return firstResponder is NSTextView || firstResponder is NSTextField
    }

    func removeEventMonitors() {
        // End any in-progress tape drag before removing monitors
        forceEndTapeDrag()

        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        if let monitor = localEventMonitor {
            NSEvent.removeMonitor(monitor)
            localEventMonitor = nil
        }
        if let monitor = mouseEventMonitor {
            NSEvent.removeMonitor(monitor)
            mouseEventMonitor = nil
        }
    }

    /// Check if a window-coordinate point is within the timeline tape area
    func isPointInTapeArea(_ pointInWindow: CGPoint) -> Bool {
        guard let viewModel = timelineViewModel else { return false }

        // Don't allow tape dragging when controls are hidden or tape is hidden
        guard !viewModel.areControlsHidden && !viewModel.isTapeHidden else { return false }

        // In NSWindow coordinates, Y=0 is at the BOTTOM
        // The tape is positioned at the bottom with .padding(.bottom, tapeBottomPadding)
        let tapeHeight = TimelineScaleFactor.tapeHeight           // 42 * scale
        let tapeBottomPadding = TimelineScaleFactor.tapeBottomPadding  // 40 * scale

        let tapeBottomY = tapeBottomPadding
        let tapeTopY = tapeBottomPadding + tapeHeight

        // Add generous padding for easier grabbing
        let hitPadding: CGFloat = 10 * TimelineScaleFactor.current
        let hitBottom = max(0, tapeBottomY - hitPadding)
        let hitTop = tapeTopY + hitPadding

        return pointInWindow.y >= hitBottom && pointInWindow.y <= hitTop
    }

    /// Hit region near playback controls.
    /// Derived from the same layout metrics as TimelineTapeView to avoid tap-vs-drag conflicts.
    func isPointNearPlaybackControls(_ pointInWindow: CGPoint) -> Bool {
        guard let viewModel = timelineViewModel,
              viewModel.showVideoControls,
              !viewModel.areControlsHidden,
              !viewModel.isTapeHidden,
              let window = window else {
            return false
        }

        let scale = TimelineScaleFactor.current
        let controlButtonSize = TimelineScaleFactor.controlButtonSize
        let controlSpacing = TimelineScaleFactor.controlSpacing
        let centerX = window.contentView?.bounds.midX ?? window.frame.width / 2
        let controlsCenterY = TimelineScaleFactor.tapeBottomPadding + TimelineScaleFactor.tapeHeight + TimelineScaleFactor.controlsYOffset

        // Keep this in sync with TimelineTapeView.playhead:
        // middleSideControlsWidth = controlButtonSize * 2 + 6 + 8 + (controlButtonSize + controlSpacing)
        let middleSideControlsWidth = (controlButtonSize * 3) + controlSpacing + 14
        let datetimeWidth = estimatedDatetimeControlWidth(for: viewModel, scale: scale)
        let rightControlsLeadingX = centerX + (datetimeWidth / 2) + controlSpacing

        // Cover both "Go to now/refresh" and play button targets.
        let horizontalPadding = 16 * scale
        let minX = rightControlsLeadingX - horizontalPadding
        let maxX = rightControlsLeadingX + middleSideControlsWidth + horizontalPadding

        // Include slight overlap with tape hit area to catch low-edge play clicks.
        let verticalPadding = 18 * scale
        let minY = controlsCenterY - (controlButtonSize / 2) - verticalPadding
        let maxY = controlsCenterY + (controlButtonSize / 2) + verticalPadding

        return pointInWindow.x >= minX &&
            pointInWindow.x <= maxX &&
            pointInWindow.y >= minY &&
            pointInWindow.y <= maxY
    }

    /// Estimate the runtime width of the datetime control so click hit-testing matches localized labels.
    func estimatedDatetimeControlWidth(for viewModel: SimpleTimelineViewModel, scale: CGFloat) -> CGFloat {
        let dateFont = NSFont.systemFont(ofSize: TimelineScaleFactor.fontCaption, weight: .medium)
        let timeFont = NSFont.monospacedSystemFont(ofSize: TimelineScaleFactor.fontMono, weight: .regular)
        let chevronFont = NSFont.systemFont(ofSize: TimelineScaleFactor.fontTiny, weight: .bold)

        let dateWidth = (viewModel.currentDateString as NSString).size(withAttributes: [.font: dateFont]).width
        let timeWidth = (viewModel.currentTimeString as NSString).size(withAttributes: [.font: timeFont]).width
        let chevronWidth = ("▾" as NSString).size(withAttributes: [.font: chevronFont]).width

        // Match DatetimeButton horizontal spacing/padding.
        let contentWidth = dateWidth +
            TimelineScaleFactor.iconSpacing +
            timeWidth +
            TimelineScaleFactor.iconSpacing +
            chevronWidth
        let paddedWidth = contentWidth + (TimelineScaleFactor.paddingH * 2)

        // Clamp to avoid pathological under/over-estimation.
        let minWidth = 120 * scale
        let maxWidth = 480 * scale
        return min(maxWidth, max(minWidth, ceil(paddedWidth)))
    }

    /// Force-end any in-progress tape drag (e.g., on window focus loss)
    func forceEndTapeDrag() {
        guard isTapeDragging else { return }
        let wasDragging = tapeDragDidExceedThreshold
        isTapeDragging = false
        tapeDragDidExceedThreshold = false
        tapeDragVelocitySamples.removeAll()
        tapeDragStartedNearPlaybackControls = false
        tapeDragStartPoint = .zero

        if wasDragging {
            NSCursor.pop()
            if let viewModel = timelineViewModel {
                Task { @MainActor in
                    viewModel.endTapeDrag(withVelocity: 0)
                }
            }
        }
    }

    func handleScrollEvent(_ event: NSEvent, source: String) {
        guard isVisible, let viewModel = timelineViewModel else { return }

        // Dedicated overlays own wheel gestures while visible.
        if viewModel.showCommentSubmenu {
            return
        }

        if viewModel.isInLiveMode, CFAbsoluteTimeGetCurrent() < suppressLiveScrollUntil {
            return
        }

        let orientationRaw = Self.timelineSettingsStore.string(forKey: "timelineScrollOrientation") ?? "horizontal"
        let orientation = TimelineScrollOrientation(rawValue: orientationRaw) ?? .horizontal
        let delta: Double
        switch orientation {
        case .horizontal:
            // Default behavior: left/right swipes move timeline.
            delta = -event.scrollingDeltaX
        case .vertical:
            // Optional behavior: up/down swipes move timeline.
            delta = -event.scrollingDeltaY
        }

        // --- Scroll orientation mismatch detection ---
        if !hasShownScrollOrientationHint {
            let wrongAxisMag = abs(orientation == .horizontal ? event.scrollingDeltaY : event.scrollingDeltaX)
            let rightAxisMag = abs(orientation == .horizontal ? event.scrollingDeltaX : event.scrollingDeltaY)

            let now = CFAbsoluteTimeGetCurrent()
            if now - scrollAccumStartTime > 2.0 {
                wrongAxisScrollAccum = 0
                rightAxisScrollAccum = 0
                scrollAccumStartTime = now
            }
            wrongAxisScrollAccum += wrongAxisMag
            rightAxisScrollAccum += rightAxisMag

            if wrongAxisScrollAccum > 500,
               rightAxisScrollAccum < 5 || wrongAxisScrollAccum > 5 * rightAxisScrollAccum {
                hasShownScrollOrientationHint = true
                viewModel.showScrollOrientationHint(current: orientation.rawValue)
            }
        }

        // Trackpads have precise scrolling deltas, mice do not
        let isTrackpad = event.hasPreciseScrollingDeltas

        if abs(delta) > 0.001 {
            // Cancel any tape drag momentum on real scroll input
            viewModel.cancelTapeDragMomentum()

            onScroll?(delta)
            // Forward scroll to view model
            Task { @MainActor in
                await viewModel.handleScroll(delta: CGFloat(delta), isTrackpad: isTrackpad)
            }
        }
    }

    func handleMagnifyEvent(_ event: NSEvent) {
        guard isVisible, let viewModel = timelineViewModel, let window = window else { return }

        // Don't handle magnify when zoom region or search overlay is active
        if viewModel.isZoomRegionActive || viewModel.isSearchOverlayVisible {
            return
        }

        // magnification is the delta from the last event (can be positive or negative)
        // Convert to a scale factor: 1.0 + magnification
        let magnification = event.magnification
        let scaleFactor = 1.0 + magnification

        // Get mouse location in window coordinates and convert to normalized anchor point
        let mouseLocation = event.locationInWindow
        let windowSize = window.frame.size

        // Convert to normalized coordinates (0-1 range, with 0.5,0.5 being center)
        // Note: macOS window coordinates have Y=0 at bottom, so we flip Y
        let normalizedX = mouseLocation.x / windowSize.width
        let normalizedY = 1.0 - (mouseLocation.y / windowSize.height)
        let anchor = CGPoint(x: normalizedX, y: normalizedY)

        // Apply the magnification with anchor point
        viewModel.applyMagnification(scaleFactor, anchor: anchor, frameSize: windowSize)
    }
}
