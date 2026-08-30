import Foundation
import Observation
import UnburyCore

/// A tag with how many links carry it, ordered once instead of in a view's
/// body. The home screen redraws on every hover and every keystroke, and
/// sorting a thousand tags inside `body` is what made the tag cloud stutter.
struct Tag: Identifiable, Hashable, Sendable {
    let name: String
    let count: Int
    var id: String { name }
}

/// Everything the three views read and write. One object, because the views are
/// three ways of looking at the same vault and the same conversation.
@MainActor
@Observable
final class AppModel {
    enum Tab: String {
        case search, ask, landscape, settings

        /// What a person reads, and the only thing the top bar shows.
        /// Deliberately not `rawValue.capitalized`: "Ask Unbury" has a space in
        /// it, and `.landscape` is read as "Library" because that is what the
        /// site calls the same page. Both raw values stay lowercase identifiers
        /// for the test channel to match on.
        var label: String {
            switch self {
            case .ask: "Ask Unbury"
            case .landscape: "Library"
            default: rawValue.capitalized
            }
        }
    }

    // Thresholds measured on this collection, not guessed. A right answer lands
    // around 0.60; unrelated records cluster at 0.44–0.47. The absolute gap is
    // small, so an absolute cut alone waves seventeen near-misses through behind
    // one good hit. The relative cut is what does the work.
    static let confident = 0.45
    static let strong = 0.55
    static let relative = 0.88
    /// How many links of a tag arrive at once. The vault will happily hand over
    /// nine hundred; SwiftUI placing nine hundred rows in a single layout pass
    /// is what froze the window for fourteen seconds.
    static let pageSize = 40
    /// The most rows this screen will ever draw, however many the tag holds.
    ///
    /// Measured on the real vault, scrolling the whole list down and back in
    /// 40pt steps with the preview pictures loaded, watching how often the main
    /// thread got a turn:
    ///
    ///   120 rows — median 8.5ms, worst 18ms, nothing over a frame
    ///   160 rows — median 18ms, 180 turns of 672 over two frames
    ///   627 rows — did not finish in ten minutes
    ///
    /// A `LazyVStack` realises rows as it passes them and never gives them
    /// back, so the cost grows with everything ever scrolled past, not with
    /// what is on screen. 120 is the largest size that stayed inside the frame
    /// budget throughout — and a list longer than that was never a way to find
    /// anything anyway.
    static let ceiling = 120

    var tab: Tab = .search
    var query = ""
    private(set) var matches: [Match] = []

    /// The tags being browsed inside, in the order they were chosen — and the
    /// same names as a set, because every row asks "is this one on?" and a
    /// linear search per tag per row is a cost the list can feel.
    ///
    /// Several at once, and they narrow together: choosing `drone` and then
    /// `review` is a person saying "and", not "or". Written through
    /// `narrow`/`widen` rather than assigned, because each change has a page to
    /// reload and a ranking to redo, and a `didSet` that starts a task fires
    /// again for the changes it makes itself.
    private(set) var scope: [String] = []
    private(set) var scopeSet: Set<String> = []

    /// The links inside the scope, a screenful at a time, and how many there
    /// are in all.
    private(set) var browse: [Bookmark] = []
    private(set) var browseTotal = 0
    private(set) var loadingMore = false
    var hasMore: Bool { browse.count < min(browseTotal, Self.ceiling) }
    /// True when there are more links than this screen will draw. Not a failure
    /// to admit to — a list of six hundred rows is not an answer — but it has
    /// to be said out loud rather than the list just stopping.
    var atCeiling: Bool { browse.count >= Self.ceiling && browseTotal > Self.ceiling }

    /// Every tag with its count, biggest first, and the ones carrying a single
    /// link. Both are worked out when the vault changes, never while drawing.
    private(set) var tags: [Tag] = []
    private(set) var singletons: [String] = []
    /// The tags still worth offering once something has been narrowed to — see
    /// `refreshReachable`. Empty means nothing is narrowed and `tags` is the list.
    private(set) var reachable: [Tag] = []
    /// What is typed into "find a tag". It lives here rather than inside the
    /// cloud because it is part of what the screen is showing, and because a
    /// state only a view knows cannot be driven or tested.
    var tagFilter = ""

