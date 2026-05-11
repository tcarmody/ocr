import Foundation

/// File-system layout settings for converter outputs. Persisted via
/// `@AppStorage` because the launcher's `QueueViewModel` and the
/// pipeline both need to read the current value live.
public enum ConversionSettingsKeys {
    /// Path of the chosen output root folder. Empty = "no preference,
    /// write next to the source PDF" (the original behavior). When
    /// set, conversion outputs land under this folder, organized
    /// into per-format subfolders.
    public static let outputFolderPath = "humanist.conversion.outputFolderPath"
    /// When true, the launcher watches `<outputRoot>/Input/` for new
    /// PDFs and enqueues them automatically with the launcher's
    /// current default settings. Effective only when an output root
    /// is configured — no root means no `Input/` folder to watch.
    public static let autoScanInputFolder = "humanist.conversion.autoScanInputFolder"
    /// When true, `EPUBImporter.start` is invoked with
    /// `skipIndexing: true` — the import path runs through anchor
    /// injection + AFM metadata + chapter classification + catalog
    /// but skips the embedding-sidecar build. Useful for bulk
    /// imports (hundreds–thousands of books) where the user prefers
    /// to run the bulk-index command overnight separately rather
    /// than block the import on per-book embedding work.
    public static let skipIndexingOnImport = "humanist.conversion.skipIndexingOnImport"

    /// Initial values for the launcher's per-conversion toggles.
    /// `QueueViewModel.init` seeds its `@Published` properties from
    /// these on app launch; the user can override per-session in
    /// the launcher UI, but the override doesn't persist back — the
    /// next launch starts from these Settings values again. The
    /// auto-scan shell companion (`Scripts/auto-scan-input.sh`)
    /// reads the same keys to pass equivalent humanist-cli flags
    /// for headless / cron runs.
    public static let defaultUseSuryaOCR = "humanist.conversion.defaultUseSuryaOCR"
    public static let defaultUseClaudePageOCR = "humanist.conversion.defaultUseClaudePageOCR"
    public static let defaultForceOCR = "humanist.conversion.defaultForceOCR"
    public static let defaultPrivateMode = "humanist.conversion.defaultPrivateMode"
    public static let defaultEmitDebugLog = "humanist.conversion.defaultEmitDebugLog"
    public static let defaultEmitSiblingTextOutputs = "humanist.conversion.defaultEmitSiblingTextOutputs"
    public static let defaultEmitSiblingDocuments = "humanist.conversion.defaultEmitSiblingDocuments"
    public static let defaultEmitSearchablePDF = "humanist.conversion.defaultEmitSearchablePDF"
}

/// Snapshot of the per-conversion toggle defaults. Read at app
/// launch and at auto-scan time so the same source-of-truth flows
/// to the launcher UI, the auto-scan watcher (which goes through
/// the launcher's queue anyway), and the headless CLI companion.
///
/// `emitSiblingTextOutputs` is the only true-by-default toggle —
/// everything else stays false until the user flips a Settings
/// switch. Reads use `object(forKey:)` so a missing key falls back
/// to the factory default (`bool(forKey:)` would return false for
/// every unset key, breaking the emitSiblingTextOutputs case).
public struct ConversionDefaults: Sendable, Equatable {
    public var useSuryaOCR: Bool
    public var useClaudePageOCR: Bool
    public var forceOCR: Bool
    public var privateMode: Bool
    public var emitDebugLog: Bool
    public var emitSiblingTextOutputs: Bool
    public var emitSiblingDocuments: Bool
    public var emitSearchablePDF: Bool

    public static let factory = ConversionDefaults(
        useSuryaOCR: false,
        useClaudePageOCR: false,
        forceOCR: false,
        privateMode: false,
        emitDebugLog: false,
        emitSiblingTextOutputs: true,
        emitSiblingDocuments: false,
        emitSearchablePDF: false
    )

