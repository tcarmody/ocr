import Foundation
import os

private let streamLog = Logger(
    subsystem: "com.tcarmody.Humanist",
    category: "AnthropicStream"
)

/// One event yielded from a streaming `messages` request. The SSE
/// stream emits more event types than these, but the chat path
/// only needs incremental text + an end-of-stream signal.
public enum AnthropicStreamEvent: Sendable, Equatable {
    /// Incremental text from a `content_block_delta` event of type
    /// `text_delta`. The chat caller appends these to the draft
    /// assistant message as they arrive.
    case textDelta(String)
    /// `message_stop` event. Stream completes after this; the
    /// `AsyncThrowingStream` then finishes with no error.
    case messageStop
}

extension AnthropicAPIClient {
    /// Streaming counterpart to `send(_:)`. Returns an
    /// `AsyncThrowingStream` of `AnthropicStreamEvent` values
    /// produced by parsing the Server-Sent Events response from
    /// `POST /v1/messages` with `stream: true`. The stream sets
    /// the `stream` flag on the outgoing request automatically;
    /// callers don't need to.
    ///
    /// Cancellation propagates: cancelling the consuming Task
    /// terminates the underlying URLSession task and finishes
    /// the stream. Errors map to `AnthropicAPIError` the same
    /// way the synchronous path does.
    public nonisolated func sendStream(
        _ request: AnthropicMessageRequest
    ) -> AsyncThrowingStream<AnthropicStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await self.runStream(request, continuation: continuation)
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private func runStream(
        _ request: AnthropicMessageRequest,
        continuation: AsyncThrowingStream<AnthropicStreamEvent, Error>.Continuation
    ) async {
        guard let key = apiKeyProvider(), !key.isEmpty else {
            continuation.finish(throwing: AnthropicAPIError.missingAPIKey)
            return
        }
        var streamReq = request
        streamReq.stream = true

        let urlRequest: URLRequest
        do {
            urlRequest = try buildStreamURLRequest(for: streamReq, apiKey: key)
        } catch let error as AnthropicAPIError {
            continuation.finish(throwing: error)
            return
        } catch {
            continuation.finish(throwing: AnthropicAPIError.invalidRequest(
                message: "request encoding failed: \(error)"
            ))
            return
        }

        streamLog.debug("sending streaming request: \(urlRequest.url?.absoluteString ?? "?")")
        if let body = urlRequest.httpBody,
           let bodyString = String(data: body, encoding: .utf8) {
            streamLog.debug("body: \(bodyString, privacy: .public)")
        }

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await URLSession.shared.bytes(for: urlRequest)
        } catch is CancellationError {
            continuation.finish(throwing: CancellationError())
            return
        } catch {
            continuation.finish(throwing: AnthropicAPIError.network(error))
            return
        }

        guard let http = response as? HTTPURLResponse else {
            continuation.finish(throwing: AnthropicAPIError.decode("non-HTTP response"))
            return
        }
        streamLog.debug("status: \(http.statusCode), content-type: \(http.value(forHTTPHeaderField: "Content-Type") ?? "?", privacy: .public)")
        guard (200..<300).contains(http.statusCode) else {
            // Drain the body for the error message; the SSE parser
            // would otherwise stall waiting for events that never
            // come. Body in error responses is small (JSON envelope).
            var data = Data()
            do {
                for try await byte in bytes {
                    data.append(byte)
                }
            } catch {
                // Ignore — we have what we have, build the error
                // from whatever arrived.
            }
            continuation.finish(throwing: mapStreamError(
                status: http.statusCode, headers: http, body: data
            ))
            return
        }

