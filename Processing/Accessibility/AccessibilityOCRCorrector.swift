import Foundation
import Shared

/// Matches OCR nodes to ordered, exclusive AX spans. Neighboring nodes establish
/// context; each node keeps its own identity, geometry and correction decision.
public enum AccessibilityOCRCorrector {
    private struct Normalized {
        let original: NSString
        let characters: [Character]
        let starts: [Int]
        let ends: [Int]

        init(_ text: String) {
            original = text as NSString
            var units: [Character] = [], lower: [Int] = [], upper: [Int] = []
            var offset = 0
            for character in text {
                if let ascii = character.asciiValue {
                    if !character.isWhitespace {
                        units.append((65...90).contains(ascii) ? Character(UnicodeScalar(ascii + 32)) : character)
                        lower.append(offset); upper.append(offset + 1)
                    }
                    offset += 1
                    continue
                }
                let raw = String(character)
                let length = raw.utf16.count
                let comparable = raw.precomposedStringWithCanonicalMapping.lowercased()
                    .replacingOccurrences(of: "’", with: "'")
                    .replacingOccurrences(of: "‘", with: "'")
                    .replacingOccurrences(of: "“", with: "\"")
                    .replacingOccurrences(of: "”", with: "\"")
                for unit in comparable where !unit.isWhitespace {
                    units.append(unit); lower.append(offset); upper.append(offset + length)
                }
                offset += length
            }
            characters = units; starts = lower; ends = upper
        }

        func rawRange(_ range: Range<Int>) -> NSRange? {
            guard !range.isEmpty, range.lowerBound >= 0, range.upperBound <= characters.count else { return nil }
            return NSRange(location: starts[range.lowerBound], length: ends[range.upperBound - 1] - starts[range.lowerBound])
        }

        private init(original: NSString, characters: [Character], starts: [Int], ends: [Int]) {
            self.original = original; self.characters = characters; self.starts = starts; self.ends = ends
        }

        func slice(_ range: Range<Int>) -> Normalized {
            Normalized(original: original, characters: Array(characters[range]),
                starts: Array(starts[range]), ends: Array(ends[range]))
        }
    }

    private struct Owner { let index: Int; let range: NSRange }
    private struct Anchor: Hashable { let source: Int; let target: Int; let length: Int }
    private struct Part { let key: Int; let range: Range<Int> }
    private struct Section { let text: String; let parts: [Part] }
    private struct Claim: Hashable { let key: Int; let range: Range<Int> }
    private struct Choice {
        let text: String
        let support: Double
        let claims: [Claim]
        let outside: [Claim]
        let outsideSupport: Int
    }
    private struct Placement {
        let node: Int
        let order: Int
        let target: Range<Int>
        let weight: Int
        let independent: Bool
    }
    private struct Neighbors { let before: [Int]; let after: [Int] }
    private struct Outside { let claims: [Claim]; let support: Int }
    private struct NodeSpan: Hashable { let node: Int; let range: Range<Int> }
    private struct Correspondence { let wording: String; let outside: Outside }
    private struct NodePath { let placements: [Placement]; let ambiguous: Set<Int> }
    private struct Point { let source: Int; let target: Int }
    private struct Alignment { let points: [Point]; let edits: Int }
    private struct Passage { let points: [Point]; let target: Range<Int>; let independent: Bool }
    private struct EndpointQuery { let nodes: [Int]; let text: Normalized }
    private struct DiscoverySeed { let query: Int; let offset: Int }
    private struct DiscoveryTrial: Hashable { let query: Int; let bin: Int }
    private struct Budget {
        var cells = 2_000_000
        var characters = 200_000
        var incomplete = false

        mutating func consumeCharacters(_ count: Int) -> Bool {
            guard !incomplete, count <= characters else { incomplete = true; return false }
            characters -= count
            return true
        }

        mutating func consumeCells(_ count: Int) -> Bool {
            guard !incomplete, count <= cells else { incomplete = true; return false }
            cells -= count
            return true
        }
    }

