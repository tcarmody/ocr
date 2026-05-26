import ArgumentParser

/// Root `humanist-cli` command. Subcommands are the actual workhorses:
///
///   * `convert`         — turn any supported input into one or more
///                         output formats (EPUB, Markdown, plain
///                         text, HTML, DOCX, searchable PDF).
///   * `compare`         — diff two EPUBs at the chapter / paragraph
///                         level.
///   * `compare-corpus`  — walk a directory of paired PDF + reference
///                         EPUBs (publisher-edited; e.g. O'Reilly),
///                         convert each PDF, and report regression
///                         metrics. Local-only quality harness.
///   * `validate`        — run epubcheck-equivalent validation on an
///                         EPUB.
///
/// Same engines as the SwiftUI app — the CLI just gives you scriptable
/// access to the conversion pipeline without the editor / queue / UI
/// surface.
@main
struct HumanistCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "humanist-cli",
        abstract: "Convert academic PDFs and rich documents into well-structured EPUB and friends.",
        version: "1.2.0",
        subcommands: [
            ConvertCommand.self,
            CompareCommand.self,
            CompareCorpusCommand.self,
            ValidateCommand.self,
            LibraryDedupeCommand.self,
            ClearOutdatedCommand.self,
            ReindexCommand.self,
            RefreshEntityIndexCommand.self,
        ],
        defaultSubcommand: ConvertCommand.self
    )
}
