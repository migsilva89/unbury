import AppKit
import QuartzCore
import SwiftUI

/// The app photographing its own window.
///
/// Screen capture from outside needs a system permission granted to whatever
/// process runs the command, and that is a decision for the person using the
/// Mac. A window can always draw itself, so this needs no permission at all —
/// it exists so the interface can be looked at while it is being built.
@MainActor
enum Snapshot {
    static func write(to path: String) -> String {
        // A sheet is a separate window *attached* to the main one — not the key
        // window, and not first in the list. Ask the main window for it, so a
        // picture taken while a sheet is up shows the sheet.
        let main = NSApp.windows.first { $0.isVisible && $0.frame.height > 200 }
        guard let window = main?.attachedSheet ?? NSApp.keyWindow ?? main,
              let view = window.contentView else { return "no window" }
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return "could not prepare a bitmap"
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            return "could not encode"
        }
        do {
            try data.write(to: URL(fileURLWithPath: path))
            return "\(bitmap.pixelsWide)x\(bitmap.pixelsHigh) → \(path)"
        } catch {
            return error.localizedDescription
        }
    }

    /// Watch for a file appearing beside the mirror, act on it, delete it.
    /// A crude channel on purpose: no port, no protocol, nothing left open. It
    /// exists so the interface can be driven while it is being built — asking a
    /// question and reading back what happened, without clicking.
    static func listen(model: AppModel) {
        let request = dataDirectory.appendingPathComponent("snapshot-please")
        Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { _ in
            guard let raw = try? String(contentsOf: request, encoding: .utf8) else { return }
            try? FileManager.default.removeItem(at: request)
            let command = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let answer = request.appendingPathExtension("result")

            // The tab is called Ask Unbury, and `ask` is its name here. `dig`
            // was the name for part of an afternoon and still works, so
            // anything written down in between keeps running.
            if command.hasPrefix("dig ") || command.hasPrefix("ask ") {
                let question = String(command.dropFirst(4))
                Task { @MainActor in
                    model.tab = .ask
                    await model.ask(question)
                    try? transcript(model).write(to: answer, atomically: true, encoding: .utf8)
                }
                return
            }
            // Sheets cannot be opened from a keyboard shortcut in a test, so the
            // channel opens them by name. Only sheets: nothing here performs an
            // action that spends money or changes what is saved.
            if command == "import" || command == "settings" {
                Task { @MainActor in
                    if command == "import" { model.showImport = true } else { model.showSettings = true }
                    try? "ok".write(to: answer, atomically: true, encoding: .utf8)
                }
                return
            }
            if command == "close" {
                Task { @MainActor in
                    model.showImport = false
                    model.showSettings = false
                    try? "ok".write(to: answer, atomically: true, encoding: .utf8)
                }
                return
            }
            if command.hasPrefix("tab ") {
                let asked = String(command.dropFirst(4))
                Task { @MainActor in
                    // This tab's raw value was "ask", then "dig", and is "ask"
                    // again. Anything written down in between still runs.
                    let name = asked == "dig" ? "ask" : asked
                    model.tab = AppModel.Tab(rawValue: name) ?? .search
                    try? "ok".write(to: answer, atomically: true, encoding: .utf8)
                }
                return
            }
            // Narrowing is a click on a word in the cloud, and the cloud has no
            // keyboard way in. `tag drones fpv` turns both on; naming one that
            // is already on turns it off, so a multiple selection can be built
            // up and taken apart from here.
            // Resize the window, so a screen can be looked at at the size
            // somebody actually keeps it rather than only at full height.
            if command.hasPrefix("size ") {
                let parts = command.dropFirst(5).split(separator: "x").compactMap { Double($0) }
                Task { @MainActor in
                    guard parts.count == 2,
                          let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.height > 200 })
                    else {
                        try? "need `size WIDTHxHEIGHT`".write(to: answer, atomically: true, encoding: .utf8)
                        return
                    }
                    var frame = window.frame
                    frame.origin.y += frame.height - parts[1]
                    frame.size = CGSize(width: parts[0], height: parts[1])
                    window.setFrame(frame, display: true)
                    try? "ok".write(to: answer, atomically: true, encoding: .utf8)
                }
                return
            }
            if command.hasPrefix("tag ") {
                let names = String(command.dropFirst(4)).split(separator: " ").map(String.init)
                Task { @MainActor in
                    model.tab = .search
                    for name in names {
                        if model.scopeSet.contains(name) {
                            model.widen(from: name)
                        } else {
                            model.narrow(to: name)
                        }
                    }
                    try? "ok".write(to: answer, atomically: true, encoding: .utf8)
                }
                return
            }
            // The next page of the list inside the chosen tags. It answers with
            // the count, because the button that asks for it sits below the
            // fold and a picture of the window cannot prove it moved.
            // Choosing a row is a click, and a click is the one thing this
            // channel cannot do. `select 3` opens the third row on screen.
            if command.hasPrefix("select ") {
                let wanted = Int(command.dropFirst(7)) ?? 0
                Task { @MainActor in
                    let rows = model.visible.isEmpty ? model.browse
                                                     : model.visible.map(\.bookmark)
                    guard wanted > 0, wanted <= rows.count else {
                        try? "only \(rows.count) rows".write(to: answer, atomically: true, encoding: .utf8)
                        return
                    }
                    model.selected = rows[wanted - 1]
                    try? rows[wanted - 1].displayTitle.write(to: answer, atomically: true, encoding: .utf8)
                }
                return
            }
            // Deleting, which is the one command here that changes what is
            // saved — so it is two words, as it is two acts on screen. `mark 3`
            // ticks the third row, `delete` asks about everything ticked,
            // `delete 3` asks about the third row alone, and `delete confirm`
            // is the only thing that actually deletes. Nothing goes on one word.
            if command == "delete" || command.hasPrefix("delete ") {
                let argument = String(command.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                Task { @MainActor in
                    var said = ""
                    if argument == "confirm" {
                        let going = model.pendingDeletion.count
                        guard going > 0 else {
                            try? "nothing is being asked about".write(to: answer, atomically: true, encoding: .utf8)
                            return
                        }
                        let gone = await model.confirmDeletion()
                        said = "deleted \(gone) of \(going) · \(model.count) left"
                    } else if argument == "cancel" {
                        model.cancelDeletion()
                        said = "cancelled"
                    } else if argument.isEmpty {
                        let going = model.markedBookmarks
                        guard !going.isEmpty else {
                            try? "nothing ticked — `mark <n>` first".write(to: answer, atomically: true, encoding: .utf8)
                            return
                        }
                        model.askToDelete(going)
                        said = "asking about \(going.count) · `delete confirm` to go through with it"
                    } else if let nth = Int(argument) {
                        let rows = model.visible.isEmpty ? model.browse
                                                         : model.visible.map(\.bookmark)
                        guard nth >= 1, nth <= rows.count else {
                            try? "only \(rows.count) rows".write(to: answer, atomically: true, encoding: .utf8)
                            return
                        }
                        model.askToDelete([rows[nth - 1]])
                        said = "asking about “\(rows[nth - 1].displayTitle)” · `delete confirm` to go through with it"
                    } else {
                        said = "need `delete`, `delete <n>`, `delete confirm` or `delete cancel`"
                    }
                    try? said.write(to: answer, atomically: true, encoding: .utf8)
                }
                return
            }
            // Ticking a row for deleting with others, which is a click on a box
            // that only appears under the pointer.
            if command.hasPrefix("mark") {
                let argument = String(command.dropFirst(4)).trimmingCharacters(in: .whitespaces)
                Task { @MainActor in
                    let rows = model.visible.isEmpty ? model.browse
                                                     : model.visible.map(\.bookmark)
                    var said = "ok"
                    if argument.isEmpty || argument == "none" {
                        model.clearMarks()
                        said = "nothing ticked"
                    } else if let nth = Int(argument), nth >= 1, nth <= rows.count {
                        model.toggleMark(rows[nth - 1].id)
                        said = "\(model.marked.count) ticked"
                    } else {
                        said = "need `mark <n>` of \(rows.count) rows, or `mark none`"
                    }
                    try? said.write(to: answer, atomically: true, encoding: .utf8)
                }
                return
            }
            if command.hasPrefix("findtag") {
                let text = String(command.dropFirst(7)).trimmingCharacters(in: .whitespaces)
                Task { @MainActor in
                    model.tab = .search
                    model.tagFilter = text
                    try? "ok".write(to: answer, atomically: true, encoding: .utf8)
                }
                return
            }
            // Park the list at a fraction of its length, so it can be
            // photographed at the top, the middle and the end.
            if command.hasPrefix("scrollat ") {
                let share = (Double(command.dropFirst(9)) ?? 0) / 100
                Task { @MainActor in
                    try? ScrollProbe.park(at: share).write(to: answer, atomically: true,
                                                          encoding: .utf8)
                }
                return
            }
            // Scroll the list and time it. A scroll wheel cannot be sent to
            // this window from outside without a permission that belongs to the
            // person, so the list is walked from within and the main thread is
            // watched while it happens — which is the thing being measured.
            if command.hasPrefix("scroll") {
                let step = Int(command.dropFirst(6).trimmingCharacters(in: .whitespaces)) ?? 10
                Task { @MainActor in
                    let report = await ScrollProbe.sweep(model: model, step: max(1, step))
                    try? report.write(to: answer, atomically: true, encoding: .utf8)
                }
                return
            }
            if command == "more" {
                Task { @MainActor in
                    await model.loadMore()
                    let state = "showing \(model.browse.count) of \(model.scopeCount)"
                    try? state.write(to: answer, atomically: true, encoding: .utf8)
                }
                return
            }
            // Opening a record an answer cited, which is a click on a row in the
            // evidence panel. `cite 2` opens the second one.
            if command.hasPrefix("cite ") {
                Task { @MainActor in
                    model.tab = .ask
                    let evidence = model.conversation.evidence
                    guard let nth = Int(command.dropFirst(5)),
                          nth >= 1, nth <= evidence.count else {
                        try? "need `cite <n>`".write(to: answer, atomically: true, encoding: .utf8)
                        return
                    }
                    model.open(evidence[nth - 1].bookmark)
                    try? "opened \(evidence[nth - 1].bookmark.displayTitle)"
                        .write(to: answer, atomically: true, encoding: .utf8)
                }
                return
            }
            // The Ask screen's conversation list, which is a click on a panel
            // and a click on a row — neither of which a test can make. `chat`
            // alone shows or hides the list; `chat new` starts a conversation;
            // `chat 2` opens the second one in it.
            if command == "chat" || command.hasPrefix("chat ") {
                let argument = String(command.dropFirst(4)).trimmingCharacters(in: .whitespaces)
                Task { @MainActor in
                    model.tab = .ask
                    let conversation = model.conversation
                    var said = "ok"
                    if argument.isEmpty {
                        conversation.historyOpen.toggle()
                        if conversation.historyOpen { conversation.evidenceOpen = false }
                        said = conversation.historyOpen ? "list shown" : "list hidden"
                    } else if argument == "evidence" {
                        conversation.evidenceOpen.toggle()
                        if conversation.evidenceOpen { conversation.historyOpen = false }
                        said = conversation.evidenceOpen ? "evidence shown" : "evidence hidden"
                    } else if argument == "new" {
                        conversation.startNew()
                        said = "new conversation"
                    } else if let nth = Int(argument),
                              nth >= 1, nth <= conversation.history.count {
                        let summary = conversation.history[nth - 1]
                        await conversation.open(summary, from: model.store)
                        said = "opened \(summary.title)"
                    } else {
                        said = "need `chat`, `chat new` or `chat <n>`"
                    }
                    try? said.write(to: answer, atomically: true, encoding: .utf8)
                }
                return
            }
            // Put words in the field WITHOUT searching — which is what typing
            // does, and the only way to see what the screen looks like between
            // a question being typed and being asked.
            if command == "type" || command.hasPrefix("type ") {
                // Bare `type` empties the field, which is the case worth seeing.
                let text = String(command.dropFirst(4)).trimmingCharacters(in: .whitespaces)
                Task { @MainActor in
                    model.tab = .search
                    model.query = text
                    try? "ok".write(to: answer, atomically: true, encoding: .utf8)
                }
                return
            }
            if command.hasPrefix("search ") {
                Task { @MainActor in
                    model.tab = .search
                    model.query = String(command.dropFirst(7))
                    model.search()
                    try? "ok".write(to: answer, atomically: true, encoding: .utf8)
                }
                return
            }
            // Photographing the window touches AppKit, so it has to happen on the
            // main actor like every other command above rather than on whatever
            // thread noticed the file.
            Task { @MainActor in
                try? write(to: command).write(to: answer, atomically: true, encoding: .utf8)
            }
        }
    }

    @MainActor
    private static func transcript(_ model: AppModel) -> String {
        guard let turn = model.conversation.turns.last else { return "no turn" }
        var out = "engine: \(turn.engine.label)\n"
        for call in turn.calls {
            out += "SEARCH \(call.number): \"\(call.query)\" — \(call.status)\n"
            for hit in call.hits.prefix(3) {
                out += String(format: "    %.2f  %@\n", hit.score,
                              String(hit.bookmark.displayTitle.prefix(58)))
            }
        }
        if let error = turn.error { out += "ERROR: \(error)\n" }
        if let dead = turn.deadEnd { out += "DEAD END: \(dead)\n" }
        for part in turn.parts {
            out += "\n\(part.text)"
            if !part.citations.isEmpty { out += " " + part.citations.map { "[\($0)]" }.joined() }
        }
        out += String(format: "\n\ncost: $%.4f · evidence: %d records", turn.cost, turn.cited.count)
        return out
    }
}

