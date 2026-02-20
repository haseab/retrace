import Foundation
import Sparkle
import Shared

/// Manages the Sparkle updater for automatic app updates
/// This class wraps SPUStandardUpdaterController to provide a clean interface
/// for the rest of the app to interact with the update system.
public final class UpdaterManager: NSObject, ObservableObject {

    // MARK: - Changelog Model

    public struct ChangelogEntry: Identifiable, Equatable {
        public enum DetailBlock: Equatable, Sendable {
            case heading(level: Int, text: String)
            case paragraph(String)
            case bullet(String)
        }

        public let id: String
        public let title: String
        public let shortVersion: String?
        public let buildVersion: String?
        public let publishedAt: Date?
        public let detailsHTML: String?
        public let details: String
        public let detailBlocks: [DetailBlock]
        public let downloadURL: URL?

        public var displayVersion: String {
            if let shortVersion, !shortVersion.isEmpty {
                return shortVersion
            }
            if let buildVersion, !buildVersion.isEmpty {
                return buildVersion
            }
            return "Unknown"
        }
    }

    // MARK: - Singleton

    public static let shared = UpdaterManager()

    // MARK: - Properties

    /// The Sparkle updater controller
    private var updaterController: SPUStandardUpdaterController?
    private var changelogRefreshTask: Task<Void, Never>?

    private static let cachedAppcastDataDefaultsKey = "cachedAppcastXMLData"
    private static let cachedAppcastRefreshedAtDefaultsKey = "cachedAppcastLastRefreshDate"
    private static let whatsNewLastAutoUpdateDateDefaultsKey = "whatsNewLastAutoUpdateDate"
    private static let pendingAutoUpdateShortVersionDefaultsKey = "pendingAutoUpdateShortVersion"
    private static let pendingAutoUpdateBuildDefaultsKey = "pendingAutoUpdateBuild"
    private static let pendingAutoUpdateDownloadedAtDefaultsKey = "pendingAutoUpdateDownloadedAt"
    private static let whatsNewVisibilityWindow: TimeInterval = 60 * 60
    private static let pendingAutoUpdateMaxAge: TimeInterval = 24 * 60 * 60

    /// Whether automatic update checks are enabled.
    /// Default: true.
    @Published public var automaticUpdateChecksEnabled: Bool = true {
        didSet {
            updaterController?.updater.automaticallyChecksForUpdates = automaticUpdateChecksEnabled
        }
    }

    /// Whether updates are automatically downloaded and installed.
    /// Default: false.
    @Published public var automaticallyDownloadsUpdatesEnabled: Bool = false {
        didSet {
            updaterController?.updater.automaticallyDownloadsUpdates = automaticallyDownloadsUpdatesEnabled
        }
    }

    /// Whether the updater can check for updates (is properly configured)
    @Published public private(set) var canCheckForUpdates: Bool = false

    /// Whether an update check is currently in progress
    @Published public private(set) var isCheckingForUpdates: Bool = false

    /// The last time we checked for updates
    @Published public private(set) var lastUpdateCheckDate: Date?

    /// Parsed changelog entries from the full appcast feed.
    @Published public private(set) var changelogEntries: [ChangelogEntry] = []

    /// Last successful changelog refresh timestamp.
    @Published public private(set) var changelogLastRefreshDate: Date?

    /// Whether the appcast changelog is currently refreshing.
    @Published public private(set) var changelogIsRefreshing: Bool = false

    /// Last detected auto-update installation time used for "What's New" visibility.
    @Published public private(set) var whatsNewLastAutoUpdateDate: Date?

    // MARK: - Initialization

    private override init() {
        super.init()
        // Initialize will be called separately to ensure proper setup timing
        loadCachedChangelogIfAvailable()
        restoreWhatsNewPromptState()
    }

    /// Initialize the Sparkle updater
    /// Call this after the app has finished launching
    public func initialize() {
        // Skip updater in debug builds
        #if DEBUG
        Log.info("[UpdaterManager] Skipping updater initialization in DEBUG mode", category: .app)
        canCheckForUpdates = false
        return
        #else
        // Create the updater controller
        // startingUpdater: true - starts automatic update checks
        // updaterDelegate: self - receive update lifecycle callbacks for changelog refreshes
        // userDriverDelegate: nil - use default UI
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )

        // Check if properly configured
        canCheckForUpdates = updaterController?.updater.canCheckForUpdates ?? false

        // Sync updater settings
        if let updater = updaterController?.updater {
            automaticUpdateChecksEnabled = updater.automaticallyChecksForUpdates
            automaticallyDownloadsUpdatesEnabled = updater.automaticallyDownloadsUpdates
            lastUpdateCheckDate = updater.lastUpdateCheckDate
        }

        Log.info("[UpdaterManager] Initialized. Can check for updates: \(canCheckForUpdates)", category: .app)

        if !canCheckForUpdates {
            Log.warning("[UpdaterManager] Update checking is not available. Check SUFeedURL and SUPublicEDKey in Info.plist", category: .app)
        }
        #endif
    }

    // MARK: - Public Methods

    /// Manually check for updates
    /// This shows the update UI if an update is available
    public func checkForUpdates() {
        guard canCheckForUpdates else {
            Log.warning("[UpdaterManager] Cannot check for updates - updater not properly configured", category: .app)
            return
        }

        Log.info("[UpdaterManager] Checking for updates...", category: .app)
        isCheckingForUpdates = true

        // checkForUpdates shows UI and handles the entire update flow
        updaterController?.checkForUpdates(nil)

        // Update the last check date after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.isCheckingForUpdates = false
            self?.lastUpdateCheckDate = self?.updaterController?.updater.lastUpdateCheckDate
        }
    }

    /// Check for updates in the background without showing UI unless an update is found
    public func checkForUpdatesInBackground() {
        guard canCheckForUpdates else { return }

        Log.info("[UpdaterManager] Checking for updates in background...", category: .app)
        updaterController?.updater.checkForUpdatesInBackground()

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.lastUpdateCheckDate = self?.updaterController?.updater.lastUpdateCheckDate
        }
    }

    /// Run one background update check during startup.
    /// This respects the user's automatic update checks preference.
    public func checkForUpdatesOnStartup() {
        guard canCheckForUpdates else { return }
        guard automaticUpdateChecksEnabled else {
            Log.info("[UpdaterManager] Skipping startup update check because automatic checks are disabled", category: .app)
            return
        }

        Log.info("[UpdaterManager] Running startup update check...", category: .app)
        updaterController?.updater.checkForUpdatesInBackground()

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.lastUpdateCheckDate = self?.updaterController?.updater.lastUpdateCheckDate
        }
    }

    /// Refresh the changelog by fetching and parsing the full appcast XML.
    /// Uses coalescing so repeated triggers join a single in-flight refresh.
    public func refreshChangelogFromAppcast(reason: String = "manual") {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.refreshChangelogFromAppcast(reason: reason)
            }
            return
        }

        guard changelogRefreshTask == nil else {
            Log.debug("[UpdaterManager] Changelog refresh already in-flight; joined reason=\(reason)", category: .app)
            return
        }

        guard let feedURL = appcastFeedURL else {
            Log.warning("[UpdaterManager] Missing SUFeedURL; cannot refresh changelog", category: .app)
            return
        }

        changelogIsRefreshing = true
        changelogRefreshTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            let refreshStartTime = CFAbsoluteTimeGetCurrent()

            defer {
                Task { @MainActor [weak self] in
                    self?.changelogIsRefreshing = false
                    self?.changelogRefreshTask = nil
                }
            }

            do {
                var request = URLRequest(url: feedURL)
                request.cachePolicy = .reloadIgnoringLocalCacheData
                request.timeoutInterval = 20

                let fetchStartTime = CFAbsoluteTimeGetCurrent()
                let (data, response) = try await URLSession.shared.data(for: request)
                let fetchElapsedMs = (CFAbsoluteTimeGetCurrent() - fetchStartTime) * 1000
                guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
                    let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                    throw UpdaterError.httpError(statusCode: statusCode)
                }

                let parseStartTime = CFAbsoluteTimeGetCurrent()
                let entries = try Self.parseAppcastEntries(data: data)
                let parseElapsedMs = (CFAbsoluteTimeGetCurrent() - parseStartTime) * 1000
                let refreshedAt = Date()

                await MainActor.run {
                    self.changelogEntries = entries
                    self.changelogLastRefreshDate = refreshedAt
                    let defaults = UserDefaults.standard
                    defaults.set(data, forKey: Self.cachedAppcastDataDefaultsKey)
                    defaults.set(refreshedAt, forKey: Self.cachedAppcastRefreshedAtDefaultsKey)
                }

                let totalElapsedMs = (CFAbsoluteTimeGetCurrent() - refreshStartTime) * 1000
                Log.recordLatency(
                    "updater.changelog_refresh_fetch_ms",
                    valueMs: fetchElapsedMs,
                    category: .app,
                    summaryEvery: 5,
                    warningThresholdMs: 500,
                    criticalThresholdMs: 1500
                )
                Log.recordLatency(
                    "updater.changelog_refresh_parse_ms",
                    valueMs: parseElapsedMs,
                    category: .app,
                    summaryEvery: 5,
                    warningThresholdMs: 120,
                    criticalThresholdMs: 300
                )
                Log.recordLatency(
                    "updater.changelog_refresh_total_ms",
                    valueMs: totalElapsedMs,
                    category: .app,
                    summaryEvery: 5,
                    warningThresholdMs: 700,
                    criticalThresholdMs: 1800
                )
                Log.info(
                    "[UpdaterManager] Refreshed changelog from appcast entries=\(entries.count) bytes=\(data.count) reason=\(reason) fetchMs=\(Self.formatMs(fetchElapsedMs)) parseMs=\(Self.formatMs(parseElapsedMs)) totalMs=\(Self.formatMs(totalElapsedMs))",
                    category: .app
                )
            } catch {
                let totalElapsedMs = (CFAbsoluteTimeGetCurrent() - refreshStartTime) * 1000
                Log.warning("[UpdaterManager] Failed to refresh changelog reason=\(reason) error=\(error)", category: .app)
                Log.recordLatency(
                    "updater.changelog_refresh_failure_total_ms",
                    valueMs: totalElapsedMs,
                    category: .app,
                    summaryEvery: 5,
                    warningThresholdMs: 700,
                    criticalThresholdMs: 1800
                )
            }
        }
    }

    /// Get the current app version.
    /// Falls back to BuildInfo when the bundle value contains unresolved
    /// Xcode build-variable placeholders (e.g. `$(MARKETING_VERSION)`).
    public var currentVersion: String {
        let raw = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        if let raw, !raw.contains("$(") { return raw }
        return BuildInfo.version
    }

    /// Get the current build number.
    /// Same fallback logic as `currentVersion`.
    public var currentBuild: String {
        let raw = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        if let raw, !raw.contains("$(") { return raw }
        return BuildInfo.buildNumber
    }

    /// Whether the dashboard "What's New" shortcut should be visible.
    /// Visible only for one hour after an auto-installed update.
    public var shouldShowWhatsNew: Bool {
        guard automaticallyDownloadsUpdatesEnabled else { return false }
        guard let whatsNewLastAutoUpdateDate else { return false }
        return Self.isWithinWhatsNewWindow(since: whatsNewLastAutoUpdateDate)
    }

    // MARK: - Private

    private var appcastFeedURL: URL? {
        if let configuredFeed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
           let feedURL = URL(string: configuredFeed) {
            return feedURL
        }
        return URL(string: "https://retrace.to/appcast.xml")
    }

    private func loadCachedChangelogIfAvailable() {
        let defaults = UserDefaults.standard
        guard let cachedData = defaults.data(forKey: Self.cachedAppcastDataDefaultsKey) else { return }

        do {
            let parseStartTime = CFAbsoluteTimeGetCurrent()
            changelogEntries = try Self.parseAppcastEntries(data: cachedData)
            let parseElapsedMs = (CFAbsoluteTimeGetCurrent() - parseStartTime) * 1000
            changelogLastRefreshDate = defaults.object(forKey: Self.cachedAppcastRefreshedAtDefaultsKey) as? Date
            Log.recordLatency(
                "updater.changelog_cached_parse_ms",
                valueMs: parseElapsedMs,
                category: .app,
                summaryEvery: 10,
                warningThresholdMs: 100,
                criticalThresholdMs: 250
            )
            Log.info(
                "[UpdaterManager] Loaded cached changelog entries=\(changelogEntries.count) bytes=\(cachedData.count) parseMs=\(Self.formatMs(parseElapsedMs))",
                category: .app
            )
        } catch {
            Log.warning("[UpdaterManager] Failed to parse cached appcast changelog: \(error)", category: .app)
        }
    }

    private func restoreWhatsNewPromptState() {
        let defaults = UserDefaults.standard
        let now = Date()

        if let pendingDownloadedAt = defaults.object(forKey: Self.pendingAutoUpdateDownloadedAtDefaultsKey) as? Date,
           now.timeIntervalSince(pendingDownloadedAt) > Self.pendingAutoUpdateMaxAge {
            clearPendingAutoUpdateState()
        }

        if let pendingDownloadedAt = defaults.object(forKey: Self.pendingAutoUpdateDownloadedAtDefaultsKey) as? Date {
            let pendingShortVersion = defaults.string(forKey: Self.pendingAutoUpdateShortVersionDefaultsKey)
            let pendingBuildVersion = defaults.string(forKey: Self.pendingAutoUpdateBuildDefaultsKey)

            if isCurrentAppVersionMatching(shortVersion: pendingShortVersion, buildVersion: pendingBuildVersion) {
                whatsNewLastAutoUpdateDate = pendingDownloadedAt
                defaults.set(pendingDownloadedAt, forKey: Self.whatsNewLastAutoUpdateDateDefaultsKey)
                clearPendingAutoUpdateState()
                Log.info(
                    "[UpdaterManager] Promoted pending auto-update marker to What's New timestamp date=\(pendingDownloadedAt)",
                    category: .app
                )
            }
        }

        if let lastAutoUpdateDate = defaults.object(forKey: Self.whatsNewLastAutoUpdateDateDefaultsKey) as? Date {
            if Self.isWithinWhatsNewWindow(since: lastAutoUpdateDate) {
                whatsNewLastAutoUpdateDate = lastAutoUpdateDate
            } else {
                whatsNewLastAutoUpdateDate = nil
                defaults.removeObject(forKey: Self.whatsNewLastAutoUpdateDateDefaultsKey)
            }
        }
    }

    private func markPendingAutoUpdate(_ item: SUAppcastItem, downloadedAt: Date) {
        let defaults = UserDefaults.standard
        defaults.set(item.displayVersionString, forKey: Self.pendingAutoUpdateShortVersionDefaultsKey)
        defaults.set(item.versionString, forKey: Self.pendingAutoUpdateBuildDefaultsKey)
        defaults.set(downloadedAt, forKey: Self.pendingAutoUpdateDownloadedAtDefaultsKey)

        Log.info(
            "[UpdaterManager] Recorded pending auto-update shortVersion=\(item.displayVersionString) build=\(item.versionString) downloadedAt=\(downloadedAt)",
            category: .app
        )
    }

    private func clearPendingAutoUpdateState() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: Self.pendingAutoUpdateShortVersionDefaultsKey)
        defaults.removeObject(forKey: Self.pendingAutoUpdateBuildDefaultsKey)
        defaults.removeObject(forKey: Self.pendingAutoUpdateDownloadedAtDefaultsKey)
    }

    private func isCurrentAppVersionMatching(shortVersion: String?, buildVersion: String?) -> Bool {
        var hasVersionSignal = false

        if let shortVersion, !shortVersion.isEmpty {
            hasVersionSignal = true
            if shortVersion != currentVersion {
                return false
            }
        }

        if let buildVersion, !buildVersion.isEmpty {
            hasVersionSignal = true
            if buildVersion != currentBuild {
                return false
            }
        }

        return hasVersionSignal
    }

    private static func isWithinWhatsNewWindow(since date: Date, now: Date = Date()) -> Bool {
        let elapsed = now.timeIntervalSince(date)
        return elapsed >= 0 && elapsed <= whatsNewVisibilityWindow
    }

    private static func parseAppcastEntries(data: Data) throws -> [ChangelogEntry] {
        let parserDelegate = AppcastXMLParser()
        let parser = XMLParser(data: data)
        parser.delegate = parserDelegate

        guard parser.parse() else {
            throw parser.parserError ?? UpdaterError.invalidAppcast
        }

        return parserDelegate.items.map { item in
            let details = item.descriptionHTML
                .flatMap(renderReleaseNotesText(fromHTML:))
                .flatMap(normalizeReleaseNotesText(_:))
                ?? "No release notes available for this version yet."
            let detailBlocks = parseReleaseBlocks(
                descriptionHTML: item.descriptionHTML?.nonEmpty,
                fallbackText: details
            )

            let idSeed = [
                item.shortVersion,
                item.version,
                item.pubDate.map(String.init(describing:))
            ]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .joined(separator: "|")

            return ChangelogEntry(
                id: idSeed.isEmpty ? UUID().uuidString : idSeed,
                title: item.title?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "Version \(item.shortVersion?.nonEmpty ?? item.version?.nonEmpty ?? "Unknown")",
                shortVersion: item.shortVersion?.nonEmpty,
                buildVersion: item.version?.nonEmpty,
                publishedAt: item.pubDate.flatMap(parsePubDate(_:)),
                detailsHTML: item.descriptionHTML?.nonEmpty,
                details: details,
                detailBlocks: detailBlocks,
                downloadURL: item.enclosureURLString.flatMap(URL.init(string:))
            )
        }
    }

    private static func parsePubDate(_ value: String) -> Date? {
        pubDateFormatter.date(from: value)
    }

    private static let pubDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter
    }()

    private static func renderReleaseNotesText(fromHTML html: String) -> String? {
        guard let data = html.data(using: .utf8) else { return nil }
        let attributedText = try? NSAttributedString(
            data: data,
            options: [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue
            ],
            documentAttributes: nil
        )
        return attributedText?.string
    }

    private static func normalizeReleaseNotesText(_ rawText: String) -> String? {
        let normalizedLines = rawText
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !normalizedLines.isEmpty else { return nil }
        return normalizedLines.joined(separator: "\n")
    }

    private static func parseReleaseBlocks(
        descriptionHTML: String?,
        fallbackText: String
    ) -> [ChangelogEntry.DetailBlock] {
        if let descriptionHTML = descriptionHTML?.trimmingCharacters(in: .whitespacesAndNewlines),
           !descriptionHTML.isEmpty {
            let parsedHTMLBlocks = parseHTMLBlocks(descriptionHTML)
            if !parsedHTMLBlocks.isEmpty {
                return parsedHTMLBlocks
            }
        }

        let fallbackBlocks = parseFallbackBlocks(fallbackText)
        if !fallbackBlocks.isEmpty {
            return fallbackBlocks
        }

        return [.paragraph("No release notes available for this version yet.")]
    }

    private static func parseHTMLBlocks(_ html: String) -> [ChangelogEntry.DetailBlock] {
        guard let regex = try? NSRegularExpression(
            pattern: #"(?is)<(h2|h3|p|li)\b[^>]*>(.*?)</\1>"#
        ) else {
            return []
        }

        let nsHTML = html as NSString
        let matches = regex.matches(
            in: html,
            range: NSRange(location: 0, length: nsHTML.length)
        )

        var result: [ChangelogEntry.DetailBlock] = []
        result.reserveCapacity(matches.count)

        for match in matches {
            guard match.numberOfRanges >= 3 else { continue }

            let tag = nsHTML.substring(with: match.range(at: 1)).lowercased()
            let rawContent = nsHTML.substring(with: match.range(at: 2))
            let decodedText = decodeHTMLFragment(rawContent)
            let normalizedText = normalizeWhitespace(decodedText)
            guard !normalizedText.isEmpty else { continue }

            switch tag {
            case "h2":
                result.append(.heading(level: 2, text: normalizedText))
            case "h3":
                result.append(.heading(level: 3, text: normalizedText))
            case "li":
                result.append(.bullet(normalizedText))
            default:
                result.append(.paragraph(normalizedText))
            }
        }

        return result
    }

    private static func parseFallbackBlocks(_ text: String) -> [ChangelogEntry.DetailBlock] {
        let lines = text.components(separatedBy: .newlines)
        var result: [ChangelogEntry.DetailBlock] = []
        result.reserveCapacity(lines.count)

        for rawLine in lines {
            let line = normalizeWhitespace(rawLine)
            guard !line.isEmpty else { continue }

            if line.hasPrefix("• ") || line.hasPrefix("- ") {
                let bulletText = line.dropFirst(2).trimmingCharacters(in: .whitespacesAndNewlines)
                if !bulletText.isEmpty {
                    result.append(.bullet(String(bulletText)))
                }
                continue
            }

            if line.count <= 60,
               line.range(of: #"^[A-Z][^:]{2,}:?$"#, options: .regularExpression) != nil {
                result.append(.heading(level: 3, text: line))
                continue
            }

            result.append(.paragraph(line))
        }

        return result
    }

    private static func decodeHTMLFragment(_ fragment: String) -> String {
        let wrapped = "<div>\(fragment)</div>"
        guard let data = wrapped.data(using: .utf8),
              let attributed = try? NSAttributedString(
                data: data,
                options: [
                    .documentType: NSAttributedString.DocumentType.html,
                    .characterEncoding: String.Encoding.utf8.rawValue
                ],
                documentAttributes: nil
              ) else {
            return fragment
        }

        return attributed.string
    }

    private static func normalizeWhitespace(_ text: String) -> String {
        let deNBSP = text.replacingOccurrences(of: "\u{00A0}", with: " ")
        let normalized = deNBSP
            .replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\n{2,}", with: "\n", options: .regularExpression)

        return normalized.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func formatMs(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
}

extension UpdaterManager: SPUUpdaterDelegate {
    public func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        let autoDownloadsEnabled = updater.automaticallyDownloadsUpdates || automaticallyDownloadsUpdatesEnabled
        if autoDownloadsEnabled {
            let downloadedAt = Date()
            markPendingAutoUpdate(item, downloadedAt: downloadedAt)
        } else {
            Log.info("[UpdaterManager] Update downloaded with automatic installs disabled; skipping What's New marker", category: .app)
        }
        refreshChangelogFromAppcast(reason: "did_download_update")
    }

    public func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        if Thread.isMainThread {
            isCheckingForUpdates = false
            lastUpdateCheckDate = updater.lastUpdateCheckDate
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.isCheckingForUpdates = false
                self?.lastUpdateCheckDate = updater.lastUpdateCheckDate
            }
        }
    }
}