    public static func correct(
        _ regions: [TextRegion], snapshot: AccessibilitySnapshot,
        recognitionLanguages: [String] = ["en-US"], windowRegions: [CGRect]? = nil
    ) async -> [TextRegion] {
        guard !regions.isEmpty, !snapshot.elements.isEmpty, !snapshot.truncated else { return regions }
        if let windows = windowRegions {
            guard windows.count <= 16 else { return regions }
            var output = regions
            for index in windows.indices {
                let owned = regions.indices.filter { WindowOCRPlanner.owns(regions[$0].bounds, at: index, in: windows) }
                let elements = snapshot.elements.filter {
                    !$0.bounds.isEmpty && WindowOCRPlanner.owns($0.bounds, at: index, in: windows)
                }
                guard !owned.isEmpty, !elements.isEmpty else { continue }
                let corrected = await correct(owned.map { regions[$0] },
                    snapshot: AccessibilitySnapshot(capturedAt: snapshot.capturedAt, elements: elements,
                        truncated: snapshot.truncated), recognitionLanguages: recognitionLanguages)
                for (offset, node) in owned.enumerated() { output[node] = corrected[offset] }
            }
            return output
        }
        // The API keeps the language parameter for its callers; literal reference
        // alignment does not depend on a language dictionary or spell service.
        var budget = Budget()
        let nodes = regions.map { Normalized($0.text) }
        guard nodes.allSatisfy({ $0.characters.count <= 6000 }) else { return regions }
        let ordered = OCRReadingOrder.indices(Array(regions.indices), bounds: { regions[$0].bounds })
        let neighbors = outsideNeighbors(ordered, regions: regions)
        // Find OCR endpoints across the complete saved AX text before spending
        // the detailed-alignment budget. Raw AX element count is not a cutoff.
        guard let contexts = boundedSections(snapshot.elements, regions: regions,
            ordered: ordered, neighbors: neighbors) else { return regions }
        var options = Array(repeating: [Choice](), count: regions.count)
        // Establish exact node anchors before fuzzy/context work. An exact
        // attribution, for example, cannot lend its words to a different header.
        var references: [String: [Int]] = [:]
        for index in snapshot.elements.indices {
            let text = snapshot.elements[index].text
            guard !text.isEmpty else { continue }
            references[String(Normalized(text).characters), default: []].append(index)
        }
        let pinned = nodes.map { references[String($0.characters)] ?? [] }
        for index in regions.indices {
            for key in pinned[index] where snapshot.elements[key].text.precomposedStringWithCanonicalMapping == regions[index].text {
                options[index].append(Choice(
                    text: snapshot.elements[key].text.precomposedStringWithCanonicalMapping,
                    support: 2, claims: [Claim(key: key, range: 0..<nodes[index].characters.count)],
                    outside: [], outsideSupport: Int.max))
            }
        }
        for section in contexts {
            guard !budget.incomplete else { return regions }
            let target = Normalized(section.text)
            var placements: [Placement] = []
            for (order, index) in ordered.enumerated() {
                guard pinned[index].isEmpty || section.parts.contains(where: { pinned[index].contains($0.key) }) else { continue }
                let source = nodes[index], work = source.characters.count + target.characters.count
                guard !source.characters.isEmpty else { continue }
                guard budget.consumeCharacters(work) else { return regions }
                var chain = anchorChain(source.characters, target.characters, budget: &budget)
                if chain.isEmpty, let offset = uniqueOccurrence(source.characters, in: target.characters),
                   wordBoundary(offset, in: target), wordBoundary(offset + source.characters.count, in: target) {
                    chain = [Anchor(source: 0, target: offset, length: source.characters.count)]
                }
                if chain.isEmpty, source.characters.count >= 2, source.characters.count < 6 {
                    chain = anchorChain(source.characters, target.characters, seed: 2, budget: &budget)
                }
                // Placement is a proposal, not a spelling acceptance threshold.
                // Even a short or badly read node can participate between neighbors.
                guard let match = alignPassage(source, target, chain: chain, budget: &budget, requireIdentity: false) else { continue }
                placements.append(Placement(node: index, order: order, target: match.target,
                    weight: chain.reduce(0) { $0 + $1.length }, independent: match.independent))
            }
            guard placements.count <= 128, !budget.incomplete else { return regions }
            let path = boundUnplacedNodes(nodePath(placements), candidates: placements,
                ordered: ordered, regions: regions, nodes: nodes, target: target, budget: &budget)
            guard !path.placements.isEmpty else { continue }
            var verified: [NodeSpan: Correspondence] = [:]
            var rejected = Set<NodeSpan>()
            var windows: [Range<Int>] = [0..<path.placements.count]
            for index in path.placements.indices {
                windows.append(max(0, index - 1)..<min(path.placements.count, index + 2))
                windows.append(index..<(index + 1))
            }
            var visited = Set<Range<Int>>()
            for window in windows where visited.insert(window).inserted {
                let work = path.placements[window].reduce(target.characters.count) { $0 + nodes[$1.node].characters.count }
                guard budget.consumeCharacters(work) else { return regions }
                var text = "", owners: [Owner] = []
                for placement in path.placements[window] {
                    if !text.isEmpty { text += "\n" }
                    let start = text.utf16.count
                    text += regions[placement.node].text
                    owners.append(Owner(index: placement.node,
                        range: NSRange(location: start, length: regions[placement.node].text.utf16.count)))
                }
                let source = Normalized(text)
                guard source.characters.count <= 6000 else { return regions }
                let chain = anchorChain(source.characters, target.characters, budget: &budget)
                guard let match = alignPassage(source, target, chain: chain, budget: &budget) else { continue }
                for (offset, owner) in owners.enumerated() {
                    guard !budget.incomplete else { return regions }
                    guard !path.ambiguous.contains(owner.index) else { continue }
                    let position = window.lowerBound + offset
                    let indices = source.characters.indices.filter {
                        source.starts[$0] >= owner.range.location && source.ends[$0] <= NSMaxRange(owner.range)
                    }
                    guard let first = indices.first, let last = indices.last,
                          let lower = match.points.last(where: { $0.source == first })?.target,
                          let upper = match.points.last(where: { $0.source == last + 1 })?.target,
                          lower < upper, wordBoundary(lower, in: target), wordBoundary(upper, in: target) else { continue }
                    // Previous/next node placements are bounds on this node's
                    // ownership, including neighbors outside this context window.
                    let minimum = position > 0 ? path.placements[position - 1].target.upperBound : 0
                    let maximum = position + 1 < path.placements.count
                        ? path.placements[position + 1].target.lowerBound : target.characters.count
                    guard lower >= minimum, upper <= maximum,
                          let raw = target.rawRange(lower..<upper) else { continue }
                    let span = NodeSpan(node: owner.index, range: lower..<upper)
                    guard !rejected.contains(span) else { continue }
                    let correspondence: Correspondence
                    if let cached = verified[span] {
                        correspondence = cached
                    } else {
                        let wording = target.original.substring(with: raw).precomposedStringWithCanonicalMapping
                        guard let outside = outsideEvidence(for: owner.index, range: lower..<upper,
                            neighbors: neighbors[owner.index], path: path, section: section,
                            regions: regions, target: target, budget: &budget),
                            hasInternalCorrespondence(nodes[owner.index], wording: wording, budget: &budget) else {
                            rejected.insert(span)
                            continue
                        }
                        correspondence = Correspondence(wording: wording, outside: outside)
                        verified[span] = correspondence
                    }
                    let claims = claims(lower..<upper, in: section)
                    let context = (position > window.lowerBound ? 0.25 : 0)
                        + (position + 1 < window.upperBound ? 0.25 : 0)
                    options[owner.index].append(Choice(
                        text: correspondence.wording,
                        support: supportedFraction(owner, source: source, chain: chain) + context,
                        claims: claims, outside: correspondence.outside.claims,
                        outsideSupport: correspondence.outside.support))
                }
            }
        }
        // None of the proposals may survive a later incomplete comparison.
        // Roll back this window only; separately owned windows have their own scan.
        guard !budget.incomplete else { return regions }
        // Choose per node, then verify AX span ownership across all reference
        // candidates. A conflict affects its nodes, never an entire passage.
        let selected: [Choice?] = options.map { choices in
            guard let outside = choices.map(\.outsideSupport).max() else { return nil }
            let located = choices.filter { $0.outsideSupport == outside }
            // Internal alignment ranks wordings only within an independently
            // established outside correspondence. It cannot break an outside tie
            // between different passages that propose different replacements.
            let groups = Dictionary(grouping: located, by: { Set($0.outside) })
            let best = groups.values.flatMap { group -> [Choice] in
                let score = group.map(\.support).max()!
                return group.filter { $0.support >= score - 0.01 }
            }
            guard Set(best.map(\.text)).count == 1, let first = best.first else { return nil }
            return Choice(text: first.text, support: first.support, claims: Array(Set(best.flatMap(\.claims))),
                outside: first.outside, outsideSupport: outside)
        }
        var conflicts = Set<Int>()
        for i in selected.indices {
            guard let a = selected[i] else { continue }
            for j in selected.indices where j > i {
                guard let b = selected[j] else { continue }
                if a.claims.contains(where: { x in b.claims.contains { x.key == $0.key && x.range.overlaps($0.range) } }) {
                    conflicts.insert(i); conflicts.insert(j)
                }
            }
        }
        return regions.enumerated().map { index, region in
            guard !conflicts.contains(index), let choice = selected[index], choice.text != region.text else { return region }
            return TextRegion(id: region.databaseID, frameID: region.frameID, text: choice.text,
                bounds: region.bounds, confidence: region.confidence, createdAt: region.createdAt)
        }
    }

