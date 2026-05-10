import Foundation
import PDFKit

public enum PDFIngestError: Error, LocalizedError {
    case cannotOpen(URL)
    case pageOutOfRange(Int, count: Int)
    case renderFailed(pageIndex: Int)

    public var errorDescription: String? {
        switch self {
        case .cannotOpen(let u):       return "PDFKit could not open \(u.path)"
        case .pageOutOfRange(let i, let n): return "Page \(i) out of range (count \(n))"
        case .renderFailed(let i):     return "Failed to render page \(i)"
        }
    }
}

/// A loaded PDF, suitable for handing to a renderer / OCR engine.
///
/// Marked `@unchecked Sendable` so it can be referenced across actor
/// boundaries in the pipeline (the `async let` per-page concurrency
/// in `PDFToEPUBPipeline.convert`, and the TaskGroup in the page-OCR
/// path). The invariant defending the assertion:
///
///   * The class's stored properties are all `let` (immutable after
///     init), so the Swift-level binding is race-free.
///   * Every PDFKit call (`document.page(at:)`, render via
///     `PDFRenderer`) runs on the `PDFToEPUBPipeline` actor's
///     serializing executor. The actor's `async let` and TaskGroup
///     children share that executor — only one PDFKit access runs
///     at a time even when child tasks logically execute "in parallel"
///     (they cooperatively yield through the actor).
///
/// `PDFDocument` itself isn't documented as thread-safe; future code
/// touching `document` from outside the pipeline actor's isolation
/// must preserve this single-executor invariant or wrap PDFKit access
/// in a dedicated actor.
public final class LoadedPDF: @unchecked Sendable {
    public let url: URL
    public let document: PDFDocument
    public let pageCount: Int
    public let title: String?

    init(url: URL, document: PDFDocument) {
        self.url = url
        self.document = document
        self.pageCount = document.pageCount
        self.title = (document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty
    }
}

public struct PDFLoader {
    public init() {}

    public func load(_ url: URL) throws -> LoadedPDF {
        guard let doc = PDFDocument(url: url), doc.pageCount > 0 else {
            throw PDFIngestError.cannotOpen(url)
        }
        return LoadedPDF(url: url, document: doc)
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
