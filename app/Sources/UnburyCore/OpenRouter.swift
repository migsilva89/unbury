import Foundation

/// Buying the two things the app cannot make itself: the vector of a piece of
/// text, and — when a paid model is the one doing it — the sentence describing a
/// page.
///
/// Named after OpenRouter because that is where it started and where both jobs
/// still go by default. Vectors can now be bought from OpenAI instead, which is
/// `settings.vectorService`; describing always goes to OpenRouter, because the
/// other two ways of describing are programs on this Mac and live in
/// `CLIDescriber`.
public struct OpenRouter: Sendable {
    public struct Settings: Codable, Sendable {
        public var embeddingModel: String
        public var describeModel: String
        public var dimensions: Int
        /// Where the vectors are bought. Stored as its identifier so a settings
        /// file stays readable, and resolved through `VectorServices`.
        public var vectorServiceID: String
        public var vectorService: VectorService {
            VectorServices.resolve(vectorServiceID)
        }
        /// Qwen embedding models are trained expecting a query to arrive with its
        /// task spelled out. Stored records are embedded bare. Without this the
        /// scores bunch together and the wrong link wins — measured, not assumed.
        public var queryInstruction: String

        /// What this person actually chose, not what the app shipped with.
        ///
        /// It reads the settings file rather than holding a literal, because
        /// every caller that did not pass settings — `unburyctl search` among
        /// them — was quietly building its vectors with the shipped model even
        /// after the app had been told to use another. Two vectors made by
        /// different models cannot be compared, so that was a search silently
        /// answering the wrong question.
        public static var `default`: Settings {
            let chosen = Preferences.load()
            return Settings(embeddingModel: chosen.embeddingModel,
                            describeModel: chosen.describeModel,
                            dimensions: chosen.embeddingDimensions,
                            vectorService: chosen.vectorService,
                            queryInstruction: Self.instruction)
        }

        /// Qwen embedding models expect a query to arrive with its task spelled
        /// out; stored records are embedded bare. One sentence, one place.
        public static let instruction =
            "Given a search query in any language, retrieve the saved bookmark that best answers it"

        /// `vectorService` last and defaulted, so a caller that predates the
        /// choice — and there is one in the app — still compiles and still lands
        /// on whatever was chosen in settings rather than on a guess.
        public init(embeddingModel: String, describeModel: String = "moonshotai/kimi-k2",
                    dimensions: Int, vectorService: String? = nil,
                    queryInstruction: String) {
            self.embeddingModel = embeddingModel
            self.describeModel = describeModel
            self.dimensions = dimensions
            self.vectorServiceID = VectorServices.known(
                vectorService ?? Preferences.load().vectorService)
            self.queryInstruction = queryInstruction
        }
    }

    let key: String
    let settings: Settings

    public init(key: String, settings: Settings = .default) {
        self.key = key
        self.settings = settings
    }

    public func embedQuery(_ question: String) async throws -> [Float] {
        try await embed("Instruct: \(settings.queryInstruction)\nQuery: \(question)")
    }

    /// The key the vectors are bought with. The OpenRouter one is the key this
    /// client was handed; any other service keeps its own in the Keychain, under
    /// its own account, so both can be held at once.
    private func vectorKey() throws -> String {
        let service = settings.vectorService
        if service.id == VectorServices.openRouter.id { return key }
        guard let held = Keychain.read(service), !held.isEmpty else {
            throw UnburyError.missingKey(service)
        }
        return held
    }

    public func embed(_ text: String) async throws -> [Float] {
        let service = settings.vectorService
        var request = URLRequest(url: service.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(try vectorKey())", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": settings.embeddingModel,
            "input": text,
            "dimensions": settings.dimensions,
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            // 402 is the one that actually happens: the account ran out of credit.
            // Say so in words, because "402" tells a person nothing — and name
            // the service that refused, or the fix points at the wrong key.
            throw UnburyError.explain(http.statusCode, data, from: service)
        }
        struct Answer: Decodable { struct Item: Decodable { let embedding: [Float] }; let data: [Item] }
        guard let vector = try JSONDecoder().decode(Answer.self, from: data).data.first?.embedding else {
            throw UnburyError.badResponse("\(service.label) returned no vector.")
        }
        return vector
    }
}


// MARK: - Describing a page

extension OpenRouter: Describer {}

public extension OpenRouter {
    struct Description: Sendable {
        public let summary: String
        public let tags: [String]
        public let cost: Double
    }

    /// One sentence about a page, and the tags to file it under. This is the
    /// expensive half of an import — a page fetched, and a model paid to read it.
    /// `known` is the vocabulary already in the vault, most used first. It is sent
    /// with every page so the model files under a tag that exists instead of coining
    /// a variant of it. Capped, because it rides along in every paid request.
    /// The wording itself lives in `DescribePrompt`, because a page described by
    /// Claude Code and one described by Kimi have to be answers to the same
    /// question — two promptings would make one library read as two.
    func describe(title: String, url: String, folder: String, content: String,
                  known: [String] = []) async throws -> Description {
        let prompt = DescribePrompt.text(title: title, url: url, folder: folder,
                                         content: content, known: known)
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": settings.describeModel,
            "messages": [["role": "user", "content": prompt]],
            "max_tokens": 400,
            "usage": ["include": true],
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw UnburyError.explain(http.statusCode, data)
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let cost = ((json["usage"] as? [String: Any])?["cost"] as? Double) ?? 0
        let choices = json["choices"] as? [[String: Any]]
        let message = choices?.first?["message"] as? [String: Any]
        // A model can answer with nothing at all — empty, or a null where the text
        // should be. That is a bookmark to describe from its title, not a crash.
        let text = (message?["content"] as? String) ?? ""
        return DescribePrompt.read(text, title: title, cost: cost)
    }
}
