import SwiftUI

/// R-Custom-Styles. Sheet that lets the user pick font / size /
/// theme for the open EPUB. Apply writes the regenerated
/// `book.css` through the dirty-buffer pipeline; Save flushes it
/// into the .epub. The preview pane reloads automatically (we
/// bump `previewVersion` on apply).
struct BookStyleSheet: View {
    @ObservedObject var vm: EditorViewModel
    @Binding var isPresented: Bool

    /// Local copy so the user can tinker without writing on every
    /// keystroke. Apply commits to `vm.bookStyle` + the CSS file;
    /// Cancel closes the sheet without touching either.
    @State private var draft: BookStyle
    /// Surfaced inline when the EPUB has no `OEBPS/css/book.css`
    /// (atypical for Humanist-built books; possible for third-party
    /// EPUBs the editor can open).
    @State private var applyError: String?

    init(vm: EditorViewModel, isPresented: Binding<Bool>) {
        self.vm = vm
        self._isPresented = isPresented
        self._draft = State(initialValue: vm.bookStyle)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Customize Style")
                .font(.title3.weight(.semibold))

            Form {
                Picker("Font", selection: $draft.font) {
                    Text("Serif (Georgia)").tag(BookStyle.FontFamily.serif)
                    Text("Sans-serif (System)").tag(BookStyle.FontFamily.sans)
                    Text("Monospace").tag(BookStyle.FontFamily.monospace)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Size: \(sizeLabel(draft.fontSize))")
                    Slider(value: $draft.fontSize, in: 0.75...1.5, step: 0.05)
                }

                Picker("Theme", selection: $draft.theme) {
                    Text("Light").tag(BookStyle.Theme.light)
                    Text("Sepia").tag(BookStyle.Theme.sepia)
                    Text("Dark").tag(BookStyle.Theme.dark)
                }
                .pickerStyle(.segmented)
            }
            .formStyle(.grouped)

            if let err = applyError {
                Text(err)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .lineLimit(3)
            }

            HStack {
                Button("Reset to Default") {
                    draft = .default
                }
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Apply") { apply() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func apply() {
        if vm.applyBookStyle(draft) {
            isPresented = false
        } else {
            applyError = "This EPUB has no OEBPS/css/book.css to update. "
                + "Custom styles need a stylesheet to attach to."
        }
    }

    private func sizeLabel(_ size: Double) -> String {
        let pct = Int((size * 100).rounded())
        return "\(pct)% (\(String(format: "%.2f", size))em)"
    }
}
