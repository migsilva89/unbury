import Foundation
import UnburyCore

/// The Claude Code and Codex engines.
///
/// Both already run on this Mac and already know how to run a command, so the
/// search tool is handed to them as a command — `unburyctl search --json` — rather
/// than as a protocol. Nothing to keep alive, nothing to configure, and the
/// person pays nothing per message because their subscription already covers it.
///
/// Their output is read line by line as it arrives, not collected and replayed at
/// the end. That is the whole difference between a screen that sits still for
/// forty seconds and one that shows the second search starting.
struct CLIChat {
    let engine: Engine
    let unburyctl: String
    let store: UnburyStore

    /// A process that can be killed from the cancellation handler, which is not
    /// allowed to await anything.
    private final class Box: @unchecked Sendable {
        let process = Process()
        func stop() { if process.isRunning { process.terminate() } }
    }

    func run(question: String,
             onEvent: @escaping @MainActor (AskEngine.Event) -> Void) async {
        await AskLive.shared.begin("starting \(engine.label)…")
        await go(question: question, onEvent: onEvent)
        await AskLive.shared.end()
    }

    private func go(question: String,
                    onEvent: @escaping @MainActor (AskEngine.Event) -> Void) async {
        guard let binary = engine.command.flatMap(ChatEngines.locate) else {
            await onEvent(.failed("\(engine.label) is not installed on this Mac."))
            return
        }

        let earlier = await MainActor.run { AskLive.shared.conversation?.priorExchanges() ?? [] }
        let prompt = """
        \(AskEngine.systemPrompt)

        Your search tool is this command, which prints JSON:

            \(unburyctl) search --json "what to look for"

        Run it with the Bash tool. Do not read or write any other file, and do not \
        run any other command. Announce each search on its own line, exactly as:

            SEARCH: <the words you searched for> — <why, in one short line>

        Then, after your searches, write ANSWER: on its own line and the answer \
        below it, with [id] citations.
        \(Self.recap(earlier))
        The question: \(question)
        """

        // Codex writes its final message to a file when asked to. That is far
        // more reliable than picking the answer out of a narration, so it is
        // used when it exists and the stream is only read for what happened.
        let lastMessage = engine == .codex
            ? FileManager.default.temporaryDirectory
                .appendingPathComponent("vault-codex-\(UUID().uuidString).txt").path
            : nil

        let box = Box()
        // The two things that have to be right or the tool hangs — no standard
        // input to wait on, and a directory it is allowed to be in — are set in
        // one place, `CLIProcess.prepare`, which importing shares. They were
        // learned here; they are not written down twice.
        CLIProcess.prepare(box.process, binary: binary,
                           arguments: arguments(prompt: prompt, lastMessage: lastMessage))
        let output = Pipe()
        let errors = Pipe()
        box.process.standardOutput = output
        box.process.standardError = errors

        do { try box.process.run() } catch {
            await onEvent(.failed("Could not start \(engine.label): \(error.localizedDescription)"))
            return
        }
        await AskLive.shared.say("\(engine.label) is thinking…")

        // Both pipes have to be drained or a chatty tool fills its buffer and
        // blocks forever. The old code left stderr unread, which is also why a
        // failing engine could only ever say "stopped without answering".
        let complaints = Complaints()
        let stderrHandle = errors.fileHandleForReading
        let draining = Task.detached {
            while true {
                let chunk = stderrHandle.availableData
                if chunk.isEmpty { break }
                await complaints.add(String(data: chunk, encoding: .utf8) ?? "")
            }
        }

        // Stopping has to reach the tool even while the read below is parked
        // waiting for the next chunk, which can be many seconds. So a small
        // watcher does the killing, and works whether the stop came from the
        // button or from the task being cancelled underneath us.
        let watchdog = Task {
            while !Task.isCancelled {
                if await AskLive.shared.stopping { box.stop(); return }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }

        let reader = Reader(engine: engine, store: store)
        await withTaskCancellationHandler {
            let handle = output.fileHandleForReading
            var buffer = Data()
            while true {
                let chunk = await Task.detached { handle.availableData }.value
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = String(data: buffer[buffer.startIndex..<newline], encoding: .utf8) ?? ""
                    buffer.removeSubrange(buffer.startIndex...newline)
                    await reader.read(line, onEvent: onEvent)
                }
                if Task.isCancelled { break }
            }
            if !buffer.isEmpty, let tail = String(data: buffer, encoding: .utf8) {
                await reader.read(tail, onEvent: onEvent)
            }
        } onCancel: {
            box.stop()
        }
        box.process.waitUntilExit()
        // Waited for, not cancelled: the last thing a failing tool writes is the
        // reason it failed, and it arrives as the process is closing. Cancelling
        // here raced it, and that race is why a broken engine could only ever
        // say "stopped without answering". The pipe closes on exit, so this ends.
        await draining.value
        watchdog.cancel()

        let asked = await AskLive.shared.stopping
        if Task.isCancelled || asked {
            if let lastMessage { try? FileManager.default.removeItem(atPath: lastMessage) }
            await onEvent(.failed(AskEngine.stopped))
            return
        }

        var answer = await reader.answer
        if let lastMessage,
           let written = try? String(contentsOfFile: lastMessage, encoding: .utf8),
           !written.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            answer = written
        }
        if let lastMessage { try? FileManager.default.removeItem(atPath: lastMessage) }

