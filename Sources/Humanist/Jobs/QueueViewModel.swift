import Foundation
import AppKit
import Document
import OCR
import Pipeline

/// View-side wrapper around the queue. Owns the option pickers
/// (language, high-accuracy) so the launcher window can render them
/// the same way the old single-PDF flow did, and adds enqueue helpers
/// for "drop one PDF" vs. "drop a folder of PDFs."
@MainActor
final class QueueViewModel: ObservableObject {
    /// User-facing language choice. Identical shape to what the old
    /// `ConversionViewModel` used so the picker UI didn't have to
    /// change.
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

    @Published var selectedLanguageIds: Set<String> = ["en"]
    @Published var useHighAccuracyOCR: Bool = false

    let store: JobStore
    let runner: JobRunner
    /// True when the Tesseract binary was found on init. Drives the
    /// "Tesseract not installed" badge in the picker row.
    let tesseractAvailable: Bool

    init(store: JobStore, runner: JobRunner) {
        self.store = store
        self.runner = runner
        self.tesseractAvailable = (TesseractOCREngine.detect() != nil)
        // If a previous session left work in the queue, pick it up
        // automatically on launch.
        if store.hasPendingWork {
            runner.start()
        }
    }

    // MARK: - language picker mirror (same logic as ConversionViewModel)

    var selectedLanguages: [BCP47] {
        let selected = Self.supportedLanguages
            .filter { selectedLanguageIds.contains($0.id) }
            .map(\.language)
        return selected.isEmpty ? [.en] : selected
    }

    func isLanguageSelected(_ language: BCP47) -> Bool {
        selectedLanguageIds.contains(language.rawValue)
    }

    func toggleLanguage(_ language: BCP47) {
        if selectedLanguageIds.contains(language.rawValue) {
            guard selectedLanguageIds.count > 1 else { return }
            selectedLanguageIds.remove(language.rawValue)
        } else {
            selectedLanguageIds.insert(language.rawValue)
        }
    }

    var languageButtonLabel: String {
        let labels = Self.supportedLanguages
            .filter { selectedLanguageIds.contains($0.id) }
            .map(\.label)
        if labels.isEmpty { return "English" }
        if labels.count <= 3 { return labels.joined(separator: ", ") }
        return "\(labels.count) languages"
    }

    var willUseTesseract: Bool {
        PDFToEPUBPipeline.shouldPreferTesseract(for: selectedLanguages)
    }

    // MARK: - enqueue

    /// Add a single PDF to the queue. Output goes next to the source
    /// (`book.pdf` → `book.epub`); existing files at that path will be
    /// overwritten when the job runs.
    func addPDF(_ url: URL) {
        let outputURL = url.deletingPathExtension().appendingPathExtension("epub")
        let job = Job(
            sourceURL: url,
            outputURL: outputURL,
            options: ConversionOptions(
                languages: selectedLanguages.map { $0.rawValue },
                useHighAccuracyOCR: useHighAccuracyOCR
            )
        )
        store.add(job)
        runner.start()
    }

    /// Add every PDF inside `folder` (recursively). Hidden files,
    /// .DS_Store, and macOS package contents are skipped.
    func addFolder(_ folder: URL) {
        for pdf in Self.enumeratePDFs(in: folder) {
            addPDF(pdf)
        }
    }

    /// Add anything dropped — PDFs go straight in, folders get walked.
    /// Returns the count actually enqueued so the drop callback can
    /// decide whether to play a "nothing matched" beep (currently no-op).
    @discardableResult
    func addDropped(_ urls: [URL]) -> Int {
        var added = 0
        for url in urls {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                let before = store.jobs.count
                addFolder(url)
                added += store.jobs.count - before
            } else if url.pathExtension.lowercased() == "pdf" {
                addPDF(url)
                added += 1
            }
        }
        return added
    }

    static func enumeratePDFs(in folder: URL) -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        var out: [URL] = []
        for case let url as URL in enumerator {
            if url.pathExtension.lowercased() == "pdf" {
                out.append(url)
            }
        }
        return out.sorted { $0.path < $1.path }
    }

    // MARK: - convenience actions for the queue UI

    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        if panel.runModal() == .OK {
            addDropped(panel.urls)
        }
    }
}

