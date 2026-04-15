import AppKit
import CoreGraphics
import Foundation
import Shared
import SwiftUI

// MARK: - Filter Panel

/// Floating vertical card panel for timeline filtering
struct FilterPanel: View {
    @ObservedObject var viewModel: SimpleTimelineViewModel
    @StateObject private var advancedFilterDraftState = TimelineAdvancedFilterDraftState()
    @StateObject private var dragController = TimelineFilterPanelDragController()
    @StateObject private var interactionController = TimelineFilterPanelInteractionController()

    private var themeBorderColor: Color {
        Color.white.opacity(0.15)
    }

    private var presentation: TimelineFilterPanelPresentation {
        TimelineFilterPanelPresentationSupport.makePresentation(
            pendingCriteria: viewModel.pendingFilterCriteria,
            appliedCriteria: viewModel.filterCriteria,
            availableApps: viewModel.availableAppsForFilter,
            availableTags: viewModel.availableTags
        )
    }

    private func makeExecutionEnvironment() -> TimelineFilterPanelExecutionEnvironment {
        let interactionController = interactionController
        let advancedFilterDraftState = advancedFilterDraftState
        let viewModel = viewModel

        return TimelineFilterPanelExecutionEnvironment(
            clearActionButtonFocus: {
                interactionController.clearActionButtonFocus()
            },
            commitAdvancedDraftInputs: {
                let pendingCriteria = TimelineFilterPanelPresentationSupport.committedPendingCriteria(
                    from: viewModel.pendingFilterCriteria,
                    draftState: advancedFilterDraftState
                )
                if pendingCriteria != viewModel.pendingFilterCriteria {
                    viewModel.replacePendingFilterCriteria(pendingCriteria)
                }
            },
            clearDraftInputs: {
                advancedFilterDraftState.clearDraftInputs()
            },
            clearPendingFilters: {
                viewModel.clearPendingFilters()
            },
            applyFilters: { dismissPanel in
                withAnimation(.easeOut(duration: 0.15)) {
                    viewModel.applyFilters(dismissPanel: dismissPanel)
                }
            },
            showDropdown: { nextDropdown, anchorFrame in
                withAnimation(.easeOut(duration: 0.15)) {
                    viewModel.showFilterDropdown(nextDropdown, anchorFrame: anchorFrame)
                }
            },
            dismissDropdown: {
                withAnimation(.easeOut(duration: 0.15)) {
                    viewModel.dismissFilterDropdown()
                }
            },
            dismissPanel: {
                withAnimation(.easeOut(duration: 0.15)) {
                    viewModel.dismissFilterPanel()
                }
            }
        )
    }

    private func handleDropdownTap(
        _ dropdown: SimpleTimelineViewModel.FilterDropdownType,
        anchorFrame: CGRect
    ) {
        TimelineFilterPanelExecutionSupport.execute(
            TimelineFilterPanelActionSupport.makeDropdownToggleAction(
                tappedDropdown: dropdown,
                activeDropdown: viewModel.activeFilterDropdown,
                anchorFrame: anchorFrame
            ),
            environment: makeExecutionEnvironment()
        )
    }

