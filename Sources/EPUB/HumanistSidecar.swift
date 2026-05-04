import Foundation

/// Editor-only metadata stored inside the EPUB at
/// `META-INF/com.humanist.json`. Standard EPUB readers ignore unknown
/// META-INF files, so this round-trips through other tools (Sigil,
/// calibre) without corrupting the book.
///
/// Today: just the path to a source PDF the user has associated with
/// this EPUB so the editor's PDF pane can open it. Future fields
/// (page-anchor map, last-opened-file, layout prefs) belong here too.
public struct HumanistSidecar: Codable, Equatable, Sendable {
    /// Path to the source PDF. Stored as either an absolute path or a
    /// path relative to the EPUB file. Resolution tries both so
    /// moving the .epub + .pdf together doesn't break the link.
    public var sourcePDFPath: String?

    public init(sourcePDFPath: String? = nil) {
        self.sourcePDFPath = sourcePDFPath
    }

    /// Path of the sidecar inside an unpacked EPUB working directory.
    public static let pathInsideEPUB = "META-INF/com.humanist.json"

    /// Read the sidecar from a working directory. Returns an empty
    /// sidecar (no fields set) if the file is missing — that's the
    /// normal case for an EPUB the editor hasn't touched before.
    public static func read(workingDirectory: URL) -> HumanistSidecar {
        let url = workingDirectory.appendingPathComponent(pathInsideEPUB)
        guard let data = try? Data(contentsOf: url) else { return HumanistSidecar() }
        return (try? JSONDecoder().decode(HumanistSidecar.self, from: data))
            ?? HumanistSidecar()
    }

    /// Write the sidecar into a working directory. Repacking the EPUB
    /// will then carry it back into the .epub.
    public func write(workingDirectory: URL) throws {
        let url = workingDirectory.appendingPathComponent(Self.pathInsideEPUB)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: url, options: .atomic)
    }

    /// Resolve `sourcePDFPath` against an EPUB's location. Tries:
    ///   1. the path as-is (handles absolute paths)
    ///   2. the path relative to the EPUB's directory
    ///   3. the path's last component next to the EPUB
    /// Returns the first existing file URL it finds.
    public func resolveSourcePDF(epubURL: URL) -> URL? {
        guard let raw = sourcePDFPath, !raw.isEmpty else { return nil }
        let fm = FileManager.default
        let asIs = URL(fileURLWithPath: raw)
        if fm.fileExists(atPath: asIs.path) { return asIs.canonicalForFile }
        let epubDir = epubURL.deletingLastPathComponent()
        let relative = epubDir.appendingPathComponent(raw).canonicalForFile
        if fm.fileExists(atPath: relative.path) { return relative }
        let basename = (raw as NSString).lastPathComponent
        let beside = epubDir.appendingPathComponent(basename).canonicalForFile
        if fm.fileExists(atPath: beside.path) { return beside }
        return nil
    }
}
