import Foundation
import CryptoKit

/// Editor-only sidecar capturing a fingerprint of each page's body
/// at conversion (or last bulk-refresh) time. Used by V-Refresh v2
/// to distinguish "page hasn't been edited since the last automated
/// pass" from "user manually edited this page" — the former is
/// eligible for overwrite during bulk Re-OCR; the latter is preserved.
///
/// Sits alongside `PageMap`: page-map tracks where each PDF page
/// landed, page-snapshots tracks whether that landing zone has been
/// touched by the user. Standard EPUB readers ignore unknown
/// META-INF files, so the sidecar round-trips through other tools
/// cleanly.
public struct PageSnapshots: Sendable, Equatable, Codable {
    /// Anchor id → SHA-256 of the page body text (the slice between
    /// this anchor and the next `hu-page-N`, or to `</body>`).
    public var fingerprintByAnchor: [String: String]

    public init(fingerprintByAnchor: [String: String] = [:]) {
        self.fingerprintByAnchor = fingerprintByAnchor
    }

    /// Path of the sidecar inside an unpacked EPUB working directory.
    public static let pathInsideEPUB = "META-INF/com.humanist.page-snapshots.json"

    /// Read snapshots from a working directory. Returns nil for
    /// books that pre-date the sidecar (legacy / non-Humanist
    /// EPUBs); callers treat absent as "no protection — overwrite
    /// freely on bulk Re-OCR".
    public static func read(workingDirectory: URL) -> PageSnapshots? {
        let url = workingDirectory.appendingPathComponent(pathInsideEPUB)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PageSnapshots.self, from: data)
    }

    /// Write snapshots to a working directory. Caller is responsible
    /// for ensuring the META-INF directory exists.
    public func write(workingDirectory: URL) throws {
        let url = workingDirectory.appendingPathComponent(Self.pathInsideEPUB)
        let parent = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parent.path) {
            try FileManager.default.createDirectory(
                at: parent, withIntermediateDirectories: true
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: url)
    }

    /// Compute the canonical fingerprint for a page body. SHA-256 of
    /// the trimmed text — leading / trailing whitespace doesn't
    /// count as a user edit.
    public static func fingerprint(of bodyText: String) -> String {
        let trimmed = bodyText.trimmingCharacters(in: .whitespacesAndNewlines)
        let digest = SHA256.hash(data: Data(trimmed.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
