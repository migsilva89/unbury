import Foundation
import UnburyCore

/// One search the model decided to run, kept in the transcript so the person can
/// see what it looked for and what came back. This is the part that earns trust:
/// an answer whose evidence is visible can be checked, and a fabrication shows.
struct SearchCall: Identifiable {
    let id = UUID()
    var number: Int
    var query: String
    var reason: String?
    var hits: [Match] = []
    var finished = false

    var status: String {
        if !finished { return "…" }
        guard let best = hits.first?.score else { return "nothing" }
        if best < 0 { return "\(hits.count) back" }
        return String(format: "%d back · best %.2f", hits.count, best)
    }
    var foundNothing: Bool { finished && hits.isEmpty }
}

/// A sentence of the answer, and the records it rests on.
struct AnswerPart: Identifiable {
    let id = UUID()
    var text: String
    var citations: [Int] = []      // bookmark ids
}

struct Turn: Identifiable {
    let id = UUID()
    var question: String
    var engine: Engine
    var calls: [SearchCall] = []
    var parts: [AnswerPart] = []
    var cited: [Match] = []
    var numbering: [Int: Int] = [:]   // bookmark id → the number shown
    var working = true
    var deadEnd: String?
    var cost: Double = 0
    var error: String?

    var hasAnswer: Bool { !parts.isEmpty }
    /// Stopped by the person, not broken. Same field as an error because that is
    /// what the engine reports, but it is not failure and must not be shown as one.
    var stopped: Bool { error == AskEngine.stopped }

    /// The whole answer as one piece of prose, for a follow-up question to be
    /// read against.
    var prose: String { parts.map(\.text).joined(separator: " ") }

    /// The ids the answer actually leans on, in the order they are first cited.
    var citedIDs: [Int] {
        var seen: [Int] = []
        for part in parts {
            for id in part.citations where !seen.contains(id) { seen.append(id) }
        }
        return seen
    }
    /// An answer resting on one middling match is not the same as one resting on
    /// three strong ones, and the difference has to be visible. A score below
    /// zero means the engine did not report one — silence, not a weak answer.
    var weakEvidence: Bool {
        guard !working, let best = cited.first?.score, best >= 0 else { return false }
        return best < 0.56
    }
    /// The number each record is shown under, handed out in the order the
    /// searches first returned them — so a citation keeps the same number
    /// wherever it appears, and keeps it when the conversation is read back
    /// from the archive.
    static func numbers(for calls: [SearchCall]) -> [Int: Int] {
        var numbers: [Int: Int] = [:]
        for call in calls {
            for hit in call.hits where numbers[hit.bookmark.id] == nil {
                numbers[hit.bookmark.id] = numbers.count + 1
            }
        }
        return numbers
    }

    var workingText: String {
        guard let last = calls.last else { return "calling search…" }
        return last.finished ? "reading \(last.hits.count) records…" : "searching…"
    }
}

/// Which assistant answers a question, as this screen holds it.
///
/// What an engine *is* — its name, the command it needs, whether it spends
/// money — is written down once in `ChatEngines`, because the settings page has
/// to describe engines and this screen has to run them. This is only the choice
/// itself, in a shape a `switch` can be exhaustive over.
///
/// The raw value is the identifier settings store, so renaming a case here would
/// silently move somebody to a different engine — and one of the three costs
/// money per message.
enum Engine: String, CaseIterable, Identifiable, Sendable {
    case claude = "claude-code"
    case codex
    case openrouter
    var id: String { rawValue }

    /// What was written in settings, read back. The file said "claude" until
    /// 2026-08-28; anyone who chose it then still means Claude Code and must not
    /// be quietly handed to the paid engine instead.
    init?(stored: String) {
        if stored == "claude" { self = .claude; return }
        guard let known = Engine(rawValue: stored) else { return nil }
        self = known
    }

    /// The fallbacks below are for an engine the registry has never heard of,
    /// which is nothing this app can run — so: no name to show, and no command.
    private var option: ChatEngineOption? { ChatEngines.option(rawValue) }
    var label: String { option?.label ?? rawValue }
    var command: String? { option?.command }
    var meteredByUs: Bool { option?.spends ?? false }
    var title: String { option?.note ?? "" }
    /// Whose money a question spends. Never the word "free" — a subscription
    /// somebody pays for every month is already paid for, not free.
    var purse: String { option?.purse ?? "" }

    /// How to get it, for the screen that has to say it is missing.
    var installCommand: String {
        switch self {
        case .claude: "npm i -g @anthropic-ai/claude-code"
        case .codex: "npm i -g @openai/codex"
        case .openrouter: "openrouter.ai/keys"
        }
    }
}

