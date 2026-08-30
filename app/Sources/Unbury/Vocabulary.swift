import SwiftUI
import UnburyCore

/// The resting home screen: the words this collection is actually made of.
///
/// It replaced a list of the fourteen most recently saved links, which was the
/// one list nobody needs — a person remembers what they saved this week. What
/// they cannot remember is what is buried, which is the whole name of the app.
///
/// Searching here means writing a description, and the hard part is the first
/// word in front of an empty field. So the screen hands over the person's own
/// vocabulary to start from — all of it, and none of it leaves the Mac. Reaching
/// a tag must never depend on the network, or a person browses their own library
/// with one eye on the meter.
struct Vocabulary: View {
    @Environment(AppModel.self) private var model
    /// How much room the screen has to fill. A tall window showing fifty tags
    /// above four hundred points of black is the app not using what it was
    /// given, so the first handful is however many the window can hold.
    let space: CGSize
    /// Whether to name itself. Under another screen's heading — "or start from a
    /// word you already use" — a second title is just noise.
    var heading = true
    @State private var deck: [Chip] = []
    @State private var limit = 0
    /// Whether the person has asked for more than the window holds. Until they
    /// do, resizing re-fits the cloud; afterwards it keeps what they asked for.
    @State private var expanded = false
    @State private var dealt: [String] = []
    @FocusState private var filtering: Bool

    /// The rest of the vocabulary arrives in steps this size.
    private static let step = 150
    /// What is left of the height once the heading, the tail and the margins
    /// have taken their share, and roughly how much room one line of tags needs.
    /// Left a little short on purpose: filling the window to the last pixel
    /// leaves the fold across the middle of a line of tags, which reads as
    /// clipping rather than as more to scroll.
    private static let chrome: CGFloat = 232
    /// The padding inside a chip's box, undone so the cloud lines up.
    private static let chipInset: CGFloat = 14
    private static let lineHeight: CGFloat = 44

