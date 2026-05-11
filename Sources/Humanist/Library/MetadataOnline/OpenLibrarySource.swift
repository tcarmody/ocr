import Foundation

/// Open Library search-endpoint adapter. Free, no API key needed,
/// reasonable hit-rate on English-language books with ISBNs;
/// weaker on academic monographs and non-Latin scripts (those
/// gaps are why R-Metadata-Online plans a Claude search
/// consolidator as a follow-on path).
///
/// Query shape: assembles `title:…+author:…` against
/// `openlibrary.org/search.json`. Returns up to 10 candidates,
/// ranked by Open Library's own relevance (we don't re-rank
/// here — the coordinator does that when merging multiple
/// sources).
struct OpenLibrarySource: MetadataSource {
    let name = "Open Library"

    /// Override for the URLSession used. Default uses
    /// `URLSession.shared`; tests can pass an ephemeral session
    /// with a mocked `URLProtocol` to fixture responses without a
    /// live network call.
    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func query(_ q: MetadataQuery) async throws -> [MetadataCandidate] {
        guard !q.isEmpty else { throw MetadataSourceError.emptyQuery }
        let url = try Self.searchURL(for: q)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(from: url)
        } catch {
            throw MetadataSourceError.network(error)
        }
        if let http = response as? HTTPURLResponse,
           !(200...299).contains(http.statusCode) {
            throw MetadataSourceError.http(status: http.statusCode)
        }
        let decoded: SearchResponse
        do {
            decoded = try JSONDecoder().decode(SearchResponse.self, from: data)
        } catch {
            throw MetadataSourceError.decode(error.localizedDescription)
        }
        return decoded.docs
            .prefix(10)
            .map { Self.candidate(from: $0) }
    }

    // MARK: - URL construction

    /// `https://openlibrary.org/search.json?q=…&limit=10`. Open
    /// Library's q parameter accepts qualified fields (`title:…`,
    /// `author:…`) joined by `+` for AND-style narrowing — what
    /// we want when both fields are given.
    static func searchURL(for q: MetadataQuery) throws -> URL {
        var components = URLComponents(
            string: "https://openlibrary.org/search.json"
        )!
        var fragments: [String] = []
        if let t = q.title?.trimmingCharacters(in: .whitespacesAndNewlines),
           !t.isEmpty {
            fragments.append("title:\(t)")
        }
        if let a = q.author?.trimmingCharacters(in: .whitespacesAndNewlines),
           !a.isEmpty {
            fragments.append("author:\(a)")
        }
        let joined = fragments.joined(separator: " ")
        components.queryItems = [
            URLQueryItem(name: "q", value: joined),
            URLQueryItem(name: "limit", value: "10"),
        ]
        guard let url = components.url else {
            throw MetadataSourceError.network(URLError(.badURL))
        }
        return url
    }

    /// Map an OL search-doc into our candidate shape. Picks the
    /// first author / publisher / language / ISBN from the
    /// (potentially long) arrays Open Library returns — the
    /// picker is meant to surface the most-likely match, not a
    /// disambiguator within a single record.
    private static func candidate(from doc: SearchDoc) -> MetadataCandidate {
        let coverURL = doc.cover_i.flatMap { id -> URL? in
            URL(string: "https://covers.openlibrary.org/b/id/\(id)-M.jpg")
        }
        let workURL = doc.key.flatMap { key -> URL? in
            URL(string: "https://openlibrary.org\(key)")
        }
        return MetadataCandidate(
            title: doc.title ?? "Untitled",
            author: doc.author_name?.first,
            publisher: doc.publisher?.first,
            year: doc.first_publish_year.map(String.init),
            isbn: doc.isbn?.first,
            language: doc.language?.first,
            coverImageURL: coverURL,
            sourceName: "Open Library",
            sourceURL: workURL
        )
    }

    // MARK: - Wire shape

    /// Defensive decoder — Open Library returns lots of fields
    /// per doc; we only model what the candidate UI displays.
    /// Anything else is silently dropped.
    private struct SearchResponse: Decodable {
        let docs: [SearchDoc]
    }

    private struct SearchDoc: Decodable {
        let key: String?
        let title: String?
        let author_name: [String]?
        let first_publish_year: Int?
        let publisher: [String]?
        let isbn: [String]?
        let language: [String]?
        let cover_i: Int?
    }
}
