import CoreGraphics
import Foundation

/// Select the captured window, which need not be the application's focused window.
/// Multiple candidates are unsafe even when their geometry and title agree.
enum AccessibilityWindowMatcher {
    static func uniqueIndex(bounds: [CGRect?], titles: [String?],
                            expectedBounds: CGRect, expectedTitle: String?, applicationName: String? = nil) -> Int? {
        guard bounds.count == titles.count else { return nil }
        var selected: Int?
        for index in bounds.indices {
            guard let candidate = bounds[index], approximatelyEqual(candidate, expectedBounds),
                  expectedTitle?.isEmpty != false || normalizedTitle(titles[index], applicationName: applicationName) == normalizedTitle(expectedTitle, applicationName: applicationName) else { continue }
            guard selected == nil else { return nil }
            selected = index
        }
        return selected
    }

    /// Strip only the known owner's suffix; a document's own dash-separated words matter.
    static func normalizedTitle(_ title: String?, applicationName: String?) -> String? {
        guard let title else { return nil }
        var value = title.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        if let applicationName, !applicationName.isEmpty {
            let name = applicationName.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            for separator in [" - ", " – ", " — "] {
                let suffix = separator + name
                if value.lowercased().hasSuffix(suffix.lowercased()) {
                    value.removeLast(suffix.count)
                    break
                }
            }
        }
        return value.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    static func approximatelyEqual(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX-b.minX) < 2 && abs(a.minY-b.minY) < 2 && abs(a.width-b.width) < 2 && abs(a.height-b.height) < 2
    }
}
