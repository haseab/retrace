import SwiftUI
import AppKit
import Shared

/// Retrace design system
/// Provides consistent colors, typography, and spacing across the UI
public struct AppTheme {
    private init() {}
}

// MARK: - App Name Resolution

/// Resolves bundle IDs to human-readable app names with caching
public class AppNameResolver {
    public static let shared = AppNameResolver()

    private var cache: [String: String] = [:]
    private let lock = NSLock()
    private let cacheFileURL: URL
    private var diskCache: [String: String] = [:]
    private var isDirty = false

    private init() {
        // Use AppPaths which respects custom storage location
        let retraceDir = URL(fileURLWithPath: AppPaths.expandedStorageRoot)
        try? FileManager.default.createDirectory(at: retraceDir, withIntermediateDirectories: true)
        cacheFileURL = retraceDir.appendingPathComponent("app_names.json")
        loadFromDisk()
    }

    /// Get a human-readable name for an app bundle ID
    public func displayName(for bundleID: String) -> String {
        lock.lock()
        defer { lock.unlock() }

        // Return from memory cache if available
        if let cached = cache[bundleID] {
            return cached
        }

        // Return from disk cache if available
        if let stored = diskCache[bundleID] {
            cache[bundleID] = stored
            return stored
        }

        // Resolve the name
        let name = resolveAppName(for: bundleID)
        cache[bundleID] = name

        // Save to disk cache
        saveToDiskAsync(bundleID: bundleID, name: name)

        return name
    }

    /// Resolve bundle ID to app name using multiple strategies
    private func resolveAppName(for bundleID: String) -> String {
        // Strategy 1: Look up the actual app name from the system
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
           let bundle = Bundle(url: appURL),
           let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                   ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String {
            return name
        }

        // Strategy 2: Handle standard reverse-DNS bundle IDs (e.g., com.google.Chrome -> Chrome)
        if bundleID.contains(".") {
            let components = bundleID.components(separatedBy: ".")
            if components.count >= 2,
               let lastComponent = components.last,
               !lastComponent.isEmpty,
               lastComponent.first?.isLetter == true {
                // Capitalize first letter if needed
                return lastComponent.prefix(1).uppercased() + lastComponent.dropFirst()
            }
        }

        // Strategy 3: Handle non-standard identifiers (e.g., "230313mzl4w4u92")
        // Check if it looks like a random/hash identifier
        if looksLikeRandomIdentifier(bundleID) {
            return "Unknown App"
        }

        // Strategy 4: Clean up and return as-is for other cases
        return cleanupName(bundleID)
    }

    /// Check if a string looks like a random/generated identifier
    private func looksLikeRandomIdentifier(_ identifier: String) -> Bool {
        // If it starts with a number, it's likely a random ID
        if identifier.first?.isNumber == true {
            return true
        }

        // If it's mostly alphanumeric with no clear word structure
        let letterCount = identifier.filter { $0.isLetter }.count
        let numberCount = identifier.filter { $0.isNumber }.count

        // High ratio of numbers to letters suggests a random ID
        if letterCount > 0 && Double(numberCount) / Double(letterCount) > 0.5 {
            return true
        }

        // Very short or very long without dots suggests random
        if !identifier.contains(".") && (identifier.count < 3 || identifier.count > 20) {
            return true
        }

        return false
    }

    /// Clean up an identifier for display
    private func cleanupName(_ identifier: String) -> String {
        // Replace common separators with spaces
        var cleaned = identifier
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")

        // Capitalize words
        cleaned = cleaned.split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
            .joined(separator: " ")

        return cleaned.isEmpty ? "Unknown App" : cleaned
    }

    // MARK: - Installed Apps

    /// Check if an app is currently installed (can be found by NSWorkspace)
    public func isInstalled(bundleID: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    /// Get all currently installed apps from /Applications (instant, no DB query needed)
    /// Returns array of AppInfo with bundleID and name
    /// Also pre-warms the icon cache for instant popover display
    public func getInstalledApps() -> [AppInfo] {
        let startTime = CFAbsoluteTimeGetCurrent()
        var apps: [AppInfo] = []
        let fm = FileManager.default

        let appFolders = [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/System/Applications"),
            fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
            fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Chrome Apps.localized")
        ]

        for folder in appFolders {
            guard let contents = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else {
                continue
            }

            for appURL in contents where appURL.pathExtension == "app" {
                let plistURL = appURL.appendingPathComponent("Contents/Info.plist")
                guard let plist = NSDictionary(contentsOf: plistURL),
                      let bundleID = plist["CFBundleIdentifier"] as? String,
                      !bundleID.isEmpty else {
                    continue
                }

                // Get display name
                let name: String
                if let displayName = plist["CFBundleDisplayName"] as? String, !displayName.isEmpty {
                    name = displayName
                } else if let bundleName = plist["CFBundleName"] as? String, !bundleName.isEmpty {
                    name = bundleName
                } else {
                    name = appURL.deletingPathExtension().lastPathComponent
                }

                apps.append(AppInfo(bundleID: bundleID, name: name))

                // Also cache the name for later lookups
                lock.lock()
                cache[bundleID] = name
                lock.unlock()

                // Pre-warm icon cache using the app URL we already have
                AppIconProvider.shared.preloadIcon(for: bundleID, appURL: appURL)
            }
        }

        let elapsed = Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000)
        #if DEBUG
        print("[AppNameResolver] getInstalledApps: found \(apps.count) apps in \(elapsed)ms, icon cache size: \(AppIconProvider.shared.cacheCount)")
        #endif

        return apps
    }

    /// Resolve multiple bundle IDs to AppInfo objects
    /// - Parameter bundleIDs: Array of bundle identifiers
    /// - Returns: Array of AppInfo with resolved names
    public func resolveAll(bundleIDs: [String]) -> [AppInfo] {
        return bundleIDs.map { bundleID in
            AppInfo(bundleID: bundleID, name: displayName(for: bundleID))
        }
    }

    // MARK: - Disk Persistence

    private func loadFromDisk() {
        guard FileManager.default.fileExists(atPath: cacheFileURL.path) else { return }
        do {
            let data = try Data(contentsOf: cacheFileURL)
            diskCache = try JSONDecoder().decode([String: String].self, from: data)
        } catch {
            // Silently fail
        }
    }

