import Foundation

/// Flushes the in-memory `EPUBBook` back to its working directory.
///
/// Order of operations is chosen so a partial failure leaves the EPUB
/// in the most useful intermediate state we can give:
///   1. Write every dirty text resource (chapters first, then nav,
///      etc.) — the new content is on disk before the OPF starts
///      pointing at it.
///   2. Re-serialize the OPF: parse the original OPF text, surgically
///      replace `<manifest>` and `<spine>`, optionally rewrite Dublin
///      Core metadata when dirty, bump `dcterms:modified`, write back.
///      The parse-and-mutate pattern preserves any OPF content the
///      Book model doesn't represent (custom metadata, comments).
///   3. Delete files for resources removed since last load — done
///      last so the OPF on disk no longer references them by the time
///      we unlink them.
///
/// We don't call this transactional. A crash between steps leaves a
/// partial save on disk, same as the old `PackageEditor` path. The
/// improvement is at the *in-memory* layer: failure during `save()`
/// throws without modifying the in-memory model, so the editor can
/// retry once the underlying problem is resolved.
public struct EPUBBookSaver {

    public init() {}

    public enum SaveError: Error, LocalizedError {
        case opfParse(String)
        case writeFailed(href: String, underlying: Error)

        public var errorDescription: String? {
            switch self {
            case .opfParse(let s):
                return "Couldn't reserialize OPF: \(s)"
            case .writeFailed(let href, let e):
                return "Couldn't write \(href): \(e)"
            }
        }
    }

    /// Persist all dirty state to disk. No-ops cleanly when
    /// `book.isDirty` is false.
    public func save(_ book: EPUBBook) throws {
        guard book.isDirty else { return }

        // Move/rename happens before dirty-resource writes so that
        // the subsequent write lands at the new (current) path
        // rather than the old one. Otherwise the dirty flush would
        // create a fresh file at the new path AND we'd still need
        // to delete the old one — wasted I/O at best, an orphaned
        // copy at worst.
        try processPendingRenames(book)
        try writeDirtyResources(book)
        try rewriteOPF(book)
        try processPendingDeletions(book)

        book.clearDirtyFlags()
    }

    // MARK: - Steps

    private func writeDirtyResources(_ book: EPUBBook) throws {
        for resource in book.resourcesByID.values {
            guard resource.isDirty else { continue }
            switch resource.content {
            case .text(let text):
                let absoluteURL = book.absoluteURL(for: resource)
                let parent = absoluteURL.deletingLastPathComponent()
                if !FileManager.default.fileExists(atPath: parent.path) {
                    try FileManager.default.createDirectory(
                        at: parent,
                        withIntermediateDirectories: true
                    )
                }
                do {
                    try text.write(to: absoluteURL, atomically: true, encoding: .utf8)
                } catch {
                    throw SaveError.writeFailed(
                        href: resource.hrefRelativeToOPF, underlying: error
                    )
                }
            case .binary:
                // Binary content is owned by the on-disk file. The
                // dirty flag here just signals that the resource's
                // metadata (href, mediaType, properties) changed,
                // which the OPF rewrite below will reflect. Nothing
                // to write per-resource.
                continue
            }
        }
    }

    private func rewriteOPF(_ book: EPUBBook) throws {
        let doc: XMLDocument
        do {
            doc = try XMLDocument(
                xmlString: book.originalOPFText,
                options: [.nodePreserveWhitespace, .nodePreserveCDATA]
            )
        } catch {
            throw SaveError.opfParse("input not valid XML: \(error)")
        }
        guard let root = doc.rootElement() else {
            throw SaveError.opfParse("OPF has no root element")
        }

        try replaceManifest(in: root, with: book)
        try replaceSpine(in: root, with: book)
        if book.metadataIsDirty {
            updateMetadataInPlace(in: root, with: book.metadata)
        }
        bumpModifiedTimestamp(in: root)

        do {
            try doc.xmlString.write(
                to: book.opfURL, atomically: true, encoding: .utf8
            )
        } catch {
            throw SaveError.writeFailed(
                href: book.opfPathRelativeToRoot, underlying: error
            )
        }
    }

    private func processPendingDeletions(_ book: EPUBBook) throws {
        let deletions = book.consumePendingDeletions()
        for deletion in deletions {
            // Best-effort. A missing file is a successful deletion;
            // any other error gets ignored at this layer because
            // the OPF is already updated to no longer reference it.
            try? FileManager.default.removeItem(at: deletion.diskURL)
        }
    }