    public static func correct(_ region: TextRegion, snapshot: AccessibilitySnapshot) async -> TextRegion {
        await correct([region], snapshot: snapshot)[0]
    }

    private static func claims(_ range: Range<Int>, in section: Section) -> [Claim] {
        section.parts.compactMap { part in
            let a = max(range.lowerBound, part.range.lowerBound), b = min(range.upperBound, part.range.upperBound)
            return a < b ? Claim(key: part.key, range: (a - part.range.lowerBound)..<(b - part.range.lowerBound)) : nil
        }
    }

    private static func hasInternalCorrespondence(_ source: Normalized, wording: String, budget: inout Budget) -> Bool {
        let target = Normalized(wording)
        let work = source.characters.count + target.characters.count
        guard budget.consumeCharacters(work) else { return false }
        var chain = anchorChain(source.characters, target.characters, budget: &budget)
        if chain.isEmpty, source.characters.count < 6 {
            chain = anchorChain(source.characters, target.characters, seed: 2, budget: &budget)
            if chain.isEmpty, let offset = uniqueOccurrence(source.characters, in: target.characters) {
                chain = [Anchor(source: 0, target: offset, length: source.characters.count)]
            }
        }
        // The full passage traceback already established the word boundaries.
        // Re-running free-edge alignment here could misread an OCR gutter letter
        // as the first letter of the next AX word ("111I" versus "111 items").
        return !chain.isEmpty
    }

    /// Neighbors come from original OCR geometry, never AX traversal order or
    /// corrected text. Keep both sides mandatory when both are present. At a
    /// flow edge the available side must still provide 24 outside anchor chars.
    private static func outsideNeighbors(_ ordered: [Int], regions: [TextRegion]) -> [Neighbors] {
        func sameFlow(_ a: CGRect, _ b: CGRect) -> Bool {
            let h = max(a.height, b.height)
            guard h > 0 else { return false }
            if abs(a.midY - b.midY) <= h * 0.6 {
                let gap = max(a.minX, b.minX) - min(a.maxX, b.maxX)
                return gap <= max(40, h * 6)
            }
            let gap = max(a.minY, b.minY) - min(a.maxY, b.maxY)
            let overlap = min(a.maxX, b.maxX) - max(a.minX, b.minX)
            return gap <= h * 5 && overlap >= min(a.width, b.width) * 0.5
        }
        var result = Array(repeating: Neighbors(before: [], after: []), count: regions.count)
        for (position, node) in ordered.enumerated() {
            func collect(_ candidates: [Int]) -> [Int] {
                var found: [Int] = [], previous = node
                for candidate in candidates where sameFlow(regions[previous].bounds, regions[candidate].bounds) {
                    found.append(candidate); previous = candidate
                    if found.count == 4 { break }
                }
                return found
            }
            result[node] = Neighbors(before: collect(Array(ordered[..<position].reversed())),
                after: collect(Array(ordered[(position + 1)...])))
        }
        return result
    }

