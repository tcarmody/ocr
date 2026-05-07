import Foundation
import PDFKit

/// Concatenates multiple PDF files into a single PDF in input order.
/// Used by the Tools → PDF → Join command. Pure file-level operation
/// — doesn't touch the OCR pipeline.
public enum PDFJoiner {

    public enum JoinError: Error, LocalizedError {
        case noInput
        case invalidPDF(URL)
        case encodeFailed

        public var errorDescription: String? {
            switch self {
            case .noInput:
                return "Pick at least one PDF to join."
            case .invalidPDF(let url):
                return "Couldn't open \(url.lastPathComponent) as a PDF."
            case .encodeFailed:
                return "Couldn't encode the merged PDF."
            }
        }
    }

    /// Join `urls` into one PDF and return its bytes. Pages are
    /// appended in the order the URLs are passed.
    public static func join(urls: [URL]) throws -> Data {
        guard !urls.isEmpty else { throw JoinError.noInput }
        let merged = PDFDocument()
        var insertIdx = 0
        for url in urls {
            guard let doc = PDFDocument(url: url) else {
                throw JoinError.invalidPDF(url)
            }
            for i in 0..<doc.pageCount {
                guard let page = doc.page(at: i) else { continue }
                merged.insert(page, at: insertIdx)
                insertIdx += 1
            }
        }
        guard let data = merged.dataRepresentation() else {
            throw JoinError.encodeFailed
        }
        return data
    }
}
