import SwiftUI

/// Modern analytics card component with glassmorphism styling
public struct AnalyticsCard: View {

    // MARK: - Properties

    let title: String
    let value: String
    let subtitle: String?
    let icon: String
    let gradient: LinearGradient

    // MARK: - Initialization

    public init(
        title: String,
        value: String,
        subtitle: String? = nil,
        icon: String,
        gradient: LinearGradient = .retraceAccentGradient
    ) {
        self.title = title
        self.value = value
        self.subtitle = subtitle
        self.icon = icon
        self.gradient = gradient
    }

    /// Legacy initializer for backwards compatibility
    public init(
        title: String,
        value: String,
        subtitle: String? = nil,
        icon: String,
        accentColor: Color
    ) {
        self.title = title
        self.value = value
        self.subtitle = subtitle
        self.icon = icon
        self.gradient = LinearGradient(
            colors: [accentColor, accentColor.opacity(0.7)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    // MARK: - Body

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Icon with gradient background
            ZStack {
                Circle()
                    .fill(gradient.opacity(0.2))
                    .frame(width: 48, height: 48)

                Image(systemName: icon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(gradient)
            }

            VStack(alignment: .leading, spacing: 6) {
                // Value
                Text(value)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundColor(.retracePrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                // Title
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.retraceSecondary)
            }

            // Subtitle (optional)
            if let subtitle = subtitle {
                Text(subtitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.retraceSecondary.opacity(0.7))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(24)
        .background(
            ZStack {
                // Base background
                Color.white.opacity(0.03)

                // Subtle gradient overlay
                LinearGradient(
                    colors: [Color.white.opacity(0.02), Color.clear],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        )
        .cornerRadius(20)
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.1),
                            Color.white.opacity(0.05)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
    }
}

// MARK: - Preview

#if DEBUG
struct AnalyticsCard_Previews: PreviewProvider {
    static var previews: some View {
        HStack(spacing: 16) {
            AnalyticsCard(
                title: "Frames Captured",
                value: "2.3M",
                subtitle: "+1,247 today",
                icon: "photo.on.rectangle.angled",
                gradient: .retraceAccentGradient
            )

            AnalyticsCard(
                title: "Storage Used",
                value: "147 GB",
                subtitle: "23% of 500 GB",
                icon: "internaldrive",
                gradient: .retraceOrangeGradient
            )

            AnalyticsCard(
                title: "Days Recording",
                value: "127",
                subtitle: "Since Jan 15, 2024",
                icon: "calendar",
                gradient: .retraceGreenGradient
            )
        }
        .padding(32)
        .background(Color.retraceBackground)
        .preferredColorScheme(.dark)
    }
}
#endif
