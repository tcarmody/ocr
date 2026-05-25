import Foundation

/// One topic in the Humanist help system. The case order is the
/// display order in the help window's sidebar; the rawValue is
/// the bundled Markdown filename (without extension) under
/// `Resources/Help/`. Hyphen-prefixed numeric ordering on disk
/// just keeps the files in display order in Finder; the
/// `displayTitle` is what users see.
///
/// Adding a new topic: drop a new `.md` file under
/// `Sources/Humanist/Resources/Help/`, add a case here with the
/// matching filename + title, and the help window's sidebar
/// picks it up on next launch.
enum HelpTopic: String, CaseIterable, Identifiable, Sendable {
    case overview      = "00-overview"
    case converting    = "01-converting"
    case reading       = "02-reading"
    case chatting      = "03-chatting"
    case library       = "04-library"
    case cli           = "05-cli"

    var id: String { rawValue }

    /// Sidebar / menu label.
    var displayTitle: String {
        switch self {
        case .overview:    return "Overview"
        case .converting:  return "Converting Documents"
        case .reading:     return "Reading"
        case .chatting:    return "Chatting with Books"
        case .library:     return "Managing Your Library"
        case .cli:         return "Command Line"
        }
    }

    /// SF Symbol for the sidebar row + Help-menu icon.
    var symbol: String {
        switch self {
        case .overview:    return "house"
        case .converting:  return "doc.text.image"
        case .reading:     return "book"
        case .chatting:    return "bubble.left.and.text.bubble.right"
        case .library:     return "books.vertical"
        case .cli:         return "terminal"
        }
    }

    /// Read the Markdown source from the app's bundle. Returns
    /// nil when the resource is missing (development build without
    /// the resource processed, file deleted, etc.); the help
    /// viewer renders a fallback error message in that case.
    /// Files are loaded synchronously on demand — at <10 KB each
    /// the cost is in the noise; no need to cache.
    func loadMarkdown() -> String? {
        guard let url = Bundle.module.url(
            forResource: rawValue, withExtension: "md", subdirectory: "Help"
        ) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}
