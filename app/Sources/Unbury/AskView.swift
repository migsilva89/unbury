import SwiftUI
import UnburyCore

/// Ask Unbury — putting a question to the library and getting an answer back.
///
/// The name says who you are talking to: Search finds links, Ask Unbury keeps
/// digging until it reaches something worth reading. The conversation is in the middle, and
/// every record the model read is beside it — numbered as it is cited, so an
/// answer can be checked against what it actually saw.
///
/// The type is still called `AskView`. Nobody sees a type name, and `AskEngine`
/// and `AskLive` are spoken to from files this one does not own; renaming half
/// of that chain would cost other people edits and buy the person nothing.
struct AskView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool
    /// The bottom of the transcript, so the view can follow a growing answer.
    private let liveAnchor = "live-edge"
    /// A side panel sits beside the conversation only while that leaves the
    /// conversation itself room to be read. Below these it still opens — over
    /// the top, on request — because a panel you cannot reach is a panel that
    /// does not exist.
    private static let roomForHistory: CGFloat = 1_180
    private static let roomForEvidence: CGFloat = 900
    /// How wide the conversation itself is allowed to get. Prose stops being
    /// readable long before a window stops being wide.
    private static let measure: CGFloat = 780

    var body: some View {
        @Bindable var conversation = model.conversation
        return GeometryReader { space in
            let railBeside = space.size.width >= Self.roomForHistory
            let evidenceBeside = space.size.width >= Self.roomForEvidence
            VStack(spacing: 0) {
                askBar(railBeside: railBeside, evidenceBeside: evidenceBeside)
                HStack(spacing: 0) {
                    if railBeside && conversation.historyOpen {
                        HistoryRail().frame(width: 244)
                        Divider().background(Theme.line)
                    }
                    VStack(spacing: 0) {
                        transcript
                        if let trouble { unavailable(trouble) }
                        composer
                    }
                    .frame(maxWidth: .infinity)
                    if evidenceBeside && conversation.evidenceOpen {
                        Divider().background(Theme.line)
                        EvidencePanel()
                            .frame(width: min(348, max(300, space.size.width * 0.26)))
                    }
                }
                // Too narrow to stand beside, so it comes over the top on
                // request. The darkened room is a second way out, and the button
                // that opened it is still lit in the bar above.
                .overlay(alignment: .leading) {
                    if !railBeside && conversation.historyOpen {
                        panelOverThe(.leading) { HistoryRail().frame(width: 244) }
                    }
                }
                .overlay(alignment: .trailing) {
                    if !evidenceBeside && conversation.evidenceOpen {
                        panelOverThe(.trailing) {
                            EvidencePanel()
                                .frame(width: min(348, max(288, space.size.width - 64)))
                        }
                    }
                }
            }
            // Opening the app in a narrow window must not open onto a panel
            // lying over the answer, so this is settled before it is drawn.
            .onChange(of: railBeside, initial: true) { _, beside in
                railHasRoom = beside
                if !beside { conversation.historyOpen = false }
            }
            .onChange(of: evidenceBeside, initial: true) { _, beside in
                evidenceHasRoom = beside
                if !beside { conversation.evidenceOpen = false }
            }
        }
        .onAppear {
            focused = true
            adoptStoredEngine()
            Task { await model.conversation.loadHistory() }
        }
        // The evidence panel opens the same record drawer the Search screen
        // does, and that drawer can delete. One dialog per screen, and only one
        // screen is ever mounted.
        .deleteConfirmation()
        // One "back", and the key does exactly what the visible buttons do, in
        // the same order: put away what is on top, then what is beside, then
        // leave the screen. Every step of it also has a control you can click.
        .onExitCommand(perform: goBack)
        // Settings is a separate page, so the choice can change while this
        // screen is sitting here. It is read again rather than cached.
        .onChange(of: model.preferences.chatEngine) { _, _ in adoptStoredEngine() }
    }

    /// The engine settings hold, if this Mac can still run it. Someone who chose
    /// Codex and then uninstalled it must not be left with a screen whose only
    /// button fails; the first engine that is actually there answers instead.
    private func adoptStoredEngine() {
        let stored = Engine(stored: model.preferences.chatEngine) ?? .claude
        let choices = AskEngine.installed()
        model.conversation.engine = choices.contains(stored) ? stored : (choices.first ?? stored)
    }

    /// What "back" means on this screen, in one place. The buttons call this
    /// too, so a person never has to work out which control returns them.
    private func goBack() {
        let conversation = model.conversation
        withAnimation(.easeOut(duration: 0.16)) {
            if model.selected != nil { model.selected = nil; return }
            if conversation.historyOpen && !railHasRoom { conversation.historyOpen = false; return }
            if conversation.evidenceOpen && !evidenceHasRoom { conversation.evidenceOpen = false; return }
            model.tab = .search
        }
    }

    /// Whether the last drawn layout had room to stand a panel beside the
    /// conversation. Read by `goBack`, which has no geometry of its own.
    @State private var railHasRoom = true
    @State private var evidenceHasRoom = true

    /// A panel lying over the conversation, with the room it covers darkened and
    /// tappable. Both sides use it, so both behave the same way.
    private func panelOverThe<Panel: View>(_ edge: HorizontalAlignment,
                                           @ViewBuilder panel: () -> Panel) -> some View {
        let scrim = Rectangle().fill(Color.black.opacity(0.72))
            .contentShape(Rectangle())
            .onTapGesture(perform: goBack)
        return HStack(spacing: 0) {
            if edge == .trailing { scrim }
            panel()
            if edge == .leading { scrim }
        }
        .transition(.move(edge: edge == .leading ? .leading : .trailing))
    }

    // MARK: the bar across the top

    /// Three controls, all labelled in words: the panel on the left, the way to
    /// a fresh conversation, the panel on the right.
    ///
    /// Nothing else. What answers a question, and whose money it spends, used to
    /// sit here as a row of engine names beside a READ-ONLY badge — four things
    /// competing with the two that are actually navigation. That belongs with
    /// the question you are about to ask, and it has moved there.
    private func askBar(railBeside: Bool, evidenceBeside: Bool) -> some View {
        let conversation = model.conversation
        return HStack(spacing: 8) {
            panelButton(title: "Conversations",
                        count: conversation.history.count,
                        open: conversation.historyOpen,
                        help: conversation.historyOpen
                            ? "Hide your past conversations"
                            : "Show your past conversations") {
                if conversation.historyOpen {
                    conversation.historyOpen = false
                } else {
                    conversation.historyOpen = true
                    // Two panels lying over one narrow conversation would leave
                    // nothing of it to see.
                    if !railBeside && !evidenceBeside { conversation.evidenceOpen = false }
                }
            }
            barButton("New conversation", help: "Start a new conversation") {
                conversation.startNew()
                focused = true
            }
            .disabled(conversation.isEmpty && conversation.current == nil)
            Spacer(minLength: 12)
            panelButton(title: "Evidence",
                        count: conversation.evidence.count,
                        open: conversation.evidenceOpen,
                        help: conversation.evidenceOpen
                            ? "Hide what the answers were built on"
                            : "Show what the answers were built on") {
                if conversation.evidenceOpen {
                    conversation.evidenceOpen = false
                } else {
                    conversation.evidenceOpen = true
                    if !railBeside && !evidenceBeside { conversation.historyOpen = false }
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(Theme.panel)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    /// The control that shows or hides a side panel. One per panel, in the bar,
    /// wearing its state: outlined in the accent and lit when the panel is
    /// showing, plain grey when it is not. The count is there so that hiding
    /// something does not hide that it exists.
    private func panelButton(title: String, count: Int, open: Bool, help: String,
                             action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.16), action)
        } label: {
            HStack(spacing: 6) {
                Text(title).font(Theme.sans(11.5, open ? .medium : .regular))
                if count > 0 {
                    Text("\(count)").font(Theme.mono(10)).monospacedDigit()
                        .foregroundStyle(open ? Theme.accent : Theme.fainter)
                }
            }
            .foregroundStyle(open ? Theme.accent : Theme.dim)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 5)
                .fill(open ? Theme.accent.opacity(0.14) : .clear))
            .overlay(RoundedRectangle(cornerRadius: 5)
                .stroke(open ? Theme.accent.opacity(0.5) : Theme.line2))
        }
        .buttonStyle(.plain).clickable().help(help)
    }

    private func barButton(_ text: String, help: String,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text).font(Theme.sans(11.5)).foregroundStyle(Theme.dim)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.line2))
        }
        .buttonStyle(.plain).clickable().help(help)
    }

    /// Whose money the next question spends, under the field that asks it —
    /// where it is a fact about what you are about to do, rather than a row of
    /// controls competing with the ones that move you around. Settings owns the
    /// choice, so this says where to go and changes nothing itself.
    private var engineLine: some View {
        HStack(spacing: 6) {
            Marker(text: "READ-ONLY")
            Circle().fill(Theme.line2).frame(width: 2.5, height: 2.5)
            Text(answeredBy).font(Theme.mono(10.5)).foregroundStyle(Theme.faint)
                .monospacedDigit()
            Button { model.showSettings = true } label: {
                Text("Change").font(Theme.mono(10.5)).foregroundStyle(Theme.dim)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(Theme.line2))
            }
            .buttonStyle(.plain).clickable()
            .help("Choose which engine answers, in Settings")
        }
    }

    private var answeredBy: String {
        let conversation = model.conversation
        let engine = conversation.engine
        if engine.meteredByUs && conversation.spent > 0 {
            return String(format: "%@ · $%.4f this session", engine.label, conversation.spent)
        }
        return "\(engine.label) · spends \(engine.purse)"
    }

    // MARK: the conversation

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.conversation.turns) { turn in
                        TurnView(turn: turn).id(turn.id)
                    }
                    Color.clear.frame(height: 1).id(liveAnchor)
                }
                .padding(.bottom, 12)
                // One measure for the conversation, held in the middle of
                // whatever room it has. Hiding a side panel widens the column,
                // and prose left clinging to the edge of it reads as a screen
                // that has come apart rather than one with room to spare.
                .frame(maxWidth: Self.measure)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .opacity(model.conversation.isEmpty ? 0 : 1)
            // An empty conversation is not a short list, it is a screen with
            // nothing on it yet — so what it says sits in the middle of the room
            // rather than clinging to the top of it.
            .overlay { if model.conversation.isEmpty { invitation } }
            .overlay { if model.conversation.opening { openingNote } }
            .onChange(of: model.conversation.turns.count) { _, _ in
                withAnimation { proxy.scrollTo(model.conversation.turns.last?.id, anchor: .top) }
            }
            .onChange(of: AskLive.shared.visibleDraft) { _, _ in
                // The answer writes itself downward; the view follows it rather
                // than leaving the person reading a fixed window.
                proxy.scrollTo(liveAnchor, anchor: .bottom)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var invitation: some View {
        VStack(alignment: .leading, spacing: 14) {
            UnburyBadge(size: 34).padding(.bottom, 2)
            Text("Ask a question. Unbury searches your own links and answers from what it finds.")
                .font(Theme.sans(19, .light)).foregroundStyle(Theme.ink).lineSpacing(4)
            Text("Every search it runs, and everything that came back, stays below the answer.")
                .font(Theme.sans(13)).foregroundStyle(Theme.faint).lineSpacing(4)
            HStack(spacing: 16) {
                key("↵"); Text("ask").font(Theme.mono(10.5)).foregroundStyle(Theme.fainter)
                key("esc"); Text("back").font(Theme.mono(10.5)).foregroundStyle(Theme.fainter)
            }.padding(.top, 4)
        }
        .frame(maxWidth: Self.measure - 200, alignment: .leading)
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    /// Reading a conversation back in. Brief, but a screen that goes blank while
    /// a file is read looks like one that has lost the conversation.
    private var openingNote: some View {
        HStack(spacing: 8) {
            Pulse()
            Text("opening…").font(Theme.mono(11)).foregroundStyle(Theme.faint)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .background(Theme.bg.opacity(0.9))
    }

    private func key(_ text: String) -> some View {
        Text(text).font(Theme.mono(10.5)).foregroundStyle(Theme.fainter)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Theme.line))
    }

    // MARK: asking

    private var composer: some View {
        @Bindable var conversation = model.conversation
        return VStack(alignment: .leading, spacing: 9) {
            questionField
            engineLine
        }
        .padding(.horizontal, 22).padding(.top, 13).padding(.bottom, 14)
        .frame(maxWidth: Self.measure, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .center)
        .background(Theme.panel)
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    private var questionField: some View {
        @Bindable var conversation = model.conversation
        return HStack(alignment: .firstTextBaseline, spacing: 11) {
            Text("?").font(Theme.mono(13)).foregroundStyle(Theme.faintest)
            TextField(conversation.isEmpty
                      ? "Ask Unbury about anything you have saved…"
                      : "Ask again, or follow up…",
                      text: $conversation.input)
                .textFieldStyle(.plain)
                .font(Theme.sans(15, .light))
                .foregroundStyle(Theme.ink)
                .focused($focused)
                .onSubmit(ask)
                .onHover { inside in
                    if inside {
                        NSCursor.iBeam.push()
                    } else {
                        NSCursor.pop()
                    }
                }
            if model.conversation.isWorking {
                // A question in flight can be taken back. Waiting with no way out
                // is the part that makes a slow answer feel broken.
                Button { model.conversation.stop() } label: {
                    Text(AskLive.shared.stopping ? "stopping…" : "stop")
                        .font(Theme.mono(10.5))
                        .foregroundStyle(AskLive.shared.stopping ? Theme.fainter : Theme.bad)
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .overlay(RoundedRectangle(cornerRadius: 4)
                            .stroke(AskLive.shared.stopping ? Theme.line : Theme.bad.opacity(0.5)))
                }
                .buttonStyle(.plain).clickable()
                .disabled(AskLive.shared.stopping)
                .help("Stop this question")
            } else {
                // Tier 3, and the only plate on this screen. It earns the teal
                // only when there is a question to send; an empty composer gets
                // the grey outline, so the colour is a promise rather than a lie.
                Button(action: ask) {
                    Text("ask ↵").font(Theme.mono(10.5, canAsk ? .medium : .regular))
                        .foregroundStyle(canAsk ? Theme.onAccent : Theme.fainter)
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 4)
                            .fill(canAsk ? Theme.accent : .clear))
                        .overlay(RoundedRectangle(cornerRadius: 4)
                            .stroke(canAsk ? Theme.accent : Theme.line))
                }.buttonStyle(.plain).clickable().disabled(!canAsk)
            }
        }
    }

    private var canAsk: Bool {
        !model.conversation.input.trimmingCharacters(in: .whitespaces).isEmpty
            && !(model.conversation.turns.last?.working ?? false)
    }

    private func ask() {
        guard canAsk else { return }
        let question = model.conversation.input.trimmingCharacters(in: .whitespaces)
        model.conversation.input = ""
        model.conversation.running = Task { await model.ask(question) }
    }

    // MARK: when an engine cannot run

    private var trouble: (String, String, String)? {
        let engine = model.conversation.engine
        if !AskEngine.available(engine) {
            return ("\(engine.label) is not installed on this Mac.",
                    "This engine runs the copy already on your machine, so nothing is charged per message — but it has to be there. Switch to OpenRouter, which works anywhere, or install it.",
                    engine.installCommand)
        }
        if engine.meteredByUs && model.key == nil {
            return ("There is no OpenRouter key.",
                    "This engine bills your OpenRouter account per conversation. Add a key, or switch to an engine that already runs on this Mac.",
                    engine.installCommand)
        }
        return nil
    }

    private func unavailable(_ trouble: (String, String, String)) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Marker(text: "UNAVAILABLE", color: Theme.bad).padding(.top, 2)
            VStack(alignment: .leading, spacing: 5) {
                Text(trouble.0).font(Theme.sans(13.5)).foregroundStyle(Theme.ink)
                Text(trouble.1).font(Theme.sans(12.5)).foregroundStyle(Theme.dim).lineSpacing(3)
                Text(trouble.2).font(Theme.mono(11.5)).foregroundStyle(Theme.faint)
                    .padding(.horizontal, 9).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Theme.bg))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.line))
                    .textSelection(.enabled)
                    .padding(.top, 5)
            }
        }
        .frame(maxWidth: 660, alignment: .leading)
        .padding(.horizontal, 22).padding(.vertical, 15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel)
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
    }
}


