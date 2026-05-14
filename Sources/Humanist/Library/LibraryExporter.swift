import Foundation
import Combine

/// R-Library-Export. Copies catalog `.epub` files to a user-chosen
/// folder, renaming each one to `Author - Title.epub` (falling back
/// to `Title.epub` when no author is on the entry). The source EPUBs
/// stay put — this is a one-way export for handing books off to
/// another reader app (Calibre, Books, Kindle's Send-to-Kindle, etc.)
/// where the catalog metadata is more useful than Humanist's
/// on-disk filename (which is typically the source PDF's stem).
///
/// Skip-if-exists: a target path that already exists is left alone
/// and reported in `skipped`. The alternative — silent overwrite —
/// would lose user edits made in the destination library; auto-
/// rename would clutter the destination with `Foo (2).epub` chaff.
/// Skip is the safe default; the user can clear the destination and
/// re-export if they want a fresh copy.
///
/// Progress mirrors the Classify / Refresh sheets via
/// `AsyncWorkProgressSheet`, so the user sees a counter + cancel
/// during the run and a per-outcome summary on completion.
@MainActor
final class LibraryExporter: ObservableObject {
    @Published private(set) var current: Int = 0
    @Published private(set) var total: Int = 0
    @Published private(set) var done: Bool = false
    @Published private(set) var copied: Int = 0
    /// Display names of entries skipped because the target already
    /// existed at the destination. Surfaced in the done-state
    /// summary so the user can choose to clear + re-export.
    @Published private(set) var skipped: [String] = []
    /// `(targetFilename, errorDescription)` for any copy that
    /// failed (permissions, disk full, source vanished). The
    /// catalog-side state is untouched — failed copies just don't
    /// appear in the destination.
    @Published private(set) var failed: [(String, String)] = []

    private var task: Task<Void, Never>?

    /// Kick off an export run. Replaces any in-flight task so a
    /// re-trigger from the menu cancels the prior run before
    /// starting fresh. Resets all counters on start so a re-run
    /// inside an already-shown progress sheet doesn't show stale
    /// numbers between the trigger and the first copy.
    func start(entries: [LibraryEntry], destination: URL) {
        cancel()
        current = 0
        total = entries.count
        done = false
        copied = 0
        skipped = []
        failed = []
        task = Task { [weak self] in
            await self?.run(entries: entries, destination: destination)
        }
    }

    /// Stop the run at the next iteration. Already-completed copies
    /// stay in place — there's no rollback. The done flag is set so
    /// the progress sheet can flip to its dismiss state.
    func cancel() {
        task?.cancel()
        task = nil
    }

    private func run(entries: [LibraryEntry], destination: URL) async {
        for (i, entry) in entries.enumerated() {
            if Task.isCancelled { break }
            let baseName = Self.exportBaseName(
                author: entry.author, title: entry.title
            )
            let target = destination
                .appendingPathComponent(baseName + ".epub")
            do {
                if FileManager.default.fileExists(atPath: target.path) {
                    skipped.append(target.lastPathComponent)
                } else {
                    try FileManager.default.copyItem(
                        at: entry.epubURL, to: target
                    )
                    copied += 1
                }
            } catch {
                failed.append(
                    (target.lastPathComponent, error.localizedDescription)
                )
            }
            current = i + 1
        }
        done = true
        task = nil
    }

    // MARK: - filename composition

    /// Compose the `.epub`'s base filename (no extension) for export.
    /// `Author - Title` when both are present; just `Title` when
    /// `author` is nil, empty, or all-whitespace. Both components
    /// are sanitized and the whole string is clamped under a typical
    /// filesystem-friendly byte budget before being returned.
    /// Static so tests can hit the naming logic without spinning up
    /// the full exporter + filesystem.
    static func exportBaseName(author: String?, title: String) -> String {
        let cleanedTitle = sanitize(title)
        let titleOrFallback = cleanedTitle.isEmpty ? "Untitled" : cleanedTitle

        let normalizedAuthor = (author ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedAuthor = sanitize(normalizedAuthor)
        if cleanedAuthor.isEmpty {
            return clampBytes(titleOrFallback, maxBytes: 200)
        }
        return clampBytes(
            "\(cleanedAuthor) - \(titleOrFallback)", maxBytes: 200
        )
    }

    /// Strip filesystem-hostile characters from a string so it can
    /// safely become part of a filename. macOS APFS forbids `/` and
    /// NUL in path components; the Finder + many sync tools also
    /// trip on `:` (it's the classic HFS path separator). Control
    /// characters are dropped outright. Leading/trailing dots and
    /// whitespace are trimmed so the result doesn't look hidden
    /// (`.foo`) or extensionless (`foo.`).
    static func sanitize(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for scalar in s.unicodeScalars {
            if CharacterSet.controlCharacters.contains(scalar) {
                continue
            }
            switch scalar {
            case "/", ":", "\\":
                out.append("-")
            default:
                out.append(Character(scalar))
            }
        }
        let trim = CharacterSet.whitespacesAndNewlines
            .union(CharacterSet(charactersIn: "."))
        return out.trimmingCharacters(in: trim)
    }

    /// Trim a string by Unicode scalar until its UTF-8 representation
    /// fits under `maxBytes`. macOS filenames are limited to 255
    /// bytes per path component (filesystem-level cap) — we leave
    /// headroom for `.epub` and a `Author - ` prefix at the caller's
    /// discretion. Drops trailing whitespace introduced by truncation
    /// so the final filename doesn't end mid-word with a space.
    static func clampBytes(_ s: String, maxBytes: Int) -> String {
        if s.utf8.count <= maxBytes { return s }
        var working = s
        while working.utf8.count > maxBytes, !working.isEmpty {
            working.removeLast()
        }
        return working.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
