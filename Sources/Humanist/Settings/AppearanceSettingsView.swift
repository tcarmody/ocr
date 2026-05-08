import SwiftUI

/// Settings → Appearance. Lets the user pick among the bundled
/// themes (System / Parchment / Scholarly / Nocturne / Studio).
/// Selection writes to `humanist.theme`; every window's
/// `humanistChrome()` re-renders on the change.
struct AppearanceSettingsView: View {
    @EnvironmentObject private var store: HumanistThemeStore

    var body: some View {
        Form {
            Section("Theme") {
                ForEach(HumanistThemeID.allCases) { theme in
                    ThemeRow(theme: theme, selection: $store.themeID)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

private struct ThemeRow: View {
    let theme: HumanistThemeID
    @Binding var selection: HumanistThemeID

    var body: some View {
        Button {
            selection = theme
        } label: {
            HStack(spacing: 14) {
                ThemeSwatch(theme: theme)
                    .frame(width: 56, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(theme.displayName)
                            .font(.headline)
                        if selection == theme {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                        }
                    }
                    Text(theme.blurb)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Three-band swatch showing each theme's accent + surface + ink.
/// Renders the actual NSColors the palette resolves so the swatch
/// always reflects the live colors (handy if we tweak hex values
/// later).
private struct ThemeSwatch: View {
    let theme: HumanistThemeID

    var body: some View {
        GeometryReader { proxy in
            let dark = (theme.forcedColorScheme == .dark)
            HStack(spacing: 0) {
                Color(nsColor: PaletteSnapshot.color(.background, theme: theme, dark: dark))
                    .frame(width: proxy.size.width * 0.55)
                Color(nsColor: PaletteSnapshot.color(.surface, theme: theme, dark: dark))
                    .frame(width: proxy.size.width * 0.25)
                Color(nsColor: PaletteSnapshot.color(.accent, theme: theme, dark: dark))
            }
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5)
            )
        }
    }
}

/// A non-dynamic snapshot of the palette for the swatch — we want
/// each row to *show* its target appearance regardless of the
/// system's current light/dark setting (so the user can preview
/// what they're picking).
private enum PaletteSnapshot {
    static func color(
        _ slot: HumanistTheme.Slot,
        theme: HumanistThemeID,
        dark: Bool
    ) -> NSColor {
        // For System theme the palette is dynamic — sample at the
        // app's current effective appearance.
        if theme == .system {
            let appearance = NSApp.effectiveAppearance
            let isDark = appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            return systemColor(slot, dark: isDark)
        }
        return paletteColor(slot, theme: theme, dark: dark)
    }

    private static func systemColor(_ slot: HumanistTheme.Slot, dark: Bool) -> NSColor {
        switch slot {
        case .accent:        return .controlAccentColor
        case .background:    return .windowBackgroundColor
        case .surface:       return .controlBackgroundColor
        default:             return .labelColor
        }
    }

    private static func paletteColor(
        _ slot: HumanistTheme.Slot, theme: HumanistThemeID, dark: Bool
    ) -> NSColor {
        // Mirror the dispatch table in `HumanistTheme.color(...)` —
        // the palettes are private there but we reproduce the
        // accent/background/surface trio here for the swatch.
        // Keep these in sync with the canonical palette file.
        switch theme {
        case .system:
            return systemColor(slot, dark: dark)
        case .parchment:
            switch slot {
            case .accent:     return dark ? hex(0xD78062) : hex(0xC4684A)
            case .background: return dark ? hex(0x1E1B17) : hex(0xF5F1EB)
            case .surface:    return dark ? hex(0x28241F) : hex(0xEBE6DD)
            default:          return dark ? hex(0xE8E4DC) : hex(0x2A2A28)
            }
        case .scholarly:
            switch slot {
            case .accent:     return dark ? hex(0xC9A961) : hex(0x1B2A4E)
            case .background: return dark ? hex(0x1A1612) : hex(0xF6F0DF)
            case .surface:    return dark ? hex(0x231D17) : hex(0xEDE6D2)
            default:          return dark ? hex(0xEDE6D2) : hex(0x2A2418)
            }
        case .nocturne:
            switch slot {
            case .accent:     return hex(0xD4A659)
            case .background: return hex(0x121212)
            case .surface:    return hex(0x1B1B1B)
            default:          return hex(0xE6DFCF)
            }
        case .studio:
            switch slot {
            case .accent:     return dark ? hex(0xF472B6) : hex(0xEC4899)
            case .background: return dark ? hex(0x0F0F13) : hex(0xFFFFFF)
            case .surface:    return dark ? hex(0x1A1A1F) : hex(0xF3F4F6)
            default:          return dark ? hex(0xF3F4F6) : hex(0x111827)
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
