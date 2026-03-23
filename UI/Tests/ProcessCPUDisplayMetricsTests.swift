import XCTest
@testable import Retrace

final class ProcessCPUDisplayMetricsTests: XCTestCase {
    func testProcessMemorySummaryCardEnablesInnerScrollWhenExpandedRowsExceedVisiblePage() {
        XCTAssertTrue(
            ProcessMemorySummaryCard.shouldEnableInnerScroll(
                isRowsScrollEnabled: true,
                visibleRows: 10,
                displayedRowsCount: 14
            )
        )
    }

    func testProcessMemorySummaryCardKeepsInnerScrollDisabledOnFirstPageWithoutExpansion() {
        XCTAssertFalse(
            ProcessMemorySummaryCard.shouldEnableInnerScroll(
                isRowsScrollEnabled: true,
                visibleRows: 10,
                displayedRowsCount: 10
            )
        )
    }

    func testProcessMemorySummaryCardBuildsExpansionScrollTargetForFirstFamilyRow() {
        let target = ProcessMemorySummaryCard.retraceExpansionScrollTarget(
            firstFamilyID: "storage.videoEncoding"
        )

        XCTAssertEqual(
            target,
            ProcessMemorySummaryCard.MemoryProcessScrollTarget(
                id: "retraceFamily.storage.videoEncoding",
                anchorY: 0
            )
        )
    }

    func testProcessMemorySummaryCardReturnsNilExpansionScrollTargetWithoutFamily() {
        XCTAssertNil(
            ProcessMemorySummaryCard.retraceExpansionScrollTarget(firstFamilyID: nil)
        )
    }

    func testProcessMemorySummaryCardParentHoverStateRequiresHoverAndEnabledScroll() {
        XCTAssertTrue(
            ProcessMemorySummaryCard.parentHoverState(
                isHoveringRows: true,
                allowsInnerScroll: true
            )
        )
        XCTAssertFalse(
            ProcessMemorySummaryCard.parentHoverState(
                isHoveringRows: true,
                allowsInnerScroll: false
            )
        )
        XCTAssertFalse(
            ProcessMemorySummaryCard.parentHoverState(
                isHoveringRows: false,
                allowsInnerScroll: true
            )
        )
    }

    func testProcessCPUSummaryCardParentHoverStateRequiresHoverAndEnabledScroll() {
        XCTAssertTrue(
            ProcessCPUSummaryCard.parentHoverState(
                isHoveringRows: true,
                allowsInnerScroll: true
            )
        )
        XCTAssertFalse(
            ProcessCPUSummaryCard.parentHoverState(
                isHoveringRows: true,
                allowsInnerScroll: false
            )
        )
        XCTAssertFalse(
            ProcessCPUSummaryCard.parentHoverState(
                isHoveringRows: false,
                allowsInnerScroll: true
            )
        )
    }

    func testProcessMemorySummaryCardFormatsGBOnceDisplayedMBWouldReachFourDigits() {
        XCTAssertEqual(
            ProcessMemorySummaryCard.formatMemoryBytesForDisplay(
                UInt64((1019.3 * 1024 * 1024).rounded())
            ),
            "1.00 GB"
        )
        XCTAssertEqual(
            ProcessMemorySummaryCard.formatMemoryBytesForDisplay(
                UInt64((905.3 * 1024 * 1024).rounded())
            ),
            "905.3 MB"
        )
    }