    /// Where the list of links should move to, cleared by the list once it has
    /// moved. Set when the funnel changes — a new set of links must not open
    /// half way down the previous one — and by the test channel, which is the
    /// only way to scroll a window that cannot be sent real events.
    enum ScrollRequest: Equatable { case top, record(Int) }
    var scrollRequest: ScrollRequest?

    var selected: Bookmark?
    /// The records ticked for deleting together, by id. A set rather than a
    /// list because every row asks "am I ticked?" while the list is drawn.
    private(set) var marked: Set<Int> = []
    /// What the confirmation is about to delete, or nil while nothing is being
    /// asked. Deleting cannot be undone, so nothing here deletes without this
    /// having been set and answered first.
    private(set) var pendingDeletion: [Bookmark] = []
    var confirmingDeletion = false
    /// Bumped every time what is stored changes. Landscape works its whole
    /// picture out once when it appears, and after a delete that picture is a
    /// count of links that are not there any more.
    private(set) var revision = 0
    private(set) var showWeak = false
    var searching = false
    var searchError: String?
    var lastSearchMilliseconds = 0
    private(set) var window: TimeWindow?

    /// What the results list actually shows, and how much it is holding back:
    /// only what is close to the best answer, and only if the best is worth
    /// trusting at all. Worked out once per ranking rather than on every read —
    /// the list, the status line and the keyboard all ask for it while scrolling.
    private(set) var visible: [Match] = []
    private(set) var withheld = 0

    /// The question these results are the answers to, which is not always what
    /// the field says. Typing does not search — deliberately — so the moment a
    /// letter is added the list on screen belongs to an older question, and the
    /// screen has to say so rather than let the counts speak for text nobody
    /// asked about.
    private(set) var askedQuery = ""

    /// The field and the results have come apart.
    var stale: Bool {
        !matches.isEmpty && query.trimmingCharacters(in: .whitespaces) != askedQuery
    }

    /// The vector of the last question asked. Kept so that narrowing by a tag
    /// afterwards costs nothing: re-ranking inside a smaller pile is arithmetic
    /// the Mac already has everything for, and asking OpenRouter for the same
    /// sentence again would be paying twice for one question.
    private var askedVector: [Float]?

    var importing = false
    var importProgress: String?
    /// Settings is a page, not a sheet: it holds a key, a browser choice and
    /// two paid models — things a person reads, compares and comes back to,
    /// which a modal that dims the app behind it makes harder, not easier.
    /// `showSettings` stays as the way in, so the menu, ⌘, and the test
    /// channel all keep working; setting it just goes to the page.
    var showSettings: Bool {
        get { tab == .settings }
        set {
            if newValue {
                if tab != .settings { tabBeforeSettings = tab }
                tab = .settings
            } else if tab == .settings {
                tab = tabBeforeSettings
            }
        }
    }
    /// Where "back" goes when settings closes.
    var tabBeforeSettings: Tab = .search
    var showImport = false
    var preferences = Preferences.load()
    var importDone = 0
    var importTotal = 0
    var importSpent = 0.0
    var stoppedImport = false
    private var activeImporter: Importer?

    let embeddingModel = OpenRouter.Settings.default.embeddingModel
    let embeddingDimensions = OpenRouter.Settings.default.dimensions
    var count = 0
    var siteCount = 0
    var picturedCount = 0
    var tagCount = 0
    var syncedAt: String?

    var conversation = Conversation()

    let store = UnburyStore()
    private var searchTask: Task<Void, Never>?

    var key: String? { Keychain.readKey() ?? Config.value("OPENROUTER_API_KEY") }

    /// The key for wherever vectors are bought. Searching cannot happen without
    /// this one, whichever service it is.
    var vectorKey: String? {
        let service = VectorServices.resolve(preferences.vectorService)
        if service.id == VectorServices.openRouter.id { return key }
        return Keychain.read(service)
    }

    /// Enough keys to import: always one for the vectors, and one for
    /// OpenRouter only when OpenRouter is also the one describing. Asking for an
    /// OpenRouter key to run "OpenAI vectors, Claude Code describing" blocks a
    /// setup that needs no OpenRouter account at all.
    var hasKey: Bool {
        guard !(vectorKey ?? "").isEmpty else { return false }
        guard preferences.describeEngine == DescribeEngines.openRouter else { return true }
        return !(key ?? "").isEmpty
    }

