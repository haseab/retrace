import Foundation

/// Build-time constants injected by build scripts.
///
/// This file is committed with sensible defaults so the app compiles without
/// running any script. `build_and_sign.sh`, `dev.sh`, and
/// `scripts/create-release.sh` overwrite the placeholder values before
/// invoking `swift build` / `xcodebuild`, then restore the defaults
/// afterwards so git stays clean.
///
/// Official releases (`create-release.sh`) leave `isDevBuild = false` so the
/// UI shows a clean version string.  Local builds (`build_and_sign.sh`,
/// `dev.sh`) set `isDevBuild = true` and populate fork/branch/commit so the
/// user can always tell exactly what they're running.
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

    /// Compact version string for space-constrained UI (sidebar, footer).
    /// Does not include the branch — use `displayBranch` for that.
    /// - Official: `v0.7.0`
    /// - Dev:      `v0.7.0-dev · 0eee7df`
    static var displayVersion: String {
        if isDevBuild {
            var s = "v\(version)-dev"
            if gitCommit != "unknown" { s += " · \(gitCommit)" }
            return s
        }
        return "v\(version)"
    }

    /// Full version with branch for prominent UI (updates card, menu bar).
    /// - Official: `0.7.0 (6)`
    /// - Dev:      `0.7.0-dev · 0eee7df (feature/version-visibility)`
    static var fullVersion: String {
        if isDevBuild {
            var s = "\(version)-dev"
            if gitCommit != "unknown" { s += " · \(gitCommit)" }
            if gitBranch != "unknown" { s += " (\(gitBranch))" }
            return s
        }
        return "\(version) (\(buildNumber))"
    }

    /// Branch name for dev builds (nil for official releases or when unknown).
    static var displayBranch: String? {
        guard isDevBuild, gitBranch != "unknown" else { return nil }
        return gitBranch
    }

    /// GitHub URL for the current commit (nil when metadata is unavailable).
    static var commitURL: URL? {
        guard gitCommitFull != "unknown", !forkName.isEmpty else { return nil }
        return URL(string: "https://github.com/\(forkName)/commit/\(gitCommitFull)")
    }

    /// Detailed multi-line string for the Developer card.
    /// Always shows all available metadata regardless of build type.
    static var developerVersion: String {
        var parts = ["v\(version)", "build \(buildNumber)"]
        if gitCommit != "unknown" { parts.append(gitCommit) }
        if gitBranch != "unknown" { parts.append(gitBranch) }
        if isDevBuild { parts.append("dev") }
        return parts.joined(separator: " · ")
    }
}
