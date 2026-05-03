import Foundation
import AppKit
import Document
import Pipeline

@MainActor
final class ConversionViewModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case running(completed: Int, total: Int)
        case done(outputURL: URL)
        case failed(message: String)
    }

    @Published var phase: Phase = .idle
    @Published var lastConfidence: Double = .nan
    @Published var sourceName: String = ""

    private var task: Task<Void, Never>?

    func convert(pdfURL: URL) {
        task?.cancel()
        sourceName = pdfURL.lastPathComponent
        phase = .running(completed: 0, total: 0)
        lastConfidence = .nan

        let outputURL = pdfURL
            .deletingPathExtension()
            .appendingPathExtension("epub")

        task = Task { [weak self] in
            let pipeline = PDFToEPUBPipeline()
            do {
                try await pipeline.convert(
                    pdfURL: pdfURL,
                    outputURL: outputURL,
                    options: .init(),
                    progress: { [weak self] p in
                        Task { @MainActor in
                            guard let self else { return }
                            self.phase = .running(completed: p.completedPages, total: p.totalPages)
                            self.lastConfidence = p.currentPageMeanConfidence
                        }
                    }
                )
                guard let self else { return }
                self.phase = .done(outputURL: outputURL)
            } catch is CancellationError {
                guard let self else { return }
                self.phase = .idle
            } catch {
                guard let self else { return }
                self.phase = .failed(message: error.localizedDescription)
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        phase = .idle
    }

    func revealOutput() {
        guard case let .done(url) = phase else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if panel.runModal() == .OK, let url = panel.url {
            convert(pdfURL: url)
        }
    }
}
