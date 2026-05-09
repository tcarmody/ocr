import Foundation
import Pipeline

/// CLI progress reporter. Three modes:
///
///   * `default` — TTY-aware: live-updating single line on a TTY,
///                 plain line-by-line on a pipe / file.
///   * `quiet`   — only errors to stderr; no progress noise.
///   * `json`    — newline-delimited JSON events on stdout, one
///                 `{"event":"...", ...}` per line. For scripts and CI.
struct ProgressReporter: Sendable {
    enum Mode: String, Sendable { case `default`, quiet, json, verbose }

    let mode: Mode
    let isTTY: Bool

    init(mode: Mode) {
        self.mode = mode
        // Interactive TTY → use carriage-return single-line update.
        // Non-TTY (piped, redirected, CI) → line-by-line so logs
        // capture cleanly.
        self.isTTY = isatty(fileno(stdout)) != 0
    }

    func handle(_ progress: PDFToEPUBPipeline.Progress) {
        switch mode {
        case .quiet:
            return
        case .json:
            emitJSON([
                "event": "page",
                "completed": progress.completedPages,
                "total": progress.totalPages,
                "confidence": (progress.currentPageMeanConfidence.isNaN ? nil : progress.currentPageMeanConfidence) as Any,
            ])
        case .default, .verbose:
            let line = "[\(progress.completedPages)/\(progress.totalPages)] page \(progress.completedPages)" +
                ((progress.currentPageMeanConfidence.isNaN ? nil : progress.currentPageMeanConfidence).map { String(format: " · conf %.2f", $0) } ?? "")
            if isTTY {
                // Carriage-return overwrite for live single-line update.
                FileHandle.standardError.write(Data(("\r\(line)\u{1B}[K").utf8))
            } else {
                FileHandle.standardError.write(Data((line + "\n").utf8))
            }
        }
    }

    /// Print a one-shot status line (e.g. "Detected: PDF, 42 pages, English").
    func note(_ text: String) {
        switch mode {
        case .quiet: return
        case .json:
            emitJSON(["event": "note", "message": text])
        case .default, .verbose:
            FileHandle.standardError.write(Data((text + "\n").utf8))
        }
    }

    /// Print a "wrote file X (size)" line.
    func wrote(_ url: URL) {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        let formatted = ByteCountFormatter.string(
            fromByteCount: Int64(size), countStyle: .file
        )
        switch mode {
        case .quiet: return
        case .json:
            emitJSON([
                "event": "wrote",
                "path": url.path,
                "bytes": size,
            ])
        case .default, .verbose:
            FileHandle.standardError.write(
                Data(("Wrote \(url.path) (\(formatted))\n").utf8)
            )
        }
    }

    /// Final summary at the end of a successful run.
    func summary(stats: ConversionStats?) {
        switch mode {
        case .quiet: return
        case .json:
            var dict: [String: Any] = ["event": "done"]
            if let s = stats {
                dict["claudeCallCount"] = s.claudeCallCount
                dict["estimatedCostUSD"] = s.estimatedCostUSD
                dict["pagesTrustedEmbeddedText"] = s.pagesTrustedEmbeddedText
            }
            emitJSON(dict)
        case .default, .verbose:
            // Clear the live progress line if we used carriage return.
            if isTTY { FileHandle.standardError.write(Data("\r\u{1B}[K".utf8)) }
            if let s = stats {
                let cost = String(format: "%.4f", s.estimatedCostUSD)
                let line = "Done: \(s.claudeCallCount) Claude calls, ~$\(cost)"
                FileHandle.standardError.write(Data((line + "\n").utf8))
            } else {
                FileHandle.standardError.write(Data("Done.\n".utf8))
            }
        }
    }

    /// Print an error (always to stderr, regardless of mode).
    func error(_ message: String) {
        if mode == .json {
            emitJSON(["event": "error", "message": message])
        } else {
            FileHandle.standardError.write(Data(("Error: \(message)\n").utf8))
        }
    }

    private func emitJSON(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(
            withJSONObject: dict.compactMapValues { $0 }, options: [.sortedKeys]
        ) else { return }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}
