import CoreGraphics
import Foundation
import Shared

enum TimelineYouTubeLinkSupport {
    struct MarkdownCopyContext: Sendable {
        let windowName: String
        let urlString: String
    }

    struct OCRMatch: Sendable, Equatable {
        let titleText: String
        let channelText: String
    }

    private static let exactActionLabels: Set<String> = [
        "join",
        "subscribe",
        "subscribed",
        "share",
        "save",
        "download",
        "clip",
        "thanks",
        "more",
        "show more",
    ]

    static func copyContext(
        windowName: String?,
        urlString: String?
    ) -> MarkdownCopyContext? {
        guard let normalizedWindowName = normalizedNonEmptyString(windowName),
              let normalizedURLString = normalizedNonEmptyString(urlString),
              isMarkdownCopyCandidate(
                windowName: normalizedWindowName,
                urlString: normalizedURLString
              ) else {
            return nil
        }

        return MarkdownCopyContext(
            windowName: normalizedWindowName,
            urlString: normalizedURLString
        )
    }

    static func timestampedBrowserURLString(
        _ urlString: String,
        videoCurrentTime: Double?
    ) -> String {
        guard let videoCurrentTime,
              videoCurrentTime.isFinite,
              videoCurrentTime >= 0,
              let url = URL(string: urlString),
              isWatchURL(url),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return urlString
        }

