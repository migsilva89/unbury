import ImageIO
import SwiftUI
import UnburyCore

/// Preview pictures, fetched once and kept for as long as the app is open.
///
/// `AsyncImage` has no memory: a row that scrolls out of sight and back asks the
/// network for the same picture again, so a long list spends its time
/// re-downloading what it already had — which is most of what made scrolling
/// stutter. The misses are remembered too. Around a third of links serve a
/// JavaScript shell with no preview tag, and asking again for each of those on
/// every pass costs exactly as much as asking for a real one.
@MainActor
final class Thumbnails {
    static let shared = Thumbnails()

    /// Pictures get their own connection to the network, away from
    /// `URLSession.shared`.
    ///
    /// They used to share it with the question. A screenful of results asks for
    /// a dozen pictures at once, some from sites that answer slowly or not at
    /// all, and the shared session only holds a handful of connections per
    /// host — so asking a second question sat in the queue behind the pictures
    /// of the first answer, and the screen said "searching by meaning…" for as
    /// long as they took. A picture must never be able to delay a question.
    private static let session: URLSession = {
        let setup = URLSessionConfiguration.default
        setup.timeoutIntervalForRequest = 12
        setup.httpMaximumConnectionsPerHost = 3
        setup.networkServiceType = .background
        setup.requestCachePolicy = .returnCacheDataElseLoad
        return URLSession(configuration: setup)
    }()

    private var pictures: [URL: NSImage] = [:]
    private var missing: Set<URL> = []
    private var fetching: [URL: Task<CGImage?, Never>] = [:]

    /// What is already here, for the first frame of a row. A picture that has to
    /// be awaited flashes a placeholder even when it is in hand.
    func held(_ url: URL) -> NSImage? { pictures[url] }
    /// Already asked for and never coming — a third of links serve a page with
    /// no preview tag at all.
    func isMissing(_ url: URL) -> Bool { missing.contains(url) }

    func picture(at url: URL) async -> NSImage? {
        if let picture = pictures[url] { return picture }
        if missing.contains(url) { return nil }
        // One request per address, however many rows are showing it: a tag and a
        // search can have the same link on screen twice.
        let fetch = fetching[url] ?? {
            let task = Task.detached(priority: .utility) { () -> CGImage? in
                guard let data = try? await Thumbnails.session.data(from: url).0
                else { return nil }
                return Thumbnails.shrink(data)
            }
            fetching[url] = task
            return task
        }()
        let small = await fetch.value
        fetching[url] = nil
        if let picture = pictures[url] { return picture }
        guard let small else {
            missing.insert(url)
            return nil
        }
        let picture = NSImage(cgImage: small,
                              size: CGSize(width: small.width, height: small.height))
        pictures[url] = picture
        return picture
    }

    /// Decode straight to the size a row actually draws, off the main thread.
    ///
    /// `NSImage(data:)` on the main actor was the second freeze: a preview
    /// picture is around 1200x630, a row shows it at 48pt, and realising a few
    /// hundred rows decoded a few hundred full-size images on the thread that
    /// draws. Measured at 627 rows it froze the window for over four seconds.
    /// ImageIO can decode a thumbnail directly, which is both far cheaper and
    /// somewhere else.
    nonisolated static func shrink(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            // Twice the widest a picture is drawn here — the drawer's 88pt — so
            // it is still sharp on a Retina display and nothing larger is kept.
            kCGImageSourceThumbnailMaxPixelSize: 256,
        ] as CFDictionary)
    }
}

/// A preview picture, or the shape of one. Around a third of links have no image
/// and never will — the row must keep its shape rather than look damaged.
struct Thumbnail: View {
    let url: String?
    let initial: String
    var size: CGFloat = 44
    var height: CGFloat? = nil
    @State private var fetched: NSImage?

    private var large: Bool { size > 60 }
    private var address: URL? { url.flatMap(URL.init(string:)) }

    /// What to draw right now: whatever this row has fetched, or whatever is
    /// already in hand. Looked up while drawing, so a picture the app already
    /// holds appears in the first frame instead of after a placeholder.
    private var picture: NSImage? {
        fetched ?? address.flatMap { Thumbnails.shared.held($0) }
    }

    /// Whether there is any work to do at all. Most rows, most of the time,
    /// have none.
    private var wanting: Bool {
        guard let address else { return false }
        return Thumbnails.shared.held(address) == nil
            && !Thumbnails.shared.isMissing(address)
    }

