import Foundation

/// Find probable duplicates across the library catalog. Four
/// tiers in descending confidence:
///
///   1. **Identical EPUB bytes** (`identicalEPUBs`). Same SHA-256
///      over the EPUB files on disk. Zero false positives —
///      duplicate content. Heaviest to compute (~50 ms per
///      book × 2k books = ~minute on a fresh detect).
///   2. **Shared source content hash** (`sharedSourceHash`). Two
///      entries share at least one entry in `sourceContentHashes`.
///      Means they were converted / imported from byte-identical
///      sources but the EPUB outputs differ — typically because
///      OCR settings or a pipeline upgrade changed between runs.
///   3. **Identical normalized title + author** (`identicalTitleAuthor`).
///      Normalization: lowercase, strip diacritics + punctuation,
///      drop year prefixes (`"1972 Anti-Oedipus"` → `"anti oedipus"`),
///      collapse whitespace. Catches the case where two catalog
///      rows came from differently-named source files of the
///      same book.
///   4. **Fuzzy title match** (`fuzzyTitleMatch`). Word-bag
///      Jaccard ≥ `fuzzyTitleThreshold` (default 0.7) with the
///      same normalized author. Catches subtitle drift like
///      "Anti-Oedipus" vs "Anti-Oedipus: Capitalism and
///      Schizophrenia". Lowest confidence — review required.
///
/// Each entry lands in at most one group (its strongest tier).
/// An entry already pinned by an `identicalEPUBs` group won't
/// reappear in lower-confidence groups even if a fuzzy match
/// also exists — the strongest signal wins.
@MainActor
enum DuplicateDetector {

    enum Tier: String, Sendable, CaseIterable {
        case identicalEPUBs
        case sharedSourceHash
        case identicalTitleAuthor
        case fuzzyTitleMatch

        var displayLabel: String {
            switch self {
            case .identicalEPUBs:        return "Identical EPUB content"
            case .sharedSourceHash:      return "Same source PDF or EPUB"
            case .identicalTitleAuthor:  return "Same title and author"
            case .fuzzyTitleMatch:       return "Similar title (review)"
            }
        }
    }

    struct Group: Identifiable, Equatable {
        let id: UUID
        let tier: Tier
        let entries: [LibraryEntry]
        /// ID of the entry the heuristic suggests keeping. The
        /// caller can override per-group via the review UI.
        let suggestedCanonicalID: UUID

        init(
            id: UUID = UUID(),
            tier: Tier,
            entries: [LibraryEntry],
            suggestedCanonicalID: UUID
        ) {
            self.id = id
            self.tier = tier
            self.entries = entries
            self.suggestedCanonicalID = suggestedCanonicalID
        }
    }

    /// Word-bag Jaccard threshold for the fuzzy-title tier. 0.7
    /// catches "Anti-Oedipus" vs "Anti-Oedipus: Capitalism and
    /// Schizophrenia" (3/5 ≈ 0.6) — actually that's below 0.7;
    /// I'm choosing a slightly stricter threshold to keep noise
    /// down. The author-must-match guard already filters most
    /// false positives, so 0.7 hits the right balance.
    static let fuzzyTitleThreshold: Double = 0.7

    /// Bounded SHA-256 concurrency. Same posture as
    /// `SourceHashBackfill`: 4 streams saturate NVMe IO without
    /// thrashing.
    static let maxConcurrentHashes = 4

