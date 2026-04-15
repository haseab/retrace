import App
import AppKit
import AVFoundation
import Database
import Foundation
import ImageIO
import Processing
import Shared
import SwiftUI

extension SimpleTimelineViewModel {
    // MARK: - Selection, OCR, and Highlighting

    func setURLBoundingBox(_ boundingBox: URLBoundingBox?) {
        overlayPresentationState.urlBoundingBox = boundingBox
    }

    func setHyperlinkMatches(_ matches: [OCRHyperlinkMatch]) {
        overlayPresentationState.hyperlinkMatches = matches
    }

    func setFrameMousePosition(_ point: CGPoint?) {
        overlayPresentationState.frameMousePosition = point
    }

    func setOCRStatus(_ status: OCRProcessingStatus) {
        overlayPresentationState.ocrStatus = status
    }

    func setTextSelection(
        start: (nodeID: Int, charIndex: Int)?,
        end: (nodeID: Int, charIndex: Int)?
    ) {
        overlayPresentationState.selectionStart = start
        overlayPresentationState.selectionEnd = end
    }

    public func showSearchHighlight(query: String) {
        showSearchHighlight(query: query, mode: .matchedTextRanges, delay: 0.5)
    }

    func showSearchHighlight(
        query: String,
        mode: SearchHighlightMode,
        delay: TimeInterval = 0.5,
        preserveExistingPresentation: Bool = false
    ) {
        let shouldPreserveVisibleState = preserveExistingPresentation && isShowingSearchHighlight
        cancelPendingSearchHighlightTasks()
        if !shouldPreserveVisibleState {
            isShowingSearchHighlight = false
        }
        searchHighlightQuery = query
        searchHighlightMode = mode

        guard delay > 0 else {
            isShowingSearchHighlight = true
            return
        }

        pendingSearchHighlightRevealTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay), clock: .continuous)
            guard !Task.isCancelled, let self else { return }
            guard self.searchHighlightQuery == query, self.searchHighlightMode == mode else { return }
            self.isShowingSearchHighlight = true
            self.pendingSearchHighlightRevealTask = nil
        }
    }

    public func clearSearchHighlight() {
        invalidateSearchResultNavigation()
        cancelPendingSearchHighlightTasks()

        let previousQuery = searchHighlightQuery
        withAnimation(.easeOut(duration: 0.3)) {
            isShowingSearchHighlight = false
        }
        searchHighlightMode = .matchedTextRanges

        guard previousQuery != nil else {
            searchHighlightQuery = nil
            return
        }

        pendingSearchHighlightResetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300), clock: .continuous)
            guard !Task.isCancelled, let self else { return }
            guard !self.isShowingSearchHighlight else { return }
            guard self.searchHighlightQuery == previousQuery else { return }
            guard self.searchHighlightMode == .matchedTextRanges else { return }
            self.searchHighlightQuery = nil
            self.pendingSearchHighlightResetTask = nil
        }
    }

    public func resetSearchHighlightState() {
        clearSearchHighlightImmediately()
    }

    func clearSearchHighlightImmediately() {
        invalidateSearchResultNavigation()
        cancelPendingSearchHighlightTasks()
        isShowingSearchHighlight = false
        searchHighlightQuery = nil
        searchHighlightMode = .matchedTextRanges
    }

    public var searchHighlightNodes: [(node: OCRNodeWithText, ranges: [Range<String.Index>])] {
        guard let query = searchHighlightQuery, !query.isEmpty, isShowingSearchHighlight else {
            return []
        }

        return Self.searchHighlightMatches(
            in: ocrNodes,
            query: query,
            mode: searchHighlightMode
        )
    }

    private static let searchHighlightLineTolerance: CGFloat = 0.02

    func highlightedSearchTextLines(
        from matches: [(node: OCRNodeWithText, ranges: [Range<String.Index>])]? = nil
    ) -> [String] {
        let sourceMatches = matches ?? searchHighlightNodes
        guard !sourceMatches.isEmpty else { return [] }

        var seenNodeIDs = Set<Int>()
        let uniqueNodes = sourceMatches.compactMap { match -> OCRNodeWithText? in
            guard seenNodeIDs.insert(match.node.id).inserted else { return nil }
            return match.node
        }
        guard !uniqueNodes.isEmpty else { return [] }

        let sortedNodes = uniqueNodes.sorted { lhs, rhs in
            if abs(lhs.y - rhs.y) > Self.searchHighlightLineTolerance {
                return lhs.y < rhs.y
            }
            return lhs.x < rhs.x
        }

        var groupedLines: [[OCRNodeWithText]] = []
        var currentLine: [OCRNodeWithText] = []
        var currentLineAverageY: CGFloat?

        for node in sortedNodes {
            if let lineY = currentLineAverageY,
               abs(node.y - lineY) <= Self.searchHighlightLineTolerance {
                currentLine.append(node)
                let lineCount = CGFloat(currentLine.count)
                currentLineAverageY = ((lineY * (lineCount - 1)) + node.y) / lineCount
            } else {
                if !currentLine.isEmpty {
                    groupedLines.append(currentLine)
                }
                currentLine = [node]
                currentLineAverageY = node.y
            }
        }

        if !currentLine.isEmpty {
            groupedLines.append(currentLine)
        }

        return groupedLines.compactMap { lineNodes in
            let lineText = lineNodes
                .sorted { $0.x < $1.x }
                .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            return lineText.isEmpty ? nil : lineText
        }
    }

    func copySearchHighlightedTextByLine(
        from matches: [(node: OCRNodeWithText, ranges: [Range<String.Index>])]? = nil
    ) {
        let lines = highlightedSearchTextLines(from: matches)
        guard !lines.isEmpty else {
            showToast("No highlighted text to copy", icon: "exclamationmark.circle.fill")
            return
        }

        let textToCopy = lines.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(textToCopy, forType: .string)
        showToast("Highlighted text copied", icon: "doc.on.doc.fill")
        DashboardViewModel.recordTextCopy(coordinator: coordinator, text: textToCopy)
    }

    private enum SearchHighlightToken {
        case term(String)
        case phrase(String)
    }

    private static let searchResultHighlightStopwords: Set<String> = [
        "a", "an", "and", "as", "at",
        "be", "but", "by",
        "for", "from",
        "if", "in", "into", "is", "it",
        "of", "on", "or",
        "the", "to",
        "with"
    ]

    static func searchHighlightMatches(
        in nodes: [OCRNodeWithText],
        query: String,
        mode: SearchHighlightMode
    ) -> [(node: OCRNodeWithText, ranges: [Range<String.Index>])] {
        let queryTokens = tokenizeSearchHighlightQuery(query, mode: mode)
        guard !queryTokens.isEmpty else { return [] }

        var matchingNodes: [(node: OCRNodeWithText, ranges: [Range<String.Index>])] = []

        for node in nodes {
            var ranges: [Range<String.Index>] = []

            for token in queryTokens {
                ranges.append(contentsOf: rangesForSearchHighlightToken(token, in: node.text))
            }

            if !ranges.isEmpty {
                matchingNodes.append((
                    node: node,
                    ranges: mode == .matchedNodes ? [] : ranges
                ))
            }
        }

        return matchingNodes
    }

    private static func tokenizeSearchHighlightQuery(
        _ query: String,
        mode: SearchHighlightMode
    ) -> [SearchHighlightToken] {
        let normalizedQuery = query
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else { return [] }

        if mode == .matchedNodes {
            var tokens: [SearchHighlightToken] = []
            var seen = Set<String>()

            func appendToken(_ token: SearchHighlightToken, key: String) {
                if seen.insert(key).inserted {
                    tokens.append(token)
                }
            }

            if normalizedQuery.hasPrefix("\""),
               normalizedQuery.hasSuffix("\""),
               normalizedQuery.count > 2 {
                let phrase = String(normalizedQuery.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
                if !phrase.isEmpty {
                    appendToken(.phrase(phrase), key: "p:\(phrase)")
                }
                return tokens
            }

            for rawTerm in normalizedQuery.split(whereSeparator: \.isWhitespace) {
                let rawValue = String(rawTerm)
                if isIgnoredSearchResultShellToken(rawValue) || rawValue.hasPrefix("-") {
                    continue
                }

                let cleaned = rawValue
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleaned.isEmpty else { continue }
                if shouldIgnoreSearchResultTerm(cleaned) {
                    continue
                }

                appendToken(.term(cleaned), key: "t:\(cleaned)")
            }

            return tokens
        }

        return normalizedQuery
            .split(separator: ",", omittingEmptySubsequences: false)
            .compactMap { rawComponent in
                let value = rawComponent
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                guard !value.isEmpty else { return nil }
                return .phrase(value)
            }
    }

    private static func rangesForSearchHighlightToken(
        _ token: SearchHighlightToken,
        in text: String
    ) -> [Range<String.Index>] {
        switch token {
        case .term(let term):
            let exactWordRanges = allWholeWordRanges(of: term, in: text)
            if !exactWordRanges.isEmpty {
                return exactWordRanges
            }
            return allRanges(of: term, in: text)
        case .phrase(let phrase):
            return allRanges(of: phrase, in: text)
        }
    }

    private static func allWholeWordRanges(
        of needle: String,
        in haystack: String
    ) -> [Range<String.Index>] {
        guard !needle.isEmpty else { return [] }
        let pattern = #"\b\#(NSRegularExpression.escapedPattern(for: needle))\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }

        let fullRange = NSRange(haystack.startIndex..<haystack.endIndex, in: haystack)
        return regex.matches(in: haystack, options: [.withTransparentBounds], range: fullRange)
            .compactMap { Range($0.range, in: haystack) }
    }

    private static func isIgnoredSearchResultShellToken(_ token: String) -> Bool {
        guard token.hasPrefix("-"), token.count > 1 else { return false }
        if token.hasPrefix("-\"") || token.hasPrefix("-'") {
            return false
        }

        if token == "--" {
            return true
        }

        let optionBody = token.hasPrefix("--") ? String(token.dropFirst(2)) : String(token.dropFirst())
        let optionName = optionBody
            .split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init) ?? optionBody
        guard !optionName.isEmpty else { return false }

        if token.hasPrefix("--") {
            return optionName.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
        }

        return optionName.count <= 3 && optionName.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
    }

    private static func shouldIgnoreSearchResultTerm(_ term: String) -> Bool {
        let normalized = term.lowercased()
        if normalized.count == 1 {
            return true
        }
        if normalized.allSatisfy(\.isNumber) {
            return true
        }
        return Self.searchResultHighlightStopwords.contains(normalized)
    }

    private static func allRanges(of needle: String, in haystack: String) -> [Range<String.Index>] {
        guard !needle.isEmpty else { return [] }

        var ranges: [Range<String.Index>] = []
        var searchStartIndex = haystack.startIndex

        while searchStartIndex < haystack.endIndex,
              let range = haystack.range(
                of: needle,
                options: [.caseInsensitive, .diacriticInsensitive],
                range: searchStartIndex..<haystack.endIndex,
                locale: .current
              ) {
            ranges.append(range)
            searchStartIndex = range.upperBound
        }

        return ranges
    }
}
