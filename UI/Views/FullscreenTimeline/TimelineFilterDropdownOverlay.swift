import AppKit
import CoreGraphics
import Foundation
import Shared
import SwiftUI

// MARK: - Filter Dropdown Overlay

/// Renders filter dropdowns at the top level of SimpleTimelineView to avoid clipping issues.
private struct FilterDropdownSizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero

    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

struct FilterDropdownOverlay: View {
    @ObservedObject var viewModel: SimpleTimelineViewModel
    @State private var measuredDropdownSize: CGSize = .zero

    var body: some View {
        GeometryReader { proxy in
            Group {
                if viewModel.activeFilterDropdown != .none && viewModel.activeFilterDropdown != .advanced {
                    let anchor = viewModel.filterDropdownAnchorFrame
                    let fallbackSize = TimelineFilterDropdownOverlaySupport.estimatedDropdownSize(
                        for: viewModel.activeFilterDropdown,
                        isDateRangeCalendarEditing: viewModel.isDateRangeCalendarEditing
                    )
                    let dropdownSize = TimelineFilterDropdownOverlaySupport.resolvedDropdownSize(
                        measuredSize: measuredDropdownSize,
                        fallbackSize: fallbackSize
                    )
                    let origin = TimelineFilterDropdownOverlaySupport.dropdownOrigin(
                        containerSize: proxy.size,
                        anchor: anchor,
                        dropdownSize: dropdownSize,
                        activeDropdown: viewModel.activeFilterDropdown,
                        isDateRangeCalendarEditing: viewModel.isDateRangeCalendarEditing
                    )

                    ZStack(alignment: .topLeading) {
                        Color.black.opacity(0.001)
                            .ignoresSafeArea()
                            .contentShape(Rectangle())
                            .onTapGesture {
                                dismissDropdown()
                            }

                        TimelineFilterDropdownPopoverHost(
                            viewModel: viewModel,
                            environment: makeExecutionEnvironment()
                        )
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color(white: 0.12))
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .shadow(color: .black.opacity(0.5), radius: 15, y: 8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color.white.opacity(0.15), lineWidth: 1)
                        )
                        .fixedSize()
                        .background(
                            GeometryReader { geo in
                                Color.clear
                                    .preference(key: FilterDropdownSizePreferenceKey.self, value: geo.size)
                            }
                        )
                        .offset(x: origin.x, y: origin.y)
                    }
                    .onPreferenceChange(FilterDropdownSizePreferenceKey.self) { size in
                        guard size.width > 0, size.height > 0 else { return }
                        let normalizedSize = TimelineFilterDropdownOverlaySupport.normalizedMeasuredSize(size)
                        guard TimelineFilterDropdownOverlaySupport.shouldUpdateMeasuredSize(
                            currentSize: measuredDropdownSize,
                            newSize: normalizedSize
                        ) else { return }
                        measuredDropdownSize = normalizedSize
                    }
                    .transition(.opacity)
                    .zIndex(2000)
                }
            }
        }
        .animation(.easeOut(duration: 0.15), value: viewModel.activeFilterDropdown)
        .animation(.easeOut(duration: 0.15), value: viewModel.isDateRangeCalendarEditing)
        .onChange(of: viewModel.activeFilterDropdown) { _ in
            if measuredDropdownSize != .zero {
                measuredDropdownSize = .zero
            }
        }
        .onChange(of: viewModel.isDateRangeCalendarEditing) { _ in
            if viewModel.activeFilterDropdown == .dateRange, measuredDropdownSize != .zero {
                measuredDropdownSize = .zero
            }
        }
    }

    private func dismissDropdown() {
        withAnimation(.easeOut(duration: 0.15)) {
            viewModel.dismissFilterDropdown()
        }
    }

    private func anchorFrame(for dropdown: SimpleTimelineViewModel.FilterDropdownType) -> CGRect {
        viewModel.filterAnchorFrames[dropdown] ?? .zero
    }

    private func makeExecutionEnvironment() -> TimelineFilterDropdownExecutionEnvironment {
        TimelineFilterDropdownExecutionEnvironment(
            toggleApp: { bundleID in
                viewModel.toggleAppFilter(bundleID)
            },
            clearPendingAppSelection: {
                viewModel.clearPendingAppSelection()
            },
            setAppFilterMode: { mode in
                viewModel.setAppFilterMode(mode)
            },
            toggleTag: { tagID in
                viewModel.toggleTagFilter(tagID)
            },
            clearPendingTagSelection: {
                viewModel.clearPendingTagSelection()
            },
            setTagFilterMode: { mode in
                viewModel.setTagFilterMode(mode)
            },
            setHiddenFilter: { filter in
                viewModel.setHiddenFilter(filter)
            },
            setCommentFilter: { filter in
                viewModel.setCommentFilter(filter)
            },
            setDateRanges: { ranges in
                viewModel.setDateRanges(ranges)
            },
            setDateRangeCalendarEditingState: { isEditing in
                viewModel.setDateRangeCalendarEditingState(isEditing)
            },
            recordKeyboardShortcut: { shortcut in
                viewModel.recordKeyboardShortcut(shortcut)
            },
            dismissDropdown: {
                dismissDropdown()
            },
            showDropdown: { dropdown, anchorFrame in
                withAnimation(.easeOut(duration: 0.15)) {
                    viewModel.showFilterDropdown(dropdown, anchorFrame: anchorFrame)
                }
            },
            anchorFrameProvider: { dropdown in
                anchorFrame(for: dropdown)
            }
        )
    }
}

