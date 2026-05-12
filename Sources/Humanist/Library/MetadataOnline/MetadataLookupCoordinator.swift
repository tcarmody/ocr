import Foundation

/// Fans a `MetadataQuery` across multiple `MetadataSource`s in
/// parallel, merges duplicate matches (a book that exists in
/// both Open Library and Google Books shows as one row, not two),
/// and ranks merged candidates by cross-source agreement. The
/// picker calls this instead of any single source directly so
/// adding / removing sources is a one-line config change.
///
/// Per-source failure is non-fatal: a thrown error from one
/// source is captured in `partialErrors` and the merge proceeds
/// with whatever the other sources returned. A single-source
/// failure shouldn't blank the whole picker.
struct MetadataLookupCoordinator: Sendable {
    let sources: [any MetadataSource]
    /// Per-source soft timeout. A slow upstream gets its task
    /// cancelled at this deadline so the picker doesn't stall
    /// waiting on one bad source.
    let perSourceTimeout: TimeInterval

    init(
        sources: [any MetadataSource] = [
            OpenLibrarySource(),
            GoogleBooksSource(),
        ],
        perSourceTimeout: TimeInterval = 5.0
    ) {
        self.sources = sources
        self.perSourceTimeout = perSourceTimeout
    }

    /// Outcome of a fanned-out lookup. Carries the merged + ranked
    /// candidate list plus a side-channel of per-source errors so
    /// the picker can surface "Google Books unavailable" without
    /// blocking the user on the successful sources.
    struct Result: Sendable {
        let candidates: [MetadataCandidate]
        let partialErrors: [(sourceName: String, message: String)]
    }

    func query(_ q: MetadataQuery) async -> Result {
        guard !q.isEmpty else {
            return Result(candidates: [], partialErrors: [])
        }
        // Fan out concurrently. TaskGroup gives us parallelism with
        // explicit cancellation on whole-group cancel (picker's
        // typing-too-fast guard). Per-task timeout via withTimeout
        // wrapper so a slow source can't outlive the deadline.
        let outcomes = await withTaskGroup(
            of: (sourceName: String, hits: [MetadataCandidate], error: String?).self
        ) { group in
            for source in sources {
                let timeout = perSourceTimeout
                group.addTask {
                    do {
                        let hits = try await Self.withTimeout(
                            seconds: timeout
                        ) {
                            try await source.query(q)
                        }
                        return (source.name, hits, nil)
                    } catch is CancellationError {
                        return (source.name, [], nil)
                    } catch let timeoutErr as TimeoutError {
                        return (source.name, [], timeoutErr.localizedDescription)
                    } catch {
                        let message = (error as? MetadataSourceError)?
                            .localizedDescription
                            ?? error.localizedDescription
                        return (source.name, [], message)
                    }
                }
            }
            var collected: [(sourceName: String, hits: [MetadataCandidate], error: String?)] = []
            for await outcome in group {
                collected.append(outcome)
            }
            return collected
        }

        let partialErrors = outcomes.compactMap { o -> (String, String)? in
            guard let err = o.error else { return nil }
            return (o.sourceName, err)
        }
        let merged = Self.mergeAndRank(
            outcomes.flatMap { $0.hits }
        )
        return Result(
            candidates: merged,
            partialErrors: partialErrors.map { (sourceName: $0.0, message: $0.1) }
        )
    }

    // MARK: - merge