/// The conversations already had, down the side.
///
/// Titled by the first question rather than by a number, because that is what a
/// person remembers about one. Only a screenful is drawn at a time: the list is
/// meant to hold years of asking, and building four hundred rows to show twelve
/// is how a sidebar starts to stutter.
struct HistoryRail: View {
    @Environment(AppModel.self) private var model
    /// How many rows have been asked for. Grows on request rather than all at
    /// once — see above.
    @State private var shown = 40
    private static let page = 40

    private var history: [ChatSummary] { model.conversation.history }

    var body: some View {
        VStack(spacing: 0) {
            if history.isEmpty {
                Text("Conversations are kept here, named after the question that started them.")
                    .font(Theme.sans(12)).foregroundStyle(Theme.fainter).lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.vertical, 16)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(history.prefix(shown)) { summary in
                            HistoryRow(summary: summary)
                        }
                        if history.count > shown {
                            Button { shown += Self.page } label: {
                                Text("\(history.count - shown) older")
                                    .font(Theme.mono(10.5)).foregroundStyle(Theme.dim)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 14).padding(.vertical, 11)
                            }.buttonStyle(.plain).clickable()
                        }
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
        .background(Theme.panel)
    }
}

struct HistoryRow: View {
    @Environment(AppModel.self) private var model
    let summary: ChatSummary
    @State private var hovering = false

