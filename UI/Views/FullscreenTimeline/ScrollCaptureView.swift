import SwiftUI
import AppKit

/// Invisible NSView wrapper that captures scroll wheel events
/// Used to enable trackpad scrolling for timeline navigation
struct ScrollCaptureView: NSViewRepresentable {
    let onScroll: (Double) -> Void

    func makeNSView(context: Context) -> ScrollEventView {
        let view = ScrollEventView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ nsView: ScrollEventView, context: Context) {
        nsView.onScroll = onScroll
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onScroll: onScroll)
    }

    class Coordinator {
        var onScroll: (Double) -> Void
        var eventMonitor: Any?

        init(onScroll: @escaping (Double) -> Void) {
            self.onScroll = onScroll

            // Monitor scroll events at the application level
            print("[ScrollCaptureView] Setting up event monitor")
            self.eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                // Get scroll delta
                let deltaX = event.scrollingDeltaX
                let deltaY = event.scrollingDeltaY

                // Use horizontal scrolling primarily, fall back to vertical if no horizontal movement
                let delta = abs(deltaX) > abs(deltaY) ? -deltaX : deltaY

                print("[ScrollCaptureView] RAW deltaX: \(deltaX), deltaY: \(deltaY), computed delta: \(delta)")

                // Only process if there's meaningful movement
                if abs(delta) > 0.1 {
                    print("[ScrollCaptureView] Calling onScroll with delta: \(delta)")
                    self?.onScroll(delta)
                }

                return event  // Pass event through to other handlers
            }
        }

        deinit {
            print("[ScrollCaptureView] Coordinator deinit - removing event monitor")
            if let monitor = eventMonitor {
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
