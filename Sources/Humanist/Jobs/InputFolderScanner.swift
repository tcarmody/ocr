import Foundation
import AppKit
import EPUB  // canonicalForFile

/// Auto-scan watcher for the configured `<outputRoot>/Input/` folder.
/// When the user enables "Automatically scan Input folder for new
/// PDFs" in Settings, the launcher starts one of these; it watches
/// the directory for file-system events, picks up any `.pdf` that
/// doesn't already have a corresponding `<outputRoot>/Books/<stem>
/// .epub` (or queue entry), and enqueues it through the existing
/// `QueueViewModel`. Outputs land in the usual per-format
/// subfolders — same code path as a drag-drop or `Convert PDF to
/// EPUB…` open.
///
/// Skip rules (in order, cheap → expensive):
///   1. EPUB already exists at the expected destination.
///   2. Queue already has a job pointing at this source path.
///   3. Source content hash (SHA-256) matches an existing catalog
///      entry's `sourceContentHashes` (dedupe), OR is in the
///      library's `rejectedSourceHashes` set (the user explicitly
///      told us not to re-scan it via the remove dialog).
///
/// Rule 3 is the multi-Mac / "I deleted the bad EPUB" answer — the
/// catalog hash set survives entry deletion when the user opts in
/// at remove time, and syncs across Macs so a PDF the user rejected
/// on Mac A won't re-enqueue on Mac B.
///
/// Hash work runs on a detached background task because SHA-256 of
/// a 100 MB PDF can take ~100 ms; doing it on MainActor would stall
/// the launcher during every Input-folder filesystem event. Cheap
/// path checks happen first so the common "nothing new" event is a
/// MainActor-only roundtrip.
@MainActor
final class InputFolderScanner: ObservableObject {

    /// Currently watching? Surfaced for diagnostics and for the
    /// Settings toggle's live state.
    @Published private(set) var isWatching: Bool = false

    /// Number of PDFs newly enqueued in the most recent scan pass.
    /// Reset to zero when the watcher starts; bumps on each
    /// directory change event.
    @Published private(set) var lastScanEnqueuedCount: Int = 0

    /// Surfaced when the watcher couldn't open the Input folder
    /// (root unset, directory missing, permission denied). Cleared
    /// on successful start.
    @Published private(set) var lastError: String?

    private weak var queue: QueueViewModel?
    private weak var library: LibraryStore?
    private var fileMonitor: DispatchSourceFileSystemObject?
    private var monitoredDescriptor: Int32 = -1
    /// Per-path hash cache. SHA-256 of an unchanged PDF doesn't
    /// vary, so the second pass over a PDF the user keeps in
    /// Input (waiting for batch action, debugging a failed scan,
    /// etc.) is free. Keyed by canonical path + invalidated when
    /// the file's mtime or size drifts.
    private struct HashEntry {
        let mtime: TimeInterval
        let size: Int64
        let hash: String
    }
    private var hashCache: [String: HashEntry] = [:]
    /// In-flight scan task — cancelled when a new event arrives so
    /// the most recent dir state always wins. Without this a
    /// rapid-fire Finder copy could queue up redundant scans, each
    /// re-hashing the same PDF.
    private var inFlightScan: Task<Void, Never>?
    /// Pending coalesce timer — directory writes can fire several
    /// `.write` events in quick succession (a Finder copy lands as
    /// rename + truncate + write). Coalesce to a single rescan
    /// after a short debounce so we don't hammer the queue with
    /// duplicate work.
    private var debounceTask: Task<Void, Never>?
    private let debounce: Duration = .milliseconds(400)

    init() {}

    deinit {
        debounceTask?.cancel()
        fileMonitor?.cancel()
        if monitoredDescriptor >= 0 {
            close(monitoredDescriptor)
        }
    }

    /// Begin watching `<outputRoot>/Input/`. Idempotent — calling
    /// again with the same (queue, library) is a no-op. Runs an
    /// immediate scan so PDFs left in the folder while the app was
    /// closed pick up on launch. The library reference is weak and
    /// used solely for the content-hash skip check; a nil library
    /// degrades to path-only skip (the pre-hash behavior).
    func start(queue: QueueViewModel, library: LibraryStore?) {
        if isWatching, self.queue === queue, self.library === library { return }
        self.queue = queue
        self.library = library
        stopMonitor()
        guard let inputFolder = ConversionOutputResolver.inputFolderURL() else {
            lastError = "Configure an output folder in Settings → Conversion first."
            isWatching = false
            return
        }
        let path = inputFolder.path
        let fd = open(path, O_EVTONLY)
        if fd < 0 {
            lastError = "Couldn't open \(path) for watching (errno \(errno))."
            isWatching = false
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.scheduleRescan()
        }
        source.setCancelHandler { [fd] in
            close(fd)
        }
        source.resume()
        fileMonitor = source
        monitoredDescriptor = fd
        isWatching = true
        lastError = nil
        lastScanEnqueuedCount = 0
        // Initial pass so anything left in the folder while the
        // app was closed shows up immediately.
        scanNow()
    }

