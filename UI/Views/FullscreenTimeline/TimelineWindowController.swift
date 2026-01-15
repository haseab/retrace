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

        // Save the current playhead position before closing
        timelineViewModel?.savePosition()

        // Remove event monitors
        removeEventMonitors()

        // Animate out
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                window.orderOut(nil)
                self?.window = nil
                self?.timelineViewModel = nil
                self?.isVisible = false
                self?.onClose?()

                // Post notification so menu bar can restore recording indicator
                NotificationCenter.default.post(name: .timelineDidClose, object: nil)
            }
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
                // Check if a text field is currently active - if so, don't intercept keyboard events
                if let window = self?.window,
                   let firstResponder = window.firstResponder {
                    // If the first responder is a text view (field editor) or text field, let the event through
                    if firstResponder is NSTextView || firstResponder is NSTextField {
                        return event // Let the text field handle it
                    }
                }

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
        // Don't handle escape if a modal panel (save panel, etc.) is open
        if NSApp.modalWindow != nil {
            return false
        }

        // Don't handle escape if our window is not the key window (e.g., save panel is open)
        if let keyWindow = NSApp.keyWindow, keyWindow != window {
            return false
        }

        // Escape key closes the timeline (unless delete dialog is showing)
        if event.keyCode == 53 { // Escape
            // If delete confirmation is showing, cancel it instead of closing timeline
            if let viewModel = timelineViewModel, viewModel.showDeleteConfirmation {
                viewModel.cancelDelete()
                return true
            }
            hide()
            return true
        }

        // Check if it's the toggle shortcut (Option+Shift+Space)
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if event.keyCode == 49 && modifiers == [.option, .shift] { // Space with Option+Shift
            hide()
            return true
        }

        // Cmd+G to toggle date search panel ("Go to" date)
        if event.keyCode == 5 && modifiers == [.command] { // G key with Command
            if let viewModel = timelineViewModel {
                viewModel.isDateSearchActive.toggle()
                // Clear text when closing
                if !viewModel.isDateSearchActive {
                    viewModel.dateSearchText = ""
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
}

// MARK: - Notifications

extension Notification.Name {
    static let timelineDidOpen = Notification.Name("timelineDidOpen")
    static let timelineDidClose = Notification.Name("timelineDidClose")
}

// MARK: - Custom Window for Text Input Support

/// Custom NSWindow subclass that can become key window even when borderless
/// This is required for text fields to receive keyboard input properly
class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