    /// One tag as it will be drawn, including which of three sizes its pill is.
    ///
    /// THREE, and no more. A size per tag is a word cloud — a picture standing in
    /// for a number that is already printed inside the pill — and it was thrown
    /// out for looking amateurish. Three steps is not a picture: it is a heavy,
    /// a middle and a light, which the eye sorts without reading a single count.
    ///
    /// The step is worked out when the deck is dealt, never in `body`: a pill
    /// that sorted the whole vocabulary to find its own size turned fifty tags
    /// into fifty sorts per frame, which is where the fourteen-second freeze
    /// came from.
    private struct Chip: Identifiable, Equatable {
        let name: String
        let count: Int
        let step: Int
        var id: String { name }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            head
            // A chip's box is padded, so its word starts 9pt in. Pulled back by
            // the same 9pt the first tag of every line sits on the same left
            // edge as the headings above and below it.
            field.padding(.top, 22)
            more
            tail
        }
        // The same left edge as the list of links below it. Two margins on one
        // screen reads as two screens that happen to be stacked.
        .padding(.horizontal, Metric.gutter)
        // The same air whether or not something is chosen. Changing the
        // padding on the click that chooses moved everything under the cursor,
        // on top of the field itself already being replaced.
        .padding(.top, 32)
        .padding(.bottom, 26)
        // The counts arrive after the first draw — the vault is read off the
        // main actor — so dealing only on appear dealt from an empty deck.
        .onAppear { limit = fits; rebuild(); if dealt.isEmpty { deal() } }
        .onChange(of: model.tags) { _, _ in if !expanded { limit = fits }; rebuild(); deal() }
        .onChange(of: model.reachable) { _, _ in expanded = false; limit = fits; rebuild() }
        .onChange(of: space) { _, _ in if !expanded { limit = fits }; rebuild() }
        .onChange(of: model.tagFilter) { _, _ in expanded = false; limit = fits; rebuild() }
    }

    // MARK: - the deck

    /// Which vocabulary this screen is showing: everything, or — once something
    /// has been narrowed to — only the tags that still lead somewhere.
    private var source: [Tag] {
        model.scope.isEmpty ? model.tags : model.reachable
    }

    /// Alphabetical, always. Sorted by count it would be a chart of a top fifty;
    /// alphabetical, the size is left to say what the count is and the eye reads
    /// the shape instead of a ranking.
    private func rebuild() {
        let taken = Array(pool.prefix(max(limit, 1)))
        // On a log scale, not a straight one. One tag with 113 links against a
        // tail of fours puts everything else in the bottom step, and a scale
        // with one pill in the top and four hundred in the bottom says nothing.
        let peak = Double(taken.map(\.count).max() ?? 1)
        deck = taken.map { tag in
            let share = peak > 1
                ? log(Double(max(tag.count, 1))) / log(peak) : 0
            return Chip(name: tag.name, count: tag.count,
                        step: share >= 0.78 ? 2 : share >= 0.5 ? 1 : 0)
        }
        .sorted { $0.name < $1.name }
    }

    /// How many tags this window can hold, packed the way the flow layout will
    /// pack them. An estimate of each word's width rather than a measurement:
    /// asking SwiftUI would mean laying the cloud out to find out how much of it
    /// to lay out, and the answer only has to be close — the button underneath
    /// catches whatever is left over.
    private var fits: Int {
        let width = space.width - Metric.gutter * 2
        let lines = Int((space.height - Self.chrome) / Self.lineHeight)
        guard width > 120, lines > 0 else { return 24 }
        // Every pill is set at one size, so the guess is off by the width of a
        // letter rather than by a whole line.
        let size = Theme.size(14)
        var used: CGFloat = 0, line = 1, taken = 0
        for tag in pool {
            let guess = CGFloat(tag.name.count) * size * 0.56
                + CGFloat("\(tag.count)".count) * 8 + 52
            if used + guess > width, used > 0 {
                line += 1
                if line > lines { break }
                used = 0
            }
            used += guess
            taken += 1
        }
        return max(24, taken)
    }

    /// The vocabulary this screen is drawing from, filtered but not yet cut.
    private var pool: [Tag] {
        let wanted = model.tagFilter.trimmingCharacters(in: .whitespaces).lowercased()
        return wanted.isEmpty ? source : source.filter { $0.name.contains(wanted) }
    }

    private var matching: Int { pool.count }

    // MARK: - the screen

    private var head: some View {
        HStack(alignment: .firstTextBaseline) {
            if heading { Marker(text: title, color: Theme.faintest) }
            Spacer()
            finder
        }
    }

    private var title: String {
        if !model.tagFilter.isEmpty { return "\(matching) OF \(source.count) TAGS MATCH" }
        if !model.scope.isEmpty { return "\(source.count) TAGS STILL REACHABLE FROM HERE" }
        return "YOUR VOCABULARY · \(model.tagCount) TAGS"
    }

    /// A thousand tags cannot all be shown and none of them may be out of reach.
    /// Typing here filters the whole vocabulary on this Mac — no model, no key,
    /// no network — which is the difference the caption is there to say out loud.
    private var finder: some View {
        @Bindable var model = model
        return HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").font(.system(size: 10))
                .foregroundStyle(Theme.fainter)
            TextField("find a tag", text: $model.tagFilter)
                .textFieldStyle(.plain).font(Theme.mono(11))
                .foregroundStyle(Theme.ink2).focused($filtering)
                .frame(width: 130)
            if !model.tagFilter.isEmpty {
                Button { model.tagFilter = "" } label: {
                    Image(systemName: "xmark").font(.system(size: 9))
                        .foregroundStyle(Theme.faint)
                }.buttonStyle(.plain).clickable()
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 7)
            .stroke(filtering ? Theme.accentEdge : Theme.line))
    }

    @ViewBuilder private var field: some View {
        if deck.isEmpty {
            // A filter that matches nothing must say so. An empty gap under a
            // heading reads as a screen that failed to draw.
            VStack(alignment: .leading, spacing: 7) {
                Text("No tag here is called “\(model.tagFilter)”.")
                    .font(Theme.sans(14)).foregroundStyle(Theme.ink)
                Text(nothingFound)
                    .font(Theme.mono(11)).foregroundStyle(Theme.fainter)
                Button { model.tagFilter = "" } label: {
                    Label2("Show every tag", filled: false)
                }
                .buttonStyle(.plain).clickable().padding(.top, 7)
            }
            .padding(.vertical, 10)
        } else {
            // A pill's box is padded, so its word starts 11pt in. Pulled back by
            // the same 11pt, the first tag of every line sits on the same left
            // edge as the headings above and below it.
            FlowLayout(spacing: 10, lineSpacing: 10) {
                ForEach(deck) { chip in
                    TagPill(name: chip.name, count: chip.count, step: chip.step,
                            chosen: model.scopeSet.contains(chip.name))
                }
            }
            .padding(.leading, -Self.chipInset)
            // Choosing a tag replaces the whole field with the tags still
            // reachable from it. Redrawn instantly that reads as the page
            // breaking under the cursor; over a fifth of a second it reads as
            // the field answering.
            .animation(.easeInOut(duration: 0.2), value: deck)
        }
    }

    private var nothingFound: String {
        model.scope.isEmpty
            ? "Tags come from what the model called each link — the word you want may be phrased differently. Describe the link itself in the field above."
            : "Only \(source.count) tags are reachable inside \(model.scope.joined(separator: " + ")). Remove one to widen the field."
    }

    /// The rest of the vocabulary, in the same size step. Everything is
    /// reachable this way; nothing is hidden behind a paid search.
    @ViewBuilder private var more: some View {
        let left = matching - deck.count
        if left > 0 {
            HStack(spacing: 10) {
                Text("\(left) more")
                    .font(Theme.mono(11)).foregroundStyle(Theme.fainter)
                step(by: min(Self.step, left), "show \(min(Self.step, left)) more")
                // The whole vocabulary in one go, because "every tag is
                // reachable" is not true if it takes three presses to get there.
                if left > Self.step { step(by: left, "show all \(matching)") }
            }
            .padding(.top, 22)
        }
    }

    private func step(by amount: Int, _ label: String) -> some View {
        Button {
            expanded = true
            limit += amount
            rebuild()
        } label: {
            Text(label).font(Theme.mono(10.5)).foregroundStyle(Theme.faint)
                .padding(.horizontal, 9).padding(.vertical, 4)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.line2))
        }
        .buttonStyle(.plain).clickable()
    }

    // MARK: - the tail

    /// Hundreds of tags carry exactly one link. Hiding them is a lie about the
    /// collection and listing them is noise, so five are dealt at random: an
    /// honest account, and a reason to open the app when looking for nothing.
    @ViewBuilder private var tail: some View {
        if !model.singletons.isEmpty, model.scope.isEmpty, model.tagFilter.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                Text("\(model.singletons.count) tags hold a single link")
                    .font(Theme.mono(11)).foregroundStyle(Theme.fainter)
                FlowLayout(spacing: 22, lineSpacing: 10) {
                    ForEach(dealt, id: \.self) { tag in
                        Button { model.narrow(to: tag) } label: {
                            Text(tag).font(Theme.sans(13)).foregroundStyle(Theme.dim)
                        }
                        .buttonStyle(.plain).clickable()
                        .help("One link carries this")
                    }
                    Button { deal() } label: {
                        Text("deal five").font(Theme.mono(10.5))
                            .foregroundStyle(Theme.faint)
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.line2))
                    }.buttonStyle(.plain).clickable()
                }
            }
            .padding(.top, 46)
        }
    }

    private func deal() {
        dealt = model.singletons.shuffled().prefix(5).sorted()
    }
}