import UnburyCore
private let dataDirectory = UnburyStore.defaultDirectory


/// Scrolling the list from top to bottom and back, timing the main thread while
/// it happens.
///
/// The complaint this exists to settle is "it breaks on scroll", and eyes are
/// not evidence. It drives the real scroll view — the same `NSScrollView` a
/// wheel moves, in the same small steps — rather than jumping between rows,
/// because asking SwiftUI to scroll *to* a row in a lazy stack makes it measure
/// everything in between, which is a cost a wheel never pays and would make the
/// figures say something that is not true of using the app.
///
/// A repeating timer fires every 8ms. If the main thread is busy laying rows
/// out its next turn comes late, and the gap between two fires is how long the
/// window was frozen for. Over 33ms is two dropped frames at 60Hz and is felt.
@MainActor
enum ScrollProbe {
    /// Somewhere to collect the gaps from inside the timer's callback.
    @MainActor private final class Watch {
        var gaps: [Double] = []
        var last = CACurrentMediaTime()
    }

    /// The tallest scroll view on screen, which is the list of links.
    private static func list() -> NSScrollView? {
        guard let root = NSApp.windows
            .first(where: { $0.isVisible && $0.frame.height > 200 })?.contentView
        else { return nil }
        var found: [NSScrollView] = []
        func walk(_ view: NSView) {
            if let scroller = view as? NSScrollView { found.append(scroller) }
            view.subviews.forEach(walk)
        }
        walk(root)
        return found.max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }
    }

    static func park(at share: Double) -> String {
        guard let scroller = list(), let paper = scroller.documentView else { return "no list" }
        let clip = scroller.contentView
        let span = max(0, paper.frame.height - clip.bounds.height)
        let y = span * min(max(share, 0), 1)
        clip.scroll(to: NSPoint(x: 0, y: y))
        scroller.reflectScrolledClipView(clip)
        return String(format: "at %.0fpt of %.0f", y, span)
    }

    static func sweep(model: AppModel, step: Int) async -> String {
        guard let scroller = list(), let paper = scroller.documentView else {
            return "no list on screen"
        }
        let clip = scroller.contentView
        let span = paper.frame.height - clip.bounds.height
        guard span > 40 else {
            return "the list is \(Int(paper.frame.height))pt tall and fits — nothing to scroll"
        }

        let watch = Watch()
        let ticker = Timer(timeInterval: 1.0 / 120, repeats: true) { _ in
            MainActor.assumeIsolated {
                let now = CACurrentMediaTime()
                watch.gaps.append((now - watch.last) * 1000)
                watch.last = now
            }
        }
        RunLoop.main.add(ticker, forMode: .common)

        // A wheel moves a few points at a time. Down the whole list, then back.
        let pitch = CGFloat(max(1, step))
        var stops = Array(stride(from: CGFloat(0), through: span, by: pitch))
        stops += stops.reversed()

        watch.last = CACurrentMediaTime()
        let started = watch.last
        for y in stops {
            clip.scroll(to: NSPoint(x: 0, y: y))
            scroller.reflectScrolledClipView(clip)
            try? await Task.sleep(for: .milliseconds(8))
        }
        ticker.invalidate()
        let total = CACurrentMediaTime() - started

        // The first gap is the time from arming the timer to its first fire and
        // says nothing about scrolling.
        let gaps = watch.gaps.dropFirst().sorted()
        guard !gaps.isEmpty else { return "no frames observed" }
        func at(_ share: Double) -> Double {
            gaps[min(gaps.count - 1, Int(Double(gaps.count) * share))]
        }
        return String(format: """
            %d rows · %.0fpt of list · %d steps of %.0fpt · %.2f s there and back
            main-thread gap  median %.1f ms · p95 %.1f ms · worst %.1f ms
            over 33 ms (two dropped frames): %d of %d turns
            """, model.browse.count, paper.frame.height, stops.count, pitch, total,
            at(0.5), at(0.95), gaps.last ?? 0, gaps.filter { $0 > 33 }.count, gaps.count)
    }
}
