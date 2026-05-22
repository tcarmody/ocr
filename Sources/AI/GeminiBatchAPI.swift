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

/// Google's batch-state enum. The live API returns
/// `BATCH_STATE_*`; older docs (and the LRO machinery elsewhere
/// in Google's stack) use `JOB_STATE_*`. We accept both spellings
/// on decode and serialize as the `BATCH_STATE_*` form to match
/// what the wire actually returns today. `succeeded` is the
/// happy terminal; `failed` / `cancelled` / `expired` are
/// unhappy terminals; `pending` / `running` are still in flight.
public enum GeminiBatchState: String, Sendable, Equatable {
    case pending
    case running
    case succeeded
    case failed
    case cancelled
    case expired

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

extension GeminiBatchState: Codable {
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        // Strip whichever prefix the API picked. Live responses
        // use BATCH_STATE_*; older docs / SDKs surface JOB_STATE_*.
        let stripped: String
        if raw.hasPrefix("BATCH_STATE_") {
            stripped = String(raw.dropFirst("BATCH_STATE_".count))
        } else if raw.hasPrefix("JOB_STATE_") {
            stripped = String(raw.dropFirst("JOB_STATE_".count))
        } else {
            stripped = raw
        }
        switch stripped.uppercased() {
        case "PENDING":   self = .pending
        case "RUNNING":   self = .running
        case "SUCCEEDED": self = .succeeded
        case "FAILED":    self = .failed
        case "CANCELLED", "CANCELED": self = .cancelled
        case "EXPIRED":   self = .expired
        default:
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "unknown batch state: \(raw)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        let token: String
        switch self {
        case .pending:   token = "BATCH_STATE_PENDING"
        case .running:   token = "BATCH_STATE_RUNNING"
        case .succeeded: token = "BATCH_STATE_SUCCEEDED"
        case .failed:    token = "BATCH_STATE_FAILED"
        case .cancelled: token = "BATCH_STATE_CANCELLED"
        case .expired:   token = "BATCH_STATE_EXPIRED"
        }
        try c.encode(token)
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

/// Response from the create-batch endpoint. Google returns a
/// Long-Running Operation envelope: top-level `name` is the
/// batch resource name; `metadata` carries the live state +
/// stats. We surface the fields we actually use.
public struct GeminiBatchSubmitResponse: Sendable, Decodable, Equatable {
    /// Fully-qualified resource name like `batches/abc-123` —
    /// use directly as the path for `status` / cancellation.
    public var name: String
    /// Initial state — typically `.pending`. Caller polls.
    /// Lives at `metadata.state` on the wire.
    public var state: GeminiBatchState
    /// User-visible label echoed from the submit request. Not
    /// load-bearing; useful for logging. Lives at
    /// `metadata.displayName`.
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
        case name, metadata, state, displayName
    }

    private struct Metadata: Decodable {
        var state: GeminiBatchState
        var displayName: String?
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try c.decode(String.self, forKey: .name)
        // Try `metadata.state` first (live API shape); fall back
        // to top-level `state` if a future SDK surfaces it flat.
        if let meta = try? c.decode(Metadata.self, forKey: .metadata) {
            self.state = meta.state
            self.displayName = meta.displayName
        } else {
            self.state = try c.decode(GeminiBatchState.self, forKey: .state)
            self.displayName = try? c.decode(String.self, forKey: .displayName)
        }
    }
}

// MARK: - Status

/// Body of `GET /v1beta/{name}` — the same Long-Running
/// Operation envelope as submit. Once `metadata.state` reaches
/// `.succeeded`, the results file name appears at either
/// `response.responsesFile` (live API per docs hint) or
/// `metadata.responsesFile` / a `dest.fileName` shape (older
/// SDK paths). We try each defensively so an API tweak doesn't
/// silently re-empty the EPUB.
public struct GeminiBatchStatusResponse: Sendable, Decodable, Equatable {
    public var name: String
    public var state: GeminiBatchState
    /// Where to download the results JSONL from. Populated once
    /// `state == .succeeded`. Nil otherwise.
    public var resultsFileName: String?
    /// Free-text error message when `state == .failed`. Lives at
    /// `error.message` or `metadata.error.message` depending on
    /// the API path that surfaced it.
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

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: TopKeys.self)
        self.name = try c.decode(String.self, forKey: .name)

        // State + (some shapes) error.message + (some shapes)
        // results file all live under `metadata`. Try that
        // first; fall back to flat top-level shape.
        var state: GeminiBatchState? = nil
        var resultsFile: String? = nil
        var errorMessage: String? = nil

