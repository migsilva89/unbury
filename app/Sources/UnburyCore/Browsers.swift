import Foundation

/// Finding the browsers on this Mac and reading their bookmarks.
///
/// Every Chromium browser keeps the same file in the same shape, so one reader
/// covers Brave, Chrome, Arc, Edge and Vivaldi. Nothing is ever written back:
/// the browser is where links are saved in a hurry, and the vault is where they
/// end up. Safari and Firefox use different formats and are not read.
public struct Browsers: Sendable {
    public struct Profile: Identifiable, Sendable, Hashable {
        public let browser: String
        /// What the person called it — "Copo", "canweFPV" — not the folder it
        /// lives in. A list of ten identical "Profile 4"s is unusable, and the
        /// browser has known the real name all along.
        public let name: String
        /// The account signed into it, when there is one. Two profiles can
        /// share a name; two Google accounts cannot.
        public let account: String
        public let file: URL
        public let count: Int
        public var id: String { file.path }
        public var label: String { "\(browser) · \(name)" }
    }

    private static let known: [(String, String)] = [
        ("Brave", "BraveSoftware/Brave-Browser"),
        ("Chrome", "Google/Chrome"),
        ("Arc", "Arc/User Data"),
        ("Edge", "Microsoft Edge"),
        ("Vivaldi", "Vivaldi"),
    ]

    /// Every profile that actually holds bookmarks, biggest first.
    public static func installed() -> [Profile] {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask)[0]
        var found: [Profile] = []
        for (browser, path) in known {
            let root = support.appendingPathComponent(path)
            let named = displayNames(in: root)
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil) else { continue }
            for entry in entries {
                let file = entry.appendingPathComponent("Bookmarks")
                guard FileManager.default.fileExists(atPath: file.path) else { continue }
                let links = (try? read(file))?.count ?? 0
                guard links > 0 else { continue }
                let folder = entry.lastPathComponent
                let known = named[folder]
                found.append(Profile(browser: browser,
                                     name: known?.0 ?? (folder == "Default" ? "Default" : folder),
                                     account: known?.1 ?? "",
                                     file: file, count: links))
            }
        }
        return found.sorted { $0.count > $1.count }
    }

    /// Chromium keeps what each profile is actually called in `Local State`,
    /// keyed by the folder name. Without it every profile reads "Profile 11".
    private static func displayNames(in root: URL) -> [String: (String, String)] {
        let state = root.appendingPathComponent("Local State")
        guard let data = try? Data(contentsOf: state),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profile = json["profile"] as? [String: Any],
              let cache = profile["info_cache"] as? [String: Any] else { return [:] }
        var names: [String: (String, String)] = [:]
        for (folder, value) in cache {
            guard let entry = value as? [String: Any] else { continue }
            let name = (entry["name"] as? String) ?? folder
            let account = (entry["user_name"] as? String) ?? ""
            names[folder] = (name, account)
        }
        return names
    }

    public struct Link: Sendable, Hashable {
        public let url: String
        public let title: String
        public let folder: String
        public let savedOn: String
    }

    /// Chromium counts microseconds since 1601, not 1970.
    private static let chromiumEpoch = Date(timeIntervalSince1970: -11_644_473_600)

    public static func read(_ file: URL) throws -> [Link] {
        let data = try Data(contentsOf: file)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let roots = root["roots"] as? [String: Any] else { return [] }
        var links: [Link] = []
        func walk(_ node: [String: Any], _ path: String) {
            if node["type"] as? String == "url",
               let url = node["url"] as? String, url.hasPrefix("http") {
                var savedOn = ""
                if let raw = node["date_added"] as? String, let micros = Double(raw) {
                    let date = chromiumEpoch.addingTimeInterval(micros / 1_000_000)
                    let format = DateFormatter()
                    format.dateFormat = "yyyy-MM-dd"
                    savedOn = format.string(from: date)
                }
                links.append(Link(url: url,
                                  title: (node["name"] as? String) ?? "",
                                  folder: path.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
                                  savedOn: savedOn))
            }
            for child in (node["children"] as? [[String: Any]]) ?? [] {
                walk(child, path + "/" + ((node["name"] as? String) ?? ""))
            }
        }
        for value in roots.values {
            if let node = value as? [String: Any] { walk(node, "") }
        }
        return links
    }
}