        // SSE format: blocks of `event: <name>\n` + `data: <json>\n`
        // separated by blank lines. We accumulate per-block and
        // dispatch on the blank-line boundary.
        var currentEvent: String?
        var currentDataLines: [String] = []
        do {
            for try await line in bytes.lines {
                streamLog.debug("line: \(line, privacy: .public)")
                if line.isEmpty {
                    if let event = currentEvent {
                        let payload = currentDataLines.joined(separator: "\n")
                        let stop = handleSSEEvent(
                            event: event,
                            data: payload,
                            continuation: continuation
                        )
                        if stop { return }
                    }
                    currentEvent = nil
                    currentDataLines.removeAll(keepingCapacity: true)
                    continue
                }
                if let trimmed = line.dropPrefix("event: ") {
                    currentEvent = String(trimmed)
                } else if let trimmed = line.dropPrefix("data: ") {
                    currentDataLines.append(String(trimmed))
                }
                // Lines starting with ":" are SSE comments / keep-
                // alives — ignore.
            }
            // Stream ended without a `message_stop` — treat that as
            // a normal completion. Anthropic does send one when the
            // model finishes; if a proxy strips it we still want
            // the consumer to see EOF.
            continuation.finish()
        } catch is CancellationError {
            continuation.finish(throwing: CancellationError())
        } catch {
            continuation.finish(throwing: AnthropicAPIError.network(error))
        }
    }

    /// Parse one SSE event. Returns true when the stream is logically
    /// complete (`message_stop` or `error` event) so the outer
    /// loop can stop reading.
    private func handleSSEEvent(
        event: String,
        data: String,
        continuation: AsyncThrowingStream<AnthropicStreamEvent, Error>.Continuation
    ) -> Bool {
        switch event {
        case "content_block_delta":
            // {"type":"content_block_delta","index":0,
            //  "delta":{"type":"text_delta","text":"Hello"}}
            guard let payload = data.data(using: .utf8),
                  let parsed = try? Self.decoder.decode(
                    SSEContentBlockDelta.self, from: payload
                  )
            else { return false }
            if parsed.delta.type == "text_delta" {
                continuation.yield(.textDelta(parsed.delta.text ?? ""))
            }
            return false
        case "message_stop":
            continuation.yield(.messageStop)
            continuation.finish()
            return true
        case "error":
            // Anthropic's error event payload has the same shape as
            // the synchronous error envelope.
            guard let payload = data.data(using: .utf8),
                  let envelope = try? Self.decoder.decode(
                    AnthropicErrorEnvelope.self, from: payload
                  )
            else {
                continuation.finish(throwing: AnthropicAPIError.serverError(
                    status: 0, message: "stream error event with no payload"
                ))
                return true
            }
            continuation.finish(throwing: AnthropicAPIError.serverError(
                status: 0, message: envelope.error.message
            ))
            return true
        default:
            // Other events (message_start, content_block_start /
            // _stop, message_delta, ping) don't drive the chat UI.
            return false
        }
    }

    private struct SSEContentBlockDelta: Decodable {
        let delta: Delta
        struct Delta: Decodable {
            let type: String
            let text: String?
        }
    }

    /// Streaming requests need the `Accept: text/event-stream`
    /// header on top of the regular Messages-API auth headers.
    /// Built separately from `buildURLRequest` because the call
    /// site is in the streaming extension and the original is
    /// `private` to the actor.
    private func buildStreamURLRequest(
        for request: AnthropicMessageRequest, apiKey: String
    ) throws -> URLRequest {
        var url = config.baseURL
        url.append(path: "v1/messages")
        var ur = URLRequest(url: url, timeoutInterval: config.requestTimeout)
        ur.httpMethod = "POST"
        ur.addValue("application/json", forHTTPHeaderField: "Content-Type")
        ur.addValue("text/event-stream", forHTTPHeaderField: "Accept")
        ur.addValue(apiKey, forHTTPHeaderField: "x-api-key")
        ur.addValue(config.apiVersion, forHTTPHeaderField: "anthropic-version")
        if !config.betaHeaders.isEmpty {
            ur.addValue(
                config.betaHeaders.joined(separator: ","),
                forHTTPHeaderField: "anthropic-beta"
            )
        }
        ur.httpBody = try Self.encoder.encode(request)
        return ur
    }

    private func mapStreamError(
        status: Int, headers: HTTPURLResponse, body: Data
    ) -> AnthropicAPIError {
        let envelope = try? Self.decoder.decode(AnthropicErrorEnvelope.self, from: body)
        let message = envelope?.error.message
            ?? String(data: body, encoding: .utf8)
            ?? ""
        switch status {
        case 400: return .invalidRequest(message: message)
        case 401: return .authenticationFailed
        case 403: return .permissionDenied(message: message)
        case 404: return .notFound(message: message)
        case 413: return .requestTooLarge
        case 429:
            let retryAfter = headers.value(forHTTPHeaderField: "retry-after")
                .flatMap(TimeInterval.init)
            return .rateLimited(retryAfter: retryAfter)
        case 529: return .overloaded
        default:
            return .serverError(status: status, message: message.isEmpty ? nil : message)
        }
    }
}

private extension String {
    /// Returns the substring after `prefix` when the string begins
    /// with it, else nil. Saves the per-line `hasPrefix` /
    /// `dropFirst` round-trip in the SSE parser.
    func dropPrefix(_ prefix: String) -> Substring? {
        guard hasPrefix(prefix) else { return nil }
        return self.dropFirst(prefix.count)
    }
}