    var body: some View {
        let box = RoundedRectangle(cornerRadius: 5)
        Group {
            if let picture {
                // Fit, not fill: preview pictures are wide and a square crop cut
                // the words out of them, which is most of what they show.
                Theme.bg.overlay(Image(nsImage: picture).resizable().scaledToFit())
                    .overlay(veil)
            } else {
                placeholder
            }
        }
        .frame(width: size, height: height ?? size)
        .clipShape(box)
        .overlay(box.stroke(Theme.line2))
        .modifier(FetchPicture(url: wanting ? address : nil, into: $fetched))
    }

    /// Pictures arrive at every brightness. A dark wash across the bottom keeps
    /// them all sitting at the same weight beside the text.
    private var veil: some View {
        LinearGradient(colors: [.white.opacity(0.05), .black.opacity(0.35)],
                       startPoint: .top, endPoint: .bottom)
    }

    /// Not an error, and it should not look like one: a lettered plate, sized
    /// and centred on purpose, plus the reason in words where there is room.
    private var placeholder: some View {
        Theme.panel.overlay(
            VStack(spacing: 3) {
                Text(initial)
                    .font(Theme.mono(large ? 15 : 13, .medium))
                    .foregroundStyle(Theme.fainter)
                if large {
                    Text("no preview").font(Theme.mono(8.5)).foregroundStyle(Theme.faintest)
                }
            }
        )
    }
}

/// Fetching, attached only to the rows that need it.
///
/// A `.task` on every row is not free: SwiftUI creates one and cancels it each
/// time a row is realised, and dragging through two hundred rows realises them
/// over and over. Measured on a 200-row list scrolled in 10pt steps, that churn
/// was half the total cost — 77 seconds with it, 47 without. A row whose picture
/// is already held, or is known to have none, now attaches nothing at all.
private struct FetchPicture: ViewModifier {
    let url: URL?
    @Binding var into: NSImage?

    func body(content: Content) -> some View {
        if let url {
            content.task(id: url) {
                // A row scrolled straight past should cost nothing. `.task` is
                // cancelled when the row goes away, so this pause means only
                // the rows somebody stopped on ever reach the network.
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled else { return }
                into = await Thumbnails.shared.picture(at: url)
            }
        } else {
            content
        }
    }
}

/// The one question the app asks before deleting, wherever deleting is asked
/// for. A system confirmation, the same kind "Erase everything" already uses,
/// rather than a panel of the app's own: it names what goes, says what is left
/// alone, and its destructive button is red because macOS makes it red — none
/// of the accent belonging to a screen's primary action is spent on it.
struct DeleteConfirmation: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        @Bindable var model = model
        let going = model.pendingDeletion
        return content.confirmationDialog(going.count == 1 ? "Delete this link?"
                                                           : "Delete \(going.count) links?",
                                          isPresented: $model.confirmingDeletion) {
            Button(going.count == 1 ? "Delete it" : "Delete \(going.count)",
                   role: .destructive) {
                Task { await model.confirmDeletion() }
            }
            Button("Cancel", role: .cancel) { model.cancelDeletion() }
        } message: {
            Text(message(going))
        }
    }

    /// What a person needs told, and the second sentence is the one that
    /// matters: Unbury never writes to a browser's bookmarks file, so this
    /// cannot and does not remove the link from the browser. What it does do is
    /// remember the address, so the next import passes over it instead of
    /// offering the same link back and making the delete look like it failed.
    private func message(_ going: [Bookmark]) -> String {
        let what = going.count == 1
            ? "“\(going[0].displayTitle)” and its description and vector are deleted from this Mac."
            : "\(going.count) records, with their descriptions and vectors, are deleted from this Mac."
        return what + " This cannot be undone, and describing them again would cost money.\n\n"
            + "Your browser is never touched, so the "
            + (going.count == 1 ? "bookmark stays" : "bookmarks stay")
            + " where "
            + (going.count == 1 ? "it is" : "they are")
            + ". Unbury remembers the "
            + (going.count == 1 ? "address" : "addresses")
            + " and the next import will pass over "
            + (going.count == 1 ? "it" : "them")
            + " — `unburyctl restore` lifts that if you change your mind."
    }
}

extension View {
    /// Ask before deleting, once per screen. Only one screen is ever mounted,
    /// so this can be attached to each of them without two dialogs racing.
    func deleteConfirmation() -> some View { modifier(DeleteConfirmation()) }
}

