import AppKit
import SwiftUI
import App
import Shared

/// Manages the full-screen timeline overlay window
/// This is a singleton that can be triggered from anywhere via keyboard shortcut
@MainActor
public class TimelineWindowController: NSObject {

    // MARK: - Singleton

    public static let shared = TimelineWindowController()

    // MARK: - Properties

    private var window: NSWindow?
    private var coordinator: AppCoordinator?
    private var eventMonitor: Any?
    private var localEventMonitor: Any?
    private var timelineViewModel: SimpleTimelineViewModel?
    private var hostingView: NSView?

    /// Whether the window has been pre-rendered and is ready to show
    private var isPrepared = false

    /// The screen the pre-rendered window was created for
    private var preparedScreen: NSScreen?

    /// When the timeline was last hidden (for cache expiry check)
    private var lastHiddenAt: Date?

    /// Cache expiration threshold (2 minutes) - matches SimpleTimelineViewModel
    private static let cacheExpirationSeconds: TimeInterval = 120

    /// Whether the timeline overlay is currently visible
    public private(set) var isVisible = false

    /// Whether the dashboard was the key window when timeline opened
    private var dashboardWasKeyWindow = false

    /// Callback when timeline closes
    public var onClose: (() -> Void)?

    /// Callback for scroll events (delta value)
    public var onScroll: ((Double) -> Void)?

    // MARK: - Initialization

    private override init() {
        super.init()
    }

    // MARK: - Shortcut Loading

    private static let timelineShortcutKey = "timelineShortcutConfig"

    /// Load the current timeline shortcut from UserDefaults
    private func loadTimelineShortcut() -> ShortcutConfig {
        let defaults = UserDefaults(suiteName: "io.retrace.app") ?? .standard
        guard let data = defaults.data(forKey: Self.timelineShortcutKey),
              let config = try? JSONDecoder().decode(ShortcutConfig.self, from: data) else {
            return .defaultTimeline
        }
        return config
    }

    // MARK: - Configuration

    /// Configure with the app coordinator (call once during app launch)
    public func configure(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        // Pre-render the window in the background for instant show()
        Task { @MainActor in
            // Small delay to let app finish launching
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
            prepareWindow()
        }
    }

    // MARK: - Pre-rendering

