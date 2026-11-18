import Foundation

public struct QueryToken: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case term
        case phrase
        case excludedTerm
        case excludedPhrase
        case ignoredShellOption
    }

    public let kind: Kind
    public let rawValue: String
    public let text: String

    public init(kind: Kind, rawValue: String, text: String) {
        self.kind = kind
        self.rawValue = rawValue
        self.text = text
    }

    public var sanitizedText: String {
        QueryTokenizer.sanitizeFTSTerm(text)
    }
}

public struct QueryTokenizer: Sendable {
    public init() {}

    public func tokenize(_ query: String) -> [QueryToken] {
        let rawTokens = rawTokens(from: query)
        let shellLikeQuery = looksShellLikeQuery(rawQuery: query, rawTokens: rawTokens)
        return rawTokens.compactMap { classify(rawToken: $0, shellLikeQuery: shellLikeQuery) }
    }

    public static func sanitizeFTSTerm(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: ":", with: "")
    }

    private func rawTokens(from query: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var activeQuote: Character?

        for char in query {
            if let openQuote = activeQuote {
                current.append(char)
                if char == openQuote {
                    tokens.append(current)
                    current = ""
                    activeQuote = nil
                }
                continue
            }

            if shouldStartQuotedToken(with: char, current: current) {
                if current == "-" {
                    current.append(char)
                    activeQuote = char
                    continue
                }
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                current.append(char)
                activeQuote = char
                continue
            }

            if char.isWhitespace {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                continue
            }

            current.append(char)
        }

        if !current.isEmpty {
            tokens.append(current)
        }

        return tokens
    }

    private func shouldStartQuotedToken(with character: Character, current: String) -> Bool {
        switch character {
        case "\"":
            return true
        case "'":
            return current.isEmpty || current == "-"
        default:
            return false
        }
    }

    private func classify(rawToken token: String, shellLikeQuery: Bool) -> QueryToken? {
        guard token != "-", !token.isEmpty else {
            return nil
        }

        if token.hasPrefix("-"), token.count > 1 {
            let rawExcluded = String(token.dropFirst())
            if let phrase = unwrappedQuotedText(rawExcluded) {
                return QueryToken(kind: .excludedPhrase, rawValue: token, text: phrase)
            }
            if shouldIgnoreDashPrefixedToken(token, shellLikeQuery: shellLikeQuery) {
                return QueryToken(kind: .ignoredShellOption, rawValue: token, text: token)
            }
            return QueryToken(kind: .excludedTerm, rawValue: token, text: rawExcluded)
        }

        if let phrase = unwrappedQuotedText(token) {
            return QueryToken(kind: .phrase, rawValue: token, text: phrase)
        }

        return QueryToken(kind: .term, rawValue: token, text: token)
    }

    private func unwrappedQuotedText(_ token: String) -> String? {
        guard token.count > 1, let first = token.first, let last = token.last, first == last else {
            return nil
        }
        guard first == "\"" || first == "'" else {
            return nil
        }
        return String(token.dropFirst().dropLast())
    }

    private func looksShellLikeQuery(rawQuery: String, rawTokens: [String]) -> Bool {
        if rawQuery.contains("'") ||
            rawQuery.contains("`") ||
            rawQuery.contains("|") ||
            rawQuery.contains(";") ||
            rawQuery.contains("&&") ||
            rawQuery.contains("||") ||
            rawQuery.contains("$(") ||
            rawQuery.contains("<") ||
            rawQuery.contains(">") {
            return true
        }

        if rawTokens.filter({ isObviouslyShellOptionToken($0) }).count >= 2 {
            return true
        }

        if let firstToken = rawTokens.first(where: { !$0.isEmpty }),
           isCommonShellCommandToken(firstToken),
           rawTokens.dropFirst().contains(where: { isObviouslyShellOptionToken($0) }) {
            return true
        }

        return false
    }

    private func shouldIgnoreDashPrefixedToken(_ token: String, shellLikeQuery: Bool) -> Bool {
        guard token.hasPrefix("-"), token.count > 1 else {
            return false
        }

        if token.hasPrefix("-\"") || token.hasPrefix("-'") {
            return false
        }

        if token.hasPrefix("--") {
            return isPotentialShellOptionToken(token)
        }

        return shellLikeQuery && isPotentialShellOptionToken(token)
    }

    private func isObviouslyShellOptionToken(_ token: String) -> Bool {
        guard token.hasPrefix("-"), token.count > 1 else {
            return false
        }

        if token.hasPrefix("-\"") || token.hasPrefix("-'") {
            return false
        }

        if token == "--" {
            return true
        }

        if token.hasPrefix("--") {
            return isLongShellOptionBody(String(token.dropFirst(2)))
        }

        let optionBody = String(token.dropFirst())
        let optionName = optionBody
            .split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init) ?? optionBody
        guard !optionName.isEmpty else {
            return false
        }

        if optionBody.contains("=") {
            return optionName.allSatisfy(isShellOptionCharacter)
        }

        return optionName.count <= 3 && optionName.allSatisfy(isShellOptionCharacter)
    }

    private func isPotentialShellOptionToken(_ token: String) -> Bool {
        guard token.hasPrefix("-"), token.count > 1 else {
            return false
        }

        if token.hasPrefix("-\"") || token.hasPrefix("-'") {
            return false
        }

        if token == "--" {
            return true
        }

        if token.hasPrefix("--") {
            return isLongShellOptionBody(String(token.dropFirst(2)))
        }

        return isSingleDashShellOptionBody(String(token.dropFirst()))
    }

    private func isLongShellOptionBody(_ body: String) -> Bool {
        let optionName = body
            .split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init) ?? body
        guard !optionName.isEmpty else {
            return false
        }

        return optionName.allSatisfy(isShellOptionCharacter)
    }

    private func isSingleDashShellOptionBody(_ body: String) -> Bool {
        let optionName = body
            .split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init) ?? body
        guard !optionName.isEmpty else {
            return false
        }

        return optionName.allSatisfy(isShellOptionCharacter)
    }

    private func isShellOptionCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "-"
    }

    private func isCommonShellCommandToken(_ token: String) -> Bool {
        let normalized = token
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))
            .lowercased()
        return Self.commonShellCommands.contains(normalized)
    }

    private static let commonShellCommands: Set<String> = [
        "awk",
        "bash",
        "cat",
        "cd",
        "cp",
        "curl",
        "defaults",
        "env",
        "export",
        "ffmpeg",
        "find",
        "git",
        "grep",
        "java",
        "javac",
        "ls",
        "mkdir",
        "mv",
        "node",
        "npm",
        "npx",
        "open",
        "osascript",
        "pip",
        "pip3",
        "pnpm",
        "python",
        "python3",
        "rg",
        "rm",
        "ruby",
        "scp",
        "sed",
        "sh",
        "ssh",
        "sqlite3",
        "swift",
        "tee",
        "touch",
        "uv",
        "wget",
        "xcodebuild",
        "xcrun",
        "yarn",
        "zsh"
    ]
}
