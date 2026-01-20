import SwiftUI
import AppKit
import Shared

/// Invisible NSView wrapper that captures scroll wheel events
/// Used to enable trackpad scrolling for timeline navigation
struct ScrollCaptureView: NSViewRepresentable {
    let onScroll: (Double) -> Void

    func makeNSView(context: Context) -> ScrollEventView {
        let view = ScrollEventView()
        view.onScroll = onScroll
        // Set up the event monitor when the view is created
        context.coordinator.setupEventMonitor()
        return view
    }

    func updateNSView(_ nsView: ScrollEventView, context: Context) {
        // Update both the view and coordinator with the latest callback
        nsView.onScroll = onScroll
        context.coordinator.onScroll = onScroll
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onScroll: onScroll)
    }

    class Coordinator {
        var onScroll: (Double) -> Void
        var localMonitor: Any?
        var globalMonitor: Any?
        private var hasSetupMonitor = false

        init(onScroll: @escaping (Double) -> Void) {
            self.onScroll = onScroll
        }

        func setupEventMonitor() {
            guard !hasSetupMonitor else { return }
            hasSetupMonitor = true

            Log.debug("[ScrollCaptureView] Setting up BOTH local and global event monitors", category: .ui)

            // Local monitor - for when our window is key
            self.localMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                self?.handleScrollEvent(event, source: "LOCAL")
                return event
            }

            // Global monitor - for when window might not be key (high-level windows)
            self.globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                self?.handleScrollEvent(event, source: "GLOBAL")
            }
        }

        private func handleScrollEvent(_ event: NSEvent, source: String) {
            // Get scroll delta
            let deltaX = event.scrollingDeltaX
            let deltaY = event.scrollingDeltaY

            // Use horizontal scrolling primarily, fall back to vertical if no horizontal movement
            let delta = abs(deltaX) > abs(deltaY) ? -deltaX : -deltaY

            // print("[ScrollCaptureView] [\(source)] RAW deltaX: \(deltaX), deltaY: \(deltaY), computed delta: \(delta)")

            // Only process if there's meaningful movement
            if abs(delta) > 0.1 {
                // print("[ScrollCaptureView] [\(source)] Calling onScroll with delta: \(delta)")
                self.onScroll(delta)
            }
        }

        deinit {
            Log.debug("[ScrollCaptureView] Coordinator deinit - removing event monitors", category: .ui)
            if let monitor = localMonitor {
                NSEvent.removeMonitor(monitor)
            }
            if let monitor = globalMonitor {
                NSEvent.removeMonitor(monitor)
            }
        }
    }
}

/// Custom NSView that's completely transparent
class ScrollEventView: NSView {
    var onScroll: ((Double) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Completely transparent
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // Return nil to be transparent to all mouse events
    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }
}
