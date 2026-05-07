import Foundation

/// In-place editor for an unpacked EPUB working directory. Handles
/// chapter-level operations the converter doesn't (split, merge,
/// regenerate nav) by manipulating the on-disk OPF + nav + chapter
/// files directly.
///
/// All operations work on the **working directory** the editor
/// already has — they don't repack the .epub. The caller (typically
/// `EditorViewModel`) is responsible for flushing dirty in-memory
/// buffers to disk before invoking, and for reloading the package
/// + file tree after the operation completes.
///
/// Failure surface is intentionally noisy. We'd rather throw a clear
/// error and leave the working tree consistent than half-modify state
/// and produce a broken EPUB on next save.
public struct PackageEditor {
    /// Root of the unpacked EPUB (parent of META-INF + OEBPS or
    /// equivalent).
    public let workingDirectory: URL
    /// Currently-parsed package, used to locate the OPF + nav files.
    public let package: OPFReader.Package

    public init(workingDirectory: URL, package: OPFReader.Package) {
        self.workingDirectory = workingDirectory
        self.package = package
    }

    public enum EditError: Error, LocalizedError {
        case chapterNotInSpine(URL)
        case alreadyLastInSpine
        case splitOffsetOutOfBounds
        case bodyNotFound(URL)
        case missingNav
        case malformedXML(String)

        public var errorDescription: String? {
            switch self {
            case .chapterNotInSpine(let u):
                return "Chapter \(u.lastPathComponent) isn't in the EPUB's spine."
            case .alreadyLastInSpine:
                return "This chapter is already the last in the book — nothing to merge with."
            case .splitOffsetOutOfBounds:
                return "Split position is outside the chapter's body."
            case .bodyNotFound(let u):
                return "Couldn't find <body>…</body> in \(u.lastPathComponent)."
            case .missingNav:
                return "Couldn't locate the navigation document (nav.xhtml) in the manifest."
            case .malformedXML(let msg):
                return "Malformed XML while editing the package: \(msg)"
            }
        }
    }

    // MARK: - URL helpers

    /// Absolute URL of the OPF file from the parsed package.
    public var opfURL: URL {
        workingDirectory.appendingPathComponent(package.opfPathRelativeToRoot)
    }

    /// Directory the OPF lives in — chapter hrefs are relative to it.
    public var opfDirectory: URL {
        opfURL.deletingLastPathComponent()
    }

    /// Resolve a manifest href (relative to the OPF) to an absolute URL.
    public func absoluteURL(forManifestHref href: String) -> URL {
        opfDirectory.appendingPathComponent(href)
    }

    /// Manifest item id for a spine slot whose file URL matches
    /// `chapterURL`. Nil when the URL isn't a spine entry.
    public func spineItemID(for chapterURL: URL) -> String? {
        let target = chapterURL.canonicalForFile
        for itemID in package.spine {
            guard let item = package.manifestById[itemID] else { continue }
            let candidate = absoluteURL(forManifestHref: item.href).canonicalForFile
            if candidate.path == target.path { return itemID }
        }
        return nil
    }

    /// Find the manifest item flagged as the EPUB nav document.
    /// Returns nil if no item has `properties="nav"` (rare; would
    /// indicate a non-EPUB-3 document or a stripped-down package).
    public func navItem() -> OPFReader.ManifestItem? {
        package.manifestById.values.first { ($0.properties ?? "").contains("nav") }
    }

    // MARK: - Chapter Split

