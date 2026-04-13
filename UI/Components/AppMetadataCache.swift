import AppKit
import Shared
import SwiftUI

private func estimatedImageBytes(_ image: NSImage) -> Int64 {
    if let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
        return Int64(cgImage.bytesPerRow * cgImage.height)
    }
    if let bitmapRep = image.representations.first(where: { $0 is NSBitmapImageRep }) as? NSBitmapImageRep {
        return Int64(bitmapRep.bytesPerRow * bitmapRep.pixelsHigh)
    }

    let width = max(Int(image.size.width.rounded()), 1)
    let height = max(Int(image.size.height.rounded()), 1)
    return Int64(width * height * 4)
}

private func estimatedStringBytes(_ string: String) -> Int64 {
    Int64(MemoryLayout<String>.stride + string.utf8.count)
}

func clampedAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
    if rhs > 0, lhs > Int64.max - rhs {
        return Int64.max
    }
    if rhs < 0, lhs < Int64.min - rhs {
        return Int64.min
    }
    return lhs + rhs
}

struct LookupMissCache {
    private struct Entry {
        var expiresAt: Date?
        var lastObservedAt: Date
    }

    let maxEntries: Int
    private var entries: [String: Entry] = [:]

    init(maxEntries: Int = 256) {
        self.maxEntries = max(1, maxEntries)
    }

    mutating func containsRecentMiss(for key: String, now: Date = Date()) -> Bool {
        guard var entry = entries[key] else { return false }
        if let expiresAt = entry.expiresAt, expiresAt <= now {
            entries.removeValue(forKey: key)
            return false
        }

        entry.lastObservedAt = now
        entries[key] = entry
        return true
    }

    mutating func recordMiss(
        for key: String,
        ttl: TimeInterval? = nil,
        now: Date = Date()
    ) {
        let expiresAt = ttl.map { now.addingTimeInterval($0) }
        if let expiresAt, expiresAt <= now {
            entries.removeValue(forKey: key)
            return
        }

        entries[key] = Entry(expiresAt: expiresAt, lastObservedAt: now)
        trimIfNeeded()
    }

    mutating func clearMiss(for key: String) {
        entries.removeValue(forKey: key)
    }

    mutating func removeAll() {
        entries.removeAll()
    }

    private mutating func trimIfNeeded() {
        guard entries.count > maxEntries else { return }

        let overflow = entries.count - maxEntries
        let keysToRemove = entries
            .sorted { lhs, rhs in
                if lhs.value.lastObservedAt == rhs.value.lastObservedAt {
                    return lhs.key < rhs.key
                }
                return lhs.value.lastObservedAt < rhs.value.lastObservedAt
            }
            .prefix(overflow)
            .map(\.key)

        for key in keysToRemove {
            entries.removeValue(forKey: key)
        }
    }
}

final class ImageMemoryCache: NSObject, NSCacheDelegate, @unchecked Sendable {
    private let cache = NSCache<NSString, NSImage>()
    private let lock = NSLock()
    private var estimatedBytesByKey: [String: Int64] = [:]
    private var keyByObjectID: [ObjectIdentifier: String] = [:]

    init(countLimit: Int, totalCostLimit: Int? = nil) {
        super.init()
        cache.countLimit = max(1, countLimit)
        if let totalCostLimit {
            cache.totalCostLimit = max(0, totalCostLimit)
        }
        cache.delegate = self
    }

    func image(for key: String) -> NSImage? {
        cache.object(forKey: key as NSString)
    }

    func contains(_ key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return estimatedBytesByKey[key] != nil
    }

    func set(_ image: NSImage, for key: String) {
        let estimate = estimatedImageBytes(image)

        lock.lock()
        if let existing = cache.object(forKey: key as NSString) {
            keyByObjectID.removeValue(forKey: ObjectIdentifier(existing))
        }
        estimatedBytesByKey[key] = estimate
        keyByObjectID[ObjectIdentifier(image)] = key
        lock.unlock()

        cache.setObject(image, forKey: key as NSString, cost: Int(clamping: estimate))
    }

