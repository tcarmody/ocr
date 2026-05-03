import Foundation
import ZIPFoundation

/// Inverse of `EPUBPackager`: unzips an .epub on disk into a working
/// directory so the editor can browse the file tree, render XHTML in a
/// WebView with relative-path resolution, and (later) repack changes
/// back into the .epub.
public struct EPUBUnpacker {
    public init() {}

    public enum UnpackError: Error, LocalizedError {
        case sourceNotFound
        case openFailed(String)
        case extractFailed(String)

        public var errorDescription: String? {
            switch self {
            case .sourceNotFound:           return "EPUB file not found"
            case .openFailed(let s):        return "Could not open EPUB: \(s)"
            case .extractFailed(let s):     return "Extraction failed: \(s)"
            }
        }
    }

    /// Unpack `epubURL` into a fresh subdirectory of `parentDir`. Returns
    /// the unpacked tree root. Caller owns cleanup; `EPUBPackage` does
    /// this automatically on deinit when used through that wrapper.
    public func unpack(epubURL: URL, into parentDir: URL) throws -> URL {
        guard FileManager.default.fileExists(atPath: epubURL.path) else {
            throw UnpackError.sourceNotFound
        }
        let workingDir = parentDir
            .appendingPathComponent(
                "Humanist-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: workingDir, withIntermediateDirectories: true
        )

        let archive: Archive
        do {
            archive = try Archive(url: epubURL, accessMode: .read)
        } catch {
            throw UnpackError.openFailed(String(describing: error))
        }

        for entry in archive {
            // Skip directory entries; we'll create dirs as needed below.
            guard entry.type == .file else { continue }
            let destURL = workingDir.appendingPathComponent(entry.path)
            // Defend against zip-slip: refuse paths that escape workingDir.
            let normalized = destURL.standardized
            guard normalized.path.hasPrefix(workingDir.standardized.path) else {
                continue
            }
            try FileManager.default.createDirectory(
                at: destURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            do {
                _ = try archive.extract(entry, to: destURL, skipCRC32: true)
            } catch {
                throw UnpackError.extractFailed("\(entry.path): \(error)")
            }
        }
        return workingDir
    }
}
