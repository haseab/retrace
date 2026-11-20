import Foundation
import SwiftUI

struct ProcessMemoryCardScrollTarget: Equatable {
    let id: String
    let anchorY: CGFloat
}

struct ProcessMemoryCardDisplayedRow: Identifiable {
    enum Kind {
        case primary(rank: Int, isPinnedRetrace: Bool)
        case retraceCategory
        case retraceFamily(categoryID: String)
        case retraceComponent(categoryID: String, familyID: String)
    }

    let row: ProcessMemoryRow
    let kind: Kind

    var id: String {
        switch kind {
        case .primary:
            return row.id
        case .retraceCategory:
            return ProcessMemoryCardPresentation.retraceCategoryRowID(row.id)
        case let .retraceFamily(categoryID):
            return ProcessMemoryCardPresentation.retraceFamilyRowID(
                categoryID: categoryID,
                familyID: row.id
            )
        case let .retraceComponent(categoryID, familyID):
            return "retraceComponent.\(categoryID).\(familyID).\(row.id)"
        }
    }

    var rank: Int? {
        switch kind {
        case let .primary(rank, _):
            return rank
        case .retraceCategory, .retraceFamily, .retraceComponent:
            return nil
        }
    }

    var isPinnedRetrace: Bool {
        switch kind {
        case let .primary(_, isPinnedRetrace):
            return isPinnedRetrace
        case .retraceCategory, .retraceFamily, .retraceComponent:
            return false
        }
    }

    var isRetraceCategory: Bool {
        if case .retraceCategory = kind {
            return true
        }
        return false
    }

    var isRetraceFamily: Bool {
        if case .retraceFamily = kind {
            return true
        }
        return false
    }

    var isRetraceComponent: Bool {
        if case .retraceComponent = kind {
            return true
        }
        return false
    }

    var retraceCategoryID: String? {
        switch kind {
        case .primary:
            return nil
        case .retraceCategory:
            return row.id
        case let .retraceFamily(categoryID):
            return categoryID
        case let .retraceComponent(categoryID, _):
            return categoryID
        }
    }

    var retraceFamilyID: String? {
        switch kind {
        case .primary:
            return nil
        case .retraceCategory:
            return nil
        case .retraceFamily:
            return row.id
        case let .retraceComponent(_, familyID):
            return familyID
        }
    }

    var retraceFamilyExpansionKey: String? {
        guard let categoryID = retraceCategoryID,
              let familyID = retraceFamilyID else { return nil }
        return ProcessCPUDisplayMetrics.retraceMemoryAttributionFamilyExpansionKey(
            categoryID: categoryID,
            familyID: familyID
        )
    }
}

struct ProcessMemoryCardPresentation {
    let totalRows: Int
    let visibleRows: Int
    let displayedRows: [ProcessMemoryCardDisplayedRow]
    let hasMoreRows: Bool
    let rankColumnWidth: CGFloat
    let allowsInnerScroll: Bool

    static func memoryProcessRowAnchorID(_ rowNumber: Int) -> String {
        "systemMonitor.memoryProcessRow.\(rowNumber)"
    }

    static func retraceCategoryRowID(_ categoryID: String) -> String {
        "retraceCategory.\(categoryID)"
    }

    static func retraceFamilyRowID(categoryID: String, familyID: String) -> String {
        "retraceFamily.\(categoryID).\(familyID)"
    }

    static func rankColumnWidth(
        for displayedRows: [ProcessMemoryCardDisplayedRow],
        compactWidth: CGFloat,
        expandedWidth: CGFloat
    ) -> CGFloat {
        let hasThreeDigitRank = displayedRows.contains { ($0.rank ?? 0) >= 100 }
        return hasThreeDigitRank ? expandedWidth : compactWidth
    }

