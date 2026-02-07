import AppKit
import SwiftUI
import App
import Shared
import CoreGraphics

/// Manages the full-screen timeline overlay window
/// This is a singleton that can be triggered from anywhere via keyboard shortcut
@MainActor
public class TimelineWindowController: NSObject {

    // MARK: - Singleton

    public static let shared = TimelineWindowController()

    // MARK: - Performance Tracking

    /// Tracks timing from hotkey press to animation complete
    private var showStartTime: CFAbsoluteTime = 0

    /// Path to the performance log file
    private static let perfLogPath = URL(fileURLWithPath: "/tmp/retrace_timeline_perf.log")

    // MARK: - Session Duration Tracking

    /// Tracks when the timeline was opened for duration tracking
    private var sessionStartTime: Date?
    private var sessionScrubDistance: Double = 0

    /// Log detailed timing breakdown for timeline show (writes to temp file)
    private func logShowTiming(_ checkpoint: String) {
        guard showStartTime > 0 else { return }
        let elapsed = (CFAbsoluteTimeGetCurrent() - showStartTime) * 1000
        let line = "[\(Log.timestamp())] \(checkpoint): \(String(format: "%.1f", elapsed))ms\n"

        // Append to file
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: Self.perfLogPath.path) {
                if let handle = try? FileHandle(forWritingTo: Self.perfLogPath) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                try? data.write(to: Self.perfLogPath)
            }
        }
    }

    /// Start a new performance trace (clears previous entries and logs header)
    private func startPerfTrace() {
        showStartTime = CFAbsoluteTimeGetCurrent()
        let header = "\n--- Timeline Show @ \(Log.timestamp()) ---\n"
        try? header.data(using: .utf8)?.write(to: Self.perfLogPath)
        Log.info("[TIMELINE-PERF] ⏱️ Logging to: \(Self.perfLogPath.path)", category: .ui)
    }

    // MARK: - Properties

    private var window: NSWindow?
    private var coordinator: AppCoordinator?
    private var coordinatorWrapper: AppCoordinatorWrapper?
    private var eventMonitor: Any?
    private var localEventMonitor: Any?
    private var mouseEventMonitor: Any?  // Debug monitor for shift-drag investigation
    private var timelineViewModel: SimpleTimelineViewModel?
    private var hostingView: NSView?
    private var tapeShowAnimationTask: Task<Void, Never>?
    private var isHiding = false

    // MARK: - Emergency Escape (CGEvent tap for when main thread is blocked)

    /// CGEvent tap for emergency escape - runs on a dedicated background thread
    /// This allows closing the timeline even when the main thread is frozen
    private nonisolated(unsafe) static var emergencyEventTap: CFMachPort?
    private nonisolated(unsafe) static var emergencyRunLoopSource: CFRunLoopSource?
    private nonisolated(unsafe) static var emergencyRunLoop: CFRunLoop?
    private nonisolated(unsafe) static var isTimelineVisible: Bool = false
    /// Whether a dialog/overlay is open that uses escape to close (search, filter, etc.)
    private nonisolated(unsafe) static var isDialogOpen: Bool = false
    /// Track escape key timestamps for triple-escape detection
    private nonisolated(unsafe) static var escapeTimestamps: [CFAbsoluteTime] = []

    /// Whether the window has been pre-rendered and is ready to show
    private var isPrepared = false

    /// When the timeline was last hidden (for cache expiry check)
    private var lastHiddenAt: Date?

    /// Cached live screenshot for instant toggle without re-capture
    private var cachedLiveScreenshot: NSImage?

    /// Timer that periodically refreshes timeline data in the background
    private var backgroundRefreshTimer: Timer?

    /// Whether the timeline overlay is currently visible
    public private(set) var isVisible = false

    /// Whether the dashboard was the key window when timeline opened
    private var dashboardWasKeyWindow = false

    /// Whether the timeline is hiding to show dashboard/settings (don't auto-hide dashboard in this case)
    private var isHidingToShowDashboard = false

    /// Callback when timeline closes
    public var onClose: (() -> Void)?

    /// Callback for scroll events (delta value)
    public var onScroll: ((Double) -> Void)?

    // MARK: - Tape Click-Drag State

    /// Whether the user is currently click-dragging the timeline tape
    private var isTapeDragging = false

    /// The last mouse X position during a tape drag (in window coordinates)
    private var tapeDragLastX: CGFloat = 0

    /// The mouse X position where the tape drag started (for minimum distance threshold)
    private var tapeDragStartX: CGFloat = 0

    /// Whether drag has passed the minimum distance threshold to be considered a drag (vs a click)
    private var tapeDragDidExceedThreshold = false

    /// Minimum pixel distance before a mouseDown+mouseDragged is treated as a drag (not a tap)
    private static let tapeDragMinDistance: CGFloat = 3.0

    /// Recent drag samples for velocity calculation (timestamp, deltaX)
    private var tapeDragVelocitySamples: [(time: CFAbsoluteTime, delta: CGFloat)] = []

    /// Maximum age of velocity samples to consider (seconds)
    private static let velocitySampleWindow: CFAbsoluteTime = 0.08

    // MARK: - Initialization

    private override init() {
        super.init()
        setupEmergencyEscapeTap()
    }

    // MARK: - Emergency Escape CGEvent Tap

    /// Sets up a CGEvent tap on a background thread to handle Escape key
    /// This works even when the main thread is completely frozen
    private func setupEmergencyEscapeTap() {
        DispatchQueue.global(qos: .userInteractive).async {
            // Create event tap for key down events
            let eventMask = (1 << CGEventType.keyDown.rawValue)

            guard let eventTap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: CGEventMask(eventMask),
                callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                    // Only process if timeline is visible
                    guard TimelineWindowController.isTimelineVisible else {
                        return Unmanaged.passRetained(event)
                    }

                    // Check for Escape key (keycode 53) or Cmd+Option+Escape
                    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                    let flags = event.flags

                    let isCmdOptEscape = keyCode == 53 &&
                        flags.contains(.maskCommand) &&
                        flags.contains(.maskAlternate)

                    // Cmd+Option+Escape: EMERGENCY - terminate app immediately
                    if isCmdOptEscape {
                        TimelineWindowController.isTimelineVisible = false
                        exit(0)
                    }

                    // Track escape presses for triple-escape detection
                    // Skip if a dialog is open (search, filter, tag submenu) since escape closes those
                    if keyCode == 53 &&
                       flags.rawValue & (CGEventFlags.maskCommand.rawValue | CGEventFlags.maskAlternate.rawValue | CGEventFlags.maskControl.rawValue) == 0 &&
                       !TimelineWindowController.isDialogOpen {
                        let now = CFAbsoluteTimeGetCurrent()

                        // Remove old timestamps (older than 1.5 seconds)
                        TimelineWindowController.escapeTimestamps = TimelineWindowController.escapeTimestamps.filter { now - $0 < 1.5 }

                        // Add current timestamp
                        TimelineWindowController.escapeTimestamps.append(now)

                        // Check for triple-escape (3 presses within 1.5 seconds)
                        if TimelineWindowController.escapeTimestamps.count >= 3 {
                            TimelineWindowController.escapeTimestamps.removeAll()
                            TimelineWindowController.isTimelineVisible = false
                            exit(0)  // Force quit immediately
                        }
                    }

                    return Unmanaged.passRetained(event)
                },
                userInfo: nil
            ) else {
                Log.error("[TIMELINE] Failed to create emergency escape event tap - check accessibility permissions", category: .ui)
                return
            }

            TimelineWindowController.emergencyEventTap = eventTap

            // Create run loop source
            let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
            TimelineWindowController.emergencyRunLoopSource = runLoopSource

            // Get current run loop for this thread
            let runLoop = CFRunLoopGetCurrent()
            TimelineWindowController.emergencyRunLoop = runLoop

            // Add to run loop
            CFRunLoopAddSource(runLoop, runLoopSource, .commonModes)

            // Enable the tap
            CGEvent.tapEnable(tap: eventTap, enable: true)

            Log.info("[TIMELINE] Emergency escape event tap installed on background thread", category: .ui)

            // Run the loop (this blocks the thread, keeping it alive)
            CFRunLoopRun()
        }
    }

    /// Update whether a dialog/overlay is open (search, filter, tag submenu, etc.)
    /// This prevents triple-escape from triggering while dialogs are open
    public func setDialogOpen(_ isOpen: Bool) {
        Self.isDialogOpen = isOpen
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
        self.coordinatorWrapper = AppCoordinatorWrapper(coordinator: coordinator)
        // Pre-render the window in the background for instant show()
        Task { @MainActor in
            // Small delay to let app finish launching
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
            prepareWindow()
        }

        // Listen for display changes to reposition the hidden window
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDisplayChange(_:)),
            name: .activeDisplayDidChange,
            object: nil
        )

        // Listen for dashboard/settings shortcuts to properly hide timeline first
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleToggleDashboard(_:)),
            name: .toggleDashboard,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleOpenSettings(_:)),
            name: .openSettings,
            object: nil
        )
    }

    /// Handle toggle dashboard notification - if timeline is visible, hide it first
    @objc private func handleToggleDashboard(_ notification: Notification) {
        guard isVisible else { return }
        // Timeline is visible, so hide it properly before showing dashboard
        hideToShowDashboard()
    }

    /// Handle open settings notification - if timeline is visible, hide it first
    @objc private func handleOpenSettings(_ notification: Notification) {
        guard isVisible else { return }
        // Timeline is visible, so hide it properly before showing settings
        hideToShowDashboard()
    }

    /// Handle active display change - move hidden window to new screen
    @objc private func handleDisplayChange(_ notification: Notification) {
        moveWindowToMouseScreen()
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

        // Get the main screen for pre-rendering (will move to target screen on show)
        guard let screen = NSScreen.main else {
            Log.info("[TIMELINE-PRERENDER] ⚠️ prepareWindow() skipped - no main screen", category: .ui)
            return
        }
        Log.info("[TIMELINE-PRERENDER] 📺 Using screen: \(screen.frame)", category: .ui)

        // Create the window (hidden)
        let window = createWindow(for: screen)
        window.alphaValue = 0
        // CRITICAL: Ignore mouse events while hidden to prevent blocking clicks on other windows
        window.ignoresMouseEvents = true
        window.orderOut(nil)
        Log.info("[TIMELINE-PRERENDER] 🪟 Window created (hidden), elapsed=\(String(format: "%.3f", (CFAbsoluteTimeGetCurrent() - prepareStartTime) * 1000))ms", category: .ui)

        // Create the view model
        let viewModel = SimpleTimelineViewModel(coordinator: coordinator)
        self.timelineViewModel = viewModel
        // Pre-set tape as hidden so view renders with tape off-screen initially
        viewModel.isTapeHidden = true
        Log.info("[TIMELINE-PRERENDER] 📊 ViewModel created, elapsed=\(String(format: "%.3f", (CFAbsoluteTimeGetCurrent() - prepareStartTime) * 1000))ms", category: .ui)

        // Create the SwiftUI view
        guard let coordinatorWrapper = coordinatorWrapper else {
            Log.error("[TIMELINE-PRERENDER] Coordinator wrapper not initialized", category: .ui)
            return
        }

        let timelineView = SimpleTimelineView(
            coordinator: coordinator,
            viewModel: viewModel,
            onClose: { [weak self] in
                self?.hide()
            }
        )
        .environmentObject(coordinatorWrapper)
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
        
        // Trigger initial layout pass to pre-render the SwiftUI view hierarchy
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
        // Start performance tracking
        startPerfTrace()

        // If we're in the middle of hiding, cancel the animation and snap back to visible
        if isHiding, let window = window {
            isHiding = false
            // Cancel any running animation by setting duration to 0
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0
                window.animator().alphaValue = 1
            })
            isVisible = true
            Self.isTimelineVisible = true
            logShowTiming("cancelled hide, snapping back to visible")
            return
        }

        guard !isVisible, let coordinator = coordinator else {
            return
        }
        logShowTiming("guard passed")

        // Only capture/use live screenshot if playhead is at or near the latest frame (last 2 frames)
        // Otherwise, user was viewing a historical frame and should see that instead
        let shouldUseLiveMode = timelineViewModel?.isNearMostRecentFrame(within: 2) ?? true

        let liveScreenshot: NSImage?
        if shouldUseLiveMode {
            // Always capture fresh screenshot
            liveScreenshot = captureLiveScreenshot()
            logShowTiming("live screenshot captured")
        } else {
            liveScreenshot = nil
            logShowTiming("skipped live screenshot - playhead not at latest frame")
        }

        // Remember if dashboard was the key window before we take over
        dashboardWasKeyWindow = DashboardWindowController.shared.isVisible &&
            NSApp.keyWindow == DashboardWindowController.shared.window

        // Get the screen where the mouse cursor is located
        let mouseLocation = NSEvent.mouseLocation
        guard let targetScreen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) }) ?? NSScreen.main else {
            return
        }
        logShowTiming("screen detected")

        // Reset scale factor cache so it recalculates for the current display
        TimelineScaleFactor.resetCache()

	        // Don't stop the background refresh timer - let it keep running
	        // The timer callback checks isVisible and skips refresh while timeline is open

        // Check if we have a pre-rendered window ready
        if isPrepared, let window = window, let viewModel = timelineViewModel {
            logShowTiming("using prerendered window")

            // Set live mode with captured screenshot
            if let screenshot = liveScreenshot {
                viewModel.isInLiveMode = true
                viewModel.liveScreenshot = screenshot
                logShowTiming("live mode activated")
                // Auto-trigger OCR on the live screenshot
                viewModel.performLiveOCR()
            }
            viewModel.isTapeHidden = true
            tapeShowAnimationTask?.cancel()

            // Move window to target screen if needed (instant, no recreation)
            if window.frame != targetScreen.frame {
                window.setFrame(targetScreen.frame, display: false)
                logShowTiming("moved window to target screen")
            }

            // Log cache state
            if let lastHidden = lastHiddenAt {
                let elapsed = Date().timeIntervalSince(lastHidden)
                Log.info("[TIMELINE-SHOW] Using prerendered view (hidden \(Int(elapsed))s ago)", category: .ui)
            } else {
                Log.info("[TIMELINE-SHOW] First show after prerender", category: .ui)
            }

            // Show the pre-rendered window
            showPreparedWindow(coordinator: coordinator)
            return
        }
        logShowTiming("no prerendered window, creating new")

        // Fallback: Create window from scratch (original behavior)
	        Log.info("[TIMELINE-SHOW] ⚠️ Using FALLBACK path - creating new window and viewModel from scratch", category: .ui)
	        let newWindow = createWindow(for: targetScreen)

	        // Create and store the view model so we can forward scroll events
        let viewModel = SimpleTimelineViewModel(coordinator: coordinator)
        self.timelineViewModel = viewModel
        viewModel.isTapeHidden = true
        tapeShowAnimationTask?.cancel()

        // Set live mode with captured screenshot
        if let screenshot = liveScreenshot {
            viewModel.isInLiveMode = true
            viewModel.liveScreenshot = screenshot
            logShowTiming("live mode activated (fallback)")
            // Auto-trigger OCR on the live screenshot
            viewModel.performLiveOCR()
        }

        guard let coordinatorWrapper = coordinatorWrapper else {
            Log.error("[TIMELINE] Coordinator wrapper not initialized", category: .ui)
            return
        }

        // Create the SwiftUI view (using new SimpleTimelineView)
        let timelineView = SimpleTimelineView(
            coordinator: coordinator,
            viewModel: viewModel,
            onClose: { [weak self] in
                self?.hide()
            }
        )
        .environmentObject(coordinatorWrapper)

        // Host the SwiftUI view (using custom hosting view that accepts first mouse for hover)
        let hostingView = FirstMouseHostingView(rootView: timelineView)
        hostingView.frame = newWindow.contentView?.bounds ?? .zero
        hostingView.autoresizingMask = [.width, .height]
        newWindow.contentView?.addSubview(hostingView)

        // Store references
        self.window = newWindow
        self.hostingView = hostingView
        self.isPrepared = true

        // Show the window
        showPreparedWindow(coordinator: coordinator)

        // Start async frame loading in background (non-blocking)
        Task {
            await viewModel.loadMostRecentFrame()
            logShowTiming("background frame load complete (fallback)")
        }
    }

    /// Show the prepared window with animation and setup event monitors
    private func showPreparedWindow(coordinator: AppCoordinator) {
        logShowTiming("showPreparedWindow started")
        guard let window = window else { return }

        // Reattach SwiftUI view if it was detached (on hide, we remove it from superview to stop display cycle)
        if let hostingView = hostingView, hostingView.superview == nil {
            hostingView.frame = window.contentView?.bounds ?? .zero
            window.contentView?.addSubview(hostingView)
            hostingView.layoutSubtreeIfNeeded()
            logShowTiming("hosting view reattached")
            // Force SwiftUI to re-read all @Published properties from the view model.
            // While detached, SwiftUI missed objectWillChange notifications,
            // so the timeline tape may show stale/empty state.
            timelineViewModel?.objectWillChange.send()
        }

        timelineViewModel?.isTapeHidden = true
        tapeShowAnimationTask?.cancel()

        // Log current view model state before showing
        if let viewModel = timelineViewModel {
            let currentVideoInfo = viewModel.currentVideoInfo
            Log.info("[TIMELINE-SHOW] 🎬 About to show window - currentIndex=\(viewModel.currentIndex), frames.count=\(viewModel.frames.count), videoPath=\(currentVideoInfo?.videoPath.suffix(30) ?? "nil"), frameIndex=\(currentVideoInfo?.frameIndex ?? -1)", category: .ui)
        }

        // Force video reload BEFORE showing window to avoid flicker
        // This ensures AVPlayer loads fresh video data with any new frames
        // Skip this when in live mode since we're showing a live screenshot instead
        if let viewModel = timelineViewModel, !viewModel.isInLiveMode, viewModel.frames.count > 1 {
            viewModel.forceVideoReload = true
            let original = viewModel.currentIndex
            viewModel.currentIndex = max(0, original - 1)
            viewModel.currentIndex = original
        }
        logShowTiming("video reload triggered")

        let isLive = (timelineViewModel?.isInLiveMode ?? false) && timelineViewModel?.liveScreenshot != nil
        window.alphaValue = isLive ? 1 : 0

        // Re-enable mouse events before showing (was disabled while hidden to prevent blocking clicks)
        window.ignoresMouseEvents = false

        Log.info("[TIMELINE-SHOW] 🚀 WINDOW BECOMING VISIBLE NOW (makeKeyAndOrderFront)", category: .ui)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        logShowTiming("makeKeyAndOrderFront")

        isVisible = true
        Self.isTimelineVisible = true  // For emergency escape tap

        // Log display/screen info for debugging cross-display zoom issues
        let mousePos = NSEvent.mouseLocation
        let screenIndex = NSScreen.screens.firstIndex(where: { NSMouseInRect(mousePos, $0.frame, false) }) ?? -1
        let windowScreen = window.screen?.frame ?? .zero
        let scaleFactor = TimelineScaleFactor.current
        let screenBackingScale = window.screen?.backingScaleFactor ?? -1
        debugLog("[TIMELINE-LAUNCH] display: \(screenIndex), mouse: (\(Int(mousePos.x)),\(Int(mousePos.y))), windowFrame: \(Int(windowScreen.width))x\(Int(windowScreen.height)), isKeyWindow: \(window.isKeyWindow), zoomScale: \(timelineViewModel?.frameZoomScale ?? -1), timelineScaleFactor: \(String(format: "%.3f", scaleFactor)), backingScale: \(screenBackingScale)")

        // Fade in only for non-live opens (prevents the live screenshot "zoom" feel)
        if !isLive {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.35
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                window.animator().alphaValue = 1
            })
        }

        // Trigger tape slide-up animation (Cmd+H style)
        tapeShowAnimationTask = Task { @MainActor in
            await Task.yield()
            guard let viewModel = self.timelineViewModel, !Task.isCancelled else { return }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                viewModel.isTapeHidden = false
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

        // Post notification so menu bar can hide recording indicator
        NotificationCenter.default.post(name: .timelineDidOpen, object: nil)
    }

    /// Hide the timeline overlay
    public func hide() {
        guard isVisible, let window = window, !isHiding else { return }
        isHiding = true

        // Record timeline session duration (only if > 3 seconds)
        if let startTime = sessionStartTime, let coordinator = coordinator {
            let durationMs = Int64(Date().timeIntervalSince(startTime) * 1000)
            DashboardViewModel.recordTimelineSession(coordinator: coordinator, durationMs: durationMs)

            // Record scrub distance metric
            if sessionScrubDistance > 0 {
                DashboardViewModel.recordScrubDistance(coordinator: coordinator, distancePixels: sessionScrubDistance)
            }

            sessionStartTime = nil
            sessionScrubDistance = 0  // Reset scrub distance for next session
        }

        // Don't save position on hide - window stays in memory
        // Position is only saved on app termination (see savePositionForTermination)

        // Cancel any running fade-in animation before starting fade-out
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0
            window.animator().alphaValue = window.alphaValue  // Snap to current value
        })

        tapeShowAnimationTask?.cancel()
        if let viewModel = timelineViewModel {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                viewModel.isTapeHidden = true
            }
        }

        // Remove event monitors
        removeEventMonitors()

        // Animate out
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                self?.isHiding = false
                // Only hide dashboard if it wasn't the active window before timeline opened
                // AND we're not hiding specifically to show the dashboard/settings
                // This prevents hiding the dashboard when user had it focused and just opened/closed timeline
                // Also don't hide if a modal sheet (feedback form, etc.) is attached
                if self?.dashboardWasKeyWindow != true,
                   self?.isHidingToShowDashboard != true,
                   DashboardWindowController.shared.window?.attachedSheet == nil {
                    DashboardWindowController.shared.hide()
                }
                // Reset the flag after use
                self?.isHidingToShowDashboard = false

                // Hide window but keep it around for instant re-show
                // This is the key optimization - we don't destroy the window or view model
                // CRITICAL: Ignore mouse events while hidden to prevent blocking clicks on other windows
                window.ignoresMouseEvents = true
                window.orderOut(nil)
                // CRITICAL: Detach SwiftUI view from window to stop display cycle updates
                // The hosting view stays in memory but is no longer in the view hierarchy,
                // so AppKit won't trigger layout passes on it (saving significant CPU)
                self?.hostingView?.removeFromSuperview()
                self?.isVisible = false
                Self.isTimelineVisible = false  // For emergency escape tap
                self?.lastHiddenAt = Date()
                self?.startBackgroundRefreshTimer()

                // Clean up live mode state AFTER fade-out completes (prevents flicker)
                if let viewModel = self?.timelineViewModel {
                    viewModel.isInLiveMode = false
                    viewModel.liveScreenshot = nil
                    viewModel.isTapeHidden = true
                    viewModel.areControlsHidden = false  // Reset controls visibility so they show on next open
                    viewModel.resetFrameZoom()  // Reset zoom so it's at 100% on next open
                }

                // Immediately refresh frame data so next open has fresh data
                // Use navigateToNewest: false to preserve user's position within the 2-minute grace period
                if let viewModel = self?.timelineViewModel {
                    await viewModel.refreshFrameData(navigateToNewest: false)
                    // Reset zoom region state on hide
                    viewModel.exitZoomRegion()
                }

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

    // MARK: - Background Refresh Timer

    /// Move the hidden window to the screen where the mouse is (for instant show on any screen)
    private func moveWindowToMouseScreen() {
        guard let window = window, !isVisible else { return }

        let mouseLocation = NSEvent.mouseLocation
        guard let targetScreen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) }) ?? NSScreen.main else {
            return
        }

        let screenIndex = NSScreen.screens.firstIndex(of: targetScreen) ?? -1
        if window.frame != targetScreen.frame {
            window.setFrame(targetScreen.frame, display: false)
            // Reset scale factor cache so it recalculates for the new display
            TimelineScaleFactor.resetCache()
            debugLog("[DISPLAY-SWITCH] moved window to display \(screenIndex), screen: \(Int(targetScreen.frame.width))x\(Int(targetScreen.frame.height)) at (\(Int(targetScreen.frame.origin.x)),\(Int(targetScreen.frame.origin.y))), mouse: (\(Int(mouseLocation.x)),\(Int(mouseLocation.y)))")
        }
    }

    /// Capture a live screenshot for seamless timeline launch
    /// Returns NSImage of the current screen, or nil on failure
    private func captureLiveScreenshot() -> NSImage? {
        // Get the screen where the mouse cursor is located
        let mouseLocation = NSEvent.mouseLocation
        guard let targetScreen = NSScreen.screens.first(where: {
            NSMouseInRect(mouseLocation, $0.frame, false)
        }) ?? NSScreen.main else {
            return nil
        }

        // Get display ID for this screen
        guard let screenNumber = targetScreen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            return nil
        }

        // Capture the screen
        guard let cgImage = CGDisplayCreateImage(screenNumber) else {
            Log.warning("[TIMELINE-LIVE] Failed to capture live screenshot", category: .ui)
            return nil
        }

        return NSImage(cgImage: cgImage, size: targetScreen.frame.size)
    }

    /// Start a repeating timer that keeps timeline data fresh while hidden
    private func startBackgroundRefreshTimer() {
        // Don't restart if already running
        guard backgroundRefreshTimer == nil else {
            Log.debug("[TIMELINE-CACHE] Timer already running, not restarting", category: .ui)
            return
        }

        let refreshInterval: TimeInterval = 10
        Log.info("[TIMELINE-CACHE] ⏱️ Starting background refresh timer (every \(Int(refreshInterval))s)", category: .ui)

        backgroundRefreshTimer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self,
                      !self.isVisible,
                      let viewModel = self.timelineViewModel,
                      let coordinator = self.coordinator else { return }

                // Only refresh if capture is active (no point refreshing if not recording)
                guard await coordinator.isCapturing() else {
                    Log.debug("[TIMELINE-CACHE] ⏸️ Skipping background refresh (not capturing)", category: .ui)
                    return
                }

                // Check if position cache has expired (1 minute)
                // If expired, navigate to newest; if not expired, preserve user's position
                let cacheExpirationSeconds: TimeInterval = 60
                let cacheExpired: Bool
                if let lastHidden = self.lastHiddenAt {
                    cacheExpired = Date().timeIntervalSince(lastHidden) > cacheExpirationSeconds
                } else {
                    cacheExpired = true // No lastHiddenAt means first show, navigate to newest
                }

                Log.info("[TIMELINE-CACHE] 🔄 Background refresh triggered (cacheExpired: \(cacheExpired))", category: .ui)
                // Only preserve position if cache hasn't expired; after 1 minute, navigate to newest
                await viewModel.refreshFrameData(navigateToNewest: cacheExpired)
                // Force video reload so AVPlayer picks up new frames appended to the video file
                viewModel.forceVideoReload = true
                Log.info("[TIMELINE-CACHE] ✅ Background refresh complete", category: .ui)
            }
        }
    }


    /// Save state for cross-session persistence (call on app termination)
    public func saveStateForTermination() {
        Log.info("[TIMELINE-PRERENDER] 💾 saveStateForTermination() called", category: .ui)
        timelineViewModel?.saveState()
    }

    /// Completely destroy the pre-rendered window (call when memory pressure is high or app is terminating)
    public func destroyPreparedWindow() {
        Log.info("[TIMELINE-PRERENDER] 🗑️ destroyPreparedWindow() called", category: .ui)
        // Save state before destroying for cross-session persistence
        timelineViewModel?.saveState()

        window?.orderOut(nil)
        hostingView?.removeFromSuperview()
        window = nil
        hostingView = nil
        timelineViewModel = nil
        isPrepared = false
    }

    /// Toggle timeline visibility
    public func toggle() {
        if isVisible {
            hide()
        } else {
            show()
        }
    }

    /// Hide the timeline to show dashboard or settings
    /// This prevents the dashboard from being auto-hidden when the timeline closes
    public func hideToShowDashboard() {
        isHidingToShowDashboard = true
        hide()
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

    /// Show the timeline with a pre-applied filter for an app and window name
    /// This instantly opens a filtered timeline view without showing a dialog
    /// - Parameters:
    ///   - startDate: Optional start date for filtering (e.g., week start)
    ///   - endDate: Optional end date for filtering (e.g., now)
    ///   - clickStartTime: Optional start time from when the tab was clicked (for end-to-end timing)
    public func showWithFilter(bundleID: String, windowName: String?, browserUrl: String? = nil, startDate: Date? = nil, endDate: Date? = nil, clickStartTime: CFAbsoluteTime? = nil) {
        let startTime = clickStartTime ?? CFAbsoluteTimeGetCurrent()
        logTabClickTiming("TIMELINE_SHOW_WITH_FILTER", startTime: startTime, bundleID: bundleID, browserUrl: browserUrl)

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
        logTabClickTiming("WINDOW_PREPARED_INVISIBLY", startTime: startTime, bundleID: bundleID, browserUrl: browserUrl)

        // Load data, then fade in once ready
        Task { @MainActor in
            guard let viewModel = timelineViewModel, let coordinator = coordinator else { return }

            // Apply the filter criteria to viewModel
            viewModel.filterCriteria = criteria
            viewModel.pendingFilterCriteria = criteria
            logTabClickTiming("TIMELINE_FILTER_SET", startTime: startTime, bundleID: bundleID, browserUrl: browserUrl)

            // Query and load frames
            logTabClickTiming("QUERY_START", startTime: startTime, bundleID: bundleID, browserUrl: browserUrl)
            let frames = try? await coordinator.getMostRecentFramesWithVideoInfo(limit: 500, filters: criteria)
            logTabClickTiming("QUERY_DONE (count=\(frames?.count ?? 0))", startTime: startTime, bundleID: bundleID, browserUrl: browserUrl)

            // Load frames directly into viewModel
            await viewModel.loadFramesDirectly(frames ?? [], clickStartTime: startTime)
            logTabClickTiming("FRAMES_LOADED", startTime: startTime, bundleID: bundleID, browserUrl: browserUrl)

            // Small delay to let the view settle before fade-in
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds

            // Now fade in the window with data already loaded
            fadeInPreparedWindow()
            logTabClickTiming("FADE_IN_STARTED", startTime: startTime, bundleID: bundleID, browserUrl: browserUrl)

            Log.info("[TIMELINE-FILTER] Applied filter for bundleID=\(bundleID), windowName=\(windowName ?? "nil"), browserUrl=\(browserUrl ?? "nil"), dateRange=\(String(describing: startDate))-\(String(describing: endDate))", category: .ui)
        }
    }

    /// Prepare the window invisibly without showing it yet
    /// Used by showWithFilter to load data before revealing
    private func prepareWindowInvisibly() {
        guard !isVisible, let coordinator = coordinator else { return }

        // Remember if dashboard was the key window before we take over
        dashboardWasKeyWindow = DashboardWindowController.shared.isVisible &&
            NSApp.keyWindow == DashboardWindowController.shared.window

        // Get the screen where the mouse cursor is located
        let mouseLocation = NSEvent.mouseLocation
        guard let targetScreen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) }) ?? NSScreen.main else {
            return
        }

        // Check if we have a pre-rendered window ready
        if isPrepared, let window = window, let viewModel = timelineViewModel {
            // Reattach SwiftUI view if it was detached (on hide, we remove it from superview to stop display cycle)
            if let hostingView = hostingView, hostingView.superview == nil {
                hostingView.frame = window.contentView?.bounds ?? .zero
                window.contentView?.addSubview(hostingView)
                hostingView.layoutSubtreeIfNeeded()
                timelineViewModel?.objectWillChange.send()
            }
            // Move window to target screen if needed
            if window.frame != targetScreen.frame {
                window.setFrame(targetScreen.frame, display: false)
            }
            // Ensure tape starts hidden for slide-up animation
            viewModel.isTapeHidden = true
            return
        }

        // Create window from scratch if needed
        let newWindow = createWindow(for: targetScreen)
        let viewModel = SimpleTimelineViewModel(coordinator: coordinator)
        self.timelineViewModel = viewModel
        // Pre-set tape as hidden so view renders with tape off-screen initially
        viewModel.isTapeHidden = true

        guard let coordinatorWrapper = coordinatorWrapper else {
            Log.error("[TIMELINE] Coordinator wrapper not initialized", category: .ui)
            return
        }

        let timelineView = SimpleTimelineView(
            coordinator: coordinator,
            viewModel: viewModel,
            onClose: { [weak self] in
                self?.hide()
            }
        )
        .environmentObject(coordinatorWrapper)

        let hostingView = FirstMouseHostingView(rootView: timelineView)
        hostingView.frame = newWindow.contentView?.bounds ?? .zero
        hostingView.autoresizingMask = [.width, .height]
        newWindow.contentView?.addSubview(hostingView)

        self.window = newWindow
        self.hostingView = hostingView
        self.isPrepared = true
            }

    /// Fade in the prepared window (called after data is loaded)
    private func fadeInPreparedWindow() {
        guard let window = window, let coordinator = coordinator else { return }

        // Reattach SwiftUI view if it was detached (on hide, we remove it from superview to stop display cycle)
        if let hostingView = hostingView, hostingView.superview == nil {
            hostingView.frame = window.contentView?.bounds ?? .zero
            window.contentView?.addSubview(hostingView)
            hostingView.layoutSubtreeIfNeeded()
            timelineViewModel?.objectWillChange.send()
        }

        // Ensure tape starts hidden and cancel any pending animation
        timelineViewModel?.isTapeHidden = true
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
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        isVisible = true
        Self.isTimelineVisible = true

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.35
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
        })

        // Trigger tape slide-up animation
        tapeShowAnimationTask = Task { @MainActor in
            await Task.yield()
            guard let viewModel = self.timelineViewModel, !Task.isCancelled else { return }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                viewModel.isTapeHidden = false
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

    // MARK: - Tab Click Timing

    private static let tabClickLogPath = URL(fileURLWithPath: "/tmp/retrace_debug.log")

    /// Log timing for tab click filter queries
    private func logTabClickTiming(_ checkpoint: String, startTime: CFAbsoluteTime, bundleID: String, browserUrl: String?) {
        let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        let filterInfo = browserUrl ?? bundleID
        let line = "[\(Log.timestamp())] [TAB_CLICK] \(checkpoint): \(String(format: "%.1f", elapsed))ms (filter: \(filterInfo))\n"

        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: Self.tabClickLogPath.path) {
                if let handle = try? FileHandle(forWritingTo: Self.tabClickLogPath) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                try? data.write(to: Self.tabClickLogPath)
            }
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
        window.animationBehavior = .none
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

    /// Debug log to /tmp/retrace_debug.log for shift-drag investigation
    private func debugLog(_ message: String) {
        let timestamp = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let line = "[\(formatter.string(from: timestamp))] [WINDOW] \(message)\n"
        if let data = line.data(using: .utf8) {
            let path = "/tmp/retrace_debug.log"
            if FileManager.default.fileExists(atPath: path) {
                if let handle = FileHandle(forWritingAtPath: path) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                FileManager.default.createFile(atPath: path, contents: data)
            }
        }
    }

    private func setupEventMonitors() {
        debugLog("setupEventMonitors called - timeline launched")

        // Monitor for mouse events to handle click-drag scrubbing on the timeline tape
        mouseEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .leftMouseDragged, .flagsChanged]) { [weak self] event in
            guard let self = self, self.isVisible else { return event }

            switch event.type {
            case .leftMouseDown:
                // Don't start tape drag if Shift is held (Shift+Drag is zoom region)
                guard !event.modifierFlags.contains(.shift) else { return event }

                // Check if the click is in the tape area
                if self.isPointInTapeArea(event.locationInWindow) {
                    // Don't start drag if overlays are open
                    if let viewModel = self.timelineViewModel,
                       !viewModel.isSearchOverlayVisible,
                       !viewModel.isFilterDropdownOpen,
                       !viewModel.isDateSearchActive,
                       !viewModel.showTagSubmenu,
                       !viewModel.isCalendarPickerVisible {
                        // Cancel any ongoing momentum from a previous drag
                        viewModel.cancelTapeDragMomentum()

                        self.tapeDragStartX = event.locationInWindow.x
                        self.tapeDragLastX = event.locationInWindow.x
                        self.isTapeDragging = true
                        self.tapeDragDidExceedThreshold = false
                        self.tapeDragVelocitySamples.removeAll()
                        // Don't consume — allow tap gestures to fire if user doesn't drag
                    }
                }
                return event

            case .leftMouseDragged:
                if self.isTapeDragging {
                    let currentX = event.locationInWindow.x
                    let totalDistance = abs(currentX - self.tapeDragStartX)

                    if !self.tapeDragDidExceedThreshold {
                        // Check if we've moved far enough to be a drag (not a click)
                        if totalDistance >= Self.tapeDragMinDistance {
                            self.tapeDragDidExceedThreshold = true
                            NSCursor.closedHand.push()
                            // Defer heavy operations during drag
                            if let viewModel = self.timelineViewModel {
                                Task { @MainActor in
                                    if !viewModel.isActivelyScrolling {
                                        viewModel.isActivelyScrolling = true
                                        viewModel.dismissContextMenu()
                                        viewModel.dismissTimelineContextMenu()
                                    }
                                }
                            }
                        } else {
                            return event // Not yet a drag, let other handlers process
                        }
                    }

                    // Calculate pixel delta since last drag event
                    let deltaX = currentX - self.tapeDragLastX
                    self.tapeDragLastX = currentX

                    // Record velocity sample (prune old samples)
                    let now = CFAbsoluteTimeGetCurrent()
                    self.tapeDragVelocitySamples.append((time: now, delta: deltaX))
                    self.tapeDragVelocitySamples.removeAll { now - $0.time > Self.velocitySampleWindow }

                    // Feed delta into the scroll handling system
                    // Negate: dragging right (positive deltaX) should move tape right (grab-and-pull)
                    if abs(deltaX) > 0.001, let viewModel = self.timelineViewModel {
                        Task { @MainActor in
                            await viewModel.handleScroll(delta: -deltaX, isTrackpad: true)
                        }
                    }

                    return nil // Consume the event to prevent other handlers
                }
                return event

            case .leftMouseUp:
                if self.isTapeDragging {
                    let wasDragging = self.tapeDragDidExceedThreshold
                    self.isTapeDragging = false
                    self.tapeDragDidExceedThreshold = false

                    if wasDragging {
                        NSCursor.pop()

                        // Calculate release velocity from recent samples
                        let now = CFAbsoluteTimeGetCurrent()
                        let recentSamples = self.tapeDragVelocitySamples.filter { now - $0.time <= Self.velocitySampleWindow }
                        self.tapeDragVelocitySamples.removeAll()

                        var velocity: CGFloat = 0
                        if recentSamples.count >= 2,
                           let first = recentSamples.first, let last = recentSamples.last {
                            let dt = last.time - first.time
                            if dt > 0.001 {
                                let totalDelta = recentSamples.reduce(0) { $0 + $1.delta }
                                velocity = totalDelta / CGFloat(dt) // pixels per second
                            }
                        }

                        if let viewModel = self.timelineViewModel {
                            // Negate velocity to match scroll convention (same as drag delta)
                            let scrollVelocity = -velocity
                            Task { @MainActor in
                                viewModel.endTapeDrag(withVelocity: scrollVelocity)
                            }
                        }
                        return nil // Consume the event
                    }
                    // If we never exceeded the threshold, let the event through
                    // so .onTapGesture on FrameSegmentView can handle it
                }
                return event

            case .flagsChanged:
                return event

            default:
                return event
            }
        }

        // Monitor for all key events globally (when timeline is visible but not key window)
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

                // Cmd+K to toggle search overlay
                if event.keyCode == 40 && modifiers == [.command] { // Cmd+K
                    _ = self?.handleKeyEvent(event)
                    return nil // Always consume the event to prevent propagation
                }

                // Cmd+F to toggle filter panel
                if event.keyCode == 3 && modifiers == [.command] { // Cmd+F
                    _ = self?.handleKeyEvent(event)
                    return nil // Always consume the event to prevent propagation
                }

                // Cmd+G to toggle date search
                if event.keyCode == 5 && modifiers == [.command] { // Cmd+G
                    _ = self?.handleKeyEvent(event)
                    return nil // Always consume the event to prevent propagation
                }

                // Cmd+=/+ to zoom in (handle before system can intercept)
                if (event.keyCode == 24 || event.keyCode == 69) && (modifiers == [.command] || modifiers == [.command, .shift]) {
                    _ = self?.handleKeyEvent(event)
                    return nil // Always consume the event to prevent propagation
                }

                // Cmd+- to zoom out (handle before system can intercept)
                if (event.keyCode == 27 || event.keyCode == 78) && modifiers == [.command] {
                    _ = self?.handleKeyEvent(event)
                    return nil // Always consume the event to prevent propagation
                }

                // Cmd+0 or Ctrl+0 to reset zoom (handle before system can intercept)
                if event.keyCode == 29 && (modifiers == [.command] || modifiers == [.control]) {
                    _ = self?.handleKeyEvent(event)
                    return nil // Always consume the event to prevent propagation
                }

                // Cmd+A to select all (handle before system can intercept)
                // But let it pass through when a dialog with text input is active
                if event.keyCode == 0 && modifiers == [.command] {
                    if let viewModel = self?.timelineViewModel,
                       (viewModel.isSearchOverlayVisible || viewModel.isFilterPanelVisible || viewModel.isDateSearchActive) {
                        return event // Let the text field handle Cmd+A
                    }
                    _ = self?.handleKeyEvent(event)
                    return nil // Always consume the event to prevent propagation
                }

                // Cmd+C to copy (handle before system can intercept)
                if event.keyCode == 8 && modifiers == [.command] {
                    _ = self?.handleKeyEvent(event)
                    return nil // Always consume the event to prevent propagation
                }

                // Cmd+H to toggle controls visibility (handle before system can intercept)
                if event.keyCode == 4 && modifiers == [.command] {
                    _ = self?.handleKeyEvent(event)
                    return nil // Always consume the event to prevent propagation
                }

                // Cmd+J to go to now (handle before system can intercept)
                if event.keyCode == 38 && modifiers == [.command] {
                    _ = self?.handleKeyEvent(event)
                    return nil // Always consume the event to prevent propagation
                }

                // Cmd+P to toggle peek mode (handle before system can intercept)
                if event.keyCode == 35 && modifiers == [.command] {
                    _ = self?.handleKeyEvent(event)
                    return nil // Always consume the event to prevent propagation
                }

                // For other keys, let text field handle them if it's active
                if isTextFieldActive {
                    return event // Let the text field handle it
                }

                if self?.handleKeyEvent(event) == true {
                    return nil // Consume the event
                }
            } else if event.type == .scrollWheel {
                // Allow scrolling timeline while search overlay is open (don't block)
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
                // Don't intercept scroll events when search overlay is open with results
                // Prioritize scrolling the search results over timeline navigation
                if let viewModel = self?.timelineViewModel,
                   viewModel.isSearchOverlayVisible && !viewModel.searchViewModel.searchQuery.isEmpty {
                    return event // Let the search results ScrollView handle it
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
                // If search highlight is showing, clear it and return to search results if available
                if viewModel.isShowingSearchHighlight {
                    viewModel.clearSearchHighlight()
                    // If there are search results to return to, reopen the search overlay
                    if viewModel.searchViewModel.results != nil && !viewModel.searchViewModel.searchQuery.isEmpty {
                        viewModel.isSearchOverlayVisible = true
                    }
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
                // If in peek mode, exit peek mode and return to filtered view
                if viewModel.isPeeking {
                    viewModel.exitPeek()
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
                // If filters are active (but panel is closed), clear them
                if viewModel.filterCriteria.hasActiveFilters {
                    viewModel.clearAllFilters()
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
            recordShortcut("cmd+g")
            if let viewModel = timelineViewModel {
                viewModel.toggleDateSearch()
            }
            return true
        }

        // Cmd+K to toggle search overlay
        if event.keyCode == 40 && modifiers == [.command] { // K key with Command
            recordShortcut("cmd+k")
            if let viewModel = timelineViewModel {
                let wasVisible = viewModel.isSearchOverlayVisible
                viewModel.toggleSearchOverlay()
                // Record search dialog open metric when opening
                if !wasVisible {
                    if let coordinator = coordinator {
                        DashboardViewModel.recordSearchDialogOpen(coordinator: coordinator)
                    }
                }
            }
            return true
        }

        // Cmd+F to toggle filter panel
        if event.keyCode == 3 && modifiers == [.command] { // F key with Command
            recordShortcut("cmd+f")
            if let viewModel = timelineViewModel {
                if viewModel.isFilterPanelVisible {
                    withAnimation(.easeOut(duration: 0.15)) {
                        viewModel.dismissFilterPanel()
                    }
                } else {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        viewModel.openFilterPanel()
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
        // Skip when a dialog with text input is active - let the text field handle it
        if event.keyCode == 0 && modifiers == [.command] { // A key with Command
            if let viewModel = timelineViewModel {
                // Don't intercept when dialogs with text inputs are open
                if viewModel.isSearchOverlayVisible || viewModel.isFilterPanelVisible || viewModel.isDateSearchActive {
                    return false // Let the text field handle Cmd+A
                }
                recordShortcut("cmd+a")
                viewModel.selectAllText()
                return true
            }
        }

        // Cmd+C to copy selected text
        if event.keyCode == 8 && modifiers == [.command] { // C key with Command
            recordShortcut("cmd+c")
            if let viewModel = timelineViewModel, viewModel.hasSelection {
                viewModel.copySelectedText()
                return true
            }
        }

        // Cmd+H to toggle timeline controls visibility
        if event.keyCode == 4 && modifiers == [.command] { // H key with Command
            recordShortcut("cmd+h")
            if let viewModel = timelineViewModel {
                viewModel.toggleControlsVisibility()
                return true
            }
        }

        // Cmd+P to toggle peek mode (view full context while filtered)
        if event.keyCode == 35 && modifiers == [.command] { // P key with Command
            recordShortcut("cmd+p")
            if let viewModel = timelineViewModel {
                // Only allow peek if we have active filters or are already peeking
                if viewModel.filterCriteria.hasActiveFilters || viewModel.isPeeking {
                    viewModel.togglePeek()
                    return true
                }
            }
        }

        // Cmd+J to go to now (most recent frame)
        if event.keyCode == 38 && modifiers == [.command] { // J key with Command
            recordShortcut("cmd+j")
            if let viewModel = timelineViewModel {
                viewModel.goToNow()
                return true
            }
        }

        // Cmd+Z to undo (go back to last stopped playhead position)
        if event.keyCode == 6 && modifiers == [.command] { // Z key with Command
            if let viewModel = timelineViewModel {
                if viewModel.undoToLastStoppedPosition() {
                    recordShortcut("cmd+z")
                    return true
                }
            }
            // Don't consume the event if there's nothing to undo
            return false
        }

        // Left arrow key - navigate to previous frame (Option = 3x speed)
        if event.keyCode == 123 && (modifiers.isEmpty || modifiers == [.option]) { // Left arrow
            if let viewModel = timelineViewModel {
                let step = modifiers.contains(.option) ? 3 : 1
                viewModel.navigateToFrame(viewModel.currentIndex - step)
                // Record arrow key navigation metric
                if let coordinator = coordinator {
                    DashboardViewModel.recordArrowKeyNavigation(coordinator: coordinator, direction: "left")
                }
            }
            return true // Always consume arrow keys to prevent system "bonk" sound
        }

        // Right arrow key - navigate to next frame (Option = 3x speed)
        if event.keyCode == 124 && (modifiers.isEmpty || modifiers == [.option]) { // Right arrow
            if let viewModel = timelineViewModel {
                let step = modifiers.contains(.option) ? 3 : 1
                viewModel.navigateToFrame(viewModel.currentIndex + step)
                // Record arrow key navigation metric
                if let coordinator = coordinator {
                    DashboardViewModel.recordArrowKeyNavigation(coordinator: coordinator, direction: "right")
                }
            }
            return true // Always consume arrow keys to prevent system "bonk" sound
        }

        // Ctrl+0 to reset frame zoom to 100%
        if event.keyCode == 29 && modifiers == [.control] { // 0 key with Control
            recordShortcut("ctrl+0")
            if let viewModel = timelineViewModel, viewModel.isFrameZoomed {
                viewModel.resetFrameZoom()
                return true
            }
        }

        // Cmd+0 to reset frame zoom to 100% (alternative shortcut)
        if event.keyCode == 29 && modifiers == [.command] { // 0 key with Command
            recordShortcut("cmd+0")
            if let viewModel = timelineViewModel, viewModel.isFrameZoomed {
                viewModel.resetFrameZoom()
                return true
            }
        }

        // Cmd++ (Cmd+=) to zoom in frame
        // Key code 24 is '=' which is '+' with shift, but Cmd+= works as zoom in
        if (event.keyCode == 24 || event.keyCode == 69) && (modifiers == [.command] || modifiers == [.command, .shift]) {
            recordShortcut("cmd++")
            if let viewModel = timelineViewModel {
                viewModel.applyMagnification(1.25, animated: true) // Zoom in by 25%
                return true
            }
        }

        // Cmd+- to zoom out frame
        if (event.keyCode == 27 || event.keyCode == 78) && modifiers == [.command] { // - key (main or numpad)
            recordShortcut("cmd+-")
            if let viewModel = timelineViewModel {
                viewModel.applyMagnification(0.8, animated: true) // Zoom out by 20%
                return true
            }
        }

        // TEMP: Debug shortcuts for testing detach/reattach fix (uncomment to use)
        // #if DEBUG
        // // Option+1 — Detach hosting view + refresh data in background (simulates real hide scenario)
        // if event.keyCode == 18 && modifiers == [.option] { // 1
        //     if let hostingView = hostingView, hostingView.superview != nil {
        //         hostingView.removeFromSuperview()
        //         Log.info("[DEV-TEST] ⚡ Detached hosting view, now refreshing data while detached...", category: .ui)
        //         Task { @MainActor in
        //             await self.timelineViewModel?.refreshFrameData(navigateToNewest: true)
        //             Log.info("[DEV-TEST] ⚡ Data refreshed while detached. frames=\(self.timelineViewModel?.frames.count ?? 0)", category: .ui)
        //         }
        //     }
        //     return true
        // }
        // // Option+2 — Reattach hosting view WITHOUT objectWillChange (should show stale tape)
        // if event.keyCode == 19 && modifiers == [.option] { // 2
        //     if let hostingView = hostingView, hostingView.superview == nil, let window = window {
        //         hostingView.frame = window.contentView?.bounds ?? .zero
        //         window.contentView?.addSubview(hostingView)
        //         hostingView.layoutSubtreeIfNeeded()
        //         Log.info("[DEV-TEST] ⚡ Reattached hosting view (WITHOUT objectWillChange)", category: .ui)
        //     }
        //     return true
        // }
        // // Option+3 — Send objectWillChange (should fix stale tape)
        // if event.keyCode == 20 && modifiers == [.option] { // 3
        //     timelineViewModel?.objectWillChange.send()
        //     Log.info("[DEV-TEST] ⚡ Sent objectWillChange.send()", category: .ui)
        //     return true
        // }
        // #endif

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

    /// Check if a window-coordinate point is within the timeline tape area
    private func isPointInTapeArea(_ pointInWindow: CGPoint) -> Bool {
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

    /// Force-end any in-progress tape drag (e.g., on window focus loss)
    private func forceEndTapeDrag() {
        guard isTapeDragging else { return }
        let wasDragging = tapeDragDidExceedThreshold
        isTapeDragging = false
        tapeDragDidExceedThreshold = false
        tapeDragVelocitySamples.removeAll()

        if wasDragging {
            NSCursor.pop()
            if let viewModel = timelineViewModel {
                Task { @MainActor in
                    viewModel.endTapeDrag(withVelocity: 0)
                }
            }
        }
    }

    private func handleScrollEvent(_ event: NSEvent, source: String) {
        guard isVisible, let viewModel = timelineViewModel else { return }

        let deltaX = event.scrollingDeltaX
        let deltaY = event.scrollingDeltaY

        // Use horizontal scrolling primarily, fall back to vertical
        let delta = abs(deltaX) > abs(deltaY) ? -deltaX : -deltaY

        // Trackpads have precise scrolling deltas, mice do not
        let isTrackpad = event.hasPreciseScrollingDeltas

        if abs(delta) > 0.001 {
            // Cancel any tape drag momentum on real scroll input
            viewModel.cancelTapeDragMomentum()

            let mousePos = NSEvent.mouseLocation
            let screenIndex = NSScreen.screens.firstIndex(where: { NSMouseInRect(mousePos, $0.frame, false) }) ?? -1
            debugLog("[SCROLL] \(source), display: \(screenIndex), delta: \(String(format: "%.1f", delta)), isKeyWindow: \(window?.isKeyWindow ?? false)")
            onScroll?(delta)
            // Forward scroll to view model
            Task { @MainActor in
                await viewModel.handleScroll(delta: CGFloat(delta), isTrackpad: isTrackpad)
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
        let mousePos = NSEvent.mouseLocation
        let screenIndex = NSScreen.screens.firstIndex(where: { NSMouseInRect(mousePos, $0.frame, false) }) ?? -1
        debugLog("[ZOOM] display: \(screenIndex), mouse: (\(Int(mousePos.x)),\(Int(mousePos.y))), magnification: \(String(format: "%.3f", magnification)), scaleBefore: \(String(format: "%.2f", viewModel.frameZoomScale)), isKeyWindow: \(window.isKeyWindow)")
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

    // MARK: - Scrub Distance Tracking

    /// Accumulate scrub distance for the current session
    public func accumulateScrubDistance(_ distance: Double) {
        sessionScrubDistance += distance
    }

    // MARK: - Keyboard Shortcut Tracking

    /// Record keyboard shortcut usage
    private func recordShortcut(_ shortcut: String) {
        if let coordinator = coordinator {
            DashboardViewModel.recordKeyboardShortcut(coordinator: coordinator, shortcut: shortcut)
        }
    }

    // MARK: - Session Metrics

    /// Force record session metrics (called on app termination)
    public func forceRecordSessionMetrics() {
        guard let startTime = sessionStartTime, let coordinator = coordinator else { return }

        let durationMs = Int64(Date().timeIntervalSince(startTime) * 1000)

        // Record synchronously using a blocking task
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            try? await coordinator.recordMetricEvent(metricType: .timelineSessionDuration, metadata: "\(durationMs)")

            if sessionScrubDistance > 0 {
                try? await coordinator.recordMetricEvent(metricType: .scrubDistance, metadata: "\(Int(sessionScrubDistance))")
            }

            semaphore.signal()
        }
        semaphore.wait()
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

// MARK: - String Extension for Debug Logging
extension String {
    func appendToFile(at path: String) throws {
        if let data = self.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: path) {
                if let fileHandle = FileHandle(forWritingAtPath: path) {
                    fileHandle.seekToEndOfFile()
                    fileHandle.write(data)
                    fileHandle.closeFile()
                }
            } else {
                try self.write(toFile: path, atomically: false, encoding: .utf8)
            }
        }
    }
}
