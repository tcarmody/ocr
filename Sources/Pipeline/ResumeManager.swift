import Foundation
import CoreGraphics
import OCR
import Layout
import Document
import EPUB

/// Per-page checkpoint persisted to disk so a re-run of the same
/// PDF can skip already-processed pages. Captures the post-cascade
/// per-page state — observations, layout regions, figures, table
/// extractions, plus the per-page slice of the trust verdict and
/// correction-trail rows. Reflow can be run from these without
/// re-rendering or re-OCRing the page.
public struct PageCheckpoint: Sendable, Codable {
    public let pageIndex: Int
    public let pageBoundsWidth: CGFloat
    public let pageBoundsHeight: CGFloat
    public let observations: [TextObservation]
    public let layoutRegions: [LayoutRegion]?
    public let figures: [FigureExtractor.ExtractedFigure]
    /// Per-region table extractions for this page. Outer key is the
    /// region index within `layoutRegions`; values are the row × cell
    /// grid Surya / heuristics produced for that region.
    public let tableExtractionsByRegionIndex: [Int: [[TableCell]]]
    /// Embedded-text trust verdict produced by
    /// `EmbeddedTextQualityScorer` on this page (`"trust"` /
    /// `"reocr"` / nil).
    public let verdict: String?
    /// Correction-trail entries the Haiku post-OCR cleanup pass
    /// produced for this page. Empty when the cleanup feature is
    /// off or no regions tripped the trigger gate.
    public let correctionTrailEntries: [CorrectionTrail.Entry]

    public init(
        pageIndex: Int,
        pageBoundsWidth: CGFloat,
        pageBoundsHeight: CGFloat,
        observations: [TextObservation],
        layoutRegions: [LayoutRegion]?,
        figures: [FigureExtractor.ExtractedFigure],
        tableExtractionsByRegionIndex: [Int: [[TableCell]]],
        verdict: String?,
        correctionTrailEntries: [CorrectionTrail.Entry]
    ) {
        self.pageIndex = pageIndex
        self.pageBoundsWidth = pageBoundsWidth
        self.pageBoundsHeight = pageBoundsHeight
        self.observations = observations
        self.layoutRegions = layoutRegions
        self.figures = figures
        self.tableExtractionsByRegionIndex = tableExtractionsByRegionIndex
        self.verdict = verdict
        self.correctionTrailEntries = correctionTrailEntries
    }
}

/// Top-level manifest stored at `staging/manifest.json`. Used to
/// validate that a resume attempt is operating on the same source
/// PDF the prior run started — moving / replacing the source
/// invalidates checkpoints and we rebuild from scratch.
public struct StagingManifest: Sendable, Codable {
    /// Schema version — bump if the checkpoint shape changes
    /// incompatibly.
    public let schemaVersion: Int
    /// Source PDF identity. Combine of byte size + first-64KB
    /// SHA-256 prefix; cheap to compute and stable across moves.
    public let sourceFingerprint: String
    /// Total pages in the source PDF, from the first run. Validated
    /// against the current PDF's page count to catch "user replaced
    /// the PDF with a different one."
    public let totalPages: Int

    public init(
        schemaVersion: Int = 1,
        sourceFingerprint: String,
        totalPages: Int
    ) {
        self.schemaVersion = schemaVersion
        self.sourceFingerprint = sourceFingerprint
        self.totalPages = totalPages
    }
}

/// Manages on-disk per-page checkpoints in a staging directory.
/// Exposes synchronous read/write — the per-page work is the slow
/// part; serializing 50KB of JSON is irrelevant.
public struct ResumeManager: Sendable {
    public let stagingDir: URL

    public init(stagingDir: URL) {
        self.stagingDir = stagingDir
    }

    /// Path of the manifest file. Read first to validate the
    /// staging directory matches the current source PDF.
    public var manifestURL: URL {
        stagingDir.appendingPathComponent("manifest.json")
    }

    public func checkpointURL(forPage page: Int) -> URL {
        stagingDir.appendingPathComponent(String(format: "page-%05d.json", page))
    }

