import SwiftUI
import Shared

/// Visual indicator for an app session in the timeline
/// Shows app icon, name, and duration with consistent color coding
public struct SessionIndicator: View {

    // MARK: - Properties

    let session: AppSession
    let width: CGFloat
    let isSelected: Bool
    let onTap: () -> Void

    @State private var isHovered = false

    // MARK: - Initialization

    public init(
        session: AppSession,
        width: CGFloat,
        isSelected: Bool = false,
        onTap: @escaping () -> Void = {}
    ) {
        self.session = session
        self.width = width
        self.isSelected = isSelected
        self.onTap = onTap
    }

    // MARK: - Body

    public var body: some View {
        VStack(spacing: 0) {
            // Session bar
            Rectangle()
                .fill(sessionColor)
                .frame(width: width, height: 24)
                .overlay(
                    HStack(spacing: 4) {
                        // App icon (if available)
                        if let icon = appIcon {
                            Image(nsImage: icon)
                                .resizable()
                                .frame(width: 16, height: 16)
                        }

                        // App name
                        if width > 60 {
                            Text(session.appName ?? session.appBundleID)
                                .font(.retraceCaption2)
                                .foregroundColor(.white)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }

                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 4)
                )
                .cornerRadius(4)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(
                            borderColor,
                            lineWidth: isSelected ? 2 : (isHovered ? 1.5 : 0)
                        )
                )
                .shadow(
                    color: isSelected ? sessionColor.opacity(0.5) : .clear,
                    radius: 4,
                    x: 0,
                    y: 2
                )
        }
        .onHover { hovering in
            isHovered = hovering
        }
        .onTapGesture {
            onTap()
        }
        .popover(isPresented: .constant(isHovered && !isSelected)) {
            sessionTooltip
        }
    }

    // MARK: - Tooltip

    private var sessionTooltip: some View {
        VStack(alignment: .leading, spacing: .spacingS) {
            // App name and icon
            HStack(spacing: .spacingS) {
                if let icon = appIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 32, height: 32)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(session.appName ?? session.appBundleID)
                        .font(.retraceHeadline)
                        .foregroundColor(.retracePrimary)

                    Text(session.appBundleID)
                        .font(.retraceCaption)
                        .foregroundColor(.retraceSecondary)
                        .lineLimit(1)
                }
            }

            Divider()

            // Session details
            DetailRow(label: "Start", value: formatTime(session.startTime))
            if let endTime = session.endTime {
                DetailRow(label: "End", value: formatTime(endTime))
            }
            if let duration = session.duration {
                DetailRow(label: "Duration", value: formatDuration(duration))
            }

            // Window title (if available)
            if let windowName = session.windowName, !windowName.isEmpty {
                Divider()
                DetailRow(label: "Window", value: windowName)
            }

            // URL (if browser)
            if let url = session.browserURL, !url.isEmpty {
                DetailRow(label: "URL", value: url)
            }
        }
        .padding(.spacingM)
        .frame(maxWidth: 300)
    }

    // MARK: - Helpers

    private var sessionColor: Color {
        Color.sessionColor(for: session.appBundleID)
    }

    private var borderColor: Color {
        if isSelected {
            return .retraceAccent
        } else if isHovered {
            return .white.opacity(0.5)
        } else {
            return .clear
        }
    }

    private var appIcon: NSImage? {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: session.appBundleID) else {
            return nil
        }
        return NSWorkspace.shared.icon(forFile: appURL.path)
    }

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let hours = Int(duration) / 3600
        let minutes = Int(duration) / 60 % 60
        let seconds = Int(duration) % 60

        if hours > 0 {
            return String(format: "%dh %dm", hours, minutes)
        } else if minutes > 0 {
            return String(format: "%dm %ds", minutes, seconds)
        } else {
            return String(format: "%ds", seconds)
        }
    }
}

// MARK: - Detail Row

private struct DetailRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top) {
            Text(label + ":")
                .font(.retraceCaption)
                .foregroundColor(.retraceSecondary)
                .frame(width: 70, alignment: .leading)

            Text(value)
                .font(.retraceCaption)
                .foregroundColor(.retracePrimary)
                .lineLimit(2)

            Spacer(minLength: 0)
        }
    }
}

// MARK: - Preview

#if DEBUG
struct SessionIndicator_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: .spacingM) {
            // Normal session
            SessionIndicator(
                session: AppSession(
                    id: AppSessionID(value: UUID()),
                    appBundleID: "com.google.Chrome",
                    appName: "Chrome",
                    windowName: "GitHub - retrace/main",
                    browserURL: "https://github.com/haseab/retrace",
                    displayID: nil,
                    startTime: Date().addingTimeInterval(-3600),
                    endTime: Date().addingTimeInterval(-1800)
                ),
                width: 150,
                isSelected: false
            )

            // Selected session
            SessionIndicator(
                session: AppSession(
                    id: AppSessionID(value: UUID()),
                    appBundleID: "com.apple.dt.Xcode",
                    appName: "Xcode",
                    windowName: nil,
                    browserURL: nil,
                    displayID: nil,
                    startTime: Date().addingTimeInterval(-1800),
                    endTime: Date()
                ),
                width: 200,
                isSelected: true
            )

            // Short session
            SessionIndicator(
                session: AppSession(
                    id: AppSessionID(value: UUID()),
                    appBundleID: "com.tinyspeck.slackmacgap",
                    appName: "Slack",
                    windowName: nil,
                    browserURL: nil,
                    displayID: nil,
                    startTime: Date().addingTimeInterval(-300),
                    endTime: Date()
                ),
                width: 50,
                isSelected: false
            )
        }
        .padding()
        .frame(width: 400, height: 300)
        .background(Color.retraceBackground)
        .preferredColorScheme(.dark)
    }
}
#endif