    private static func outsideEvidence(for node: Int, range: Range<Int>, neighbors: Neighbors,
        path: NodePath, section: Section, regions: [TextRegion], target: Normalized,
        budget: inout Budget) -> Outside? {
        guard !neighbors.before.isEmpty || !neighbors.after.isEmpty else { return nil }
        let placements = Dictionary(uniqueKeysWithValues: path.placements.map { ($0.node, $0) })
        var evidence: [Claim] = [], outsideNodes: [Placement] = []
        var beforeEnd: Int?, afterStart: Int?
        for (indices, before) in [(neighbors.before, true), (neighbors.after, false)] where !indices.isEmpty {
            var found = false
            for index in indices {
                guard let anchor = placements[index], anchor.independent,
                      !path.ambiguous.contains(index) else { continue }
                guard before ? anchor.target.upperBound <= range.lowerBound : anchor.target.lowerBound >= range.upperBound else {
                    return nil
                }
                evidence += claims(anchor.target, in: section)
                outsideNodes.append(anchor)
                if before { beforeEnd = max(beforeEnd ?? 0, anchor.target.upperBound) }
                else { afterStart = min(afterStart ?? target.characters.count, anchor.target.lowerBound) }
                found = true
            }
            guard found else { return nil }
        }
        // The nearest outside anchors must actually bound this node. Leaving a
        // whole AX word/row unclaimed between them is an alternative passage,
        // not evidence that either repeated row has been uniquely identified.
        func hasUnclaimedWord(_ gap: Range<Int>) -> Bool {
            var cursor = gap.lowerBound
            for placement in path.placements where placement.node != node {
                let start = max(cursor, placement.target.lowerBound), end = min(gap.upperBound, placement.target.upperBound)
                guard start < end else { continue }
                if target.characters[cursor..<start].contains(where: { $0.isLetter || $0.isNumber }) { return true }
                cursor = end
            }
            return target.characters[cursor..<gap.upperBound].contains(where: { $0.isLetter || $0.isNumber })
        }
        if let end = beforeEnd, hasUnclaimedWord(end..<range.lowerBound) { return nil }
        if let start = afterStart, hasUnclaimedWord(range.upperBound..<start) { return nil }
        // Establish outside passage identity without including the target's own
        // text. Several noisy/short neighbors may jointly establish identity;
        // no individual neighbor gets a local spelling/edit threshold.
        outsideNodes.sort { $0.order < $1.order }
        let source = Normalized(outsideNodes.map { regions[$0.node].text }.joined(separator: "\n"))
        let reference = Normalized(outsideNodes.compactMap { placement -> String? in
            guard let range = target.rawRange(placement.target) else { return nil }
            return target.original.substring(with: range)
        }.joined(separator: "\n"))
        let work = source.characters.count + reference.characters.count
        guard source.characters.count <= 6000, reference.characters.count <= 12000 else {
            budget.incomplete = true
            return nil
        }
        guard budget.consumeCharacters(work) else { return nil }
        let chain = anchorChain(source.characters, reference.characters, budget: &budget)
        guard alignPassage(source, reference, chain: chain, budget: &budget) != nil else { return nil }
        return Outside(claims: evidence, support: chain.reduce(0) { $0 + $1.length })
    }

    private static func supportedFraction(_ owner: Owner, source: Normalized, chain: [Anchor]) -> Double {
        guard let first = chain.first, let last = chain.last else { return 0 }
        var total = 0, supported = 0
        for index in source.characters.indices where source.starts[index] >= owner.range.location
            && source.ends[index] <= NSMaxRange(owner.range) {
            total += 1
            if index >= first.source && index < last.source + last.length { supported += 1 }
        }
        return total > 0 ? Double(supported) / Double(total) : 0
    }

    /// Maximum-support node sequence: node order and AX offsets must agree,
    /// and one AX interval cannot be used twice. Equal competing paths mark
    /// only their incompatible nodes ambiguous.
    private static func nodePath(_ candidates: [Placement]) -> NodePath {
        guard !candidates.isEmpty else { return NodePath(placements: [], ambiguous: []) }
        func follows(_ a: Placement, _ b: Placement) -> Bool {
            a.order < b.order && a.target.upperBound <= b.target.lowerBound
        }
        var forward = candidates.map(\.weight), backward = forward
        var previous = Array(repeating: -1, count: candidates.count)
        for i in candidates.indices {
            for j in 0..<i where follows(candidates[j], candidates[i]) {
                if forward[j] + candidates[i].weight > forward[i] {
                    forward[i] = forward[j] + candidates[i].weight; previous[i] = j
                }
            }
        }
        for i in candidates.indices.reversed() {
            for j in candidates.indices where j > i && follows(candidates[i], candidates[j]) {
                backward[i] = max(backward[i], candidates[i].weight + backward[j])
            }
        }
        let score = forward.max()!
        let optimal = candidates.indices.filter { forward[$0] + backward[$0] - candidates[$0].weight == score }
        var ambiguous = Set<Int>()
        for i in optimal {
            for j in optimal where j > i && !follows(candidates[i], candidates[j]) {
                ambiguous.insert(candidates[i].node); ambiguous.insert(candidates[j].node)
            }
        }
        var cursor = forward.firstIndex(of: score)!, path: [Placement] = []
        while cursor >= 0 { path.append(candidates[cursor]); cursor = previous[cursor] }
        return NodePath(placements: path.reversed(), ambiguous: ambiguous)
    }