        guard box.process.terminationStatus == 0,
              !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // The tool's own words. "Your access token was revoked" is something
            // a person can act on; "code 1" is not.
            let said = await complaints.tail
            await onEvent(.failed(said.isEmpty
                ? "\(engine.label) stopped without answering (code \(box.process.terminationStatus))."
                : "\(engine.label) could not answer. It said: \(said)"))
            return
        }
        await finish(answer, onEvent: onEvent)
    }

    private func arguments(prompt: String, lastMessage: String?) -> [String] {
        switch engine {
        case .claude:
            return ["-p", prompt, "--allowedTools", "Bash",
                    "--output-format", "stream-json", "--verbose",
                    // Word-by-word deltas, so the answer is written on screen as
                    // it is written by the model rather than landing in one lump.
                    "--include-partial-messages"]
        case .codex:
            var arguments = ["exec", "--skip-git-repo-check", "--json",
                             // The search has to reach OpenRouter for the query's
                             // vector, and Codex's read-only sandbox has no
                             // network. Writing is still confined to a scratch
                             // folder it has no reason to touch.
                             "--sandbox", "workspace-write",
                             "-c", "sandbox_workspace_write.network_access=true",
                             "-C", FileManager.default.temporaryDirectory.path]
            if let lastMessage { arguments += ["-o", lastMessage] }
            return arguments + [prompt]
        case .openrouter:
            // Not a command-line engine; `run` never reaches here.
            return []
        }
    }

    /// What was already asked and answered, so "and the other one?" means
    /// something. Kept short on purpose: a follow-up reaches back one or two
    /// questions, and pasting the whole session in would only blur the new one.
    static func recap(_ earlier: [Exchange]) -> String {
        guard !earlier.isEmpty else { return "" }
        let lines = earlier.map { "Q: \($0.question)\nA: \($0.answer)" }.joined(separator: "\n\n")
        return """

        Earlier in this same conversation, oldest first:

        \(lines)

        """
    }

    /// Whatever the model cited, looked up here so the evidence panel
    /// fills. Without this the citations are numbers pointing at nothing, which
    /// is worse than no citations at all.
    private func finish(_ rawAnswer: String,
                        onEvent: @escaping @MainActor (AskEngine.Event) -> Void) async {
        // The CLI is asked to mark the answer with ANSWER: so it can be found in
        // a stream of narration; the marker itself is not part of the prose.
        var answer = rawAnswer
        if let marker = answer.range(of: "ANSWER:") {
            answer = String(answer[marker.upperBound...])
        }
        answer = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        let (parts, ids) = Citations.split(answer)
        let all = await store.bookmarks
        let cited = ids.compactMap { id in
            // -1 means "cited, score unknown": the CLI does not report the
            // score it saw, and inventing one would be a lie in a panel whose
            // whole job is showing what actually happened.
            all.first { $0.id == id }.map { Match(bookmark: $0, score: -1) }
        }
        await onEvent(.answer(parts, cited: cited))
        await onEvent(.cost(0))
    }
}

