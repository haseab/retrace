import XCTest
import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Shared
@testable import Processing

/// Opt-in benchmark: measures what Vision's language-correction pass costs on the
/// production region-OCR path, replaying real captured frames through the same
/// `VisionOCR.recognizeTextRegionBased` entry point `ProcessingManager` uses.
///
/// It is paired -- both arms see byte-identical frames -- and runs the sequence in
/// OFF/ON/ON/OFF order so any monotonic thermal or load drift cancels. That is what
/// makes it trustworthy where the production log is not: log windows cannot be
/// matched for machine load, and the app only logs a `Region OCR:` line when it saved
/// >10% energy, so the logged tile counts are a censored sample.
///
/// Skipped unless RETRACE_BENCH_CHUNKS is set to a colon-separated list of chunk
/// video paths (they need an `.mp4` extension for AVFoundation to open them; symlink
/// the extensionless chunk files if necessary). Those files are read read-only and
/// nothing is written. Recognised text is never printed -- only aggregate counts --
/// because these frames are real screen contents.
///
///     RETRACE_BENCH_CHUNKS=/path/a.mp4:/path/b.mp4 RETRACE_BENCH_MAX_FRAMES=40 \
///         swift test --filter RegionOCRLanguageCorrectionBenchmark
final class RegionOCRLanguageCorrectionBenchmark: XCTestCase {

    private struct PassResult {
        var ocrMs: [Double] = []
        var changeMs: [Double] = []
        var mergeMs: [Double] = []
        var tiles: [Int] = []
        var totalTiles: Int = 0
        var chars: [Int] = []
        var text: [String] = []
    }

    func testRegionOCRLanguageCorrectionOnRealFrames() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let spec = env["RETRACE_BENCH_CHUNKS"], !spec.isEmpty else {
            throw XCTSkip("Set RETRACE_BENCH_CHUNKS to run this benchmark.")
        }
        let maxFrames = Int(env["RETRACE_BENCH_MAX_FRAMES"] ?? "") ?? 24
        let chunkPaths = spec.split(separator: ":").map(String.init)

