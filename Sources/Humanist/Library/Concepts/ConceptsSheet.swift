import SwiftUI
import LibraryIndexing

/// Modal sheet that surfaces the federated concept graph for
/// occasional browsing. Replaces the inline HSplitView pane the
/// Concepts feature shipped in originally — concept browsing isn't
/// part of the moment-to-moment library workflow, so it lives
/// behind a sparkles-style button rather than taking up permanent
/// horizontal real estate alongside collections / chat.
///
/// Layout: list of significant concepts on the left, detail on the
/// right (bar chart + related-concepts chips). Clicking a book
/// in the chart dismisses the sheet and hands off to OpenRouter
/// so the user lands in the editor / reader for that book.
struct ConceptsSheet: View {

    let library: LibraryStore
    var onOpenBook: (URL) -> Void
    var onDismiss: () -> Void

    @State private var selectedCanonical: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                ConceptsSidebarView(
                    library: library,
                    selectedCanonical: $selectedCanonical
                )
                .frame(minWidth: 240, idealWidth: 280, maxWidth: 360)
                ConceptDetailHost(
                    selectedCanonical: $selectedCanonical,
                    library: library,
                    onOpenBook: { url in
                        // Dismiss before opening so the sheet doesn't
                        // sit in front of the editor/reader that the
                        // book hand-off just brought to focus.
                        onDismiss()
                        onOpenBook(url)
                    }
                )
                .frame(minWidth: 460)
            }
            Divider()
            footer
        }
        .frame(width: 1000, height: 640)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "tag.fill")
                .foregroundStyle(HumanistTheme.accent)
                .imageScale(.large)
            Text("Concepts in your library")
                .font(.headline)
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Done") { onDismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(.bar)
    }
}
