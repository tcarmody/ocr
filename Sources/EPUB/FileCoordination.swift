import Foundation

/// Wraps file I/O in `NSFileCoordinator` when the target lives in
/// iCloud Drive. Coordinated access is Apple's recommended path
/// for cloud-synced files for three reasons:
///
///   * **Materializes evicted placeholders.** When iCloud has
///     "Optimize Mac Storage" on, a file may be visible in Finder
///     as a placeholder but not yet downloaded locally. A raw
///     `open()` against the placeholder either fails or returns
///     a sparse zero-filled file; coordinated access triggers
///     the download and waits for the actual bytes to land.
///   * **Pauses sync during the access window.** Without
///     coordination, iCloud can be rewriting the file from the
///     daemon side while we read or write — producing torn reads,
///     ZIP-corruption errors on unpack, and "the file changed
///     under me" save failures.
///   * **Routes through the iCloud daemon's privileges.** macOS
///     TCC / sandbox / `com.apple.macl` checks that gate raw
///     POSIX I/O are often satisfied at the daemon level when
///     the access goes through coordination. Doesn't fix every
///     EPERM case, but converts "silent permission failure" into
///     "OS knows what we're trying to do and can negotiate."
///
/// Local (non-iCloud) paths take an unwrapped fast path —
/// coordination has IPC overhead and offers no benefit when no
/// sync daemon is watching.
public enum FileCoordination {

    /// True when `url` lives under iCloud Drive
    /// (`~/Library/Mobile Documents/com~apple~CloudDocs/…`).
    ///
    /// We use a path-prefix check rather than
    /// `FileManager.isUbiquitousItem(at:)` because the formal
    /// API gates on (a) the file existing on disk AND (b) the
    /// ubiquity container being registered with this app's
    /// entitlements. The path check fires the right way for
    /// writes to paths that don't exist yet (a fresh EPUB
    /// being created in iCloud) and doesn't require any
    /// entitlement plumbing.
    public static func isICloudPath(_ url: URL) -> Bool {
        let path = url.canonicalForFile.path
        return path.contains("/Mobile Documents/com~apple~CloudDocs/")
    }

    /// Run `body` inside an `NSFileCoordinator.coordinate
    /// (readingItemAt:...)` block when `url` is in iCloud;
    /// run it directly otherwise. Generic over the body's
    /// return type so call sites doing different read shapes
    /// (Archive open, Data load, file enumeration) share the
    /// same helper.
    ///
    /// `options` defaults to `[]` — the right choice for most
    /// reads. Set `.withoutChanges` when you're reading without
    /// intending to modify; set `.resolvesSymbolicLink` if the
    /// target may be a symlink.
    public static func coordinatedRead<T>(
        at url: URL,
        options: NSFileCoordinator.ReadingOptions = [],
        body: (URL) throws -> T
    ) throws -> T {
        guard isICloudPath(url) else {
            return try body(url)
        }
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordError: NSError?
        var captured: Result<T, Error>?
        coordinator.coordinate(
            readingItemAt: url, options: options, error: &coordError
        ) { resolved in
            // The accessor closure can't itself throw, so we
            // capture either the return value or the thrown
            // error into `captured` and re-raise outside the
            // coordination block.
            do {
                captured = .success(try body(resolved))
            } catch {
                captured = .failure(error)
            }
        }
        return try unwrap(captured: captured, coordError: coordError)
    }

    /// Run `body` inside an `NSFileCoordinator.coordinate
    /// (writingItemAt:...)` block when `url` is in iCloud;
    /// run it directly otherwise. Use `options:
    /// .forReplacing` when the write atomically swaps the
    /// target file (e.g., `Data.write(to:options:.atomic)` or
    /// `EPUBPackager`'s archive-create-then-rename pattern).
    public static func coordinatedWrite<T>(
        at url: URL,
        options: NSFileCoordinator.WritingOptions = [],
        body: (URL) throws -> T
    ) throws -> T {
        guard isICloudPath(url) else {
            return try body(url)
        }
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordError: NSError?
        var captured: Result<T, Error>?
        coordinator.coordinate(
            writingItemAt: url, options: options, error: &coordError
        ) { resolved in
            do {
                captured = .success(try body(resolved))
            } catch {
                captured = .failure(error)
            }
        }
        return try unwrap(captured: captured, coordError: coordError)
    }

    // MARK: - Internals

    /// Common rethrow logic: a coordinator error wins (it means
    /// the coordination itself failed and the accessor never
    /// ran), then the accessor's captured throw, then a
    /// defensive "accessor never invoked" path that shouldn't
    /// happen but is worth guarding against.
    private static func unwrap<T>(
        captured: Result<T, Error>?, coordError: NSError?
    ) throws -> T {
        if let coordError { throw coordError }
        switch captured {
        case .success(let value): return value
        case .failure(let error): throw error
        case .none:
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(EIO),
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "File coordination did not invoke the accessor"
                ]
            )
        }
    }
}
