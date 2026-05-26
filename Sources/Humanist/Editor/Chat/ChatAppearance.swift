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

    /// Type-family choice for the chat surface. Two stock system
    /// fonts (`system` → SF Pro, `serif` → New York on macOS 26)
    /// plus four named alternatives that all ship with stock
    /// macOS — no font bundling, no licensing concerns, no
    /// fallback path when the user's system doesn't have them.
    /// Monospace stays reserved for code blocks regardless of
    /// choice; SF Mono is the universal target there.
    ///
    /// Sans-serif options: SF Pro (system), Avenir, Helvetica Neue.
    /// Serif options: New York (system serif), Charter, Hoefler Text.
    ///
    /// Charter is Matthew Carter's screen-optimized serif —
    /// widely considered the best body-text serif on Apple
    /// platforms at small sizes. Hoefler Text is the closest
    /// stock substitute for Garamond (old-style serif, warm,
    /// editorial feel) since macOS doesn't bundle Garamond.
    enum FontFamily: String, CaseIterable, Identifiable {
        case system
        case avenir
        case helveticaNeue
        case serif
        case charter
        case hoeflerText

        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .system:        return "SF Pro (System)"
            case .avenir:        return "Avenir"
            case .helveticaNeue: return "Helvetica Neue"
            case .serif:         return "New York (System Serif)"
            case .charter:       return "Charter"
            case .hoeflerText:   return "Hoefler Text"
            }
        }

        /// Sans-serif vs. serif grouping for the Settings picker.
        /// Drives the Section header so the dropdown reads as
        /// two named groups rather than a flat alphabetical list.
        var isSerif: Bool {
            switch self {
            case .system, .avenir, .helveticaNeue:
                return false
            case .serif, .charter, .hoeflerText:
                return true
            }
        }

        /// Build a `Font` of the requested size + weight in this
        /// family. The two system fonts route through
        /// `.system(size:weight:design:)` so the user's system
        /// appearance / accessibility settings apply. Named fonts
        /// route through `.custom(_:size:)` + `.weight()` since
        /// `.system(design:)` only covers the stock SF Pro / New
        /// York pair.
        func font(size: CGFloat, weight: Font.Weight = .regular) -> Font {
            switch self {
            case .system:
                return .system(size: size, weight: weight, design: .default)
            case .serif:
                return .system(size: size, weight: weight, design: .serif)
            case .avenir:
                return Font.custom("Avenir", size: size).weight(weight)
            case .helveticaNeue:
                return Font.custom("Helvetica Neue", size: size)
                    .weight(weight)
            case .charter:
                return Font.custom("Charter", size: size).weight(weight)
            case .hoeflerText:
                return Font.custom("Hoefler Text", size: size)
                    .weight(weight)
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
        return Resolved(
            baseFont:           family.font(size: base),
            // Code stays system-monospaced regardless of family.
            // SF Mono / Menlo is the universal target; named-font
            // monospace variants don't exist for Avenir / Charter /
            // Hoefler Text, and even when they do (Helvetica Neue
            // doesn't ship one) the mixed-pair Avenir + SF Mono
            // looks more cohesive than Avenir + a faked monospace.
            codeFont:           .system(size: base, design: .monospaced),
            // Italic stacks on the family font — Font.italic()
            // works on both .system(...) and .custom(...) returns.
            italicFont:         family.font(size: base).italic(),
            heading1Font:       family.font(size: base + 6, weight: .semibold),
            heading2Font:       family.font(size: base + 3, weight: .semibold),
            headingDefaultFont: family.font(size: base, weight: .semibold),
            colorScheme:        mode.preferredColorScheme
        )
    }
}
