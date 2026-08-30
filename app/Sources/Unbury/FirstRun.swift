import SwiftUI
import UnburyCore

/// The first thing anyone sees, and the screen that decides whether this reads
/// as a product or as somebody's weekend project.
///
/// It is a flow, not a page: one idea at a time, one thing to press, and a rail
/// down the side saying where you are and letting you go back. Everything needed
/// to start happens here — the key is pasted here, the engine is chosen here —
/// rather than sending a person off to Settings and hoping they come back.
///
/// It fills the window. What it replaced was a 620-point column centred in a
/// black room, which on any real display read as a page that had failed to load
/// the rest of itself.
struct FirstRun: View {
    @Environment(AppModel.self) private var model

    /// The room this screen has been given. Handed in by the search view, which
    /// is the only thing that knows how much of the window is left under the
    /// header — a GeometryReader in here would be told the height is nothing.
    let space: CGSize

    @State private var step: Step = .welcome
    @State private var profiles: [Browsers.Profile] = []
    @State private var engines: [ChatEngineOption] = []
    @State private var prices: [String: ChatModelFacts] = [:]

    // The key is entered here rather than in Settings: a first run that sends
    // somebody to another screen for the one thing it needs has already lost them.
    @State private var key = ""
    @State private var checking = false
    @State private var keyState: (String, Bool)?

    /// Where the rail stops being worth its width and becomes a strip on top.
    private let foldBelow: CGFloat = 1000
    private let rail: CGFloat = 292
    /// On a small laptop window the search header above leaves this screen barely
    /// 260 points to work in. Everything tightens rather than letting a step be
    /// cut off halfway down a row — the same words, closer together.
    private var compact: Bool { space.height < 440 }

    enum Step: Int, CaseIterable {
        case welcome, key, answering, importing

        /// The welcome is the front door, not a step: nothing is asked for on
        /// it, and numbering it would promise four chores instead of three.
        var number: Int { rawValue }
        var title: String {
            switch self {
            case .welcome: "Welcome"
            case .key: "Your key"
            case .answering: "Who answers"
            case .importing: "Your bookmarks"
            }
        }
        var summary: String {
            switch self {
            case .welcome: "What this is for"
            case .key: "One account, and what it costs"
            case .answering: "Which model reads your questions"
            case .importing: "Bring them in from your browser"
            }
        }
        static let asked = allCases.filter { $0 != .welcome }
    }

    var body: some View {
        Group {
            if space.width >= foldBelow {
                HStack(spacing: 0) {
                    sidebar.frame(width: rail)
                    Rectangle().fill(Theme.line).frame(width: 1)
                    stage
                }
            } else {
                VStack(spacing: 0) {
                    strip
                    Rectangle().fill(Theme.line).frame(height: 1)
                    stage
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .frame(minHeight: space.height, alignment: .top)
        .background(Theme.bg)
        .task {
            profiles = Browsers.installed()
            engines = ChatEngines.available()
            prices = (try? await ChatModels.catalogue()) ?? [:]
        }
    }

    // MARK: - Where you are

    /// The rail: the mark, the three things there are to do, and which one is
    /// open. Tier 1 of the accent scheme lives here — the iris from the app icon,
    /// at a size where its blades are still blades — and tier 2 marks the step
    /// you are on. Nothing in the rail is a plate; the plate belongs to the one
    /// action on the right.
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                UnburyMark().fill(Theme.accent).frame(width: 26, height: 26)
                Text("UNBURY").font(Theme.sans(12, .semibold)).tracking(2.6)
                    .foregroundStyle(Theme.ink2)
            }
            .padding(.bottom, 34)

            ForEach(Step.asked, id: \.rawValue) { entry in
                railRow(entry)
            }

            Spacer(minLength: 24)

            Text("Nothing is uploaded anywhere. Your links stay in two files on this Mac.")
                .font(Theme.sans(11.5)).foregroundStyle(Theme.faint).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(32)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.panel)
    }

    private func railRow(_ entry: Step) -> some View {
        let here = step == entry
        let done = entry.rawValue < step.rawValue
        return HStack(alignment: .top, spacing: 13) {
            Text(done ? "✓" : "\(entry.number)")
                .font(Theme.mono(11.5))
                .foregroundStyle(here || done ? Theme.accent : Theme.faint)
                .frame(width: 24, height: 24)
                .overlay(Circle().stroke(here || done ? Theme.accentEdge : Theme.line2))
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title)
                    .font(Theme.sans(13, here ? .medium : .regular))
                    .foregroundStyle(here ? Theme.ink : (done ? Theme.dim : Theme.faint))
                Text(entry.summary).font(Theme.sans(11.5)).foregroundStyle(Theme.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.bottom, 22)
    }

