import Foundation

/// Who does the two paid jobs, and with whose key.
///
/// The app began assuming one company did everything, and said so on the settings
/// page: "both of them run through your key". That stopped being true. The two
/// jobs are unrelated and are chosen separately here:
///
/// - **Describing a page** is a piece of writing. Any capable model can do it,
///   including the two already installed on this Mac, which spend a subscription
///   instead of a key. Slow — a whole process per link — but nothing is charged.
/// - **Building a vector** is not writing, and the choice is far narrower.
///   Anthropic sells no embeddings at all, and a command-line tool cannot produce
///   one, so Claude Code and Codex are not options here and must never be offered
///   as if they were. That leaves the services that do sell them.

// MARK: - Who builds the vectors

/// A model on a paid service, and what it charges. Prices are per million tokens
/// as published; they are here rather than fetched because only two services are
/// offered and their embedding prices have not moved in a year — but they are
/// worded as "about", never as a promise.
public struct VectorModelOption: Identifiable, Sendable, Equatable {
    public let id: String
    public let label: String
    public let note: String
}

/// One place vectors can be bought from: where to send the text, whose key pays
/// for it, and how it says no.
public struct VectorService: Identifiable, Sendable, Equatable {
    public let id: String
    public let label: String
    /// The Keychain account its key is kept under. The OpenRouter key has lived
    /// under "openrouter" since the first version and stays exactly there.
    public let account: String
    public let endpoint: URL
    /// Where a key is created, for the link beside the field.
    public let keysPage: String
    /// What is asked for, to prove a key works, without buying anything.
    public let probe: URL
    public let note: String
    public let models: [VectorModelOption]

    public static func == (a: VectorService, b: VectorService) -> Bool { a.id == b.id }
}

public enum VectorServices {
    public static let openRouter = VectorService(
        id: "openrouter", label: "OpenRouter", account: "openrouter",
        endpoint: URL(string: "https://openrouter.ai/api/v1/embeddings")!,
        keysPage: "https://openrouter.ai/keys",
        probe: URL(string: "https://openrouter.ai/api/v1/key")!,
        note: "One key for both jobs, and Qwen handles a Portuguese question about an English page.",
        models: [
            VectorModelOption(id: "qwen/qwen3-embedding-8b", label: "Qwen3 Embedding 8B",
                              note: "About $0.01 per million tokens, and genuinely multilingual. What your library is built with."),
            VectorModelOption(id: "openai/text-embedding-3-small", label: "OpenAI 3 Small, via OpenRouter",
                              note: "About $0.02 per million tokens. English-first — a Portuguese question scores worse."),
        ])

    public static let openAI = VectorService(
        id: "openai", label: "OpenAI", account: "openai",
        endpoint: URL(string: "https://api.openai.com/v1/embeddings")!,
        keysPage: "https://platform.openai.com/api-keys",
        probe: URL(string: "https://api.openai.com/v1/models")!,
        note: "Straight to OpenAI, no company in the middle. Both its models are English-first.",
        models: [
            VectorModelOption(id: "text-embedding-3-small", label: "Text Embedding 3 Small",
                              note: "About $0.02 per million tokens. Enough for a few thousand links."),
            VectorModelOption(id: "text-embedding-3-large", label: "Text Embedding 3 Large",
                              note: "About $0.13 per million tokens, for a sharper English ranking."),
        ])

    public static let all: [VectorService] = [openRouter, openAI]

    public static func service(_ id: String) -> VectorService? { all.first { $0.id == id } }

    /// A service this version understands, so a settings file written by another
    /// one cannot point the app at somewhere it cannot reach.
    public static func known(_ id: String) -> String { service(id)?.id ?? openRouter.id }

    /// The service a stored choice resolves to.
    public static func resolve(_ id: String) -> VectorService { service(id) ?? openRouter }
}

public extension VectorService {
    /// Whether this key is accepted, asked in the cheapest way each service
    /// allows: OpenRouter reports what a key is, OpenAI lists its models. Neither
    /// buys anything. Throws a sentence, never a status code.
    func checkKey(_ key: String) async throws {
        var request = URLRequest(url: probe)
        request.timeoutInterval = 20
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { return }
        if http.statusCode != 200 { throw UnburyError.explain(http.statusCode, data, from: self) }
    }
}

