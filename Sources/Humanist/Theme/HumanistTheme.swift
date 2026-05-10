import SwiftUI
import AppKit

/// Theme identity — each is a distinct palette + typography pairing
/// the user can switch between in Settings → Appearance. Stored
/// under `humanist.theme` in UserDefaults; default is `.system`.
enum HumanistThemeID: String, CaseIterable, Identifiable {
    case system
    case parchment
    case scholarly
    case studio

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system:    return "System"
        case .parchment: return "Parchment"
        case .scholarly: return "Scholarly"
        case .studio:    return "Studio"
        }
    }

    var blurb: String {
        switch self {
        case .system:    return "Default macOS appearance with the system accent color."
        case .parchment: return "Warm cream paper, muted terracotta accent. Quiet and unhurried."
        case .scholarly: return "Cream background, deep navy accent, serif titles. Reference-press feel."
        case .studio:    return "Bright white surface with a vibrant rose accent. Modern lab aesthetic."
        }
    }

    /// Whether this theme prefers serif titles in display contexts
    /// (drop-zone hero, library row title, window subtitles, etc.).
    var usesSerifTitles: Bool {
        switch self {
        case .parchment, .scholarly: return true
        case .system, .studio:       return false
        }
    }
}

/// Single source of truth for the user's chosen theme. SwiftUI's
/// `@AppStorage` propagates within one window's view hierarchy
/// reliably but is *not* reliable across multi-window scenes on
/// macOS — switching the theme in Settings would update some
/// windows immediately and leave others on the previous palette
/// until they redrew for unrelated reasons.
///
/// Exposed as a shared singleton so the chrome modifier and the
/// settings picker both observe the same instance via
/// `@ObservedObject`. We deliberately avoided `@EnvironmentObject`
/// here: the chrome modifier sits at the top of every window's
/// view chain, where the env propagated *up* from inner
/// `.environmentObject` calls isn't visible — the env would have
/// to be set as the outermost modifier on every scene, easy to
/// get wrong, and the lookup failure crashes at runtime.
@MainActor
final class HumanistThemeStore: ObservableObject {
    static let shared = HumanistThemeStore()
    /// `nonisolated` so `HumanistTheme.current` (a free helper) can
    /// read it from any context. Truly immutable — String literal.
    nonisolated static let storageKey = "humanist.theme"

    @Published var themeID: HumanistThemeID {
        didSet {
            UserDefaults.standard.set(themeID.rawValue, forKey: Self.storageKey)
        }
    }

    init() {
        let raw = UserDefaults.standard.string(forKey: Self.storageKey) ?? ""
        self.themeID = HumanistThemeID(rawValue: raw) ?? .system
    }
}

/// Palette accessors. Static properties resolve dynamically each
/// time AppKit asks for a color, so the next redraw picks up the
/// current theme. `HumanistChromeModifier` triggers that redraw
/// across every window when the shared `HumanistThemeStore`
/// publishes a change.
enum HumanistTheme {
    static var current: HumanistThemeID {
        let raw = UserDefaults.standard.string(forKey: HumanistThemeStore.storageKey) ?? ""
        return HumanistThemeID(rawValue: raw) ?? .system
    }

    // Computed (not stored) so each access returns a fresh
    // `Color` whose identity reflects the current theme. SwiftUI's
    // environment diffing for `.tint` / `.background` keys on
    // value identity, so a stored-let `Color` (same identity
    // whose underlying NSColor closure resolves at draw time)
    // wouldn't propagate to descendant Toggles / Buttons / etc.
    // when the user picks a new theme.
    static var accent: Color          { dynamic(.accent) }
    static var accentMuted: Color     { dynamic(.accentMuted) }
    static var background: Color      { dynamic(.background) }
    static var surface: Color         { dynamic(.surface) }
    static var inkPrimary: Color      { dynamic(.inkPrimary) }
    static var inkSecondary: Color    { dynamic(.inkSecondary) }
    static var inkTertiary: Color     { dynamic(.inkTertiary) }
    static var divider: Color         { dynamic(.divider) }

    /// Display-context font that respects the current theme's
    /// serif-titles preference. `.system(.title3, design: ...)`
    /// won't reactively change on its own, so callers should use
    /// this inside views attached to `.humanistChrome()` (the
    /// chrome's @AppStorage observation triggers re-evaluation).
    static func displayFont(_ style: Font.TextStyle) -> Font {
        if current.usesSerifTitles {
            return .system(style, design: .serif)
        }
        return .system(style)
    }

    enum Slot {
        case accent, accentMuted, background, surface
        case inkPrimary, inkSecondary, inkTertiary, divider
    }

    private static func dynamic(_ slot: Slot) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            return color(slot, in: current, dark: dark)
        })
    }

    private static func color(_ slot: Slot, in theme: HumanistThemeID, dark: Bool) -> NSColor {
        switch theme {
        case .system:    return SystemPalette.color(slot, dark: dark)
        case .parchment: return ParchmentPalette.color(slot, dark: dark)
        case .scholarly: return ScholarlyPalette.color(slot, dark: dark)
        case .studio:    return StudioPalette.color(slot, dark: dark)
        }
    }
}

// MARK: - palettes