        if let meta = try? c.decode(Metadata.self, forKey: .metadata) {
            state = meta.state
            if let f = meta.responsesFile { resultsFile = f }
            if let f = meta.dest?.fileName { resultsFile = resultsFile ?? f }
            if let m = meta.error?.message { errorMessage = m }
        }
        if state == nil {
            state = try c.decode(GeminiBatchState.self, forKey: .state)
        }
        // `response.responsesFile` is the docs-hinted location on
        // the succeeded LRO. Falls back through alternative
        // shapes so we tolerate minor API drift.
        if let resp = try? c.decode(ResponseEnvelope.self, forKey: .response) {
            if let f = resp.responsesFile { resultsFile = resultsFile ?? f }
            if let f = resp.dest?.fileName { resultsFile = resultsFile ?? f }
        }
        // Flat top-level dest as a last-ditch fallback.
        if let dest = try? c.decode(Dest.self, forKey: .dest) {
            if let f = dest.fileName { resultsFile = resultsFile ?? f }
        }
        if errorMessage == nil,
           let err = try? c.decode(ErrorEnvelope.self, forKey: .error) {
            errorMessage = err.message
        }

        self.state = state!
        self.resultsFileName = resultsFile
        self.errorMessage = errorMessage
    }

    private enum TopKeys: String, CodingKey {
        case name, state, metadata, response, dest, error
    }

    /// `metadata` block on the LRO envelope.
    private struct Metadata: Decodable {
        var state: GeminiBatchState
        var responsesFile: String?
        var dest: Dest?
        var error: ErrorEnvelope?

        private enum CodingKeys: String, CodingKey {
            case state, responsesFile, dest, error
        }
    }

    /// `response` block on a succeeded LRO. Holds the file name
    /// either as `responsesFile` (docs-hinted) or nested in a
    /// `dest` object.
    private struct ResponseEnvelope: Decodable {
        var responsesFile: String?
        var dest: Dest?
    }