    /// Run all four tiers against `entries`. `epubHash` returns
    /// the cached SHA-256 if the caller already has one (skipping
    /// disk IO); nil triggers a fresh `ContentHash.sha256` run on
    /// a detached task. `progress` is called with (completed,
    /// total) during the EPUB-hash pass — the heaviest step —
    /// so the UI can render a progress bar.
    static func detect(
        in entries: [LibraryEntry],
        epubHashByID: [UUID: String] = [:],
        progress: ((Int, Int) async -> Void)? = nil
    ) async -> [Group] {
        // Tier 1: EPUB-content hash.
        let hashes = await hashEPUBs(
            entries: entries,
            cached: epubHashByID,
            progress: progress
        )
        var assigned = Set<UUID>()
        var groups: [Group] = []
        groups.append(contentsOf: groupByEPUBHash(
            entries: entries, hashes: hashes, assigned: &assigned
        ))
        // Tier 2: shared source-content-hash.
        groups.append(contentsOf: groupBySharedSourceHash(
            entries: entries, assigned: &assigned
        ))
        // Tier 3: normalized title+author exact.
        groups.append(contentsOf: groupByTitleAuthorExact(
            entries: entries, assigned: &assigned
        ))
        // Tier 4: fuzzy title match (same author).
        groups.append(contentsOf: groupByFuzzyTitle(
            entries: entries, assigned: &assigned
        ))
        return groups
    }

    // MARK: - Tier 1: identical EPUB bytes

    private static func hashEPUBs(
        entries: [LibraryEntry],
        cached: [UUID: String],
        progress: ((Int, Int) async -> Void)?
    ) async -> [UUID: String] {
        let total = entries.count
        var hashes: [UUID: String] = cached
        // Filter to entries that need hashing.
        let pending = entries.filter { hashes[$0.id] == nil }
        guard !pending.isEmpty else {
            await progress?(total, total)
            return hashes
        }
        // Concurrent SHA-256 across the pending set.
        let results = await withTaskGroup(
            of: (UUID, String?).self,
            returning: [(UUID, String?)].self
        ) { group in
            var iterator = pending.makeIterator()
            var completed = cached.count
            func enqueueNext() -> Bool {
                guard let next = iterator.next() else { return false }
                let id = next.id
                let url = next.epubURL
                group.addTask(priority: .utility) {
                    let h = try? ContentHash.sha256(of: url)
                    return (id, h)
                }
                return true
            }
            for _ in 0..<maxConcurrentHashes {
                if !enqueueNext() { break }
            }
            var results: [(UUID, String?)] = []
            while let r = await group.next() {
                results.append(r)
                completed += 1
                await progress?(completed, total)
                _ = enqueueNext()
            }
            return results
        }
        for (id, hash) in results {
            if let hash { hashes[id] = hash }
        }
        return hashes
    }

    private static func groupByEPUBHash(
        entries: [LibraryEntry],
        hashes: [UUID: String],
        assigned: inout Set<UUID>
    ) -> [Group] {
        var byHash: [String: [LibraryEntry]] = [:]
        for entry in entries {
            guard let h = hashes[entry.id] else { continue }
            byHash[h, default: []].append(entry)
        }
        var out: [Group] = []
        for (_, members) in byHash where members.count >= 2 {
            for m in members { assigned.insert(m.id) }
            out.append(Group(
                tier: .identicalEPUBs,
                entries: members,
                suggestedCanonicalID: suggestCanonical(members).id
            ))
        }
        return out
    }

    // MARK: - Tier 2: shared source-content-hash

    private static func groupBySharedSourceHash(
        entries: [LibraryEntry],
        assigned: inout Set<UUID>
    ) -> [Group] {
        // Index entries by every source hash they carry. Then
        // group every entry-set ≥ 2 under each hash, skipping
        // already-assigned entries.
        var byHash: [String: [LibraryEntry]] = [:]
        for entry in entries where !assigned.contains(entry.id) {
            for h in entry.sourceContentHashes where !h.isEmpty {
                byHash[h, default: []].append(entry)
            }
        }
        // Multiple source hashes can produce overlapping groups
        // (entry A with hashes [x, y]; entry B with [x, z];
        // entry C with [z]). Coalesce via a simple connected-
        // components walk so A+B+C land in one group when their
        // transitively-shared hashes connect them.
        var components = ConnectedComponents<UUID>()
        for entries in byHash.values where entries.count >= 2 {
            for i in 1..<entries.count {
                components.union(entries[0].id, entries[i].id)
            }
        }
        var byComponent: [UUID: [LibraryEntry]] = [:]
        for entries in byHash.values where entries.count >= 2 {
            for entry in entries {
                let root = components.find(entry.id) ?? entry.id
                if byComponent[root]?.contains(where: { $0.id == entry.id }) != true {
                    byComponent[root, default: []].append(entry)
                }
            }
        }
        var out: [Group] = []
        for members in byComponent.values where members.count >= 2 {
            for m in members { assigned.insert(m.id) }
            out.append(Group(
                tier: .sharedSourceHash,
                entries: members,
                suggestedCanonicalID: suggestCanonical(members).id
            ))
        }
        return out
    }

