import Foundation
import CryptoKit
import EPUB

/// Persists chat transcripts under
/// `~/Library/Application Support/Humanist/Chats/<key>.json`,
/// keyed by the canonical path of the EPUB the chat belongs to.
///
/// We deliberately store outside the EPUB:
///
/// * The transcript shouldn't be coupled to the editor's
///   save flow — the user expects "the chat I was just having"
///   to still be there even if they close without saving.
/// * Storing inside the .epub would conflate chat state with
///   document state for diffs / version control.
///
/// Tradeoff: moving the .epub file to a different path orphans
/// its transcript. Acceptable for v1; a follow-up can index by
/// the OPF unique-identifier metadata to follow renames.
struct ChatTranscriptStore {
    private let baseDirectory: URL

    init(baseDirectory: URL? = nil) {
        if let baseDirectory {
            self.baseDirectory = baseDirectory
        } else {
            let support = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first ?? FileManager.default.temporaryDirectory
            self.baseDirectory = support
                .appendingPathComponent("Humanist", isDirectory: true)
                .appendingPathComponent("Chats", isDirectory: true)
        }
    }

    /// Read the transcript for `epubURL`. Returns an empty array
    /// when no transcript exists for that key (first-open case)
    /// or when the on-disk file is unreadable.
    func read(for epubURL: URL) -> [BookChatMessage] {
        let url = fileURL(for: epubURL)
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let payload = try? Self.decoder.decode(Payload.self, from: data)
        else { return [] }
        return payload.messages.sorted { $0.createdAt < $1.createdAt }
    }

    /// Write the transcript for `epubURL`. Creates the storage
    /// directory if needed; failures are silent (chat persistence
    /// is best-effort — losing it shouldn't break the editor).
    func write(_ messages: [BookChatMessage], for epubURL: URL) {
        let url = fileURL(for: epubURL)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let payload = Payload(version: 1, messages: messages)
        guard let data = try? Self.encoder.encode(payload) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Drop the transcript for `epubURL`. Used by the chat pane's
    /// "Clear" button so the next open starts fresh.
    func clear(for epubURL: URL) {
        let url = fileURL(for: epubURL)
        try? FileManager.default.removeItem(at: url)
    }

    private func fileURL(for epubURL: URL) -> URL {
        let canonical = epubURL.canonicalForFile.standardizedFileURL.path
        let digest = SHA256.hash(data: Data(canonical.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return baseDirectory.appendingPathComponent("\(hex).json")
    }

    /// Wrapper struct so the on-disk format can grow without
    /// breaking older readers (e.g. add settings, summary, etc.).
    /// `version` lets a future format tweak negotiate decode
    /// behavior; today every persisted file is version 1.
    private struct Payload: Codable {
        let version: Int
        let messages: [BookChatMessage]
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
