import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import ImageIO
import Shared
import XCTest
@testable import Storage

final class EncoderFileInspectionTests: XCTestCase {
    func testFileInspectionDistinguishesEmptyExistingAndMissingOutput() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("video.mp4")
        XCTAssertNil(try HEVCEncoder.outputFileSizeIfPresent(at: url))
        try Data().write(to: url)
        XCTAssertEqual(try HEVCEncoder.outputFileSizeIfPresent(at: url), 0)
        try Data(repeating: 42, count: 4_096).write(to: url)
        XCTAssertEqual(try HEVCEncoder.outputFileSizeIfPresent(at: url), 4_096)
        try FileManager.default.removeItem(at: url)
        XCTAssertNil(try HEVCEncoder.outputFileSizeIfPresent(at: url))
    }

    func testPermissionFailureIsNotMisclassifiedAsDeletedFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }
        let url = root.appendingPathComponent("video.mp4")
        try Data([1,2,3]).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: root.path)
        XCTAssertThrowsError(try HEVCEncoder.outputFileSizeIfPresent(at: url))
    }

    func testEncoderRecoversFromOutputDeletionAndProducesReadableVideo() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let encoder = HEVCEncoder()
        let output = root.appendingPathComponent("video.mp4")
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(repository.appendingPathComponent("UI/Assets.xcassets/InPageURLInstructions.imageset/safari_instructions.png") as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let context = try XCTUnwrap(CGContext(data: nil, width: 320, height: 240, bitsPerComponent: 8, bytesPerRow: 1280,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 320, height: 240))
        let pixels = try BGRAImageUtilities.makeData(from: try XCTUnwrap(context.makeImage()))
        let frame = CapturedFrame(imageData: pixels, width: 320, height: 240, bytesPerRow: 1280)
        try await encoder.initialize(width: 320, height: 240, config: .default, outputURL: output, segmentStartTime: Date())
        for index in 0..<10 {
            if index == 4 { try FileManager.default.removeItem(at: output) }
            let pixelBuffer = try await encoder.makePixelBuffer(from: frame)
            try await encoder.encode(pixelBuffer: pixelBuffer, timestamp: CMTime(seconds: Double(index), preferredTimescale: 600))
        }
        try await encoder.finalize()
        let size = try XCTUnwrap(HEVCEncoder.outputFileSizeIfPresent(at: output))
        XCTAssertGreaterThan(size, 0)
        let asset = AVURLAsset(url: output)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertEqual(tracks.count, 1)
        let reader = try AVAssetReader(asset: asset)
        let trackOutput = AVAssetReaderTrackOutput(track: try XCTUnwrap(tracks.first), outputSettings: nil)
        reader.add(trackOutput)
        XCTAssertTrue(reader.startReading())
        XCTAssertNotNil(trackOutput.copyNextSampleBuffer())
        reader.cancelReading()
    }
}
