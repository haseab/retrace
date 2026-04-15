import App
import AppKit
import Shared
import SwiftUI

// MARK: - Filter Chip Button

struct FilterChip: View {
    let icon: String
    let label: String
    let isActive: Bool
    let isOpen: Bool
    let showChevron: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4.5) {
                Image(systemName: icon)
                    .font(.system(size: 11))

                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)

                if showChevron {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                }
            }
            .foregroundColor(isActive ? .white : .white.opacity(0.7))
            .padding(.horizontal, 10.5)
            .padding(.vertical, 7.5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isActive ? Color.white.opacity(0.2) : Color.white.opacity((isHovered || isOpen) ? 0.15 : 0.1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(
                        isOpen
                            ? RetraceMenuStyle.filterStrokeStrong
                            : (isActive
                                ? RetraceMenuStyle.filterStrokeMedium
                                : (isHovered ? Color.white.opacity(0.65) : Color.clear)),
                        lineWidth: (isOpen || isHovered) ? 1.2 : 1
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.1)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Apps Filter Chip

struct AppsFilterChip: View {
    let selectedApps: Set<String>?
    let filterMode: AppFilterMode
    let isActive: Bool
    let isOpen: Bool
    let action: () -> Void

    @StateObject private var appMetadata = AppMetadataCache.shared
    @State private var isHovered = false

    private let maxVisibleIcons = 5
    private let iconSize: CGFloat = 13

    private var sortedApps: [String] {
        guard let apps = selectedApps else { return [] }
        return apps.sorted()
    }

    private var isExcludeMode: Bool {
        filterMode == .exclude && isActive
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4.5) {
                if isExcludeMode {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 9))
                        .frame(width: iconSize, height: iconSize)
                        .foregroundColor(.orange)
                        .transition(.scale.combined(with: .opacity))
                }

                if sortedApps.count == 1 {
                    let bundleID = sortedApps[0]
                    appIcon(for: bundleID)
                        .frame(width: iconSize, height: iconSize)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                        .transition(.scale.combined(with: .opacity))

                    Text(appName(for: bundleID))
                        .font(.system(size: 10.5, weight: .medium))
                        .lineLimit(1)
                        .strikethrough(isExcludeMode, color: .orange)
                        .transition(.opacity)
                } else if sortedApps.count > 1 {
                    HStack(spacing: -3) {
                        ForEach(Array(sortedApps.prefix(maxVisibleIcons)), id: \.self) { bundleID in
                            appIcon(for: bundleID)
                                .frame(width: iconSize, height: iconSize)
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                                .opacity(isExcludeMode ? 0.6 : 1.0)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }

                    if sortedApps.count > maxVisibleIcons {
                        Text("+\(sortedApps.count - maxVisibleIcons)")
                            .font(.retraceTinyBold)
                            .foregroundColor(.white.opacity(0.8))
                            .transition(.scale.combined(with: .opacity))
                    }
                } else {
                    Image(systemName: "square.grid.2x2.fill")
                        .font(.system(size: 11))
                        .frame(width: iconSize, height: iconSize)
                        .transition(.scale.combined(with: .opacity))
                    Text("Apps")
                        .font(.system(size: 11, weight: .medium))
                        .transition(.opacity)
                }

                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .frame(height: iconSize)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: sortedApps)
            .foregroundColor(isActive ? .white : .white.opacity(0.7))
            .padding(.horizontal, 10.5)
            .padding(.vertical, 7.5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isActive ? Color.white.opacity(0.2) : Color.white.opacity((isHovered || isOpen) ? 0.15 : 0.1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(
                        isOpen
                            ? RetraceMenuStyle.filterStrokeStrong
                            : (isActive
                                ? RetraceMenuStyle.filterStrokeMedium
                                : (isHovered ? Color.white.opacity(0.65) : Color.clear)),
                        lineWidth: (isOpen || isHovered) ? 1.2 : 1
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.1)) {
                isHovered = hovering
            }
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

// MARK: - Search Order Dropdown

enum SearchOrderOption: CaseIterable {
    case relevance
    case newest
    case oldest

    var icon: String {
        switch self {
        case .relevance: return "arrow.up.arrow.down"
        case .newest: return "arrow.down"
        case .oldest: return "arrow.up"
        }
    }

    var title: String {
        switch self {
        case .relevance: return "Relevance"
        case .newest: return "Newest"
        case .oldest: return "Oldest"
        }
    }

    var subtitle: String {
        switch self {
        case .relevance: return "Best semantic match"
        case .newest: return "Most recent results first"
        case .oldest: return "Oldest results first"
        }
    }

    static func from(mode: SearchMode, sortOrder: SearchSortOrder) -> SearchOrderOption {
        if mode == .relevant {
            return .relevance
        }
        return sortOrder == .oldestFirst ? .oldest : .newest
    }
}

struct TagsFilterChip: View {
    let selectedTags: Set<Int64>?
    let availableTags: [Tag]
    let filterMode: TagFilterMode
    let isActive: Bool
    let isOpen: Bool
    let action: () -> Void

    @State private var isHovered = false

    private var selectedTagCount: Int {
        selectedTags?.count ?? 0
    }

    private var isExcludeMode: Bool {
        filterMode == .exclude && isActive
    }

    private var label: String {
        if selectedTagCount == 0 {
            return "Tags"
        } else if selectedTagCount == 1,
                  let tagId = selectedTags?.first,
                  let tag = availableTags.first(where: { $0.id.value == tagId }) {
            return tag.name
        } else {
            return "\(selectedTagCount) Tags"
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4.5) {
                if isExcludeMode {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 9))
                        .foregroundColor(.orange)
                        .transition(.scale.combined(with: .opacity))
                }

                Image(systemName: isActive ? "tag.fill" : "tag")
                    .font(.system(size: 11))

                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .strikethrough(isExcludeMode, color: .orange)

                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundColor(isActive ? .white : .white.opacity(0.7))
            .padding(.horizontal, 10.5)
            .padding(.vertical, 7.5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isActive ? Color.white.opacity(0.2) : Color.white.opacity((isHovered || isOpen) ? 0.15 : 0.1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(
                        isOpen
                            ? RetraceMenuStyle.filterStrokeStrong
                            : (isActive
                                ? RetraceMenuStyle.filterStrokeMedium
                                : (isHovered ? Color.white.opacity(0.65) : Color.clear)),
                        lineWidth: (isOpen || isHovered) ? 1.2 : 1
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.1)) {
                isHovered = hovering
            }
        }
    }
}

struct VisibilityFilterChip: View {
    let currentFilter: HiddenFilter
    let isActive: Bool
    let isOpen: Bool
    let action: () -> Void

    @State private var isHovered = false

    private var icon: String {
        switch currentFilter {
        case .hide: return "eye"
        case .onlyHidden: return "eye.slash"
        case .showAll: return "eye.circle"
        }
    }

    private var label: String {
        switch currentFilter {
        case .hide: return "Visible"
        case .onlyHidden: return "Hidden"
        case .showAll: return "All"
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4.5) {
                Image(systemName: icon)
                    .font(.system(size: 11))

                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)

                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundColor(isActive ? .white : .white.opacity(0.7))
            .padding(.horizontal, 10.5)
            .padding(.vertical, 7.5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isActive ? Color.white.opacity(0.2) : Color.white.opacity((isHovered || isOpen) ? 0.15 : 0.1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(
                        isOpen
                            ? RetraceMenuStyle.filterStrokeStrong
                            : (isActive
                                ? RetraceMenuStyle.filterStrokeMedium
                                : (isHovered ? Color.white.opacity(0.65) : Color.clear)),
                        lineWidth: (isOpen || isHovered) ? 1.2 : 1
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.1)) {
                isHovered = hovering
            }
        }
    }
}

struct CommentFilterChip: View {
    let currentFilter: CommentFilter
    let isActive: Bool
    let isOpen: Bool
    let action: () -> Void

    @State private var isHovered = false

    private var icon: String {
        switch currentFilter {
        case .allFrames: return "text.bubble"
        case .commentsOnly: return "text.bubble.fill"
        case .noComments: return "text.bubble.slash"
        }
    }

    private var label: String {
        switch currentFilter {
        case .allFrames: return "All"
        case .commentsOnly: return "Comments"
        case .noComments: return "No Comments"
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4.5) {
                Image(systemName: icon)
                    .font(.system(size: 11))

                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)

                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundColor(isActive ? .white : .white.opacity(0.7))
            .padding(.horizontal, 10.5)
            .padding(.vertical, 7.5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isActive ? Color.white.opacity(0.2) : Color.white.opacity((isHovered || isOpen) ? 0.15 : 0.1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(
                        isOpen
                            ? RetraceMenuStyle.filterStrokeStrong
                            : (isActive
                                ? RetraceMenuStyle.filterStrokeMedium
                                : (isHovered ? Color.white.opacity(0.65) : Color.clear)),
                        lineWidth: (isOpen || isHovered) ? 1.2 : 1
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.1)) {
                isHovered = hovering
            }
        }
    }
}

struct SearchOrderChip: View {
    let selection: SearchOrderOption
    let isOpen: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        let isHighlighted = isHovered || isOpen

        Button(action: action) {
            HStack(spacing: 4.5) {
                Image(systemName: selection.icon)
                    .font(.system(size: 11))

                Text(selection.title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)

                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 10.5)
            .padding(.vertical, 7.5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.white.opacity(isHighlighted ? 0.22 : 0.2))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(
                        isOpen
                            ? RetraceMenuStyle.filterStrokeStrong
                            : (isHovered ? Color.white.opacity(0.65) : RetraceMenuStyle.filterStrokeMedium),
                        lineWidth: 1.2
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.1)) {
                isHovered = hovering
            }
        }
    }
}