    private func applyKeyboardDecision(_ decision: TimelineFilterPanelKeyboardDecision) {
        interactionController.apply(decision)
        let resolvedActions = TimelineFilterPanelActionSupport.resolveKeyboardDecision(
            decision,
            hasApplyButton: presentation.hasApplyButton,
            anchorFrameProvider: { dropdown in
                viewModel.filterAnchorFrames[dropdown] ?? .zero
            }
        )

        if let shortcut = resolvedActions.shortcutToRecord {
            viewModel.recordKeyboardShortcut(shortcut)
        }

        if let command = resolvedActions.command {
            TimelineFilterPanelExecutionSupport.execute(
                command,
                environment: makeExecutionEnvironment()
            )
        }

        if let navigation = resolvedActions.navigation {
            TimelineFilterPanelExecutionSupport.execute(
                navigation,
                environment: makeExecutionEnvironment()
            )
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TimelineFilterPanelHeader(
                onClose: {
                    TimelineFilterPanelExecutionSupport.execute(
                        .dismissPanel,
                        environment: makeExecutionEnvironment()
                    )
                },
                onDragChanged: { translation in
                    dragController.updateDrag(translation: translation)
                },
                onDragEnded: { translation in
                    dragController.endDrag(translation: translation)
                }
            )

            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)
                .padding(.horizontal, 16)

            TimelineFilterPanelCompactGrid(
                viewModel: viewModel,
                appsLabel: presentation.appsLabel,
                tagsLabel: presentation.tagsLabel,
                hiddenFilterLabel: presentation.hiddenFilterLabel,
                commentFilterLabel: presentation.commentFilterLabel,
                dateRangeLabel: presentation.dateRangeLabel,
                onDropdownTap: { dropdown, frame in
                    handleDropdownTap(dropdown, anchorFrame: frame)
                },
                onAnchorFrame: { dropdown, frame in
                    viewModel.setFilterAnchorFrame(frame, for: dropdown)
                }
            )
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 12)

            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)
                .padding(.horizontal, 16)

            AdvancedFiltersSection(
                viewModel: viewModel,
                draftState: advancedFilterDraftState,
                advancedFocusedFieldIndex: $interactionController.advancedFocusedFieldIndex
            )

            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)
                .padding(.horizontal, 16)

            TimelineFilterPanelActionBar(
                hasClearButton: presentation.hasClearButton,
                hasApplyButton: presentation.hasApplyButton,
                focusedActionButton: interactionController.focusedActionButton,
                onClear: {
                    TimelineFilterPanelExecutionSupport.execute(
                        .clear,
                        environment: makeExecutionEnvironment()
                    )
                },
                onApply: {
                    TimelineFilterPanelExecutionSupport.execute(
                        .apply(dismissPanel: true),
                        environment: makeExecutionEnvironment()
                    )
                }
            )
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 14)
        }
        .frame(width: 360)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(white: 0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(themeBorderColor, lineWidth: 1)
                )
        )
        .shadow(color: .black.opacity(0.4), radius: 30, y: 15)
        .offset(
            x: dragController.resolvedOffset.width,
            y: dragController.resolvedOffset.height
        )
        .onAppear {
            interactionController.installEventMonitors(
                context: {
                    TimelineFilterPanelKeyboardContext(
                        activeFilterDropdown: viewModel.activeFilterDropdown,
                        advancedFocusedFieldIndex: interactionController.advancedFocusedFieldIndex,
                        isDateRangeCalendarEditing: viewModel.isDateRangeCalendarEditing,
                        focusedActionButton: interactionController.focusedActionButton,
                        hasClearButton: presentation.hasClearButton,
                        hasApplyButton: presentation.hasApplyButton
                    )
                },
                isCommentSubmenuVisible: {
                    viewModel.showCommentSubmenu
                },
                handleDecision: { decision in
                    applyKeyboardDecision(decision)
                },
                handleEscapeAction: { action in
                    if let navigation = TimelineFilterPanelActionSupport.makeNavigationAction(for: action) {
                        TimelineFilterPanelExecutionSupport.execute(
                            navigation,
                            environment: makeExecutionEnvironment()
                        )
                    }
                }
            )
        }
        .onChange(of: viewModel.pendingFilterCriteria) { newCriteria in
            guard viewModel.filterCriteria.hasActiveFilters else { return }
            guard newCriteria != viewModel.filterCriteria else { return }
            TimelineFilterPanelExecutionSupport.execute(
                .apply(dismissPanel: false),
                environment: makeExecutionEnvironment()
            )
        }
        .onChange(of: viewModel.pendingFilterCriteria.hasActiveFilters) { _ in
            interactionController.reconcileActionButtonFocus(
                hasClearButton: presentation.hasClearButton,
                hasApplyButton: presentation.hasApplyButton
            )
        }
        .onChange(of: viewModel.filterCriteria.hasActiveFilters) { _ in
            interactionController.reconcileActionButtonFocus(
                hasClearButton: presentation.hasClearButton,
                hasApplyButton: presentation.hasApplyButton
            )
        }
        .onDisappear {
            interactionController.removeEventMonitors()
            interactionController.resetTransientState()
        }
    }
}

