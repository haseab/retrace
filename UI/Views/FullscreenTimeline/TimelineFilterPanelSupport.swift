import AppKit
import CoreGraphics
import Foundation
import Shared
import SwiftUI

enum TimelineFilterPanelActionButtonFocus: Equatable {
    case clear
    case apply
}

enum TimelineFilterPanelActionButtonFocusChange: Equatable {
    case none
    case set(TimelineFilterPanelActionButtonFocus?)
}

enum TimelineFilterPanelAdvancedFocusChange: Equatable {
    case none
    case set(Int)
}

enum TimelineFilterPanelKeyboardCommand: Equatable {
    case apply
    case clear
}

enum TimelineFilterPanelKeyboardNavigation: Equatable {
    case showDropdown(SimpleTimelineViewModel.FilterDropdownType)
    case dismissDropdown
    case dismissPanel
}

enum TimelineFilterPanelEscapeAction: Equatable {
    case passthrough
    case dismissDropdown
    case dismissPanel
}

struct TimelineFilterPanelKeyboardContext: Equatable {
    let activeFilterDropdown: SimpleTimelineViewModel.FilterDropdownType
    let advancedFocusedFieldIndex: Int
    let isDateRangeCalendarEditing: Bool
    let focusedActionButton: TimelineFilterPanelActionButtonFocus?
    let hasClearButton: Bool
    let hasApplyButton: Bool
}

enum TimelineFilterPanelKeyboardDecision: Equatable {
    case passthrough
    case handled(
        actionButtonFocus: TimelineFilterPanelActionButtonFocusChange,
        advancedFocus: TimelineFilterPanelAdvancedFocusChange,
        navigation: TimelineFilterPanelKeyboardNavigation?,
        command: TimelineFilterPanelKeyboardCommand?,
        shortcutToRecord: String?
    )

    static func consume(
        actionButtonFocus: TimelineFilterPanelActionButtonFocusChange = .none,
        advancedFocus: TimelineFilterPanelAdvancedFocusChange = .none,
        navigation: TimelineFilterPanelKeyboardNavigation? = nil,
        command: TimelineFilterPanelKeyboardCommand? = nil,
        shortcutToRecord: String? = nil
    ) -> TimelineFilterPanelKeyboardDecision {
        .handled(
            actionButtonFocus: actionButtonFocus,
            advancedFocus: advancedFocus,
            navigation: navigation,
            command: command,
            shortcutToRecord: shortcutToRecord
        )
    }

    var actionButtonFocus: TimelineFilterPanelActionButtonFocusChange {
        guard case let .handled(actionButtonFocus, _, _, _, _) = self else { return .none }
        return actionButtonFocus
    }

    var advancedFocus: TimelineFilterPanelAdvancedFocusChange {
        guard case let .handled(_, advancedFocus, _, _, _) = self else { return .none }
        return advancedFocus
    }

    var navigation: TimelineFilterPanelKeyboardNavigation? {
        guard case let .handled(_, _, navigation, _, _) = self else { return nil }
        return navigation
    }

    var command: TimelineFilterPanelKeyboardCommand? {
        guard case let .handled(_, _, _, command, _) = self else { return nil }
        return command
    }

    var shortcutToRecord: String? {
        guard case let .handled(_, _, _, _, shortcutToRecord) = self else { return nil }
        return shortcutToRecord
    }
}

enum TimelineFilterPanelKeyboardSupport {
    static func makeEscapeAction(
        activeFilterDropdown: SimpleTimelineViewModel.FilterDropdownType,
        isDateRangeCalendarEditing: Bool
    ) -> TimelineFilterPanelEscapeAction {
        if activeFilterDropdown == .dateRange && isDateRangeCalendarEditing {
            return .dismissDropdown
        }
        if activeFilterDropdown != .none {
            return .dismissDropdown
        }
        return .dismissPanel
    }

