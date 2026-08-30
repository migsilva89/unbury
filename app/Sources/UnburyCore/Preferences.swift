import Foundation

/// Settings that survive a restart. The key is not here — it lives in the
/// Keychain — and neither is the database password, for the same reason.
public struct Preferences: Codable, Sendable {
    public var embeddingModel: String
    public var describeModel: String
    public var embeddingDimensions: Int
    /// Who reads a page and writes the sentence under it, as one of the
    /// identifiers in `DescribeEngines`: a model on OpenRouter, or one of the
    /// command-line tools already on this Mac. `describeModel` matters only for
    /// the first — the other two bring their own model along with their own bill.
    public var describeEngine: String
    /// Who turns text into the numbers a search is ranked by, as one of the
    /// identifiers in `VectorServices`. Never a command-line tool: Anthropic
    /// sells no embeddings and a CLI cannot make one.
    public var vectorService: String
    /// Which engine answers in Ask, as one of the identifiers in `ChatEngines`.
    /// A string rather than an enum because this file has to survive a version
    /// that offers an engine this one has never heard of.
    public var chatEngine: String
    /// The model Ask sends a question to, and only when `chatEngine` is
    /// OpenRouter — the other two engines bring their own.
    public var chatModel: String
    /// Path of the browser profile this person imports from. Remembered because
    /// nine of the ten profiles on a Mac are noise, and picking through them
    /// every time is a chore the app should only ask about once.
    public var browserProfile: String

    public static let empty = Preferences(
        embeddingModel: "qwen/qwen3-embedding-8b",
        describeModel: "moonshotai/kimi-k2",
        embeddingDimensions: 1024,
        describeEngine: DescribeEngines.openRouter,
        vectorService: VectorServices.openRouter.id,
        chatEngine: ChatEngines.claudeCode,
        chatModel: "anthropic/claude-sonnet-5",
        browserProfile: "")

    private static let file = UnburyStore.defaultDirectory
        .appendingPathComponent("settings.json")

    public static func load() -> Preferences {
        guard let data = try? Data(contentsOf: file),
              let saved = try? JSONDecoder().decode(Preferences.self, from: data)
        else { return .empty }
        return saved
    }

    public func save() throws {
        try FileManager.default.createDirectory(at: UnburyStore.defaultDirectory,
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: Self.file)
    }

    /// Read a settings file field by field, so that one missing key cannot throw
    /// away the other five. The synthesised decoder is all-or-nothing: adding a
    /// setting to this struct would have silently reset everybody's models and
    /// browser choice the first time the app read a file written before it.
    /// `engine` is the name `chatEngine` was written under until 2026-08-28.
    public init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        func text(_ key: CodingKeys, or fallback: String) -> String {
            let value = (try? box.decodeIfPresent(String.self, forKey: key)) ?? nil
            return (value?.isEmpty ?? true) ? fallback : value!
        }
        let fallback = Preferences.empty
        embeddingModel = text(.embeddingModel, or: fallback.embeddingModel)
        describeModel = text(.describeModel, or: fallback.describeModel)
        embeddingDimensions = ((try? box.decodeIfPresent(Int.self, forKey: .embeddingDimensions)) ?? nil)
            ?? fallback.embeddingDimensions
        // A file written before these two existed means what it always meant:
        // everything through OpenRouter. That is what the fallbacks say.
        describeEngine = DescribeEngines.known(text(.describeEngine, or: fallback.describeEngine))
        vectorService = VectorServices.known(text(.vectorService, or: fallback.vectorService))
        let attic = try decoder.container(keyedBy: FormerKeys.self)
        let former = (try? attic.decodeIfPresent(String.self, forKey: .engine)) ?? nil
        chatEngine = ChatEngines.known(text(.chatEngine, or: former ?? fallback.chatEngine))
        chatModel = text(.chatModel, or: fallback.chatModel)
        browserProfile = text(.browserProfile, or: "")
    }

    private enum CodingKeys: String, CodingKey {
        case embeddingModel, describeModel, embeddingDimensions
        case describeEngine, vectorService
        case chatEngine, chatModel, browserProfile
    }

    /// Names this file used to be written under. Read, never written, so the old
    /// spelling dies out the first time somebody saves.
    private enum FormerKeys: String, CodingKey {
        case engine
    }

    public init(embeddingModel: String, describeModel: String, embeddingDimensions: Int,
                describeEngine: String = DescribeEngines.openRouter,
                vectorService: String = "openrouter",
                chatEngine: String, chatModel: String, browserProfile: String) {
        self.embeddingModel = embeddingModel
        self.describeModel = describeModel
        self.embeddingDimensions = embeddingDimensions
        self.describeEngine = describeEngine
        self.vectorService = vectorService
        self.chatEngine = chatEngine
        self.chatModel = chatModel
        self.browserProfile = browserProfile
    }
}

