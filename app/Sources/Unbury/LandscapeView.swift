import AppKit
import SwiftUI
import UnburyCore

/// A short accent rule that opens a section. Colour used as structure — it
/// says "a new thing starts here", never "this one is selected".
struct SectionRule: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 1).fill(Theme.accent)
            .frame(width: 3, height: 13)
    }
}

/// The collection seen whole. It reads rather than controls: the only thing you
/// can ask it is "what is that bar made of", and the only thing you can change
/// is which link you open.
///
/// Everything drawn here is worked out once, in `compute`, and nothing is
/// worked out again while drawing. That is not tidiness: the version of this
/// screen that filtered six hundred records inside `body` to fill its panel ran
/// that filter on every pointer move, because the hover state lived up here and
/// invalidated the whole page. Hover now belongs to the row it lights, and the
/// panel is a dictionary lookup.
struct LandscapeView: View {
    @Environment(AppModel.self) private var model
    @State private var shape: Shape?
    @State private var focus: Focus?

    /// Every bar in here belongs to one of three slices of the collection, and
    /// picking one is the whole of the interaction.
    enum Focus: Hashable { case month(String), site(String), tag(String) }

    struct Finding: Identifiable {
        let id: Int
        let number: String
        let line: String
    }

    /// A named bar and how many links stand behind it. Months carry their key
    /// — `2026-03` — rather than their name, because the key is what sorts and
    /// what the links are grouped under.
    struct Bar: Identifiable {
        let name: String
        let count: Int
        var id: String { name }
    }

    struct Shape {
        var months: [Bar]
        var years: [Bar]
        var sites: [Bar]
        var tags: [Bar]
        var sitesOnce: Int
        var distinctTags: Int
        var tagsPerLink: Double
        var firstSaved: String
        var days: Int
        var oldest: [Bookmark]
        var findings: [Finding]
        var medianMonth: Int
        var busiestMonth: String
        /// The links behind every bar that can be picked, newest first and
        /// grouped once. Opening a panel is then a lookup rather than a scan.
        var inside: [Focus: [Bookmark]]
    }

    /// How many bars each column lists. The same number for both, because two
    /// columns of different lengths side by side read as one of them having
    /// failed to finish.
    private static let barsShown = 10
    /// The widest a single month is drawn. Without it a library saved inside
    /// one month is a chart with one bar a thousand points wide, which is a
    /// block of colour rather than a shape.
    private static let monthWidth: CGFloat = 30
    /// Below this many months the series has no shape worth drawing, and a
    /// median taken from a handful of them is not a fact.
    private static let monthsWorthCharting = 3
    private static let monthsWorthAMedian = 6
    /// Below this many links "the oldest six" is most of the library rather
    /// than the bottom of it.
    private static let oldestWorthListing = 12

    private let sidePadding: CGFloat = 40
    private let maxContentWidth: CGFloat = 1320

    var body: some View {
        GeometryReader { geometry in
            // The month axis is positioned by arithmetic rather than by letting
            // the stack divide the space, so the year ticks land on the same
            // pixels as the bars. That needs the content width up front.
            let content = max(420, min(geometry.size.width, maxContentWidth) - sidePadding * 2)
            let wide = content >= 1020
            ScrollView {
                // One measure for every state. An empty screen that starts at a
                // different left edge from the full one reads as a different
                // screen rather than the same one with nothing in it.
                Group {
                    if model.count == 0 {
                        nothingYet
                    } else if let shape {
                        page(shape, content: content, wide: wide)
                            .padding(.top, 30).padding(.bottom, 70)
                    } else {
                        reading
                    }
                }
                .frame(width: content, alignment: .leading)
                .padding(.horizontal, sidePadding)
            }
            // Centred rather than pinned left. The page stops widening at
            // 1320pt because a line of text wider than that is not read, and
            // left-aligned that left a quarter of a large window empty on one
            // side only, which reads as the screen having slipped.
            .frame(maxWidth: .infinity)
        }
        // Keyed on the vault's revision: this whole picture is counts of what is
        // stored, and after a link is deleted a picture worked out once when the
        // screen appeared is a count of something that is not there any more.
        .task(id: model.revision) { shape = await compute() }
    }

