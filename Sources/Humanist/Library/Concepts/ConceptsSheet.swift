import SwiftUI
import LibraryIndexing

/// Modal sheet that surfaces the federated concept graph for
/// occasional browsing. User-facing label is **Topics**; the
/// underlying data structure stays `LibraryConceptGraph` in code
/// since it's a per-entity rollup from NER, not a topic-modeling
/// pipeline. Replaces the inline HSplitView pane the feature
/// shipped in originally — topic browsing isn't part of the
/// moment-to-moment library workflow, so it lives behind a
/// sparkles-style button rather than taking up permanent
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
                        // Keep the sheet open across book opens —
                        // browsing topics is the user's loop here;
                        // closing the sheet on every click forces a
                        // 40s re-build (pre-warm has already gone)
                        // to keep exploring. The reader window
                        // opens behind the sheet, which is fine —
                        // the user can drag the sheet aside or
                        // close it explicitly when done browsing.
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
            Text("Topics in your library")
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
