import SwiftUI

/// Modal that displays one paragraph picked by
/// `SurfaceParagraphSelector` for the Library window's sparkles
/// button. Three actions: "Try Another" re-picks, "Open Book"
/// hands off to `OpenRouter`, "Done" dismisses.
///
/// Deliberately minimal — the goal is delight on re-encounter, not
/// a deep follow-up surface. Discussion threads / pinning / sharing
/// are deferred to follow-up commits if real use surfaces a need.
struct SurfacedParagraphSheet: View {
    /// Currently-displayed paragraph, or nil while the selector
    /// runs / no candidate could be found. The view shows a
    /// loading state when nil + `isLoading` true, and an empty-
    /// state message when nil + `isLoading` false.
    let paragraph: SurfacedParagraph?
    let isLoading: Bool

    let onTryAnother: () -> Void
    let onOpenBook: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()
            content
            Spacer(minLength: 12)
            actionBar
        }
        .padding(24)
        .frame(width: 600, height: 520)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .foregroundStyle(HumanistTheme.accent)
                .imageScale(.large)
            Text("From your library")
                .font(.headline)
            Spacer()
        }
    }

    @ViewBuilder
    private var content: some View {
        if let paragraph {
            VStack(alignment: .leading, spacing: 8) {
                Text(paragraph.libraryEntry.title)
                    .font(.title3)
                    .fontWeight(.semibold)
                if let author = paragraph.libraryEntry.author,
                   !author.isEmpty {
                    Text("by \(author)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Text("Chapter \(paragraph.chapterIdx + 1) · paragraph \(paragraph.paragraphIdx + 1)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                ScrollView {
                    Text(paragraph.text)
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 8)
                }
                .frame(maxHeight: .infinity)
            }
        } else if isLoading {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Looking for something interesting…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "tray")
                    .font(.largeTitle)
                    .foregroundStyle(.tertiary)
                Text("No paragraphs ready yet")
                    .font(.headline)
                Text("Index more of your library or try again — the selector skips short snippets, headings, and anything you've seen recently.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var actionBar: some View {
        HStack {
            Button {
                onTryAnother()
            } label: {
                Label("Try Another", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(isLoading)

            Button {
                onOpenBook()
            } label: {
                Label("Open Book", systemImage: "book")
            }
            .disabled(paragraph == nil)

            Spacer()

            Button("Done", action: onDismiss)
                .keyboardShortcut(.cancelAction)
        }
    }
}
