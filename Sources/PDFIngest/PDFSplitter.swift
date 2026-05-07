import Foundation
import PDFKit

/// Splits a single PDF into multiple PDFs by page range. Used by
/// the Tools → PDF → Split command. Reuses the same 1-based,
/// inclusive page-range semantics as `PageRangeParser` so the input
/// shape matches what users already see in "Force OCR pages:".
public enum PDFSplitter {

    public enum SplitError: Error, LocalizedError {
        case invalidPDF
        case emptyRanges
        case rangeOutOfBounds(ClosedRange<Int>, pageCount: Int)
        case encodeFailed(ClosedRange<Int>)

        public var errorDescription: String? {
            switch self {
            case .invalidPDF:
                return "Couldn't open the PDF."
            case .emptyRanges:
                return "No page ranges supplied."
            case .rangeOutOfBounds(let r, let pc):
                // Display 1-based page numbers in the user-facing message.
                return "Range \(r.lowerBound + 1)–\(r.upperBound + 1) is outside the PDF (which has \(pc) pages)."
            case .encodeFailed(let r):
                return "Couldn't encode the PDF chunk for pages \(r.lowerBound + 1)–\(r.upperBound + 1)."
            }
        }
    }

    public struct Chunk {
        /// Original 0-based, inclusive page range. Same form
        /// `PageRangeParser` produces.
        public let range: ClosedRange<Int>
        public let data: Data
    }

    /// Split `url` into chunks, one per range. Ranges are 0-based,
    /// inclusive (matching `PageRangeParser`); they may overlap, be
    /// out of order, or duplicate pages — the caller decides what
    /// makes sense. Out-of-bounds ranges throw.
    public static func split(
        url: URL,
        ranges: [ClosedRange<Int>]
    ) throws -> [Chunk] {
        guard !ranges.isEmpty else { throw SplitError.emptyRanges }
        guard let source = PDFDocument(url: url) else {
            throw SplitError.invalidPDF
        }
        let pageCount = source.pageCount
        var chunks: [Chunk] = []
        for range in ranges {
            guard range.lowerBound >= 0, range.upperBound < pageCount,
                  range.lowerBound <= range.upperBound
            else {
                throw SplitError.rangeOutOfBounds(range, pageCount: pageCount)
            }
            let chunk = PDFDocument()
            var insertIdx = 0
            for pageIdx in range {
                guard let page = source.page(at: pageIdx) else { continue }
                chunk.insert(page, at: insertIdx)
                insertIdx += 1
            }
            guard let data = chunk.dataRepresentation() else {
                throw SplitError.encodeFailed(range)
            }
            chunks.append(Chunk(range: range, data: data))
        }
        return chunks
    }
}