// MARK: - Which engine answers a question

/// One way of answering a question in Ask, and — the part a person actually has
/// to decide on — who pays for it.
public struct ChatEngineOption: Identifiable, Sendable, Equatable {
    public let id: String
    public let label: String
    /// The command that has to exist on this Mac, or nil for the engine that
    /// runs on OpenRouter's servers and needs a key instead of a program.
    public let command: String?
    /// Whether asking a question spends from this person's OpenRouter balance.
    /// The other two are not cheaper — they spend a subscription that is already
    /// being paid for — but only this one turns a question into a charge here,
    /// and only this one needs a model chosen for it.
    public let spends: Bool
    /// Whose money a question comes out of, in two or three words, for the place
    /// beside the name where there is no room for a sentence.
    public let purse: String
    /// One sentence saying what it is and what it spends, in the words somebody
    /// would use out loud.
    public let note: String
}

/// The engines Ask can run through, and whether this Mac can actually run them.
///
/// An engine that is not installed must never be offered: a choice that turns
/// into "not installed on this Mac" the first time a question is asked is worse
/// than never having been offered the choice at all.
public enum ChatEngines {
    public static let claudeCode = "claude-code"
    public static let codex = "codex"
    public static let openRouter = "openrouter"

    public static let all: [ChatEngineOption] = [
        ChatEngineOption(
            id: claudeCode, label: "Claude Code", command: "claude", spends: false,
            purse: "your subscription",
            note: "Runs the copy of Claude Code already on this Mac, and spends the subscription you already pay for it. Nothing goes through your OpenRouter key."),
        ChatEngineOption(
            id: codex, label: "Codex", command: "codex", spends: false,
            purse: "your ChatGPT plan",
            note: "Runs the copy of Codex already on this Mac, and spends the ChatGPT plan you already pay for it. Nothing goes through your OpenRouter key."),
        ChatEngineOption(
            id: openRouter, label: "OpenRouter", command: nil, spends: true,
            purse: "your key, per question",
            note: "Needs no other program, and works on any Mac. It spends from your OpenRouter key every time you ask, and the model you pick below decides how much."),
    ]

    public static func option(_ id: String) -> ChatEngineOption? { all.first { $0.id == id } }

    /// An identifier this version understands, so a settings file written by
    /// another one cannot leave the app pointed at an engine that does not exist.
    public static func known(_ id: String) -> String {
        option(id) != nil ? id : Preferences.empty.chatEngine
    }

    /// The engines this Mac can really run, in the order they should be offered.
    /// Touches the disk, so ask once when a screen appears rather than while it
    /// is being drawn.
    public static func available() -> [ChatEngineOption] {
        all.filter { engine in engine.command.map { locate($0) != nil } ?? true }
    }

    /// The engine a stored choice should actually resolve to: what was chosen if
    /// it can still run, and otherwise the first one that can. Nil only on a Mac
    /// where nothing at all is available, which cannot happen while OpenRouter
    /// needs no program.
    public static func resolve(_ id: String) -> ChatEngineOption? {
        let usable = available()
        return usable.first { $0.id == id } ?? usable.first
    }

