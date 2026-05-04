import SwiftUI
import AppKit
import PDFKit

/// Owns a PDFKit `PDFView` for one open PDF and exposes it for both
/// the standalone viewer window and the editor's embedded PDF pane.
/// Wrapping in an `ObservableObject` keeps the view's scroll/zoom
/// state alive across SwiftUI body re-evaluations and pane toggles.
@MainActor
final class PDFViewerController: ObservableObject {
    let pdfView: PDFView
    @Published private(set) var document: PDFDocument?
    @Published private(set) var errorMessage: String?

    init(pdfURL: URL) {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.backgroundColor = NSColor.underPageBackgroundColor
        self.pdfView = view

        if let doc = PDFDocument(url: pdfURL) {
            view.document = doc
            self.document = doc
        } else {
            self.errorMessage = "PDFKit could not parse the file."
        }
    }

    func fitPage() {
        pdfView.scaleFactor = pdfView.scaleFactorForSizeToFit
    }
}

/// SwiftUI representable for the PDF surface. Recreating this view
/// across body evaluations is fine — the underlying `PDFView` lives in
/// the controller and is reused.
struct PDFKitView: NSViewRepresentable {
    let pdfView: PDFView
    func makeNSView(context: Context) -> PDFView { pdfView }
    func updateNSView(_ nsView: PDFView, context: Context) {}
}

/// Sidebar of page thumbnails. Bound to a controller's `pdfView` so
/// clicks on a thumbnail navigate the same surface.
struct PDFThumbnailSidebar: NSViewRepresentable {
    let pdfView: PDFView

    func makeNSView(context: Context) -> PDFThumbnailView {
        let v = PDFThumbnailView()
        v.pdfView = pdfView
        v.thumbnailSize = NSSize(width: 110, height: 140)
        v.backgroundColor = NSColor.windowBackgroundColor
        return v
    }

    func updateNSView(_ nsView: PDFThumbnailView, context: Context) {
        // PDFThumbnailView keeps its own ref to pdfView; nothing to update.
    }
}