    func testBuildRowsUsesLatestSamplePercentForCurrentColumnWhileKeepingAverageSortOrder() {
        let rows = ProcessCPUDisplayMetrics.buildRows(
            cumulativeNanosecondsByGroup: [
                "bundle:io.retrace.app": 15_000_000_000,
                "bundle:com.google.Chrome": 10_000_000_000
            ],
            latestDeltaNanosecondsByGroup: [
                "bundle:io.retrace.app": 250_000_000,
                "bundle:com.google.Chrome": 1_000_000_000
            ],
            latestSampleDurationSeconds: 1,
            energyNanojoulesByGroup: [:],
            peakPowerWattsByGroup: [:],
            displayNamesByKey: [
                "bundle:io.retrace.app": "Retrace",
                "bundle:com.google.Chrome": "Google Chrome"
            ],
            totalDuration: 100,
            logicalCoreCount: 10
        )

        XCTAssertEqual(rows.map(\.id), [
            "bundle:io.retrace.app",
            "bundle:com.google.Chrome"
        ])
        XCTAssertEqual(rows[0].currentCapacityPercent, 2.5, accuracy: 0.000_1)
        XCTAssertEqual(rows[1].currentCapacityPercent, 10.0, accuracy: 0.000_1)
        XCTAssertEqual(rows[0].capacityPercent, 1.5, accuracy: 0.000_1)
        XCTAssertEqual(rows[1].capacityPercent, 1.0, accuracy: 0.000_1)
    }

    func testCapacityPercentReturnsZeroWithoutUsableLatestSampleDuration() {
        XCTAssertEqual(
            ProcessCPUDisplayMetrics.capacityPercent(
                deltaNanoseconds: 1_000_000_000,
                sampleDurationSeconds: 0,
                logicalCoreCount: 10
            ),
            0,
            accuracy: 0.000_1
        )
    }

    func testBuildMemoryRowsCalculatesCurrentAverageAndPeakValues() {
        let rows = ProcessCPUDisplayMetrics.buildMemoryRows(
            currentBytesByKey: [
                "bundle:io.retrace.app": 300,
                "retrace-proc:retrace-main": 120
            ],
            memoryByteSecondsByKey: [
                "bundle:io.retrace.app": 2_400,
                "retrace-proc:retrace-main": 600
            ],
            peakBytesByKey: [
                "bundle:io.retrace.app": 420,
                "retrace-proc:retrace-main": 180
            ],
            displayNamesByKey: [
                "bundle:io.retrace.app": "Retrace",
                "retrace-proc:retrace-main": "Retrace (main)"
            ],
            totalDuration: 10
        )

        XCTAssertEqual(rows.map(\.id), [
            "bundle:io.retrace.app",
            "retrace-proc:retrace-main"
        ])
        XCTAssertEqual(rows[0].currentBytes, 300)
        XCTAssertEqual(rows[0].averageBytes, 240)
        XCTAssertEqual(rows[0].peakBytes, 420)
        XCTAssertEqual(rows[1].currentBytes, 120)
        XCTAssertEqual(rows[1].averageBytes, 60)
        XCTAssertEqual(rows[1].peakBytes, 180)
    }

    func testBuildMemoryRowsSortsByAverageThenCurrentThenPeak() {
        let rows = ProcessCPUDisplayMetrics.buildMemoryRows(
            currentBytesByKey: [
                "a": 100,
                "b": 140,
                "c": 100
            ],
            memoryByteSecondsByKey: [
                "a": 2_000,
                "b": 2_000,
                "c": 1_000
            ],
            peakBytesByKey: [
                "a": 150,
                "b": 120,
                "c": 300
            ],
            displayNamesByKey: [
                "a": "A",
                "b": "B",
                "c": "C"
            ],
            totalDuration: 10
        )

        XCTAssertEqual(rows.map(\.id), ["b", "a", "c"])
        XCTAssertEqual(rows[0].averageBytes, 200)
        XCTAssertEqual(rows[1].averageBytes, 200)
        XCTAssertEqual(rows[0].currentBytes, 140)
        XCTAssertEqual(rows[1].currentBytes, 100)
    }