    /// Pre-create the window and SwiftUI view hierarchy (hidden) for instant display on hotkey press
    /// This should be called at app startup to eliminate the ~260ms delay when showing the timeline
    public func prepareWindow() {
        let prepareStartTime = CFAbsoluteTimeGetCurrent()
        Log.info("[TIMELINE-PRERENDER] 🚀 prepareWindow() started", category: .ui)

        guard let coordinator = coordinator else {
            Log.info("[TIMELINE-PRERENDER] ⚠️ prepareWindow() skipped - no coordinator", category: .ui)
            return
        }

        // Don't re-prepare if already prepared and window exists
        if isPrepared && window != nil {
            Log.info("[TIMELINE-PRERENDER] ⚠️ prepareWindow() skipped - already prepared", category: .ui)
            return
        }

        // Get the main screen for pre-rendering (will check mouse location on actual show)
        guard let screen = NSScreen.main else {
            Log.info("[TIMELINE-PRERENDER] ⚠️ prepareWindow() skipped - no main screen", category: .ui)
            return
        }
        Log.info("[TIMELINE-PRERENDER] 📺 Using screen: \(screen.frame)", category: .ui)

        // Create the window (hidden)
        let window = createWindow(for: screen)
        window.alphaValue = 0
        window.orderOut(nil)
        Log.info("[TIMELINE-PRERENDER] 🪟 Window created (hidden), elapsed=\(String(format: "%.3f", (CFAbsoluteTimeGetCurrent() - prepareStartTime) * 1000))ms", category: .ui)

        // Create the view model
        let viewModel = SimpleTimelineViewModel(coordinator: coordinator)
        self.timelineViewModel = viewModel
        Log.info("[TIMELINE-PRERENDER] 📊 ViewModel created, elapsed=\(String(format: "%.3f", (CFAbsoluteTimeGetCurrent() - prepareStartTime) * 1000))ms", category: .ui)

        // Create the SwiftUI view
        let timelineView = SimpleTimelineView(
            coordinator: coordinator,
            viewModel: viewModel,
            onClose: { [weak self] in
                self?.hide()
            }
        )
        Log.info("[TIMELINE-PRERENDER] 📺 SwiftUI view created, elapsed=\(String(format: "%.3f", (CFAbsoluteTimeGetCurrent() - prepareStartTime) * 1000))ms", category: .ui)

        // Host the SwiftUI view
        let hostingView = FirstMouseHostingView(rootView: timelineView)
        hostingView.frame = window.contentView?.bounds ?? .zero
        hostingView.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(hostingView)
        Log.info("[TIMELINE-PRERENDER] 🎨 Hosting view added, elapsed=\(String(format: "%.3f", (CFAbsoluteTimeGetCurrent() - prepareStartTime) * 1000))ms", category: .ui)

        // Store references
        self.window = window
        self.hostingView = hostingView
        self.preparedScreen = screen

        // Trigger initial layout pass to pre-render the SwiftUI view hierarchy
        // This is the key step that eliminates the delay on show()
        hostingView.layoutSubtreeIfNeeded()
        Log.info("[TIMELINE-PRERENDER] 🔄 Initial layout completed, elapsed=\(String(format: "%.3f", (CFAbsoluteTimeGetCurrent() - prepareStartTime) * 1000))ms", category: .ui)

        // Load the most recent frame data in the background
        Task { @MainActor in
            await viewModel.loadMostRecentFrame()
            Log.info("[TIMELINE-PRERENDER] 📊 Frame data loaded, total elapsed=\(String(format: "%.3f", (CFAbsoluteTimeGetCurrent() - prepareStartTime) * 1000))ms", category: .ui)
        }

        isPrepared = true
        Log.info("[TIMELINE-PRERENDER] ✅ prepareWindow() completed, total=\(String(format: "%.3f", (CFAbsoluteTimeGetCurrent() - prepareStartTime) * 1000))ms", category: .ui)
    }

    // MARK: - Show/Hide

