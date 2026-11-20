import SwiftUI
import AppKit

struct RetentionAppsChip<PopoverContent: View>: View {
    let selectedApps: Set<String>
    @Binding var isPopoverShown: Bool
    @ViewBuilder var popoverContent: () -> PopoverContent

    @StateObject private var metadata = AppMetadataCache.shared
    @State private var isHovered = false

    private let maxVisibleIcons = 5
    private let iconSize: CGFloat = 18

    private var sortedApps: [String] {
        selectedApps.sorted()
    }

    private var isActive: Bool {
        !selectedApps.isEmpty
    }

    var body: some View {
        Button(action: {
            isPopoverShown.toggle()
        }) {
            HStack(spacing: 6) {
                if sortedApps.count == 1 {
                    let bundleID = sortedApps[0]
                    appIcon(for: bundleID)
                        .frame(width: iconSize, height: iconSize)
                        .clipShape(RoundedRectangle(cornerRadius: 3))

                    Text(appName(for: bundleID))
                        .font(.retraceCaptionMedium)
                        .lineLimit(1)
                } else if sortedApps.count > 1 {
                    HStack(spacing: -4) {
                        ForEach(Array(sortedApps.prefix(maxVisibleIcons)), id: \.self) { bundleID in
                            appIcon(for: bundleID)
                                .frame(width: iconSize, height: iconSize)
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                        }
                    }

                    if sortedApps.count > maxVisibleIcons {
                        Text("+\(sortedApps.count - maxVisibleIcons)")
                            .font(.retraceTinyBold)
                            .foregroundColor(.white.opacity(0.8))
                    }
                } else {
                    Image(systemName: "app.fill")
                        .font(.system(size: 12))
                    Text("None")
                        .font(.retraceCaptionMedium)
                }

                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .rotationEffect(.degrees(isPopoverShown ? 180 : 0))
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: sortedApps)
            .foregroundColor(isActive ? .white : .retraceSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isActive ? Color.retraceAccent.opacity(0.2) : Color.white.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(isActive ? Color.retraceAccent.opacity(0.4) : Color.white.opacity(0.1), lineWidth: 1)
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .task(id: sortedApps.joined(separator: "|")) {
            await preloadAppPresentation(for: sortedApps)
        }
        .popover(isPresented: $isPopoverShown, arrowEdge: .bottom) {
            popoverContent()
        }
    }

    @ViewBuilder
    private func appIcon(for bundleID: String) -> some View {
        if let icon = metadata.icon(for: bundleID) {
            Image(nsImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: "app.fill")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .foregroundColor(.white.opacity(0.6))
        }
    }

    private func appName(for bundleID: String) -> String {
        if let cachedName = metadata.name(for: bundleID) { return cachedName }
        return bundleID.components(separatedBy: ".").last ?? bundleID
    }

    @MainActor
    private func preloadAppPresentation(for bundleIDs: [String]) async {
        let iconBundleIDs = bundleIDs.count <= 1 ? bundleIDs : Array(bundleIDs.prefix(maxVisibleIcons))
        metadata.prefetch(bundleIDs: Array(Set(iconBundleIDs + (bundleIDs.count == 1 ? bundleIDs : []))))
    }
}
