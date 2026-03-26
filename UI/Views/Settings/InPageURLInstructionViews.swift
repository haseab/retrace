import SwiftUI

struct InPageURLInstructionsDisclosure<Content: View>: View {
    let title: String
    @Binding var isExpanded: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                    isExpanded.toggle()
                }
            }) {
                HStack(spacing: 10) {
                    Text(title)
                        .font(.retraceCaption2Bold)
                        .foregroundColor(.retracePrimary)

                    Spacer()

                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.retraceSecondary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    content()
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(Color.white.opacity(0.04))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

struct InPageURLSecurityWarning: View {
    let showSafariSpecificLine: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundColor(.retraceWarning)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 4) {
                Text("Important security warning")
                    .font(.retraceCaption2Bold)
                    .foregroundColor(.retraceWarning)

                if showSafariSpecificLine {
                    Text("Safari may show a very severe warning when you enable this setting.")
                        .font(.retraceCaption2)
                        .foregroundColor(.retraceSecondary)
                }

                Text("After turning this on, be very careful which apps you grant Automation permission to. Granting it to untrusted apps can expose you to account takeover or data theft.")
                    .font(.retraceCaption2)
                    .foregroundColor(.retraceSecondary)

                Text("Retrace only uses this access to extract in-page browser URLs, mouse position, and video playback position.")
                    .font(.retraceCaption2)
                    .foregroundColor(.retraceSecondary)
            }
        }
    }
}