private enum UpdaterError: Error {
    case invalidAppcast
    case httpError(statusCode: Int)
}

private struct AppcastParsedItem {
    var title: String?
    var version: String?
    var shortVersion: String?
    var pubDate: String?
    var descriptionHTML: String?
    var enclosureURLString: String?
}

private final class AppcastXMLParser: NSObject, XMLParserDelegate {
    private(set) var items: [AppcastParsedItem] = []

    private var currentItem: AppcastParsedItem?
    private var currentValue = ""

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let normalizedName = Self.normalizedElementName(qName ?? elementName)
        currentValue = ""

        if normalizedName == "item" {
            currentItem = AppcastParsedItem()
            return
        }

        guard currentItem != nil else { return }
        if normalizedName == "enclosure" {
            currentItem?.enclosureURLString = attributeDict["url"]
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentValue += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let normalizedName = Self.normalizedElementName(qName ?? elementName)
        guard currentItem != nil else { return }

        let trimmedValue = currentValue.trimmingCharacters(in: .whitespacesAndNewlines)

        switch normalizedName {
        case "title":
            currentItem?.title = trimmedValue
        case "version":
            currentItem?.version = trimmedValue
        case "shortVersionString":
            currentItem?.shortVersion = trimmedValue
        case "pubDate":
            currentItem?.pubDate = trimmedValue
        case "description":
            currentItem?.descriptionHTML = currentValue.trimmingCharacters(in: .whitespacesAndNewlines)
        case "item":
            if let currentItem {
                items.append(currentItem)
            }
            self.currentItem = nil
        default:
            break
        }

        currentValue = ""
    }

    private static func normalizedElementName(_ elementName: String) -> String {
        guard let separator = elementName.lastIndex(of: ":") else {
            return elementName
        }
        return String(elementName[elementName.index(after: separator)...])
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