    private var current: Bool { model.conversation.current?.id == summary.id }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(summary.title)
                    .font(Theme.sans(12.5))
                    .foregroundStyle(current ? Theme.ink : Theme.dim)
                    .lineLimit(2).multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 6) {
                    Text(Self.when(summary.updatedAt))
                    Circle().fill(Theme.line2).frame(width: 2.5, height: 2.5)
                    Text(summary.questions == 1 ? "1 question" : "\(summary.questions) questions")
                }
                .font(Theme.mono(10)).foregroundStyle(Theme.faint).monospacedDigit()
            }
            // Only on the row under the pointer: a column of crosses reads as a
            // list of things asking to be thrown away.
            Button { Task { await model.conversation.delete(summary) } } label: {
                Text("✕").font(Theme.mono(10))
                    .foregroundStyle(hovering ? Theme.bad : .clear)
                    .padding(.horizontal, 3).padding(.vertical, 1)
            }
            .buttonStyle(.plain).clickable()
            .help("Delete this conversation")
            .disabled(!hovering)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(current ? Theme.raised : hovering ? Theme.bg.opacity(0.6) : .clear)
        .overlay(alignment: .leading) {
            Rectangle().fill(current ? Theme.accent : .clear).frame(width: 2)
        }
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
        .contentShape(Rectangle())
        .onTapGesture { Task { await model.conversation.open(summary, from: model.store) } }
        .onHover { hovering = $0 }
        .clickable()
    }

    /// When it was last asked in. A link is dated to the day, but three
    /// conversations on one afternoon all read "today" — so today keeps its
    /// clock, and anything older loses it.
    static func when(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            let clock = DateFormatter()
            clock.dateFormat = "HH:mm"
            return clock.string(from: date)
        }
        if calendar.isDateInYesterday(date) { return "yesterday" }
        let days = calendar.dateComponents([.day], from: date, to: Date()).day ?? 0
        if days < 7 { return "\(days) days ago" }
        let parts = calendar.dateComponents([.day, .month], from: date)
        guard let day = parts.day, let month = parts.month, month >= 1, month <= 12
        else { return "earlier" }
        return "\(day) \(Format.months[month - 1])"
    }
}

