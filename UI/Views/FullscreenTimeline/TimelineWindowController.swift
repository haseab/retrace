import AppKit
import SwiftUI
import App

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

    /// Whether the timeline overlay is currently visible
    public private(set) var isVisible = false

    /// Callback when timeline closes
    public var onClose: (() -> Void)?

    /// Callback for scroll events (delta value)
    public var onScroll: ((Double) -> Void)?

    // MARK: - Initialization

    private override init() {
        super.init()
    }

    // MARK: - Configuration

    /// Configure with the app coordinator (call once during app launch)
    public func configure(coordinator: AppCoordinator) {
        self.coordinator = coordinator
    }

    // MARK: - Show/Hide

    /// Show the timeline overlay on the current screen
    public func show() {
        guard !isVisible, let coordinator = coordinator else { return }

        // Get the screen where the mouse cursor is located
        let mouseLocation = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) }) ?? NSScreen.main else {
            return
        }

        // Create the window
        let window = createWindow(for: screen)

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

        // Host the SwiftUI view
        let hostingView = NSHostingView(rootView: timelineView)
        hostingView.frame = window.contentView?.bounds ?? .zero
        hostingView.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(hostingView)

        // Store reference and show
        self.window = window
        window.makeKeyAndOrderFront(nil)

        // Animate in
        window.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
        }

        isVisible = true

        // Setup keyboard monitoring
        setupEventMonitors()

        // Post notification so menu bar can hide recording indicator
        NotificationCenter.default.post(name: .timelineDidOpen, object: nil)
    }

    /// Hide the timeline overlay
    public func hide() {
        guard isVisible, let window = window else { return }

        // Remove event monitors
        removeEventMonitors()

        // Animate out
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            window.orderOut(nil)
            self?.window = nil
            self?.timelineViewModel = nil
            self?.isVisible = false
            self?.onClose?()

            // Post notification so menu bar can restore recording indicator
            NotificationCenter.default.post(name: .timelineDidClose, object: nil)
        })
    }

    /// Toggle timeline visibility
    public func toggle() {
        if isVisible {
            hide()
        } else {
            show()
        }
    }

    // MARK: - Window Creation

    private func createWindow(for screen: NSScreen) -> NSWindow {
        let window = NSWindow(
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
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .scrollWheel]) { [weak self] event in
            if event.type == .keyDown {
                self?.handleKeyEvent(event)
            } else if event.type == .scrollWheel {
                self?.handleScrollEvent(event, source: "GLOBAL")
            }
        }

        // Also monitor local events (when our window is key)
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .scrollWheel]) { [weak self] event in
            if event.type == .keyDown {
                if self?.handleKeyEvent(event) == true {
                    return nil // Consume the event
                }
            } else if event.type == .scrollWheel {
                self?.handleScrollEvent(event, source: "LOCAL")
                return nil // Consume scroll events
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
        // Escape key closes the timeline
        if event.keyCode == 53 { // Escape
            hide()
            return true
        }

        // Check if it's the toggle shortcut (Option+Shift+Space)
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if event.keyCode == 49 && modifiers == [.option, .shift] { // Space with Option+Shift
            hide()
            return true
        }

        return false
    }

    private func handleScrollEvent(_ event: NSEvent, source: String) {
        guard isVisible, let viewModel = timelineViewModel else { return }

        let deltaX = event.scrollingDeltaX
        let deltaY = event.scrollingDeltaY

        // Use horizontal scrolling primarily, fall back to vertical
        let delta = abs(deltaX) > abs(deltaY) ? -deltaX : -deltaY

        print("[TimelineWindowController] [\(source)] scroll: deltaX=\(deltaX), deltaY=\(deltaY), computed=\(delta)")

        if abs(delta) > 0.1 {
            onScroll?(delta)
            // Forward scroll to view model
            Task { @MainActor in
                await viewModel.handleScroll(delta: CGFloat(delta))
            }
        }
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let timelineDidOpen = Notification.Name("timelineDidOpen")
    static let timelineDidClose = Notification.Name("timelineDidClose")
}