/// The full record, beside the results. Read top to bottom it answers, in order:
/// what is this, what is it about, where did it come from, and — last, because
/// it is the curiosity and not the point — what does the machine see.
struct DetailDrawer: View {
    @Environment(AppModel.self) private var model
    let bookmark: Bookmark
    /// True when the window is too narrow to hold the list as well, so this is
    /// the whole screen, and the way back has to name where it goes.
    var standalone = false
    /// What the way out is called. Nil takes the wording from where the panel
    /// is: beside a list it closes, over a list it goes back to it. Ask passes
    /// its own, because from there the way back is to the evidence.
    var closeLabel: String?
    /// What the way out does. Nil clears the chosen record, which is what it
    /// has always done and what the Search screen still wants.
    var onClose: (() -> Void)?
    @State private var vectorHead: [Float] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                Divider().background(Theme.line)
                subject
                Divider().background(Theme.line)
                Group {
                    section("WHERE IT CAME FROM", provenance)
                    Divider().background(Theme.line)
                    section("IN THE VAULT", record)
                }
                Divider().background(Theme.line)
                embedding
                Divider().background(Theme.line)
                removal
            }
        }
        .background(Theme.panel)
        .task(id: bookmark.id) {
            vectorHead = await model.store.vectorHead(for: bookmark.id, count: 32)
        }
    }

    private var header: some View {
        HStack {
            Marker(text: "RECORD #\(bookmark.id)", color: Theme.faint)
            Spacer()
            // A way out in words, with a target big enough to hit. It used to
            // be a chip reading "esc" — a keyboard hint standing in for the
            // only control, which leaves anybody who does not know the shortcut
            // with no way back at all. The key still works; it is now the
            // second route rather than the only one.
            Button { (onClose ?? { model.selected = nil })() } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.left").font(.system(size: 9, weight: .semibold))
                    Text(closeLabel ?? (standalone ? "Back to the list" : "Close"))
                        .font(Theme.sans(11.5))
                }
                .foregroundStyle(Theme.dim)
                .padding(.horizontal, 9).padding(.vertical, 4)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.line2))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).clickable()
            .help("\(closeLabel ?? (standalone ? "Back to the list" : "Close")) · esc")
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
    }

    // The one block that earns the top of the drawer: what the link is, what it
    // is about, and the button. The address is long and rarely read, so it goes
    // downstairs with the rest of the paperwork.
    private var subject: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Thumbnail(url: bookmark.image,
                          initial: String(bookmark.site.prefix(1)).uppercased(),
                          size: 88, height: 60)
                VStack(alignment: .leading, spacing: 5) {
                    Text(bookmark.displayTitle).font(Theme.sans(14, .medium))
                        .foregroundStyle(Theme.ink).lineSpacing(2).lineLimit(3)
                    Text("\(bookmark.site)  ·  \(Format.ago(bookmark.savedOn)) ago")
                        .font(Theme.mono(10.5)).foregroundStyle(Theme.faint)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(bookmark.summary).font(Theme.sans(13)).foregroundStyle(Theme.dim)
                .lineSpacing(3.5).padding(.top, 13)
            FlowTags(tags: bookmark.tags).padding(.top, 13)
            Link(destination: URL(string: bookmark.url) ?? URL(string: "https://example.com")!) {
                Label2("Open link ↵", filled: true)
            }
            .buttonStyle(.plain).clickable()
            .padding(.top, 16)
        }
        .padding(16)
    }

    private func section(_ title: String, _ fields: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Marker(text: title, color: Theme.faintest)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(fields, id: \.0) { key, value in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(key).font(Theme.mono(10.5)).tracking(0.4)
                            .foregroundStyle(Theme.faint)
                            .frame(width: 84, alignment: .leading)
                        Text(value).font(Theme.mono(11.5)).foregroundStyle(Theme.dim)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 3.5)
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
    }

    private var embedding: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Marker(text: "EMBEDDING", color: Theme.faintest)
                Spacer()
                Text("1024 d · cosine · qwen3").font(Theme.mono(10.5))
                    .foregroundStyle(Theme.fainter)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4),
                      spacing: 3) {
                ForEach(Array(vectorHead.enumerated()), id: \.offset) { _, value in
                    Text(String(format: "%@%.3f", value >= 0 ? "+" : "", value))
                        .font(Theme.mono(10.5))
                        .foregroundStyle(abs(value) > 0.04 ? Theme.dim : Theme.faintest)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .monospacedDigit()
            Text("first \(vectorHead.count) of 1024 · remaining hidden")
                .font(Theme.mono(10)).foregroundStyle(Theme.fainter)
        }
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 26)
    }

    /// Deleting, at the bottom, under the paperwork and away from "Open link".
    /// Outlined in red rather than filled: the filled plate in this panel is the
    /// button that opens the link, which is what a record is for.
    private var removal: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("Deleting keeps nothing of this record. Your browser is not touched.")
                .font(Theme.mono(10)).foregroundStyle(Theme.faintest)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button { model.askToDelete([bookmark]) } label: {
                Text("Delete this link").font(Theme.sans(11.5)).foregroundStyle(Theme.bad)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.bad.opacity(0.4)))
            }
            .buttonStyle(.plain).clickable().fixedSize()
            .help("Delete this record from Unbury. The bookmark stays in your browser.")
        }
        .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 24)
    }

    private var provenance: [(String, String)] {
        var fields = [
            ("SAVED", Format.date(bookmark.savedOn)),
            // "browser" is what an import stamps now; "brave" is what the first
            // imports wrote. Anything else came in through a chat, and saying
            // "browser · via chat" about a bookmark was nonsense either way.
            ("SAVED BY", ["browser", "brave"].contains(bookmark.origin)
                ? "your browser's bookmarks" : "\(bookmark.origin) · via chat"),
            ("FOLDER", bookmark.folder.isEmpty ? "unsorted" : bookmark.folder),
        ]
        // Stated plainly, in the same grey as the rest of the paperwork. The
        // record is kept and still answers questions; a browser being tidied up
        // is not something that happened to this link.
        if let gone = bookmark.goneFromBrowserOn {
            fields.append(("IN BROWSER", "gone since \(Format.date(gone)) · kept here"))
        }
        return fields
    }

    private var record: [(String, String)] {
        [
            ("URL", bookmark.url),
            ("INDEXED", String(bookmark.indexedAt.prefix(16)).replacingOccurrences(of: "T", with: " ")),
            ("ID", "bk_" + String(format: "%06d", bookmark.id)),
        ]
    }
}

