import Foundation
import SwiftUI

/// User-facing editor preferences. Persisted directly via
/// `@AppStorage` (one key per setting, kept simple) rather than as
/// a single Codable blob — the panes need to observe individual
/// values and re-render on change without parsing the whole struct.
///
/// Values flow:
///   * Settings UI writes via `@AppStorage` → UserDefaults.
///   * Editor panes read via `@AppStorage` and push the new value
///     through their JS bridges (CodeMirror's `humanistSetTheme`
///     etc., or the preview's injected CSS).
public enum EditorSettingsKeys {
    /// CodeMirror font size in points (10–24).
    public static let sourceFontSize = "humanist.editor.sourceFontSize"
    /// Theme override for the source pane: "system" / "light" / "dark".
    public static let sourceTheme = "humanist.editor.sourceTheme"
    /// Show CodeMirror's line-number gutter.
    public static let sourceLineNumbers = "humanist.editor.sourceLineNumbers"
    /// Wrap long lines instead of horizontal scroll.
    public static let sourceWordWrap = "humanist.editor.sourceWordWrap"
    /// Preview pane base font size in points (12–24).
    public static let previewFontSize = "humanist.editor.previewFontSize"
    /// Theme override for the preview pane: "system" / "light" / "dark".
    public static let previewTheme = "humanist.editor.previewTheme"
    /// WYSIWYG pane font family token: "system" / "serif" / "monospace".
    public static let wysiwygFontFamily = "humanist.editor.wysiwygFontFamily"
    /// WYSIWYG pane font size in points (12–24).
    public static let wysiwygFontSize = "humanist.editor.wysiwygFontSize"
    /// Theme override for the WYSIWYG pane: "system" / "light" / "dark".
    public static let wysiwygTheme = "humanist.editor.wysiwygTheme"
}

/// Font-family token for WYSIWYG / preview rendering. Resolves to a
/// CSS `font-family` stack — we don't expose arbitrary fonts to keep
/// the picker tight and the rendered output portable.
public enum EditorFontFamily: String, CaseIterable, Identifiable, Sendable {
    case system, serif, monospace
    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .system:    return "System"
        case .serif:     return "Serif"
        case .monospace: return "Monospace"
        }
    }

    /// CSS font-family stack. Uses generic family names so the
    /// browser picks the platform's idiomatic typeface.
    public var cssStack: String {
        switch self {
        case .system:
            return "-apple-system, BlinkMacSystemFont, \"Helvetica Neue\", system-ui, sans-serif"
        case .serif:
            return "\"New York\", \"Iowan Old Style\", Charter, Georgia, serif"
        case .monospace:
            return "ui-monospace, \"SF Mono\", \"Menlo\", monospace"
        }
    }
}

/// Three-way theme selector — `system` honors the OS appearance
/// (current behavior); `light` / `dark` force the pane regardless
/// of the system setting. Stored as a string for easy
/// `@AppStorage` interop.
public enum EditorThemeMode: String, CaseIterable, Identifiable, Sendable {
    case system, light, dark
    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .system: return "Match system"
        case .light:  return "Light"
        case .dark:   return "Dark"
        }
    }
}

/// Defaults the editor uses on first launch and that the Settings
/// pane resets to. Centralized so the editor and the settings UI
/// stay in lockstep.
public enum EditorSettingsDefaults {
    public static let sourceFontSize: Double = 12
    public static let sourceTheme: String = EditorThemeMode.system.rawValue
    public static let sourceLineNumbers: Bool = true
    public static let sourceWordWrap: Bool = true
    public static let previewFontSize: Double = 16
    public static let previewTheme: String = EditorThemeMode.system.rawValue
    public static let wysiwygFontFamily: String = EditorFontFamily.serif.rawValue
    public static let wysiwygFontSize: Double = 16
    public static let wysiwygTheme: String = EditorThemeMode.system.rawValue
}
