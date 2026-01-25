import SwiftUI
import AppKit
import Shared

/// List-style view for app usage data (traditional top 10 ranking)
struct AppUsageListView: View {
    let apps: [AppUsageData]
    var onAppTapped: ((AppUsageData) -> Void)? = nil
    @State private var hoveredAppIndex: Int? = nil

    var body: some View {
        VStack(spacing: 8) {
            ForEach(Array(apps.prefix(10).enumerated()), id: \.offset) { index, app in
                appUsageRow(index: index, app: app)
            }
        }
        .padding(16)
    }

    private func appUsageRow(index: Int, app: AppUsageData) -> some View {
        let isHovered = hoveredAppIndex == index
        let appColor = Color.segmentColor(for: app.appBundleID)

        // Rank colors: gold for #1, silver for #2, bronze for #3
        let rankColor: Color = switch index {
        case 0: Color(red: 255/255, green: 215/255, blue: 0/255)   // Gold
        case 1: Color(red: 192/255, green: 192/255, blue: 192/255) // Silver
        case 2: Color(red: 205/255, green: 127/255, blue: 50/255)  // Bronze
        default: .retraceSecondary
        }

        return HStack(spacing: 12) {
            // Rank number
            Text("\(index + 1)")
                .font(.retraceCaption2Bold)
                .foregroundColor(rankColor)
                .frame(width: 20)

            // App icon
            AppIconView(bundleID: app.appBundleID, size: 32)

            // App info
            VStack(alignment: .leading, spacing: 2) {
                Text(app.appName)
                    .font(.retraceCalloutMedium)
                    .foregroundColor(.retracePrimary)
                    .lineLimit(1)

                Text("\(app.sessionCount) session\(app.sessionCount == 1 ? "" : "s")")
                    .font(.retraceCaption2)
                    .foregroundColor(.retraceSecondary)
            }

            Spacer()

            // Progress bar
            GeometryReader { geometry in
                ZStack(alignment: .trailing) {
                    // Background
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.white.opacity(0.05))

                    // Progress
                    RoundedRectangle(cornerRadius: 4)
                        .fill(
                            LinearGradient(
                                colors: [appColor.opacity(0.8), appColor.opacity(0.4)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(geometry.size.width * app.percentage, 8))
                }
            }
            .frame(width: 120, height: 6)

            // Duration and percentage
            VStack(alignment: .trailing, spacing: 2) {
                Text(formatDuration(app.duration))
                    .font(.retraceCalloutBold)
                    .foregroundColor(.retracePrimary)

                Text(String(format: "%.1f%%", app.percentage * 100))
                    .font(.retraceCaption2Medium)
                    .foregroundColor(.retraceSecondary)
            }
            .frame(width: 70, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isHovered ? Color.white.opacity(0.05) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering {
                NSCursor.pointingHand.set()
            } else {
                NSCursor.arrow.set()
            }
            withAnimation(.easeInOut(duration: 0.15)) {
                hoveredAppIndex = hovering ? index : nil
            }
        }
        .onTapGesture {
            onAppTapped?(app)
        }
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let hours = Int(duration) / 3600
        let minutes = (Int(duration) % 3600) / 60

        if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else {
            return "\(minutes)m"
        }
    }
}
