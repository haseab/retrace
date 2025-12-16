import SwiftUI

/// Retrace design system
/// Provides consistent colors, typography, and spacing across the UI
public struct AppTheme {
    private init() {}
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

    // MARK: Session Colors (hashed from bundle ID)
    public static func sessionColor(for appBundleID: String) -> Color {
        let hash = appBundleID.hashValue
        let hue = Double(abs(hash) % 360) / 360.0
        return Color(hue: hue, saturation: 0.7, brightness: 0.75)
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
