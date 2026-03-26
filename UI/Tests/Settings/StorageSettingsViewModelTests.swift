import XCTest
@testable import Retrace

final class StorageSettingsViewModelTests: XCTestCase {
    func testNormalizeRewindFolderPathLeavesDirectoryUntouched() {
        let directory = "/tmp/Rewind"

        XCTAssertEqual(
            StorageSettingsViewModel.normalizeRewindFolderPath(directory),
            directory
        )
    }

    func testNormalizeRewindFolderPathStripsSQLiteFilename() {
        XCTAssertEqual(
            StorageSettingsViewModel.normalizeRewindFolderPath("/tmp/Rewind/db-enc.sqlite3"),
            "/tmp/Rewind"
        )
    }

    func testNormalizeRewindFolderPathStripsGenericDatabaseFilename() {
        XCTAssertEqual(
            StorageSettingsViewModel.normalizeRewindFolderPath("/tmp/Rewind/archive.db"),
            "/tmp/Rewind"
        )
    }
}