struct FlowTags: View {
    let tags: [String]
    var body: some View {
        FlowLayout(spacing: 5) {
            ForEach(tags, id: \.self) { tag in
                Text(tag).font(Theme.mono(10.5)).foregroundStyle(Theme.dim)
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .overlay(Capsule().stroke(Theme.line2))
            }
        }
    }
}

/// Tags wrap; a horizontal stack would clip them. Small enough to hand-roll.
///
/// Every subview is measured once per pass and the sizes kept. SwiftUI asks a
/// layout for its size several times with different proposals before placing
/// anything, and measuring a thousand tags on each of those asks is how a tag
/// cloud ends up costing seconds instead of milliseconds.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    /// Words of different sizes need more air between rows than between
    /// neighbours, or the lines comb into each other.
    var lineSpacing: CGFloat?
    private var between: CGFloat { lineSpacing ?? spacing }

    func makeCache(subviews: Subviews) -> [CGSize] {
        subviews.map { $0.sizeThatFits(.unspecified) }
    }

    func updateCache(_ cache: inout [CGSize], subviews: Subviews) {
        cache = subviews.map { $0.sizeThatFits(.unspecified) }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews,
                      cache: inout [CGSize]) -> CGSize {
        let width = proposal.width ?? 300
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for size in cache {
            if x + size.width > width, x > 0 { x = 0; y += lineHeight + between; lineHeight = 0 }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: width, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout [CGSize]) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for (view, size) in zip(subviews, cache) {
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX; y += lineHeight + between; lineHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

/// The button face, in exactly the two weights the accent tiers allow: the way
/// forward wears the teal plate (tier 3), everything else is a grey outline.
/// There is deliberately no middle weight — one would let two buttons on the
/// same screen both look important, which is the failure the scheme exists to
/// stop. `filled` therefore does not mean "emphasised", it means "this is the
/// one", so no screen may pass it twice.
struct Label2: View {
    let text: String
    let filled: Bool
    init(_ text: String, filled: Bool) { self.text = text; self.filled = filled }
    var body: some View {
        Text(text).font(Theme.sans(12, filled ? .medium : .regular))
            .foregroundStyle(filled ? Theme.onAccent : Theme.dim)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 4).fill(filled ? Theme.accent : .clear))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(filled ? Theme.accent : Theme.line))
    }
}

/// The mark, drawn rather than loaded: the same aperture as the app icon — an
/// octagon with four blades wound round a square opening. It is here so the top
/// bar and the empty screens read as the same object as the thing in the Dock.
/// At 13pt a scaled-down .icns turns to mush; a path does not. Tier 1 of the
/// accent scheme, and it only ever appears in chrome.
///
/// The blades are cut, not drawn: the octagon has the opening and four slits
/// subtracted from it, so the gaps are whatever the mark sits on and the shape
/// stays one filled path at any size.
struct UnburyMark: Shape {
    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let r = side / 2