/// What is happening right now, while an answer is being made.
///
/// The prose here is deliberately dimmer than a finished answer, and carries no
/// citation chips: it is the model thinking out loud, not something to act on.
/// The moment the turn ends this disappears and the checked answer takes its
/// place, so a half-written sentence can never be mistaken for a conclusion.
struct LiveView: View {
    var body: some View {
        let live = AskLive.shared
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Pulse()
                Text(live.note.isEmpty ? "working…" : live.note)
                    .font(Theme.mono(11)).foregroundStyle(Theme.faint)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(Self.elapsed(from: live.startedAt, to: context.date))
                        .font(Theme.mono(10.5)).foregroundStyle(Theme.fainter)
                        .monospacedDigit()
                }
            }
            if !live.visibleDraft.isEmpty {
                Text(live.visibleDraft)
                    .font(Theme.sans(13.5)).foregroundStyle(Theme.dim).lineSpacing(5)
                    .frame(maxWidth: 600, alignment: .leading)
                    .transition(.opacity)
            }
        }
        .padding(.leading, 13)
    }

    static func elapsed(from start: Date, to now: Date) -> String {
        guard start > .distantPast else { return "" }
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s"
    }
}

/// A dot that breathes, so a still screen still reads as alive.
struct Pulse: View {
    var body: some View {
        TimelineView(.animation) { context in
            let phase = context.date.timeIntervalSinceReferenceDate * 1.6
            Circle()
                .fill(Theme.accent)
                .frame(width: 5, height: 5)
                .opacity(0.35 + 0.5 * (0.5 + 0.5 * sin(phase)))
        }
    }
}

