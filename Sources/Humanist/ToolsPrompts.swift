import Foundation
import AppKit
import EPUB
import PDFIngest
import Pipeline
import UniformTypeIdentifiers

/// File-system utilities — Join / Split for PDFs and EPUBs. Each
/// prompt is sync (NSOpenPanel + NSAlert + NSSavePanel chain) the
/// same way `TwoUpPrompt` is, since the user invoked the command
/// from a menu and expects modal behavior. No editor required.
enum ToolsPrompts {

    // MARK: - PDF Join

    /// Pick 2+ PDFs and write the concatenation to a chosen file.
    static func runJoinPDFs() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = "Pick the PDFs to join, in the order you want them combined."
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        guard urls.count >= 1 else {
            errorAlert(message: "Pick at least one PDF.")
            return
        }

        let save = NSSavePanel()
        save.allowedContentTypes = [.pdf]
        save.nameFieldStringValue = "joined.pdf"
        save.directoryURL = urls.first?.deletingLastPathComponent()
        guard save.runModal() == .OK, let outputURL = save.url else { return }

        do {
            let data = try PDFJoiner.join(urls: urls)
            try data.write(to: outputURL)
            successAlert(
                title: "PDFs joined",
                body: "Wrote \(urls.count) PDF\(urls.count == 1 ? "" : "s") to \(outputURL.lastPathComponent)."
            )
        } catch {
            errorAlert(message: error.localizedDescription)
        }
    }

    // MARK: - PDF Split

    /// Pick a PDF, ask for page ranges, write one PDF per range to a
    /// chosen output directory. Output filenames are `<source> Part N.pdf`.
    static func runSplitPDF() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK, let sourceURL = panel.url else { return }

        guard let rangesString = promptForRangeString(
            title: "Split \(sourceURL.lastPathComponent)",
            informativeText: "Enter page ranges, one per output file. e.g. \"1-50, 51-100, 101-150\" produces three PDFs.",
            placeholder: "1-50, 51-100"
        ) else { return }

        let ranges = PageRangeParser.parse(rangesString)
        guard !ranges.isEmpty else {
            errorAlert(message: "No valid page ranges parsed from “\(rangesString)”.")
            return
        }

        guard let outputDirectory = pickOutputDirectory(
            preferredDir: sourceURL.deletingLastPathComponent()
        ) else { return }

        let stem = sourceURL.deletingPathExtension().lastPathComponent
        do {
            let chunks = try PDFSplitter.split(url: sourceURL, ranges: ranges)
            var written = 0
            for (i, chunk) in chunks.enumerated() {
                let outName = "\(stem) Part \(i + 1).pdf"
                let outURL = outputDirectory.appendingPathComponent(outName)
                try chunk.data.write(to: outURL)
                written += 1
            }
            successAlert(
                title: "PDF split",
                body: "Wrote \(written) PDF\(written == 1 ? "" : "s") to \(outputDirectory.lastPathComponent)/."
            )
        } catch {
            errorAlert(message: error.localizedDescription)
        }
    }

    // MARK: - EPUB Join

    /// Pick 2+ EPUBs and write a single combined EPUB.
    static func runJoinEPUBs() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.epub]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = "Pick the EPUBs to join, in the order you want them combined. Source #1's title and author will be used."
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        guard urls.count >= 1 else {
            errorAlert(message: "Pick at least one EPUB.")
            return
        }

        let save = NSSavePanel()
        save.allowedContentTypes = [.epub]
        save.nameFieldStringValue = "joined.epub"
        save.directoryURL = urls.first?.deletingLastPathComponent()
        guard save.runModal() == .OK, let outputURL = save.url else { return }

        do {
            let result = try EPUBJoiner().join(
                sourceURLs: urls, outputURL: outputURL, title: nil
            )
            successAlert(
                title: "EPUBs joined",
                body: "Wrote \(result.chapterCount) chapter\(result.chapterCount == 1 ? "" : "s") from \(result.sourceCount) source EPUB\(result.sourceCount == 1 ? "" : "s") to \(outputURL.lastPathComponent)."
            )
        } catch {
            errorAlert(message: error.localizedDescription)
        }
    }

    // MARK: - EPUB Split

    /// Pick an EPUB, ask for chapter ranges, write one EPUB per range
    /// to a chosen output directory.
    static func runSplitEPUB() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.epub]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK, let sourceURL = panel.url else { return }

        guard let rangesString = promptForRangeString(
            title: "Split \(sourceURL.lastPathComponent)",
            informativeText: "Enter chapter ranges, one per output file. Chapter numbers are 1-based, in spine order. e.g. \"1-5, 6-10\" produces two EPUBs.",
            placeholder: "1-5, 6-10"
        ) else { return }

        let ranges = PageRangeParser.parse(rangesString)
        guard !ranges.isEmpty else {
            errorAlert(message: "No valid chapter ranges parsed from “\(rangesString)”.")
            return
        }

        guard let outputDirectory = pickOutputDirectory(
            preferredDir: sourceURL.deletingLastPathComponent()
        ) else { return }

        let parts = ranges.map { range in
            EPUBSplitter.Part(chapterIndexes: Array(range))
        }
        do {
            let result = try EPUBSplitter().split(
                sourceURL: sourceURL,
                outputDirectory: outputDirectory,
                parts: parts
            )
            successAlert(
                title: "EPUB split",
                body: "Wrote \(result.outputURLs.count) part\(result.outputURLs.count == 1 ? "" : "s") covering \(result.totalChapters) chapter\(result.totalChapters == 1 ? "" : "s") to \(outputDirectory.lastPathComponent)/."
            )
        } catch {
            errorAlert(message: error.localizedDescription)
        }
    }

    // MARK: - Compare EPUBs (O-Diff)

    /// Pick exactly two EPUBs, run the differ, stash the result on
    /// the presenter, and post a notification so the diff window
    /// scene can openWindow itself. (Direct openWindow access from
    /// a menu callback isn't available here — the launcher window's
    /// scene posts on receipt.)
    @MainActor
    static func runDiffEPUBs() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.epub]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = "Pick exactly two EPUBs to compare. The first you pick is the “left”; the second is the “right”."
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        guard urls.count == 2 else {
            errorAlert(message: "Pick exactly two EPUB files (you picked \(urls.count)).")
            return
        }

        do {
            let diff = try EPUBDiffer().diff(
                leftURL: urls[0], rightURL: urls[1]
            )
            EPUBDiffPresenter.shared.present(diff)
            NotificationCenter.default.post(
                name: .humanistShowEPUBDiff, object: nil
            )
        } catch {
            errorAlert(message: error.localizedDescription)
        }
    }

    // MARK: - Shared helpers

    /// NSAlert with an NSTextField accessory view. Returns the entered
    /// string on OK, nil on Cancel.
    private static func promptForRangeString(
        title: String,
        informativeText: String,
        placeholder: String
    ) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = informativeText
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = placeholder
        alert.accessoryView = field
        // Give the field initial focus so the user can just type.
        alert.window.initialFirstResponder = field
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return nil }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func pickOutputDirectory(preferredDir: URL?) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose where to save the output files."
        panel.prompt = "Choose"
        if let preferredDir { panel.directoryURL = preferredDir }
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    private static func successAlert(title: String, body: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.runModal()
    }

    private static func errorAlert(message: String) {
        let alert = NSAlert()
        alert.messageText = "Tool failed"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