    /// An OCR node without its own usable anchor can still be identified by the
    /// previous and next placed nodes. Align it only inside that exclusive AX
    /// interval. Its wording is accepted later using the neighboring context.
    private static func boundUnplacedNodes(_ path: NodePath, candidates: [Placement],
        ordered: [Int], regions: [TextRegion], nodes: [Normalized], target: Normalized,
        budget: inout Budget) -> NodePath {
        guard path.placements.count > 1 else { return path }
        let located = Set(candidates.map(\.node))
        let columnMin = path.placements.map { regions[$0.node].bounds.minX }.min()!
        let columnMax = path.placements.map { regions[$0.node].bounds.maxX }.max()!
        var result: [Placement] = []
        for (left, right) in zip(path.placements, path.placements.dropFirst()) {
            result.append(left)
            let gap = left.target.upperBound..<right.target.lowerBound
            guard !gap.isEmpty else { continue }
            let missing = ((left.order + 1)..<right.order).filter { order in
                let node = ordered[order]
                let rect = regions[node].bounds
                return !located.contains(node) && !nodes[node].characters.isEmpty
                    && rect.midX >= columnMin && rect.midX <= columnMax
                    && isBetween(rect, regions[left.node].bounds, regions[right.node].bounds)
            }
            guard !missing.isEmpty else { continue }
            let source = missing.flatMap { nodes[ordered[$0]].characters }
            guard let match = align(source, Array(target.characters[gap]), budget: &budget) else { continue }
            var offset = 0
            for order in missing {
                let index = ordered[order], end = offset + nodes[index].characters.count
                defer { offset = end }
                guard let a = match.points.last(where: { $0.source == offset })?.target,
                      let b = match.points.last(where: { $0.source == end })?.target, a < b else { continue }
                let lower = gap.lowerBound + a, upper = gap.lowerBound + b
                guard wordBoundary(lower, in: target), wordBoundary(upper, in: target) else { continue }
                result.append(Placement(node: index, order: order, target: lower..<upper, weight: 0, independent: false))
            }
        }
        result.append(path.placements.last!)
        return NodePath(placements: result, ambiguous: path.ambiguous)
    }

    private static func isBetween(_ node: CGRect, _ previous: CGRect, _ next: CGRect) -> Bool {
        func sameRow(_ a: CGRect, _ b: CGRect) -> Bool {
            abs(a.midY - b.midY) <= max(a.height, b.height) * 0.6
        }
        let tolerance = max(node.height, previous.height, next.height)
        if sameRow(node, next), node.maxX <= next.minX + tolerance { return true }
        if sameRow(node, previous), node.minX >= previous.maxX - tolerance { return true }
        let overlap = min(node.maxX, previous.maxX, next.maxX) - max(node.minX, previous.minX, next.minX)
        return overlap > 0 && node.midY > previous.midY && node.midY < next.midY
    }

