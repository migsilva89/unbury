import Foundation

/// One saved link, as the app holds it. The vector lives apart from this — see
/// `UnburyStore` — because 623 records of 1024 floats do not belong in JSON.
public struct Bookmark: Codable, Identifiable, Sendable, Hashable {
    public let id: Int
    public var url: String
    public var title: String
    public var folder: String
    public var site: String
    public var savedOn: String       // yyyy-MM-dd, as the database stores it
    public var origin: String        // "brave", or the agent that added it
    public var summary: String
    public var tags: [String]
    public var image: String?
    public var indexedAt: String
    public var updatedAt: String
    /// Which browser profile this link was imported from, identified by the path
    /// of its bookmarks file. Records saved before profiles were recorded — and
    /// anything the Pi wrote — carry nothing here, and are left alone by the
    /// sweep that notices links a browser no longer has.
    public var sourceProfile: String?
    /// The day the link was found to be gone from that profile, or nil while it
    /// is still there. Deleting a bookmark in the browser must not delete it
    /// here: losing something because a browser was tidied up is worse than
    /// keeping a stale row. One optional date rather than a flag beside a date,
    /// so "gone with no date" cannot be written.
    public var goneFromBrowserOn: String?

    public init(id: Int, url: String, title: String, folder: String, site: String,
                savedOn: String, origin: String, summary: String, tags: [String],
                image: String?, indexedAt: String, updatedAt: String,
                sourceProfile: String? = nil, goneFromBrowserOn: String? = nil) {
        self.id = id; self.url = url; self.title = title; self.folder = folder
        self.site = site; self.savedOn = savedOn; self.origin = origin
        self.summary = summary; self.tags = tags; self.image = image
        self.indexedAt = indexedAt; self.updatedAt = updatedAt
        self.sourceProfile = sourceProfile; self.goneFromBrowserOn = goneFromBrowserOn
    }

    /// Whether to show the "no longer in your browser" note. Both new fields are
    /// optional so that a vault.json written before they existed still decodes.
    public var isGoneFromBrowser: Bool { goneFromBrowserOn != nil }

    /// What to show when the page never gave up a title.
    public var displayTitle: String {
        if !title.isEmpty { return title }
        let words = summary.split(separator: " ").prefix(7).joined(separator: " ")
        return words.isEmpty ? site : words + "…"
    }
}

/// A bookmark with how well it answered the question that was asked.
public struct Match: Identifiable, Sendable {
    public let bookmark: Bookmark
    /// Cosine similarity, or -1 when the list was not produced by a question.
    public let score: Double
    public var id: Int { bookmark.id }

    public init(bookmark: Bookmark, score: Double) {
        self.bookmark = bookmark
        self.score = score
    }
}