    private func page(_ shape: Shape, content: CGFloat, wide: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            headline(shape)
            tiles(shape).padding(.top, 22)
            if !shape.findings.isEmpty { stands(shape, wide: wide).padding(.top, 30) }
            if shape.months.count >= Self.monthsWorthCharting {
                when(shape, width: content).padding(.top, 36)
                if case .month = focus { reveal(shape, width: content, wide: wide).padding(.top, 16) }
            }
            HStack(alignment: .top, spacing: wide ? 38 : 22) {
                bars("Where it came from", "\(model.siteCount) distinct sites",
                     shape.sites, kind: { .site($0) }, wide: wide, content: content,
                     note: shape.sitesOnce > 0
                        ? "\(shape.sitesOnce) sites appear exactly once."
                        : nil)
                bars("What you collect", "\(shape.distinctTags) tags · \(String(format: "%.1f", shape.tagsPerLink)) per link",
                     shape.tags, kind: { .tag($0) }, wide: wide, content: content,
                     note: shape.distinctTags > Self.barsShown
                        ? "A handful cover most of it; the rest appear once or twice."
                        : nil)
            }.padding(.top, 36)
            if isRowFocus { reveal(shape, width: content, wide: wide).padding(.top, 18) }
            if shape.oldest.count >= 6 { oldest(shape, wide: wide).padding(.top, 38) }
            if let waiting = tooYoungFor(shape) {
                // A young library leaves half this page out, and half a page
                // above a field of black reads as a screen that failed to
                // finish drawing. Saying what is missing, and why, turns it
                // back into a state.
                Text(waiting).font(Theme.sans(12.5)).foregroundStyle(Theme.faint)
                    .lineSpacing(2).frame(maxWidth: 620, alignment: .leading)
                    .padding(.top, 40)
            }
        }
    }

    /// What this screen is still too young to say. Nil once it says everything.
    private func tooYoungFor(_ shape: Shape) -> String? {
        let noChart = shape.months.count < Self.monthsWorthCharting
        let noOldest = shape.oldest.isEmpty
        guard noChart || noOldest else { return nil }
        let missing = noChart && noOldest ? "when you saved things, and what the oldest of them are,"
            : noChart ? "when you saved things" : "what the oldest things in here are"
        return "There is more to draw than this. The part about \(missing) needs a library with some age on it — \(model.count) links inside \(shape.months.count == 1 ? "one month" : "\(shape.months.count) months") is not yet a shape. Keep importing and it fills in."
    }

    private var isRowFocus: Bool {
        if case .site = focus { return true }
        if case .tag = focus { return true }
        return false
    }

    // MARK: nothing to draw yet

    /// A picture of a library needs a library. Without one this screen used to
    /// draw itself anyway — "0 links from 0 sites, over 0 years", empty
    /// headings, and a sentence about how a handful of tags cover most of the
    /// collection — which reads as an app that is broken rather than empty.
    private var nothingYet: some View {
        Notice(title: "There is nothing to map yet.",
               body: "This screen is a picture of what you have saved: when you saved it, where it came from, and the words you filed it under. It needs links before it can draw one.",
               marker: "NOTHING SAVED HERE") {
            Button { model.showImport = true } label: {
                Label2("Import from your browser", filled: true)
            }.buttonStyle(.plain).clickable()
        }
    }

    private var reading: some View {
        VStack(alignment: .leading, spacing: 7) {
            Marker(text: "READING YOUR LINKS", color: Theme.fainter)
            Text("Counted from the copy on this Mac.")
                .font(Theme.sans(13)).foregroundStyle(Theme.dim)
        }
        .padding(.top, 44)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: what you are looking at

    private func headline(_ shape: Shape) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            (Text("\(model.count)").foregroundStyle(Theme.accent)
                + Text(" links from ").foregroundStyle(Theme.dim)
                + Text("\(model.siteCount)").foregroundStyle(Theme.accent)
                + Text(" sites, over ").foregroundStyle(Theme.dim)
                + Text("\(shape.years.count)").foregroundStyle(Theme.accent)
                + Text(shape.years.count == 1 ? " year." : " years.").foregroundStyle(Theme.dim))
                .font(Theme.sans(26, .light)).tracking(-0.3)
            Text("Click any bar to see what it is made of.")
                .font(Theme.sans(13)).foregroundStyle(Theme.dim)
                .lineSpacing(3).frame(maxWidth: 600, alignment: .leading)
                .padding(.top, 8)
        }
    }

    private func tiles(_ shape: Shape) -> some View {
        let latest = shape.years.last
        return HStack(spacing: 1) {
            tile("\(model.count)", "links indexed",
                 latest.map { "+\($0.count) so far in \($0.name)" } ?? "no dates on any of them")
            tile("\(model.siteCount)", "distinct sites", "\(shape.sitesOnce) appear once")
            tile("\(shape.distinctTags)", "distinct tags",
                 "\(String(format: "%.1f", shape.tagsPerLink)) per link")
            tile("\(shape.days)", "days of saving", "since \(Format.date(shape.firstSaved))")
        }
        .background(Theme.line)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.line))
    }

    private func tile(_ number: String, _ label: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(number).font(Theme.mono(25)).foregroundStyle(Theme.accent).monospacedDigit()
            Text(label).font(Theme.sans(11.5)).foregroundStyle(Theme.faint).padding(.top, 4)
            Text(sub).font(Theme.mono(10.5)).foregroundStyle(Theme.fainter).padding(.top, 2)
                .lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.vertical, 15)
        .background(Theme.panel)
    }

    /// The counts above are inventory; these are the sentences a person would
    /// actually repeat out loud. They come before the charts on purpose.
    private func stands(_ shape: Shape, wide: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                SectionRule()
                Text("What stands out").font(Theme.sans(13.5, .medium)).foregroundStyle(Theme.ink)
            }
            // As many columns as there are things to say, never more. A young
            // library has two findings, and two of them stretched across four
            // columns is half a row of empty space under a heading.
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 18, alignment: .topLeading),
                                     count: min(shape.findings.count, wide ? 4 : 2)),
                      alignment: .leading, spacing: 16) {
                ForEach(shape.findings) { finding in
                    VStack(alignment: .leading, spacing: 5) {
                        // These were teal, and that put two meanings on one
                        // screen: a wall of teal figures, plus teal for the bar
                        // you clicked. On a read-only screen with no action to
                        // take, the accent belongs to the second — so the
                        // figures carry themselves at 21pt, in ink.
                        Text(finding.number).font(Theme.mono(21)).foregroundStyle(Theme.ink)
                            .monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                        Text(finding.line).font(Theme.sans(12.5)).foregroundStyle(Theme.dim)
                            .lineSpacing(2.5).fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 13)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(Theme.accent.opacity(0.45)).frame(width: 1)
                    }
                }
            }
            .padding(.top, 15)
        }
    }

    // MARK: the months

    private func when(_ shape: Shape, width: CGFloat) -> some View {
        let gap: CGFloat = 2
        // Capped, so a library saved inside a few months draws a few bars
        // rather than a wall. Everything on the axis is measured from the plot
        // the bars actually fill, not from the width of the window.
        let plotWidth = min(width, CGFloat(shape.months.count) * Self.monthWidth)
        let slot = (plotWidth + gap) / CGFloat(max(1, shape.months.count))
        let barWidth = max(1, slot - gap)
        let peak = max(1, shape.months.map(\.count).max() ?? 1)
        let plot: CGFloat = 132
        let lastYear = shape.years.last?.name ?? ""
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                SectionRule()
                Text("When you saved it").font(Theme.sans(13.5, .medium)).foregroundStyle(Theme.ink)
                Text("\(shape.years.first?.name ?? "") – \(lastYear)")
                    .font(Theme.mono(11)).foregroundStyle(Theme.faint)
            }
            HStack(alignment: .bottom, spacing: gap) {
                ForEach(shape.months) { month in
                    MonthBar(key: month.name, name: monthName(month.name), count: month.count,
                             width: barWidth, plot: plot, peak: peak,
                             resting: resting(month, lastYear: lastYear, busiest: shape.busiestMonth),
                             picked: focus == .month(month.name)) {
                        pick(.month(month.name))
                    }
                }
            }
            .padding(.top, 16)
            .overlay(alignment: .bottomLeading) {
                if shape.months.count >= Self.monthsWorthAMedian, shape.medianMonth > 0 {
                    median(shape, peak: peak, plot: plot, width: plotWidth)
                }
            }
            Rectangle().fill(Theme.line2).frame(width: plotWidth, height: 1)
            HStack(alignment: .top, spacing: gap) {
                ForEach(shape.years) { year in
                    let span = shape.months.filter { $0.name.hasPrefix(year.name) }.count
                    VStack(alignment: .leading, spacing: 4) {
                        Rectangle().fill(Theme.line2).frame(width: 1, height: 4)
                        HStack(spacing: 4) {
                            Text(year.name).foregroundStyle(Theme.faint)
                            Text("\(year.count)").foregroundStyle(Theme.fainter)
                        }
                        .font(Theme.mono(10.5)).monospacedDigit().fixedSize()
                    }
                    .frame(width: max(1, CGFloat(span) * slot - gap), alignment: .leading)
                }
            }
            .padding(.top, 5)
        }
    }

    /// What a bar looks like when nobody is touching it. Worked out here rather
    /// than inside the bar, because none of it changes with the pointer.
    private func resting(_ month: Bar, lastYear: String, busiest: String) -> Color {
        // The finding above says "click that bar", and until it was marked
        // there was no *that*: forty grey bars and a sentence pointing at one
        // of them. Half accent marks it without taking the full accent, which
        // still means the bar a person actually picked.
        if month.name == busiest { return Theme.accent.opacity(0.55) }
        if month.count == 0 { return Theme.line }
        let recent = month.name.prefix(4) >= "\(max(0, (Int(lastYear) ?? 0) - 1))"
        return recent ? Theme.fainter : Theme.line2
    }

    private func median(_ shape: Shape, peak: Int, plot: CGFloat, width: CGFloat) -> some View {
        let y = CGFloat(shape.medianMonth) / CGFloat(peak) * plot
        // Normally the label sits above its line. Near the top of the plot
        // there is no above — it would be written across the heading — so it
        // hangs under the line instead.
        let above = plot - y > 15
        return ZStack(alignment: .topLeading) {
            Rectangle().fill(Theme.accent.opacity(0.30)).frame(width: width, height: 1)
            Text("median month · \(shape.medianMonth)").font(Theme.mono(10))
                .foregroundStyle(Theme.accent.opacity(0.75)).offset(x: 1, y: above ? -13 : 3)
        }
        .padding(.bottom, y)
        .allowsHitTesting(false)
    }

    // MARK: the two bar columns

    private func bars(_ title: String, _ subtitle: String, _ rows: [Bar],
                      kind: @escaping (String) -> Focus, wide: Bool, content: CGFloat,
                      note: String?) -> some View {
        let peak = max(1, rows.first?.count ?? 1)
        // The track is measured rather than laid out. A `GeometryReader` inside
        // each row is a second layout pass per row for a width both columns
        // already know — they split the page in half and everything else on the
        // row is a fixed size.
        let nameWidth: CGFloat = wide ? 180 : 118
        let column = (content - (wide ? 38 : 22)) / 2
        let track = max(50, column - nameWidth - 34 - 32)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                SectionRule()
                Text(title).font(Theme.sans(13.5, .medium)).foregroundStyle(Theme.ink)
            }
            Text(subtitle).font(Theme.mono(11)).foregroundStyle(Theme.faint).padding(.top, 3)
            VStack(spacing: 0) {
                ForEach(rows) { row in
                    let wanted = kind(row.name)
                    BarRow(name: row.name, count: row.count, share: Double(row.count) / Double(peak),
                           nameWidth: nameWidth, track: track,
                           picked: focus == wanted) { pick(wanted) }
                }
            }
            .padding(.top, 14).padding(.horizontal, -6)
            if let note {
                Text(note).font(Theme.sans(12.5)).foregroundStyle(Theme.faint)
                    .lineSpacing(2).padding(.top, 12)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: what is inside the bar you picked

    private func reveal(_ shape: Shape, width: CGFloat, wide: Bool) -> some View {
        let rows = focus.flatMap { shape.inside[$0] } ?? []
        let shown = Array(rows.prefix(wide ? 24 : 12))
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Marker(text: focusKind, color: Theme.accent)
                Text(focusLabel).font(Theme.sans(13.5, .medium)).foregroundStyle(Theme.ink)
                Text(rows.count == 1 ? "1 link" : "\(rows.count) links · newest first")
                    .font(Theme.mono(11)).foregroundStyle(Theme.faint)
                Spacer(minLength: 8)
                // A way out in words, with a target big enough to hit — the
                // same shape the record drawer uses, because a panel whose only
                // exit is a grey whisper in a corner is a panel people get
                // stuck in.
                Button { focus = nil } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                        Text("Close").font(Theme.sans(11.5))
                    }
                    .foregroundStyle(Theme.dim)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.line2))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).clickable()
                .help("Close this panel and put the bar back")
            }
            .padding(.horizontal, 13).padding(.top, 11).padding(.bottom, 10)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: wide ? 2 : 1),
                      spacing: 0) {
                ForEach(shown) { bookmark in LinkRow(bookmark: bookmark) }
            }
            if rows.count > shown.count {
                Text("\(rows.count - shown.count) more — search for them by meaning.")
                    .font(Theme.mono(10.5)).foregroundStyle(Theme.fainter)
                    .padding(.horizontal, 13).padding(.vertical, 9)
            }
        }
        .frame(width: width, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.line))
        // Only the panel animates. On the whole page it also animated the
        // chart above it, so clicking a bar re-ran the entire layout on a curve.
        .animation(.easeOut(duration: 0.14), value: focus)
    }

    // MARK: the oldest things

    private func oldest(_ shape: Shape, wide: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                SectionRule()
                Text("The oldest things in here").font(Theme.sans(13.5, .medium))
                    .foregroundStyle(Theme.ink)
                Text("saved first, and still saved").font(Theme.mono(11))
                    .foregroundStyle(Theme.faint)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: wide ? 2 : 1),
                      spacing: 0) {
                ForEach(shape.oldest) { bookmark in OldRow(bookmark: bookmark) }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.line))
            .padding(.top, 13)
            Text("You did not forget these on purpose — you forgot what they were called.")
                .font(Theme.sans(12.5)).foregroundStyle(Theme.faint)
                .lineSpacing(2).frame(maxWidth: 620, alignment: .leading).padding(.top, 12)
        }
    }

    // MARK: picking

    private func pick(_ wanted: Focus) {
        focus = focus == wanted ? nil : wanted
    }

    private var focusKind: String {
        switch focus {
        case .month: "MONTH"
        case .site: "SITE"
        case .tag: "TAG"
        case nil: ""
        }
    }

    private var focusLabel: String {
        switch focus {
        case .month(let month): monthName(month)
        case .site(let site): site
        case .tag(let tag): tag
        case nil: ""
        }
    }

    private func monthName(_ key: String) -> String {
        let parts = key.split(separator: "-")
        guard parts.count == 2, let month = Int(parts[1]), month >= 1, month <= 12 else { return key }
        return "\(Format.months[month - 1]) \(parts[0])"
    }

    // MARK: reading the vault

    private func compute() async -> Shape {
        let all = await model.store.bookmarks
        var months: [String: Int] = [:], years: [String: Int] = [:]
        var sites: [String: Int] = [:], tags: [String: Int] = [:]
        for bookmark in all {
            sites[bookmark.site, default: 0] += 1
            for tag in bookmark.tags { tags[tag, default: 0] += 1 }
            guard bookmark.savedOn.count >= 7 else { continue }
            months[String(bookmark.savedOn.prefix(7)), default: 0] += 1
            years[String(bookmark.savedOn.prefix(4)), default: 0] += 1
        }
        // Empty months must appear as gaps, so the series is filled in rather
        // than only listing the months that happen to have something.
        let sortedMonths = months.keys.sorted()
        var series: [Bar] = []
        if let first = sortedMonths.first, let last = sortedMonths.last {
            var cursor = first
            while cursor <= last {
                series.append(Bar(name: cursor, count: months[cursor] ?? 0))
                let year = Int(cursor.prefix(4))!, month = Int(cursor.suffix(2))!
                cursor = month == 12 ? "\(year + 1)-01" : String(format: "%d-%02d", year, month + 1)
            }
        }
        let dated = all.filter { !$0.savedOn.isEmpty }
        let rankedSites = ranked(sites)
        let rankedTags = ranked(tags)
        let counts = series.map(\.count).sorted()
        let median = counts.isEmpty ? 0 : counts[counts.count / 2]
        let busiest = series.max { $0.count < $1.count } ?? Bar(name: "", count: 0)
        let sitesOnce = sites.values.filter { $0 == 1 }.count
        let firstSaved = dated.map(\.savedOn).min() ?? ""
        let shownSites = Array(rankedSites.prefix(Self.barsShown))
        let shownTags = Array(rankedTags.prefix(Self.barsShown))
        return Shape(
            months: series,
            years: years.sorted { $0.key < $1.key }.map { Bar(name: $0.key, count: $0.value) },
            sites: shownSites,
            tags: shownTags,
            sitesOnce: sitesOnce,
            distinctTags: tags.count,
            tagsPerLink: all.isEmpty ? 0 : Double(all.reduce(0) { $0 + $1.tags.count }) / Double(all.count),
            firstSaved: firstSaved,
            days: daysSince(firstSaved),
            oldest: dated.count >= Self.oldestWorthListing
                ? Array(dated.sorted { $0.savedOn < $1.savedOn }.prefix(6)) : [],
            findings: findings(all: all, dated: dated, series: series,
                               rankedSites: rankedSites, sitesOnce: sitesOnce,
                               median: median, busiest: busiest),
            medianMonth: median,
            busiestMonth: busiest.name,
            inside: group(all, sites: shownSites, tags: shownTags))
    }

    private func ranked(_ counts: [String: Int]) -> [Bar] {
        counts.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }
            .map { Bar(name: $0.key, count: $0.value) }
    }

    /// The links behind every bar somebody can click, newest first. Grouped in
    /// one pass here so that opening a panel costs a dictionary lookup — the
    /// screen redraws often enough that a filter and a sort of the whole
    /// library must never happen while it is drawing.
    private func group(_ all: [Bookmark], sites: [Bar], tags: [Bar]) -> [Focus: [Bookmark]] {
        let wantedSites = Set(sites.map(\.name)), wantedTags = Set(tags.map(\.name))
        var inside: [Focus: [Bookmark]] = [:]
        for bookmark in all.sorted(by: { $0.savedOn > $1.savedOn }) {
            if bookmark.savedOn.count >= 7 {
                inside[.month(String(bookmark.savedOn.prefix(7))), default: []].append(bookmark)
            }
            if wantedSites.contains(bookmark.site) {
                inside[.site(bookmark.site), default: []].append(bookmark)
            }
            for tag in bookmark.tags where wantedTags.contains(tag) {
                inside[.tag(tag), default: []].append(bookmark)
            }
        }
        return inside
    }

    private func daysSince(_ iso: String) -> Int {
        let format = DateFormatter(); format.dateFormat = "yyyy-MM-dd"
        guard let then = format.date(from: iso) else { return 0 }
        return Int(Date().timeIntervalSince(then) / 86400)
    }

    /// Up to four sentences, each one counted rather than estimated, and each
    /// one dropped when the library is too young for it to mean anything — a
    /// finding reading "1 months is all it took to collect half of the 7 links
    /// here. The other half took 0." is arithmetic pretending to be insight.
    ///
    /// Anything that would need a visit history is impossible here — the
    /// browser's bookmarks file has none — so nothing in this list claims to
    /// know what he has read.
    private func findings(all: [Bookmark], dated: [Bookmark], series: [Bar],
                          rankedSites: [Bar], sitesOnce: Int,
                          median: Int, busiest: Bar) -> [Finding] {
        var out: [Finding] = []

        let byDate = dated.map(\.savedOn).sorted()
        if !byDate.isEmpty, series.count >= Self.monthsWorthAMedian {
            let halfway = String(byDate[byDate.count / 2].prefix(7))
            let recent = series.drop { $0.name < halfway }.count
            out.append(Finding(id: 0, number: months(max(1, recent)),
                               line: "is all it took to collect half of the \(all.count) links here. The other half took \(series.count - recent)."))
        }

        if busiest.count > 0, series.count >= Self.monthsWorthCharting, busiest.count > median {
            // The multiple is only worth saying when it is a multiple. "1× a
            // typical month" is a busiest month that is not busy.
            let ratio = median > 0 ? Double(busiest.count) / Double(median) : 0
            let against = ratio >= 1.5 ? String(format: " — %.0f× a typical one", ratio) : ""
            out.append(Finding(id: 1, number: "\(busiest.count) in \(monthName(busiest.name))",
                               line: "is the busiest month here\(against). Click that bar to see what it was."))
        }

        // Only worth saying when there are sites outside the group being
        // counted. "100% of everything comes from 5 sites" is not a
        // concentration, it is the whole list read back.
        let top = min(10, rankedSites.count)
        if !all.isEmpty, rankedSites.count > top {
            let share = Int((Double(rankedSites.prefix(top).reduce(0) { $0 + $1.count })
                             / Double(all.count) * 100).rounded())
            let once = sitesOnce > 0
                ? " Another \(sitesOnce) \(sitesOnce == 1 ? "site you visited" : "sites you visited") once and never again." : ""
            out.append(Finding(id: 2, number: "\(share)%",
                               line: "of everything comes from \(top) sites.\(once)"))
        }

        // The longest run of months with nothing saved. A real gap in the
        // collection, and the only honest thing to say about not saving.
        var run = 0, best = 0, endsAt = ""
        for month in series {
            if month.count == 0 {
                run += 1
                if run > best { best = run; endsAt = month.name }
            } else {
                run = 0
            }
        }
        if best >= 2, let index = series.firstIndex(where: { $0.name == endsAt }) {
            let from = series[max(0, index - best + 1)].name
            out.append(Finding(id: 3, number: months(best),
                               line: "is the longest stretch with nothing saved at all, from \(monthName(from)) to \(monthName(endsAt))."))
        }
        return out
    }

    private func months(_ n: Int) -> String { "\(n) month\(n == 1 ? "" : "s")" }
}

