import SwiftUI
import AppKit

/// "Anthropic-adjacent warm minimal" palette. Warm cream / parchment
/// backgrounds, muted terracotta accent, warm-grey ink for body text.
/// Adapts to light + dark.
///
/// Apply via `.tint(HumanistTheme.accent)` + `.humanistChrome()` at
/// each window scene. Direct callers can pull from `HumanistTheme`
/// for one-offs.
enum HumanistTheme {
    /// Single-source-of-truth palette. Each color resolves from the
    /// dynamic `NSColor` factory below so light / dark variants
    /// follow the system appearance without per-call branching.
    static let accent          = Color(nsColor: dynamic(.accent))
    static let accentMuted     = Color(nsColor: dynamic(.accentMuted))
    static let background      = Color(nsColor: dynamic(.background))
    static let surface         = Color(nsColor: dynamic(.surface))
    static let inkPrimary      = Color(nsColor: dynamic(.inkPrimary))
    static let inkSecondary    = Color(nsColor: dynamic(.inkSecondary))
    static let inkTertiary     = Color(nsColor: dynamic(.inkTertiary))
    static let divider         = Color(nsColor: dynamic(.divider))

    /// Serif used for window titles + library row headings. New
    /// York is built-in; falls back to the system serif elsewhere.
    static let titleSerif = Font.system(.title2, design: .serif)
    static let bodySerif  = Font.system(.body, design: .serif)

    private enum Slot {
        case accent
        case accentMuted
        case background
        case surface
        case inkPrimary
        case inkSecondary
        case inkTertiary
        case divider
    }

    private static func dynamic(_ slot: Slot) -> NSColor {
        NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            switch slot {
            case .accent:
                // Muted terracotta. Slightly brighter in dark mode
                // so it reads against the deeper background without
                // glowing.
                return dark
                    ? hex(0xD78062)
                    : hex(0xC4684A)
            case .accentMuted:
                return dark
                    ? hex(0xD78062, alpha: 0.16)
                    : hex(0xC4684A, alpha: 0.12)
            case .background:
                // Warm parchment in light mode; deep warm
                // near-black in dark mode (not pure #000 — pure
                // black with cream accents reads as broken).
                return dark ? hex(0x1E1B17) : hex(0xF5F1EB)
            case .surface:
                // One step inset from background — used for cards,
                // table-row strips, popovers.
                return dark ? hex(0x28241F) : hex(0xEBE6DD)
            case .inkPrimary:
                return dark ? hex(0xE8E4DC) : hex(0x2A2A28)
            case .inkSecondary:
                return dark ? hex(0x999388) : hex(0x6B6760)
            case .inkTertiary:
                return dark ? hex(0x6B665E) : hex(0x9A9489)
            case .divider:
                return dark ? hex(0x3A352C) : hex(0xDDD7CB)
            }
        }
    }

    private static func hex(_ rgb: UInt32, alpha: CGFloat = 1.0) -> NSColor {
        let r = CGFloat((rgb >> 16) & 0xFF) / 255.0
        let g = CGFloat((rgb >> 8)  & 0xFF) / 255.0
        let b = CGFloat( rgb        & 0xFF) / 255.0
        return NSColor(red: r, green: g, blue: b, alpha: alpha)
    }
}

extension View {
    /// Apply the Humanist theme: accent tint + window-background
    /// override. Attach once at the top of each window scene.
    func humanistChrome() -> some View {
        self
            .tint(HumanistTheme.accent)
            .background(HumanistTheme.background)
    }
}
