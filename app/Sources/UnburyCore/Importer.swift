import Foundation

/// Turning browser bookmarks into vault records: fetch the page, have a model
/// say what it is, turn that into a vector, store it.
///
/// Native, because an app that needs a Python environment beside it to do its
/// main job is not an app. It also means the import can be watched and stopped,
/// which a shelled-out script never allowed.
public actor Importer {
    public struct Candidate: Identifiable, Sendable, Hashable {
        public let url: String
        public let title: String
        public let folder: String
        public let savedOn: String
        public var id: String { url }
        public var site: String {
            guard let host = URL(string: url)?.host else { return "?" }
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }

        public init(url: String, title: String, folder: String, savedOn: String) {
            self.url = url; self.title = title; self.folder = folder; self.savedOn = savedOn
        }
    }

    public struct Progress: Sendable {
        public let done: Int
        public let total: Int
        public let current: String       // the site being read right now
        public let note: String          // what happened to the last one
        public let spent: Double
    }

    private let store: UnburyStore
    /// Vectors. Always bought, from whichever service was chosen.
    private let client: OpenRouter
    /// Descriptions, which are no longer necessarily bought: a model on
    /// OpenRouter, or Claude Code or Codex on this Mac spending a subscription.
    /// Left unsaid by the caller, it is whatever settings say — the app builds
    /// this from a screen away and should not have to know about the choice.
    private let describer: Describer
    private var stopped = false

    public init(store: UnburyStore, client: OpenRouter, describer: Describer? = nil) {
        self.store = store
        self.client = client
        self.describer = describer
            ?? DescribeEngines.describer(Preferences.load().describeEngine, fallingBackTo: client)
    }

    public func stop() { stopped = true }

    /// Snap a tag the model just coined onto one the vault already holds, when the
    /// two are the same word written differently — a trailing "s", hyphens, nothing
    /// else. Free, and it catches the pairs a prompt alone still lets through
    /// ("drones" beside "drone", "tailwindcss" beside "tailwind-css").
    private static func settle(_ tags: [String], into known: [String: String]) -> [String] {
        var out: [String] = []
        for tag in tags {
            let clean = tag.lowercased().trimmingCharacters(in: .whitespaces)
            guard !clean.isEmpty else { continue }
            let settled = known[shape(clean)] ?? clean
            if !out.contains(settled) { out.append(settled) }
        }
        return out
    }

    /// The bare shape of a tag: letters and digits only, no plural. Two tags with the
    /// same shape are the same drawer.
    private static func shape(_ tag: String) -> String {
        let bare = tag.lowercased().filter { $0.isLetter || $0.isNumber }
        return bare.count > 3 && bare.hasSuffix("s") ? String(bare.dropLast()) : bare
    }

    /// Import the chosen links, saving as it goes.
    ///
    /// Saved in batches rather than at the end: stopping halfway, or losing the
    /// network, must not throw away work already paid for.
    /// `profile` is the bookmarks file the links came from, stamped on each
    /// record so that a later sweep can tell which profile a link belongs to
    /// before deciding it is gone from the browser.
    public func run(_ candidates: [Candidate], from profile: String? = nil,
                    onProgress: @Sendable @escaping (Progress) -> Void) async -> Int {
        stopped = false
        var done = 0
        var spent = 0.0
        var batch: [(Bookmark, [Float])] = []
        var nextID = await store.nextID()

        // The vocabulary already in the vault, most used first, grown as we go: the
        // model is shown it with every page so it files under a tag that exists
        // rather than inventing a near-copy of one.
        var counts = await store.tagCounts()
        var shapes: [String: String] = [:]
        for tag in counts.keys { shapes[Self.shape(tag)] = tag }
        var vocabulary: [String] { counts.sorted { $0.value > $1.value }.map(\.key) }

        for candidate in candidates {
            if stopped { break }
            onProgress(Progress(done: done, total: candidates.count,
                                current: candidate.site, note: "", spent: spent))

            let page = await PageReader.read(candidate.url)
            var note = page.status
            var summary = candidate.title
            var tags: [String] = []

            do {
                let written = try await describer.describe(
                    title: candidate.title, url: candidate.url,
                    folder: candidate.folder, content: page.text,
                    known: vocabulary)
                summary = written.summary
                tags = Self.settle(written.tags, into: shapes)
                for tag in tags {
                    counts[tag, default: 0] += 1
                    shapes[Self.shape(tag)] = shapes[Self.shape(tag)] ?? tag
                }
                spent += written.cost
            } catch {
                note = "described from its title (\(error.localizedDescription))"
            }

            // Everything a person might search by goes into the vector. The
            // browser folder is deliberately left out: a folder records where
            // something was filed on the day it was saved, which is exactly the
            // thing the person has forgotten. The model's reading of the page is
            // what gets indexed.
            let subject = "\(candidate.title). \(summary) Tags: \(tags.joined(separator: ", ")). Site: \(candidate.site)"
            guard let vector = try? await client.embed(subject) else {
                onProgress(Progress(done: done, total: candidates.count,
                                    current: candidate.site,
                                    note: "could not be indexed — skipped", spent: spent))
                continue
            }

            batch.append((Bookmark(id: nextID, url: candidate.url, title: candidate.title,
                                   folder: candidate.folder, site: candidate.site,
                                   savedOn: candidate.savedOn, origin: "browser",
                                   summary: summary, tags: tags, image: page.image,
                                   indexedAt: ISO8601DateFormatter().string(from: Date()),
                                   updatedAt: ISO8601DateFormatter().string(from: Date()),
                                   sourceProfile: profile),
                          vector))
            nextID += 1
            done += 1

            if batch.count >= 10 {
                try? await store.upsert(batch)
                batch.removeAll()
            }
            onProgress(Progress(done: done, total: candidates.count,
                                current: candidate.site, note: note, spent: spent))
        }

        if !batch.isEmpty { try? await store.upsert(batch) }
        return done
    }

    /// Read these profiles and tell the vault which of its links they still hold.
    ///
    /// The counterpart of importing: a browser is an inbox, so a link leaving it
    /// is news, not an instruction to delete. Records the profiles no longer hold
    /// are marked and keep appearing in searches carrying that note. A profile
    /// whose file cannot be read is left out entirely rather than counted as
    /// empty, which would declare every link it holds gone.
    public static func sweep(profiles: [Browsers.Profile],
                             into store: UnburyStore) async throws -> UnburyStore.BrowserSweep {
        var read: Set<String> = []
        var urls: Set<String> = []
        for profile in profiles {
            guard let links = try? Browsers.read(profile.file) else { continue }
            read.insert(profile.id)
            for link in links { urls.insert(link.url) }
        }
        return try await store.reconcileBrowser(profiles: read, urls: urls)
    }
}
