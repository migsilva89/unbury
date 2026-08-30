import Foundation

// A terminal front end for UnburyCore, so the engine can be proved before the app
// exists — and so a failure can be told apart from a UI bug later.
//
//   unburyctl sync                    pull the vault down from the Pi
//   unburyctl search "…"              ask a question
//   unburyctl status                  what the local copy holds
//   unburyctl list --tag a --tag b    the links carrying every one of those tags
//   unburyctl lookup <url> …          the stored record for an address
//   unburyctl gone                    note which links the browser no longer has
//   unburyctl remove <id|url> … --yes delete records, and stop them coming back
//   unburyctl restore <url> …         let a deleted address be imported again

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("error: " + message + "\n").utf8))
    exit(1)
}

/// Read the same .env the Python side uses, so there is one place to change.
func environment() -> [String: String] {
    let file = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .deletingLastPathComponent().appendingPathComponent(".env")
    var values: [String: String] = [:]
    if let text = try? String(contentsOf: file, encoding: .utf8) {
        for line in text.split(separator: "\n") where line.contains("=") {
            let parts = line.split(separator: "=", maxSplits: 1)
            values[String(parts[0]).trimmingCharacters(in: .whitespaces)] =
                String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
    return values
}

/// Everything from `index` on that is not a flag or a flag's value — the words a
/// person actually typed, with `--tag drones --json` taken out of the middle.
func words(after index: Int, of arguments: [String]) -> String {
    var out: [String] = []
    var position = index
    while position < arguments.count {
        let argument = arguments[position]
        if argument.hasPrefix("--") {
            position += flagsTakingAValue.contains(argument) ? 2 : 1
            continue
        }
        out.append(argument)
        position += 1
    }
    return out.joined(separator: " ")
}

let flagsTakingAValue: Set<String> = ["--tag", "--limit", "--offset", "--profile"]

/// The value given to a flag, when there is one.
func value(of flag: String, in arguments: [String]) -> String? {
    guard let position = arguments.firstIndex(of: flag), position + 1 < arguments.count
    else { return nil }
    return arguments[position + 1]
}

/// Every value given to a repeated flag, in the order it was typed.
func values(of flag: String, in arguments: [String]) -> [String] {
    arguments.indices
        .filter { arguments[$0] == flag && $0 + 1 < arguments.count }
        .map { arguments[$0 + 1] }
}

func serverFromEnvironment() -> PiSync.Server {
    guard let url = environment()["DATABASE_URL"],
          let parsed = URLComponents(string: url),
          let host = parsed.host, let user = parsed.user, let password = parsed.password
    else { fail("DATABASE_URL missing or unreadable in ../.env") }
    return PiSync.Server(host: host, port: parsed.port ?? 5432,
                         database: String(parsed.path.dropFirst()),
                         username: user,
                         password: password.removingPercentEncoding ?? password)
}

public enum UnburyCLI {
    public static let commands: Set<String> = [
        "sync", "search", "status", "list", "lookup", "gone", "browsers",
        "import", "remove", "restore",
    ]

    public static func run(arguments: [String]) async throws {
        let store = UnburyStore()
        guard let command = arguments.first else {
            print("usage: unburyctl [sync|search \"question\"|status|list|lookup|gone|browsers|import|remove|restore]")
            return
        }

        switch command {
case "sync":
    let sync = PiSync(server: serverFromEnvironment())
    print("pulling from the Pi…")
    let result = try await sync.pull()
    let stamp = ISO8601DateFormatter().string(from: Date())
    try await store.replace(bookmarks: result.bookmarks, vectors: result.vectors,
                            dimensions: result.dimensions, syncedAt: stamp)
    let megabytes = Double(result.vectors.count * 4) / 1_000_000
    print(String(format: "%d bookmarks · %d dimensions · %.1f MB of vectors · %.1fs",
                 result.bookmarks.count, result.dimensions, megabytes, result.seconds))
    print("mirror at \(UnburyStore.defaultDirectory.path)")

case "status":
    try await store.load()
    let count = await store.count
    let synced = await store.syncedAt ?? "never"
    let dimensions = await store.dimensions
    print("\(count) bookmarks · \(dimensions) dimensions · last synced \(synced)")

case "search":
    guard arguments.count > 1 else { fail("what should I search for?") }
    // --json is what Claude Code and Codex call when the app hands them the
    // vault: they already know how to run a command, so the search tool is a
    // command rather than a protocol.
    let wantsJSON = arguments.contains("--json")
    let question = words(after: 1, of: arguments)
    try await store.load()
    let count = await store.count
    guard count > 0 else { fail("the local copy is empty — run `unburyctl sync` first") }
    // Keychain first: this runs from inside the app bundle as often as from a
    // terminal, and only the Keychain is found from both.
    guard let key = Keychain.readKey() ?? environment()["OPENROUTER_API_KEY"] else {
        fail("no OpenRouter key in the Keychain or ../.env")
    }
    let asking = Date()
    let vector = try await OpenRouter(key: key).embedQuery(question)
    let asked = Date()
    // --tag may be given more than once, and narrows to links carrying all of them.
    let tags = values(of: "--tag", in: arguments)
    let matches = await store.search(vector: vector, within: tags, limit: 8)
    let ranked = Date()

    if wantsJSON {
        let payload = matches.prefix(8).map { match in
            [
                "id": match.bookmark.id, "score": (match.score * 1000).rounded() / 1000,
                "title": match.bookmark.displayTitle, "summary": match.bookmark.summary,
                "site": match.bookmark.site, "saved_on": match.bookmark.savedOn,
                "tags": match.bookmark.tags, "url": match.bookmark.url,
            ] as [String: Any]
        }
        let body: [String: Any] = ["query": question, "searched": count, "results": payload]
        let data = try JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted, .sortedKeys])
        print(String(data: data, encoding: .utf8)!)
        break
    }
    print(String(format: "vector from OpenRouter: %.0f ms · ranked %d locally: %.1f ms\n",
                 asked.timeIntervalSince(asking) * 1000, count,
                 ranked.timeIntervalSince(asked) * 1000))
    for match in matches.prefix(5) {
        print(String(format: "  %.3f  %-24@ %@", match.score,
                     match.bookmark.site as NSString,
                     String(match.bookmark.displayTitle.prefix(58)) as NSString))
    }

case "browsers":
    for profile in Browsers.installed() {
        print(String(format: "  %-24@ %5d bookmarks  %@", profile.label as NSString,
                     profile.count, profile.file.path as NSString))
    }

case "import":
    // The same importer the app runs, so a failure here is a failure there.
    try await store.load()
    guard let key = Keychain.readKey() ?? environment()["OPENROUTER_API_KEY"] else {
        fail("no OpenRouter key in the Keychain or ../.env")
    }
    let limit = value(of: "--limit", in: arguments).flatMap(Int.init) ?? 0
    let force = arguments.contains("--force")
    guard let profile = Browsers.installed().first else { fail("no browser found") }

    let saved = Set(await store.bookmarks.map(\.url))
    // Links deleted here on purpose are still in the browser. Offering them
    // again at the next import would read as the delete not having worked, so
    // they are passed over — `restore` is how a person changes their mind, and
    // `--force` re-reads everything as it always did.
    let deleted = await store.discarded
    var links = (try Browsers.read(profile.file))
    if !force { links = links.filter { !saved.contains($0.url) && !deleted.contains($0.url) } }
    if !force, !deleted.isEmpty {
        let skipped = (try Browsers.read(profile.file)).filter { deleted.contains($0.url) }.count
        if skipped > 0 { print("\(skipped) still in the browser were deleted here — passing over them") }
    }
    var seen = Set<String>()
    var candidates = links.compactMap { link -> Importer.Candidate? in
        guard seen.insert(link.url).inserted else { return nil }
        return Importer.Candidate(url: link.url, title: link.title,
                                  folder: link.folder, savedOn: link.savedOn)
    }
    if limit > 0 { candidates = Array(candidates.prefix(limit)) }
    print("\(profile.label): \(candidates.count) to import\n")

    let importer = Importer(store: store, client: OpenRouter(key: key))
    let done = await importer.run(candidates, from: profile.id) { progress in
        let line = progress.note.isEmpty ? "reading \(progress.current)…"
                                         : "\(progress.current) — \(progress.note)"
        print(String(format: "  %3d/%3d  $%.4f  %@", progress.done, progress.total,
                     progress.spent, line as NSString))
    }
    print("\n\(done) imported · \(await store.count) saved")

case "list":
    // What the interface asks for when a tag is chosen: one screenful and a
    // count, rather than every row at once.
    try await store.load()
    let tags = values(of: "--tag", in: arguments)
    let offset = value(of: "--offset", in: arguments).flatMap(Int.init) ?? 0
    let limit = value(of: "--limit", in: arguments).flatMap(Int.init) ?? 20
    let page = await store.page(tagged: tags, offset: offset, limit: limit)
    let named = tags.isEmpty ? "everything" : tags.joined(separator: " + ")
    print("\(named): \(page.total) links · showing \(page.bookmarks.count) from \(page.offset)\(page.hasMore ? " · more to come" : "")\n")
    for bookmark in page.bookmarks {
        let note = bookmark.isGoneFromBrowser ? "  (gone from your browser \(bookmark.goneFromBrowserOn!))" : ""
        print(String(format: "  %-24@ %@%@", bookmark.site as NSString,
                     String(bookmark.displayTitle.prefix(58)) as NSString, note as NSString))
    }

case "remove":
    // Deleting for real, from the terminal. Both files are rewritten together —
    // vault.json and the block of vectors are indexed against each other by
    // position, so a record can never leave one without the other being rebuilt.
    try await store.load()
    let asked = Array(arguments.dropFirst()).filter { $0 != "--yes" }
    guard !asked.isEmpty else { fail("which records? give ids or addresses") }
    let all = await store.bookmarks
    var going: [Bookmark] = []
    for word in asked {
        if let id = Int(word), let found = all.first(where: { $0.id == id }) {
            going.append(found)
        } else if let found = all.first(where: { $0.url == word }) {
            going.append(found)
        } else {
            print("  not here: \(word)")
        }
    }
    guard !going.isEmpty else { fail("none of those are in the vault") }
    for bookmark in going {
        print("  #\(bookmark.id)  \(String(bookmark.displayTitle.prefix(58)))")
        print("     \(bookmark.url)")
    }
    guard arguments.contains("--yes") else {
        print("\n\(going.count) would be deleted. This cannot be undone — add --yes to go through with it.")
        break
    }
    let before = await store.count
    try await store.discard(ids: Set(going.map(\.id)))
    let after = await store.count
    print("""

        \(before - after) deleted · \(after) left
        Your browser is untouched, so those bookmarks are still in it — the next
        import will pass over them. `unburyctl restore <url>` lifts that.
        """)

case "restore":
    // Not undeleting: the record and its paid-for description are gone. This
    // only lets the address be imported again.
    try await store.load()
    let urls = Array(arguments.dropFirst())
    guard !urls.isEmpty else { fail("which address?") }
    let lifted = try await store.restore(urls: urls)
    let left = await store.discarded.count
    print("\(lifted) of \(urls.count) will be offered again at the next import · \(left) still passed over")

case "lookup":
    // What the answer's citations need: the record behind an address, without
    // asking the question again and hoping the same link comes back.
    try await store.load()
    let urls = Array(arguments.dropFirst())
    guard !urls.isEmpty else { fail("which address?") }
    let found = await store.bookmarks(urls: urls)
    guard !found.isEmpty else { fail("none of those are in the vault") }
    for bookmark in found {
        print("  #\(bookmark.id)  \(bookmark.displayTitle)")
        print("     \(bookmark.url)")
        print("     tags: \(bookmark.tags.joined(separator: ", "))")
    }

case "gone":
    // Reading a browser to see what it no longer has. Nothing is deleted here,
    // by design — the record stays and says so.
    try await store.load()
    let profiles = Browsers.installed()
    guard !profiles.isEmpty else { fail("no browser found") }
    let chosen = value(of: "--profile", in: arguments)
        .flatMap { name in profiles.first { $0.label.localizedCaseInsensitiveContains(name) } }
    let read = chosen.map { [$0] } ?? profiles
    print("reading \(read.map(\.label).joined(separator: ", "))…")
    let sweep = try await Importer.sweep(profiles: read, into: store)
    print("\(sweep.gone) newly gone · \(sweep.returned) back · \(sweep.claimed) matched to a profile")

default:
    fail("unknown command \(command)")
        }
    }
}
