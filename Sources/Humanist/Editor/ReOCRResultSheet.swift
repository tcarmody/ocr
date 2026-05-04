import SwiftUI
import AppKit

/// Sheet that surfaces the output of a "Re-OCR Selection With…"
/// command. Shows the recognized text in a scrollable monospace
/// view; user copies it to the clipboard and pastes into the source
/// pane themselves. Splicing back in automatically is deliberately
/// not in v1 — the user wants to read the result, decide whether
/// it's an improvement, and place it where they want.
struct ReOCRResultSheet: View {
    let result: EditorViewModel.ReOCRResult
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "text.viewfinder")
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Re-OCR result · \(result.engine.displayName)")
                        .font(.headline)
                    Text(pageRangeLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Divider()

            ScrollView {
                Text(result.text.isEmpty ? "(No text recognized.)" : result.text)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(8)
            }
            .frame(minWidth: 520, minHeight: 240)
            .background(Color(nsColor: .textBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.secondary.opacity(0.2))
            )

            HStack {
                Button {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(result.text, forType: .string)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .keyboardShortcut("c", modifiers: .command)
                .disabled(result.text.isEmpty)

                Spacer()

                Button("Close") { onDismiss() }
                    .keyboardShortcut(.cancelAction)
                    .keyboardShortcut(.return, modifiers: [])
            }
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 360)
    }

    private var pageRangeLabel: String {
        let r = result.pageRange
        if r.lowerBound == r.upperBound {
            return "Page \(r.lowerBound + 1)"
        }
        return "Pages \(r.lowerBound + 1)–\(r.upperBound + 1)"
    }
}
