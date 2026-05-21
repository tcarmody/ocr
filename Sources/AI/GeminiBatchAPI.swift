import Foundation

/// P-Gemini-Batch. Google Generative Language Batch API
/// (`POST /v1beta/models/{model}:batchGenerateContent`).
/// 50% off list price in exchange for asynchronous processing.
/// Sibling of `AnthropicBatchAPIClient` — same Phase A → submit →
/// poll → fetch → Phase C lifecycle, different shapes underneath.
///
/// Shape differences worth knowing when reading the code:
///
///   * **Per-model endpoint**: each model has its own URL
///     (`gemini-2.5-flash:batchGenerateContent`,
///     `gemini-3-flash-preview:batchGenerateContent`).
///   * **Correlation**: each batch entry carries
///     `metadata.key` instead of Anthropic's `custom_id`. We use
///     the same `"page-%05d"` format on both providers so the
///     parser stays simple.
///   * **State machine**: `JOB_STATE_PENDING/RUNNING/SUCCEEDED/
///     FAILED/CANCELLED/EXPIRED`. `SUCCEEDED` is the terminal
///     happy state (Anthropic just emits `ended`); `EXPIRED`
///     fires at the 48 h hard cap (Anthropic's cap is 24 h).
///   * **Results delivery**: a typical batch (image-heavy) blows
///     past the 20 MB inline cap, so we route through the Files
///     API: upload a JSONL of requests, submit the batch with
///     `input_config.file_name`, poll to `SUCCEEDED`, download
///     the result JSONL referenced by `dest.fileName`. Three
///     endpoints instead of Anthropic's two.
///
/// Doesn't apply to one-call-per-book features (TOC parsing,
/// chapter classification, metadata extraction, coherence pass)
/// — those don't have anything to batch.

// MARK: - State

/// Google's job state enum. `SUCCEEDED` is the happy terminal;
/// `FAILED` / `CANCELLED` / `EXPIRED` are unhappy terminals;
/// `PENDING` / `RUNNING` are still in flight.
public enum GeminiBatchState: String, Sendable, Codable, Equatable {
    case pending     = "JOB_STATE_PENDING"
    case running     = "JOB_STATE_RUNNING"
    case succeeded   = "JOB_STATE_SUCCEEDED"
    case failed      = "JOB_STATE_FAILED"
    case cancelled   = "JOB_STATE_CANCELLED"
    case expired     = "JOB_STATE_EXPIRED"

    /// True when the batch will no longer change state — caller
    /// can stop polling. `succeeded` is the only terminal we
    /// can fetch results from.
    public var isTerminal: Bool {
        switch self {
        case .succeeded, .failed, .cancelled, .expired:
            return true
        case .pending, .running:
            return false
        }
    }
}

// MARK: - Submit (file-based)

/// Body of `POST /v1beta/models/{model}:batchGenerateContent` for
/// the file-input variant. Phase 1 only supports file input —
/// the inline-requests variant has a 20 MB cap that any
/// image-bearing batch immediately blows through. The shape is
/// nested per Google's API surface
/// (`{batch: {input_config: {file_name: ...}}}`).
public struct GeminiBatchSubmitRequest: Sendable, Encodable, Equatable {
    public var batch: Batch

    public init(displayName: String, inputFileName: String) {
        self.batch = Batch(
            displayName: displayName,
            inputConfig: InputConfig(fileName: inputFileName)
        )
    }

    public struct Batch: Sendable, Encodable, Equatable {
        public var displayName: String
        public var inputConfig: InputConfig

        private enum CodingKeys: String, CodingKey {
            case displayName = "display_name"
            case inputConfig = "input_config"
        }
    }

    public struct InputConfig: Sendable, Encodable, Equatable {
        public var fileName: String

        private enum CodingKeys: String, CodingKey {
            case fileName = "file_name"
        }
    }
}