private enum SystemPalette {
    static func color(_ slot: HumanistTheme.Slot, dark: Bool) -> NSColor {
        switch slot {
        case .accent:        return .controlAccentColor
        case .accentMuted:   return .controlAccentColor.withAlphaComponent(0.14)
        case .background:    return .windowBackgroundColor
        case .surface:       return .controlBackgroundColor
        case .inkPrimary:    return .labelColor
        case .inkSecondary:  return .secondaryLabelColor
        case .inkTertiary:   return .tertiaryLabelColor
        case .divider:       return .separatorColor
        }
    }
}

private enum ParchmentPalette {
    static func color(_ slot: HumanistTheme.Slot, dark: Bool) -> NSColor {
        switch slot {
        case .accent:        return dark ? hex(0xD78062) : hex(0xC4684A)
        case .accentMuted:   return dark ? hex(0xD78062, alpha: 0.16) : hex(0xC4684A, alpha: 0.12)
        case .background:    return dark ? hex(0x1E1B17) : hex(0xF5F1EB)
        case .surface:       return dark ? hex(0x28241F) : hex(0xEBE6DD)
        case .inkPrimary:    return dark ? hex(0xE8E4DC) : hex(0x2A2A28)
        case .inkSecondary:  return dark ? hex(0x999388) : hex(0x6B6760)
        case .inkTertiary:   return dark ? hex(0x6B665E) : hex(0x9A9489)
        case .divider:       return dark ? hex(0x3A352C) : hex(0xDDD7CB)
        }
    }
}

private enum ScholarlyPalette {
    static func color(_ slot: HumanistTheme.Slot, dark: Bool) -> NSColor {
        switch slot {
        // Deep navy in light mode (#1B2A4E); warm gold in dark mode
        // since navy on near-black would disappear.
        case .accent:        return dark ? hex(0xC9A961) : hex(0x1B2A4E)
        case .accentMuted:   return dark ? hex(0xC9A961, alpha: 0.16) : hex(0x1B2A4E, alpha: 0.10)
        case .background:    return dark ? hex(0x1A1612) : hex(0xF6F0DF)
        case .surface:       return dark ? hex(0x231D17) : hex(0xEDE6D2)
        case .inkPrimary:    return dark ? hex(0xEDE6D2) : hex(0x2A2418)
        case .inkSecondary:  return dark ? hex(0x9C927E) : hex(0x6E6451)
        case .inkTertiary:   return dark ? hex(0x6E6552) : hex(0x9C9079)
        case .divider:       return dark ? hex(0x3A3025) : hex(0xDCD4BD)
        }
    }
}

private enum StudioPalette {
    /// DeepLearning.AI-inspired: vivid rose accent on near-white,
    /// crisp grey borders, modern sans throughout.
    static func color(_ slot: HumanistTheme.Slot, dark: Bool) -> NSColor {
        switch slot {
        case .accent:        return dark ? hex(0xF472B6) : hex(0xEC4899)
        case .accentMuted:   return dark ? hex(0xF472B6, alpha: 0.18) : hex(0xEC4899, alpha: 0.10)
        case .background:    return dark ? hex(0x0F0F13) : hex(0xFFFFFF)
        case .surface:       return dark ? hex(0x1A1A1F) : hex(0xF3F4F6)
        case .inkPrimary:    return dark ? hex(0xF3F4F6) : hex(0x111827)
        case .inkSecondary:  return dark ? hex(0x9CA3AF) : hex(0x6B7280)
        case .inkTertiary:   return dark ? hex(0x6B7280) : hex(0x9CA3AF)
        case .divider:       return dark ? hex(0x2A2A33) : hex(0xE5E7EB)
        }
    }
}

private func hex(_ rgb: UInt32, alpha: CGFloat = 1.0) -> NSColor {
    let r = CGFloat((rgb >> 16) & 0xFF) / 255.0
    let g = CGFloat((rgb >> 8)  & 0xFF) / 255.0
    let b = CGFloat( rgb        & 0xFF) / 255.0
    return NSColor(red: r, green: g, blue: b, alpha: alpha)
}

// MARK: - chrome modifier

extension View {
    /// Apply the Humanist theme to a window scene. Reads the current
    /// theme via `@AppStorage` so changing it in Settings forces a
    /// redraw across every chrome-wrapped surface.
    func humanistChrome() -> some View {
        modifier(HumanistChromeModifier())
    }
}

private struct HumanistChromeModifier: ViewModifier {
    func body(content: Content) -> some View {
        // ViewModifiers with `@ObservedObject` properties don't
        // reliably re-render when the observed object publishes.
        // Wrapping content in a real `View` (not a ViewModifier)
        // gives SwiftUI a stable subscription point — the View's
        // `body` re-evaluates on every store mutation, which
        // forces a redraw of `content` and AppKit re-resolves the
        // dynamic NSColors that back the palette.
        ChromedView(content: content)
    }
}

private struct ChromedView<Content: View>: View {
    @ObservedObject private var store = HumanistThemeStore.shared
    let content: Content

    var body: some View {
        let theme = store.themeID
        let base = content.tint(HumanistTheme.accent)
        if theme == .system {
            base
        } else {
            base.background(HumanistTheme.background)
        }
    }
}
