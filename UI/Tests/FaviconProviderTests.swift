import XCTest
import AppKit
@testable import Retrace

@MainActor
final class FaviconProviderDiskCacheTests: XCTestCase {
    func testFaviconSynchronousLookupDoesNotReadDisk() async throws {
        let fileManager = FileManager.default
        let storageRootURL = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: storageRootURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: storageRootURL) }

        let provider = FaviconProvider(storageRoot: storageRootURL.path)
        let domain = "example.com"
        let cacheFileURL = FaviconProvider
            .cacheDirectoryURL(storageRoot: storageRootURL.path)
            .appendingPathComponent("\(domain).png")
        try makeFaviconPNGData().write(to: cacheFileURL, options: .atomic)

        XCTAssertNil(provider.favicon(for: domain))

        let loadExpectation = expectation(description: "load favicon from disk")
        provider.loadFaviconIfNeeded(for: domain) { image in
            XCTAssertNotNil(image)
            loadExpectation.fulfill()
        }

        await fulfillment(of: [loadExpectation], timeout: 2)
        XCTAssertNotNil(provider.favicon(for: domain))
    }

    private func makeFaviconPNGData() throws -> Data {
        let size = NSSize(width: 16, height: 16)
        let image = NSImage(size: size)

        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
        image.unlockFocus()

        let tiffData = try XCTUnwrap(image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiffData))
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }
}
