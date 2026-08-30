import AppKit
import Sparkle

/// The standard macOS update window: find, verify, install and reopen Unbury.
///
/// Sparkle owns the schedule and the one preference behind it, so the menu item,
/// the Settings panel and the check that happens on its own cannot drift into
/// three different answers to the same question. Nothing about updates is
/// written into `Preferences` for that reason.
///
/// Started when the window opens: starting the updater is what makes it consider
/// checking, and nobody should have to open Settings to learn that a newer build
/// already exists.
@MainActor
enum Updates {
    private static let controller = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )
    private static var started = false

    /// Read straight off the bundle so the number on screen is the number that
    /// shipped, and cannot fall behind a constant somebody forgot to bump.
    nonisolated static var current: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
    }

    static var automaticallyChecksForUpdates: Bool {
        get {
            start()
            return controller.updater.automaticallyChecksForUpdates
        }
        set {
            start()
            controller.updater.automaticallyChecksForUpdates = newValue
        }
    }

    static func start() {
        guard !started else { return }
        started = true
        controller.startUpdater()
    }

    static func checkNow() {
        start()
        controller.checkForUpdates(nil)
    }
}