    func remove(_ key: String) {
        let existing = cache.object(forKey: key as NSString)

        lock.lock()
        estimatedBytesByKey.removeValue(forKey: key)
        if let existing {
            keyByObjectID.removeValue(forKey: ObjectIdentifier(existing))
        }
        lock.unlock()

        cache.removeObject(forKey: key as NSString)
    }

    func removeAll() {
        lock.lock()
        estimatedBytesByKey.removeAll()
        keyByObjectID.removeAll()
        lock.unlock()
        cache.removeAllObjects()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return estimatedBytesByKey.count
    }

    var estimatedBytes: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return estimatedBytesByKey.values.reduce(into: Int64(0)) { total, value in
            total = clampedAdd(total, value)
        }
    }

    func cache(_ cache: NSCache<AnyObject, AnyObject>, willEvictObject obj: Any) {
        let object = obj as AnyObject

        lock.lock()
        if let key = keyByObjectID.removeValue(forKey: ObjectIdentifier(object)) {
            estimatedBytesByKey.removeValue(forKey: key)
        }
        lock.unlock()
    }
}

private struct NSImageBox: @unchecked Sendable {
    let image: NSImage?
}

/// Resolves bundle IDs to human-readable app names with caching.
public class AppNameResolver {
    public static let shared = AppNameResolver()

    private var cache: [String: String] = [:]
    private let lock = NSLock()
    private let cacheFileURL: URL
    private var diskCache: [String: String] = [:]
    private var isDirty = false

    private init() {
        let retraceDir = URL(fileURLWithPath: AppPaths.expandedStorageRoot)
        try? FileManager.default.createDirectory(at: retraceDir, withIntermediateDirectories: true)
        cacheFileURL = retraceDir.appendingPathComponent("app_names.json")
        loadFromDisk()
    }

    public func displayName(for bundleID: String) -> String {
        lock.lock()
        defer { lock.unlock() }

        if let cached = cache[bundleID] {
            return cached
        }

        if let stored = diskCache[bundleID] {
            cache[bundleID] = stored
            return stored
        }

        let name = resolveAppName(for: bundleID)
        cache[bundleID] = name
        saveToDiskAsync(bundleID: bundleID, name: name)
        return name
    }

    private func resolveAppName(for bundleID: String) -> String {
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
           let bundle = Bundle(url: appURL),
           let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String {
            return name
        }

        if bundleID.contains(".") {
            let components = bundleID.components(separatedBy: ".")
            if components.count >= 2,
               let lastComponent = components.last,
               !lastComponent.isEmpty,
               lastComponent.first?.isLetter == true {
                return lastComponent.prefix(1).uppercased() + lastComponent.dropFirst()
            }
        }

        if looksLikeRandomIdentifier(bundleID) {
            return "Unknown App"
        }

        return cleanupName(bundleID)
    }

    private func looksLikeRandomIdentifier(_ identifier: String) -> Bool {
        if identifier.first?.isNumber == true {
            return true
        }

        let letterCount = identifier.filter { $0.isLetter }.count
        let numberCount = identifier.filter { $0.isNumber }.count
        if letterCount > 0 && Double(numberCount) / Double(letterCount) > 0.5 {
            return true
        }

        if !identifier.contains(".") && (identifier.count < 3 || identifier.count > 20) {
            return true
        }

        return false
    }

    private func cleanupName(_ identifier: String) -> String {
        var cleaned = identifier
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")

        cleaned = cleaned.split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
            .joined(separator: " ")

        return cleaned.isEmpty ? "Unknown App" : cleaned
    }

