import Foundation
import CoreGraphics

/// `LayoutAnalyzer` impl backed by the shared Surya Python sidecar.
/// Thin wrapper around `SuryaConnection.layout(...)`.
public struct SuryaLayoutAnalyzer: LayoutAnalyzer {
    public let connection: SuryaConnection

    /// Convenience: build a layout analyzer from auto-detected
    /// connection. Returns nil if Surya/sidecar isn't available.
    public static func detect() -> SuryaLayoutAnalyzer? {
        SuryaConnection.detect().map(SuryaLayoutAnalyzer.init)
    }

    public init(connection: SuryaConnection) {
        self.connection = connection
    }

    public func analyze(imageURL: URL, pageBounds: CGSize) async throws -> [LayoutRegion] {
        try await connection.layout(imageURL: imageURL, pageBounds: pageBounds)
    }
}
