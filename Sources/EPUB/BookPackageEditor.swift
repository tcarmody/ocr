import Foundation

/// In-memory analog of `PackageEditor`: same chapter-level operations
/// (split, merge, regenerate nav) but mutates an `EPUBBook` rather
/// than the on-disk working tree. Disk writes happen later, in one
/// shot, when the editor calls `EPUBBookSaver.save(_:)`.
///
/// The win over `PackageEditor` is failure semantics. Mid-operation
/// throws here mutate at most a couple of in-memory references —
/// nothing has been written to disk, so the user can retry from a
/// clean state. With the disk-mutating editor, a partial failure
/// leaves the working tree inconsistent and required the multi-fix
/// cleanup that landed in `8d6d535`.
///
/// Inputs are resource ids (the manifest @id), not URLs. The editor
/// layer is still URL-keyed today — `EPUBBook.resource(at:)` does
/// the URL → id translation at the call site.
public struct BookPackageEditor {

    public let book: EPUBBook

    public init(book: EPUBBook) {
        self.book = book
    }

    public enum EditError: Error, LocalizedError {
        case unknownResource(id: String)
        case notInSpine(id: String)
        case alreadyLastInSpine
        case bodyNotFound(resourceID: String)
        case splitOffsetOutOfBounds
        case missingNav
        case binaryResource(id: String)

        public var errorDescription: String? {
            switch self {
            case .unknownResource(let id):
                return "No manifest item with id=\(id)"
            case .notInSpine(let id):
                return "Resource \(id) isn't in the spine."
            case .alreadyLastInSpine:
                return "This chapter is already the last in the book — nothing to merge with."
            case .bodyNotFound(let id):
                return "Couldn't find <body>…</body> in resource \(id)."
            case .splitOffsetOutOfBounds:
                return "Split position is outside the chapter's body."
            case .missingNav:
                return "Couldn't locate the navigation document (nav.xhtml) in the manifest."
            case .binaryResource(let id):
                return "Resource \(id) is binary; this operation needs text content."
            }
        }
    }

    // MARK: - Split

    /// Split the chapter `resourceID` at `splitOffset` (UTF-16 offset
    /// into the resource's full XHTML text). Snaps forward to the next
    /// safe element-start boundary (mirrors the disk-based editor).
    ///
    /// On success: the original chapter's text shrinks to the head;
    /// a new `Resource` is inserted into the manifest immediately
    /// after the original, spliced into the spine, and contains the
    /// tail. The nav resource is regenerated. Returns the new
    /// resource.
    @discardableResult
    public func splitChapter(
        resourceID: String,
        splitOffset: Int
    ) throws -> Resource {
        guard let original = book.resourcesByID[resourceID] else {
            throw EditError.unknownResource(id: resourceID)
        }
        guard book.spine.contains(resourceID) else {
            throw EditError.notInSpine(id: resourceID)
        }
        guard let originalText = original.text else {
            throw EditError.binaryResource(id: resourceID)
        }
        guard let bodyRange = PackageEditor.bodyRange(in: originalText) else {
            throw EditError.bodyNotFound(resourceID: resourceID)
        }

        let bodyStart = originalText.distance(
            from: originalText.startIndex, to: bodyRange.lowerBound
        )
        let bodyEnd = originalText.distance(
            from: originalText.startIndex, to: bodyRange.upperBound
        )
        let clamped = max(bodyStart, min(splitOffset, bodyEnd))
        let safeOffset = PackageEditor.snapToSafeBoundary(
            in: originalText, near: clamped, bodyEnd: bodyEnd
        )
        guard safeOffset > bodyStart, safeOffset < bodyEnd else {
            throw EditError.splitOffsetOutOfBounds
        }

        let safeIndex = originalText.index(
            originalText.startIndex, offsetBy: safeOffset
        )
        let firstBody = String(originalText[bodyRange.lowerBound..<safeIndex])
        let secondBody = String(originalText[safeIndex..<bodyRange.upperBound])
        let head = String(originalText[..<bodyRange.lowerBound])
        let foot = String(originalText[bodyRange.upperBound...])
        let firstFile = head + firstBody + foot
        let secondFile = head + secondBody + foot

        let newID = book.nextAvailableResourceID(prefix: "chapter")
        let newHref = book.nextAvailableHref(near: original.hrefRelativeToOPF)
        let newResource = Resource(
            id: newID,
            hrefRelativeToOPF: newHref,
            mediaType: original.mediaType,
            properties: nil,
            content: .text(secondFile),
            isDirty: true
        )

        original.text = firstFile  // marks dirty
        try book.appendResource(newResource)
        book.insertInSpine(id: newID, after: resourceID)

        try regenerateNav()
        return newResource
    }

