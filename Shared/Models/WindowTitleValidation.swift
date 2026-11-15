import Foundation
import CoreGraphics

/// Capture-time evidence only. Normalized titleRegion uses a top-left origin.
/// Optional on legacy frames; unrelated to frame.metadata's in-page URL JSON.
public struct WindowTitleObservation: Codable, Sendable, Equatable {
    public let pid: Int32
    public let windowID: UInt32
    public let bounds: CGRect
    public let title: String
    public let titleRegion: CGRect?
    public init(pid: Int32, windowID: UInt32, bounds: CGRect, title: String, titleRegion: CGRect?) {
        self.pid = pid; self.windowID = windowID; self.bounds = bounds
        self.title = title; self.titleRegion = titleRegion
    }
}

public struct WindowTitleEvidence: Codable, Sendable, Equatable {
    public let before: WindowTitleObservation?
    public let after: WindowTitleObservation?
    public init(before: WindowTitleObservation?, after: WindowTitleObservation?) {
        self.before = before; self.after = after
    }
}

/// Shared normalization for boundary comparison and OCR verification.
public enum WindowTitleWords {
    public static func normalized(_ text: String) -> String {
        var text = text.precomposedStringWithCompatibilityMapping.lowercased()
        if text.hasPrefix("agents - ") { text.removeFirst("agents - ".count) }
        for suffix in [" - google chrome", " - safari", " - microsoft edge", " - brave"] where text.hasSuffix(suffix) {
            text.removeLast(suffix.count)
        }
        // BB renders run status after the thread title in the same OCR line.
        if let range = text.range(of: #"\s+working\s*[•·-]\s*\d"#, options: .regularExpression) {
            text = String(text[..<range.lowerBound])
        }
        return text
    }
    public static func tokens(_ text: String) -> [String] {
        let text = normalized(text)
        let regex = try! NSRegularExpression(pattern: #"\p{N}+|[\p{L}\p{M}]+"#)
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }
    public static func matches(_ title: String, _ ocr: String) -> Bool {
        let a = tokens(title), b = tokens(ocr)
        guard !a.isEmpty, a.count == b.count, a.count <= 128 else { return false }
        return zip(a, b).allSatisfy { wordMatches($0.0, $0.1) }
    }

    private static func wordMatches(_ x: String, _ y: String) -> Bool {
        guard x != y else { return true }
        guard !x.allSatisfy(\.isNumber), !y.allSatisfy(\.isNumber) else { return false }
        if min(x.count, y.count) <= 3 {
            // Actual full-frame OCR reads API as APl. Permit this glyph
            // confusion, not general short-word fuzziness (for/tor, ids, etc.).
            return x.count == y.count && zip(x, y).allSatisfy { a, b in
                if a == b { return true }
                return (a == "i" || a == "l") && (b == "i" || b == "l")
            }
        }
        // Bound work on corrupted/oversized OCR.
        guard max(x.count, y.count) <= 128 else { return false }
        var row = Array(0...y.count)
        for (i, xc) in x.enumerated() {
            var next = [i + 1]
            for (j, yc) in y.enumerated() {
                next.append(min(next[j] + 1, row[j + 1] + 1, row[j] + (xc == yc ? 0 : 1)))
            }
            row = next
        }
        return Double(row.last!) / Double(max(x.count, y.count)) <= 0.25
    }
}
