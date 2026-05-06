import SwiftUI

/// Editor preferences pane in the Settings scene. All values are
/// persisted directly via `@AppStorage` — the editor's
/// `EditorView` reads the same keys and pushes changes through
/// the CodeMirror / preview JS bridges in real time, so updates
/// here apply immediately without an editor restart.
struct EditorSettingsView: View {
    @AppStorage(EditorSettingsKeys.sourceFontSize)
    private var sourceFontSize: Double = EditorSettingsDefaults.sourceFontSize
    @AppStorage(EditorSettingsKeys.sourceTheme)
    private var sourceTheme: String = EditorSettingsDefaults.sourceTheme
    @AppStorage(EditorSettingsKeys.sourceLineNumbers)
    private var sourceLineNumbers: Bool = EditorSettingsDefaults.sourceLineNumbers
    @AppStorage(EditorSettingsKeys.sourceWordWrap)
    private var sourceWordWrap: Bool = EditorSettingsDefaults.sourceWordWrap
    @AppStorage(EditorSettingsKeys.previewFontSize)
    private var previewFontSize: Double = EditorSettingsDefaults.previewFontSize
    @AppStorage(EditorSettingsKeys.previewTheme)
    private var previewTheme: String = EditorSettingsDefaults.previewTheme

    var body: some View {
        Form {
            Section("Source pane") {
                fontSizeRow(
                    label: "Font size",
                    value: $sourceFontSize,
                    range: 10...24
                )
                themePicker(
                    label: "Theme",
                    selection: $sourceTheme
                )
                Toggle("Show line numbers", isOn: $sourceLineNumbers)
                Toggle("Wrap long lines", isOn: $sourceWordWrap)
            }
            Section("Preview pane") {
                fontSizeRow(
                    label: "Base font size",
                    value: $previewFontSize,
                    range: 12...28
                )
                themePicker(
                    label: "Theme",
                    selection: $previewTheme
                )
                Text("Preview overrides cascade through the EPUB's stylesheet via an injected `<style>` tag — useful for proofreading at a different size or contrast than the book ships with.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                Button("Restore Defaults", role: .destructive) {
                    sourceFontSize = EditorSettingsDefaults.sourceFontSize
                    sourceTheme = EditorSettingsDefaults.sourceTheme
                    sourceLineNumbers = EditorSettingsDefaults.sourceLineNumbers
                    sourceWordWrap = EditorSettingsDefaults.sourceWordWrap
                    previewFontSize = EditorSettingsDefaults.previewFontSize
                    previewTheme = EditorSettingsDefaults.previewTheme
                }
            }
        }
        .formStyle(.grouped)
        .padding(.vertical)
        .frame(width: 520)
        .frame(minHeight: 460)
    }

    @ViewBuilder
    private func fontSizeRow(
        label: String,
        value: Binding<Double>,
        range: ClosedRange<Double>
    ) -> some View {
        HStack {
            Text(label)
            Spacer()
            Slider(value: value, in: range, step: 1)
                .frame(width: 200)
            Text("\(Int(value.wrappedValue)) pt")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 50, alignment: .trailing)
        }
    }

    @ViewBuilder
    private func themePicker(
        label: String,
        selection: Binding<String>
    ) -> some View {
        Picker(label, selection: selection) {
            ForEach(EditorThemeMode.allCases) { mode in
                Text(mode.label).tag(mode.rawValue)
            }
        }
        .pickerStyle(.segmented)
    }
}
