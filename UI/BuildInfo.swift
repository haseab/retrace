import Foundation

private enum EmbeddedBuildMetadata {
    static let version = "dev"
    static let buildNumber = "unknown"
    static let gitCommit = "unknown"
    static let gitCommitFull = "unknown"
    static let gitBranch = "unknown"
    static let buildDate = "unknown"
    static let forkName = ""
}

/// Build metadata used by UI version surfaces.
///
/// Resolution order:
/// 1. Environment variables (for explicit local overrides)
/// 2. Bundle Info.plist keys (for packaged apps)
/// 3. Generic embedded defaults for standalone SwiftPM builds
public enum BuildInfo {
    // MARK: - Defaults

    private static let defaultVersion = "dev"
    private static let defaultGitCommit = "unknown"
    private static let defaultGitCommitFull = "unknown"
    private static let defaultGitBranch = "unknown"
    private static let defaultBuildConfig = "unknown"
    private static let executablePath = Bundle.main.executablePath ?? CommandLine.arguments.first ?? ""
    private static let bundlePath = Bundle.main.bundlePath

    // MARK: - Raw values

    static var version: String {
        resolveString(
            envKey: "RETRACE_VERSION",
            bundleKeys: ["CFBundleShortVersionString", "RetraceVersion"],
            defaultValue: EmbeddedBuildMetadata.version,
            rejectBuildPlaceholders: true
        )
    }

    static var buildNumber: String {
        resolveString(
            envKey: "RETRACE_BUILD_NUMBER",
            bundleKeys: ["CFBundleVersion", "RetraceBuildNumber"],
            defaultValue: EmbeddedBuildMetadata.buildNumber,
            rejectBuildPlaceholders: true
        )
    }

    static var gitCommit: String {
        resolveString(
            envKey: "RETRACE_GIT_COMMIT",
            bundleKeys: ["RetraceGitCommit"],
            defaultValue: EmbeddedBuildMetadata.gitCommit
        )
    }

    static var gitCommitFull: String {
        resolveString(
            envKey: "RETRACE_GIT_COMMIT_FULL",
            bundleKeys: ["RetraceGitCommitFull"],
            defaultValue: EmbeddedBuildMetadata.gitCommitFull
        )
    }

    static var gitBranch: String {
        resolveString(
            envKey: "RETRACE_GIT_BRANCH",
            bundleKeys: ["RetraceGitBranch"],
            defaultValue: EmbeddedBuildMetadata.gitBranch
        )
    }

    static var buildDate: String {
        resolveString(
            envKey: "RETRACE_BUILD_DATE",
            bundleKeys: ["RetraceBuildDate"],
            defaultValue: EmbeddedBuildMetadata.buildDate
        )
    }

    static var buildConfig: String {
        resolveString(
            envKey: "RETRACE_BUILD_CONFIG",
            bundleKeys: ["RetraceBuildConfig"],
            defaultValue: inferredBuildConfig()
        )
    }

    static var isDevBuild: Bool {
        resolveBool(
            envKey: "RETRACE_IS_DEV_BUILD",
            bundleKey: "RetraceIsDevBuild",
            defaultValue: inferredIsDevBuild(buildConfig: buildConfig)
        )
    }

    static var forkName: String {
        resolveString(
            envKey: "RETRACE_FORK_NAME",
            bundleKeys: ["RetraceForkName"],
            defaultValue: EmbeddedBuildMetadata.forkName
        )
    }

    // MARK: - Derived properties

    /// Compact version string for space-constrained UI (sidebar, footer).
    /// Does not include the branch — use `displayBranch` for that.
    /// - Official: `v1.2.3`
    /// - Dev:      `v1.2.3-dev · 0eee7df`
    /// - Fallback: `dev · 0eee7df`
    static var displayVersion: String {
        makeDisplayVersion(version: version, isDevBuild: isDevBuild, gitCommit: gitCommit)
    }

    /// Full version with branch for prominent UI (updates card, menu bar).
    /// - Official: `1.2.3 (99)`
    /// - Dev:      `1.2.3-dev · 0eee7df (feature/version-visibility)`
    /// - Fallback: `dev · 0eee7df (feature/version-visibility)`
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
        if isFallbackDevVersion(version) {
            var s = defaultVersion
            if isDevBuild, gitCommit != defaultGitCommit { s += " · \(gitCommit)" }
            return s
        }

        guard isDevBuild else { return "v\(version)" }
        var s = "v\(version)-dev"
        if gitCommit != defaultGitCommit { s += " · \(gitCommit)" }
        return s
    }

    static func makeFullVersion(version: String, buildNumber: String, isDevBuild: Bool, gitCommit: String, gitBranch: String) -> String {
        if isFallbackDevVersion(version) {
            var s = defaultVersion
            if isDevBuild, gitCommit != defaultGitCommit { s += " · \(gitCommit)" }
            if isDevBuild, gitBranch != defaultGitBranch { s += " (\(gitBranch))" }
            return s
        }

        guard isDevBuild else { return "\(version) (\(buildNumber))" }
        var s = "\(version)-dev"
        if gitCommit != defaultGitCommit { s += " · \(gitCommit)" }
        if gitBranch != defaultGitBranch { s += " (\(gitBranch))" }
        return s
    }

    static func makeDisplayBranch(isDevBuild: Bool, gitBranch: String) -> String? {
        guard isDevBuild, gitBranch != defaultGitBranch else { return nil }
        return gitBranch
    }

    static func makeCommitURL(gitCommitFull: String, forkName: String) -> URL? {
        guard gitCommitFull != defaultGitCommitFull else { return nil }
        guard let repoPath = normalizeRepoPath(forkName) else { return nil }
        return URL(string: "https://github.com/\(repoPath)/commit/\(gitCommitFull)")
    }

    static func normalizeRepoPath(_ rawForkName: String) -> String? {
        var value = rawForkName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

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

    private static func isFallbackDevVersion(_ version: String) -> Bool {
        version == defaultVersion
    }

    private static func inferredBuildConfig() -> String {
        let normalized = [executablePath, bundlePath]
            .map { $0.lowercased() }
            .joined(separator: "\n")

        let debugMarkers = [
            "/.build/debug/",
            "/.build/arm64-apple-macosx/debug/",
            "/build/products/debug/"
        ]
        if debugMarkers.contains(where: normalized.contains) {
            return "debug"
        }

        let releaseMarkers = [
            "/.build/release/",
            "/.build/arm64-apple-macosx/release/",
            "/build/products/release/"
        ]
        if releaseMarkers.contains(where: normalized.contains) {
            return "release"
        }

        return defaultBuildConfig
    }

    private static func inferredIsDevBuild(buildConfig: String) -> Bool {
        let normalized = [executablePath, bundlePath]
            .map { $0.lowercased() }
            .joined(separator: "\n")

        if normalized.contains("/.build/") {
            return true
        }

        return buildConfig == "debug"
    }

    // MARK: - Value resolution

    private static func resolveString(
        envKey: String,
        bundleKeys: [String],
        defaultValue: @autoclosure () -> String,
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

        return defaultValue()
    }

    private static func resolveBool(
        envKey: String,
        bundleKey: String,
        defaultValue: @autoclosure () -> Bool
    ) -> Bool {
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

        return defaultValue()
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