struct TimelineFilterDropdownExecutionEnvironment {
    let toggleApp: (String) -> Void
    let clearPendingAppSelection: () -> Void
    let setAppFilterMode: (AppFilterMode) -> Void
    let toggleTag: (TagID) -> Void
    let clearPendingTagSelection: () -> Void
    let setTagFilterMode: (TagFilterMode) -> Void
    let setHiddenFilter: (HiddenFilter) -> Void
    let setCommentFilter: (CommentFilter) -> Void
    let setDateRanges: ([DateRangeCriterion]) -> Void
    let setDateRangeCalendarEditingState: (Bool) -> Void
    let recordKeyboardShortcut: (String) -> Void
    let dismissDropdown: () -> Void
    let showDropdown: (SimpleTimelineViewModel.FilterDropdownType, CGRect) -> Void
    let anchorFrameProvider: (SimpleTimelineViewModel.FilterDropdownType) -> CGRect
}

enum TimelineFilterDropdownExecutionSupport {
    static func executeAppSelection(
        _ bundleID: String?,
        environment: TimelineFilterDropdownExecutionEnvironment
    ) {
        if let bundleID {
            environment.toggleApp(bundleID)
        } else {
            environment.clearPendingAppSelection()
        }
    }

    static func executeTagSelection(
        _ tagID: TagID?,
        environment: TimelineFilterDropdownExecutionEnvironment
    ) {
        if let tagID {
            environment.toggleTag(tagID)
        } else {
            environment.clearPendingTagSelection()
        }
    }

    static func executeAdvanceNavigation(
        from activeDropdown: SimpleTimelineViewModel.FilterDropdownType,
        environment: TimelineFilterDropdownExecutionEnvironment
    ) {
        execute(
            TimelineFilterDropdownOverlaySupport.makeAdvanceNavigationAction(
                from: activeDropdown,
                anchorFrameProvider: environment.anchorFrameProvider
            ),
            environment: environment
        )
    }

    static func execute(
        _ action: TimelineFilterDropdownOverlayNavigationAction?,
        environment: TimelineFilterDropdownExecutionEnvironment
    ) {
        guard let action else { return }

        switch action {
        case let .showDropdown(dropdown, anchorFrame):
            environment.showDropdown(dropdown, anchorFrame)
        }
    }
}

enum TimelineFilterDropdownOverlayNavigationAction: Equatable {
    case showDropdown(SimpleTimelineViewModel.FilterDropdownType, anchorFrame: CGRect)
}