    func start() async {
        adoptKeyFromEnvFile()
        do {
            try await store.load()
        } catch {
            // A half-written mirror is dropped rather than trusted; say so.
            importProgress = error.localizedDescription
        }
        await refreshCounts()
    }

    /// The `.env` beside the Python importer is where the key lived first. Copy
    /// it into the Keychain once, so nothing depends on a relative path again.
    private func adoptKeyFromEnvFile() {
        guard Keychain.readKey() == nil,
              let fromFile = Config.value("OPENROUTER_API_KEY"), !fromFile.isEmpty
        else { return }
        Keychain.writeKey(fromFile)
    }

    /// Delete everything stored. The browser is never touched, so this is a
    /// restart rather than a loss — but the descriptions were paid for once and
    /// will be paid for again, which is why it asks first.
    func eraseVault() async {
        try? await store.replace(bookmarks: [], vectors: [], dimensions: 0,
                                 syncedAt: ISO8601DateFormatter().string(from: Date()))
        matches = []; visible = []; withheld = 0
        selected = nil; query = ""; askedVector = nil
        scope = []; scopeSet = []
        marked = []; pendingDeletion = []; confirmingDeletion = false
        conversation.turns = []
        await refreshCounts()
    }

    func refreshCounts() async {
        revision += 1
        let all = await store.bookmarks
        count = all.count
        siteCount = Set(all.map(\.site)).count
        picturedCount = all.filter { !($0.image ?? "").isEmpty }.count
        let counts = await store.tagCounts()
        tagCount = counts.count
        tags = counts.map { Tag(name: $0.key, count: $0.value) }
            .sorted { $0.count == $1.count ? $0.name < $1.name : $0.count > $1.count }
        singletons = tags.filter { $0.count == 1 }.map(\.name).sorted()
        syncedAt = await store.syncedAt
        // A tag can vanish under an erase or an import; keep the scope honest.
        let known = Set(counts.keys)
        let kept = scope.filter(known.contains)
        if kept != scope { scope = kept; scopeSet = Set(kept) }
        await reloadScope()
    }

    // MARK: - Narrowing

    /// Add a tag to the funnel. Nothing leaves the Mac: this filters records
    /// that are already here.
    func narrow(to tag: String) {
        guard !scopeSet.contains(tag) else { return }
        scope.append(tag)
        scopeSet.insert(tag)
        Task { await reloadScope() }
    }

    func widen(from tag: String) {
        guard scopeSet.contains(tag) else { return }
        scope.removeAll { $0 == tag }
        scopeSet.remove(tag)
        Task { await reloadScope() }
    }

    func clearScope() {
        guard !scope.isEmpty else { return }
        tagFilter = ""
        scope = []; scopeSet = []
        Task { await reloadScope() }
    }

    /// What has to happen after the funnel changes: the first page of links
    /// inside it, and — if a question has already been asked — the same question
    /// ranked again inside the smaller pile, without spending anything.
    private func reloadScope() async {
        selected = nil
        // What was deleted was said about the list that was on screen then.
        deleteNote = nil
        scrollRequest = .top
        browse = []
        browseTotal = 0
        await refreshReachable()
        if !scope.isEmpty { await loadMore() }
        if let askedVector, !query.isEmpty {
            await rank(with: askedVector)
        } else if query.isEmpty {
            matches = []; visible = []; withheld = 0
        }
    }

    /// The tags that still lead somewhere from inside the funnel: the ones
    /// carried by links that already carry everything chosen. Without this the
    /// cloud keeps offering tags that would empty the list, and a second choice
    /// looks broken rather than exclusive.
    private func refreshReachable() async {
        guard !scope.isEmpty else { reachable = []; return }
        var counts: [String: Int] = [:]
        for bookmark in await store.bookmarks where scopeSet.isSubset(of: bookmark.tags) {
            for tag in bookmark.tags where !scopeSet.contains(tag) { counts[tag, default: 0] += 1 }
        }
        reachable = counts.map { Tag(name: $0.key, count: $0.value) }
            .sorted { $0.count == $1.count ? $0.name < $1.name : $0.count > $1.count }
    }