    /// A cheap complete scan finds candidate endpoints; ordinary alignment then
    /// verifies the last OCR text together with its original neighboring nodes.
    /// Overlapping queries cover each flow, including its first and last nodes.
    /// Every competing occurrence survives discovery. AX tree array order never
    /// establishes a passage: multi-element contexts use saved visual geometry.
    private static func boundedSections(_ elements: [AccessibilitySnapshot.Element], regions: [TextRegion],
        ordered: [Int], neighbors: [Neighbors]) -> [Section]? {
        // The encoded snapshot is already bounded at capture time. Also bound
        // direct callers before normalization or index construction. These are
        // complete-scan limits, not prefixes silently selected from the input.
        var rawCharacters = 0
        for element in elements {
            rawCharacters += max(1, element.text.utf16.count)
            guard rawCharacters <= AccessibilitySnapshot.maximumBytes else { return nil }
        }
        var queries: [EndpointQuery] = [], seen = Set<[Int]>(), queryCharacters = 0
        // Start from the last OCR node, with its preceding nodes as witnesses.
        // Other overlapping queries retain earlier passages and separate flows.
        for node in ordered.reversed() {
            let before = neighbors[node].before, after = neighbors[node].after
            let candidates = [before + [node] + after,
                              Array(before.prefix(1)) + [node],
                              [node] + Array(after.prefix(1)),
                              Array(before.prefix(1)) + [node] + Array(after.prefix(1))]
            for candidate in candidates {
                let chosen = Set(candidate), indices = ordered.filter { chosen.contains($0) }
                guard indices.count > 1, seen.insert(indices).inserted else { continue }
                let text = Normalized(indices.map { regions[$0].text }.joined(separator: "\n"))
                queryCharacters += text.characters.count
                guard queryCharacters <= 200_000 else { return nil }
                guard text.characters.count >= 24, text.characters.count <= 6000 else { continue }
                queries.append(EndpointQuery(nodes: indices, text: text))
            }
        }
        guard !queries.isEmpty else { return [] }
        var index: [String: [DiscoverySeed]] = [:]
        for (query, item) in queries.enumerated() {
            var offsets: [String: Int] = [:]
            for offset in 0...(item.text.characters.count - 6) {
                let seed = String(item.text.characters[offset..<(offset + 6)])
                offsets[seed] = offsets[seed] == nil ? offset : -1
            }
            for (seed, offset) in offsets where offset >= 0 {
                index[seed, default: []].append(DiscoverySeed(query: query, offset: offset))
            }
        }
        var discoveryBudget = Budget(), hits = 0, scanned = 0
        var result: [Section] = [], normalized: [String: Normalized] = [:]
        for section in sections(elements) {
            let target: Normalized
            if let cached = normalized[section.text] { target = cached }
            else { target = Normalized(section.text); normalized[section.text] = target }
            scanned += target.characters.count
            guard scanned <= AccessibilitySnapshot.maximumBytes * 2 else { return nil }
            guard target.characters.count >= 24 else { continue }
            var trials: [DiscoveryTrial: Set<Int>] = [:]
            for offset in 0...(target.characters.count - 6) {
                let seed = String(target.characters[offset..<(offset + 6)])
                for hit in index[seed] ?? [] {
                    hits += 1
                    guard hits <= 32_768 else { return nil }
                    let stride = max(32, queries[hit.query].text.characters.count / 2)
                    let diagonal = offset - hit.offset
                    let bin = Int(floor(Double(diagonal) / Double(stride)))
                    // Neighboring bins retain a common trial when OCR edits
                    // move the estimated start across a bin boundary.
                    for candidate in (bin - 1)...(bin + 1) {
                        trials[DiscoveryTrial(query: hit.query, bin: candidate), default: []].insert(hit.offset)
                    }
                }
            }
            guard trials.count <= 4096 else { return nil }
            var located = Set<Range<Int>>()
            let ranked = trials.keys.sorted { a, b in
                a.query == b.query ? a.bin < b.bin : a.query < b.query
            }
            for trial in ranked {
                // A valid passage already requires 24 exact anchor characters.
                // Count distinct source coverage, so repeating one common word
                // hundreds of times cannot consume expensive alignment work.
                var support = 0, end = 0
                for start in trials[trial]!.sorted() {
                    support += max(0, start + 6 - max(start, end)); end = max(end, start + 6)
                }
                guard support >= 24 else { continue }
                let source = queries[trial.query].text, length = source.characters.count
                let stride = max(32, length / 2), margin = stride + 32
                var lower = max(0, trial.bin * stride - margin)
                var upper = min(target.characters.count, trial.bin * stride + stride + length + margin)
                guard lower < upper else { continue }
                while lower > 0 && !wordBoundary(lower, in: target) { lower -= 1 }
                while upper < target.characters.count && !wordBoundary(upper, in: target) { upper += 1 }
                guard upper - lower <= 12000 else { return nil }
                let candidate = target.slice(lower..<upper)
                guard discoveryBudget.consumeCharacters(length + candidate.characters.count) else { return nil }
                let chain = anchorChain(source.characters, candidate.characters, budget: &discoveryBudget)
                if let match = alignPassage(source, candidate, chain: chain, budget: &discoveryBudget) {
                    located.insert((lower + match.target.lowerBound)..<(lower + match.target.upperBound))
                }
                guard !discoveryBudget.incomplete else { return nil }
            }
            var merged: [Range<Int>] = []
            for range in located.sorted(by: { $0.lowerBound == $1.lowerBound ? $0.upperBound < $1.upperBound : $0.lowerBound < $1.lowerBound }) {
                if let last = merged.last, range.lowerBound <= last.upperBound {
                    merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
                } else { merged.append(range) }
            }
            for range in merged {
                guard range.count <= 12000, let raw = target.rawRange(range) else { return nil }
                // Retain original element IDs and character offsets. Cropping
                // does not create new ownership or permit duplicate AX words.
                let parts = section.parts.filter { $0.range.overlaps(range) }.map {
                    Part(key: $0.key, range: ($0.range.lowerBound - range.lowerBound)..<($0.range.upperBound - range.lowerBound))
                }
                result.append(Section(text: target.original.substring(with: raw), parts: parts))
                guard result.count <= 128 else { return nil }
            }
        }
        return result
    }

    private static func sections(_ elements: [AccessibilitySnapshot.Element]) -> [Section] {
        let bounded = elements.indices.filter { !elements[$0].text.isEmpty }
        func section(_ indices: [Int]) -> Section {
            var offset = 0, parts: [Part] = []
            for index in indices {
                let length = Normalized(elements[index].text).characters.count
                parts.append(Part(key: index, range: offset..<(offset + length))); offset += length
            }
            return Section(text: indices.map { elements[$0].text }.joined(separator: "\n"), parts: parts)
        }
        var result = bounded.map { section([$0]) }
        // AX rectangles only propose optional neighboring reference contexts.
        // They never gate whether an OCR node may align with their text.
        let short = bounded.filter { elements[$0].bounds.height > 0 && elements[$0].bounds.height <= 120 }
        for group in spatialGroups(short, bounds: { elements[$0].bounds }, inline: false) where group.count > 1 {
            let candidate = section(OCRReadingOrder.indices(group, bounds: { elements[$0].bounds }))
            result.insert(candidate, at: 0)
        }
        return result
    }

