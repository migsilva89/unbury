import Foundation
import UnburyCore

/// One conversation, as the list down the side of the Ask screen knows it.
///
/// Deliberately small: a title, two dates and a count. The list is read on every
/// launch and the turns are not, so what it costs to know a conversation exists
/// has to stay far below what it costs to read one.
struct ChatSummary: Identifiable, Codable, Sendable, Hashable {
    var id: UUID
    /// The first question asked, as typed. "Conversation 3" tells nobody which
    /// one they are looking for.
    var title: String
    var startedAt: Date
    var updatedAt: Date
    /// How many questions were asked in it, so the list can say so without
    /// reading the file that holds them.
    var questions: Int

    /// A tombstone. A deleted conversation is recorded as deleted rather than
    /// cut out of the middle of a file that is only ever appended to.
    var deleted: Bool?

    static func opening(_ question: String, at now: Date) -> ChatSummary {
        ChatSummary(id: UUID(), title: question, startedAt: now, updatedAt: now, questions: 1)
    }
}

/// A finished turn as it is written down: the question, every search it caused,
/// what came back, and the answer with its citations.
///
/// The records are kept whole rather than as ids. An id is only a shorthand for
/// an address, and a re-import renumbers; keeping the record means a conversation
/// from last month still reads as it did, even for a link since deleted. What is
/// still in the vault is refreshed from it on the way back in, so tags and the
/// "gone from your browser" note are never stale.
struct StoredTurn: Codable, Sendable {
    var question: String
    var engine: String
    var calls: [StoredCall]
    var parts: [StoredPart]
    var cited: [StoredMatch]
    var deadEnd: String?
    var error: String?
    var cost: Double
}

struct StoredCall: Codable, Sendable {
    var number: Int
    var query: String
    var reason: String?
    var hits: [StoredMatch]
}

struct StoredPart: Codable, Sendable {
    var text: String
    var citations: [Int]
}

struct StoredMatch: Codable, Sendable {
    var bookmark: Bookmark
    var score: Double
}

