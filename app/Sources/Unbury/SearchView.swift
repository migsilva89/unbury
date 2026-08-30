import SwiftUI
import AppKit
import UnburyCore

struct SearchView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            head
            GeometryReader { space in
                let width = space.size.width
                // Below about eight hundred points a drawer beside the list
                // leaves neither of them room to be read, so the record takes
                // the whole area and escape gives the list back.
                let takesOver = width < 820 && model.selected != nil
                let drawer = takesOver ? width
                                       : drawerWidth(width, showing: model.selected != nil)
                HStack(spacing: 0) {
                    if !takesOver {
                        results(in: CGSize(width: width - drawer, height: space.size.height))
                    }
                    if let selected = model.selected {
                        if !takesOver { Divider().background(Theme.line) }
                        DetailDrawer(bookmark: selected, standalone: takesOver)
                            .frame(width: drawer)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                            // Only the drawer animates. On the whole row it
                            // also animated every result underneath it, so
                            // choosing one link re-ran the list's layout with
                            // a curve on it.
                            .animation(.easeOut(duration: 0.16), value: selected.id)
                    }
                }
            }
        }
        .onAppear { focused = true }
        .deleteConfirmation()
        // Emptying the field puts the screen back to rest. This does NOT search
        // — nothing here ever searches on a keystroke — it only stops a list of
        // answers hanging under a field that no longer asks anything.
        .onChange(of: model.query) { _, text in
            if text.trimmingCharacters(in: .whitespaces).isEmpty, !model.matches.isEmpty {
                model.clearQuestion()
            }
        }
        .focusable()
        .onKeyPress(.upArrow) { move(-1) }
        .onKeyPress(.downArrow) { move(1) }
        .onKeyPress(.return) { openSelected() }
        .onKeyPress(.escape) { back() }
        .onKeyPress(characters: CharacterSet(charactersIn: "/"), phases: .down) { _ in
            focused = true
            return .handled
        }
    }

    /// A third of the window, and never more than 396pt: a record is a column
    /// of text, and a column six hundred points wide is harder to read, not
    /// easier. The floor is 300 — at the smallest window the app allows, that
    /// still leaves the list 640pt, which is enough to keep reading it.
    private func drawerWidth(_ available: CGFloat, showing: Bool) -> CGFloat {
        showing ? min(396, max(300, available * 0.34)) : 0
    }

    private func move(_ step: Int) -> KeyPress.Result {
        let rows = model.visible.isEmpty ? model.browse : model.visible.map(\.bookmark)
        guard !rows.isEmpty else { return .ignored }
        let current = rows.firstIndex { $0.id == model.selected?.id } ?? -1
        model.selected = rows[max(0, min(rows.count - 1, current + step))]
        return .handled
    }

    private func openSelected() -> KeyPress.Result {
        guard let selected = model.selected, let url = URL(string: selected.url)
        else { return .ignored }
        NSWorkspace.shared.open(url)
        return .handled
    }

    /// Escape retreats one step at a time, and the steps are in the order they
    /// were taken: the record, then the funnel, then the question.
    private func back() -> KeyPress.Result {
        if model.selected != nil { model.selected = nil; return .handled }
        if !model.scope.isEmpty { model.clearScope(); return .handled }
        if !model.query.isEmpty { model.clearQuestion(); return .handled }
        return .ignored
    }

    // MARK: the question

    private var head: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 0) {
            // A measure, not the width of the window. Left to itself the row
            // stretched to whatever the display allowed and put the button that
            // means "go" a thousand pixels from the sentence it acts on.
            HStack(alignment: .center, spacing: 12) {
                TextField("Describe what you half-remember…", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(Theme.sans(19, .light))
                    .foregroundStyle(Theme.ink)
                    .focused($focused)
                    .onSubmit { model.search() }
                    .onHover { inside in
                        if inside {
                            NSCursor.iBeam.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                if !model.query.isEmpty {
                    Button { model.clearQuestion() } label: {
                        Text("clear · esc").font(Theme.mono(10.5))
                            .foregroundStyle(Theme.fainter)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.line))
                    }.buttonStyle(.plain).clickable()
                }
                // Searching is deliberate, not a side effect of typing. Half a
                // sentence is not half a question here: a search by meaning
                // reads "that printed part for the" as an idea of its own and
                // answers it, so results used to churn under the fingers. The
                // key still works — the button is here because a key nobody
                // mentioned is not a way in.
                //
                // Tier 1 of the accent scheme: filled accent, the single
                // primary action of the screen, lit only once there is
                // something to ask.
                Button { model.search() } label: {
                    ZStack {
                        Circle().fill(ready ? Theme.accent : Theme.panel)
                            .overlay(Circle().stroke(ready ? .clear : Theme.line))
                        Image(systemName: model.searching ? "ellipsis" : "arrow.right")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(ready ? Theme.bg : Theme.fainter)
                    }
                    .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
                .clickable()
                .disabled(!ready)
                .help(ready ? "Search by meaning  ·  ↵"
                            : "Describe what you are looking for first")
            }
            // Full width, which only works because the button at the far end is
            // a solid accent disc rather than the grey ghost it used to be: at
            // any distance it is still obviously the way on.
            .padding(.leading, 16).padding(.trailing, 8).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.bg))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .stroke(focused ? Theme.accent.opacity(0.55) : Theme.line2))

            if !model.scope.isEmpty { chosen }

            if hasStatusRow { HStack(spacing: 10) {
                Text(status).font(Theme.mono(11)).foregroundStyle(Theme.faint).monospacedDigit()
                if let window = model.window {
                    Text("time · \(window.label)").font(Theme.mono(11))
                        .foregroundStyle(Theme.dim)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Theme.line2))
                }
                Spacer()
                // Two jobs, two names. "Sync" said neither: asked what it
                // meant, nobody could answer without naming both.
                if model.importing {
                    HStack(spacing: 9) {
                        if model.importTotal > 0 {
                            ProgressView(value: Double(model.importDone),
                                         total: Double(model.importTotal))
                                .progressViewStyle(.linear).tint(Theme.accent)
                                .frame(width: 90)
                        }
                        Text(model.importProgress ?? "importing…")
                            .font(Theme.mono(10.5)).foregroundStyle(Theme.faint).lineLimit(1)
                        Button { model.stopImport() } label: {
                            Text("stop").font(Theme.mono(10.5)).foregroundStyle(Theme.dim)
                                .padding(.horizontal, 7).padding(.vertical, 3)
                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.line2))
                        }.buttonStyle(.plain).clickable()
                    }
                } else if let message = model.importProgress {
                    // Importing is not something this screen does — it lives in
                    // the top bar with the rest of the chrome. What is left here
                    // is only the sentence saying how the last one went.
                    Text(message).font(Theme.mono(10.5)).foregroundStyle(Theme.faint)
                        .lineLimit(1)
                }
            }
            .padding(.top, 10).padding(.bottom, 11).padding(.leading, 17) }

            if !model.narrowSuggestions.isEmpty, !model.stale { suggestions }
            if !model.marked.isEmpty { ticked } else if let note = model.deleteNote { deleted(note) }
        }
        .padding(.horizontal, 18).padding(.top, 16)
        .background(Theme.panel)
    }

    /// What is being filtered by, under the field that does the asking. Chosen
    /// tags used to live only in the cloud further down the page, so a person
    /// who had narrowed to one could scroll away from the only thing telling
    /// them why the list was short.
    private var chosen: some View {
        HStack(alignment: .top, spacing: 6) {
            Marker(text: "INSIDE", color: Theme.faintest)
                .padding(.top, 3).fixedSize()
            FlowLayout(spacing: 6, lineSpacing: 6) {
                ForEach(model.scope, id: \.self) { tag in
                    Button { model.widen(from: tag) } label: {
                        HStack(spacing: 5) {
                            Text(tag)
                            Image(systemName: "xmark").font(.system(size: 8, weight: .semibold))
                        }
                        .font(Theme.mono(10.5))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(Theme.accentWash))
                        .overlay(Capsule().stroke(Theme.accentEdge))
                    }
                    .buttonStyle(.plain).clickable()
                    .help("Stop narrowing by \(tag)")
                }
            }
            Button { model.clearScope() } label: {
                Text("clear all").font(Theme.mono(10.5)).foregroundStyle(Theme.faint)
            }
            .buttonStyle(.plain).clickable().fixedSize()
            .padding(.top, 3)
            .help("Search everything again")
        }
        .padding(.top, 11).padding(.leading, 17).padding(.trailing, 8)
    }

    /// Tags carried by what came back. Adding one costs nothing — the question's
    /// vector is already here, so the pile is ranked again without a request.
    private var suggestions: some View {
        HStack(alignment: .top, spacing: 6) {
            Marker(text: "NARROW FURTHER", color: Theme.faintest)
                .padding(.top, 3).fixedSize()
            FlowLayout(spacing: 6, lineSpacing: 6) {
                ForEach(model.narrowSuggestions) { tag in
                Button { model.narrow(to: tag.name) } label: {
                    HStack(spacing: 4) {
                        Text(tag.name); Text("\(tag.count)").opacity(0.55)
                    }
                    .font(Theme.mono(10.5))
                    .foregroundStyle(Theme.dim)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .overlay(Capsule().stroke(Theme.line))
                    }.buttonStyle(.plain).clickable()
                }
            }
        }
        .padding(.bottom, 11).padding(.leading, 27).padding(.trailing, 8)
    }

    /// What has been ticked, and the one thing to do with it.
    ///
    /// Grey outlined in red, never a filled plate: the filled accent on this
    /// screen belongs to the round button that asks the question, and a screen
    /// with two primary actions has stopped saying which one matters. Deleting
    /// is not the thing this screen is for — it is the thing you do to one row
    /// once you have found it.
    private var ticked: some View {
        HStack(spacing: 10) {
            Marker(text: "TICKED", color: Theme.faintest).fixedSize()
            Text("\(model.marked.count) selected")
                .font(Theme.mono(11)).foregroundStyle(Theme.dim).monospacedDigit()
            Spacer()
            Button { model.clearMarks() } label: {
                Text("clear").font(Theme.mono(10.5)).foregroundStyle(Theme.faint)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.line2))
            }.buttonStyle(.plain).clickable()
            Button { model.askToDelete(model.markedBookmarks) } label: {
                Text("Delete \(model.marked.count)").font(Theme.sans(11.5))
                    .foregroundStyle(Theme.bad)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.bad.opacity(0.4)))
            }
            .buttonStyle(.plain).clickable()
            .help("Delete from Unbury — your browser is never touched")
        }
        .padding(.top, 11).padding(.leading, 17).padding(.trailing, 4).padding(.bottom, 4)
    }

    /// Said once, after something has gone, because a row disappearing is not by
    /// itself an explanation of what happened to the copy in the browser.
    private func deleted(_ note: String) -> some View {
        Text(note).font(Theme.mono(10.5)).foregroundStyle(Theme.faint)
            .padding(.top, 4).padding(.leading, 17).padding(.bottom, 6)
    }

    // MARK: the results

    @ViewBuilder private func results(in space: CGSize) -> some View {
        // An empty vault is not a short list, it is the whole screen. Inside a
        // scrolling region it would be proposed an unbounded height and could
        // never fill the window, so it is handed the space and scrolls itself.
        if model.count == 0, model.searchError == nil {
            FirstRun(space: space)
        } else {
            scrolling(in: space)
        }
    }

    private func scrolling(in space: CGSize) -> some View {
        ScrollViewReader { list in
        ScrollView {
            Group {
                if let error = model.searchError {
                    failed(error)
                } else if model.query.isEmpty {
                    browsing(in: space)
                } else if model.searching && model.visible.isEmpty {
                    searchingRows
                } else if model.visible.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        nothingMatched
                        Divider().background(Theme.line).padding(.top, 34)
                        Marker(text: "OR START FROM A WORD YOU ALREADY USE",
                               color: Theme.faintest)
                            .padding(.top, 26).padding(.leading, Metric.gutter)
                        Vocabulary(space: CGSize(width: space.width,
                                                 height: space.height - 290),
                                   heading: false)
                            .padding(.top, -30)
                    }
                } else {
                    ranked
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .id(Self.listTop)
            .padding(.bottom, 40)
        }
        .frame(maxWidth: .infinity)
        // When the question field loses the keyboard, focus lands on the list
        // and macOS draws its focus ring around the whole scrolling region — a
        // rounded rectangle around half the window, which reads as a stray box
        // rather than as "the list is focused". The rows say which one is
        // selected themselves.
        .focusEffectDisabled()
        .noScrollEdge()
        // The list is asked to move from one place, and only ever to a row it
        // is already holding. Changing the funnel is the product reason: a new
        // set of links must not open half way down the last one.
        .onChange(of: model.scrollRequest) { _, request in
            guard let request else { return }
            switch request {
            case .top: list.scrollTo(Self.listTop, anchor: .top)
            case let .record(id): list.scrollTo(id, anchor: .top)
            }
            model.scrollRequest = nil
        }
        }
    }

    /// What "the top of the list" means to `ScrollViewReader`.
    static let listTop = "top-of-list"


    /// At rest: the vocabulary, and — once something is narrowed to — the links
    /// inside it, a page at a time.
    ///
    /// The cloud sits outside the lazy stack on purpose. A `LazyVStack` measures
    /// and places its children itself, and handing it a flow layout holding a
    /// thousand tags is what put fourteen seconds into `LazyStack.place`.
    private func browsing(in space: CGSize) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Vocabulary(space: space)
            if !model.scope.isEmpty {
                listLabel("\(model.scopeCount) \(model.scopeCount == 1 ? "LINK" : "LINKS") HERE · NEWEST FIRST")
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.browse) { bookmark in
                        Row(match: Match(bookmark: bookmark, score: -1),
                            selected: model.selected?.id == bookmark.id,
                            narrowed: model.scopeSet)
                    }
                }
                if model.hasMore { loadMore } else if model.atCeiling { ceiling }
            }
        }
    }

    private var ranked: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.stale { diverged }
            listLabel(label(model.showWeak ? "WEAK MATCHES — SHOWN ON REQUEST"
                                           : "RANKED BY MEANING"))
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(model.visible) { match in
                    Row(match: match,
                        selected: model.selected?.id == match.bookmark.id,
                        narrowed: model.scopeSet)
                }
            }
            if model.withheld > 0 { withheldNote }
        }
        // Not current, and it should not look current. Still readable, still
        // clickable — these are real records — but plainly not the answer to
        // what the field now says.
        .opacity(model.stale ? 0.45 : 1)
    }

    /// Every list of results carries the question it answers, so a count can
    /// never be read as belonging to text nobody has asked about.
    private func label(_ heading: String) -> String {
        model.stale && !model.askedQuery.isEmpty
            ? heading + " · FOR “\(shorten(model.askedQuery))”" : heading
    }

    private func shorten(_ text: String) -> String {
        text.count <= 44 ? text : String(text.prefix(42)) + "…"
    }

    /// Said in full, above the list, the moment the field stops matching it.
    private var diverged: some View {
        HStack(alignment: .top, spacing: 10) {
            Rectangle().fill(Theme.faintest).frame(width: 2, height: 30)
            VStack(alignment: .leading, spacing: 4) {
                Marker(text: "NOT WHAT THE FIELD SAYS", color: Theme.fainter)
                Text("These answer “\(shorten(model.askedQuery))” — press ↵ to ask what the field says now.")
                    .font(Theme.mono(11)).foregroundStyle(Theme.faint)
            }
        }
        .padding(.init(top: 16, leading: Metric.rail, bottom: 0, trailing: Metric.gutter))
    }

    /// The rest of a tag, on request. A list that runs to the end of a tag with
    /// nine hundred links in it is not a list anybody reads — and drawing it is
    /// what froze the window.
    private var loadMore: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button {
                Task { await model.loadMore() }
            } label: {
                Label2(model.loadingMore ? "Loading…"
                       : "Show \(min(AppModel.pageSize, model.scopeCount - model.browse.count)) more",
                       filled: false)
            }
            .buttonStyle(.plain).clickable()
            .disabled(model.loadingMore)
            Text("\(model.browse.count) of \(model.scopeCount) shown")
                .font(Theme.mono(11)).foregroundStyle(Theme.fainter).monospacedDigit()
        }
        .padding(.top, 16).padding(.leading, Metric.rail)
    }

    /// What the list says when it has drawn as much as it will. The way on is
    /// another tag or a question, not more rows.
    private var ceiling: some View {
        HStack(spacing: 6) {
            Text("Newest \(AppModel.ceiling) of \(model.scopeCount) — narrow with a tag, or describe the one you want.")
                .font(Theme.mono(11)).foregroundStyle(Theme.faint)
        }
        .padding(.init(top: 18, leading: Metric.rail, bottom: 0, trailing: Metric.gutter))
    }

    private func listLabel(_ text: String) -> some View {
        Marker(text: text)
            .padding(.init(top: 14, leading: Metric.gutter, bottom: 6, trailing: Metric.gutter))
    }

    /// Waiting has the shape of the answer. Three rows on the same grid keep the
    /// list from jumping when the real ones land, and say the wait is the search
    /// working rather than the screen being broken.
    private var searchingRows: some View {
        VStack(alignment: .leading, spacing: 0) {
            listLabel("SEARCHING BY MEANING")
            ForEach(0..<3, id: \.self) { index in
                GhostRow(delay: Double(index) * 0.12)
            }
        }
    }

    private func failed(_ error: String) -> some View {
        Notice(title: "The search could not run.", body: error,
               marker: "SEARCH FAILED", tone: Theme.bad) {
            Button { model.search() } label: { Label2("Try again", filled: true) }
                .buttonStyle(.plain).clickable()
            Button { model.clearQuestion() } label: {
                Label2("Start over", filled: false)
            }.buttonStyle(.plain).clickable()
        }
    }

    private var withheldNote: some View {
        HStack(spacing: 6) {
            Text("\(model.withheld) weak matches withheld")
                .font(Theme.mono(11)).foregroundStyle(Theme.faint)
            Button { model.revealWeak() } label: {
                Text("show them").font(Theme.mono(11)).underline().foregroundStyle(Theme.dim)
            }.buttonStyle(.plain).clickable().fixedSize()
        }
        .padding(.init(top: 16, leading: Metric.rail, bottom: 0, trailing: Metric.gutter))
    }

    private var nothingMatched: some View {
        let best = model.matches.first?.score ?? 0
        let searched = model.scope.isEmpty ? "\(model.count) records"
                                           : "\(model.scopeCount) records inside \(model.scope.joined(separator: " + "))"
        let body: String = {
            if let window = model.window {
                // With a window on, `matches` is already cut down to it — so an
                // empty list means the dates emptied it, not the meaning, and
                // quoting a best score of 0.00 would blame the wrong thing.
                if model.matches.isEmpty {
                    return "Nothing at all was saved in \(window.label). The dates emptied the list before meaning came into it."
                }
                return "Nothing saved in \(window.label) is about this. Best inside it: \(String(format: "%.2f", best))."
            }
            if best >= 0.35 {
                return "\(searched) searched. The closest came in at \(String(format: "%.2f", best)) — close, but not enough to trust. Try describing what it did, not what it was called."
            }
            return "\(searched) searched. The best was \(String(format: "%.2f", best)) — nothing here is about this."
        }()
        return Notice(title: "Nothing here matches that well.", body: body,
                      marker: "NO CONFIDENT MATCH") {
            Button { model.revealWeak() } label: {
                Label2("Show 3 weak matches anyway", filled: true)
            }.buttonStyle(.plain).clickable()
            // Widening the funnel sends nothing: the question's vector is
            // already here, so the same sentence is ranked again on this Mac.
            if !model.scope.isEmpty {
                Button { model.clearScope() } label: {
                    Label2("Search everything", filled: false)
                }.buttonStyle(.plain).clickable()
            }
            // The time phrase is part of the sentence he typed, so dropping the
            // filter means taking those words back out of the question.
            if let window = model.window {
                Button {
                    model.query = window.strip(from: model.query)
                    model.search()
                } label: { Label2("Search all time", filled: false) }.buttonStyle(.plain).clickable()
            }
            Button { model.clearQuestion() } label: {
                Label2("Start over", filled: false)
            }.buttonStyle(.plain).clickable()
        }
    }

    // MARK: plumbing

    /// There is something to ask, and nothing already being asked.
    private var ready: Bool {
        !model.query.trimmingCharacters(in: .whitespaces).isEmpty && !model.searching
    }

    private var hasStatusRow: Bool {
        !status.isEmpty || model.window != nil || model.importing
            || model.importProgress != nil
    }

    private var status: String {
        if model.searching { return "searching by meaning…" }
        if model.count == 0 { return "nothing saved here yet" }
        if model.query.isEmpty {
            if model.scope.isEmpty {
                return ""
            }
            return "\(model.scopeCount) here"
        }
        if model.stale { return "not searched yet · press ↵ to ask what you typed" }
        let rows = model.visible
        if rows.isEmpty { return "no confident match" }
        return "\(rows.count) \(rows.count == 1 ? "match" : "matches") · best \(String(format: "%.2f", rows[0].score))"
    }
}

