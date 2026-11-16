import CoreGraphics

/// Select the captured window, which need not be the application's focused window.
/// Multiple candidates are unsafe even when their geometry and title agree.
enum AccessibilityWindowMatcher {
    static func uniqueIndex(bounds: [CGRect?], titles: [String?],
                            expectedBounds: CGRect, expectedTitle: String?) -> Int? {
        guard bounds.count == titles.count else { return nil }
        var selected: Int?
        for index in bounds.indices {
            guard let candidate = bounds[index], approximatelyEqual(candidate, expectedBounds),
                  expectedTitle?.isEmpty != false || titles[index] == expectedTitle else { continue }
            guard selected == nil else { return nil }
            selected = index
        }
        return selected
    }

    static func approximatelyEqual(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX-b.minX) < 2 && abs(a.minY-b.minY) < 2 && abs(a.width-b.width) < 2 && abs(a.height-b.height) < 2
    }
}