    private func saveToDiskAsync(bundleID: String, name: String) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            self.diskCache[bundleID] = name
            self.isDirty = true
            self.lock.unlock()
            self.flushToDiskIfNeeded()
        }
    }

    private func flushToDiskIfNeeded() {
        lock.lock()
        guard isDirty else {
            lock.unlock()
            return
        }
        let cacheToSave = diskCache
        isDirty = false
        lock.unlock()

        do {
            let data = try JSONEncoder().encode(cacheToSave)
            try data.write(to: cacheFileURL, options: .atomic)
        } catch {
            // Silently fail
        }
    }

    /// Clear all cached app names (both memory and disk)
    /// Call this when app names appear stale or incorrect
    /// - Returns: Number of entries cleared from cache
    @discardableResult
    public func clearCache() -> Int {
        lock.lock()
        let entriesCleared = cache.count + diskCache.count
        cache.removeAll()
        diskCache.removeAll()
        isDirty = false
        lock.unlock()

        // Delete the disk cache file
        try? FileManager.default.removeItem(at: cacheFileURL)

        // Also clear the "other apps" cache file
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let otherAppsCache = cacheDir.appendingPathComponent("other_apps_cache.json")
        try? FileManager.default.removeItem(at: otherAppsCache)

        // Clear the timestamp so it will be refreshed
        UserDefaults.standard.removeObject(forKey: "search.otherAppsCacheSavedAt")

        #if DEBUG
        print("[AppNameResolver] Cache cleared (\(entriesCleared) entries)")
        #endif
        return entriesCleared
    }
}

// MARK: - App Icon Provider

/// Provides app icons for bundle IDs with caching
public class AppIconProvider {
    public static let shared = AppIconProvider()

    private var cache: [String: NSImage] = [:]
    private let lock = NSLock()

    private init() {}

    /// Get the app icon for a bundle ID as an NSImage
    public func icon(for bundleID: String) -> NSImage? {
        lock.lock()
        defer { lock.unlock() }

        // Return from cache if available
        if let cached = cache[bundleID] {
            return cached
        }

        // Cache miss - need to resolve (this is slow!)
        let startTime = CFAbsoluteTimeGetCurrent()

        // Try to get the icon from the system
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let icon = NSWorkspace.shared.icon(forFile: appURL.path)
            cache[bundleID] = icon
            #if DEBUG
            print("[AppIconProvider] CACHE MISS for \(bundleID) - resolved in \(Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000))ms")
            #endif
            return icon
        }

        #if DEBUG
        print("[AppIconProvider] CACHE MISS for \(bundleID) - not found, took \(Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000))ms")
        #endif
        return nil
    }

    /// Pre-load an icon into cache when we already have the app URL
    /// This avoids the NSWorkspace lookup when iterating through /Applications
    public func preloadIcon(for bundleID: String, appURL: URL) {
        lock.lock()
        defer { lock.unlock() }

        // Skip if already cached
        guard cache[bundleID] == nil else { return }

        let icon = NSWorkspace.shared.icon(forFile: appURL.path)
        cache[bundleID] = icon
    }

    /// Debug: Get current cache size
    public var cacheCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return cache.count
    }
}

// MARK: - Favicon Provider

/// Provides website favicons using Google's favicon API with caching
public class FaviconProvider {
    public static let shared = FaviconProvider()

    private var cache: [String: NSImage] = [:]
    private var pendingRequests: Set<String> = []
    private let lock = NSLock()
    private let cacheFileURL: URL
    private var diskCache: [String: Data] = [:]

    private init() {
        // Store favicon cache in AppPaths.storageRoot (respects custom location)
        let retraceDir = URL(fileURLWithPath: AppPaths.expandedStorageRoot)
        try? FileManager.default.createDirectory(at: retraceDir, withIntermediateDirectories: true)
        cacheFileURL = retraceDir.appendingPathComponent("favicon_cache")

        // Create favicon cache directory
        try? FileManager.default.createDirectory(at: cacheFileURL, withIntermediateDirectories: true)

        // Load existing cache from disk
        loadFromDisk()
    }

    /// Get the favicon for a domain synchronously (returns cached image or nil)
    public func favicon(for domain: String) -> NSImage? {
        let normalizedDomain = normalizeDomain(domain)
        guard !normalizedDomain.isEmpty else { return nil }

        lock.lock()
        defer { lock.unlock() }

        // Return from memory cache if available
        if let cached = cache[normalizedDomain] {
            return cached
        }

        // Return from disk cache if available
        if let imageData = diskCache[normalizedDomain],
           let image = NSImage(data: imageData) {
            cache[normalizedDomain] = image
            return image
        }

        return nil
    }

    /// Fetch favicon asynchronously if not cached
    public func fetchFaviconIfNeeded(for domain: String, completion: @escaping (NSImage?) -> Void) {
        let normalizedDomain = normalizeDomain(domain)
        guard !normalizedDomain.isEmpty else {
            completion(nil)
            return
        }

        lock.lock()

        // Already cached in memory
        if let cached = cache[normalizedDomain] {
            lock.unlock()
            completion(cached)
            return
        }

        // Already cached on disk
        if let imageData = diskCache[normalizedDomain],
           let image = NSImage(data: imageData) {
            cache[normalizedDomain] = image
            lock.unlock()
            completion(image)
            return
        }

        // Already fetching
        if pendingRequests.contains(normalizedDomain) {
            lock.unlock()
            completion(nil)
            return
        }

        pendingRequests.insert(normalizedDomain)
        lock.unlock()

        // Fetch from Google's favicon API
        // Using size 64 for good quality on retina displays
        let urlString = "https://www.google.com/s2/favicons?domain=\(normalizedDomain)&sz=64"
        guard let url = URL(string: urlString) else {
            lock.lock()
            pendingRequests.remove(normalizedDomain)
            lock.unlock()
            completion(nil)
            return
        }

        URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            guard let self = self else { return }

            self.lock.lock()
            self.pendingRequests.remove(normalizedDomain)

            guard let data = data,
                  let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200,
                  let image = NSImage(data: data) else {
                self.lock.unlock()
                DispatchQueue.main.async { completion(nil) }
                return
            }

            // Cache in memory and disk
            self.cache[normalizedDomain] = image
            self.diskCache[normalizedDomain] = data
            self.lock.unlock()

            // Save to disk asynchronously
            self.saveToDiskAsync(domain: normalizedDomain, data: data)

            DispatchQueue.main.async { completion(image) }
        }.resume()
    }

    /// Normalize domain name (remove protocol, www, and path)
    private func normalizeDomain(_ domain: String) -> String {
        var normalized = domain.lowercased()

        // Remove protocol
        if let range = normalized.range(of: "://") {
            normalized = String(normalized[range.upperBound...])
        }

        // Remove www.
        if normalized.hasPrefix("www.") {
            normalized = String(normalized.dropFirst(4))
        }

        // Remove path
        if let slashIndex = normalized.firstIndex(of: "/") {
            normalized = String(normalized[..<slashIndex])
        }

        // Remove port
        if let colonIndex = normalized.firstIndex(of: ":") {
            normalized = String(normalized[..<colonIndex])
        }

        return normalized.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Disk Persistence

    private func loadFromDisk() {
        guard FileManager.default.fileExists(atPath: cacheFileURL.path) else { return }

        do {
            let contents = try FileManager.default.contentsOfDirectory(at: cacheFileURL, includingPropertiesForKeys: nil)
            for fileURL in contents {
                let domain = fileURL.deletingPathExtension().lastPathComponent
                if let data = try? Data(contentsOf: fileURL) {
                    diskCache[domain] = data
                }
            }
        } catch {
            // Silently fail - will re-fetch as needed
        }
    }

    private func saveToDiskAsync(domain: String, data: Data) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }

            let fileURL = self.cacheFileURL.appendingPathComponent("\(domain).png")
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    /// Clear all cached favicons
    public func clearCache() {
        lock.lock()
        cache.removeAll()
        diskCache.removeAll()
        lock.unlock()

        // Delete disk cache
        try? FileManager.default.removeItem(at: cacheFileURL)
        try? FileManager.default.createDirectory(at: cacheFileURL, withIntermediateDirectories: true)
    }

    /// Debug: Get current cache size
    public var cacheCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return cache.count
    }
}

