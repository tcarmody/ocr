import SwiftUI
import AppKit

/// Document-spelling check sheet. Iterates through the misspellings
/// `SpellCheckSession` found in the loaded source, one at a time,
/// surfacing suggestions and offering Replace / Skip / Ignore /
/// Learn actions.
///
/// Replaces use `vm.applySpellingReplacement(_:)` which mutates the
/// `sourceText` binding via the existing CodeMirror push path —
/// works even though the editor pane is open behind the sheet.
struct SpellCheckSheet: View {
    @ObservedObject var vm: EditorViewModel
    @ObservedObject var session: SpellCheckSession
    @Binding var isPresented: Bool
    @State private var selectedSuggestion: String?
    @State private var customReplacement: String = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 540, height: 420)
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Spelling")
                    .font(.title2.bold())
                if session.totalCount > 0 {
                    Text("Word \(min(session.currentIndex + 1, session.totalCount)) of \(session.totalCount)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Done") { isPresented = false }
                .keyboardShortcut(.cancelAction)
        }
        .padding(16)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let misspelling = session.current {
            VStack(alignment: .leading, spacing: 16) {
                contextBlock(misspelling)
                suggestionsBlock(misspelling)
                customBlock
            }
            .padding(16)
        } else {
            emptyState
        }
    }

    @ViewBuilder
    private func contextBlock(_ m: SpellCheckSession.Misspelling) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("In context").font(.caption).foregroundStyle(.secondary)
            // Compose the context with the misspelled word
            // highlighted. SwiftUI Text concatenation gives us a
            // single styled run.
            (
                Text(m.contextBefore)
                + Text(m.word)
                    .foregroundColor(.red)
                    .underline()
                + Text(m.contextAfter)
            )
            .font(.system(size: 13))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
        }
    }

    @ViewBuilder
    private func suggestionsBlock(_ m: SpellCheckSession.Misspelling) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Suggestions").font(.caption).foregroundStyle(.secondary)
            if m.suggestions.isEmpty {
                Text("(no suggestions)")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .italic()
                    .padding(8)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(m.suggestions, id: \.self) { suggestion in
                            suggestionRow(suggestion)
                        }
                    }
                }
                .frame(maxHeight: 140)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
            }
        }
    }

    @ViewBuilder
    private func suggestionRow(_ suggestion: String) -> some View {
        Button {
            selectedSuggestion = suggestion
            customReplacement = suggestion
        } label: {
            HStack {
                Text(suggestion)
                    .font(.system(size: 13))
                Spacer()
                if selectedSuggestion == suggestion {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                selectedSuggestion == suggestion
                    ? Color.accentColor.opacity(0.15)
                    : Color.clear
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var customBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Or replace with").font(.caption).foregroundStyle(.secondary)
            TextField("Custom replacement", text: $customReplacement)
                .textFieldStyle(.roundedBorder)
                .onSubmit { applyReplacement() }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.green)
            Text("No more misspellings.")
                .font(.headline)
            Text("This sheet was scanning all text outside XHTML tags. Attribute values and element names were skipped.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    // MARK: - Footer

    @ViewBuilder
    private var footer: some View {
        HStack {
            Button("Learn") {
                session.learnCurrent()
                resetSelection()
            }
            .help("Add this word to your system-wide spelling dictionary")
            .disabled(!session.hasCurrent)

            Button("Ignore") {
                session.ignoreCurrent()
                resetSelection()
            }
            .help("Skip every occurrence of this word in this session")
            .disabled(!session.hasCurrent)

            Spacer()

            Button("Skip") {
                session.advance()
                resetSelection()
            }
            .disabled(!session.hasCurrent)

            Button("Replace") { applyReplacement() }
                .keyboardShortcut(.defaultAction)
                .disabled(
                    !session.hasCurrent
                    || customReplacement.trimmingCharacters(in: .whitespaces).isEmpty
                )
        }
        .padding(16)
        .background(.bar)
    }

    // MARK: - Actions

    private func applyReplacement() {
        let replacement = customReplacement
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !replacement.isEmpty else { return }
        vm.applySpellingReplacement(replacement)
        // The view-model re-scans against the updated source text;
        // the session's misspellings list is now refreshed and the
        // current cursor sits at the next entry (the one we replaced
        // dropped out of the rescan).
        resetSelection()
    }

    private func resetSelection() {
        selectedSuggestion = nil
        customReplacement = ""
    }
}
