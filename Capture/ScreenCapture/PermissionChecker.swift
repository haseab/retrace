import Foundation
import CoreGraphics
import ScreenCaptureKit
import Shared

/// Handles screen recording permission checking and requesting
struct PermissionChecker: Sendable {

    // MARK: - Permission Checking

    /// Check if screen recording permission is currently granted
    /// - Returns: True if permission is granted, false otherwise
    static func hasScreenRecordingPermission() async -> Bool {
        // On macOS 10.15+, we check permission by attempting to get shareable content
        // If permission is denied, this will return empty content or fail
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            )

            // If we can get displays, permission is granted
            return !content.displays.isEmpty
        } catch {
            // If we get an error, permission is likely denied
            return false
        }
    }

    /// Request screen recording permission from the user
    /// This will trigger the system permission dialog if not already granted
    /// - Returns: True if permission was granted, false otherwise
    @MainActor
    static func requestPermission() async -> Bool {
        // Attempt to get shareable content - this triggers the permission dialog
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )

            return !content.displays.isEmpty
        } catch {
            return false
        }
    }

    /// Legacy fallback method using CGWindowList for older systems
    /// This is less reliable but works as a backup check
    static func hasPermissionLegacy() -> Bool {
        // Try to get window list - if we can't, permission is denied
        let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly],
            kCGNullWindowID
        ) as? [[String: Any]]

        return windowList != nil && !windowList!.isEmpty
    }
}
