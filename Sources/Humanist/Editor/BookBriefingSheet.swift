import SwiftUI

/// Modal that renders a streaming pre-reading briefing produced
/// by `BookBriefingService`. Read-only — the briefing is a
/// one-off generative pass, not a chat. Follow-up discussion
/// happens in the regular chat pane after the user closes the
/// sheet.
///
/// Layout: header (title + author + status), Markdown body that
/// grows as deltas arrive, footer with Retry / Copy / Done.
/// Retry re-runs the briefing fresh; Copy puts the Markdown on
/// the pasteboard so the user can paste into a notes app.
struct BookBriefingSheet: View {
    @ObservedObject var service: BookBriefingService
    let bookTitle: String
    let author: String?
    let onRetry: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            body(text: service.briefing)
            Spacer(minLength: 8)
            footer
        }
        .padding(24)
        .frame(width: 660, height: 560)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Image(systemName: "text.book.closed")
                    .foregroundStyle(HumanistTheme.accent)
                    .imageScale(.large)
                Text("Pre-reading briefing")
                    .font(.headline)
                Spacer()
                if service.isStreaming {
                    ProgressView().controlSize(.small)
                }
            }
            Text(bookTitle)
                .font(.title3)
                .fontWeight(.semibold)
            if let author, !author.isEmpty {
                Text("by \(author)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func body(text: String) -> some View {
        if let err = service.error {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(.orange)
                Text("Couldn't write a briefing")
                    .font(.headline)
                Text(err)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if text.isEmpty && service.isStreaming {
            HStack(spacing: 10) {
                Text("Drafting the briefing…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                // Markdown rendering — the briefing system prompt
                // asks for inline-bold section headers so this
                // renders cleanly without h2 headings breaking up
                // the visual flow.
                if let attributed = try? AttributedString(
                    markdown: text,
                    options: .init(
                        interpretedSyntax: .inlineOnlyPreservingWhitespace
                    )
                ) {
                    Text(attributed)
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(text)
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    private var footer: some View {
        HStack {
            Button {
                onRetry()
            } label: {
                Label("Retry", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(service.isStreaming)

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(
                    service.briefing, forType: .string
                )
            } label: {
                Label("Copy Markdown", systemImage: "doc.on.doc")
            }
            .disabled(service.briefing.isEmpty)

            Spacer()

            Button("Done", action: onDismiss)
                .keyboardShortcut(.cancelAction)
        }
    }
}
