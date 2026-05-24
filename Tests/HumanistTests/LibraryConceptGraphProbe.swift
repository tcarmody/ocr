import XCTest
import LibraryIndexing
import Foundation
@testable import Humanist

/// One-off probe that builds `LibraryConceptGraph` against the
/// user's real library catalog and prints stats. Gated on
/// `HUMANIST_PROBE=1` so normal `swift test` runs skip it — the
/// probe is for ad-hoc validation, not regression coverage.
///
/// Invoke:
///
///     HUMANIST_PROBE=1 swift test --filter ProbeConceptGraph
///
/// Optional env vars:
///
///     HUMANIST_PROBE_CATALOG   — explicit path to library.json
///                                (defaults to
///                                ~/Library/Application Support/Humanist/library.json)
///     HUMANIST_PROBE_TOPK      — how many top concepts to print
///                                (default 25)
@MainActor
final class LibraryConceptGraphProbe: XCTestCase {

    func test_ProbeConceptGraph() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(
            env["HUMANIST_PROBE"] == "1",
            "Set HUMANIST_PROBE=1 to run the concept-graph probe."
        )
        let catalogURL = try resolveCatalog(env: env)
        print("Catalog: \(catalogURL.path)")

        let raw = try Data(contentsOf: catalogURL)
        let entries = try decodeEntries(from: raw)
        print("Entries in catalog: \(entries.count)")

        let store = EmbeddingsSidecarStore()

        // Filtered build (Phase 2a default).
        let filteredStart = Date()
        let filtered = LibraryConceptGraph.build(
            libraryEntries: entries, store: store
        )
        let filteredElapsed = Date().timeIntervalSince(filteredStart)

        // Unfiltered build for comparison so we can quantify the
        // noise the stopwords + aliases dropped.
        let unfilteredStart = Date()
        let unfiltered = LibraryConceptGraph.build(
            libraryEntries: entries, store: store, applyFilters: false
        )
        let unfilteredElapsed = Date().timeIntervalSince(unfilteredStart)

        // Cache round-trip — first call should be a hit and
        // return near-instantaneously.
        let cache = LibraryConceptGraphCache()
        _ = await cache.graph(
            libraryEntries: entries,
            backendIdentifier: "probe.backend",
            store: store
        )
        let cacheStart = Date()
        _ = await cache.graph(
            libraryEntries: entries,
            backendIdentifier: "probe.backend",
            store: store
        )
        let cacheHitElapsed = Date().timeIntervalSince(cacheStart)

        let topK = Int(env["HUMANIST_PROBE_TOPK"] ?? "") ?? 25
        print("")
        print("=== Build comparison ===")
        print(String(
            format: "Unfiltered build:  %.2fs, %d concepts, %d edges",
            unfilteredElapsed, unfiltered.concepts.count,
            unfiltered.coOccurrence.count
        ))
        print(String(
            format: "Filtered build:    %.2fs, %d concepts, %d edges",
            filteredElapsed, filtered.concepts.count,
            filtered.coOccurrence.count
        ))
        print(String(
            format: "Cache hit:         %.4fs", cacheHitElapsed
        ))
        let significant = filtered.significantConcepts()
        print("Significant (bookCount >= 2): \(significant.count)")

        printStats(graph: filtered, elapsed: filteredElapsed, topK: topK)
    }

    // MARK: - Stats formatting

    private func printStats(
        graph: LibraryConceptGraph,
        elapsed: TimeInterval,
        topK: Int
    ) {
        print("")
        print("=== LibraryConceptGraph rollup ===")
        print(String(
            format: "Build time:        %.2fs", elapsed
        ))
        print("Indexed books:     \(graph.indexedBookCount)")
        print("Distinct concepts: \(graph.concepts.count)")
        print("Retained edges:    \(graph.coOccurrence.count)")

        let edgeCounts = graph.coOccurrence.values
        if let maxEdge = edgeCounts.max() {
            let avg = Double(edgeCounts.reduce(0, +))
                / Double(max(edgeCounts.count, 1))
            print(String(
                format: "Edge counts:       max %d, mean %.2f",
                maxEdge, avg
            ))
        }

        let byBreadth = graph.significantConcepts()
        print("")
        print("=== Top \(topK) SIGNIFICANT concepts by breadth ===")
        for stats in byBreadth.prefix(topK) {
            print(String(
                format: "  %4d books, %5d mentions  %@",
                stats.bookCount, stats.totalMentions, stats.displayName
            ))
        }

        print("")
        print("=== Top \(min(topK, 15)) co-occurrence edges ===")
        let topEdges = graph.coOccurrence
            .sorted { $0.value > $1.value }
            .prefix(min(topK, 15))
        for (edge, count) in topEdges {
            let da = graph.concepts[edge.a]?.displayName ?? edge.a
            let db = graph.concepts[edge.b]?.displayName ?? edge.b
            print(String(format: "  %5d  %@ ↔ %@", count, da, db))
        }

        if let mostBroad = byBreadth.first {
            print("")
            print("=== Related concepts for \"\(mostBroad.displayName)\" ===")
            for (concept, count) in graph.related(
                to: mostBroad.canonical, limit: 10
            ) {
                let display = graph.concepts[concept]?.displayName ?? concept
                print(String(format: "  %5d  %@", count, display))
            }
        }
    }

    // MARK: - Catalog locate / decode

    private func resolveCatalog(
        env: [String: String]
    ) throws -> URL {
        if let explicit = env["HUMANIST_PROBE_CATALOG"], !explicit.isEmpty {
            let url = URL(fileURLWithPath: explicit).standardizedFileURL
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw ProbeError.catalogMissing(url)
            }
            return url
        }
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        let url = support
            .appendingPathComponent("Humanist", isDirectory: true)
            .appendingPathComponent("library.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ProbeError.catalogMissing(url)
        }
        return url
    }

    private func decodeEntries(from data: Data) throws -> [LibraryEntry] {
        // The catalog is a JSON object with an `entries` array. We
        // decode each entry independently so a single bad row
        // doesn't kill the probe — print the offender and continue.
        guard let root = try JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              let rawEntries = root["entries"] as? [Any]
        else {
            throw ProbeError.catalogShape
        }
        let decoder = JSONDecoder()
        var out: [LibraryEntry] = []
        out.reserveCapacity(rawEntries.count)
        for (i, item) in rawEntries.enumerated() {
            do {
                let entryData = try JSONSerialization.data(withJSONObject: item)
                let entry = try decoder.decode(LibraryEntry.self, from: entryData)
                out.append(entry)
            } catch {
                print("Skipped catalog entry \(i): \(error)")
            }
        }
        return out
    }

    enum ProbeError: Error, CustomStringConvertible {
        case catalogMissing(URL)
        case catalogShape

        var description: String {
            switch self {
            case .catalogMissing(let url):
                return "No catalog at \(url.path)"
            case .catalogShape:
                return "library.json is not the expected shape"
            }
        }
    }
}