    /// `dest` block — accepts both camelCase and snake_case.
    private struct Dest: Decodable {
        var fileName: String?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyCodingKey.self)
            self.fileName = (try? c.decode(String.self, forKey: .init(stringValue: "fileName")!))
                ?? (try? c.decode(String.self, forKey: .init(stringValue: "file_name")!))
        }
    }

    private struct ErrorEnvelope: Decodable {
        var message: String?
    }

    /// Tiny dynamic-key helper so the `Dest` decoder can probe
    /// both spellings without exploding into two CodingKeys
    /// enums.
    private struct AnyCodingKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
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
    /// Optional append-only log destination for diagnostic
    /// tracing. When non-nil, every phase boundary (upload init,
    /// upload finalize, submit, status poll, fetchResults) writes
    /// a timestamped line to this URL. Used by the pipeline's
    /// `emitDebugLog` path so a failed run leaves a forensic
    /// trail next to the rest of the staging artifacts. Nil =
    /// no-op.
    private let debugLogURL: URL?

    public init(
        config: Config = Config(),
        transport: any GoogleAITransport = URLSessionGoogleAITransport(),
        apiKeyProvider: @escaping @Sendable () -> String?,
        sleeper: (@Sendable (TimeInterval) async throws -> Void)? = nil,
        debugLogURL: URL? = nil
    ) {
        self.config = config
        self.transport = transport
        self.apiKeyProvider = apiKeyProvider
        self.sleeper = sleeper
        self.debugLogURL = debugLogURL
    }

    /// Append one diagnostic line to `debugLogURL`. Cheap when
    /// the URL is nil (early return) so it's safe to scatter
    /// calls liberally through the phase-boundary code. Each
    /// call opens / appends / closes — wasteful on a fast loop,
    /// fine for the ~10-20 lines a real batch generates.
    private func log(_ message: String) {
        guard let url = debugLogURL else { return }
        // Build a fresh formatter per call — cheap, sidesteps
        // ISO8601DateFormatter's non-Sendable status without
        // needing `nonisolated(unsafe)` ceremony for what's a
        // diagnostic-only path.
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [
            .withInternetDateTime, .withFractionalSeconds
        ]
        let stamp = formatter.string(from: Date())
        let line = "[\(stamp)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: url.path) {
            if let handle = try? FileHandle(forWritingTo: url) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            }
        } else {
            try? data.write(to: url)
        }
    }

    /// Truncate a string to `n` characters with a tail marker, so
    /// long response bodies don't blow up the log file. JSON bodies
    /// over a few KB get capped — enough to see the wire shape +
    /// any error message without spamming the log.
    private static func truncate(_ s: String, max n: Int = 1024) -> String {
        if s.count <= n { return s }
        return String(s.prefix(n)) + "… [+\(s.count - n) chars]"
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
        log("uploadJSONL begin — \(data.count) bytes, displayName=\(displayName)")

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
            log("uploadJSONL init: non-HTTP response")
            throw GeminiBatchError.decode("non-HTTP response (init)")
        }
        log("uploadJSONL init response: status=\(initHTTP.statusCode) headers=\(initHTTP.allHeaderFields)")
        guard (200..<300).contains(initHTTP.statusCode) else {
            let body = String(data: initData, encoding: .utf8) ?? ""
            log("uploadJSONL init failed body: \(Self.truncate(body))")
            throw mapErrorResponse(status: initHTTP.statusCode, body: initData)
        }
        guard let uploadURLString = initHTTP.value(
            forHTTPHeaderField: "x-goog-upload-url"
        ) ?? initHTTP.value(forHTTPHeaderField: "X-Goog-Upload-URL"),
              let uploadURL = URL(string: uploadURLString) else {
            log("uploadJSONL init missing x-goog-upload-url header — headers: \(initHTTP.allHeaderFields)")
            throw GeminiBatchError.missingUploadURL
        }
        log("uploadJSONL init OK — uploadURL=\(uploadURLString)")

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
            log("uploadJSONL finalize: non-HTTP response")
            throw GeminiBatchError.decode("non-HTTP response (upload)")
        }
        let uploadBody = String(data: uploadData, encoding: .utf8) ?? ""
        log("uploadJSONL finalize: status=\(uploadHTTP.statusCode) body=\(Self.truncate(uploadBody))")
        guard (200..<300).contains(uploadHTTP.statusCode) else {
            throw mapErrorResponse(status: uploadHTTP.statusCode, body: uploadData)
        }
        do {
            let resource = try Self.decoder.decode(
                GeminiFileResource.self, from: uploadData
            )
            log("uploadJSONL OK — file.name=\(resource.file.name)")
            return resource.file.name
        } catch {
            log("uploadJSONL decode failed: \(error) (raw body shown above)")
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
            log("submit encode failed: \(error)")
            throw GeminiBatchError.invalidRequest(
                message: "batch encoding failed: \(error)"
            )
        }
        if let body = ur.httpBody,
           let bodyText = String(data: body, encoding: .utf8) {
            log("submit POST \(url.path) body=\(Self.truncate(bodyText))")
        }
        let (data, response) = try await sendRaw(ur)
        guard let http = response as? HTTPURLResponse else {
            log("submit: non-HTTP response")
            throw GeminiBatchError.decode("non-HTTP response")
        }
        let bodyText = String(data: data, encoding: .utf8) ?? ""
        log("submit response: status=\(http.statusCode) body=\(Self.truncate(bodyText))")
        guard (200..<300).contains(http.statusCode) else {
            throw mapErrorResponse(status: http.statusCode, body: data)
        }
        do {
            let decoded = try Self.decoder.decode(
                GeminiBatchSubmitResponse.self, from: data
            )
            log("submit OK — name=\(decoded.name) state=\(decoded.state.rawValue)")
            return decoded
        } catch {
            log("submit decode failed: \(error)")
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
            log("status: non-HTTP response for \(name)")
            throw GeminiBatchError.decode("non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            log("status \(name) failed: \(http.statusCode) body=\(Self.truncate(bodyText))")
            throw mapErrorResponse(status: http.statusCode, body: data)
        }
        do {
            let decoded = try Self.decoder.decode(
                GeminiBatchStatusResponse.self, from: data
            )
            // Always log the FULL raw status body so we can compare
            // wire shape vs decoded values. This is the spot where
            // dest.fileName vs dest.file_name disagreements surface.
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            log("status \(name) decoded: state=\(decoded.state.rawValue) resultsFileName=\(decoded.resultsFileName ?? "nil") errorMessage=\(decoded.errorMessage ?? "nil") rawBody=\(Self.truncate(bodyText, max: 2048))")
            return decoded
        } catch {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            log("status \(name) decode failed: \(error) rawBody=\(Self.truncate(bodyText, max: 2048))")
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
            log("fetchResults: invalid URL for \(fileName)")
            throw GeminiBatchError.decode("invalid results URL")
        }
        log("fetchResults GET \(finalURL.absoluteString)")
        var ur = URLRequest(url: finalURL, timeoutInterval: config.requestTimeout)
        ur.httpMethod = "GET"
        ur.addValue(key, forHTTPHeaderField: "x-goog-api-key")
        let (data, response) = try await sendRaw(ur)
        guard let http = response as? HTTPURLResponse else {
            log("fetchResults: non-HTTP response")
            throw GeminiBatchError.decode("non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            log("fetchResults failed: \(http.statusCode) body=\(Self.truncate(bodyText))")
            throw mapErrorResponse(status: http.statusCode, body: data)
        }
        // Log the first result-line raw bytes so we can see the
        // actual wire shape — `key` field, nested vs top-level,
        // any unexpected wrappers Google adds.
        let bodyText = String(data: data, encoding: .utf8) ?? ""
        let firstLine = bodyText.split(separator: "\n").first.map(String.init) ?? ""
        log("fetchResults OK: bytes=\(data.count) firstLine=\(Self.truncate(firstLine, max: 1500))")
        let parsed = Self.parseResultsJSONL(data: data)
        let succeeded = parsed.filter {
            if case .succeeded = $0.result { return true }
            return false
        }.count
        let errored = parsed.count - succeeded
        log("fetchResults parsed: total=\(parsed.count) succeeded=\(succeeded) errored=\(errored) keys=\(parsed.prefix(5).map(\.key).joined(separator: ","))")
        return parsed
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
            // Live API shape: `metadata.key` (mirrors how the
            // submit body nests it). Older docs hint at a
            // top-level `key` — accept either so a future API
            // tweak doesn't re-empty the EPUB.
            let key: String
            if let meta = obj["metadata"] as? [String: Any],
               let metaKey = meta["key"] as? String {
                key = metaKey
            } else if let topKey = obj["key"] as? String {
                key = topKey
            } else {
                continue
            }
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
