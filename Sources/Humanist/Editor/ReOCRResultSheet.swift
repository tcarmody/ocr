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
    /// Replace handler — its label and behavior depend on
    /// `result.replaceTarget`. For `.sourceSelection` it splices the
    /// OCR text into the current CodeMirror selection; for
    /// `.pageInSource` it replaces everything between two
    /// `hu-page-N` anchors.
    let onReplaceInSource: () -> Void
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

                Button {
                    onReplaceInSource()
                } label: {
                    Label(replaceLabel, systemImage: "square.and.pencil")
                }
                .help(replaceHelp)
                .disabled(result.text.isEmpty)

                Spacer()

                Button("Close") { onDismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 360)
    }

    private var replaceLabel: String {
        switch result.replaceTarget {
        case .sourceSelection:    return "Replace Selection in Source"
        case .pageInSource:       return "Replace Page in Source"
        }
    }

    private var replaceHelp: String {
        switch result.replaceTarget {
        case .sourceSelection:
            return "Replace the current source-pane selection with this text (or insert at the caret if nothing is selected)."
        case .pageInSource:
            return "Replace everything between this page's anchors in the source pane with the OCR result, wrapping each line in <p>."
        }
    }

    private var pageRangeLabel: String {
        let r = result.pageRange
        if r.lowerBound == r.upperBound {
            return "Page \(r.lowerBound + 1)"
        }
        return "Pages \(r.lowerBound + 1)–\(r.upperBound + 1)"
    }
}