    /// The next screenful of links inside the scope. Never the whole tag.
    func loadMore() async {
        guard !loadingMore, !scope.isEmpty, browse.count < Self.ceiling else { return }
        loadingMore = true
        defer { loadingMore = false }
        let room = min(Self.pageSize, Self.ceiling - browse.count)
        let page = await store.page(tagged: scope, offset: browse.count, limit: room)
        // The vault may have changed under a slow page — trust the offset it
        // came back with rather than appending blindly.
        guard page.offset == browse.count else { return }
        browse.append(contentsOf: page.bookmarks)
        browseTotal = page.total
    }

    /// How many links carry every tag being browsed.
    var scopeCount: Int { browseTotal }

    // MARK: - Searching

    func search() {
        searchTask?.cancel()
        let asked = query.trimmingCharacters(in: .whitespaces)
        guard !asked.isEmpty else {
            matches = []; visible = []; withheld = 0
            searchError = nil; window = nil; askedVector = nil
            return
        }
        searchTask = Task {
            // Time phrases are a filter, not meaning: pulled out before the
            // sentence is embedded, because leaving them in muddies the vector.
            let parsed = TimeWindow.read(asked)
            window = parsed
            let cleaned = parsed?.strip(from: asked) ?? asked
            // The vectors decide which key matters. Refusing for a missing
            // OpenRouter key while vectors are bought from OpenAI names the
            // wrong setting, and the person goes looking for the wrong fix.
            let service = VectorServices.resolve(preferences.vectorService)
            guard let key = vectorKey, !key.isEmpty else {
                searchError = "No \(service.label) key."; return
            }
            searching = true
            defer { searching = false }
            let started = Date()
            do {
                let vector = try await OpenRouter(key: key, settings: openRouterSettings)
                    .embedQuery(cleaned)
                if Task.isCancelled { return }
                askedVector = vector
                askedQuery = asked
                showWeak = false
                selected = nil
                await rank(with: vector)
                searchError = nil
                lastSearchMilliseconds = Int(Date().timeIntervalSince(started) * 1000)
            } catch is CancellationError {
                // A second search cancels the first. That is the newer question
                // winning, not a failure — showing it as one made the screen
                // flash an error while the answer was still on its way.
                return
            } catch {
                if (error as NSError).code == NSURLErrorCancelled { return }
                searchError = error.localizedDescription
                matches = []; visible = []; withheld = 0
            }
        }
    }

    /// Rank a question already turned into a vector. No network: this is the
    /// step that runs again, for nothing, every time a tag is added or removed.
    private func rank(with vector: [Float]) async {
        var found = await store.search(vector: vector, within: scope, limit: 60)
        if let window { found = found.filter { window.contains($0.bookmark.savedOn) } }
        matches = found
        settleVisible()
    }

    /// Show the near-misses the relative cut held back. A deliberate act, and
    /// the only way past the threshold — a search that always returns something
    /// cannot be trusted.
    func revealWeak() {
        guard !showWeak else { return }
        showWeak = true
        settleVisible()
    }

    private func settleVisible() {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty,
              let best = matches.first?.score else {
            visible = []; withheld = 0; return
        }
        if best < Self.confident {
            visible = showWeak ? Array(matches.filter { $0.score > 0.05 }.prefix(3)) : []
        } else if showWeak {
            visible = Array(matches.filter { $0.score >= Self.confident * 0.7 }.prefix(18))
        } else {
            let cut = max(Self.confident, best * Self.relative)
            visible = Array(matches.filter { $0.score >= cut }.prefix(18))
        }
        withheld = showWeak ? 0 : matches.filter { $0.score >= Self.confident }.count - visible.count
    }

    /// Put the screen back to rest without touching what has been narrowed to —
    /// clearing the question and clearing the funnel are two different retreats.
    func clearQuestion() {
        query = ""
        matches = []; visible = []; withheld = 0
        askedVector = nil; window = nil; searchError = nil; showWeak = false
        askedQuery = ""
        selected = nil
        deleteNote = nil
    }

    func select(_ bookmark: Bookmark) {
        selected = selected?.id == bookmark.id ? nil : bookmark
    }

    // MARK: - Deleting

    /// Tick or untick one record for deleting with others.
    func toggleMark(_ id: Int) {
        if marked.contains(id) { marked.remove(id) } else { marked.insert(id) }
    }

    func clearMarks() { marked = [] }

