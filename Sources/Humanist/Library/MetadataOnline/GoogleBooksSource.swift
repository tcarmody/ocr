import Foundation

/// Google Books search adapter. Complements `OpenLibrarySource`
/// on the parts of the long tail OL is weaker on: academic
/// monographs, non-Latin scripts, and multilingual editions.
///
/// Free tier without an API key works for low-volume use
/// (~1000 requests/day, rate-limited per source IP). A future
/// Settings field can supply an API key to lift the cap;
/// `apiKey` is wired through here so adding it is a one-line
/// init change rather than a refactor.
///
/// Query shape: `intitle:…+inauthor:…` against
/// `googleapis.com/books/v1/volumes`. Returns up to 10 candidates
/// — the coordinator merges duplicates from other sources.
struct GoogleBooksSource: MetadataSource {
    let name = "Google Books"
    let session: URLSession
    let apiKey: String?

    init(session: URLSession = .shared, apiKey: String? = nil) {
        self.session = session
        self.apiKey = apiKey
    }

    func query(_ q: MetadataQuery) async throws -> [MetadataCandidate] {
        guard !q.isEmpty else { throw MetadataSourceError.emptyQuery }
        let url = try Self.searchURL(for: q, apiKey: apiKey)
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
        return (decoded.items ?? []).compactMap { Self.candidate(from: $0) }
    }

    // MARK: - URL construction

    /// `https://www.googleapis.com/books/v1/volumes?q=…&maxResults=10[&key=…]`.
    /// Google Books accepts qualified terms (`intitle:…`,
    /// `inauthor:…`) joined by `+` for AND-style narrowing.
    static func searchURL(
        for q: MetadataQuery, apiKey: String? = nil
    ) throws -> URL {
        var components = URLComponents(
            string: "https://www.googleapis.com/books/v1/volumes"
        )!
        var fragments: [String] = []
        if let t = q.title?.trimmingCharacters(in: .whitespacesAndNewlines),
           !t.isEmpty {
            fragments.append("intitle:\(t)")
        }
        if let a = q.author?.trimmingCharacters(in: .whitespacesAndNewlines),
           !a.isEmpty {
            fragments.append("inauthor:\(a)")
        }
        var items: [URLQueryItem] = [
            URLQueryItem(name: "q", value: fragments.joined(separator: " ")),
            URLQueryItem(name: "maxResults", value: "10"),
            URLQueryItem(name: "printType", value: "books"),
        ]
        if let key = apiKey, !key.isEmpty {
            items.append(URLQueryItem(name: "key", value: key))
        }
        components.queryItems = items
        guard let url = components.url else {
            throw MetadataSourceError.network(URLError(.badURL))
        }
        return url
    }

    /// Map a Google Books volume into our shared candidate shape.
    /// Returns nil for entries without a title (the rare empty-
    /// volumeInfo edge case the API occasionally returns).
    private static func candidate(from item: Item) -> MetadataCandidate? {
        guard let info = item.volumeInfo,
              let title = info.title
        else { return nil }
        let isbn = info.industryIdentifiers?.first { id in
            // Prefer ISBN_13; fall back to ISBN_10. Either is a
            // valid normalized ISBN per our catalog convention.
            id.type == "ISBN_13" || id.type == "ISBN_10"
        }?.identifier
        let year = info.publishedDate.flatMap { Self.fourDigitYear(from: $0) }
        // Google Books' http thumbnail URL — strip edge=curl and
        // upgrade http→https so the AsyncImage in the picker
        // doesn't run into ATS issues.
        let coverURL = info.imageLinks?.thumbnail
            .flatMap { Self.sanitizeCoverURL($0) }
        let infoURL = info.infoLink.flatMap(URL.init(string:))
        return MetadataCandidate(
            title: title,
            author: info.authors?.first,
            publisher: info.publisher,
            year: year,
            isbn: isbn,
            language: info.language,
            coverImageURL: coverURL,
            sourceName: "Google Books",
            sourceURL: infoURL
        )
    }

    private static func fourDigitYear(from raw: String) -> String? {
        // publishedDate is one of: "1975", "1975-04", "1975-04-15".
        // Take the first 4 digits if present.
        let prefix = raw.prefix(4)
        guard prefix.count == 4, prefix.allSatisfy(\.isNumber) else {
            return nil
        }
        return String(prefix)
    }

    private static func sanitizeCoverURL(_ raw: String) -> URL? {
        // Google Books URLs use http by default + a `&edge=curl`
        // parameter that adds a page-curl effect we don't want
        // in our thumbnails. Strip the curl, upgrade http→https.
        var cleaned = raw.replacingOccurrences(of: "&edge=curl", with: "")
        if cleaned.hasPrefix("http://") {
            cleaned = "https://" + cleaned.dropFirst("http://".count)
        }
        return URL(string: cleaned)
    }

    // MARK: - Wire shape

    private struct SearchResponse: Decodable {
        let items: [Item]?
    }

    private struct Item: Decodable {
        let volumeInfo: VolumeInfo?
    }

    private struct VolumeInfo: Decodable {
        let title: String?
        let authors: [String]?
        let publisher: String?
        let publishedDate: String?
        let industryIdentifiers: [IndustryIdentifier]?
        let language: String?
        let imageLinks: ImageLinks?
        let infoLink: String?
    }

    private struct IndustryIdentifier: Decodable {
        let type: String
        let identifier: String
    }

    private struct ImageLinks: Decodable {
        let thumbnail: String?
    }
}