/// One result. The three columns — picture, what it is, how well it answered —
/// sit on the same grid in every row, and all three hang off the title's
/// baseline, so the dates and scores read as a column rather than as decoration
/// scattered down the right-hand side.
///
/// Everything it draws arrives as a value. Reading the model from inside a row
/// meant that choosing one link invalidated all of them, and a list of a few
/// hundred re-laid itself out on every click and every hover.
struct Row: View {
    @Environment(AppModel.self) private var model
    let match: Match
    let selected: Bool
    let narrowed: Set<String>
    @State private var hovering = false

    private var scoring: Bool { match.score >= 0 }
    private var strong: Bool { match.score >= AppModel.strong }

    var body: some View {
        let b = match.bookmark
        HStack(alignment: .rowTitle, spacing: Metric.column) {
            tick(b)
                .alignmentGuide(.rowTitle) { _ in Metric.titleBaseline }
            Thumbnail(url: b.image, initial: String(b.site.prefix(1)).uppercased(),
                      size: Metric.thumb)
                .alignmentGuide(.rowTitle) { _ in Metric.titleBaseline }
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(b.displayTitle).font(Theme.sans(13.5, .medium))
                        .foregroundStyle(b.title.isEmpty ? Theme.dim : Theme.ink)
                        .lineLimit(1)
                    if b.title.isEmpty {
                        note("no title · from description")
                    }
                    // A link the browser no longer has is still a record here,
                    // and still an answer. Grey, and stated once: a colour that
                    // means "wrong" would be a lie about a link that works.
                    if b.isGoneFromBrowser {
                        note("no longer in your browser")
                    }
                }
                Text(b.summary).font(Theme.sans(12.5)).foregroundStyle(Theme.dim)
                    .lineLimit(1).padding(.top, 4)
                HStack(spacing: 6) {
                    ForEach(b.tags.prefix(5), id: \.self) { tag in
                        let on = narrowed.contains(tag)
                        Text(tag).font(Theme.mono(10))
                            .foregroundStyle(on ? Theme.accent : Theme.faint)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .overlay(Capsule().stroke(on ? Theme.accentEdge : Theme.line2))
                    }
                }.padding(.top, 7).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            meta
        }
        .frame(height: Metric.rowHeight)
        .padding(.leading, Metric.rail).padding(.trailing, Metric.gutter)
        .background(selected ? Theme.raised : hovering ? Theme.panel.opacity(0.6) : .clear)
        .overlay(alignment: .leading) {
            Rectangle().fill(selected ? (strong ? Theme.accent : Theme.faintest) : .clear)
                .frame(width: 2)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { model.select(match.bookmark) }
        .clickable()
    }