public extension UnburyError {
    /// The same job `explain` already does for OpenRouter, done for whichever
    /// service actually refused. A wrong OpenAI key that reads as "OpenRouter
    /// refused the request (401)" sends somebody to fix the wrong key, which is
    /// worse than saying nothing.
    static func explain(_ status: Int, _ body: Data, from service: VectorService) -> UnburyError {
        guard service.id == VectorServices.openAI.id else { return explain(status, body) }
        let text = String(data: body, encoding: .utf8) ?? ""
        switch status {
        case 401:
            return .badResponse("That OpenAI key was not accepted. Check it in settings — an OpenAI key starts with sk- and is not the same as your OpenRouter one.")
        case 403:
            return .badResponse("OpenAI refused that key for this request. If the key belongs to a project, check the project is allowed to use embeddings.")
        case 404:
            return .badResponse("OpenAI has no model by that name. Check the vector model in settings — it is written without a slash there, like text-embedding-3-small.")
        case 429 where text.contains("insufficient_quota"):
            return .badResponse("Your OpenAI account has no credit left. Top up at platform.openai.com/settings/organization/billing and try again.")
        case 429:
            return .badResponse("OpenAI is asking us to slow down. Wait a moment and try again.")
        case 500...599:
            return .badResponse("OpenAI is having trouble (\(status)). Not your side — try again shortly.")
        default:
            return .badResponse("OpenAI refused the request (\(status)).")
        }
    }

    /// A key that was never entered. Named, because "no key" when two are
    /// possible is not something a person can act on.
    static func missingKey(_ service: VectorService) -> UnburyError {
        .badResponse("No \(service.label) key. Vectors are built by \(service.label), so add its key in settings — the field is beside your other one.")
    }
}

// MARK: - Who describes a page

/// Anything that can read a page and say what it is. Two things can: a model on
/// a paid service, which is `OpenRouter`, and a command-line tool already
/// installed on this Mac, which is `CLIDescriber`.
public protocol Describer: Sendable {
    func describe(title: String, url: String, folder: String, content: String,
                  known: [String]) async throws -> OpenRouter.Description
}

/// A way of describing pages, and — the part somebody actually decides on —
/// whose money and how long it takes.
public struct DescribeEngineOption: Identifiable, Sendable, Equatable {
    public let id: String
    /// The command that must exist on this Mac, or nil for the one that needs a
    /// key instead of a program.
    public let command: String?
    public let label: String
    /// Whether importing spends from a key held here.
    public let spends: Bool
    public let purse: String
    public let note: String
    /// Seconds one link takes, measured rather than guessed. A CLI is a whole
    /// process per link, and an import is hundreds of links in a row — the
    /// difference is minutes against an hour, and it has to be said out loud.
    public let secondsPerLink: Double
    /// Cents one link costs on this route.
    public let centsPerLink: Double
}

public enum DescribeEngines {
    public static let openRouter = "openrouter"
    public static let claudeCode = ChatEngines.claudeCode
    public static let codex = ChatEngines.codex

    /// Measured on this Mac on 2026-08-28, one real bookmark each, wall clock
    /// from launching the process to holding the JSON: OpenRouter with Kimi K2
    /// about 1.6 s, Claude Code about 6.7 s, Codex about 8.2 s.
    public static let all: [DescribeEngineOption] = [
        DescribeEngineOption(
            id: openRouter, command: nil, label: "A model on OpenRouter", spends: true,
            purse: "your key, per link",
            note: "The quickest by far — one request per link. Kimi K2 costs about 0.07 cents a link.",
            secondsPerLink: 1.6, centsPerLink: 0.068),
        DescribeEngineOption(
            id: claudeCode, command: "claude", label: "Claude Code", spends: false,
            purse: "your subscription",
            note: "Spends the subscription already on this Mac. Four times slower — a whole program per link.",
            secondsPerLink: 6.7, centsPerLink: 0),
        DescribeEngineOption(
            id: codex, command: "codex", label: "Codex", spends: false,
            purse: "your ChatGPT plan",
            note: "Spends the ChatGPT plan already on this Mac. The slowest, and the shortest descriptions.",
            secondsPerLink: 8.2, centsPerLink: 0),
    ]

    public static func option(_ id: String) -> DescribeEngineOption? { all.first { $0.id == id } }

    public static func known(_ id: String) -> String { option(id)?.id ?? openRouter }

    /// The ones this Mac can really run. Same rule as Ask: an engine that is not
    /// installed is left out rather than offered and then refused halfway
    /// through an import.
    public static func available() -> [DescribeEngineOption] {
        all.filter { engine in engine.command.map { ChatEngines.locate($0) != nil } ?? true }
    }