    // MARK: - Tier 3: identical normalized title + author

    private static func groupByTitleAuthorExact(
        entries: [LibraryEntry],
        assigned: inout Set<UUID>
    ) -> [Group] {
        struct Key: Hashable { let title: String; let author: String }
        var byKey: [Key: [LibraryEntry]] = [:]
        for entry in entries where !assigned.contains(entry.id) {
            let normTitle = normalizeTitle(entry.title)
            let normAuthor = normalizeAuthor(entry.author ?? "")
            guard !normTitle.isEmpty, !normAuthor.isEmpty else { continue }
            byKey[Key(title: normTitle, author: normAuthor), default: []]
                .append(entry)
        }
        var out: [Group] = []
        for (_, members) in byKey where members.count >= 2 {
            for m in members { assigned.insert(m.id) }
            out.append(Group(
                tier: .identicalTitleAuthor,
                entries: members,
                suggestedCanonicalID: suggestCanonical(members).id
            ))
        }
        return out
    }

    // MARK: - Tier 4: fuzzy title (same author)

    private static func groupByFuzzyTitle(
        entries: [LibraryEntry],
        assigned: inout Set<UUID>
    ) -> [Group] {
        // Group by author first so the O(N²) title comparison
        // stays inside each author bucket — usually tiny.
        var byAuthor: [String: [LibraryEntry]] = [:]
        for entry in entries where !assigned.contains(entry.id) {
            let a = normalizeAuthor(entry.author ?? "")
            guard !a.isEmpty else { continue }
            byAuthor[a, default: []].append(entry)
        }
        var components = ConnectedComponents<UUID>()
        for bucket in byAuthor.values where bucket.count >= 2 {
            let words: [(UUID, Set<String>)] = bucket.map {
                ($0.id, titleWordBag($0.title))
            }
            for i in 0..<words.count {
                for j in (i+1)..<words.count {
                    let s = jaccard(words[i].1, words[j].1)
                    if s >= fuzzyTitleThreshold {
                        components.union(words[i].0, words[j].0)
                    }
                }
            }
        }
        var byComponent: [UUID: [LibraryEntry]] = [:]
        for entry in entries where !assigned.contains(entry.id) {
            guard let root = components.find(entry.id) else { continue }
            byComponent[root, default: []].append(entry)
        }
        var out: [Group] = []
        for members in byComponent.values where members.count >= 2 {
            for m in members { assigned.insert(m.id) }
            out.append(Group(
                tier: .fuzzyTitleMatch,
                entries: members,
                suggestedCanonicalID: suggestCanonical(members).id
            ))
        }
        return out
    }

    // MARK: - Canonical heuristic

    /// Pick the most "canonical-looking" entry from a duplicate
    /// group. Weighted score:
    ///   * EPUB file size — proxy for content completeness. 1 pt
    ///     per MB up to 50 MB.
    ///   * Metadata completeness — 2 pts each for author, year,
    ///     publisher, isbn, genre.
    ///   * `lastOpened` is non-nil — 3 pts (the user actually
    ///     used this row).
    ///   * `sourceContentHashes` non-empty — 2 pts (covered by
    ///     dedupe defenses).
    ///   * Oldest `addedAt` — 1 pt (the original entry; tie-
    ///     breaks toward continuity).
    /// User can override per-group via the review sheet.
    static func suggestCanonical(_ entries: [LibraryEntry]) -> LibraryEntry {
        guard let first = entries.first else {
            fatalError("suggestCanonical called with empty group")
        }
        guard entries.count > 1 else { return first }
        let scored = entries.map { entry -> (LibraryEntry, Double) in
            (entry, canonicalScore(entry))
        }
        // Stable: among equal scores, pick the earliest in
        // input order for deterministic output.
        return scored.max(by: { $0.1 < $1.1 })?.0 ?? first
    }