    private static func spatialGroups(_ indices: [Int], bounds: (Int) -> CGRect, inline: Bool) -> [[Int]] {
        var remaining = Set(indices), groups: [[Int]] = []
        while let first = remaining.min() {
            remaining.remove(first)
            var group = [first], cursor = 0
            while cursor < group.count {
                let a = bounds(group[cursor]); cursor += 1
                for index in remaining.sorted() {
                    let b = bounds(index), h = min(a.height, b.height)
                    guard h > 0 else { continue }
                    let horizontalOverlap = min(a.maxX, b.maxX) - max(a.minX, b.minX)
                    let verticalGap = max(a.minY, b.minY) - min(a.maxY, b.maxY)
                    let sameColumn = abs(a.minX - b.minX) <= max(24, min(a.width, b.width) * 0.15)
                        && horizontalOverlap >= min(a.width, b.width) * 0.65
                        && verticalGap >= -h * 0.2 && verticalGap <= h * 4
                    let horizontalGap = max(a.minX, b.minX) - min(a.maxX, b.maxX)
                    let sameLine = inline && abs(a.midY - b.midY) <= h * 0.5
                        && horizontalGap >= -h * 0.2 && horizontalGap <= h * 3
                    if sameColumn || sameLine { remaining.remove(index); group.append(index) }
                }
            }
            groups.append(group)
        }
        return groups
    }

    private static func uniqueOccurrence(_ query: [Character], in text: [Character]) -> Int? {
        guard !query.isEmpty, query.count <= text.count else { return nil }
        var found: Int?
        for offset in 0...(text.count - query.count) where text[offset..<(offset + query.count)].elementsEqual(query) {
            if found != nil { return nil }; found = offset
        }
        return found
    }

    private static func anchorChain(_ source: [Character], _ target: [Character], seed: Int = 6,
        budget: inout Budget) -> [Anchor] {
        // Six-character seeds also retain short identifiers/times as anchors.
        // They are extended maximally, must be unique on both sides, and a gap
        // requires at least 24 characters of anchor support in its selected chain.
        guard source.count >= seed, target.count >= seed else { return [] }
        func index(_ text: [Character]) -> [String: Int] {
            var result: [String: Int] = [:]
            for offset in 0...(text.count - seed) {
                let key = String(text[offset..<(offset + seed)])
                result[key] = result[key] == nil ? offset : -1
            }
            return result
        }
        let a = index(source), b = index(target)
        var found = Set<Anchor>()
        var extended: [Int: [Range<Int>]] = [:]
        for (key, i) in a where i >= 0 {
            guard let j = b[key], j >= 0 else { continue }
            // Every seed inside the same exact run and source/target diagonal
            // extends to the same maximal anchor. Reuse that run instead of
            // scanning a long matching paragraph once for each seed.
            let diagonal = j - i
            if extended[diagonal, default: []].contains(where: {
                $0.lowerBound <= i && i + seed <= $0.upperBound
            }) { continue }
            var left = 0, length = seed
            while i - left > 0, j - left > 0, source[i - left - 1] == target[j - left - 1] { left += 1 }
            while i + length < source.count, j + length < target.count, source[i + length] == target[j + length] { length += 1 }
            found.insert(Anchor(source: i - left, target: j - left, length: length + left))
            extended[diagonal, default: []].append((i - left)..<(i + length))
            if found.count > 256 { budget.incomplete = true; return [] }
        }
        let anchors = found.sorted {
            if $0.source != $1.source { return $0.source < $1.source }
            if $0.target != $1.target { return $0.target < $1.target }
            return $0.length > $1.length
        }
        guard !anchors.isEmpty else { return [] }
        var scores = anchors.map(\.length), previous = Array(repeating: -1, count: anchors.count)
        var prefixTrim = Array(repeating: 0, count: anchors.count)
        for i in anchors.indices {
            for j in 0..<i {
                // Maximal matches can overlap around a doubled/missing letter.
                // Trim the next exact anchor equally on both sides so its suffix
                // stays exact and the repeated letter becomes a bounded gap.
                let trim = max(0, anchors[j].source + anchors[j].length - anchors[i].source,
                    anchors[j].target + anchors[j].length - anchors[i].target)
                guard anchors[i].length - trim >= seed else { continue }
                let score = scores[j] + anchors[i].length - trim
                if score > scores[i] {
                    scores[i] = score; previous[i] = j; prefixTrim[i] = trim
                }
            }
        }
        let ranked = anchors.indices.sorted { scores[$0] > scores[$1] }
        guard let best = ranked.first else { return [] }
        // Crossing paths with almost equal support indicate incompatible local order.
        for other in ranked.dropFirst() where previous[other] != best && previous[best] != other {
            if abs(scores[best] - scores[other]) <= 2,
               (anchors[best].source < anchors[other].source) != (anchors[best].target < anchors[other].target) { return [] }
        }
        var chain: [Anchor] = [], cursor = best
        while cursor >= 0 {
            let anchor = anchors[cursor], trim = prefixTrim[cursor]
            chain.append(Anchor(source: anchor.source + trim, target: anchor.target + trim, length: anchor.length - trim))
            cursor = previous[cursor]
        }
        return chain.reversed()
    }

    /// Whether a normalized offset is a word boundary in the original AX text.
    /// This prevents matches such as "Specifications" -> "Specification section".
    private static func wordBoundary(_ offset: Int, in text: Normalized) -> Bool {
        guard offset > 0, offset < text.characters.count else { return true }
        if text.ends[offset - 1] < text.starts[offset] { return true }
        func word(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }
        return !word(text.characters[offset - 1]) || !word(text.characters[offset])
    }

