import Foundation

/// User-driven query against an online metadata source. v1 supports
/// title + author only; an ISBN-direct path slots in later as a
/// separate query shape. Both fields are optional but at least one
/// must be non-empty for the source to do anything useful.
struct MetadataQuery: Sendable, Equatable {
    let title: String?
    let author: String?

    /// True when neither field carries searchable content. Sources
    /// short-circuit on empty queries — saves a network round-trip
    /// and avoids API rate-limit hits on garbage input.
    var isEmpty: Bool {
        let t = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let a = author?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return t.isEmpty && a.isEmpty
    }
}

/// One match returned from a metadata source. Shape is the union
/// of fields the editor can write back into the catalog (title,
/// author, language) plus richer context the picker displays so
/// the user can disambiguate between editions (year, publisher,
/// ISBN, cover thumbnail, source attribution).
///
/// All optional fields default to nil so sources that return
/// partial records (e.g. older OL entries without `cover_i`) can
/// surface them without padding placeholders.
struct MetadataCandidate: Sendable, Identifiable, Hashable {
    let id: UUID
    let title: String
    let author: String?
    let publisher: String?
    /// 4-digit publication year. Sources that emit ISO dates get
    /// truncated to the year here so the picker reads cleanly.
    let year: String?
    /// Normalized ISBN — digit-only, hyphens stripped, optionally
    /// `X` check-digit uppercase. `nil` when the source didn't
    /// return one.
    let isbn: String?
    /// BCP-47 / MARC language code (`en`, `eng`, `grc`, `la`).
    /// Stored verbatim from the source; the editor's languages
    /// field is a free-text comma-separated list so 3-letter MARC
    /// codes pass through fine.
    let language: String?
    let coverImageURL: URL?
    /// Display name of the catalog ("Open Library" / "Google
    /// Books"). The picker uses this as a per-row badge so the
    /// user knows which source a candidate came from when the
    /// coordinator merges results from multiple.
    let sourceName: String
    /// Canonical link to the source's page for this record. Used
    /// by the picker's "view source" affordance — lets the user
    /// click through to verify before accepting.
    let sourceURL: URL?

    init(
        id: UUID = UUID(),
        title: String,
        author: String? = nil,
        publisher: String? = nil,
        year: String? = nil,
        isbn: String? = nil,
        language: String? = nil,
        coverImageURL: URL? = nil,
        sourceName: String,
        sourceURL: URL? = nil
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.publisher = publisher
        self.year = year
        self.isbn = isbn
        self.language = language
        self.coverImageURL = coverImageURL
        self.sourceName = sourceName
        self.sourceURL = sourceURL
    }
}

/// Pluggable source for online metadata. v1 ships one impl
/// (`OpenLibrarySource`); the protocol exists now so the
/// coordinator can fan queries to multiple sources later without
/// changing call sites. `Sendable` so concrete impls can run on a
/// background actor / detached task.
protocol MetadataSource: Sendable {
    /// Display name for this source — surfaces in the picker as
    /// the per-row badge.
    var name: String { get }

    /// Issue a query and return zero-or-more candidates. Sources
    /// MUST clamp their own result count (typically ≤ 10) to keep
    /// the picker readable. Throws on network or parse failure;
    /// the picker treats a thrown error as "skip this source,
    /// surface a soft error in the UI" rather than failing the
    /// whole lookup.
    func query(_ q: MetadataQuery) async throws -> [MetadataCandidate]
}

/// Surfaced when a source can't complete a query. The picker
/// shows the description verbatim — keep messages short and
/// user-actionable.
enum MetadataSourceError: Error, LocalizedError {
    case emptyQuery
    case network(Error)
    case http(status: Int)
    case decode(String)

    var errorDescription: String? {
        switch self {
        case .emptyQuery:
            return "Enter a title or author to search."
        case .network(let underlying):
            return "Network error: \(underlying.localizedDescription)"
        case .http(let status):
            return "Source returned HTTP \(status)."
        case .decode(let detail):
            return "Couldn't parse response: \(detail)"
        }
    }
}
