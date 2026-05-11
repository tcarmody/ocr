import Foundation

/// R-Auto-Collections Phase 1. Generate `BookCollection` rows from
/// `LibraryEntry` metadata — no model needed.
///
/// Two collection families today:
///   * **By Type** (Print / Manuscript / Early Print / Digital):
///     bucketed by `LibraryEntry.conversionType`. The stamp is
///     written at conversion / import time; legacy entries get a
///     sibling-PDF heuristic backfill at load time
///     (see `LibraryStore.inferConversionType`).
///   * **By Author**: grouped by `LibraryEntry.author`, filtered
///     to authors with at least `autoAuthorThreshold` books
///     (Settings-configurable; default 3).
///
/// Auto-collections carry an `autoSource` discriminator so the UI
/// can render them in a separate sidebar section + so the next
/// refresh can recycle the same `id` (collections regenerate on
/// each call; existing auto-collections matching the same source
/// are reused so user-visible IDs stay stable).
///
/// User-created collections (autoSource == nil) are never touched.
@MainActor
enum LibraryAutoCollections {

    /// Re-materialize all auto-collections from the current
    /// catalog. Drops any existing auto-collections that no longer
    /// match (e.g. an author who fell below the threshold) +
    /// updates membership on the ones that survive. Returns a
    /// summary the caller can surface in the UI.
    @discardableResult
    static func refresh(library: LibraryStore) -> RefreshResult {
        let entries = library.entries
        let threshold = currentAuthorThreshold()

        // Build the desired auto-collection set from scratch
        // against the live catalog.
        var desired: [BookCollection] = []
        desired.append(contentsOf: typeCollections(from: entries))
        desired.append(contentsOf: authorCollections(
            from: entries, threshold: threshold
        ))

        // Merge with existing auto-collections by autoSource —
        // reuse ids where possible so the user's UI selection
        // doesn't bounce on every refresh.
        let existingAuto = library.collections.filter { $0.autoSource != nil }
        let existingByKey = Dictionary(
            uniqueKeysWithValues: existingAuto.compactMap { c -> (AutoCollectionSource, BookCollection)? in
                guard let s = c.autoSource else { return nil }
                return (s, c)
            }
        )
        var merged: [BookCollection] = desired.map { d in
            guard let source = d.autoSource,
                  let existing = existingByKey[source]
            else { return d }
            var copy = d
            // Preserve the existing id + createdAt so SwiftUI
            // selection state survives the refresh.
            copy = BookCollection(
                id: existing.id,
                name: d.name,
                bookIDs: d.bookIDs,
                createdAt: existing.createdAt,
                autoSource: d.autoSource
            )
            return copy
        }

        // Keep user-created collections + the merged auto ones.
        let userCollections = library.collections.filter { $0.autoSource == nil }
        merged = userCollections + merged

        library.replaceCollections(merged)

        return RefreshResult(
            typeCount: desired.filter {
                if case .byType = $0.autoSource { return true } else { return false }
            }.count,
            authorCount: desired.filter {
                if case .byAuthor = $0.autoSource { return true } else { return false }
            }.count,
            authorThreshold: threshold
        )
    }

    // MARK: - Generation

    private static func typeCollections(
        from entries: [LibraryEntry]
    ) -> [BookCollection] {
        var byType: [BookConversionType: [UUID]] = [:]
        for entry in entries {
            guard let t = entry.conversionType else { continue }
            byType[t, default: []].append(entry.id)
        }
        // Stable ordering (enum case order) so the sidebar lists
        // types consistently across refreshes.
        return BookConversionType.allCases.compactMap { type in
            guard let ids = byType[type], !ids.isEmpty else { return nil }
            return BookCollection(
                name: type.displayName,
                bookIDs: ids,
                autoSource: .byType(type)
            )
        }
    }

    private static func authorCollections(
        from entries: [LibraryEntry],
        threshold: Int
    ) -> [BookCollection] {
        // Group by author string with case-sensitive matching.
        // Library catalogs from AFM extraction normalize whitespace
        // already; finer dedup (e.g. "Foucault, Michel" vs
        // "Michel Foucault") is a follow-up.
        var byAuthor: [String: [UUID]] = [:]
        for entry in entries {
            let normalized = (entry.author ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { continue }
            byAuthor[normalized, default: []].append(entry.id)
        }
        // Surname-sortable order so the sidebar reads naturally.
        // Quick-and-dirty: sort by the last whitespace-separated
        // token (works for "Michel Foucault" → "Foucault"; for
        // "Foucault, Michel" → ", Michel" which sorts weirdly but
        // is rare in practice).
        return byAuthor
            .filter { $0.value.count >= threshold }
            .sorted { surnameKey($0.key) < surnameKey($1.key) }
            .map { author, ids in
                BookCollection(
                    name: author,
                    bookIDs: ids,
                    autoSource: .byAuthor(author)
                )
            }
    }

    private static func surnameKey(_ author: String) -> String {
        author.split(separator: " ").last.map(String.init) ?? author
    }

    // MARK: - Settings

    /// Read the configured threshold. Falls back to 3 when unset
    /// or zero (which UserDefaults returns for missing Int keys).
    static func currentAuthorThreshold() -> Int {
        let raw = UserDefaults.standard.integer(
            forKey: ConversionSettingsKeys.autoAuthorThreshold
        )
        return raw > 0 ? raw : 3
    }

    static let defaultAuthorThreshold = 3
}

extension LibraryAutoCollections {
    struct RefreshResult: Sendable, Equatable {
        let typeCount: Int
        let authorCount: Int
        let authorThreshold: Int
    }
}