/// Where conversations are kept between launches.
///
/// Beside the vault but never inside it: `vault.json` and `vectors.bin` are the
/// person's links and are not touched here. This is its own folder, with one
/// file per conversation and one list of them all.
///
/// The list is appended to, never rewritten in place — a conversation gaining a
/// question adds a line rather than rewriting every question ever asked — and
/// the last line for an id is the one that counts. A line that will not parse is
/// skipped, so a write cut off by a crash costs one entry and not the history.
/// The list is rebuilt from scratch only when it has grown to several times the
/// number of conversations it describes.
actor ChatArchive {
    static let shared = ChatArchive()

    private let folder: URL
    private var listFile: URL { folder.appendingPathComponent("index.jsonl") }

    /// How many stale lines the list may carry before it is written out afresh.
    private static let slack = 3

    init(directory: URL = UnburyStore.defaultDirectory.appendingPathComponent("conversations")) {
        folder = directory
    }

    private var coder: (JSONEncoder, JSONDecoder) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (encoder, decoder)
    }

    // MARK: the list

    /// Every conversation still kept, newest first.
    func list() -> [ChatSummary] {
        let (_, decoder) = coder
        guard let text = try? String(contentsOf: listFile, encoding: .utf8) else { return [] }
        var byID: [UUID: ChatSummary] = [:]
        var lines = 0
        for line in text.split(separator: "\n") {
            guard let entry = try? decoder.decode(ChatSummary.self, from: Data(line.utf8)) else {
                // A half-written last line, or one from a version that wrote
                // something else. Neither is worth losing the rest over.
                continue
            }
            lines += 1
            if entry.deleted == true { byID[entry.id] = nil } else { byID[entry.id] = entry }
        }
        let kept = byID.values.sorted { $0.updatedAt > $1.updatedAt }
        if lines > max(20, kept.count * Self.slack) { rewriteList(kept) }
        return kept
    }

    private func rewriteList(_ entries: [ChatSummary]) {
        let (encoder, _) = coder
        let body = entries.compactMap { try? encoder.encode($0) }
            .compactMap { String(data: $0, encoding: .utf8) }
            .joined(separator: "\n")
        // Through a neighbouring file: a rewrite interrupted half way must not
        // be able to leave a shorter list where the whole one was.
        let scratch = folder.appendingPathExtension("rebuilding")
        guard (try? (body + "\n").write(to: scratch, atomically: true, encoding: .utf8)) != nil else { return }
        _ = try? FileManager.default.replaceItemAt(listFile, withItemAt: scratch)
    }

    private func append(_ entry: ChatSummary) {
        let (encoder, _) = coder
        guard var line = try? encoder.encode(entry) else { return }
        line.append(0x0A)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let handle = try? FileHandle(forWritingTo: listFile) else {
            try? line.write(to: listFile)
            return
        }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: line)
    }

    // MARK: one conversation

    private func file(_ id: UUID) -> URL {
        folder.appendingPathComponent(id.uuidString).appendingPathExtension("json")
    }

    /// The turns of one conversation. Read only when it is opened — a person with
    /// four hundred conversations is not made to wait for three hundred and
    /// ninety-nine of them.
    func turns(of id: UUID) -> [StoredTurn] {
        let (_, decoder) = coder
        guard let data = try? Data(contentsOf: file(id)),
              let turns = try? decoder.decode([StoredTurn].self, from: data)
        else { return [] }
        return turns
    }

    /// Write a conversation down, and say so in the list.
    ///
    /// `listing` is false while an answer is still being made. The conversation
    /// itself is written anyway — a question interrupted by a crash is still a
    /// question that was asked — but a turn moves half a dozen times before it
    /// settles, and one line in the list per movement would be a list that grows
    /// six times faster than the thing it describes.
    func save(_ summary: ChatSummary, turns: [StoredTurn], listing: Bool) {
        guard !turns.isEmpty else { return }
        let (encoder, _) = coder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let data = try? encoder.encode(turns) else { return }
        try? data.write(to: file(summary.id), options: .atomic)
        if listing { append(summary) }
    }

    func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: file(id))
        append(ChatSummary(id: id, title: "", startedAt: .distantPast,
                           updatedAt: .distantPast, questions: 0, deleted: true))
    }
}

// MARK: - Between a turn on screen and a turn on disk

extension StoredTurn {
    init(_ turn: Turn) {
        question = turn.question
        engine = turn.engine.rawValue
        calls = turn.calls.map { call in
            StoredCall(number: call.number, query: call.query, reason: call.reason,
                       hits: call.hits.map(StoredMatch.init))
        }
        parts = turn.parts.map { StoredPart(text: $0.text, citations: $0.citations) }
        cited = turn.cited.map(StoredMatch.init)
        deadEnd = turn.deadEnd
        error = turn.error
        cost = turn.cost
    }

    /// The turn as the screen shows it, with every record it names replaced by
    /// the vault's copy where the vault still has one — found by address, which
    /// is the identity that survives a re-import.
    func restored(from vault: [String: Bookmark]) -> Turn {
        func match(_ stored: StoredMatch) -> Match {
            Match(bookmark: vault[stored.bookmark.url] ?? stored.bookmark, score: stored.score)
        }
        var turn = Turn(question: question, engine: Engine(stored: engine) ?? .claude)
        turn.calls = calls.map { call in
            SearchCall(number: call.number, query: call.query, reason: call.reason,
                       hits: call.hits.map(match), finished: true)
        }
        turn.parts = parts.map { AnswerPart(text: $0.text, citations: $0.citations) }
        turn.cited = cited.map(match)
        turn.deadEnd = deadEnd
        turn.error = error
        turn.cost = cost
        turn.working = false
        turn.numbering = Turn.numbers(for: turn.calls)
        return turn
    }

    /// Every address this turn names, so one lookup can refresh the whole thing.
    var addresses: [String] {
        calls.flatMap { $0.hits.map(\.bookmark.url) } + cited.map(\.bookmark.url)
    }
}

extension StoredMatch {
    init(_ match: Match) {
        bookmark = match.bookmark
        score = match.score
    }
}