/// One question, the searches it caused, and the answer that came out.
struct TurnView: View {
    @Environment(AppModel.self) private var model
    let turn: Turn

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 11) {
                Text("?").font(Theme.mono(12)).foregroundStyle(Theme.faintest)
                Text(turn.question).font(Theme.sans(15)).foregroundStyle(Theme.ink).lineSpacing(3)
            }
            VStack(alignment: .leading, spacing: 11) {
                ForEach(turn.calls) { call in CallView(call: call, numbering: turn.numbering) }
                if turn.working { LiveView() }
            }
            .padding(.top, 15).padding(.leading, 23)

            if turn.stopped {
                HStack(spacing: 8) {
                    Marker(text: "STOPPED")
                    Text("You stopped this one. Nothing was charged for what it had not finished.")
                        .font(Theme.sans(12.5)).foregroundStyle(Theme.faint)
                }
                .padding(.top, 14).padding(.leading, 23)
            } else if let error = turn.error {
                Text(error).font(Theme.sans(13)).foregroundStyle(Theme.bad)
                    .frame(maxWidth: 600, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(.top, 14).padding(.leading, 23)
            } else if let dead = turn.deadEnd {
                VStack(alignment: .leading, spacing: 13) {
                    Text(dead).font(Theme.sans(14)).foregroundStyle(Theme.ink).lineSpacing(6)
                    Text("\(turn.engine.label) · nothing cited")
                        .font(Theme.mono(10.5)).foregroundStyle(Theme.fainter)
                }
                .frame(maxWidth: 600, alignment: .leading)
                .padding(.top, 14).padding(.leading, 23)
            } else if turn.hasAnswer {
                answer
            }
        }
        .frame(maxWidth: 660, alignment: .leading)
        .padding(.horizontal, 22).padding(.top, 22).padding(.bottom, 26)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    private var answer: some View {
        VStack(alignment: .leading, spacing: 0) {
            if turn.weakEvidence {
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    Marker(text: "WEAK", color: Theme.warn)
                    Text("The best match scored \(String(format: "%.2f", turn.cited.first?.score ?? 0)) — read this as a hint, not an answer.")
                        .font(Theme.sans(12.5)).foregroundStyle(Theme.dim).lineSpacing(2)
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.panel)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.line2))
                .overlay(alignment: .leading) { Rectangle().fill(Theme.warn).frame(width: 2) }
                .padding(.bottom, 13)
            }
            ForEach(turn.parts) { part in
                VStack(alignment: .leading, spacing: 6) {
                    // Emphasis as emphasis. The models write ordinary markdown,
                    // and a paragraph reading "the **awesome-mac** catalogue"
                    // is the app showing its plumbing.
                    Text(Self.styled(part.text))
                        .font(Theme.sans(14)).foregroundStyle(Theme.ink).lineSpacing(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    // Under the sentence, not beside it. Beside it meant beside
                    // the *first line* of it, so a four-line sentence's sources
                    // floated at the top right with nothing to do with them.
                    if !part.citations.isEmpty {
                        HStack(spacing: 4) {
                            ForEach(part.citations, id: \.self) { id in
                                CitationChip(id: id, number: turn.numbering[id] ?? 0,
                                             match: turn.cited.first { $0.bookmark.id == id })
                            }
                        }
                    }
                }
                .padding(.bottom, 10)
            }
            HStack(spacing: 10) {
                Text(turn.engine.label)
                Circle().fill(Theme.line2).frame(width: 3, height: 3)
                Text(turn.engine.meteredByUs ? String(format: "$%.4f", turn.cost) : turn.engine.purse)
                Circle().fill(Theme.line2).frame(width: 3, height: 3)
                Text(evidenceNote).foregroundStyle(turn.weakEvidence ? Theme.warn : Theme.fainter)
            }
            .font(Theme.mono(10.5)).foregroundStyle(Theme.fainter).monospacedDigit()
            .padding(.top, 15)
        }
        .padding(.top, 14).padding(.leading, 23)
    }

    /// A sentence with its emphasis kept, and nothing else — no headings, no
    /// lists, no links. An answer is prose, and anything more would let a model
    /// redesign this screen from inside a string.
    static func styled(_ text: String) -> AttributedString {
        // Backticks first: a model writing `background-attachment` gets a
        // monospaced run in the middle of a sentence, and the line it sits on
        // grows taller than the ones around it. The word is the point, not the
        // typeface.
        let prose = text.replacingOccurrences(of: "`", with: "")
        return (try? AttributedString(
            markdown: prose,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(prose)
    }

    private var evidenceNote: String {
        if turn.cited.isEmpty { return "nothing cited" }
        let scored = turn.cited.filter { $0.score >= 0 }
        guard !scored.isEmpty else { return "\(turn.cited.count) records cited" }
        let strong = scored.filter { $0.score >= AppModel.strong }.count
        return "\(turn.cited.count) records cited · \(strong) strong"
    }
}

struct CallView: View {
    @Environment(AppModel.self) private var model
    let call: SearchCall
    let numbering: [Int: Int]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Marker(text: "SEARCH \(call.number)")
                Text("“\(call.query)”").font(Theme.mono(12)).foregroundStyle(Theme.ink2)
                Text(call.status).font(Theme.mono(11)).monospacedDigit()
                    .foregroundStyle(call.foundNothing ? Theme.warn : Theme.faint)
            }
            if let reason = call.reason, !reason.isEmpty {
                Text(reason).font(Theme.sans(12)).foregroundStyle(Theme.faint)
                    .lineSpacing(2).padding(.top, 4)
            }
            ForEach(Array(call.hits.prefix(4).enumerated()), id: \.element.id) { _, hit in
                Button { model.open(hit.bookmark) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Text(numbering[hit.bookmark.id].map(String.init) ?? "·")
                            .font(Theme.mono(10.5)).foregroundStyle(Theme.fainter)
                            .frame(width: 20, alignment: .leading)
                        Text(hit.bookmark.displayTitle).font(Theme.sans(12.5))
                            .foregroundStyle(Theme.ink2).lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(hit.bookmark.site).font(Theme.mono(10.5))
                            .foregroundStyle(Theme.faint).lineLimit(1)
                            .frame(width: 78, alignment: .leading)
                        Text(String(format: "%.2f", hit.score)).font(Theme.mono(11))
                            .foregroundStyle(hit.score >= AppModel.strong ? Theme.accent : Theme.faint)
                            .monospacedDigit().frame(width: 42, alignment: .trailing)
                    }
                    .padding(.vertical, 4).padding(.trailing, 6)
                    .background(model.selected?.id == hit.bookmark.id ? Theme.panel : .clear)
                }.buttonStyle(.plain).clickable()
            }
        }
        .padding(.leading, 12)
        .overlay(alignment: .leading) {
            Rectangle().fill(call.foundNothing ? Theme.line2 : Theme.line).frame(width: 1)
        }
    }
}

