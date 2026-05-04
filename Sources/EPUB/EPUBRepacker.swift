import Foundation

/// Inverse of `EPUBUnpacker`: walk a working directory and re-zip it
/// into a valid EPUB. Used by the editor's Save action after edits
/// have been flushed to disk.
///
/// All the EPUB-format fiddliness (mimetype first, mimetype
/// uncompressed, exact bytes) lives in `EPUBPackager.validate`; this
/// type's job is to produce the entry list in the right order.
public struct EPUBRepacker {
    public init() {}

    public enum RepackError: Error, LocalizedError {
        case missingMimetype
        case mimetypeContentMismatch
        case readFailed(String)

        public var errorDescription: String? {
            switch self {
            case .missingMimetype:        return "EPUB working directory has no `mimetype` file"
            case .mimetypeContentMismatch: return "`mimetype` does not contain `application/epub+zip`"
            case .readFailed(let s):      return "Read failed: \(s)"
            }
        }
    }

    /// Pack everything under `workingDirectory` into an EPUB at
    /// `outputURL`. Overwrites any existing file at the destination.
    public func repack(workingDirectory: URL, to outputURL: URL) throws {
        let mimetypeURL = workingDirectory.appendingPathComponent("mimetype")
        guard FileManager.default.fileExists(atPath: mimetypeURL.path) else {
            throw RepackError.missingMimetype
        }
        let mimeData: Data
        do {
            mimeData = try Data(contentsOf: mimetypeURL)
        } catch {
            throw RepackError.readFailed("mimetype: \(error)")
        }
        guard String(data: mimeData, encoding: .utf8) == EPUBStaticFiles.mimetype else {
            throw RepackError.mimetypeContentMismatch
        }

        var entries: [EPUBPackager.Entry] = []
        // mimetype MUST be first and stored uncompressed.
        entries.append(EPUBPackager.Entry(
            path: "mimetype", data: mimeData, compressed: false
        ))

        let allFiles = try Self.walkFiles(workingDirectory)
        for fileURL in allFiles {
            let relPath = Self.relativePath(of: fileURL, from: workingDirectory)
            // Skip mimetype — already added first.
            if relPath == "mimetype" { continue }
            // Skip macOS metadata accidentally created in the working dir.
            if relPath.hasPrefix(".") || relPath.contains("/.DS_Store") { continue }
            let data: Data
            do {
                data = try Data(contentsOf: fileURL)
            } catch {
                throw RepackError.readFailed("\(relPath): \(error)")
            }
            entries.append(EPUBPackager.Entry(
                path: relPath, data: data, compressed: true
            ))
        }

        try EPUBPackager().write(entries, to: outputURL)
    }

    // MARK: - helpers

    /// Recursive enumeration of every regular file under `root`.
    /// Sorted alphabetically so repacked archives are reproducible.
    static func walkFiles(_ root: URL) throws -> [URL] {
        var out: [URL] = []
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: Set(keys))
            if values.isRegularFile == true {
                out.append(url)
            }
        }
        return out.sorted { $0.path < $1.path }
    }

    /// Compute the slash-separated path of `fileURL` relative to `root`.
    /// Canonicalizes both sides — on macOS the temp dir is
    /// `/var/folders/...` (a symlink) while `enumerator(at:)` yields
    /// URLs through `/private/var/folders/...`, so a naive prefix
    /// check fails and the file ends up at the archive root.
    static func relativePath(of fileURL: URL, from root: URL) -> String {
        let f = fileURL.canonicalForFile.path
        let r = root.canonicalForFile.path
        guard f.hasPrefix(r) else { return fileURL.lastPathComponent }
        var rel = String(f.dropFirst(r.count))
        if rel.hasPrefix("/") { rel.removeFirst() }
        return rel
    }
}
