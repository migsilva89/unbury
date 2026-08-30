import SwiftUI
import UnburyCore

/// What a person can change, and an honest account of what the app spends on
/// their behalf and where their library sits.
///
/// It is a page in a tab, not a dialogue, and it is laid out as one: a board of
/// panels that takes the width it is given, three across on a wide display, two
/// on a laptop, one when the window is dragged narrow. It used to be a 940-point
/// column pinned in the middle, which on any real screen read as a form somebody
/// had dropped into an empty room.
///
/// It also used to carry database details for a Raspberry Pi that only one
/// person has, and a browser picker nothing read. Both are gone; the import
/// window is where a profile is chosen, and it is the one that remembers.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    /// One key per service, held by the service's identifier. The app used to
    /// speak of "your key" as if there were only ever one; there are two paid
    /// jobs here now and they need not be bought from the same company.
    @State private var keys: [String: String] = [:]
    @State private var keyStates: [String: (String, Bool)] = [:]
    @State private var checkingKey: String?
    @State private var describeEngine = ""
    @State private var describeModel = ""
    @State private var vectorService = ""
    @State private var embeddingModel = ""
    @State private var chatEngine = ""
    @State private var chatModel = ""
    /// The engines that can describe a page on this Mac. Same rule as Ask: one
    /// that is not installed is left out rather than offered and then refused.
    @State private var describeEngines: [DescribeEngineOption] = []
    /// What the library was indexed with, kept from the moment the page opened
    /// so a change can be recognised — and refused quietly — before it is saved.
    @State private var indexedWith: (service: String, model: String) = ("", "")
    @State private var confirmingReindex = false
    /// Only the engines this Mac can really run. Worked out when the page
    /// appears, because finding them touches the disk.
    @State private var engines: [ChatEngineOption] = []
    @State private var prices: [String: ChatModelFacts] = [:]
    @State private var priceTrouble: String?
    @State private var confirmingErase = false
    /// Sparkle's own setting, read when the page opens rather than kept in
    /// `Preferences`: two records of the same answer is how they start
    /// disagreeing. See Updates.swift.
    @State private var autoUpdate = true

    /// One spacing scale for the whole page. Panels are a gap apart, a panel's
    /// inside is a gap of padding, and the things stacked inside it are half a
    /// gap. Nothing on this page is measured any other way.
    private let gap: CGFloat = 24
    private let margin: CGFloat = 28

    var body: some View {
        GeometryReader { space in
            ScrollView {
                page(width: space.size.width)
                    // The page owns the whole window even when its content is
                    // shorter: the closing bar goes to the bottom edge rather
                    // than leaving a third of the screen blank underneath.
                    .frame(minHeight: space.size.height - 1, alignment: .top)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
        .onAppear(perform: load)
        .task { await readPrices() }
    }

    private func page(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: gap) {
            header
            // Ideal height, not stretched: inside a row the panels still even
            // out to the tallest of them, but the page must not blow them up to
            // fill the window. What fills the window is the space above the
            // closing bar, which is meant to be empty.
            board(across: columns(for: width))
                .fixedSize(horizontal: false, vertical: true)
            askPanel(across: columns(for: width))
                .fixedSize(horizontal: false, vertical: true)
            spendPanel(across: columns(for: width))
                .fixedSize(horizontal: false, vertical: true)
            updatesPanel(across: columns(for: width))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: gap)
            closingBar
        }
        .padding(.horizontal, margin)
        .padding(.top, margin)
        .padding(.bottom, 20)
    }

    /// How many panels fit side by side. Decided on the measured width because
    /// ViewThatFits cannot judge it: every panel here is made of text, which
    /// squeezes to any width rather than reporting that it does not fit.
    private func columns(for width: CGFloat) -> Int {
        let usable = width - margin * 2
        if usable < 760 { return 1 }
        if usable < 1180 { return 2 }
        return 3
    }

    private func board(across columns: Int) -> some View {
        // Panels in a row stretch to the tallest of them, so a row reads as one
        // band rather than cards of different heights hanging off a line.
        Group {
            switch columns {
            case 1:
                VStack(spacing: gap) { keysPanel; describePanel; vectorPanel; libraryPanel }
            case 2:
                VStack(spacing: gap) {
                    HStack(alignment: .top, spacing: gap) { keysPanel; describePanel }
                    HStack(alignment: .top, spacing: gap) { vectorPanel; libraryPanel }
                }
            default:
                VStack(spacing: gap) {
                    HStack(alignment: .top, spacing: gap) { keysPanel; describePanel; vectorPanel }
                    libraryPanel
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 20) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Settings").font(Theme.sans(22, .medium)).foregroundStyle(Theme.ink)
                Text("Unbury \(version) · signed and notarised for macOS")
                    .font(Theme.mono(10.5)).foregroundStyle(Theme.fainter)
            }
            Spacer(minLength: 0)
            Button(action: attemptSave) {
                // Tier 3: the one action of this page. "Check" beside the key
                // field stays grey — it proves something, it does not move on.
                Text("Save and go back").font(Theme.sans(12, .medium)).foregroundStyle(Theme.onAccent)
                    .padding(.horizontal, 15).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.accent))
            }
            .buttonStyle(.plain).clickable()
            .keyboardShortcut(.defaultAction)
            .help("Save, and return to what you were doing")
        }
        .padding(.bottom, 4)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
        // Changing who builds the vectors is not a preference — it is a decision
        // about every record already stored, and it is asked as one.
        .confirmationDialog("Your library was built with a different model",
                            isPresented: $confirmingReindex) {
            Button("Change it anyway", role: .destructive) {
                save()
                model.showSettings = false
            }
            Button("Keep \(indexedWith.model)", role: .cancel) {
                vectorService = indexedWith.service
                embeddingModel = indexedWith.model
            }
        } message: {
            Text("Your links hold numbers made by \(indexedWith.model), which cannot be compared with \(embeddingModel.trimmingCharacters(in: .whitespaces))\u{2019}s. Search stays meaningless until you erase and import again.")
        }
    }

    // MARK: the keys

    /// A field per service rather than one "your key".
    ///
    /// Both are shown at all times, each saying what it is being used for right
    /// now, because the alternative — showing OpenAI's field only after OpenAI
    /// is chosen — makes somebody choose a service before they can prove they
    /// can reach it. What is not used is said plainly instead of hidden.
    private var keysPanel: some View {
        panel("Your keys", "In the macOS Keychain, never in a file.", more: """
            Two things here are bought, and they no longer have to be bought from the same \
            place. Each key sits with the service it belongs to, in the macOS Keychain and \
            never in a file. Nothing is spent without you pressing something first.
            """) {
            ForEach(VectorServices.all) { service in
                keyField(service)
            }
        }
    }

    private func keyField(_ service: VectorService) -> some View {
        let state = keyStates[service.id]
        let held = Binding(get: { keys[service.id] ?? "" },
                           set: { keys[service.id] = $0 })
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(service.label).font(Theme.sans(12.5, .medium)).foregroundStyle(Theme.ink)
                Spacer(minLength: 0)
                Link(service.keysPage.replacingOccurrences(of: "https://", with: ""),
                     destination: URL(string: service.keysPage)!)
                    .font(Theme.mono(10)).foregroundStyle(Theme.link).clickable()
            }
            SecureField(service.id == VectorServices.openAI.id ? "sk-…" : "sk-or-…", text: held)
                .textFieldStyle(.plain).font(Theme.mono(12))
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 11).padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.raised))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.line2))
                .help("Kept in the macOS Keychain, never in a file")
            HStack(spacing: 12) {
                Button { Task { await check(service) } } label: {
                    Label2(checkingKey == service.id ? "Checking…" : "Check", filled: false)
                }
                .buttonStyle(.plain).clickable()
                .disabled(held.wrappedValue.isEmpty || checkingKey != nil)
                .opacity(held.wrappedValue.isEmpty || checkingKey != nil ? 0.45 : 1)
                .help("Ask \(service.label) whether it accepts this key. Nothing is bought.")
                Text(usedFor(service)).font(Theme.mono(10)).foregroundStyle(Theme.fainter)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let state {
                Text(state.0).font(Theme.mono(11))
                    .foregroundStyle(state.1 ? Theme.accent : Theme.bad)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// What this key is actually paying for, as the page currently stands. A
    /// field that is not needed says so rather than sitting there looking
    /// obligatory.
    private func usedFor(_ service: VectorService) -> String {
        var jobs: [String] = []
        if service.id == VectorServices.openRouter.id {
            if describeEngine == DescribeEngines.openRouter { jobs.append("describing") }
            if chatEngine == ChatEngines.openRouter { jobs.append("answering in Ask Unbury") }
        }
        if vectorService == service.id { jobs.append("vectors") }
        guard !jobs.isEmpty else { return "not used by anything you have chosen" }
        return "used for " + jobs.joined(separator: ", ")
    }

    /// The whole of what the app spends, as its own subject rather than a
    /// footnote under the key. It is the question the owner actually asks first,
    /// and burying it inside another panel made the key panel twice the height
    /// of everything beside it.
    private func spendPanel(across columns: Int) -> some View {
        panel("What this spends", "Two of these four never leave this Mac.", more: """
            Four things happen in this app, and they do not cost the same. Two of them \
            never leave this Mac; the other two are worth knowing about before you press \
            anything.
            """) {
            CostGuide(across: columns)
        }
    }

    // MARK: who describes a page

    /// Describing is a piece of writing, so anything that writes can do it —
    /// including the two programs already on this Mac, which spend a
    /// subscription instead of a key. What they cost is time, and that is said
    /// in the same breath rather than discovered during a six-hundred-link
    /// import.
    private var describePanel: some View {
        panel("Who describes your links", "One sentence per link, written at import.", more: """
            Once per link, at import: the page is read and one sentence is written under \
            it. This is where an import's time and money go, so the choice is whose.
            """) {
            VStack(spacing: 10) { ForEach(describeEngines) { describeCard($0) } }
            if let missing = missingDescribers { caption(missing, tone: Theme.fainter) }
            if describeEngine == DescribeEngines.openRouter {
                field("Which model", $describeModel,
                      help: "Any model on openrouter.ai. Kimi K2 is what your library was written with.")
                if let complaint = complaint(about: describeModel) {
                    caption(complaint, tone: Theme.warn)
                }
            }
        }
    }

    private func describeCard(_ engine: DescribeEngineOption) -> some View {
        let on = describeEngine == engine.id
        return Button { describeEngine = engine.id } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 9) {
                    // Tier 2 of the accent scheme: a small teal mark saying
                    // "this is the one you chose". Not a plate — the plate on
                    // this page belongs to Save, and only to Save.
                    Circle()
                        .strokeBorder(on ? Theme.accent : Theme.line2, lineWidth: 1)
                        .background(Circle().fill(on ? Theme.accent : .clear).padding(3))
                        .frame(width: 12, height: 12)
                    Text(engine.label).font(Theme.sans(13, on ? .medium : .regular))
                        .foregroundStyle(on ? Theme.ink : Theme.dim)
                    Spacer(minLength: 8)
                    Text(pace(engine)).font(Theme.mono(10.5)).monospacedDigit()
                        .foregroundStyle(on ? Theme.accent : Theme.fainter)
                        .fixedSize()
                }
                Text("spends \(engine.purse)")
                    .font(Theme.mono(10.5))
                    .foregroundStyle(engine.spends ? Theme.warn : Theme.fainter)
                Text(engine.note).font(Theme.sans(11.5)).foregroundStyle(Theme.faint)
                    .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            }
            .padding(13)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 8).fill(on ? Theme.accentWash : Theme.raised))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(on ? Theme.accentEdge : Theme.line))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).clickable()
    }

    /// How long this route takes over the library that is actually here, which
    /// is the only form of "slower" anybody can feel. Measured per link, then
    /// multiplied by the number of links in front of them.
    private func pace(_ engine: DescribeEngineOption) -> String {
        let links = max(model.count, 1)
        let minutes = engine.secondsPerLink * Double(links) / 60
        let each = engine.secondsPerLink < 3
            ? String(format: "%.1fs", engine.secondsPerLink)
            : "\(Int(engine.secondsPerLink.rounded()))s"
        if minutes < 1 { return "\(each) a link" }
        if minutes < 90 { return "\(each) a link · \(Int(minutes.rounded())) min for \(links)" }
        return "\(each) a link · \(String(format: "%.1f", minutes / 60)) h for \(links)"
    }

    private var missingDescribers: String? {
        let absent = DescribeEngines.all.filter { candidate in
            !describeEngines.contains { $0.id == candidate.id }
        }
        guard !absent.isEmpty else { return nil }
        let names = absent.map(\.label).joined(separator: " and ")
        let verb = absent.count == 1 ? "is" : "are"
        return "\(names) \(verb) not on this Mac, so \(absent.count == 1 ? "it is" : "they are") not offered. "
            + absent.map { "\($0.label): npm i -g \($0.id == DescribeEngines.codex ? "@openai/codex" : "@anthropic-ai/claude-code")" }
                .joined(separator: " · ")
    }

    // MARK: who builds the vectors

    /// The narrower choice, and the one with a consequence. Anthropic sells no
    /// embeddings and a command-line tool cannot make one, so Claude Code and
    /// Codex are not here — and the panel says why, because their absence
    /// otherwise reads as an oversight.
    private var vectorPanel: some View {
        panel("Who builds your vectors", "The numbers a search is ranked by. Bought, always.", more: """
            Once per link, and again every time you press Return in Search: text turned \
            into the numbers a search is ranked by. It has to be bought — Claude Code and \
            Codex cannot do this one, whatever their subscription covers.
            """) {
            VStack(spacing: 10) { ForEach(VectorServices.all) { vectorCard($0) } }
            field("Which model", $embeddingModel,
                  help: "Written the way its own service writes it: with a slash on OpenRouter, without one on OpenAI.")
            caption(reindexWarning, tone: vectorChanged ? Theme.warn : Theme.faint)
        }
    }

    private func vectorCard(_ service: VectorService) -> some View {
        let on = vectorService == service.id
        return Button {
            guard vectorService != service.id else { return }
            vectorService = service.id
            // The model belongs to the service: "qwen/qwen3-embedding-8b" means
            // nothing to OpenAI. Landing on that service's first model is a
            // better guess than leaving a name that is certain to be refused.
            if !service.models.contains(where: { $0.id == embeddingModel }) {
                embeddingModel = service.models.first?.id ?? embeddingModel
            }
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 9) {
                    Circle()
                        .strokeBorder(on ? Theme.accent : Theme.line2, lineWidth: 1)
                        .background(Circle().fill(on ? Theme.accent : .clear).padding(3))
                        .frame(width: 12, height: 12)
                    Text(service.label).font(Theme.sans(13, on ? .medium : .regular))
                        .foregroundStyle(on ? Theme.ink : Theme.dim)
                    Spacer(minLength: 8)
                    Text(keys[service.id].map { $0.isEmpty ? "no key yet" : "key held" } ?? "no key yet")
                        .font(Theme.mono(10.5))
                        .foregroundStyle((keys[service.id]?.isEmpty ?? true) ? Theme.warn : Theme.fainter)
                        .fixedSize()
                }
                Text(service.note).font(Theme.sans(11.5)).foregroundStyle(Theme.faint)
                    .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                if on {
                    ForEach(service.models) { option in
                        Button { embeddingModel = option.id } label: {
                            HStack(alignment: .top, spacing: 8) {
                                Circle()
                                    .strokeBorder(embeddingModel == option.id ? Theme.accent : Theme.line2, lineWidth: 1)
                                    .background(Circle().fill(embeddingModel == option.id ? Theme.accent : .clear).padding(2.5))
                                    .frame(width: 10, height: 10).padding(.top, 3)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(option.label).font(Theme.sans(11.5, .medium))
                                        .foregroundStyle(embeddingModel == option.id ? Theme.ink : Theme.dim)
                                    Text(option.note).font(Theme.sans(11)).foregroundStyle(Theme.faint)
                                        .lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).clickable()
                    }
                }
            }
            .padding(13)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 8).fill(on ? Theme.accentWash : Theme.raised))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(on ? Theme.accentEdge : Theme.line))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).clickable()
    }

    /// Whether what is on screen would index differently from what the library
    /// already holds. Numbers made at one size, or by one model, cannot be
    /// compared with another's — so this is not a preference, it is a decision
    /// about every record already stored.
    private var vectorChanged: Bool {
        vectorService != indexedWith.service
            || embeddingModel.trimmingCharacters(in: .whitespaces) != indexedWith.model
    }

    private var reindexWarning: String {
        guard vectorChanged else {
            return "Changing this means importing everything again: numbers made by one model cannot be compared with another's."
        }
        guard model.count > 0 else {
            return "Nothing is stored yet, so there is nothing to redo — whatever you import will be built with this."
        }
        return "Your \(model.count) links were indexed with \(indexedWith.model). Saving this leaves them as they are, and they cannot be compared with anything this builds — searching would rank on numbers that do not mean the same thing. Erase and import again after saving."
    }

    // MARK: who answers a question

    private func askPanel(across columns: Int) -> some View {
        panel("Answering in Ask Unbury", "The costliest thing here. Choose whose money it spends.", more: """
            Ask Unbury puts a question to a model, which searches your library itself and reads \
            what comes back. It is the costliest thing this app does, whichever of these \
            answers — so the only real question is whose money it comes out of.
            """) {
            if columns == 1 {
                VStack(spacing: 10) { ForEach(engines) { engineCard($0) } }
            } else {
                HStack(alignment: .top, spacing: 12) { ForEach(engines) { engineCard($0) } }
            }
            if let missing = missingEngines {
                caption(missing, tone: Theme.fainter)
            }
            if chatEngine == ChatEngines.openRouter {
                modelPicker(across: columns)
            }
        }
    }

    private func engineCard(_ engine: ChatEngineOption) -> some View {
        let on = chatEngine == engine.id
        return Button { chatEngine = engine.id } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 9) {
                    // Tier 2 of the accent scheme: a small teal mark saying
                    // "this is the one you chose". Not a plate — a plate is the
                    // way forward, and the way forward here is Save.
                    Circle()
                        .strokeBorder(on ? Theme.accent : Theme.line2, lineWidth: 1)
                        .background(Circle().fill(on ? Theme.accent : .clear).padding(3))
                        .frame(width: 12, height: 12)
                    Text(engine.label).font(Theme.sans(13, on ? .medium : .regular))
                        .foregroundStyle(on ? Theme.ink : Theme.dim)
                    Spacer(minLength: 0)
                }
                Text("spends \(engine.purse)")
                    .font(Theme.mono(10.5))
                    .foregroundStyle(engine.spends ? Theme.warn : Theme.fainter)
                Text(engine.note).font(Theme.sans(11.5)).foregroundStyle(Theme.faint)
                    .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            }
            .padding(13)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 8).fill(on ? Theme.accentWash : Theme.raised))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(on ? Theme.accentEdge : Theme.line))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).clickable()
    }

    /// An engine that is not installed is left out rather than offered and then
    /// refused. Saying which one is missing, and how it is installed, is the
    /// difference between a short list and a list that looks broken.
    private var missingEngines: String? {
        let absent = ChatEngines.all.filter { candidate in
            !engines.contains { $0.id == candidate.id }
        }
        guard !absent.isEmpty else { return nil }
        let names = absent.map(\.label).joined(separator: " and ")
        let verb = absent.count == 1 ? "is" : "are"
        return "\(names) \(verb) not on this Mac, so \(absent.count == 1 ? "it is" : "they are") not offered. "
            + absent.map { "\($0.label): npm i -g \($0.id == ChatEngines.codex ? "@openai/codex" : "@anthropic-ai/claude-code")" }
                .joined(separator: " · ")
    }

    /// Which model OpenRouter is asked. Shown only when OpenRouter is the chosen
    /// engine, because for the other two it is not a question — they bring their
    /// own model along with their own bill.
    private func modelPicker(across columns: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                Marker(text: "WHICH MODEL")
                Text(priceNote).font(Theme.mono(10)).foregroundStyle(Theme.faintest)
                Spacer(minLength: 0)
            }
            .padding(.top, 6)

            if columns == 1 {
                VStack(spacing: 8) { ForEach(ChatModels.offered) { modelRow($0) } }
            } else {
                VStack(spacing: 8) {
                    ForEach(Array(stride(from: 0, to: ChatModels.offered.count, by: 2)), id: \.self) { start in
                        HStack(alignment: .top, spacing: 8) {
                            modelRow(ChatModels.offered[start])
                            if start + 1 < ChatModels.offered.count {
                                modelRow(ChatModels.offered[start + 1])
                            }
                        }
                    }
                }
            }
            HStack(spacing: 12) {
                Text("Another model").font(Theme.mono(11)).foregroundStyle(Theme.faint)
                    .fixedSize()
                TextField("owner/model-id", text: $chatModel)
                    .textFieldStyle(.plain).font(Theme.mono(12))
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 11).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.raised))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.line2))
            }
            .help("Any model on openrouter.ai that can call a tool. It is checked against today's list before it is saved.")
            if let complaint = complaint(about: chatModel) {
                caption(complaint, tone: Theme.warn)
            }
        }
    }

    private var priceNote: String {
        if let priceTrouble { return priceTrouble }
        return prices.isEmpty ? "reading today's prices from openrouter.ai…"
                              : "today's prices, read from openrouter.ai"
    }

    private func modelRow(_ option: ChatModelOption) -> some View {
        let on = chatModel == option.id
        return Button { chatModel = option.id } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 9) {
                    Circle()
                        .strokeBorder(on ? Theme.accent : Theme.line2, lineWidth: 1)
                        .background(Circle().fill(on ? Theme.accent : .clear).padding(3))
                        .frame(width: 11, height: 11)
                    Text(option.label).font(Theme.sans(12.5, on ? .medium : .regular))
                        .foregroundStyle(on ? Theme.ink : Theme.dim)
                    Spacer(minLength: 8)
                    Text(priceInWords(option.id))
                        .font(Theme.mono(11)).monospacedDigit()
                        .foregroundStyle(on ? Theme.accent : Theme.fainter)
                        .fixedSize()
                }
                Text(option.note).font(Theme.sans(11.5)).foregroundStyle(Theme.faint)
                    .fixedSize(horizontal: false, vertical: true)
                Text(option.id).font(Theme.mono(10)).foregroundStyle(Theme.faintest)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 7).fill(on ? Theme.accentWash : Theme.raised))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(on ? Theme.accentEdge : Theme.line))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).clickable()
    }

    /// The price in the only unit that means anything to somebody deciding: what
    /// one question costs. Blank until the live list arrives, because a made-up
    /// number here is exactly the kind of thing that becomes a surprise later.
    private func priceInWords(_ id: String) -> String {
        guard let facts = prices[id] else { return "—" }
        return ChatModels.inWords(facts)
    }

    /// What is wrong with a model id, in a sentence. Nil while the price list has
    /// not arrived: not knowing is not the same as knowing it is wrong.
    private func complaint(about id: String) -> String? {
        let wanted = id.trimmingCharacters(in: .whitespaces)
        guard !prices.isEmpty, !wanted.isEmpty else { return nil }
        guard let facts = prices[wanted] else {
            return "OpenRouter has no model called “\(wanted)”. Check the spelling at openrouter.ai/models."
        }
        guard facts.callsTools else {
            return "\(facts.name) cannot call a tool, so it cannot search your library. Pick one that can."
        }
        return nil
    }

    // MARK: the library itself

    private var libraryPanel: some View {
        panel("Your library", "Two files on this Mac. Browsing them touches no network.", more: """
            Two files on this Mac: the links, which you could read yourself, and the block \
            of numbers used to search them. Browsing and filtering them touches no network \
            at all.
            """) {
            HStack(spacing: 1) {
                figure("\(model.count)", "links")
                figure("\(model.siteCount)", "sites")
                figure(sizeOnDisk, "on disk")
            }
            .background(Theme.line)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
            Text(UnburyStore.defaultDirectory.path)
                .font(Theme.mono(10.5)).foregroundStyle(Theme.fainter)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func figure(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value).font(Theme.mono(18)).foregroundStyle(Theme.accent).monospacedDigit()
            Text(label).font(Theme.sans(11)).foregroundStyle(Theme.faint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(Theme.raised)
    }

    /// The bottom of the page: the two things that reach outside it. The one
    /// that cannot be undone sits as far from everything else as the page allows,
    /// on its own line, at the edge.
    private var closingBar: some View {
        HStack(spacing: 12) {
            Button { NSWorkspace.shared.open(UnburyStore.defaultDirectory) } label: {
                Label2("Show in Finder", filled: false)
            }
            .buttonStyle(.plain).clickable()
            .help("Open the folder holding both files")
            Spacer(minLength: 0)
            Text("Erasing keeps nothing. Your browser is never touched.")
                .font(Theme.mono(10.5)).foregroundStyle(Theme.fainter)
            Button { confirmingErase = true } label: {
                Text("Erase everything").font(Theme.sans(12)).foregroundStyle(Theme.bad)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.bad.opacity(0.4)))
            }
            .buttonStyle(.plain).clickable()
            .help("Delete every stored link and start over. Your browser is not touched.")
            .confirmationDialog("Erase everything?", isPresented: $confirmingErase) {
                Button("Erase \(model.count) links", role: .destructive) {
                    Task { await model.eraseVault() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Every description and vector is deleted from this Mac. Your bookmarks stay in your browser — importing them again costs money a second time.")
            }
        }
        .padding(.top, 14)
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    // MARK: staying current

    /// A row of its own rather than a fourth card in the board: three controls
    /// on one line, which in a 300-point column would wrap into a paragraph.
    ///
    /// "Check now" is a grey outline and not a teal plate. The plate on this
    /// page belongs to "Save and go back", and a screen with two of them is a
    /// screen that has stopped saying which one matters.
    private func updatesPanel(across columns: Int) -> some View {
        panel("Updates", "Signed builds only, and nothing downloads until you agree.", more: """
            Unbury asks GitHub for the list of released versions, and that list is signed \
            — a build that is not the owner's is refused rather than installed. Nothing is \
            downloaded until you agree to it, and the question carries nothing about you \
            or your library.
            """) {
            if columns == 1 {
                VStack(alignment: .leading, spacing: 14) {
                    installed
                    automaticRow
                    checkNowButton
                }
            } else {
                HStack(alignment: .center, spacing: 18) {
                    installed
                    Spacer(minLength: 12)
                    automaticRow
                    checkNowButton
                }
            }
        }
    }

    private var installed: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(version).font(Theme.mono(18)).foregroundStyle(Theme.accent)
                .monospacedDigit()
            Text("installed").font(Theme.sans(11)).foregroundStyle(Theme.faint)
        }
    }

    /// Applied the moment it is clicked, not on Save: Sparkle holds this one
    /// itself, so there is nothing for Save to write.
    private var automaticRow: some View {
        Button {
            autoUpdate.toggle()
            Updates.automaticallyChecksForUpdates = autoUpdate
        } label: {
            HStack(spacing: 9) {
                // Tier 2 of the accent scheme: teal says "on", never a plate.
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(autoUpdate ? Theme.accent : Theme.line2, lineWidth: 1)
                    .background(RoundedRectangle(cornerRadius: 3)
                        .fill(autoUpdate ? Theme.accent : .clear).padding(3))
                    .frame(width: 13, height: 13)
                Text("Look for a new version on its own")
                    .font(Theme.sans(12.5))
                    .foregroundStyle(autoUpdate ? Theme.ink : Theme.dim)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).clickable()
        .help("Check once a day in the background. You are still asked before anything is downloaded or installed.")
    }

    private var checkNowButton: some View {
        Button { Updates.checkNow() } label: {
            Label2("Check now", filled: false)
        }
        .buttonStyle(.plain).clickable()
        .help("Ask GitHub right now whether there is a newer version")
    }

    // MARK: plumbing

    private var version: String { Updates.current }

    private var sizeOnDisk: String {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: UnburyStore.defaultDirectory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        let bytes = files.reduce(0) { total, url in
            total + ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return bytes < 1_000_000 ? "\(bytes / 1000) KB"
                                 : String(format: "%.1f MB", Double(bytes) / 1_000_000)
    }

    private func load() {
        for service in VectorServices.all { keys[service.id] = Keychain.read(service) ?? "" }
        describeEngine = model.preferences.describeEngine
        describeModel = model.preferences.describeModel
        vectorService = VectorServices.known(model.preferences.vectorService)
        embeddingModel = model.preferences.embeddingModel
        chatModel = model.preferences.chatModel
        engines = ChatEngines.available()
        describeEngines = DescribeEngines.available()
        // A chosen tool may have been uninstalled since. Land on something that
        // can actually run rather than showing nothing selected.
        if !describeEngines.contains(where: { $0.id == describeEngine }) {
            describeEngine = describeEngines.first?.id ?? DescribeEngines.openRouter
        }
        chatEngine = ChatEngines.resolve(model.preferences.chatEngine)?.id
            ?? model.preferences.chatEngine
        // What is stored was built with whatever was saved when it was built.
        // Kept from before anything is touched, so a change can be recognised.
        indexedWith = (vectorService, embeddingModel)
        autoUpdate = Updates.automaticallyChecksForUpdates
    }

    private func readPrices() async {
        do { prices = try await ChatModels.catalogue() } catch {
            priceTrouble = "today's prices are out of reach — \(error.localizedDescription)"
        }
    }

    /// Whether a key is accepted, asked of the service the key belongs to and in
    /// the cheapest way each one allows. Nothing is bought, so this can be
    /// pressed as often as somebody likes.
    private func check(_ service: VectorService) async {
        checkingKey = service.id
        defer { checkingKey = nil }
        let held = (keys[service.id] ?? "").trimmingCharacters(in: .whitespaces)
        do {
            try await service.checkKey(held)
            keyStates[service.id] = ("Works.", true)
        } catch {
            keyStates[service.id] = (error.localizedDescription, false)
        }
    }

    /// Save, unless saving would quietly leave a library it can no longer rank.
    /// Then it asks, once, in the words of what is actually at stake.
    private func attemptSave() {
        if vectorChanged, model.count > 0 { confirmingReindex = true; return }
        save()
        model.showSettings = false
    }

    private func save() {
        for service in VectorServices.all {
            let held = (keys[service.id] ?? "").trimmingCharacters(in: .whitespaces)
            // An emptied field means "forget it", which is the only way somebody
            // can undo pasting a key into the wrong one of two fields.
            if held.isEmpty { Keychain.forget(service) } else { Keychain.write(service, key: held) }
        }
        var preferences = model.preferences
        preferences.describeEngine = DescribeEngines.known(describeEngine)
        preferences.describeModel = describeModel.trimmingCharacters(in: .whitespaces)
        preferences.vectorService = VectorServices.known(vectorService)
        preferences.embeddingModel = embeddingModel.trimmingCharacters(in: .whitespaces)
        preferences.chatEngine = chatEngine
        // A model the live list has just called unusable is not written down: a
        // paid setting must never be left in a state that only fails later. The
        // field keeps showing what was typed, with the reason beside it.
        let wanted = chatModel.trimmingCharacters(in: .whitespaces)
        if complaint(about: wanted) == nil, !wanted.isEmpty { preferences.chatModel = wanted }
        try? preferences.save()
        model.preferences = preferences
        indexedWith = (preferences.vectorService, preferences.embeddingModel)
    }

    /// Title, then the reason the subject exists, then the controls — always in
    /// that order and always at the same three distances, so four different
    /// subjects still read as one page.
    private func panel<Content: View>(_ title: String, _ explanation: String,
                                      more: String? = nil,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                SectionRule()
                Text(title).font(Theme.sans(15, .medium)).foregroundStyle(Theme.ink)
                if let more { MoreInfo(text: more) }
            }
            Text(explanation).font(Theme.sans(12.5)).foregroundStyle(Theme.dim)
                .lineSpacing(3.5).fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
            VStack(alignment: .leading, spacing: 12) { content() }
                .padding(.top, 16)
        }
        .padding(gap - 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
    }

    private func caption(_ text: String, tone: Color) -> some View {
        Text(text).font(Theme.sans(11.5)).foregroundStyle(tone).lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Label above rather than beside: a field with a 124-point label to its left
    /// stops being a column the moment the panel is 340 points wide.
    private func field(_ label: String, _ value: Binding<String>, help: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(Theme.mono(11)).foregroundStyle(Theme.faint)
            TextField("", text: value).textFieldStyle(.plain).font(Theme.mono(12))
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 11).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.raised))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.line2))
        }
        .help(help)
    }
}

