import SwiftUI
import AppKit

/// Banner view for displaying permission-related warnings with action buttons
struct PermissionBanner: View {
    let message: String
    let actionTitle: String
    let action: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Warning icon
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
                .font(.system(size: 20))

            // Message
            Text(message)
                .font(.system(size: 13))
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()

            // Action button
            Button(action: action) {
                Text(actionTitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.accentColor)
                    .cornerRadius(6)
            }
            .buttonStyle(.plain)

            // Dismiss button
            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
                    .font(.system(size: 16))
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(Color.orange.opacity(0.1))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.orange.opacity(0.3), lineWidth: 1)
        )
    }
}

/// Helper to open System Settings to specific panes
struct SystemSettingsOpener {
    /// Open Accessibility privacy settings
    static func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    /// Open Screen Recording privacy settings
    static func openScreenRecordingSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Preview

#Preview {
    VStack(spacing: 16) {
        PermissionBanner(
            message: "Retrace needs Accessibility permission to detect which display you're working on.",
            actionTitle: "Open Settings",
            action: {
                print("Opening settings...")
            },
            onDismiss: {
                print("Dismissed")
            }
        )
        .padding()

        PermissionBanner(
            message: "Screen recording permission is required to capture your screen.",
            actionTitle: "Grant Permission",
            action: {
                print("Opening settings...")
            },
            onDismiss: {
                print("Dismissed")
            }
        )
        .padding()
    }
    .frame(width: 500)
}
