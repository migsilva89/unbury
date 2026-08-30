import Foundation

/// Reading a saved page well enough to describe it.
///
/// Not a browser: no JavaScript runs, so a page that renders itself entirely in
/// the client gives up nothing. That is expected and handled — the description
/// then comes from the title and the domain, which is usually enough to find it
/// again later.
public enum PageReader {
    static let agent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) Unbury/1.0 (+https://unbury.migsilva.dev)"

    public struct Page: Sendable {
        public let text: String
        public let image: String?
        public let status: String     // "ok", or why it could not be read
        public var wasRead: Bool { status == "ok" }
    }

    public static func read(_ link: String, timeout: TimeInterval = 20) async -> Page {
        guard let url = URL(string: link) else { return Page(text: "", image: nil, status: "bad address") }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue(agent, forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            return Page(text: "", image: derivedImage(link), status: reason(error))
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            return Page(text: "", image: derivedImage(link), status: "refused (\(http.statusCode))")
        }
        let html = String(data: data.prefix(400_000), encoding: .utf8)
            ?? String(decoding: data.prefix(400_000), as: UTF8.self)

        var image = meta(html, "og:image", "twitter:image", "twitter:image:src")
        image = absolute(image, against: response.url ?? url)
        if image.isEmpty { image = derivedImage(link) ?? "" }

        let described = meta(html, "description", "og:description")
        var body = html.replacingOccurrences(
            of: "<(script|style|nav|footer|svg)[^>]*>[\\s\\S]*?</\\1>",
            with: " ", options: [.regularExpression, .caseInsensitive])
        body = body.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        body = body.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let text = String("\(described) || \(body)".prefix(4000))
        return Page(text: text, image: image.isEmpty ? nil : image, status: "ok")
    }

    /// A few big sites serve a JavaScript shell with no preview tags at all, but
    /// their thumbnail address is predictable from the link itself.
    public static func derivedImage(_ link: String) -> String? {
        guard link.contains("youtube.com") || link.contains("youtu.be") else { return nil }
        let patterns = ["v=", "youtu.be/", "/shorts/", "/embed/"]
        for pattern in patterns {
            guard let range = link.range(of: pattern) else { continue }
            let id = link[range.upperBound...].prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
            if id.count == 11 { return "https://i.ytimg.com/vi/\(id)/hqdefault.jpg" }
        }
        return nil
    }

    private static func meta(_ html: String, _ names: String...) -> String {
        for name in names {
            let pattern = "<meta[^>]+(?:property|name)=[\"']\(NSRegularExpression.escapedPattern(for: name))[\"'][^>]+content=[\"']([^\"']{4,600})"
            if let match = html.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
                let piece = String(html[match])
                if let quote = piece.range(of: "content=[\"']", options: .regularExpression) {
                    return String(piece[quote.upperBound...])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
        return ""
    }

    private static func absolute(_ image: String, against base: URL) -> String {
        if image.isEmpty || image.hasPrefix("http") { return image }
        if image.hasPrefix("//") { return "https:" + image }
        return URL(string: image, relativeTo: base)?.absoluteString ?? ""
    }

    private static func reason(_ error: Error) -> String {
        let code = (error as NSError).code
        switch code {
        case NSURLErrorTimedOut: return "timed out"
        case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost: return "host not found"
        case NSURLErrorNotConnectedToInternet: return "no internet"
        default: return "could not be read"
        }
    }
}
