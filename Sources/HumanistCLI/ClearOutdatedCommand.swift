import Foundation
import ArgumentParser
import AI
import LibraryIndexing

/// `humanist-cli clear-outdated --backend <choice>` — surgical
/// alternative to "Clear all" in Settings. Deletes every embedding
/// sidecar whose `backendIdentifier` doesn't start with the chosen
/// backend's namespace prefix (e.g. `gemini.`), so the next
/// `humanist-cli reindex` / Library window "Build Missing Indexes"
/// retries just those books against the current backend.
///
/// Use case: user switched to a cloud backend (Gemini, Voyage) and
/// has books that earlier indexed against the Apple-NL safety net
/// (the cloud call errored at index time, or the books are legacy
/// pre-switch). After fixing the API key / restoring quota, this
/// command surfaces and clears the outdated sidecars without
/// touching the ones that ARE on the chosen backend.
///
/// Dry-run by default; `--apply` actually deletes. Same posture as
/// `library-dedupe` — the report is the deliverable; destructive
/// step is opt-in.
struct ClearOutdatedCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clear-outdated",
        abstract: "Delete embedding sidecars whose backend doesn't match the current primary."
    )

    @Option(
        name: .shortAndLong,
        help: ArgumentHelp(
            "Current primary embedding backend. Sidecars from any other backend are considered outdated.",
            valueName: "apple|ollama|voyage|gemini"
        )
    )
    var backend: BackendChoice

    @Flag(
        name: .long,
        help: "Actually delete the outdated sidecars. Without this flag, prints the count + sample only."
    )
    var apply: Bool = false

    @Option(
        name: .long,
        help: "Override the embeddings storage root. Defaults to ~/Library/Application Support/Humanist/Embeddings/."
    )
    var storeRoot: String?

    func run() async throws {
        let storeURL = resolveStoreURL()
        guard FileManager.default.fileExists(atPath: storeURL.path) else {
            print("No embeddings cache at \(storeURL.path) — nothing to clear.")
            return
        }
        let store = EmbeddingsSidecarStore(baseDirectory: storeURL)
        let prefix = backend.identifierPrefix
        print("Primary backend prefix: \(prefix)")
        print("Embeddings root:        \(storeURL.path)")
        print("")

        let count = store.countMismatched(primaryPrefix: prefix)
        if count == 0 {
            print("All sidecars are on the \(backend.rawValue) backend. Nothing to clear.")
            return
        }
        print("Outdated sidecars: \(count)")

        guard apply else {
            print("")
            print("Dry run — pass --apply to delete them.")
            return
        }

        print("")
        print("Deleting outdated sidecars…")
        let removed = store.clearMismatched(primaryPrefix: prefix)
        print("Removed \(removed) sidecar(s).")
        print("")
        print("Next step: open Humanist → Library → \"Build Missing Indexes\"")
        print("(or run `humanist-cli reindex --backend \(backend.rawValue)`)")
        print("to re-index the cleared books against \(backend.rawValue).")
    }

    private func resolveStoreURL() -> URL {
        if let storeRoot {
            return URL(fileURLWithPath: storeRoot).standardizedFileURL
        }
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return support
            .appendingPathComponent("Humanist", isDirectory: true)
            .appendingPathComponent("Embeddings", isDirectory: true)
    }
}

/// CLI-friendly mirror of `EmbeddingBackendChoice`. Identical
/// `identifierPrefix` so `clearMismatched` interprets the prefix
/// the same way Settings does. We don't import the SwiftUI-coupled
/// app types from the CLI — this small enum is the bridge.
enum BackendChoice: String, ExpressibleByArgument, CaseIterable {
    case apple
    case ollama
    case voyage
    case gemini

    var identifierPrefix: String {
        switch self {
        case .apple:  return "apple.nl."
        case .ollama: return "ollama."
        case .voyage: return "voyage."
        case .gemini: return "gemini."
        }
    }
}
