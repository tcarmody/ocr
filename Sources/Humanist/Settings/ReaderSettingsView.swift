import SwiftUI

/// Reader preferences pane in the Settings scene. Mirrors the
/// layout / styling of `EditorSettingsView` and
/// `AppearanceSettingsView` — `.formStyle(.grouped)` over a
/// fixed-width Form, three substantive sections (Opening, Default
/// layout, Reading appearance) plus Restore Defaults.
///
/// All values are persisted directly via `@AppStorage`. The font
/// face / line spacing / margins / theme keys are shared with the
/// reader window's toolbar popover (⌃⌘A) — both surfaces drive the
/// same JS appearance bridge, so changes here apply immediately to
/// any open reader window. The layout + chat-sidebar defaults are
/// read once at reader-window init, so changes apply on the next
/// book open (the in-place toggles in the reader's toolbar still
/// override per-window).
struct ReaderSettingsView: View {
    @AppStorage(ReaderSettingsKeys.openTarget)
    private var openTargetRaw: String = ReaderOpenTarget.reader.rawValue

    @AppStorage("humanist.reader.paginated")
    private var paginatedDefault: Bool = false
    @AppStorage("humanist.reader.showChatPane")
    private var chatPaneDefault: Bool = false

    @AppStorage("humanist.reader.fontFamily")
    private var fontFamilyRaw: String = ReaderFontFamily.serif.rawValue
    @AppStorage(EditorSettingsKeys.previewFontSize)
    private var fontSize: Double = EditorSettingsDefaults.previewFontSize
    @AppStorage("humanist.reader.lineHeight")
    private var lineHeight: Double = 1.5
    @AppStorage("humanist.reader.marginEm")
    private var marginEm: Double = 2.0
    @AppStorage("humanist.reader.theme")
    private var themeRaw: String = ReaderTheme.system.rawValue

    private var openTarget: Binding<ReaderOpenTarget> {
        Binding(
            get: { ReaderOpenTarget(rawValue: openTargetRaw) ?? .reader },
            set: { openTargetRaw = $0.rawValue }
        )
    }
    private var fontFamily: Binding<ReaderFontFamily> {
        Binding(
            get: { ReaderFontFamily(rawValue: fontFamilyRaw) ?? .serif },
            set: { fontFamilyRaw = $0.rawValue }
        )
    }
    private var theme: Binding<ReaderTheme> {
        Binding(
            get: { ReaderTheme(rawValue: themeRaw) ?? .system },
            set: { themeRaw = $0.rawValue }
        )
    }

    var body: some View {
        Form {
            Section("Opening books") {
                Picker("Double-click opens books in", selection: openTarget) {
                    ForEach(ReaderOpenTarget.allCases) { target in
                        Label(target.displayName, systemImage: target.systemImage)
                            .tag(target)
                    }
                }
                .pickerStyle(.menu)
                Text(openTargetCaption)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Default layout") {
                Picker("Layout", selection: $paginatedDefault) {
                    Label("Scroll", systemImage: "scroll").tag(false)
                    Label("Paginated", systemImage: "rectangle.split.2x1").tag(true)
                }
                .pickerStyle(.segmented)
                Toggle("Show chat sidebar on new books", isOn: $chatPaneDefault)
                Text("Layout and chat-sidebar choices apply to books opened from now on; books already open in a reader window keep their current state until you toggle them there (⌥⌘P, ⌥⌘C).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Reading appearance") {
                Picker("Font", selection: fontFamily) {
                    ForEach(ReaderFontFamily.allCases) { ff in
                        Text(ff.displayName).tag(ff)
                    }
                }
                .pickerStyle(.segmented)
                fontSizeRow(
                    label: "Size",
                    value: $fontSize,
                    range: 10...36,
                    unit: "pt",
                    valueFormat: { "\(Int($0)) pt" }
                )
                fontSizeRow(
                    label: "Line spacing",
                    value: $lineHeight,
                    range: 1.2...2.2,
                    step: 0.1,
                    unit: "×",
                    valueFormat: { String(format: "%.1f×", $0) }
                )
                fontSizeRow(
                    label: "Margins",
                    value: $marginEm,
                    range: 0...8,
                    step: 0.5,
                    unit: "em",
                    valueFormat: { String(format: "%.1f em", $0) }
                )
                Picker("Theme", selection: theme) {
                    ForEach(ReaderTheme.allCases) { t in
                        Text(t.displayName).tag(t)
                    }
                }
                .pickerStyle(.segmented)
                Text("Changes apply to every open reader window immediately — no chapter reload.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                Button("Restore Defaults", role: .destructive) {
                    restoreDefaults()
                }
            }
        }
        .formStyle(.grouped)
        // Match Editor / Conversion / AI / Appearance panes:
        // `.padding(.vertical)` + explicit width + minHeight so
        // switching tabs doesn't shift content position or jump
        // the window's vertical bounds.
        .padding(.vertical)
        .frame(width: 520)
        .frame(minHeight: 460)
    }

    /// One paragraph that updates with the open-target picker.
    /// Says where the user lands on double-click + the path back
    /// to the other window.
    private var openTargetCaption: String {
        switch openTarget.wrappedValue {
        case .reader:
            return "Library double-click, File → Open, drag-drop, and Recents all open EPUBs in the reader. The source editor is one click away via the reader's “Edit Source…” action (⌥⌘O) or Window → Show Editor (⌘3)."
        case .editor:
            return "Library double-click, File → Open, drag-drop, and Recents all open EPUBs in the source editor. The reader is one click away via Window → Show Reader (⌘5)."
        }
    }

    /// Generic "label · slider · trailing value" row used by the
    /// size / spacing / margin controls. Mirrors the layout in
    /// `EditorSettingsView.fontSizeRow` so the two panes feel
    /// the same.
    @ViewBuilder
    private func fontSizeRow(
        label: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double = 1,
        unit _: String = "",
        valueFormat: @escaping (Double) -> String
    ) -> some View {
        HStack {
            Text(label)
            Spacer()
            Slider(value: value, in: range, step: step)
                .frame(width: 200)
            Text(valueFormat(value.wrappedValue))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .trailing)
        }
    }

    /// Reset every key this pane owns to its shipped default.
    /// `openTarget` is included — "Restore Defaults" should mean
    /// "make this pane match what a fresh install shows," not
    /// "restore most defaults but quietly preserve one."
    private func restoreDefaults() {
        openTargetRaw = ReaderOpenTarget.reader.rawValue
        paginatedDefault = false
        chatPaneDefault = false
        fontFamilyRaw = ReaderFontFamily.serif.rawValue
        fontSize = EditorSettingsDefaults.previewFontSize
        lineHeight = 1.5
        marginEm = 2.0
        themeRaw = ReaderTheme.system.rawValue
    }
}
