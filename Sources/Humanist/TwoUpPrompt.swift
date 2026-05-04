import Foundation
import AppKit
import PDFIngest

/// UI glue for the manual `File > Split Two-Up PDF…` command. The
/// drop-time two-up flow lives in `TwoUpProcessor` (async with
/// progress sheet); this stays sync because the user already
/// invoked it from a menu and expects modal behavior.
enum TwoUpPrompt {
    /// Run the splitter unconditionally for a manually-chosen PDF
    /// (File > Split Two-Up PDF…). Asks the user where to save the
    /// output. Returns the output URL on success, nil on user cancel
    /// or write failure (an error alert is shown for failures).
    static func runManual(pdfURL: URL) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = pdfURL
            .deletingPathExtension()
            .lastPathComponent + ".split.pdf"
        panel.directoryURL = pdfURL.deletingLastPathComponent()
        guard panel.runModal() == .OK, let outputURL = panel.url else {
            return nil
        }
        do {
            let counts = try TwoUpSplitter.split(pdfURL: pdfURL, outputURL: outputURL)
            // Confirm to the user — the manual command has no other
            // visible feedback otherwise.
            let done = NSAlert()
            done.messageText = "Split complete"
            done.informativeText = "Wrote \(counts.outputPages) page(s) "
                + "(\(counts.splitSources) source page(s) split) to "
                + outputURL.lastPathComponent + "."
            done.runModal()
            return outputURL
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not split \(pdfURL.lastPathComponent)"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return nil
        }
    }
}