    static func makeKeyDecision(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        context: TimelineFilterPanelKeyboardContext
    ) -> TimelineFilterPanelKeyboardDecision {
        let normalizedModifiers = modifiers.intersection([.command, .shift, .option, .control])

        if normalizedModifiers == [.command], keyCode == 36 {
            return .consume(
                command: .apply,
                shortcutToRecord: "timeline.filter_panel.apply"
            )
        }

        if normalizedModifiers == [.shift], keyCode == 48,
           context.activeFilterDropdown == .apps {
            return .consume(
                actionButtonFocus: .set(trailingActionButton(hasClearButton: context.hasClearButton, hasApplyButton: context.hasApplyButton)),
                navigation: .dismissDropdown
            )
        }

        guard normalizedModifiers.isEmpty else { return .passthrough }

        switch (context.activeFilterDropdown, keyCode) {
        case (.apps, 124):
            return .consume(navigation: .showDropdown(.tags))
        case (.advanced, 124) where context.advancedFocusedFieldIndex > 0:
            return .passthrough
        case (.advanced, 125) where context.advancedFocusedFieldIndex >= 2:
            return .consume(
                actionButtonFocus: .set(leadingActionButton(hasClearButton: context.hasClearButton, hasApplyButton: context.hasApplyButton)),
                advancedFocus: .set(-4)
            )
        case (.advanced, 48) where context.advancedFocusedFieldIndex == 0:
            return .consume(
                actionButtonFocus: .set(leadingActionButton(hasClearButton: context.hasClearButton, hasApplyButton: context.hasApplyButton)),
                advancedFocus: .set(-4)
            )
        default:
            return .passthrough
        }
    }

    private static func leadingActionButton(
        hasClearButton: Bool,
        hasApplyButton: Bool
    ) -> TimelineFilterPanelActionButtonFocus? {
        if hasClearButton { return .clear }
        if hasApplyButton { return .apply }
        return nil
    }

    private static func trailingActionButton(
        hasClearButton: Bool,
        hasApplyButton: Bool
    ) -> TimelineFilterPanelActionButtonFocus? {
        if hasApplyButton { return .apply }
        if hasClearButton { return .clear }
        return nil
    }
}

@MainActor
final class TimelineFilterPanelDragController: ObservableObject {
    @Published var panelPosition: CGSize = .zero
    @Published var dragOffset: CGSize = .zero

    var resolvedOffset: CGSize {
        CGSize(
            width: panelPosition.width + dragOffset.width,
            height: panelPosition.height + dragOffset.height
        )
    }

    func updateDrag(translation: CGSize) {
        dragOffset = translation
    }

    func endDrag(translation: CGSize) {
        panelPosition = CGSize(
            width: panelPosition.width + translation.width,
            height: panelPosition.height + translation.height
        )
        dragOffset = .zero
    }
}

@MainActor
final class TimelineFilterPanelInteractionController: ObservableObject {
    @Published var focusedActionButton: TimelineFilterPanelActionButtonFocus?
    @Published var advancedFocusedFieldIndex = 0

    private var eventMonitor: Any?

    func apply(_ decision: TimelineFilterPanelKeyboardDecision) {
        if case let .set(newFocus) = decision.actionButtonFocus {
            focusedActionButton = newFocus
        }
        if case let .set(index) = decision.advancedFocus {
            advancedFocusedFieldIndex = index
        }
    }

    func clearActionButtonFocus() {
        focusedActionButton = nil
    }

    func reconcileActionButtonFocus(hasClearButton: Bool, hasApplyButton: Bool) {
        switch focusedActionButton {
        case .clear? where !hasClearButton:
            focusedActionButton = hasApplyButton ? .apply : nil
        case .apply? where !hasApplyButton:
            focusedActionButton = hasClearButton ? .clear : nil
        default:
            if !hasClearButton && !hasApplyButton {
                focusedActionButton = nil
            }
        }
    }

    func installEventMonitors(
        context: @escaping () -> TimelineFilterPanelKeyboardContext,
        isCommentSubmenuVisible: @escaping () -> Bool,
        handleDecision: @escaping (TimelineFilterPanelKeyboardDecision) -> Void,
        handleEscapeAction: @escaping (TimelineFilterPanelEscapeAction) -> Void
    ) {
        removeEventMonitors()
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard !isCommentSubmenuVisible() else { return event }

            let currentContext = context()
            if event.keyCode == 53 {
                let action = TimelineFilterPanelKeyboardSupport.makeEscapeAction(
                    activeFilterDropdown: currentContext.activeFilterDropdown,
                    isDateRangeCalendarEditing: currentContext.isDateRangeCalendarEditing
                )
                handleEscapeAction(action)
                return nil
            }

            let decision = TimelineFilterPanelKeyboardSupport.makeKeyDecision(
                keyCode: event.keyCode,
                modifiers: event.modifierFlags,
                context: currentContext
            )
            guard decision != .passthrough else { return event }
            handleDecision(decision)
            return nil
        }
    }

    func removeEventMonitors() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
    }

    func resetTransientState() {
        focusedActionButton = nil
        advancedFocusedFieldIndex = 0
    }
}

