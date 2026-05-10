import Foundation
import FoundationModels

/// Thin wrapper over Apple's `FoundationModels` framework. Provides a
/// uniform availability check and a single schema-guided
/// `respond(instructions:prompt:)` entry point that the on-device
/// classifier engines call.
///
/// Each `respond` call constructs a fresh `LanguageModelSession`
/// rather than reusing a long-lived one — sessions accumulate
/// transcript context, which is helpful for chat but actively
/// counterproductive for classification (each chapter should be
/// scored against the same fixed instructions, not against the
/// previous chapter's classification turn). The classifier engines
/// call this client per-chapter; one fresh session per call keeps
/// the context window predictable.
///
/// Availability + graceful fallback are the caller's responsibility:
/// inspect `availability` before instantiating the client, and
/// route to a no-op (or Cloud) path when unavailable. The wrapper
/// itself doesn't try to gate calls — if you call `respond` while
/// unavailable, the underlying framework throws and the error
/// propagates.
public struct AppleFoundationModelClient: Sendable {
    public enum Availability: Sendable, Equatable {
        case available
        /// Includes the user-facing reason string from the
        /// framework. Surfaces in Settings when Apple Intelligence
        /// is disabled, the device doesn't support it, etc.
        case unavailable(reason: String)
    }

    public static var availability: Availability {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(let reason):
            return .unavailable(reason: String(describing: reason))
        }
    }

    public init() {}

    /// Schema-guided respond. The output type's `@Generable` macro
    /// supplies the JSON-schema constraint that pins the on-device
    /// model's output to a parseable shape. Caller is responsible
    /// for validating the parsed result if it needs additional
    /// post-conditions (e.g. checking against a closed label set).
    ///
    /// `instructions` is the system prompt — analogous to the
    /// cached Anthropic `system` field; held for the session's
    /// lifetime, which is one call here.
    public func respond<Output: Generable>(
        instructions: String,
        prompt: String,
        generating: Output.Type = Output.self
    ) async throws -> Output {
        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(
            to: prompt,
            generating: Output.self
        )
        return response.content
    }
}
