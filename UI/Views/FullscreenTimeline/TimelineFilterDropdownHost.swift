import AppKit
import CoreGraphics
import Foundation
import Shared
import SwiftUI

// MARK: - Compact Filter Components

/// Compact filter dropdown for two-column layout
struct CompactFilterDropdown: View {
    let label: String
    let value: String
    let icon: String
    let isActive: Bool
    let isOpen: Bool
    let onTap: (CGRect) -> Void
    var onFrameAvailable: ((CGRect) -> Void)? = nil

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white.opacity(0.4))
                .tracking(0.5)

            GeometryReader { geo in
                let localFrame = geo.frame(in: .named("timelineContent"))
                Button(action: { onTap(localFrame) }) {
                    HStack(spacing: 7) {
                        Image(systemName: icon)
                            .font(.system(size: 11))
                            .foregroundColor(isActive ? .white : .white.opacity(0.5))

                        Text(value)
                            .font(.system(size: 12))
                            .foregroundColor(isActive ? .white : .white.opacity(0.9))
                            .lineLimit(1)

                        Spacer(minLength: 2)

                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(.white.opacity(0.4))
                    }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(isActive ? Color.white.opacity(0.15) : ((isHovered || isOpen) ? Color.white.opacity(0.12) : Color.white.opacity(0.08)))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(
                                (isHovered || isOpen)
                                    ? RetraceMenuStyle.filterStrokeStrong
                                    : (isActive ? RetraceMenuStyle.filterStrokeMedium : RetraceMenuStyle.filterStrokeSubtle),
                                lineWidth: (isHovered || isOpen) ? 1.2 : 1
                            )
                    )
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    withAnimation(.easeInOut(duration: 0.1)) {
                        isHovered = hovering
                    }
                }
                .onAppear {
                    // Delay slightly to ensure geometry is calculated
                    DispatchQueue.main.async {
                        onFrameAvailable?(localFrame)
                    }
                }
            }
            .frame(height: 38)
        }
    }
}

/// Compact apps filter dropdown with app icons (matches search dialog behavior)
struct CompactAppsFilterDropdown: View {
    let label: String
    let selectedApps: Set<String>?
    let isExcludeMode: Bool
    let isOpen: Bool
    let onTap: (CGRect) -> Void
    var onFrameAvailable: ((CGRect) -> Void)? = nil

    @StateObject private var appMetadata = AppMetadataCache.shared
    @State private var isHovered = false

    private let maxVisibleIcons = 5
    private let iconSize: CGFloat = 13

    private var sortedApps: [String] {
        guard let apps = selectedApps else { return [] }
        return apps.sorted()
    }

    private var isActive: Bool {
        selectedApps != nil && !selectedApps!.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white.opacity(0.4))
                .tracking(0.5)

