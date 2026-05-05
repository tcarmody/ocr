import Foundation

/// One request to the Messages API. Pure data — no transport
/// coupling — so it round-trips through `JSONEncoder` for either
/// `POST /v1/messages` (synchronous, today) or as one entry inside
/// a future `POST /v1/messages/batches` body.
///
/// Ordered as it appears on the wire: `model`, `max_tokens`,
/// `system`, `messages`, then optional behavior controls. Field
/// names map to the API's snake_case via custom `CodingKeys`; Swift
/// property names stay camelCase.
public struct AnthropicMessageRequest: Sendable, Encodable, Equatable {
    public var model: AnthropicModel
    public var maxTokens: Int
    public var system: SystemPrompt?
    public var messages: [Message]
    public var thinking: ThinkingConfig?
    public var stopSequences: [String]?
    public var cacheControl: CacheControl?
    public var outputConfig: OutputConfig?

    public init(
        model: AnthropicModel,
        maxTokens: Int,
        system: SystemPrompt? = nil,
        messages: [Message],
        thinking: ThinkingConfig? = nil,
        stopSequences: [String]? = nil,
        cacheControl: CacheControl? = nil,
        outputConfig: OutputConfig? = nil
    ) {
        self.model = model
        self.maxTokens = maxTokens
        self.system = system
        self.messages = messages
        self.thinking = thinking
        self.stopSequences = stopSequences
        self.cacheControl = cacheControl
        self.outputConfig = outputConfig
    }

    private enum CodingKeys: String, CodingKey {
        case model
        case maxTokens = "max_tokens"
        case system
        case messages
        case thinking
        case stopSequences = "stop_sequences"
        case cacheControl = "cache_control"
        case outputConfig = "output_config"
    }
}

// MARK: - System prompt

/// The system prompt is `string | [TextBlock]` on the wire. The
/// block form is required when attaching `cache_control` to the
/// system prompt — the cheapest, highest-leverage cache breakpoint
/// for our planned features (same instruction reused across every
/// region of a book).
public enum SystemPrompt: Sendable, Equatable {
    case plain(String)
    case blocks([TextBlock])

    /// Convenience constructor for the most common case: one big
    /// system prompt the caller wants cached across requests.
    /// Defaults to omitting the `ttl` field, which yields the
    /// API's default 5-minute ephemeral TTL. Pass `.oneHour` for
    /// bursty workloads spanning >5 minutes.
    public static func cached(_ text: String, ttl: CacheControl.TTL? = nil) -> SystemPrompt {
        .blocks([TextBlock(text: text, cacheControl: CacheControl(type: .ephemeral, ttl: ttl))])
    }
}

extension SystemPrompt: Encodable {
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .plain(let s):     try container.encode(s)
        case .blocks(let bs):   try container.encode(bs)
        }
    }
}

// MARK: - Messages

public struct Message: Sendable, Encodable, Equatable {
    public var role: Role
    public var content: MessageContent

    public init(role: Role, content: MessageContent) {
        self.role = role
        self.content = content
    }

    public enum Role: String, Sendable, Encodable, Equatable {
        case user
        case assistant
    }
}

/// User and assistant content can be a plain string or an array of
/// typed blocks. The block form is required for multimodal inputs
/// (image + text) and for placing per-block `cache_control`.
public enum MessageContent: Sendable, Equatable {
    case plain(String)
    case blocks([ContentBlock])
}

extension MessageContent: Encodable {
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .plain(let s):     try container.encode(s)
        case .blocks(let bs):   try container.encode(bs)
        }
    }
}

// MARK: - Content blocks

/// One block inside a `Message.content` array. Phase 1 covers
/// `text` and `image` — the two block kinds every planned feature
/// needs. Tool-use / tool-result blocks are intentionally absent
/// because none of our planned features use Claude's tool API.
public enum ContentBlock: Sendable, Equatable {
    /// Plain text, optionally tagged with a cache breakpoint.
    case text(String, cacheControl: CacheControl? = nil)
    /// Base64-encoded image, optionally tagged with a cache breakpoint
    /// (rare in our pipeline — the image bytes themselves vary per
    /// page, so the cache hit comes from the system prompt above).
    case image(mediaType: ImageMediaType, base64Data: String, cacheControl: CacheControl? = nil)
}

extension ContentBlock: Encodable {
    private enum BlockKey: String, CodingKey {
        case type, text, source, cacheControl = "cache_control"
    }
    private enum SourceKey: String, CodingKey {
        case type, mediaType = "media_type", data
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: BlockKey.self)
        switch self {
        case .text(let s, let cache):
            try c.encode("text", forKey: .type)
            try c.encode(s, forKey: .text)
            if let cache { try c.encode(cache, forKey: .cacheControl) }
        case .image(let media, let data, let cache):
            try c.encode("image", forKey: .type)
            var src = c.nestedContainer(keyedBy: SourceKey.self, forKey: .source)
            try src.encode("base64", forKey: .type)
            try src.encode(media.rawValue, forKey: .mediaType)
            try src.encode(data, forKey: .data)
            if let cache { try c.encode(cache, forKey: .cacheControl) }
        }
    }
}

public enum ImageMediaType: String, Sendable, Equatable {
    case png  = "image/png"
    case jpeg = "image/jpeg"
    case webp = "image/webp"
    case gif  = "image/gif"
}