/// A question already asked and the answer it got, as an engine is given it.
struct Exchange: Sendable {
    let question: String
    let answer: String
}

/// What is happening this very second, while a question is being answered.
///
/// Deliberately separate from the transcript. The transcript is the record — it
/// only ever gains finished things. This is the window, and it is emptied the
/// moment the turn ends, so nothing half-written can survive as if it were an
/// answer. There is one conversation in the app, so there is one of these; the
/// engines reach it without having to be handed it through four initialisers.
@MainActor
@Observable
final class AskLive {
    static let shared = AskLive()

    /// Set by `Conversation` itself, so both the interface and the file channel
    /// get history and cancellation without either having to arrange it.
    weak var conversation: Conversation?

    private(set) var running = false
    private(set) var startedAt = Date.distantPast
    /// One short line: what the engine is doing right now.
    private(set) var note = ""
    /// The answer as it arrives, word by word. Never stored in a turn.
    private(set) var draft = ""
    /// The person pressed stop and the engine has not finished unwinding yet.
    private(set) var stopping = false

    /// The draft with the engine's own bookkeeping taken out. Claude Code is
    /// asked to announce each search on a SEARCH: line and to mark the answer
    /// with ANSWER:; those lines are instructions to the machine and reading
    /// them as the beginning of an answer is confusing, so they are dropped and
    /// only the prose is shown.
    var visibleDraft: String {
        draft
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("SEARCH:") }
            .joined(separator: "\n")
            .replacingOccurrences(of: "ANSWER:", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func begin(_ first: String) {
        running = true
        stopping = false
        startedAt = Date()
        note = first
        draft = ""
    }
    /// A new search is starting: whatever prose was on screen belonged to the
    /// thinking before it, and keeping it would read as half an answer.
    func beginSearch() {
        guard running else { return }
        draft = ""
        note = "searching your links…"
    }
    func say(_ line: String) {
        guard running else { return }
        note = line
    }
    func write(_ chunk: String) {
        guard running else { return }
        draft += chunk
        if !visibleDraft.isEmpty { note = "writing the answer…" }
    }
    /// Some engines hand over the whole text at once rather than in pieces.
    func replaceDraft(with text: String) {
        guard running else { return }
        draft = text
    }
    func askedToStop() {
        guard running else { return }
        stopping = true
        note = "stopping…"
    }
    func end() {
        running = false
        stopping = false
        note = ""
        draft = ""
    }
}

@MainActor
@Observable
final class Conversation {
    /// The conversation on screen. Every change is written down shortly after it
    /// happens, so quitting the app is not a way of losing a question.
    var turns: [Turn] = [] { didSet { archiveSoon() } }
    var input = ""
    var spent: Double = 0

    /// Which engine answers. Settings holds the choice; this is the working copy
    /// the transcript stamps each turn with. It starts from what was stored, so
    /// a question asked before anybody opens the Ask screen still goes to the
    /// engine the person picked.
    var engine: Engine

    /// The question being answered, so it can be stopped. Held here rather than
    /// in the view because the file channel starts questions too.
    @ObservationIgnored var running: Task<Void, Never>?

    /// Whether each side panel is showing. Held here rather than in the view
    /// because they survive leaving the Ask screen and coming back, and because
    /// the test channel has to be able to open them.
    ///
    /// The two are the same kind of thing — a panel beside the conversation,
    /// with one labelled button each — so they are the same kind of state.
    var historyOpen = true
    var evidenceOpen = true

    /// The conversation being shown, once it has a first question to be named
    /// after. Nil means a fresh, empty one that is not worth keeping yet.
    private(set) var current: ChatSummary?
    /// Every conversation kept, newest first. Titles and dates only — the
    /// questions of one are read when it is opened.
    private(set) var history: [ChatSummary] = []
    /// A conversation is being read back in. Held so the screen can say so
    /// rather than blink.
    private(set) var opening = false

    /// Writing back what has just been read would move a conversation to the top
    /// of the list for being looked at, which is not the same as being used.
    @ObservationIgnored private var restoring = false
    @ObservationIgnored private var archiving: Task<Void, Never>?

    init(preferences: Preferences = .load()) {
        engine = Engine(stored: preferences.chatEngine) ?? .claude
        AskLive.shared.conversation = self
    }

    // MARK: keeping conversations

    func loadHistory() async {
        history = await ChatArchive.shared.list()
    }

