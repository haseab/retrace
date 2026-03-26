import XCTest
@testable import Retrace

final class AdvancedSettingsViewModelTests: XCTestCase {
    func testBuildTypeTextUsesDevBuildLabel() {
        XCTAssertEqual(
            AdvancedSettingsViewModel.buildTypeText(isDevBuild: true),
            "Dev Build"
        )
    }

    func testShouldShowForkRowRequiresDevBuildAndForkName() {
        XCTAssertTrue(
            AdvancedSettingsViewModel.shouldShowForkRow(
                isDevBuild: true,
                forkName: "feature-branch"
            )
        )
        XCTAssertFalse(
            AdvancedSettingsViewModel.shouldShowForkRow(
                isDevBuild: false,
                forkName: "feature-branch"
            )
        )
        XCTAssertFalse(
            AdvancedSettingsViewModel.shouldShowForkRow(
                isDevBuild: true,
                forkName: ""
            )
        )
    }
}
