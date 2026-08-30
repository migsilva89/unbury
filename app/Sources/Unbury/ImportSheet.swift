import SwiftUI
import UnburyCore

/// Choosing what comes in, before anything is spent.
///
/// The first version started importing the moment it was opened. That spends
/// someone's money and minutes on their behalf, and gives them no way to leave
/// out the fifty links they saved by accident. This shows the list, lets them
/// cut it down, and says what the rest will cost.
///
/// The profiles used to sit in a row of buttons across the top. Ten of them do
/// not fit in 620 points, so each button squeezed until its label broke one
/// letter per line — "C/h/r/o/m/e". They live down the left side now, one per
/// line, where a list can grow without the layout fighting back.
struct ImportSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var profiles: [Browsers.Profile] = []
    @State private var profile: Browsers.Profile?
    @State private var candidates: [Importer.Candidate] = []
    /// Links in this profile that were deleted here on purpose. Shown, never
    /// offered — see `AppModel.candidates(in:)`.
    @State private var passedOver = 0
    @State private var excluded: Set<String> = []
    @State private var filter = ""
    @State private var reading = true
    @State private var loadingProfile = false

    /// What a link costs and how long it takes, taken from whoever is set to
    /// describe them. Describing is no longer necessarily bought — Claude Code
    /// and Codex spend a subscription instead, and take four to five times as
    /// long — so a figure fixed at Kimi's price and pace would now be wrong in
    /// both directions. Measured per engine in `DescribeEngines`.
    private var describer: DescribeEngineOption {
        DescribeEngines.option(model.preferences.describeEngine) ?? DescribeEngines.all[0]
    }
    private var centsPerLink: Double { describer.centsPerLink }
    private var secondsPerLink: Double { describer.secondsPerLink }

    private var chosen: [Importer.Candidate] {
        candidates.filter { !excluded.contains($0.url) }
    }
    private var shown: [Importer.Candidate] {
        guard !filter.isEmpty else { return candidates }
        let needle = filter.lowercased()
        return candidates.filter {
            $0.title.lowercased().contains(needle) || $0.site.contains(needle)
        }
    }
    /// The rows actually built. A profile can hold two thousand new links, and
    /// laying every one of them out froze the window for fourteen seconds —
    /// a lazy stack is lazy about drawing, not about measuring. Everything past
    /// this is reached with the filter; nothing is hidden from the selection,
    /// which always acts on the whole filtered set.
    private var listed: ArraySlice<Importer.Candidate> { shown.prefix(rowCap) }
    private let rowCap = 200

    var body: some View {
        VStack(spacing: 0) {
            header
            if reading {
                centred("Looking for browsers…")
            } else if profiles.isEmpty {
                noBrowser
            } else {
                HStack(spacing: 0) {
                    sidebar
                    Rectangle().fill(Theme.line).frame(width: 1)
                    main
                }
            }
            footer
        }
        .frame(width: 780, height: 640)
        .background(Theme.panel)
        .task {
            profiles = Browsers.installed()
            reading = false
            // Open on the profile last imported from. It used to open on
            // whichever profile happened to be biggest, which on a Mac with ten
            // Chrome profiles is rarely the one anybody uses.
            let remembered = profiles.first { $0.file.path == model.preferences.browserProfile }
            if let opening = remembered ?? profiles.first { await load(opening) }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            UnburyBadge(size: 26).padding(.trailing, 11).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 6 }
            VStack(alignment: .leading, spacing: 3) {
                Text("Import bookmarks").font(Theme.sans(15, .medium)).foregroundStyle(Theme.ink)
                Text("Nothing is written back to your browser.")
                    .font(Theme.sans(12)).foregroundStyle(Theme.faint)
            }
            Spacer()
            if !profiles.isEmpty {
                Text("\(profiles.count) profiles · \(profiles.map(\.count).reduce(0, +)) bookmarks")
                    .font(Theme.mono(11)).foregroundStyle(Theme.fainter).monospacedDigit()
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 15)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    // MARK: - Profiles

    /// Profiles grouped under the browser they belong to, biggest browser
    /// first. `Browsers.installed()` already sorts by size, so the order the
    /// browsers are first seen in is the order they should be shown in.
    private var grouped: [(browser: String, profiles: [Browsers.Profile])] {
        var order: [String] = []
        var byBrowser: [String: [Browsers.Profile]] = [:]
        for candidate in profiles {
            if byBrowser[candidate.browser] == nil { order.append(candidate.browser) }
            byBrowser[candidate.browser, default: []].append(candidate)
        }
        return order.map { ($0, byBrowser[$0] ?? []) }
    }

    private var largest: Int { max(profiles.map(\.count).max() ?? 1, 1) }

    private var sidebar: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(grouped, id: \.browser) { group in
                    Section {
                        ForEach(group.profiles) { candidate in
                            profileRow(candidate)
                        }
                    } header: {
                        Marker(text: group.browser.uppercased(), color: Theme.faintest)
                            .padding(.horizontal, 16)
                            .padding(.top, 14).padding(.bottom, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.panel)
                    }
                }
            }
            .padding(.bottom, 12)
        }
        .frame(width: 226)
    }

    private func profileRow(_ candidate: Browsers.Profile) -> some View {
        let picked = profile == candidate
        // A profile holding one link should not shout as loudly as one holding
        // six hundred. The bar is square-rooted so the small ones stay visible
        // instead of collapsing to nothing.
        let share = (Double(candidate.count) / Double(largest)).squareRoot()
        let slight = candidate.count < 10

        return Button { Task { await load(candidate) } } label: {
            HStack(spacing: 10) {
                Rectangle()
                    .fill(picked ? Theme.accent : .clear)
                    .frame(width: 2)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(candidate.name)
                            .font(Theme.sans(12.5, picked ? .medium : .regular))
                            .foregroundStyle(picked ? Theme.onAccent : (slight ? Theme.faint : Theme.dim))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 6)
                        Text("\(candidate.count)")
                            .font(Theme.mono(10.5)).monospacedDigit()
                            .foregroundStyle(picked ? Theme.onAccent.opacity(0.72) : Theme.fainter)
                            .fixedSize()
                    }
                    Capsule()
                        .fill(picked ? Theme.onAccent.opacity(0.72) : Theme.faintest)
                        .frame(width: max(3, share * 150), height: 2)
                }
                .padding(.trailing, 14)
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(picked ? Theme.accent : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(candidate.label) — \(candidate.count) bookmarks saved in this profile")
        .handCursor()
    }

    // MARK: - The links themselves

    @ViewBuilder private var main: some View {
        VStack(spacing: 0) {
            if loadingProfile {
                centred("Reading \(profile?.label ?? "the profile")…")
            } else if candidates.isEmpty {
                nothingNew
            } else {
                list
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("\(chosen.count) of \(candidates.count) new")
                    .font(Theme.mono(11)).foregroundStyle(Theme.faint).monospacedDigit()
                    .help("Links in this profile that are not saved here yet")
                if passedOver > 0 {
                    Text("· \(passedOver) deleted here")
                        .font(Theme.mono(11)).foregroundStyle(Theme.faint).monospacedDigit()
                        .help("You deleted these in Unbury on purpose. They are still in your browser — Unbury never writes to it — so the import steps over them rather than saving them again. `unburyctl restore <url>` undoes a deletion.")
                }
                Spacer()
                TextField("filter", text: $filter)
                    .textFieldStyle(.plain).font(Theme.mono(11))
                    .foregroundStyle(Theme.ink).frame(width: 150)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.line2))
                    .help("Narrow the list by title or site")
                pill("all") { for candidate in shown { excluded.remove(candidate.url) } }
                    .help(filter.isEmpty ? "Select every link" : "Select the \(shown.count) shown")
                pill("none") { for candidate in shown { excluded.insert(candidate.url) } }
                    .help(filter.isEmpty ? "Clear the selection" : "Deselect the \(shown.count) shown")
            }
            .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 9)

            if shown.isEmpty {
                centred("Nothing matches “\(filter)”.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(listed) { candidate in
                            row(candidate)
                        }
                        if shown.count > rowCap {
                            Text("Showing the first \(rowCap) of \(shown.count). Type in the filter to reach the rest — “all” and “none” still act on every one of them.")
                                .font(Theme.mono(10.5)).foregroundStyle(Theme.fainter)
                                .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 18).padding(.top, 12)
                        }
                    }
                    .padding(.bottom, 10)
                }
            }
        }
    }

    private func pill(_ text: String, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Text(text).font(Theme.mono(11)).foregroundStyle(Theme.dim)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.line))
        }
        .buttonStyle(.plain)
        .handCursor()
    }

    private func row(_ candidate: Importer.Candidate) -> some View {
        let on = !excluded.contains(candidate.url)
        return Button {
            if on { excluded.insert(candidate.url) } else { excluded.remove(candidate.url) }
        } label: {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(on ? Theme.accent : .clear)
                    .overlay(RoundedRectangle(cornerRadius: 3)
                        .stroke(on ? Theme.accent : Theme.line2))
                    .overlay(Text(on ? "✓" : "").font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Theme.onAccent))
                    .frame(width: 13, height: 13)
                VStack(alignment: .leading, spacing: 2) {
                    Text(candidate.title.isEmpty ? candidate.url : candidate.title)
                        .font(Theme.sans(12.5))
                        .foregroundStyle(on ? Theme.ink2 : Theme.faintest)
                        .strikethrough(!on, color: Theme.faintest)
                        .lineLimit(1)
                    HStack(spacing: 7) {
                        Text(candidate.site)
                        if !candidate.folder.isEmpty {
                            Text(candidate.folder).lineLimit(1)
                        }
                    }
                    .font(Theme.mono(10.5)).foregroundStyle(on ? Theme.faint : Theme.faintest)
                }
                Spacer(minLength: 8)
                Text(candidate.savedOn.isEmpty ? "—" : candidate.savedOn)
                    .font(Theme.mono(10.5))
                    .foregroundStyle(on ? Theme.fainter : Theme.faintest).monospacedDigit()
            }
            .padding(.horizontal, 18).padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(candidate.url)
        .handCursor()
    }

    // MARK: - The states where there is nothing to show

    private var nothingNew: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Everything in this profile is already saved here.")
                .font(Theme.sans(13.5)).foregroundStyle(Theme.ink)
            Text("All \(profile?.count ?? 0) bookmarks in \(profile?.label ?? "it") have been imported. Pick another profile on the left, or close this.")
                .font(Theme.sans(12.5)).foregroundStyle(Theme.dim).lineSpacing(3)
        }
        .frame(maxWidth: 380, maxHeight: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
    }

    private var noBrowser: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No browser bookmarks found.").font(Theme.sans(13.5)).foregroundStyle(Theme.ink)
            Text("Brave, Chrome, Arc, Edge and Vivaldi are read. Safari and Firefox keep bookmarks in a different format and are not supported yet.")
                .font(Theme.sans(12.5)).foregroundStyle(Theme.dim).lineSpacing(3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(20)
    }

    private func centred(_ text: String) -> some View {
        Text(text).font(Theme.sans(12.5)).foregroundStyle(Theme.faint)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - What it will cost, and the button

    private var footer: some View {
        HStack(spacing: 12) {
            estimate
            Spacer()
            Button { dismiss() } label: { Label2("Cancel", filled: false) }
                .buttonStyle(.plain)
                .handCursor()
            if model.hasKey {
                Button {
                    // Both read before the sheet goes: the profile travels with
                    // the import so every record knows which one it came from,
                    // and so the sweep afterwards judges that profile alone.
                    let list = chosen
                    let read = profile
                    dismiss()
                    Task { await model.runImport(list, from: read) }
                } label: {
                    Label2(chosen.isEmpty ? "Nothing selected" : "Import \(chosen.count)",
                           filled: !chosen.isEmpty)
                }
                .buttonStyle(.plain)
                .disabled(chosen.isEmpty)
                .opacity(chosen.isEmpty ? 0.45 : 1)
                .help(chosen.isEmpty ? "Select at least one link" : "Read and describe \(chosen.count) pages")
                .handCursor()
            } else {
                // A greyed-out button that will not say why is a dead end. The
                // missing key is the reason, so the button becomes the fix.
                Button {
                    dismiss()
                    model.showSettings = true
                } label: {
                    Label2("Add a key", filled: true)
                }
                .buttonStyle(.plain)
                .help("Opens Settings, where the OpenRouter key goes")
                .handCursor()
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    /// What this will cost, said before it is spent and in money rather than in
    /// tokens. Importing is the costliest thing the app does and the only one
    /// worth an estimate up front, so it is stated plainly and beside the button
    /// rather than tucked into a help tag nobody hovers.
    @ViewBuilder private var estimate: some View {
        if !model.hasKey {
            VStack(alignment: .leading, spacing: 3) {
                Text("An OpenRouter key is needed to import.")
                    .font(Theme.sans(12)).foregroundStyle(Theme.warn)
                Text("each page is read and described once, for a fraction of a cent")
                    .font(Theme.mono(10)).foregroundStyle(Theme.fainter)
            }
        } else if !chosen.isEmpty {
            HStack(alignment: .top, spacing: 10) {
                Marker(text: "COST", color: Theme.warn).padding(.top, 2)
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(chosen.count) \(chosen.count == 1 ? "link" : "links") · \(cost.hasPrefix("no charge") ? cost : "about " + cost), and \(time)")
                        .font(Theme.mono(11.5)).foregroundStyle(Theme.dim).monospacedDigit()
                    Text(describer.spends
                         ? "read and described once each, from your OpenRouter key. Browsing them afterwards never leaves this Mac."
                         : "described by \(describer.label), which spends \(describer.purse) rather than your key. The vectors are still bought. Browsing them afterwards never leaves this Mac.")
                        .font(Theme.mono(10)).foregroundStyle(Theme.fainter)
                }
            }
        }
    }

    private var cost: String {
        let cents = Double(chosen.count) * centsPerLink
        // Nothing is charged to a key when a program on this Mac does the
        // describing — but a vector is still bought for every link, and saying
        // "nothing" would be the kind of half-truth this app does not tell.
        if cents == 0 { return "no charge for describing, and a fraction of a cent in vectors" }
        if cents < 1 { return "a cent" }
        if cents < 100 { return String(format: "%.0f cents", cents) }
        return String(format: "$%.2f", cents / 100)
    }

    private var time: String {
        let seconds = Double(chosen.count) * secondsPerLink
        if seconds < 90 { return "under two minutes" }
        let minutes = seconds / 60
        if minutes > 90 { return String(format: "about %.1f hours", minutes / 60) }
        return "about \(Int(minutes.rounded())) minutes"
    }

    private func load(_ candidate: Browsers.Profile) async {
        profile = candidate
        if model.preferences.browserProfile != candidate.file.path {
            var preferences = model.preferences
            preferences.browserProfile = candidate.file.path
            try? preferences.save()
            model.preferences = preferences
        }
        loadingProfile = true
        filter = ""
        let found = await model.candidates(in: candidate)
        candidates = found.rows
        passedOver = found.passedOver
        excluded = []
        loadingProfile = false
    }
}

/// The pointing hand, on everything that answers to a click. Kept private to
/// this file so it cannot collide with the same idea living somewhere else.
private extension View {
    func handCursor() -> some View {
        onHover { $0 ? NSCursor.pointingHand.push() : NSCursor.pop() }
    }
}
