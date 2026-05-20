import Foundation
import SwiftUI

/// User-facing reader preferences. Same posture as
/// `EditorSettingsKeys` — one `@AppStorage` key per setting,
/// observed directly by the view that cares about it. Most of
/// the reader's other knobs (font face, line spacing, margins,
/// theme) already live as `humanist.reader.*` keys read by
/// `ReaderView` for live-update via the appearance JS bridge;
/// those don't need a constant here because there's only one
/// reader of them. This file holds the keys that cross
/// view boundaries — currently just the default-open routing
/// that `OpenRouter.open` reads off the main view tree.
public enum ReaderSettingsKeys {
    /// Where double-clicking an EPUB (or any other route through
    /// `OpenRouter.open`) lands: the reader scene or the editor
    /// scene. Stored as `ReaderOpenTarget.rawValue`. Default is
    /// `.reader` so the existing post-R-Reader behavior holds
    /// for users who never touch Settings.
    public static let openTarget = "humanist.reader.openTarget"
}

/// Choice for where `.epub` opens go by default. Read by
/// `OpenRouter.open` to dispatch the right window scene.
/// Persisted as the raw value, so existing UserDefaults
/// records (none yet) round-trip cleanly.
public enum ReaderOpenTarget: String, CaseIterable, Identifiable, Sendable {
    case reader, editor

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .reader: return "Reader"
        case .editor: return "Source Editor"
        }
    }

    public var systemImage: String {
        switch self {
        case .reader: return "book"
        case .editor: return "text.cursor"
        }
    }

    /// Helper for non-view sites (e.g. `OpenRouter.open`) that
    /// need to read the user's choice off `UserDefaults` without
    /// a SwiftUI environment. Defaults to `.reader` when the key
    /// is absent or holds a stray value.
    public static var current: ReaderOpenTarget {
        let raw = UserDefaults.standard.string(
            forKey: ReaderSettingsKeys.openTarget
        ) ?? ReaderOpenTarget.reader.rawValue
        return ReaderOpenTarget(rawValue: raw) ?? .reader
    }
}