/// Whatever the tool wrote to stderr, kept so a failure can be quoted rather
/// than reduced to an exit code.
private actor Complaints {
    private var text = ""
    func add(_ chunk: String) { text += chunk }
    /// The last few real lines, with the timestamped log noise dropped.
    var tail: String {
        let useful = text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("hook:") }
            .map { line -> String in
                // "2026-08-27T11:37:42Z ERROR module: the actual sentence"
                guard let range = line.range(of: "ERROR ") else { return line }
                return String(line[range.upperBound...])
            }
        var seen: [String] = []
        for line in useful.suffix(6) where !seen.contains(line) { seen.append(line) }
        return seen.suffix(2).joined(separator: " ")
    }
}

/// Reading one line of a tool's output as it arrives, and saying what changed.
///
/// An actor because the line loop and the events it raises have to stay in
/// order: a search must appear before the records it found.
private actor Reader {
    let engine: Engine
    let store: UnburyStore
    private(set) var answer = ""

    init(engine: Engine, store: UnburyStore) {
        self.engine = engine
        self.store = store
    }

    func read(_ line: String,
              onEvent: @escaping @MainActor (AskEngine.Event) -> Void) async {
        switch engine {
        case .claude: await claude(line, onEvent: onEvent)
        case .codex: await codex(line, onEvent: onEvent)
        case .openrouter: break
        }
    }

    /// Claude Code emits one JSON object per line. The searches are the Bash
    /// commands it ran, which is the truth rather than what it said it did.
    private func claude(_ line: String,
                        onEvent: @escaping @MainActor (AskEngine.Event) -> Void) async {
        guard let data = line.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        // A word of the answer arriving.
        if let inner = event["event"] as? [String: Any],
           let delta = inner["delta"] as? [String: Any],
           let piece = delta["text"] as? String, !piece.isEmpty {
            await AskLive.shared.write(piece)
        }

        if let message = event["message"] as? [String: Any],
           let content = message["content"] as? [[String: Any]] {
            for block in content {
                if block["type"] as? String == "tool_use",
                   let input = block["input"] as? [String: Any],
                   let command = input["command"] as? String,
                   command.contains("unburyctl") {
                    await AskLive.shared.beginSearch()
                    await onEvent(.searching(query: Self.quoted(command),
                                             reason: input["description"] as? String))
                    continue
                }
                if block["type"] as? String == "text",
                   let piece = block["text"] as? String {
                    answer = piece      // the last text block is the answer
                }
            }
        }
        // A search came back: the tool's own JSON, so the records it found can be
        // shown under it instead of only a count.
        if let message = event["message"] as? [String: Any],
           let content = message["content"] as? [[String: Any]],
           message["role"] as? String == "user" {
            for block in content where block["type"] as? String == "tool_result" {
                let text = Self.flatten(block["content"])
                await onEvent(.results(records(in: text)))
                await AskLive.shared.say("reading what came back…")
            }
        }
        if event["type"] as? String == "result",
           let final = event["result"] as? String, !final.isEmpty {
            answer = final
        }
    }

    /// Codex prints its events as JSONL too, but the shape has changed between
    /// versions, so this looks for what it needs anywhere in the object rather
    /// than at a fixed path. It has never been proven against a live account on
    /// this Mac — see `Engine.unproven`.
    private func codex(_ line: String,
                       onEvent: @escaping @MainActor (AskEngine.Event) -> Void) async {
        guard let data = line.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data)
        else {
            // Not JSON: the plain narration, which still carries SEARCH: lines.
            await plain(line, onEvent: onEvent)
            return
        }
        var commands: [String] = []
        var texts: [String] = []
        Self.walk(event, commands: &commands, texts: &texts)
        for command in commands where command.contains("unburyctl") {
            await AskLive.shared.beginSearch()
            await onEvent(.searching(query: Self.quoted(command), reason: nil))
        }
        for text in texts where !text.isEmpty {
            if text.contains("unburyctl") || text.contains("\"results\"") {
                await onEvent(.results(records(in: text)))
                continue
            }
            await AskLive.shared.replaceDraft(with: text)
            answer = text
        }
    }

    private func plain(_ line: String,
                       onEvent: @escaping @MainActor (AskEngine.Event) -> Void) async {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("SEARCH:") {
            let body = trimmed.dropFirst("SEARCH:".count).trimmingCharacters(in: .whitespaces)
            let pieces = body.components(separatedBy: " — ")
            await AskLive.shared.beginSearch()
            await onEvent(.searching(query: pieces.first ?? body,
                                     reason: pieces.count > 1 ? pieces[1] : nil))
            return
        }
        if trimmed.hasPrefix("ANSWER:") {
            answer = String(trimmed.dropFirst("ANSWER:".count))
            return
        }
        if !answer.isEmpty { answer += "\n" + line }
    }

    // MARK: reading the tool's own JSON

    /// The records a `unburyctl search --json` run printed, so the transcript can
    /// show what came back and the evidence panel can carry real scores instead
    /// of the honest but bare "cited".
    ///
    /// Only the id and the score are taken from the tool's output; the record
    /// itself comes from the local copy, so the panel shows the same title and
    /// picture the rest of the app shows.
    func records(in text: String) async -> [Match] {
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"),
              start < end,
              let data = String(text[start...end]).data(using: .utf8),
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = body["results"] as? [[String: Any]]
        else { return [] }
        let all = await store.bookmarks
        return rows.compactMap { row in
            guard let id = row["id"] as? Int,
                  let bookmark = all.first(where: { $0.id == id }) else { return nil }
            return Match(bookmark: bookmark, score: row["score"] as? Double ?? -1)
        }
    }

    /// Tool results arrive either as a plain string or as a list of blocks.
    static func flatten(_ content: Any?) -> String {
        if let text = content as? String { return text }
        if let blocks = content as? [[String: Any]] {
            return blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        return ""
    }

    /// Everything that looks like a command it ran, or something it said,
    /// wherever it sits in the object.
    static func walk(_ value: Any, commands: inout [String], texts: inout [String]) {
        if let dictionary = value as? [String: Any] {
            for (key, child) in dictionary {
                if key == "command" || key == "cmd" {
                    if let one = child as? String { commands.append(one) }
                    if let many = child as? [String] { commands.append(many.joined(separator: " ")) }
                    continue
                }
                if key == "text" || key == "message" || key == "last_agent_message"
                    || key == "aggregated_output" || key == "output",
                   let one = child as? String {
                    texts.append(one)
                    continue
                }
                walk(child, commands: &commands, texts: &texts)
            }
            return
        }
        if let list = value as? [Any] {
            for child in list { walk(child, commands: &commands, texts: &texts) }
        }
    }

    /// The words between the quotes of `unburyctl search --json "…"`.
    static func quoted(_ command: String) -> String {
        guard let start = command.range(of: "\""),
              let end = command.range(of: "\"", options: .backwards),
              start.upperBound < end.lowerBound
        else { return command }
        return String(command[start.upperBound..<end.lowerBound])
    }
}
