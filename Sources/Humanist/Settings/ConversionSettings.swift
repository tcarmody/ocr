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
}

/// Subfolder layout under the configured output root. Hardcoded for
/// v1 — exposing them as user-renamable settings would expand the
/// surface area more than the value justifies for most workflows.
public enum ConversionOutputSubfolder {
    /// EPUBs (and, when V-PDF-Searchable ships, output PDFs) land here.
    public static let books = "Books"
    /// Plain-text sibling outputs (V-Outputs).
    public static let textFiles = "Text Files"
    /// Markdown sibling outputs (V-Outputs).
    public static let markdown = "Markdown"
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
    /// when the user has an output root configured. `suffix`
    /// applies the same "<basename> <suffix>" convention to the
    /// sibling filenames so they group with the matching EPUB.
    /// Returns `(nil, nil)` when there's no root — callers leave
    /// the pipeline's default side-by-side behavior in place.
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

    /// Build the searchable-PDF sibling URL for a source PDF when
    /// the user has an output root configured. Lands next to the
    /// EPUB in the `Books` subfolder so paired outputs sort
    /// together. Returns nil when there's no root — pipeline keeps
    /// the side-by-side default.
    public static func searchablePDFOutputURL(
        forSource sourcePDF: URL, suffix: String = ""
    ) -> URL? {
        let stem = stemmedName(forSource: sourcePDF, suffix: suffix)
        guard let root = currentRoot() else { return nil }
        return root
            .appendingPathComponent(ConversionOutputSubfolder.books, isDirectory: true)
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