    func testBuildRetraceMemoryAttributionRowsGroupsFamiliesAndShortensChildren() {
        let rows = ProcessCPUDisplayMetrics.buildRetraceMemoryAttributionRows(
            currentBytesByComponent: [
                "processing.extract.handoffObservedResidual": 320,
                "processing.extract.ocrCallResidual": 80,
                "storage.videoEncoding.videoToolboxHeap": 220
            ],
            memoryByteSecondsByComponent: [
                "processing.extract.handoffObservedResidual": 2_400,
                "processing.extract.ocrCallResidual": 800,
                "storage.videoEncoding.videoToolboxHeap": 1_800
            ],
            peakBytesByComponent: [
                "processing.extract.handoffObservedResidual": 360,
                "processing.extract.ocrCallResidual": 120,
                "storage.videoEncoding.videoToolboxHeap": 260
            ],
            peakBytesByFamily: [
                "processing.extract": 420,
                "storage.videoEncoding": 260
            ],
            totalDuration: 10
        )

        XCTAssertEqual(rows.families.map(\.id), [
            "processing.extract",
            "storage.videoEncoding"
        ])
        XCTAssertEqual(rows.families[0].currentBytes, 400)
        XCTAssertEqual(rows.families[0].averageBytes, 320)
        XCTAssertEqual(rows.families[0].peakBytes, 420)

        let extractChildren = rows.childrenByFamily["processing.extract"]
        XCTAssertEqual(extractChildren?.map(\.id), [
            "processing.extract.handoffObservedResidual",
            "processing.extract.ocrCallResidual"
        ])
        XCTAssertEqual(extractChildren?.map(\.name), [
            "handoffObservedResidual",
            "ocrCallResidual"
        ])
    }

    func testBuildRetraceMemoryAttributionRowsIncludesReadableUnattributedBucket() {
        let rows = ProcessCPUDisplayMetrics.buildRetraceMemoryAttributionRows(
            currentBytesByComponent: [
                "memory.unattributed.total": 512,
                "storage.videoEncoding.videoToolboxHeap": 220
            ],
            memoryByteSecondsByComponent: [
                "memory.unattributed.total": 5_120,
                "storage.videoEncoding.videoToolboxHeap": 1_800
            ],
            peakBytesByComponent: [
                "memory.unattributed.total": 768,
                "storage.videoEncoding.videoToolboxHeap": 260
            ],
            peakBytesByFamily: [
                "memory.unattributed": 768,
                "storage.videoEncoding": 260
            ],
            totalDuration: 10
        )

        XCTAssertEqual(rows.families.map(\.id), [
            "memory.unattributed",
            "storage.videoEncoding"
        ])
        XCTAssertEqual(rows.families.first?.name, "Unattributed")
        XCTAssertEqual(rows.childrenByFamily["memory.unattributed"]?.map(\.name), ["unattributed"])
    }

    func testMemoryLedgerFamilyKeyUsesFirstTwoSegments() {
        XCTAssertEqual(
            ProcessCPUDisplayMetrics.memoryLedgerFamilyKey(for: "processing.ocr.regionRuntimeResidual"),
            "processing.ocr"
        )
        XCTAssertEqual(
            ProcessCPUDisplayMetrics.memoryLedgerFamilyKey(for: "storage.videoEncoding.videoToolboxHeap"),
            "storage.videoEncoding"
        )
        XCTAssertEqual(
            ProcessCPUDisplayMetrics.memoryLedgerFamilyKey(for: "unscoped"),
            "unscoped"
        )
    }

    func testProcessMemoryCardPresentationPinsRetraceRowWhenOutsideVisiblePage() {
        let retraceRowID = "bundle:io.retrace.app"
        var topRows: [ProcessMemoryRow] = []
        topRows.reserveCapacity(11)
        for index in 1...11 {
            topRows.append(
                makeMemoryRow(
                    id: index == 11 ? retraceRowID : "bundle:app.\(index)",
                    name: index == 11 ? "Retrace" : "App \(index)",
                    currentBytes: UInt64(100 + index),
                    averageBytes: UInt64(90 + index),
                    peakBytes: UInt64(120 + index)
                )
            )
        }
        let snapshot = makeMemorySnapshot(
            topRows: topRows,
            retraceGroupKey: retraceRowID
        )

        let displayed = ProcessMemoryCardPresentation.buildDisplayedRows(
            from: snapshot,
            visibleRows: 10,
            isRetraceExpanded: false,
            expandedAttributionFamilyIDs: []
        )

        XCTAssertEqual(displayed.count, 10)
        XCTAssertEqual(displayed.last?.row.id, retraceRowID)
        XCTAssertEqual(displayed.last?.rank, 11)
        XCTAssertTrue(displayed.last?.isPinnedRetrace ?? false)
    }