    /// The ticked records, in the order the screen is showing them, so the
    /// confirmation names them the way they were read.
    var markedBookmarks: [Bookmark] {
        let onScreen = visible.map(\.bookmark) + browse
        var seen = Set<Int>()
        var out = onScreen.filter { marked.contains($0.id) && seen.insert($0.id).inserted }
        // Something ticked and then scrolled out of the ranking still counts.
        if out.count < marked.count, let record = selected, marked.contains(record.id),
           seen.insert(record.id).inserted {
            out.append(record)
        }
        return out
    }

    /// Ask before deleting. Nothing is written here — this only puts the
    /// question on screen, and `confirmDeletion` is the only thing that acts.
    func askToDelete(_ bookmarks: [Bookmark]) {
        guard !bookmarks.isEmpty else { return }
        pendingDeletion = bookmarks
        confirmingDeletion = true
    }

    func cancelDeletion() {
        pendingDeletion = []
        confirmingDeletion = false
    }

    /// Delete what was confirmed, and put the screen back in a state that
    /// matches what is left: the rows go, the counts and the vocabulary are
    /// worked out again, and a tag that held only the deleted link stops being
    /// offered rather than sitting in the cloud at zero.
    @discardableResult
    func confirmDeletion() async -> Int {
        let going = pendingDeletion
        pendingDeletion = []
        confirmingDeletion = false
        guard !going.isEmpty else { return 0 }
        let ids = Set(going.map(\.id))
        do {
            try await store.discard(ids: ids)
        } catch {
            importProgress = error.localizedDescription
            return 0
        }
        matches.removeAll { ids.contains($0.bookmark.id) }
        browse.removeAll { ids.contains($0.id) }
        browseTotal = max(0, browseTotal - going.count)
        marked.subtract(ids)
        if let record = selected, ids.contains(record.id) { selected = nil }
        settleVisible()
        await refreshCounts()
        deleteNote = going.count == 1
            ? "Deleted “\(going[0].displayTitle)”. Your browser still has it — the next import will pass over it."
            : "Deleted \(going.count) links. Your browser still has them — the next import will pass over them."
        return going.count
    }

    /// What just went, said once above the list. Cleared by asking anything new.
    var deleteNote: String?

    /// The tags worth offering to narrow further with: the ones actually carried
    /// by what came back, biggest first, minus the ones already chosen. Only a
    /// handful — this is a suggestion, not a second vocabulary.
    var narrowSuggestions: [Tag] {
        guard !visible.isEmpty else { return [] }
        var counts: [String: Int] = [:]
        for match in matches where match.score >= Self.confident * 0.9 {
            for tag in match.bookmark.tags where !scopeSet.contains(tag) {
                counts[tag, default: 0] += 1
            }
        }
        return counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(7).map { Tag(name: $0.key, count: $0.value) }
    }
}

/// The `.env` beside the Python importer, read once so an existing key is
/// picked up without being typed again. Nothing in the app requires it.
enum Config {
    private static let values: [String: String] = {
        var found: [String: String] = [:]
        let candidates = [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".env"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .deletingLastPathComponent().appendingPathComponent(".env"),
            URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Projects/PERSONAL/APPS/bookmarks-vault/.env"),
        ]
        for url in candidates {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") where line.contains("=") {
                let parts = line.split(separator: "=", maxSplits: 1)
                found[String(parts[0]).trimmingCharacters(in: .whitespaces)] =
                    String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if !found.isEmpty { break }
        }
        return found
    }()

    static func value(_ name: String) -> String? { values[name] }
}

/// "last month" is a date window, not a subject. Recognised, applied, and taken
/// out of the sentence before it reaches the model.
struct TimeWindow {
    let since: String?
    let until: String?
    let label: String
    let pattern: String

