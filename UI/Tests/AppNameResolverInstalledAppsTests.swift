import XCTest
@testable import Retrace

final class AppNameResolverInstalledAppsTests: XCTestCase {
    func testInstalledAppsDeduplicatesDuplicateBundleIDsAcrossScanFolders() throws {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let primaryFolderURL = rootURL.appendingPathComponent("Applications", isDirectory: true)
        let secondaryFolderURL = rootURL.appendingPathComponent("Applications-2", isDirectory: true)

        try fileManager.createDirectory(at: primaryFolderURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: secondaryFolderURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: rootURL) }

        try createAppBundle(
            named: "Safari Primary",
            bundleID: "com.apple.Safari",
            displayName: "Safari Primary",
            in: primaryFolderURL
        )
        try createAppBundle(
            named: "Safari Secondary",
            bundleID: "com.apple.Safari",
            displayName: "Safari Secondary",
            in: secondaryFolderURL
        )
        try createAppBundle(
            named: "Chrome",
            bundleID: "com.google.Chrome",
            displayName: "Chrome",
            in: secondaryFolderURL
        )

        let apps = AppNameResolver.installedApps(
            in: [primaryFolderURL, secondaryFolderURL],
            fileManager: fileManager
        )

        XCTAssertEqual(apps.map(\.bundleID), ["com.apple.Safari", "com.google.Chrome"])
        XCTAssertEqual(apps.map(\.name), ["Safari Primary", "Chrome"])
    }

    private func createAppBundle(
        named appName: String,
        bundleID: String,
        displayName: String,
        in folderURL: URL
    ) throws {
        let appURL = folderURL.appendingPathComponent("\(appName).app", isDirectory: true)
        let contentsURL = appURL.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)

        let plist: [String: Any] = [
            "CFBundleIdentifier": bundleID,
            "CFBundleDisplayName": displayName
        ]
        let plistData = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try plistData.write(to: contentsURL.appendingPathComponent("Info.plist"))
    }
}
