import ArgumentParser

/// Root `humanist-cli` command. Subcommands are the actual workhorses:
///
///   * `convert`  — turn any supported input into one or more output
///                  formats (EPUB, Markdown, plain text, HTML, DOCX,
///                  searchable PDF).
///   * `compare`  — diff two EPUBs at the chapter / paragraph level.
///   * `validate` — run epubcheck-equivalent validation on an EPUB.
///
/// Same engines as the SwiftUI app — the CLI just gives you scriptable
/// access to the conversion pipeline without the editor / queue / UI
/// surface.
@main
struct HumanistCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "humanist-cli",
        abstract: "Convert academic PDFs and rich documents into well-structured EPUB and friends.",
        version: "1.1.0",
        subcommands: [
            ConvertCommand.self,
            CompareCommand.self,
            ValidateCommand.self,
        ],
        defaultSubcommand: ConvertCommand.self
    )
}