struct CitationChip: View {
    @Environment(AppModel.self) private var model
    let id: Int
    let number: Int
    let match: Match?

    var body: some View {
        let strong = (match?.score ?? 0) >= 0.62
        let on = model.selected?.id == id
        Button {
            if let bookmark = match?.bookmark { model.open(bookmark) }
        } label: {
            Text("\(number == 0 ? id : number)")
                .font(Theme.mono(10))
                .foregroundStyle(on ? Theme.onAccent : strong ? Theme.accent : Theme.dim)
                .padding(.horizontal, 4)
                .background(RoundedRectangle(cornerRadius: 3)
                    .fill(on ? Theme.accent : .clear))
                .overlay(RoundedRectangle(cornerRadius: 3)
                    .stroke(on ? Theme.accent : Theme.line))
        }
        .buttonStyle(.plain).clickable()
        // A citation the searches never returned points at nothing, so it does
        // nothing. It is still shown: an answer citing a record that is not in
        // the evidence is exactly what a person needs to see.
        .disabled(match == nil)
        .help(match?.bookmark.displayTitle ?? "record \(id) — never came back from a search")
    }
}

/// Everything the model read, split by whether the answer actually leans on it.
///
/// A flat list of eleven records says nothing about which three the answer rests
/// on. This says it: the ones carrying sentences come first, with how many each
/// carries, and the rest are kept below under their own heading — because what
/// the model read and chose to ignore is part of the evidence too.
struct EvidencePanel: View {
    @Environment(AppModel.self) private var model
    /// The vault's copy of each record on show, by address. The transcript keeps
    /// the record as it was when the search ran; an import since then can have
    /// retagged it or marked it gone from the browser, and the panel has to
    /// show what is true now.
    @State private var live: [String: Bookmark] = [:]

