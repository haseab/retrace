import XCTest
import Shared
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

    func testProcessMemorySummaryCardBuildsExpansionScrollTargetForFirstCategoryRow() {
        let target = ProcessMemorySummaryCard.retraceExpansionScrollTarget(
            firstCategoryID: "explicit"
        )

        XCTAssertEqual(
            target,
            ProcessMemorySummaryCard.MemoryProcessScrollTarget(
                id: "retraceCategory.explicit",
                anchorY: 0
            )
        )
    }

    func testProcessMemorySummaryCardReturnsNilExpansionScrollTargetWithoutCategory() {
        XCTAssertNil(
            ProcessMemorySummaryCard.retraceExpansionScrollTarget(firstCategoryID: nil)
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

    func testBuildCategorizedRetraceMemoryAttributionTreeGroupsFamiliesAndShortensChildren() {
        let tree = ProcessCPUDisplayMetrics.buildCategorizedRetraceMemoryAttributionTree(
            currentBytesByComponent: [
                "processing.extract.handoffObservedResidual": 320,
                "processing.extract.ocrRegionPayload": 80,
                "storage.videoEncoding.videoToolboxHeap": 220
            ],
            componentCategoriesByKey: [
                "processing.extract.handoffObservedResidual": .inferred,
                "processing.extract.ocrRegionPayload": .explicit,
                "storage.videoEncoding.videoToolboxHeap": .inferred
            ],
            memoryByteSecondsByComponent: [
                "processing.extract.handoffObservedResidual": 2_400,
                "processing.extract.ocrRegionPayload": 800,
                "storage.videoEncoding.videoToolboxHeap": 1_800
            ],
            peakBytesByComponent: [
                "processing.extract.handoffObservedResidual": 360,
                "processing.extract.ocrRegionPayload": 120,
                "storage.videoEncoding.videoToolboxHeap": 260
            ],
            componentSamples: [
                [
                    "processing.extract.handoffObservedResidual": 360,
                    "processing.extract.ocrRegionPayload": 120,
                    "storage.videoEncoding.videoToolboxHeap": 260
                ]
            ],
            totalDuration: 10
        )

        let explicitFamilies = tree.familiesByCategory[RetraceMemoryAttributionCategory.explicit.rawValue]
        let inferredFamilies = tree.familiesByCategory[RetraceMemoryAttributionCategory.inferred.rawValue]

        XCTAssertEqual(explicitFamilies?.map(\.id), ["processing.extract"])
        XCTAssertEqual(inferredFamilies?.map(\.id), [
            "processing.extract",
            "storage.videoEncoding"
        ])
        XCTAssertEqual(explicitFamilies?.first?.currentBytes, 80)
        XCTAssertEqual(explicitFamilies?.first?.averageBytes, 80)
        XCTAssertEqual(explicitFamilies?.first?.peakBytes, 120)

        let explicitExtractKey = ProcessCPUDisplayMetrics.retraceMemoryAttributionFamilyExpansionKey(
            categoryID: RetraceMemoryAttributionCategory.explicit.rawValue,
            familyID: "processing.extract"
        )
        let explicitExtractChildren = tree.componentsByCategoryFamily[explicitExtractKey]
        XCTAssertEqual(explicitExtractChildren?.map(\.id), [
            "processing.extract.ocrRegionPayload"
        ])
        XCTAssertEqual(explicitExtractChildren?.map(\.name), [
            "ocrRegionPayload"
        ])
    }

    func testBuildCategorizedRetraceMemoryAttributionTreeIncludesReadableUnattributedBucket() {
        let tree = ProcessCPUDisplayMetrics.buildCategorizedRetraceMemoryAttributionTree(
            currentBytesByComponent: [
                "memory.unattributed.total": 512,
                "storage.videoEncoding.videoToolboxHeap": 220
            ],
            componentCategoriesByKey: [
                "memory.unattributed.total": .unattributed,
                "storage.videoEncoding.videoToolboxHeap": .inferred
            ],
            memoryByteSecondsByComponent: [
                "memory.unattributed.total": 5_120,
                "storage.videoEncoding.videoToolboxHeap": 1_800
            ],
            peakBytesByComponent: [
                "memory.unattributed.total": 768,
                "storage.videoEncoding.videoToolboxHeap": 260
            ],
            componentSamples: [],
            totalDuration: 10
        )

        XCTAssertEqual(
            tree.familiesByCategory[RetraceMemoryAttributionCategory.unattributed.rawValue]?.map(\.id),
            ["memory.unattributed"]
        )
        XCTAssertEqual(
            tree.familiesByCategory[RetraceMemoryAttributionCategory.inferred.rawValue]?.map(\.id),
            ["storage.videoEncoding"]
        )

        let unattributedKey = ProcessCPUDisplayMetrics.retraceMemoryAttributionFamilyExpansionKey(
            categoryID: RetraceMemoryAttributionCategory.unattributed.rawValue,
            familyID: "memory.unattributed"
        )
        XCTAssertEqual(tree.componentsByCategoryFamily[unattributedKey]?.map(\.name), ["unattributed"])
    }

    func testBuildCategorizedRetraceMemoryAttributionTreeSeparatesExplicitInferredAndUnattributed() {
        let tree = ProcessCPUDisplayMetrics.buildCategorizedRetraceMemoryAttributionTree(
            currentBytesByComponent: [
                "processing.extract.ocrRegionPayload": 64,
                "processing.extract.handoffObservedResidual": 320,
                "storage.videoEncoding.videoToolboxHeap": 220,
                "memory.unattributed.total": 512
            ],
            componentCategoriesByKey: [
                "processing.extract.ocrRegionPayload": .explicit,
                "processing.extract.handoffObservedResidual": .inferred,
                "storage.videoEncoding.videoToolboxHeap": .inferred,
                "memory.unattributed.total": .unattributed
            ],
            memoryByteSecondsByComponent: [
                "processing.extract.ocrRegionPayload": 640,
                "processing.extract.handoffObservedResidual": 3_200,
                "storage.videoEncoding.videoToolboxHeap": 2_200,
                "memory.unattributed.total": 5_120
            ],
            peakBytesByComponent: [
                "processing.extract.ocrRegionPayload": 80,
                "processing.extract.handoffObservedResidual": 360,
                "storage.videoEncoding.videoToolboxHeap": 260,
                "memory.unattributed.total": 768
            ],
            componentSamples: [
                [
                    "processing.extract.ocrRegionPayload": 80,
                    "processing.extract.handoffObservedResidual": 300,
                    "storage.videoEncoding.videoToolboxHeap": 180,
                    "memory.unattributed.total": 400
                ],
                [
                    "processing.extract.ocrRegionPayload": 64,
                    "processing.extract.handoffObservedResidual": 320,
                    "storage.videoEncoding.videoToolboxHeap": 220,
                    "memory.unattributed.total": 512
                ]
            ],
            totalDuration: 10
        )

        XCTAssertEqual(tree.categories.map(\.id), ["explicit", "inferred", "unattributed"])
        XCTAssertEqual(tree.categories[0].currentBytes, 64)
        XCTAssertEqual(tree.categories[1].currentBytes, 540)
        XCTAssertEqual(tree.categories[2].currentBytes, 512)

        XCTAssertEqual(tree.familiesByCategory["explicit"]?.map(\.id), ["processing.extract"])
        XCTAssertEqual(tree.familiesByCategory["inferred"]?.map(\.id), [
            "processing.extract",
            "storage.videoEncoding"
        ])
        XCTAssertEqual(tree.familiesByCategory["unattributed"]?.map(\.id), ["memory.unattributed"])

        let explicitExtractKey = ProcessCPUDisplayMetrics.retraceMemoryAttributionFamilyExpansionKey(
            categoryID: "explicit",
            familyID: "processing.extract"
        )
        let inferredExtractKey = ProcessCPUDisplayMetrics.retraceMemoryAttributionFamilyExpansionKey(
            categoryID: "inferred",
            familyID: "processing.extract"
        )
        XCTAssertEqual(tree.componentsByCategoryFamily[explicitExtractKey]?.map(\.name), ["ocrRegionPayload"])
        XCTAssertEqual(tree.componentsByCategoryFamily[inferredExtractKey]?.map(\.name), ["handoffObservedResidual"])
    }

    func testBuildCategorizedRetraceMemoryAttributionTreeUsesProvidedCategoryMapInsteadOfKeyHeuristics() {
        let tree = ProcessCPUDisplayMetrics.buildCategorizedRetraceMemoryAttributionTree(
            currentBytesByComponent: [
                "custom.named.bucket": 96
            ],
            componentCategoriesByKey: [
                "custom.named.bucket": .inferred
            ],
            memoryByteSecondsByComponent: [
                "custom.named.bucket": 960
            ],
            peakBytesByComponent: [
                "custom.named.bucket": 128
            ],
            componentSamples: [
                ["custom.named.bucket": 128]
            ],
            totalDuration: 10
        )

        XCTAssertEqual(tree.familiesByCategory["inferred"]?.map(\.id), ["custom.named"])
        XCTAssertTrue(tree.familiesByCategory["explicit"]?.isEmpty ?? true)
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
            expandedAttributionCategoryIDs: [],
            expandedAttributionFamilyIDs: []
        )

        XCTAssertEqual(displayed.count, 10)
        XCTAssertEqual(displayed.last?.row.id, retraceRowID)
        XCTAssertEqual(displayed.last?.rank, 11)
        XCTAssertTrue(displayed.last?.isPinnedRetrace ?? false)
    }

    func testProcessMemoryCardPresentationAppendsExpandedCategoriesFamiliesAndChildrenAfterRetrace() {
        let retraceRowID = "bundle:io.retrace.app"
        let categoryID = "explicit"
        let familyID = "processing.extract"
        let snapshot = makeMemorySnapshot(
            topRows: [
                makeMemoryRow(id: retraceRowID, name: "Retrace", currentBytes: 900, averageBytes: 800, peakBytes: 950),
                makeMemoryRow(id: "bundle:com.apple.Safari", name: "Safari", currentBytes: 400, averageBytes: 380, peakBytes: 430)
            ],
            retraceGroupKey: retraceRowID,
            tree: RetraceMemoryAttributionTree(
                categories: [
                    makeMemoryRow(id: "explicit", name: "explicit", currentBytes: 300, averageBytes: 280, peakBytes: 320),
                    makeMemoryRow(id: "inferred", name: "inferred", currentBytes: 0, averageBytes: 0, peakBytes: 0),
                    makeMemoryRow(id: "unattributed", name: "unattributed", currentBytes: 0, averageBytes: 0, peakBytes: 0)
                ],
                familiesByCategory: [
                    categoryID: [
                        makeMemoryRow(id: familyID, name: "Processing Extract", currentBytes: 300, averageBytes: 280, peakBytes: 320)
                    ],
                    "inferred": [],
                    "unattributed": []
                ],
                componentsByCategoryFamily: [
                    ProcessCPUDisplayMetrics.retraceMemoryAttributionFamilyExpansionKey(
                        categoryID: categoryID,
                        familyID: familyID
                    ): [
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
        )

        let displayed = ProcessMemoryCardPresentation.buildDisplayedRows(
            from: snapshot,
            visibleRows: 10,
            isRetraceExpanded: true,
            expandedAttributionCategoryIDs: [categoryID],
            expandedAttributionFamilyIDs: [
                ProcessCPUDisplayMetrics.retraceMemoryAttributionFamilyExpansionKey(
                    categoryID: categoryID,
                    familyID: familyID
                )
            ]
        )

        XCTAssertEqual(displayed.map(\.id), [
            retraceRowID,
            "retraceCategory.explicit",
            "retraceFamily.explicit.processing.extract",
            "retraceComponent.explicit.processing.extract.processing.extract.ocrCallResidual",
            "retraceCategory.inferred",
            "retraceCategory.unattributed",
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
    tree: RetraceMemoryAttributionTree = .empty
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
        retraceMemoryAttributionTree: tree,
        latestSampleTimestamp: nil
    )
}
