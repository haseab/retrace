import Foundation
import CoreGraphics

enum ForegroundWindowSelection {
    static func isComputerUse(bundleID: String?) -> Bool {
        bundleID == "com.openai.sky.CUAService"
    }

    static func isEligible(
        _ windowInfo: [String: Any],
        foregroundPID: pid_t?,
        bundleID: String?,
        displayBounds: CGRect? = nil,
        requireForegroundApp: Bool = true
    ) -> Bool {
        guard let ownerPID = windowInfo[kCGWindowOwnerPID as String] as? pid_t,
              !requireForegroundApp || foregroundPID == ownerPID,
              !isComputerUse(bundleID: bundleID),
              (windowInfo[kCGWindowLayer as String] as? Int ?? 0) == 0,
              (windowInfo[kCGWindowAlpha as String] as? Double ?? 0) > 0,
              windowInfo[kCGWindowIsOnscreen as String] as? Bool == true,
              let boundsInfo = windowInfo[kCGWindowBounds as String] as? [String: Any],
              let bounds = CGRect(dictionaryRepresentation: boundsInfo as CFDictionary),
              bounds.width > 1,
              bounds.height > 1,
              !isSharingIndicator(
                  title: windowInfo[kCGWindowName as String] as? String,
                  size: bounds.size
              ) else {
            return false
        }

        return displayBounds.map { bounds.intersects($0) } ?? true
    }

    /// Prefer the foreground app even when recording every display. A display-local
    /// fallback is only needed when that app has no eligible window on this display.
    static func preferredWindowID(
        in windows: [[String: Any]],
        foregroundPID: pid_t?,
        displayBounds: CGRect,
        allowOtherApps: Bool,
        bundleIDForPID: (pid_t) -> String?
    ) -> CGWindowID? {
        let eligible = windows.filter { window in
            guard let pid = window[kCGWindowOwnerPID as String] as? pid_t else { return false }
            return isEligible(window, foregroundPID: foregroundPID,
                              bundleID: bundleIDForPID(pid), displayBounds: displayBounds,
                              requireForegroundApp: !allowOtherApps)
        }
        let foreground = eligible.first {
            ($0[kCGWindowOwnerPID as String] as? pid_t) == foregroundPID
        }
        return ((foreground ?? eligible.first)?[kCGWindowNumber as String] as? NSNumber)?.uint32Value
    }

    static func isSharingIndicator(title: String?, size: CGSize) -> Bool {
        title?.trimmingCharacters(in: .whitespacesAndNewlines) == "Window" &&
            size.width > 0 && size.width <= 100 &&
            size.height > 0 && size.height <= 40
    }
}
