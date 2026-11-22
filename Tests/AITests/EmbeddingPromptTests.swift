import XCTest
@testable import AI

/// Query / document handling across embedding backends: the
/// EmbeddingGemma 2 default, the per-model Ollama prompt prefixes,
/// and the `.prefixed` identifier that forces a re-embed.
final class EmbeddingPromptTests: XCTestCase {

    // MARK: - Defaults and prefix lookup

    func test_default_ollama_model_is_embeddinggemma_2_text_only() {
        XCTAssertEqual(EmbeddingBackendChoice.defaultOllamaModel, "embeddinggemma-2:270m")
    }

    func test_prefixes_for_embeddinggemma_tags() {
        for tag in ["embeddinggemma-2:270m", "embeddinggemma-2", "embeddinggemma-2:740m-q8_0",
                    "embeddinggemma:300m", "EmbeddingGemma-2:270m"] {
            XCTAssertEqual(EmbeddingPromptPrefixes.forOllamaModel(tag), .embeddingGemma, tag)
        }
        XCTAssertEqual(EmbeddingPromptPrefixes.embeddingGemma.query, "task: search result | query: ")
        XCTAssertEqual(EmbeddingPromptPrefixes.embeddingGemma.document, "title: none | text: ")
    }

    func test_prefixes_for_nomic_and_unknown_models() {
        XCTAssertEqual(EmbeddingPromptPrefixes.forOllamaModel("nomic-embed-text"), .nomicEmbedText)
        XCTAssertEqual(EmbeddingPromptPrefixes.forOllamaModel("nomic-embed-text:v1.5"), .nomicEmbedText)
        XCTAssertNil(EmbeddingPromptPrefixes.forOllamaModel("mxbai-embed-large"))
        XCTAssertNil(EmbeddingPromptPrefixes.forOllamaModel("all-minilm:l6-v2"))
    }

    func test_namespaced_model_tags_match_on_the_model_name() {
        XCTAssertEqual(
            EmbeddingPromptPrefixes.forOllamaModel("someuser/embeddinggemma-2:270m"),
            .embeddingGemma
        )
    }

    func test_identifier_marks_prefixed_models() {
        XCTAssertEqual(
            OllamaEmbeddingBackend.identifier(model: "embeddinggemma-2:270m", prefixes: .embeddingGemma),
            "ollama.embeddinggemma-2:270m.prefixed"
        )
        // nomic sidecars from before prefixes were applied get a new
        // identifier, so they rebuild instead of mixing vector styles.
        XCTAssertEqual(
            OllamaEmbeddingBackend.identifier(model: "nomic-embed-text", prefixes: .nomicEmbedText),
            "ollama.nomic-embed-text.prefixed"
        )
        XCTAssertEqual(
            OllamaEmbeddingBackend.identifier(model: "mxbai-embed-large", prefixes: nil),
            "ollama.mxbai-embed-large"
        )
        XCTAssertTrue(
            OllamaEmbeddingBackend.identifier(model: "x", prefixes: .embeddingGemma)
                .hasPrefix(EmbeddingBackendChoice.ollama.identifierPrefix)
        )
    }

    // MARK: - Ollama wire format

    override func setUp() {
        super.setUp()
        OllamaStubProtocol.reset()
        URLProtocol.registerClass(OllamaStubProtocol.self)
    }

    override func tearDown() {
        URLProtocol.unregisterClass(OllamaStubProtocol.self)
        super.tearDown()
    }

    private func makeClient() -> OllamaClient {
        OllamaClient(config: .init(baseURL: URL(string: "http://ollama-stub.invalid")!))
    }

    func test_ollama_backend_prefixes_documents_and_queries() async throws {
        let backend = try await OllamaEmbeddingBackend.make(
            model: "embeddinggemma-2:270m", client: makeClient()
        )
        XCTAssertEqual(backend.dimension, 3)
        XCTAssertEqual(backend.identifier, "ollama.embeddinggemma-2:270m.prefixed")

        _ = try await backend.embed(["Paragraph one.", "Paragraph two."])
        _ = try await backend.embedQuery(["what is humanism?"])

        let inputs = OllamaStubProtocol.inputs()
        // [0] is the dimension probe, sent unprefixed.
        XCTAssertEqual(inputs.count, 3)
        XCTAssertEqual(inputs[0], ["x"])
        XCTAssertEqual(inputs[1], [
            "title: none | text: Paragraph one.",
            "title: none | text: Paragraph two.",
        ])
        XCTAssertEqual(inputs[2], ["task: search result | query: what is humanism?"])
        XCTAssertEqual(OllamaStubProtocol.models().last, "embeddinggemma-2:270m")
    }

    func test_ollama_backend_leaves_unknown_models_unprefixed() async throws {
        let backend = try await OllamaEmbeddingBackend.make(
            model: "mxbai-embed-large", client: makeClient()
        )
        XCTAssertEqual(backend.identifier, "ollama.mxbai-embed-large")
        _ = try await backend.embed(["doc"])
        _ = try await backend.embedQuery(["query"])
        XCTAssertEqual(OllamaStubProtocol.inputs().suffix(2), [["doc"], ["query"]])
    }

    // MARK: - Default embedQuery

    func test_default_embed_query_falls_back_to_embed() async throws {
        struct Symmetric: EmbeddingBackend {
            let identifier = "test.symmetric"
            let dimension = 1
            func embed(_ texts: [String]) async throws -> [[Float]] {
                texts.map { [Float($0.count)] }
            }
        }
        let v = try await Symmetric().embedQuery(["abc"])
        XCTAssertEqual(v, [[3]])
    }
}

/// Answers `POST /api/embed` on `ollama-stub.invalid` with one
/// 3-dimensional vector per input and records each request's
/// `model` and `input`.
final class OllamaStubProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var recorded: [(model: String, input: [String])] = []

    static func reset() { lock.withLock { recorded = [] } }
    static func inputs() -> [[String]] { lock.withLock { recorded.map(\.input) } }
    static func models() -> [String] { lock.withLock { recorded.map(\.model) } }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "ollama-stub.invalid"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = Self.bodyData(of: request)
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        let model = json["model"] as? String ?? ""
        let input: [String]
        if let many = json["input"] as? [String] {
            input = many
        } else if let one = json["input"] as? String {
            input = [one]
        } else {
            input = []
        }
        Self.lock.withLock { Self.recorded.append((model, input)) }

        let embeddings = input.map { _ in [0.1, 0.2, 0.3] }
        let data = try! JSONSerialization.data(withJSONObject: [
            "model": model, "embeddings": embeddings,
        ])
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// URLSession moves `httpBody` into `httpBodyStream` before a
    /// protocol sees it.
    private static func bodyData(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
}
