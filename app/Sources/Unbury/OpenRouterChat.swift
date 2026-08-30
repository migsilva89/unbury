import Foundation
import UnburyCore

/// The OpenRouter engine: an ordinary tool-calling loop, so the model decides
/// when to search and with what words. Works on any machine with a key, and is
/// the only engine that costs money per conversation — which is why the spend is
/// shown in the transcript rather than hidden.
///
/// The answer is streamed, so the prose appears as it is written. Nothing that
/// arrives this way is ever kept: the transcript only gains the finished text,
/// once the citations in it have been matched to real records.
struct OpenRouterChat {
    let key: String
    let model: String
    let store: UnburyStore
    let embedder: OpenRouter

    static var searchTool: [String: Any] { [
        "type": "function",
        "function": [
            "name": "search_vault",
            "description": "Search the person's saved bookmarks by meaning. Returns the closest records with a similarity score; above 0.55 is a good match, below 0.45 means nothing relevant was found.",
            "parameters": [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "What to look for, described in plain words."],
                    "reason": ["type": "string", "description": "One short line: why this wording, especially when retrying."],
                ],
                "required": ["query"],
            ],
        ],
    ] }

    func run(question: String,
             onEvent: @escaping @MainActor (AskEngine.Event) -> Void) async {
        await AskLive.shared.begin("putting the question to the model…")
        await go(question: question, onEvent: onEvent)
        await AskLive.shared.end()
    }

    private func go(question: String,
                    onEvent: @escaping @MainActor (AskEngine.Event) -> Void) async {
        let earlier = await MainActor.run { AskLive.shared.conversation?.priorExchanges() ?? [] }
        var messages: [[String: Any]] = [
            ["role": "system", "content": AskEngine.systemPrompt],
        ]
        // The conversation so far, as itself. A follow-up like "and the other
        // one?" is unanswerable without it, and the model searches again anyway
        // because the system prompt tells it to.
        for exchange in earlier {
            messages.append(["role": "user", "content": exchange.question])
            messages.append(["role": "assistant", "content": exchange.answer])
        }
        messages.append(["role": "user", "content": question])

        var everything: [Int: Match] = [:]
        var spent = 0.0

        for _ in 0..<5 {
            let askedToStop = await AskLive.shared.stopping
            if Task.isCancelled || askedToStop {
                await onEvent(.failed(AskEngine.stopped))
                return
            }
            let round: Round
            do {
                round = try await call(messages: messages)
            } catch is CancellationError {
                await onEvent(.failed(AskEngine.stopped))
                return
            } catch {
                let asked = await AskLive.shared.stopping
                if Task.isCancelled || asked {
                    await onEvent(.failed(AskEngine.stopped))
                    return
                }
                await onEvent(.failed(error.localizedDescription))
                return
            }
            spent += round.cost
            messages.append(round.assistantMessage)

            if !round.calls.isEmpty {
                for call in round.calls {
                    guard let parsed = try? JSONSerialization.jsonObject(
                            with: Data(call.arguments.utf8)) as? [String: Any],
                          let query = parsed["query"] as? String else { continue }
                    await AskLive.shared.beginSearch()
                    await onEvent(.searching(query: query, reason: parsed["reason"] as? String))
                    let hits = await lookUp(query)
                    for hit in hits { everything[hit.bookmark.id] = hit }
                    await AskLive.shared.say(hits.isEmpty
                        ? "nothing came back — trying another wording…"
                        : "reading \(hits.count) records…")
                    await onEvent(.results(hits))
                    messages.append([
                        "role": "tool",
                        "tool_call_id": call.id,
                        "content": describe(hits),
                    ])
                }
                continue
            }

            await onEvent(.cost(spent))
            await finish(text: round.content, everything: everything, onEvent: onEvent)
            return
        }
        await onEvent(.failed("Gave up after five searches without an answer."))
    }

    @MainActor
    private func finish(text: String, everything: [Int: Match],
                        onEvent: @escaping @MainActor (AskEngine.Event) -> Void) async {
        let (parts, citedIDs) = Citations.split(text)
        let cited = citedIDs.compactMap { everything[$0] }.sorted { $0.score > $1.score }
        if cited.isEmpty && everything.values.allSatisfy({ $0.score < AppModel.confident }) {
            onEvent(.deadEnd(text))
        } else {
            onEvent(.answer(parts, cited: cited))
        }
    }

    private func lookUp(_ query: String) async -> [Match] {
        guard let vector = try? await embedder.embedQuery(query) else { return [] }
        let found = await store.search(vector: vector, limit: 8)
        return found.filter { $0.score >= 0.30 }
    }

    private func describe(_ hits: [Match]) -> String {
        guard !hits.isEmpty else {
            return "No records came back above the threshold. Nothing saved matches this wording."
        }
        return hits.map { hit in
            let b = hit.bookmark
            return "[\(b.id)] \(String(format: "%.2f", hit.score)) — \(b.displayTitle) (\(b.site), saved \(b.savedOn))\n\(b.summary)\ntags: \(b.tags.joined(separator: ", "))"
        }.joined(separator: "\n\n")
    }

    // MARK: one round, read as it arrives

    /// What one exchange with the model produced: either words, or searches to run.
    private struct Round {
        var content = ""
        var calls: [ToolCall] = []
        var cost = 0.0
        /// The assistant's turn, in the shape the API wants it handed back.
        var assistantMessage: [String: Any] {
            var message: [String: Any] = ["role": "assistant", "content": content]
            if !calls.isEmpty {
                message["tool_calls"] = calls.map { call in
                    ["id": call.id, "type": "function",
                     "function": ["name": call.name, "arguments": call.arguments]] as [String: Any]
                }
            }
            return message
        }
    }

    private struct ToolCall {
        var id = ""
        var name = ""
        var arguments = ""
    }

    private func call(messages: [[String: Any]]) async throws -> Round {
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "messages": messages,
            "tools": [Self.searchTool],
            "stream": true,
            "usage": ["include": true],
        ])

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            if http.statusCode == 402 {
                throw UnburyError.badResponse("The OpenRouter key has no credit left.")
            }
            var body = ""
            for try await line in bytes.lines where body.count < 400 { body += line }
            throw UnburyError.badResponse("OpenRouter answered \(http.statusCode): \(body.prefix(180))")
        }

        var round = Round()
        var partial: [Int: ToolCall] = [:]
        for try await line in bytes.lines {
            // Stopping mid-answer: drop the connection rather than finish paying
            // for words nobody is going to read.
            let asked = await AskLive.shared.stopping
            if asked { throw CancellationError() }
            guard line.hasPrefix("data: ") else { continue }
            let payload = String(line.dropFirst(6))
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            if let usage = event["usage"] as? [String: Any],
               let cost = usage["cost"] as? Double { round.cost = cost }
            if let error = event["error"] as? [String: Any],
               let message = error["message"] as? String {
                throw UnburyError.badResponse("OpenRouter: \(message)")
            }
            guard let choice = (event["choices"] as? [[String: Any]])?.first,
                  let delta = choice["delta"] as? [String: Any] else { continue }

            if let piece = delta["content"] as? String, !piece.isEmpty {
                round.content += piece
                await AskLive.shared.write(piece)
            }
            // Tool calls arrive in pieces too, keyed by position in the list.
            for fragment in (delta["tool_calls"] as? [[String: Any]]) ?? [] {
                let index = fragment["index"] as? Int ?? 0
                var call = partial[index] ?? ToolCall()
                if let id = fragment["id"] as? String, !id.isEmpty { call.id = id }
                if let function = fragment["function"] as? [String: Any] {
                    if let name = function["name"] as? String, !name.isEmpty { call.name = name }
                    if let arguments = function["arguments"] as? String { call.arguments += arguments }
                }
                partial[index] = call
                await AskLive.shared.say("choosing what to search for…")
            }
        }
        round.calls = partial.keys.sorted().compactMap { partial[$0] }
        return round
    }
}

