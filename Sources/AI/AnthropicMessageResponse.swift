import Foundation

/// One response from the Messages API. Same shape whether it came
/// back from `POST /v1/messages` synchronously or as one entry inside
/// a future batch result stream — that's why this type lives next to
/// the request type and stays free of transport coupling.
public struct AnthropicMessageResponse: Sendable, Decodable, Equatable {
    /// `msg_…` identifier — useful for log correlation when reporting
    /// problems to Anthropic.
    public var id: String
    /// Always `"message"` today; reserved for future expansion.
    public var type: String
    /// Always `"assistant"` for Messages API responses.
    public var role: String
    /// Echoes back the model that served the request — including any
    /// snapshot resolution from an alias.
    public var model: String
    /// One or more output blocks. For Phase 1's read-only workloads
    /// we only ever expect `text` blocks; future tool-use features
    /// would surface `tool_use` blocks here.
    public var content: [ResponseBlock]
    /// Why generation stopped — see `StopReason`.
    public var stopReason: StopReason?
    /// The stop sequence that triggered `stop_reason == .stopSequence`,
    /// if any.
    public var stopSequence: String?
    /// Token usage breakdown. The four `*_tokens` fields together
    /// describe the full prompt cost: `input_tokens` is uncached,
    /// `cache_creation_input_tokens` paid the write premium,
    /// `cache_read_input_tokens` was served at ~0.1× the read price.
    public var usage: Usage

    private enum CodingKeys: String, CodingKey {
        case id, type, role, model, content
        case stopReason   = "stop_reason"
        case stopSequence = "stop_sequence"
        case usage
    }
}

// MARK: - Response blocks

/// One output block. Phase 1 surfaces text only — that's all our
/// planned features need. Unknown block types decode to `.unknown`
/// so a future API addition (a new block kind we don't yet model)
/// won't break decoding for callers that don't care about it.
public enum ResponseBlock: Sendable, Decodable, Equatable {
    case text(String)
    case unknown(type: String)

    private enum CodingKeys: String, CodingKey {
        case type, text
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .type)
        switch kind {
        case "text":
            let text = try c.decode(String.self, forKey: .text)
            self = .text(text)
        default:
            self = .unknown(type: kind)
        }
    }
}

// MARK: - Stop reasons

/// Why the model stopped generating. The synchronous client surfaces
/// every value to the caller — a guardrail layer (Phase 2+) needs
/// to distinguish "Claude finished cleanly" from "the output was
/// truncated" from "Claude refused".
public enum StopReason: String, Sendable, Decodable, Equatable {
    /// Normal completion.
    case endTurn = "end_turn"
    /// Hit the `max_tokens` ceiling — output is truncated. Caller
    /// should treat the response as incomplete.
    case maxTokens = "max_tokens"
    /// Custom stop sequence matched.
    case stopSequence = "stop_sequence"
    /// Claude wants to call a tool. Phase 1 features don't use tools,
    /// so this would indicate a misconfigured request.
    case toolUse = "tool_use"
    /// Server-tool sampling loop reached its iteration cap. Resume by
    /// re-sending the assistant turn unchanged. Phase 1 features
    /// don't use server tools.
    case pauseTurn = "pause_turn"
    /// Claude refused for safety reasons. The output may not match
    /// the requested schema and the caller should NOT retry the
    /// same prompt.
    case refusal
    /// Input exceeded the model's context window. Caller should chunk
    /// or summarize the input before retrying.
    case contextWindowExceeded = "model_context_window_exceeded"
}

// MARK: - Usage

/// Token-usage breakdown returned with every response. Used by the
/// per-book cost cap and surfaced in the editor's AI trail
/// inspector (future).
public struct Usage: Sendable, Decodable, Equatable {
    /// Tokens billed at full input price (uncached portion of the prompt).
    public var inputTokens: Int
    /// Tokens generated for the response.
    public var outputTokens: Int
    /// Tokens written to cache this request — billed at ~1.25× input
    /// for 5-minute TTL, ~2× for 1-hour. Zero if no cache breakpoint
    /// was set or the prefix was below the cacheable minimum.
    public var cacheCreationInputTokens: Int
    /// Tokens served from cache this request — billed at ~0.1× input.
    /// If this is zero across repeated requests with what should be
    /// an identical prefix, a silent invalidator (timestamp,
    /// non-deterministic JSON serialization, varying tool list) is
    /// at work.
    public var cacheReadInputTokens: Int

    public init(
        inputTokens: Int,
        outputTokens: Int,
        cacheCreationInputTokens: Int = 0,
        cacheReadInputTokens: Int = 0
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationInputTokens = cacheCreationInputTokens
        self.cacheReadInputTokens = cacheReadInputTokens
    }

    private enum CodingKeys: String, CodingKey {
        case inputTokens              = "input_tokens"
        case outputTokens             = "output_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
        case cacheReadInputTokens     = "cache_read_input_tokens"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.inputTokens              = try c.decode(Int.self, forKey: .inputTokens)
        self.outputTokens             = try c.decode(Int.self, forKey: .outputTokens)
        self.cacheCreationInputTokens = try c.decodeIfPresent(Int.self, forKey: .cacheCreationInputTokens) ?? 0
        self.cacheReadInputTokens     = try c.decodeIfPresent(Int.self, forKey: .cacheReadInputTokens) ?? 0
    }

    /// Total tokens in the prompt across all three categories. Useful
    /// for cost tracking — multiply this against the model's input
    /// rate (less the cache-read discount) to compute spend.
    public var totalInputTokens: Int {
        inputTokens + cacheCreationInputTokens + cacheReadInputTokens
    }

    /// Convenience for callers logging a one-line usage summary.
    public var summary: String {
        "in=\(inputTokens) out=\(outputTokens) cacheW=\(cacheCreationInputTokens) cacheR=\(cacheReadInputTokens)"
    }
}

// MARK: - Convenience accessors on the response

public extension AnthropicMessageResponse {
    /// First text block, joined-text fallback when there are
    /// multiple. Returns nil when the response carried no text
    /// (e.g. only tool-use blocks — not expected in Phase 1).
    var primaryText: String? {
        let texts = content.compactMap { block -> String? in
            if case .text(let s) = block { return s }
            return nil
        }
        guard !texts.isEmpty else { return nil }
        return texts.joined()
    }

    /// True when generation hit `max_tokens` and the output is
    /// therefore truncated. Callers using the response as
    /// ground-truth should treat this as a soft failure.
    var didTruncate: Bool { stopReason == .maxTokens }

    /// True when Claude refused for safety reasons. The body may not
    /// match a requested schema; callers should not retry the same
    /// prompt.
    var didRefuse: Bool { stopReason == .refusal }
}

// MARK: - Wire error envelope

/// Error responses come back as `{"type":"error","error":{"type":"...","message":"..."}}`.
/// Decoded by `AnthropicAPIClient` and mapped into `AnthropicAPIError`
/// based on the HTTP status; this struct is the intermediate shape.
struct AnthropicErrorEnvelope: Decodable {
    let type: String
    let error: ErrorBody
    let requestID: String?

    struct ErrorBody: Decodable {
        let type: String
        let message: String
    }

    private enum CodingKeys: String, CodingKey {
        case type, error
        case requestID = "request_id"
    }
}
