import Foundation

/// Extracts http(s) links from message bodies for the media browser's Links
/// tab. `NSDataDetector` (not a regex) so markdown suffixes, angle brackets
/// and trailing punctuation resolve the way the OS link-tap path resolves
/// them; this wrapper pins the scheme filter — agent chats are full of
/// file://, mailto: and ssh: strings nobody wants in a link list.
public enum LinkExtractor {
    public static func links(in body: String) -> [URL] {
        guard let detector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        let range = NSRange(body.startIndex..., in: body)
        return detector.matches(in: body, options: [], range: range).compactMap { match in
            guard let url = match.url,
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else { return nil }
            return url
        }
    }
}
