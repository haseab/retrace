import Foundation

/// Build metadata used by UI version surfaces.
///
/// Resolution order:
/// 1. Environment variables (for local `dev.sh` runs)
/// 2. Bundle Info.plist keys (for packaged apps)
/// 3. Committed defaults (safe compile-time fallback)
public enum BuildInfo {
    // MARK: - Defaults (compile-time fallback)

    private static let defaultVersion = "0.7.0"
    private static let defaultBuildNumber = "6"
    private static let defaultGitCommit = "unknown"
    private static let defaultGitCommitFull = "unknown"
    private static let defaultGitBranch = "unknown"
    private static let defaultBuildDate = "unknown"
    private static let defaultBuildConfig = "release"
    private static let defaultIsDevBuild = false
    private static let defaultForkName = ""

    // MARK: - Raw values

    static var version: String {
        resolveString(
            envKey: "RETRACE_VERSION",
            bundleKeys: ["CFBundleShortVersionString", "RetraceVersion"],
            defaultValue: defaultVersion,
            rejectBuildPlaceholders: true
        )
    }

    static var buildNumber: String {
        resolveString(
            envKey: "RETRACE_BUILD_NUMBER",
            bundleKeys: ["CFBundleVersion", "RetraceBuildNumber"],
            defaultValue: defaultBuildNumber,
            rejectBuildPlaceholders: true
        )
    }

    static var gitCommit: String {
        resolveString(
            envKey: "RETRACE_GIT_COMMIT",
            bundleKeys: ["RetraceGitCommit"],
            defaultValue: defaultGitCommit
        )
    }

    static var gitCommitFull: String {
        resolveString(
            envKey: "RETRACE_GIT_COMMIT_FULL",
            bundleKeys: ["RetraceGitCommitFull"],
            defaultValue: defaultGitCommitFull
        )
    }

    static var gitBranch: String {
        resolveString(
            envKey: "RETRACE_GIT_BRANCH",
            bundleKeys: ["RetraceGitBranch"],
            defaultValue: defaultGitBranch
        )
    }

    static var buildDate: String {
        resolveString(
            envKey: "RETRACE_BUILD_DATE",
            bundleKeys: ["RetraceBuildDate"],
            defaultValue: defaultBuildDate
        )
    }

    static var buildConfig: String {
        resolveString(
            envKey: "RETRACE_BUILD_CONFIG",
            bundleKeys: ["RetraceBuildConfig"],
            defaultValue: defaultBuildConfig
        )
    }

    static var isDevBuild: Bool {
        resolveBool(
            envKey: "RETRACE_IS_DEV_BUILD",
            bundleKey: "RetraceIsDevBuild",
            defaultValue: defaultIsDevBuild
        )
    }

    static var forkName: String {
        resolveString(
            envKey: "RETRACE_FORK_NAME",
            bundleKeys: ["RetraceForkName"],
            defaultValue: defaultForkName
        )
    }

    // MARK: - Derived properties

    /// Compact version string for space-constrained UI (sidebar, footer).
    /// Does not include the branch — use `displayBranch` for that.
    /// - Official: `v0.7.0`
    /// - Dev:      `v0.7.0-dev · 0eee7df`
    static var displayVersion: String {
        makeDisplayVersion(version: version, isDevBuild: isDevBuild, gitCommit: gitCommit)
    }

    /// Full version with branch for prominent UI (updates card, menu bar).
    /// - Official: `0.7.0 (6)`
    /// - Dev:      `0.7.0-dev · 0eee7df (feature/version-visibility)`
    static var fullVersion: String {
        makeFullVersion(
            version: version,
            buildNumber: buildNumber,
            isDevBuild: isDevBuild,
            gitCommit: gitCommit,
            gitBranch: gitBranch
        )
    }

    /// Branch name for dev builds (nil for official releases or when unknown).
    static var displayBranch: String? {
        makeDisplayBranch(isDevBuild: isDevBuild, gitBranch: gitBranch)
    }

    /// GitHub URL for the current commit (nil when metadata is unavailable).
    static var commitURL: URL? {
        makeCommitURL(gitCommitFull: gitCommitFull, forkName: forkName)
    }

    static func makeDisplayVersion(version: String, isDevBuild: Bool, gitCommit: String) -> String {
        guard isDevBuild else { return "v\(version)" }
        var s = "v\(version)-dev"
        if gitCommit != "unknown" { s += " · \(gitCommit)" }
        return s
    }

    static func makeFullVersion(version: String, buildNumber: String, isDevBuild: Bool, gitCommit: String, gitBranch: String) -> String {
        guard isDevBuild else { return "\(version) (\(buildNumber))" }
        var s = "\(version)-dev"
        if gitCommit != "unknown" { s += " · \(gitCommit)" }
        if gitBranch != "unknown" { s += " (\(gitBranch))" }
        return s
    }

    static func makeDisplayBranch(isDevBuild: Bool, gitBranch: String) -> String? {
        guard isDevBuild, gitBranch != "unknown" else { return nil }
        return gitBranch
    }

    static func makeCommitURL(gitCommitFull: String, forkName: String) -> URL? {
        guard gitCommitFull != "unknown" else { return nil }
        guard let repoPath = normalizeRepoPath(forkName) else { return nil }
        return URL(string: "https://github.com/\(repoPath)/commit/\(gitCommitFull)")
    }

    static func normalizeRepoPath(_ rawForkName: String) -> String? {
        var value = rawForkName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        // Handle common remote URL formats:
        // - git@github.com:owner/repo(.git)
        // - ssh://git@github.com/owner/repo(.git)
        // - https://github.com/owner/repo(.git)
        if let range = value.range(of: "github.com/") {
            value = String(value[range.upperBound...])
        } else if let range = value.range(of: "github.com:") {
            value = String(value[range.upperBound...])
        }

        if value.hasSuffix(".git") {
            value.removeLast(4)
        }

        let parts = value.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }
        return "\(parts[0])/\(parts[1])"
    }

    // MARK: - Value resolution

    private static func resolveString(
        envKey: String,
        bundleKeys: [String],
        defaultValue: String,
        rejectBuildPlaceholders: Bool = false
    ) -> String {
        if let value = ProcessInfo.processInfo.environment[envKey],
           isUsable(value, rejectBuildPlaceholders: rejectBuildPlaceholders) {
            return value
        }

        for key in bundleKeys {
            if let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
               isUsable(value, rejectBuildPlaceholders: rejectBuildPlaceholders) {
                return value
            }
        }

        return defaultValue
    }

    private static func resolveBool(envKey: String, bundleKey: String, defaultValue: Bool) -> Bool {
        if let raw = ProcessInfo.processInfo.environment[envKey],
           let parsed = parseBool(raw) {
            return parsed
        }

        if let raw = Bundle.main.object(forInfoDictionaryKey: bundleKey) as? NSNumber {
            return raw.boolValue
        }

        if let raw = Bundle.main.object(forInfoDictionaryKey: bundleKey) as? String,
           let parsed = parseBool(raw) {
            return parsed
        }

        return defaultValue
    }

    private static func isUsable(_ raw: String, rejectBuildPlaceholders: Bool) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard !(rejectBuildPlaceholders && trimmed.contains("$(")) else { return false }
        return true
    }

    private static func parseBool(_ raw: String) -> Bool? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "y", "on":
            return true
        case "0", "false", "no", "n", "off":
            return false
        default:
            return nil
        }
    }
}
