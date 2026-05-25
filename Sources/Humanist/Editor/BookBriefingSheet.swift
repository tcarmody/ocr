import SwiftUI
import EPUB

/// Wrapper that owns the `BookBriefingService` as a `@StateObject`
/// and mounts the briefing sheet. Pulled out of `ChatPaneView`
/// because holding the service there made every streaming text
/// delta re-render the entire chat pane — observed as a main-
/// thread hang on long transcripts (a sampled stack showed
/// thousands of `BookChatMessage` copy/destroy ops per update).
///
/// Mounted only while the sheet is presented, so the
/// `@StateObject`'s update churn never leaves this small subtree.
/// The chat pane's parent view stays still — same pattern as
/// `feedback_swiftui_stateobject_cascade.md` (demote rapidly-
/// publishing state to a child the parent doesn't observe).
///
/// One side effect: dismissing + reopening the sheet starts a
/// fresh briefing. Acceptable for a ~5–15 s generation; the user
/// gets a Retry button inside the sheet for a deliberate rerun
/// during the same session.
struct BriefingSheetContainer: View {
    let book: EPUBBook
    let bookTitle: String
    let entry: LibraryEntry?
    let library: LibraryStore?
    let onDismiss: () -> Void

    @StateObject private var service = BookBriefingService()

    var body: some View {
        BookBriefingSheet(
            service: service,
            bookTitle: bookTitle,
            author: entry?.author,
            onRetry: { start(forceRefresh: true) },
            onDismiss: onDismiss
        )
        .onAppear {
            // First mount → kick off the briefing once. Re-mounts
            // (sheet dismiss + reopen) reach this path too; the
            // service's `start` is idempotent and cancels any
            // prior in-flight task. With caching, a saved briefing
            // is hydrated synchronously and no streaming runs.
            if service.briefing.isEmpty && !service.isStreaming {
                start()
            }
        }
    }

    /// Briefing cache key. Falls back to the loaded EPUBBook's
    /// own `sourceURL` when the library entry is nil (book opened
    /// outside the catalog) — both forms canonicalize to the same
    /// path for an indexed book.
    private var briefingCacheKey: URL {
        entry?.epubURL ?? book.sourceURL
    }

    private func start(forceRefresh: Bool = false) {
        service.start(
            book: book,
            entry: entry,
            bookTitle: bookTitle,
            library: library,
            epubURL: briefingCacheKey,
            forceRefresh: forceRefresh
        )
    }
}

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
            // Cache provenance line. Shown only when the visible
            // briefing came from disk so a fresh stream's header
            // doesn't carry a misleading "saved earlier" badge.
            // Two affordances at once: timestamp + model so the
            // user can decide whether to Retry against a different
            // backend.
            if service.loadedFromCache,
               let generatedAt = service.generatedAt,
               let generatedBy = service.generatedBy {
                Text(
                    "Saved \(Self.cacheTimestampFormatter.localizedString(for: generatedAt, relativeTo: Date())) · \(generatedBy) · Retry to regenerate"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            }
        }
    }

    /// Relative-time formatter for the cache provenance line.
    /// "Saved 3 days ago" reads better than an ISO timestamp.
    private static let cacheTimestampFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

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
