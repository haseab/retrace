import SwiftUI
import AppKit

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
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let retraceDir = appSupport.appendingPathComponent("Retrace", isDirectory: true)
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

        // Try to get the icon from the system
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let icon = NSWorkspace.shared.icon(forFile: appURL.path)
            cache[bundleID] = icon
            return icon
        }

        return nil
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
        // Store in Application Support/Retrace/
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let retraceDir = appSupport.appendingPathComponent("Retrace", isDirectory: true)

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
    // Deep blue background: hsl(222, 47%, 4%) = #040b1a
    public static let retraceDeepBlue = Color(red: 4/255, green: 11/255, blue: 26/255)

    // Primary blue: hsl(217, 91%, 60%) = vibrant blue
    public static let retraceAccent = Color(red: 74/255, green: 144/255, blue: 226/255)

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
    public static let retraceBoundingBoxSecondary = Color(red: 100/255, green: 200/255, blue: 255/255)
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

    /// The current font style (persisted in UserDefaults)
    public static var currentStyle: RetraceFontStyle {
        get {
            if let rawValue = UserDefaults.standard.string(forKey: fontStyleKey),
               let style = RetraceFontStyle(rawValue: rawValue) {
                return style
            }
            return .default
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: fontStyleKey)
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
    public static let retraceDisplay = RetraceFont.font(size: 48, weight: .bold)
    public static let retraceDisplay2 = RetraceFont.font(size: 36, weight: .bold)
    public static let retraceDisplay3 = RetraceFont.font(size: 32, weight: .bold)

    // MARK: Titles
    public static let retraceTitle = RetraceFont.font(size: 28, weight: .bold)
    public static let retraceTitle2 = RetraceFont.font(size: 22, weight: .bold)
    public static let retraceTitle3 = RetraceFont.font(size: 20, weight: .semibold)

    // MARK: Large Numbers (for stats/metrics display)
    public static let retraceLargeNumber = RetraceFont.font(size: 28, weight: .bold)
    public static let retraceMediumNumber = RetraceFont.font(size: 24, weight: .semibold)

    // MARK: Body Text
    public static let retraceHeadline = RetraceFont.font(size: 17, weight: .semibold)
    public static let retraceBody = RetraceFont.font(size: 15, weight: .regular)
    public static let retraceBodyMedium = RetraceFont.font(size: 15, weight: .medium)
    public static let retraceBodyBold = RetraceFont.font(size: 15, weight: .semibold)
    public static let retraceCallout = RetraceFont.font(size: 14, weight: .regular)
    public static let retraceCalloutMedium = RetraceFont.font(size: 14, weight: .medium)
    public static let retraceCalloutBold = RetraceFont.font(size: 14, weight: .semibold)

    // MARK: Small Text
    public static let retraceCaption = RetraceFont.font(size: 13, weight: .regular)
    public static let retraceCaptionMedium = RetraceFont.font(size: 13, weight: .medium)
    public static let retraceCaptionBold = RetraceFont.font(size: 13, weight: .semibold)
    public static let retraceCaption2 = RetraceFont.font(size: 11, weight: .regular)
    public static let retraceCaption2Medium = RetraceFont.font(size: 11, weight: .medium)
    public static let retraceCaption2Bold = RetraceFont.font(size: 11, weight: .semibold)

    // MARK: Tiny Text (for labels, badges)
    public static let retraceTiny = RetraceFont.font(size: 10, weight: .regular)
    public static let retraceTinyMedium = RetraceFont.font(size: 10, weight: .medium)
    public static let retraceTinyBold = RetraceFont.font(size: 10, weight: .semibold)

    // MARK: Monospace (for IDs, technical data - always uses monospaced design)
    public static let retraceMono = RetraceFont.mono(size: 13)
    public static let retraceMonoSmall = RetraceFont.mono(size: 11)
    public static let retraceMonoLarge = RetraceFont.mono(size: 15)
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
    public static let retraceAccentGradient = LinearGradient(
        colors: [
            Color(red: 74/255, green: 144/255, blue: 226/255),
            Color(red: 139/255, green: 92/255, blue: 246/255)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    public static let retracePurpleGradient = LinearGradient(
        colors: [
            Color(red: 139/255, green: 92/255, blue: 246/255),
            Color(red: 217/255, green: 70/255, blue: 239/255)
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

    /// Calculate scale factor based on current screen height
    public static var current: CGFloat {
        guard let screen = NSScreen.main else { return 1.0 }
        let screenHeight = screen.frame.height
        let rawScale = screenHeight / referenceHeight
        return min(maxScale, max(minScale, rawScale))
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
    public static var searchPanelYOffset: CGFloat { -175 * current }

    /// Y offset for calendar picker
    public static var calendarPickerYOffset: CGFloat { -280 * current }

    /// X position for left controls
    public static var leftControlsX: CGFloat { 120 * current }

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
    public static var controlButtonSize: CGFloat { 32 * current }

    /// Zoom slider width
    public static var zoomSliderWidth: CGFloat { 100 * current }

    /// Search button width
    public static var searchButtonWidth: CGFloat { 160 * current }

    // MARK: - Panel Dimensions (scaled)

    /// Floating date search panel width
    public static var searchPanelWidth: CGFloat { 380 * current }

    /// Calendar picker width
    public static var calendarPickerWidth: CGFloat { 280 * current }

    /// Calendar picker height
    public static var calendarPickerHeight: CGFloat { 340 * current }

    // MARK: - Font Sizes (scaled)

    /// Callout font size (14pt base)
    public static var fontCallout: CGFloat { 14 * current }

    /// Caption font size (13pt base)
    public static var fontCaption: CGFloat { 13 * current }

    /// Caption2 font size (11pt base)
    public static var fontCaption2: CGFloat { 11 * current }

    /// Tiny font size (10pt base)
    public static var fontTiny: CGFloat { 10 * current }

    /// Mono font size (13pt base)
    public static var fontMono: CGFloat { 13 * current }

    // MARK: - Padding/Spacing (scaled)

    /// Standard horizontal padding for buttons
    public static var buttonPaddingH: CGFloat { 12 * current }

    /// Standard vertical padding for buttons
    public static var buttonPaddingV: CGFloat { 8 * current }

    /// Larger horizontal padding
    public static var paddingH: CGFloat { 16 * current }

    /// Larger vertical padding
    public static var paddingV: CGFloat { 10 * current }

    /// Control spacing
    public static var controlSpacing: CGFloat { 12 * current }

    /// Icon spacing within buttons
    public static var iconSpacing: CGFloat { 8 * current }
}
