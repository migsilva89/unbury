import Foundation
import UnburyCore

/// Ask Unbury: running a question against the library, whichever engine is chosen.
///
/// The model is never handed results. It is given one tool — search the library —
/// and calls it itself, as many times as it needs. That is deliberate: a vague
/// question usually needs rephrasing, and only the model knows what it tried.
enum AskEngine {
    /// What the caller gets told as the answer is built, so the transcript can
    /// fill in as it happens rather than appearing all at once at the end.
    ///
    /// These are the events that change the *record* of a turn. Everything that
    /// only changes what is happening *right now* — the words arriving, the
    /// seconds passing — goes through `AskLive` instead, which is thrown away
    /// when the turn ends. Keeping the two apart is what stops a half-written
    /// sentence from ever being mistaken for an answer.
    enum Event {
        case searching(query: String, reason: String?)
        case results([Match])
        case answer([AnswerPart], cited: [Match])
        case deadEnd(String)
        case cost(Double)
        case failed(String)
    }

    /// The exact words used when the person stops a question themselves. The
    /// transcript reads it and shows it grey rather than red: nothing broke.
    static let stopped = "Stopped."

    static let systemPrompt = """
    You answer questions about one person's saved bookmarks, using only what is in \
    their vault. You have one tool: search_vault, which finds saved links by meaning.

    How to work:
    - Search before answering. If the first search comes back weak (best score under \
      0.5), try a different wording — describe what the thing does, not what it is called.
    - Two or three searches is normal. Stop when you have what you need.
    - Answer in prose, two to five sentences, in the SAME language the question \
      was asked in — these are one person's own links and the app does not know \
      which language they speak until they write. Speak to them directly, never \
      about them in the third person.
    - After each sentence that rests on a saved link, put its id in square brackets, \
      like [372]. Never cite an id that did not come back from a search.
    - If nothing relevant came back, say so plainly and say what you searched for. \
      Do not pad the answer with what you happen to know — the point is what THEY saved.
    - Never invent a link, a title or a fact that was not in a search result.
    - When the question follows on from an earlier one ("and the other one?", \
      "who wrote it?"), read it against what was already asked and answered, and \
      search again anyway — do not answer from the earlier results alone.
    """

    // MARK: running a question

    /// Run one question through the engine the person chose, reporting what
    /// happens as it happens.
    ///
    /// The choice is read at the moment of asking rather than baked in when the
    /// screen was built: settings is a separate page, and switching engine there
    /// has to take effect on the next question without a restart.
    static func run(engine: Engine,
                    question: String,
                    chatModel: String,
                    store: UnburyStore,
                    key: String?,
                    onEvent: @escaping @MainActor (Event) -> Void) async {
        switch engine {
        case .openrouter:
            guard let key, !key.isEmpty else {
                await onEvent(.failed("There is no OpenRouter key."))
                return
            }
            await OpenRouterChat(key: key, model: chatModel, store: store,
                                 embedder: OpenRouter(key: key))
                .run(question: question, onEvent: onEvent)
        case .claude, .codex:
            await CLIChat(engine: engine, unburyctl: unburyctl, store: store)
                .run(question: question, onEvent: onEvent)
        }
    }

    /// The search tool the command-line engines are given. Inside a shipped app
    /// it sits next to the executable; in a development build the app is run
    /// from the package, where only the build folder has it.
    static var unburyctl: String {
        let shipped = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/unburyctl").path
        guard FileManager.default.isExecutableFile(atPath: shipped) else {
            return FileManager.default.currentDirectoryPath + "/.build/release/unburyctl"
        }
        return shipped
    }

    // MARK: what this Mac can actually run

    /// The engines that can answer on this Mac, in the order they are offered.
    ///
    /// Which of them is really installed is `ChatEngines`' answer, not a second
    /// one: the settings page offers the choice and this screen runs it, and two
    /// pieces of code disagreeing about whether Codex exists is exactly the bug
    /// that shows up as a button that can only fail.
    static func installed() -> [Engine] {
        ChatEngines.available().compactMap { Engine(rawValue: $0.id) }
    }

    static func available(_ engine: Engine) -> Bool {
        installed().contains(engine)
    }
}