        for path in chunkPaths {
            let url = URL(fileURLWithPath: path)
            let frames = try await Self.decodeFrames(url: url, limit: maxFrames)
            guard frames.count >= 2 else {
                print("BENCH: \(path) -> only \(frames.count) frames, skipping")
                continue
            }
            print("BENCH CHUNK \(url.lastPathComponent): \(frames.count) frames "
                  + "\(frames[0].width)x\(frames[0].height)")

            // Interleaved OFF, ON, ON, OFF cancels monotonic thermal/load drift.
            let order: [Bool] = [false, true, true, false]
            var results: [Bool: [PassResult]] = [false: [], true: []]
            for correction in order {
                let r = try await Self.runPass(frames: frames, correction: correction)
                results[correction, default: []].append(r)
            }

            Self.report(chunk: url.lastPathComponent,
                        off: results[false]!,
                        on: results[true]!,
                        frameCount: frames.count)
        }
    }

    // MARK: - One replay of the whole sequence at one setting

    private static func runPass(frames: [CapturedFrame], correction: Bool) async throws -> PassResult {
        let ocr = VisionOCR(recognitionLanguages: ["en-US"])
        let cache = FullFrameOCRCache()
        let config = ProcessingConfig(ocrLanguageCorrectionEnabled: correction)
        var out = PassResult()
        var previous: CapturedFrame?
        for frame in frames {
            let result = try await ocr.recognizeTextRegionBased(
                frame: frame,
                previousFrame: previous,
                cache: cache,
                config: config
            )
            out.ocrMs.append(result.stats.ocrTimeMs)
            out.changeMs.append(result.stats.changeDetectionTimeMs)
            out.mergeMs.append(result.stats.mergeTimeMs)
            out.tiles.append(result.stats.tilesOCRed)
            out.totalTiles = result.stats.totalTiles
            let joined = result.regions.map(\.text).joined(separator: "\n")
            out.chars.append(joined.count)
            out.text.append(joined)
            previous = frame
        }
        return out
    }

    // MARK: - Reporting

    private static func report(chunk: String, off: [PassResult], on: [PassResult], frameCount: Int) {
        func mean(_ xs: [Double]) -> Double { xs.isEmpty ? 0 : xs.reduce(0, +) / Double(xs.count) }
        // Frame 0 always cold-starts the cache with a full-frame OCR; report it apart
        // from the steady-state region frames, which is what production spends its time on.
        func sum(_ p: PassResult, _ kp: (PassResult) -> [Double], from: Int) -> Double {
            Array(kp(p).dropFirst(from)).reduce(0, +)
        }

        let offOCRcold = mean(off.map { $0.ocrMs[0] })
        let onOCRcold = mean(on.map { $0.ocrMs[0] })
        let offOCR = mean(off.map { sum($0, { $0.ocrMs }, from: 1) })
        let onOCR = mean(on.map { sum($0, { $0.ocrMs }, from: 1) })
        let offTotal = mean(off.map { sum($0, { $0.ocrMs }, from: 1) + sum($0, { $0.changeMs }, from: 1) + sum($0, { $0.mergeMs }, from: 1) })
        let onTotal = mean(on.map { sum($0, { $0.ocrMs }, from: 1) + sum($0, { $0.changeMs }, from: 1) + sum($0, { $0.mergeMs }, from: 1) })
        let n = frameCount - 1
        let tiles = off[0].tiles.dropFirst().reduce(0, +)
        let offChars = off.map { $0.chars.dropFirst().reduce(0, +) }
        let onChars = on.map { $0.chars.dropFirst().reduce(0, +) }

        print("""
        BENCH RESULT \(chunk)
          region frames (excl. cold frame 0): \(n), tiles re-OCR'd total: \(tiles) of \(off[0].totalTiles)/frame
          cold frame-0 OCR      OFF \(String(format: "%8.1f", offOCRcold)) ms   ON \(String(format: "%8.1f", onOCRcold)) ms   \(pct(offOCRcold, onOCRcold))
          region OCR (sum)      OFF \(String(format: "%8.1f", offOCR)) ms   ON \(String(format: "%8.1f", onOCR)) ms   \(pct(offOCR, onOCR))
          region OCR (per frame)OFF \(String(format: "%8.1f", offOCR / Double(n))) ms   ON \(String(format: "%8.1f", onOCR / Double(n))) ms
          stage total (sum)     OFF \(String(format: "%8.1f", offTotal)) ms   ON \(String(format: "%8.1f", onTotal)) ms   \(pct(offTotal, onTotal))
          chars recognised      OFF \(offChars)   ON \(onChars)
          per-pass OCR sums     OFF \(off.map { Int(sum($0, { $0.ocrMs }, from: 1)) })   ON \(on.map { Int(sum($0, { $0.ocrMs }, from: 1)) })
          per-pass tile counts  OFF \(off.map { $0.tiles.dropFirst().reduce(0, +) })   ON \(on.map { $0.tiles.dropFirst().reduce(0, +) })
          per-frame tiles       \(Array(off[0].tiles.dropFirst()))
          per-frame OCR ms OFF  \(Array(off[0].ocrMs.dropFirst()).map { Int($0) })
          per-frame OCR ms ON   \(Array(on[0].ocrMs.dropFirst()).map { Int($0) })
        \(searchTokenReport(off: off[0], on: on[0]))
        """)
    }


    /// Search-token overlap between the two arms. Counts only -- never the tokens
    /// themselves, which are real screen contents.
    private static func searchTokenReport(off: PassResult, on: PassResult) -> String {
        func tokens(_ texts: [String]) -> Set<String> {
            var out: Set<String> = []
            for text in texts {
                for raw in text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }) {
                    let token = raw.lowercased().trimmingCharacters(
                        in: CharacterSet.alphanumerics.inverted
                    )
                    if token.count >= 3 { out.insert(token) }
                }
            }
            return out
        }
        let offTokens = tokens(Array(off.text.dropFirst()))
        let onTokens = tokens(Array(on.text.dropFirst()))
        let shared = offTokens.intersection(onTokens).count
        func pct(_ part: Int, _ whole: Int) -> String {
            whole == 0 ? "n/a" : String(format: "%.2f%%", Double(part) / Double(whole) * 100)
        }
        // Characterise the tokens each arm finds alone, without printing any of them.
        // If correction is rewriting technical tokens into dictionary words, the
        // OFF-only set should skew code-like (digits, punctuation, mixed case) and the
        // ON-only set should skew plain lowercase alphabetic.
        func shape(_ tokens: Set<String>, _ label: String) -> String {
            guard !tokens.isEmpty else { return "            \(label): none" }
            let count = Double(tokens.count)
            let withDigit = tokens.filter { $0.contains(where: \.isNumber) }.count
            let allAlpha = tokens.filter { $0.allSatisfy(\.isLetter) }.count
            let meanLength = Double(tokens.reduce(0) { $0 + $1.count }) / count
            return String(
                format: "            %@: %d tokens, mean len %.1f, %.1f%% contain a digit, %.1f%% all-alphabetic",
                label, tokens.count, meanLength,
                Double(withDigit) / count * 100, Double(allAlpha) / count * 100
            )
        }
        let offOnly = offTokens.subtracting(onTokens)
        let onOnly = onTokens.subtracting(offTokens)
        return """
          search tokens         OFF \(offTokens.count) distinct   ON \(onTokens.count) distinct   shared \(shared)
            of ON's tokens, OFF also finds  \(pct(shared, onTokens.count))  (missed \(onTokens.count - shared))
            of OFF's tokens, ON also finds  \(pct(shared, offTokens.count))  (missed \(offTokens.count - shared))
        \(shape(offTokens.intersection(onTokens), "shared  "))
        \(shape(offOnly, "OFF-only"))
        \(shape(onOnly, "ON-only "))
        """
    }

    private static func pct(_ offValue: Double, _ onValue: Double) -> String {
        guard onValue > 0 else { return "" }
        return String(format: "(OFF is %.1f%% faster than ON)", (onValue - offValue) / onValue * 100)
    }

    // MARK: - Decode real captured frames to BGRA

    private static func decodeFrames(url: URL, limit: Int) async throws -> [CapturedFrame] {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else { return [] }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        )
        reader.add(output)
        guard reader.startReading() else { return [] }
        var frames: [CapturedFrame] = []
        while frames.count < limit, let sample = output.copyNextSampleBuffer() {
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            let width = CVPixelBufferGetWidth(buffer)
            let height = CVPixelBufferGetHeight(buffer)
            let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                let data = Data(bytes: base, count: bytesPerRow * height)
                frames.append(CapturedFrame(
                    timestamp: Date(),
                    imageData: data,
                    width: width,
                    height: height,
                    bytesPerRow: bytesPerRow,
                    metadata: .empty
                ))
            }
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
        }
        reader.cancelReading()
        return frames
    }
}