/// Turning "…worked like this [372]. And this too [401]." into sentences that carry their
/// sources, so a citation can light up the record it points at.
enum Citations {
    static func split(_ text: String) -> ([AnswerPart], [Int]) {
        var parts: [AnswerPart] = []
        var everyID: [Int] = []
        for raw in sentences(in: text) {
            var sentence = raw.trimmingCharacters(in: .whitespaces)
            guard !sentence.isEmpty else { continue }
            var ids: [Int] = []
            while let range = sentence.range(of: #"\[\s*\d+\s*\]"#, options: .regularExpression) {
                let digits = sentence[range].filter(\.isNumber)
                if let id = Int(digits) { ids.append(id); everyID.append(id) }
                sentence.removeSubrange(range)
            }
            sentence = sentence.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                // Pulling "[372]" out of "…to review [372], and the…" leaves a space
                // stranded before the comma. The prose has to read as written.
                .replacingOccurrences(of: #"\s+([,;:.!?…)])"#, with: "$1", options: .regularExpression)
                .replacingOccurrences(of: #"\(\s+"#, with: "(", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            guard !sentence.isEmpty else { continue }
            if !".!?…".contains(sentence.last!) { sentence += "." }
            parts.append(AnswerPart(text: sentence, citations: ids))
        }
        return (parts, Array(NSOrderedSet(array: everyID)) as? [Int] ?? [])
    }

    /// Sentences, keeping their own terminator so a question stays a question.
    ///
    /// A full stop only ends a sentence when something blank follows it. Cutting
    /// on every dot turned "Once UI, a design system for Next.js" into two
    /// lines, the second of which read "js." — which is not a sentence and made
    /// the answer look broken.
    private static func sentences(in text: String) -> [String] {
        let characters = Array(text.replacingOccurrences(of: "\n", with: " "))
        var found: [String] = []
        var current = ""
        for (index, character) in characters.enumerated() {
            current.append(character)
            guard ".!?…".contains(character) else { continue }
            let next = index + 1 < characters.count ? characters[index + 1] : " "
            if next.isWhitespace {
                found.append(current)
                current = ""
            }
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty { found.append(current) }
        return found
    }
}
