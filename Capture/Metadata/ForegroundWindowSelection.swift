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
        displayBounds: CGRect? = nil
    ) -> Bool {
        guard let foregroundPID,
              let ownerPID = windowInfo[kCGWindowOwnerPID as String] as? pid_t,
              ownerPID == foregroundPID,
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

    static func isSharingIndicator(title: String?, size: CGSize) -> Bool {
        title?.trimmingCharacters(in: .whitespacesAndNewlines) == "Window" &&
            size.width > 0 && size.width <= 100 &&
            size.height > 0 && size.height <= 40
    }
}