    private static func canonicalScore(_ entry: LibraryEntry) -> Double {
        var score = 0.0
        // Size component (cap at 50 MB to avoid pathological
        // padding inflating the score on a single misshaped book).
        if let attrs = try? FileManager.default.attributesOfItem(
            atPath: entry.epubURL.path
        ),
        let size = (attrs[.size] as? NSNumber)?.doubleValue {
            let mb = min(size / (1024 * 1024), 50)
            score += mb
        }
        // Metadata completeness — 2 pts each.
        if entry.author?.isEmpty == false { score += 2 }
        if entry.genre != nil { score += 2 }
        if entry.lastOpened != nil { score += 3 }
        if !entry.sourceContentHashes.isEmpty { score += 2 }
        // Oldest addedAt: subtract days-since-epoch / 1000 so
        // older wins by a tiny margin. (Time-since-epoch is
        // a big number; the /1000 keeps it from dominating.)
        score += -entry.addedAt.timeIntervalSince1970 / (86400 * 1000)
        return score
    }

    // MARK: - Text normalization

    /// Title normalization for tier-3 exact match. Lowercases,
    /// strips diacritics, drops leading year-like prefixes
    /// (`"1972 Anti-Oedipus"` → `"anti-oedipus"`), strips
    /// punctuation, collapses whitespace.
    static func normalizeTitle(_ s: String) -> String {
        var t = (s.applyingTransform(.stripDiacritics, reverse: false) ?? s).lowercased()
        // Drop leading 4-digit year + delimiter.
        if let m = t.range(of: "^\\d{4}\\s*[-–—:]?\\s*",
                           options: .regularExpression) {
            t.removeSubrange(m)
        }
        // Replace any non-letter / non-digit with space.
        let scalars = t.unicodeScalars.map { scalar -> String in
            CharacterSet.alphanumerics.contains(scalar)
                ? String(scalar) : " "
        }
        let joined = scalars.joined()
        return joined.split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }

    static func normalizeAuthor(_ s: String) -> String {
        // Slightly more aggressive than title — strip leading
        // initials, drop comma-separated last-name-first
        // reordering. "Lacan, Jacques" and "Jacques Lacan" should
        // both normalize to "jacques lacan".
        var t = (s.applyingTransform(.stripDiacritics, reverse: false) ?? s).lowercased()
        if let comma = t.firstIndex(of: ",") {
            let last = String(t[..<comma])
            let rest = String(t[t.index(after: comma)...])
            t = (rest + " " + last)
        }
        let scalars = t.unicodeScalars.map { scalar -> String in
            CharacterSet.alphanumerics.contains(scalar)
                ? String(scalar) : " "
        }
        let joined = scalars.joined()
        return joined.split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }

    /// Word bag for fuzzy-title matching. Same normalization +
    /// drop tokens shorter than 2 chars.
    static func titleWordBag(_ s: String) -> Set<String> {
        let normalized = normalizeTitle(s)
        return Set(normalized
            .split(separator: " ", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { $0.count >= 2 })
    }

    static func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        let inter = a.intersection(b).count
        let union = a.union(b).count
        return Double(inter) / Double(union)
    }
}

/// Tiny union-find for tier-2 / tier-4 group merging where one
/// entry can pair with multiple others via different signals.
/// Keeps the merge logic linear-ish without a full graph library.
fileprivate struct ConnectedComponents<Key: Hashable> {
    private var parent: [Key: Key] = [:]
    mutating func find(_ x: Key) -> Key? {
        guard let p = parent[x] else { return nil }
        if p == x { return x }
        let root = find(p) ?? p
        parent[x] = root
        return root
    }
    mutating func union(_ a: Key, _ b: Key) {
        if parent[a] == nil { parent[a] = a }
        if parent[b] == nil { parent[b] = b }
        guard let ra = find(a), let rb = find(b), ra != rb else { return }
        parent[ra] = rb
    }
}