    /// The same three things in one line, for a window too narrow to give them a
    /// column of their own.
    private var strip: some View {
        HStack(spacing: 10) {
            HStack(spacing: 9) {
                UnburyMark().fill(Theme.accent).frame(width: 17, height: 17)
                Text("UNBURY").font(Theme.sans(10.5, .semibold)).tracking(2.3)
                    .foregroundStyle(Theme.ink2)
            }
            Spacer(minLength: 8)
            ForEach(Step.asked, id: \.rawValue) { entry in
                let here = step == entry
                let done = entry.rawValue < step.rawValue
                HStack(spacing: 6) {
                    Text(done ? "✓" : "\(entry.number)")
                        .font(Theme.mono(10))
                        .foregroundStyle(here || done ? Theme.accent : Theme.faint)
                    Text(entry.title).font(Theme.sans(11.5, here ? .medium : .regular))
                        .foregroundStyle(here ? Theme.ink : Theme.faint)
                }
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 5)
                    .fill(here ? Theme.accentWash : .clear))
            }
        }
        .padding(.horizontal, 22).padding(.vertical, 13)
        .background(Theme.panel)
    }

    // MARK: - The step itself

    /// One idea, its explanation, and the single thing to press. Every step is
    /// built from the same parts at the same distances, so moving between them
    /// feels like turning a page rather than opening a different screen.
    private var stage: some View {
        VStack(spacing: 0) {
            // The room left once the footer has taken its bar. A short step sits
            // in the middle of it and a long one scrolls, so no step ever hangs
            // off the top of a half-empty window.
            GeometryReader { room in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        switch step {
                        case .welcome: welcome
                        case .key: keyStep
                        case .answering: answeringStep
                        case .importing: importStep
                        }
                    }
                    // A reading measure, centred in whatever room the stage has.
                    // Pinned left it emptied a third of a wide window on one
                    // side only, which reads as a column that failed to stretch
                    // rather than as a deliberate margin.
                    .frame(maxWidth: 660, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.horizontal, compact ? 26 : 44)
                    .padding(.vertical, compact ? 22 : 46)
                    .frame(minHeight: room.size.height, alignment: .center)
                }
            }
            footer
        }
    }

    /// The way forward, on a bar at the foot of the window rather than trailing
    /// the text. It is in the same place whether the step is long or short, and
    /// it gives the screen a bottom edge instead of a paragraph hanging in the
    /// middle of a black field.
    private var footer: some View {
        HStack(spacing: 16) {
            if step != .welcome {
                Button { back() } label: {
                    Text("Back").font(Theme.sans(12.5)).foregroundStyle(Theme.faint)
                }
                .buttonStyle(.plain).clickable()
                .help("The step before this one")
            }
            Spacer(minLength: 8)
            if let why = blocked {
                Text(why).font(Theme.mono(11)).foregroundStyle(Theme.fainter)
            }
            // Tier 3 of the accent scheme, and the only filled thing on screen:
            // one step, one way on.
            Button(action: forward.act) { Label2(forward.title, filled: true) }
                .buttonStyle(.plain).clickable()
                .disabled(!forward.enabled)
                .opacity(forward.enabled ? 1 : 0.4)
        }
        .padding(.horizontal, compact ? 26 : 44)
        .padding(.vertical, compact ? 11 : 18)
        .background(Theme.panel)
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    /// What the one button does on the step showing. Held in one place so that
    /// "exactly one way forward" is a fact of the structure and not a promise.
    private var forward: (title: String, enabled: Bool, act: () -> Void) {
        switch step {
        case .welcome: ("Start", true, { step = .key })
        case .key: ("Continue", model.hasKey, { step = .answering })
        case .answering: ("Continue", true, { step = .importing })
        case .importing: ("Choose what to import",
                          model.hasKey && !profiles.isEmpty,
                          { model.showImport = true })
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Find a link without remembering\nwhat it was called.")
                .font(Theme.sans(compact ? 20 : 28, .light)).foregroundStyle(Theme.ink)
                .lineSpacing(compact ? 4 : 7)
                .fixedSize(horizontal: false, vertical: true)

            Text("Unbury reads what your bookmarks are about, not just their titles. You describe the thing you half-remember — \u{201c}that printed part for the pegboard\u{201d} — and it finds it.")
                .font(Theme.sans(14)).foregroundStyle(Theme.dim).lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, compact ? 12 : 18)

            Text("Three short steps. Nothing is spent until you press something that has already told you what it costs.")
                .font(Theme.sans(14)).foregroundStyle(Theme.dim).lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)

            // The four-line account of what things cost needs room it does not
            // have on a small laptop window, and half a table cut off by the
            // footer reads as a fault. One honest sentence instead; the full
            // account is on the next step and in Settings.
            Group {
                if compact {
                    Text("Two things here spend money — importing your bookmarks, and asking a question. Both say what they cost before they run, and browsing what you have saved never leaves this Mac.")
                        .font(Theme.sans(12)).foregroundStyle(Theme.dim).lineSpacing(3.5)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(13)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.raised))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
                } else {
                    CostGuide()
                }
            }
            .padding(.top, compact ? 18 : 28)
        }
    }

    // MARK: step 1 — the key

    private var keyStep: some View {
        stepBody("Your key", """
            Unbury has no subscription of its own. It runs on your own OpenRouter \
            account, which is where the reading and the answering are paid for — a few \
            cents at a time, and only when you ask for something.
            """) {
            VStack(alignment: .leading, spacing: 11) {
                SecureField("sk-or-…", text: $key)
                    .textFieldStyle(.plain).font(Theme.mono(12.5))
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Theme.panel))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line2))
                    .help("Kept in the macOS Keychain, never written to a file")
                HStack(spacing: 14) {
                    Button { Task { await check() } } label: {
                        Label2(checking ? "Checking…" : "Check this key", filled: false)
                    }
                    .buttonStyle(.plain).clickable()
                    .disabled(key.isEmpty || checking)
                    .opacity(key.isEmpty || checking ? 0.45 : 1)
                    .help("Asks OpenRouter for one vector, to prove the key works")
                    Link("Get a key at openrouter.ai/keys",
                         destination: URL(string: "https://openrouter.ai/keys")!)
                        .font(Theme.sans(12.5)).foregroundStyle(Theme.link).clickable()
                }
                if let keyState {
                    Text(keyState.0).font(Theme.sans(12))
                        .foregroundStyle(keyState.1 ? Theme.accent : Theme.bad)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: step 2 — who answers

    private var answeringStep: some View {
        stepBody("Who answers your questions", """
            Ask Unbury puts a question to a model, which searches your library itself \
            and reads what comes back. It is the costliest thing Unbury does, so the \
            choice worth making is whose money it comes out of.
            """) {
            VStack(alignment: .leading, spacing: 9) {
                ForEach(engines) { engine in
                    engineRow(engine)
                }
                if engines.count < ChatEngines.all.count {
                    Text("Only what is already installed on this Mac is offered here.")
                        .font(Theme.sans(11.5)).foregroundStyle(Theme.fainter)
                }
                if model.preferences.chatEngine == ChatEngines.openRouter {
                    modelMenu.padding(.top, 4)
                }
            }
        }
    }

    private func engineRow(_ engine: ChatEngineOption) -> some View {
        let on = model.preferences.chatEngine == engine.id
        return Button { choose(engine: engine.id) } label: {
            HStack(alignment: .top, spacing: 12) {
                Circle()
                    .strokeBorder(on ? Theme.accent : Theme.line2, lineWidth: 1)
                    .background(Circle().fill(on ? Theme.accent : .clear).padding(3))
                    .frame(width: 13, height: 13)
                    .padding(.top, 3)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 9) {
                        Text(engine.label).font(Theme.sans(13.5, on ? .medium : .regular))
                            .foregroundStyle(on ? Theme.ink : Theme.dim)
                        Text("spends \(engine.purse)").font(Theme.mono(10.5))
                            .foregroundStyle(engine.spends ? Theme.warn : Theme.fainter)
                    }
                    // On a short window the sentence goes and the row keeps
                    // what decides the choice: the name and whose money it is.
                    // Three cut-off cards would hide the one option that bills
                    // per question below the fold.
                    if !compact {
                        Text(engine.note).font(Theme.sans(12)).foregroundStyle(Theme.faint)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(compact ? 11 : 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(on ? Theme.accentWash : Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(on ? Theme.accentEdge : Theme.line))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).clickable()
        .help(engine.note)
    }

    /// The model, and only when the engine is the one that bills per question. A
    /// menu rather than four more rows: this is the getting-started screen, and
    /// the full comparison with prices lives in Settings.
    private var modelMenu: some View {
        HStack(spacing: 10) {
            Text("Model").font(Theme.mono(11)).foregroundStyle(Theme.faint)
            Menu {
                ForEach(ChatModels.offered) { option in
                    Button("\(option.label) — \(price(option.id))") { choose(model: option.id) }
                }
            } label: {
                HStack(spacing: 8) {
                    Text(chosenModelLabel).font(Theme.sans(12.5)).foregroundStyle(Theme.ink2)
                    Text(price(model.preferences.chatModel))
                        .font(Theme.mono(11)).foregroundStyle(Theme.warn)
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Which model OpenRouter is asked, and what one question costs")
        }
    }

    // MARK: step 3 — the bookmarks

    private var importStep: some View {
        stepBody("Bring your bookmarks in", importLine) {
            VStack(alignment: .leading, spacing: 9) {
                ForEach(byBrowser, id: \.name) { entry in
                    HStack(spacing: 12) {
                        Text(entry.name).font(Theme.sans(13)).foregroundStyle(Theme.ink2)
                        Text(entry.detail).font(Theme.mono(11)).foregroundStyle(Theme.faint)
                            .monospacedDigit()
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 13).padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Theme.panel))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line))
                }
                Text("The next window lists what is new, lets you cut it down, and says what the reading will cost. Nothing is spent until you press Import there.")
                    .font(Theme.sans(12)).foregroundStyle(Theme.faint).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        }
    }

    /// One line per browser rather than one per profile: ten Chrome profiles is
    /// a list nobody reads, and the choosing happens in the import window.
    private var byBrowser: [(name: String, detail: String)] {
        var order: [String] = []
        var counts: [String: (profiles: Int, links: Int)] = [:]
        for profile in profiles {
            if counts[profile.browser] == nil { order.append(profile.browser) }
            let running = counts[profile.browser] ?? (0, 0)
            counts[profile.browser] = (running.profiles + 1, running.links + profile.count)
        }
        return order.map { browser in
            let tally = counts[browser] ?? (0, 0)
            let word = tally.profiles == 1 ? "profile" : "profiles"
            return (browser, "\(tally.links) bookmarks · \(tally.profiles) \(word)")
        }
    }

    private var importLine: String {
        guard !profiles.isEmpty else {
            return """
                No browser Unbury can read was found. It reads Brave, Chrome, Arc, Edge \
                and Vivaldi; Safari and Firefox keep their bookmarks in a different \
                format and are not supported yet.
                """
        }
        let total = profiles.map(\.count).reduce(0, +)
        return """
            Unbury reads your browser's bookmarks and writes a sentence about each one, \
            so you can find it later by what it is rather than by what it was called. \
            There are \(total) here to choose from, and your browser is never written to.
            """
    }

    // MARK: - The parts every step is made of

    /// Heading, one paragraph, the controls, then the way forward and the way
    /// back. Always in that order and always at the same distances.
    private func stepBody<Content: View>(
        _ title: String, _ explanation: String,
        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(Theme.sans(compact ? 18 : 24, .light)).foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text(explanation).font(Theme.sans(compact ? 12.5 : 13.5))
                .foregroundStyle(Theme.dim).lineSpacing(compact ? 4 : 5)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, compact ? 9 : 14)
            content().padding(.top, compact ? 16 : 26)
        }
    }

    /// Why the way forward is closed, in the fewest words that name the fix.
    /// Nil whenever it is open, so the bar stays quiet when there is nothing
    /// wrong.
    private var blocked: String? {
        guard !forward.enabled else { return nil }
        switch step {
        case .key: return "paste a key, then check it"
        case .importing: return model.hasKey ? "no supported browser found"
                                             : "a key is needed first"
        default: return nil
        }
    }

    private func back() {
        guard let previous = Step(rawValue: step.rawValue - 1) else { return }
        step = previous
    }

    // MARK: - Plumbing

    private var chosenModelLabel: String {
        let id = model.preferences.chatModel
        return ChatModels.offered.first { $0.id == id }?.label ?? id
    }

    /// Blank rather than invented while OpenRouter's price list has not arrived.
    private func price(_ id: String) -> String {
        prices[id].map(ChatModels.inWords) ?? "—"
    }

    private func choose(engine: String) {
        var preferences = model.preferences
        preferences.chatEngine = engine
        try? preferences.save()
        model.preferences = preferences
    }

    private func choose(model id: String) {
        var preferences = model.preferences
        preferences.chatModel = id
        try? preferences.save()
        model.preferences = preferences
    }

    /// Proving the key costs a fraction of a cent, which is why it happens on a
    /// press and never on its own. The key is kept only once OpenRouter has
    /// answered to it: a wrong key saved quietly becomes a failed import later.
    private func check() async {
        checking = true
        defer { checking = false }
        let trimmed = key.trimmingCharacters(in: .whitespaces)
        do {
            _ = try await OpenRouter(key: trimmed,
                                     settings: model.openRouterSettings).embed("a short test")
            Keychain.writeKey(trimmed)
            keyState = ("That key works, and it is now in your Keychain.", true)
        } catch {
            keyState = (error.localizedDescription, false)
        }
    }
}
