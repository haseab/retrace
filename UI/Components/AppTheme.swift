import SwiftUI
import AppKit
import CryptoKit
import Shared

/// Retrace design system
/// Provides consistent colors, typography, and spacing across the UI
public struct AppTheme {
    private init() {}
}

// MARK: - Video URL Symlink Resolver

/// Resolves extensionless video paths to stable, collision-safe `.mp4` symlink URLs.
/// Symlink file names are derived from the full normalized destination path to avoid
/// basename collisions across different sources.
enum MP4SymlinkResolver {
    static func resolveURL(for videoPath: String) -> URL? {
        if videoPath.hasSuffix(".mp4") {
            return URL(fileURLWithPath: videoPath)
        }

        let destinationPath = URL(fileURLWithPath: videoPath).standardizedFileURL.path
        let symlinkURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("retrace_video_\(pathDigest(destinationPath)).mp4")

        do {
            try ensureSymlink(at: symlinkURL, destinationPath: destinationPath)
            return symlinkURL
        } catch {
            return nil
        }
    }

    private static func ensureSymlink(at symlinkURL: URL, destinationPath: String) throws {
        let fileManager = FileManager.default
        var lastError: Error?

        // Retry a small number of times to tolerate concurrent resolvers racing to create/remove the same symlink.
        for _ in 0..<3 {
            do {
                try fileManager.createSymbolicLink(
                    atPath: symlinkURL.path,
                    withDestinationPath: destinationPath
                )
                return
            } catch {
                lastError = error

                if let existingDestination = try? fileManager.destinationOfSymbolicLink(atPath: symlinkURL.path),
                   normalizedSymlinkDestination(existingDestination, symlinkURL: symlinkURL) == destinationPath {
                    return
                }

                guard fileManager.fileExists(atPath: symlinkURL.path) else {
                    continue
                }

                do {
                    try fileManager.removeItem(at: symlinkURL)
                } catch {
                    lastError = error
                    if !fileManager.fileExists(atPath: symlinkURL.path) {
                        continue
                    }
                    break
                }
            }
        }

        if let lastError {
            throw lastError
        }
    }

    private static func normalizedSymlinkDestination(_ destination: String, symlinkURL: URL) -> String {
        if destination.hasPrefix("/") {
            return URL(fileURLWithPath: destination).standardizedFileURL.path
        }

        return URL(
            fileURLWithPath: destination,
            relativeTo: symlinkURL.deletingLastPathComponent()
        ).standardizedFileURL.path
    }