/// The whole of what this app spends, in four lines.
///
/// It exists because the owner has hit a spending cap twice, and both times the
/// app read as broken rather than as out of credit. Money is never a footnote
/// here — it is stated where the key is entered, and again on the first screen
/// anybody sees, in exactly these words. The word "free" appears nowhere: the
/// engines that do not touch the key spend a subscription that is being paid for
/// all the same, and pretending otherwise is the kind of half-truth that turns
/// into a nasty surprise.
struct CostGuide: View {
    /// One column per thing when the page is wide enough to line them up, and a
    /// stack when it is not. Onboarding always uses the stack: it is a reading
    /// column, not a board.
    var across: Int = 1

    private let rows = [
        ("BROWSING", "Tags, filtering, opening a link, reading what is saved. Nothing leaves this Mac and no network is used.", false),
        ("SEARCHING", "Pressing Return sends the question to OpenRouter to be turned into a vector. Real, but thousandths of a cent.", false),
        ("ASKING", "The costly one. Claude Code and Codex spend the subscription you already pay for; OpenRouter spends from your key.", true),
        ("IMPORTING", "The other costly one: every page read and described once. The import window says what it will cost first.", true),
    ]

    var body: some View {
        Group {
            if across > 1 {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(rows, id: \.0) { marker, text, costly in
                        column(marker, text, costly)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(rows, id: \.0) { marker, text, costly in
                        HStack(alignment: .top, spacing: 11) {
                            Marker(text: marker, color: costly ? Theme.warn : Theme.fainter)
                                .fixedSize()
                                .frame(width: 78, alignment: .leading)
                                .padding(.top, 2)
                            Text(text).font(Theme.sans(11.5)).foregroundStyle(Theme.dim)
                                .lineSpacing(3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(13)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.raised))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
            }
        }
    }

    private func column(_ marker: String, _ text: String, _ costly: Bool) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Marker(text: marker, color: costly ? Theme.warn : Theme.fainter).fixedSize()
            Text(text).font(Theme.sans(11.5)).foregroundStyle(Theme.dim).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(13)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.raised))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
    }
}
