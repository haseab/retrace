import Foundation
import CoreGraphics
import ScreenCaptureKit
import AppKit
import ApplicationServices
import Shared

/// Monitors and provides information about available displays
actor DisplayMonitor {

    // MARK: - Properties

    private var cachedDisplays: [DisplayInfo] = []
    private var lastRefresh: Date?
    private let cacheValidityDuration: TimeInterval = 5.0 // Refresh every 5 seconds

    // MARK: - Public Methods

    /// Get all available displays
    /// Results are cached for performance
    func getAvailableDisplays() async throws -> [DisplayInfo] {
        // Return cached results if still valid
        if let lastRefresh = lastRefresh,
           Date().timeIntervalSince(lastRefresh) < cacheValidityDuration {
            return cachedDisplays
        }

        // Refresh display list
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: false
        )

        let mainDisplayID = CGMainDisplayID()
        let displays = content.displays.map { display in
            DisplayInfo(
                id: display.displayID,
                width: display.width,
                height: display.height,
                scaleFactor: getScaleFactor(for: display.displayID),
                isMain: display.displayID == mainDisplayID,
                name: getDisplayName(for: display.displayID)
            )
        }

        cachedDisplays = displays
        lastRefresh = Date()

        return displays
    }

    /// Get the display containing the focused window (active display)
    /// This may differ from the main display in multi-monitor setups
    func getFocusedDisplay() async throws -> DisplayInfo? {
        let displays = try await getAvailableDisplays()

        // Get the display containing the frontmost window
        let activeDisplayID = getActiveDisplayID()

        // Try to find the active display
        if let activeDisplay = displays.first(where: { $0.id == activeDisplayID }) {
            return activeDisplay
        }

        // Fallback to main display
        return displays.first { $0.isMain }
    }

    /// Get the display ID of the currently active display (contains focused window)
    /// Uses the frontmost window's position to determine which display is active
    /// This is more accurate than mouse position for keyboard-driven workflows
    func getActiveDisplayID() -> UInt32 {
        let (displayID, _) = getActiveDisplayIDWithPermissionStatus()
        return displayID
    }

    /// Get the display ID of the currently active display and whether AX permission was granted
    /// Returns: (displayID, hasAXPermission)
    func getActiveDisplayIDWithPermissionStatus() -> (UInt32, Bool) {
        // Get the frontmost application
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return (CGMainDisplayID(), true) // No app is fine, not a permission issue
        }

        // Create accessibility element for the application
        let appElement = AXUIElementCreateApplication(app.processIdentifier)

        // Get the focused window
        var focusedWindow: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &focusedWindow
        )

        // Check for permission denial
        // Note: .cannotComplete typically indicates accessibility permissions are denied
        if result == .apiDisabled || result == .cannotComplete {
            // logger.warning("Accessibility permission denied - falling back to main display")
            return (CGMainDisplayID(), false)
        }

        // If we got a focused window, get its position and size
        if result == .success, let window = focusedWindow {
            if let windowFrame = getWindowFrame(window as! AXUIElement) {
                // Find which display contains the center of the window
                let displayID = getDisplayContainingPoint(windowFrame.midX, windowFrame.midY)
                return (displayID, true)
            }
        }

        // Fallback: return main display (not a permission issue, just couldn't get window)
        return (CGMainDisplayID(), true)
    }

    /// Get the frame (position and size) of an accessibility window element
    private func getWindowFrame(_ window: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?

        // Get position
        guard AXUIElementCopyAttributeValue(
            window,
            kAXPositionAttribute as CFString,
            &positionValue
        ) == .success else {
            return nil
        }

        // Get size
        guard AXUIElementCopyAttributeValue(
            window,
            kAXSizeAttribute as CFString,
            &sizeValue
        ) == .success else {
            return nil
        }

        var position = CGPoint.zero
        var size = CGSize.zero

        // Extract CGPoint from AXValue
        if let posValue = positionValue {
            AXValueGetValue(posValue as! AXValue, .cgPoint, &position)
        }

        // Extract CGSize from AXValue
        if let szValue = sizeValue {
            AXValueGetValue(szValue as! AXValue, .cgSize, &size)
        }

        return CGRect(origin: position, size: size)
    }

    /// Find which display contains the given point
    private func getDisplayContainingPoint(_ x: CGFloat, _ y: CGFloat) -> UInt32 {
        let point = CGPoint(x: x, y: y)

        var displayCount: UInt32 = 0
        var displayID: CGDirectDisplayID = 0

        let result = CGGetDisplaysWithPoint(point, 1, &displayID, &displayCount)
        if result == .success && displayCount > 0 {
            return displayID
        }

        return CGMainDisplayID()
    }

    /// Get display by ID
    func getDisplay(by id: UInt32) async throws -> DisplayInfo? {
        let displays = try await getAvailableDisplays()
        return displays.first { $0.id == id }
    }

    /// Force refresh of display cache
    func refreshDisplays() async throws -> [DisplayInfo] {
        lastRefresh = nil
        return try await getAvailableDisplays()
    }

    // MARK: - Private Helpers

    /// Get the scale factor (Retina multiplier) for a display
    private func getScaleFactor(for displayID: UInt32) -> Double {
        // Get the CGDisplay mode to determine scale factor
        guard let mode = CGDisplayCopyDisplayMode(displayID) else {
            return 1.0
        }

        let pixelWidth = mode.pixelWidth
        let width = mode.width

        // Scale factor is the ratio of pixel width to logical width
        return Double(pixelWidth) / Double(width)
    }

    /// Get a human-readable name for the display
    private func getDisplayName(for displayID: UInt32) -> String? {
        // Try to get the display name from IOKit
        // For simplicity, we'll return a basic description
        // A full implementation would query IOKit for the actual display name

        if displayID == CGMainDisplayID() {
            return "Main Display"
        }

        return "Display \(displayID)"
    }
}