    /// Split the chapter at `chapterURL` at `splitOffset` (a UTF-16
    /// offset into the file's full XHTML text). The caller usually
    /// derives `splitOffset` from the source pane's cursor position.
    ///
    /// The split point snaps **forward** to the next boundary that
    /// isn't inside an element (i.e. a position immediately after
    /// `>`), so we don't break tags in half. If no such boundary
    /// exists between the cursor and `</body>`, throws
    /// `splitOffsetOutOfBounds`.
    ///
    /// On success, writes a new chapter file (auto-numbered) into
    /// the same directory as `chapterURL`, updates the OPF spine +
    /// manifest, and regenerates the nav. Returns the new file's URL.
    @discardableResult
    public func splitChapter(
        at chapterURL: URL,
        splitOffset: Int
    ) throws -> URL {
        let originalContent = try String(contentsOf: chapterURL, encoding: .utf8)
        guard let bodyRange = Self.bodyRange(in: originalContent) else {
            throw EditError.bodyNotFound(chapterURL)
        }

        // Clamp / snap split offset.
        let bodyStart = originalContent.distance(
            from: originalContent.startIndex, to: bodyRange.lowerBound
        )
        let bodyEnd = originalContent.distance(
            from: originalContent.startIndex, to: bodyRange.upperBound
        )
        let clamped = max(bodyStart, min(splitOffset, bodyEnd))
        let safeOffset = Self.snapToSafeBoundary(
            in: originalContent, near: clamped, bodyEnd: bodyEnd
        )
        guard safeOffset > bodyStart, safeOffset < bodyEnd else {
            throw EditError.splitOffsetOutOfBounds
        }

        // Slice body into [first half | second half].
        let safeIndex = originalContent.index(
            originalContent.startIndex, offsetBy: safeOffset
        )
        let firstBody = String(originalContent[bodyRange.lowerBound..<safeIndex])
        let secondBody = String(originalContent[safeIndex..<bodyRange.upperBound])

        // Reuse the original head/footer (everything outside <body>…</body>).
        let head = String(originalContent[..<bodyRange.lowerBound])
        let foot = String(originalContent[bodyRange.upperBound...])
        let firstFile = head + firstBody + foot
        let secondFile = head + secondBody + foot

        // Pick a new file name in the same directory, with the same
        // extension as the original.
        let newURL = nextAvailableChapterURL(near: chapterURL)

        // Write new file first; only mutate the original after the
        // new file is on disk so a write failure leaves the source
        // untouched.
        try secondFile.write(to: newURL, atomically: true, encoding: .utf8)
        try firstFile.write(to: chapterURL, atomically: true, encoding: .utf8)

        // Update OPF: insert new chapter into manifest + spine right
        // after the original.
        guard let originalSpineID = spineItemID(for: chapterURL) else {
            // Roll back: delete the new file and restore original content.
            try? FileManager.default.removeItem(at: newURL)
            try? originalContent.write(
                to: chapterURL, atomically: true, encoding: .utf8
            )
            throw EditError.chapterNotInSpine(chapterURL)
        }
        let newID = nextAvailableManifestId(prefix: "chapter")
        let newHref = manifestHref(forAbsolute: newURL)
        try insertManifestItem(
            id: newID,
            href: newHref,
            mediaType: package.manifestById[originalSpineID]?.mediaType
                ?? "application/xhtml+xml",
            afterSpineID: originalSpineID
        )

        try regenerateNav()
        return newURL
    }

    // MARK: - Chapter Merge

