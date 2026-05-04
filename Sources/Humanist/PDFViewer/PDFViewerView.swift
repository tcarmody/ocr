import SwiftUI
import AppKit
import PDFKit

/// Standalone PDF viewer window. Two-pane: thumbnail sidebar +
/// main page view. Used when the user opens a PDF without an
/// associated EPUB; the editor's embedded PDF pane shares the
/// underlying `PDFViewerController`.
struct PDFViewerView: View {
    let pdfURL: URL

    @StateObject private var controller: PDFViewerController

    init(pdfURL: URL) {
        self.pdfURL = pdfURL
        _controller = StateObject(wrappedValue: PDFViewerController(pdfURL: pdfURL))
    }

    var body: some View {
        Group {
            if let document = controller.document {
                NavigationSplitView {
                    PDFThumbnailSidebar(pdfView: controller.pdfView)
                        .frame(minWidth: 140, idealWidth: 160, maxWidth: 220)
                } detail: {
                    PDFKitView(pdfView: controller.pdfView)
                        .background(Color(nsColor: .underPageBackgroundColor))
                        .frame(minWidth: 480, minHeight: 480)
                }
                .navigationTitle(pdfURL.lastPathComponent)
                .navigationSubtitle("\(document.pageCount) page\(document.pageCount == 1 ? "" : "s")")
                .toolbar { toolbarContent }
            } else if let error = controller.errorMessage {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(.orange)
                    Text("Could not open PDF").font(.headline)
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                ProgressView("Opening \(pdfURL.lastPathComponent)…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 720, minHeight: 540)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button {
                controller.pdfView.goToPreviousPage(nil)
            } label: { Label("Previous Page", systemImage: "chevron.left") }
                .keyboardShortcut(.leftArrow, modifiers: .command)
            Button {
                controller.pdfView.goToNextPage(nil)
            } label: { Label("Next Page", systemImage: "chevron.right") }
                .keyboardShortcut(.rightArrow, modifiers: .command)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                controller.pdfView.zoomOut(nil)
            } label: { Label("Zoom Out", systemImage: "minus.magnifyingglass") }
                .keyboardShortcut("-", modifiers: .command)
            Button {
                controller.pdfView.zoomIn(nil)
            } label: { Label("Zoom In", systemImage: "plus.magnifyingglass") }
                .keyboardShortcut("=", modifiers: .command)
            Button {
                controller.fitPage()
            } label: { Label("Fit Page", systemImage: "rectangle.arrowtriangle.2.inward") }
                .keyboardShortcut("0", modifiers: .command)
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([pdfURL])
            } label: { Label("Reveal in Finder", systemImage: "folder") }
        }
    }
}
