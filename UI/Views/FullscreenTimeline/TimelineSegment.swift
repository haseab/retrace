import SwiftUI
import Shared

/// Visual representation of an app session in the timeline bar
/// Shows a colored rectangle with app icon on hover
public struct TimelineSegment: View {

    // MARK: - Properties

    let session: AppSession
    let totalWidth: CGFloat
    let segmentHeight: CGFloat
    let timeRange: (start: Date, end: Date)
    let isSelected: Bool

    @State private var isHovered = false

    // MARK: - Computed Properties

    private var segmentWidth: CGFloat {
        let totalDuration = timeRange.end.timeIntervalSince(timeRange.start)
        guard totalDuration > 0 else { return 50 }

        let sessionEnd = session.endTime ?? Date()
        let sessionDuration = sessionEnd.timeIntervalSince(session.startTime)
        let width = CGFloat(sessionDuration / totalDuration) * totalWidth

        return max(4, width) // Minimum width of 4 pixels
    }

    private var segmentColor: Color {
        Color.sessionColor(for: session.appBundleID)
    }

    // MARK: - Body

    public var body: some View {
        ZStack(alignment: .leading) {
            // Main segment bar
            RoundedRectangle(cornerRadius: 4)
                .fill(segmentColor.opacity(isSelected ? 1.0 : 0.7))
                .frame(width: segmentWidth, height: segmentHeight)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(
                            isSelected ? Color.white : Color.clear,
                            lineWidth: 2
                        )
                )
                .shadow(
                    color: isHovered ? segmentColor.opacity(0.5) : .clear,
                    radius: 4,
                    x: 0,
                    y: 2
                )

            // App info tooltip on hover
            if isHovered && segmentWidth > 30 {
                HStack(spacing: .spacingS) {
                    // App icon placeholder
                    Circle()
                        .fill(Color.white.opacity(0.3))
                        .frame(width: 16, height: 16)
                        .overlay(
                            Text(String(session.appName?.prefix(1) ?? "?"))
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(.white)
                        )

                    // App name (if space allows)
                    if segmentWidth > 80 {
                        Text(session.appName ?? "Unknown")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.white)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, .spacingS)
            }
        }
        .frame(width: segmentWidth, height: segmentHeight)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .help(tooltipText)
    }

    // MARK: - Tooltip

    private var tooltipText: String {
        let appName = session.appName ?? "Unknown App"
        let duration = formatDuration(session.duration ?? 0)
        return "\(appName)\n\(duration)"
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let hours = Int(duration) / 3600
        let minutes = (Int(duration) % 3600) / 60
        let seconds = Int(duration) % 60

        if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else if minutes > 0 {
            return "\(minutes)m \(seconds)s"
        } else {
            return "\(seconds)s"
        }
    }
}

// MARK: - Preview

#if DEBUG
struct TimelineSegment_Previews: PreviewProvider {
    static var previews: some View {
        HStack(spacing: 2) {
            // Chrome session
            TimelineSegment(
                session: AppSession(
                    id: AppSessionID(value: UUID()),
                    appBundleID: "com.google.Chrome",
                    appName: "Google Chrome",
                    windowName: "GitHub",
                    startTime: Date().addingTimeInterval(-3600),
                    endTime: Date().addingTimeInterval(-1800)
                ),
                totalWidth: 600,
                segmentHeight: 40,
                timeRange: (Date().addingTimeInterval(-3600), Date()),
                isSelected: false
            )

            // Xcode session (selected)
            TimelineSegment(
                session: AppSession(
                    id: AppSessionID(value: UUID()),
                    appBundleID: "com.apple.dt.Xcode",
                    appName: "Xcode",
                    windowName: "Project.swift",
                    startTime: Date().addingTimeInterval(-1800),
                    endTime: Date()
                ),
                totalWidth: 600,
                segmentHeight: 40,
                timeRange: (Date().addingTimeInterval(-3600), Date()),
                isSelected: true
            )
        }
        .padding()
        .background(Color.black)
        .preferredColorScheme(.dark)
    }
}
#endif
