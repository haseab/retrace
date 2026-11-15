import Foundation
import Shared

/// Uses the existing full-frame OCR output. Never does another Vision request.
enum WindowTitleValidator {
    struct Result {
        let title: String?
        let outcome: String
    }
    static func validate(_ evidence: WindowTitleEvidence, text: ExtractedText, width: Int, height: Int) -> Result {
        let start = ProcessInfo.processInfo.systemUptime
        defer { Log.recordLatency("processing.window_title_compare", valueMs: (ProcessInfo.processInfo.systemUptime - start) * 1000, category: .processing) }
        guard let a = evidence.before, let b = evidence.after else {
            return Result(title: nil, outcome: "ax_unavailable")
        }
        guard a.pid == b.pid, a.windowID == b.windowID, a.bounds == b.bounds,
              WindowTitleWords.tokens(a.title) == WindowTitleWords.tokens(b.title),
              a.titleRegion == b.titleRegion else {
            return Result(title: nil, outcome: "boundary_changed")
        }
        guard let normalizedArea = a.titleRegion, normalizedArea.width > 0, normalizedArea.height > 0, width > 0, height > 0 else {
            return Result(title: nil, outcome: "title_region_unavailable")
        }
        let area = CGRect(x: normalizedArea.minX * Double(width), y: normalizedArea.minY * Double(height),
                          width: normalizedArea.width * Double(width), height: normalizedArea.height * Double(height))
        // OCR regions are in frame pixels, top-left based.
        // Only use whole OCR lines inside the caption/selected tab, never body/sidebar hits.
        let lines = (text.regions + text.chromeRegions).filter {
            area.contains(CGPoint(x: $0.bounds.midX, y: $0.bounds.midY)) &&
            $0.bounds.minX >= area.minX - 3 && $0.bounds.maxX <= area.maxX + 3
        }
        guard !lines.isEmpty else { return Result(title: nil, outcome: "ocr_unavailable") }
        let matches = lines.filter { WindowTitleWords.matches(a.title, $0.text) }
        guard matches.count == 1 else { return Result(title: nil, outcome: "ocr_disagreement") }
        return Result(title: a.title, outcome: "verified")
    }
}
