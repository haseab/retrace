import Foundation
import ApplicationServices
import AppKit
import Shared

// MARK: - AccessibilityService

/// Accessibility API implementation for text extraction
/// Uses ApplicationServices framework to walk the AX tree and extract text
public actor AccessibilityService: AccessibilityProtocol {

    public init() {}

    // MARK: - AccessibilityProtocol

    public func hasPermission() -> Bool {
        return AXIsProcessTrusted()
    }

    public func requestPermission() {
        // Open System Settings to Accessibility preferences
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    public func getFocusedAppText() async throws -> AccessibilityResult {
        guard hasPermission() else {
            throw ProcessingError.accessibilityPermissionDenied
        }

        // Get frontmost application
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            throw ProcessingError.accessibilityQueryFailed(underlying: "No frontmost application")
        }

        guard let bundleID = frontApp.bundleIdentifier else {
            throw ProcessingError.accessibilityQueryFailed(underlying: "No bundle ID for frontmost app")
        }

        return try await getAppText(bundleID: bundleID)
    }

    public func getAppText(bundleID: String) async throws -> AccessibilityResult {
        guard hasPermission() else {
            throw ProcessingError.accessibilityPermissionDenied
        }

        // Find running application by bundle ID
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }) else {
            throw ProcessingError.accessibilityQueryFailed(underlying: "Application not found: \(bundleID)")
        }

        // Create AX reference to application
        let appRef = AXUIElementCreateApplication(app.processIdentifier)

        // Extract text from AX tree
        let textElements = try extractTextElements(from: appRef)

        // Get app info
        let appInfo = AppInfo(
            bundleID: bundleID,
            name: app.localizedName ?? bundleID,
            windowName: getWindowTitle(from: appRef),
            browserURL: nil  // TODO: Extract URL if browser
        )

        return AccessibilityResult(
            appInfo: appInfo,
            textElements: textElements,
            extractionTime: Date()
        )
    }

    public func getFrontmostAppInfo() async throws -> AppInfo {
        guard let frontApp = NSWorkspace.shared.frontmostApplication,
              let bundleID = frontApp.bundleIdentifier else {
            throw ProcessingError.accessibilityQueryFailed(underlying: "No frontmost application")
        }

        let appRef = AXUIElementCreateApplication(frontApp.processIdentifier)

        return AppInfo(
            bundleID: bundleID,
            name: frontApp.localizedName ?? bundleID,
            windowName: getWindowTitle(from: appRef),
            browserURL: nil
        )
    }

    // MARK: - Private Helpers

    /// Recursively extract text from AX tree
    private func extractTextElements(from element: AXUIElement, depth: Int = 0) throws -> [AccessibilityTextElement] {
        // Prevent infinite recursion
        guard depth < 15 else { return [] }

        var results: [AccessibilityTextElement] = []

        // Get role of element
        var roleValue: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue)
        let role = roleValue as? String

        // Extract value (text content)
        var valueValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueValue) == .success,
           let textValue = valueValue as? String,
           !textValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {

            results.append(AccessibilityTextElement(
                text: textValue,
                role: role,
                label: nil,
                isEditable: isEditableRole(role)
            ))
        }

        // Extract title (for buttons, labels, windows, etc.)
        var titleValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleValue) == .success,
           let title = titleValue as? String,
           !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {

            results.append(AccessibilityTextElement(
                text: title,
                role: role,
                label: "title",
                isEditable: false
            ))
        }

        // Extract description (for accessible content)
        var descValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXDescriptionAttribute as CFString, &descValue) == .success,
           let description = descValue as? String,
           !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {

            results.append(AccessibilityTextElement(
                text: description,
                role: role,
                label: "description",
                isEditable: false
            ))
        }

        // Recurse into children
        var childrenValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue) == .success,
           let children = childrenValue as? [AXUIElement] {

            for child in children {
                let childResults = try extractTextElements(from: child, depth: depth + 1)
                results.append(contentsOf: childResults)
            }
        }

        return results
    }

    /// Get the title of the focused window
    private func getWindowTitle(from appRef: AXUIElement) -> String? {
        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appRef, kAXFocusedWindowAttribute as CFString, &windowValue) == .success,
              let window = windowValue else {
            return nil
        }

        var titleValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &titleValue) == .success,
              let title = titleValue as? String else {
            return nil
        }

        return title
    }

    /// Check if a role represents an editable element
    private func isEditableRole(_ role: String?) -> Bool {
        guard let role = role else { return false }
        return role == "AXTextField" || role == "AXTextArea" || role == "AXComboBox"
    }
}