/// One month of the series.
///
/// Its own view, and its own hover, because a `hoveredMonth` held by the page
/// invalidated the page — the headline, the tiles, both bar columns and the
/// open panel — every time the pointer crossed one of fifty bars. The count it
/// used to write into the heading on hover is a tooltip now: the same fact,
/// drawn by the system, for no redraw at all.
private struct MonthBar: View {
    let key: String
    let name: String
    let count: Int
    let width: CGFloat
    let plot: CGFloat
    let peak: Int
    let resting: Color
    let picked: Bool
    let pick: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            RoundedRectangle(cornerRadius: 1)
                .fill(picked ? Theme.accent : hovering ? Theme.ink2 : resting)
                .frame(height: max(count == 0 ? 2 : 3, CGFloat(count) / CGFloat(peak) * plot))
        }
        .frame(width: width, height: plot)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: pick)
        .clickable()
        .help(count == 0 ? "\(name) · nothing saved" : "\(name) · \(count) saved — click to see them")
        .accessibilityLabel("\(name), \(count) links")
    }
}

/// One site or one tag, as a bar you can open.
///
/// Chosen is accent as text, edge and fill — never a filled accent plate. The
/// plate is reserved for the single primary action of a screen, and this screen
/// has none: it is read-only, so the strongest thing on it is what you picked.
private struct BarRow: View {
    let name: String
    let count: Int
    let share: Double
    let nameWidth: CGFloat
    let track: CGFloat
    let picked: Bool
    let pick: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: pick) {
            HStack(spacing: 10) {
                Text(name).font(Theme.mono(11))
                    .foregroundStyle(picked ? Theme.accent : hovering ? Theme.ink2 : Theme.dim)
                    .lineLimit(1).frame(width: nameWidth, alignment: .leading)
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2).fill(Theme.panel)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(picked ? Theme.accent : share >= 0.5 ? Theme.fainter : Theme.line2)
                        .frame(width: max(2, track * share))
                }
                .frame(width: track, height: 7)
                Text("\(count)").font(Theme.mono(11))
                    .foregroundStyle(picked ? Theme.accent : Theme.faint)
                    .monospacedDigit().frame(width: 34, alignment: .trailing)
            }
            .padding(.vertical, 3).padding(.horizontal, 6)
            .background(RoundedRectangle(cornerRadius: 4)
                .fill(picked ? Theme.accentWash : hovering ? Theme.panel : .clear))
            .overlay(RoundedRectangle(cornerRadius: 4)
                .stroke(picked ? Theme.accentEdge : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).clickable()
        .onHover { hovering = $0 }
        .help(picked ? "Close \(name)" : "See the \(count) links behind \(name)")
    }
}