/// SwiftUI view that displays a favicon for a website domain
public struct FaviconView: View {
    let domain: String
    let size: CGFloat
    let fallbackColor: Color

    @State private var favicon: NSImage? = nil
    @State private var hasFetched: Bool = false

    public init(domain: String, size: CGFloat = 16, fallbackColor: Color = .retraceSecondary) {
        self.domain = domain
        self.size = size
        self.fallbackColor = fallbackColor
    }

    public var body: some View {
        Group {
            if let favicon = favicon {
                Image(nsImage: favicon)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.15))
                    .frame(width: size * 0.85, height: size * 0.85) // Scale down to match app icon visual size
            } else {
                // Fallback: colored circle (same as current dot indicator)
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
        // First try synchronous cache lookup
        if let cached = FaviconProvider.shared.favicon(for: domain) {
            self.favicon = cached
            return
        }

        // Then fetch asynchronously if not already fetched
        guard !hasFetched else { return }
        hasFetched = true

        FaviconProvider.shared.fetchFaviconIfNeeded(for: domain) { image in
            self.favicon = image
        }
    }
}

/// SwiftUI view that displays an app icon for a bundle ID
public struct AppIconView: View {
    let bundleID: String
    let size: CGFloat

    public init(bundleID: String, size: CGFloat = 32) {
        self.bundleID = bundleID
        self.size = size
    }

    public var body: some View {
        Group {
            if let nsImage = AppIconProvider.shared.icon(for: bundleID) {
                Image(nsImage: nsImage)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                // Fallback: colored rounded square with first letter
                fallbackIcon
            }
        }
        .frame(width: size, height: size)
    }

    private var fallbackIcon: some View {
        let appName = AppNameResolver.shared.displayName(for: bundleID)
        let firstLetter = appName.first.map { String($0).uppercased() } ?? "?"
        let color = Color.segmentColor(for: bundleID)

        return ZStack {
            RoundedRectangle(cornerRadius: size * 0.22)
                .fill(color.opacity(0.2))

            RoundedRectangle(cornerRadius: size * 0.22)
                .stroke(color.opacity(0.3), lineWidth: 1)

            Text(firstLetter)
                .font(RetraceFont.font(size: size * 0.45, weight: .semibold))
                .foregroundColor(color)
        }
    }
}

// MARK: - App Icon Color Extraction

/// Storable color data for persistence
private struct StoredColor: Codable {
    let hue: Double
    let saturation: Double
    let brightness: Double

    var color: Color {
        Color(hue: hue, saturation: saturation, brightness: brightness)
    }

    init(hue: Double, saturation: Double, brightness: Double) {
        self.hue = hue
        self.saturation = saturation
        self.brightness = brightness
    }
}

/// Extracts and caches dominant colors from app icons (with disk persistence)
public class AppIconColorCache {
    public static let shared = AppIconColorCache()

    private var cache: [String: Color] = [:]
    private let lock = NSLock()
    private let cacheFileURL: URL
    private var diskCache: [String: StoredColor] = [:]
    private var isDirty = false

    private init() {
        // Store in AppPaths.storageRoot (respects custom location)
        let retraceDir = URL(fileURLWithPath: AppPaths.expandedStorageRoot)

        // Create directory if needed
        try? FileManager.default.createDirectory(at: retraceDir, withIntermediateDirectories: true)

        cacheFileURL = retraceDir.appendingPathComponent("app_icon_colors.json")

        // Load existing cache from disk
        loadFromDisk()
    }

    /// Get the dominant color for an app's icon, with caching
    public func color(for bundleID: String) -> Color {
        lock.lock()
        defer { lock.unlock() }

        // Return from memory cache if available
        if let cached = cache[bundleID] {
            return cached
        }

        // Return from disk cache if available
        if let stored = diskCache[bundleID] {
            let color = stored.color
            cache[bundleID] = color
            return color
        }

        // Extract color from icon
        let color = extractDominantColor(for: bundleID)
        cache[bundleID] = color

        // Save to disk cache (async to avoid blocking)
        saveToDiskAsync(bundleID: bundleID, color: color)

        return color
    }

    /// Extract the dominant color from an app's icon
    private func extractDominantColor(for bundleID: String) -> Color {
        // Get the app icon
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return fallbackColor(for: bundleID)
        }

        let icon = NSWorkspace.shared.icon(forFile: appURL.path)

        // Get a bitmap representation
        guard let tiffData = icon.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else {
            return fallbackColor(for: bundleID)
        }

        // Sample the icon at a smaller size for performance
        let sampleSize = 32
        var colorCounts: [String: (count: Int, r: CGFloat, g: CGFloat, b: CGFloat)] = [:]