/// One tag, as a pill. Every pill is the same size and carries the same edge,
/// so the field reads as a set of controls rather than as a word cloud — twelve
/// sizes of type said with a picture what the number inside already says.
///
/// Its own view, and its own hover state, because a `hovered` flag held by the
/// field invalidated all four hundred of them — and with them the whole flow
/// layout — every time the pointer crossed one.
private struct TagPill: View {
    @Environment(AppModel.self) private var model
    let name: String
    let count: Int
    /// 0, 1 or 2 — see `Vocabulary.Chip`. The whole pill grows, not just the
    /// word: a bigger word inside the same box reads as a typo.
    let step: Int
    let chosen: Bool
    @State private var hovering = false

    private var nameSize: CGFloat { [12.5, 14, 15.5][step] }
    private var countSize: CGFloat { [10, 11, 12][step] }
    private var padH: CGFloat { [12, 14, 16][step] }
    private var padV: CGFloat { [6, 8, 9][step] }

    var body: some View {
        Button {
            if chosen { model.widen(from: name) } else { model.narrow(to: name) }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(name)
                    .font(Theme.sans(nameSize, chosen || step == 2 ? .medium : .regular))
                    .foregroundStyle(chosen ? Theme.accent : hovering ? Theme.ink : Theme.ink2)
                    .lineLimit(1)
                Text("\(count)").font(Theme.mono(countSize))
                    .foregroundStyle(chosen ? Theme.accent.opacity(0.75)
                                            : step == 2 ? Theme.faint : Theme.fainter)
                    .monospacedDigit()
            }
            .padding(.horizontal, padH).padding(.vertical, padV)
            .background(Capsule().fill(chosen ? Theme.accentWash
                                              : hovering ? Theme.panel : .clear))
            .overlay(Capsule().stroke(chosen ? Theme.accentEdge
                                             : hovering ? Theme.line2 : Theme.line))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain).clickable()
        .onHover { hovering = $0 }
        .help(chosen ? "Stop narrowing by \(name)"
                     : "Narrow to the \(count) links tagged \(name)")
    }
}
