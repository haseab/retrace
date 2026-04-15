import CoreGraphics
import XCTest
@testable import Retrace

final class TimelineFilterDropdownOverlaySupportTests: XCTestCase {
    func testNormalizedMeasuredSizeRoundsToHalfPoints() {
        XCTAssertEqual(
            TimelineFilterDropdownOverlaySupport.normalizedMeasuredSize(
                CGSize(width: 220.24, height: 159.76)
            ),
            CGSize(width: 220, height: 160)
        )
    }

    func testShouldUpdateMeasuredSizeIgnoresSubEpsilonJitter() {
        XCTAssertFalse(
            TimelineFilterDropdownOverlaySupport.shouldUpdateMeasuredSize(
                currentSize: CGSize(width: 220, height: 160),
                newSize: CGSize(width: 220.25, height: 160.25)
            )
        )
    }

    func testEstimatedDropdownSizeExpandsDateRangeWhenCalendarEditing() {
        XCTAssertEqual(
            TimelineFilterDropdownOverlaySupport.estimatedDropdownSize(
                for: .dateRange,
                isDateRangeCalendarEditing: false
            ),
            CGSize(width: 300, height: 250)
        )
        XCTAssertEqual(
            TimelineFilterDropdownOverlaySupport.estimatedDropdownSize(
                for: .dateRange,
                isDateRangeCalendarEditing: true
            ),
            CGSize(width: 300, height: 430)
        )
    }

    func testDropdownOriginOpensUpwardWhenBelowSpaceIsTight() {
        let origin = TimelineFilterDropdownOverlaySupport.dropdownOrigin(
            containerSize: CGSize(width: 400, height: 400),
            anchor: CGRect(x: 80, y: 340, width: 120, height: 40),
            dropdownSize: CGSize(width: 220, height: 120),
            activeDropdown: .comments,
            isDateRangeCalendarEditing: false
        )

        XCTAssertEqual(origin, CGPoint(x: 80, y: 212))
    }

    func testDropdownOriginKeepsDateRangeBottomStableWhileCalendarExpands() {
        let anchor = CGRect(x: 60, y: 180, width: 120, height: 38)
        let collapsedOrigin = TimelineFilterDropdownOverlaySupport.dropdownOrigin(
            containerSize: CGSize(width: 600, height: 600),
            anchor: anchor,
            dropdownSize: CGSize(width: 300, height: 250),
            activeDropdown: .dateRange,
            isDateRangeCalendarEditing: false
        )
        let expandedOrigin = TimelineFilterDropdownOverlaySupport.dropdownOrigin(
            containerSize: CGSize(width: 600, height: 600),
            anchor: anchor,
            dropdownSize: CGSize(width: 300, height: 430),
            activeDropdown: .dateRange,
            isDateRangeCalendarEditing: true
        )

        XCTAssertEqual(collapsedOrigin.x, expandedOrigin.x)
        XCTAssertEqual(collapsedOrigin.y + 250, expandedOrigin.y + 430)
    }

    func testAdvanceNavigationActionUsesNextDropdownAnchor() {
        let action = TimelineFilterDropdownOverlaySupport.makeAdvanceNavigationAction(
            from: .comments,
            anchorFrameProvider: { dropdown in
                XCTAssertEqual(dropdown, .dateRange)
                return CGRect(x: 12, y: 24, width: 36, height: 48)
            }
        )

        XCTAssertEqual(
            action,
            .showDropdown(.dateRange, anchorFrame: CGRect(x: 12, y: 24, width: 36, height: 48))
        )
    }

    func testAdvanceNavigationActionReturnsNilForDropdownWithoutNextStep() {
        XCTAssertNil(
            TimelineFilterDropdownOverlaySupport.makeAdvanceNavigationAction(
                from: .apps,
                anchorFrameProvider: { _ in
                    XCTFail("Anchor should not be requested without a next dropdown")
                    return .zero
                }
            )
        )
    }
}
