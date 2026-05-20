import Foundation

/// R-Reader. One user-marked thing inside an EPUB: a bookmark, a
/// highlight, or a passage (= highlight + note). Unified model
/// because all three share the same anchor + storage shape; only
/// the rendering and what fields are populated differ.
///
/// Anchor strategy is "text match first, offsets second": the
/// renderer tries to find `selectedText` verbatim inside the
/// paragraph at restore time, falling back to `selectionRange`
/// offsets when the text has been edited away. The verbatim
/// match survives small paragraph edits / OCR fixes; offsets
/// survive larger edits when the original text no longer
/// appears.
public struct Annotation: Codable, Equatable, Identifiable, Sendable {

    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// Anchor-only marker — "return here." No selection text,
        /// no note.
        case bookmark
        /// Selected passage with optional note. The default for
        /// the highlight gesture.
        case highlight
        /// Selected passage with a non-empty note. The kind is
        /// the same as highlight at storage time; this case
        /// signals "the user wrote something about this." UI may
        /// filter / sort separately.
        case passage
    }

    /// Offsets within the containing paragraph's text node. The
    /// 0-based start + end character positions of the selection
    /// when it was first captured. Used as the fallback anchor
    /// when verbatim text matching fails at restore time.
    public struct TextRange: Codable, Equatable, Sendable {
        public let startOffset: Int
        public let endOffset: Int

        public init(startOffset: Int, endOffset: Int) {
            self.startOffset = startOffset
            self.endOffset = endOffset
        }
    }

    public let id: UUID
    /// Zero-based spine index of the containing chapter.
    public var chapterIdx: Int
    /// Paragraph anchor id (`hu-p-{chapterIdx}-{paragraphIdx}`).
    /// nil for bookmarks placed in EPUBs without Humanist
    /// per-paragraph anchors — those degrade to chapter-top on
    /// restore.
    public var paragraphAnchorId: String?
    /// The selected text at capture time. nil for bookmarks
    /// (anchor-only). The renderer uses this for the verbatim-
    /// match restore path; preserved exactly so trailing
    /// whitespace and punctuation match what the user grabbed.
    public var selectedText: String?
    /// Character-offset range within the paragraph's text. The
    /// offset-based fallback when verbatim match fails. nil for
    /// bookmarks.
    public var selectionRange: TextRange?
    /// Optional user-written note. nil → plain bookmark or
    /// highlight; non-empty → annotation kind = `.passage`.
    public var note: String?
    public var kind: Kind
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        chapterIdx: Int,
        paragraphAnchorId: String? = nil,
        selectedText: String? = nil,
        selectionRange: TextRange? = nil,
        note: String? = nil,
        kind: Kind,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.chapterIdx = chapterIdx
        self.paragraphAnchorId = paragraphAnchorId
        self.selectedText = selectedText
        self.selectionRange = selectionRange
        self.note = note
        self.kind = kind
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Per-book annotations bundle. One file per content hash on
/// disk; the array is sorted by `createdAt` (ascending) for
/// deterministic file output. The reader UI sorts at display
/// time as needed.
public struct AnnotationsBundle: Codable, Equatable, Sendable {
    public let contentHash: String
    public var annotations: [Annotation]

    public init(contentHash: String, annotations: [Annotation] = []) {
        self.contentHash = contentHash
        self.annotations = annotations
    }
}

/// Reads and writes `AnnotationsBundle` records to a per-content-
/// hash sidecar in Application Support. Mirrors
/// `ReadingPositionStore` — same directory layout, same atomic-
/// write posture, same decode-corrupt-as-empty fallback.
public enum AnnotationStore {

    public static func fileURL(forContentHash contentHash: String) -> URL? {
        guard let dir = ensureDirectory() else { return nil }
        return dir
            .appendingPathComponent(contentHash)
            .appendingPathExtension("json")
    }

    /// Load the bundle for `contentHash`. Returns an empty
    /// bundle (not nil) when no file exists — callers can append
    /// to whatever they get back without an extra
    /// initialize-if-missing dance. Corrupt files log via NSLog
    /// and return empty so a damaged sidecar can't break reader
    /// open.
    public static func load(forContentHash contentHash: String) -> AnnotationsBundle {
        guard let url = fileURL(forContentHash: contentHash) else {
            return AnnotationsBundle(contentHash: contentHash)
        }
        guard let data = try? Data(contentsOf: url) else {
            return AnnotationsBundle(contentHash: contentHash)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(AnnotationsBundle.self, from: data)
        } catch {
            NSLog(
                "Humanist: AnnotationStore decode failed for %@: %@",
                contentHash, error.localizedDescription
            )
            return AnnotationsBundle(contentHash: contentHash)
        }
    }

    /// Write the bundle. Atomic write to a temp file then
    /// rename, so a process kill mid-write can't corrupt the
    /// sidecar. Failure logs via NSLog without surfacing to the
    /// user (annotation loss is local; reading still works).
    public static func save(_ bundle: AnnotationsBundle) {
        guard let url = fileURL(forContentHash: bundle.contentHash) else {
            return
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(bundle)
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog(
                "Humanist: AnnotationStore save failed for %@: %@",
                bundle.contentHash, error.localizedDescription
            )
        }
    }

    /// Append `annotation` to the existing bundle and save. The
    /// most common path — user adds a bookmark / highlight /
    /// passage; this routes that one event to disk without
    /// callers having to load + mutate + save themselves.
    public static func add(
        _ annotation: Annotation, forContentHash contentHash: String
    ) {
        var bundle = load(forContentHash: contentHash)
        bundle.annotations.append(annotation)
        save(bundle)
    }

    /// Replace an existing annotation by id (matches via
    /// `Annotation.id`). No-op when not found. Used by the
    /// note-editing flow; an updatedAt timestamp bump is the
    /// caller's responsibility.
    public static func update(
        _ annotation: Annotation, forContentHash contentHash: String
    ) {
        var bundle = load(forContentHash: contentHash)
        guard let idx = bundle.annotations.firstIndex(
            where: { $0.id == annotation.id }
        ) else { return }
        bundle.annotations[idx] = annotation
        save(bundle)
    }

    /// Remove an annotation by id. No-op when not found.
    public static func remove(
        id: UUID, forContentHash contentHash: String
    ) {
        var bundle = load(forContentHash: contentHash)
        bundle.annotations.removeAll { $0.id == id }
        save(bundle)
    }

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
            .appendingPathComponent("Annotations", isDirectory: true)
        try? fm.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        return dir
    }
}
