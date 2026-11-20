import ApplicationServices
import Foundation

/// A meeting URL identifies a service, not an active call. Only offer consent
/// when that exact window exposes an actionable leave/end-call control.
struct ConferenceCallActivityProvider: ConferenceCallObserving {
    func observe(_ target: ConferenceCallObservationTarget) -> ConferenceCallObservation {
        guard let pid = target.pid else { return .unknown(.windowUnavailable) }
        return Self.observation(pid: pid, windowTitle: target.windowTitle)
    }

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
        observation(pid: pid, windowTitle: windowTitle) == .active
    }

    private static func observation(pid: pid_t, windowTitle: String?) -> ConferenceCallObservation {
        guard AXIsProcessTrusted() else { return .unknown(.accessibilityUnavailable) }
        guard let window = BrowserURLExtractor.matchingAXWindow(pid: pid, requestedTitle: windowTitle) else {
            return .unknown(.windowUnavailable)
        }
        var incomplete = false
        func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
            var value: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(element, key as CFString, &value)
            if error != .success && error != .attributeUnsupported && error != .noValue {
                incomplete = true
            }
            return error == .success ? value : nil
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
                        return .active
                    }
                }
            }
            if let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement], !children.isEmpty {
                let capacity = 750 - min(pending.count, 750)
                if depth >= 16 || children.count > capacity { incomplete = true }
                if depth < 16 {
                    pending.append(contentsOf: children.prefix(capacity).map { ($0, depth + 1) })
                }
            }
        }
        if index < pending.count || CFAbsoluteTimeGetCurrent() >= deadline { incomplete = true }
        // Even a complete tree without Leave/End is inconclusive: call toolbars
        // can hide. Only stronger evidence (or expiration) may revoke consent.
        return .unknown(incomplete ? .traversalIncomplete : .controlNotFound)
    }
}