        for x in 0..<min(sampleSize, bitmap.pixelsWide) {
            for y in 0..<min(sampleSize, bitmap.pixelsHigh) {
                // Scale coordinates to bitmap size
                let scaledX = x * bitmap.pixelsWide / sampleSize
                let scaledY = y * bitmap.pixelsHigh / sampleSize

                guard let pixelColor = bitmap.colorAt(x: scaledX, y: scaledY) else { continue }

                // Convert to RGB
                guard let rgbColor = pixelColor.usingColorSpace(.sRGB) else { continue }

                let r = rgbColor.redComponent
                let g = rgbColor.greenComponent
                let b = rgbColor.blueComponent
                let a = rgbColor.alphaComponent

                // Skip transparent pixels
                guard a > 0.5 else { continue }

                // Skip very dark pixels (likely background/shadow)
                let brightness = (r + g + b) / 3
                guard brightness > 0.1 else { continue }

                // Skip very light/white pixels
                guard brightness < 0.95 else { continue }

                // Skip grayish pixels (low saturation)
                let maxC = max(r, g, b)
                let minC = min(r, g, b)
                let saturation = maxC > 0 ? (maxC - minC) / maxC : 0
                guard saturation > 0.2 else { continue }

                // Quantize colors to reduce noise (group similar colors)
                let qr = Int(r * 8) // 8 levels per channel
                let qg = Int(g * 8)
                let qb = Int(b * 8)
                let key = "\(qr),\(qg),\(qb)"

                if let existing = colorCounts[key] {
                    colorCounts[key] = (existing.count + 1, existing.r + r, existing.g + g, existing.b + b)
                } else {
                    colorCounts[key] = (1, r, g, b)
                }
            }
        }

        // Find the most common color
        guard let mostCommon = colorCounts.max(by: { $0.value.count < $1.value.count }) else {
            return fallbackColor(for: bundleID)
        }

        // Average the colors in this bucket
        let count = CGFloat(mostCommon.value.count)
        let avgR = mostCommon.value.r / count
        let avgG = mostCommon.value.g / count
        let avgB = mostCommon.value.b / count

        // Boost saturation slightly for better visibility on dark backgrounds
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        NSColor(red: avgR, green: avgG, blue: avgB, alpha: 1.0)
            .getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: nil)

        // Ensure minimum saturation and brightness for visibility
        saturation = max(saturation, 0.5)
        brightness = max(brightness, 0.6)

        return Color(hue: Double(hue), saturation: Double(saturation), brightness: Double(brightness))
    }

    /// Fallback color when icon extraction fails (hash-based)
    private func fallbackColor(for bundleID: String) -> Color {
        let hash = bundleID.hashValue
        let hue = Double(abs(hash) % 360) / 360.0
        return Color(hue: hue, saturation: 0.7, brightness: 0.75)
    }

    // MARK: - Disk Persistence

    private func loadFromDisk() {
        guard FileManager.default.fileExists(atPath: cacheFileURL.path) else { return }

        do {
            let data = try Data(contentsOf: cacheFileURL)
            diskCache = try JSONDecoder().decode([String: StoredColor].self, from: data)
        } catch {
            // Silently fail - will re-extract colors as needed
        }
    }

    private func saveToDiskAsync(bundleID: String, color: Color) {
        // Convert Color to StoredColor by extracting HSB components
        let nsColor = NSColor(color)
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        nsColor.usingColorSpace(.sRGB)?.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: nil)

        let stored = StoredColor(hue: Double(hue), saturation: Double(saturation), brightness: Double(brightness))

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }

            self.lock.lock()
            self.diskCache[bundleID] = stored
            self.isDirty = true
            self.lock.unlock()

            self.flushToDiskIfNeeded()
        }
    }

    private func flushToDiskIfNeeded() {
        lock.lock()
        guard isDirty else {
            lock.unlock()
            return
        }
        let cacheToSave = diskCache
        isDirty = false
        lock.unlock()

        do {
            let data = try JSONEncoder().encode(cacheToSave)
            try data.write(to: cacheFileURL, options: .atomic)
        } catch {
            // Silently fail - cache will be rebuilt next time
        }
    }
}

// MARK: - Colors

extension Color {
    // MARK: Brand Colors (matching retrace-frontend design)
    // Deep blue background: #051127
    public static let retraceDeepBlue = Color(red: 5/255, green: 17/255, blue: 39/255)

    // Primary accent color - adapts based on user's color theme preference
    // Blue: Retrace accent color (lighter blue for better visibility)
    // Gold: Warm gold accent
    // Purple: Royal purple accent
    public static var retraceAccent: Color {
        let theme = MilestoneCelebrationManager.getCurrentTheme()
        switch theme {
        case .blue:
            return Color(red: 59/255, green: 130/255, blue: 246/255)  // #3B82F6 - lighter blue
        case .gold:
            return Color(red: 255/255, green: 200/255, blue: 0/255)  // Gold
        case .purple:
            return Color(red: 160/255, green: 100/255, blue: 255/255)  // Purple
        }
    }

    // Original brand blue (for cases where we always want blue)
    public static let retraceBrandBlue = Color(red: 11/255, green: 51/255, blue: 108/255)

    // Submit button accent - darker blue for submit/action buttons (#0b336c)
    public static let retraceSubmitAccent = Color(red: 11/255, green: 51/255, blue: 108/255)

    // Card background: hsl(222, 47%, 7%)
    public static let retraceCard = Color(red: 9/255, green: 18/255, blue: 38/255)

    // Secondary: hsl(217, 33%, 17%)
    public static let retraceSecondaryColor = Color(red: 29/255, green: 41/255, blue: 58/255)

    // Foreground: hsl(210, 40%, 98%)
    public static let retraceForeground = Color(red: 247/255, green: 249/255, blue: 252/255)

    // Muted foreground: hsl(215, 20%, 65%)
    public static let retraceMutedForeground = Color(red: 150/255, green: 160/255, blue: 181/255)

    // State colors
    public static let retraceDanger = Color(red: 220/255, green: 38/255, blue: 38/255)
    public static let retraceSuccess = Color(red: 34/255, green: 197/255, blue: 94/255)
    public static let retraceWarning = Color(red: 251/255, green: 146/255, blue: 60/255)

    // MARK: Segment Colors (extracted from app icon)
    public static func segmentColor(for bundleID: String) -> Color {
        AppIconColorCache.shared.color(for: bundleID)
    }

    // MARK: Semantic Colors (adaptive to system light/dark mode)
    public static let retraceBackground = Color.retraceDeepBlue
    public static let retraceSecondaryBackground = Color.retraceCard
    public static let retraceTertiaryBackground = Color.retraceSecondaryColor

    public static let retracePrimary = Color.retraceForeground
    public static let retraceSecondary = Color.retraceMutedForeground

    public static let retraceBorder = Color.retraceSecondaryColor
    public static let retraceHover = Color.retraceSecondaryColor.opacity(0.5)

