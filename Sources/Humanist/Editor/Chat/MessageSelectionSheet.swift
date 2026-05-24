import SwiftUI

/// Sheet that exposes one chat message's text in a read-only
/// `TextEditor` so users can drag-select a passage and copy it.
///
/// Why a sheet: plain `Text` doesn't support drag-selection, and
/// `Text(...).textSelection(.enabled)` / NSTextView-wrapped Text
/// both cascade through the JetUI / LazyVStack renderer on macOS
/// 26 and pin the main thread on every scroll frame in the chat
/// pane. A sheet pops the message text out of the LazyVStack
/// scroll path entirely, so the heavy NSTextView lives in its own
/// (non-scrolling, transient) window where selection works
/// natively without affecting chat scroll perf.
///
/// Read-only — users can't edit the message. ⌘C / ⌘A work; the
/// "Copy All" button is there for users who'd rather click than
/// drag.
struct MessageSelectionSheet: View {
    let text: String
    let onDismiss: () -> Void

    @State private var workingText: String

    init(text: String, onDismiss: @escaping () -> Void) {
        self.text = text
        self.onDismiss = onDismiss
        _workingText = State(initialValue: text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Select Text")
                    .font(.headline)
                Spacer()
            }
            // `TextEditor` bound to `workingText` so users can edit
            // (won't persist), but mostly it's the only SwiftUI
            // primitive on macOS that gives drag-select + ⌘A out
            // of the box without going through the NSTextView
            // wrapper that bit us in the chat pane. The transient
            // sheet host doesn't carry LazyVStack cost, so the
            // expensive selection-enabled text view is fine here.
            TextEditor(text: $workingText)
                .font(.body)
                .frame(minWidth: 480, minHeight: 320)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                )
            HStack {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                } label: {
                    Label("Copy All", systemImage: "doc.on.doc")
                }
                Spacer()
                Button("Done", action: onDismiss)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 560, height: 480)
    }
}