    public static func current() -> ConversionDefaults {
        let d = UserDefaults.standard
        func read(_ key: String, fallback: Bool) -> Bool {
            (d.object(forKey: key) as? Bool) ?? fallback
        }
        let f = factory
        return ConversionDefaults(
            useSuryaOCR: read(ConversionSettingsKeys.defaultUseSuryaOCR, fallback: f.useSuryaOCR),
            useClaudePageOCR: read(ConversionSettingsKeys.defaultUseClaudePageOCR, fallback: f.useClaudePageOCR),
            forceOCR: read(ConversionSettingsKeys.defaultForceOCR, fallback: f.forceOCR),
            privateMode: read(ConversionSettingsKeys.defaultPrivateMode, fallback: f.privateMode),
            emitDebugLog: read(ConversionSettingsKeys.defaultEmitDebugLog, fallback: f.emitDebugLog),
            emitSiblingTextOutputs: read(ConversionSettingsKeys.defaultEmitSiblingTextOutputs, fallback: f.emitSiblingTextOutputs),
            emitSiblingDocuments: read(ConversionSettingsKeys.defaultEmitSiblingDocuments, fallback: f.emitSiblingDocuments),
            emitSearchablePDF: read(ConversionSettingsKeys.defaultEmitSearchablePDF, fallback: f.emitSearchablePDF)
        )
    }
}

/// Subfolder layout under the configured output root. Hardcoded for
/// v1 — exposing them as user-renamable settings would expand the
/// surface area more than the value justifies for most workflows.
public enum ConversionOutputSubfolder {
    /// Drop zone for the auto-scan watcher. PDFs the user drops
    /// here get enqueued automatically when the
    /// `autoScanInputFolder` toggle is on; otherwise the folder is
    /// just a convenient staging area the user can use manually.
    public static let input = "Input"
    /// EPUBs land here.
    public static let books = "Books"
    /// Searchable-PDF siblings (source PDF + invisible OCR text
    /// overlay). Kept separate from `books` so the library folder
    /// is unambiguous: `Books/` is the EPUB collection that opens
    /// in the editor; `Searchable PDFs/` is the parallel set of
    /// Cmd+F'able source PDFs that nothing in the editor pipeline
    /// reads from. Bookkeeping aside, this also lets users sync
    /// `Books/` to a Kindle / Boox / dedicated reader without
    /// pulling along the much larger PDF copies.
    public static let searchablePDFs = "Searchable PDFs"
    /// Plain-text sibling outputs (V-Outputs).
    public static let textFiles = "Text Files"
    /// Markdown sibling outputs (V-Outputs).
    public static let markdown = "Markdown"
    /// Self-contained HTML sibling outputs (V-Outputs).
    public static let html = "HTML"
    /// Word DOCX sibling outputs (V-Outputs).
    public static let docx = "Word Documents"
    /// Per-conversion debug staging directories — populated only
    /// when "Emit debug log" is on for the conversion. Without
    /// debug-log enabled, the staging dir stays next to the source
    /// PDF (resume-friendly: re-runs find checkpoints regardless
    /// of where the EPUB landed).
    public static let logs = "Logs"
}

