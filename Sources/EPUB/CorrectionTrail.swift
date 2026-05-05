import Foundation

/// Editor-only sidecar capturing every post-OCR Haiku correction the
/// pipeline considered for this book. Written by `EPUBBuilder` when
/// the conversion produced any trail entries; read by the editor's
/// "Correction Trail" panel on open. Standard EPUB readers ignore
/// unknown META-INF files, so the sidecar round-trips through other
/// tools cleanly.
///
/// Entries cover **both** accepted corrections (the suggested text is
/// in the XHTML, original is preserved here so the user can revert)
/// and rejected corrections (the original text is in the XHTML, the
/// guardrail-rejected suggestion is preserved here so the user can
/// apply it manually if they disagreed with the guardrail). The
/// `accepted` flag distinguishes the two.
public struct CorrectionTrail: Sendable, Equatable, Codable {
    public var entries: [Entry]

    public struct Entry: Sendable, Equatable, Codable, Identifiable {
        /// Stable identifier so the editor's SwiftUI list uses a
        /// proper Identifiable identity even after re-decoding.
        public var id: UUID
        /// Zero-based PDF page index. Pairs with `PageMap.Entry.pdfPage`
        /// for joining trail entries to their XHTML file.
        public var pageIndex: Int
        /// Zero-based region index within the page, in reading order.
        /// Used to sort entries within a page in the trail UI.
        public var regionIndex: Int
        /// Page anchor ID (`hu-page-N`). Joins with
        /// `PageMap.Entry.anchorId` to find the XHTML file the
        /// correction lives in.
        public var anchorId: String
        /// OCR text before Haiku ran. The "revert target" for
        /// accepted entries; the "current state" for rejected entries.
        public var original: String
        /// Haiku's proposed correction. The "current state" for
        /// accepted entries; the "apply target" for rejected entries.
        public var suggested: String
        /// True when `OCRChangeGuardrail` accepted the suggestion and
        /// the pipeline replaced the region's observations with it.
        /// False when the guardrail rejected — original stayed.
        public var accepted: Bool
        /// String-encoded rejection reason when `accepted == false`.
        /// Carried as a string (rather than the enum directly) so the
        /// trail format stays stable across guardrail-enum case
        /// additions and renames.
        public var rejectionReason: String?
        /// `"passages"` for text-only correction or `"vision"` when
        /// Haiku was given the rendered region image. Surface in the
        /// UI so the user understands why a particular suggestion
        /// looks the way it does.
        public var mode: String

        public init(
            id: UUID = UUID(),
            pageIndex: Int,
            regionIndex: Int,
            anchorId: String,
            original: String,
            suggested: String,
            accepted: Bool,
            rejectionReason: String? = nil,
            mode: String
        ) {
            self.id = id
            self.pageIndex = pageIndex
            self.regionIndex = regionIndex
            self.anchorId = anchorId
            self.original = original
            self.suggested = suggested
            self.accepted = accepted
            self.rejectionReason = rejectionReason
            self.mode = mode
        }
    }

    public init(entries: [Entry]) {
        self.entries = entries
    }

    /// Path of the sidecar inside an unpacked EPUB working directory.
    public static let pathInsideEPUB = "META-INF/com.humanist.correction-trail.json"

    /// Read the trail from a working directory. Returns nil when the
    /// file is missing — books that didn't go through the cleanup
    /// pass (or older EPUBs predating the trail feature) get no
    /// trail panel.
    public static func read(workingDirectory: URL) -> CorrectionTrail? {
        let url = workingDirectory.appendingPathComponent(pathInsideEPUB)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CorrectionTrail.self, from: data)
    }
}
