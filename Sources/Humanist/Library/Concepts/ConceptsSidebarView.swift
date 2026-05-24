import SwiftUI
import LibraryIndexing
import AI

/// Library-window sidebar that surfaces `LibraryConceptGraph`
/// concepts. Top row: header + search field. Body: scrolling list
/// of significant concepts (`bookCount >= minBookCount`) sorted by
/// breadth, then total mentions, then name. Selecting a row hands
/// the chosen `ConceptStats` up to the parent for the detail view
/// to render.
///
/// Build path: kicks off `LibraryConceptGraphCache.shared.graph(...)`
/// in a detached task on first appear. The cache hit on subsequent
/// reopens is ~0.15s; the cold build is ~40s on a 2k-book library
/// and shows a progress UI until it lands.
@MainActor
struct ConceptsSidebarView: View {

    let library: LibraryStore
    @Binding var selectedCanonical: String?

    @AppStorage(EmbeddingBackendChoice.userDefaultsKey)
    private var embeddingBackendRaw: String = EmbeddingBackendChoice.appleNL.rawValue
    /// Floor for the significant-concepts cut. Default 5 — the
    /// 2-floor in the data layer is too noisy at sidebar scale
    /// (171k rows on the user's real library). Five gets us to a
    /// browsable list while still surfacing the long tail of
    /// niche-but-real concepts.
    @AppStorage("humanist.concepts.minBookCount")
    private var minBookCount: Int = 5

    @State private var graph: LibraryConceptGraph?
    @State private var buildState: BuildState = .idle
    @State private var searchText: String = ""

    enum BuildState: Equatable {
        case idle
        case building
        case ready
        case failed(String)
    }

    private var backendIdentifier: String {
        let choice = EmbeddingBackendChoice(rawValue: embeddingBackendRaw)
            ?? .appleNL
        // The cache fingerprint uses this string + sidecar mtimes;
        // identifier-prefix is stable across model-name churn within
        // a provider and is the natural cache key for the sidebar's
        // "current backend" semantics.
        return choice.identifierPrefix
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
        // Without explicit maxHeight, the building-state
        // ProgressView's small intrinsic height lets HSplitView
        // collapse the whole row to a thin band. Pin the pane
        // to fill vertically so every state (idle / building /
        // ready) sits at the full column height.
        .frame(maxHeight: .infinity, alignment: .top)
        .task(id: backendIdentifier) {
            await buildIfNeeded()
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Concepts")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let graph {
                    Text("\(filtered(graph).count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Button {
                    Task { await rebuild() }
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.borderless)
                .help("Rebuild concept index from per-book sidecars.")
                .disabled(buildState == .building)
            }
            if graph != nil {
                TextField("Search concepts", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch buildState {
        case .idle, .building:
            VStack(spacing: 10) {
                ProgressView()
                Text(buildState == .building
                     ? "Building concept index…"
                     : "Preparing…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("First build on a large library can take ~40s. Subsequent opens are instant.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text("Couldn't build concept index")
                    .font(.callout.weight(.semibold))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                Button("Retry") { Task { await rebuild() } }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready:
            if let graph {
                conceptList(graph)
            } else {
                Text("No concepts yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private func conceptList(_ graph: LibraryConceptGraph) -> some View {
        let rows = filtered(graph)
        if rows.isEmpty {
            VStack(spacing: 8) {
                Text(searchText.isEmpty
                     ? "No concepts cleared the breadth floor."
                     : "No concepts match \"\(searchText)\".")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                if minBookCount > 1 {
                    Button("Lower the floor (≥2 books)") {
                        minBookCount = 2
                    }
                    .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(selection: $selectedCanonical) {
                ForEach(rows, id: \.canonical) { stats in
                    HStack {
                        Text(stats.displayName)
                            .lineLimit(1)
                        Spacer()
                        Text("\(stats.bookCount)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                    .tag(stats.canonical as String?)
                }
            }
        }
    }

    // MARK: - Filtering

    private func filtered(_ graph: LibraryConceptGraph) -> [LibraryConceptGraph.ConceptStats] {
        let significant = graph.significantConcepts(minBookCount: minBookCount)
        let q = searchText
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return significant }
        return significant.filter {
            $0.displayName.lowercased().contains(q)
                || $0.canonical.contains(q)
        }
    }

    // MARK: - Build

    private func buildIfNeeded() async {
        let cache = LibraryConceptGraphCache.shared
        let entries = library.entries
        let identifier = backendIdentifier
        let isHit = await cache.hasCache(
            libraryEntries: entries, backendIdentifier: identifier
        )
        if isHit {
            // Hit returns instantly; no progress UI needed.
            let fresh = await cache.graph(
                libraryEntries: entries, backendIdentifier: identifier
            )
            graph = fresh
            buildState = .ready
            return
        }
        await rebuild()
    }

    private func rebuild() async {
        buildState = .building
        let entries = library.entries
        let identifier = backendIdentifier
        let built = await LibraryConceptGraphCache.shared.graph(
            libraryEntries: entries, backendIdentifier: identifier
        )
        graph = built
        buildState = .ready
    }
}
