import XCTest
@testable import Capture
import CoreGraphics

final class ConferenceROIPlannerTests: XCTestCase {
    func testLargeBaseRegionUsesFullPassPlusOverlapping2x2AndCenterSquare() {
        let requestRegions = ConferenceFaceBlurProcessor.detectionRequestRegions(
            baseRegionOfInterest: nil,
            imageWidth: 1920,
            imageHeight: 1080,
            configuration: .production
        )

        XCTAssertEqual(requestRegions.count, 6)
        XCTAssertEqual(requestRegions.first, CGRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertTrue(requestRegions.contains(where: {
            abs($0.minX - 0.35) < 0.0001 &&
                abs($0.minY - 0.35) < 0.0001 &&
                abs($0.width - 0.30) < 0.0001 &&
                abs($0.height - 0.30) < 0.0001
        }))
    }

    func testSmallBaseRegionStaysSinglePass() {
        let requestRegions = ConferenceFaceBlurProcessor.detectionRequestRegions(
            baseRegionOfInterest: CGRect(x: 0.20, y: 0.20, width: 0.16, height: 0.14),
            imageWidth: 1920,
            imageHeight: 1080,
            configuration: .production
        )

        XCTAssertEqual(requestRegions.count, 1)
        XCTAssertEqual(requestRegions[0].minX, 0.20, accuracy: 0.0001)
        XCTAssertEqual(requestRegions[0].minY, 0.20, accuracy: 0.0001)
        XCTAssertEqual(requestRegions[0].width, 0.16, accuracy: 0.0001)
        XCTAssertEqual(requestRegions[0].height, 0.14, accuracy: 0.0001)
    }

    func testRemapDetectedRectFromROIDoesNotDoubleScaleVisionBoundingBoxes() {
        let remappedRect = ConferenceFaceBlurProcessor.remapDetectedRectFromRegionOfInterest(
            CGRect(x: 0.10, y: 0.20, width: 0.30, height: 0.40),
            regionOfInterest: CGRect(x: 0.25, y: 0.40, width: 0.50, height: 0.20)
        )

        XCTAssertNotNil(remappedRect)
        if let remappedRect {
            XCTAssertEqual(remappedRect.minX, 0.10, accuracy: 0.0001)
            XCTAssertEqual(remappedRect.minY, 0.20, accuracy: 0.0001)
            XCTAssertEqual(remappedRect.width, 0.30, accuracy: 0.0001)
            XCTAssertEqual(remappedRect.height, 0.40, accuracy: 0.0001)
        }
    }

    func testMergedDetectionsUnionOverlappingDuplicates() {
        let mergedRects = ConferenceFaceBlurProcessor.mergedDetections(
            [
                CGRect(x: 0.20, y: 0.20, width: 0.10, height: 0.10),
                CGRect(x: 0.205, y: 0.205, width: 0.11, height: 0.11),
                CGRect(x: 0.70, y: 0.20, width: 0.08, height: 0.08),
            ],
            overlapThreshold: 0.60
        )

        XCTAssertEqual(mergedRects.count, 2)
        XCTAssertTrue(mergedRects.contains(where: { $0.minX <= 0.20 && $0.maxX >= 0.315 }))
        XCTAssertTrue(mergedRects.contains(where: { abs($0.minX - 0.70) < 0.0001 }))
    }

    func testSeparateOverlappingWindowROIsRemainDistinct() {
        let displayBounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let mainWindowBounds = CGRect(x: 200, y: 120, width: 900, height: 700)
        let overlayWindowBounds = CGRect(x: 800, y: 400, width: 700, height: 500)

        let mainWindowROI = CGWindowListCapture.ConferenceROIPlanner.normalizedVisionRegionOfInterest(
            windowBounds: mainWindowBounds,
            displayBounds: displayBounds
        )
        let overlayWindowROI = CGWindowListCapture.ConferenceROIPlanner.normalizedVisionRegionOfInterest(
            windowBounds: overlayWindowBounds,
            displayBounds: displayBounds
        )
        XCTAssertNotNil(mainWindowROI)
        XCTAssertNotNil(overlayWindowROI)
        if let mainWindowROI, let overlayWindowROI {
            XCTAssertNotEqual(mainWindowROI, overlayWindowROI)
            XCTAssertTrue(mainWindowROI.intersects(overlayWindowROI))
        }
    }

    func testSeparateNonOverlappingWindowROIsRemainDistinct() {
        let displayBounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let firstWindowBounds = CGRect(x: 80, y: 120, width: 420, height: 320)
        let secondWindowBounds = CGRect(x: 1300, y: 620, width: 420, height: 320)

        let firstWindowROI = CGWindowListCapture.ConferenceROIPlanner.normalizedVisionRegionOfInterest(
            windowBounds: firstWindowBounds,
            displayBounds: displayBounds
        )
        let secondWindowROI = CGWindowListCapture.ConferenceROIPlanner.normalizedVisionRegionOfInterest(
            windowBounds: secondWindowBounds,
            displayBounds: displayBounds
        )

        XCTAssertNotNil(firstWindowROI)
        XCTAssertNotNil(secondWindowROI)
        if let firstWindowROI, let secondWindowROI {
            XCTAssertNotEqual(firstWindowROI, secondWindowROI)
            XCTAssertFalse(firstWindowROI.intersects(secondWindowROI))
        }
    }

    func testNormalizedVisionRegionClampsToDisplayIntersection() {
        let displayBounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let partiallyOffscreen = CGRect(x: -200, y: -100, width: 600, height: 400)

        let roi = CGWindowListCapture.ConferenceROIPlanner.normalizedVisionRegionOfInterest(
            windowBounds: partiallyOffscreen,
            displayBounds: displayBounds
        )

        XCTAssertNotNil(roi)
        if let roi {
            XCTAssertGreaterThanOrEqual(roi.minX, 0)
            XCTAssertGreaterThanOrEqual(roi.minY, 0)
            XCTAssertLessThanOrEqual(roi.maxX, 1)
            XCTAssertLessThanOrEqual(roi.maxY, 1)
            XCTAssertGreaterThan(roi.width, 0)
            XCTAssertGreaterThan(roi.height, 0)
        }
    }

    func testEquivalentBoundsProduceEquivalentROIsWhenComputedSeparately() {
        let displayBounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let bounds = CGRect(x: 160, y: 140, width: 480, height: 360)

        let firstROI = CGWindowListCapture.ConferenceROIPlanner.normalizedVisionRegionOfInterest(
            windowBounds: bounds,
            displayBounds: displayBounds
        )
        let secondROI = CGWindowListCapture.ConferenceROIPlanner.normalizedVisionRegionOfInterest(
            windowBounds: bounds,
            displayBounds: displayBounds
        )

        XCTAssertEqual(firstROI, secondROI)
    }

    func testVisibleWindowIDsExcludeFullyOccludedBackgroundConferenceWindow() {
        let displayBounds = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let orderedWindows = [
            CGWindowListCapture.ConferenceROIPlanner.WindowVisibilityCandidate(
                windowID: 10,
                windowBounds: CGRect(x: 180, y: 140, width: 720, height: 480)
            ),
            CGWindowListCapture.ConferenceROIPlanner.WindowVisibilityCandidate(
                windowID: 20,
                windowBounds: CGRect(x: 180, y: 140, width: 720, height: 480)
            )
        ]

        let visibleWindowIDs = CGWindowListCapture.ConferenceROIPlanner.visibleWindowIDs(
            from: orderedWindows,
            displayBounds: displayBounds
        )

        XCTAssertEqual(visibleWindowIDs, [10])
    }

    func testVisibleWindowIDsKeepPartiallyVisibleBackgroundConferenceWindow() {
        let displayBounds = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let orderedWindows = [
            CGWindowListCapture.ConferenceROIPlanner.WindowVisibilityCandidate(
                windowID: 10,
                windowBounds: CGRect(x: 280, y: 180, width: 420, height: 260)
            ),
            CGWindowListCapture.ConferenceROIPlanner.WindowVisibilityCandidate(
                windowID: 20,
                windowBounds: CGRect(x: 180, y: 140, width: 720, height: 480)
            )
        ]

        let visibleWindowIDs = CGWindowListCapture.ConferenceROIPlanner.visibleWindowIDs(
            from: orderedWindows,
            displayBounds: displayBounds
        )

        XCTAssertEqual(visibleWindowIDs, [10, 20])
    }

    func testMissionControlDockSurfaceIsNotUsedAsOcclusionBlocker() {
        let displayBounds = CGRect(x: 0, y: 0, width: 1512, height: 982)

        XCTAssertFalse(
            CGWindowListCapture.ConferenceROIPlanner.shouldUseAsOcclusionBlocker(
                ownerName: "Dock",
                appBundleID: "com.apple.dock",
                windowLayer: 20,
                windowBounds: displayBounds,
                displayBounds: displayBounds
            )
        )
    }

    func testVisibleWindowIDsIgnoreNonOccludingMissionControlDockSurface() {
        let displayBounds = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let orderedWindows = [
            CGWindowListCapture.ConferenceROIPlanner.WindowVisibilityCandidate(
                windowID: 8,
                windowBounds: displayBounds,
                occludesBackgroundWindows: false
            ),
            CGWindowListCapture.ConferenceROIPlanner.WindowVisibilityCandidate(
                windowID: 15740,
                windowBounds: CGRect(x: 515, y: 278, width: 986, height: 618)
            ),
            CGWindowListCapture.ConferenceROIPlanner.WindowVisibilityCandidate(
                windowID: 34933,
                windowBounds: CGRect(x: 142, y: 326, width: 986, height: 618)
            )
        ]

        let visibleWindowIDs = CGWindowListCapture.ConferenceROIPlanner.visibleWindowIDs(
            from: orderedWindows,
            displayBounds: displayBounds
        )

        XCTAssertEqual(visibleWindowIDs, [8, 15740, 34933])
    }

}
