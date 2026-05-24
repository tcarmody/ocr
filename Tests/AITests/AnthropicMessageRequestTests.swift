import XCTest
@testable import AI

/// Pin the JSON wire shape of `AnthropicMessageRequest`. Caching
/// depends on byte-stable serialization (any byte change in the
/// prefix invalidates the cache), so these tests double as a
/// regression check against accidental key-order or field-rename
/// drift.
final class AnthropicMessageRequestTests: XCTestCase {

    private func encode(_ request: AnthropicMessageRequest) throws -> [String: Any] {
        let data = try AnthropicAPIClient.encoder.encode(request)
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    // MARK: - Basics

    func test_minimal_request_uses_snake_case_field_names() throws {
        let r = AnthropicMessageRequest(
            model: .haiku4_5,
            maxTokens: 256,
            messages: [Message(role: .user, content: .plain("Hi"))]
        )
        let json = try encode(r)
        XCTAssertEqual(json["model"] as? String, "claude-haiku-4-5")
        XCTAssertEqual(json["max_tokens"] as? Int, 256)
        let messages = json["messages"] as? [[String: Any]]
        XCTAssertEqual(messages?.count, 1)
        XCTAssertEqual(messages?[0]["role"] as? String, "user")
        XCTAssertEqual(messages?[0]["content"] as? String, "Hi")
    }

    func test_optional_fields_are_omitted_when_nil() throws {
        let r = AnthropicMessageRequest(
            model: .haiku4_5,
            maxTokens: 256,
            messages: [Message(role: .user, content: .plain("Hi"))]
        )
        let json = try encode(r)
        XCTAssertNil(json["system"])
        XCTAssertNil(json["thinking"])
        XCTAssertNil(json["stop_sequences"])
        XCTAssertNil(json["cache_control"])
        XCTAssertNil(json["output_config"])
    }

    // MARK: - System prompt

    func test_plain_system_prompt_encodes_as_string() throws {
        let r = AnthropicMessageRequest(
            model: .haiku4_5,
            maxTokens: 256,
            system: .plain("You are a helpful assistant."),
            messages: [Message(role: .user, content: .plain("Hi"))]
        )
        let json = try encode(r)
        XCTAssertEqual(json["system"] as? String, "You are a helpful assistant.")
    }

    func test_cached_system_prompt_encodes_as_blocks_with_cache_control() throws {
        let r = AnthropicMessageRequest(
            model: .haiku4_5,
            maxTokens: 256,
            system: .cached("Stable instruction across many regions of a book."),
            messages: [Message(role: .user, content: .plain("Hi"))]
        )
        let json = try encode(r)
        let blocks = json["system"] as? [[String: Any]]
        XCTAssertEqual(blocks?.count, 1)
        XCTAssertEqual(blocks?[0]["type"] as? String, "text")
        XCTAssertEqual(blocks?[0]["text"] as? String,
                       "Stable instruction across many regions of a book.")
        let cache = blocks?[0]["cache_control"] as? [String: Any]
        XCTAssertEqual(cache?["type"] as? String, "ephemeral")
        // Default TTL (5m) renders as the absence of the ttl field —
        // Anthropic's default for `ephemeral`.
        XCTAssertNil(cache?["ttl"])
    }

    func test_cached_system_prompt_with_one_hour_ttl_encodes_field() throws {
        let r = AnthropicMessageRequest(
            model: .haiku4_5,
            maxTokens: 256,
            system: .cached("Long-running corpus prompt.", ttl: .oneHour),
            messages: [Message(role: .user, content: .plain("Hi"))]
        )
        let json = try encode(r)
        let blocks = json["system"] as? [[String: Any]]
        let cache = blocks?[0]["cache_control"] as? [String: Any]
        XCTAssertEqual(cache?["ttl"] as? String, "1h")
    }

    // MARK: - Multimodal content

    func test_image_content_block_uses_base64_source() throws {
        let pngBytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        let base64 = Data(pngBytes).base64EncodedString()
        let r = AnthropicMessageRequest(
            model: .sonnet4_6,
            maxTokens: 1024,
            messages: [Message(role: .user, content: .blocks([
                .image(mediaType: .png, base64Data: base64),
                .text("What does this image say?"),
            ]))]
        )
        let json = try encode(r)
        let messages = json["messages"] as? [[String: Any]]
        let content = messages?[0]["content"] as? [[String: Any]]
        XCTAssertEqual(content?.count, 2)
        XCTAssertEqual(content?[0]["type"] as? String, "image")
        let source = content?[0]["source"] as? [String: Any]
        XCTAssertEqual(source?["type"] as? String, "base64")
        XCTAssertEqual(source?["media_type"] as? String, "image/png")
        XCTAssertEqual(source?["data"] as? String, base64)
        XCTAssertEqual(content?[1]["type"] as? String, "text")
        XCTAssertEqual(content?[1]["text"] as? String, "What does this image say?")
    }

    // MARK: - Top-level cache control

    func test_top_level_cache_control_renders_as_object() throws {
        let r = AnthropicMessageRequest(
            model: .haiku4_5,
            maxTokens: 256,
            messages: [Message(role: .user, content: .plain("Hi"))],
            cacheControl: .ephemeral
        )
        let json = try encode(r)
        let cache = json["cache_control"] as? [String: Any]
        XCTAssertEqual(cache?["type"] as? String, "ephemeral")
    }

    // MARK: - Thinking

    func test_thinking_disabled_renders_correctly() throws {
        let r = AnthropicMessageRequest(
            model: .haiku4_5,
            maxTokens: 256,
            messages: [Message(role: .user, content: .plain("Hi"))],
            thinking: .disabled
        )
        let json = try encode(r)
        let thinking = json["thinking"] as? [String: Any]
        XCTAssertEqual(thinking?["type"] as? String, "disabled")
    }

    func test_thinking_adaptive_renders_correctly() throws {
        let r = AnthropicMessageRequest(
            model: .sonnet4_6,
            maxTokens: 1024,
            messages: [Message(role: .user, content: .plain("Hi"))],
            thinking: .adaptive
        )
        let json = try encode(r)
        let thinking = json["thinking"] as? [String: Any]
        XCTAssertEqual(thinking?["type"] as? String, "adaptive")
    }

    // MARK: - Output config

    func test_output_config_with_json_schema_passes_through_payload() throws {
        let schemaJSON = #"""
        {"type":"object","properties":{"label":{"type":"string"}},"required":["label"]}
        """#.data(using: .utf8)!
        let r = AnthropicMessageRequest(
            model: .haiku4_5,
            maxTokens: 256,
            messages: [Message(role: .user, content: .plain("Classify this."))],
            outputConfig: OutputConfig(format: .init(schemaJSON: schemaJSON))
        )
        let json = try encode(r)
        let out = json["output_config"] as? [String: Any]
        let format = out?["format"] as? [String: Any]
        XCTAssertEqual(format?["type"] as? String, "json_schema")
        let schema = format?["schema"] as? [String: Any]
        XCTAssertEqual(schema?["type"] as? String, "object")
        let props = schema?["properties"] as? [String: Any]
        let labelProp = props?["label"] as? [String: Any]
        XCTAssertEqual(labelProp?["type"] as? String, "string")
        let required = schema?["required"] as? [String]
        XCTAssertEqual(required, ["label"])
    }

    // MARK: - Tools

    func test_tool_encodes_with_nested_input_schema_object() throws {
        let schema = Data("""
        {
          "type": "object",
          "properties": {
            "query": { "type": "string", "description": "Search query" },
            "top_k": { "type": "integer" }
          },
          "required": ["query"]
        }
        """.utf8)
        let tool = Tool(
            name: "search_library",
            description: "Search the user's library.",
            inputSchema: schema
        )
        let r = AnthropicMessageRequest(
            model: .haiku4_5,
            maxTokens: 256,
            messages: [Message(role: .user, content: .plain("Hi"))],
            tools: [tool]
        )
        let json = try encode(r)
        let tools = json["tools"] as? [[String: Any]]
        XCTAssertEqual(tools?.count, 1)
        XCTAssertEqual(tools?[0]["name"] as? String, "search_library")
        XCTAssertEqual(tools?[0]["description"] as? String,
                       "Search the user's library.")
        let inputSchema = tools?[0]["input_schema"] as? [String: Any]
        XCTAssertEqual(inputSchema?["type"] as? String, "object")
        let props = inputSchema?["properties"] as? [String: Any]
        let queryProp = props?["query"] as? [String: Any]
        XCTAssertEqual(queryProp?["type"] as? String, "string")
        let required = inputSchema?["required"] as? [String]
        XCTAssertEqual(required, ["query"])
    }

    func test_tool_result_block_serializes_with_snake_case_tool_use_id() throws {
        let r = AnthropicMessageRequest(
            model: .haiku4_5,
            maxTokens: 256,
            messages: [Message(role: .user, content: .blocks([
                .toolResult(toolUseID: "toolu_abc", content: "[book:0] Foo")
            ]))]
        )
        let json = try encode(r)
        let messages = json["messages"] as? [[String: Any]]
        let blocks = messages?[0]["content"] as? [[String: Any]]
        XCTAssertEqual(blocks?[0]["type"] as? String, "tool_result")
        XCTAssertEqual(blocks?[0]["tool_use_id"] as? String, "toolu_abc")
        XCTAssertEqual(blocks?[0]["content"] as? String, "[book:0] Foo")
        // `is_error: false` is omitted to keep the wire payload small
        // and match what Anthropic's docs show.
        XCTAssertNil(blocks?[0]["is_error"])
    }

    func test_tool_result_block_with_error_flag_emits_is_error_true() throws {
        let r = AnthropicMessageRequest(
            model: .haiku4_5,
            maxTokens: 256,
            messages: [Message(role: .user, content: .blocks([
                .toolResult(
                    toolUseID: "toolu_abc",
                    content: "Search failed: API rate limit",
                    isError: true
                )
            ]))]
        )
        let json = try encode(r)
        let messages = json["messages"] as? [[String: Any]]
        let blocks = messages?[0]["content"] as? [[String: Any]]
        XCTAssertEqual(blocks?[0]["is_error"] as? Bool, true)
    }

    // MARK: - Byte stability (cache hygiene)

    func test_two_identical_requests_produce_byte_identical_JSON() throws {
        // Cache hits depend on byte-stable serialization. This guards
        // against future Codable customizations accidentally
        // introducing key-order drift.
        let make: () -> AnthropicMessageRequest = {
            AnthropicMessageRequest(
                model: .sonnet4_6,
                maxTokens: 1024,
                system: .cached("Stable instruction"),
                messages: [Message(role: .user, content: .blocks([
                    .text("First"),
                    .text("Second"),
                ]))],
                thinking: .disabled,
                stopSequences: ["END"]
            )
        }
        let a = try AnthropicAPIClient.encoder.encode(make())
        let b = try AnthropicAPIClient.encoder.encode(make())
        XCTAssertEqual(a, b, "Identical requests must serialize to identical bytes")
    }
}