    /// The box that ticks a row for deleting. It holds its 14 points whether it
    /// is drawn or not, so pointing at a row cannot make the whole list shuffle
    /// sideways — and it only appears once the pointer is on the row or
    /// something is already ticked, because a list of results is for reading
    /// first and deleting second.
    @ViewBuilder private func tick(_ b: Bookmark) -> some View {
        let on = model.marked.contains(b.id)
        Group {
            if hovering || on || !model.marked.isEmpty {
                Button { model.toggleMark(b.id) } label: {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(on ? Theme.bad.opacity(0.18) : .clear)
                        .overlay(RoundedRectangle(cornerRadius: 3)
                            .stroke(on ? Theme.bad.opacity(0.7) : Theme.line2))
                        .overlay {
                            if on {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(Theme.bad)
                            }
                        }
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).clickable()
                .help(on ? "Untick this link" : "Tick this link to delete it")
            } else {
                Color.clear.frame(width: 14, height: 14)
            }
        }
        .frame(width: 14)
    }

    private func note(_ text: String) -> some View {
        Text(text).font(Theme.mono(9.5))
            .foregroundStyle(Theme.fainter)
            .padding(.horizontal, 4).padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Theme.line2))
            .layoutPriority(1)
    }

    // How well it answered, over where it came from — the two things worth
    // reading down a column. A row that was never scored (a list inside a tag)
    // says the date instead, because a dead gauge is worse than no gauge.
    private var meta: some View {
        VStack(alignment: .trailing, spacing: 0) {
            if scoring {
                Text(String(format: "%.2f", match.score))
                    .font(Theme.mono(14))
                    .foregroundStyle(strong ? Theme.accent
                                     : match.score >= AppModel.confident ? Theme.dim : Theme.fainter)
            } else {
                Text(Format.date(match.bookmark.savedOn))
                    .font(Theme.mono(11)).foregroundStyle(Theme.faint)
            }
            Text(match.bookmark.site)
                .font(Theme.mono(10)).foregroundStyle(Theme.fainter)
                .lineLimit(1).padding(.top, 5)
        }
        .frame(width: Metric.meta, alignment: .trailing)
        .monospacedDigit()
    }
}