        let seconds = Int(floor(videoCurrentTime))
        var queryItems = components.queryItems ?? []
        queryItems.removeAll { $0.name.caseInsensitiveCompare("t") == .orderedSame }
        queryItems.append(URLQueryItem(name: "t", value: "\(seconds)"))
        components.queryItems = queryItems
        return components.url?.absoluteString ?? urlString
    }

    static func urlContainsTimestamp(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString),
              isWatchURL(url),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return false
        }
        return components.queryItems?.contains(where: { $0.name.caseInsensitiveCompare("t") == .orderedSame }) == true
    }

    static func isMarkdownCopyCandidate(
        windowName: String?,
        urlString: String?
    ) -> Bool {
        guard let normalizedWindowName = normalizedNonEmptyString(windowName),
              normalizedWindowName.localizedCaseInsensitiveContains("youtube"),
              let normalizedURLString = normalizedNonEmptyString(urlString),
              let url = URL(string: normalizedURLString) else {
            return false
        }

        return isPageURL(url)
    }

    static func markdownClipboardString(
        channelName: String,
        titleText: String,
        urlString: String
    ) -> String {
        let safeChannelName = escapeMarkdownInlineText(
            sanitizedMarkdownClipboardComponent(sanitizedChannelName(channelName))
        )
        let safeTitleText = escapeMarkdownInlineText(sanitizedMarkdownClipboardComponent(titleText))
        let destination = urlString
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ")", with: "%29")

        return "\(safeChannelName) - [\(safeTitleText)](\(destination))"
    }

    static func resolveOCRMatch(
        windowName: String,
        nodes: [OCRNodeWithText]
    ) -> OCRMatch? {
        let titleCandidates = windowTitleCandidates(from: windowName)
        guard let titleNode = titleNode(
            titleCandidates: titleCandidates,
            nodes: nodes
        ) else {
            return nil
        }

        guard let titleText = normalizedNonEmptyString(titleNode.text),
              let channelText = channelText(
                titleCandidates: titleCandidates,
                titleNode: titleNode,
                nodes: nodes
              ) else {
            return nil
        }

        return OCRMatch(
            titleText: sanitizedMarkdownClipboardComponent(titleText),
            channelText: channelText
        )
    }

    private static func titleNode(
        titleCandidates: [String],
        nodes: [OCRNodeWithText]
    ) -> OCRNodeWithText? {
        let scoredNodes = nodes.compactMap { node -> (node: OCRNodeWithText, score: Double, hasChannel: Bool)? in
            guard let nodeText = normalizedNonEmptyString(node.text) else {
                return nil
            }

            let score = titleNodeScore(
                nodeText: nodeText,
                titleCandidates: titleCandidates,
                width: node.width
            )

            guard score >= 120 else {
                return nil
            }

            return (
                node: node,
                score: score,
                hasChannel: channelText(
                    titleCandidates: titleCandidates,
                    titleNode: node,
                    nodes: nodes
                ) != nil
            )
        }

        guard !scoredNodes.isEmpty else {
            return nil
        }

        let preferredNodes = scoredNodes.filter(\.hasChannel)
        let pool = preferredNodes.isEmpty ? scoredNodes : preferredNodes

        return pool.max { lhs, rhs in
            if lhs.score != rhs.score {
                return lhs.score < rhs.score
            }
            if lhs.node.width != rhs.node.width {
                return lhs.node.width < rhs.node.width
            }
            return lhs.node.y < rhs.node.y
        }?.node
    }

    private static func channelText(
        titleCandidates: [String],
        titleNode: OCRNodeWithText,
        nodes: [OCRNodeWithText]
    ) -> String? {
        let candidateNodes = nodesBelowTitle(
            titleNode: titleNode,
            nodes: nodes
        )
        guard !candidateNodes.isEmpty else {
            return nil
        }

        if let subscriberNode = candidateNodes.first(where: {
            isSubscriberText($0.text)
        }) {
            if let inlineChannelText = inlineChannelText(
                from: subscriberNode.text,
                titleCandidates: titleCandidates
            ) {
                return inlineChannelText
            }

            let nodesAboveSubscriber = candidateNodes.prefix { $0.id != subscriberNode.id }
            let alignedCandidate = nodesAboveSubscriber.compactMap { node -> (text: String, xGap: CGFloat, yGap: CGFloat)? in
                guard let text = usableChannelText(
                    from: node.text,
                    titleCandidates: titleCandidates
                ) else {
                    return nil
                }

                let yGap = max(0, subscriberNode.y - (node.y + node.height))
                return (
                    text: text,
                    xGap: abs(node.x - subscriberNode.x),
                    yGap: yGap
                )
            }.min { lhs, rhs in
                if lhs.xGap != rhs.xGap {
                    return lhs.xGap < rhs.xGap
                }
                return lhs.yGap < rhs.yGap
            }

            if let alignedCandidate {
                return alignedCandidate.text
            }
        }

        return candidateNodes.compactMap { node -> (text: String, score: Double)? in
            guard let text = usableChannelText(
                from: node.text,
                titleCandidates: titleCandidates
            ) else {
                return nil
            }

            return (
                text: text,
                score: channelNodeScore(
                    node: node,
                    titleNode: titleNode,
                    text: text
                )
            )
        }.max { lhs, rhs in
            if lhs.score != rhs.score {
                return lhs.score < rhs.score
            }
            return lhs.text.count < rhs.text.count
        }?.text
    }

    private static func nodesBelowTitle(
        titleNode: OCRNodeWithText,
        nodes: [OCRNodeWithText]
    ) -> [OCRNodeWithText] {
        let horizontalRange = metadataHorizontalRange(for: titleNode)
        let titleBottom = titleNode.y + titleNode.height
        let maximumVerticalGap = metadataVerticalGapLimit(for: titleNode)

        return nodes.filter { node in
            guard node.id != titleNode.id else {
                return false
            }
            let nodeRight = node.x + node.width
            guard nodeRight >= horizontalRange.lowerBound,
                  node.x <= horizontalRange.upperBound else {
                return false
            }

            let verticalGap = node.y - titleBottom
            return verticalGap >= -0.01 && verticalGap <= maximumVerticalGap
        }.sorted {
            if $0.y != $1.y {
                return $0.y < $1.y
            }
            return $0.x < $1.x
        }
    }

    private static func usableChannelText(
        from rawText: String,
        titleCandidates: [String]
    ) -> String? {
        guard let text = normalizedNonEmptyString(rawText) else {
            return nil
        }

        let normalizedText = comparisonText(text)
        guard !normalizedText.isEmpty else {
            return nil
        }
        guard !isURLLikeOCRText(text) else {
            return nil
        }
        guard !isSubscriberText(text) else {
            return nil
        }
        guard !isCountMetadataText(text) else {
            return nil
        }
        guard !isExactActionText(normalizedText) else {
            return nil
        }

        if titleCandidates.contains(where: {
            let normalizedTitle = comparisonText($0)
            return normalizedText == normalizedTitle || normalizedTitle.contains(normalizedText)
        }) {
            return nil
        }

        let letterCount = text.unicodeScalars.filter(CharacterSet.letters.contains).count
        guard letterCount >= 2 else {
            return nil
        }

        let cleanedText = cleanChannelDisplayText(text)
        guard let cleanedText = normalizedNonEmptyString(cleanedText) else {
            return nil
        }
        return sanitizedMarkdownClipboardComponent(cleanedText)
    }

    private static func channelNodeScore(
        node: OCRNodeWithText,
        titleNode: OCRNodeWithText,
        text: String
    ) -> Double {
        let titleBottom = titleNode.y + titleNode.height
        let verticalGap = max(0, node.y - titleBottom)
        let leadingOffset = abs(node.x - titleNode.x)

        var score = 320.0
        score -= Double(verticalGap) * 1_800.0
        score -= Double(leadingOffset) * 900.0
        score += Double(min(max(0, node.width), 0.24)) * 140.0
        score += Double(min(text.count, 28)) * 6.0

        if node.x + node.width < titleNode.x {
            score -= 120.0
        }

        return score
    }

    private static func titleNodeScore(
        nodeText: String,
        titleCandidates: [String],
        width: CGFloat
    ) -> Double {
        let normalizedNodeText = comparisonText(nodeText)
        guard !normalizedNodeText.isEmpty else { return -Double.greatestFiniteMagnitude }
        guard !isURLLikeOCRText(nodeText) else { return -Double.greatestFiniteMagnitude }

        var bestScore = -Double.greatestFiniteMagnitude

        for titleCandidate in titleCandidates {
            let normalizedTitle = comparisonText(titleCandidate)
            guard !normalizedTitle.isEmpty else { continue }

            if normalizedNodeText == normalizedTitle {
                bestScore = max(bestScore, 1000 + Double(width) * 100)
                continue
            }

            let titleTokens = Set(normalizedTitle.split(separator: " ").map(String.init))
            let nodeTokens = Set(normalizedNodeText.split(separator: " ").map(String.init))
            let overlapCount = titleTokens.intersection(nodeTokens).count
            guard overlapCount > 0 else { continue }

            let overlapRatio = Double(overlapCount) / Double(max(titleTokens.count, 1))
            let tokenDeltaPenalty = Double(abs(titleTokens.count - nodeTokens.count)) * 20
            let score = overlapRatio * 500 + Double(width) * 100 - tokenDeltaPenalty
            bestScore = max(bestScore, score)
        }

        return bestScore
    }

    private static func windowTitleCandidates(from windowName: String) -> [String] {
        let trimmedWindowName = sanitizedMarkdownClipboardComponent(windowName)
        guard !trimmedWindowName.isEmpty else { return [] }

        var candidates = [trimmedWindowName]

        if let range = trimmedWindowName.range(
            of: " - YouTube",
            options: [.caseInsensitive, .backwards]
        ) {
            let stripped = trimmedWindowName[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            if !stripped.isEmpty {
                candidates.append(stripped)
            }
        }

        return Array(NSOrderedSet(array: candidates)) as? [String] ?? candidates
    }

    private static func metadataHorizontalRange(for titleNode: OCRNodeWithText) -> ClosedRange<CGFloat> {
        let titleWidth = max(0, titleNode.width)
        let leftPadding = min(max(titleWidth * 0.12, 0.02), 0.05)
        let rightSpan = min(max(titleWidth * 0.9, 0.34), 0.52)
        let minX = max(0, titleNode.x - leftPadding)
        let maxX = min(titleNode.x + rightSpan, 0.62)
        return minX...max(minX, maxX)
    }

    private static func metadataVerticalGapLimit(for titleNode: OCRNodeWithText) -> CGFloat {
        min(max(titleNode.height * 5.0, 0.18), 0.24)
    }

    private static func inlineChannelText(
        from rawText: String,
        titleCandidates: [String]
    ) -> String? {
        let lowered = rawText.lowercased()
        guard let subscriberRange = lowered.range(of: "subscriber") else {
            return nil
        }

        let rawPrefix = rawText[..<subscriberRange.lowerBound]
        let cleanedPrefix = String(rawPrefix)
            .replacingOccurrences(
                of: "\\b\\d[\\d.,kKmM\\s]*$",
                with: "",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return usableChannelText(
            from: cleanedPrefix,
            titleCandidates: titleCandidates
        )
    }

    private static func isSubscriberText(_ text: String) -> Bool {
        comparisonText(text).contains("subscriber")
    }

    private static func isCountMetadataText(_ text: String) -> Bool {
        let normalizedText = comparisonText(text)
        let digitCount = text.unicodeScalars.filter(CharacterSet.decimalDigits.contains).count
        guard digitCount > 0 else {
            return false
        }

        return normalizedText.contains("views")
            || normalizedText.contains("ago")
            || normalizedText.contains("comment")
    }

    private static func isExactActionText(_ normalizedText: String) -> Bool {
        exactActionLabels.contains(normalizedText)
    }

    private static func cleanChannelDisplayText(_ text: String) -> String {
        text.trimmingCharacters(
            in: CharacterSet.whitespacesAndNewlines.union(
                CharacterSet(charactersIn: "•·-|:–—")
            )
        )
    }

    private static func sanitizedChannelName(_ channelName: String) -> String {
        let sanitized = sanitizedMarkdownClipboardComponent(channelName)
        return sanitized
            .replacingOccurrences(of: #"\s+[oO0]$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func sanitizedMarkdownClipboardComponent(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func escapeMarkdownInlineText(_ text: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(text.count)

        for character in text {
            switch character {
            case "\\", "*", "_", "[", "]", "(", ")":
                escaped.append("\\")
                escaped.append(character)
            default:
                escaped.append(character)
            }
        }

        return escaped
    }

    private static func comparisonText(_ text: String) -> String {
        let lowered = text.lowercased()
        let filteredScalars = lowered.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar)
                || CharacterSet.whitespacesAndNewlines.contains(scalar) {
                return Character(scalar)
            }
            return " "
        }

        return sanitizedMarkdownClipboardComponent(String(filteredScalars))
    }

    private static func isURLLikeOCRText(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return lowered.contains("http://")
            || lowered.contains("https://")
            || lowered.contains("www.")
            || lowered.contains("youtube.com/")
            || lowered.contains("youtu.be/")
            || lowered.contains("/watch")
            || lowered.contains("?v=")
    }

    private static func isWatchURL(_ url: URL) -> Bool {
        normalizedHost(url.host) == "youtube.com" && url.path.lowercased() == "/watch"
    }

    private static func isPageURL(_ url: URL) -> Bool {
        let host = normalizedHost(url.host)
        return host == "youtu.be" || host == "youtube.com" || host.hasSuffix(".youtube.com")
    }

    private static func normalizedNonEmptyString(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalizedHost(_ host: String?) -> String {
        guard var host else { return "" }
        host = host.lowercased()
        if host.hasPrefix("www.") {
            return String(host.dropFirst(4))
        }
        return host
    }
}