    private var turn: Turn? { model.conversation.evidenceTurn }

    /// How many sentences of the answer rest on each record, worked out once so
    /// that being in the first group and having a count are the same fact.
    private var leaning: [Int: Int] {
        guard let turn, !turn.working else { return [:] }
        var counts: [Int: Int] = [:]
        for part in turn.parts {
            for id in Set(part.citations) { counts[id, default: 0] += 1 }
        }
        return counts
    }
    /// The records the answer cites, in the order the panel already has them.
    private var carrying: [Match] {
        let counts = leaning
        return model.conversation.evidence.filter { counts[$0.bookmark.id] != nil }
    }
    private var read: [Match] {
        let counts = leaning
        return model.conversation.evidence.filter { counts[$0.bookmark.id] == nil }
    }

    /// Which of these records is open, if any. Opening one from an answer and
    /// opening one from the results list is the same act, so it is the same
    /// piece of state — and that is what makes "show in Search" land.
    private var openRecord: Bookmark? {
        guard let selected = model.selected,
              model.conversation.evidence.contains(where: { $0.bookmark.id == selected.id })
        else { return nil }
        return selected
    }

    /// The addresses on show, as one value a task can watch.
    private var addresses: String {
        model.conversation.evidence.map(\.bookmark.url).joined(separator: "\n")
    }

