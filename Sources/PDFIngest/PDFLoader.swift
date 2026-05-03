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
/// Not Sendable — PDFKit's `PDFDocument` is not. Hold this on a single task.
public final class LoadedPDF {
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
