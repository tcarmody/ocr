import Foundation
import ZIPFoundation

/// Packages a set of in-memory EPUB files into a valid EPUB 3 ZIP.
///
/// EPUB packaging has one ZIP-level rule that is easy to get wrong:
///
///   * The **first** entry MUST be named `mimetype`, stored uncompressed
///     (compression method 0), with the literal bytes "application/epub+zip"
///     and no trailing newline. Some readers (Apple Books, calibre) will
///     reject the file outright if this isn't right.
///
/// Everything else can be deflated normally. This file gets the rule right
/// in one place so the rest of the EPUB code can stay declarative.
public struct EPUBPackager {
    public init() {}

    /// One file to write into the EPUB ZIP.
    public struct Entry: Sendable {
        public var path: String   // ZIP-relative path, forward slashes
        public var data: Data
        public var compressed: Bool

        public init(path: String, data: Data, compressed: Bool = true) {
            self.path = path
            self.data = data
            self.compressed = compressed
        }
    }

    public enum PackagingError: Error, LocalizedError, Equatable {
        case firstEntryMustBeMimetype
        case mimetypeMustBeUncompressed
        case mimetypeContentMismatch
        case archiveCreationFailed
        case writeFailed(String)

        public var errorDescription: String? {
            switch self {
            case .firstEntryMustBeMimetype:    return "First entry must be 'mimetype'"
            case .mimetypeMustBeUncompressed:  return "'mimetype' must be stored uncompressed"
            case .mimetypeContentMismatch:     return "'mimetype' must contain exactly 'application/epub+zip'"
            case .archiveCreationFailed:       return "Could not create EPUB archive"
            case .writeFailed(let s):          return "Write failed: \(s)"
            }
        }
    }

    /// Validate then write entries to `outputURL` as a valid EPUB ZIP.
    /// Overwrites any existing file at `outputURL`. Creates the
    /// parent directory if needed — `Archive(create:)` fails when
    /// the parent doesn't exist, and the configured-output-folder
    /// feature routes writes into per-format subdirs (`Books/`)
    /// that may not exist yet.
    public func write(_ entries: [Entry], to outputURL: URL) throws {
        try Self.validate(entries: entries)

        // mkdir -p the destination folder. `Archive(create:)` returns
        // a non-specific error when the parent is missing; surface
        // the directory-creation failure as `writeFailed` instead so
        // the user sees the actual permission / path issue.
        let parent = outputURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parent.path) {
            do {
                try FileManager.default.createDirectory(
                    at: parent, withIntermediateDirectories: true
                )
            } catch {
                throw PackagingError.writeFailed(
                    "createDirectory(\(parent.path)): \(error)"
                )
            }
        }

        // Remove any existing file so Archive(create:) starts clean.
        try? FileManager.default.removeItem(at: outputURL)

        let archive: Archive
        do {
            archive = try Archive(url: outputURL, accessMode: .create)
        } catch {
            throw PackagingError.archiveCreationFailed
        }

        for entry in entries {
            let method: CompressionMethod = entry.compressed ? .deflate : .none
            let data = entry.data
            do {
                try archive.addEntry(
                    with: entry.path,
                    type: .file,
                    uncompressedSize: Int64(data.count),
                    compressionMethod: method,
                    provider: { position, size in
                        let start = Int(position)
                        let end = start + Int(size)
                        return data.subdata(in: start..<end)
                    }
                )
            } catch {
                throw PackagingError.writeFailed("addEntry(\(entry.path)): \(error)")
            }
        }
    }

    /// Pre-flight checks for the EPUB packaging rules. Exposed so tests
    /// (and future builders) can verify before touching the filesystem.
    public static func validate(entries: [Entry]) throws {
        guard let first = entries.first, first.path == "mimetype" else {
            throw PackagingError.firstEntryMustBeMimetype
        }
        guard first.compressed == false else {
            throw PackagingError.mimetypeMustBeUncompressed
        }
        guard String(data: first.data, encoding: .utf8) == EPUBStaticFiles.mimetype else {
            throw PackagingError.mimetypeContentMismatch
        }
    }
}
