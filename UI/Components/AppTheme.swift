import SwiftUI
import AppKit

/// Retrace design system
/// Provides consistent colors, typography, and spacing across the UI
public struct AppTheme {
    private init() {}
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

extension Font {
    // MARK: Titles
    public static let retraceTitle = Font.system(size: 28, weight: .bold)
    public static let retraceTitle2 = Font.system(size: 22, weight: .bold)
    public static let retraceTitle3 = Font.system(size: 20, weight: .semibold)

    // MARK: Body Text
    public static let retraceHeadline = Font.system(size: 17, weight: .semibold)
    public static let retraceBody = Font.system(size: 15, weight: .regular)
    public static let retraceBodyBold = Font.system(size: 15, weight: .semibold)
    public static let retraceCallout = Font.system(size: 14, weight: .regular)

    // MARK: Small Text
    public static let retraceCaption = Font.system(size: 13, weight: .regular)
    public static let retraceCaption2 = Font.system(size: 11, weight: .regular)

    // MARK: Monospace (for IDs, technical data)
    public static let retraceMono = Font.system(size: 13, weight: .regular, design: .monospaced)
    public static let retraceMonoSmall = Font.system(size: 11, weight: .regular, design: .monospaced)
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
