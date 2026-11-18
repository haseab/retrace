import Foundation
import Shared

/// Replaces matched OCR tokens only. AX-only text and OCR reading order are preserved.
public enum AccessibilityOCRCorrector {
    // Combining marks belong to the preceding letter/number. Splitting them off
    // can turn canonically equivalent AX text into a spelling regression.
    private static let pattern = try! NSRegularExpression(pattern: "[\\p{L}\\p{N}][\\p{L}\\p{N}\\p{M}]*")
    private static func tokens(_ text: String) -> [(String, NSRange)] {
        let ns = text as NSString
        return pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { (ns.substring(with: $0.range), $0.range) }
    }
    public static func correct(_ region: TextRegion, snapshot: AccessibilitySnapshot) -> TextRegion {
        let source = tokens(region.text)
        guard !source.isEmpty, source.count <= 150 else { return region }
        var alternatives = Set<String>()
        for element in snapshot.elements {
            let intersection = element.bounds.intersection(region.bounds)
            let area = region.bounds.width * region.bounds.height
            guard area > 0, !intersection.isNull, intersection.width*intersection.height / area >= 0.85 else { continue }
            let exactPosition = element.precise && abs(element.bounds.midY-region.bounds.midY) <= max(5, region.bounds.height*0.4)
                && element.bounds.width <= region.bounds.width*1.5 && region.bounds.width <= element.bounds.width*1.5
            let target = tokens(element.text)
            guard target.count >= source.count, target.count <= 3000 else { continue }
            for offset in 0...(target.count-source.count) {
                let changed = source.indices.filter { source[$0].0 != target[offset+$0].0 }
                if changed.isEmpty { return region }
                let exactCount = source.count-changed.count
                guard exactPosition ? (changed.count <= max(1, source.count/2)) : (source.count >= 5 && exactCount >= 3 && Double(exactCount)/Double(source.count) >= 0.7) else { continue }
                guard changed.allSatisfy({ close(source[$0].0, target[offset+$0].0) }) else { continue }
                // A sentence boundary present in AX but absent in OCR indicates a
                // merged/misaligned observation. Do not try to repair its structure.
                let sourceString = region.text as NSString
                let targetString = element.text as NSString
                let boundariesMatch = source.indices.dropLast().allSatisfy { i in
                    let a = NSRange(location: NSMaxRange(source[i].1), length: source[i+1].1.location-NSMaxRange(source[i].1))
                    let b = NSRange(location: NSMaxRange(target[offset+i].1), length: target[offset+i+1].1.location-NSMaxRange(target[offset+i].1))
                    let separators = CharacterSet(charactersIn: ".!?\n")
                    return sourceString.substring(with: a).rangeOfCharacter(from: separators) != nil
                        ? targetString.substring(with: b).rangeOfCharacter(from: separators) != nil
                        : targetString.substring(with: b).rangeOfCharacter(from: separators) == nil
                }
                guard boundariesMatch else { continue }
                let output = NSMutableString(string: region.text)
                // Match Vision's composed accent representation instead of introducing
                // extra combining scalars into existing index-offset conventions.
                for i in changed.reversed() { output.replaceCharacters(in: source[i].1, with: target[offset+i].0.precomposedStringWithCanonicalMapping) }
                alternatives.insert(output as String)
            }
        }
        guard alternatives.count == 1, let text = alternatives.first else { return region }
        return TextRegion(id: region.databaseID, frameID: region.frameID, text: text, bounds: region.bounds,
                          confidence: region.confidence, createdAt: region.createdAt)
    }
    private static func close(_ a: String, _ b: String) -> Bool {
        let x = Array(a.lowercased()), y = Array(b.lowercased())
        guard !x.isEmpty, !y.isEmpty, x.count <= 80, y.count <= 80 else { return false }
        let limit = min(x.count,y.count) >= 6 ? 2 : 1
        guard abs(x.count-y.count) <= limit else { return false }
        var previous = Array(0...y.count)
        for i in x.indices {
            var next = [i+1]
            for j in y.indices { next.append(min(previous[j+1]+1, next[j]+1, previous[j] + (x[i] == y[j] ? 0 : 1))) }
            if next.min()! > limit { return false }
            previous = next
        }
        return previous[y.count] <= limit
    }
}