        var octagon = Path()
        for i in 0..<8 {
            let a = (Double(i) * 45 + 22.5) * .pi / 180
            let p = CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a))
            if i == 0 { octagon.move(to: p) } else { octagon.addLine(to: p) }
        }
        octagon.closeSubpath()

        // The opening, and the four slits that wind out of its corners. One
        // handedness throughout — that turn is what makes it read as a shutter
        // rather than a decorative octagon.
        let hole = side * 0.30
        let opening = Path(CGRect(x: c.x - hole / 2, y: c.y - hole / 2,
                                  width: hole, height: hole))
        let slit = side * 0.055
        let reach = side * 1.2
        var blades = Path()
        for i in 0..<4 {
            let a = (Double(i) * 90 + 45) * .pi / 180      // corner direction
            let corner = CGPoint(x: c.x + (hole / 2) * (cos(a) < 0 ? -1 : 1),
                                 y: c.y + (hole / 2) * (sin(a) < 0 ? -1 : 1))
            let out = (Double(i) * 90 + 135) * .pi / 180    // and the turn
            var arm = Path(CGRect(x: -slit / 2, y: 0, width: slit, height: reach))
            arm = arm.applying(CGAffineTransform(rotationAngle: out - .pi / 2))
            arm = arm.applying(CGAffineTransform(translationX: corner.x, y: corner.y))
            blades.addPath(arm)
        }

        return octagon.subtracting(opening).subtracting(blades)
    }
}

/// The mark on the dark plate it lives on in the Dock, at whatever size is
/// asked for. Used where a screen has nothing to show and would otherwise be
/// an empty grey rectangle with a sentence on it.
struct UnburyBadge: View {
    var size: CGFloat = 30
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(Theme.bg)
            .overlay(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .stroke(Theme.accent.opacity(0.28)))
            .overlay(
                UnburyMark().fill(Theme.accent)
                    .frame(width: size * 0.46, height: size * 0.46)
            )
            .frame(width: size, height: size)
    }
}

/// What the screen says when there are no rows to show. A marker names the
/// state, a rule ties it to the left edge, and the tone carries whether this is
/// an ordinary outcome or something that went wrong.
struct Notice<Actions: View>: View {
    let title: String
    let body_: String
    var marker: String?
    var tone: Color
    @ViewBuilder var actions: Actions

    init(title: String, body: String, marker: String? = nil, tone: Color = Theme.faintest,
         @ViewBuilder actions: () -> Actions = { EmptyView() }) {
        self.title = title; self.body_ = body
        self.marker = marker; self.tone = tone; self.actions = actions()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Rectangle().fill(tone).frame(width: 2).frame(maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 0) {
                if let marker {
                    Marker(text: marker, color: tone == Theme.faintest ? Theme.fainter : tone)
                        .padding(.bottom, 8)
                }
                Text(title).font(Theme.sans(15)).foregroundStyle(Theme.ink)
                Text(body_).font(Theme.sans(13)).foregroundStyle(Theme.dim)
                    .lineSpacing(3.5).padding(.top, 7)
                HStack(spacing: 8) { actions }.padding(.top, 14)
            }
            .frame(maxWidth: 520, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, 44).padding(.leading, Metric.rail).padding(.trailing, Metric.gutter)
    }
}


/// macOS 26 draws a hairline and a soft blur at the edges of anything that
/// scrolls. On a light interface it separates; on this one it reads as a
/// rectangle someone left behind. Hidden everywhere, from one place.
extension View {
    @ViewBuilder func noScrollEdge() -> some View {
        // The app runs from macOS 14, where this edge does not exist yet.
        if #available(macOS 26.0, *) {
            scrollEdgeEffectHidden(true, for: .all)
        } else {
            self
        }
    }
}

/// The rest of a sentence, on request. A panel says one line; the reasoning
/// behind a paid choice is still worth having, so it sits under a mark the size
/// of a full stop rather than in front of the controls it explains.
struct MoreInfo: View {
    let text: String
    @State private var open = false
    @State private var hovering = false

    var body: some View {
        Button { open.toggle() } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 11))
                .foregroundStyle(open || hovering ? Theme.dim : Theme.faintest)
        }
        .buttonStyle(.plain).clickable()
        .onHover { hovering = $0 }
        .popover(isPresented: $open, arrowEdge: .bottom) {
            Text(text)
                .font(Theme.sans(12.5)).foregroundStyle(Theme.dim)
                .lineSpacing(3.5).fixedSize(horizontal: false, vertical: true)
                .frame(width: 280, alignment: .leading)
                .padding(14)
        }
    }
}
