import Foundation
import SwiftUI

struct ProcessMemoryCardScrollTarget: Equatable {
    let id: String
    let anchorY: CGFloat
}

struct ProcessMemoryCardDisplayedRow: Identifiable {
    enum Kind {
        case primary(rank: Int, isPinnedRetrace: Bool)
        case retraceFamily
        case retraceComponent(familyID: String)
    }

    let row: ProcessMemoryRow
    let kind: Kind

    var id: String {
        switch kind {
        case .primary:
            return row.id
        case .retraceFamily:
            return ProcessMemoryCardPresentation.retraceFamilyRowID(row.id)
        case let .retraceComponent(familyID):
            return "retraceComponent.\(familyID).\(row.id)"
        }
    }

    var rank: Int? {
        switch kind {
        case let .primary(rank, _):
            return rank
        case .retraceFamily, .retraceComponent:
            return nil
        }
    }

    var isPinnedRetrace: Bool {
        switch kind {
        case let .primary(_, isPinnedRetrace):
            return isPinnedRetrace
        case .retraceFamily, .retraceComponent:
            return false
        }
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

    var retraceFamilyID: String? {
        switch kind {
        case .primary:
            return nil
        case .retraceFamily:
            return row.id
        case let .retraceComponent(familyID):
            return familyID
        }
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

    static func retraceFamilyRowID(_ familyID: String) -> String {
        "retraceFamily.\(familyID)"
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
        expandedRows.reserveCapacity(displayed.count + snapshot.topRetraceMemoryAttributionFamilies.count)

        for (index, displayedRow) in displayed.enumerated() {
            expandedRows.append(displayedRow)
            guard index == retraceDisplayIndex else { continue }

            for familyRow in snapshot.topRetraceMemoryAttributionFamilies {
                let familyDisplayedRow = ProcessMemoryCardDisplayedRow(
                    row: familyRow,
                    kind: .retraceFamily
                )
                expandedRows.append(familyDisplayedRow)

                guard expandedAttributionFamilyIDs.contains(familyRow.id) else { continue }
                let componentRows = snapshot.retraceMemoryAttributionChildrenByFamily[familyRow.id] ?? []
                expandedRows.append(contentsOf: componentRows.map {
                    ProcessMemoryCardDisplayedRow(
                        row: $0,
                        kind: .retraceComponent(familyID: familyRow.id)
                    )
                })
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
        expandedAttributionFamilyIDs.removeAll()
    }

    func handleDisappear() {
        scrollTarget = nil
        isHoveringRows = false
        isRetraceExpanded = false
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
                    expandedAttributionFamilyIDs.removeAll()
                }
            }
            if willExpand {
                scrollTarget = Self.retraceExpansionScrollTarget(
                    firstFamilyID: snapshot.topRetraceMemoryAttributionFamilies.first?.id,
                    anchorY: retraceExpansionScrollAnchorY
                )
            }
            onRetraceRowToggle?(willExpand)
            return
        }

        guard displayedRow.isRetraceFamily, let familyID = displayedRow.retraceFamilyID else { return }
        withAnimation(.easeInOut(duration: 0.18)) {
            if expandedAttributionFamilyIDs.contains(familyID) {
                expandedAttributionFamilyIDs.remove(familyID)
            } else {
                expandedAttributionFamilyIDs.insert(familyID)
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
        firstFamilyID: String?,
        anchorY: CGFloat = 0
    ) -> ProcessMemoryCardScrollTarget? {
        guard let firstFamilyID, !firstFamilyID.isEmpty else { return nil }
        return ProcessMemoryCardScrollTarget(
            id: ProcessMemoryCardPresentation.retraceFamilyRowID(firstFamilyID),
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
