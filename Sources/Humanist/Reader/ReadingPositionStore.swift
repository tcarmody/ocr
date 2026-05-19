import Foundation
import EPUB

/// R-Reader. Persists "where the user left off" per book, keyed by
/// the EPUB's SHA-256 content hash so positions survive file
/// moves and multi-machine syncs. Stored in Application Support
/// at `Humanist/ReadingPositions/<hash>.json`.
///
/// v1 scope: spine index only. Scroll-within-chapter persistence
/// is documented in the schema (`scrollFraction`) but always
/// written as 0 — the JS bridge to capture WKWebView scroll on a
/// debounce lands in a follow-up commit. Reopening still lands
/// the user at the chapter they were reading, which is the
/// dominant win.
public struct ReadingPosition: Codable, Equatable, Sendable {
    /// EPUB content hash. The store keys files by this so two
    /// copies of the same book (different file paths) share a
    /// position.
    public let contentHash: String
    /// Zero-based spine index — drives `ReaderViewModel.jump(toSpineIndex:)`
    /// on restore.
    public var spineIndex: Int
    /// Scroll-within-chapter offset, normalized 0.0–1.0.
    /// Schema-forward — always 0 in v1; the future scroll-
    /// capture bridge will write meaningful values without
    /// changing the file shape.
    public var scrollFraction: Double
    /// Last touched. The library window's "Continue reading" hover
    /// affordance (R-Reader-Library-Continue follow-up) consumes
    /// this to sort recent reads.
    public var updatedAt: Date

    public init(
        contentHash: String,
        spineIndex: Int,
        scrollFraction: Double = 0,
        updatedAt: Date = Date()
    ) {
        self.contentHash = contentHash
        self.spineIndex = spineIndex
        self.scrollFraction = scrollFraction
        self.updatedAt = updatedAt
    }
}

/// Reads and writes `ReadingPosition` records to disk. Operates
/// on a dedicated subdirectory of Application Support so the
/// store survives Library purges and works for ad-hoc EPUBs the
/// user never imported.
public enum ReadingPositionStore {

    /// Compute the on-disk URL for `contentHash`. Creates the
    /// parent directory lazily on first call so callers don't
    /// have to. Returns nil only when Application Support is
    /// itself unreachable (catastrophic — never seen in
    /// practice).
    public static func fileURL(forContentHash contentHash: String) -> URL? {
        guard let dir = ensureDirectory() else { return nil }
        return dir
            .appendingPathComponent(contentHash)
            .appendingPathExtension("json")
    }

    /// Load a position for `contentHash`, or nil when no record
    /// exists / decode fails. Decode failure logs once via NSLog
    /// + treats as a cache miss so a corrupt sidecar can't break
    /// reader open.
    public static func load(forContentHash contentHash: String) -> ReadingPosition? {
        guard let url = fileURL(forContentHash: contentHash) else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(ReadingPosition.self, from: data)
        } catch {
            NSLog(
                "Humanist: ReadingPositionStore decode failed for %@: %@",
                contentHash, error.localizedDescription
            )
            return nil
        }
    }

    /// Write a position record. Atomic — the encoder writes to a
    /// temp file and renames, so a process kill mid-write can't
    /// corrupt the sidecar. Failures log via NSLog without
    /// surfacing to the user (worst case: position is lost for
    /// this session; reading still works).
    public static func save(_ position: ReadingPosition) {
        guard let url = fileURL(forContentHash: position.contentHash) else {
            return
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(position)
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog(
                "Humanist: ReadingPositionStore save failed for %@: %@",
                position.contentHash, error.localizedDescription
            )
        }
    }

    /// Resolve the `Application Support/Humanist/ReadingPositions`
    /// directory and create it (with parents) on first call.
    /// Returns nil if Application Support is unreachable.
    private static func ensureDirectory() -> URL? {
        let fm = FileManager.default
        guard let appSupport = try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        let dir = appSupport
            .appendingPathComponent("Humanist", isDirectory: true)
            .appendingPathComponent("ReadingPositions", isDirectory: true)
        try? fm.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        return dir
    }
}