struct TimelineFilterPanelPresentation: Equatable {
    let appsLabel: String
    let tagsLabel: String
    let hiddenFilterLabel: String
    let commentFilterLabel: String
    let dateRangeLabel: String
    let hasClearButton: Bool
    let hasApplyButton: Bool
}

@MainActor
enum TimelineFilterPanelPresentationSupport {
    static func makePresentation(
        pendingCriteria: FilterCriteria,
        appliedCriteria: FilterCriteria,
        availableApps: [(bundleID: String, name: String)],
        availableTags: [Tag],
        dateFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.locale = .autoupdatingCurrent
            formatter.dateFormat = "MMM d"
            return formatter
        }()
    ) -> TimelineFilterPanelPresentation {
        TimelineFilterPanelPresentation(
            appsLabel: appLabel(criteria: pendingCriteria, availableApps: availableApps),
            tagsLabel: tagLabel(criteria: pendingCriteria, availableTags: availableTags),
            hiddenFilterLabel: hiddenLabel(for: pendingCriteria.hiddenFilter),
            commentFilterLabel: commentLabel(for: pendingCriteria.commentFilter),
            dateRangeLabel: dateRangeLabel(criteria: pendingCriteria, formatter: dateFormatter),
            hasClearButton: pendingCriteria.hasActiveFilters || appliedCriteria.hasActiveFilters,
            hasApplyButton: pendingCriteria != appliedCriteria
        )
    }

    static func committedPendingCriteria(
        from criteria: FilterCriteria,
        draftState: TimelineAdvancedFilterDraftState
    ) -> FilterCriteria {
        var updated = criteria
        draftState.applyMetadataFilters(to: &updated)
        return updated
    }

    private static func appLabel(
        criteria: FilterCriteria,
        availableApps: [(bundleID: String, name: String)]
    ) -> String {
        guard let selectedApps = criteria.selectedApps, !selectedApps.isEmpty else { return "All Apps" }
        if selectedApps.count == 1, let selected = selectedApps.first {
            let name = availableApps.first(where: { $0.bundleID == selected })?.name
            return name ?? (selected.components(separatedBy: ".").last ?? selected)
        }
        let prefix = criteria.appFilterMode == .exclude ? "Exclude: " : ""
        return "\(prefix)\(selectedApps.count) Apps"
    }

    private static func tagLabel(criteria: FilterCriteria, availableTags: [Tag]) -> String {
        guard let selectedTags = criteria.selectedTags, !selectedTags.isEmpty else { return "All Tags" }
        if selectedTags.count == 1, let selected = selectedTags.first {
            return availableTags.first(where: { $0.id.value == selected })?.name ?? "1 Tag"
        }
        let prefix = criteria.tagFilterMode == .exclude ? "Exclude: " : ""
        return "\(prefix)\(selectedTags.count) Tags"
    }

    private static func hiddenLabel(for filter: HiddenFilter) -> String {
        switch filter {
        case .hide: return "Visible"
        case .onlyHidden: return "Hidden"
        case .showAll: return "All"
        }
    }

    private static func commentLabel(for filter: CommentFilter) -> String {
        switch filter {
        case .allFrames: return "All"
        case .commentsOnly: return "Comments"
        case .noComments: return "No Comments"
        }
    }

    private static func dateRangeLabel(criteria: FilterCriteria, formatter: DateFormatter) -> String {
        let ranges = criteria.effectiveDateRanges
        guard !ranges.isEmpty else { return "Any Date" }
        if ranges.count > 1 { return "\(ranges.count) date ranges" }

        let range = ranges[0]
        switch (range.start, range.end) {
        case let (start?, end?):
            return "\(formatter.string(from: start)) - \(formatter.string(from: end))"
        case let (start?, nil):
            return "From \(formatter.string(from: start))"
        case let (nil, end?):
            return "Until \(formatter.string(from: end))"
        default:
            return "Any Date"
        }
    }
}

