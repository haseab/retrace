import Foundation

/// Captured/OCR text is untrusted input, even when opening it requires a click.
enum CapturedURLPolicy {
    static func webURL(_ value: String) -> URL? {
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }
}
