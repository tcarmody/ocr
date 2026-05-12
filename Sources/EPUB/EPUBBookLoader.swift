import Foundation

/// Loads an unpacked EPUB working directory into an in-memory
/// `EPUBBook`. Reuses `OPFReader` for the package metadata, then
/// pulls every manifest text resource into RAM and references binary
/// resources by their on-disk URL.
public struct EPUBBookLoader {

    public init() {}

    public enum LoadError: Error, LocalizedError {
        case opfRead(Error)
        case missingFile(String)
        case decodingFailed(href: String, underlying: Error)

        public var errorDescription: String? {
            switch self {
            case .opfRead(let e):
                return "Couldn't read OPF: \(e)"
            case .missingFile(let href):
                return "Manifest references missing file: \(href)"
            case .decodingFailed(let href, let e):
                return "Couldn't decode \(href) as UTF-8: \(e)"
            }
        }
    }

    /// Load a Book from the working directory of an already-unpacked
    /// EPUB. Mirrors `EPUBPackage.open(epubURL:)` but produces the
    /// in-memory model instead of the disk-backed package.
    public func load(
        sourceURL: URL,
        workingDirectory: URL
    ) throws -> EPUBBook {
        let canonicalWorkingDir = workingDirectory.canonicalForFile
        let opfPackage: OPFReader.Package
        do {
            opfPackage = try OPFReader().read(rootDir: canonicalWorkingDir)
        } catch {
            throw LoadError.opfRead(error)
        }

        let opfURL = canonicalWorkingDir
            .appendingPathComponent(opfPackage.opfPathRelativeToRoot)
        let opfDirectory = opfURL.deletingLastPathComponent()
        let originalOPFText: String
        do {
            originalOPFText = try String(contentsOf: opfURL, encoding: .utf8)
        } catch {
            throw LoadError.opfRead(error)
        }

        // Build resources in manifest order. We can't recover the
        // original manifest order from `OPFReader.Package` because
        // its `manifestById` is a dictionary — we re-walk the OPF
        // here to get a stable order. Use the spine and the
        // dictionary together: spine items first (in spine order),
        // then everything else sorted by id for determinism.
        //
        // PR 2 will replace this with an order-preserving OPF parse.
        // For now this gives a stable, reproducible iteration order
        // that's good enough for round-tripping.
        let manifestIDs = orderedManifestIDs(package: opfPackage)
        var resources: [String: Resource] = [:]
        var resourceOrder: [String] = []

        for id in manifestIDs {
            guard let item = opfPackage.manifestById[id] else { continue }
            // Percent-decode the href before resolving to disk —
            // OPF stores URI references, but the filesystem has
            // the decoded forms. See `EPUBBook.appendingHref(_:to:)`
            // for the rationale (Walter Benjamin EPUB import
            // tripped on `text/Table%20of%20Contents.xhtml`
            // 2026-05-12).
            let absoluteURL = EPUBBook.appendingHref(
                item.href, to: opfDirectory
            )
            let resource = try buildResource(from: item, at: absoluteURL)
            resources[id] = resource
            resourceOrder.append(id)
        }

        let book = EPUBBook(
            sourceURL: sourceURL.canonicalForFile,
            workingDirectory: canonicalWorkingDir,
            opfPathRelativeToRoot: opfPackage.opfPathRelativeToRoot,
            originalOPFText: originalOPFText,
            metadata: opfPackage.metadata,
            resourceOrder: resourceOrder,
            resourcesByID: resources,
            spine: opfPackage.spine
        )
        return book
    }

    // MARK: - Helpers

    /// Spine ids first, then any non-spine manifest ids sorted
    /// alphabetically. Stable enough to give round-trip determinism
    /// for tests; we'll replace with true OPF order once we have an
    /// order-preserving parser.
    private func orderedManifestIDs(package: OPFReader.Package) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for id in package.spine where package.manifestById[id] != nil {
            if seen.insert(id).inserted { out.append(id) }
        }
        let nonSpine = package.manifestById.keys
            .filter { !seen.contains($0) }
            .sorted()
        out.append(contentsOf: nonSpine)
        return out
    }

    private func buildResource(
        from item: OPFReader.ManifestItem,
        at absoluteURL: URL
    ) throws -> Resource {
        let isText = Self.isTextMediaType(item.mediaType)
        let content: Resource.Content
        if isText {
            guard FileManager.default.fileExists(atPath: absoluteURL.path) else {
                throw LoadError.missingFile(item.href)
            }
            do {
                let text = try String(contentsOf: absoluteURL, encoding: .utf8)
                content = .text(text)
            } catch {
                throw LoadError.decodingFailed(href: item.href, underlying: error)
            }
        } else {
            // Binary. We don't load content; we keep a disk URL.
            // We *don't* require the file to exist here — some EPUBs
            // declare items in the manifest that aren't yet on disk
            // (e.g. cover.jpg planned but not generated). The save
            // path will skip writes for non-existent binaries.
            content = .binary(diskURL: absoluteURL)
        }
        return Resource(
            id: item.id,
            hrefRelativeToOPF: item.href,
            mediaType: item.mediaType,
            properties: item.properties,
            content: content,
            isDirty: false
        )
    }

    /// Decide whether a manifest item should be loaded into memory as
    /// text. Conservatively text: anything obvious; everything else
    /// stays binary.
    static func isTextMediaType(_ mediaType: String) -> Bool {
        let lower = mediaType.lowercased()
        if lower.hasPrefix("text/") { return true }
        switch lower {
        case "application/xhtml+xml",
             "application/xml",
             "application/x-dtbncx+xml",
             "application/javascript",
             "application/json",
             "application/oebps-package+xml",
             "image/svg+xml":
            // SVG counts as text — small, often hand-edited, fits
            // the "load into RAM, edit in-place" model.
            return true
        default:
            return false
        }
    }
}