    public func isInstalled(bundleID: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    nonisolated static func installedApps(in appFolders: [URL], fileManager: FileManager = .default) -> [AppInfo] {
        var apps: [AppInfo] = []
        var seenBundleIDs = Set<String>()

        for folder in appFolders {
            guard let contents = try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else {
                continue
            }

            for appURL in contents where appURL.pathExtension == "app" {
                let plistURL = appURL.appendingPathComponent("Contents/Info.plist")
                guard let plist = NSDictionary(contentsOf: plistURL),
                      let bundleID = plist["CFBundleIdentifier"] as? String,
                      !bundleID.isEmpty,
                      seenBundleIDs.insert(bundleID).inserted else {
                    continue
                }

                let name: String
                if let displayName = plist["CFBundleDisplayName"] as? String, !displayName.isEmpty {
                    name = displayName
                } else if let bundleName = plist["CFBundleName"] as? String, !bundleName.isEmpty {
                    name = bundleName
                } else {
                    name = appURL.deletingPathExtension().lastPathComponent
                }

                apps.append(AppInfo(bundleID: bundleID, name: name))
            }
        }

        return apps
    }

    public func getInstalledApps() -> [AppInfo] {
        let fileManager = FileManager.default
        let appFolders = [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/System/Applications"),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Chrome Apps.localized")
        ]

        let apps = Self.installedApps(in: appFolders, fileManager: fileManager)

        lock.lock()
        for app in apps {
            cache[app.bundleID] = app.name
        }
        lock.unlock()

        return apps
    }

    public func resolveAll(bundleIDs: [String]) -> [AppInfo] {
        bundleIDs.map { bundleID in
            AppInfo(bundleID: bundleID, name: displayName(for: bundleID))
        }
    }

    private func loadFromDisk() {
        guard FileManager.default.fileExists(atPath: cacheFileURL.path) else { return }
        do {
            let data = try Data(contentsOf: cacheFileURL)
            diskCache = try JSONDecoder().decode([String: String].self, from: data)
        } catch {
            // Ignore corrupt cache and rebuild it lazily.
        }
    }

    private func saveToDiskAsync(bundleID: String, name: String) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
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
            // Ignore write failures and rebuild lazily later.
        }
    }

    @discardableResult
    public func clearCache() -> Int {
        lock.lock()
        let entriesCleared = cache.count + diskCache.count
        cache.removeAll()
        diskCache.removeAll()
        isDirty = false
        lock.unlock()

        try? FileManager.default.removeItem(at: cacheFileURL)

        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let otherAppsCache = cacheDir.appendingPathComponent("other_apps_cache.json")
        try? FileManager.default.removeItem(at: otherAppsCache)
        UserDefaults.standard.removeObject(forKey: "search.otherAppsCacheSavedAt")

        return entriesCleared
    }
}

/// Provides app icons for bundle IDs with a simple NSCache-backed memory cache.
public class AppIconProvider {
    public static let shared = AppIconProvider()

    private let cache = ImageMemoryCache(countLimit: 128, totalCostLimit: 16 * 1024 * 1024)

    private init() {}

    public func icon(for bundleID: String) -> NSImage? {
        if let cached = cache.image(for: bundleID) {
            return cached
        }

        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }

        let icon = NSWorkspace.shared.icon(forFile: appURL.path)
        cache.set(icon, for: bundleID)
        return icon
    }

    public func preloadIcon(for bundleID: String, appURL: URL) {
        guard !cache.contains(bundleID) else { return }
        cache.set(NSWorkspace.shared.icon(forFile: appURL.path), for: bundleID)
    }

    public var cacheCount: Int {
        cache.count
    }
}

/// Main-actor cache for app names/icons used by SwiftUI render paths.
/// Views read cached values synchronously and trigger async resolution on demand.
@MainActor
public final class AppMetadataCache: ObservableObject {
    public static let shared = AppMetadataCache()

    private static let memoryLedgerBundleIconsTag = "ui.appMetadata.bundleIcons"
    private static let memoryLedgerFileIconsTag = "ui.appMetadata.fileIcons"
    private static let memoryLedgerProcessIconsTag = "ui.appMetadata.processIcons"
    private static let memoryLedgerNamesTag = "ui.appMetadata.names"
    private static let maxBundleIconEntries = 192
    private static let maxFileIconEntries = 96
    private static let maxProcessIconEntries = 96
    private static let maxMissEntries = 512
    private static let bundleIconMissTTL: TimeInterval = 6 * 60 * 60
    private static let appPathIconMissTTL: TimeInterval = 6 * 60 * 60
    private static let processNameIconMissTTL: TimeInterval = 60

