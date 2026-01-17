import Foundation

/// Extracts browser URLs from OCR text
/// Used as a fallback when Accessibility API cannot retrieve the URL
struct URLExtractor {

    // MARK: - URL Extraction

    /// Extract URL from OCR chrome text (top 5% of screen)
    /// - Parameter chromeText: Text from UI chrome regions (status bar, address bar)
    /// - Returns: Extracted URL if found, nil otherwise
    ///
    /// Note: Only searches in chrome text (top 5% area where address bar is located).
    /// Does not search full page text as the address bar is always in the top chrome area.
    static func extractURL(chromeText: String?) -> String? {
        // Only search in chrome text (top 5% - address bar location)
        guard let chrome = chromeText, !chrome.isEmpty else {
            return nil
        }

        return findURL(in: chrome)
    }

    // MARK: - URL Pattern Matching

    /// Find URL in text using regex patterns
    /// - Parameter text: Text to search
    /// - Returns: First valid URL found, nil if none
    private static func findURL(in text: String) -> String? {
        // Pattern 1: Full URLs with protocol
        let fullURLPattern = #"https?://[^\s<>"{}|\\^`\[\]]+"#
        if let url = extractFirstMatch(in: text, pattern: fullURLPattern) {
            if isValidURL(url) {
                return cleanURL(url)
            }
        }

        // Pattern 2: Domain-like patterns (www.example.com or example.com)
        // Common in address bars where protocol might be hidden
        let domainPattern = #"(?:www\.)?[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)+(?:/[^\s]*)?"#
        if let domain = extractFirstMatch(in: text, pattern: domainPattern) {
            // Only accept if it has a valid TLD
            if hasValidTLD(domain) && isValidDomain(domain) {
                // Add https:// prefix if missing
                return domain.hasPrefix("http") ? cleanURL(domain) : "https://\(cleanURL(domain))"
            }
        }

        return nil
    }

    /// Extract first regex match from text
    private static func extractFirstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }

        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range) else {
            return nil
        }

        guard let matchRange = Range(match.range, in: text) else {
            return nil
        }

        return String(text[matchRange])
    }

    // MARK: - URL Validation

    /// Validate that URL is well-formed and not garbage OCR text
    private static func isValidURL(_ urlString: String) -> Bool {
        // Must have protocol
        guard urlString.hasPrefix("http://") || urlString.hasPrefix("https://") else {
            return false
        }

        // Must have domain after protocol
        let afterProtocol = urlString.replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")

        guard !afterProtocol.isEmpty else {
            return false
        }

        // Must have valid TLD
        guard hasValidTLD(afterProtocol) else {
            return false
        }

        // Validate with Foundation URL
        guard let url = URL(string: urlString),
              let host = url.host,
              !host.isEmpty else {
            return false
        }

        return true
    }

    /// Validate that domain is well-formed
    private static func isValidDomain(_ domain: String) -> Bool {
        // Minimum domain length (e.g., "a.co")
        guard domain.count >= 4 else {
            return false
        }

        // Must contain at least one dot
        guard domain.contains(".") else {
            return false
        }

        // Must not start or end with dot
        guard !domain.hasPrefix(".") && !domain.hasSuffix(".") else {
            return false
        }

        // Must not have consecutive dots
        guard !domain.contains("..") else {
            return false
        }

        return true
    }

    /// Check if URL/domain has a valid top-level domain
    private static func hasValidTLD(_ urlOrDomain: String) -> Bool {
        let validTLDs: Set<String> = [
            // Generic TLDs
            "com", "org", "net", "edu", "gov", "mil", "int",
            "info", "biz", "name", "pro", "museum", "coop", "aero",

            // Common country TLDs
            "us", "uk", "ca", "au", "de", "fr", "jp", "cn", "in", "br",
            "ru", "it", "es", "nl", "se", "no", "dk", "fi", "pl", "ch",

            // New generic TLDs
            "io", "ai", "app", "dev", "tech", "online", "site", "website",
            "store", "shop", "blog", "news", "media", "cloud", "digital",

            // Common local TLDs
            "local", "localhost", "test", "example", "invalid"
        ]

        // Extract domain from URL if it has protocol
        let domain = urlOrDomain
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .components(separatedBy: "/").first ?? urlOrDomain

        // Extract TLD (last part after final dot)
        let components = domain.components(separatedBy: ".")
        guard let tld = components.last?.lowercased() else {
            return false
        }

        return validTLDs.contains(tld)
    }

    /// Clean URL by removing common OCR artifacts
    private static func cleanURL(_ url: String) -> String {
        var cleaned = url

        // Remove trailing punctuation that might be OCR errors
        let trailingChars = CharacterSet(charactersIn: ".,;:!?")
        cleaned = cleaned.trimmingCharacters(in: trailingChars)

        // Remove common OCR artifacts at the end
        let artifacts = ["...", "..", ".,", ",."]
        for artifact in artifacts {
            if cleaned.hasSuffix(artifact) {
                cleaned = String(cleaned.dropLast(artifact.count))
            }
        }

        return cleaned
    }
}
