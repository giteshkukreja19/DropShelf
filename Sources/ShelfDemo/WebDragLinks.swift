import AppKit

enum WebDragLinks {
    static let types: [NSPasteboard.PasteboardType] = [
        .URL, .string, .init("text/uri-list"), .init("WebURLsWithTitlesPboardType"),
        .init("NSURLPboardType"), .init("public.url-name"), .init("public.utf8-plain-text"),
        .init("public.utf16-external-plain-text"), .init("public.html"),
        .init("text/html"), .init("Apple URL pasteboard type")
    ]

    static func open(_ item: ShelfItem) -> Bool {
        guard item.type == .text, let text = item.textContent,
              let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return false }
        return NSWorkspace.shared.open(url)
    }

    static func read(_ board: NSPasteboard) -> [URL] {
        var candidates = (board.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? []).map { $0.absoluteString }
        for type in types where !(["public.html", "text/html", "public.url-name"].contains(type.rawValue)) {
            if let value = board.string(forType: type) {
                candidates.append(contentsOf: value.components(separatedBy: .newlines))
            }
        }
        if let groups = board.propertyList(forType: NSPasteboard.PasteboardType("WebURLsWithTitlesPboardType")) as? [[String]], let urls = groups.first {
            candidates.append(contentsOf: urls)
        }
        for item in board.pasteboardItems ?? [] {
            for type in types where !(["public.html", "text/html", "public.url-name"].contains(type.rawValue)) {
                if let value = item.string(forType: type) { candidates.append(contentsOf: value.components(separatedBy: .newlines)) }
                if let values = item.propertyList(forType: type) as? [String] { candidates.append(contentsOf: values) }
            }
        }
        // Browser HTML fragments can contain an explicit anchor even when
        // no public.url representation is offered. Never fetch remote HTML.
        if candidates.isEmpty || !candidates.contains(where: { $0.hasPrefix("https://") || $0.hasPrefix("http://") }) {
            let pattern = #"(?i)<a\b[^>]*\bhref\s*=\s*["'](https?://[^"']+)["']"#
            if let regex = try? NSRegularExpression(pattern: pattern) {
                for type in [NSPasteboard.PasteboardType("public.html"), .init("text/html")] {
                    let fragments = [board.string(forType: type)].compactMap { $0 } +
                        (board.pasteboardItems ?? []).compactMap { $0.string(forType: type) }
                    for html in fragments {
                        for match in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
                            if let range = Range(match.range(at: 1), in: html) {
                                candidates.append(String(html[range]).replacingOccurrences(of: "&amp;", with: "&"))
                            }
                        }
                    }
                }
            }
        }
        var seen = Set<URL>()
        return candidates.compactMap { raw in
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.contains(where: { $0.isWhitespace }), let url = URL(string: text),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  url.host != nil, seen.insert(url).inserted else { return nil }
            return url
        }
    }
}