    private static func pathDigest(_ path: String) -> String {
        let digest = SHA256.hash(data: Data(path.utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
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
    private var pendingExtractions: Set<String> = []

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
        if let cached = cache[bundleID] {
            lock.unlock()
            return cached
        }

        // Return from disk cache if available
        if let stored = diskCache[bundleID] {
            let color = stored.color
            cache[bundleID] = color
            lock.unlock()
            return color
        }

        // Cache miss: return deterministic fallback immediately and extract asynchronously.
        if !pendingExtractions.contains(bundleID) {
            pendingExtractions.insert(bundleID)
            DispatchQueue.global(qos: .utility).async { [weak self] in
                self?.extractAndCacheColor(for: bundleID)
            }
        }
        lock.unlock()
        return fallbackColor(for: bundleID)
    }

    private func extractAndCacheColor(for bundleID: String) {
        let color = extractDominantColor(for: bundleID)

        lock.lock()
        cache[bundleID] = color
        pendingExtractions.remove(bundleID)
        lock.unlock()

        // Persist asynchronously to keep extraction path non-blocking.
        saveToDiskAsync(bundleID: bundleID, color: color)
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

// MARK: - Tag Color Storage

/// Persists per-tag colors selected by users in Settings.
/// Colors are keyed by tag ID and fall back to a deterministic color when unset.
public enum TagColorStore {
    private static let defaults: UserDefaults = UserDefaults(suiteName: "io.retrace.app") ?? .standard
    private static let storageKey = "tagColorsByID"
    private static let lock = NSLock()
    private static var cachedHexByTagID: [Int64: String] = [:]
    private static var didLoadCache = false

    public static func color(for tag: Tag) -> Color {
        color(forTagID: tag.id, tagName: tag.name)
    }

    public static func color(forTagID tagID: TagID, tagName: String? = nil) -> Color {
        lock.lock()
        loadCacheIfNeededLocked()
        let storedHex = cachedHexByTagID[tagID.value]
        lock.unlock()

        if let storedHex, let storedColor = colorFromHex(storedHex) {
            return storedColor
        }

        return fallbackColor(forTagID: tagID, tagName: tagName)
    }

    public static func setColor(_ color: Color, for tagID: TagID) {
        let hex = hexString(from: color)
        var didChange = false

        lock.lock()
        loadCacheIfNeededLocked()

        if cachedHexByTagID[tagID.value] != hex {
            cachedHexByTagID[tagID.value] = hex
            persistLocked()
            didChange = true
        }

        lock.unlock()

        if didChange {
            NotificationCenter.default.post(name: .tagColorsDidChange, object: tagID)
        }
    }

    public static func removeColor(for tagID: TagID) {
        var didChange = false

        lock.lock()
        loadCacheIfNeededLocked()

        if cachedHexByTagID.removeValue(forKey: tagID.value) != nil {
            persistLocked()
            didChange = true
        }

        lock.unlock()

        if didChange {
            NotificationCenter.default.post(name: .tagColorsDidChange, object: tagID)
        }
    }

    public static func pruneColors(keeping validTagIDs: Set<Int64>) {
        var didChange = false

        lock.lock()
        loadCacheIfNeededLocked()

        let initialCount = cachedHexByTagID.count
        cachedHexByTagID = cachedHexByTagID.filter { validTagIDs.contains($0.key) }
        didChange = cachedHexByTagID.count != initialCount

        if didChange {
            persistLocked()
        }

        lock.unlock()

        if didChange {
            NotificationCenter.default.post(name: .tagColorsDidChange, object: nil)
        }
    }

    public static func suggestedColor(for tagName: String) -> Color {
        fallbackColor(forTagID: TagID(value: 0), tagName: tagName)
    }

    private static func loadCacheIfNeededLocked() {
        guard !didLoadCache else { return }
        defer { didLoadCache = true }

        guard let raw = defaults.dictionary(forKey: storageKey) as? [String: String] else {
            cachedHexByTagID = [:]
            return
        }

        cachedHexByTagID = raw.reduce(into: [:]) { map, entry in
            guard let id = Int64(entry.key) else { return }
            map[id] = entry.value
        }
    }

    private static func persistLocked() {
        let serialized = cachedHexByTagID.reduce(into: [String: String]()) { map, entry in
            map[String(entry.key)] = entry.value
        }
        defaults.set(serialized, forKey: storageKey)
    }

    private static func fallbackColor(forTagID tagID: TagID, tagName: String?) -> Color {
        let normalizedName = (tagName ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let hashSeed = normalizedName.isEmpty ? "tag-\(tagID.value)" : "tag-\(tagID.value)-\(normalizedName)"
        let hash = stableHash(for: hashSeed)
        let hue = Double(hash % 360) / 360.0
        return Color(hue: hue, saturation: 0.72, brightness: 0.88)
    }

    private static func stableHash(for input: String) -> UInt64 {
        // FNV-1a 64-bit hash for deterministic color assignment.
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in input.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash
    }

    private static func colorFromHex(_ hex: String) -> Color? {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard cleaned.count == 6 else { return nil }
        return Color(hex: cleaned)
    }

    private static func hexString(from color: Color) -> String {
        let nsColor = NSColor(color).usingColorSpace(.sRGB) ?? NSColor.systemBlue

        let red = max(0, min(255, Int((nsColor.redComponent * 255).rounded())))
        let green = max(0, min(255, Int((nsColor.greenComponent * 255).rounded())))
        let blue = max(0, min(255, Int((nsColor.blueComponent * 255).rounded())))

        return String(format: "#%02X%02X%02X", red, green, blue)
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

    // Submit/action button accent - slightly deeper tones for filled buttons
    public static var retraceSubmitAccent: Color {
        let theme = MilestoneCelebrationManager.getCurrentTheme()
        switch theme {
        case .blue:
            return Color(red: 59/255, green: 130/255, blue: 246/255)
        case .gold:
            return Color(red: 245/255, green: 180/255, blue: 0/255)
        case .purple:
            return Color(red: 148/255, green: 84/255, blue: 242/255)
        }
    }

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
public enum RetraceFontStyle: String, CaseIterable, Identifiable, Sendable {
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
    private static let settingsStore = UserDefaults(suiteName: "io.retrace.app") ?? .standard

    /// The current font style (persisted in UserDefaults)
    public static var currentStyle: RetraceFontStyle {
        get {
            if let rawValue = settingsStore.string(forKey: fontStyleKey),
               let style = RetraceFontStyle(rawValue: rawValue) {
                return style
            }
            return .default
        }
        set {
            settingsStore.set(newValue.rawValue, forKey: fontStyleKey)
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
    private static let maxScale: CGFloat = 1.35

    /// Thread-safe cached scale factor to prevent size changes during window lifecycle
    private static var _cachedScaleFactor: CGFloat?
    private static let lock = NSLock()

    /// Calculate scale factor based on the screen where the timeline is displayed
    /// Returns cached value to prevent UI size changes during window lifecycle
    public static var current: CGFloat {
        lock.lock()
        defer { lock.unlock() }

        if let cached = _cachedScaleFactor {
            return cached
        }

        // Use the screen where the mouse is (where the timeline will open),
        // not NSScreen.main (which is always the primary display)
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) }) ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return 1.0 }
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

    /// Y offset for control buttons above tape.
    /// Raised by 10pt from baseline.
    public static var controlsYOffset: CGFloat { -65 * current }

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

    /// Font for keyboard shortcut hints shown on the right side of menu rows
    /// Use default system design so symbol glyphs like "⌫" and "⌘" render cleanly.
    public static let shortcutFont = Font.system(size: 14, weight: .semibold)

    /// Reserved width for the right-aligned shortcut column
    public static let shortcutColumnMinWidth: CGFloat = 38

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

    /// Base accent color for filter control strokes (buttons and fields).
    /// Uses the lighter Retrace accent for consistent focus/hover/open outlines.
    public static var filterStrokeAccent: Color {
        Color.retraceAccent
    }

    /// Strong stroke color for hovered/focused/open filter controls.
    public static var filterStrokeStrong: Color {
        filterStrokeAccent.opacity(0.95)
    }

    /// Medium stroke color for active/selected filter controls.
    public static var filterStrokeMedium: Color {
        filterStrokeAccent.opacity(0.45)
    }

    /// Subtle resting stroke color for filter controls.
    public static var filterStrokeSubtle: Color {
        filterStrokeAccent.opacity(0.18)
    }

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

// MARK: - Timeline Overlay Surface Families

/// Fullscreen timeline overlays must use one of two families:
/// glass black for transient HUD chrome, or matte dark gray for owned editors/dialogs.
public enum RetraceTimelineGlassVariant {
    case chip
    case banner
    case panel

    var fillColor: Color {
        switch self {
        case .chip:
            return Color.black.opacity(0.46)
        case .banner:
            return Color.black.opacity(0.56)
        case .panel:
            return Color.black.opacity(0.4)
        }
    }

    var materialOpacity: Double {
        switch self {
        case .chip:
            return 0.9
        case .banner:
            return 1.0
        case .panel:
            return 1.0
        }
    }

    var borderColor: Color {
        switch self {
        case .chip:
            return Color.white.opacity(0.18)
        case .banner:
            return Color.white.opacity(0.16)
        case .panel:
            return Color.white.opacity(0.15)
        }
    }

    var shadowColor: Color {
        Color.black.opacity(0.5)
    }

    var shadowRadius: CGFloat {
        switch self {
        case .chip:
            return 12
        case .banner:
            return 20
        case .panel:
            return 20
        }
    }

    var shadowY: CGFloat {
        switch self {
        case .chip:
            return 5
        case .banner, .panel:
            return 10
        }
    }
}

public struct RetraceTimelineGlassSurface: ViewModifier {
    let variant: RetraceTimelineGlassVariant
    let cornerRadius: CGFloat
    let borderColorOverride: Color?

    public func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial.opacity(variant.materialOpacity))
                    .environment(\.colorScheme, .dark)
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(variant.fillColor)
                    )
                    .shadow(
                        color: variant.shadowColor,
                        radius: variant.shadowRadius,
                        y: variant.shadowY
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(borderColorOverride ?? variant.borderColor, lineWidth: 1)
            )
    }
}

public struct RetraceMattePanelSurface: ViewModifier {
    let cornerRadius: CGFloat
    let addPadding: Bool

    public func body(content: Content) -> some View {
        content.retraceMenuContainer(addPadding: addPadding, cornerRadius: cornerRadius)
    }
}

// MARK: - Reusable Menu Components

/// Standardized menu button component
/// Used in context menus, popovers, and dialogs for consistent appearance
public struct RetraceMenuButton: View {
    let icon: String
    let title: String
    var shortcut: String? = nil
    var showChevron: Bool = false
    var isDestructive: Bool = false
    var isDisabled: Bool = false
    var onHoverChanged: ((Bool) -> Void)? = nil
    let action: () -> Void

    @State private var isHovering = false

    public init(
        icon: String,
        title: String,
        shortcut: String? = nil,
        showChevron: Bool = false,
        isDestructive: Bool = false,
        isDisabled: Bool = false,
        onHoverChanged: ((Bool) -> Void)? = nil,
        action: @escaping () -> Void
    ) {
        self.icon = icon
        self.title = title
        self.shortcut = shortcut
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
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)

                Spacer(minLength: 0)

                if let shortcut {
                    Text(shortcut)
                        .font(RetraceMenuStyle.shortcutFont)
                        .foregroundColor(shortcutColor)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .frame(minWidth: RetraceMenuStyle.shortcutColumnMinWidth, alignment: .trailing)
                        .layoutPriority(1)
                }

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

    private var shortcutColor: Color {
        if isDisabled {
            return RetraceMenuStyle.textColorMuted.opacity(0.4)
        }
        return RetraceMenuStyle.textColorMuted.opacity(isHovering ? 0.95 : 0.7)
    }
}

/// Shared UserDefaults store for accessing settings
private let menuContainerSettingsStore = UserDefaults(suiteName: "io.retrace.app") ?? .standard

/// Standardized menu container modifier
/// Applies consistent background, border, and shadow to any menu/popover content
/// Border color adapts based on user's color theme preference
public struct RetraceMenuContainer: ViewModifier {
    var addPadding: Bool = true
    var cornerRadius: CGFloat = RetraceMenuStyle.cornerRadius

    private var showColoredBorders: Bool {
        menuContainerSettingsStore.bool(forKey: "timelineColoredBorders")
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
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(RetraceMenuStyle.backgroundColor)
                .shadow(
                    color: RetraceMenuStyle.shadowColor,
                    radius: RetraceMenuStyle.shadowRadius,
                    y: RetraceMenuStyle.shadowY
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(borderColor, lineWidth: RetraceMenuStyle.borderWidth)
        )
    }
}

extension View {
    /// Apply standardized menu/popover container styling
    public func retraceMenuContainer(
        addPadding: Bool = true,
        cornerRadius: CGFloat = RetraceMenuStyle.cornerRadius
    ) -> some View {
        self.modifier(RetraceMenuContainer(addPadding: addPadding, cornerRadius: cornerRadius))
    }

    public func timelineGlassSurface(
        _ variant: RetraceTimelineGlassVariant,
        cornerRadius: CGFloat,
        borderColor: Color? = nil
    ) -> some View {
        self.modifier(
            RetraceTimelineGlassSurface(
                variant: variant,
                cornerRadius: cornerRadius,
                borderColorOverride: borderColor
            )
        )
    }

    public func retraceMattePanel(
        addPadding: Bool = true,
        cornerRadius: CGFloat = RetraceMenuStyle.cornerRadius
    ) -> some View {
        self.modifier(RetraceMattePanelSurface(cornerRadius: cornerRadius, addPadding: addPadding))
    }
}

/// Standardized search field for menus/popovers
public struct RetraceMenuSearchField: View {
    @Binding var text: String
    var placeholder: String
    var onSubmit: (() -> Void)? = nil
    @FocusState private var isFocused: Bool

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
                .focused($isFocused)
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
        .contentShape(Rectangle())
        .onTapGesture {
            isFocused = true
        }
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
                    Animation.easeOut(duration: 3.0)
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
    /// Posted when user-defined tag colors are updated
    public static let tagColorsDidChange = Notification.Name("tagColorsDidChange")
}