enum TimelineFilterPanelCommandAction: Equatable {
    case apply(dismissPanel: Bool)
    case clear
}

enum TimelineFilterPanelNavigationAction: Equatable {
    case showDropdown(SimpleTimelineViewModel.FilterDropdownType, anchorFrame: CGRect)
    case dismissDropdown
    case dismissPanel
}

struct TimelineFilterPanelResolvedKeyboardActions: Equatable {
    let shortcutToRecord: String?
    let command: TimelineFilterPanelCommandAction?
    let navigation: TimelineFilterPanelNavigationAction?
}

enum TimelineFilterPanelActionSupport {
    static func makeDropdownToggleAction(
        tappedDropdown: SimpleTimelineViewModel.FilterDropdownType,
        activeDropdown: SimpleTimelineViewModel.FilterDropdownType,
        anchorFrame: CGRect
    ) -> TimelineFilterPanelNavigationAction {
        if activeDropdown == tappedDropdown {
            return .dismissDropdown
        }
        return .showDropdown(tappedDropdown, anchorFrame: anchorFrame)
    }

    static func makeNavigationAction(
        for escapeAction: TimelineFilterPanelEscapeAction
    ) -> TimelineFilterPanelNavigationAction? {
        switch escapeAction {
        case .passthrough:
            return nil
        case .dismissDropdown:
            return .dismissDropdown
        case .dismissPanel:
            return .dismissPanel
        }
    }

    static func resolveKeyboardDecision(
        _ decision: TimelineFilterPanelKeyboardDecision,
        hasApplyButton: Bool,
        anchorFrameProvider: (SimpleTimelineViewModel.FilterDropdownType) -> CGRect
    ) -> TimelineFilterPanelResolvedKeyboardActions {
        let command: TimelineFilterPanelCommandAction?
        switch decision.command {
        case .apply?:
            command = .apply(dismissPanel: hasApplyButton)
        case .clear?:
            command = .clear
        case nil:
            command = nil
        }

        let navigation: TimelineFilterPanelNavigationAction?
        switch decision.navigation {
        case let .showDropdown(nextDropdown)?:
            navigation = .showDropdown(nextDropdown, anchorFrame: anchorFrameProvider(nextDropdown))
        case .dismissDropdown?:
            navigation = .dismissDropdown
        case .dismissPanel?:
            navigation = .dismissPanel
        case nil:
            navigation = nil
        }

        return TimelineFilterPanelResolvedKeyboardActions(
            shortcutToRecord: decision.shortcutToRecord,
            command: command,
            navigation: navigation
        )
    }
}

struct TimelineFilterPanelExecutionEnvironment {
    let clearActionButtonFocus: () -> Void
    let commitAdvancedDraftInputs: () -> Void
    let clearDraftInputs: () -> Void
    let clearPendingFilters: () -> Void
    let applyFilters: (Bool) -> Void
    let showDropdown: (SimpleTimelineViewModel.FilterDropdownType, CGRect) -> Void
    let dismissDropdown: () -> Void
    let dismissPanel: () -> Void
}

enum TimelineFilterPanelExecutionSupport {
    static func execute(
        _ action: TimelineFilterPanelCommandAction,
        environment: TimelineFilterPanelExecutionEnvironment
    ) {
        environment.clearActionButtonFocus()

        switch action {
        case let .apply(dismissPanel):
            environment.commitAdvancedDraftInputs()
            environment.applyFilters(dismissPanel)
        case .clear:
            environment.clearDraftInputs()
            environment.clearPendingFilters()
            environment.applyFilters(false)
        }
    }

    static func execute(
        _ action: TimelineFilterPanelNavigationAction,
        environment: TimelineFilterPanelExecutionEnvironment
    ) {
        switch action {
        case let .showDropdown(dropdown, anchorFrame):
            environment.showDropdown(dropdown, anchorFrame)
        case .dismissDropdown:
            environment.dismissDropdown()
        case .dismissPanel:
            environment.dismissPanel()
        }
    }
}
