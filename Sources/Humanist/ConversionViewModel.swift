import Foundation
import AppKit
import Document
import OCR
import Pipeline

@MainActor
final class ConversionViewModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case running(completed: Int, total: Int)
        case done(outputURL: URL)
        case failed(message: String)
    }

    /// User-facing language choice. The picker shows `label`; the
    /// pipeline routes on `language` (modern Latin → Vision, ancient
    /// or non-Latin → Tesseract when available).
    struct LanguageOption: Identifiable, Hashable {
        let id: String
        let language: BCP47
        let label: String
        init(_ language: BCP47, _ label: String) {
            self.id = language.rawValue
            self.language = language
            self.label = label
        }
    }

    static let supportedLanguages: [LanguageOption] = [
        .init(.en,         "English"),
        .init(.fr,         "French"),
        .init(.de,         "German"),
        .init(.it,         "Italian"),
        .init(.es,         "Spanish"),
        .init(.grc,        "Ancient Greek (polytonic)"),
        .init(.la,         "Latin"),
        .init("he",        "Hebrew"),
        .init("ar",        "Arabic"),
        .init("ru",        "Russian"),
    ]

    @Published var phase: Phase = .idle
    @Published var lastConfidence: Double = .nan
    @Published var sourceName: String = ""
    @Published var selectedLanguage: BCP47 = .en

    /// True when the Tesseract binary was found on init. Used by the UI
    /// to warn before the user picks an ancient/non-Latin language and
    /// gets surprised by Vision-quality output.
    let tesseractAvailable: Bool

    private var task: Task<Void, Never>?

    init() {
        self.tesseractAvailable = (TesseractOCREngine.detect() != nil)
    }

    func convert(pdfURL: URL) {
        task?.cancel()
        sourceName = pdfURL.lastPathComponent
        phase = .running(completed: 0, total: 0)
        lastConfidence = .nan

        let outputURL = pdfURL
            .deletingPathExtension()
            .appendingPathExtension("epub")
        let language = selectedLanguage

        task = Task { [weak self] in
            let pipeline = PDFToEPUBPipeline()
            do {
                try await pipeline.convert(
                    pdfURL: pdfURL,
                    outputURL: outputURL,
                    options: .init(languages: [language]),
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
