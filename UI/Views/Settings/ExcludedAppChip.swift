import SwiftUI
import AppKit

struct ExcludedAppChip: View {
    let app: ExcludedAppInfo
    let onRemove: () -> Void

    @StateObject private var metadata = AppMetadataCache.shared
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            if let icon = resolvedIcon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 20, height: 20)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            } else {
                Image(systemName: "app.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.retraceSecondary)
                    .frame(width: 20, height: 20)
            }

            Text(app.name)
                .font(.retraceCaptionMedium)
                .foregroundColor(.retracePrimary)
                .lineLimit(1)

            Spacer(minLength: 0)

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.retraceSecondary)
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .opacity(isHovered ? 1 : 0)
            .allowsHitTesting(isHovered)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(isHovered ? 0.09 : 0.055))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.white.opacity(isHovered ? 0.14 : 0.07), lineWidth: 1)
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .task(id: "\(app.bundleID)|\(app.iconPath ?? "")") {
            if let iconPath = app.iconPath {
                metadata.requestIcon(forAppPath: iconPath)
            }
            metadata.requestMetadata(for: app.bundleID)
        }
    }

    private var resolvedIcon: NSImage? {
        if let iconPath = app.iconPath,
           let icon = metadata.icon(forAppPath: iconPath) {
            return icon
        }
        return metadata.icon(for: app.bundleID)
    }
}

struct ExcludedAppsAddButton: View {
    let isOpen: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.retraceSecondary.opacity(0.9))

                Text("Add App...")
                    .font(.retraceCaptionMedium)
                    .foregroundColor(.retraceSecondary.opacity(0.9))
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.white.opacity((isHovered || isOpen) ? 0.09 : 0.045))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(
                        isOpen ? RetraceMenuStyle.filterStrokeStrong : Color.white.opacity((isHovered || isOpen) ? 0.22 : 0.1),
                        lineWidth: isOpen ? 1.2 : 1
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}