enum TimelineFilterDropdownOverlaySupport {
    static func normalizedMeasuredSize(_ size: CGSize) -> CGSize {
        let width = (size.width * 2).rounded() / 2
        let height = (size.height * 2).rounded() / 2
        return CGSize(width: width, height: height)
    }

    static func shouldUpdateMeasuredSize(
        currentSize: CGSize,
        newSize: CGSize,
        epsilon: CGFloat = 0.5
    ) -> Bool {
        abs(currentSize.width - newSize.width) > epsilon ||
            abs(currentSize.height - newSize.height) > epsilon ||
            currentSize == .zero
    }

    static func resolvedDropdownSize(
        measuredSize: CGSize,
        fallbackSize: CGSize
    ) -> CGSize {
        if measuredSize.width > 0, measuredSize.height > 0 {
            return measuredSize
        }

        return fallbackSize
    }

    static func estimatedDropdownSize(
        for type: SimpleTimelineViewModel.FilterDropdownType,
        isDateRangeCalendarEditing: Bool
    ) -> CGSize {
        switch type {
        case .apps:
            return CGSize(width: 220, height: 320)
        case .tags:
            return CGSize(width: 220, height: 320)
        case .visibility:
            return CGSize(width: 240, height: 180)
        case .comments:
            return CGSize(width: 240, height: 160)
        case .dateRange:
            let height: CGFloat = isDateRangeCalendarEditing ? 430 : 250
            return CGSize(width: 300, height: height)
        case .advanced, .none:
            return CGSize(width: 260, height: 200)
        }
    }

    static func dropdownOrigin(
        containerSize: CGSize,
        anchor: CGRect,
        dropdownSize: CGSize,
        activeDropdown: SimpleTimelineViewModel.FilterDropdownType,
        isDateRangeCalendarEditing: Bool
    ) -> CGPoint {
        if activeDropdown == .dateRange, isDateRangeCalendarEditing {
            let collapsedHeight: CGFloat = 250
            let collapsedSize = CGSize(width: dropdownSize.width, height: collapsedHeight)
            let baseOrigin = defaultDropdownOrigin(
                containerSize: containerSize,
                anchor: anchor,
                dropdownSize: collapsedSize
            )
            let baseBottomY = baseOrigin.y + collapsedHeight

            let margin: CGFloat = 8
            let maxY = max(margin, containerSize.height - dropdownSize.height - margin)
            let anchoredY = baseBottomY - dropdownSize.height
            let clampedY = min(max(anchoredY, margin), maxY)

            return CGPoint(x: baseOrigin.x, y: clampedY)
        }

        return defaultDropdownOrigin(
            containerSize: containerSize,
            anchor: anchor,
            dropdownSize: dropdownSize
        )
    }

    static func makeAdvanceNavigationAction(
        from activeDropdown: SimpleTimelineViewModel.FilterDropdownType,
        anchorFrameProvider: (SimpleTimelineViewModel.FilterDropdownType) -> CGRect
    ) -> TimelineFilterDropdownOverlayNavigationAction? {
        guard let nextDropdown = nextDropdown(after: activeDropdown) else { return nil }
        return .showDropdown(nextDropdown, anchorFrame: anchorFrameProvider(nextDropdown))
    }

    private static func nextDropdown(
        after activeDropdown: SimpleTimelineViewModel.FilterDropdownType
    ) -> SimpleTimelineViewModel.FilterDropdownType? {
        switch activeDropdown {
        case .visibility:
            return .comments
        case .comments:
            return .dateRange
        case .dateRange:
            return .advanced
        case .none, .apps, .tags, .advanced:
            return nil
        }
    }