    /// Where a command-line tool actually is. The obvious directories first, then
    /// the PATH this process inherited, then Node's version manager — a tool
    /// installed under a version number is still installed, and calling it
    /// missing would be a lie a person cannot argue with.
    public static func locate(_ command: String) -> String? {
        var directories = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin",
                           NSHomeDirectory() + "/.local/bin",
                           NSHomeDirectory() + "/.claude/local"]
        directories += (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map(String.init)
        let nvm = NSHomeDirectory() + "/.nvm/versions/node"
        directories += ((try? FileManager.default.contentsOfDirectory(atPath: nvm)) ?? [])
            .sorted(by: >).map { nvm + "/" + $0 + "/bin" }

        for directory in directories {
            let path = directory + "/" + command
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }
}

// MARK: - Which model, when the engine is OpenRouter

/// What OpenRouter says about a model right now: its price, and whether it can
/// use a tool at all. A model that cannot call a tool cannot search the vault,
/// so it cannot answer here however good it is.
public struct ChatModelFacts: Sendable, Equatable {
    public let name: String
    /// Dollars per million tokens, as published.
    public let input: Double
    public let output: Double
    public let callsTools: Bool
}

/// A model worth offering for Ask, and why somebody would pick it.
public struct ChatModelOption: Identifiable, Sendable, Equatable {
    public let id: String
    public let label: String
    public let note: String
}

public enum ChatModels {
    /// A short list rather than the four hundred models OpenRouter carries. All
    /// four take tools, which Ask cannot work without, and they are here to be
    /// told apart by price. Anything else can still be typed in by hand, and is
    /// checked against the live list before it is allowed to be saved.
    public static let offered: [ChatModelOption] = [
        ChatModelOption(id: "moonshotai/kimi-k2", label: "Kimi K2",
                        note: "The cheapest here, and already the model that writes your descriptions."),
        ChatModelOption(id: "anthropic/claude-haiku-4.5", label: "Claude Haiku 4.5",
                        note: "Quick and cheap, and rarely misreads a question."),
        ChatModelOption(id: "anthropic/claude-sonnet-5", label: "Claude Sonnet 5",
                        note: "The most careful reader of the four, and the one that rephrases a weak search best."),
        ChatModelOption(id: "openai/gpt-5.4", label: "GPT-5.4",
                        note: "Strong at following an instruction to the letter, and the dearest here."),
    ]

    /// A question is not one request: the model searches two or three times,
    /// reads what came back, and then writes a few sentences. These two sizes
    /// are what turn a price per million tokens into the only number anybody
    /// cares about — what one question costs. Reckoned from the shape of a turn
    /// and deliberately generous, so the figure shown is never the flattering one.
    static let tokensRead = 12_000
    static let tokensWritten = 600

    public static func perQuestion(_ facts: ChatModelFacts) -> Double {
        facts.input * Double(tokensRead) / 1_000_000
            + facts.output * Double(tokensWritten) / 1_000_000
    }

    /// The price as a sentence. Cents, because a fraction of a dollar written in
    /// four decimal places is a number nobody can feel.
    public static func inWords(_ facts: ChatModelFacts) -> String {
        let cents = perQuestion(facts) * 100
        if cents < 1 { return "under a cent a question" }
        if cents < 10 { return "about \(Int(cents.rounded())) cents a question" }
        return String(format: "about $%.2f a question", cents / 100)
    }

    /// Today's prices, straight from OpenRouter's public model list. No key is
    /// sent and nothing is charged — it is the same list the website shows. The
    /// prices are never written down in the app on purpose: a figure that quietly
    /// goes stale is worse than one that is sometimes missing.
    public static func catalogue() async throws -> [String: ChatModelFacts] {
        struct Answer: Decodable {
            struct Model: Decodable {
                struct Pricing: Decodable { let prompt: String?; let completion: String? }
                let id: String
                let name: String?
                let pricing: Pricing?
                let supported_parameters: [String]?
            }
            let data: [Model]
        }
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/models")!)
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw UnburyError.explain(http.statusCode, data)
        }
        let models = try JSONDecoder().decode(Answer.self, from: data).data
        return Dictionary(uniqueKeysWithValues: models.map { model in
            // Published per token; every price in this app is per million, which
            // is the unit the models are actually advertised in.
            let input = (model.pricing?.prompt).flatMap(Double.init) ?? 0
            let output = (model.pricing?.completion).flatMap(Double.init) ?? 0
            return (model.id, ChatModelFacts(name: model.name ?? model.id,
                                             input: input * 1_000_000,
                                             output: output * 1_000_000,
                                             callsTools: model.supported_parameters?
                                                 .contains("tools") ?? false))
        })
    }
}

public extension Keychain {
    /// The database password, kept beside the OpenRouter key rather than in a
    /// settings file that syncs or gets copied around.
    static func readDatabasePassword() -> String? { read(account: "postgres") }
    @discardableResult
    static func writeDatabasePassword(_ value: String) -> Bool {
        write(account: "postgres", value: value)
    }
}