/// Response from the create-batch endpoint. The server returns
/// the batch resource itself (not a long-running operation
/// envelope), so `name` is immediately usable for the status
/// poll: `GET /v1beta/{name}` where `name` is `batches/abc-123`.
public struct GeminiBatchSubmitResponse: Sendable, Decodable, Equatable {
    /// Fully-qualified resource name like `batches/abc-123` —
    /// use directly as the path for `status` / cancellation.
    public var name: String
    /// Initial state — typically `.pending`. Caller polls.
    public var state: GeminiBatchState
    /// User-visible label echoed from the submit request. Not
    /// load-bearing; useful for logging.
    public var displayName: String?

    public init(
        name: String,
        state: GeminiBatchState,
        displayName: String? = nil
    ) {
        self.name = name
        self.state = state
        self.displayName = displayName
    }

    private enum CodingKeys: String, CodingKey {
        case name, state
        case displayName = "displayName"
    }
}

// MARK: - Status

/// Body of `GET /v1beta/{name}`. The interesting fields are
/// `state` (terminal check) and `dest.fileName` (where to
/// download results from, populated once `state == .succeeded`).
public struct GeminiBatchStatusResponse: Sendable, Decodable, Equatable {
    public var name: String
    public var state: GeminiBatchState
    /// Where to download the results JSONL from. Populated once
    /// `state == .succeeded`. Nil otherwise.
    public var resultsFileName: String?
    /// Free-text error message when `state == .failed` — Google
    /// puts this in `error.message`. nil on the happy path.
    public var errorMessage: String?

    public init(
        name: String,
        state: GeminiBatchState,
        resultsFileName: String? = nil,
        errorMessage: String? = nil
    ) {
        self.name = name
        self.state = state
        self.resultsFileName = resultsFileName
        self.errorMessage = errorMessage
    }

    private enum CodingKeys: String, CodingKey {
        case name, state, dest, error
    }

    private struct Dest: Decodable {
        var fileName: String?

        private enum CodingKeys: String, CodingKey {
            case fileName = "file_name"
        }
    }

    private struct ErrorEnvelope: Decodable {
        var message: String?
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try c.decode(String.self, forKey: .name)
        self.state = try c.decode(GeminiBatchState.self, forKey: .state)
        let dest = try c.decodeIfPresent(Dest.self, forKey: .dest)
        self.resultsFileName = dest?.fileName
        let err = try c.decodeIfPresent(ErrorEnvelope.self, forKey: .error)
        self.errorMessage = err?.message
    }
}

// MARK: - Result

/// One line of the result JSONL stream. The `key` ties the
/// result back to the submit request's `metadata.key`; the
/// payload is either a `GenerateContentResponse` or an error
/// status object.
public struct GeminiBatchResultLine: Sendable, Equatable {
    /// `metadata.key` echoed from the submit. We use
    /// `"page-%05d"` to match Anthropic's `custom_id`.
    public var key: String
    public var result: Result

    public enum Result: Sendable, Equatable {
        case succeeded(rawResponseJSON: Data)
        case errored(message: String)
    }

    public init(key: String, result: Result) {
        self.key = key
        self.result = result
    }
}

// MARK: - Files API

/// Response from the Files-API init step. The full file
/// resource — but the only field we use is `file.name`, which
/// goes into `GeminiBatchSubmitRequest.batch.input_config.fileName`.
public struct GeminiFileResource: Sendable, Decodable, Equatable {
    public var file: File

    public struct File: Sendable, Decodable, Equatable {
        /// Fully-qualified resource name like `files/abc-123`.
        public var name: String
    }
}

// MARK: - Error

