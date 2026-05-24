import SwiftUI
import LibraryIndexing
import AI

/// Host for `ConceptDetailView` that reads the graph from the
/// shared `LibraryConceptGraphCache`. The sidebar's task already
/// populated the cache; this host's await is fast on the hit path
/// and falls through to the same build progress UI on a miss
/// (rare — only happens if someone navigates to the detail
/// without going through the sidebar first).
///
/// Lives next to `ConceptDetailView` so the cache wiring is in
/// one place; the detail view itself is pure presentation over a
/// resolved `ConceptStats` + `LibraryConceptGraph`.
@MainActor
struct ConceptDetailHost: View {

    @Binding var selectedCanonical: String?
    let library: LibraryStore
    var onOpenBook: (URL) -> Void

    @AppStorage(EmbeddingBackendChoice.userDefaultsKey)
    private var embeddingBackendRaw: String = EmbeddingBackendChoice.appleNL.rawValue

    @State private var graph: LibraryConceptGraph?

    private var backendIdentifier: String {
        let choice = EmbeddingBackendChoice(rawValue: embeddingBackendRaw)
            ?? .appleNL
        return choice.identifierPrefix
    }

    var body: some View {
        Group {
            if let canonical = selectedCanonical,
               let graph,
               let stats = graph.concepts[canonical] {
                ConceptDetailView(
                    stats: stats,
                    graph: graph,
                    onOpenBook: onOpenBook,
                    onSelectRelated: { selectedCanonical = $0 }
                )
            } else if selectedCanonical != nil && graph == nil {
                // Cache miss + selection in flight — rare but
                // possible if the user clicks a row before the
                // sidebar's await landed the graph for the host's
                // copy. The sidebar shows its own progress UI;
                // here we just defer.
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(
                    "Pick a concept",
                    systemImage: "tag",
                    description: Text(
                        "Select a concept on the left to see which books mention it."
                    )
                )
            }
        }
        .task(id: backendIdentifier) {
            await loadGraph()
        }
    }

    private func loadGraph() async {
        let entries = library.entries
        let identifier = backendIdentifier
        let cache = LibraryConceptGraphCache.shared
        let isHit = await cache.hasCache(
            libraryEntries: entries, backendIdentifier: identifier
        )
        if isHit {
            graph = await cache.graph(
                libraryEntries: entries, backendIdentifier: identifier
            )
        } else {
            // Don't kick a cold build from the detail host — the
            // sidebar is the canonical builder. If the user
            // somehow landed here first, fall back to the same
            // cache call (it'll build, but at least we don't
            // race two builds).
            graph = await cache.graph(
                libraryEntries: entries, backendIdentifier: identifier
            )
        }
    }
}
