import SwiftUI
import AppKit

struct RetentionAppsChip<PopoverContent: View>: View {
    let selectedApps: Set<String>
    @Binding var isPopoverShown: Bool
    @ViewBuilder var popoverContent: () -> PopoverContent

    @State private var isHovered = false
    @State private var cachedAppIcons: [String: NSImage] = [:]
    @State private var cachedAppNames: [String: String] = [:]
    @State private var cachedAppPaths: [String: String] = [:]

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
        if let icon = cachedAppIcons[bundleID] {
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
        if let cachedName = cachedAppNames[bundleID] {
            return cachedName
        }
        return bundleID.components(separatedBy: ".").last ?? bundleID
    }

    @MainActor
    private func preloadAppPresentation(for bundleIDs: [String]) async {
        let validBundleIDs = Set(bundleIDs)
        cachedAppIcons = cachedAppIcons.filter { validBundleIDs.contains($0.key) }
        cachedAppNames = cachedAppNames.filter { validBundleIDs.contains($0.key) }
        cachedAppPaths = cachedAppPaths.filter { validBundleIDs.contains($0.key) }

        let iconBundleIDs = iconBundleIDsForCurrentPresentation(from: bundleIDs)
        let nameBundleIDs = bundleIDs.count == 1 ? bundleIDs : []
        let requiredBundleIDs = Set(iconBundleIDs + nameBundleIDs)
        guard !requiredBundleIDs.isEmpty else { return }

        let missingBundleIDs = requiredBundleIDs.filter {
            cachedAppPaths[$0] == nil || (nameBundleIDs.contains($0) && cachedAppNames[$0] == nil)
        }
        if !missingBundleIDs.isEmpty {
            let resolved = await Task.detached(priority: .utility) {
                Self.discoverInstalledAppsByBundleID(bundleIDs: Array(missingBundleIDs))
            }.value

            for (bundleID, app) in resolved {
                if cachedAppPaths[bundleID] == nil {
                    cachedAppPaths[bundleID] = app.appPath
                }
                if cachedAppNames[bundleID] == nil, !app.displayName.isEmpty {
                    cachedAppNames[bundleID] = app.displayName
                }
            }
        }

        for (index, bundleID) in iconBundleIDs.enumerated() {
            guard cachedAppIcons[bundleID] == nil,
                  let appPath = cachedAppPaths[bundleID] else {
                continue
            }

            let icon = NSWorkspace.shared.icon(forFile: appPath)
            icon.size = NSSize(width: iconSize, height: iconSize)
            cachedAppIcons[bundleID] = icon

            if (index + 1).isMultiple(of: 3) {
                await Task.yield()
            }
        }
    }

    private func iconBundleIDsForCurrentPresentation(from bundleIDs: [String]) -> [String] {
        if bundleIDs.count <= 1 {
            return bundleIDs
        }
        return Array(bundleIDs.prefix(maxVisibleIcons))
    }

    private struct InstalledAppPresentation {
        let displayName: String
        let appPath: String
    }

    nonisolated private static func discoverInstalledAppsByBundleID(
        bundleIDs: [String],
        fileManager: FileManager = .default
    ) -> [String: InstalledAppPresentation] {
        let requiredBundleIDs = Set(bundleIDs.filter { !$0.isEmpty })
        guard !requiredBundleIDs.isEmpty else { return [:] }

        let applicationFolders: [URL] = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            URL(fileURLWithPath: "/Applications/Chrome Apps.localized", isDirectory: true),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Chrome Apps.localized", isDirectory: true),
        ]

        var remainingBundleIDs = requiredBundleIDs
        var resolvedApps: [String: InstalledAppPresentation] = [:]

        for folder in applicationFolders {
            guard !remainingBundleIDs.isEmpty else { break }
            guard let entries = try? fileManager.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for appURL in entries where appURL.pathExtension.lowercased() == "app" {
                guard let bundle = Bundle(url: appURL),
                      let bundleID = bundle.bundleIdentifier,
                      remainingBundleIDs.contains(bundleID) else {
                    continue
                }

                let displayName =
                    (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String) ??
                    (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String) ??
                    appURL.deletingPathExtension().lastPathComponent

                resolvedApps[bundleID] = InstalledAppPresentation(
                    displayName: displayName,
                    appPath: appURL.path
                )
                remainingBundleIDs.remove(bundleID)
            }
        }

        return resolvedApps
    }
}