public enum GeminiBatchError: Error, LocalizedError {
    case missingAPIKey
    case invalidRequest(message: String)
    case authenticationFailed
    case rateLimited(retryAfter: TimeInterval?)
    case serverError(status: Int, message: String)
    case decode(String)
    case network(any Error)
    /// `awaitCompletion` ran for longer than the configured
    /// `pollTimeout` without seeing a terminal state.
    case pollTimedOut(name: String, seconds: TimeInterval)
    /// Files API init returned no `x-goog-upload-url` header.
    case missingUploadURL
    /// Batch reached a terminal state that isn't `.succeeded` —
    /// caller decides whether to fall back, retry, or surface.
    case unsuccessfulTerminal(state: GeminiBatchState, message: String?)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Missing Google AI Studio API key."
        case .invalidRequest(let m):
            return "Invalid batch request: \(m)"
        case .authenticationFailed:
            return "Gemini batch authentication failed."
        case .rateLimited:
            return "Gemini batch rate-limited."
        case .serverError(let s, let m):
            return "Gemini batch HTTP \(s): \(m)"
        case .decode(let m):
            return "Gemini batch decode: \(m)"
        case .network(let e):
            return e.localizedDescription
        case .pollTimedOut(_, let s):
            return "Batch did not complete within \(Int(s))s."
        case .missingUploadURL:
            return "Gemini Files API returned no upload URL header."
        case .unsuccessfulTerminal(let state, let m):
            return "Batch ended in \(state.rawValue): \(m ?? "(no message)")"
        }
    }
}

// MARK: - Client

