import Foundation

/// The local mirror of the vault: everything the app needs to answer a question
/// without a network, plus the vectors it needs to rank the answers.
///
/// Two files, on purpose. Metadata is JSON because it is 168 KB and worth being
/// able to read with your eyes. Vectors are a flat block of 32-bit floats because
/// 623 × 1024 of them in JSON would be twenty times the size and slow to parse.
/// Together they are around 3 MB — small enough that the whole vault loads in one
/// go and the search never touches disk again.
public actor UnburyStore {
    public struct Snapshot: Codable, Sendable {
        public var bookmarks: [Bookmark]
        public var dimensions: Int
        public var syncedAt: String?
        /// The addresses of links deleted here on purpose. Optional so that a
        /// vault.json written before deleting existed still decodes.
        public var discarded: [String]?
    }

    /// Where the mirror lives. The app was called Vault while it was being
    /// built, so a folder under the old name may already hold somebody's whole
    /// library — move it across rather than leaving them with an empty app and
    /// a paid import to do again.
    public static let defaultDirectory: URL = {
        // A second copy of the app, or a command, pointed at a copy of the vault:
        // a screen can then be driven and photographed without touching the real
        // one. Application Support is found through the user's record rather than
        // HOME, so setting HOME does not redirect it — this does. Unset, which is
        // every normal run, nothing below changes.
        if let override = ProcessInfo.processInfo.environment["UNBURY_DATA_DIR"],
           !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath,
                       isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        let home = base.appendingPathComponent("Unbury", isDirectory: true)
        let former = base.appendingPathComponent("Vault", isDirectory: true)
        let files = FileManager.default
        if !files.fileExists(atPath: home.path), files.fileExists(atPath: former.path) {
            try? files.moveItem(at: former, to: home)
        }
        return home
    }()

    private let directory: URL
    private var metaURL: URL { directory.appendingPathComponent("vault.json") }
    private var vectorURL: URL { directory.appendingPathComponent("vectors.bin") }

    public private(set) var bookmarks: [Bookmark] = []
    public private(set) var dimensions: Int = 0
    public private(set) var syncedAt: String?
    /// Row-major: bookmark i occupies [i*dimensions ..< (i+1)*dimensions].
    private var vectors: [Float] = []
    /// Addresses a person deleted here on purpose.
    ///
    /// Unbury never writes to a browser's bookmarks file, so a link deleted here
    /// is still sitting in the browser and the next import would offer it back —
    /// which reads as the delete not having worked. The address is kept, and the
    /// import passes over it. This is the opposite of `goneFromBrowserOn`, and
    /// deliberately so: the browser dropping a link is news, a person deleting
    /// one is an instruction.
    public private(set) var discarded: Set<String> = []

    func vectorsSlice(_ range: Range<Int>) -> ArraySlice<Float> { vectors[range] }

    public init(directory: URL = UnburyStore.defaultDirectory) {
        self.directory = directory
    }

    public var count: Int { bookmarks.count }
    public var isEmpty: Bool { bookmarks.isEmpty }

    public func load() throws {
        guard FileManager.default.fileExists(atPath: metaURL.path) else { return }
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: metaURL))
        bookmarks = snapshot.bookmarks
        dimensions = snapshot.dimensions
        syncedAt = snapshot.syncedAt
        discarded = Set(snapshot.discarded ?? [])
        let raw = try Data(contentsOf: vectorURL)
        vectors = raw.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let expected = bookmarks.count * dimensions
        guard vectors.count == expected else {
            // A half-written mirror is worse than none: it would rank against the
            // wrong rows silently. Drop it and let the next sync rebuild.
            bookmarks = []; vectors = []; dimensions = 0; syncedAt = nil
            discarded = []
            throw UnburyError.mirrorCorrupt(expected: expected, found: vectors.count)
        }
    }

    /// Add or update links, keeping the vector block in step. The vault is the
    /// list: a link that arrives twice updates rather than duplicating.
    public func upsert(_ incoming: [(Bookmark, [Float])]) throws {
        guard !incoming.isEmpty else { return }
        if dimensions == 0 { dimensions = incoming[0].1.count }
        var index: [String: Int] = [:]
        for (position, bookmark) in bookmarks.enumerated() { index[bookmark.url] = position }

        for (bookmark, vector) in incoming {
            guard vector.count == dimensions else { continue }
            if let position = index[bookmark.url] {
                bookmarks[position] = bookmark
                let start = position * dimensions
                vectors.replaceSubrange(start..<(start + dimensions), with: vector)
            } else {
                index[bookmark.url] = bookmarks.count
                bookmarks.append(bookmark)
                vectors.append(contentsOf: vector)
            }
        }
        try write()
    }

    /// Delete these records, and remember their addresses so that importing the
    /// same browser again does not quietly bring them back. Answers with the
    /// addresses actually deleted, which is how many rows really went.
    @discardableResult
    public func discard(ids: Set<Int>) throws -> [String] {
        let going = bookmarks.filter { ids.contains($0.id) }.map(\.url)
        guard !going.isEmpty else { return [] }
        for url in going { discarded.insert(url) }
        try remove(ids: ids)
        return going
    }

    /// Let a deleted address be imported again. The record itself is gone and
    /// its description was paid for once — this only lifts the block.
    @discardableResult
    public func restore(urls: [String]) throws -> Int {
        let lifted = urls.filter { discarded.remove($0) != nil }.count
        if lifted > 0 { try write() }
        return lifted
    }

    /// Take these records out, keeping the vector block in step.
    ///
    /// The two files are indexed against each other by position, so a record can
    /// never be dropped from one without the block being rebuilt: leaving a
    /// stale vector behind would shift every later record onto somebody else's
    /// numbers and silently wreck every search from then on.
    public func remove(ids: Set<Int>) throws {
        guard !ids.isEmpty, dimensions > 0 else { return }
        var keptBookmarks: [Bookmark] = []
        var keptVectors: [Float] = []
        for (position, bookmark) in bookmarks.enumerated() where !ids.contains(bookmark.id) {
            keptBookmarks.append(bookmark)
            let start = position * dimensions
            keptVectors.append(contentsOf: vectors[start..<(start + dimensions)])
        }
        bookmarks = keptBookmarks
        vectors = keptVectors
        try write()
    }

    /// The next free id. Ids are the vault's own, not the browser's — a browser
    /// has no stable id for a bookmark, and the citations in an answer need one.
    public func nextID() -> Int { (bookmarks.map(\.id).max() ?? 0) + 1 }

    public func replace(bookmarks: [Bookmark], vectors: [Float], dimensions: Int,
                        syncedAt: String) throws {
        self.bookmarks = bookmarks
        self.vectors = vectors
        self.dimensions = dimensions
        self.syncedAt = syncedAt
        // Erasing or pulling a whole library down is a fresh start, and a block
        // on an address nobody holds any more would only be a trap.
        self.discarded = []
        try write()
    }

    private func write() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let snapshot = Snapshot(bookmarks: bookmarks, dimensions: dimensions,
                                syncedAt: syncedAt ?? ISO8601DateFormatter().string(from: Date()),
                                discarded: discarded.isEmpty ? nil : discarded.sorted())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // Write beside, then move: a crash mid-write must not leave a torn mirror.
        let metaTemp = metaURL.appendingPathExtension("writing")
        let vectorTemp = vectorURL.appendingPathExtension("writing")
        try encoder.encode(snapshot).write(to: metaTemp)
        try vectors.withUnsafeBufferPointer { Data(buffer: $0) }.write(to: vectorTemp)
        _ = try? FileManager.default.replaceItemAt(metaURL, withItemAt: metaTemp)
        _ = try? FileManager.default.replaceItemAt(vectorURL, withItemAt: vectorTemp)
    }

    /// Rank every bookmark against a question already turned into a vector.
    ///
    /// No index, and none needed: this is one pass of multiply-and-add over a few
    /// megabytes. Measured at 623 records it is under a millisecond, and the wait
    /// a person feels is the second and a half spent asking the model for the
    /// question's vector, not this.
    /// Ranking inside the chosen tags, not ranking everything and then throwing
    /// away what does not carry them. A tag with 91 links would otherwise have to
    /// win a place in the global top sixty before it could be narrowed, which is
    /// the opposite of narrowing.
    ///
    /// Several tags narrow together — a record has to carry all of them — because
    /// two tags chosen one after the other is a person saying "and", not "or".
    /// Passing none searches everything.
    public func search(vector query: [Float], within tags: [String] = [], limit: Int = 60) -> [Match] {
        guard dimensions > 0, query.count == dimensions, !bookmarks.isEmpty else { return [] }
        var queryNorm: Float = 0
        for value in query { queryNorm += value * value }
        queryNorm = queryNorm.squareRoot()
        guard queryNorm > 0 else { return [] }

        var scored: [Match] = []
        scored.reserveCapacity(bookmarks.count)
        vectors.withUnsafeBufferPointer { buffer in
            for (index, bookmark) in bookmarks.enumerated() {
                if !Self.carries(bookmark, tags) { continue }
                let start = index * dimensions
                var dot: Float = 0, norm: Float = 0
                for offset in 0..<dimensions {
                    let value = buffer[start + offset]
                    dot += value * query[offset]
                    norm += value * value
                }
                let denominator = norm.squareRoot() * queryNorm
                let score = denominator > 0 ? Double(dot / denominator) : 0
                scored.append(Match(bookmark: bookmark, score: score))
            }
        }
        return scored.sorted { $0.score > $1.score }.prefix(limit).map { $0 }
    }

    public func recent(limit: Int = 14, tagged tags: [String] = []) -> [Bookmark] {
        bookmarks
            .filter { Self.carries($0, tags) }
            .sorted { $0.savedOn > $1.savedOn }
            .prefix(limit).map { $0 }
    }

    /// One screenful of the links carrying every one of these tags, newest
    /// first, with how many there are in all.
    ///
    /// A tag can hold hundreds of links, and handing all of them to the
    /// interface at once froze it for fourteen seconds. The screen asks for what
    /// it can draw and asks again when the person scrolls.
    public struct Page: Sendable {
        public let bookmarks: [Bookmark]
        public let offset: Int
        /// How many carry the tags in all, not how many are in this page.
        public let total: Int
        public var hasMore: Bool { offset + bookmarks.count < total }
    }

    public func page(tagged tags: [String] = [], offset: Int = 0, limit: Int = 60) -> Page {
        let all = bookmarks
            .filter { Self.carries($0, tags) }
            .sorted { $0.savedOn > $1.savedOn }
        let start = min(max(offset, 0), all.count)
        let end = min(start + max(limit, 0), all.count)
        return Page(bookmarks: Array(all[start..<end]), offset: start, total: all.count)
    }

    /// Does this record carry every one of these tags? No tags means everything.
    private static func carries(_ bookmark: Bookmark, _ tags: [String]) -> Bool {
        guard !tags.isEmpty else { return true }
        return tags.allSatisfy(bookmark.tags.contains)
    }

    /// The stored record for a link, found by its address.
    ///
    /// An answer cites the links it used, and pointing at one of them has to land
    /// on the same record — searching for its title again is a different question
    /// and often finds nothing.
    public func bookmark(url: String) -> Bookmark? {
        bookmarks.first { $0.url == url }
    }

    /// The same for a handful of addresses at once, in the order asked for, with
    /// anything the vault does not hold left out.
    public func bookmarks(urls: [String]) -> [Bookmark] {
        guard !urls.isEmpty else { return [] }
        var byURL: [String: Bookmark] = [:]
        for bookmark in bookmarks { byURL[bookmark.url] = bookmark }
        return urls.compactMap { byURL[$0] }
    }

    /// What one sweep of the browser changed.
    public struct BrowserSweep: Sendable {
        /// Links that were there last time and are not any more.
        public let gone: Int
        /// Links that had been marked gone and are back.
        public let returned: Int
        /// Records that predate profiles being recorded and have just been
        /// recognised as belonging to one of the profiles read.
        public let claimed: Int

        public var changedAnything: Bool { gone + returned + claimed > 0 }
    }

    /// Notice which links a browser no longer has, without losing them.
    ///
    /// `profiles` is the bookmarks files actually read and `urls` everything they
    /// held between them. Only records stamped with one of those profiles are
    /// judged: reading one profile must not declare every link of another one
    /// gone. Records from before profiles were recorded are claimed by a profile
    /// the moment it is seen holding them, and are never marked gone until then —
    /// unattributed is a reason to say nothing, not a reason to guess.
    ///
    /// `noticedOn` is today unless a caller says otherwise, which only a test does.
    public func reconcileBrowser(profiles: Set<String>, urls: Set<String>,
                                 noticedOn: String? = nil) throws -> BrowserSweep {
        guard !profiles.isEmpty else { return BrowserSweep(gone: 0, returned: 0, claimed: 0) }
        let noticed = noticedOn ?? Self.today()
        var gone = 0, returned = 0, claimed = 0

        for position in bookmarks.indices {
            let bookmark = bookmarks[position]
            guard bookmark.origin == "browser" else { continue }
            let present = urls.contains(bookmark.url)

            guard let profile = bookmark.sourceProfile else {
                // Nobody stamped this one. If a single profile was read and it
                // holds the link, that settles whose it is; with several read at
                // once it does not, so it stays unattributed and unjudged.
                if present, profiles.count == 1 {
                    bookmarks[position].sourceProfile = profiles.first
                    claimed += 1
                }
                continue
            }
            guard profiles.contains(profile) else { continue }

            if present, bookmark.goneFromBrowserOn != nil {
                bookmarks[position].goneFromBrowserOn = nil
                returned += 1
            } else if !present, bookmark.goneFromBrowserOn == nil {
                bookmarks[position].goneFromBrowserOn = noticed
                gone += 1
            }
        }

        let sweep = BrowserSweep(gone: gone, returned: returned, claimed: claimed)
        if sweep.changedAnything { try write() }
        return sweep
    }

    /// yyyy-MM-dd, the shape every other date in a record already has.
    private static func today() -> String {
        let format = DateFormatter()
        format.dateFormat = "yyyy-MM-dd"
        return format.string(from: Date())
    }

    /// Every tag with how many links carry it. The home screen reads the shape
    /// of a collection from this, so it counts all of them — the long tail is
    /// the point, not an inconvenience.
    public func tagCounts() -> [String: Int] {
        var counts: [String: Int] = [:]
        for bookmark in bookmarks {
            for tag in bookmark.tags { counts[tag, default: 0] += 1 }
        }
        return counts
    }
}