    static func read(_ text: String) -> TimeWindow? {
        let lower = text.lowercased()
        let calendar = Calendar.current
        let now = Date()
        let format = DateFormatter()
        format.dateFormat = "yyyy-MM-dd"
        func day(_ date: Date) -> String { format.string(from: date) }
        func monthStart(_ offset: Int) -> (String, String, String) {
            let start = calendar.date(byAdding: .month, value: offset,
                                      to: calendar.date(from: calendar.dateComponents([.year, .month], from: now))!)!
            let end = calendar.date(byAdding: .month, value: 1, to: start)!
            let name = DateFormatter()
            name.dateFormat = "LLLL yyyy"
            return (day(start), day(end), name.string(from: start))
        }

        if lower.contains("last month") || lower.contains("past month") {
            let (s, u, l) = monthStart(-1)
            return TimeWindow(since: s, until: u, label: l, pattern: "(last|past) month")
        }
        if lower.contains("this month") {
            let (s, u, l) = monthStart(0)
            return TimeWindow(since: s, until: u, label: l, pattern: "this month")
        }
        if lower.contains("last week") || lower.contains("past week") {
            return TimeWindow(since: day(calendar.date(byAdding: .day, value: -7, to: now)!),
                              until: nil, label: "last 7 days", pattern: "(last|past) week")
        }
        if lower.contains("this year") {
            let year = calendar.component(.year, from: now)
            return TimeWindow(since: "\(year)-01-01", until: nil, label: "\(year)", pattern: "this year")
        }
        if let match = lower.range(of: #"\b20[12]\d\b"#, options: .regularExpression) {
            let year = String(lower[match])
            return TimeWindow(since: "\(year)-01-01", until: "\(Int(year)! + 1)-01-01",
                              label: year, pattern: "\\b\(year)\\b")
        }
        return nil
    }

