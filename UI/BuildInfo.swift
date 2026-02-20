import Foundation

/// Build-time constants injected by build scripts.
///
/// This file is committed with sensible defaults so the app compiles without
/// running any script. `build_and_sign.sh`, `dev.sh`, and
/// `scripts/create-release.sh` overwrite the placeholder values before
/// invoking `swift build` / `xcodebuild`, then restore the defaults
/// afterwards so git stays clean.
public enum BuildInfo {
    static let version = "0.7.0"
    static let buildNumber = "6"
    static let gitCommit = "unknown"
    static let gitCommitFull = "unknown"
    static let gitBranch = "unknown"
    static let buildDate = "unknown"
    static let buildConfig = "release"
    static let isDevBuild = false
    static let forkName = ""

    // MARK: - Derived properties

    /// User-facing version string, e.g. "v0.7.0"
    static var displayVersion: String { "v\(version)" }

    /// Version with build number, e.g. "0.7.0 (6)"
    static var fullVersion: String { "\(version) (\(buildNumber))" }

    /// Detailed string for developer/debug views
    static var developerVersion: String {
        var parts = ["v\(version)", "build \(buildNumber)"]
        if gitCommit != "unknown" { parts.append(gitCommit) }
        if isDevBuild { parts.append("dev") }
        return parts.joined(separator: " · ")
    }
}
