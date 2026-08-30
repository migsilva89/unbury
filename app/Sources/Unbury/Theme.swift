import SwiftUI

/// The palette and type of the Unbury design, in one place. Colours are the
/// design's own hex values rather than semantic names, because the design is the
/// source of truth and a rename here would drift from it silently.
enum Theme {
    static let bg = Color(hex: 0x100F0F)
    static let panel = Color(hex: 0x1C1B1A)
    static let raised = Color(hex: 0x232221)
    static let line = Color(hex: 0x282726)
    static let line2 = Color(hex: 0x343331)
    // The design's own greys, lifted. On the flat panel of a design tool they
    // read fine; on a real display, at 12–13px, #878580 body text on #100F0F is
    // under 4:1 and unreadable at arm's length. Each step moved up two notches
    // and the darkest three now only ever carry decoration, never words.
    static let ink = Color(hex: 0xE6E4DC)
    static let ink2 = Color(hex: 0xCECDC3)
    static let dim = Color(hex: 0xACA9A1)      // body text — 8:1, was 0x878580
    static let faint = Color(hex: 0x8C8983)    // labels, dates — 6:1
    // Sentences do get written in this one (the withheld note, the vector
    // caption), so it has to clear 4.5:1 at 10–11px, which 0x736F69 did not.
    static let fainter = Color(hex: 0x7E7A74)
    static let faintest = Color(hex: 0x545049) // lines, rules and dots only
    // MARK: - The accent, and the three places it is allowed to go
    //
    // The mark is a teal bookmark on near-black, and this is that teal. It is
    // the only saturated colour the interface owns, which makes it the only
    // thing the eye goes to first — so spending it is a decision, not a
    // decoration. Painted everywhere it says nothing; the design's original
    // rule was that teal means "this one is right", and a teal button next to
    // a teal score would have killed that sentence.
    //
    // It resolves into three tiers, told apart by FORM as much as by colour:
    //
    //   1. THE MARK — identity. The bookmark glyph, and only in the chrome:
    //      the top bar, and the plate an empty screen sits under. Never inside
    //      content, so it cannot be mistaken for a result saying something.
    //
    //   2. THE SIGNAL — teal as ink, hairline, wash, or a small mark (a tick,
    //      a radio, a meter bar, the working pulse). One meaning, phrased three
    //      ways: this is the machine's own voice. It is confident (score >=
    //      strong), it is working, or this is the thing you turned on.
    //
    //   3. THE WAY FORWARD — a solid teal plate with near-black text: the one
    //      action that moves this screen on. "Import 214", "Done", "ask",
    //      "Try again". ONE per screen, never two, and never inside a row —
    //      a plate is the loudest thing here and two of them cancel out.
    //
    // Grey carries inactive and secondary controls. A selected control uses a
    // solid accent plate so its state is immediately visible.
    static let accent = Color(hex: 0x3AA99F)
    /// What sits ON a solid accent plate. Near-black on #3AA99F is 6.6:1; white
    /// on the same teal is 2.4:1, so the dark ink is the only readable choice
    /// and the plate borrows the icon's own background while it is at it.
    static let onAccent = Color(hex: 0x100F0F)
    /// Tier 2 in its two quiet forms: a tint you feel rather than see, and an
    /// edge strong enough to read as chosen without becoming a plate.
    static let accentWash = Color(hex: 0x3AA99F).opacity(0.10)
    static let accentEdge = Color(hex: 0x3AA99F).opacity(0.45)
    static let link = Color(hex: 0x66A0C8)
    static let warn = Color(hex: 0xD0A215)
    static let bad = Color(hex: 0xD14D41)

    /// One knob for the size of every word in the app. The design was drawn at
    /// a size that reads on a design tool's flat canvas and too small on a real
    /// display at arm's length — rather than retune forty call sites, every
    /// size in the app goes through here. Rounded to whole points so stems
    /// stay on the pixel grid and the type does not go soft.
    static let typeScale: CGFloat = 1.15
    static func size(_ size: CGFloat) -> CGFloat { (size * typeScale).rounded() }

    static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom("IBM Plex Sans", size: Theme.size(size)).weight(weight)
    }
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom("IBM Plex Mono", size: Theme.size(size)).weight(weight)
    }
}

/// The measurements a result row is built from. They live here and not inside
/// the row because the list header, the empty states and the ghost rows all have
/// to sit on the same columns — the design is a three-column grid
/// (44 / rest / 116) and it only reads as one when every state uses these.
enum Metric {
    static let gutter: CGFloat = 18       // the page's left and right margin
    static let rail: CGFloat = 16         // rows start 2pt in: the selection bar
    static let thumb: CGFloat = 48
    static let meta: CGFloat = 128
    static let column: CGFloat = 13       // gap between the three columns
    static let rowHeight: CGFloat = 86    // fixed, so the eye can scan the scores
    /// Where the title's baseline falls inside a row, measured from the top of
    /// the row's content. Everything on the top line hangs off this.
    static let titleBaseline: CGFloat = 12
}

/// The three columns of a row share one horizontal line: the title's baseline.
/// Aligning tops instead — which is what a plain HStack does — leaves the 11pt
/// date floating above the 13.5pt title, and the whole list looks hand-placed.
extension VerticalAlignment {
    private enum RowTitle: AlignmentID {
        static func defaultValue(in context: ViewDimensions) -> CGFloat {
            context[.firstTextBaseline]
        }
    }
    static let rowTitle = VerticalAlignment(RowTitle.self)
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

/// A label in the mono face, used for the small capitalised markers the design
/// leans on: SEARCH 1, EVIDENCE, READ-ONLY.
struct Marker: View {
    let text: String
    var color: Color = Theme.fainter
    var body: some View {
        Text(text)
            .font(Theme.mono(10, .medium))
            .tracking(1)
            .foregroundStyle(color)
    }
}