    static func buildDisplayedRows(
        from snapshot: ProcessCPUSnapshot,
        visibleRows: Int,
        isRetraceExpanded: Bool,
        expandedAttributionCategoryIDs: Set<String>,
        expandedAttributionFamilyIDs: Set<String>
    ) -> [ProcessMemoryCardDisplayedRow] {
        let rankedRows = snapshot.topMemoryProcesses
        guard !rankedRows.isEmpty else { return [] }
        let retraceGroupKey = snapshot.retraceGroupKey

        var displayed = rankedRows
            .prefix(visibleRows)
            .enumerated()
            .map { offset, row in
                ProcessMemoryCardDisplayedRow(
                    row: row,
                    kind: .primary(rank: offset + 1, isPinnedRetrace: row.id == retraceGroupKey)
                )
            }

        if let retraceGroupKey,
           let retraceIndex = rankedRows.firstIndex(where: { $0.id == retraceGroupKey }),
           retraceIndex >= visibleRows {
            let retraceRow = ProcessMemoryCardDisplayedRow(
                row: rankedRows[retraceIndex],
                kind: .primary(rank: retraceIndex + 1, isPinnedRetrace: true)
            )

            if displayed.isEmpty {
                displayed.append(retraceRow)
            } else {
                displayed[displayed.count - 1] = retraceRow
            }
        }

        guard isRetraceExpanded,
              let retraceDisplayIndex = displayed.firstIndex(where: { $0.isPinnedRetrace }) else {
            return displayed
        }

        var expandedRows: [ProcessMemoryCardDisplayedRow] = []
        expandedRows.reserveCapacity(
            displayed.count
                + snapshot.retraceMemoryAttributionTree.categories.count
        )

        for (index, displayedRow) in displayed.enumerated() {
            expandedRows.append(displayedRow)
            guard index == retraceDisplayIndex else { continue }

            let attributionTree = snapshot.retraceMemoryAttributionTree
            for categoryRow in attributionTree.categories {
                let categoryDisplayedRow = ProcessMemoryCardDisplayedRow(
                    row: categoryRow,
                    kind: .retraceCategory
                )
                expandedRows.append(categoryDisplayedRow)

                guard expandedAttributionCategoryIDs.contains(categoryRow.id) else { continue }
                let familyRows = attributionTree.familiesByCategory[categoryRow.id] ?? []
                for familyRow in familyRows {
                    let familyDisplayedRow = ProcessMemoryCardDisplayedRow(
                        row: familyRow,
                        kind: .retraceFamily(categoryID: categoryRow.id)
                    )
                    expandedRows.append(familyDisplayedRow)

                    let familyExpansionKey = ProcessCPUDisplayMetrics.retraceMemoryAttributionFamilyExpansionKey(
                        categoryID: categoryRow.id,
                        familyID: familyRow.id
                    )
                    guard expandedAttributionFamilyIDs.contains(familyExpansionKey) else { continue }
                    let componentRows = attributionTree.componentsByCategoryFamily[familyExpansionKey] ?? []
                    expandedRows.append(contentsOf: componentRows.map {
                        ProcessMemoryCardDisplayedRow(
                            row: $0,
                            kind: .retraceComponent(
                                categoryID: categoryRow.id,
                                familyID: familyRow.id
                            )
                        )
                    })
                }
            }
        }

        return expandedRows
    }
}

@MainActor
final class ProcessMemoryCardController: ObservableObject {
    @Published private(set) var visibleRows: Int
    @Published private(set) var isHoveringRows = false
    @Published private(set) var isRetraceExpanded = false
    @Published private(set) var expandedAttributionCategoryIDs: Set<String> = []
    @Published private(set) var expandedAttributionFamilyIDs: Set<String> = []
    @Published var scrollTarget: ProcessMemoryCardScrollTarget?

    private let pageSize: Int
    private let retraceExpansionScrollAnchorY: CGFloat

    init(
        pageSize: Int = 10,
        retraceExpansionScrollAnchorY: CGFloat = 0
    ) {
        self.pageSize = pageSize
        self.retraceExpansionScrollAnchorY = retraceExpansionScrollAnchorY
        self.visibleRows = pageSize
    }

    func handleAppear() {
        visibleRows = pageSize
        scrollTarget = nil
        isHoveringRows = false
        isRetraceExpanded = false
        expandedAttributionCategoryIDs.removeAll()
        expandedAttributionFamilyIDs.removeAll()
    }

    func handleDisappear() {
        scrollTarget = nil
        isHoveringRows = false
        isRetraceExpanded = false
        expandedAttributionCategoryIDs.removeAll()
        expandedAttributionFamilyIDs.removeAll()
    }

    func handleRowsHoverChanged(_ hovering: Bool) {
        isHoveringRows = hovering
    }

    func clearScrollTarget() {
        scrollTarget = nil
    }

    func loadMore(totalRows: Int) {
        let nextStartRow = visibleRows + 1
        guard nextStartRow <= totalRows else { return }
        visibleRows = min(totalRows, visibleRows + pageSize)
        scrollTarget = ProcessMemoryCardScrollTarget(
            id: ProcessMemoryCardPresentation.memoryProcessRowAnchorID(nextStartRow),
            anchorY: 0
        )
    }