    func testProcessMemoryCardPresentationAppendsExpandedFamiliesAndChildrenAfterRetrace() {
        let retraceRowID = "bundle:io.retrace.app"
        let familyID = "processing.extract"
        let snapshot = makeMemorySnapshot(
            topRows: [
                makeMemoryRow(id: retraceRowID, name: "Retrace", currentBytes: 900, averageBytes: 800, peakBytes: 950),
                makeMemoryRow(id: "bundle:com.apple.Safari", name: "Safari", currentBytes: 400, averageBytes: 380, peakBytes: 430)
            ],
            retraceGroupKey: retraceRowID,
            families: [
                makeMemoryRow(id: familyID, name: "Processing Extract", currentBytes: 300, averageBytes: 280, peakBytes: 320)
            ],
            childrenByFamily: [
                familyID: [
                    makeMemoryRow(
                        id: "processing.extract.ocrCallResidual",
                        name: "ocrCallResidual",
                        currentBytes: 120,
                        averageBytes: 110,
                        peakBytes: 140
                    )
                ]
            ]
        )

        let displayed = ProcessMemoryCardPresentation.buildDisplayedRows(
            from: snapshot,
            visibleRows: 10,
            isRetraceExpanded: true,
            expandedAttributionFamilyIDs: [familyID]
        )

        XCTAssertEqual(displayed.map(\.id), [
            retraceRowID,
            "retraceFamily.processing.extract",
            "retraceComponent.processing.extract.processing.extract.ocrCallResidual",
            "bundle:com.apple.Safari"
        ])
    }
}

private func makeMemoryRow(
    id: String,
    name: String,
    currentBytes: UInt64,
    averageBytes: UInt64,
    peakBytes: UInt64
) -> ProcessMemoryRow {
    ProcessMemoryRow(
        id: id,
        name: name,
        currentBytes: currentBytes,
        averageBytes: averageBytes,
        peakBytes: peakBytes,
        currentSharePercent: 0,
        averageSharePercent: 0
    )
}

private func makeMemorySnapshot(
    topRows: [ProcessMemoryRow],
    retraceGroupKey: String?,
    families: [ProcessMemoryRow] = [],
    childrenByFamily: [String: [ProcessMemoryRow]] = [:]
) -> ProcessCPUSnapshot {
    ProcessCPUSnapshot(
        sampleDurationSeconds: 10,
        peakInstantPercent: 0,
        peakCapacityPercent: 0,
        averagePercent: 0,
        capacityPercent: 0,
        trackedSharePercent: 0,
        logicalCoreCount: 10,
        retraceCPUSeconds: 0,
        totalTrackedCPUSeconds: 0,
        retraceEnergyJoules: 0,
        totalTrackedEnergyJoules: 0,
        retraceRank: nil,
        retraceGroupKey: retraceGroupKey,
        peakPercentByGroup: [:],
        peakPowerWattsByGroup: [:],
        topProcesses: [],
        totalTrackedCurrentResidentBytes: topRows.reduce(0) { $0 + $1.currentBytes },
        totalTrackedAverageResidentBytes: topRows.reduce(0) { $0 + $1.averageBytes },
        peakResidentBytesByGroup: [:],
        topMemoryProcesses: topRows,
        topRetraceChildMemoryProcesses: [],
        topRetraceMemoryAttributionFamilies: families,
        retraceMemoryAttributionChildrenByFamily: childrenByFamily,
        latestSampleTimestamp: nil
    )
}
