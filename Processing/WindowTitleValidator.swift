import Foundation
import Shared

/// Uses existing, privacy-sanitized OCR only. Scores describe evidence, not probabilities.
enum WindowTitleValidator {
    struct Result {
        let title: String?
        let confidence: Int
        let outcome: String
    }

    static func validate(_ evidence: WindowTitleEvidence, text: ExtractedText, width: Int, height: Int) -> Result {
        let start = ProcessInfo.processInfo.systemUptime
        defer { Log.recordLatency("processing.window_title_compare", valueMs: (ProcessInfo.processInfo.systemUptime - start) * 1000, category: .processing) }
        let observations = [evidence.before, evidence.after].compactMap { $0 }
        let fallback = evidence.before?.title ?? evidence.after?.title
        guard width > 0, height > 0 else { return Result(title: fallback, confidence: fallback == nil ? 0 : 5, outcome: "ocr_unavailable") }
        let regions = text.regions + text.chromeRegions
        func lines(in normalized: CGRect?) -> [String] {
            guard let r = normalized, r.width > 0, r.height > 0 else { return [] }
            let area = CGRect(x: r.minX * Double(width), y: r.minY * Double(height),
                              width: r.width * Double(width), height: r.height * Double(height))
            return Array(Set(regions.filter {
                area.contains(CGPoint(x: $0.bounds.midX, y: $0.bounds.midY)) &&
                $0.bounds.minX >= area.minX - 3 && $0.bounds.maxX <= area.maxX + 3 &&
                !WindowTitleWords.tokens($0.text).isEmpty
            }.map(\.text))).sorted()
        }
        // Keep the geometric association between each AX observation and OCR.
        // With both boundaries: exact/explicit-ellipsis matches score 10, spelling 9.
        // A changed boundary uniquely selected by OCR scores 10; a missing boundary caps at 7.
        let bothBoundaries = evidence.before != nil && evidence.after != nil
        let changed = bothBoundaries && (
            WindowTitleWords.tokens(evidence.before!.title) != WindowTitleWords.tokens(evidence.after!.title) ||
            evidence.before!.pid != evidence.after!.pid || evidence.before!.windowID != evidence.after!.windowID)
        var matches: [(title: String, score: Int, outcome: String)] = []
        var matchedLines = Set<String>()
        for observation in observations {
            for line in lines(in: observation.titleRegion) {
                let a = WindowTitleWords.tokens(observation.title), b = WindowTitleWords.tokens(line)
                let exact = !a.isEmpty && a == b
                let truncated = WindowTitleWords.matchesTruncated(observation.title, line)
                if exact || truncated {
                    matchedLines.insert(WindowTitleWords.tokens(line).joined(separator: " "))
                    matches.append((observation.title, bothBoundaries ? 10 : 7,
                        !bothBoundaries ? "ocr_single_boundary" : changed ? "boundary_match" : truncated ? "truncated" : "exact"))
                }
                else if WindowTitleWords.matches(observation.title, line) {
                    matchedLines.insert(WindowTitleWords.tokens(line).joined(separator: " "))
                    matches.append((observation.title, !bothBoundaries ? 7 : changed ? 10 : 9,
                                    !bothBoundaries ? "ocr_single_boundary" : changed ? "boundary_match" : "spelling"))
                }
            }
        }
        let matchedTitles = Set(matches.map { WindowTitleWords.tokens($0.title).joined(separator: " ") })
        if matchedTitles.count > 1 || matchedLines.count > 1 {
            return Result(title: fallback, confidence: 5, outcome: "ambiguous")
        }
        if let best = matches.max(by: { $0.score < $1.score }) {
            return Result(title: best.title, confidence: best.score, outcome: best.outcome)
        }
        // A single distinct caption/selected-tab line can replace stale AX at score 7.
        // Never mine the body or sidebar for a plausible title.
        let areas = observations.compactMap(\.titleRegion) + [evidence.fallbackTitleRegion].compactMap { $0 }
        var candidates: [String: String] = [:]
        for line in areas.flatMap({ lines(in: $0) }) {
            var title = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if let range = title.range(of: #"\s+working\s*[•·-]\s*\d"#, options: [.regularExpression, .caseInsensitive]) {
                title = String(title[..<range.lowerBound])
            }
            let key = WindowTitleWords.tokens(title).joined(separator: " ")
            if !key.isEmpty { candidates[key] = title }
        }
        if candidates.count == 1, let title = candidates.values.first {
            return Result(title: title, confidence: 7, outcome: "ocr_recovered")
        }
        return Result(title: fallback, confidence: fallback == nil ? 0 : 5,
                      outcome: candidates.isEmpty ? "ocr_unavailable" : "ambiguous")
    }
}