    /// Move each renamed file from its old location on disk to its
    /// new location. The resource's `hrefRelativeToOPF` already
    /// holds the new path; combined with `book.opfDirectory` that
    /// gives us the destination URL.
    private func processPendingRenames(_ book: EPUBBook) throws {
        let renames = book.consumePendingRenames()
        for rename in renames {
            guard let resource = book.resourcesByID[rename.id] else { continue }
            let newURL = book.absoluteURL(for: resource)
            if rename.oldDiskURL == newURL { continue }

            // Make sure the destination directory exists — rename
            // into a sibling directory should still work.
            let destDir = newURL.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: destDir.path) {
                try FileManager.default.createDirectory(
                    at: destDir, withIntermediateDirectories: true
                )
            }

            if FileManager.default.fileExists(atPath: rename.oldDiskURL.path) {
                // Drop a stale destination if it somehow exists —
                // shouldn't happen because renameResource() rejects
                // duplicate hrefs in the manifest, but defensive.
                try? FileManager.default.removeItem(at: newURL)
                do {
                    try FileManager.default.moveItem(
                        at: rename.oldDiskURL, to: newURL
                    )
                } catch {
                    throw SaveError.writeFailed(
                        href: resource.hrefRelativeToOPF, underlying: error
                    )
                }
            }
            // If the old file didn't exist on disk yet (resource
            // was added in-memory and never saved), the dirty-
            // resource flush below writes the new content directly
            // to the new path; nothing to move.
        }
    }

    // MARK: - OPF mutation helpers

    private func replaceManifest(
        in root: XMLElement, with book: EPUBBook
    ) throws {
        guard let manifest = firstChild(of: root, named: "manifest") else {
            throw SaveError.opfParse("OPF missing <manifest>")
        }
        // Drop existing children.
        while let first = manifest.children?.first {
            first.detach()
        }
        // Rebuild from book state in resourceOrder. Preserves any
        // properties string verbatim.
        for id in book.resourceOrder {
            guard let resource = book.resourcesByID[id] else { continue }
            let item = XMLElement(name: "item")
            var attrs: [String: String] = [
                "id": resource.id,
                "href": resource.hrefRelativeToOPF,
                "media-type": resource.mediaType,
            ]
            if let properties = resource.properties, !properties.isEmpty {
                attrs["properties"] = properties
            }
            item.setAttributesWith(attrs)
            manifest.addChild(item)
        }
    }

    private func replaceSpine(
        in root: XMLElement, with book: EPUBBook
    ) throws {
        guard let spine = firstChild(of: root, named: "spine") else {
            throw SaveError.opfParse("OPF missing <spine>")
        }
        // Preserve attributes on <spine> itself (e.g. toc="ncx" for
        // EPUB 2 books). Drop only the <itemref> children.
        if let children = spine.children {
            for child in children {
                if let el = child as? XMLElement, el.name == "itemref" {
                    el.detach()
                }
            }
        }
        for id in book.spine {
            let itemref = XMLElement(name: "itemref")
            itemref.setAttributesWith(["idref": id])
            spine.addChild(itemref)
        }
    }

    /// Surgically update the six modeled `<dc:*>` fields from
    /// `metadata`. Other dc:* / meta children pass through
    /// untouched — we're not rebuilding the metadata block, just
    /// upserting our slots.
    ///
    /// ISBN gets special treatment: never overwrite the package's
    /// `unique-identifier` element (the publishing identity that
    /// `<package unique-identifier="…">` references), even if it's
    /// the only `<dc:identifier>` in the doc. We add the ISBN as
    /// a *separate* `<dc:identifier>urn:isbn:…</dc:identifier>`
    /// sibling — same shape the conversion path's `OPFWriter`
    /// emits, so round-trips through Humanist stay consistent.
    private func updateMetadataInPlace(
        in root: XMLElement, with metadata: OPFReader.Metadata
    ) {
        guard let metadataEl = firstChild(of: root, named: "metadata") else {
            return
        }
        upsertSimpleDC(metadataEl, localName: "title", value: metadata.title)
        upsertSimpleDC(metadataEl, localName: "creator", value: metadata.author)
        upsertSimpleDC(metadataEl, localName: "language", value: metadata.language)
        upsertSimpleDC(metadataEl, localName: "date", value: metadata.year)
        upsertSimpleDC(metadataEl, localName: "publisher", value: metadata.publisher)
        upsertSimpleDC(metadataEl, localName: "source", value: metadata.source)
        upsertISBNIdentifier(
            in: metadataEl,
            packageUniqueIdentifierID: root
                .attribute(forName: "unique-identifier")?.stringValue,
            value: metadata.isbn
        )
    }

    /// Update the *first* `<dc:{localName}>` child to the given value,
    /// or insert one if absent. Removes the element if `value` is nil
    /// or empty. Doesn't touch additional siblings with the same
    /// local name (e.g. multiple authors) — only the first.
    private func upsertSimpleDC(
        _ metadataEl: XMLElement, localName: String, value: String?
    ) {
        let existing = (metadataEl.children ?? []).compactMap { node -> XMLElement? in
            guard let el = node as? XMLElement else { return nil }
            return el.localName == localName ? el : nil
        }
        if let value = value, !value.isEmpty {
            if let target = existing.first {
                target.stringValue = value
            } else {
                let el = XMLElement(name: "dc:\(localName)", stringValue: value)
                metadataEl.addChild(el)
            }
        } else {
            existing.first?.detach()
        }
    }

    /// Upsert the ISBN as a `<dc:identifier>urn:isbn:VALUE</dc:identifier>`
    /// sibling element. Looks for an existing ISBN-shaped
    /// identifier (URN-prefixed value or `scheme="ISBN"`
    /// attribute) and updates it in place; otherwise appends a
    /// new element. The package's `unique-identifier` element
    /// (matched by `id == packageUniqueIdentifierID`) is
    /// excluded from match candidates so the publishing identity
    /// is never silently replaced — even if the only existing
    /// `<dc:identifier>` is ISBN-shaped, we add a new one
    /// alongside it.
    ///
    /// Nil / empty `value` drops a previously-added Humanist
    /// ISBN element (URN-prefixed). Doesn't touch
    /// scheme-attributed identifiers in the deletion path —
    /// those were likely publisher-set and shouldn't disappear
    /// just because the model lost the value.
    private func upsertISBNIdentifier(
        in metadataEl: XMLElement,
        packageUniqueIdentifierID: String?,
        value: String?
    ) {
        let allIdentifiers = (metadataEl.children ?? []).compactMap {
            node -> XMLElement? in
            guard let el = node as? XMLElement,
                  el.localName == "identifier" else { return nil }
            // Skip the package's identity identifier.
            if let id = el.attribute(forName: "id")?.stringValue,
               id == packageUniqueIdentifierID {
                return nil
            }
            return el
        }
        // Find an existing ISBN-bearing identifier — by URN prefix
        // or by scheme attribute (with or without opf: prefix,
        // case-insensitive).
        let isbnIdentifier = allIdentifiers.first { el in
            let raw = (el.stringValue ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            if raw.hasPrefix("urn:isbn:") { return true }
            let scheme = (el.attribute(forName: "opf:scheme")?.stringValue
                ?? el.attribute(forName: "scheme")?.stringValue
                ?? "").lowercased()
            return scheme == "isbn"
        }

        guard let value = value, !value.isEmpty else {
            // Drop only URN-shaped (Humanist-emitted) elements;
            // leave publisher-set scheme="ISBN" attributes alone
            // so the EPUB's original metadata isn't degraded.
            if let target = isbnIdentifier,
               (target.stringValue ?? "")
                .lowercased().hasPrefix("urn:isbn:") {
                target.detach()
            }
            return
        }

        let urnValue = "urn:isbn:\(value)"
        if let target = isbnIdentifier {
            target.stringValue = urnValue
            return
        }
        let el = XMLElement(name: "dc:identifier", stringValue: urnValue)
        metadataEl.addChild(el)
    }

    /// EPUB 3 mandates a `<meta property="dcterms:modified">` whose
    /// value is bumped on every save. Insert if missing.
    private func bumpModifiedTimestamp(in root: XMLElement) {
        let stamp = Self.iso8601(Date())
        guard let metadataEl = firstChild(of: root, named: "metadata") else {
            return
        }
        let metas = (metadataEl.children ?? []).compactMap { node -> XMLElement? in
            guard let el = node as? XMLElement, el.localName == "meta" else { return nil }
            return el.attribute(forName: "property")?.stringValue == "dcterms:modified"
                ? el : nil
        }
        if let target = metas.first {
            target.stringValue = stamp
        } else {
            let el = XMLElement(name: "meta", stringValue: stamp)
            el.setAttributesWith(["property": "dcterms:modified"])
            metadataEl.addChild(el)
        }
    }

    // MARK: - XML helpers

    private func firstChild(
        of element: XMLElement, named: String
    ) -> XMLElement? {
        for child in element.children ?? [] {
            if let el = child as? XMLElement, el.name == named { return el }
            if let el = child as? XMLElement, el.localName == named { return el }
        }
        return nil
    }

    private static func iso8601(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return f.string(from: date)
    }
}