    func strip(from text: String) -> String {
        text.replacingOccurrences(of: pattern, with: " ",
                                  options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    func contains(_ day: String) -> Bool {
        if let since, day < since { return false }
        if let until, day >= until { return false }
        return true
    }
}

// MARK: - Asking

extension AppModel {
    /// Run one question through the chosen engine, filling the transcript in as
    /// the searches happen rather than at the end.
    func ask(_ question: String) async {
        let engine = conversation.engine
        var turn = Turn(question: question, engine: engine)
        conversation.turns.append(turn)
        let index = conversation.turns.count - 1

        func apply(_ change: (inout Turn) -> Void) {
            change(&turn)
            // Numbering is assigned in the order records are first seen, so a
            // citation keeps the same number everywhere it appears.
            var next = turn.numbering.count
            for call in turn.calls {
                for hit in call.hits where turn.numbering[hit.bookmark.id] == nil {
                    next += 1
                    turn.numbering[hit.bookmark.id] = next
                }
            }
            conversation.turns[index] = turn
        }

        let handle: @MainActor (AskEngine.Event) -> Void = { [self] event in
            switch event {
            case let .searching(query, reason):
                apply { $0.calls.append(SearchCall(number: $0.calls.count + 1,
                                                   query: query, reason: reason)) }
            case let .results(hits):
                apply {
                    guard !$0.calls.isEmpty else { return }
                    $0.calls[$0.calls.count - 1].hits = hits
                    $0.calls[$0.calls.count - 1].finished = true
                }
            case let .answer(parts, cited):
                apply {
                    $0.parts = parts
                    // Anything the model read is evidence, whether it cited it or
                    // not — hiding the rest would hide what it chose to ignore.
                    // The engine's own list comes first and is never dropped: a
                    // CLI engine reports what it cited without reporting the
                    // searches' results, and losing that left the panel empty.
                    var unique: [Int: Match] = [:]
                    for hit in $0.calls.flatMap(\.hits) where unique[hit.bookmark.id] == nil {
                        unique[hit.bookmark.id] = hit
                    }
                    for match in cited where unique[match.bookmark.id] == nil {
                        unique[match.bookmark.id] = match
                    }
                    let order = cited.map(\.bookmark.id)
                    $0.cited = order.compactMap { unique[$0] }
                        + unique.values.filter { !order.contains($0.bookmark.id) }
                            .sorted { $0.score > $1.score }
                    $0.working = false
                }
            case let .deadEnd(text):
                apply { $0.deadEnd = text; $0.working = false }
            case let .cost(amount):
                apply { $0.cost = amount }
                self.conversation.spent += amount
            case let .failed(message):
                apply { $0.error = message; $0.working = false }
            }
        }

        await AskEngine.run(engine: engine,
                            question: question,
                            chatModel: preferences.chatModel,
                            store: store,
                            key: key,
                            onEvent: handle)
    }
}

// MARK: - Importing from the browser

extension AppModel {
    /// Everything in a browser profile that is not saved here yet.
    /// Everything in a browser profile that is not saved here yet — and was not
    /// deleted here on purpose. A link deleted in Unbury is still in the
    /// browser, so without that second test the very next import would offer it
    /// back, which reads as the delete not having worked.
    /// What an import would offer, and how much of this profile it will step
    /// over. The count matters: a link deleted here stays in the browser, so
    /// without saying so the sheet reads as having lost track of it.
    func candidates(in profile: Browsers.Profile) async -> (rows: [Importer.Candidate], passedOver: Int) {
        let saved = Set(await store.bookmarks.map(\.url))
        let deleted = await store.discarded
        let links = (try? Browsers.read(profile.file)) ?? []
        var seen = Set<String>()
        var passedOver = 0
        let rows = links.compactMap { link -> Importer.Candidate? in
            guard seen.insert(link.url).inserted, !saved.contains(link.url) else { return nil }
            if deleted.contains(link.url) { passedOver += 1; return nil }
            return Importer.Candidate(url: link.url, title: link.title,
                                      folder: link.folder, savedOn: link.savedOn)
        }
        .sorted { $0.savedOn > $1.savedOn }
        return (rows, passedOver)
    }

    /// Import a chosen set of links, stamping each with the profile it came
    /// from. Nothing is written to the browser, ever.
    func runImport(_ chosen: [Importer.Candidate], from profile: Browsers.Profile?) async {
        // Two keys can be wanted here and they are not the same one: the
        // vectors always cost money, while describing only does when it is
        // OpenRouter doing it. `hasKey` knows which of them this setup needs.
        guard !importing, hasKey else {
            let service = VectorServices.resolve(preferences.vectorService)
            let missing = (vectorKey ?? "").isEmpty ? service.label : "OpenRouter"
            importProgress = "No \(missing) key — add one in settings."
            return
        }
        let key = self.key ?? ""
        importing = true
        importDone = 0
        importTotal = chosen.count
        importSpent = 0
        importProgress = "starting…"
        defer { importing = false }

        let importer = Importer(store: store,
                                client: OpenRouter(key: key, settings: openRouterSettings))
        activeImporter = importer

        let saved = await importer.run(chosen, from: profile?.id) { progress in
            Task { @MainActor in
                self.importDone = progress.done
                self.importTotal = progress.total
                self.importSpent = progress.spent
                self.importProgress = progress.note.isEmpty
                    ? "reading \(progress.current)…"
                    : "\(progress.current) — \(progress.note)"
            }
        }

        activeImporter = nil
        // `refreshCounts` reloads the vocabulary and the page inside the scope,
        // so newly imported links appear where they belong without a second ask.
        await refreshCounts()
        importProgress = stoppedImport
            ? "stopped · \(saved) saved, and kept"
            : "imported \(saved) \(saved == 1 ? "link" : "links") · " + String(format: "$%.3f", importSpent)
        stoppedImport = false
        if let profile { await sweep(profile) }
        if !query.isEmpty { search() }
    }

    /// Notice which of this profile's links the browser no longer has. Only the
    /// profile just read: one profile going quiet says nothing about another,
    /// and a sweep over the whole vault would declare half of it gone. Nothing
    /// is deleted — the sentence exists so a shorter list has a reason.
    private func sweep(_ profile: Browsers.Profile) async {
        guard let swept = try? await Importer.sweep(profiles: [profile], into: store),
              swept.gone > 0 || swept.returned > 0 else { return }
        await refreshCounts()
        var said: [String] = []
        if swept.gone > 0 {
            said.append("\(swept.gone) \(swept.gone == 1 ? "link is" : "links are") no longer in \(profile.name) — kept here, and still searchable")
        }
        if swept.returned > 0 {
            said.append("\(swept.returned) back in \(profile.name)")
        }
        importProgress = ((importProgress.map { [$0] } ?? []) + said).joined(separator: " · ")
    }

    /// Stop an import in flight. Everything already described is kept — the
    /// importer saves in batches precisely so this is never wasted work.
    func stopImport() {
        stoppedImport = true
        Task { await activeImporter?.stop() }
    }

    var openRouterSettings: OpenRouter.Settings {
        OpenRouter.Settings(embeddingModel: preferences.embeddingModel,
                            describeModel: preferences.describeModel,
                            dimensions: preferences.embeddingDimensions,
                            queryInstruction: OpenRouter.Settings.default.queryInstruction)
    }
}
