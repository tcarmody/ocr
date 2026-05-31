import SwiftUI

/// Modal sheet for Insert > Anchor…. Collects an id and dispatches
/// `EditorViewModel.insertAnchor(id:)` on submit. Mirrors the
/// `GotoLineSheet` shape so menu-driven inserts feel consistent.
///
/// The source-pane toolbar has a separate popover for the same
/// gesture (`SourceFormattingToolbar.anchorPopover`); both paths
/// commit through `vm.insertAnchor(id:)`.
struct AnchorInsertSheet: View {
    @Binding var isPresented: Bool
    let onSubmit: (String) -> Void

    @State private var input: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Insert Anchor").font(.headline)
            Text("Inserts `<a id=\"…\"></a>` at the cursor — a jump target for `<a href=\"#…\">` links elsewhere in the book.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 320, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            TextField("anchor-id (e.g. intro, ch3-note-2)", text: $input)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
                .onSubmit { commit() }
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Insert") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(16)
    }

    private var trimmed: String {
        input.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func commit() {
        let id = trimmed
        guard !id.isEmpty else { return }
        onSubmit(id)
        isPresented = false
    }
}
