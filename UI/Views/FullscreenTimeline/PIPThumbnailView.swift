import SwiftUI
import AVKit
import Shared

/// Picture-in-Picture thumbnail view for secondary displays in multi-display mode.
/// Shows a small video frame with state badges and pin/unpin action.
/// Tapping the thumbnail performs the same primary action as the center button.
struct PIPThumbnailView: View {
    let displayLabel: String
    let videoInfo: FrameVideoInfo?
    let isCurrentDisplay: Bool
    let isPinnedDisplay: Bool
    let onPrimaryAction: () -> Void
    @State private var forceReload = false
    @State private var isThumbnailHovering = false
    @State private var isPinButtonHovering = false

    var body: some View {
        ZStack {
            Button(action: triggerPrimaryAction) {
                ZStack(alignment: .bottomLeading) {
                    // Video frame content
                    if let videoInfo = videoInfo {
                        SimpleVideoFrameView(
                            videoInfo: videoInfo,
                            forceReload: $forceReload,
                            onLoadFailed: nil,
                            onLoadSuccess: nil
                        )
                        .aspectRatio(16/10, contentMode: .fill)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                    } else {
                        // No frame available — show placeholder
                        Rectangle()
                            .fill(Color.black.opacity(0.6))
                            .aspectRatio(16/10, contentMode: .fill)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .clipped()
                            .overlay(
                                Image(systemName: "display")
                                    .font(.title3)
                                    .foregroundColor(.white.opacity(0.3))
                            )
                    }

                    // Slightly darken thumbnail while hover actions are visible.
                    Rectangle()
                        .fill(Color.black.opacity(isThumbnailHovering ? 0.45 : 0))
                        .animation(.easeOut(duration: 0.16), value: isThumbnailHovering)

                    // Display label overlay
                    Text(displayLabel)
                        .font(.caption2)
                        .fontWeight(.medium)
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.black.opacity(0.6))
                        .cornerRadius(4)
                        .padding(6)
                }
            }
            .buttonStyle(.plain)
            .opacity(isCurrentDisplay ? 1.0 : 0.92)

            if isThumbnailHovering {
                DisplayPinActionButton(
                    label: primaryActionLabel,
                    systemImage: primaryActionIcon,
                    isHovering: isPinButtonHovering,
                    action: triggerPrimaryAction
                )
                .onHover { hovering in
                    isPinButtonHovering = hovering
                }
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(
                    isCurrentDisplay ? Color.white.opacity(0.75) : Color.white.opacity(0.2),
                    lineWidth: isCurrentDisplay ? 2.2 : 1
                )
        )
        .overlay {
            if isCurrentDisplay && !isThumbnailHovering {
                statusBadge("Current", systemImage: "eye.fill")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .topTrailing) {
            if isPinnedDisplay {
                statusBadge("Pinned", systemImage: "pin.fill")
                    .padding(6)
            }
        }
        .shadow(color: .black.opacity(isCurrentDisplay ? 0.5 : 0.4), radius: isCurrentDisplay ? 7 : 4, x: 0, y: 2)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.16)) {
                isThumbnailHovering = hovering
                if !hovering {
                    isPinButtonHovering = false
                }
            }
        }
        .contextMenu {
            Button("\(primaryActionLabel) (\(displayLabel))") {
                triggerPrimaryAction()
            }
        }
    }

    private var primaryActionLabel: String {
        isPinnedDisplay ? "Unpin" : "Pin"
    }

    private var primaryActionIcon: String {
        isPinnedDisplay ? "pin.slash.fill" : "pin.fill"
    }

    private func triggerPrimaryAction() {
        onPrimaryAction()
    }

    @ViewBuilder
    private func statusBadge(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(.white.opacity(0.95))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.black.opacity(0.55))
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(Color.white.opacity(0.25), lineWidth: 0.6)
            )
    }
}

/// Shared pin/unpin action button used by display thumbnails and current-display cards.
struct DisplayPinActionButton: View {
    let label: String
    let systemImage: String
    let isHovering: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 11)
                .background(
                    Capsule()
                        .fill(Color.black.opacity(isHovering ? 0.78 : 0.68))
                )
                .overlay(
                    Capsule()
                        .stroke(Color.white.opacity(0.22), lineWidth: 0.8)
                )
                .shadow(
                    color: .black.opacity(isHovering ? 0.42 : 0.25),
                    radius: isHovering ? 12 : 8,
                    x: 0,
                    y: isHovering ? 6 : 4
                )
                .scaleEffect(isHovering ? 1.05 : 1.0)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help(label)
    }
}
