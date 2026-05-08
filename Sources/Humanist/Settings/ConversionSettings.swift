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
    /// Per-conversion debug logs. v1 doesn't yet route the staging
    /// dir here — the Settings UI shows the slot so the user knows
    /// it'll be populated when we wire the staging-dir relocation
    /// in a follow-up. Today the staging dir still lives next to
    /// the source PDF.
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
    /// configured output root if any. Falls back to side-by-side
    /// when no root is set.
    public static func epubOutputURL(forSource sourcePDF: URL) -> URL {
        let basename = sourcePDF.deletingPathExtension().lastPathComponent
        if let root = currentRoot() {
            let dir = root.appendingPathComponent(
                ConversionOutputSubfolder.books, isDirectory: true
            )
            return dir.appendingPathComponent(basename)
                .appendingPathExtension("epub")
        }
        return sourcePDF.deletingPathExtension()
            .appendingPathExtension("epub")
    }

    /// Compute (txt, md) sibling URL overrides for a source PDF
    /// when the user has an output root configured. Returns
    /// `(nil, nil)` when there's no root — callers leave the
    /// pipeline's default side-by-side behavior in place.
    public static func siblingTextOverrides(
        forSource sourcePDF: URL
    ) -> (txt: URL?, md: URL?) {
        let basename = sourcePDF.deletingPathExtension().lastPathComponent
        guard let root = currentRoot() else { return (nil, nil) }
        let txt = root
            .appendingPathComponent(ConversionOutputSubfolder.textFiles, isDirectory: true)
            .appendingPathComponent(basename)
            .appendingPathExtension("txt")
        let md = root
            .appendingPathComponent(ConversionOutputSubfolder.markdown, isDirectory: true)
            .appendingPathComponent(basename)
            .appendingPathExtension("md")
        return (txt, md)
    }
}
