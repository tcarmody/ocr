import XCTest
@testable import AI

/// Pin the JSON shape we decode from `/v1/messages` responses.
/// Sample bodies match the documented Anthropic API output.
final class AnthropicMessageResponseTests: XCTestCase {

    private func decode(_ json: String) throws -> AnthropicMessageResponse {
        try AnthropicAPIClient.decoder.decode(
            AnthropicMessageResponse.self,
            from: json.data(using: .utf8)!
        )
    }

    func test_basic_text_response_decodes() throws {
        let body = #"""
        {
          "id": "msg_01ABCDxyz",
          "type": "message",
          "role": "assistant",
          "model": "claude-haiku-4-5-20251001",
          "content": [
            {"type": "text", "text": "Hello, world."}
          ],
          "stop_reason": "end_turn",
          "stop_sequence": null,
          "usage": {
            "input_tokens": 12,
            "output_tokens": 5
          }
        }
        """#
        let r = try decode(body)
        XCTAssertEqual(r.id, "msg_01ABCDxyz")
        XCTAssertEqual(r.role, "assistant")
        XCTAssertEqual(r.model, "claude-haiku-4-5-20251001")
        XCTAssertEqual(r.content.count, 1)
        if case let .text(s) = r.content[0] { XCTAssertEqual(s, "Hello, world.") }
        else { XCTFail("Expected text block") }
        XCTAssertEqual(r.stopReason, .endTurn)
        XCTAssertNil(r.stopSequence)
        XCTAssertEqual(r.usage.inputTokens, 12)
        XCTAssertEqual(r.usage.outputTokens, 5)
        XCTAssertEqual(r.usage.cacheCreationInputTokens, 0)
        XCTAssertEqual(r.usage.cacheReadInputTokens, 0)
    }

    func test_usage_with_cache_fields_decodes() throws {
        let body = #"""
        {
          "id": "msg_x",
          "type": "message",
          "role": "assistant",
          "model": "claude-sonnet-4-6",
          "content": [{"type":"text","text":"ok"}],
          "stop_reason": "end_turn",
          "usage": {
            "input_tokens": 10,
            "output_tokens": 3,
            "cache_creation_input_tokens": 1024,
            "cache_read_input_tokens": 2048
          }
        }
        """#
        let r = try decode(body)
        XCTAssertEqual(r.usage.cacheCreationInputTokens, 1024)
        XCTAssertEqual(r.usage.cacheReadInputTokens, 2048)
        XCTAssertEqual(r.usage.totalInputTokens, 10 + 1024 + 2048)
    }

    func test_unknown_block_type_decodes_as_unknown_variant() throws {
        // Future API additions should fall through to `.unknown`
        // rather than break decoding. `tool_use` used to live here
        // and now has its own case (see `test_tool_use_block_…`);
        // pick a placeholder type the layer doesn't model yet.
        let body = #"""
        {
          "id": "msg_x",
          "type": "message",
          "role": "assistant",
          "model": "claude-sonnet-4-6",
          "content": [
            {"type": "text", "text": "hello"},
            {"type": "future_block_kind", "data": "whatever"}
          ],
          "stop_reason": "end_turn",
          "usage": {"input_tokens": 1, "output_tokens": 1}
        }
        """#
        let r = try decode(body)
        XCTAssertEqual(r.content.count, 2)
        if case .text = r.content[0] {} else { XCTFail("expected text") }
        if case .unknown(let type) = r.content[1] {
            XCTAssertEqual(type, "future_block_kind")
        } else {
            XCTFail("expected unknown")
        }
    }

    func test_stop_reason_max_tokens_marks_truncation() throws {
        let body = #"""
        {
          "id": "msg_x",
          "type": "message",
          "role": "assistant",
          "model": "claude-haiku-4-5",
          "content": [{"type":"text","text":"truncated…"}],
          "stop_reason": "max_tokens",
          "usage": {"input_tokens": 1, "output_tokens": 256}
        }
        """#
        let r = try decode(body)
        XCTAssertEqual(r.stopReason, .maxTokens)
        XCTAssertTrue(r.didTruncate)
        XCTAssertFalse(r.didRefuse)
    }

    func test_stop_reason_refusal_marks_refusal() throws {
        let body = #"""
        {
          "id": "msg_x",
          "type": "message",
          "role": "assistant",
          "model": "claude-haiku-4-5",
          "content": [{"type":"text","text":"I can't help with that."}],
          "stop_reason": "refusal",
          "usage": {"input_tokens": 1, "output_tokens": 10}
        }
        """#
        let r = try decode(body)
        XCTAssertTrue(r.didRefuse)
    }

    func test_primary_text_returns_first_text_block() throws {
        let body = #"""
        {
          "id":"x","type":"message","role":"assistant","model":"claude-haiku-4-5",
          "content":[
            {"type":"text","text":"First."},
            {"type":"text","text":"Second."}
          ],
          "stop_reason":"end_turn",
          "usage":{"input_tokens":1,"output_tokens":1}
        }
        """#
        let r = try decode(body)
        XCTAssertEqual(r.primaryText, "First.Second.")
    }

    func test_tool_use_block_decodes_with_id_name_and_raw_input_json() throws {
        // Anthropic tool-use response shape: `id` is opaque, `input`
        // is a nested JSON object matching the advertised tool
        // schema. ResponseBlock re-serializes `input` to opaque
        // bytes so the chat-VM dispatcher can decode it against
        // its own argument struct without this layer modeling any
        // schema.
        let body = #"""
        {
          "id":"msg_y","type":"message","role":"assistant","model":"claude-haiku-4-5",
          "content":[
            {"type":"tool_use","id":"toolu_42","name":"search_library",
             "input":{"query":"mirror stage","top_k":12}}
          ],
          "stop_reason":"tool_use",
          "usage":{"input_tokens":120,"output_tokens":35}
        }
        """#
        let r = try decode(body)
        XCTAssertEqual(r.stopReason, .toolUse)
        guard case .toolUse(let id, let name, let inputJSON)
                = r.content.first else {
            XCTFail("expected tool_use block, got \(r.content)")
            return
        }
        XCTAssertEqual(id, "toolu_42")
        XCTAssertEqual(name, "search_library")
        let obj = try JSONSerialization.jsonObject(with: inputJSON) as? [String: Any]
        XCTAssertEqual(obj?["query"] as? String, "mirror stage")
        XCTAssertEqual(obj?["top_k"] as? Int, 12)
    }
}