public enum UnburyError: LocalizedError {
    /// What OpenRouter said, said back in words.
    ///
    /// Raw JSON in front of a person is not an error message: the three things
    /// that actually go wrong here — no credit, a spending cap on the key, a bad
    /// key — each have a different fix, and none of them is obvious from a
    /// status code.
    public static func explain(_ status: Int, _ body: Data) -> UnburyError {
        let text = String(data: body, encoding: .utf8) ?? ""
        switch status {
        case 401:
            return .badResponse("That OpenRouter key was not accepted. Check it in settings.")
        case 402:
            return .badResponse("Your OpenRouter account is out of credit. Top up at openrouter.ai/credits and try again.")
        case 403 where text.contains("limit"):
            return .badResponse("This key has a spending limit and has reached it. Raise or remove the limit at openrouter.ai/keys — the money on your account is fine.")
        case 429:
            return .badResponse("OpenRouter is asking us to slow down. Wait a moment and try again.")
        case 500...599:
            return .badResponse("OpenRouter is having trouble (\(status)). Not your side — try again shortly.")
        default:
            return .badResponse("OpenRouter refused the request (\(status)).")
        }
    }

    case mirrorCorrupt(expected: Int, found: Int)
    case noKey
    case badResponse(String)

    public var errorDescription: String? {
        switch self {
        case let .mirrorCorrupt(expected, found):
            return "The local copy was incomplete (\(found) numbers where \(expected) were expected) and was discarded. Sync again."
        case .noKey:
            return "No OpenRouter key. Add one in settings."
        case let .badResponse(detail):
            return detail
        }
    }
}

public extension UnburyStore {
    /// The first few numbers of one record's vector, for the detail view. Kept
    /// here because only the store knows how the block is laid out.
    func vectorHead(for id: Int, count: Int) -> [Float] {
        guard let index = bookmarks.firstIndex(where: { $0.id == id }), dimensions > 0
        else { return [] }
        let start = index * dimensions
        let end = min(start + count, start + dimensions)
        return Array(vectorsSlice(start..<end))
    }
}
