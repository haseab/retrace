import SwiftUI
import AppKit
import Combine
import App
import Shared

/// Controller for the pause reminder floating window
/// Positions the window in the top-right corner of the screen (like Rewind AI)
@MainActor
public class PauseReminderWindowController: NSObject, ObservableObject {

    // MARK: - Singleton

    public static let shared = PauseReminderWindowController()

    // MARK: - Properties

    private var window: NSWindow?
    private var pauseReminderManager: PauseReminderManager?
    private var cancellables = Set<AnyCancellable>()

    // Window dimensions
    private let windowWidth: CGFloat = 220
    private let windowHeight: CGFloat = 188
    private let topMargin: CGFloat = 40      // Below menu bar
    private let rightMargin: CGFloat = 16

    // MARK: - Initialization

    private override init() {
        super.init()
    }

    // MARK: - Configuration

    /// Configure the controller with the app coordinator
    public func configure(coordinator: AppCoordinator) {
        // Create the pause reminder manager
        pauseReminderManager = PauseReminderManager(coordinator: coordinator)

        // Subscribe to state changes
        pauseReminderManager?.$shouldShowReminder
            .receive(on: DispatchQueue.main)
            .sink { [weak self] shouldShow in
                if shouldShow {
                    self?.showWindow()
                } else {
                    self?.hideWindow()
                }
            }
            .store(in: &cancellables)

        Log.debug("[PauseReminderWindowController] Configured with coordinator", category: .ui)
    }

    // MARK: - Window Management

    /// Show the pause reminder window
    private func showWindow() {
        guard pauseReminderManager != nil else { return }

        // If window already exists, just show it
        if let existingWindow = window {
            existingWindow.orderFront(nil)
            return
        }

        // Create the SwiftUI content
        let contentView = PauseReminderView(
            onResumeCapturing: { [weak self] in
                Task { @MainActor in
                    await self?.pauseReminderManager?.resumeCapturing()
                }
            },
            onRemindMeLater: { [weak self] in
                self?.pauseReminderManager?.remindLater()
            },
            onEditIntervalInSettings: { [weak self] in
                self?.pauseReminderManager?.dismissReminder()
                DashboardWindowController.shared.show()
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .openSettingsPauseReminderInterval, object: nil)
                }
            },
            onDismiss: { [weak self] in
                self?.pauseReminderManager?.remindLater()
            }
        )

        // Create the window
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .floating  // Float above other windows but below screen saver
        window.hasShadow = false  // We handle shadows in SwiftUI
        window.isMovableByWindowBackground = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]

        // Set the SwiftUI content
        window.contentView = NSHostingView(rootView: contentView)

        // Position in top-right corner
        positionWindow(window)

        // Show the window with animation
        window.alphaValue = 0
        window.orderFront(nil)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
        }

        self.window = window
        Log.debug("[PauseReminderWindowController] Window shown", category: .ui)
    }

    /// Hide the pause reminder window
    private func hideWindow() {
        guard let window = window else { return }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0
        }, completionHandler: {
            Task { @MainActor [weak self] in
                window.orderOut(nil)
                self?.window = nil
            }
        })

        Log.debug("[PauseReminderWindowController] Window hidden", category: .ui)
    }

    /// Position the window in the top-right corner of the main screen
    private func positionWindow(_ window: NSWindow) {
        guard let screen = NSScreen.main else { return }

        let screenFrame = screen.visibleFrame

        // Calculate position (top-right corner)
        let x = screenFrame.maxX - windowWidth - rightMargin
        let y = screenFrame.maxY - windowHeight - topMargin

        window.setFrameOrigin(NSPoint(x: x, y: y))
    }

    // MARK: - Public Access

    /// Get the pause reminder manager for external state observation
    public var manager: PauseReminderManager? {
        pauseReminderManager
    }
}