    /// Stop watching. Safe to call multiple times.
    func stop() {
        debounceTask?.cancel()
        debounceTask = nil
        inFlightScan?.cancel()
        inFlightScan = nil
        stopMonitor()
        isWatching = false
    }

    /// Force an immediate scan pass — useful from a manual "Scan
    /// Now" button or after the user explicitly toggles the
    /// feature on. Doesn't start watching; pair with `start` for
    /// the full feature.
    ///
    /// Two-phase: cheap MainActor checks (path-based) run first
    /// against every candidate, then any survivors get a SHA-256
    /// pass on a detached task with hops back to MainActor to
    /// query the library + enqueue. Cancelling the in-flight scan
    /// when a new dir event arrives keeps the hash work bounded
    /// during a Finder-copy storm.
    func scanNow() {
        guard let queue,
              let inputFolder = ConversionOutputResolver.inputFolderURL()
        else { return }
        let urls = pdfsIn(folder: inputFolder)
        // First-pass path check — drops the obvious skips (EPUB
        // exists, already in queue) before we pay any hash work.
        let candidates = urls.filter {
            passesCheapCheck(source: $0, queue: queue)
        }
        guard !candidates.isEmpty else {
            lastScanEnqueuedCount = 0
            return
        }
        // If we don't have a library reference, skip the hash
        // step entirely and enqueue everything the cheap check
        // allowed through. Functionally equivalent to the pre-
        // Phase-D behavior — used by tests + the no-catalog path.
        guard let library = self.library else {
            for url in candidates { queue.addPDF(url) }
            lastScanEnqueuedCount = candidates.count
            return
        }
        inFlightScan?.cancel()
        let scan = Task { [weak self] in
            guard let self else { return }
            await self.runHashedScan(
                candidates: candidates, queue: queue, library: library
            )
        }
        inFlightScan = scan
    }

    private func runHashedScan(
        candidates: [URL],
        queue: QueueViewModel,
        library: LibraryStore
    ) async {
        var enqueued = 0
        for url in candidates {
            if Task.isCancelled { return }
            // Snapshot file attributes for the hash-cache key. A
            // moved/renamed file ends up in a new path; mtime
            // typically changes on copy-from-Finder, which is the
            // signal we trust for "this file might be different."
            let attrs = (try? FileManager.default
                .attributesOfItem(atPath: url.path)) ?? [:]
            let mtime = (attrs[.modificationDate] as? Date)?
                .timeIntervalSince1970 ?? 0
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0

            let hash: String?
            if let cached = hashCache[url.path],
               cached.mtime == mtime, cached.size == size {
                hash = cached.hash
            } else {
                let urlCopy = url
                hash = await Task.detached(priority: .utility) {
                    try? ContentHash.sha256(of: urlCopy)
                }.value
                if let computed = hash {
                    hashCache[url.path] = HashEntry(
                        mtime: mtime, size: size, hash: computed
                    )
                }
            }
            guard let hash else {
                // Hashing failed (file just got moved/deleted out
                // from under us, permission glitch). Skip rather
                // than guess — next event will re-evaluate.
                continue
            }
            if library.isSourceHashKnownOrRejected(hash) {
                continue
            }
            queue.addPDF(url)
            enqueued += 1
        }
        if Task.isCancelled { return }
        lastScanEnqueuedCount = enqueued
    }

    // MARK: - Internals

    private func stopMonitor() {
        fileMonitor?.cancel()
        fileMonitor = nil
        // `setCancelHandler` closes the fd; the descriptor field
        // is just diagnostics, reset for clarity.
        monitoredDescriptor = -1
    }

    private func scheduleRescan() {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: debounce)
            if Task.isCancelled { return }
            self.scanNow()
        }
    }

    /// PDFs directly inside `folder` (non-recursive). Hidden files
    /// (e.g. macOS `.DS_Store`) are skipped. Sorted by name so the
    /// enqueue order is deterministic across runs.
    private func pdfsIn(folder: URL) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        )) ?? []
        return contents
            .filter { $0.pathExtension.lowercased() == "pdf" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Path-only skip check — the cheap pre-filter. Skip when: the
    /// expected output EPUB already exists, OR the queue already
    /// has a job pointing at this source. The content-hash check
    /// against the catalog is layered on top in `runHashedScan` so
    /// "I deleted the EPUB and don't want to re-scan" survives
    /// across machines.
    private func passesCheapCheck(source: URL, queue: QueueViewModel) -> Bool {
        let expectedOutput = ConversionOutputResolver.epubOutputURL(
            forSource: source
        )
        if FileManager.default.fileExists(atPath: expectedOutput.path) {
            return false
        }
        let canonicalSource = source.canonicalForFile
        for job in queue.store.jobs {
            if job.sourceURL.canonicalForFile == canonicalSource {
                return false
            }
        }
        return true
    }
}