@MainActor
final class TimelineAdvancedFilterDraftState: ObservableObject {
    static let metadataFilterPrefix = "__retrace_meta_filter_v1__"

    struct EncodedMetadataFilterPayload: Codable, Equatable {
        let includeTerms: [String]?
        let excludeTerms: [String]?
        let mode: AppFilterMode?
        let terms: [String]?
    }

    struct DecodedMetadataFilter: Equatable {
        let includeTerms: [String]
        let excludeTerms: [String]
        let mode: AppFilterMode
    }

    @Published var windowNameIncludeTerms: [String] = []
    @Published var windowNameExcludeTerms: [String] = []
    @Published var windowNameFilterMode: AppFilterMode = .include
    @Published var browserUrlIncludeTerms: [String] = []
    @Published var browserUrlExcludeTerms: [String] = []
    @Published var browserUrlFilterMode: AppFilterMode = .include
    @Published var windowInputText = ""
    @Published var browserInputText = ""

    func clearDraftInputs() {
        windowInputText = ""
        browserInputText = ""
    }

    func commitWindowNameDraft() {
        commitDraft(
            input: &windowInputText,
            mode: windowNameFilterMode,
            includeTerms: &windowNameIncludeTerms,
            excludeTerms: &windowNameExcludeTerms
        )
    }

    func commitBrowserDraft() {
        commitDraft(
            input: &browserInputText,
            mode: browserUrlFilterMode,
            includeTerms: &browserUrlIncludeTerms,
            excludeTerms: &browserUrlExcludeTerms
        )
    }

    func sync(from criteria: FilterCriteria) {
        let window = Self.decodeMetadataFilter(criteria.windowNameFilter)
        let browser = Self.decodeMetadataFilter(criteria.browserUrlFilter)
        windowNameIncludeTerms = window.includeTerms
        windowNameExcludeTerms = window.excludeTerms
        windowNameFilterMode = window.mode
        browserUrlIncludeTerms = browser.includeTerms
        browserUrlExcludeTerms = browser.excludeTerms
        browserUrlFilterMode = browser.mode
        clearDraftInputs()
    }

    func applyMetadataFilters(to criteria: inout FilterCriteria) {
        commitWindowNameDraft()
        commitBrowserDraft()
        criteria.windowNameFilter = Self.encodeMetadataFilter(
            includeTerms: windowNameIncludeTerms,
            excludeTerms: windowNameExcludeTerms
        )
        criteria.browserUrlFilter = Self.encodeMetadataFilter(
            includeTerms: browserUrlIncludeTerms,
            excludeTerms: browserUrlExcludeTerms
        )
    }

    static func decodeMetadataFilter(_ encoded: String?) -> DecodedMetadataFilter {
        guard let encoded,
              encoded.hasPrefix(metadataFilterPrefix),
              let data = Data(base64Encoded: String(encoded.dropFirst(metadataFilterPrefix.count))),
              let payload = try? JSONDecoder().decode(EncodedMetadataFilterPayload.self, from: data) else {
            return .init(includeTerms: [], excludeTerms: [], mode: .include)
        }

        if let mode = payload.mode, let terms = payload.terms {
            return mode == .exclude
                ? .init(includeTerms: [], excludeTerms: normalizedTerms(terms), mode: .exclude)
                : .init(includeTerms: normalizedTerms(terms), excludeTerms: [], mode: .include)
        }

        let includeTerms = normalizedTerms(payload.includeTerms ?? [])
        let excludeTerms = normalizedTerms(payload.excludeTerms ?? [])
        let mode: AppFilterMode = excludeTerms.isEmpty ? .include : .exclude
        return .init(includeTerms: includeTerms, excludeTerms: excludeTerms, mode: mode)
    }

    private static func encodeMetadataFilter(includeTerms: [String], excludeTerms: [String]) -> String? {
        let normalizedInclude = normalizedTerms(includeTerms)
        let includeKeys = Set(normalizedInclude.map { $0.lowercased() })
        let normalizedExclude = normalizedTerms(excludeTerms).filter { !includeKeys.contains($0.lowercased()) }
        guard !normalizedInclude.isEmpty || !normalizedExclude.isEmpty else { return nil }

        let payload = EncodedMetadataFilterPayload(
            includeTerms: normalizedInclude,
            excludeTerms: normalizedExclude,
            mode: nil,
            terms: nil
        )
        guard let data = try? JSONEncoder().encode(payload) else { return nil }
        return metadataFilterPrefix + data.base64EncodedString()
    }