            GeometryReader { geo in
                let localFrame = geo.frame(in: .named("timelineContent"))
                Button(action: { onTap(localFrame) }) {
                    HStack(spacing: 7) {
                        // Show exclude indicator
                        if isExcludeMode && isActive {
                            Image(systemName: "minus.circle.fill")
                                .font(.system(size: 10))
                                .frame(width: iconSize, height: iconSize)
                                .foregroundColor(.orange)
                        }

                        if sortedApps.count == 1 {
                            // Single app: show icon + name
                            let bundleID = sortedApps[0]
                            appIcon(for: bundleID)
                                .frame(width: iconSize, height: iconSize)
                                .clipShape(RoundedRectangle(cornerRadius: 3))

                            Text(appName(for: bundleID))
                                .font(.system(size: 12))
                                .foregroundColor(.white)
                                .lineLimit(1)
                                .strikethrough(isExcludeMode, color: .orange)
                        } else if sortedApps.count > 1 {
                            // Multiple apps: show icons stacked
                            HStack(spacing: -4) {
                                ForEach(Array(sortedApps.prefix(maxVisibleIcons)), id: \.self) { bundleID in
                                    appIcon(for: bundleID)
                                        .frame(width: iconSize, height: iconSize)
                                        .clipShape(RoundedRectangle(cornerRadius: 3))
                                        .opacity(isExcludeMode ? 0.6 : 1.0)
                                }
                            }

                            // Show "+X" if more than maxVisibleIcons
                            if sortedApps.count > maxVisibleIcons {
                                Text("+\(sortedApps.count - maxVisibleIcons)")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(.white.opacity(0.8))
                            }
                        } else {
                            // Default state - no apps selected
                            Image(systemName: "square.grid.2x2")
                                .font(.system(size: 11))
                                .frame(width: iconSize, height: iconSize)
                                .foregroundColor(.white.opacity(0.5))

                            Text("All Apps")
                                .font(.system(size: 12))
                                .foregroundColor(.white.opacity(0.9))
                        }

                        Spacer(minLength: 2)

                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(.white.opacity(0.4))
                    }
                    .frame(height: iconSize)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(isActive ? Color.white.opacity(0.15) : ((isHovered || isOpen) ? Color.white.opacity(0.12) : Color.white.opacity(0.08)))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(
                                (isHovered || isOpen)
                                    ? RetraceMenuStyle.filterStrokeStrong
                                    : (isActive ? RetraceMenuStyle.filterStrokeMedium : RetraceMenuStyle.filterStrokeSubtle),
                                lineWidth: (isHovered || isOpen) ? 1.2 : 1
                            )
                    )
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    withAnimation(.easeInOut(duration: 0.1)) {
                        isHovered = hovering
                    }
                }
                .onAppear {
                    // Delay slightly to ensure geometry is calculated
                    DispatchQueue.main.async {
                        onFrameAvailable?(localFrame)
                    }
                }
            }
            .frame(height: 38)
        }
        .onAppear {
            appMetadata.prefetch(bundleIDs: sortedApps)
        }
        .onChange(of: sortedApps) { bundleIDs in
            appMetadata.prefetch(bundleIDs: bundleIDs)
        }
    }

    private func appIcon(for bundleID: String) -> some View {
        AppIconView(bundleID: bundleID, size: iconSize)
    }

    private func appName(for bundleID: String) -> String {
        appMetadata.name(for: bundleID) ?? fallbackName(for: bundleID)
    }

    private func fallbackName(for bundleID: String) -> String {
        bundleID.components(separatedBy: ".").last ?? bundleID
    }
}

/// Compact toggle chip for source filters
struct FilterToggleChipCompact: View {
    let label: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                Text(label)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(isSelected ? .white : .white.opacity(0.5))
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.white.opacity(0.15) : Color.white.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(
                        isHovered
                            ? RetraceMenuStyle.filterStrokeStrong
                            : (isSelected ? RetraceMenuStyle.filterStrokeMedium : RetraceMenuStyle.filterStrokeSubtle),
                        lineWidth: isHovered ? 1.2 : 1
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

// MARK: - Filter Toggle Chip

/// Toggle chip for source filters (Retrace/Rewind)
/// Styled similar to Relevant/All tabs in search dialog - white accent instead of blue
struct FilterToggleChip: View {
    let label: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12))

                Text(label)
                    .font(.system(size: 13, weight: isSelected ? .bold : .medium))
            }
            .foregroundColor(isSelected ? .white : .white.opacity(0.6))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? Color.white.opacity(0.2) : (isHovered ? Color.white.opacity(0.1) : Color.clear))
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovered = hovering
            }
            if hovering { NSCursor.pointingHand.push() }
            else { NSCursor.pop() }
        }
    }
}

// MARK: - Filter Dropdown Button

/// Dropdown button for Apps/Tags selection
struct FilterDropdownButton: View {
    let label: String
    let icon: String
    let isActive: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: icon)
                        .font(.system(size: 13))
                        .foregroundColor(isActive ? .white : .white.opacity(0.5))

                    Text(label)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(isActive ? .white : .white.opacity(0.7))
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.3))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isActive ? RetraceMenuStyle.actionBlue.opacity(0.15) : Color.white.opacity(isHovered ? 0.1 : 0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isActive ? RetraceMenuStyle.actionBlue.opacity(0.3) : Color.white.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovered = hovering
            }
            if hovering { NSCursor.pointingHand.push() }
            else { NSCursor.pop() }
        }
    }
}