    /// Show the timeline overlay on the current screen
    public func show() {
        guard !isVisible, let coordinator = coordinator else {
            return
        }

        // Remember if dashboard was the key window before we take over
        dashboardWasKeyWindow = DashboardWindowController.shared.isVisible &&
            NSApp.keyWindow == DashboardWindowController.shared.window

        // Get the screen where the mouse cursor is located
        let mouseLocation = NSEvent.mouseLocation
        guard let targetScreen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) }) ?? NSScreen.main else {
            return
        }

        // Check if we have a pre-rendered window ready
        if isPrepared, window != nil, let viewModel = timelineViewModel {
            // Check if we need to move to a different screen
            let needsScreenChange = preparedScreen?.frame != targetScreen.frame
            if needsScreenChange {
                // Recreate the window on the correct screen
                recreateWindowForScreen(targetScreen)
            }

            // Check if cache has expired (2 minutes since last hide)
            // If expired, refresh frame data to show current state
            // If not expired, preserve the exact playhead position
            if let lastHidden = lastHiddenAt {
                let elapsed = Date().timeIntervalSince(lastHidden)
                if elapsed > Self.cacheExpirationSeconds {
                    Task { @MainActor in
                        await viewModel.refreshFrameData()
                    }
                }
            }

            // Show the pre-rendered window
            showPreparedWindow(coordinator: coordinator)
            return
        }

        // Fallback: Create window from scratch (original behavior)
        let window = createWindow(for: targetScreen)

        // Create and store the view model so we can forward scroll events
        let viewModel = SimpleTimelineViewModel(coordinator: coordinator)
        self.timelineViewModel = viewModel

        // Create the SwiftUI view (using new SimpleTimelineView)
        let timelineView = SimpleTimelineView(
            coordinator: coordinator,
            viewModel: viewModel,
            onClose: { [weak self] in
                self?.hide()
            }
        )

        // Host the SwiftUI view (using custom hosting view that accepts first mouse for hover)
        let hostingView = FirstMouseHostingView(rootView: timelineView)
        hostingView.frame = window.contentView?.bounds ?? .zero
        hostingView.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(hostingView)

        // Store references
        self.window = window
        self.hostingView = hostingView
        self.preparedScreen = targetScreen
        self.isPrepared = true

        // Show the window
        showPreparedWindow(coordinator: coordinator)
    }

    /// Show the prepared window with animation and setup event monitors
    private func showPreparedWindow(coordinator: AppCoordinator) {
        guard let window = window else { return }

        window.makeKeyAndOrderFront(nil)

        // Animate in
        window.alphaValue = 0
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
        })

        isVisible = true

        // Track timeline open event
        DashboardViewModel.recordTimelineOpen(coordinator: coordinator)

        // Setup keyboard monitoring
        setupEventMonitors()

        // Notify coordinator to pause frame processing while timeline is visible
        Task {
            await coordinator.setTimelineVisible(true)
        }

        // Post notification so menu bar can hide recording indicator
        NotificationCenter.default.post(name: .timelineDidOpen, object: nil)
    }

    /// Recreate the window on a different screen (for multi-monitor support)
    private func recreateWindowForScreen(_ screen: NSScreen) {
        guard let coordinator = coordinator else { return }

        // Clean up old window
        window?.orderOut(nil)
        hostingView?.removeFromSuperview()

        // Create new window on the target screen
        let newWindow = createWindow(for: screen)
        newWindow.alphaValue = 0
        newWindow.orderOut(nil)

        // Create the view model if needed
        if timelineViewModel == nil {
            timelineViewModel = SimpleTimelineViewModel(coordinator: coordinator)
        }

        guard let viewModel = timelineViewModel else { return }

        // Create new SwiftUI view
        let timelineView = SimpleTimelineView(
            coordinator: coordinator,
            viewModel: viewModel,
            onClose: { [weak self] in
                self?.hide()
            }
        )

        // Host the SwiftUI view
        let newHostingView = FirstMouseHostingView(rootView: timelineView)
        newHostingView.frame = newWindow.contentView?.bounds ?? .zero
        newHostingView.autoresizingMask = [.width, .height]
        newWindow.contentView?.addSubview(newHostingView)

        // Trigger layout
        newHostingView.layoutSubtreeIfNeeded()

        // Store references
        self.window = newWindow
        self.hostingView = newHostingView
        self.preparedScreen = screen
    }

    /// Hide the timeline overlay
    public func hide() {
        guard isVisible, let window = window else { return }

        // Don't save position on hide - window stays in memory
        // Position is only saved on app termination (see savePositionForTermination)

        // Remove event monitors
        removeEventMonitors()

        // Animate out
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                // Only hide dashboard if it wasn't the active window before timeline opened
                // This prevents hiding the dashboard when user had it focused and just opened/closed timeline
                if self?.dashboardWasKeyWindow != true {
                    DashboardWindowController.shared.hide()
                }

                // Hide window but keep it around for instant re-show
                // This is the key optimization - we don't destroy the window or view model
                window.orderOut(nil)
                self?.isVisible = false
                self?.lastHiddenAt = Date()  // Track when hidden for cache expiry
                self?.onClose?()

                // Reset the cached scale factor so it recalculates for next window
                TimelineScaleFactor.resetCache()

                // Notify coordinator to resume frame processing
                if let coordinator = self?.coordinator {
                    await coordinator.setTimelineVisible(false)
                }

                // Post notification so menu bar can restore recording indicator
                NotificationCenter.default.post(name: .timelineDidClose, object: nil)
            }
        })
    }

    /// Save the current position for cross-session persistence (call on app termination)
    public func savePositionForTermination() {
        Log.info("[TIMELINE-PRERENDER] 💾 savePositionForTermination() called", category: .ui)
        timelineViewModel?.savePosition()
    }

    /// Completely destroy the pre-rendered window (call when memory pressure is high or app is terminating)
    public func destroyPreparedWindow() {
        Log.info("[TIMELINE-PRERENDER] 🗑️ destroyPreparedWindow() called", category: .ui)
        // Save position before destroying for cross-session persistence
        timelineViewModel?.savePosition()

        window?.orderOut(nil)
        hostingView?.removeFromSuperview()
        window = nil
        hostingView = nil
        timelineViewModel = nil
        isPrepared = false
        preparedScreen = nil
    }

    /// Toggle timeline visibility
    public func toggle() {
        if isVisible {
            hide()
        } else {
            show()
        }
    }

    /// Show the timeline and navigate to a specific date
    public func showAndNavigate(to date: Date) {
        show()

        // Navigate after a brief delay to allow the view to initialize
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000) // 0.3 seconds
            await timelineViewModel?.navigateToHour(date)
        }
    }

    // MARK: - Window Creation

    private func createWindow(for screen: NSScreen) -> NSWindow {
        // Use custom window subclass that can become key even when borderless
        let window = KeyableWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        // Configure window properties
        window.level = .screenSaver
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = false
        window.acceptsMouseMovedEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        // Make it cover the entire screen including menu bar
        window.setFrame(screen.frame, display: true)

        // Create content view with dark background
        let contentView = NSView(frame: screen.frame)
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.95).cgColor
        window.contentView = contentView

        return window
    }

    // MARK: - Event Monitoring

    private func setupEventMonitors() {
        // Monitor for escape key and toggle shortcut (global)
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .scrollWheel, .magnify]) { [weak self] event in
            if event.type == .keyDown {
                self?.handleKeyEvent(event)
            } else if event.type == .scrollWheel {
                // Don't handle scroll events when search overlay, filter dropdown, or tag submenu is open
                if let viewModel = self?.timelineViewModel,
                   (viewModel.isSearchOverlayVisible || viewModel.isFilterDropdownOpen || viewModel.showTagSubmenu) {
                    return // Let SwiftUI handle it
                }
                self?.handleScrollEvent(event, source: "GLOBAL")
            } else if event.type == .magnify {
                self?.handleMagnifyEvent(event)
            }
        }

        // Also monitor local events (when our window is key)
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .scrollWheel, .magnify]) { [weak self] event in
            if event.type == .keyDown {
                // Check if a text field is currently active
                let isTextFieldActive: Bool
                if let window = self?.window,
                   let firstResponder = window.firstResponder {
                    isTextFieldActive = firstResponder is NSTextView || firstResponder is NSTextField
                } else {
                    isTextFieldActive = false
                }

                // Always handle certain shortcuts even when text field is active
                let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])

                // Cmd+F to toggle search overlay
                if event.keyCode == 3 && modifiers == [.command] { // Cmd+F
                    if self?.handleKeyEvent(event) == true {
                        return nil // Consume the event
                    }
                }

                // Cmd+=/+ to zoom in (handle before system can intercept)
                if (event.keyCode == 24 || event.keyCode == 69) && (modifiers == [.command] || modifiers == [.command, .shift]) {
                    if self?.handleKeyEvent(event) == true {
                        return nil // Consume the event
                    }
                }

                // Cmd+- to zoom out (handle before system can intercept)
                if (event.keyCode == 27 || event.keyCode == 78) && modifiers == [.command] {
                    if self?.handleKeyEvent(event) == true {
                        return nil // Consume the event
                    }
                }

                // Cmd+0 to reset zoom (handle before system can intercept)
                if event.keyCode == 29 && (modifiers == [.command] || modifiers == [.control]) {
                    if self?.handleKeyEvent(event) == true {
                        return nil // Consume the event
                    }
                }

                // For other keys, let text field handle them if it's active
                if isTextFieldActive {
                    return event // Let the text field handle it
                }

                if self?.handleKeyEvent(event) == true {
                    return nil // Consume the event
                }
            } else if event.type == .scrollWheel {
                // Don't intercept scroll events when search overlay is visible
                // Let SwiftUI ScrollView handle them for scrolling through results
                if let viewModel = self?.timelineViewModel, viewModel.isSearchOverlayVisible {
                    return event // Let the ScrollView handle it
                }
                // Don't intercept scroll events when a filter dropdown is open
                // Let SwiftUI ScrollView handle them for scrolling through the dropdown list
                if let viewModel = self?.timelineViewModel, viewModel.isFilterDropdownOpen {
                    return event // Let the dropdown ScrollView handle it
                }
                // Don't intercept scroll events when the tag submenu is open
                // Let SwiftUI ScrollView handle them for scrolling through tags
                if let viewModel = self?.timelineViewModel, viewModel.showTagSubmenu {
                    return event // Let the tag submenu ScrollView handle it
                }
                self?.handleScrollEvent(event, source: "LOCAL")
                return nil // Consume scroll events
            } else if event.type == .magnify {
                self?.handleMagnifyEvent(event)
                return nil // Consume magnify events
            }
            return event
        }
    }

    private func removeEventMonitors() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        if let monitor = localEventMonitor {
            NSEvent.removeMonitor(monitor)
            localEventMonitor = nil
        }
    }

    @discardableResult
    private func handleKeyEvent(_ event: NSEvent) -> Bool {
        // Don't handle escape if a modal panel (save panel, etc.) is open
        if NSApp.modalWindow != nil {
            return false
        }

        // Don't handle escape if our window is not the key window (e.g., save panel is open)
        if let keyWindow = NSApp.keyWindow, keyWindow != window {
            return false
        }

        // Escape key - cascading behavior based on current state
        if event.keyCode == 53 { // Escape
            if let viewModel = timelineViewModel {
                // If currently dragging to create zoom region, cancel the drag
                if viewModel.isDraggingZoomRegion {
                    viewModel.cancelZoomRegionDrag()
                    return true
                }
                // If calendar picker is showing, close it first with animation
                if viewModel.isCalendarPickerVisible {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                        viewModel.isCalendarPickerVisible = false
                        viewModel.hoursWithFrames = []
                        viewModel.selectedCalendarDate = nil
                    }
                    return true
                }
                // If zoom slider is expanded, collapse it
                if viewModel.isZoomSliderExpanded {
                    withAnimation(.easeOut(duration: 0.12)) {
                        viewModel.isZoomSliderExpanded = false
                    }
                    return true
                }
                // If date search is active, close it with animation
                if viewModel.isDateSearchActive {
                    viewModel.closeDateSearch()
                    return true
                }
                // If search overlay is showing, close it
                if viewModel.isSearchOverlayVisible {
                    viewModel.isSearchOverlayVisible = false
                    return true
                }
                // If search highlight is showing, clear it
                if viewModel.isShowingSearchHighlight {
                    viewModel.clearSearchHighlight()
                    return true
                }
                // If delete confirmation is showing, cancel it
                if viewModel.showDeleteConfirmation {
                    viewModel.cancelDelete()
                    return true
                }
                // If zoom region is active, exit zoom mode
                if viewModel.isZoomRegionActive {
                    viewModel.exitZoomRegion()
                    return true
                }
                // If text selection is active, clear it
                if viewModel.hasSelection {
                    viewModel.clearTextSelection()
                    return true
                }
                // If filter panel is visible with open dropdown, let the panel handle it
                if viewModel.isFilterPanelVisible && viewModel.isFilterDropdownOpen {
                    // The FilterPanel's NSEvent monitor will handle this
                    return false
                }
                // If filter panel is visible (no dropdown), close it
                if viewModel.isFilterPanelVisible {
                    withAnimation(.easeOut(duration: 0.15)) {
                        viewModel.dismissFilterPanel()
                    }
                    return true
                }
            }
            // Otherwise close the timeline
            hide()
            return true
        }

        // Check if it's the toggle shortcut (uses saved shortcut config)
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let shortcutConfig = loadTimelineShortcut()
        let expectedKeyCode = keyCodeForString(shortcutConfig.key)
        if event.keyCode == expectedKeyCode && modifiers == shortcutConfig.modifiers.nsModifiers {
            hide()
            return true
        }

        // Cmd+G to toggle date search panel ("Go to" date)
        if event.keyCode == 5 && modifiers == [.command] { // G key with Command
            if let viewModel = timelineViewModel {
                viewModel.toggleDateSearch()
            }
            return true
        }

        // Cmd+F to toggle search overlay
        if event.keyCode == 3 && modifiers == [.command] { // F key with Command
            if let viewModel = timelineViewModel {
                let wasVisible = viewModel.isSearchOverlayVisible
                viewModel.isSearchOverlayVisible.toggle()
                // Clear search highlight asynchronously when opening search overlay
                if !wasVisible {
                    Task { @MainActor in
                        viewModel.clearSearchHighlight()
                    }
                }
            }
            return true
        }

        // Delete or Backspace key to delete selected frame
        if (event.keyCode == 51 || event.keyCode == 117) && modifiers.isEmpty { // Backspace (51) or Delete (117)
            if let viewModel = timelineViewModel, viewModel.selectedFrameIndex != nil {
                viewModel.requestDeleteSelectedFrame()
                return true
            }
        }

        // Handle delete confirmation dialog keyboard shortcuts
        if let viewModel = timelineViewModel, viewModel.showDeleteConfirmation {
            // Enter/Return confirms deletion
            if event.keyCode == 36 || event.keyCode == 76 { // Return (36) or Enter (76)
                viewModel.confirmDeleteSelectedFrame()
                return true
            }
            // Escape cancels (handled above, but also catch it here for the dialog)
            if event.keyCode == 53 { // Escape
                viewModel.cancelDelete()
                return true
            }
        }

        // Cmd+A to select all text on the frame
        if event.keyCode == 0 && modifiers == [.command] { // A key with Command
            if let viewModel = timelineViewModel {
                viewModel.selectAllText()
                return true
            }
        }

        // Cmd+C to copy selected text
        if event.keyCode == 8 && modifiers == [.command] { // C key with Command
            if let viewModel = timelineViewModel, viewModel.hasSelection {
                viewModel.copySelectedText()
                return true
            }
        }

        // Cmd+. (period) to toggle timeline controls visibility
        if event.keyCode == 47 && modifiers == [.command] { // Period key with Command
            if let viewModel = timelineViewModel {
                viewModel.toggleControlsVisibility()
                return true
            }
        }

        // Left arrow key - navigate to previous frame (Option = 3x speed)
        if event.keyCode == 123 && (modifiers.isEmpty || modifiers == [.option]) { // Left arrow
            if let viewModel = timelineViewModel {
                let step = modifiers.contains(.option) ? 3 : 1
                viewModel.navigateToFrame(viewModel.currentIndex - step)
                return true
            }
        }

        // Right arrow key - navigate to next frame (Option = 3x speed)
        if event.keyCode == 124 && (modifiers.isEmpty || modifiers == [.option]) { // Right arrow
            if let viewModel = timelineViewModel {
                let step = modifiers.contains(.option) ? 3 : 1
                viewModel.navigateToFrame(viewModel.currentIndex + step)
                return true
            }
        }

        // Ctrl+0 to reset frame zoom to 100%
        if event.keyCode == 29 && modifiers == [.control] { // 0 key with Control
            if let viewModel = timelineViewModel, viewModel.isFrameZoomed {
                viewModel.resetFrameZoom()
                return true
            }
        }

        // Cmd+0 to reset frame zoom to 100% (alternative shortcut)
        if event.keyCode == 29 && modifiers == [.command] { // 0 key with Command
            if let viewModel = timelineViewModel, viewModel.isFrameZoomed {
                viewModel.resetFrameZoom()
                return true
            }
        }

        // Cmd++ (Cmd+=) to zoom in frame
        // Key code 24 is '=' which is '+' with shift, but Cmd+= works as zoom in
        if (event.keyCode == 24 || event.keyCode == 69) && (modifiers == [.command] || modifiers == [.command, .shift]) {
            if let viewModel = timelineViewModel {
                viewModel.applyMagnification(1.25, animated: true) // Zoom in by 25%
                return true
            }
        }

        // Cmd+- to zoom out frame
        if (event.keyCode == 27 || event.keyCode == 78) && modifiers == [.command] { // - key (main or numpad)
            if let viewModel = timelineViewModel {
                viewModel.applyMagnification(0.8, animated: true) // Zoom out by 20%
                return true
            }
        }

        // Any other key (not a modifier) clears text selection
        if let viewModel = timelineViewModel,
           viewModel.hasSelection,
           !event.modifierFlags.contains(.command),
           !event.modifierFlags.contains(.option),
           !event.modifierFlags.contains(.control),
           event.keyCode != 53 { // Don't clear on Escape (handled above)
            // Only clear for non-navigation keys
            let navigationKeys: Set<UInt16> = [123, 124, 125, 126] // Arrow keys
            if !navigationKeys.contains(event.keyCode) {
                viewModel.clearTextSelection()
            }
        }

        return false
    }

    private func handleScrollEvent(_ event: NSEvent, source: String) {
        guard isVisible, let viewModel = timelineViewModel else { return }

        let deltaX = event.scrollingDeltaX
        let deltaY = event.scrollingDeltaY

        // Use horizontal scrolling primarily, fall back to vertical
        let delta = abs(deltaX) > abs(deltaY) ? -deltaX : -deltaY

        if abs(delta) > 0.1 {
            onScroll?(delta)
            // Forward scroll to view model
            Task { @MainActor in
                await viewModel.handleScroll(delta: CGFloat(delta))
            }
        }
    }

    private func handleMagnifyEvent(_ event: NSEvent) {
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

    // MARK: - Key Code Mapping

    private func keyCodeForString(_ key: String) -> UInt16 {
        switch key.lowercased() {
        case "space": return 49
        case "return", "enter": return 36
        case "tab": return 48
        case "escape", "esc": return 53
        case "delete", "backspace": return 51
        case "left", "leftarrow", "←": return 123
        case "right", "rightarrow", "→": return 124
        case "down", "downarrow", "↓": return 125
        case "up", "uparrow", "↑": return 126

        // Letters
        case "a": return 0
        case "b": return 11
        case "c": return 8
        case "d": return 2
        case "e": return 14
        case "f": return 3
        case "g": return 5
        case "h": return 4
        case "i": return 34
        case "j": return 38
        case "k": return 40
        case "l": return 37
        case "m": return 46
        case "n": return 45
        case "o": return 31
        case "p": return 35
        case "q": return 12
        case "r": return 15
        case "s": return 1
        case "t": return 17
        case "u": return 32
        case "v": return 9
        case "w": return 13
        case "x": return 7
        case "y": return 16
        case "z": return 6

        // Numbers
        case "0": return 29
        case "1": return 18
        case "2": return 19
        case "3": return 20
        case "4": return 21
        case "5": return 23
        case "6": return 22
        case "7": return 26
        case "8": return 28
        case "9": return 25

        default: return 0
        }
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let timelineDidOpen = Notification.Name("timelineDidOpen")
    static let timelineDidClose = Notification.Name("timelineDidClose")
    static let navigateTimelineToDate = Notification.Name("navigateTimelineToDate")
}

// MARK: - Custom Window for Text Input Support

/// Custom NSWindow subclass that can become key window even when borderless
/// This is required for text fields to receive keyboard input properly
class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Custom hosting view that accepts first mouse to enable hover on first interaction
class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    required init(rootView: Content) {
        super.init(rootView: rootView)
    }

    @MainActor @preconcurrency required dynamic init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }
}