    private func commitDraft(
        input: inout String,
        mode: AppFilterMode,
        includeTerms: inout [String],
        excludeTerms: inout [String]
    ) {
        guard let normalized = Self.normalizedTerm(input) else {
            input = ""
            return
        }

        if mode == .exclude {
            excludeTerms = Self.normalizedTerms(excludeTerms + [normalized])
            includeTerms.removeAll { $0.caseInsensitiveCompare(normalized) == .orderedSame }
        } else {
            includeTerms = Self.normalizedTerms(includeTerms + [normalized])
            excludeTerms.removeAll { $0.caseInsensitiveCompare(normalized) == .orderedSame }
        }
        input = ""
    }

    private static func normalizedTerm(_ term: String) -> String? {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalizedTerms(_ terms: [String]) -> [String] {
        var seen = Set<String>()
        var normalized: [String] = []
        for term in terms {
            guard let cleaned = normalizedTerm(term) else { continue }
            let key = cleaned.lowercased()
            if seen.insert(key).inserted {
                normalized.append(cleaned)
            }
        }
        return normalized
    }
}

struct TimelineFilterPanelHeader: View {
    let onClose: () -> Void
    let onDragChanged: (CGSize) -> Void
    let onDragEnded: (CGSize) -> Void

    var body: some View {
        HStack {
            Text("Filters")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(0.95))
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.75))
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .contentShape(Rectangle())
        .gesture(
            DragGesture()
                .onChanged { onDragChanged($0.translation) }
                .onEnded { onDragEnded($0.translation) }
        )
    }
}

struct TimelineFilterPanelCompactGrid: View {
    @ObservedObject var viewModel: SimpleTimelineViewModel
    let appsLabel: String
    let tagsLabel: String
    let hiddenFilterLabel: String
    let commentFilterLabel: String
    let dateRangeLabel: String
    let onDropdownTap: (SimpleTimelineViewModel.FilterDropdownType, CGRect) -> Void
    let onAnchorFrame: (SimpleTimelineViewModel.FilterDropdownType, CGRect) -> Void

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                CompactAppsFilterDropdown(
                    label: "APPS",
                    selectedApps: viewModel.pendingFilterCriteria.selectedApps,
                    isExcludeMode: viewModel.pendingFilterCriteria.appFilterMode == .exclude,
                    isOpen: viewModel.activeFilterDropdown == .apps,
                    onTap: { onDropdownTap(.apps, $0) },
                    onFrameAvailable: { onAnchorFrame(.apps, $0) }
                )
                CompactFilterDropdown(
                    label: "TAGS",
                    value: tagsLabel,
                    icon: "tag",
                    isActive: viewModel.pendingFilterCriteria.selectedTags?.isEmpty == false,
                    isOpen: viewModel.activeFilterDropdown == .tags,
                    onTap: { onDropdownTap(.tags, $0) },
                    onFrameAvailable: { onAnchorFrame(.tags, $0) }
                )
            }

            HStack(spacing: 10) {
                CompactFilterDropdown(
                    label: "VISIBILITY",
                    value: hiddenFilterLabel,
                    icon: "eye",
                    isActive: viewModel.pendingFilterCriteria.hiddenFilter != .hide,
                    isOpen: viewModel.activeFilterDropdown == .visibility,
                    onTap: { onDropdownTap(.visibility, $0) },
                    onFrameAvailable: { onAnchorFrame(.visibility, $0) }
                )
                CompactFilterDropdown(
                    label: "COMMENTS",
                    value: commentFilterLabel,
                    icon: "text.bubble",
                    isActive: viewModel.pendingFilterCriteria.commentFilter != .allFrames,
                    isOpen: viewModel.activeFilterDropdown == .comments,
                    onTap: { onDropdownTap(.comments, $0) },
                    onFrameAvailable: { onAnchorFrame(.comments, $0) }
                )
            }

            HStack(spacing: 10) {
                CompactFilterDropdown(
                    label: "DATE",
                    value: dateRangeLabel,
                    icon: "calendar",
                    isActive: !viewModel.pendingFilterCriteria.effectiveDateRanges.isEmpty,
                    isOpen: viewModel.activeFilterDropdown == .dateRange,
                    onTap: { onDropdownTap(.dateRange, $0) },
                    onFrameAvailable: { onAnchorFrame(.dateRange, $0) }
                )
                CompactFilterDropdown(
                    label: "ADVANCED",
                    value: viewModel.pendingFilterCriteria.hasAdvancedFilters ? "Configured" : "None",
                    icon: "slider.horizontal.3",
                    isActive: viewModel.pendingFilterCriteria.hasAdvancedFilters,
                    isOpen: viewModel.activeFilterDropdown == .advanced,
                    onTap: { onDropdownTap(.advanced, $0) },
                    onFrameAvailable: { onAnchorFrame(.advanced, $0) }
                )
            }
        }
    }
}