struct SearchOrderPopover: View {
    let selection: SearchOrderOption
    let onSelect: (SearchOrderOption) -> Void
    var onDismiss: (() -> Void)?

    @FocusState private var isFocused: Bool
    @State private var highlightedIndex: Int = 0

    private let options: [SearchOrderOption] = [.newest, .oldest, .relevance]

    private func selectHighlightedItem() {
        guard highlightedIndex >= 0, highlightedIndex < options.count else { return }
        onSelect(options[highlightedIndex])
        onDismiss?()
    }

    private func moveHighlight(by offset: Int) {
        highlightedIndex = max(0, min(options.count - 1, highlightedIndex + offset))
    }

    var body: some View {
        FilterPopoverContainer(width: 200) {
            VStack(spacing: 0) {
                ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                    if index > 0 {
                        Divider()
                            .padding(.vertical, 4)
                    }

                    FilterRow(
                        systemIcon: option.icon,
                        title: option.title,
                        subtitle: option.subtitle,
                        isSelected: selection == option,
                        isKeyboardHighlighted: highlightedIndex == index
                    ) {
                        onSelect(option)
                        onDismiss?()
                    }
                    .id(index)
                }
            }
            .padding(.vertical, 8)
        }
        .focused($isFocused)
        .onAppear {
            highlightedIndex = options.firstIndex(of: selection) ?? 0
            isFocused = true
        }
        .keyboardNavigation(
            onUpArrow: { moveHighlight(by: -1) },
            onDownArrow: { moveHighlight(by: 1) },
            onReturn: { selectHighlightedItem() }
        )
    }
}
