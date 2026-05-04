import Foundation

public extension URL {
    /// File URL with symlinks resolved AND path components normalized.
    ///
    /// macOS canonicalizes filesystem paths (`/var/folders/...` →
    /// `/private/var/folders/...`) inside several APIs (most notably
    /// `FileManager.contentsOfDirectory(at:)` and the WebKit sandbox
    /// check). When some code paths use the symlink form and others
    /// the resolved form, equality fails, dictionary lookups miss,
    /// and prefix checks reject legitimate paths.
    ///
    /// Use this whenever a URL will be:
    ///   * compared to another URL,
    ///   * used as a dictionary or set key,
    ///   * checked with `hasPrefix` against another path,
    ///   * handed to a strict-prefix API like WebKit's `loadFileURL(_:allowingReadAccessTo:)`.
    ///
    /// Cheap to call repeatedly; safe on non-file URLs (returns self).
    var canonicalForFile: URL {
        guard isFileURL else { return self }
        return resolvingSymlinksInPath().standardizedFileURL
    }
}