    private static func defaultDropdownOrigin(
        containerSize: CGSize,
        anchor: CGRect,
        dropdownSize: CGSize
    ) -> CGPoint {
        let margin: CGFloat = 8
        let gap: CGFloat = 8

        let availableBelow = containerSize.height - anchor.maxY - margin
        let availableAbove = anchor.minY - margin
        let openUpward = availableBelow < (dropdownSize.height + gap) && availableAbove > availableBelow

        let rawY = openUpward
            ? (anchor.minY - gap - dropdownSize.height)
            : (anchor.maxY + gap)
        let maxY = max(margin, containerSize.height - dropdownSize.height - margin)
        let clampedY = min(max(rawY, margin), maxY)

        let rawX = anchor.minX
        let maxX = max(margin, containerSize.width - dropdownSize.width - margin)
        let clampedX = min(max(rawX, margin), maxX)

        return CGPoint(x: clampedX, y: clampedY)
    }
}

struct TimelineFilterDropdownPopoverHost: View {
    @ObservedObject var viewModel: SimpleTimelineViewModel
    let environment: TimelineFilterDropdownExecutionEnvironment

    var body: some View {
        switch viewModel.activeFilterDropdown {
        case .apps:
            AppsFilterPopover(
                apps: viewModel.availableAppsForFilter,
                otherApps: viewModel.otherAppsForFilter,
                selectedApps: viewModel.pendingFilterCriteria.selectedApps,
                filterMode: viewModel.pendingFilterCriteria.appFilterMode,
                allowMultiSelect: true,
                isLoading: viewModel.isLoadingAppsForFilter,
                isLoadingOtherApps: viewModel.isRefreshingRewindAppsForFilter,
                onSelectApp: { bundleID in
                    TimelineFilterDropdownExecutionSupport.executeAppSelection(
                        bundleID,
                        environment: environment
                    )
                },
                onFilterModeChange: { mode in
                    environment.setAppFilterMode(mode)
                }
            )
        case .tags:
            TagsFilterPopover(
                tags: viewModel.availableTags,
                selectedTags: viewModel.pendingFilterCriteria.selectedTags,
                filterMode: viewModel.pendingFilterCriteria.tagFilterMode,
                allowMultiSelect: true,
                onSelectTag: { tagID in
                    TimelineFilterDropdownExecutionSupport.executeTagSelection(
                        tagID,
                        environment: environment
                    )
                },
                onFilterModeChange: { mode in
                    environment.setTagFilterMode(mode)
                }
            )
        case .visibility:
            VisibilityFilterPopover(
                currentFilter: viewModel.pendingFilterCriteria.hiddenFilter,
                onSelect: { filter in
                    environment.setHiddenFilter(filter)
                },
                onDismiss: {
                    environment.dismissDropdown()
                },
                onKeyboardSelect: {
                    TimelineFilterDropdownExecutionSupport.executeAdvanceNavigation(
                        from: .visibility,
                        environment: environment
                    )
                }
            )
        case .comments:
            CommentFilterPopover(
                currentFilter: viewModel.pendingFilterCriteria.commentFilter,
                onSelect: { filter in
                    environment.setCommentFilter(filter)
                },
                onDismiss: {
                    environment.dismissDropdown()
                },
                onKeyboardSelect: {
                    TimelineFilterDropdownExecutionSupport.executeAdvanceNavigation(
                        from: .comments,
                        environment: environment
                    )
                }
            )
        case .dateRange:
            DateRangeFilterPopover(
                dateRanges: viewModel.pendingFilterCriteria.effectiveDateRanges,
                onApply: { ranges in
                    environment.setDateRanges(ranges)
                },
                onClear: {
                    environment.setDateRanges([])
                },
                enableKeyboardNavigation: true,
                onMoveToNextFilter: {
                    TimelineFilterDropdownExecutionSupport.executeAdvanceNavigation(
                        from: .dateRange,
                        environment: environment
                    )
                },
                onCalendarEditingChange: { isEditing in
                    environment.setDateRangeCalendarEditingState(isEditing)
                },
                onQuickPresetShortcut: { preset in
                    environment.recordKeyboardShortcut("timeline.date_range.\(preset.rawValue)")
                },
                onClearShortcut: {
                    environment.recordKeyboardShortcut("timeline.date_range.clear")
                },
                onDismiss: {
                    environment.dismissDropdown()
                }
            )
        case .advanced:
            EmptyView()
        case .none:
            EmptyView()
        }
    }
}
