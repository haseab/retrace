import AppKit
import Shared
import SwiftUI

/// Provides website favicons by fetching directly from the website itself (no third-party APIs).
/// PRIVACY: No browsing data is sent to any third party. Favicon requests go only to the
/// site the user already visited. Each domain is fetched once and cached to disk.
public class FaviconProvider {
    public static let shared = FaviconProvider()

    private static let maxMemoryCacheEntries = 128
    private static let maxDiskCacheBytes: Int64 = 128 * 1024 * 1024
    private static let diskEntryMaxAge: TimeInterval = 60 * 60 * 24 * 30
    private static let failedFetchMissTTL: TimeInterval = 10 * 60

    private let cache = ImageMemoryCache(countLimit: maxMemoryCacheEntries, totalCostLimit: 16 * 1024 * 1024)
    private let lock = NSLock()
    private let cacheFileURL: URL

    private var pendingRequests: Set<String> = []
    private var pendingCompletions: [String: [(NSImage?) -> Void]] = [:]
    private var recentMisses = LookupMissCache(maxEntries: 256)

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 10
        return URLSession(configuration: config)
    }()

    init(storageRoot: String = AppPaths.expandedStorageRoot) {
        cacheFileURL = Self.cacheDirectoryURL(storageRoot: storageRoot)
        try? FileManager.default.createDirectory(at: cacheFileURL, withIntermediateDirectories: true)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.pruneDiskCacheIfNeeded()
        }
    }

    public func favicon(for domain: String) -> NSImage? {
        let normalizedDomain = normalizeDomain(domain)
        guard !normalizedDomain.isEmpty else { return nil }
        return cache.image(for: normalizedDomain)
    }

    public func loadFaviconIfNeeded(
        for domain: String,
        completion: @escaping (NSImage?) -> Void
    ) {
        let normalizedDomain = normalizeDomain(domain)
        guard !normalizedDomain.isEmpty else {
            DispatchQueue.main.async { completion(nil) }
            return
        }

        if let cached = cache.image(for: normalizedDomain) {
            DispatchQueue.main.async { completion(cached) }
            return
        }

        lock.lock()
        if recentMisses.containsRecentMiss(for: normalizedDomain) {
            lock.unlock()
            DispatchQueue.main.async { completion(nil) }
            return
        }

        if pendingRequests.contains(normalizedDomain) {
            pendingCompletions[normalizedDomain, default: []].append(completion)
            lock.unlock()
            return
        }

        pendingRequests.insert(normalizedDomain)
        pendingCompletions[normalizedDomain] = [completion]
        lock.unlock()

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }

            if let image = self.loadImageFromDisk(for: normalizedDomain) {
                self.finishLoadedImage(image, domain: normalizedDomain)
                return
            }

            self.fetchFaviconFromWebsite(domain: normalizedDomain)
        }
    }

    public func fetchFaviconIfNeeded(
        for domain: String,
        completion: @escaping (NSImage?) -> Void
    ) {
        loadFaviconIfNeeded(for: domain, completion: completion)
    }

    static func cacheDirectoryURL(storageRoot: String = AppPaths.expandedStorageRoot) -> URL {
        let retraceDir = URL(fileURLWithPath: storageRoot)
        try? FileManager.default.createDirectory(at: retraceDir, withIntermediateDirectories: true)
        return retraceDir.appendingPathComponent("favicon_cache")
    }

    private func finishLoadedImage(_ image: NSImage, domain: String) {
        cache.set(image, for: domain)

        lock.lock()
        recentMisses.clearMiss(for: domain)
        let completions = pendingCompletions.removeValue(forKey: domain) ?? []
        pendingRequests.remove(domain)
        lock.unlock()

        DispatchQueue.main.async {
            for completion in completions {
                completion(image)
            }
        }
    }

    private func fetchFaviconFromWebsite(domain: String) {
        let baseURL = "https://\(domain)"
        guard let homepageURL = URL(string: baseURL) else {
            finishRequest(domain: domain)
            return
        }

        var request = URLRequest(url: homepageURL)
        request.setValue("text/html", forHTTPHeaderField: "Accept")

        session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }

            if let data,
               let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii),
               let faviconURL = self.parseFaviconURL(from: html, baseURL: baseURL) {
                self.downloadFaviconImage(from: faviconURL, domain: domain)
                return
            }

            let fallbackURL = "\(baseURL)/favicon.ico"
            guard let icoURL = URL(string: fallbackURL) else {
                self.finishRequest(domain: domain)
                return
            }

            self.downloadFaviconImage(from: icoURL, domain: domain)
        }.resume()
    }

    private func parseFaviconURL(from html: String, baseURL: String) -> URL? {
        let searchRange: String
        if let headEnd = html.range(of: "</head>", options: .caseInsensitive) {
            searchRange = String(html[html.startIndex..<headEnd.lowerBound])
        } else {
            let limit = html.index(html.startIndex, offsetBy: min(10_000, html.count))
            searchRange = String(html[html.startIndex..<limit])
        }

        let pattern = #"<link\s[^>]*rel\s*=\s*["']([^"']*)["'][^>]*href\s*=\s*["']([^"']*)["'][^>]*/?\s*>|<link\s[^>]*href\s*=\s*["']([^"']*)["'][^>]*rel\s*=\s*["']([^"']*)["'][^>]*/?\s*>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return nil
        }

        let nsRange = NSRange(searchRange.startIndex..., in: searchRange)
        let matches = regex.matches(in: searchRange, options: [], range: nsRange)

        var bestHref: String?
        var bestPriority = -1

        for match in matches {
            let rel: String
            let href: String

            if let relRange = Range(match.range(at: 1), in: searchRange),
               let hrefRange = Range(match.range(at: 2), in: searchRange) {
                rel = String(searchRange[relRange]).lowercased()
                href = String(searchRange[hrefRange])
            } else if let hrefRange = Range(match.range(at: 3), in: searchRange),
                      let relRange = Range(match.range(at: 4), in: searchRange) {
                rel = String(searchRange[relRange]).lowercased()
                href = String(searchRange[hrefRange])
            } else {
                continue
            }

            guard rel.contains("icon") else { continue }

            let priority: Int
            if rel.contains("apple-touch-icon") {
                priority = 2
            } else if rel == "icon" {
                priority = 1
            } else {
                priority = 0
            }

            if priority > bestPriority {
                bestPriority = priority
                bestHref = href
            }
        }

        guard let href = bestHref else { return nil }
        return resolveURL(href, baseURL: baseURL)
    }

    private func resolveURL(_ href: String, baseURL: String) -> URL? {
        if href.hasPrefix("//") {
            return URL(string: "https:\(href)")
        }
        if href.hasPrefix("http://") || href.hasPrefix("https://") {
            return URL(string: href)
        }
        if href.hasPrefix("/") {
            return URL(string: "\(baseURL)\(href)")
        }
        return URL(string: "\(baseURL)/\(href)")
    }

    private func downloadFaviconImage(from url: URL, domain: String) {
        let isFallback = url.path == "/favicon.ico"

        session.dataTask(with: url) { [weak self] data, response, _ in
            guard let self else { return }

            guard let data,
                  let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode),
                  let image = NSImage(data: data) else {
                if !isFallback {
                    let fallbackURL = "https://\(domain)/favicon.ico"
                    if let icoURL = URL(string: fallbackURL) {
                        self.downloadFaviconImage(from: icoURL, domain: domain)
                        return
                    }
                }
                self.finishRequest(domain: domain)
                return
            }

            self.finishLoadedImage(image, domain: domain)
            self.saveToDiskAsync(domain: domain, data: data)
        }.resume()
    }

    private func finishRequest(domain: String) {
        lock.lock()
        recentMisses.recordMiss(for: domain, ttl: Self.failedFetchMissTTL)
        let completions = pendingCompletions.removeValue(forKey: domain) ?? []
        pendingRequests.remove(domain)
        lock.unlock()

        DispatchQueue.main.async {
            for completion in completions {
                completion(nil)
            }
        }
    }

    private func normalizeDomain(_ domain: String) -> String {
        var normalized = domain.lowercased()

        if let range = normalized.range(of: "://") {
            normalized = String(normalized[range.upperBound...])
        }
        if normalized.hasPrefix("www.") {
            normalized = String(normalized.dropFirst(4))
        }
        if let slashIndex = normalized.firstIndex(of: "/") {
            normalized = String(normalized[..<slashIndex])
        }
        if let colonIndex = normalized.firstIndex(of: ":") {
            normalized = String(normalized[..<colonIndex])
        }

        return normalized.trimmingCharacters(in: .whitespaces)
    }

    private func loadImageFromDisk(for domain: String) -> NSImage? {
        let fileURL = cacheFileURL.appendingPathComponent("\(domain).png")
        guard let data = try? Data(contentsOf: fileURL),
              let image = NSImage(data: data) else {
            return nil
        }
        return image
    }

    private func saveToDiskAsync(domain: String, data: Data) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }

            let fileURL = self.cacheFileURL.appendingPathComponent("\(domain).png")
            try? data.write(to: fileURL, options: .atomic)
            self.pruneDiskCacheIfNeeded()
        }
    }

    private func pruneDiskCacheIfNeeded() {
        let resourceKeys: Set<URLResourceKey> = [
            .contentModificationDateKey,
            .fileSizeKey,
            .isRegularFileKey
        ]

        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: cacheFileURL,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let now = Date()
        var totalBytes: Int64 = 0
        var retainedEntries: [(url: URL, modifiedAt: Date, size: Int64)] = []

        for fileURL in contents {
            guard let resourceValues = try? fileURL.resourceValues(forKeys: resourceKeys),
                  resourceValues.isRegularFile == true else {
                continue
            }

            let modifiedAt = resourceValues.contentModificationDate ?? .distantPast
            let size = Int64(resourceValues.fileSize ?? 0)
            if now.timeIntervalSince(modifiedAt) > Self.diskEntryMaxAge {
                try? FileManager.default.removeItem(at: fileURL)
                continue
            }

            retainedEntries.append((url: fileURL, modifiedAt: modifiedAt, size: size))
            totalBytes = clampedAdd(totalBytes, size)
        }

        guard totalBytes > Self.maxDiskCacheBytes else {
            return
        }

        for entry in retainedEntries.sorted(by: { $0.modifiedAt < $1.modifiedAt }) {
            guard totalBytes > Self.maxDiskCacheBytes else { break }
            try? FileManager.default.removeItem(at: entry.url)
            totalBytes -= entry.size
        }
    }

    public func clearCache() {
        cache.removeAll()

        lock.lock()
        pendingRequests.removeAll()
        pendingCompletions.removeAll()
        recentMisses.removeAll()
        lock.unlock()

        try? FileManager.default.removeItem(at: cacheFileURL)
        try? FileManager.default.createDirectory(at: cacheFileURL, withIntermediateDirectories: true)
    }

    public var cacheCount: Int {
        cache.count
    }
}

/// SwiftUI view that displays a favicon for a website domain.
public struct FaviconView: View {
    let domain: String
    let size: CGFloat
    let fallbackColor: Color

    @State private var favicon: NSImage? = nil
    @State private var hasFetched = false

    public init(domain: String, size: CGFloat = 16, fallbackColor: Color = .retraceSecondary) {
        self.domain = domain
        self.size = size
        self.fallbackColor = fallbackColor
    }

    public var body: some View {
        Group {
            if let favicon {
                Image(nsImage: favicon)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.15))
                    .frame(width: size * 0.85, height: size * 0.85)
            } else {
                Circle()
                    .fill(fallbackColor.opacity(0.5))
                    .frame(width: size * 0.4, height: size * 0.4)
            }
        }
        .frame(width: size, height: size)
        .onAppear {
            loadFavicon()
        }
    }

    private func loadFavicon() {
        if let cached = FaviconProvider.shared.favicon(for: domain) {
            favicon = cached
            return
        }

        guard !hasFetched else { return }
        hasFetched = true

        FaviconProvider.shared.loadFaviconIfNeeded(for: domain) { image in
            favicon = image
        }
    }
}