    /// Merge `chapterURL` with the next chapter in the spine. The
    /// next chapter's body content is appended to `chapterURL`'s
    /// body, the next chapter's file is deleted from disk and the
    /// manifest, and nav is regenerated.
    ///
    /// Throws `alreadyLastInSpine` when there's no next chapter.
    public func mergeWithNextChapter(at chapterURL: URL) throws {
        guard let currentID = spineItemID(for: chapterURL) else {
            throw EditError.chapterNotInSpine(chapterURL)
        }
        guard let currentSpineIdx = package.spine.firstIndex(of: currentID) else {
            throw EditError.chapterNotInSpine(chapterURL)
        }
        let nextSpineIdx = currentSpineIdx + 1
        guard nextSpineIdx < package.spine.count else {
            throw EditError.alreadyLastInSpine
        }
        let nextID = package.spine[nextSpineIdx]
        guard let nextItem = package.manifestById[nextID] else {
            throw EditError.alreadyLastInSpine
        }
        let nextURL = absoluteURL(forManifestHref: nextItem.href)

        // Read both files; extract bodies; concatenate.
        let currentText = try String(contentsOf: chapterURL, encoding: .utf8)
        let nextText = try String(contentsOf: nextURL, encoding: .utf8)
        guard let currentBody = Self.bodyRange(in: currentText) else {
            throw EditError.bodyNotFound(chapterURL)
        }
        guard let nextBody = Self.bodyRange(in: nextText) else {
            throw EditError.bodyNotFound(nextURL)
        }
        let head = String(currentText[..<currentBody.lowerBound])
        let foot = String(currentText[currentBody.upperBound...])
        let merged = head
            + currentText[currentBody.lowerBound..<currentBody.upperBound]
            + "\n"
            + nextText[nextBody.lowerBound..<nextBody.upperBound]
            + foot

        // Write merged file, then delete next file + remove from
        // manifest. Order: write first so a crash leaves us with the
        // pre-merge state (next file still present, original
        // unchanged would be ideal — we accept the trade-off of an
        // updated current file before the manifest update).
        try merged.write(to: chapterURL, atomically: true, encoding: .utf8)
        try? FileManager.default.removeItem(at: nextURL)
        try removeManifestItem(id: nextID)
        try regenerateNav()
    }

    // MARK: - TOC regeneration

    /// Rebuild `nav.xhtml` from the current spine. Each chapter's
    /// title is extracted from its first `<h1>` or `<h2>` element;
    /// chapters with no heading fall back to "Chapter N".
    ///
    /// Re-reads the OPF from disk so we reflect any spine /
    /// manifest mutations made by sibling operations on this
    /// editor (Split / Merge ran `insertManifestItem` /
    /// `removeManifestItem` before getting here; the in-memory
    /// `self.package` is now stale). Without this re-read, the
    /// regenerated nav would still link to the freshly-deleted
    /// chapter, and the new spine entry from a Split would be
    /// missing from the nav.
    public func regenerateNav() throws {
        let freshPackage: OPFReader.Package
        do {
            freshPackage = try OPFReader().read(rootDir: workingDirectory)
        } catch {
            throw EditError.malformedXML(
                "Couldn't re-read OPF before regenerating nav: \(error)"
            )
        }
        guard let nav = freshPackage.manifestById.values.first(where: {
            ($0.properties ?? "").contains("nav")
        }) else { throw EditError.missingNav }
        let navURL = opfDirectory.appendingPathComponent(nav.href)
        var entries: [String] = []
        for (i, itemID) in freshPackage.spine.enumerated() {
            guard let item = freshPackage.manifestById[itemID] else { continue }
            let chapterURL = opfDirectory.appendingPathComponent(item.href)
            let title = (try? Self.firstHeadingTitle(in: chapterURL))
                ?? "Chapter \(i + 1)"
            // Nav links use the chapter href relative to the nav file
            // — both live in the same directory in our packaging
            // convention, so the manifest href works as-is.
            let relHref = relativePath(from: navURL, to: chapterURL)
            entries.append(
                "<li><a href=\"\(XMLEscape.attribute(relHref))\">\(XMLEscape.text(title))</a></li>"
            )
        }

        let language = XMLEscape.attribute(freshPackage.metadata.language ?? "en")
        let docTitle = XMLEscape.text(freshPackage.metadata.title ?? "Contents")
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
        try xhtml.write(to: navURL, atomically: true, encoding: .utf8)
    }

    // MARK: - OPF mutation

