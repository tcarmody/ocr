import SwiftUI

/// User-customizable appearance for the chat surface (per-book +
/// library + standalone window). Three knobs: font family, font
/// size, and color scheme. Persisted as `@AppStorage` so the
/// selection sticks across sessions; resolved on every chat-pane
/// body recompute so a Settings change propagates without a
/// window relaunch.
///
/// Scope is deliberately narrow — the goal is "looks the way the
/// user wants to read" without inventing a full theming system.
/// Bubble color, message density, and per-role font overrides
/// are deferred to a Phase 2 if real use surfaces a need.
enum ChatAppearance {

    // MARK: - User-tunable types

    /// Type-family choice. `system` follows SF Pro (matches the
    /// rest of macOS chrome); `serif` swaps to the system serif
    /// (New York on macOS 26) for users who find serifs easier
    /// for long-form reading. Monospace stays reserved for code
    /// blocks regardless of choice — the variant derives from
    /// the picked family rather than overriding it.
    enum FontFamily: String, CaseIterable, Identifiable {
        case system
        case serif

        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .system: return "System (sans-serif)"
            case .serif:  return "Serif"
            }
        }

        /// SwiftUI design value passed to `.system(size:design:)`.
        var design: Font.Design {
            switch self {
            case .system: return .default
            case .serif:  return .serif
            }
        }
    }

    /// Discrete size buckets. Specific point sizes (not relative
    /// to a text style) so the chat pane's typography is
    /// predictable independent of the system Dynamic Type
    /// setting. The medium size matches the previous hard-coded
    /// `.callout` (13pt on macOS) so existing users see no
    /// change until they explicitly opt in.
    enum FontSize: String, CaseIterable, Identifiable {
        case small
        case medium
        case large
        case extraLarge

        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .small:      return "Small"
            case .medium:     return "Medium"
            case .large:      return "Large"
            case .extraLarge: return "Extra Large"
            }
        }
        var basePoints: CGFloat {
            switch self {
            case .small:      return 11
            case .medium:     return 13   // matches the prior .callout default
            case .large:      return 15
            case .extraLarge: return 17
            }
        }
    }

    /// Color-scheme override. `auto` defers to the system
    /// (followsAccentColor + light/dark from System Settings).
    /// `light` / `dark` force the chat surface regardless of
    /// system. Useful when the surrounding app is at a different
    /// brightness than the user wants for reading (force-dark
    /// chat in a daytime light-mode app, or vice versa).
    enum ColorMode: String, CaseIterable, Identifiable {
        case auto
        case light
        case dark

        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .auto:  return "Match System"
            case .light: return "Light"
            case .dark:  return "Dark"
            }
        }

        /// SwiftUI `.preferredColorScheme(...)` value — nil for
        /// auto so the chat surface inherits whatever the
        /// surrounding window uses.
        var preferredColorScheme: ColorScheme? {
            switch self {
            case .auto:  return nil
            case .light: return .light
            case .dark:  return .dark
            }
        }
    }

    // MARK: - UserDefaults keys

    enum Keys {
        static let fontFamily = "humanist.chat.appearance.fontFamily"
        static let fontSize   = "humanist.chat.appearance.fontSize"
        static let colorMode  = "humanist.chat.appearance.colorMode"
    }

    // MARK: - Resolved snapshot

    /// One concrete appearance configuration, derived from the
    /// `@AppStorage` keys. Carries pre-computed `Font` values
    /// for each block kind the chat renders so neither
    /// `MarkdownMessageBody` nor `ChatMessageRow` has to
    /// re-derive them per message.
    struct Resolved: Equatable {
        let baseFont: Font
        let codeFont: Font
        let italicFont: Font
        let heading1Font: Font
        let heading2Font: Font
        let headingDefaultFont: Font
        let colorScheme: ColorScheme?

        func headingFont(level: Int) -> Font {
            switch level {
            case 1: return heading1Font
            case 2: return heading2Font
            default: return headingDefaultFont
            }
        }
    }

    /// Resolve the current `@AppStorage` values into a `Resolved`
    /// snapshot. Callers read from UserDefaults to make this
    /// runnable from contexts (init, helpers) that aren't a View
    /// body; views that need to re-render on changes bind via
    /// `@AppStorage` themselves and then call this with the
    /// observed values.
    static func resolve(
        family: FontFamily,
        size: FontSize,
        mode: ColorMode
    ) -> Resolved {
        let base = size.basePoints
        let design = family.design
        return Resolved(
            baseFont:           .system(size: base, design: design),
            codeFont:           .system(size: base, design: .monospaced),
            // Italic is a separate font variant — set on top of
            // the base size + design so it composes properly.
            italicFont:         .system(size: base, design: design).italic(),
            heading1Font:       .system(size: base + 6, weight: .semibold, design: design),
            heading2Font:       .system(size: base + 3, weight: .semibold, design: design),
            headingDefaultFont: .system(size: base, weight: .semibold, design: design),
            colorScheme:        mode.preferredColorScheme
        )
    }
}
