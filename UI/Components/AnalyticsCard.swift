import SwiftUI

/// Reusable analytics card component for dashboard stats
public struct AnalyticsCard: View {

    // MARK: - Properties

    let title: String
    let value: String
    let subtitle: String?
    let icon: String
    let accentColor: Color

    // MARK: - Initialization

    public init(
        title: String,
        value: String,
        subtitle: String? = nil,
        icon: String,
        accentColor: Color = .retraceAccent
    ) {
        self.title = title
        self.value = value
        self.subtitle = subtitle
        self.icon = icon
        self.accentColor = accentColor
    }

    // MARK: - Body

    public var body: some View {
        VStack(alignment: .leading, spacing: .spacingM) {
            // Header with icon
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 24))
                    .foregroundColor(accentColor)

                Spacer()
            }

            // Value
            Text(value)
                .font(.system(size: 32, weight: .bold))
                .foregroundColor(.retracePrimary)

            // Title
            Text(title)
                .font(.retraceBody)
                .foregroundColor(.retraceSecondary)

            // Subtitle (optional)
            if let subtitle = subtitle {
                Text(subtitle)
                    .font(.retraceCaption)
                    .foregroundColor(.retraceSecondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.spacingL)
        .background(Color.retraceCard)
        .cornerRadius(.cornerRadiusL)
        .retraceShadowLight()
    }
}

// MARK: - Preview

#if DEBUG
struct AnalyticsCard_Previews: PreviewProvider {
    static var previews: some View {
        HStack(spacing: .spacingM) {
            AnalyticsCard(
                title: "Frames Captured",
                value: "2.3M",
                subtitle: "+1,247 today",
                icon: "photo.on.rectangle.angled",
                accentColor: .retraceAccent
            )

            AnalyticsCard(
                title: "Storage Used",
                value: "147 GB",
                subtitle: "23% of 500 GB",
                icon: "internaldrive",
                accentColor: .retraceWarning
            )

            AnalyticsCard(
                title: "Days Recording",
                value: "127",
                subtitle: "Since Jan 15, 2024",
                icon: "calendar",
                accentColor: .retraceSuccess
            )
        }
        .padding()
        .background(Color.retraceBackground)
        .preferredColorScheme(.dark)
    }
}
#endif
