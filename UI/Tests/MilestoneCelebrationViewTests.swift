import XCTest
@testable import Retrace

final class MilestoneCelebrationViewTests: XCTestCase {
    func testTenHourMilestoneUsesContinueOnlyActionLayout() {
        XCTAssertEqual(
            MilestoneCelebrationView.actionLayout(for: .tenHours),
            .continueOnly
        )
        XCTAssertEqual(
            MilestoneCelebrationView.singleButtonAction(for: .tenHours),
            .maybeLater
        )
    }

    func testHundredAndThousandHourMilestonesKeepSupportPromptLayout() {
        XCTAssertEqual(
            MilestoneCelebrationView.actionLayout(for: .hundredHours),
            .maybeLaterAndSupport
        )
        XCTAssertEqual(
            MilestoneCelebrationView.actionLayout(for: .thousandHours),
            .maybeLaterAndSupport
        )
    }

    func testTenThousandHourMilestoneKeepsCelebrateOnlyLayout() {
        XCTAssertEqual(
            MilestoneCelebrationView.actionLayout(for: .tenThousandHours),
            .acceptCrown
        )
        XCTAssertEqual(
            MilestoneCelebrationView.singleButtonAction(for: .tenThousandHours),
            .dismiss
        )
    }
}