    /// Compute a stable identity for `pdfURL`: hex of the SHA-256 of
    /// the file's first 64 KB, followed by `:` and the file's byte
    /// size. Cheap (no full-file scan), stable across moves, and
    /// distinguishes near-identical PDFs by size.
    public static func fingerprint(of pdfURL: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: pdfURL) else {
            return nil
        }
        defer { try? handle.close() }
        let prefix = (try? handle.read(upToCount: 64 * 1024)) ?? Data()
        let attrs = try? FileManager.default.attributesOfItem(atPath: pdfURL.path)
        let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        // Inline SHA-256: avoids importing CryptoKit at the module
        // boundary (Pipeline doesn't link it for anything else yet).
        // Use Apple's CC_SHA256 from CommonCrypto.
        var digest = [UInt8](repeating: 0, count: 32)
        prefix.withUnsafeBytes { buf in
            _ = Self.sha256(buf, &digest)
        }
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "\(hex):\(size)"
    }

    /// Read the manifest; returns nil when the file doesn't exist
    /// or fails to decode (any reason → start fresh).
    public func readManifest() -> StagingManifest? {
        guard let data = try? Data(contentsOf: manifestURL) else { return nil }
        return try? JSONDecoder().decode(StagingManifest.self, from: data)
    }

    public func writeManifest(_ manifest: StagingManifest) throws {
        try FileManager.default.createDirectory(
            at: stagingDir, withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: manifestURL, options: .atomic)
    }

    /// Read a per-page checkpoint. Nil → page hasn't been done yet
    /// or its checkpoint file is corrupt; either way the pipeline
    /// should re-process the page.
    public func readCheckpoint(forPage page: Int) -> PageCheckpoint? {
        let url = checkpointURL(forPage: page)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PageCheckpoint.self, from: data)
    }

    /// Atomic per-page write — rename(2) over an existing checkpoint
    /// so a crash mid-write can't leave a half-flushed file the
    /// next run mistakes for valid.
    public func writeCheckpoint(_ checkpoint: PageCheckpoint) throws {
        try FileManager.default.createDirectory(
            at: stagingDir, withIntermediateDirectories: true
        )
        let url = checkpointURL(forPage: checkpoint.pageIndex)
        let encoder = JSONEncoder()
        let data = try encoder.encode(checkpoint)
        try data.write(to: url, options: .atomic)
    }

    /// Remove the staging directory entirely. Called once the EPUB
    /// has been written — the checkpoints have served their purpose
    /// and we don't want to leave stale data next to every PDF.
    public func deleteAll() {
        try? FileManager.default.removeItem(at: stagingDir)
    }

    /// Set of page indices for which we have a valid checkpoint on
    /// disk. Used by the pipeline to decide which pages to skip on
    /// resume.
    public func completedPages() -> Set<Int> {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            atPath: stagingDir.path
        ) else { return [] }
        var pages = Set<Int>()
        for name in entries {
            // Match `page-NNNNN.json`.
            guard name.hasPrefix("page-"), name.hasSuffix(".json") else {
                continue
            }
            let middle = name
                .dropFirst("page-".count)
                .dropLast(".json".count)
            if let idx = Int(middle) { pages.insert(idx) }
        }
        return pages
    }

    // MARK: - SHA-256

    /// Inline SHA-256 via CommonCrypto. Avoids pulling in CryptoKit
    /// (which Pipeline doesn't otherwise need); we just want a stable
    /// hash for the source-fingerprint comparison.
    private static func sha256(
        _ buffer: UnsafeRawBufferPointer,
        _ out: inout [UInt8]
    ) -> Bool {
        out.withUnsafeMutableBufferPointer { outBuf in
            CC_SHA256(buffer.baseAddress, CC_LONG(buffer.count), outBuf.baseAddress)
            return true
        }
    }
}

/// CommonCrypto SHA-256 declaration. Bridged via the system header
/// (CommonCrypto/CommonDigest.h); we declare the symbol inline so we
/// don't need a bridging header at the module level.
@_silgen_name("CC_SHA256")
private func CC_SHA256(
    _ data: UnsafeRawPointer?,
    _ len: CC_LONG,
    _ md: UnsafeMutablePointer<UInt8>?
) -> UnsafeMutablePointer<UInt8>?

private typealias CC_LONG = UInt32