    private func insertManifestItem(
        id: String,
        href: String,
        mediaType: String,
        afterSpineID anchor: String
    ) throws {
        let opfText = try String(contentsOf: opfURL, encoding: .utf8)
        guard let doc = try? XMLDocument(
            xmlString: opfText,
            options: [.nodePreserveWhitespace, .nodePreserveCDATA]
        ) else {
            throw EditError.malformedXML("OPF is not valid XML")
        }
        guard let root = doc.rootElement() else {
            throw EditError.malformedXML("OPF has no root element")
        }
        guard let manifest = Self.firstChild(of: root, named: "manifest"),
              let spine = Self.firstChild(of: root, named: "spine")
        else {
            throw EditError.malformedXML("OPF missing <manifest> or <spine>")
        }

        // Append to manifest.
        let item = XMLElement(name: "item")
        item.setAttributesWith([
            "id": id, "href": href, "media-type": mediaType,
        ])
        manifest.addChild(item)

        // Insert itemref in spine after the anchor.
        let itemref = XMLElement(name: "itemref")
        itemref.setAttributesWith(["idref": id])
        let children = spine.children ?? []
        var insertIdx = children.count
        for (idx, child) in children.enumerated() {
            guard let el = child as? XMLElement, el.name == "itemref" else { continue }
            if el.attribute(forName: "idref")?.stringValue == anchor {
                insertIdx = idx + 1
                break
            }
        }
        spine.insertChild(itemref, at: insertIdx)

        try doc.xmlString.write(to: opfURL, atomically: true, encoding: .utf8)
    }

    private func removeManifestItem(id: String) throws {
        let opfText = try String(contentsOf: opfURL, encoding: .utf8)
        guard let doc = try? XMLDocument(
            xmlString: opfText,
            options: [.nodePreserveWhitespace, .nodePreserveCDATA]
        ) else {
            throw EditError.malformedXML("OPF is not valid XML")
        }
        guard let root = doc.rootElement() else {
            throw EditError.malformedXML("OPF has no root element")
        }
        // Drop matching <item> from manifest.
        if let manifest = Self.firstChild(of: root, named: "manifest") {
            for child in manifest.children ?? [] {
                guard let el = child as? XMLElement, el.name == "item" else { continue }
                if el.attribute(forName: "id")?.stringValue == id {
                    el.detach()
                }
            }
        }
        // Drop matching <itemref> from spine.
        if let spine = Self.firstChild(of: root, named: "spine") {
            for child in spine.children ?? [] {
                guard let el = child as? XMLElement, el.name == "itemref" else { continue }
                if el.attribute(forName: "idref")?.stringValue == id {
                    el.detach()
                }
            }
        }
        try doc.xmlString.write(to: opfURL, atomically: true, encoding: .utf8)
    }

    private static func firstChild(of element: XMLElement, named: String) -> XMLElement? {
        for child in element.children ?? [] {
            if let el = child as? XMLElement, el.name == named { return el }
        }
        return nil
    }

    // MARK: - File-system helpers

    /// Compute a fresh manifest id like `chapter-NNN` not already
    /// present in the manifest.
    private func nextAvailableManifestId(prefix: String) -> String {
        var i = 1
        while true {
            let candidate = String(format: "\(prefix)-%03d", i)
            if package.manifestById[candidate] == nil { return candidate }
            i += 1
        }
    }

    /// Compute a fresh chapter file URL in the same directory as
    /// `near`, using a `chapter-NNNNN.<ext>` numbering scheme.
    private func nextAvailableChapterURL(near other: URL) -> URL {
        let dir = other.deletingLastPathComponent()
        let ext = other.pathExtension.isEmpty ? "xhtml" : other.pathExtension
        var i = 1
        while true {
            let candidate = dir.appendingPathComponent(
                String(format: "chapter-split-%05d.\(ext)", i)
            )
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            i += 1
        }
    }

    /// Manifest href for `absoluteURL`, expressed relative to the
    /// OPF's directory.
    private func manifestHref(forAbsolute absoluteURL: URL) -> String {
        relativePath(from: opfURL, to: absoluteURL)
    }

