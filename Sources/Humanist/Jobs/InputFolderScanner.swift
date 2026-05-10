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
/// "Has already been scanned" check: an output EPUB exists at the
/// expected destination OR the source URL is already a job in the
/// queue (any state — running, done, failed, profiling).
/// User-triggered re-scan path is "delete the output EPUB" — same
/// posture as the rest of the conversion pipeline.
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
    private var fileMonitor: DispatchSourceFileSystemObject?
    private var monitoredDescriptor: Int32 = -1
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
    /// again with the same queue is a no-op. Runs an immediate
    /// scan so PDFs left in the folder while the app was closed
    /// pick up on launch.
    func start(queue: QueueViewModel) {
        if isWatching, self.queue === queue { return }
        self.queue = queue
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
        stopMonitor()
        isWatching = false
    }

    /// Force an immediate scan pass — useful from a manual "Scan
    /// Now" button or after the user explicitly toggles the
    /// feature on. Doesn't start watching; pair with `start` for
    /// the full feature.
    func scanNow() {
        guard let queue,
              let inputFolder = ConversionOutputResolver.inputFolderURL()
        else { return }
        let urls = pdfsIn(folder: inputFolder)
        var enqueued = 0
        for url in urls {
            if shouldEnqueue(source: url, queue: queue) {
                queue.addPDF(url)
                enqueued += 1
            }
        }
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

    /// Skip when: the expected output EPUB already exists, OR the
    /// queue already has a job pointing at this source. Both
    /// guards together keep us from re-enqueuing a PDF the user
    /// dropped in while a previous scan was still in flight.
    private func shouldEnqueue(source: URL, queue: QueueViewModel) -> Bool {
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
