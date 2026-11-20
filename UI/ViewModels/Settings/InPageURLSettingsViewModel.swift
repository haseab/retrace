import SwiftUI
import AppKit

struct InPageURLBrowserTarget: Identifiable, Hashable, Sendable {
    let bundleID: String
    let displayName: String
    let appURL: URL?

    var id: String { bundleID }
}

struct PrivateModeAutomationTarget: Identifiable, Hashable, Sendable {
    let bundleID: String
    let displayName: String
    let appURL: URL?

    var id: String { bundleID }
}

struct UnsupportedInPageURLTarget: Identifiable, Hashable, Sendable {
    let bundleID: String
    let displayName: String
    let reason: String
    let appURL: URL?

    var id: String { bundleID }
}

enum InPageURLPermissionState: Equatable, Sendable {
    case granted
    case denied
    case needsConsent
    case unavailable(OSStatus)
}

enum InPageURLVerificationState: Equatable {
    case pending
    case success(String)
    case warning(String)
    case failed(String)
}

struct InPageURLAppleScriptRunResult {
    let stdout: String
    let stderr: String
    let exitCode: Int32
    let didTimeOut: Bool
    let elapsedMs: Double
}

struct InPageURLVerificationTraceContext {
    let traceID: String
    let bundleID: String
    let displayName: String
    let verificationMode: String
    let startedAtUptime: TimeInterval

    var logPrefix: String {
        "[InPageURL][SettingsTest][\(bundleID)][\(traceID)]"
    }
}

@MainActor
final class InPageURLSettingsViewModel: ObservableObject {
    nonisolated static func chromiumHostBrowserBundleID(
        for bundleID: String,
        hostBundleIDPrefixes: [String]
    ) -> String? {
        if hostBundleIDPrefixes.contains(bundleID) {
            return bundleID
        }

        for prefix in hostBundleIDPrefixes where bundleID.hasPrefix(prefix + ".app.") {
            return prefix
        }

        return nil
    }

    nonisolated static func isChromiumWebAppBundleID(
        _ bundleID: String,
        hostBundleIDPrefixes: [String]
    ) -> Bool {
        hostBundleIDPrefixes.contains { prefix in
            bundleID.hasPrefix(prefix + ".app.")
        }
    }
}