struct TimelineFilterPanelActionBar: View {
    let hasClearButton: Bool
    let hasApplyButton: Bool
    let focusedActionButton: TimelineFilterPanelActionButtonFocus?
    let onClear: () -> Void
    let onApply: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if hasClearButton {
                button(
                    title: "Clear",
                    isFocused: focusedActionButton == .clear,
                    primary: false,
                    action: onClear
                )
            }
            if hasApplyButton {
                button(
                    title: "Apply",
                    isFocused: focusedActionButton == .apply,
                    primary: true,
                    action: onApply
                )
            }
        }
    }

    private func button(
        title: String,
        isFocused: Bool,
        primary: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(primary ? .black : .white.opacity(0.9))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 9)
                        .fill(primary ? Color.white.opacity(0.92) : Color.white.opacity(0.09))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9)
                        .stroke(isFocused ? Color.white.opacity(0.9) : Color.white.opacity(0.14), lineWidth: isFocused ? 1.5 : 1)
                )
        }
        .buttonStyle(.plain)
    }
}

struct AdvancedFiltersSection: View {
    @ObservedObject var viewModel: SimpleTimelineViewModel
    @ObservedObject var draftState: TimelineAdvancedFilterDraftState
    @Binding var advancedFocusedFieldIndex: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Advanced")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.7))

            TextField("Window name", text: $draftState.windowInputText)
                .textFieldStyle(.roundedBorder)
                .onSubmit { draftState.commitWindowNameDraft() }
                .onTapGesture { advancedFocusedFieldIndex = 1 }

            termRow(
                terms: draftState.windowNameFilterMode == .exclude ? draftState.windowNameExcludeTerms : draftState.windowNameIncludeTerms,
                remove: removeWindowTerm
            )

            TextField("Browser URL", text: $draftState.browserInputText)
                .textFieldStyle(.roundedBorder)
                .onSubmit { draftState.commitBrowserDraft() }
                .onTapGesture { advancedFocusedFieldIndex = 2 }

            termRow(
                terms: draftState.browserUrlFilterMode == .exclude ? draftState.browserUrlExcludeTerms : draftState.browserUrlIncludeTerms,
                remove: removeBrowserTerm
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .onAppear {
            draftState.sync(from: viewModel.pendingFilterCriteria)
        }
        .onChange(of: viewModel.pendingFilterCriteria) { criteria in
            draftState.sync(from: criteria)
        }
    }

    private func termRow(terms: [String], remove: @escaping (String) -> Void) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(terms, id: \.self) { term in
                    TimelineMetadataTermChip(text: term) { remove(term) }
                }
            }
        }
    }

    private func removeWindowTerm(_ term: String) {
        draftState.windowNameIncludeTerms.removeAll { $0.caseInsensitiveCompare(term) == .orderedSame }
        draftState.windowNameExcludeTerms.removeAll { $0.caseInsensitiveCompare(term) == .orderedSame }
    }

    private func removeBrowserTerm(_ term: String) {
        draftState.browserUrlIncludeTerms.removeAll { $0.caseInsensitiveCompare(term) == .orderedSame }
        draftState.browserUrlExcludeTerms.removeAll { $0.caseInsensitiveCompare(term) == .orderedSame }
    }
}

struct TimelineMetadataTermChip: View {
    let text: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.9))
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.white.opacity(0.75))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            Capsule()
                .fill(Color.white.opacity(0.08))
        )
        .overlay(
            Capsule()
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
    }
}