/// One link inside an opened bar. Everything it draws arrives as a value and
/// its hover is its own, so a pointer crossing the panel does not re-lay the
/// page it sits in.
private struct LinkRow: View {
    let bookmark: Bookmark
    @State private var hovering = false

    var body: some View {
        Button { open(bookmark) } label: {
            HStack(spacing: 11) {
                Thumbnail(url: bookmark.image,
                          initial: String(bookmark.site.prefix(1)).uppercased(),
                          size: 34, height: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(bookmark.displayTitle).font(Theme.sans(12.5))
                        .foregroundStyle(hovering ? Theme.ink : Theme.dim).lineLimit(1)
                    HStack(spacing: 6) {
                        Text("\(bookmark.site) · \(Format.date(bookmark.savedOn))")
                            .font(Theme.mono(10.5)).foregroundStyle(Theme.fainter).lineLimit(1)
                        if bookmark.isGoneFromBrowser { GoneNote() }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 13).padding(.vertical, 7)
            .background(hovering ? Theme.raised : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).clickable()
        .onHover { hovering = $0 }
        .help("Open \(bookmark.url)")
    }
}

/// One of the first things ever saved. A column rule on the right of every cell
/// keeps the two columns apart — without it the date of the left one and the
/// title of the right one read as a single run-on row.
private struct OldRow: View {
    let bookmark: Bookmark
    @State private var hovering = false

    var body: some View {
        Button { open(bookmark) } label: {
            HStack(spacing: 12) {
                Text(bookmark.displayTitle).font(Theme.sans(12.5))
                    .foregroundStyle(hovering ? Theme.ink : Theme.dim).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if bookmark.isGoneFromBrowser { GoneNote() }
                Text(bookmark.site).font(Theme.mono(11)).foregroundStyle(Theme.faint)
                    .lineLimit(1).frame(width: 110, alignment: .leading)
                Text("\(Format.ago(bookmark.savedOn)) ago").font(Theme.mono(11))
                    .foregroundStyle(Theme.fainter).monospacedDigit()
                    .frame(width: 74, alignment: .trailing)
            }
            .padding(.horizontal, 13).padding(.vertical, 9)
            .background(hovering ? Theme.raised : Theme.panel)
            .contentShape(Rectangle())
            .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
            .overlay(alignment: .trailing) { Rectangle().fill(Theme.line).frame(width: 1) }
        }
        .buttonStyle(.plain).clickable()
        .onHover { hovering = $0 }
        .help("Open \(bookmark.url)")
    }
}

/// A link the browser no longer has. It is still a record here and still opens,
/// so this is stated once, in grey — a colour meaning "wrong" would be a lie
/// about a link that works.
private struct GoneNote: View {
    var body: some View {
        Text("no longer in your browser").font(Theme.mono(9.5))
            .foregroundStyle(Theme.fainter)
            .padding(.horizontal, 4).padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Theme.line2))
            .fixedSize()
    }
}

private func open(_ bookmark: Bookmark) {
    guard let url = URL(string: bookmark.url) else { return }
    NSWorkspace.shared.open(url)
}
