import Dispatch
import Foundation
import SwiftUI
import UnburyCore

struct UnburyApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window("Unbury", id: "unbury") {
            RootView()
                .environment(model)
                // Small enough that the layouts which adapt below 820pt — the record
                // drawer taking over the window rather than sitting beside the list —
                // can actually be reached on a laptop screen.
                .frame(minWidth: 720, minHeight: 520)
                // Sparkle is started here rather than the first time somebody
                // opens Settings: an updater that only wakes when you go looking
                // for it never checks by itself, and the first person to run
                // this had to find the button to be told there was a new
                // version at all.
                .task { Updates.start(); await model.start(); Snapshot.listen(model: model) }
        }
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .defaultSize(width: 1180, height: 760)
        .commands {
            // Where macOS puts it in every other app: directly under "About
            // Unbury", not with the window commands. Somebody looking for an
            // update looks in one place.
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { Updates.checkNow() }.clickable()
            }
            CommandGroup(after: .toolbar) {
                Button("Import from browser…") { model.showImport = true }.clickable()
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                Divider()
                Button("Settings…") { model.showSettings = true }.clickable()
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

/// Decide whether this process is the app or its command-line front end before
/// SwiftUI creates NSApplication. The shipped `unburyctl` is a symlink to this
/// executable, so both routes have the same code signature and Keychain identity.
@main
enum UnburyEntryPoint {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).lastPathComponent
        let isCommand = executable == "unburyctl"
            || arguments.first.map(UnburyCLI.commands.contains) == true

        guard isCommand else {
            UnburyApp.main()
            return
        }

        Task.detached {
            do {
                try await UnburyCLI.run(arguments: arguments)
                exit(0)
            } catch {
                FileHandle.standardError.write(
                    Data(("error: \(error.localizedDescription)\n").utf8)
                )
                exit(1)
            }
        }
        dispatchMain()
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            TopBar()
            switch model.tab {
            case .search: SearchView()
            case .ask: AskView()
            case .landscape: LandscapeView()
            case .settings: SettingsView()
            }
            // Only under Search, where these keys are the truth. Ask Unbury and the
            // others drive nothing of the sort, and a strip promising "↑↓ move"
            // over a screen where nothing moves is worse than no strip at all.
            if model.tab == .search { KeyStrip() }
        }
        .sheet(isPresented: Binding(get: { model.showImport },
                                    set: { model.showImport = $0 })) {
            ImportSheet().environment(model)
        }
        .background(Theme.bg)
        // macOS draws a rounded focus ring around whatever holds the keyboard.
        // When that is a scrolling region — anything the question field is not —
        // the ring is a box around half the window, which reads as a stray
        // frame rather than as "the keyboard is here". Disabled for the whole
        // app because the app already says where focus is in its own terms: the
        // question field's edge turns teal, the open tab is teal, the selected
        // row carries a bar.
        .focusEffectDisabled()
        // macOS 26 draws a hairline and a soft blur at the edge of anything
        // that scrolls. On a light interface it separates; on this one it read
        // as a rectangle someone had left behind, and it never showed up in the
        // app's own screenshots because the system composites it afterwards.
        .noScrollEdge()
        .preferredColorScheme(.dark)
        .environment(\.font, Theme.sans(13.5))
    }
}

/// The keys of the Search screen, under the list they drive rather than beside
/// the tabs. Quiet by design: this is a reminder for the second visit, not a
/// thing to read. Shown only on Search — see RootView.
struct KeyStrip: View {
    private let keys = [("/", "search"), ("↑↓", "move"), ("↵", "open"), ("esc", "back")]

    var body: some View {
        HStack(spacing: 6) {
            Spacer(minLength: 0)
            ForEach(keys, id: \.0) { key in
                Text(key.0).font(Theme.mono(10)).foregroundStyle(Theme.fainter)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(Theme.line))
                Text(key.1).font(Theme.mono(10)).foregroundStyle(Theme.fainter)
                    .padding(.trailing, 6)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 30)
        .background(Theme.panel)
    }
}

struct TopBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 14) {
            // Tier 1 of the accent scheme: the aperture from the app icon, at the
            // size it stays crisp, so the window and the thing in the Dock are
            // obviously one object. It is the only teal in this bar — the tabs
            // are navigation and navigation stays grey.
            // Centred on the capitals, not on the text box: all-caps type has no
            // descenders, so its box hangs lower than the letters do and a mark
            // centred on the box reads as if it has slipped.
            HStack(spacing: 7) {
                UnburyMark().fill(Theme.accent).frame(width: 15, height: 15)
                    .offset(y: -1.5)
                Text("Unbury").font(Theme.sans(13, .medium))
                    .foregroundStyle(Theme.ink2)
            }
            Rectangle().fill(Theme.line).frame(width: 1, height: 14)
            Text(meta).font(Theme.mono(11)).foregroundStyle(Theme.faint)
                .monospacedDigit()
            Spacer(minLength: 8)

            // Ask Unbury stands outside the group, because it is not one of
            // three destinations — it is the way into what the app is for.
            // Search and Landscape stay a quiet pair in their box beside it.
            //
            // Accent OUTLINE, and never a filled plate: filled accent belongs to
            // the single primary action of whatever screen you are on, and
            // spending it on navigation would leave every screen carrying two.
            // Being on the tab deepens the wash and the stroke; it never fills.
            Button { model.tab = .ask } label: {
                HStack(spacing: 7) {
                    UnburyMark().fill(Theme.accent).frame(width: 13, height: 13)
                        .offset(y: -0.5)
                    Text(AppModel.Tab.ask.label)
                        .font(Theme.sans(12.5, .semibold))
                        .foregroundStyle(Theme.accent)
                }
                .padding(.horizontal, 13).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(Theme.accent.opacity(model.tab == .ask ? 0.16 : 0.06)))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .stroke(Theme.accent.opacity(model.tab == .ask ? 0.9 : 0.45)))
            }
            .buttonStyle(.plain).clickable()
            .help("Ask a question — Unbury searches your links and answers from them")

            HStack(spacing: 2) {
                ForEach([AppModel.Tab.search, .landscape], id: \.rawValue) { tab in
                    Button { model.tab = tab } label: {
                        Text(tab.label)
                            .font(Theme.sans(12, model.tab == tab ? .medium : .regular))
                            .foregroundStyle(model.tab == tab ? Theme.accent : Theme.faint)
                            .padding(.horizontal, 11).padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 4)
                                .fill(model.tab == tab ? Theme.accent.opacity(0.14) : .clear))
                    }
                    .buttonStyle(.plain).clickable()
                }
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.panel))

            Button { model.showImport = true } label: {
                Text("Import").font(Theme.sans(12))
                    .foregroundStyle(Theme.ink2)
                    .padding(.horizontal, 11).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Theme.line2))
            }
            .buttonStyle(.plain).clickable()
            .help("Read your browser's bookmarks and describe what is new. It says what it costs first.")

            Button { model.showSettings = model.tab != .settings } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(model.tab == .settings ? Theme.accent : Theme.ink2)
                    .padding(.horizontal, 7).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 5)
                        .fill(model.tab == .settings ? Theme.accent.opacity(0.14) : Theme.line2))
            }
            .buttonStyle(.plain).clickable()
            .help("Settings")
        }
        .padding(.horizontal, 14)
        .frame(height: 42)
        .background(Theme.panel)
    }

    private var meta: String {
        guard model.count > 0 else { return "empty — import to begin" }
        return "\(model.count) links"
    }
}
