import Foundation
import ArgumentParser
import EPUB

/// `humanist-cli validate <epub>` — run `epubcheck` against an EPUB
/// and surface its messages. Wraps the same `EPUBValidator` that
/// powers Tools → Validate EPUB in the SwiftUI app.
///
/// Exit codes:
///   0 — passed (no FATAL or ERROR messages)
///   1 — failed validation (one or more FATAL/ERROR)
///   2 — `epubcheck` not installed (suggest `brew install epubcheck`)
struct ValidateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "validate",
        abstract: "Run epubcheck against an EPUB and report any issues."
    )

    @Argument(help: "Path to the EPUB to validate.")
    var input: String

    @Flag(name: .long, help: "Emit a JSON report on stdout instead of formatted text.")
    var json: Bool = false

    @Flag(name: .long, help: "Suppress non-error messages (warnings, info, usage).")
    var errorsOnly: Bool = false

    func run() async throws {
        let url = URL(fileURLWithPath: input).standardizedFileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ValidationError("EPUB not found: \(input)")
        }

        guard EPUBValidator.detect() != nil else {
            FileHandle.standardError.write(Data(
                "epubcheck not installed. Install with `brew install epubcheck` (requires a Java runtime).\n".utf8
            ))
            throw ExitCode(2)
        }

        let report: EPUBValidator.Report
        do {
            report = try EPUBValidator().validate(epubURL: url)
        } catch let err as EPUBValidator.ValidatorError {
            FileHandle.standardError.write(
                Data(("epubcheck failed: \(err.localizedDescription)\n").utf8)
            )
            throw ExitCode(2)
        }

        let messages = errorsOnly
            ? report.messages.filter { $0.severity == .error || $0.severity == .fatal }
            : report.messages

        if json {
            try emitJSON(report: report, filtered: messages)
        } else {
            emitText(report: report, filtered: messages, errorsOnly: errorsOnly)
        }

        if !report.passed {
            throw ExitCode(1)
        }
    }

    private func emitText(
        report: EPUBValidator.Report,
        filtered: [EPUBValidator.Message],
        errorsOnly: Bool
    ) {
        for message in filtered.sorted(by: messageSort) {
            let severity = message.severity.rawValue.uppercased()
            var line = "\(severity)  \(message.code)  \(message.message)"
            if let path = message.path, !path.isEmpty {
                line += "  [\(path)\(message.line.map { ":\($0)" } ?? "")]"
            }
            print(line)
        }

        // Summary line on stderr so it's separate from the per-message
        // body that scripts might pipe through grep.
        var parts: [String] = []
        for severity in EPUBValidator.Severity.allCases.sorted(by: { $0.sortWeight > $1.sortWeight }) {
            if let count = report.counts[severity], count > 0 {
                parts.append("\(count) \(severity.rawValue)")
            }
        }
        let summary = parts.isEmpty
            ? "epubcheck: no messages."
            : "epubcheck: \(parts.joined(separator: ", ")) — \(report.passed ? "PASSED" : "FAILED")"
        FileHandle.standardError.write(Data((summary + "\n").utf8))
    }

    private func emitJSON(
        report: EPUBValidator.Report,
        filtered: [EPUBValidator.Message]
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        struct Output: Encodable {
            let passed: Bool
            let counts: [String: Int]
            let messages: [EPUBValidator.Message]
        }
        let body = Output(
            passed: report.passed,
            counts: Dictionary(
                uniqueKeysWithValues: report.counts.map { ($0.key.rawValue, $0.value) }
            ),
            messages: filtered
        )
        let data = try encoder.encode(body)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    private func messageSort(
        _ a: EPUBValidator.Message, _ b: EPUBValidator.Message
    ) -> Bool {
        if a.severity.sortWeight != b.severity.sortWeight {
            return a.severity.sortWeight > b.severity.sortWeight
        }
        return (a.path ?? "") < (b.path ?? "")
    }
}