    /// What a stored choice should actually resolve to, and what will run it.
    /// Falls back to the paid service when the chosen tool has been uninstalled
    /// since — an import that stops on the first link is worse than one that
    /// costs what it always cost.
    public static func describer(_ id: String, fallingBackTo client: OpenRouter) -> Describer {
        guard id != openRouter, let cli = CLIDescriber(engine: id) else { return client }
        return cli
    }
}

// MARK: - The words sent, wherever they are sent

/// The one prompt, written once. Both routes send exactly this, so a description
/// written by Claude Code and one written by Kimi are answers to the same
/// question — otherwise a library would read as two libraries.
public enum DescribePrompt {
    static let template = """
    Write a short record for this bookmark, in ENGLISH.

    Reply with JSON only:
    {"summary": "1-2 sentences: what this page is and what it is for, concrete and specific", "tags": ["3 to 5 lowercase english tags, hyphenated, no accents"]}

    Rules:
    - Judge the page by its CONTENT, not by the folder. The folder is a weak hint and is
      often wrong or stale — ignore it when the content says otherwise.
    - Tags name the subject, the kind of thing, and the use ("fpv", "3d-printing",
      "open-source", "reference", "shop"). Never invent a tag the page does not support.
    - REUSE a tag from EXISTING TAGS whenever one fits, exactly as written there. A new
      spelling of a tag that already exists ("drones" beside "drone", "tailwindcss"
      beside "tailwind-css") splits one drawer in two and is a bug. Only coin a new tag
      when nothing in the list covers the page.
    - If the content is empty, work from the title and the domain and say what the site is.
    - No marketing language. Say what it does, not how great it is.
    - Never begin with "This page" — the same opening in every record makes them all
      look alike to the search that comes later.

    EXISTING TAGS (prefer these, verbatim): %@

    TITLE: %@
    URL: %@
    FOLDER (unreliable hint): %@
    CONTENT: %@
    """

    public static func text(title: String, url: String, folder: String, content: String,
                            known: [String]) -> String {
        let vocabulary = known.prefix(200).joined(separator: ", ")
        return String(format: template,
                      vocabulary.isEmpty ? "none yet — this is a new collection" : vocabulary,
                      title, url, folder, String(content.prefix(3500)))
    }

    /// The JSON out of whatever the model wrapped it in — a fence, a sentence
    /// before it, a narration around it. A model that answered with nothing
    /// usable is a bookmark described from its title, not a crash.
    public static func read(_ text: String, title: String, cost: Double) -> OpenRouter.Description {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"),
              start < end,
              let parsed = try? JSONSerialization.jsonObject(
                  with: Data(text[start...end].utf8)) as? [String: Any]
        else { return OpenRouter.Description(summary: title, tags: [], cost: cost) }
        let summary = (parsed["summary"] as? String) ?? title
        let tags = ((parsed["tags"] as? [Any])?.compactMap { $0 as? String } ?? []).prefix(5)
        return OpenRouter.Description(summary: summary.isEmpty ? title : summary,
                                      tags: Array(tags), cost: cost)
    }
}

// MARK: - Describing with a tool already on this Mac

/// Claude Code or Codex, asked one question and given no tools.
///
/// Both fixes that Ask needed are needed here for the same reasons and are
/// applied from the same place, `CLIProcess.prepare`: the tool inherits the
/// app's standard input and waits forever for a line that never comes, and an
/// app launched from the Finder is sitting in "/", which a tool that expects
/// somewhere writable is entitled to refuse.
public struct CLIDescriber: Describer {
    public let engine: DescribeEngineOption
    private let binary: String

    /// Nil when the tool is not on this Mac, so a caller cannot end up holding a
    /// describer that fails on every link.
    public init?(engine id: String) {
        guard let option = DescribeEngines.option(id),
              let command = option.command,
              let found = ChatEngines.locate(command) else { return nil }
        self.engine = option
        self.binary = found
    }

    public func describe(title: String, url: String, folder: String, content: String,
                         known: [String]) async throws -> OpenRouter.Description {
        let prompt = DescribePrompt.text(title: title, url: url, folder: folder,
                                         content: content, known: known)
        let spoken = try await run(prompt: prompt)
        // Cost is zero against a key, and that is the whole truth here: what it
        // spends is a subscription, which the settings page says in words.
        return DescribePrompt.read(spoken, title: title, cost: 0)
    }

