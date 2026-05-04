import Foundation

/// UserDefaults-backed list of recently-opened EPUBs and PDFs that
/// drives the File > Open Recent submenu. Entries are stored as a
/// JSON-encoded array of absolute path strings so SwiftUI's
/// `@AppStorage` can observe writes via the same key and re-render
/// the menu without manual notifications.
enum RecentsStore {
    static let key = "humanist.recents.json"
    static let maxCount = 10

    /// Read the current list of recently-opened URLs (most recent first).
    /// Filters out files that no longer exist so stale entries don't
    /// linger in the menu.
    static var urls: [URL] {
        guard let str = UserDefaults.standard.string(forKey: key),
              let data = str.data(using: .utf8),
              let raw = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return raw.compactMap { URL(string: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Bring `url` to the front of the list. If the URL is already
    /// present, it's moved (not duplicated). Caps the list at
    /// `maxCount`.
    static func add(_ url: URL) {
        var list = urls.filter { $0 != url }
        list.insert(url, at: 0)
        if list.count > maxCount { list = Array(list.prefix(maxCount)) }
        write(list)
    }

    /// Reset the menu — File > Open Recent > Clear Menu.
    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    private static func write(_ list: [URL]) {
        let strings = list.map { $0.absoluteString }
        if let data = try? JSONEncoder().encode(strings),
           let str = String(data: data, encoding: .utf8) {
            UserDefaults.standard.set(str, forKey: key)
        }
    }
}