    /// Write the conversation down a moment after it changes. A turn moves half
    /// a dozen times while it is being answered — a search starting, records
    /// coming back, the prose arriving — and each of those is not worth its own
    /// write.
    private func archiveSoon() {
        guard !restoring else { return }
        archiving?.cancel()
        let now = Date()
        if current == nil, let first = turns.first {
            current = ChatSummary.opening(first.question, at: now)
        }
        guard var summary = current else { return }
        summary.questions = turns.count
        summary.updatedAt = now
        current = summary
        let written = turns.map(StoredTurn.init)
        let settled = !isWorking
        archiving = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await ChatArchive.shared.save(summary, turns: written, listing: settled)
            if settled { await loadHistory() }
        }
    }

    /// Start a fresh conversation. What was on screen is already written down,
    /// so nothing is lost and nothing needs confirming.
    func startNew() {
        guard current != nil || !turns.isEmpty else { return }
        restoring = true
        turns = []
        restoring = false
        current = nil
        spent = 0
        input = ""
    }

    /// Read a conversation back in, with every record it names refreshed from
    /// the vault by its address — so a link retagged since, or now gone from the
    /// browser, reads as it is today rather than as it was.
    func open(_ summary: ChatSummary, from store: UnburyStore) async {
        guard summary.id != current?.id else { return }
        opening = true
        defer { opening = false }
        let stored = await ChatArchive.shared.turns(of: summary.id)
        let addresses = Array(Set(stored.flatMap(\.addresses)))
        let vault = await store.bookmarks(urls: addresses)
        let byURL = Dictionary(vault.map { ($0.url, $0) }, uniquingKeysWith: { first, _ in first })
        restoring = true
        turns = stored.map { $0.restored(from: byURL) }
        restoring = false
        current = summary
        spent = turns.reduce(0) { $0 + $1.cost }
        input = ""
    }

    func delete(_ summary: ChatSummary) async {
        await ChatArchive.shared.delete(summary.id)
        if summary.id == current?.id { startNew() }
        await loadHistory()
    }

    var isEmpty: Bool { turns.isEmpty }
    var isWorking: Bool { turns.last?.working ?? false }

    /// Which turn the evidence panel is showing. The one in flight, so the panel
    /// fills as the searches come back; otherwise the most recent one that
    /// actually found something, so asking a new question does not blank out the
    /// records you were still reading.
    var evidenceTurn: Turn? {
        if let last = turns.last, last.working || !last.cited.isEmpty { return last }
        return turns.last(where: { !$0.cited.isEmpty }) ?? turns.last
    }
    var evidence: [Match] {
        guard let turn = evidenceTurn else { return [] }
        if !turn.cited.isEmpty { return turn.cited }
        // Still working: everything the searches have returned so far, first
        // seen first, which is the order the numbers were handed out in.
        var unique: [Int: Match] = [:]
        var order: [Int] = []
        for hit in turn.calls.flatMap(\.hits) where unique[hit.bookmark.id] == nil {
            unique[hit.bookmark.id] = hit
            order.append(hit.bookmark.id)
        }
        return order.compactMap { unique[$0] }
    }
    var numbering: [Int: Int] { evidenceTurn?.numbering ?? [:] }

    /// Stop the question in flight. The engine notices, kills whatever it started
    /// and reports it as stopped, so the turn closes instead of spinning forever.
    func stop() {
        guard isWorking else { return }
        AskLive.shared.askedToStop()
        running?.cancel()
    }

    /// What was already asked and answered, oldest first, for the engine to read
    /// the next question against. Only finished turns that produced prose: a
    /// failed or stopped turn has nothing to remember. The last few, because a
    /// follow-up reaches back one or two questions, not twenty.
    func priorExchanges(limit: Int = 4) -> [Exchange] {
        turns
            .filter { !$0.working && $0.error == nil }
            .compactMap { turn in
                let answer = turn.deadEnd ?? turn.prose
                let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : Exchange(question: turn.question, answer: trimmed)
            }
            .suffix(limit)
            .map { $0 }
    }
}

/// Reaching a record from a conversation.
extension AppModel {
    /// Open a record an answer pointed at — the vault's own copy of it, found by
    /// its address.
    ///
    /// The transcript keeps each record as it was when the search ran, and an
    /// import since then can have retagged it or marked it gone from the
    /// browser. The address is the identity that survives all of that; the id in
    /// a citation is only shorthand for it. Searching for the title again, which
    /// is what this used to do, asks a different question and usually finds
    /// nothing.
    func open(_ bookmark: Bookmark) {
        guard selected?.id != bookmark.id else { selected = nil; return }
        selected = bookmark
        Task {
            guard let live = await store.bookmark(url: bookmark.url),
                  selected?.id == bookmark.id else { return }
            selected = live
        }
    }
}