/// A row that has not arrived yet. Same grid, same heights, no content — so the
/// list holds still while the search runs instead of collapsing and reflowing.
struct GhostRow: View {
    let delay: Double
    @State private var lit = false

    var body: some View {
        HStack(alignment: .top, spacing: Metric.column) {
            bar(width: Metric.thumb, height: Metric.thumb, radius: 5)
            VStack(alignment: .leading, spacing: 7) {
                bar(width: 210, height: 9)
                bar(width: 330, height: 8)
                bar(width: 120, height: 7)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 7) {
                bar(width: 54, height: 8)
                bar(width: 30, height: 8)
            }
            .frame(width: Metric.meta, alignment: .trailing)
        }
        .frame(height: Metric.rowHeight)
        .padding(.leading, Metric.rail).padding(.trailing, Metric.gutter)
        .opacity(lit ? 0.75 : 0.35)
        .task {
            try? await Task.sleep(for: .seconds(delay))
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                lit = true
            }
        }
    }

    private func bar(width: CGFloat, height: CGFloat, radius: CGFloat = 2) -> some View {
        RoundedRectangle(cornerRadius: radius).fill(Theme.line)
            .frame(width: width, height: height)
    }
}

enum Format {
    static let months = ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"]
    static func date(_ iso: String) -> String {
        let parts = iso.split(separator: "-")
        guard parts.count == 3, let month = Int(parts[1]), month >= 1, month <= 12 else { return "—" }
        return "\(parts[2]) \(months[month - 1]) \(parts[0].suffix(2))"
    }
    /// How long ago, in the largest unit that still says something true. Months
    /// alone rounded everything saved this week down to "0 mo", which is worse
    /// than saying nothing.
    static func ago(_ iso: String) -> String {
        let format = DateFormatter(); format.dateFormat = "yyyy-MM-dd"
        guard let then = format.date(from: iso) else { return "—" }
        let days = max(0, Int(Date().timeIntervalSince(then) / 86400))
        if days < 1 { return "today" }
        if days < 60 { return "\(days) d" }
        if days <= 500 { return "\(days / 30) mo" }
        return String(format: "%.1f yr", Double(days) / 365)
    }
}