    // MARK: Search Highlight
    public static let retraceMatchHighlight = Color.yellow.opacity(0.4)
    public static let retraceBoundingBox = Color.retraceAccent
    public static let retraceBoundingBoxSecondary = Color(red: 11/255, green: 51/255, blue: 108/255)  // #0b336c
}

// MARK: - Typography

/// Available font styles for the app
public enum RetraceFontStyle: String, CaseIterable, Identifiable {
    case `default` = "default"
    case rounded = "rounded"
    case serif = "serif"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .default: return "SF Pro"
        case .rounded: return "SF Pro Rounded"
        case .serif: return "New York"
        }
    }

    public var description: String {
        switch self {
        case .default: return "Clean and professional"
        case .rounded: return "Friendly and approachable"
        case .serif: return "Classic and elegant"
        }
    }

    var design: Font.Design {
        switch self {
        case .default: return .default
        case .rounded: return .rounded
        case .serif: return .serif
        }
    }
}

/// Centralized font configuration for the entire app.
/// Font style can be changed in Settings.
public enum RetraceFont {
    /// UserDefaults key for font preference
    private static let fontStyleKey = "retraceFontStyle"

    /// Shared UserDefaults store (same as Settings uses)
    private static let settingsStore = UserDefaults(suiteName: "io.retrace.app")

    /// The current font style (persisted in UserDefaults)
    public static var currentStyle: RetraceFontStyle {
        get {
            if let rawValue = settingsStore?.string(forKey: fontStyleKey),
               let style = RetraceFontStyle(rawValue: rawValue) {
                return style
            }
            return .default
        }
        set {
            settingsStore?.set(newValue.rawValue, forKey: fontStyleKey)
            // Post notification so views can update
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .fontStyleDidChange, object: newValue)
            }
        }
    }

    /// The font design used throughout the app
    public static var design: Font.Design {
        currentStyle.design
    }

    /// Creates a font with the app's current design style
    public static func font(size: CGFloat, weight: Font.Weight) -> Font {
        .system(size: size, weight: weight, design: design)
    }

    /// Creates a monospaced font (ignores the global design setting)
    public static func mono(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

extension Font {
    // MARK: Display (Hero text, large numbers)
    public static var retraceDisplay: Font { RetraceFont.font(size: 48, weight: .bold) }
    public static var retraceDisplay2: Font { RetraceFont.font(size: 36, weight: .bold) }
    public static var retraceDisplay3: Font { RetraceFont.font(size: 32, weight: .bold) }

    // MARK: Titles
    public static var retraceTitle: Font { RetraceFont.font(size: 28, weight: .bold) }
    public static var retraceTitle2: Font { RetraceFont.font(size: 22, weight: .bold) }
    public static var retraceTitle3: Font { RetraceFont.font(size: 20, weight: .semibold) }

    // MARK: Large Numbers (for stats/metrics display)
    public static var retraceLargeNumber: Font { RetraceFont.font(size: 28, weight: .bold) }
    public static var retraceMediumNumber: Font { RetraceFont.font(size: 24, weight: .semibold) }

    // MARK: Body Text
    public static var retraceHeadline: Font { RetraceFont.font(size: 17, weight: .semibold) }
    public static var retraceBody: Font { RetraceFont.font(size: 15, weight: .regular) }
    public static var retraceBodyMedium: Font { RetraceFont.font(size: 15, weight: .medium) }
    public static var retraceBodyBold: Font { RetraceFont.font(size: 15, weight: .semibold) }
    public static var retraceCallout: Font { RetraceFont.font(size: 14, weight: .regular) }
    public static var retraceCalloutMedium: Font { RetraceFont.font(size: 14, weight: .medium) }
    public static var retraceCalloutBold: Font { RetraceFont.font(size: 14, weight: .semibold) }

    // MARK: Small Text
    public static var retraceCaption: Font { RetraceFont.font(size: 13, weight: .regular) }
    public static var retraceCaptionMedium: Font { RetraceFont.font(size: 13, weight: .medium) }
    public static var retraceCaptionBold: Font { RetraceFont.font(size: 13, weight: .semibold) }
    public static var retraceCaption2: Font { RetraceFont.font(size: 11, weight: .regular) }
    public static var retraceCaption2Medium: Font { RetraceFont.font(size: 11, weight: .medium) }
    public static var retraceCaption2Bold: Font { RetraceFont.font(size: 11, weight: .semibold) }

    // MARK: Tiny Text (for labels, badges)
    public static var retraceTiny: Font { RetraceFont.font(size: 10, weight: .regular) }
    public static var retraceTinyMedium: Font { RetraceFont.font(size: 10, weight: .medium) }
    public static var retraceTinyBold: Font { RetraceFont.font(size: 10, weight: .semibold) }

    // MARK: Monospace (for IDs, technical data - always uses monospaced design)
    public static var retraceMono: Font { RetraceFont.mono(size: 13) }
    public static var retraceMonoSmall: Font { RetraceFont.mono(size: 11) }
    public static var retraceMonoLarge: Font { RetraceFont.mono(size: 15) }
}

// MARK: - Spacing

extension CGFloat {
    // MARK: Standard Spacing Scale
    public static let spacingXS: CGFloat = 4
    public static let spacingS: CGFloat = 8
    public static let spacingM: CGFloat = 16
    public static let spacingL: CGFloat = 24
    public static let spacingXL: CGFloat = 32
    public static let spacingXXL: CGFloat = 48

    // MARK: Component-specific
    public static let cornerRadiusS: CGFloat = 4
    public static let cornerRadiusM: CGFloat = 8
    public static let cornerRadiusL: CGFloat = 12

    public static let borderWidth: CGFloat = 1
    public static let borderWidthThick: CGFloat = 2

    public static let iconSizeS: CGFloat = 16
    public static let iconSizeM: CGFloat = 20
    public static let iconSizeL: CGFloat = 24
    public static let iconSizeXL: CGFloat = 32

    // MARK: Layout
    public static let sidebarWidth: CGFloat = 200
    public static let toolbarHeight: CGFloat = 44
    public static let timelineBarHeight: CGFloat = 80
    public static let thumbnailSize: CGFloat = 120

    // MARK: Utility
    /// Clamp value to a closed range
    public func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        return Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

// MARK: - Shadow Styles

extension View {
    public func retraceShadowLight() -> some View {
        self.shadow(color: .black.opacity(0.05), radius: 2, x: 0, y: 1)
    }

    public func retraceShadowMedium() -> some View {
        self.shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
    }

    public func retraceShadowHeavy() -> some View {
        self.shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 4)
    }

    public func retraceGlow(color: Color = .retraceAccent, radius: CGFloat = 20) -> some View {
        self.shadow(color: color.opacity(0.3), radius: radius, x: 0, y: 0)
    }
}

// MARK: - Glassmorphism Style

public struct GlassmorphismModifier: ViewModifier {
    var cornerRadius: CGFloat
    var opacity: Double

    public init(cornerRadius: CGFloat = 16, opacity: Double = 0.1) {
        self.cornerRadius = cornerRadius
        self.opacity = opacity
    }

    public func body(content: Content) -> some View {
        content
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(Color.white.opacity(opacity))
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(.ultraThinMaterial.opacity(0.3))
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .stroke(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.2),
                                    Color.white.opacity(0.05)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                }
            )
    }
}