    /// Compute a path from `fromFile` (a file URL) to `toFile`,
    /// suitable for use as an `href` in a containing element. Uses
    /// `URLComponents` would be overkill — chapter files almost
    /// always sit in the same directory, so we handle that fast
    /// path and degrade to `..`-walking only if needed.
    private func relativePath(from fromFile: URL, to toFile: URL) -> String {
        let fromDir = fromFile.deletingLastPathComponent()
            .canonicalForFile.standardizedFileURL.path
        let toPath = toFile.canonicalForFile.standardizedFileURL.path
        if toPath.hasPrefix(fromDir + "/") {
            return String(toPath.dropFirst(fromDir.count + 1))
        }
        // Fallback: return absolute-ish relative path. Not bulletproof
        // for arbitrary directory shapes but covers the common case.
        return toFile.lastPathComponent
    }

    // MARK: - XHTML scanning

    /// Find the byte range of `<body>` content in `xhtml` —
    /// specifically, the range from just after `<body…>` to just
    /// before `</body>`. Used by split + merge.
    static func bodyRange(in xhtml: String) -> Range<String.Index>? {
        guard let openLT = xhtml.range(of: "<body", options: .caseInsensitive)
        else { return nil }
        guard let openGT = xhtml.range(
            of: ">", options: [], range: openLT.lowerBound..<xhtml.endIndex
        ) else { return nil }
        guard let closeLT = xhtml.range(
            of: "</body>", options: .caseInsensitive,
            range: openGT.upperBound..<xhtml.endIndex
        ) else { return nil }
        return openGT.upperBound..<closeLT.lowerBound
    }

    /// Snap `offset` forward in `xhtml` to the nearest position that
    /// is at the start of a top-level element on its own line — a
    /// position of the form `\n<` (with optional whitespace after the
    /// newline). This is the unambiguous safe boundary: there are no
    /// open elements being split, and the new chapter's body starts
    /// cleanly with an element.
    ///
    /// Returns `bodyEnd` if no such position exists between `offset`
    /// and the end of the body — the caller treats that as
    /// `splitOffsetOutOfBounds`.
    ///
    /// This matches the typical user gesture of "put my cursor on the
    /// blank line above the heading I want to start a new chapter at,
    /// then split." The cursor's current line stays in the original
    /// chapter; everything from the next element-start line onward
    /// becomes the new chapter.
    static func snapToSafeBoundary(
        in xhtml: String, near offset: Int, bodyEnd: Int
    ) -> Int {
        let chars = Array(xhtml)
        var i = max(0, min(offset, bodyEnd))
        while i < bodyEnd {
            if chars[i] == "\n" {
                var j = i + 1
                while j < bodyEnd, chars[j].isWhitespace, chars[j] != "\n" {
                    j += 1
                }
                if j < bodyEnd, chars[j] == "<" {
                    return j
                }
            }
            i += 1
        }
        return bodyEnd
    }

    /// Extract the text of the first `<h1>` or `<h2>` element in the
    /// chapter at `url`. Returns nil if no heading is present.
    static func firstHeadingTitle(in url: URL) throws -> String? {
        let content = try String(contentsOf: url, encoding: .utf8)
        return firstHeadingTitle(in: content)
    }

    /// Same as the URL-based form, but takes the chapter content
    /// directly. Used by the in-memory book path so we don't need to
    /// read from disk to regenerate a nav.
    static func firstHeadingTitle(in content: String) -> String? {
        for tag in ["h1", "h2", "h3"] {
            let pattern = "<\(tag)[^>]*>([\\s\\S]*?)</\(tag)>"
            if let regex = try? NSRegularExpression(
                pattern: pattern, options: [.caseInsensitive]
            ),
            let match = regex.firstMatch(
                in: content,
                range: NSRange(content.startIndex..., in: content)
            ),
            match.numberOfRanges > 1,
            let range = Range(match.range(at: 1), in: content) {
                let inner = String(content[range])
                let stripped = inner.replacingOccurrences(
                    of: "<[^>]+>", with: "", options: .regularExpression
                )
                let trimmed = stripped.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }
}