    // MARK: - Merge

    /// Merge the chapter at `resourceID` with the next chapter in the
    /// spine. The next chapter's body is appended to this one's body
    /// (in memory), the next chapter is removed from the manifest +
    /// spine + queued for deletion at save time, and the nav is
    /// regenerated.
    public func mergeWithNextChapter(at resourceID: String) throws {
        guard let current = book.resourcesByID[resourceID] else {
            throw EditError.unknownResource(id: resourceID)
        }
        guard book.spine.contains(resourceID) else {
            throw EditError.notInSpine(id: resourceID)
        }
        guard let nextID = book.nextSpineResourceID(after: resourceID) else {
            throw EditError.alreadyLastInSpine
        }
        guard let next = book.resourcesByID[nextID] else {
            throw EditError.unknownResource(id: nextID)
        }
        guard let currentText = current.text else {
            throw EditError.binaryResource(id: resourceID)
        }
        guard let nextText = next.text else {
            throw EditError.binaryResource(id: nextID)
        }
        guard let currentBody = PackageEditor.bodyRange(in: currentText) else {
            throw EditError.bodyNotFound(resourceID: resourceID)
        }
        guard let nextBody = PackageEditor.bodyRange(in: nextText) else {
            throw EditError.bodyNotFound(resourceID: nextID)
        }

        let head = String(currentText[..<currentBody.lowerBound])
        let foot = String(currentText[currentBody.upperBound...])
        let merged = head
            + currentText[currentBody.lowerBound..<currentBody.upperBound]
            + "\n"
            + nextText[nextBody.lowerBound..<nextBody.upperBound]
            + foot

        current.text = merged  // marks dirty
        book.removeResource(id: nextID)
        try regenerateNav()
    }

    // MARK: - Nav regeneration

    /// Rebuild the nav resource's text from the current spine.
    /// Pulls each spine chapter's first heading from in-memory text;
    /// chapters without a heading get "Chapter N".
    public func regenerateNav() throws {
        guard let nav = book.navResource else {
            throw EditError.missingNav
        }
        let navAbsoluteURL = book.absoluteURL(for: nav)

        var entries: [String] = []
        for (i, itemID) in book.spine.enumerated() {
            guard let resource = book.resourcesByID[itemID] else { continue }
            // Prefer in-memory text; if a binary somehow ended up in
            // the spine (shouldn't happen for XHTML), skip.
            let heading: String? = resource.text.flatMap {
                PackageEditor.firstHeadingTitle(in: $0)
            }
            let title = heading ?? "Chapter \(i + 1)"
            let chapterAbsoluteURL = book.absoluteURL(for: resource)
            let relHref = relativePath(
                from: navAbsoluteURL, to: chapterAbsoluteURL
            )
            entries.append(
                "<li><a href=\"\(XMLEscape.attribute(relHref))\">\(XMLEscape.text(title))</a></li>"
            )
        }

        let language = XMLEscape.attribute(book.metadata.language ?? "en")
        let docTitle = XMLEscape.text(book.metadata.title ?? "Contents")
        let xhtml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="\(language)" lang="\(language)">
        <head>
        <meta charset="utf-8"/>
        <title>\(docTitle)</title>
        </head>
        <body>
        <nav epub:type="toc" id="toc">
        <h1>\(docTitle)</h1>
        <ol>
        \(entries.joined(separator: "\n"))
        </ol>
        </nav>
        </body>
        </html>
        """
        nav.text = xhtml  // marks dirty
    }

    // MARK: - Helpers

    /// Compute a path from `fromFile` (a file URL) to `toFile`,
    /// suitable for use as an `href` in a containing element. Mirrors
    /// `PackageEditor.relativePath`. Same-directory case is the only
    /// one our packaging convention produces, so we keep it simple.
    private func relativePath(from fromFile: URL, to toFile: URL) -> String {
        let fromDir = fromFile.deletingLastPathComponent()
            .canonicalForFile.standardizedFileURL.path
        let toPath = toFile.canonicalForFile.standardizedFileURL.path
        if toPath.hasPrefix(fromDir + "/") {
            return String(toPath.dropFirst(fromDir.count + 1))
        }
        return toFile.lastPathComponent
    }
}
