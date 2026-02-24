import XCTest
@testable import Retrace

final class BuildInfoFormattingTests: XCTestCase {
    func testDisplayVersionForReleaseBuild() {
        XCTAssertEqual(
            BuildInfo.makeDisplayVersion(version: "1.2.3", isDevBuild: false, gitCommit: "abc1234"),
            "v1.2.3"
        )
    }

    func testDisplayVersionForDevBuildIncludesCommitWhenKnown() {
        XCTAssertEqual(
            BuildInfo.makeDisplayVersion(version: "1.2.3", isDevBuild: true, gitCommit: "abc1234"),
            "v1.2.3-dev · abc1234"
        )
    }

    func testDisplayVersionForDevBuildOmitsUnknownCommit() {
        XCTAssertEqual(
            BuildInfo.makeDisplayVersion(version: "1.2.3", isDevBuild: true, gitCommit: "unknown"),
            "v1.2.3-dev"
        )
    }

    func testFullVersionForReleaseBuild() {
        XCTAssertEqual(
            BuildInfo.makeFullVersion(
                version: "1.2.3",
                buildNumber: "99",
                isDevBuild: false,
                gitCommit: "abc1234",
                gitBranch: "feature/xyz"
            ),
            "1.2.3 (99)"
        )
    }

    func testFullVersionForDevBuildIncludesCommitAndBranchWhenKnown() {
        XCTAssertEqual(
            BuildInfo.makeFullVersion(
                version: "1.2.3",
                buildNumber: "99",
                isDevBuild: true,
                gitCommit: "abc1234",
                gitBranch: "feature/xyz"
            ),
            "1.2.3-dev · abc1234 (feature/xyz)"
        )
    }

    func testDisplayBranchShownOnlyForDevWithKnownBranch() {
        XCTAssertEqual(
            BuildInfo.makeDisplayBranch(isDevBuild: true, gitBranch: "feature/xyz"),
            "feature/xyz"
        )
        XCTAssertNil(BuildInfo.makeDisplayBranch(isDevBuild: false, gitBranch: "feature/xyz"))
        XCTAssertNil(BuildInfo.makeDisplayBranch(isDevBuild: true, gitBranch: "unknown"))
    }

    func testCommitURLRequiresCommitAndFork() {
        XCTAssertEqual(
            BuildInfo.makeCommitURL(gitCommitFull: "abcdef1234", forkName: "haseab/retrace")?.absoluteString,
            "https://github.com/haseab/retrace/commit/abcdef1234"
        )
        XCTAssertEqual(
            BuildInfo.makeCommitURL(gitCommitFull: "abcdef1234", forkName: "git@github.com:haseab/retrace")?.absoluteString,
            "https://github.com/haseab/retrace/commit/abcdef1234"
        )
        XCTAssertEqual(
            BuildInfo.makeCommitURL(gitCommitFull: "abcdef1234", forkName: "https://github.com/haseab/retrace.git")?.absoluteString,
            "https://github.com/haseab/retrace/commit/abcdef1234"
        )
        XCTAssertNil(BuildInfo.makeCommitURL(gitCommitFull: "unknown", forkName: "haseab/retrace"))
        XCTAssertNil(BuildInfo.makeCommitURL(gitCommitFull: "abcdef1234", forkName: ""))
    }
}

final class UpdaterManagerVersionResolutionTests: XCTestCase {
    func testResolveBundleVersionValueUsesConcreteBundleValue() {
        XCTAssertEqual(
            UpdaterManager.resolveBundleVersionValue("1.2.3", fallback: "0.0.0"),
            "1.2.3"
        )
    }

    func testResolveBundleVersionValueFallsBackForPlaceholder() {
        XCTAssertEqual(
            UpdaterManager.resolveBundleVersionValue("$(MARKETING_VERSION)", fallback: "0.0.0"),
            "0.0.0"
        )
    }

    func testResolveBundleVersionValueFallsBackForNilOrEmpty() {
        XCTAssertEqual(UpdaterManager.resolveBundleVersionValue(nil, fallback: "0.0.0"), "0.0.0")
        XCTAssertEqual(UpdaterManager.resolveBundleVersionValue("", fallback: "0.0.0"), "0.0.0")
    }
}