    private let appIcons = ImageMemoryCache(countLimit: maxBundleIconEntries, totalCostLimit: 24 * 1024 * 1024)
    private let fileIcons = ImageMemoryCache(countLimit: maxFileIconEntries, totalCostLimit: 12 * 1024 * 1024)
    private let processNameIcons = ImageMemoryCache(countLimit: maxProcessIconEntries, totalCostLimit: 12 * 1024 * 1024)
    private var appNames: [String: String] = [:]

    private var pendingBundleIDs: Set<String> = []
    private var pendingAppPaths: Set<String> = []
    private var pendingProcessNames: Set<String> = []
    private var bundleIconMisses = LookupMissCache(maxEntries: maxMissEntries)
    private var appPathIconMisses = LookupMissCache(maxEntries: maxMissEntries)
    private var processNameIconMisses = LookupMissCache(maxEntries: maxMissEntries)

    private init() {}

    public func icon(for bundleID: String) -> NSImage? {
        appIcons.image(for: bundleID)
    }

    public func name(for bundleID: String) -> String? {
        appNames[bundleID]
    }

    public func icon(forAppPath appPath: String) -> NSImage? {
        fileIcons.image(for: appPath)
    }

    public func icon(forProcessName processName: String) -> NSImage? {
        let normalizedName = Self.normalizedProcessName(processName)
        guard !normalizedName.isEmpty else { return nil }
        return processNameIcons.image(for: normalizedName)
    }

    public func prefetch(bundleIDs: [String]) {
        for bundleID in Set(bundleIDs) where !bundleID.isEmpty {
            requestMetadata(for: bundleID)
        }
    }

    public func requestMetadata(for bundleID: String) {
        guard !bundleID.isEmpty else { return }
        if pendingBundleIDs.contains(bundleID) {
            return
        }

        let hasResolvedName = appNames[bundleID] != nil
        let hasResolvedIcon = appIcons.contains(bundleID)
        if hasResolvedName && (hasResolvedIcon || bundleIconMisses.containsRecentMiss(for: bundleID)) {
            return
        }

        pendingBundleIDs.insert(bundleID)

        Task.detached(priority: .utility) {
            let resolvedName = AppNameResolver.shared.displayName(for: bundleID)
            let resolvedIcon = NSImageBox(image: AppIconProvider.shared.icon(for: bundleID))

            await MainActor.run {
                self.appNames[bundleID] = resolvedName
                if let icon = resolvedIcon.image {
                    self.appIcons.set(icon, for: bundleID)
                    self.bundleIconMisses.clearMiss(for: bundleID)
                } else {
                    self.bundleIconMisses.recordMiss(for: bundleID, ttl: Self.bundleIconMissTTL)
                }
                self.pendingBundleIDs.remove(bundleID)
                self.publishCacheMutation()
            }
        }
    }

    public func requestIcon(forAppPath appPath: String) {
        guard !appPath.isEmpty else { return }
        if pendingAppPaths.contains(appPath) {
            return
        }
        if fileIcons.contains(appPath) || appPathIconMisses.containsRecentMiss(for: appPath) {
            return
        }

        pendingAppPaths.insert(appPath)

        Task.detached(priority: .utility) {
            let icon: NSImage?
            if FileManager.default.fileExists(atPath: appPath) {
                icon = NSWorkspace.shared.icon(forFile: appPath)
            } else {
                icon = nil
            }
            let boxedIcon = NSImageBox(image: icon)

            await MainActor.run {
                if let icon = boxedIcon.image {
                    self.fileIcons.set(icon, for: appPath)
                    self.appPathIconMisses.clearMiss(for: appPath)
                    self.publishCacheMutation()
                } else {
                    self.appPathIconMisses.recordMiss(for: appPath, ttl: Self.appPathIconMissTTL)
                }
                self.pendingAppPaths.remove(appPath)
            }
        }
    }

