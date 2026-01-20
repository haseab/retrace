import Foundation
import AppKit
import Shared

/// Utility for resolving app bundle IDs to human-readable names
/// Uses NSWorkspace and Info.plist to find the best display name
public enum AppNameResolver {

    /// Resolve a single bundle ID to an app name
    /// - Parameter bundleID: The app's bundle identifier (e.g., "com.apple.Safari")
    /// - Returns: The resolved display name, or the last component of the bundle ID as fallback
    @MainActor
    public static func resolve(bundleID: String) -> String {
        // Try to find the app via NSWorkspace
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let infoPlistURL = appURL.appendingPathComponent("Contents/Info.plist")
            if let plist = NSDictionary(contentsOf: infoPlistURL) {
                // Prefer CFBundleDisplayName, then CFBundleName
                if let displayName = plist["CFBundleDisplayName"] as? String, !displayName.isEmpty {
                    return displayName
                }
                if let bundleName = plist["CFBundleName"] as? String, !bundleName.isEmpty {
                    return bundleName
                }
            }
            // Use filename without extension as last resort
            let fileName = appURL.deletingPathExtension().lastPathComponent
            if !fileName.isEmpty { return fileName }
        }

        // Check Chrome Apps folder for PWAs
        let chromeAppsPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/Chrome Apps.localized")
        if FileManager.default.fileExists(atPath: chromeAppsPath.path) {
            if let contents = try? FileManager.default.contentsOfDirectory(at: chromeAppsPath, includingPropertiesForKeys: nil) {
                for appURL in contents where appURL.pathExtension == "app" {
                    let plistURL = appURL.appendingPathComponent("Contents/Info.plist")
                    if let plist = NSDictionary(contentsOf: plistURL),
                       let appBundleID = plist["CFBundleIdentifier"] as? String,
                       appBundleID == bundleID {
                        // Found matching Chrome app
                        if let displayName = plist["CFBundleDisplayName"] as? String, !displayName.isEmpty {
                            return displayName
                        }
                        if let bundleName = plist["CFBundleName"] as? String, !bundleName.isEmpty {
                            return bundleName
                        }
                        return appURL.deletingPathExtension().lastPathComponent
                    }
                }
            }
        }

        // Also check non-localized Chrome Apps folder
        let chromeAppsPathAlt = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/Chrome Apps")
        if FileManager.default.fileExists(atPath: chromeAppsPathAlt.path) {
            if let contents = try? FileManager.default.contentsOfDirectory(at: chromeAppsPathAlt, includingPropertiesForKeys: nil) {
                for appURL in contents where appURL.pathExtension == "app" {
                    let plistURL = appURL.appendingPathComponent("Contents/Info.plist")
                    if let plist = NSDictionary(contentsOf: plistURL),
                       let appBundleID = plist["CFBundleIdentifier"] as? String,
                       appBundleID == bundleID {
                        if let displayName = plist["CFBundleDisplayName"] as? String, !displayName.isEmpty {
                            return displayName
                        }
                        if let bundleName = plist["CFBundleName"] as? String, !bundleName.isEmpty {
                            return bundleName
                        }
                        return appURL.deletingPathExtension().lastPathComponent
                    }
                }
            }
        }

        // Fallback: last component of bundle ID
        return bundleID.components(separatedBy: ".").last ?? bundleID
    }

    /// Resolve multiple bundle IDs to AppInfo objects
    /// - Parameter bundleIDs: Array of bundle identifiers
    /// - Returns: Array of AppInfo with resolved names
    @MainActor
    public static func resolveAll(bundleIDs: [String]) -> [AppInfo] {
        bundleIDs.compactMap { bundleID in
            AppInfo(bundleID: bundleID, name: resolve(bundleID: bundleID))
        }
    }
}
