import Foundation
import ArgumentParser
import EPUB

/// `humanist-cli compare <left> <right>` — diff two EPUBs at the
/// chapter/paragraph level. Mirrors Tools → Compare EPUBs… in the
/// SwiftUI app, but emits the unified-diff text report directly to
/// stdout (or to `--output` if specified). Useful in scripts and
/// CI for "did this conversion change?" checks.
struct CompareCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "compare",
        abstract: "Diff two EPUBs at the chapter / paragraph level."
    )

    @Argument(help: "First EPUB (the \"old\" / \"left\" side).")
    var left: String

    @Argument(help: "Second EPUB (the \"new\" / \"right\" side).")
    var right: String

    @Option(name: [.short, .customLong("output")],
            help: "Write the report to this path instead of stdout.")
    var outputPath: String?

    @Flag(name: .long, help: "Print only the one-line summary, suppress per-chapter detail.")
    var summaryOnly: Bool = false

    func run() async throws {
        let leftURL  = URL(fileURLWithPath: left).standardizedFileURL
        let rightURL = URL(fileURLWithPath: right).standardizedFileURL
        guard FileManager.default.fileExists(atPath: leftURL.path) else {
            throw ValidationError("Left EPUB not found: \(left)")
        }
        guard FileManager.default.fileExists(atPath: rightURL.path) else {
            throw ValidationError("Right EPUB not found: \(right)")
        }

        let diff = try EPUBDiffer().diff(leftURL: leftURL, rightURL: rightURL)
        let report = summaryOnly
            ? EPUBDiffReporter.summary(diff)
            : EPUBDiffReporter.report(diff)

        if let outputPath {
            let url = URL(fileURLWithPath: outputPath)
            try report.write(to: url, atomically: true, encoding: .utf8)
            FileHandle.standardError.write(Data("Wrote \(url.path)\n".utf8))
        } else {
            print(report)
        }

        // Non-zero exit when there are differences — useful for `git
        // diff`-style scripting where the caller cares whether
        // anything changed.
        if diff.totalChanges > 0 {
            throw ExitCode(1)
        }
    }
}