    private func run(prompt: String) async throws -> String {
        // Codex will write its final message to a file when asked, which is far
        // more reliable than picking it out of a narration carrying hook lines
        // and a token count. Claude Code prints the answer and nothing else.
        let lastMessage = engine.id == DescribeEngines.codex
            ? FileManager.default.temporaryDirectory
                .appendingPathComponent("unbury-describe-\(UUID().uuidString).txt").path
            : nil
        defer { if let lastMessage { try? FileManager.default.removeItem(atPath: lastMessage) } }

        let result = try await CLIProcess.run(binary: binary,
                                              arguments: arguments(prompt: prompt,
                                                                   lastMessage: lastMessage),
                                              timeout: 120)
        if let lastMessage,
           let written = try? String(contentsOfFile: lastMessage, encoding: .utf8),
           !written.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return written
        }
        guard result.status == 0, !result.output.trimmingCharacters(in: .whitespaces).isEmpty else {
            // The tool's own last words. "Your access token was revoked" is
            // something a person can act on; "code 1" is not.
            let said = result.complaint
            throw UnburyError.badResponse(said.isEmpty
                ? "\(engine.label) stopped without describing anything (code \(result.status))."
                : "\(engine.label) could not describe it. It said: \(said)")
        }
        return result.output
    }

    private func arguments(prompt: String, lastMessage: String?) -> [String] {
        switch engine.id {
        case DescribeEngines.codex:
            // Read-only and no network: describing is a piece of writing about
            // text it has already been handed, so a tool that goes looking on
            // its own is a tool doing something nobody asked for.
            var arguments = ["exec", "--skip-git-repo-check", "--sandbox", "read-only",
                             "-C", FileManager.default.temporaryDirectory.path]
            if let lastMessage { arguments += ["-o", lastMessage] }
            return arguments + [prompt]
        default:
            return ["-p", prompt, "--allowedTools", ""]
        }
    }
}

/// Starting a command-line tool from inside an app, with the two things that
/// were learned the hard way in Ask applied in one place rather than copied.
public enum CLIProcess {
    public struct Result: Sendable {
        public let output: String
        public let errors: String
        public let status: Int32
        /// The last couple of real lines a failing tool wrote, with the
        /// timestamped log noise dropped, so a failure can be quoted.
        public var complaint: String {
            let useful = errors.split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("hook:") }
                .map { line -> String in
                    guard let range = line.range(of: "ERROR ") else { return line }
                    return String(line[range.upperBound...])
                }
            return useful.suffix(2).joined(separator: " ")
        }
    }

    /// Everything about launching one of these tools that is not about what is
    /// being asked. Ask streams its output and this waits for all of it, but
    /// both have to get these two lines right or the tool hangs.
    public static func prepare(_ process: Process, binary: String, arguments: [String]) {
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        // Codex reads its prompt from standard input when there is one to read,
        // and an app has no console: inheriting it left the tool waiting for a
        // line that never came. Handing it nothing closes that door.
        process.standardInput = FileHandle.nullDevice
        // An app launched from the Finder is sitting in "/", which a tool that
        // expects to be somewhere it can write is entitled to refuse.
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
    }

    /// Run it, wait for it, and hand back everything it said. Both pipes are
    /// drained, because a chatty tool that fills its error buffer blocks forever
    /// — and the last thing a failing tool writes is the reason it failed.
    public static func run(binary: String, arguments: [String],
                           timeout: TimeInterval) async throws -> Result {
        final class Box: @unchecked Sendable {
            let process = Process()
            func stop() { if process.isRunning { process.terminate() } }
        }
        let box = Box()
        let out = Pipe(), err = Pipe()
        prepare(box.process, binary: binary, arguments: arguments)
        box.process.standardOutput = out
        box.process.standardError = err

        do { try box.process.run() } catch {
            throw UnburyError.badResponse("Could not start \(binary): \(error.localizedDescription)")
        }
        // A tool that never answers must not stop an import of six hundred
        // links for good. Killed, and the link is described from its title.
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(timeout))
            box.stop()
        }
        let errors = Task.detached { String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) }
        let output = await Task.detached { String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) }.value
        let complaints = await errors.value
        box.process.waitUntilExit()
        watchdog.cancel()
        return Result(output: output, errors: complaints, status: box.process.terminationStatus)
    }
}