    /// Fold duplicates from multiple sources into one row each.
    /// Duplicate detection key: normalized title prefix + author
    /// last-name. When a duplicate is found, the resulting
    /// candidate keeps the first hit's fields but folds the
    /// additional `sourceName` into the badge (joined by " · ")
    /// so the user sees which sources agree.
    ///
    /// Ranking: candidates with N source agreements rank above
    /// candidates with N-1; ties preserve insertion order (which
    /// reflects each source's own relevance ranking).
    static func mergeAndRank(
        _ hits: [MetadataCandidate]
    ) -> [MetadataCandidate] {
        // Use a Dictionary keyed by fuzzy-key, value = (first-hit
        // candidate, accumulated source name list, source-agreement
        // count). Preserve insertion order via a parallel key list
        // so the per-source ranking carries through to ties.
        var byKey: [String: (MetadataCandidate, [String], Int)] = [:]
        var keyOrder: [String] = []
        for hit in hits {
            let key = mergeKey(for: hit)
            if let existing = byKey[key] {
                var (candidate, sources, count) = existing
                if !sources.contains(hit.sourceName) {
                    sources.append(hit.sourceName)
                    count += 1
                    candidate = candidate.mergingWith(hit, addedSource: hit.sourceName)
                }
                byKey[key] = (candidate, sources, count)
            } else {
                byKey[key] = (hit, [hit.sourceName], 1)
                keyOrder.append(key)
            }
        }
        // Stable sort by agreement count descending; within the
        // same count, keep insertion order.
        let ranked = keyOrder
            .compactMap { byKey[$0] }
            .enumerated()
            .sorted { lhs, rhs in
                if lhs.element.2 != rhs.element.2 {
                    return lhs.element.2 > rhs.element.2
                }
                return lhs.offset < rhs.offset
            }
            .map { $0.element.0 }
        return ranked
    }

    /// Fuzzy key used to spot the same book across sources.
    /// First 5 lowercased title words (dropped of common
    /// punctuation) + the author's normalized last name. Catches
    /// "Discipline and Punish" vs "Discipline and Punish: The
    /// Birth of the Prison" (same prefix) and "Foucault, Michel"
    /// vs "Michel Foucault" (same last name).
    static func mergeKey(for candidate: MetadataCandidate) -> String {
        let title = candidate.title
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .prefix(5)
            .joined(separator: " ")
        let last = lastName(of: candidate.author) ?? "?"
        return "\(title)|\(last.lowercased())"
    }

    /// Pull the author's likely last name out of either
    /// "Last, First" or "First Last" shapes. Returns nil for
    /// empty / nil input. v1-shape: no diacritic folding (the
    /// match is already case-insensitive and key-only, so accents
    /// just mean two candidates don't merge — survivable for v1).
    static func lastName(of author: String?) -> String? {
        guard let raw = author?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else { return nil }
        if let commaIdx = raw.firstIndex(of: ",") {
            return String(raw[..<commaIdx])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let words = raw.split(separator: " ", omittingEmptySubsequences: true)
        return words.last.map(String.init)
    }

    // MARK: - timeout

    private struct TimeoutError: Error, LocalizedError {
        let seconds: TimeInterval
        var errorDescription: String? {
            "Source took longer than \(Int(seconds))s — skipped."
        }
    }

    private static func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw TimeoutError(seconds: seconds)
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
    }
}

// MARK: - Candidate merge

extension MetadataCandidate {
    /// Fold another source's record into this one. Keeps the
    /// existing fields (`self` represents the first-encountered
    /// candidate, which preserves its source's intra-rank), but
    /// appends the other source's name to the badge so the user
    /// sees "Open Library · Google Books" on cross-source
    /// agreement. Also fills in any optional fields the first
    /// candidate didn't have but the second did (publisher, ISBN,
    /// cover URL) — pragmatic union of the records.
    fileprivate func mergingWith(
        _ other: MetadataCandidate, addedSource: String
    ) -> MetadataCandidate {
        MetadataCandidate(
            id: id,
            title: title,
            author: author ?? other.author,
            publisher: publisher ?? other.publisher,
            year: year ?? other.year,
            isbn: isbn ?? other.isbn,
            language: language ?? other.language,
            coverImageURL: coverImageURL ?? other.coverImageURL,
            sourceName: sourceName.contains(addedSource)
                ? sourceName
                : "\(sourceName) · \(addedSource)",
            sourceURL: sourceURL ?? other.sourceURL
        )
    }
}
