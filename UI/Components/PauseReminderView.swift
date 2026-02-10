import SwiftUI

/// A floating notification view that appears in the top-right corner
/// when capturing has been paused for 5 minutes
/// Design matches Rewind AI's pause notification style
public struct PauseReminderView: View {

    // MARK: - Properties

    let onResumeCapturing: () -> Void
    let onRemindMeLater: () -> Void
    let onEditIntervalInSettings: () -> Void
    let onDismiss: () -> Void

    @State private var isHovering = false

    // MARK: - Body

    public var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            // Close button
            HStack {
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.retraceTinyMedium)
                        .foregroundColor(.white.opacity(0.6))
                        .frame(width: 20, height: 20)
                        .background(Color.white.opacity(isHovering ? 0.2 : 0.1))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    isHovering = hovering
                }
            }
            .padding(.trailing, 12)
            .padding(.top, 12)

            // Main content
            VStack(spacing: 16) {
                // Status text
                Text("Retrace is paused.")
                    .font(.retraceCalloutMedium)
                    .foregroundColor(.white)

                // Primary action button
                Button(action: onResumeCapturing) {
                    Text("Resume Capturing")
                        .font(.retraceCaptionBold)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.retraceAccent)
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)

                // Secondary action button
                Button(action: onRemindMeLater) {
                    Text("Remind Me Later")
                        .font(.retraceCaptionMedium)
                        .foregroundColor(.white.opacity(0.9))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.white.opacity(0.1))
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.white.opacity(0.2), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)

                // Settings shortcut link
                Button(action: onEditIntervalInSettings) {
                    Text("Edit interval in Settings")
                        .font(.retraceCaption2)
                        .foregroundColor(.white.opacity(0.65))
                        .underline()
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .frame(width: 220)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(red: 30/255, green: 30/255, blue: 35/255))
                .shadow(color: .black.opacity(0.4), radius: 16, x: 0, y: 8)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.1), lineWidth: 1)
        )
    }
}

// MARK: - Preview

#if DEBUG
struct PauseReminderView_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            Color.gray.opacity(0.3)
                .ignoresSafeArea()

            VStack {
                HStack {
                    Spacer()
                    PauseReminderView(
                        onResumeCapturing: { print("Resume") },
                        onRemindMeLater: { print("Remind me later") },
                        onEditIntervalInSettings: { print("Open settings") },
                        onDismiss: { print("Dismiss") }
                    )
                    .padding()
                }
                Spacer()
            }
        }
        .frame(width: 400, height: 300)
        .preferredColorScheme(.dark)
    }
}
#endif
