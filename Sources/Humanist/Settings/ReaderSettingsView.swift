import SwiftUI

/// Reader preferences pane in the Settings scene. Today holds the
/// open-target routing picker — where double-clicking an EPUB
/// (and every other path that flows through `OpenRouter.open`)
/// lands. Other reader knobs (font face, line spacing, margins,
/// theme) live in the reader window's toolbar popover (⌃⌘A) so
/// they're discoverable while reading, not buried in Settings.
///
/// Promoting any of those toolbar knobs to this pane is fine in
/// the future; the @AppStorage keys are already shared.
struct ReaderSettingsView: View {
    @AppStorage(ReaderSettingsKeys.openTarget)
    private var openTargetRaw: String = ReaderOpenTarget.reader.rawValue

    private var openTarget: Binding<ReaderOpenTarget> {
        Binding(
            get: { ReaderOpenTarget(rawValue: openTargetRaw) ?? .reader },
            set: { openTargetRaw = $0.rawValue }
        )
    }

    var body: some View {
        Form {
            Section("Opening books") {
                Picker(
                    "Double-click opens books in",
                    selection: openTarget
                ) {
                    ForEach(ReaderOpenTarget.allCases) { target in
                        Label(target.displayName, systemImage: target.systemImage)
                            .tag(target)
                    }
                }
                .pickerStyle(.menu)
                Text(routingDescription)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Reading appearance") {
                Text("Font face, line spacing, margins, and theme live in the reader window's toolbar popover (⌃⌘A) so they're at hand while you're reading. Changes apply immediately to the open book — no reload.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding()
    }

    /// One-paragraph explainer that updates with the picker. The
    /// "fallback path" line matters because it's the bit that
    /// surprises users — picking Source Editor doesn't remove the
    /// reader; it just makes the editor primary.
    private var routingDescription: String {
        switch openTarget.wrappedValue {
        case .reader:
            return "Library double-click, File → Open, drag-drop, and Recents all open EPUBs in the reader. Use the reader's “Edit Source…” action (⌥⌘O) or Window → Show Editor (⌘3) to reach the source editor."
        case .editor:
            return "Library double-click, File → Open, drag-drop, and Recents all open EPUBs in the source editor. Use Window → Show Reader (⌘5) to read in the reader window."
        }
    }
}