    var body: some View {
        VStack(spacing: 0) {
            if let openRecord {
                // The same drawer the Search screen opens, not a second, thinner
                // description of the same record. Two presentations of one thing
                // drift apart, and the poorer one is always the one on show.
                // It is told what closing means here, so its button says where
                // it goes rather than naming a key.
                DetailDrawer(bookmark: openRecord,
                             closeLabel: "Back to evidence",
                             onClose: { model.selected = nil })
                footer(showing: openRecord)
            } else {
                list
                footer(showing: nil)
            }
        }
        .background(Theme.panel)
        .task(id: addresses) {
            let urls = model.conversation.evidence.map(\.bookmark.url)
            live = Dictionary(await model.store.bookmarks(urls: urls).map { ($0.url, $0) },
                              uniquingKeysWith: { first, _ in first })
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            ScrollView {
                if model.conversation.evidence.isEmpty {
                    Text("Every record read appears here, the ones the answer rests on first.")
                        .font(Theme.sans(12.5)).foregroundStyle(Theme.fainter)
                        .lineSpacing(3).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14).padding(.vertical, 18)
                } else {
                    LazyVStack(spacing: 0) {
                        if !carrying.isEmpty {
                            heading("CARRIES THE ANSWER", count: carrying.count, note: shape)
                            // The group is part of the row's identity: the same
                            // record starts under "found so far" and moves up
                            // once the answer cites it, and without this SwiftUI
                            // reuses the old row and keeps showing the old count.
                            ForEach(carrying) { match in
                                row(match).id("carrying-\(match.bookmark.id)")
                            }
                        }
                        if !read.isEmpty {
                            heading(turn?.working == true ? "FOUND SO FAR" : "READ, NOT USED",
                                    count: read.count,
                                    note: turn?.working == true
                                        ? "Returned by the searches so far."
                                        : "Seen and left out.")
                            ForEach(read) { match in
                                row(match).id("read-\(match.bookmark.id)")
                            }
                        }
                    }
                }
            }
        }
    }

    /// The one action a record earns here, and the standing promise underneath
    /// it. Read-only is the rule this whole screen is built on, so it is said on
    /// the screen rather than assumed.
    private func footer(showing bookmark: Bookmark?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if bookmark != nil {
                // It is already the record in hand, and the Search screen shows
                // whatever that is — so this only has to change screens.
                Button { model.tab = .search } label: {
                    Label2("Show it in Search", filled: false)
                }.buttonStyle(.plain).clickable()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14).padding(.vertical, 9)
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    /// One line saying what the answer is built on, before any record is read.
    private var shape: String {
        guard let turn else { return "" }
        let counts = leaning
        let sentences = turn.parts.filter { !$0.citations.isEmpty }.count
        let scored = carrying.filter { $0.score >= 0 }
        var line = "\(sentences) of \(turn.parts.count) sentences are sourced"
        if let most = counts.values.max(), most > 1 {
            line += ", \(most) of them to a single record"
        }
        if let best = scored.map(\.score).max() {
            line += String(format: ". Best match %.2f", best)
        } else if !carrying.isEmpty {
            line += ". The engine did not report scores"
        }
        return line + "."
    }

    private func heading(_ text: String, count: Int, note: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Marker(text: text)
                Spacer()
                Text("\(count)").font(Theme.mono(10.5))
                    .foregroundStyle(Theme.fainter).monospacedDigit()
            }
            if !note.isEmpty {
                Text(note).font(Theme.sans(11.5)).foregroundStyle(Theme.fainter).lineSpacing(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14).padding(.top, 13).padding(.bottom, 9)
        .background(Theme.bg)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    private func row(_ match: Match) -> some View {
        let bookmark = live[match.bookmark.url] ?? match.bookmark
        return EvidenceRow(match: Match(bookmark: bookmark, score: match.score),
                           number: model.conversation.numbering[match.bookmark.id] ?? 0,
                           leaning: leaning[match.bookmark.id] ?? 0)
    }
}

struct EvidenceRow: View {
    @Environment(AppModel.self) private var model
    let match: Match
    let number: Int
    /// How many sentences of the answer rest on this record. Zero means it was
    /// read and not used.
    var leaning: Int = 0

    var body: some View {
        let open = model.selected?.id == match.bookmark.id
        let b = match.bookmark
        HStack(alignment: .top, spacing: 9) {
            Text(number == 0 ? "·" : "\(number)")
                .font(Theme.mono(10.5))
                .foregroundStyle(open ? Theme.accent : Theme.fainter)
                .frame(width: 22, alignment: .leading).padding(.top, 2)
            Thumbnail(url: b.image, initial: String(b.site.prefix(1)).uppercased(), size: 40)
            VStack(alignment: .leading, spacing: 4) {
                Text(b.displayTitle).font(Theme.sans(12.5))
                    .foregroundStyle(open ? Theme.ink : Theme.dim).lineLimit(open ? 3 : 2)
                HStack(spacing: 7) {
                    Text(b.site).lineLimit(1).truncationMode(.tail)
                    Text(Format.date(b.savedOn)).fixedSize()
                    Spacer(minLength: 0)
                }
                .font(Theme.mono(10.5)).foregroundStyle(Theme.faint).monospacedDigit()
                strength
            }
        }
        .padding(.horizontal, 13).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(open ? Theme.raised : .clear)
        .overlay(alignment: .leading) {
            Rectangle().fill(open ? Theme.accent : .clear).frame(width: 2)
        }
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
        .contentShape(Rectangle())
        .onTapGesture { model.open(b) }
        .clickable()
    }

    /// How well this record answered the question, as a bar rather than a number
    /// alone — the numbers live between 0.30 and 0.70 and a bare "0.58" tells
    /// you nothing unless you already know that. A score below zero means the
    /// engine never reported one, and inventing a bar there would be a lie.
    private var strength: some View {
        HStack(spacing: 6) {
            if match.score < 0 {
                Text("cited · score not reported")
                    .font(Theme.mono(10)).foregroundStyle(Theme.fainter)
            } else {
                GeometryReader { space in
                    let fraction = min(1, max(0.04, (match.score - 0.30) / 0.40))
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Theme.line).frame(height: 3)
                        Rectangle()
                            .fill(match.score >= AppModel.strong ? Theme.accent : Theme.faintest)
                            .frame(width: space.size.width * fraction, height: 3)
                    }
                    .frame(height: 3)
                    .clipShape(RoundedRectangle(cornerRadius: 2))
                }
                .frame(height: 3)
                Text(String(format: "%.2f", match.score))
                    .font(Theme.mono(10)).monospacedDigit()
                    .foregroundStyle(match.score >= AppModel.strong ? Theme.accent : Theme.faint)
                    .frame(width: 26, alignment: .trailing)
            }
            if leaning > 0 {
                // How much of the answer this record carries, next to how well
                // it matched — the two numbers that decide whether to trust it.
                Text(leaning == 1 ? "· 1 sentence" : "· \(leaning) sentences")
                    .font(Theme.mono(10)).foregroundStyle(Theme.accent).fixedSize()
            }
        }
        .padding(.top, 3)
    }
}