extension View {
    public func glassmorphism(cornerRadius: CGFloat = 16, opacity: Double = 0.1) -> some View {
        self.modifier(GlassmorphismModifier(cornerRadius: cornerRadius, opacity: opacity))
    }
}

// MARK: - Gradient Backgrounds

extension LinearGradient {
    // Accent gradient - adapts based on user's color theme preference
    public static var retraceAccentGradient: LinearGradient {
        let theme = MilestoneCelebrationManager.getCurrentTheme()
        switch theme {
        case .blue:
            return LinearGradient(
                colors: [
                    Color(red: 60/255, green: 130/255, blue: 220/255),   // Bright blue
                    Color(red: 90/255, green: 160/255, blue: 240/255)    // Lighter blue
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .gold:
            return LinearGradient(
                colors: [
                    Color(red: 255/255, green: 215/255, blue: 0/255),    // Gold
                    Color(red: 255/255, green: 180/255, blue: 0/255)     // Darker gold
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .purple:
            return LinearGradient(
                colors: [
                    Color(red: 180/255, green: 130/255, blue: 255/255),  // Light purple
                    Color(red: 138/255, green: 43/255, blue: 226/255)    // Blue violet
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    // Original blue gradient (for cases where we always want blue)
    public static let retraceBrandGradient = LinearGradient(
        colors: [
            Color(red: 60/255, green: 130/255, blue: 220/255),
            Color(red: 90/255, green: 160/255, blue: 240/255)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    public static let retracePurpleGradient = LinearGradient(
        colors: [
            Color(red: 70/255, green: 140/255, blue: 230/255),   // Bright blue for visibility
            Color(red: 100/255, green: 170/255, blue: 250/255)   // Lighter blue
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    public static let retraceGreenGradient = LinearGradient(
        colors: [
            Color(red: 34/255, green: 197/255, blue: 94/255),
            Color(red: 16/255, green: 185/255, blue: 129/255)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    public static let retraceOrangeGradient = LinearGradient(
        colors: [
            Color(red: 251/255, green: 146/255, blue: 60/255),
            Color(red: 251/255, green: 191/255, blue: 36/255)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    public static let retraceSubtleGradient = LinearGradient(
        colors: [
            Color.white.opacity(0.05),
            Color.white.opacity(0.02)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

// MARK: - Button Styles

public struct RetracePrimaryButtonStyle: ButtonStyle {
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, .spacingM)
            .padding(.vertical, .spacingS)
            .background(Color.retraceAccent)
            .foregroundColor(.white)
            .cornerRadius(.cornerRadiusM)
            .opacity(configuration.isPressed ? 0.8 : 1.0)
    }
}

public struct RetraceSecondaryButtonStyle: ButtonStyle {
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, .spacingM)
            .padding(.vertical, .spacingS)
            .background(Color.retraceSecondaryBackground)
            .foregroundColor(.retracePrimary)
            .cornerRadius(.cornerRadiusM)
            .overlay(
                RoundedRectangle(cornerRadius: .cornerRadiusM)
                    .stroke(Color.retraceBorder, lineWidth: .borderWidth)
            )
            .opacity(configuration.isPressed ? 0.8 : 1.0)
    }
}

public struct RetraceDangerButtonStyle: ButtonStyle {
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, .spacingM)
            .padding(.vertical, .spacingS)
            .background(Color.retraceDanger)
            .foregroundColor(.white)
            .cornerRadius(.cornerRadiusM)
            .opacity(configuration.isPressed ? 0.8 : 1.0)
    }
}

// MARK: - Card Style

public struct RetraceCardModifier: ViewModifier {
    public func body(content: Content) -> some View {
        content
            .padding(.spacingM)
            .background(Color.retraceSecondaryBackground)
            .cornerRadius(.cornerRadiusL)
            .retraceShadowLight()
    }
}

extension View {
    public func retraceCard() -> some View {
        self.modifier(RetraceCardModifier())
    }
}

// MARK: - Hover Effect

public struct RetraceHoverModifier: ViewModifier {
    @State private var isHovered = false

    public func body(content: Content) -> some View {
        content
            .background(isHovered ? Color.retraceHover : Color.clear)
            .onHover { hovering in
                isHovered = hovering
            }
    }
}

extension View {
    public func retraceHover() -> some View {
        self.modifier(RetraceHoverModifier())
    }
}

// MARK: - Timeline Scale Factor

/// Provides resolution-adaptive scaling for timeline UI elements
/// Baseline is 1080p (1920x1080) where scale = 1.0
/// Scales proportionally for larger/smaller screens
public struct TimelineScaleFactor {
    /// Reference height for scale factor 1.0 (1080p)
    private static let referenceHeight: CGFloat = 1080

    /// Minimum scale factor to prevent UI from becoming too small
    private static let minScale: CGFloat = 0.85

    /// Maximum scale factor to prevent UI from becoming too large
    private static let maxScale: CGFloat = 1.6

    /// Thread-safe cached scale factor to prevent size changes during window lifecycle
    private static var _cachedScaleFactor: CGFloat?
    private static let lock = NSLock()

    /// Calculate scale factor based on current screen height
    /// Returns cached value to prevent UI size changes during window lifecycle
    public static var current: CGFloat {
        lock.lock()
        defer { lock.unlock() }

        if let cached = _cachedScaleFactor {
            return cached
        }

        // Calculate and cache the scale factor
        guard let screen = NSScreen.main else { return 1.0 }
        let screenHeight = screen.frame.height
        let rawScale = screenHeight / referenceHeight
        let scale = min(maxScale, max(minScale, rawScale))
        _cachedScaleFactor = scale
        return scale
    }

    /// Reset the cached scale factor (call when timeline window closes)
    public static func resetCache() {
        lock.lock()
        defer { lock.unlock() }
        _cachedScaleFactor = nil
    }

    /// Calculate scale factor for a specific screen
    public static func forScreen(_ screen: NSScreen?) -> CGFloat {
        guard let screen = screen else { return 1.0 }
        let screenHeight = screen.frame.height
        let rawScale = screenHeight / referenceHeight
        return min(maxScale, max(minScale, rawScale))
    }

    // MARK: - Timeline Tape Dimensions (scaled)

    /// Base tape height (42pt at 1080p)
    public static var tapeHeight: CGFloat { 42 * current }

    /// Block spacing between app segments
    public static var blockSpacing: CGFloat { 2 * current }

    /// App icon size within blocks
    public static var appIconSize: CGFloat { 30 * current }

    /// Minimum block width to show app icon
    public static var iconDisplayThreshold: CGFloat { 40 * current }

    /// Playhead width
    public static var playheadWidth: CGFloat { 6 * current }

    // MARK: - Control Positioning (scaled)

    /// Y offset for control buttons above tape
    public static var controlsYOffset: CGFloat { -55 * current }

    /// Y offset for floating search panel
    public static var searchPanelYOffset: CGFloat { -195 * current }

    /// Y offset for calendar picker
    public static var calendarPickerYOffset: CGFloat { -280 * current }

    /// X position for left controls
    public static var leftControlsX: CGFloat { 130 * current }

    /// X offset from right edge for right controls
    public static var rightControlsXOffset: CGFloat { 100 * current }

    // MARK: - Container Dimensions (scaled)

    /// Blur backdrop height
    public static var blurBackdropHeight: CGFloat { 350 * current }

    /// Bottom padding for tape
    public static var tapeBottomPadding: CGFloat { 40 * current }

    /// Offset when controls are hidden
    public static var hiddenControlsOffset: CGFloat { 150 * current }

    /// Close button Y offset when hidden
    public static var closeButtonHiddenYOffset: CGFloat { -100 * current }

    // MARK: - Button/Control Sizes (scaled)

    /// Control button size
    public static var controlButtonSize: CGFloat { 38 * current }

    /// Close button size (top-right X button)
    public static var closeButtonSize: CGFloat { 38 * current }

    /// Zoom slider width
    public static var zoomSliderWidth: CGFloat { 110 * current }

    /// Search button width
    public static var searchButtonWidth: CGFloat { 190 * current }

    // MARK: - Panel Dimensions (scaled)

    /// Floating date search panel width
    public static var searchPanelWidth: CGFloat { 420 * current }

    /// Calendar picker width
    public static var calendarPickerWidth: CGFloat { 280 * current }

    /// Calendar picker height
    public static var calendarPickerHeight: CGFloat { 340 * current }

    // MARK: - Font Sizes (scaled)

    /// Callout font size (16pt base)
    public static var fontCallout: CGFloat { 16 * current }

    /// Caption font size (14pt base)
    public static var fontCaption: CGFloat { 14 * current }

    /// Caption2 font size (12pt base)
    public static var fontCaption2: CGFloat { 12 * current }

    /// Tiny font size (11pt base)
    public static var fontTiny: CGFloat { 11 * current }

    /// Mono font size (15pt base)
    public static var fontMono: CGFloat { 15 * current }

    // MARK: - Padding/Spacing (scaled)

    /// Standard horizontal padding for buttons
    public static var buttonPaddingH: CGFloat { 12 * current }

    /// Standard vertical padding for buttons
    public static var buttonPaddingV: CGFloat { 8 * current }

    /// Larger horizontal padding
    public static var paddingH: CGFloat { 18 * current }

    /// Larger vertical padding
    public static var paddingV: CGFloat { 12 * current }

    /// Control spacing
    public static var controlSpacing: CGFloat { 14 * current }

    /// Icon spacing within buttons
    public static var iconSpacing: CGFloat { 8 * current }
}

// MARK: - Unified Menu & Popover Design System

/// Unified design system for all menus, popovers, and dialogs
/// Based on the right-click context menu design (optimal reference)
public struct RetraceMenuStyle {
    private init() {}

    // MARK: - Container Styling

    /// Background color for all menus, popovers, and dialogs
    public static let backgroundColor = Color(white: 0.1)

    /// Corner radius for all containers
    public static let cornerRadius: CGFloat = 12

    /// Border color
    public static let borderColor = Color.white.opacity(0.15)

    /// Border width
    public static let borderWidth: CGFloat = 1

    /// Shadow configuration
    public static let shadowColor = Color.black.opacity(0.5)
    public static let shadowRadius: CGFloat = 20
    public static let shadowY: CGFloat = 10

    // MARK: - Interactive Item Styling

    /// Hover background color for menu items
    public static let itemHoverColor = Color.white.opacity(0.1)

    /// Corner radius for menu items
    public static let itemCornerRadius: CGFloat = 6

    /// Horizontal padding for menu items
    public static let itemPaddingH: CGFloat = 12

    /// Vertical padding for menu items
    public static let itemPaddingV: CGFloat = 6

    /// Spacing between items
    public static let itemSpacing: CGFloat = 0

    // MARK: - Typography

    /// Font for menu item text
    public static let font = Font.system(size: 13, weight: .medium)

    /// Font size value (for non-SwiftUI contexts)
    public static let fontSize: CGFloat = 13

    /// Font weight
    public static let fontWeight: Font.Weight = .medium

    /// Icon size
    public static let iconSize: CGFloat = 13

    /// Icon frame width (for alignment)
    public static let iconFrameWidth: CGFloat = 18

    /// Spacing between icon and text
    public static let iconTextSpacing: CGFloat = 10

    // MARK: - Colors

    /// Primary text color
    public static let textColor = Color.white

    /// Secondary text color (muted)
    public static let textColorMuted = Color.white.opacity(0.7)

    /// Destructive action color
    public static let destructiveColor = Color.red.opacity(0.9)

    /// Chevron color (for submenus)
    public static let chevronColor = Color.white.opacity(0.4)

    /// Chevron size
    public static let chevronSize: CGFloat = 10

    /// Action button color (used for all primary action buttons like Submit, Apply, Include)
    public static var actionBlue: Color {
        Color.retraceSubmitAccent
    }

    /// UI blue - desaturated, calmer blue for focus rings and subtle accents
    /// Same hue as brand blue but lower saturation for less visual noise
    public static let uiBlue = Color(red: 0.4, green: 0.55, blue: 0.7)

    // MARK: - Search Field Styling (within menus)

    /// Search field background
    public static let searchFieldBackground = Color.white.opacity(0.05)

    /// Search field corner radius
    public static let searchFieldCornerRadius: CGFloat = 8

    /// Search field padding
    public static let searchFieldPaddingH: CGFloat = 10
    public static let searchFieldPaddingV: CGFloat = 6

    // MARK: - Animation

    /// Standard animation duration for hover effects
    public static let hoverAnimationDuration: CGFloat = 0.1

    /// Animation for menu appearance
    public static let appearanceAnimation = Animation.easeOut(duration: 0.15)
}

// MARK: - Reusable Menu Components

/// Standardized menu button component
/// Used in context menus, popovers, and dialogs for consistent appearance
public struct RetraceMenuButton: View {
    let icon: String
    let title: String
    var showChevron: Bool = false
    var isDestructive: Bool = false
    var isDisabled: Bool = false
    var onHoverChanged: ((Bool) -> Void)? = nil
    let action: () -> Void

    @State private var isHovering = false

    public init(
        icon: String,
        title: String,
        showChevron: Bool = false,
        isDestructive: Bool = false,
        isDisabled: Bool = false,
        onHoverChanged: ((Bool) -> Void)? = nil,
        action: @escaping () -> Void
    ) {
        self.icon = icon
        self.title = title
        self.showChevron = showChevron
        self.isDestructive = isDestructive
        self.isDisabled = isDisabled
        self.onHoverChanged = onHoverChanged
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: RetraceMenuStyle.iconTextSpacing) {
                Image(systemName: icon)
                    .font(.system(size: RetraceMenuStyle.iconSize, weight: RetraceMenuStyle.fontWeight))
                    .foregroundColor(foregroundColor)
                    .frame(width: RetraceMenuStyle.iconFrameWidth)

                Text(title)
                    .font(RetraceMenuStyle.font)
                    .foregroundColor(foregroundColor)

                Spacer()

                if showChevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: RetraceMenuStyle.chevronSize, weight: .bold))
                        .foregroundColor(RetraceMenuStyle.chevronColor)
                }
            }
            .padding(.horizontal, RetraceMenuStyle.itemPaddingH)
            .padding(.vertical, RetraceMenuStyle.itemPaddingV)
            .background(
                RoundedRectangle(cornerRadius: RetraceMenuStyle.itemCornerRadius)
                    .fill(isHovering && !isDisabled ? RetraceMenuStyle.itemHoverColor : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .onHover { hovering in
            withAnimation(.easeOut(duration: RetraceMenuStyle.hoverAnimationDuration)) {
                isHovering = hovering
            }
            if hovering && !isDisabled { NSCursor.pointingHand.push() }
            else { NSCursor.pop() }
            onHoverChanged?(hovering)
        }
    }

    private var foregroundColor: Color {
        if isDisabled {
            return RetraceMenuStyle.textColorMuted.opacity(0.5)
        } else if isDestructive {
            return RetraceMenuStyle.destructiveColor
        } else {
            return isHovering ? RetraceMenuStyle.textColor : RetraceMenuStyle.textColorMuted
        }
    }
}

/// Shared UserDefaults store for accessing settings
private let menuContainerSettingsStore = UserDefaults(suiteName: "io.retrace.app")

/// Standardized menu container modifier
/// Applies consistent background, border, and shadow to any menu/popover content
/// Border color adapts based on user's color theme preference
public struct RetraceMenuContainer: ViewModifier {
    var addPadding: Bool = true

    private var showColoredBorders: Bool {
        menuContainerSettingsStore?.bool(forKey: "timelineColoredBorders") ?? true
    }

    private var borderColor: Color {
        guard showColoredBorders else {
            return Color.white.opacity(0.15)
        }
        let theme = MilestoneCelebrationManager.getCurrentTheme()
        return theme.controlBorderColor
    }

    public func body(content: Content) -> some View {
        Group {
            if addPadding {
                content.padding(.spacingS)
            } else {
                content
            }
        }
        .background(
            RoundedRectangle(cornerRadius: RetraceMenuStyle.cornerRadius)
                .fill(RetraceMenuStyle.backgroundColor)
                .shadow(
                    color: RetraceMenuStyle.shadowColor,
                    radius: RetraceMenuStyle.shadowRadius,
                    y: RetraceMenuStyle.shadowY
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: RetraceMenuStyle.cornerRadius)
                .stroke(borderColor, lineWidth: RetraceMenuStyle.borderWidth)
        )
    }
}

extension View {
    /// Apply standardized menu/popover container styling
    public func retraceMenuContainer(addPadding: Bool = true) -> some View {
        self.modifier(RetraceMenuContainer(addPadding: addPadding))
    }
}

/// Standardized search field for menus/popovers
public struct RetraceMenuSearchField: View {
    @Binding var text: String
    var placeholder: String
    var onSubmit: (() -> Void)? = nil

    public init(text: Binding<String>, placeholder: String = "Search...", onSubmit: (() -> Void)? = nil) {
        self._text = text
        self.placeholder = placeholder
        self.onSubmit = onSubmit
    }

    public var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.5))

            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(RetraceMenuStyle.font)
                .foregroundColor(.white)
                .onSubmit {
                    onSubmit?()
                }

            if !text.isEmpty {
                Button(action: { text = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.4))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, RetraceMenuStyle.searchFieldPaddingH)
        .padding(.vertical, RetraceMenuStyle.searchFieldPaddingV)
        .background(
            RoundedRectangle(cornerRadius: RetraceMenuStyle.searchFieldCornerRadius)
                .fill(RetraceMenuStyle.searchFieldBackground)
        )
    }
}

// MARK: - Color Extension for Hex Support
extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

// MARK: - Ping Dot View

/// A pulsating dot indicator for status display
/// Use for showing active/connected states (green) or warning/disconnected states (orange)
public struct PingDotView: View {
    let color: Color
    let size: CGFloat
    let isAnimating: Bool

    @State private var isPulsing = false

    public init(color: Color, size: CGFloat = 8, isAnimating: Bool = true) {
        self.color = color
        self.size = size
        self.isAnimating = isAnimating
    }

    public var body: some View {
        ZStack {
            if isAnimating {
                Circle()
                    .fill(color)
                    .frame(width: size, height: size)
                    .scaleEffect(isPulsing ? 2.0 : 1.0)
                    .opacity(isPulsing ? 0.0 : 0.6)
            }

            Circle()
                .fill(color)
                .frame(width: size, height: size)
        }
        .onAppear {
            if isAnimating {
                withAnimation(
                    Animation.easeOut(duration: 1.5)
                        .repeatForever(autoreverses: false)
                ) {
                    isPulsing = true
                }
            }
        }
    }
}

// MARK: - Notifications

extension Notification.Name {
    /// Posted when the font style preference changes
    public static let fontStyleDidChange = Notification.Name("fontStyleDidChange")
}