    func handleRowTap(
        _ displayedRow: ProcessMemoryCardDisplayedRow,
        snapshot: ProcessCPUSnapshot,
        onRetraceRowToggle: ((Bool) -> Void)? = nil
    ) {
        if displayedRow.isPinnedRetrace {
            let willExpand = !isRetraceExpanded
            withAnimation(.easeInOut(duration: 0.18)) {
                isRetraceExpanded = willExpand
                if !willExpand {
                    expandedAttributionCategoryIDs.removeAll()
                    expandedAttributionFamilyIDs.removeAll()
                }
            }
            if willExpand {
                scrollTarget = Self.retraceExpansionScrollTarget(
                    firstCategoryID: snapshot.retraceMemoryAttributionTree.categories.first?.id,
                    anchorY: retraceExpansionScrollAnchorY
                )
            }
            onRetraceRowToggle?(willExpand)
            return
        }

        if displayedRow.isRetraceCategory,
           let categoryID = displayedRow.retraceCategoryID {
            withAnimation(.easeInOut(duration: 0.18)) {
                if expandedAttributionCategoryIDs.contains(categoryID) {
                    expandedAttributionCategoryIDs.remove(categoryID)
                    expandedAttributionFamilyIDs = Set(
                        expandedAttributionFamilyIDs.filter { !$0.hasPrefix(categoryID + "|") }
                    )
                } else {
                    expandedAttributionCategoryIDs.insert(categoryID)
                }
            }
            return
        }

        guard displayedRow.isRetraceFamily,
              let familyExpansionKey = displayedRow.retraceFamilyExpansionKey else { return }
        withAnimation(.easeInOut(duration: 0.18)) {
            if expandedAttributionFamilyIDs.contains(familyExpansionKey) {
                expandedAttributionFamilyIDs.remove(familyExpansionKey)
            } else {
                expandedAttributionFamilyIDs.insert(familyExpansionKey)
            }
        }
    }

    func presentation(
        for snapshot: ProcessCPUSnapshot,
        isRowsScrollEnabled: Bool,
        compactRankColumnWidth: CGFloat,
        expandedRankColumnWidth: CGFloat
    ) -> ProcessMemoryCardPresentation {
        let totalRows = snapshot.topMemoryProcesses.count
        let clampedVisibleRows = min(max(pageSize, visibleRows), totalRows)
        let displayedRows = ProcessMemoryCardPresentation.buildDisplayedRows(
            from: snapshot,
            visibleRows: clampedVisibleRows,
            isRetraceExpanded: isRetraceExpanded,
            expandedAttributionCategoryIDs: expandedAttributionCategoryIDs,
            expandedAttributionFamilyIDs: expandedAttributionFamilyIDs
        )
        return ProcessMemoryCardPresentation(
            totalRows: totalRows,
            visibleRows: clampedVisibleRows,
            displayedRows: displayedRows,
            hasMoreRows: clampedVisibleRows < totalRows,
            rankColumnWidth: ProcessMemoryCardPresentation.rankColumnWidth(
                for: displayedRows,
                compactWidth: compactRankColumnWidth,
                expandedWidth: expandedRankColumnWidth
            ),
            allowsInnerScroll: Self.shouldEnableInnerScroll(
                isRowsScrollEnabled: isRowsScrollEnabled,
                visibleRows: clampedVisibleRows,
                displayedRowsCount: displayedRows.count,
                pageSize: pageSize
            )
        )
    }

    static func retraceExpansionScrollTarget(
        firstCategoryID: String?,
        anchorY: CGFloat = 0
    ) -> ProcessMemoryCardScrollTarget? {
        guard let firstCategoryID, !firstCategoryID.isEmpty else { return nil }
        return ProcessMemoryCardScrollTarget(
            id: ProcessMemoryCardPresentation.retraceCategoryRowID(firstCategoryID),
            anchorY: anchorY
        )
    }

    static func shouldEnableInnerScroll(
        isRowsScrollEnabled: Bool,
        visibleRows: Int,
        displayedRowsCount: Int,
        pageSize: Int = 10
    ) -> Bool {
        guard isRowsScrollEnabled else { return false }
        return visibleRows > pageSize || displayedRowsCount > visibleRows
    }

    static func parentHoverState(isHoveringRows: Bool, allowsInnerScroll: Bool) -> Bool {
        allowsInnerScroll && isHoveringRows
    }
}