    private static func alignPassage(_ source: Normalized, _ target: Normalized,
        chain: [Anchor], budget: inout Budget, requireIdentity: Bool = true) -> Passage? {
        guard let first = chain.first, let last = chain.last else { return nil }
        let support = chain.reduce(0) { $0 + $1.length }
        if requireIdentity && support < 24 { return nil }
        var points: [Point] = [], edits = 0
        func append(_ alignment: Alignment, sourceOffset: Int, targetOffset: Int) {
            points += alignment.points.map { Point(source: $0.source + sourceOffset, target: $0.target + targetOffset) }
            edits += alignment.edits
        }
        // The first/last OCR word can be badly recognized. Align those edges
        // loosely, allowing AX-only exterior words to be skipped, not appended.
        guard let prefix = align(Array(source.characters[..<first.source]), Array(target.characters[..<first.target]),
            freeTargetPrefix: true, starts: (0...first.target).map { wordBoundary($0, in: target) }, budget: &budget) else { return nil }
        append(prefix, sourceOffset: 0, targetOffset: 0)
        for (index, anchor) in chain.enumerated() {
            points += (0...anchor.length).map { Point(source: anchor.source + $0, target: anchor.target + $0) }
            if index + 1 < chain.count {
                let next = chain[index + 1], a = (anchor.source + anchor.length)..<next.source,
                    b = (anchor.target + anchor.length)..<next.target
                guard let gap = align(Array(source.characters[a]), Array(target.characters[b]), budget: &budget) else { return nil }
                append(gap, sourceOffset: a.lowerBound, targetOffset: b.lowerBound)
            }
        }
        let sourceEnd = last.source + last.length, targetEnd = last.target + last.length
        let a = Array(source.characters[sourceEnd...]), b = Array(target.characters[targetEnd...])
        guard let reversed = align(Array(a.reversed()), Array(b.reversed()), freeTargetPrefix: true,
            starts: (0...b.count).map { wordBoundary(target.characters.count - $0, in: target) }, budget: &budget) else { return nil }
        let suffix = Alignment(points: reversed.points.reversed().map {
            Point(source: source.characters.count - $0.source, target: target.characters.count - $0.target)
        }, edits: reversed.edits)
        points += suffix.points; edits += suffix.edits
        guard let lower = points.first?.target, var upper = points.last?.target,
              lower < upper, wordBoundary(lower, in: target), wordBoundary(upper, in: target) else { return nil }
        // Punctuation belongs to an observed word; a following AX-only word does not.
        while upper < target.characters.count, upper > 0,
              target.ends[upper - 1] == target.starts[upper],
              !target.characters[upper].isLetter, !target.characters[upper].isNumber,
              target.characters[upper] != "_" {
            upper += 1
            points.append(Point(source: source.characters.count, target: upper))
        }
        let length = max(source.characters.count, upper - lower)
        // These are passage-identity checks. No word or gap has its own edit limit.
        // Independent exact anchors, order, location and competing-span checks
        // complement the aggregate similarity, including split/joined words.
        if requireIdentity {
            guard Double(support) / Double(length) >= 0.55,
                  Double(edits) / Double(length) <= 0.20 else { return nil }
        }
        let independent = support >= min(6, source.characters.count)
        return Passage(points: points, target: lower..<upper, independent: independent)
    }

    /// Unit-cost character alignment within an established anchor chain. Free AX
    /// prefixes must begin on an original word boundary. Traceback retains every
    /// source boundary so AX wording can be assigned to the existing OCR boxes.
    private static func align(_ source: [Character], _ target: [Character],
        freeTargetPrefix: Bool = false, starts: [Bool] = [], budget: inout Budget) -> Alignment? {
        let width = target.count + 1, cells = (source.count + 1) * width
        guard budget.consumeCells(cells) else { return nil }
        var previous = Array(0...target.count), trace = [UInt8](repeating: 0, count: cells)
        if freeTargetPrefix {
            previous = (0...target.count).map { starts[$0] ? 0 : cells + 1 }
        } else {
            for j in 1..<width { trace[j] = 3 }
        }
        for i in 1..<(source.count + 1) {
            var row = [Int](repeating: 0, count: width); row[0] = i; trace[i * width] = 2
            for j in 1..<width {
                let diagonal = previous[j - 1] + (source[i - 1] == target[j - 1] ? 0 : 1)
                let deletion = previous[j] + 1, insertion = row[j - 1] + 1
                // At an unanchored edge, equal-cost deletion of an OCR gutter
                // character is preferable to taking punctuation from its neighbor.
                let exact = source[i - 1] == target[j - 1]
                if diagonal <= deletion && diagonal <= insertion
                    && (!freeTargetPrefix || diagonal != deletion || exact) {
                    row[j] = diagonal; trace[i * width + j] = 1
                }
                else if deletion <= insertion { row[j] = deletion; trace[i * width + j] = 2 }
                else { row[j] = insertion; trace[i * width + j] = 3 }
            }
            previous = row
        }
        var i = source.count, j = target.count, points = [Point(source: i, target: j)]
        while i > 0 || (!freeTargetPrefix && j > 0) {
            switch trace[i * width + j] {
            case 1: i -= 1; j -= 1
            case 2: i -= 1
            case 3: j -= 1
            default: return nil
            }
            points.append(Point(source: i, target: j))
        }
        guard !freeTargetPrefix || starts[j] else { return nil }
        return Alignment(points: points.reversed(), edits: previous[target.count])
    }
}
