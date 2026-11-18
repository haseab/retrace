import ApplicationServices
import Foundation

/// A meeting URL identifies a service, not an active call. Only offer consent
/// when that exact window exposes an actionable leave/end-call control.
enum ConferenceCallActivityProvider {
    static func isActiveCallControl(role: String?, label: String?, isEnabled: Bool = true) -> Bool {
        guard isEnabled, role == kAXButtonRole as String, let label else { return false }
        let normalized = label.replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if ["leave", "end"].contains(normalized.lowercased()) { return true }
        return normalized.range(
            of: #"\b(?:(?:leave|end) (?:the )?(?:call|meeting|huddle)|hang[ -]?up|disconnect)\b"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    static func hasActiveCallControl(pid: pid_t, windowTitle: String?) -> Bool {
        guard AXIsProcessTrusted(),
              let window = BrowserURLExtractor.matchingAXWindow(pid: pid, requestedTitle: windowTitle) else {
            return false
        }
        let deadline = CFAbsoluteTimeGetCurrent() + 0.15
        var pending: [(AXUIElement, Int)] = [(window, 0)]
        var index = 0
        while index < pending.count, index < 750, CFAbsoluteTimeGetCurrent() < deadline {
            let (element, depth) = pending[index]
            index += 1
            AXUIElementSetMessagingTimeout(element, 0.02)
            let role = attribute(element, kAXRoleAttribute) as? String
            if role == kAXButtonRole as String {
                for key in [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute, kAXIdentifierAttribute] {
                    if isActiveCallControl(
                        role: role, label: attribute(element, key) as? String,
                        isEnabled: attribute(element, kAXEnabledAttribute) as? Bool ?? false
                    ) {
                        return true
                    }
                }
            }
            if depth < 16, let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] {
                pending.append(contentsOf: children.prefix(750 - min(pending.count, 750)).map { ($0, depth + 1) })
            }
        }
        return false
    }

    private static func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
        return value
    }
}