/// Dedicated client for the Gemini Batch API + the slice of the
/// Files API we need to feed it. Parallel to
/// `AnthropicBatchAPIClient` — same submit/poll/fetch contract,
/// adapted to Google's resumable-upload + per-model-URL shape.
public actor GeminiBatchAPIClient {
    public struct Config: Sendable, Equatable {
        public var baseURL: URL
        /// Polling cadence for `awaitCompletion`. Default 10 s,
        /// same as Anthropic — Google's batches typically run
        /// minutes-to-hours, so 10 s gives reasonable status
        /// granularity without hammering the API.
        public var pollInterval: TimeInterval
        /// Hard timeout on `awaitCompletion`. 48 h matches
        /// Google's documented hard expiration (`JOB_STATE_EXPIRED`
        /// fires at that point server-side anyway). Caller can
        /// pass shorter for tests.
        public var pollTimeout: TimeInterval
        public var requestTimeout: TimeInterval

        public init(
            baseURL: URL = URL(string: "https://generativelanguage.googleapis.com")!,
            pollInterval: TimeInterval = 10,
            pollTimeout: TimeInterval = 48 * 60 * 60,
            requestTimeout: TimeInterval = 300
        ) {
            self.baseURL = baseURL
            self.pollInterval = pollInterval
            self.pollTimeout = pollTimeout
            self.requestTimeout = requestTimeout
        }
    }

    public let config: Config
    private let transport: any GoogleAITransport
    private let apiKeyProvider: @Sendable () -> String?
    /// Test seam — replaces `Task.sleep` for poll-loop testing.
    private let sleeper: (@Sendable (TimeInterval) async throws -> Void)?

    public init(
        config: Config = Config(),
        transport: any GoogleAITransport = URLSessionGoogleAITransport(),
        apiKeyProvider: @escaping @Sendable () -> String?,
        sleeper: (@Sendable (TimeInterval) async throws -> Void)? = nil
    ) {
        self.config = config
        self.transport = transport
        self.apiKeyProvider = apiKeyProvider
        self.sleeper = sleeper
    }

    // MARK: - Files API: upload JSONL

    /// Upload a JSONL request file. Returns the resource name
    /// (e.g. `"files/abc-123"`) to pass into
    /// `GeminiBatchSubmitRequest(inputFileName:)`. Two-step
    /// resumable protocol per Google's docs:
    ///   1. POST `/upload/v1beta/files` with metadata + length
    ///      headers; pluck `x-goog-upload-url` from response.
    ///   2. POST the raw bytes to that URL with
    ///      `X-Goog-Upload-Command: upload, finalize`.
    public func uploadJSONL(
        _ data: Data,
        displayName: String
    ) async throws -> String {
        guard let key = apiKeyProvider(), !key.isEmpty else {
            throw GeminiBatchError.missingAPIKey
        }

        // Step 1 — init the resumable upload.
        var initURL = config.baseURL
        initURL.append(path: "upload/v1beta/files")
        var initReq = URLRequest(url: initURL, timeoutInterval: config.requestTimeout)
        initReq.httpMethod = "POST"
        initReq.addValue("application/json", forHTTPHeaderField: "Content-Type")
        initReq.addValue(key, forHTTPHeaderField: "x-goog-api-key")
        initReq.addValue("resumable", forHTTPHeaderField: "X-Goog-Upload-Protocol")
        initReq.addValue("start", forHTTPHeaderField: "X-Goog-Upload-Command")
        initReq.addValue(
            String(data.count),
            forHTTPHeaderField: "X-Goog-Upload-Header-Content-Length"
        )
        initReq.addValue(
            "application/jsonl",
            forHTTPHeaderField: "X-Goog-Upload-Header-Content-Type"
        )
        do {
            let metadata = #"{"file":{"display_name":\#(Self.jsonString(displayName))}}"#
            initReq.httpBody = metadata.data(using: .utf8)
        }
        let (initData, initResp) = try await sendRaw(initReq)
        guard let initHTTP = initResp as? HTTPURLResponse else {
            throw GeminiBatchError.decode("non-HTTP response (init)")
        }
        guard (200..<300).contains(initHTTP.statusCode) else {
            throw mapErrorResponse(status: initHTTP.statusCode, body: initData)
        }
        guard let uploadURLString = initHTTP.value(
            forHTTPHeaderField: "x-goog-upload-url"
        ) ?? initHTTP.value(forHTTPHeaderField: "X-Goog-Upload-URL"),
              let uploadURL = URL(string: uploadURLString) else {
            throw GeminiBatchError.missingUploadURL
        }

        // Step 2 — POST the bytes to the resumable URL.
        var uploadReq = URLRequest(url: uploadURL, timeoutInterval: config.requestTimeout)
        uploadReq.httpMethod = "POST"
        uploadReq.addValue(
            "upload, finalize",
            forHTTPHeaderField: "X-Goog-Upload-Command"
        )
        uploadReq.addValue("0", forHTTPHeaderField: "X-Goog-Upload-Offset")
        uploadReq.httpBody = data
        let (uploadData, uploadResp) = try await sendRaw(uploadReq)
        guard let uploadHTTP = uploadResp as? HTTPURLResponse else {
            throw GeminiBatchError.decode("non-HTTP response (upload)")
        }
        guard (200..<300).contains(uploadHTTP.statusCode) else {
            throw mapErrorResponse(status: uploadHTTP.statusCode, body: uploadData)
        }
        do {
            let resource = try Self.decoder.decode(
                GeminiFileResource.self, from: uploadData
            )
            return resource.file.name
        } catch {
            throw GeminiBatchError.decode(String(describing: error))
        }
    }

    // MARK: - Submit

    /// Submit a batch against the given model. Returns the batch
    /// resource name + initial state. Caller polls via `status`.
    public func submit(
        model: String,
        request: GeminiBatchSubmitRequest
    ) async throws -> GeminiBatchSubmitResponse {
        guard let key = apiKeyProvider(), !key.isEmpty else {
            throw GeminiBatchError.missingAPIKey
        }
        var url = config.baseURL
        url.append(path: "v1beta/models/\(model):batchGenerateContent")
        var ur = URLRequest(url: url, timeoutInterval: config.requestTimeout)
        ur.httpMethod = "POST"
        ur.addValue("application/json", forHTTPHeaderField: "Content-Type")
        ur.addValue(key, forHTTPHeaderField: "x-goog-api-key")
        do {
            ur.httpBody = try Self.encoder.encode(request)
        } catch {
            throw GeminiBatchError.invalidRequest(
                message: "batch encoding failed: \(error)"
            )
        }
        let (data, response) = try await sendRaw(ur)
        guard let http = response as? HTTPURLResponse else {
            throw GeminiBatchError.decode("non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw mapErrorResponse(status: http.statusCode, body: data)
        }
        do {
            return try Self.decoder.decode(
                GeminiBatchSubmitResponse.self, from: data
            )
        } catch {
            throw GeminiBatchError.decode(String(describing: error))
        }
    }

    // MARK: - Status

    public func status(
        name: String
    ) async throws -> GeminiBatchStatusResponse {
        guard let key = apiKeyProvider(), !key.isEmpty else {
            throw GeminiBatchError.missingAPIKey
        }
        var url = config.baseURL
        url.append(path: "v1beta/\(name)")
        var ur = URLRequest(url: url, timeoutInterval: config.requestTimeout)
        ur.httpMethod = "GET"
        ur.addValue(key, forHTTPHeaderField: "x-goog-api-key")
        let (data, response) = try await sendRaw(ur)
        guard let http = response as? HTTPURLResponse else {
            throw GeminiBatchError.decode("non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw mapErrorResponse(status: http.statusCode, body: data)
        }
        do {
            return try Self.decoder.decode(
                GeminiBatchStatusResponse.self, from: data
            )
        } catch {
            throw GeminiBatchError.decode(String(describing: error))
        }
    }

    /// Poll until the batch reaches a terminal state. Returns the
    /// final status. Throws `.pollTimedOut` on the configured
    /// `pollTimeout`. Does NOT throw on unsuccessful terminals —
    /// caller inspects `state` and decides what to do. (Anthropic
    /// equivalent has the same posture.)
    public func awaitCompletion(
        name: String
    ) async throws -> GeminiBatchStatusResponse {
        let start = Date()
        while true {
            try Task.checkCancellation()
            let s = try await status(name: name)
            if s.state.isTerminal { return s }
            if Date().timeIntervalSince(start) >= config.pollTimeout {
                throw GeminiBatchError.pollTimedOut(
                    name: name, seconds: config.pollTimeout
                )
            }
            try await sleep(config.pollInterval)
        }
    }

    // MARK: - Fetch results

    /// Download the result JSONL referenced by `name`
    /// (e.g. `"files/abc-results"`, taken from
    /// `GeminiBatchStatusResponse.resultsFileName`). Each line is
    /// parsed into a `GeminiBatchResultLine`; malformed lines are
    /// skipped rather than failing the whole fetch.
    public func fetchResults(
        fileName: String
    ) async throws -> [GeminiBatchResultLine] {
        guard let key = apiKeyProvider(), !key.isEmpty else {
            throw GeminiBatchError.missingAPIKey
        }
        var url = config.baseURL
        url.append(path: "download/v1beta/\(fileName):download")
        var components = URLComponents(
            url: url, resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "alt", value: "media")]
        guard let finalURL = components?.url else {
            throw GeminiBatchError.decode("invalid results URL")
        }
        var ur = URLRequest(url: finalURL, timeoutInterval: config.requestTimeout)
        ur.httpMethod = "GET"
        ur.addValue(key, forHTTPHeaderField: "x-goog-api-key")
        let (data, response) = try await sendRaw(ur)
        guard let http = response as? HTTPURLResponse else {
            throw GeminiBatchError.decode("non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw mapErrorResponse(status: http.statusCode, body: data)
        }
        return Self.parseResultsJSONL(data: data)
    }

    /// Parse a result JSONL byte buffer into per-request result
    /// lines. Each line is expected to be a JSON object shaped
    /// like:
    ///
    ///   {"key": "page-00042",
    ///    "response": {GenerateContentResponse}}
    ///
    /// or for failures:
    ///
    ///   {"key": "page-00042",
    ///    "status": {"code": N, "message": "..."}}
    ///
    /// Unrecognized line shapes become `.errored("malformed
    /// result line")` so the dispatcher can emit empty content
    /// for that page rather than skipping it silently.
    public static func parseResultsJSONL(
        data: Data
    ) -> [GeminiBatchResultLine] {
        let text = String(data: data, encoding: .utf8) ?? ""
        var out: [GeminiBatchResultLine] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = line.data(using: .utf8) else { continue }
            guard let obj = try? JSONSerialization.jsonObject(
                with: lineData, options: []
            ) as? [String: Any] else { continue }
            guard let key = obj["key"] as? String else { continue }
            if let response = obj["response"] {
                // Re-serialize the response sub-object so callers
                // can run their own decoder (matches the existing
                // `GenerateContentResponse` shape the sync engine
                // uses). Failure to re-serialize is treated as
                // "malformed" rather than dropped.
                if let encoded = try? JSONSerialization.data(
                    withJSONObject: response, options: []
                ) {
                    out.append(.init(
                        key: key,
                        result: .succeeded(rawResponseJSON: encoded)
                    ))
                } else {
                    out.append(.init(
                        key: key,
                        result: .errored(message: "malformed response sub-object")
                    ))
                }
            } else if let status = obj["status"] as? [String: Any] {
                let message = (status["message"] as? String) ?? "(no message)"
                out.append(.init(
                    key: key, result: .errored(message: message)
                ))
            } else if let error = obj["error"] as? [String: Any] {
                let message = (error["message"] as? String) ?? "(no message)"
                out.append(.init(
                    key: key, result: .errored(message: message)
                ))
            } else {
                out.append(.init(
                    key: key,
                    result: .errored(message: "malformed result line")
                ))
            }
        }
        return out
    }

    // MARK: - File cleanup

    /// Delete an uploaded file. Best-effort tidiness — call after
    /// the batch completes so input + result files don't pile up
    /// against the user's account. Errors are surfaced so callers
    /// can log; they should not abort the conversion on a delete
    /// failure (Google deletes files automatically after a while
    /// anyway).
    public func deleteFile(name: String) async throws {
        guard let key = apiKeyProvider(), !key.isEmpty else {
            throw GeminiBatchError.missingAPIKey
        }
        var url = config.baseURL
        url.append(path: "v1beta/\(name)")
        var ur = URLRequest(url: url, timeoutInterval: config.requestTimeout)
        ur.httpMethod = "DELETE"
        ur.addValue(key, forHTTPHeaderField: "x-goog-api-key")
        let (data, response) = try await sendRaw(ur)
        guard let http = response as? HTTPURLResponse else {
            throw GeminiBatchError.decode("non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw mapErrorResponse(status: http.statusCode, body: data)
        }
    }

    // MARK: - private

    private func sendRaw(
        _ ur: URLRequest
    ) async throws -> (Data, URLResponse) {
        do {
            return try await transport.send(ur)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw GeminiBatchError.network(error)
        }
    }

    private func sleep(_ seconds: TimeInterval) async throws {
        if let sleeper {
            try await sleeper(seconds)
        } else {
            try await Task.sleep(
                nanoseconds: UInt64(max(0, seconds) * 1_000_000_000)
            )
        }
    }

    private func mapErrorResponse(
        status: Int, body: Data
    ) -> GeminiBatchError {
        let bodyText = String(data: body, encoding: .utf8) ?? ""
        // Google's error envelope: {"error":{"code":N,"message":"…"}}
        var message = bodyText
        if let obj = try? JSONSerialization.jsonObject(
            with: body, options: []
        ) as? [String: Any],
           let err = obj["error"] as? [String: Any],
           let m = err["message"] as? String {
            message = m
        }
        switch status {
        case 400: return .invalidRequest(message: message)
        case 401, 403: return .authenticationFailed
        case 429: return .rateLimited(retryAfter: nil)
        default: return .serverError(status: status, message: message)
        }
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        // The wire format is exactly what we declare in Encodable
        // (snake_case via CodingKeys); don't double-convert.
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        return d
    }()

    /// Escape a Swift string into a JSON-string literal. Used by
    /// the Files-API init step where we hand-build the metadata
    /// body so we don't need a Codable wrapper for one field.
    private static func jsonString(_ s: String) -> String {
        let data = (try? JSONSerialization.data(
            withJSONObject: [s], options: []
        )) ?? Data("[\"\"]".utf8)
        let str = String(data: data, encoding: .utf8) ?? "[\"\"]"
        return String(str.dropFirst().dropLast())
    }
}