    public func requestIcon(forProcessName processName: String) {
        let normalizedName = Self.normalizedProcessName(processName)
        guard !normalizedName.isEmpty else { return }

        if pendingProcessNames.contains(normalizedName) {
            return
        }
        if processNameIcons.contains(normalizedName)
            || processNameIconMisses.containsRecentMiss(for: normalizedName) {
            return
        }

        pendingProcessNames.insert(normalizedName)
        let lookupName = processName.trimmingCharacters(in: .whitespacesAndNewlines)

        Task.detached(priority: .utility) {
            let iconPath = Self.resolveAppPath(forProcessName: lookupName)
            let icon = iconPath.map { NSWorkspace.shared.icon(forFile: $0) }
            let boxedIcon = NSImageBox(image: icon)

            await MainActor.run {
                if let icon = boxedIcon.image {
                    self.processNameIcons.set(icon, for: normalizedName)
                    self.processNameIconMisses.clearMiss(for: normalizedName)
                    self.publishCacheMutation()
                } else {
                    self.processNameIconMisses.recordMiss(
                        for: normalizedName,
                        ttl: Self.processNameIconMissTTL
                    )
                }
                self.pendingProcessNames.remove(normalizedName)
            }
        }
    }

    private func publishCacheMutation() {
        objectWillChange.send()
        updateMemoryLedger()
    }

    private func updateMemoryLedger() {
        MemoryLedger.set(
            tag: Self.memoryLedgerBundleIconsTag,
            bytes: appIcons.estimatedBytes,
            count: appIcons.count,
            unit: "icons",
            function: "ui.app_metadata",
            kind: "bundle-icons",
            note: "estimated"
        )
        MemoryLedger.set(
            tag: Self.memoryLedgerFileIconsTag,
            bytes: fileIcons.estimatedBytes,
            count: fileIcons.count,
            unit: "icons",
            function: "ui.app_metadata",
            kind: "file-icons",
            note: "estimated"
        )
        MemoryLedger.set(
            tag: Self.memoryLedgerProcessIconsTag,
            bytes: processNameIcons.estimatedBytes,
            count: processNameIcons.count,
            unit: "icons",
            function: "ui.app_metadata",
            kind: "process-icons",
            note: "estimated"
        )
        MemoryLedger.set(
            tag: Self.memoryLedgerNamesTag,
            bytes: appNames.values.reduce(into: Int64(0)) { total, value in
                total = clampedAdd(total, estimatedStringBytes(value))
            },
            count: appNames.count,
            unit: "names",
            function: "ui.app_metadata",
            kind: "display-names",
            note: "estimated"
        )
    }

    nonisolated private static func normalizedProcessName(_ processName: String) -> String {
        processName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    nonisolated private static func resolveAppPath(forProcessName processName: String) -> String? {
        guard !processName.isEmpty else { return nil }

        for app in NSWorkspace.shared.runningApplications {
            guard let localizedName = app.localizedName,
                  localizedName.compare(
                    processName,
                    options: [.caseInsensitive, .diacriticInsensitive]
                  ) == .orderedSame,
                  let bundlePath = app.bundleURL?.path else {
                continue
            }
            return bundlePath
        }

        return nil
    }
}

/// SwiftUI view that displays an app icon for a bundle ID.
public struct AppIconView: View {
    let bundleID: String
    let size: CGFloat
    @StateObject private var metadata = AppMetadataCache.shared

    public init(bundleID: String, size: CGFloat = 32) {
        self.bundleID = bundleID
        self.size = size
    }

    public var body: some View {
        Group {
            if let nsImage = metadata.icon(for: bundleID) {
                Image(nsImage: nsImage)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                fallbackIcon
            }
        }
        .frame(width: size, height: size)
        .task(id: bundleID) {
            metadata.requestMetadata(for: bundleID)
        }
    }

    private var fallbackIcon: some View {
        let appName = metadata.name(for: bundleID) ?? fallbackName(for: bundleID)
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

    private func fallbackName(for bundleID: String) -> String {
        bundleID.components(separatedBy: ".").last ?? bundleID
    }
}