/// User's currently-configured output root, resolved from
/// `@AppStorage`. Nil when the user hasn't picked a folder yet —
/// callers fall back to the original side-by-side behavior.
public enum ConversionOutputResolver {
    /// Returns the output root URL when set + the directory exists.
    /// Returns nil when unset, when the path no longer exists, or
    /// when reading UserDefaults fails for any reason.
    public static func currentRoot() -> URL? {
        let raw = UserDefaults.standard.string(
            forKey: ConversionSettingsKeys.outputFolderPath
        ) ?? ""
        guard !raw.isEmpty else { return nil }
        let url = URL(fileURLWithPath: raw)
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: url.path, isDirectory: &isDir
        )
        guard exists, isDir.boolValue else { return nil }
        return url
    }

    /// Resolve the auto-scan Input folder URL when an output root
    /// is configured. Returns nil when no root is set — the
    /// auto-scan feature requires a root so PDFs and outputs share
    /// a single configured directory. Creates the directory lazily
    /// on first read so the user doesn't have to do it manually.
    public static func inputFolderURL() -> URL? {
        guard let root = currentRoot() else { return nil }
        let url = root.appendingPathComponent(
            ConversionOutputSubfolder.input, isDirectory: true
        )
        try? FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true
        )
        return url
    }

    /// Build the EPUB output URL for a source PDF, honoring the
    /// configured output root and the optional `suffix`. Falls
    /// back to side-by-side when no root is set. `suffix` is
    /// appended to the basename with a leading space when
    /// non-empty (`<basename> <suffix>.epub`); empty preserves
    /// the original `<basename>.epub` shape.
    public static func epubOutputURL(
        forSource sourcePDF: URL, suffix: String = ""
    ) -> URL {
        let stem = stemmedName(forSource: sourcePDF, suffix: suffix)
        if let root = currentRoot() {
            let dir = root.appendingPathComponent(
                ConversionOutputSubfolder.books, isDirectory: true
            )
            return dir.appendingPathComponent(stem)
                .appendingPathExtension("epub")
        }
        return sourcePDF.deletingLastPathComponent()
            .appendingPathComponent(stem)
            .appendingPathExtension("epub")
    }

    /// Compute (txt, md) sibling URL overrides for a source PDF
    /// when the user has an output root configured.
    /// Returns `(nil, nil)` when there's no root.
    public static func siblingTextOverrides(
        forSource sourcePDF: URL, suffix: String = ""
    ) -> (txt: URL?, md: URL?) {
        let stem = stemmedName(forSource: sourcePDF, suffix: suffix)
        guard let root = currentRoot() else { return (nil, nil) }
        let txt = root
            .appendingPathComponent(ConversionOutputSubfolder.textFiles, isDirectory: true)
            .appendingPathComponent(stem)
            .appendingPathExtension("txt")
        let md = root
            .appendingPathComponent(ConversionOutputSubfolder.markdown, isDirectory: true)
            .appendingPathComponent(stem)
            .appendingPathExtension("md")
        return (txt, md)
    }

    /// Compute (html, docx) sibling URL overrides for a source PDF
    /// when the user has an output root configured.
    /// Returns `(nil, nil)` when there's no root.
    public static func siblingDocumentOverrides(
        forSource sourcePDF: URL, suffix: String = ""
    ) -> (html: URL?, docx: URL?) {
        let stem = stemmedName(forSource: sourcePDF, suffix: suffix)
        guard let root = currentRoot() else { return (nil, nil) }
        let html = root
            .appendingPathComponent(ConversionOutputSubfolder.html, isDirectory: true)
            .appendingPathComponent(stem)
            .appendingPathExtension("html")
        let docx = root
            .appendingPathComponent(ConversionOutputSubfolder.docx, isDirectory: true)
            .appendingPathComponent(stem)
            .appendingPathExtension("docx")
        return (html, docx)
    }

    /// Build the searchable-PDF sibling URL for a source PDF when
    /// the user has an output root configured. Lands in the
    /// `Searchable PDFs/` subfolder — separate from `Books/` so the
    /// EPUB library stays uncluttered and can be synced to e-reader
    /// hardware without pulling along the much larger PDF copies.
    /// Returns nil when there's no root — pipeline keeps the
    /// side-by-side default.
    public static func searchablePDFOutputURL(
        forSource sourcePDF: URL, suffix: String = ""
    ) -> URL? {
        let stem = stemmedName(forSource: sourcePDF, suffix: suffix)
        guard let root = currentRoot() else { return nil }
        return root
            .appendingPathComponent(
                ConversionOutputSubfolder.searchablePDFs, isDirectory: true
            )
            .appendingPathComponent(stem)
            .appendingPathExtension("searchable.pdf")
    }

    /// Override for the debug-mode staging directory for a source
    /// PDF. The pipeline normally stashes per-page artifacts in
    /// `<source>.humanist-debug/` next to the EPUB output (when
    /// `emitDebugLog` is on); when the user has configured an
    /// output root, route it under `<root>/Logs/` instead so the
    /// Settings layout preview's "Logs/" promise is real. `suffix`
    /// applies the same "<basename> <suffix>" convention to the
    /// debug dir's name so each variant's logs land in their own
    /// directory rather than overwriting each other.
    /// Returns nil when no root is configured — pipeline keeps the
    /// original next-to-EPUB behavior.
    public static func debugStagingURL(
        forSource sourcePDF: URL, suffix: String = ""
    ) -> URL? {
        let stem = stemmedName(forSource: sourcePDF, suffix: suffix)
        guard let root = currentRoot() else { return nil }
        return root
            .appendingPathComponent(ConversionOutputSubfolder.logs, isDirectory: true)
            .appendingPathComponent(stem)
            .appendingPathExtension("humanist-debug")
    }

    /// `<basename>` or `<basename> <suffix>` depending on whether
    /// `suffix` is empty. Trims and rejects path-traversal inputs.
    private static func stemmedName(
        forSource sourcePDF: URL, suffix: String
    ) -> String {
        let basename = sourcePDF.deletingPathExtension().lastPathComponent
        let trimmed = suffix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return basename }
        // Strip path-meta characters defensively. The UI can't
        // reasonably catch every weird string the user might
        // paste; keep the output-filename derivation safe.
        let cleaned = trimmed.replacingOccurrences(
            of: "[/:\\\\]+", with: "-", options: .regularExpression
        )
        return "\(basename) \(cleaned)"
    }
}