public struct TextBlock: Sendable, Encodable, Equatable {
    public var text: String
    public var cacheControl: CacheControl?

    public init(text: String, cacheControl: CacheControl? = nil) {
        self.text = text
        self.cacheControl = cacheControl
    }

    private enum CodingKeys: String, CodingKey {
        case type, text, cacheControl = "cache_control"
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode("text", forKey: .type)
        try c.encode(text, forKey: .text)
        if let cacheControl { try c.encode(cacheControl, forKey: .cacheControl) }
    }
}

// MARK: - Cache control

/// `cache_control: {type: "ephemeral", ttl?: "5m"|"1h"}` on a content
/// block, or top-level on the request body (auto-places on the last
/// cacheable block). 5-minute default; 1-hour for bursty workloads
/// that span ≥ 5 minutes between requests.
///
/// Caching is a prefix match — any byte change anywhere in the
/// prefix invalidates everything after it. Render order is
/// `tools` → `system` → `messages`, so a marker on the last system
/// block caches both tools (when present) and the system prompt.
public struct CacheControl: Sendable, Encodable, Equatable {
    public var type: ControlType
    public var ttl: TTL?

    public init(type: ControlType = .ephemeral, ttl: TTL? = nil) {
        self.type = type
        self.ttl = ttl
    }

    public enum ControlType: String, Sendable, Encodable, Equatable {
        case ephemeral
    }

    public enum TTL: String, Sendable, Encodable, Equatable {
        case fiveMinutes = "5m"
        case oneHour     = "1h"
    }

    /// Default 5-minute ephemeral breakpoint.
    public static let ephemeral = CacheControl(type: .ephemeral, ttl: nil)

    /// 1-hour ephemeral breakpoint. Useful when the same cached prefix
    /// will be hit across requests that may span >5 minutes (bulk runs).
    public static let ephemeralOneHour = CacheControl(type: .ephemeral, ttl: .oneHour)
}

// MARK: - Thinking control

/// Adaptive thinking is the recommended mode on Sonnet 4.6 and Haiku
/// 4.5; for our read-only tasks (OCR, table extraction, classification,
/// TOC parsing) we explicitly disable thinking — none of them benefit
/// from chain-of-thought, and disabling saves tokens + latency.
public struct ThinkingConfig: Sendable, Encodable, Equatable {
    public var type: Mode

    public enum Mode: String, Sendable, Encodable, Equatable {
        case disabled
        case adaptive
    }

    public static let disabled = ThinkingConfig(type: .disabled)
    public static let adaptive = ThinkingConfig(type: .adaptive)
}

// MARK: - Output config (structured outputs + effort)

/// Constrains the response shape and / or reasoning depth. Currently
/// supports `format: json_schema` for structured outputs (used by
/// future table extraction and classification features) and `effort`
/// for thinking-on workloads. Both fields are optional.
public struct OutputConfig: Sendable, Encodable, Equatable {
    public var format: Format?
    public var effort: Effort?

    public init(format: Format? = nil, effort: Effort? = nil) {
        self.format = format
        self.effort = effort
    }

    public enum Effort: String, Sendable, Encodable, Equatable {
        case low, medium, high, max
    }

    /// `{"type": "json_schema", "schema": {...}}`. The schema is
    /// stored as raw JSON bytes so the request type stays free of
    /// any schema-modeling baggage; callers pre-encode the schema
    /// they want and pass it through.
    public struct Format: Sendable, Encodable, Equatable {
        public var schemaJSON: Data

        public init(schemaJSON: Data) {
            self.schemaJSON = schemaJSON
        }

        private enum CodingKeys: String, CodingKey {
            case type, schema
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode("json_schema", forKey: .type)
            // Decode the caller's pre-built schema bytes once and
            // re-encode through the parent container so we don't
            // double-quote the JSON. Failing to decode is a caller
            // bug — surface as an encoding error.
            let parsed = try JSONSerialization.jsonObject(
                with: schemaJSON, options: [.allowFragments]
            )
            let bridge = AnyJSON(parsed)
            try c.encode(bridge, forKey: .schema)
        }
    }
}

// MARK: - Internal: AnyJSON bridge for raw schema payloads

/// Walks an arbitrary `JSONSerialization` object tree and re-encodes
/// it through `Encoder`. Used only for the schema-payload pass-through
/// inside `OutputConfig.Format`. Not part of the public surface.
struct AnyJSON: Encodable {
    let value: Any

    init(_ value: Any) { self.value = value }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case is NSNull:
            try container.encodeNil()
        case let b as Bool:
            try container.encode(b)
        case let n as NSNumber:
            // Distinguish bool / int / double via NSNumber's objCType.
            // Bool covered above; integer types come through with "q"
            // / "i" / etc.; floating with "d" / "f".
            switch String(cString: n.objCType) {
            case "f", "d":  try container.encode(n.doubleValue)
            default:        try container.encode(n.int64Value)
            }
        case let s as String:
            try container.encode(s)
        case let arr as [Any]:
            try container.encode(arr.map(AnyJSON.init))
        case let dict as [String: Any]:
            try container.encode(dict.mapValues(AnyJSON.init))
        default:
            throw EncodingError.invalidValue(value, EncodingError.Context(
                codingPath: encoder.codingPath,
                debugDescription: "Unsupported JSON value: \(type(of: value))"
            ))
        }
    }
}
